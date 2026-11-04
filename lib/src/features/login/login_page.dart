// 登录页 —— "身份验证序列"（HUD 科幻英雄页）。
//
// 设计意图：登录是用户和 NAS 建立信任关系的一刻，所以这里不做成一张表单，
// 而做成一次**授权序列**：全屏深空座舱背景（`FieldBackdrop`）打底，真机上进页
// 先播一段自检开场（`BootSequence`），三段凭据各占一个切角科技面板
// （`TechFrame` + 玻璃输入框），最后由中央能量核（`EnergyOrb`）作为提交动作。
//
// 为什么用「身份 / 口令 / 动态码」三段而不是一个表单：三段是递进的，OTP 只有在
// 服务端要求时才会出现（原来的 `_needsOtp` 逻辑一字未动），面板化之后"多出来
// 一段"这件事本身就有反馈。所有中文语义串（账号/密码/一次性验证码/信任此设备…）
// 一律保持原样，只换外观。
//
// 动效安全：常驻效果全部走 `AppEffects.ambientAllowed`（测试与"减少动效"下静止），
// 进场光扫这类一次性动效用有限时长，且和 `BootSequence` 一样只在真机播。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/router/app_routes.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/boot_sequence.dart';
import '../../core/ui/energy_orb.dart';
import '../../core/ui/glass_pane.dart';
import '../../core/ui/glass_text_field.dart';
import '../../core/ui/hud_widgets.dart';
import '../../core/ui/tech_frame.dart';
import '../servers/connection_service.dart';
import '../servers/session_controller.dart';
import '../../data/chat_api.dart';
import '../settings/settings_page.dart' show kAppVersion;
import '../chat/chat_deep_link.dart' show chatDeepLinkPrefillProvider;

/// 登录页：账号 + 密码（+ 需要时出现的一次性验证码）。
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _account = TextEditingController();

  /// ★★★ 访客模式（第 96 轮）—— 对齐官方登录页的 `mGuestBox` 勾选框。
  ///
  /// 官方链路（`SynologyChat 2.11.1-607` smali 逐级取证）：
  /// `LoginActivity.mGuestBox`（勾选框）→ `LoginPresenter.queryGuestAccount(email)`
  /// → `SYNO.SAS.Guest:stat` v1（**只发 `email`**）→ 返回访客 `username`
  /// → `LoginPresenter$1.call(String)` → `LoginMvpView.getUserName(String)`
  /// → `LoginActivity.getUserName` → `link(username)`。
  ///
  /// ⚠️ 官方 `getUserName` 之后走的是它自己的 socket `link()`；
  /// **我方没有"免密建立会话"的等价证据** ⇒ 本页只做到
  /// **查到访客账号并填入账号框**，**不臆造免密登录**。
  bool _guestMode = false;
  bool _guestQuerying = false;
  String? _guestName;
  String? _guestError;
  final _password = TextEditingController();
  final _otp = TextEditingController();

  bool _obscure = true;
  bool _remember = false;
  bool _submitting = false;

  /// 上一次登录是否因为需要 OTP 而失败 —— 决定要不要显示验证码输入框。
  bool _needsOtp = false;

  /// 进场光扫只在真机播：它和 `BootSequence` 同属"开场"，而且 `ScanSweep` 的
  /// 延迟定时器在 widget 测试里会留到测试结束（pumpAndSettle 不会等它）。
  bool get _entrance => BootSequence.shouldPlay;

  @override
  void initState() {
    super.initState();
    // 审计行 262：聊天深链预填账号（官方 `fillInData` 的 `mAccountText`）。
    // 深链里的 `account` **优先于**"上次登录的账号"。
    final dlLink = ref.read(chatDeepLinkPrefillProvider);
    if (dlLink != null && dlLink.account.isNotEmpty) {
      _account.text = dlLink.account;
    }
    // 预填上次的账号 / 信任开关：自动重登失败（密码改了、要验证码）落在这里时，
    // 用户只需要补密码，不用再想"上次用的哪个账号"。
    final saved = ref.read(sessionControllerProvider).saved;
    if (saved != null) {
      _account.text = saved.account;
      _remember = saved.rememberDevice;
    }
  }

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    _otp.dispose();
    super.dispose();
  }

  /// ★★★ DA56（r404）：进这一页时**可能还没有连上服务器**，先把连接补上。
  ///
  /// 登录页有一条"未绑定"的入口：多 NAS 下点切换器里的另一条
  /// （`SessionController.switchTo`）—— 本机没有可用凭据时它**只卸连接**、
  /// 把用户带到这一页补密码。此前这一页的「登录」会直接撞上
  /// `login() → state.connection == null → srvNotConnected`：
  /// **账号密码都填好了，按钮却永远报"尚未连接服务器"**（真机可复现，两次同读）。
  ///
  /// 这里用 `state.saved` 的地址把连接补上；失败时 `connect()` 自己会把错误
  /// 写进 `state.error`，页面照常显示，**不吞入口**（照 §2.0.8 第②条）。
  Future<bool> _ensureConnected() async {
    final notifier = ref.read(sessionControllerProvider.notifier);
    if (ref.read(sessionControllerProvider).connection != null) return true;
    final saved = ref.read(sessionControllerProvider).saved;
    if (saved == null) return false;
    return notifier.connect(saved.profile);
  }

  /// 访客模式下点"继续"：查该邮箱对应的访客账号名。
  Future<void> _queryGuest() async {
    final email = _account.text.trim();
    if (email.isEmpty) return;
    setState(() {
      _guestQuerying = true;
      _guestName = null;
      _guestError = null;
    });
    // 访客查询走同一条 `ChatApi`，没有连接同样只能报 `setNotConnected`
    // （DA56 的访客分支）。
    if (!await _ensureConnected()) {
      if (!mounted) return;
      setState(() {
        _guestQuerying = false;
        _guestError = context.t.setNotConnected;
      });
      return;
    }
    final conn = ref.read(sessionControllerProvider).connection;
    final api = conn?.api;
    if (api == null) {
      setState(() {
        _guestQuerying = false;
        _guestError = context.t.setNotConnected;
      });
      return;
    }
    try {
      final g = await ChatApi(api).queryGuestAccount(email);
      if (!mounted) return;
      setState(() {
        _guestQuerying = false;
        if (g == null) {
          _guestError = context.t.loginGuestNotFound;
        } else {
          _guestName = g.username;
          // 对齐官方 `getUserName`：把访客名填进账号框
          _account.text = g.username;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _guestQuerying = false;
        // ★ 如实报错：未认证（119）时说"未找到访客账号"是**误导**。
        //   实测：我方当前 Mock 语义下未登录一定回 119
        //   （`mock_dsm_core.dart:57` 把缺失的 authLevel 默认成 1）。
        _guestError = '$e'.contains('119')
            ? context.t.loginGuestHint
            : context.t.loginGuestNotFound;
      });
    }
  }

  Future<void> _submit() async {
    if (_guestMode) {
      await _queryGuest();
      return;
    }
    final account = _account.text.trim();
    final password = _password.text;
    if (account.isEmpty || password.isEmpty) return;

    setState(() => _submitting = true);
    final notifier = ref.read(sessionControllerProvider.notifier);
    // DA56：未绑定服务器就先把它连上（否则下面的 login 必然报"尚未连接"）。
    // 只有"有记录却连不上"才提前收手 —— 那种情况 `connect()` 已经把原因
    // 写进 `state.error`；**一条记录都没有**时照旧往下走，保住原来那句
    // `srvNotConnected` 提示（不静默吞掉）。
    final bound = await _ensureConnected();
    if (!bound && ref.read(sessionControllerProvider).saved != null) {
      if (!mounted) return;
      setState(() => _submitting = false);
      return;
    }
    final otpText = _otp.text.trim();
    final ok = await notifier.login(
      account: account,
      password: password,
      otp: otpText.isEmpty ? null : otpText,
      rememberDevice: _remember,
    );

    if (!mounted) return;
    setState(() {
      _submitting = false;
      // 失败原因在 state.error 里；要 OTP 是**与语言无关**的布尔判据
      _needsOtp = ref.read(sessionControllerProvider).otpRequired;
    });

    if (ok) {
      context.go(AppRoutes.home);
    } else if (_needsOtp) {
      // 提示用户填验证码，而不是只丢一句错误
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sessionControllerProvider);
    final conn = state.connection;
    final hud = DesignPalette.of(context);

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
                            _topBar(context, conn?.profile.label),

                            if (conn != null) ...[
                              const SizedBox(height: Gap.lg),
                              _ServerFrame(conn: conn),
                            ],

                            const SizedBox(height: Gap.lg),
                            TechFrame(
                              label: 'IDENTITY',
                              code: 'STEP 01',
                              sweep: _entrance,
                              padding: const EdgeInsets.fromLTRB(
                                Gap.md,
                                Gap.lg,
                                Gap.md,
                                Gap.sm,
                              ),
                              child: GlassTextField(
                                controller: _account,
                                enabled: !_submitting,
                                autocorrect: false,
                                textInputAction: TextInputAction.next,
                                labelText: context.t.meAccount,
                                prefixIcon: const Icon(Icons.person_outline),
                              ),
                            ),

                            const SizedBox(height: Gap.lg),
                            TechFrame(
                              label: 'PASSPHRASE',
                              code: 'STEP 02',
                              sweep: _entrance,
                              padding: const EdgeInsets.fromLTRB(
                                Gap.md,
                                Gap.lg,
                                Gap.md,
                                Gap.sm,
                              ),
                              child: GlassTextField(
                                controller: _password,
                                enabled: !_submitting,
                                obscureText: _obscure,
                                textInputAction: _needsOtp
                                    ? TextInputAction.next
                                    : TextInputAction.go,
                                onSubmitted: _needsOtp
                                    ? null
                                    : (_) => _submit(),
                                labelText: context.t.contactPassword,
                                prefixIcon: const Icon(Icons.lock_outline),
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _obscure
                                        ? Icons.visibility_off
                                        : Icons.visibility,
                                  ),
                                  onPressed: () =>
                                      setState(() => _obscure = !_obscure),
                                ),
                              ),
                            ),

                            const SizedBox(height: Gap.md),
                            // ★★★ 访客模式开关 —— 对齐官方 `mGuestBox`。
                            //
                            // ⚠️ 刻意**不用 `CheckboxListTile`**：本页没有 `Material`
                            // 祖先（是自定义 HUD 背景），ListTile 会抛
                            // "ink splashes may be invisible" 布局异常，
                            // `ui_overflow_audit_test` 会把它算作布局缺陷（第 96 轮实测）。
                            Row(
                              key: const Key('login-guest-toggle'),
                              children: [
                                SizedBox(
                                  width: 32,
                                  height: 32,
                                  child: Checkbox(
                                    value: _guestMode,
                                    onChanged: _submitting
                                        ? null
                                        : (v) => setState(() {
                                            _guestMode = v ?? false;
                                            _guestName = null;
                                            _guestError = null;
                                          }),
                                  ),
                                ),
                                const SizedBox(width: Gap.sm),
                                Expanded(
                                  child: GestureDetector(
                                    onTap: _submitting
                                        ? null
                                        : () => setState(() {
                                            _guestMode = !_guestMode;
                                            _guestName = null;
                                            _guestError = null;
                                          }),
                                    child: Text(
                                      context.t.loginGuestMode,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (_guestMode) ...[
                              if (_guestQuerying)
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 8),
                                  child: LinearProgressIndicator(),
                                ),
                              if (_guestName != null)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: Text(
                                    context.t.loginGuestFound(_guestName!),
                                    key: const Key('login-guest-result'),
                                  ),
                                ),
                              if (_guestError != null)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: Text(
                                    _guestError!,
                                    key: const Key('login-guest-error'),
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    ),
                                  ),
                                ),
                            ],

                            if (_needsOtp) ...[
                              const SizedBox(height: Gap.lg),
                              TechFrame(
                                label: 'OTP',
                                code: 'STEP 03',
                                sweep: _entrance,
                                padding: const EdgeInsets.fromLTRB(
                                  Gap.md,
                                  Gap.lg,
                                  Gap.md,
                                  Gap.sm,
                                ),
                                child: GlassTextField(
                                  controller: _otp,
                                  enabled: !_submitting,
                                  keyboardType: TextInputType.number,
                                  textInputAction: TextInputAction.go,
                                  onSubmitted: (_) => _submit(),
                                  labelText: context.t.loginOtpLabel,
                                  helperText: context.t.loginOtpHint,
                                  prefixIcon: const Icon(Icons.pin_outlined),
                                ),
                              ),
                            ],

                            const SizedBox(height: Gap.md),
                            _trustToggle(context),

                            const SizedBox(height: Gap.lg),
                            Center(
                              child: EnergyOrb(
                                size: 128,
                                label: context.t.loginAction,
                                busy: _submitting,
                                // 失败后核体转 warning 色：状态不只靠文案，颜色/形状双编码
                                color: state.error != null && !_submitting
                                    ? hud.danger
                                    : null,
                                onTap: _submitting ? null : _submit,
                                semanticLabel: context.t.loginAction,
                                caption: _submitting
                                    ? 'AUTHENTICATING'
                                    : 'SIGN IN',
                              ),
                            ),

                            if (state.error != null) ...[
                              const SizedBox(height: Gap.lg),
                              _ErrorBox(text: state.error!),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                _strip(context, hud, conn),
              ],
            ),
          ),
        ),
    );
  }

  /// 顶部一行遥测：返回 + `AUTH · 服务器标签`。
  ///
  /// 原来这里是 AppBar 的 `Text('登录')`；按钮文字「登录」现在落在能量核上，
  /// 语义串没有丢，页面反而更像"序列"而不是"表单"。
  Widget _topBar(BuildContext context, String? serverLabel) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _submitting ? null : () => context.go(AppRoutes.setup),
        ),
        const SizedBox(width: Gap.xs),
        Expanded(
          child: TelemetryLabel(
            'AUTH · ${serverLabel ?? 'UNBOUND'}',
            size: 11,
            letterSpacing: 1.4,
            color: scheme.primary,
          ),
        ),
      ],
    );
  }

  /// 信任设备：原来是 `CheckboxListTile`，这里换成一个玻璃行，
  /// 中文串（信任此设备 / 下次登录免验证码）保持原样。
  Widget _trustToggle(BuildContext context) {
    return GlassPane(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
      child: Row(
        children: [
          Checkbox(
            value: _remember,
            onChanged: _submitting
                ? null
                : (v) => setState(() => _remember = v ?? false),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.t.loginTrustDevice,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                // ★ r533（DA170）：这是**整句提示**，1 行会被省略号截半句
                // （DA169 同族）⇒ 允许 2 行。
                TelemetryLabel(
                  context.t.loginTrustDeviceHint,
                  size: 10.5,
                  maxLines: 2,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 底部遥测带：只放**真的拿得到**的信息（地址 / 来源 / 协议 / 证书 / 版本）。
  Widget _strip(BuildContext context, DesignPalette hud, DsmConnection? conn) {
    final items = conn == null
        ? <String>['UPLINK · NONE', 'APP v$kAppVersion']
        : <String>[
            'HOST ${conn.endpoint.baseUrl}',
            'SOURCE ${conn.endpoint.source}',
            'PROTOCOL ${conn.endpoint.baseUrl.startsWith('http://') ? 'HTTP' : 'HTTPS'}',
            'CERT ${conn.certPinned ? 'PINNED' : 'CA-VERIFIED'}',
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

/// 已连接服务器摘要：原来是 `Card` + `ListTile`，现在是一个切角遥测面板，
/// host / 来源 / 协议 / 证书四项信息一个不漏（`TelemetryRow` 的点线引导）。
class _ServerFrame extends StatelessWidget {
  const _ServerFrame({required this.conn});

  final DsmConnection conn;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final protocol = conn.endpoint.baseUrl.startsWith('http://')
        ? 'HTTP'
        : 'HTTPS';
    return TechFrame(
      label: 'UPLINK',
      code: protocol,
      statusDot: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TelemetryRow(label: 'SERVER', value: conn.profile.label),
          TelemetryRow(label: 'HOST', value: conn.endpoint.baseUrl),
          TelemetryRow(label: 'SOURCE', value: conn.endpoint.source),
          TelemetryRow(
            label: 'CERT',
            value: conn.certPinned ? 'PINNED' : 'CA VERIFIED',
            color: conn.certPinned ? hud.danger : hud.ok,
          ),
        ],
      ),
    );
  }
}

/// 玻璃输入框：胶囊玻璃面 + 聚焦时的主色描边与外辉光。
///
/// 为什么自己管 `FocusNode` 而不是用 `InputDecoration.focusedBorder`：Material
/// 的聚焦边框只能画那条线，给不了我们要的"面板被点亮"的外辉光；自己管还能让
/// 描边/填充/辉光一起做 240ms 过渡。

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
