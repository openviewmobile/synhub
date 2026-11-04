// ⑥下载 F10：**内置链接浏览器**（对齐官方安卓端 `BrowserActivity` + WebView +
// `onDownloadStart`：用户在内置浏览器里点链接，命中的直接建成下载任务）。
//
// 事实来源：`DSdownload.apk` 的 `classes*.dex` 含
// `Lcom/synology/DSdownload/activities/BrowserActivity;`、
// `Landroid/webkit/WebView;`、`Landroid/webkit/WebViewClient;`、`onDownloadStart`
// ⇒ 官方安卓端**确实有**这个页面，所以本行不是"可以不做的"。
//
// 判定逻辑抽成**纯函数** [classifyDownloadLink]，便于单测（WebView 本体
// 是平台视图，只能在真机取证）。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/download_station.dart';
import '../../core/i18n/l10n.dart';
import 'download_providers.dart';

/// 可建成下载任务的链接类型。
enum DownloadLinkKind {
  /// `magnet:?xt=…`（BT）
  magnet,

  /// `ed2k://|file|…`（eMule）
  ed2k,

  /// `.torrent` 直链
  torrent,

  /// `.nzb` 直链
  nzb,
}

/// **纯函数**：把 URL 归类成可下载链接；不是下载链接就回 null（= 正常导航）。
///
/// 规则（官方 WebView 的 `onDownloadStart` + 我们既有的 `canonizeUrl` 语义）：
/// * `magnet:` / `ed2k://` 前缀（大小写不敏感）；
/// * 路径以 `.torrent` / `.nzb` 结尾（**忽略 query/hash**）。
DownloadLinkKind? classifyDownloadLink(String url) {
  final u = url.trim();
  if (u.isEmpty) return null;
  final lower = u.toLowerCase();
  if (lower.startsWith('magnet:')) return DownloadLinkKind.magnet;
  if (lower.startsWith('ed2k://')) return DownloadLinkKind.ed2k;
  final path = Uri.tryParse(u)?.path.toLowerCase() ?? lower;
  if (path.endsWith('.torrent')) return DownloadLinkKind.torrent;
  if (path.endsWith('.nzb')) return DownloadLinkKind.nzb;
  return null;
}

/// 输入框按「打开」时的**去向**（纯函数 [planBrowserGo] 的产物，便于单测）。
///
/// * `addKind != null` ⇒ 这是下载链接，交给"添加到下载"（**与页面内点击同一条路**）；
/// * 否则按 [uri] 正常导航（缺 scheme 时补 `https://`）。
class BrowserGoPlan {
  const BrowserGoPlan({required this.uri, this.addKind});

  final String uri;
  final DownloadLinkKind? addKind;
}

/// **纯函数**：输入框里那串字按「打开」之后该去哪。
///
/// ★★ 为什么要有它（r408 真机，DA60 第二形态）：以前 `_go()` 无条件
/// `loadRequest`，于是往输入框里贴 `ed2k://…` / `magnet:…` 会得到
/// WebView 甩给开发者的 `net::ERR_UNKNOWN_URL_SCHEME`，用户拿不到"添加到下载"。
/// 分类函数当时**只在 `onNavigationRequest` 里被调用** ⇒ 同一个页面、同一条链接，
/// "点进去"能用、"贴进去"不能用。现在两条路走同一个判据。
BrowserGoPlan planBrowserGo(String rawTyped) {
  final u = rawTyped.trim();
  final kind = classifyDownloadLink(u);
  if (kind != null) return BrowserGoPlan(uri: u, addKind: kind);
  return BrowserGoPlan(uri: u.contains('://') ? u : 'https://$u');
}

/// 系统返回键通道名（Kotlin 侧 `BrowserBackBridge.CHANNEL` 必须逐字相同；
/// 守卫用例在 `test/download_d6c_test.dart` 里**两侧对读**）。
const String kBrowserBackChannelName = 'synhub/browser_back';

/// 系统返回键（Kotlin 侧 `synhub/browser_back` 转过来）该做的事。
enum BrowserBackAction {
  /// 输入框的键盘开着 ⇒ 先收键盘（安卓惯例：第一次返回只关输入法）。
  dismissKeyboard,

  /// WebView 有历史 ⇒ 回上一页（浏览器语义）。
  goBack,

  /// 没有历史 ⇒ 退出本页（与工具栏 `Back` 一致）。
  popPage,
}

/// **纯函数**：系统返回键的三选一去向（离线用例覆盖全部组合）。
BrowserBackAction planBrowserBack({
  required bool keyboardVisible,
  required bool canGoBack,
}) {
  if (keyboardVisible) return BrowserBackAction.dismissKeyboard;
  return canGoBack ? BrowserBackAction.goBack : BrowserBackAction.popPage;
}

/// 执行一次"系统返回键"（可注入，便于离线给三条腿都写上用例）。
///
/// ★★ 为什么要绕这一圈（**DA62**，r409 真机三组实验）：内置浏览器页只要
/// **WebView 加载过任何一页**，`keyevent 4` 就再也到不了 Flutter ——
/// 既不退页、也不回 WebView 历史，而且**焦点在 Flutter 输入框（E1）还是
/// 网页内容（E2）结果完全一样**（见 `docs/android-ui-audit-r409.md` §S2）。
/// 没有加载网页时返回键是正常的（E4 对照）⇒ 变量是"WebView 有没有内容"，
/// 不是"谁拿着焦点"。
/// 因此修复落在**视图树之上**：`MainActivity.dispatchKeyEvent` 先吃下按键
/// （`BrowserBackBridge`），再回到这里执行 —— 谁拿着焦点都不再影响结果。
class BrowserBackDispatcher {
  BrowserBackDispatcher({
    required this.keyboardVisible,
    required this.canGoBack,
    required this.goBack,
    required this.popPage,
    required this.dismissKeyboard,
  });

  final bool Function() keyboardVisible;
  final Future<bool> Function() canGoBack;
  final Future<void> Function() goBack;
  final Future<void> Function() popPage;
  final VoidCallback dismissKeyboard;

  /// 执行并返回**实际走了哪条腿**（真机与用例都按它判）。
  Future<BrowserBackAction> handle() async {
    if (keyboardVisible()) {
      // 键盘开着这一支**同步可判** ⇒ 短路掉 `canGoBack` 的通道往返
      // （真机上那是一次 MethodChannel 往返，没必要等）。
      // 判据本身仍只由 [planBrowserBack] 一份说了算。
      final action = planBrowserBack(keyboardVisible: true, canGoBack: false);
      dismissKeyboard();
      return action;
    }
    final action = planBrowserBack(
      keyboardVisible: false,
      canGoBack: await canGoBack(),
    );
    switch (action) {
      case BrowserBackAction.dismissKeyboard:
        dismissKeyboard();
      case BrowserBackAction.goBack:
        await goBack();
      case BrowserBackAction.popPage:
        await popPage();
    }
    return action;
  }
}

/// 内置浏览器页：普通网页正常导航；命中下载链接则**拦下并询问**是否建任务。
///
/// 只有 `http(s)` 页面才交给 WebView；`magnet:`/`ed2k:` 这类 WebView 自己
/// 也加载不了，必须拦。
class DownloadBrowserPage extends ConsumerStatefulWidget {
  const DownloadBrowserPage({super.key, this.initialUrl});

  final String? initialUrl;

  @override
  ConsumerState<DownloadBrowserPage> createState() =>
      _DownloadBrowserPageState();
}

class _DownloadBrowserPageState extends ConsumerState<DownloadBrowserPage> {
  /// 系统返回键通道（Kotlin **`BrowserBackBridge`** 的对端）。
  ///
  /// ★ 为什么**不**进 `AppCapability` 表（与 `fold-posture-hinge` 同一手法）：
  /// 本通道要治的是"Android 的 WebView 把返回键吃掉"这个**物理行为**；
  /// 别的宿主上 WebView 平台视图不存在、Flutter/系统的返回路径本来就好
  /// ⇒ 那一档**没有这个缺陷**（定义域外，不是能力缺失）⇒ 只在 Android 上 arm。
  static const MethodChannel backChannel = MethodChannel(
    kBrowserBackChannelName,
  );

  late final WebViewController _controller;
  final _urlText = TextEditingController();
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _armSystemBack();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _loading = true),
          onPageFinished: (u) {
            if (mounted) {
              setState(() {
                _loading = false;
                _urlText.text = u;
              });
            }
          },
          onNavigationRequest: (request) {
            final kind = classifyDownloadLink(request.url);
            if (kind == null) return NavigationDecision.navigate;
            // 命中下载链接：**拦下**（WebView 也加载不了 magnet/ed2k），
            // 询问后交给既有的 `createUrl` 建任务。
            _offerAddTask(request.url, kind);
            return NavigationDecision.prevent;
          },
        ),
      );
    final initial = widget.initialUrl;
    if (initial != null && initial.trim().isNotEmpty) {
      _controller.loadRequest(Uri.parse(initial.trim()));
    }
  }

  @override
  void dispose() {
    // ★ DA62：离开本页**立刻撤防** —— 返回键马上回到系统默认路径，
    // 别的页面/别的时刻行为与改前一字不差（这是本次修复的作用域边界）。
    // gate-exempt: browser-back-key —— 与 arm 同一理由（撤防是它的逆操作）
    backChannel.setMethodCallHandler(null);
    backChannel.invokeMethod<void>('setActive', false).ignore();
    _urlText.dispose();
    super.dispose();
  }

  /// 把"系统返回键"接过来（DA62）。宿主没实现（桌面 / 测试）就静默 ——
  /// 不崩、不报错，那一档本来也没有这个缺陷（只有 Android 的 WebView 会吃键）。
  Future<void> _armSystemBack() async {
    // 非 Android 宿主：一个字都不发（定义域外，见 backChannel 的注释）
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    // gate-exempt: browser-back-key —— Android 视图树物理行为；别的宿主没这个缺陷
    backChannel.setMethodCallHandler((call) async {
      if (call.method != 'onBack') return;
      await _handleSystemBack();
    });
    try {
      await backChannel.invokeMethod<void>('setActive', true);
    } on MissingPluginException {
      // 非 Android 宿主：走 Flutter 自己那套
    } on PlatformException {
      // 同上（宿主实现了但拒绝/出错，也不该让页面挂掉）
    }
  }

  /// 真机按返回键之后真正要做的事（三条腿）—— 判据全在可单测的 [planBrowserBack]。
  Future<void> _handleSystemBack() async {
    if (!mounted) return;
    final dispatcher = BrowserBackDispatcher(
      keyboardVisible: () => MediaQuery.of(context).viewInsets.bottom > 0,
      canGoBack: _controller.canGoBack,
      goBack: _controller.goBack,
      dismissKeyboard: () => FocusManager.instance.primaryFocus?.unfocus(),
      popPage: () async {
        if (!mounted) return;
        await Navigator.of(context, rootNavigator: true).maybePop();
      },
    );
    await dispatcher.handle();
  }

  Future<void> _offerAddTask(String url, DownloadLinkKind kind) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('ds-browser-add-dialog'),
        title: Text(dataText('dsBrowserFound', '发现下载链接')),
        content: Text(url, maxLines: 4, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            key: const Key('ds-browser-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(dataText('dsCancel', '取消')),
          ),
          FilledButton(
            key: const Key('ds-browser-add'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(dataText('dsBrowserAdd', '添加到下载')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(downloadActionsProvider).createUrl(urls: [url]);
      messenger.showSnackBar(
        SnackBar(content: Text(dataText('dsBrowserAdded', '已添加到下载任务'))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(describeDownloadError(e))),
      );
    }
  }

  void _go() {
    final u = _urlText.text.trim();
    if (u.isEmpty) return;
    final plan = planBrowserGo(u);
    final kind = plan.addKind;
    if (kind != null) {
      // 下载链接（`magnet:` / `ed2k://` / `.torrent` / `.nzb`）——
      // WebView 自己加载不了，直接走**同一个**询问弹层（DA60 第二形态）。
      _offerAddTask(plan.uri, kind);
      return;
    }
    _controller.loadRequest(Uri.parse(plan.uri));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return DesignScaffold(
      appBar: AppBar(
        title: Text(dataText('dsBrowserTitle', '下载链接浏览器')),
        leading: IconButton(
          key: const Key('ds-browser-back'),
          tooltip: dataText('dsBack', '返回'),
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context, rootNavigator: true).maybePop(),
        ),
        actions: [
          IconButton(
            key: const Key('ds-browser-reload'),
            tooltip: t.photoRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: () => _controller.reload(),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('ds-browser-url'),
                    controller: _urlText,
                    decoration: InputDecoration(
                      hintText: 'https://example.com',
                      labelText: dataText('dsBrowserUrl', '网址'),
                    ),
                    onSubmitted: (_) => _go(),
                  ),
                ),
                const SizedBox(width: Gap.sm),
                IconButton(
                  key: const Key('ds-browser-go'),
                  tooltip: dataText('dsBrowserGo', '打开'),
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: _go,
                ),
              ],
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: Gap.lg),
              child: LinearProgressIndicator(),
            ),
          Expanded(
            key: const Key('ds-browser-view'),
            child: WebViewWidget(controller: _controller),
          ),
        ],
      ),
    );
  }
}
