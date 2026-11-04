// 连接页（服务器设置）—— "飞船对接序列"（HUD 科幻英雄页）。
//
// 这是 App 的第一印象，也是唯一一个"什么都还没连上"的页面，所以它承担了设定
// 基调的任务：全屏 `FieldBackdrop`（透视网格地平线 + 星尘 + 扫描线）铺底，
// 真机上进入时播一段自检开场（`BootSequence`，点一下可跳过），中央用能量核
// （`EnergyOrb`）充当主行动 —— 待机/握手/在线/故障四态用真实会话状态驱动，
// 不是装饰动画。QuickConnect 与地址输入收进切角科技面板（`TechFrame`），
// 底部一条滚动遥测带（`DataStrip`）只放真拿得到的信息。
//
// 流程一字未动：选中录入方式 → 填值 → 点「连接」→ `SessionController.connect`
// → 成功进登录页；连接日志、失败提示、诊断工具与设计预览入口全部保留。
//
// 动效安全：常驻效果走 `AppEffects.ambientAllowed`；一次性进场光扫只在真机播
// （它和 `BootSequence` 同属开场，且测试里延迟定时器会干扰 pumpAndSettle）。
import '../../design/design_palette.dart';
import '../../core/dev/dev_tools.dart';
import '../../core/i18n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_routes.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/boot_sequence.dart';
import '../../core/ui/energy_orb.dart';
import '../../core/ui/glass_pane.dart';
import '../../core/ui/glass_text_field.dart';
import '../../core/ui/hud_widgets.dart';
import '../../core/ui/tech_frame.dart';
import '../settings/settings_page.dart' show kAppVersion;
import 'connection_service.dart';
import 'nas_manager_page.dart';
import 'server_profile.dart';
import 'session_controller.dart';
import '../chat/chat_deep_link.dart' show chatDeepLinkPrefillProvider;

/// 首页：选择服务器。两种录入方式 —— QuickConnect ID 或直接地址。
class ServerSetupPage extends ConsumerStatefulWidget {
  const ServerSetupPage({super.key});

  @override
  ConsumerState<ServerSetupPage> createState() => _ServerSetupPageState();
}

class _ServerSetupPageState extends ConsumerState<ServerSetupPage> {
  final _controller = TextEditingController();
  ServerAddressKind _kind = ServerAddressKind.quickConnect;
  bool _submitting = false;

  /// 进场光扫只在真机播（见文件头"动效安全"）。
  bool get _entrance => BootSequence.shouldPlay;

  @override
  void initState() {
    super.initState();
    // 底部遥测带要实时反映正在输入的目标地址：输入控制器不通知父级，
    // 这里补一个监听（页面很小，重建代价可以忽略）。
    _controller.addListener(_onTargetChanged);
    // 审计行 262：聊天深链预填服务器地址。
    // 官方 `LoginActivity.fillInData` 的 `mAddressText`：深链里的 `address`
    // 直接填进地址框；`https` 由 `ServerProfile.normalizedBaseUrl` 处理，
    // 与官方 `mHttpsBox` 的语义一致。
    // ⚠️ 深链带 `guest` 是官方行为，但访客登录属审计行 261（未实现、证据不足）
    //    ⇒ 这里**故意不消费 `guest`**，避免半成品访客链路。
    final link = ref.read(chatDeepLinkPrefillProvider);
    if (link != null && link.address.isNotEmpty) {
      _kind = ServerAddressKind.direct;
      _controller.text = link.address;
    }
    // 冷启动第一步：如果本机存过上次登录，静默连上并重登（用户无感）。
    // 结果统一在 build 的 ref.listen 里处理：成功进主页、被拒去登录页、
    // 连不上就留在这一页（地址已预填）。
    ref.read(sessionControllerProvider.notifier).restore();
  }

  void _onTargetChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onTargetChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    setState(() => _submitting = true);

    final profile = ServerProfile(kind: _kind, value: value);
    final ok = await ref
        .read(sessionControllerProvider.notifier)
        .connect(profile);
    if (!mounted) return;
    setState(() => _submitting = false);
    if (ok) context.go(AppRoutes.login);
  }

  /// 输入值推出来的协议（QuickConnect 走 dsm_https，直连默认补 https）——
  /// 只是把 `ServerProfile.normalizedBaseUrl` 的规则在 UI 上说出来，没有新逻辑。
  String get _protocol =>
      _controller.text.trim().toLowerCase().startsWith('http://')
      ? 'HTTP'
      : 'HTTPS';

  /// 顶部状态串：完全按 `sessionControllerProvider` 的实际阶段选，不瞎编状态。
  (String, Color) _link(SessionState s, DesignPalette hud, ColorScheme scheme) {
    if (s.restoring) return ('LINK · RESTORE', scheme.primary);
    if (s.busy) return ('LINK · HANDSHAKE', scheme.primary);
    if (s.connection != null) return ('LINK · ONLINE', hud.ok);
    if (s.error != null) return ('LINK · FAULT', hud.danger);
    return ('LINK · STANDBY', hud.dim);
  }

  @override
  Widget build(BuildContext context) {
    // 静默重登的三种结果，各自有去处（见 AutoLoginResult）
    ref.listen(sessionControllerProvider, (prev, next) {
      if (!mounted) return;
      if (next.loggedIn) {
        // 能走到这里说明是 restore() 静默登进来的（手动登录由登录页跳转）
        context.go(AppRoutes.home);
        return;
      }
      final saved = next.saved;
      if (saved != null && _controller.text.trim().isEmpty) {
        // 预填上次的服务器，用户只需要补密码 / 或直接点连接
        setState(() {
          _kind = saved.profile.kind;
          _controller.text = saved.profile.value;
        });
      }
      if (next.autoLoginFailed) {
        // 服务器认了网络、不认凭据：去登录页（账号已预填）
        context.go(AppRoutes.login);
      }
    });

    final state = ref.watch(sessionControllerProvider);
    final hud = DesignPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (linkText, linkColor) = _link(state, hud, scheme);
    final connected = state.connection != null;
    final failed = state.error != null && !_submitting && !state.restoring;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: BootSequence(
          child: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(
                        Gap.xl,
                        Gap.lg,
                        Gap.xl,
                        Gap.xl,
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 480),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // 顶部状态：点 + 遥测串（状态不只靠颜色）
                            Row(
                              children: [
                                PulseDot(
                                  color: linkColor,
                                  size: 6,
                                  pulsing: false,
                                  semanticLabel: linkText,
                                ),
                                const SizedBox(width: Gap.sm),
                                Expanded(
                                  child: TelemetryLabel(
                                    linkText,
                                    size: 11,
                                    letterSpacing: 1.6,
                                    color: linkColor,
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: Gap.xl),

                            // 中央能量核 = 主行动（原来的「连接」按钮）
                            Center(
                              child: EnergyOrb(
                                size: 134,
                                label: state.restoring
                                    ? context.t.srvRestoring
                                    : context.t.srvConnect,
                                busy: _submitting || state.restoring,
                                color: failed
                                    ? hud.danger
                                    : (connected ? hud.ok : null),
                                onTap: (_submitting || state.restoring)
                                    ? null
                                    : _submit,
                                semanticLabel: state.restoring
                                    ? context.t.srvRestoringSemantics
                                    : context.t.srvConnect,
                                caption: state.restoring
                                    ? 'RESTORE'
                                    : (_submitting
                                          ? 'HANDSHAKE'
                                          : (connected
                                                ? 'LINK ONLINE'
                                                : 'READY')),
                              ),
                            ),

                            const SizedBox(height: Gap.xl),
                            Text(
                              context.t.appName,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            const SizedBox(height: Gap.xs),
                            Text(
                              state.restoring
                                  ? context.t.srvRestoringHint
                                  : (state.saved != null
                                        ? context.t.srvLastAccount(
                                            state.saved!.account,
                                            state.saved!.profile.label,
                                          )
                                        : context.t.srvConnectToNas),
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            // 连不上但有上次登录 → 允许**离线浏览本地缓存**。
                            // 与官方 DS note 一致：没网也能进笔记看上次同步的内容。
                            if (failed &&
                                (state.saved?.account.isNotEmpty ?? false))
                              Padding(
                                padding: const EdgeInsets.only(top: Gap.md),
                                child: TextButton.icon(
                                  onPressed: () => context.go(AppRoutes.home),
                                  icon: const Icon(Icons.cloud_off, size: 16),
                                  label: Text(
                                    context.t.srvOfflineBrowse(
                                      state.saved!.account,
                                    ),
                                  ),
                                ),
                              ),
                            // 多 NAS：本机已保存多个时，这里就是切换器；只有一个时
                            // 只显示"当前是哪个"，入口仍旧通向「管理 NAS」。
                            const SizedBox(height: Gap.md),
                            const NasSwitcherBar(),
                            const SizedBox(height: Gap.lg),

                            // 录入区：切角面板 + 角括号 + 遥测 label；面板里是
                            // 录入方式切换 + 玻璃输入框。
                            TechFrame(
                              label: _kind == ServerAddressKind.quickConnect
                                  ? 'QUICKCONNECT'
                                  : 'ENDPOINT',
                              code: _protocol,
                              sweep: _entrance,
                              padding: const EdgeInsets.fromLTRB(
                                Gap.md,
                                Gap.lg,
                                Gap.md,
                                Gap.sm,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SegmentedButton<ServerAddressKind>(
                                    segments: [
                                      const ButtonSegment(
                                        value: ServerAddressKind.quickConnect,
                                        label: Text('QuickConnect ID'),
                                        icon: Icon(Icons.cloud_outlined),
                                      ),
                                      ButtonSegment(
                                        value: ServerAddressKind.direct,
                                        label: Text(context.t.srvDirectAddress),
                                        icon: const Icon(Icons.lan_outlined),
                                      ),
                                    ],
                                    selected: {_kind},
                                    onSelectionChanged: _submitting
                                        ? null
                                        : (s) =>
                                              setState(() => _kind = s.first),
                                  ),
                                  const SizedBox(height: Gap.lg),
                                  GlassTextField(
                                    controller: _controller,
                                    enabled: !_submitting && !state.restoring,
                                    autocorrect: false,
                                    keyboardType: TextInputType.url,
                                    textInputAction: TextInputAction.go,
                                    onSubmitted: (_) => _submit(),
                                    labelText:
                                        _kind == ServerAddressKind.quickConnect
                                        ? 'QuickConnect ID'
                                        : context.t.srvHostOrAddress,
                                    hintText:
                                        _kind == ServerAddressKind.quickConnect
                                        ? context.t.srvQuickConnectExample
                                        : context.t.srvHostExample,
                                    prefixIcon: const Icon(Icons.dns_outlined),
                                  ),
                                ],
                              ),
                            ),

                            if (state.steps.isNotEmpty) ...[
                              const SizedBox(height: Gap.lg),
                              _StepList(steps: state.steps),
                            ],

                            if (state.error != null) ...[
                              const SizedBox(height: Gap.lg),
                              _ErrorBox(text: state.error!),
                            ],

                            const SizedBox(height: Gap.lg),
                            // 原来的两个次要入口（诊断 / 设计预览）原样保留
                            // 临时/调试入口：release 档一个都不出现（登录前就看得见的
                            // 开发者按钮属于上线红线）。开关见 core/dev/dev_tools.dart。
                            if (kDevTools)
                              Wrap(
                                alignment: WrapAlignment.center,
                                spacing: Gap.md,
                                children: [
                                  TextButton.icon(
                                    onPressed: () =>
                                        context.push(AppRoutes.diagnostics),
                                    icon: const Icon(
                                      Icons.bug_report_outlined,
                                      size: 18,
                                    ),
                                    label: Text(context.t.chatDiagnostics),
                                  ),
                                  TextButton.icon(
                                    onPressed: () =>
                                        context.push(AppRoutes.designPreview),
                                    icon: const Icon(
                                      Icons.auto_awesome_outlined,
                                      size: 18,
                                    ),
                                    label: Text(context.t.srvDesignPreview),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                _strip(context, hud, state),
              ],
            ),
          ),
        ),
    );
  }

  /// 底部滚动遥测带：只放真拿得到的信息（录入方式 / 目标 / 协议 / 步数 / 版本）。
  Widget _strip(BuildContext context, DesignPalette hud, SessionState state) {
    final value = _controller.text.trim();
    final items = <String>[
      'NODE ${_kind == ServerAddressKind.quickConnect ? 'QUICKCONNECT' : 'DIRECT'}',
      'TARGET ${value.isEmpty ? '—' : value}',
      'PROTOCOL $_protocol',
      'STEPS ${state.steps.length}',
      'APP v$kAppVersion',
    ];
    return Container(
      decoration: BoxDecoration(
        color: hud.bg.withValues(alpha: 0.72),
        border: Border(top: BorderSide(color: hud.line, width: 0.8)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
      child: DataStrip(items: items, prefix: 'TELEMETRY'),
    );
  }
}

/// 玻璃输入框：胶囊玻璃面 + 聚焦时的主色描边与外辉光。
///
/// 为什么自己管 `FocusNode` 而不是用 `InputDecoration.focusedBorder`：Material
/// 的聚焦边框只能画那条线，给不了"面板被点亮"的外辉光；自己管还能让描边/填充/
/// 辉光一起过渡。

/// 连接过程的逐行日志（切角面板 + 遥测行）。
class _StepList extends StatelessWidget {
  const _StepList({required this.steps});

  final List<ConnectStep> steps;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hud = DesignPalette.of(context);
    return TechFrame(
      label: 'LINK LOG',
      code: '${steps.length}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final s in steps)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    s.ok ? Icons.check_circle_outline : Icons.error_outline,
                    size: 14,
                    color: s.ok ? hud.ok : scheme.error,
                  ),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(
                      s.text,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GlassPane(
      fill: scheme.errorContainer.withValues(alpha: 0.32),
      padding: const EdgeInsets.all(Gap.md),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.error),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              text,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
        ],
      ),
    );
  }
}
