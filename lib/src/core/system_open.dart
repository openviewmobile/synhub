// 「把本地文件交给系统默认应用打开」这一步的**唯一入口**。
//
// 为什么要有这个文件（用户明确要求过）：
//   测试/验证时用的都是"假文件"（几十字节的占位 png / 空 mp4 / 拼出来的 docx…），
//   在 mac 上真交给系统就是 **Preview / QuickTime 弹出来报错**，一点都不好看，
//   而且离线测试本来就不该启动任何外部应用。
//   所以：
//   * 跑在 `flutter test` 里时**直接 no-op**（`FLUTTER_TEST` 环境变量，flutter tool 自己放）；
//   * 桌面/没有插件桥的环境静默失败（原来会抛 `MissingPluginException`）；
//   * 需要断言"到底有没有打开"的测试用 `systemOpenProvider` 覆盖成假的
//     （见 `test/system_open_test.dart`）。
//
// Android 真机上的行为不变：system_open.dart 只多一层环境判断，
// 真正打开的是带**显式 MIME** 的 `ACTION_VIEW`（`MediaOpenBridge.viewLocal`，
// 认不出桥时才退回 `open_filex`）。
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:open_filex/open_filex.dart';

import '../features/chat/media_stream.dart'
    show fileExtensionOf, kMimeByExtension;
import 'user_facing_error.dart';

/// "打开本地文件"的可注入签名（测试里换成记录调用的假实现）。
typedef SystemOpenRunner = Future<OpenResult> Function(String path);

/// `flutter test` 会在测试进程的环境变量里放 `FLUTTER_TEST=true`。
///
/// ⚠️ 只用于**避免在测试里启动系统应用**，不要拿它当业务分支用。
///
/// ★★ 第 336 轮（web 首屏 D34 的第二发）：**`!kIsWeb` 必须写在最左边**。
///   `Platform.environment` 在 web 上**抛** `UnsupportedError`（dart2js 的
///   `dart:io` 是抛错桩），而原来的调用方 `readDeviceModel()` 写的是
///   `if (isTestEnvironment || kIsWeb || ...)` —— `||` **从左往右短路**，
///   于是"判 web 的那一位"根本没轮到，启动路径当场抛。（教训：
///   **把 `kIsWeb` 放在 `||` 右边 = 没判**。）
bool get isTestEnvironment =>
    !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

/// 本地文件交给系统应用时要显式给的 MIME。
///
/// **为什么不能只靠 `open_filex`**：它内部那张手写表（`OpenFilePlugin.getFileType`）
/// 里**没有** `mkv` / `webm` / `flac` / `opus` / `heic` …，`default` 直接回 `*/*`。
/// 于是 `.mkv` 的 `ACTION_VIEW` 变成 `content://…` + `*/*`，华为/HONOR ROM
/// （真机 HONOR LGE-AN10 / API 31）把它解析到
/// `com.android.packageinstaller/.InstallStart` —— 既不弹选择器也打不开；
/// 而 `.mp4` 命中 `video/mp4` 就能正常拉起 `Complete action using`。
///
/// 这里复用播放/串流那套扩展名表（`kMimeByExtension`），认不出来才回 `*/*`。
String externalOpenMimeOf(String path) =>
    kMimeByExtension[fileExtensionOf(path)] ?? '*/*';

/// 打开本地文件（默认实现）。
///
/// * 测试环境：**不打开**，返回一个 done 占位（调用方只看"成功/失败"文案）；
/// * Android：桥（`synhub/media_open` 的 `viewLocal`）用显式 MIME +
///   FileProvider 发 `ACTION_VIEW`；桥不在（桌面/iOS）才退回 `open_filex`；
/// * 其余平台：`open_filex`。
Future<OpenResult> defaultSystemOpen(String path) async {
  if (isTestEnvironment) {
    return OpenResult(type: ResultType.done, message: 'test-noop');
  }
  // 第 79 轮：`Platform.isAndroid` → 能力门（语义等价：Android 静态 available、
  // 桌面 unavailable；`unknown` 也放行，与旧判断同为"先放过去试"）。
  if (capabilityGateAllows(AppCapability.systemOpen)) {
    try {
      final handled =
          await _mediaOpenChannel.invokeMethod<bool>('viewLocal', {
            'path': path,
            'mime': externalOpenMimeOf(path),
          }) ??
          false;
      if (handled) {
        return OpenResult(type: ResultType.done, message: 'android-view');
      }
      // 桥明确说"没有应用能处理这个 MIME"：不要再用 `open_filex` 的 `*/*`
      // 去撞一遍（那正是 `.mkv` 被 `InstallStart` 接走的原因）。
      return OpenResult(type: ResultType.error, message: 'no-handler');
    } on MissingPluginException {
      // 没挂桥（桌面跑 / 纯 Dart）→ 退回插件
    } on PlatformException {
      // 桥自己失败 → 也退回插件
    }
  }
  // ★★ 第 42 轮（macOS 迁移 P0-1）：`open_filex` 的 plugin platforms 只有
  //   android/ios ⇒ 在 macOS 上**必然失败**（它是这里唯一的兜底），
  //   于是"用外部应用打开"在桌面上是死的。桌面改用系统命令，
  //   失败也不抛到界面（与上面的 Android 分支同一种"如实回错误"的风格）。
  //   注：macOS 上 `open` 是系统自带的启动器；不引入 url_launcher 依赖。
  // ★ 同轮：web 上这里也必须先短路（`Platform.isMacOS` 在 web 上抛）。
  if (!kIsWeb &&
      (Platform.isMacOS || Platform.isLinux || Platform.isWindows)) {
    final cmd = Platform.isMacOS
        ? 'open'
        : (Platform.isWindows ? 'explorer' : 'xdg-open');
    try {
      final r = await Process.run(cmd, <String>[path]);
      if (desktopOpenExitIsSuccess(
        isWindows: Platform.isWindows,
        exitCode: r.exitCode,
      )) {
        return OpenResult(type: ResultType.done, message: 'desktop-open');
      }
      return OpenResult(
        type: ResultType.error,
        message: 'desktop-open-exit-${r.exitCode}',
      );
    } catch (e) {
      return OpenResult(type: ResultType.error, message: userFacingError(e));
    }
  }
  try {
    return await OpenFilex.open(path);
  } catch (e) {
    return OpenResult(type: ResultType.error, message: userFacingError(e));
  }
}

/// 桌面"外部打开"命令的**退出码判据**（纯函数 ⇒ 可在任意宿主上单测）。
///
/// ★ r295（真 Windows VM 实测）：`.exe` 的返回码**不是**成功信号 ——
/// `explorer.exe <path>` 在"把请求转交给**已有**的 explorer 实例"时**回 1**，
/// 而真桌面上确实开了新窗口（`CabinetWClass` 窗口数 **3 → 4**、标题是目标目录）。
/// 原判据 `exitCode == 0` 会把这次**成功的**打开如实报成
/// `desktop-open-exit-1`（用户看到"打开失败"，其实已经开了）。
///
/// 因此 Windows 上 0/1 都算成功；其它平台仍只认 0
/// （`open` / `xdg-open` 的失败确实给非 0，别顺手放宽它们）。
bool desktopOpenExitIsSuccess({
  required bool isWindows,
  required int exitCode,
}) => exitCode == 0 || (isWindows && exitCode == 1);

/// 系统打开的可注入 provider（默认 `defaultSystemOpen`）。
final systemOpenProvider = Provider<SystemOpenRunner>(
  (ref) => defaultSystemOpen,
);

const MethodChannel _mediaOpenChannel = MethodChannel(
  'synhub/media_open',
);
