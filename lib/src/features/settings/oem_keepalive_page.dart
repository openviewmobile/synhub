// ★ 厂商（OEM）后台保活指引页（第 278 轮）。
//
// 为什么是一个**页面**而不是一段文档：本 App 不用 FCM，国内 ROM 的
// 「应用启动管理 / 智能省电 / 深度睡眠」直接决定"后台服务活不活、通知到不到"。
// 用户在"设置 → 后台保活"里能看到：
//   * 本机是哪家 ROM（原生**只读**采集）；
//   * 这家 ROM 的省电激进程度 + **逐家的手动设置路径**；
//   * 可点的深链（自启动管理 / 电池优化白名单 / 应用详情）——**只有原生验真
//     过的落点才会出现**，点不动的东西不放上来；
//   * 「不用 FCM」这条背景说明（否则用户以为通知不到是 App 坏了）。
//
// i18n（AGENTS §2.0.13 三步规则）：厂商路径/提示文案在 `oem_guidance.dart`
// 经 `dataText(key, 中文回落)` 取译文，key 已同时登记进
// `app_zh.arb` + `app_en.arb` + `dataTextMap`；本页自己的少量标签直接用
// `context.t.xxx`（ARB getter）。本文件**没有**任何硬编码界面中文
// （守卫 `test/i18n_hardcoded_cjk_test.dart`）。
import 'package:flutter/material.dart';

import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/device/oem_compat_platform.dart';
import '../../core/device/oem_guidance.dart';
import '../../core/theme/app_tokens.dart';
import '../photos/photo_backup_providers.dart' show photoBackupPlatformProvider;

/// 原生 OEM 事实（只读，全局缓存一次）。
final oemCompatPlatformProvider = Provider<OemCompatPlatform>(
  (ref) => MethodChannelOemCompatPlatform(),
);

/// 本机 OEM 事实快照；失败/非 Android ⇒ [OemCompatStatus] 默认（supported=false）。
final oemCompatStatusProvider = FutureProvider<OemCompatStatus>((ref) async {
  return ref.watch(oemCompatPlatformProvider).status();
});

/// 落点 → 按钮文案（ARB getter，逐条显式，便于 i18n 守卫核对）。
String oemOpenLabel(BuildContext context, OemSettingsTarget target) =>
    switch (target) {
      OemSettingsTarget.autostart => context.t.oemOpenAutostart,
      OemSettingsTarget.batteryWhitelist => context.t.oemOpenBattery,
      OemSettingsTarget.appDetails => context.t.oemOpenAppDetails,
    };

class OemKeepalivePage extends ConsumerWidget {
  const OemKeepalivePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final async = ref.watch(oemCompatStatusProvider);
    // 三态：探测中 / 探测失败（仍给通用指引）/ 有事实。**绝不空页**。
    return DesignScaffold(
      key: const Key('oem-keepalive-page'),
      appBar: AppBar(title: Text(t.oemKeepaliveTitle)),
      body: async.when(
        loading: () => const Center(
          key: Key('oem-loading'),
          child: CircularProgressIndicator(),
        ),
        error: (_, _) => _Body(
          status: const OemCompatStatus(),
          onOpen: (target) => _open(context, ref, target),
        ),
        data: (status) => _Body(
          status: status,
          onOpen: (target) => _open(context, ref, target),
        ),
      ),
    );
  }

  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    OemSettingsTarget target,
  ) async {
    final ok = await ref.read(oemCompatPlatformProvider).openSettings(target.id);
    if (!context.mounted || ok) return;
    // 打不开就**如实说**（不静默、不假装成功）；用户照下面的手动路径走
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.t.oemOpenFailed)));
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.status, required this.onOpen});

  final OemCompatStatus status;
  final Future<void> Function(OemSettingsTarget target) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final hud = DesignPalette.of(context);
    final vendor = OemVendor.fromId(status.oemId);
    final g = oemGuidanceFor(vendor, autostartAvailable: status.hasAutostartPage);
    // 非 Android / 通道缺失 / 未收录厂商 ⇒ 只显示通用步骤（不假装知道是哪家）
    final known = status.supported && status.oemId.isNotEmpty;

    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        // ---- 本机一行 + 电池白名单三态 ----
        Card(
          key: const Key('oem-device-card'),
          color: hud.surface,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (status.deviceLine.isNotEmpty)
                  Text(
                    key: const Key('oem-device-line'),
                    '${t.oemDeviceLabel} · ${status.deviceLine}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Text(
                    key: const Key('oem-battery-state'),
                    oemBatteryStateText(
                      ignored: status.batteryOptimizationIgnored,
                    ),
                    style: TextStyle(color: hud.dim),
                  ),
                ),
                if (known)
                  Padding(
                    padding: const EdgeInsets.only(top: Gap.xs),
                    child: Text(
                      key: const Key('oem-kill-level'),
                      oemKillLevelText(g.level),
                      style: TextStyle(
                        color: g.level == OemKillLevel.aggressive
                            ? Theme.of(context).colorScheme.error
                            : hud.dim,
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(top: Gap.xs),
                    child: Text(
                      key: const Key('oem-not-detected'),
                      t.oemNoteOther,
                      style: TextStyle(color: hud.dim),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Gap.md),

        // ---- 「不用 FCM」的背景说明（失败原因可解释） ----
        for (final note in oemGeneralNotes())
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 16, color: hud.dim),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(note, style: TextStyle(color: hud.dim))),
              ],
            ),
          ),
        const SizedBox(height: Gap.md),

        // ---- 步骤（每步一个 Key，测试可逐条点） ----
        //
        // ⚠️ **不把按钮放 `ListTile.trailing`**：中文标签（「打开自启动管理」）
        // + 中文标题在窄屏下会让 trailing 吃掉整行宽度，ListTile 直接抛
        // "Trailing widget consumes the entire tile width"（本页的 widget 用例
        // 在写成 trailing 时**当场抓到过**，见 `oem_keepalive_page_test.dart`）。
        // 改成"标题一行 + 按钮一行左对齐"，宽度不再是固定预算（AGENTS §2.0.10
        // 同一类问题的另一面：可变宽度的动作不许塞进固定预算里）。
        Card(
          color: hud.surface,
          child: Column(
            children: [
              for (final step in g.steps)
                Padding(
                  key: Key('oem-step-${step.id}'),
                  padding: const EdgeInsets.fromLTRB(
                    Gap.md,
                    Gap.sm,
                    Gap.md,
                    Gap.xs,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            step.target == null
                                ? Icons.check_circle_outline
                                : Icons.settings_outlined,
                            size: 18,
                            color: hud.dim,
                          ),
                          const SizedBox(width: Gap.sm),
                          Expanded(child: Text(step.text)),
                        ],
                      ),
                      if (step.target != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            key: Key('oem-open-${step.target!.id}'),
                            onPressed: () => onOpen(step.target!),
                            icon: const Icon(Icons.open_in_new, size: 16),
                            label: Text(oemOpenLabel(context, step.target!)),
                          ),
                        ),
                    ],
                  ),
                ),
              // 自启动页探不到时的**诚实提示**（而不是一个点了报错的按钮）
              if (g.expectsAutostartPage && !status.hasAutostartPage)
                Padding(
                  key: const Key('oem-autostart-missing'),
                  padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_outlined,
                        size: 16,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                        child: Text(
                          oemAutostartMissingText(),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: Gap.md),

        // ---- 手动路径（品牌专有） ----
        Card(
          key: const Key('oem-path-card'),
          color: hud.surface,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  oemPathLabelText(),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: Gap.xs),
                Text(key: const Key('oem-path'), g.path),
                const SizedBox(height: Gap.sm),
                Text(
                  key: const Key('oem-note'),
                  g.note,
                  style: TextStyle(color: hud.dim),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Gap.md),

        // ---- 电池优化白名单（系统页，所有平台都有） ----
        Center(
          child: TextButton.icon(
            key: const Key('oem-open-battery_whitelist-page'),
            onPressed: () => onOpen(OemSettingsTarget.batteryWhitelist),
            icon: const Icon(Icons.battery_saver_outlined, size: 18),
            label: Text(t.oemOpenBattery),
          ),
        ),
        Center(
          child: TextButton.icon(
            key: const Key('oem-recheck'),
            onPressed: () {
              ref.invalidate(oemCompatStatusProvider);
              // 顺手刷新相册备份状态卡片（读的是同一个"白名单"事实）
              ref.invalidate(photoBackupPlatformProvider);
            },
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(t.serviceRecheck),
          ),
        ),
      ],
    );
  }
}
