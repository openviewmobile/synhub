// 相册「手机备份」页 —— 把本机相册（图片/视频）增量备份到 NAS。
//
// 两条落点二选一（用户可选，见 `photo_backup_target.dart`）：
//   * **Drive**（官方相机备份的落点）`/mydrive/PhotoBackup/<设备名>/`；
//   * **Synology Photos** 的「手机备份」相册。
// 两个落点各自独立游标（`PhotoBackupStore`），切换落点**不清空**对方账本。
//
// 这一页是**前台队列**；后台化（WorkManager + 后台 FlutterEngine）在
// `PhotoBackupPlugin.kt` / `PhotoBackupWorker.kt` +
// `photo_backup_background.dart`。两条路共用 `PhotoBackupRunner`
// （同一个队列、同一个上传器、同一套去重），并用 `reportForeground`
// 与原生互斥，**不会双跑**。
//
// 去重 = 本地账本（`stableKey`）+ 目标目录同名同大小 + 抽样 MD5
// （官方 `MD5Utils` 形态，见 `photo_backup_dedup.dart`）。
// 上传 = Photos 走 `Upload.Item/upload_to_folder`（官方 Web 形态）；
// Drive 走 `SYNO.SynologyDrive.Photos/upload`（官方 Drive APK 形态）。
import '../../design/kit/design_kit.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/net/network_type.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/foto_dto.dart';
import '../../data/drive_api.dart' show DriveApi, DriveBackupStructure;
import '../../data/media/device_media_library.dart';
import '../notifications/notification_service.dart'
    show networkTypeProbeProvider;
import 'photo_backup_platform.dart';
import 'photo_backup_providers.dart';
import 'photo_backup_queue.dart';
import 'photo_upload_quality.dart';
import 'photo_backup_target.dart';
import 'photo_backup_text.dart';
import 'photo_browse_page.dart' show showCreateFolderDialog;
import 'photo_free_up_page.dart';
import '../settings/oem_keepalive_page.dart';
import 'sleep_backup_page.dart';
import 'photo_free_up_text.dart';
import 'photo_providers.dart';
import 'photo_widgets.dart' show describePhotoError;

class PhotoBackupPage extends ConsumerStatefulWidget {
  const PhotoBackupPage({super.key});

  @override
  ConsumerState<PhotoBackupPage> createState() => _PhotoBackupPageState();
}

/// P43：档位中文名（官方"原图 / 压缩"两支，这里给出四档细分）。
String _qualityLabel(PhotoUploadQuality q) => switch (q) {
  PhotoUploadQuality.original => pbText(
    PhotoBackupTextKeys.uploadQualityOriginal,
    '原图',
  ),
  PhotoUploadQuality.high => pbText(
    PhotoBackupTextKeys.uploadQualityHigh,
    '高（长边 2048）',
  ),
  PhotoUploadQuality.medium => pbText(
    PhotoBackupTextKeys.uploadQualityMedium,
    '中（长边 1600）',
  ),
  PhotoUploadQuality.low => pbText(
    PhotoBackupTextKeys.uploadQualityLow,
    '低（长边 1280）',
  ),
};

class _PhotoBackupPageState extends ConsumerState<PhotoBackupPage> {
  PhotoBackupQueue? _queue;
  PhotoBackupSnapshot _snapshot = const PhotoBackupSnapshot();
  MediaPermission _permission = MediaPermission.denied;
  List<FotoFolderDto> _folders = const [];
  PhotoBackupPlatformStatus _status = const PhotoBackupPlatformStatus();
  bool _booting = true;
  bool _preparing = false;
  bool _switching = false;
  String? _fatal;
  bool _wifiBlocked = false;
  bool _chargeBlocked = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _queue?.removeListener(_onQueue);
    _queue?.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    PhotoBackupSnapshot snapshot;
    MediaPermission permission;
    try {
      final store = ref.read(photoBackupStoreProvider);
      snapshot = await store.load();
      final media = ref.read(deviceMediaLibraryProvider);
      permission = await media.permissionStatus();
    } catch (err) {
      // 本地库/权限任何一步炸了都不该让页面永远停在转圈
      if (!mounted) return;
      setState(() {
        _booting = false;
        _fatal = describePhotoError(err, context.t);
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _snapshot = snapshot;
      _permission = permission;
      _booting = false;
    });
    // 原生桥是**尽力而为**，不阻塞首帧：没有宿主（单测/纯 Dart）时通道不回应，
    // 页面照常渲染，只把后台卡片降级成"不支持系统级排程"。
    unawaited(_safe(_connectPlatform(snapshot)));
    await _refreshFolders();
  }

  /// 注册后台 entrypoint handle + 对齐排程 + 取原生状态（充电/息屏/上次结果）。
  Future<void> _connectPlatform(PhotoBackupSnapshot snapshot) async {
    final platform = ref.read(photoBackupPlatformProvider);
    // 打开 App 就对一次排程：开关是开的就保证 WorkManager 里有一份
    // （开机/覆盖安装后由 `PhotoBackupBootReceiver` 负责重排）。
    await ensurePhotoBackupCallbackRegistered(platform);
    if (snapshot.enabled) {
      await platform.setSchedule(
        enabled: true,
        chargeOnly: snapshot.chargeOnly,
        screenOffOnly: snapshot.screenOffOnly,
        wifiOnly: snapshot.wifiOnly,
        destination: snapshot.destination,
      );
    }
    final status = await platform.status();
    cachePhotoBackupDeviceName(status.deviceName);
    if (!mounted) return;
    setState(() => _status = status);
  }

  /// 原生调用一律"发出去就不管结果"——界面不允许被原生桥卡住。
  static Future<void> _safe(Future<void> future) async {
    try {
      await future;
    } catch (_) {
      // 通道不认识/无宿主都按"不支持"处理
    }
  }

  void _onQueue() {
    // 队列收尾会改 `lastFinishedAtMs`（存进 store），页面这份快照要跟着走，
    // 否则「上次完成」一直停在「还没备份过」。
    final live = _queue?.snapshot;
    if (mounted) {
      setState(() {
        if (live != null) _snapshot = live;
      });
    }
  }

  Future<void> _onFinished() async {
    final queue = _queue;
    if (!mounted || queue == null) return;
    final counts = queue.counts;
    final t = context.t;
    setState(() => _snapshot = queue.snapshot);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          counts.done == 0 && counts.failed == 0
              ? t.pbNothingToDo
              : t.pbAllDone(counts.done, counts.skipped),
        ),
      ),
    );
    // 松互斥标志：原生 Worker 看到 `foregroundRunning=false` 才会接上
    unawaited(_safe(_refreshAfterForegroundRun()));
  }

  Future<void> _refreshAfterForegroundRun() async {
    final platform = ref.read(photoBackupPlatformProvider);
    await platform.reportForeground(false);
    final status = await platform.status();
    if (!mounted) return;
    setState(() => _status = status);
  }

  Future<void> _update(PhotoBackupSnapshot next) async {
    setState(() => _snapshot = next);
    await ref.read(photoBackupStoreProvider).save(next);
    await _queue?.updateSnapshot(next);
    // 约束/落点/开关变了就重排一次（关闭时等于撤掉排程）
    unawaited(_safe(_pushSchedule(next)));
  }

  /// 落点切换：**只是换一份游标**，两个落点的账本互不影响。
  Future<void> _switchDestination(PhotoBackupDestination destination) async {
    if (_snapshot.destination == destination || _switching) return;
    if (_queue?.running == true) {
      // 正在跑就别切，避免"传一半换目录"
      return;
    }
    setState(() => _switching = true);
    final store = ref.read(photoBackupStoreProvider);
    final next = await store.loadFor(destination);
    if (!mounted) return;
    await store.save(next);
    setState(() {
      _snapshot = next;
      _switching = false;
    });
    unawaited(_safe(_pushSchedule(next)));
    if (!mounted) return;
    final name = destination == PhotoBackupDestination.drive
        ? pbText(PhotoBackupTextKeys.destinationDrive, 'Synology Drive')
        : pbText(PhotoBackupTextKeys.destinationPhotos, 'Synology Photos');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          pbTextFill(
            PhotoBackupTextKeys.destinationSwitched,
            '已切换到{name}；两个落点各自记账，不会互相影响',
            {'name': name},
          ),
        ),
      ),
    );
    await _refreshFolders();
  }

  /// 把当前选项推给原生（WorkManager 约束/周期/开关都在原生侧落地）。
  Future<void> _pushSchedule(PhotoBackupSnapshot s) async {
    final platform = ref.read(photoBackupPlatformProvider);
    await platform.setSchedule(
      enabled: s.enabled,
      chargeOnly: s.chargeOnly,
      screenOffOnly: s.screenOffOnly,
      wifiOnly: s.wifiOnly,
      destination: s.destination,
    );
    final status = await platform.status();
    if (!mounted) return;
    setState(() => _status = status);
  }

  Future<void> _refreshFolders() async {
    final api = ref.read(fotoApiProvider);
    if (api == null) return;
    try {
      final folders = await api.folders();
      if (!mounted) return;
      setState(() => _folders = folders);
    } catch (_) {
      // 列表拉不到不影响用已选目标备份
    }
  }

  Future<void> _grant() async {
    final permission = await ref
        .read(deviceMediaLibraryProvider)
        .ensurePermission();
    if (!mounted) return;
    setState(() => _permission = permission);
  }

  Future<void> _start() async {
    setState(() {
      _preparing = true;
      _fatal = null;
      _wifiBlocked = false;
      _chargeBlocked = false;
    });
    try {
      if (_snapshot.wifiOnly) {
        final net = await ref.read(networkTypeProbeProvider).current();
        if (net != NetworkType.unknown && !net.isWifi) {
          if (!mounted) return;
          setState(() {
            _preparing = false;
            _wifiBlocked = true;
          });
          return;
        }
      }
      // 「仅充电」是硬约束：没插电就不跑（后台由 WorkManager 的
      // `setRequiresCharging` 判定，前台在这里判定，口径一致）。
      if (_snapshot.chargeOnly && !_status.charging) {
        if (!mounted) return;
        setState(() {
          _preparing = false;
          _chargeBlocked = true;
        });
        return;
      }
      // 走**共享编排器**：前台与后台用的是同一个队列/上传器/去重口径
      // （需求：后台复用现有上传器，不重写一遍）。
      final prepared = await ref
          .read(photoBackupRunnerProvider)
          .prepare(_snapshot);
      if (!mounted) return;
      _permission = prepared.permission;
      final queue = prepared.queue;
      if (queue == null) {
        setState(() {
          _preparing = false;
          _fatal = switch (prepared.error) {
            'permission' => context.t.pbPermissionDenied,
            'not-connected' => context.t.pbNotConnected,
            _ => describePhotoError(
              StateError(prepared.error ?? ''),
              context.t,
            ),
          };
        });
        return;
      }
      // 互斥：告诉原生"前台正在跑"，后台 Worker 看到就直接退出（不会双跑）。
      // 发出去即可，不等回报（见 `_safe`）。
      unawaited(
        _safe(ref.read(photoBackupPlatformProvider).reportForeground(true)),
      );
      if (!mounted) return;
      _queue?.removeListener(_onQueue);
      _queue?.dispose();
      queue.addListener(_onQueue);
      queue.onFinished = () {
        _onFinished();
      };
      setState(() {
        _queue = queue;
        _snapshot = queue.snapshot;
        _preparing = false;
      });
      queue.start();
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _fatal = describePhotoError(err, context.t);
      });
    }
  }

  Future<void> _pickTarget() async {
    await _refreshFolders();
    if (!mounted) return;
    final t = context.t;
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DesignRowTile(
              title: Text(t.pbFolderPickTitle),
              trailing: IconButton(
                tooltip: t.photoClose,
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            const Divider(height: 1),
            DesignRowTile(
              key: const Key('photo-backup-new-folder'),
              leading: const Icon(Icons.create_new_folder_outlined),
              title: Text(t.pbTargetCreate),
              onTap: () => Navigator.of(context).pop('__new__'),
            ),
            if (_folders.isEmpty)
              Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Text(
                  t.photoEmptyFoldersTitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: DesignPalette.of(context).dim,
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _folders.length,
                  itemBuilder: (context, i) => DesignRowTile(
                    key: Key('photo-backup-folder-${_folders[i].id}'),
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(_folders[i].name),
                    selected: _folders[i].id == _snapshot.targetFolderId,
                    onTap: () => Navigator.of(context).pop(_folders[i].id),
                  ),
                ),
              ),
            const SizedBox(height: Gap.xs),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked == '__new__') {
      final created = await showCreateFolderDialog(context, ref, parentId: '0');
      if (created == null) return;
      await _update(
        _snapshot.copyWith(
          targetFolderId: created.id,
          targetFolderName: created.name,
        ),
      );
      await _refreshFolders();
      return;
    }
    final folder = _folders.where((f) => f.id == picked).firstOrNull;
    await _update(
      _snapshot.copyWith(
        targetFolderId: picked,
        targetFolderName: folder?.name ?? picked,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final queue = _queue;
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(t.pbTitle),
        actions: [
          IconButton(
            tooltip: t.photoRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              await _refreshFolders();
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      floatingActionButton: _booting || _fatal != null
          ? null
          : FloatingActionButton.extended(
              key: const Key('photo-backup-start'),
              // ★ r522（DA165 同族）：`backgroundColor: hud.surface` + 全局 FAB
              // 前景色（`onPrimary`=白）⇒ 亮色白底白字。显式给前景色。
              backgroundColor: hud.surface,
              foregroundColor: hud.primary,
              icon: const Icon(Icons.backup_outlined),
              label: Text(t.pbStart),
              onPressed: _preparing ? null : _start,
            ),
      body: _booting
          ? const Center(child: CircularProgressIndicator())
          // 内容固定且不多，用非懒加载的 Column：卡片不会因为"在折叠之下"
          // 而根本没被构建（进度/结果卡必须始终可断言、可读屏）。
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 96),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_fatal != null)
                    AppEmptyState(
                      icon: Icons.error_outline,
                      title: t.pbErrorTitle,
                      message: _fatal,
                      actionLabel: t.photoRetry,
                      onAction: () {
                        setState(() => _fatal = null);
                        _start();
                      },
                    )
                  else ...[
                    if (_wifiBlocked) _banner(context, t.pbWifiBlocked),
                    if (_chargeBlocked)
                      _banner(
                        context,
                        pbText(
                          PhotoBackupTextKeys.chargeBlocked,
                          '当前未在充电，已按「仅充电时备份」暂停',
                        ),
                      ),
                    if (_preparing) _banner(context, t.pbPreparing),
                    if (queue != null) ...[
                      _statusCard(context, t, queue),
                      if (queue.failedItems.isNotEmpty)
                        _failedCard(context, t, queue),
                      const SizedBox(height: Gap.md),
                    ],
                    _permissionCard(context, t),
                    const SizedBox(height: Gap.md),
                    _freeUpCard(context, t),
                    const SizedBox(height: Gap.md),
                    _sleepBackupCard(context),
                    const SizedBox(height: Gap.md),
                    _destinationCard(context, t),
                    const SizedBox(height: Gap.md),
                    _targetCard(context, t),
                    const SizedBox(height: Gap.md),
                    _optionsCard(context, t),
                    const SizedBox(height: Gap.md),
                    _backgroundCard(context, t),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _banner(BuildContext context, String text) => Container(
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

  Widget _permissionCard(BuildContext context, AppText t) {
    final granted = _permission.isUsable;
    return Card(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      // ★ 第 55 轮：按钮原来挂在 `ListTile.trailing`，x2.0 文字缩放下
      //   会触发 "Trailing widget consumes the entire tile width"（真溢出，
      //   `ui_overflow_audit_test` 抓到）。放到 tile 下面整行宽度，任何字号都不挤。
      child: Column(
        children: [
          DesignRowTile(
            leading: Icon(
              granted ? Icons.photo_library_outlined : Icons.lock_outline,
              color: granted ? null : Theme.of(context).colorScheme.error,
            ),
            title: Text(t.pbPermissionTitle),
            subtitle: Text(
              granted
                  ? t.pbPermissionGranted
                  // 第 55 轮：桥只有 Android 有 ⇒ 桌面/测试上如实说"此平台尚未
                  // 实现"，不假称"没授权"（那个按钮在桌面上点了也没意义）。
                  : _permission == MediaPermission.unsupported
                  ? t.capReasonNotImplemented
                  : _permission == MediaPermission.partial
                  ? t.pbPermissionPartial
                  : t.pbPermissionDenied,
            ),
          ),
          if (!granted && _permission != MediaPermission.unsupported)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(0, 0, 8, 8),
                child: TextButton(
                  key: const Key('photo-backup-grant'),
                  onPressed: _grant,
                  child: Text(t.pbGrant),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 「释放手机空间」入口（相册 P51）。
  ///
  /// 放在备份页是因为它**依赖备份**：只有 NAS 上已经备份过的照片才会被当成
  /// 可删除的本地副本。判定与删除都在 [PhotoFreeUpSpacePage] 里，这里只给入口。
  Widget _freeUpCard(BuildContext context, AppText t) {
    return Card(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: DesignRowTile(
        key: const Key('photo-free-up-entry'),
        leading: const Icon(Icons.auto_delete_outlined),
        title: Text(freeUpText(PhotoFreeUpTextKeys.entry, '释放手机空间')),
        subtitle: Text(
          freeUpText(
            PhotoFreeUpTextKeys.entryHint,
            '删掉已备份到 NAS 的本地照片，腾出手机存储；没备份的一张都不会动',
          ),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context, rootNavigator: true).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const PhotoFreeUpSpacePage(),
          ),
        ),
      ),
    );
  }

  /// ★ D84（214 轮）「专注备份和同步 / 休眠备份」入口。
  ///
  /// 官方在「更多 > 备份和同步任务」里给这一档（`SleepBackupActivity`）；
  /// 放在备份页的理由与「释放手机空间」一样：它**依赖备份**（统计剩余量、
  /// 在屏幕变暗时跑任务），是备份的"夜间模式"。
  Widget _sleepBackupCard(BuildContext context) {
    return Card(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: DesignRowTile(
        key: const Key('photo-sleep-backup-entry'),
        leading: const Icon(Icons.nightlight_round),
        title: Text(context.t.sleepBackupTitle),
        subtitle: Text(context.t.photoSleepBackupSubtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context, rootNavigator: true).push<void>(
          MaterialPageRoute<void>(builder: (_) => const SleepBackupPage()),
        ),
      ),
    );
  }

  Widget _targetCard(BuildContext context, AppText t) {
    final isDrive = _snapshot.destination == PhotoBackupDestination.drive;
    final device = _status.deviceName.isEmpty ? 'Android' : _status.deviceName;
    final drivePath = DriveApi.photoBackupFolderPath(device);
    // Drive 落点在**跑之前**就有确定路径（官方同构，`ensurePhotoBackupFolder`
    // 只是把这两级目录补出来），所以这里直接显示，不假装"还没选目标"。
    final String ready;
    if (_snapshot.targetFolderId.isNotEmpty) {
      ready = t.pbTargetReady(
        _snapshot.targetFolderName.isEmpty
            ? _snapshot.targetFolderId
            : _snapshot.targetFolderName,
      );
    } else if (isDrive) {
      ready = t.pbTargetReady(DriveApi.sanitizeDeviceName(device));
    } else {
      ready = t.pbTargetNone;
    }
    return Card(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: DesignRowTile(
        key: const Key('photo-backup-target'),
        leading: const Icon(Icons.folder_outlined),
        title: Text(t.pbTargetTitle),
        subtitle: Text(
          isDrive && _snapshot.targetFolderId.isNotEmpty
              ? '$ready\n${pbTextFill(PhotoBackupTextKeys.targetPathLabel, '落点路径：{path}', {'path': drivePath})}'
              : ready,
        ),
        trailing: isDrive ? null : const Icon(Icons.chevron_right),
        onTap: isDrive ? null : _pickTarget,
      ),
    );
  }

  /// **备份目标**单选：Drive（官方同构）或 Synology Photos。
  ///
  /// 统一降级规则（用户钦定，不许删）：
  ///   * `105`/`160` → 该选项**隐藏** + 原因（账号级确定性拒绝，留着只会反复报错）；
  ///   * `102`/`103` → **只影响该选项**（置灰）—— 换台 NAS 就可能有；
  ///   * 未连接 → 两个都置灰。
  Widget _destinationCard(BuildContext context, AppText t) {
    final targets = ref.read(photoBackupTargetsProvider);
    final infos = {
      for (final d in PhotoBackupDestination.values) d: targets.info(d),
    };
    final visible = infos.values.where((i) => !i.isHidden).toList();
    final device = _status.deviceName.isEmpty ? 'Android' : _status.deviceName;
    // 官方同构的落点路径：`/mydrive/PhotoBackup/<设备名>`（见 DriveApi）
    final drivePath = DriveApi.photoBackupFolderPath(device);
    return Card(
      key: const Key('photo-backup-destination-card'),
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Column(
        children: [
          DesignRowTile(
            leading: const Icon(Icons.cloud_outlined),
            title: Text(pbText(PhotoBackupTextKeys.destinationTitle, '备份目标')),
            subtitle: Text(
              pbText(
                PhotoBackupTextKeys.destinationDriveDesc,
                '两个落点各自独立记账，切换不会互相影响',
              ),
            ),
          ),
          const Divider(height: 1),
          if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Text(
                infos.values.first.reason.isEmpty
                    ? pbText(
                        PhotoBackupTextKeys.targetUnavailable,
                        '当前没有可用的备份落点',
                      )
                    : infos.values.first.reason,
              ),
            )
          else
            for (final info in visible)
              _destinationTile(
                context,
                t,
                info,
                info.destination == PhotoBackupDestination.drive
                    ? drivePath
                    : null,
              ),
        ],
      ),
    );
  }

  Widget _destinationTile(
    BuildContext context,
    AppText t,
    PhotoBackupTargetInfo info,
    String? path,
  ) {
    final isDrive = info.destination == PhotoBackupDestination.drive;
    final label = isDrive
        ? pbText(PhotoBackupTextKeys.destinationDrive, 'Synology Drive')
        : pbText(PhotoBackupTextKeys.destinationPhotos, 'Synology Photos');
    final desc = isDrive
        ? pbText(
            PhotoBackupTextKeys.destinationDriveDesc,
            '官方相机备份落点：/mydrive/PhotoBackup/<设备名>/',
          )
        : pbText(
            PhotoBackupTextKeys.destinationPhotosDesc,
            '备份进 Synology Photos 的「手机备份」相册',
          );
    return RadioListTile<PhotoBackupDestination>(
      key: Key('photo-backup-destination-${info.destination.id}'),
      value: info.destination,
      // ignore: deprecated_member_use
      groupValue: _snapshot.destination,
      // ignore: deprecated_member_use
      onChanged: info.isUsable && !_switching
          ? (v) {
              if (v != null) _switchDestination(v);
            }
          : null,
      title: Text(label),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(desc),
          if (path != null && info.isUsable)
            Text(
              pbTextFill(PhotoBackupTextKeys.targetPathLabel, '落点路径：{path}', {
                'path': path,
              }),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (!info.isUsable && info.reason.isNotEmpty)
            Text(
              info.reason,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }

  /// 后台化状态卡片（WorkManager 排程 / 约束 / 上次结果 / 电池白名单）。
  Widget _backgroundCard(BuildContext context, AppText t) {
    final status = _status;
    final meta = DesignPalette.of(context).dim;
    Widget row(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(bottom: Gap.xs),
      child: Row(
        children: [
          Icon(icon, size: 16, color: meta),
          const SizedBox(width: Gap.sm),
          Expanded(child: Text(text)),
        ],
      ),
    );
    return Card(
      key: const Key('photo-backup-background'),
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              pbText(PhotoBackupTextKeys.backgroundTitle, '后台备份'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: Gap.sm),
            if (!status.supported)
              row(
                Icons.info_outline,
                pbText(
                  PhotoBackupTextKeys.backgroundUnsupported,
                  '这台设备不支持系统级后台排程：备份只在应用打开时进行',
                ),
              )
            else ...[
              row(
                status.scheduled ? Icons.schedule : Icons.schedule_outlined,
                status.scheduled
                    ? pbText(
                        PhotoBackupTextKeys.backgroundScheduled,
                        '已开启系统级后台排程（约每小时一次）',
                      )
                    : pbText(
                        PhotoBackupTextKeys.backgroundNotScheduled,
                        '未排程：打开「自动备份」后由系统调度',
                      ),
              ),
              row(
                status.charging ? Icons.bolt : Icons.bolt_outlined,
                status.charging
                    ? pbText(PhotoBackupTextKeys.backgroundCharging, '正在充电')
                    : pbText(PhotoBackupTextKeys.backgroundNotCharging, '未在充电'),
              ),
              row(
                status.screenInteractive
                    ? Icons.brightness_high_outlined
                    : Icons.brightness_low_outlined,
                status.screenInteractive
                    ? pbText(
                        PhotoBackupTextKeys.backgroundScreenOn,
                        '屏幕亮着（若开了「仅息屏」会等到息屏再跑）',
                      )
                    : pbText(
                        PhotoBackupTextKeys.backgroundScreenOff,
                        '屏幕已熄（满足「仅息屏」条件）',
                      ),
              ),
              if (status.deviceName.isNotEmpty)
                row(
                  Icons.phone_android_outlined,
                  pbTextFill(
                    PhotoBackupTextKeys.backgroundDevice,
                    '本机设备名：{name}',
                    {'name': status.deviceName},
                  ),
                ),
              if (status.lastResult.isNotEmpty)
                row(
                  Icons.check_circle_outline,
                  pbTextFill(
                    PhotoBackupTextKeys.backgroundLastResult,
                    '上次后台结果：{result}',
                    {'result': status.lastResult},
                  ),
                ),
              if (!status.batteryOptimizationIgnored) ...[
                row(
                  Icons.battery_alert_outlined,
                  pbText(
                    PhotoBackupTextKeys.backgroundBatteryHint,
                    '系统电池优化可能掐断后台备份，建议加入白名单',
                  ),
                ),
                TextButton(
                  key: const Key('photo-backup-battery'),
                  onPressed: _requestBatteryExemption,
                  child: Text(
                    pbText(
                      PhotoBackupTextKeys.backgroundGrantBattery,
                      '去加入白名单',
                    ),
                  ),
                ),
                // ★ 第 278 轮：厂商（OEM）保活指引 —— 白名单只是"系统级"那一层，
                // 国内 ROM 还有「应用启动管理 / 智能省电」这道自家闸门。
                TextButton(
                  key: const Key('photo-backup-oem-guide'),
                  onPressed: () => Navigator.of(
                    context,
                    rootNavigator: true,
                  ).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const OemKeepalivePage(),
                    ),
                  ),
                  child: Text(t.oemKeepaliveTitle),
                ),
              ],
              TextButton.icon(
                key: const Key('photo-backup-run-now'),
                onPressed: () {
                  unawaited(
                    _safe(ref.read(photoBackupPlatformProvider).runNow()),
                  );
                },
                icon: const Icon(Icons.play_arrow, size: 18),
                label: Text(
                  pbText(PhotoBackupTextKeys.backgroundRunNow, '立即排队跑一次'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _requestBatteryExemption() async {
    unawaited(
      _safe(
        ref
            .read(photoBackupPlatformProvider)
            .requestIgnoreBatteryOptimization(),
      ),
    );
  }

  Widget _optionsCard(BuildContext context, AppText t) => Card(
    color: Theme.of(
      context,
    ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
    child: Column(
      children: [
        DesignSwitchRow(
          key: const Key('photo-backup-auto'),
          value: _snapshot.enabled,
          title: Text(t.pbAutoBackup),
          subtitle: Text(t.pbAutoBackupHint),
          onChanged: (v) => _update(_snapshot.copyWith(enabled: v)),
        ),
        // P43：上传质量档（原图 / 压缩）。压缩是**纯客户端**行为
        // （服务端 `SYNO.Foto.Upload.so` 没有质量/尺寸参数），所以这里只是
        // 客户端策略：`PhotoBackupSnapshot.uploadQuality` → 队列里的压缩器。
        DesignRowTile(
          key: const Key('photo-backup-quality'),
          title: Text(pbText(PhotoBackupTextKeys.uploadQuality, '上传质量')),
          subtitle: Text(
            pbText(
              PhotoBackupTextKeys.uploadQualityHint,
              '压缩在手机本地完成（原图不压缩）；HEIC/RAW/视频一律原样上传',
            ),
          ),
        ),
        // ★ 第 55 轮：下拉框原来挂在 `ListTile.trailing` 上，x2.0 文字缩放下
        //   会触发 "Trailing widget consumes the entire tile width"（真溢出，
        //   `ui_overflow_audit_test` 抓到）。移到整行宽度下面，任何字号都不挤。
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: DropdownButton<PhotoUploadQuality>(
              key: const Key('photo-backup-quality-select'),
              isExpanded: true,
              value: _snapshot.uploadQuality,
              onChanged: (v) {
                if (v != null) _update(_snapshot.copyWith(uploadQuality: v));
              },
              items: [
                for (final q in PhotoUploadQuality.values)
                  DropdownMenuItem(
                    key: Key('photo-backup-quality-${q.id}'),
                    value: q,
                    child: Text(_qualityLabel(q)),
                  ),
              ],
            ),
          ),
        ),
        DesignSwitchRow(
          key: const Key('photo-backup-videos'),
          value: _snapshot.includeVideos,
          title: Text(t.pbIncludeVideos),
          onChanged: (v) => _update(_snapshot.copyWith(includeVideos: v)),
        ),
        DesignSwitchRow(
          key: const Key('photo-backup-wifi'),
          value: _snapshot.wifiOnly,
          title: Text(t.pbWifiOnly),
          onChanged: (v) => _update(_snapshot.copyWith(wifiOnly: v)),
        ),
        // 「仅充电」官方 `PhotoBackupSettings.isUploadChargeOnly`（默认 false）
        DesignSwitchRow(
          key: const Key('photo-backup-charge'),
          value: _snapshot.chargeOnly,
          title: Text(pbText(PhotoBackupTextKeys.chargeOnly, '仅充电时备份')),
          subtitle: Text(
            pbText(
              PhotoBackupTextKeys.chargeOnlyHint,
              '官方同款约束：插上电源才跑（后台交给系统约束，前台立即生效）',
            ),
          ),
          onChanged: (v) => _update(_snapshot.copyWith(chargeOnly: v)),
        ),
        // 「仅息屏」：官方 `SleepBackupUtil` / 专注备份
        DesignSwitchRow(
          key: const Key('photo-backup-screenoff'),
          value: _snapshot.screenOffOnly,
          title: Text(pbText(PhotoBackupTextKeys.screenOffOnly, '仅息屏时备份')),
          subtitle: Text(
            pbText(
              PhotoBackupTextKeys.screenOffOnlyHint,
              '屏幕熄灭后才开始，亮屏时后台会退避重试',
            ),
          ),
          onChanged: (v) => _update(_snapshot.copyWith(screenOffOnly: v)),
        ),
        // ★ D72 按日期分目录（官方 `BackupStructure`：none/year/year_and_month，
        // 默认 year_and_month；用**拍摄时间**分段 ——
        // `PhotoBackupManager:1596-1600` + `DateUtilities` 的 `yyyy` / `yyyy/MM`）。
        DesignRowTile(
          key: const Key('photo-backup-structure'),
          title: Text(pbText(PhotoBackupTextKeys.structure, '按日期分目录')),
          subtitle: Text(
            _structureHint(_snapshot.structure),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _pickStructure,
        ),
        // 备份范围：官方恒为 DCIM（可配置，默认只扫 DCIM）
        DesignSwitchRow(
          key: const Key('photo-backup-dcim'),
          value: _snapshot.dcimOnly,
          title: Text(pbText(PhotoBackupTextKeys.dcimOnly, '只备份 DCIM（相机）')),
          subtitle: Text(
            pbText(
              PhotoBackupTextKeys.dcimOnlyHint,
              '官方相机备份的范围恒为 DCIM；关掉会把截图/下载目录也传上去',
            ),
          ),
          onChanged: (v) => _update(_snapshot.copyWith(dcimOnly: v)),
        ),
      ],
    ),
  );

  /// D72：官方三个取值的中文说明（option 名沿用官方枚举字面量）。
  String _structureHint(DriveBackupStructure s) => switch (s) {
    DriveBackupStructure.none => pbText(
      PhotoBackupTextKeys.structureNone,
      '不建日期目录（none）：全部文件放在设备目录下',
    ),
    DriveBackupStructure.year => pbText(
      PhotoBackupTextKeys.structureYear,
      '按年（year）：设备目录 / 2026',
    ),
    DriveBackupStructure.yearAndMonth => pbText(
      PhotoBackupTextKeys.structureYearMonth,
      '按年 + 月（year_and_month，官方默认）：设备目录 / 2026 / 09',
    ),
  };

  /// 选目录结构（三个官方取值；选完立刻落盘，与其它开关同一路径）。
  Future<void> _pickStructure() async {
    final picked = await showModalBottomSheet<DriveBackupStructure>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          key: const Key('photo-backup-structure-sheet'),
          children: [
            for (final s in DriveBackupStructure.values)
              DesignRowTile(
                key: Key('photo-backup-structure-${s.value}'),
                selected: s == _snapshot.structure,
                title: Text(s.value),
                subtitle: Text(_structureHint(s)),
                onTap: () => Navigator.of(ctx).pop(s),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await _update(_snapshot.copyWith(structure: picked));
  }

  Widget _statusCard(BuildContext context, AppText t, PhotoBackupQueue queue) {
    final counts = queue.counts;
    final running = queue.running;
    return Card(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _snapshot.hasFinished
                  ? t.pbLastFinished(_formatTime(_snapshot.lastFinishedAtMs))
                  : t.pbNeverFinished,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Gap.sm),
            LinearProgressIndicator(
              key: const Key('photo-backup-progress'),
              value: counts.total == 0 ? 0 : counts.ratio,
            ),
            const SizedBox(height: Gap.sm),
            Text(
              t.pbProgress(counts.done, counts.total - counts.skipped),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: Gap.xs),
            Wrap(
              spacing: Gap.md,
              children: [
                if (counts.pending > 0) Text(t.pbCountPending(counts.pending)),
                if (counts.failed > 0) Text(t.pbCountFailed(counts.failed)),
                if (counts.skipped > 0) Text(t.pbCountSkipped(counts.skipped)),
              ],
            ),
            const SizedBox(height: Gap.sm),
            Row(
              children: [
                if (running && !queue.paused)
                  TextButton.icon(
                    key: const Key('photo-backup-pause'),
                    onPressed: queue.pause,
                    icon: const Icon(Icons.pause, size: 18),
                    label: Text(t.pbPause),
                  )
                else if (running && queue.paused)
                  TextButton.icon(
                    key: const Key('photo-backup-resume'),
                    onPressed: queue.resume,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: Text(t.pbResume),
                  ),
                if (running)
                  TextButton.icon(
                    key: const Key('photo-backup-cancel'),
                    onPressed: queue.cancel,
                    icon: const Icon(Icons.close, size: 18),
                    label: Text(t.pbCancel),
                  ),
                if (counts.failed > 0)
                  TextButton.icon(
                    key: const Key('photo-backup-retry'),
                    onPressed: queue.retryFailed,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(t.pbRetryFailed),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _failedCard(BuildContext context, AppText t, PhotoBackupQueue queue) =>
      Card(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Text(
                t.pbFailedTitle,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            for (final item in queue.failedItems)
              DesignRowTile(
                dense: true,
                leading: Icon(
                  Icons.error_outline,
                  size: 18,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  item.asset.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  item.cause != null
                      ? describePhotoError(item.cause!, t)
                      : (item.error ?? ''),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      );

  static String _formatTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }
}
