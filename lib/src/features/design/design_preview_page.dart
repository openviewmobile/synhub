import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/device/device_profile.dart';
import '../../core/settings/app_settings.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_routes.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/ui/app_sheet.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/boot_sequence.dart';
import '../../core/ui/energy_orb.dart';
import '../../core/ui/glass_pane.dart';
import '../../core/ui/hud_widgets.dart';
import '../../core/ui/orb_button.dart';
import '../../core/ui/tech_frame.dart';
import '../../core/ui/viewport_bound.dart';

/// 设计预览画廊（**临时页面**）。
///
/// 用途：在真机上直接看 HUD 设计语言的每个积木，亮/暗 + 动态取色一键切换。
/// 等各页面改造完成后这个页面可以删掉（或作为开发者入口保留在诊断页）。
class DesignPreviewPage extends ConsumerStatefulWidget {
  const DesignPreviewPage({super.key});

  @override
  ConsumerState<DesignPreviewPage> createState() => _DesignPreviewPageState();
}

class _DesignPreviewPageState extends ConsumerState<DesignPreviewPage> {
  /// 预览用：null = 跟随应用主题
  Brightness? _forced;

  /// 画廊里"启动自检"是一次性的，点按钮重播
  bool _boot = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = _forced ?? scheme.brightness;
    // 预览里直接构造一套主题，方便原地切亮/暗
    final previewTheme = brightness == Brightness.light
        ? AppTheme.light(
            dynamic: scheme.brightness == Brightness.light ? scheme : null,
          )
        : AppTheme.dark(
            dynamic: scheme.brightness == Brightness.dark ? scheme : null,
          );

    return Theme(
      data: previewTheme,
      child: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: Text(
              context.t.dpTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              // 三段模式开关在英文 + 大字号下比 AppBar 的可用宽度还宽，
              // 会顶爆 AppBar 内部的 Row（实测 71px）→ 收进 `Flexible`，
              // 段内标签自带省略号。
              Flexible(
                child: _ModeSwitch(
                  forced: _forced,
                  onChange: (b) => setState(() => _forced = b),
                ),
              ),
              IconButton(
                tooltip: 'Design gallery',
                icon: const Icon(Icons.photo_library_outlined),
                onPressed: () =>
                    context.pushNamed(AppRoutes.designGalleryName),
              ),
              const SizedBox(width: Gap.sm),
            ],
          ),
          body: Stack(
            children: [
              const Positioned.fill(
                child: SizedBox.expand(),
              ),
              ListView(
                padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 120),
                children: [
                  _section(context, context.t.dpSecSwitches),
                  _switches(context),
                  _section(context, context.t.dpSecScifi),
                  _sciFi(context),
                  _section(context, context.t.dpSecPalette),
                  _palette(context),
                  _section(context, context.t.dpSecBubbles),
                  _bubbles(context),
                  _section(context, context.t.dpSecChips),
                  _chips(context),
                  _section(context, context.t.dpSecComposer),
                  _composer(context),
                  _section(context, context.t.dpSecRows),
                  _rows(context),
                  _section(context, context.t.dpSecIdentity),
                  _identity(context),
                  _section(context, context.t.dpSecOrbs),
                  _orbs(context),
                  _section(context, context.t.dpSecStates),
                  _states(context),
                  _section(context, context.t.dpSecSheet),
                  _sheetDemo(context),
                ],
              ),
            ],
          ),
          floatingActionButton: OrbButton(
            icon: Icons.hub_outlined,
            tooltip: context.t.dpCommandTooltip,
            size: 56,
            onPressed: () => AppSnack.show(context, context.t.dpCommandSnack),
          ),
        ),
      ),
    );
  }

  /// 全局开关：动态取色 / 性能模式（关毛玻璃）/ 减少动效 / 网格底纹。
  ///
  /// 后三个是**三态**：`null` = 跟随设备性能自动，手动拨过就有覆盖值，
  /// 长按（或点「AUTO」）恢复自动。
  Widget _switches(BuildContext context) {
    final dynamic = ref.watch(dynamicColorProvider);
    final profile = ref.watch(deviceProfileProvider);
    final perf = ref.watch(perfModeProvider);
    final motion = ref.watch(reducedMotionProvider);
    final grid = ref.watch(chatGridProvider);
    final perfOv = ref.watch(effectOverrideProvider(EffectKind.perfMode));
    final motionOv = ref.watch(
      effectOverrideProvider(EffectKind.reducedMotion),
    );
    final gridOv = ref.watch(effectOverrideProvider(EffectKind.chatGrid));
    Widget sw(String label, String hint, bool value, ValueChanged<bool> on) =>
        SwitchListTile(
          value: value,
          onChanged: on,
          contentPadding: const EdgeInsets.symmetric(horizontal: Gap.sm),
          title: Text(label, style: Theme.of(context).textTheme.bodyLarge),
          subtitle: TelemetryLabel(hint, size: 10.5, letterSpacing: 0.2),
        );
    Widget auto(String label, EffectKind kind, bool? override, String hint) =>
        Row(
          children: [
            Expanded(child: TelemetryLabel('$label · $hint', size: 10)),
            if (override != null)
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
                  minimumSize: const Size(0, 30),
                  textStyle: Theme.of(context).textTheme.labelSmall,
                ),
                onPressed: () =>
                    ref.read(effectOverrideProvider(kind).notifier).set(null),
                child: Text(context.t.setRestoreAuto),
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: Gap.xs),
                child: TelemetryLabel(
                  'AUTO',
                  size: 10,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
          ],
        );
    return GlassPane(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Column(
        children: [
          sw(
            context.t.dpDynamicColor,
            context.t.dpDynamicColorHint,
            dynamic,
            (v) => ref.read(dynamicColorProvider.notifier).set(v),
          ),
          TelemetryLabel(
            context.t.dpDeviceTier(
              profile.tierLabelIn(context.t).toUpperCase(),
              profile.specLabelIn(context.t),
            ),
            size: 10,
            color: Theme.of(context).colorScheme.primary,
          ),
          sw(
            context.t.setPerfMode,
            context.t.dpPerfModeHint,
            perf,
            (v) => ref
                .read(effectOverrideProvider(EffectKind.perfMode).notifier)
                .set(v),
          ),
          auto(
            'perfMode',
            EffectKind.perfMode,
            perfOv,
            profile.preferBlur
                ? context.t.dpPerfDefaultOffHigh
                : context.t.dpPerfDefaultOnLow,
          ),
          sw(
            context.t.setReducedMotion,
            context.t.dpReducedMotionHint,
            motion,
            (v) => ref
                .read(effectOverrideProvider(EffectKind.reducedMotion).notifier)
                .set(v),
          ),
          auto(
            'reducedMotion',
            EffectKind.reducedMotion,
            motionOv,
            profile.preferReducedMotion
                ? context.t.dpMotionDefaultOnEntry
                : context.t.dpMotionDefaultOff,
          ),
          sw(
            context.t.dpChatGrid,
            context.t.dpChatGridHint,
            grid,
            (v) => ref
                .read(effectOverrideProvider(EffectKind.chatGrid).notifier)
                .set(v),
          ),
          auto(
            'chatGrid',
            EffectKind.chatGrid,
            gridOv,
            profile.preferChatGrid
                ? context.t.dpGridDefaultOn
                : context.t.dpGridDefaultOffEntry,
          ),
        ],
      ),
    );
  }

  /// 科幻层展示：能量核 / 科技边框 / 数据带 / 启动自检
  Widget _sciFi(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hud = HudTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 能量核三态：待机 / 连接中（带进度）/ 失败
        GlassPane(
          padding: const EdgeInsets.symmetric(vertical: Gap.lg),
          child: Column(
            children: [
              Wrap(
                alignment: WrapAlignment.center,
                spacing: Gap.xl,
                runSpacing: Gap.lg,
                children: [
                  EnergyOrb(
                    size: 108,
                    icon: Icons.power_settings_new,
                    caption: 'STANDBY',
                    semanticLabel: context.t.dpConnectSemantics,
                    onTap: () =>
                        AppSnack.show(context, context.t.dpEnergySnack),
                  ),
                  EnergyOrb(
                    size: 108,
                    label: context.t.srvConnect,
                    caption: 'HANDSHAKE 42%',
                    progress: 0.42,
                    busy: true,
                    onTap: () {},
                  ),
                  EnergyOrb(
                    size: 108,
                    icon: Icons.priority_high,
                    caption: 'LINK FAILED',
                    color: hud.warning,
                  ),
                ],
              ),
              const SizedBox(height: Gap.md),
              TelemetryLabel(context.t.dpEnergyOrbCaption, size: 10),
            ],
          ),
        ),
        const SizedBox(height: Gap.md),
        // 科技边框（角括号 + 刻度 + 遥测行 + 光扫）
        TechFrame(
          label: 'ENDPOINT',
          code: '0x1F · SRM 1.3',
          statusDot: true,
          sweep: true,
          glow: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: const [
              TelemetryRow(label: 'HOST', value: 'nas.example.com:5001'),
              TelemetryRow(label: 'QUICKCONNECT', value: 'demo_admin-qq'),
              TelemetryRow(label: 'CRYPTO', value: 'AES-256 / E2EE'),
              TelemetryRow(label: 'LATENCY', value: '18 ms', dense: true),
            ],
          ),
        ),
        const SizedBox(height: Gap.md),
        // 数据带（常驻滚动只在真机 + 允许动效时动）
        TechFrame(
          label: 'TELEMETRY STREAM',
          ticks: false,
          padding: const EdgeInsets.symmetric(
            horizontal: Gap.md,
            vertical: Gap.sm,
          ),
          child: DataStrip(
            prefix: 'LINK',
            items: [
              'nas.example.com:5001',
              'SRM 1.3',
              'AES-256',
              'SOCKET READY',
              '${scheme.brightness.name.toUpperCase()} THEME',
            ],
          ),
        ),
        const SizedBox(height: Gap.md),
        // 深空背景 + 启动自检（点了才播，免得进画廊就被盖住）
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.pane),
          child: SizedBox(
            height: 210,
            child: BootSequence(
              enabled: _boot,
              child: Center(
                  child: TextButton.icon(
                    onPressed: () => setState(() => _boot = true),
                    icon: const Icon(Icons.restart_alt, size: 16),
                    label: Text(context.t.dpReplayBoot),
                  ),
                ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _section(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.xl, Gap.xs, Gap.md),
    child: Row(
      children: [
        Container(
          width: 4,
          height: 14,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: Gap.sm),
        // 章节标题是可变长度文案（英文普遍更长）。`Row` 给非 flex 子项的是
        // **无界**宽度，长标题会直接把这一行撑出屏幕（实测溢出最多 565px）
        // → 给它 `Expanded`（有界、自动折行）。
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
      ],
    ),
  );

  // ------------------------------------------------------------------ 调色板

  Widget _palette(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final hud = HudTokens.of(context);
    final swatches = <String, Color>{
      'primary': s.primary,
      'primaryContainer': s.primaryContainer,
      'secondary': s.secondary,
      'tertiary': s.tertiary,
      'surface': s.surface,
      'surfaceContainerHigh': s.surfaceContainerHigh,
      'online': hud.online,
      'warning': hud.warning,
      'error': s.error,
      'star': hud.star,
    };
    return GlassPane(
      padding: const EdgeInsets.all(Gap.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Gap.sm,
            runSpacing: Gap.sm,
            children: [
              for (final e in swatches.entries)
                Column(
                  children: [
                    Container(
                      width: 52,
                      height: 40,
                      decoration: BoxDecoration(
                        color: e.value,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: s.outlineVariant.withValues(alpha: 0.5),
                          width: 0.6,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      width: 56,
                      child: TelemetryLabel(e.key, size: 9.5, letterSpacing: 0),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: Gap.md),
          TelemetryLabel(context.t.dpMaterialYouCaption),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------- 气泡

  Widget _bubbles(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 对方连续三条：合并圆角
        _demoBubble(
          context,
          text: context.t.dpBubble1,
          mine: false,
          name: 'demo_user',
          time: '21:04',
          first: true,
          last: false,
        ),
        _demoBubble(
          context,
          text: context.t.dpBubble2,
          mine: false,
          time: '21:04',
          first: false,
          last: false,
        ),
        _demoBubble(
          context,
          text: context.t.dpBubble3,
          mine: false,
          time: '21:05',
          first: false,
          last: true,
        ),
        const SizedBox(height: Gap.md),
        _demoBubble(
          context,
          text: context.t.dpBubble4,
          mine: true,
          time: '21:06',
          last: true,
          state: _BubbleState.sent,
        ),
        _demoBubble(
          context,
          text: context.t.dpBubble5,
          mine: true,
          time: '21:06',
          last: true,
          state: _BubbleState.sending,
        ),
        _demoBubble(
          context,
          text: context.t.dpBubble6,
          mine: true,
          time: '21:07',
          last: true,
          state: _BubbleState.failed,
        ),
        const SizedBox(height: Gap.md),
        // 回应 + 引用
        _demoBubble(
          context,
          text: context.t.dpBubble7,
          mine: false,
          time: '21:08',
          last: true,
          reactions: const ['👍 2', '🔥 1'],
          myReaction: '👍',
          quoted: ('demo_user', context.t.dpBubbleQuoted),
        ),
      ],
    );
  }

  Widget _demoBubble(
    BuildContext context, {
    required String text,
    required bool mine,
    String? name,
    required String time,
    bool first = false,
    bool last = true,
    _BubbleState state = _BubbleState.sent,
    List<String> reactions = const [],
    String? myReaction,
    (String, String)? quoted,
  }) {
    final s = Theme.of(context).colorScheme;
    final hud = HudTokens.of(context);
    final outer = Radius.circular(Radii.bubble);
    final inner = Radius.circular(Radii.bubbleInner);
    // reverse 列表里"更旧"在下：组首 = 上方，组尾 = 下方
    final radius = BorderRadius.only(
      topLeft: first ? outer : (mine ? outer : inner),
      topRight: first ? outer : (mine ? inner : outer),
      bottomLeft: last ? outer : (mine ? outer : inner),
      bottomRight: last ? outer : (mine ? inner : outer),
    );
    return Padding(
      padding: EdgeInsets.only(
        top: first ? Gap.md : Gap.xxs,
        bottom: last ? 0 : 0,
      ),
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!mine)
            SizedBox(
              width: Gap.xxl + Gap.sm,
              child: last
                  ? RingAvatar(
                      label: 'K',
                      size: 32,
                      semanticLabel: context.t.dpAvatarSemantics('demo_user'),
                    )
                  : null,
            ),
          Flexible(
            child: Column(
              crossAxisAlignment: mine
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                if (name != null && first)
                  Padding(
                    padding: const EdgeInsets.only(left: Gap.md, bottom: 2),
                    child: Text(
                      name,
                      style: Theme.of(
                        context,
                      ).textTheme.labelLarge?.copyWith(color: hud.meta),
                    ),
                  ),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    // P2-7：0.78 是经验系数，加安全上下界（见 viewport_bound.dart）
                    maxWidth: boundedViewportWidth(
                      MediaQuery.sizeOf(context).width,
                      0.78,
                    ),
                  ),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(
                      Gap.md,
                      Gap.sm + 1,
                      Gap.md,
                      Gap.sm,
                    ),
                    decoration: BoxDecoration(
                      color: mine ? hud.bubbleMine : hud.bubbleOther,
                      borderRadius: radius,
                      border: Border.all(
                        color: mine
                            ? Colors.white.withValues(alpha: 0.14)
                            : hud.edge.withValues(alpha: 0.5),
                        width: 0.7,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (quoted != null)
                          Container(
                            margin: const EdgeInsets.only(bottom: Gap.sm),
                            padding: const EdgeInsets.fromLTRB(
                              Gap.sm,
                              Gap.xs + 1,
                              Gap.sm,
                              Gap.xs + 1,
                            ),
                            decoration: BoxDecoration(
                              color: (mine ? s.onPrimary : s.primary)
                                  .withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(8),
                              border: Border(
                                left: BorderSide(
                                  color: mine ? s.onPrimary : s.primary,
                                  width: 2.4,
                                ),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  quoted.$1,
                                  style: AppType.telemetry(
                                    color: mine ? s.onPrimary : s.primary,
                                    size: 11,
                                  ),
                                ),
                                Text(
                                  quoted.$2,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: mine
                                            ? hud.bubbleMineText.withValues(
                                                alpha: 0.85,
                                              )
                                            : hud.meta,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        Text(
                          text,
                          style: AppType.chatBody.copyWith(
                            color: mine
                                ? hud.bubbleMineText
                                : hud.bubbleOtherText,
                          ),
                        ),
                        const SizedBox(height: Gap.xs),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TelemetryLabel(
                              time,
                              size: 10.5,
                              letterSpacing: 0.4,
                              color: (mine ? hud.bubbleMineText : hud.meta)
                                  .withValues(alpha: 0.8),
                            ),
                            if (state == _BubbleState.sending) ...[
                              const SizedBox(width: Gap.xs + 1),
                              ScanRing(
                                size: 12,
                                semanticLabel: context.t.chatSending,
                              ),
                            ],
                            if (state == _BubbleState.failed) ...[
                              const SizedBox(width: Gap.xs + 1),
                              Icon(
                                Icons.error_outline,
                                size: 14,
                                color: s.error,
                              ),
                            ],
                            if (mine && state == _BubbleState.sent) ...[
                              const SizedBox(width: Gap.xs + 1),
                              Icon(
                                Icons.done_all,
                                size: 14,
                                color: hud.bubbleMineText.withValues(
                                  alpha: 0.75,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                if (state == _BubbleState.failed)
                  Padding(
                    padding: const EdgeInsets.only(top: Gap.xs, right: Gap.xs),
                    child: InkWell(
                      onTap: () =>
                          AppSnack.show(context, context.t.dpResendHint),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.refresh, size: 13, color: s.error),
                          const SizedBox(width: 3),
                          Text(
                            context.t.chatSendFailedRetry,
                            style: AppType.telemetry(color: s.error, size: 11),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (reactions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: Gap.xs + 1),
                    child: Wrap(
                      spacing: Gap.xs,
                      children: [
                        for (final r in reactions)
                          GlassTap(
                            radius: 14,
                            fill: r.contains(myReaction ?? '#')
                                ? s.primary.withValues(alpha: 0.18)
                                : s.surfaceContainerHighest.withValues(
                                    alpha: 0.7,
                                  ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: Gap.sm,
                              vertical: 3,
                            ),
                            onTap: () => AppSnack.show(
                              context,
                              context.t.dpSwitchReaction(r),
                            ),
                            child: Text(
                              r.split(' ').first,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------- chip

  Widget _chips(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Column(
      children: [
        HudChip(text: context.t.calToday, icon: Icons.today_outlined),
        const SizedBox(height: Gap.md),
        Row(
          children: [
            Expanded(
              child: Container(
                height: 1,
                color: s.primary.withValues(alpha: 0.4),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
              child: HudChip(
                text: context.t.dpNewMessages,
                icon: Icons.arrow_downward,
                glow: true,
              ),
            ),
            Expanded(
              child: Container(
                height: 1,
                color: s.primary.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            HudChip(text: context.t.dpChannelCreated, dense: true),
            const SizedBox(width: Gap.sm),
            HudChip(
              text: context.t.dpE2eeOn,
              icon: Icons.lock_outline,
              dense: true,
            ),
          ],
        ),
      ],
    );
  }

  // -------------------------------------------------------------------- 输入区

  Widget _composer(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final hud = HudTokens.of(context);
    final hasText = _composerHasText;
    return GlassPane(
      radius: Radii.sheet,
      blur: hud.blurChrome,
      elevated: true,
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, Gap.sm),
      child: StatefulBuilder(
        builder: (context, setLocal) => Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            HudIconButton(
              icon: Icons.add_rounded,
              tooltip: context.t.dpAttachTooltip,
              onPressed: () => _showAttachPanel(context),
            ),
            const SizedBox(width: Gap.xs),
            Expanded(
              child: Container(
                constraints: const BoxConstraints(minHeight: 40),
                padding: const EdgeInsets.symmetric(
                  horizontal: Gap.lg,
                  vertical: Gap.sm + 2,
                ),
                decoration: BoxDecoration(
                  color: s.surfaceContainerHighest.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(Radii.pane),
                  border: Border.all(
                    color: hud.edge.withValues(alpha: 0.5),
                    width: 0.7,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        hasText
                            ? context.t.dpComposerTyped
                            : context.t.dpComposerHint,
                        style: hasText
                            ? AppType.chatBody
                            : AppType.chatBody.copyWith(color: hud.meta),
                      ),
                    ),
                    InkWell(
                      onTap: () {
                        setLocal(() => _composerHasText = !_composerHasText);
                        HapticFeedbackCompat.tick();
                      },
                      child: Icon(
                        Icons.emoji_emotions_outlined,
                        size: 20,
                        color: hud.meta,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: Gap.sm),
            MorphOrbButton(
              morph: hasText,
              icon: hasText
                  ? Icons.arrow_upward_rounded
                  : Icons.mic_none_rounded,
              tooltip: hasText ? context.t.chatSend : context.t.dpHoldToTalk,
              onPressed: () =>
                  setLocal(() => _composerHasText = !_composerHasText),
            ),
          ],
        ),
      ),
    );
  }

  bool _composerHasText = false;

  void _showAttachPanel(BuildContext context) {
    showAppSheet(
      context,
      title: context.t.chatSend,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
          child: Wrap(
            spacing: Gap.md,
            runSpacing: Gap.md,
            children: [
              for (final a in [
                (Icons.photo_library_outlined, context.t.navPhotos),
                (Icons.photo_camera_outlined, context.t.profileEditTakePhoto),
                (Icons.insert_drive_file_outlined, context.t.navFiles),
                (Icons.poll_outlined, context.t.chatFilterVote),
                (Icons.schedule_send_outlined, context.t.dpSchedule),
              ])
                _AttachTile(icon: a.$1, label: a.$2),
            ],
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------- 列表行

  Widget _rows(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final hud = HudTokens.of(context);
    Widget row({
      required String title,
      required String preview,
      required String time,
      int unread = 0,
      bool mention = false,
      bool muted = false,
      bool encrypted = false,
      bool pinned = false,
      bool failed = false,
      bool online = false,
      IconData? icon,
      String initial = 'K',
    }) => GlassTap(
      radius: Radii.pane,
      blur: hud.blurChrome - 8,
      fill: hud.glass,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.md),
      margin: const EdgeInsets.only(bottom: Gap.sm),
      onTap: () {},
      haptic: true,
      child: Row(
        children: [
          RingAvatar(
            label: initial,
            icon: icon,
            size: 46,
            ring: online ? hud.online : (unread > 0 ? s.primary : null),
            badge: failed
                ? Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: s.error,
                      shape: BoxShape.circle,
                      border: Border.all(color: s.surface, width: 1.6),
                    ),
                    child: const Icon(
                      Icons.priority_high,
                      size: 9,
                      color: Colors.white,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (pinned)
                      Padding(
                        padding: const EdgeInsets.only(right: 3),
                        child: Icon(Icons.push_pin, size: 13, color: hud.meta),
                      ),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: unread > 0
                              ? FontWeight.w700
                              : FontWeight.w600,
                        ),
                      ),
                    ),
                    if (encrypted)
                      Icon(Icons.lock_outline, size: 12, color: hud.meta),
                    if (muted)
                      Padding(
                        padding: const EdgeInsets.only(left: 3),
                        child: Icon(
                          Icons.notifications_off_outlined,
                          size: 13,
                          color: hud.meta,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: unread > 0 ? s.onSurface : hud.meta,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: Gap.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              TelemetryLabel(time, size: 10.5, letterSpacing: 0.3),
              const SizedBox(height: 5),
              if (unread > 0)
                CountBadge(count: unread, mention: mention, dense: true)
              else
                const SizedBox(height: 18),
            ],
          ),
        ],
      ),
    );
    return Column(
      children: [
        row(
          title: context.t.dpDemoChannel1,
          preview: context.t.dpDemoPreview1,
          time: '21:12',
          unread: 12,
          mention: true,
          pinned: true,
          encrypted: true,
          initial: context.t.dpDemoChannel1.substring(0, 1),
        ),
        row(
          title: 'demo_user',
          preview: context.t.dpDemoPreview2,
          time: '20:58',
          unread: 2,
          online: true,
        ),
        row(
          title: context.t.dpDemoChannel2,
          preview: context.t.dpDemoPreview3,
          time: context.t.fileYesterday,
          icon: Icons.smart_toy_outlined,
          muted: true,
        ),
        row(
          title: context.t.dpDemoChannel3,
          preview: context.t.dpDemoPreview4,
          time: context.t.dtoCalWeekdayWednesday,
          failed: true,
          initial: context.t.dpDemoChannel3.substring(0, 1),
        ),
      ],
    );
  }

  // ------------------------------------------------------------- 头像/徽标/点

  Widget _identity(BuildContext context) {
    final hud = HudTokens.of(context);
    final s = Theme.of(context).colorScheme;
    return GlassPane(
      padding: const EdgeInsets.all(Gap.lg),
      child: Wrap(
        spacing: Gap.lg,
        runSpacing: Gap.lg,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const RingAvatar(label: 'K', size: 56, ring: null),
          RingAvatar(
            label: context.t.dpDemoChannel1.substring(0, 1),
            size: 56,
            ring: s.primary,
            badge: const CountBadge(count: 9, dense: true),
          ),
          const RingAvatar(icon: Icons.smart_toy_outlined, size: 56),
          PulseDot(
            color: const Color(0xFF12B76A),
            semanticLabel: context.t.chatLinkReady,
          ),
          PulseDot(
            color: const Color(0xFFF79009),
            pulsing: false,
            semanticLabel: context.t.dpDegraded,
          ),
          const CountBadge(count: 3),
          const CountBadge(count: 128, mention: true),
          ScanRing(size: 20, semanticLabel: context.t.chatSyncSyncing),
          HudChip(
            text: context.t.chatLinkReady,
            icon: Icons.bolt,
            dense: true,
            color: hud.online,
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------- 球

  Widget _orbs(BuildContext context) {
    return GlassPane(
      padding: const EdgeInsets.all(Gap.lg),
      child: Wrap(
        spacing: Gap.lg,
        runSpacing: Gap.lg,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OrbButton(
            icon: Icons.arrow_downward_rounded,
            badge: const CountBadge(count: 5, dense: true),
            onPressed: () {},
            tooltip: context.t.dpToBottom,
          ),
          OrbButton(
            icon: Icons.edit_outlined,
            onPressed: () {},
            tooltip: context.t.calNew,
          ),
          OrbButton(
            icon: Icons.mic_none_rounded,
            filled: false,
            onPressed: () {},
            tooltip: context.t.chatRecording,
          ),
          HudIconButton(
            icon: Icons.search,
            tooltip: context.t.calEnvSearch,
            onPressed: () {},
          ),
          HudIconButton(
            icon: Icons.more_horiz,
            tooltip: context.t.photoMore,
            glass: true,
            onPressed: () {},
          ),
          MorphOrbButton(
            morph: true,
            icon: Icons.arrow_upward_rounded,
            onPressed: () {},
          ),
          MorphOrbButton(
            morph: false,
            icon: Icons.mic_none_rounded,
            onPressed: () {},
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------- 状态

  Widget _states(BuildContext context) {
    return Column(
      children: [
        GlassPane(
          padding: const EdgeInsets.symmetric(vertical: Gap.lg),
          child: SizedBox(
            height: 190,
            child: AppEmptyState(
              icon: Icons.forum_outlined,
              title: context.t.chatNoMessages,
              message: context.t.chatNoMessagesHint,
              compact: true,
            ),
          ),
        ),
        const SizedBox(height: Gap.md),
        GlassPane(
          padding: const EdgeInsets.symmetric(vertical: Gap.lg),
          child: SizedBox(
            height: 210,
            child: AppErrorView(
              title: context.t.photoLoadFailed,
              detail: context.t.dpCannotConnectNas,
              onRetry: () => AppSnack.show(context, context.t.dpRetryDemo),
            ),
          ),
        ),
        const SizedBox(height: Gap.md),
        GlassPane(
          padding: EdgeInsets.zero,
          child: SizedBox(height: 220, child: const AppChatSkeleton(rows: 5)),
        ),
        const SizedBox(height: Gap.md),
        GlassPane(
          padding: EdgeInsets.zero,
          child: SizedBox(height: 200, child: const AppListSkeleton(rows: 3)),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------- 面板

  Widget _sheetDemo(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.tonal(
            onPressed: () => showAppSheet(
              context,
              title: context.t.dpMessageActions,
              children: [
                QuickReactionRow(
                  emojis: const ['👍', '❤️', '😂', '🎉', '👀', '🔥'],
                  mine: const {'👍'},
                  onPick: (e) {
                    Navigator.of(context).pop();
                    AppSnack.show(context, context.t.dpReactSnack(e));
                  },
                ),
                AppSheetSection(
                  children: [
                    AppSheetAction(
                      icon: Icons.reply_outlined,
                      label: context.t.dpReplyInThread,
                      description: context.t.dpReplyInThreadDesc,
                      onTap: () {},
                    ),
                    AppSheetAction(
                      icon: Icons.star_border,
                      label: context.t.driveStar,
                      onTap: () {},
                    ),
                    AppSheetAction(
                      icon: Icons.push_pin_outlined,
                      label: context.t.chatActionPin,
                      onTap: () {},
                    ),
                    AppSheetAction(
                      icon: Icons.content_copy_outlined,
                      label: context.t.dpCopyText,
                      onTap: () {},
                    ),
                    AppSheetAction(
                      icon: Icons.download_outlined,
                      label: context.t.dpDownloadAttachment,
                      onTap: () {},
                    ),
                  ],
                ),
                AppSheetSection(
                  label: context.t.dpDangerZone,
                  danger: true,
                  children: [
                    AppSheetAction(
                      icon: Icons.delete_outline,
                      label: context.t.dpDeleteMessage,
                      danger: true,
                      onTap: () {},
                    ),
                  ],
                ),
              ],
            ),
            child: Text(context.t.dpBottomSheet),
          ),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: FilledButton(
            onPressed: () => _showAttachPanel(context),
            child: Text(context.t.dpAttachGrid),
          ),
        ),
      ],
    );
  }
}

enum _BubbleState { sent, sending, failed }

/// 亮/暗/跟随 三态切换
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.forced, required this.onChange});

  final Brightness? forced;
  final ValueChanged<Brightness?> onChange;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.sm),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(Radii.capsule),
        ),
        child: Row(
          children: [
            Flexible(child: _seg(context, context.t.dpFollowSystem, null)),
            Flexible(child: _seg(context, context.t.dpLight, Brightness.light)),
            Flexible(child: _seg(context, context.t.dpDark, Brightness.dark)),
          ],
        ),
      ),
    );
  }

  Widget _seg(BuildContext context, String label, Brightness? value) {
    final scheme = Theme.of(context).colorScheme;
    final active = forced == value;
    return InkWell(
      onTap: () => onChange(value),
      borderRadius: BorderRadius.circular(Radii.capsule),
      child: AnimatedContainer(
        duration: Motion.resolve(Motion.fast),
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 6),
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: active ? scheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.capsule),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppType.telemetry(
            color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
            size: 11,
          ),
        ),
      ),
    );
  }
}

/// 附件面板里的一个格子
class _AttachTile extends StatelessWidget {
  const _AttachTile({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 74,
      child: Column(
        children: [
          GlassTap(
            radius: Radii.pane,
            fill: scheme.primary.withValues(alpha: 0.10),
            padding: const EdgeInsets.all(Gap.md),
            onTap: () => AppSnack.show(context, context.t.dpPick(label)),
            child: Icon(icon, size: 24, color: scheme.primary),
          ),
          const SizedBox(height: Gap.xs + 2),
          Text(label, style: Theme.of(context).textTheme.labelMedium),
        ],
      ),
    );
  }
}
