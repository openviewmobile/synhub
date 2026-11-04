// Phase 8：通知与后台设置页。
//
// * 前台常驻服务：开/关（关掉就只在 App 前台时收消息）
// * 开机自启（原生 SharedPreferences，`BootReceiver` 用）
// * 发一条测试通知：真机上验证通知权限 + 通知频道 + 动作按钮
//
// 外观：深空座舱 · 开关矩阵（二级页面样板之二）——
//   * 底：`HudScaffold`（透视网格 + 星尘；常驻动效只在 `AppEffects.ambientAllowed`
//     时启动，测试 / "减少动效"下退化成静态图，零帧）；
//   * 分组：`_SectionHead`（`TelemetryLabel` 英文代号 · 中文组名）+ 一框一组；
//   * 面板：`TechFrame` 切角 + 角括号 + 边缘刻度；`blur: 0` —— 列表里**不做**
//     `BackdropFilter`（一屏十几个毛玻璃在中低端机上会掉帧）；
//   * 行：切角图标 + 标题 + **真实**状态副标题 + 右侧开关（整行可点，交互语义
//     等同 `SwitchListTile`），行与行之间用切角分隔线，而不是每行各自上模糊；
//   * 遥测：顶部 `DataStrip` + 底部 `TelemetryRow` 只显示真实字段
//     （前台服务 / conn_id / 实时通道 / 原生后台服务可用性 / 免打扰）。
//
// 语义与逻辑刻意一字未改：所有中文串、`_load()` / `bg.getAutostart()` /
// `bg.start()/stop()` / `NotificationService` / 跳 `SnoozeSettingsPage` 都照旧，
// 真机脚本与 `test/notification_test.dart` 依赖它们。
import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';

import '../../core/platform/app_platform.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../native/background_service.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/tech_frame.dart';
import '../notifications/notification_service.dart';
import '../../data/remote/socket/chat_socket.dart';

import '../chat/chat_session_controller.dart';
import 'snooze_controller.dart';
import 'snooze_settings_page.dart';

/// ★ r711：Windows 的 toast 里没有动作按钮（`MessageNotification` 没有动作字段，
/// WinRT toast XML 里也没有 `<actions>`/`<input>`，可用 `GetHistory` 的原文复核）。
/// 文案因此按平台换一句，并且**抽成可注入函数** —— 宿主机上 `Platform.isWindows`
/// 恒为 false，"按平台换文案"这条判据在 mac/linux 上永远测不到（见 AGENTS §2.0.97⑤）。
String notifSendTestHintText({
  required String generic,
  required String windows,
  required bool isWindows,
}) =>
    isWindows ? windows : generic;

class NotificationSettingsPage extends ConsumerStatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  ConsumerState<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState
    extends ConsumerState<NotificationSettingsPage>
    with WidgetsBindingObserver {
  bool _boot = false;
  bool _foreground = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// ★ r342 D45：从后台回来时**重新问一次系统**「常驻服务还在跑吗」。
  /// 这个值可能被 App 之外的东西改（系统回收/重启服务、用户在系统设置里改放行），
  /// 只在构建时问一次会漏掉这些变化。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(foregroundServiceRunningProvider);
    }
  }

  Future<void> _load() async {
    final bg = ref.read(backgroundServiceProvider);
    final auto = await bg.getAutostart();
    if (!mounted) return;
    setState(() {
      _boot = auto.boot;
      _foreground = auto.foreground;
      _loading = false;
    });
  }

  /// 这个宿主有没有「前台常驻服务」这条桥（只有手机上有；桌面没有）。
  bool get _hasForegroundService =>
      capabilityGateAllows(AppCapability.backgroundExecution);

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(chatSessionControllerProvider);
    final snooze = ref.watch(snoozeControllerProvider);
    final bg = ref.read(backgroundServiceProvider);
    // ★ r342 D45：这个位一律**实时问系统**（唯一来源），不是会话内存里的快照
    final fgs = ref.watch(foregroundServiceRunningProvider).value ?? false;
    final now = DateTime.now();
    final t = context.t;

    return DesignScaffold(
      appBar: AppBar(title: Text(t.setNotifications)),
      body: _loading
          // 加载态用列表骨架（不是空白也不是转圈）：没有内容跳变
          ? const AppListSkeleton(rows: 4)
          : ListView(
              padding: const EdgeInsets.only(bottom: Gap.xxl),
              children: [
                _TelemetryBand(
                  sync: sync,
                  bg: bg,
                  snooze: snooze,
                  fgsRunning: fgs,
                ),

                // ★ r693 DA334：`FOREGROUND` / `BOOT` 两段是**安卓前台服务**的开关
                //   （`synhub/background` 桥）。桌面宿主没有这个桥 ⇒ 两个开关点了
                //   不动＝死控件；标题还把"服务没跑"读成"链路没准备好"，误导。
                //   按能力位 fail-closed：桌面整两段不摆。
                if (_hasForegroundService) ...[
                // ------------------------------------------------ 前台服务
                _SectionHead('FOREGROUND', t.notifForegroundSection),
                _MatrixPanel(
                  child: _MatrixSwitchRow(
                    icon: fgs
                        ? Icons.cloud_done_outlined
                        : Icons.cloud_off_outlined,
                    title: t.notifForegroundService,
                    subtitle: Text(
                      fgs
                          ? t.notifForegroundRunningHint
                          : t.notifForegroundStoppedHint,
                    ),
                    value: fgs,
                    onChanged: (on) async {
                      if (on) {
                        await bg.start();
                      } else {
                        await bg.stop();
                      }
                      // 让状态行立刻反映真实值（重新问一次系统）
                      ref.invalidate(foregroundServiceRunningProvider);
                    },
                  ),
                ),

                // ------------------------------------------------ 开机自启
                // 分组名不能再叫「开机自启」：下面那行也叫这个（设计稿里分组名是类目，不是动作）
                _SectionHead('BOOT', t.notifBootSection),
                _MatrixPanel(
                  child: Column(
                    children: [
                      _MatrixSwitchRow(
                        icon: Icons.restart_alt,
                        title: t.notifBoot,
                        subtitle: Text(t.notifBootHint),
                        value: _boot,
                        onChanged: (on) async {
                          setState(() => _boot = on);
                          await bg.setAutostart(
                            boot: on,
                            foreground: _foreground,
                          );
                        },
                      ),
                      const _MatrixDivider(),
                      _MatrixSwitchRow(
                        icon: Icons.open_in_new,
                        title: t.notifBootOpenApp,
                        subtitle: Text(t.notifBootOpenAppHint),
                        value: _foreground,
                        onChanged: (on) async {
                          setState(() => _foreground = on);
                          await bg.setAutostart(boot: _boot, foreground: on);
                        },
                      ),
                    ],
                  ),
                ),
                ],

                // ------------------------------------------------ 通知自检
                _SectionHead('TEST', t.notifSelfTestSection),
                _MatrixPanel(
                  child: Column(
                    children: [
                      _MatrixTapRow(
                        icon: Icons.notifications_active_outlined,
                        title: t.notifSendTest,
                        subtitle: Text(
                          // ★ r711（W-B9 同族）：Windows 的 toast 里**没有**动作按钮
                          //   —— `MessageNotification` 没有动作字段，WinRT toast 的 XML
                          //   里也没有 <actions>/<input>（实测 GetHistory 的原文可证）。
                          //   所以在这台平台上不许承诺"验证按钮"。
                          notifSendTestHintText(
                            generic: t.notifSendTestHint,
                            windows: t.notifSendTestHintWindows,
                            // 用 defaultTargetPlatform 而不是 Platform.isWindows：
                            // lib 里 io 的 import 数有「只许降」的守卫（web 基线 94）。
                            isWindows: !kIsWeb &&
                                defaultTargetPlatform == TargetPlatform.windows,
                          ),
                        ),
                        onTap: () async {
                          final ok = await bg.show(
                            MessageNotification(
                              channelId: 0,
                              postId: 999999,
                              title: platformAppName(),
                              text: t.notifTestBody,
                            ),
                          );
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                ok ? t.notifTestSent : t.notifTestFailed,
                              ),
                            ),
                          );
                        },
                      ),
                      const _MatrixDivider(),
                      _MatrixTapRow(
                        icon: Icons.notifications_off_outlined,
                        title: t.notifClearAll,
                        onTap: () => bg.cancelAll(),
                      ),
                    ],
                  ),
                ),

                // ------------------------------------------------ 免打扰
                _SectionHead('SNOOZE', t.notifSnooze),
                _MatrixPanel(
                  child: _MatrixTapRow(
                    icon: Icons.notifications_off_outlined,
                    title: t.notifSnooze,
                    subtitle: Text(snooze.subtitleIn(t, now)),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SnoozeSettingsPage(),
                      ),
                    ),
                  ),
                ),

                // ------------------------------------------------ 后台链路
                _SectionHead('LINK', t.notifLinkSection),
                _MatrixPanel(
                  child: _LinkTelemetry(sync: sync, bg: bg, fgsRunning: fgs),
                ),
              ],
            ),
    );
  }
}

// ------------------------------------------------------------------ 分组头

/// 小节头：状态点 + `英文代号 · 中文组名`（`TelemetryLabel` 排字）。
///
/// 无障碍上合并成一个 heading（只念中文组名），英文代号不吵屏幕阅读器。
class _SectionHead extends StatelessWidget {
  const _SectionHead(this.code, this.title);

  /// `code`（FOREGROUND/BOOT…）只是 HUD 时期的英文代号；
  /// 设计稿的分组标题只有中文组名，所以这里不再上屏。
  final String code;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      label: title,
      child: DesignSectionHeader(title),
    );
  }
}

// ------------------------------------------------------------------ 切角面板

/// 一组开关的切角面板壳：`TechFrame` + 统一左右边距 + `blur: 0`。
///
/// 列表里不开模糊（性能），靠切角 / 角括号 / 边缘刻度表达层次。
class _MatrixPanel extends StatelessWidget {
  const _MatrixPanel({required this.child});

  final Widget child;

  /// 设计稿里设置行是**一行一张卡片**，不再需要外层切角面板；
  /// 保留这个类只为让调用点（`_MatrixPanel(child: …)`）不动。
  @override
  Widget build(BuildContext context) => child;
}

// ------------------------------------------------------------------ 开关行

/// 开关矩阵的一行：切角图标 + 标题 + 副标题 + 右侧开关。
///
/// **整行可点**（点标题也能切换），交互语义与原来的 `SwitchListTile` 一致
/// —— 真机脚本与测试都是 `tap(find.text('开机自启'))`。
class _MatrixSwitchRow extends StatelessWidget {
  const _MatrixSwitchRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final Widget subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return DesignSwitchRow(
      secondary: Icon(icon),
      title: Text(title),
      subtitle: subtitle,
      value: value,
      onChanged: onChanged,
    );
  }
}

// ------------------------------------------------------------------ 入口行

/// 进入二级页 / 触发一次性动作的一行：图标 + 标题 + 副标题 + 右箭头。
class _MatrixTapRow extends StatelessWidget {
  const _MatrixTapRow({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final Widget? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DesignRowTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle,
      onTap: onTap,
    );
  }
}

class _MatrixDivider extends StatelessWidget {
  const _MatrixDivider();

  /// 卡片行之间已经有 10 的间隙，不再需要分隔线（留着只为调用点不动）。
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _TelemetryBand extends StatelessWidget {
  const _TelemetryBand({
    required this.fgsRunning,
    required this.sync,
    required this.bg,
    required this.snooze,
  });

  final ChatSyncState sync;
  final BackgroundService bg;
  final SnoozeState snooze;
  final bool fgsRunning;

  @override
  Widget build(BuildContext context) {
    // ★ r508：**这一行原来是 HUD 遥测码**：
    //   `SVC ON · CONN <conn_id> · SOCKET READY · NATIVE READY · DND OFF`。
    //   把 conn_id 直接印在设置页上，等于把诊断串当用户文案（DA142 同一个病），
    //   而且全大写代号在真机上一个字都读不懂。改成**一句人话**：
    //   只回答"链路现在能不能用"，细节留给日志。
    // ★ r693 DA334：桌面没有前台服务这条桥，判「链路好不好」就**只**看 socket ——
    //   否则桌面永远显示"链路没准备好"，而真正的原因是"这台机器上没有那个服务"。
    // ★ r693 DA335：**文案也要跟着判据走**。修完 DA334 之后横幅改用真话，但
    //   `notifLinkOk` 原文是「后台服务在跑，实时通道已连接」—— 桌面上没有那个服务，
    //   于是这一句本身变成**假话**（真机像素 `102_notification_after_fix.png` 抓到的）。
    //   没有前台服务的宿主走 `*ChannelOnly` 两条：只说实时通道，不替系统编服务。
    final hasFgs = capabilityGateAllows(AppCapability.backgroundExecution);
    final ready =
        (!hasFgs || fgsRunning) && sync.socketStatus == ChatSocketStatus.ready;
    final String text;
    if (hasFgs) {
      text = ready ? context.t.notifLinkOk : context.t.notifLinkWarn;
    } else {
      text = ready
          ? context.t.notifLinkOkChannelOnly
          : context.t.notifLinkWarnChannelOnly;
    }
    return DesignNote(text, icon: Icons.sensors_outlined);
  }
}

/// 底部链路遥测：稳定的 `键 ····· 值` 行，值都是真读到的状态。
class _LinkTelemetry extends StatelessWidget {
  const _LinkTelemetry({
    required this.sync,
    required this.bg,
    required this.fgsRunning,
  });

  final ChatSyncState sync;
  final BackgroundService bg;
  final bool fgsRunning;

  @override
  Widget build(BuildContext context) {
    final conn = sync.connId;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Gap.sm + 2,
        vertical: Gap.xs,
      ),
      child: Column(
        children: [
          // ★ r693 DA334：桌面没有前台服务这条桥 ⇒ 这一行**不许**再摆
          //   （否则页面上会出现一个恒为 `STOPPED` 的"前台服务"，用户以为坏了）。
          if (capabilityGateAllows(AppCapability.backgroundExecution))
            TelemetryRow(
              label: context.t.notifForegroundSection,
              value: fgsRunning ? 'RUNNING' : 'STOPPED',
              color: fgsRunning ? DesignPalette.of(context).ok : null,
            ),
          TelemetryRow(
            label: context.t.notifRealtimeChannel,
            value: sync.socketStatus.name,
          ),
          TelemetryRow(
            label: 'conn_id',
            value: (conn == null || conn.isEmpty) ? '--' : conn,
          ),
          TelemetryRow(
            label: context.t.notifNativeService,
            value: bg.isSupported ? 'AVAILABLE' : 'UNAVAILABLE',
          ),
        ],
      ),
    );
  }
}
