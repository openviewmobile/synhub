// 相册「释放手机空间」页（P51）：删掉**已备份到 NAS** 的本地照片副本，腾出手机存储。
//
// ## 官方对应物
//
// `freeupspace.FreeUpSpaceActivity` + `FreeUpSpaceService`、
// `layout/fragment_free_up_*`、`str_explain_free_up_space`、
// `str_start_free_up_space`、`activity_photo_backup_release_space`。
//
// ## 本页的三条硬规矩
//
// ① **未备份的照片绝不删**：候选只在 [PhotoFreeUpPlanner] 里产生，而它复用的就是
//    相机备份"这张已经传上去了"的判据（本机账本 `stableKey` / NAS 同名同大小）。
//    判定不确定（还没传、传失败、不在备份范围、0 字节清单条目）⇒ 一律保留。
// ② **绝不静默删除**：删本地照片**必然**经过 Android 系统确认框
//    （`MediaStore.createDeleteRequest`）。用户点取消 → 一张都不删。
// ③ **平台不给删就如实说**：系统版本太低 / 没有平台通道时，页面给**人话说明**
//    并引导去系统设置手动清理，**绝不把"跳去设置"包装成"已释放空间"**。
//
// ## 文案纪律
//
// 界面**不出现**任何工程词（`MediaStore` / `clearCache` / `content://` /
// `FreeUpSpaceActivity`）；平台差异只说"系统确认框 / 到系统设置里手动清理"。
// 全部文案走 `photo_free_up_text.dart`（key + 中文原文），key 清单见交付报告。
//
// ## §5.1：本页不对 NAS 发任何写操作
//
// 只用**已保存的**备份落点做**只读**清单（`Browse.Item/list` / Drive `list`）；
// 绝不调用会建目录的 `ensureTarget`。删除只发生在**手机本地相册**。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/media/cache_service.dart' show humanBytes;
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/media/device_media_library.dart';
import 'photo_backup_providers.dart';
import 'photo_c2_sections.dart';
import 'photo_free_up_controller.dart';
import 'photo_free_up_plan.dart';
import 'photo_free_up_providers.dart';
import 'photo_free_up_text.dart';
import 'photo_widgets.dart' show describePhotoError;

class PhotoFreeUpSpacePage extends ConsumerStatefulWidget {
  const PhotoFreeUpSpacePage({super.key});

  @override
  ConsumerState<PhotoFreeUpSpacePage> createState() =>
      _PhotoFreeUpSpacePageState();
}

class _PhotoFreeUpSpacePageState extends ConsumerState<PhotoFreeUpSpacePage> {
  PhotoFreeUpController? _controller;
  bool _booting = true;
  String? _fatal;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _controller?.removeListener(_onChanged);
    _controller?.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _boot() async {
    try {
      final controller = PhotoFreeUpController(
        media: ref.read(deviceMediaLibraryProvider),
        deleter: ref.read(photoFreeUpDeleterProvider),
        store: ref.read(photoBackupStoreProvider),
        targets: ref.read(photoBackupTargetsProvider),
      )..addListener(_onChanged);
      if (!mounted) return;
      setState(() {
        _controller = controller;
        _booting = false;
      });
      await controller.scan();
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _booting = false;
        _fatal = describePhotoError(err, context.t);
      });
    }
  }

  Future<void> _rescan() => _controller?.scan() ?? Future<void>.value();

  Future<void> _grant() => _controller?.scan(interactive: true) ??
      Future<void>.value();

  /// 释放：请求平台删除候选 —— 平台**必须**弹系统确认框。
  ///
  /// 只有**真的删掉了**才顺带清 App 自己的上传临时副本：用户拒绝 / 平台不支持时
  /// 这一轮**什么都不该被动过**（连我们自己的临时文件也不清）。
  Future<void> _freeUp() async {
    final controller = _controller;
    if (controller == null) return;
    final report = await controller.run();
    if (report.anyDeleted) {
      await controller.clearAppCache();
    }
    if (!mounted) return;
    final String message = switch (report.outcome) {
      FreeUpRunOutcome.deleted => freeUpTextFill(
        PhotoFreeUpTextKeys.deleted,
        '已释放 {size}（{count} 张）',
        {'size': humanBytes(report.bytesDeleted), 'count': '${report.deleted}'},
      ),
      // **绝不**把"跳设置"说成"已释放"
      FreeUpRunOutcome.rejected => freeUpText(
        PhotoFreeUpTextKeys.cancelled,
        '已取消，没有删除任何照片',
      ),
      FreeUpRunOutcome.unsupported => freeUpText(
        PhotoFreeUpTextKeys.unsupportedTitle,
        '这台设备不能由应用删除照片',
      ),
      FreeUpRunOutcome.failed => freeUpText(
        PhotoFreeUpTextKeys.failed,
        '删除没有完成，一张都没有删掉，请稍后重试',
      ),
      FreeUpRunOutcome.nothing => freeUpText(
        PhotoFreeUpTextKeys.nothingToFree,
        '当前没有可释放的照片',
      ),
    };
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openSettings() async {
    final controller = _controller;
    if (controller == null) return;
    final ok = await controller.openSystemSettings();
    if (ok || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          freeUpText(
            PhotoFreeUpTextKeys.settingsFailed,
            '没能打开系统设置，请手动进入「设置 → 应用 → 存储」清理',
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return PhotoC2Scaffold(
      pageKey: const Key('photo-free-up-page'),
      title: freeUpText(PhotoFreeUpTextKeys.title, '释放手机空间'),
      body: _booting || controller == null
          ? const Center(child: CircularProgressIndicator())
          : _body(context, controller),
    );
  }

  Widget _body(BuildContext context, PhotoFreeUpController c) {
    if (_fatal != null) {
      return AppEmptyState(
        icon: Icons.error_outline,
        title: freeUpText(PhotoFreeUpTextKeys.title, '释放手机空间'),
        message: _fatal,
        actionLabel: context.t.photoRetry,
        onAction: () {
          setState(() => _fatal = null);
          _rescan();
        },
      );
    }
    final granted = c.permission.isUsable;
    return ListView(
      key: const Key('photo-free-up-body'),
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xl),
      children: [
        _explainCard(context),
        const SizedBox(height: Gap.md),
        if (!granted)
          _permissionCard(context, c)
        else ...[
          if (c.scanning)
            _notice(
              context,
              freeUpText(
                PhotoFreeUpTextKeys.scanning,
                '正在核对本机照片与 NAS 备份…',
              ),
            ),
          if (c.notConnected)
            _notice(
              context,
              freeUpText(
                PhotoFreeUpTextKeys.notConnected,
                '还没连接 NAS，无法核对哪些照片已经备份；请先连接后重新核对',
              ),
            ),
          if (!c.remoteChecked && c.ledgerSize > 0)
            _notice(
              context,
              freeUpText(
                PhotoFreeUpTextKeys.noTarget,
                '还没设置备份目标，只能依据本机备份记录判断',
              ),
            ),
          _reclaimCard(context, c),
          const SizedBox(height: Gap.md),
          if (c.entries.isNotEmpty && !c.support.canDeleteOnDevice) ...[
            _platformCard(context, c),
            const SizedBox(height: Gap.md),
          ],
          if (c.lastRun != null) ...[
            _resultCard(context, c.lastRun!),
            const SizedBox(height: Gap.md),
          ],
          if (c.entries.isNotEmpty) _entryListCard(context, c),
        ],
      ],
    );
  }

  /// 官方 `str_explain_free_up_space` 同构：先把"会发生什么"讲清楚。
  Widget _explainCard(BuildContext context) {
    final hud = DesignPalette.of(context);
    final meta = Theme.of(context).textTheme.bodySmall?.copyWith(color: hud.dim);
    return Card(
      key: const Key('photo-free-up-explain'),
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_delete_outlined, size: 20),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Text(
                    freeUpText(
                      PhotoFreeUpTextKeys.explainTitle,
                      '只删除已备份的照片',
                    ),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Text(
              freeUpText(
                PhotoFreeUpTextKeys.explainBody,
                '我们会逐张核对：只有 NAS 上已经备份过的照片才会进入可删除列表，'
                '没备份的照片一律保留。删除前系统会弹出确认框，你也可以随时取消；'
                'NAS 上的备份不受影响。',
              ),
              style: meta,
            ),
          ],
        ),
      ),
    );
  }

  Widget _permissionCard(BuildContext context, PhotoFreeUpController c) {
    final partial = c.permission == MediaPermission.partial;
    return Card(
      key: const Key('photo-free-up-permission'),
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: DesignRowTile(
        leading: Icon(
          Icons.lock_outline,
          color: Theme.of(context).colorScheme.error,
        ),
        title: Text(
          freeUpText(
            PhotoFreeUpTextKeys.noPermissionTitle,
            '读不到本机照片，无法核对备份',
          ),
        ),
        subtitle: Text(
          partial ? context.t.pbPermissionPartial : context.t.pbPermissionDenied,
        ),
        trailing: TextButton(
          key: const Key('photo-free-up-grant'),
          onPressed: _grant,
          child: Text(context.t.pbGrant),
        ),
      ),
    );
  }

  /// 「可释放 X」+ 计数 + 主按钮。
  Widget _reclaimCard(BuildContext context, PhotoFreeUpController c) {
    final hud = DesignPalette.of(context);
    final meta = Theme.of(context).textTheme.bodySmall?.copyWith(color: hud.dim);
    final count = c.reclaimableCount;
    return Card(
      key: const Key('photo-free-up-reclaimable'),
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (count == 0)
              Text(
                freeUpText(
                  PhotoFreeUpTextKeys.nothingTitle,
                  '没有可释放的照片',
                ),
                style: Theme.of(context).textTheme.titleMedium,
              )
            else
              Text(
                freeUpTextFill(
                  PhotoFreeUpTextKeys.reclaimable,
                  '可释放 {size}',
                  {'size': humanBytes(c.reclaimableBytes)},
                ),
                key: const Key('photo-free-up-reclaimable-size'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            const SizedBox(height: Gap.xs),
            Text(
              count == 0
                  ? freeUpText(
                      PhotoFreeUpTextKeys.nothingBody,
                      '本机照片都还没有备份，或已经核对完毕、没有多余的本地副本。',
                    )
                  : freeUpTextFill(
                      PhotoFreeUpTextKeys.counts,
                      '已备份 {backedUp} 张 · 未备份 {kept} 张不会删除',
                      {
                        'backedUp': '${c.scannedCount - c.keptCount}',
                        'kept': '${c.keptCount}',
                      },
                    ),
              key: const Key('photo-free-up-counts'),
              style: meta,
            ),
            if (c.deleting) ...[
              const SizedBox(height: Gap.sm),
              LinearProgressIndicator(
                key: const Key('photo-free-up-progress'),
                value: c.entries.isEmpty
                    ? null
                    : c.entries
                              .where(
                                (e) => e.outcome != FreeUpEntryOutcome.pending,
                              )
                              .length /
                          c.entries.length,
              ),
              const SizedBox(height: Gap.xxs),
              Text(
                freeUpTextFill(
                  PhotoFreeUpTextKeys.progress,
                  '已处理 {done}/{total}',
                  {
                    'done':
                        '${c.entries.where((e) => e.outcome != FreeUpEntryOutcome.pending).length}',
                    'total': '${c.entries.length}',
                  },
                ),
                style: meta,
              ),
            ],
            if (c.cacheCleared) ...[
              const SizedBox(height: Gap.xs),
              Text(
                freeUpText(
                  PhotoFreeUpTextKeys.cacheCleared,
                  '应用上传时留下的临时文件已清理',
                ),
                key: const Key('photo-free-up-cache-cleared'),
                style: meta,
              ),
            ],
            const SizedBox(height: Gap.sm),
            Row(
              children: [
                // 只有"平台能弹系统确认框"时才提供代删按钮；
                // 否则主按钮在下面的降级卡片里（去系统设置）。
                if (count > 0 && c.support.canDeleteOnDevice)
                  // ★ r332：这一处**在 r330 被漏掉了** —— 它前面有注释，
                  //   老守卫的 `_stripGuards` 只剥 `if (`，撞上 `//` 就整条跳过
                  //   ⇒ 静态守卫看不见、又没有任何用例带产品主题渲染这一支
                  //   ⇒ 真机点进"释放空间"会当场 `BoxConstraints forces an infinite width`。
                  FilledButton.icon( style: InlineButtonStyle.filled,
                    key: const Key('photo-free-up-start'),
                    onPressed: c.deleting || c.scanning ? null : _freeUp,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                    label: Text(
                      freeUpText(PhotoFreeUpTextKeys.start, '释放空间'),
                    ),
                  ),
                if (count > 0 && !c.support.canDeleteOnDevice)
                  TextButton.icon(
                    key: const Key('photo-free-up-settings-primary'),
                    onPressed: _openSettings,
                    icon: const Icon(Icons.settings_outlined, size: 18),
                    label: Text(
                      freeUpText(
                        PhotoFreeUpTextKeys.openSettings,
                        '去系统设置手动清理',
                      ),
                    ),
                  ),
                const Spacer(),
                TextButton(
                  key: const Key('photo-free-up-rescan'),
                  onPressed: c.scanning || c.deleting ? null : _rescan,
                  child: Text(
                    freeUpText(PhotoFreeUpTextKeys.rescan, '重新核对'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 平台能力降级说明：**只讲人话**，不讲实现。
  Widget _platformCard(BuildContext context, PhotoFreeUpController c) {
    final settingsOnly = c.support == MediaDeleteSupport.settingsOnly;
    return Card(
      key: const Key('photo-free-up-platform'),
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              settingsOnly
                  ? freeUpText(
                      PhotoFreeUpTextKeys.settingsOnlyTitle,
                      '这台设备需要你手动清理',
                    )
                  : freeUpText(
                      PhotoFreeUpTextKeys.unsupportedTitle,
                      '这台设备不能由应用删除照片',
                    ),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: Gap.xs),
            Text(
              settingsOnly
                  ? freeUpText(
                      PhotoFreeUpTextKeys.settingsOnlyBody,
                      '当前系统不支持由应用发起删除确认。请到系统设置的应用存储里手动清理，'
                      '或在系统相册里手动删除上面列出的照片；NAS 上的备份都还在。',
                    )
                  : freeUpText(
                      PhotoFreeUpTextKeys.unsupportedBody,
                      '当前环境没有可用的删除能力。你可以到系统设置里手动清理；'
                      'NAS 上的备份都还在，什么都没被删除。',
                    ),
            ),
            TextButton.icon(
              key: const Key('photo-free-up-settings'),
              onPressed: _openSettings,
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: Text(
                freeUpText(PhotoFreeUpTextKeys.openSettings, '去系统设置手动清理'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultCard(BuildContext context, FreeUpRunReport report) {
    final hud = DesignPalette.of(context);
    final meta = Theme.of(context).textTheme.bodySmall?.copyWith(color: hud.dim);
    final (IconData icon, String text) = switch (report.outcome) {
      FreeUpRunOutcome.deleted => (
        Icons.check_circle_outline,
        report.failed > 0
            ? freeUpTextFill(
                PhotoFreeUpTextKeys.deletedSomeFailed,
                '有 {count} 张没能删除，其余已释放',
                {'count': '${report.failed}'},
              )
            : freeUpTextFill(
                PhotoFreeUpTextKeys.deleted,
                '已释放 {size}（{count} 张）',
                {
                  'size': humanBytes(report.bytesDeleted),
                  'count': '${report.deleted}',
                },
              ),
      ),
      FreeUpRunOutcome.rejected => (
        Icons.info_outline,
        freeUpText(
          PhotoFreeUpTextKeys.cancelled,
          '已取消，没有删除任何照片',
        ),
      ),
      FreeUpRunOutcome.unsupported || FreeUpRunOutcome.failed => (
        Icons.info_outline,
        report.outcome == FreeUpRunOutcome.failed
            ? freeUpText(
                PhotoFreeUpTextKeys.failed,
                '删除没有完成，一张都没有删掉，请稍后重试',
              )
            : freeUpText(
                PhotoFreeUpTextKeys.settingsOnlyBody,
                '当前系统不支持由应用发起删除确认。请到系统设置的应用存储里手动清理，'
                '或在系统相册里手动删除上面列出的照片；NAS 上的备份都还在。',
              ),
      ),
      FreeUpRunOutcome.nothing => (
        Icons.info_outline,
        freeUpText(PhotoFreeUpTextKeys.nothingToFree, '当前没有可释放的照片'),
      ),
    };
    return Card(
      key: const Key('photo-free-up-result'),
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: DesignRowTile(
        leading: Icon(icon),
        title: Text(text),
        subtitle: report.anyDeleted
            ? Text(
                freeUpTextFill(
                  PhotoFreeUpTextKeys.progress,
                  '已处理 {done}/{total}',
                  {
                    'done': '${report.requested - report.failed}',
                    'total': '${report.requested}',
                  },
                ),
                style: meta,
              )
            : null,
      ),
    );
  }

  Widget _entryListCard(BuildContext context, PhotoFreeUpController c) {
    final hud = DesignPalette.of(context);
    final meta = Theme.of(context).textTheme.bodySmall?.copyWith(color: hud.dim);
    return Card(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in c.entries)
            DesignRowTile(
              key: Key('photo-free-up-item-${entry.asset.id}'),
              dense: true,
              leading: Icon(
                switch (entry.outcome) {
                  FreeUpEntryOutcome.deleted => Icons.check_circle_outline,
                  FreeUpEntryOutcome.kept => Icons.shield_outlined,
                  FreeUpEntryOutcome.pending => Icons.delete_outline,
                },
                color: hud.dim,
                size: 20,
              ),
              title: Text(
                entry.asset.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  entry.reason == FreeUpReason.backupLedger
                      ? freeUpText(
                          PhotoFreeUpTextKeys.itemReasonLedger,
                          '已备份（本机备份记录）',
                        )
                      : freeUpText(
                          PhotoFreeUpTextKeys.itemReasonRemote,
                          '已备份（NAS 上已有同名文件）',
                        ),
                  humanBytes(entry.asset.size),
                  switch (entry.outcome) {
                    FreeUpEntryOutcome.deleted => freeUpText(
                      PhotoFreeUpTextKeys.itemStateDeleted,
                      '已删除',
                    ),
                    FreeUpEntryOutcome.kept => freeUpText(
                      PhotoFreeUpTextKeys.itemStateKept,
                      '已保留',
                    ),
                    FreeUpEntryOutcome.pending => freeUpText(
                      PhotoFreeUpTextKeys.itemStatePending,
                      '待删除',
                    ),
                  },
                ].join(' · '),
                style: meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  Widget _notice(BuildContext context, String text) => Container(
    key: Key('photo-free-up-notice-${text.hashCode}'),
    margin: const EdgeInsets.only(bottom: Gap.md),
    padding: const EdgeInsets.all(Gap.md),
    decoration: BoxDecoration(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(Radii.cut),
    ),
    child: Row(
      children: [
        const Icon(Icons.info_outline, size: 18),
        const SizedBox(width: Gap.sm),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
