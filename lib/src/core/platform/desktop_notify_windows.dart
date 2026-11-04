// r709 · Windows **桌面通知**（`Windows.UI.Notifications` 的 toast）。
//
// 为什么自己写一份：
//   * `flutter_local_notifications` **没有 windows 列**，所以这条能力在 Windows 上
//     一直是 `unavailable:not-implemented-on-host`（`app_platform.dart` 的 Windows 分支）；
//   * Windows 10/11 的标准做法是 WinRT 的 toast（`ToastNotificationManager`），
//     **不引入新依赖**就能用 `powershell.exe` 发（本仓没有 C++/WinRT 绑定，也没有
//     `winrt` 的 Dart 包，照 Linux 那份的经验走子进程最省）。
//
// ★★ 前置条件（r708 才具备，这也是为什么这条以前做不了）：
//   toast **必须带一个"已注册"的 AUMID**（App User Model ID），否则
//   `CreateToastNotifier()` 直接抛 `Element not found`（HRESULT 0x80070490）。
//   AUMID 的来源只有两种：① 装成 MSIX（Start 菜单里就有了）；
//   ② 在 Start 菜单放一个带 `System.AppUserModel.ID` 的快捷方式。
//   r708 把 MSIX 侧载链打通以后，**打包态天然有 AUMID** ⇒ 这条能力才有前提。
//
// 判据（AGENTS §2.0.6 第 3 条"宿主不编事实"）：
//   * 能力位**只认安装形态**：能推导出 AUMID（= 跑在 `C:\Program Files\WindowsApps\…`
//     里、包名形如 `<Name>_<x.y.z.w>_<arch>__<publisherId>`）才算可用；
//     免安装的 dev 版**如实报未实现**，不许拿"代码写了"当能用；
//   * `show()` 返回 `true` 只代表**调用通了**（PowerShell 退出码 0），
//     证明"真弹出去了"必须是**消费方**的读数（像素里的横幅 / 操作中心的条目）。
//     这条区分与 `desktop_notify_linux.dart` 同一个口径。
import 'dart:convert';
import 'dart:io';

// ★ 这个文件**故意不 import `package:flutter/*`**：它是纯 `dart:io` 的桌面集成，
//   不 import flutter 才好在 guest 上直接 `dart run tool/probe/…` 验（探针不必
//   起 Flutter 引擎）。`kIsWeb` 在 `foundation` 里本来就是
//   `bool.fromEnvironment('dart.library.js_util')`，这里照抄同一个判据。
const bool _kIsWeb = bool.fromEnvironment('dart.library.js_util');

/// 跑子进程的最小接口（测试可注入，不必真起 PowerShell）。
typedef WindowsProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      Map<String, String>? environment,
    });

Future<ProcessResult> _defaultRunner(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
}) => Process.run(executable, arguments, environment: environment);

/// 把 `C:\Program Files\WindowsApps\<PFN 目录>\synhub.exe` 解析成 AUMID。
///
/// 目录名是 **PackageFamilyName 目录**（`<Name>_<x.y.z.w>_<arch>__<publisherId>`），
/// 而 AUMID 要的是 **PackageFamilyName**（`<Name>_<publisherId>`，去掉版本与架构）。
/// 例：目录 `com.flutter.synhub_1.0.0.0_x64__fxkeb4dgdm144`
///     ⇒ PFN `com.flutter.synhub_fxkeb4dgdm144`
///     ⇒ AUMID `com.flutter.synhub_fxkeb4dgdm144!synhub`。
///
/// 不是打包态（路径里没有 `WindowsApps`）⇒ 返回 `null`（**不猜**）。
String? windowsToastAumid({String? exePath, String appId = 'synhub'}) {
  final path = (exePath ?? Platform.resolvedExecutable).replaceAll('/', r'\');
  final m = RegExp(
    r'\\WindowsApps\\([^\\]+)\\',
    caseSensitive: false,
  ).firstMatch(path);
  if (m == null) return null;
  final dir = m.group(1)!;
  final parts = RegExp(
    r'^(.+?)_(\d+\.\d+\.\d+\.\d+)_([A-Za-z0-9]+)__([A-Za-z0-9]+)$',
  ).firstMatch(dir);
  if (parts == null) {
    // 目录名不合 `<Name>_<ver>_<arch>__<pub>` 的形状：可能是别的 App 的目录，
    // 也可能 Windows 以后换了命名 —— 两种都**不猜**，如实返回 null。
    return null;
  }
  return '${parts.group(1)}_${parts.group(4)}!$appId';
}

/// **能力位判据（可注入，便于确定性验收）**：宿主是 Windows **且**能推导出 AUMID。
///
/// 两个入参都是为了"把判据本身钉死"：
///   * [isWindows] —— 不传就看 `Platform.isWindows`；传了就按它算，
///     这样在 macOS 上跑 `flutter test` 也能验"打包态 Windows ⇒ 可用"这一格；
///   * [exePath] —— 同上，验"免安装 ⇒ 不可用"。
/// ★ 没有这个注入点时，能力列会**随测试宿主机变**，守卫就会静默放过
///   （r709 现场发现：`platform_web_test` 里"windows 的 available 集合不变"
///   在 macOS 上恒真）—— 所以判据必须能被单独钉住。
bool windowsToastCapability({
  String? exePath,
  bool? isWindows,
  String appId = 'synhub',
}) {
  if (_kIsWeb) return false;
  final win = isWindows ?? Platform.isWindows;
  if (!win) return false;
  return windowsToastAumid(exePath: exePath, appId: appId) != null;
}

/// 当前进程所在安装形态**有没有**可用 AUMID（能力位的默认入参版本）。
bool windowsToastAumidAvailable() => windowsToastCapability();

/// PowerShell 脚本：发一条 `ToastText02`（标题 + 正文）。
///
/// 用 `-EncodedCommand`（base64 的 UTF-16LE）传，好处是**完全没有引号转义**问题；
/// 标题/正文/AppId 走**环境变量**，也不进命令行。
const String _showScript = r'''
$ErrorActionPreference = 'Stop'
$id = $env:SYNHUB_TOAST_APPID
$title = $env:SYNHUB_TOAST_TITLE
$body = $env:SYNHUB_TOAST_BODY
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
$tpl = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
  [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$texts = $tpl.GetElementsByTagName('text')
$null = $texts.Item(0).AppendChild($tpl.CreateTextNode($title))
$null = $texts.Item(1).AppendChild($tpl.CreateTextNode($body))
$toast = [Windows.UI.Notifications.ToastNotification]::new($tpl)
# r710: Tag/Group make per-item removal possible via History.Remove(tag, group, id).
# Android's tag string is {"channel_id":N,"thread_id":T}; reuse it verbatim.
if ($env:SYNHUB_TOAST_TAG) { $toast.Tag = $env:SYNHUB_TOAST_TAG }
if ($env:SYNHUB_TOAST_GROUP) { $toast.Group = $env:SYNHUB_TOAST_GROUP }
$notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($id)
# Drop the previous entry with the same (tag, group) first: Android keeps one
# notification per channel/thread, and a plain Show would stack duplicates.
if ($env:SYNHUB_TOAST_TAG) {
  try { [Windows.UI.Notifications.ToastNotificationManager]::History.Remove($env:SYNHUB_TOAST_TAG, $env:SYNHUB_TOAST_GROUP, $id) } catch {}
}
$notifier.Show($toast)
''';

/// PowerShell 脚本：按 `(tag, group)` 撤掉**一条**（`History.Remove`）。
///
/// ★ 为什么是 `History.Remove` 而不是 `ToastNotifier.Hide`：`Hide` 只对**当前挂在
/// 屏幕上**的那一条有效，用户已经把横幅划走、条目还在操作中心里时它什么都不做；
/// 而 `History.Remove(tag, group, aumid)` 撤的是**操作中心里的条目**（这才是用户
/// 感知的"通知没了"）。两条读数在 guest 上都量过（见 `docs/platform-windows.md` §24）。
const String _removeScript = r'''
$ErrorActionPreference = 'Stop'
$id = $env:SYNHUB_TOAST_APPID
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
if ($env:SYNHUB_TOAST_TAG) {
  [Windows.UI.Notifications.ToastNotificationManager]::History.Remove($env:SYNHUB_TOAST_TAG, $env:SYNHUB_TOAST_GROUP, $id)
} elseif ($env:SYNHUB_TOAST_GROUP) {
  [Windows.UI.Notifications.ToastNotificationManager]::History.RemoveGroup($env:SYNHUB_TOAST_GROUP, $id)
} else {
  [Windows.UI.Notifications.ToastNotificationManager]::History.Clear($id)
}
''';

/// PowerShell 脚本：撤掉本 App 的**全部**通知（`History.Clear(aumid)`）。
const String _clearScript = r'''
$ErrorActionPreference = 'Stop'
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.UI.Notifications.ToastNotificationManager]::History.Clear($env:SYNHUB_TOAST_APPID)
''';

/// UTF-16LE 编码（`-EncodedCommand` 要的就是这个；PowerShell 不认 UTF-8）。
List<int> encodeUtf16Le(String text) {
  final out = <int>[];
  for (final unit in text.codeUnits) {
    out.add(unit & 0xff);
    out.add((unit >> 8) & 0xff);
  }
  return out;
}

/// 把脚本包成 `powershell.exe` 的参数（`-EncodedCommand`）。
List<String> powershellArgs(String script) => <String>[
  '-NoProfile',
  '-NonInteractive',
  '-ExecutionPolicy',
  'Bypass',
  '-EncodedCommand',
  base64.encode(encodeUtf16Le(script)),
];

/// Windows 桌面通知的最小实现（`powershell.exe` + WinRT toast）。
class WindowsDesktopNotifier {
  const WindowsDesktopNotifier({this.aumid, WindowsProcessRunner? run})
    : _run = run;

  /// 显式指定 AUMID（探针/测试用）；留空则按**当前进程的安装形态**推导。
  final String? aumid;
  final WindowsProcessRunner? _run;

  String? get _resolvedAumid => aumid ?? windowsToastAumid();

  /// 发一条通知。返回 `true` 只代表**调用通了**（见文件头）。
  Future<bool> show({
    required String title,
    required String body,
    String appName = 'SynHub',
    String? icon,
    String? tag,
    String? group,
  }) async {
    if (_kIsWeb || !Platform.isWindows) return false;
    final id = _resolvedAumid;
    if (id == null || id.isEmpty) return false;
    final env = <String, String>{
      'SYNHUB_TOAST_APPID': id,
      'SYNHUB_TOAST_TITLE': title,
      'SYNHUB_TOAST_BODY': body,
      // 空 tag 就不传（PowerShell 侧用 `if ($env:…)` 判空）。
      if (tag != null && tag.isNotEmpty) 'SYNHUB_TOAST_TAG': tag,
      if (group != null && group.isNotEmpty) 'SYNHUB_TOAST_GROUP': group,
    };
    final run = _run ?? _defaultRunner;
    try {
      final r = await run(
        'powershell.exe',
        powershellArgs(_showScript),
        environment: env,
      );
      return r.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// 按 `(tag, group)` 撤掉一条；只给 [group] 就撤这一组；都不给 = 全清。
  ///
  /// 这是 Windows 上 `cancelTag(tag)` / `cancelChannel(channelId)` 的落地形态：
  /// Android 的通知 identity 就是 (tag, id)，Windows 的对应物是 (Tag, Group)。
  Future<bool> remove({String? tag, String? group}) async {
    if (_kIsWeb || !Platform.isWindows) return false;
    final id = _resolvedAumid;
    if (id == null || id.isEmpty) return false;
    final run = _run ?? _defaultRunner;
    try {
      final r = await run(
        'powershell.exe',
        powershellArgs(_removeScript),
        environment: <String, String>{
          'SYNHUB_TOAST_APPID': id,
          if (tag != null && tag.isNotEmpty) 'SYNHUB_TOAST_TAG': tag,
          if (group != null && group.isNotEmpty) 'SYNHUB_TOAST_GROUP': group,
        },
      );
      return r.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// 撤掉本 App 的全部通知。AUMID 不可得 ⇒ `false`（不假装成功）。
  Future<bool> clearAll() async {
    if (_kIsWeb || !Platform.isWindows) return false;
    final id = _resolvedAumid;
    if (id == null || id.isEmpty) return false;
    final run = _run ?? _defaultRunner;
    try {
      final r = await run(
        'powershell.exe',
        powershellArgs(_clearScript),
        environment: <String, String>{'SYNHUB_TOAST_APPID': id},
      );
      return r.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }
}
