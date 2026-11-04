// 手机自动备份的**纯逻辑层**：去重计划 + 上传队列状态机。
//
// 这里不碰 UI、不碰 `dart:io`、不 import l10n —— 方便离线单测直接构造：
//   * [DeviceMediaLibrary] 提供"本机有哪些照片"（测试里是假实现）；
//   * [PhotoBackupUploader] 提供"把一张传上去"（测试里是假的，可让它按意愿成败）；
//   * [PhotoBackupStore] 提供"本地记过什么"（测试里是内存实现）。
//
// 去重口径（见 `docs/p2-photos-backup-research.md` §1.5）：
//   1. **本地记账**：`stableKey`（相对路径+文件名+大小+拍摄时间）已 done → 跳过；
//   2. **服务端目标目录**：目标相册里已有"同名 + 同大小" → 跳过；
//   3. `Upload.Item/backup_check` 若响应可识别，再过滤一遍（Best-effort，见 FotoApi）。
//
// ⚠️ **同内容不同名**在客户端认不出来（`hash_code` 算法未知），会当成新文件上传；
// 服务端自己的 `duplicate_hash` 会兜住。这个取舍在文档里写明了。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../data/media/device_media_library.dart';
import '../../data/drive_api.dart' show DriveBackupStructure;
import 'photo_upload_quality.dart';
import '../../core/user_facing_error.dart';

/// 目标相册里已存在的一个文件（来自 `Browse.Item/list` + `folder_id`）。
@immutable
class RemotePhotoEntry {
  const RemotePhotoEntry({required this.name, required this.size});

  final String name;
  final int size;

  /// 服务端去重键：**文件名 + 大小**
  String get key => '$name|$size';
}

/// 一条备份项的结局原因（跳过时用）。
enum BackupSkipReason {
  /// 本地账本里已标记完成
  alreadyDone,

  /// 目标相册里已有同名同大小
  existsOnNas,

  /// 用户选择不备份视频
  videoExcluded,

  /// **抽样 MD5 命中**：本机另一条记录（可能已被改名）内容相同，不重复传
  duplicateContent,

  /// 不在备份范围（默认只扫 DCIM）
  outsideSourceScope,
}

/// 用户可选的**备份落点**（两个落点各自独立游标，见 `PhotoBackupStore`）。
///
/// * [drive] —— 官方相机备份的落点：Drive 的 `/mydrive/PhotoBackup/<设备名>/`
///   （`docs/drive-parity-audit.md:264`，逐字证据 `BackupTarget.java:177-190`）；
/// * [synologyPhotos] —— 我们历史上一直在用的落点：Synology Photos 的
///   `Upload.Item/upload_to_folder`（`docs/photo-parity-audit.md` §4.2）。
///
/// `id` 是**落盘字面量**（Drift 表主键 + Android 侧 SharedPreferences），
/// 改它等于换一个落点，别动。默认 [synologyPhotos]：老库里的旧游标当初就写在
/// Photos 上，默认沿用旧落点，升级后**不会**被误判成"Drive 已备份过"而漏传。
enum PhotoBackupDestination {
  drive('drive'),
  synologyPhotos('synology_photos');

  const PhotoBackupDestination(this.id);

  final String id;

  /// 认得就转，不认得回默认落点（脏数据不许把备份整个卡死）。
  static PhotoBackupDestination fromId(String? id) =>
      PhotoBackupDestination.values.firstWhere(
        (d) => d.id == id,
        orElse: () => PhotoBackupDestination.synologyPhotos,
      );
}

/// 队列里一项的状态。
enum BackupItemState { pending, uploading, done, failed, skipped }

/// 队列里的一项（照片 + 它的状态）。
class PhotoBackupItem {
  PhotoBackupItem(this.asset, {this.state = BackupItemState.pending});

  final DeviceMediaAsset asset;
  BackupItemState state;

  /// 已经试了几次（含自动重试）
  int attempts = 0;

  /// 最近一次失败的原因（给人看的原文，界面侧再包一层文案）
  String? error;

  /// 原始异常（界面用 [describePhotoError] 翻成人话；`cancelled` 之类没有）
  Object? cause;

  /// 跳过原因（`state == skipped` 时有值）
  BackupSkipReason? skipReason;

  /// 上传进度 0..1（材料化 + 上传合并算；未知时为 null）
  double? progress;

  bool get isActive =>
      state == BackupItemState.pending || state == BackupItemState.uploading;
}

/// 本轮备份的统计。
@immutable
class BackupCounts {
  const BackupCounts({
    required this.pending,
    required this.uploading,
    required this.done,
    required this.failed,
    required this.skipped,
  });

  final int pending;
  final int uploading;
  final int done;
  final int failed;
  final int skipped;

  int get total => pending + uploading + done + failed + skipped;

  /// 已归档的比例（done / 需要传的总数）
  double get ratio {
    final transferable = total - skipped;
    if (transferable <= 0) return 1;
    return done / transferable;
  }
}

/// 去重计划器：本机相册 + 目标相册已有 + 本地账本 → 本轮要处理的项。
class PhotoBackupPlanner {
  const PhotoBackupPlanner._();

  /// 官方相机备份的扫描范围**恒为 DCIM**：`PhotoBackupSettings.java:143-144`
  /// `getBackupSourceMode(){ return BackupSourceMode.DCIM; }`，库侧
  /// `core/BackupSettings.java:144-152` 只在 `isDCIMPath(path)` 时入集，
  /// `PBUtils.java:42-45` 判的就是 `path.contains(DCIMName)`。
  /// 我们的 `relativePath` 来自 MediaStore（`Pictures/Screenshots` 这类），
  /// 所以同一判据 = 大小写不敏感地包含 `DCIM`。
  static bool isDcimAsset(DeviceMediaAsset asset) =>
      asset.relativePath.toUpperCase().contains('DCIM');

  /// [assets] 已按拍摄时间倒序；[doneKeys] 是本地账本；
  /// [remote] 是目标相册现有内容；[includeVideos] = false 时视频直接标跳过；
  /// [dcimOnly] = 只扫 DCIM，范围外的项**不进计划**（官方连枚举都不枚举它们，
  /// 不是"跳过"）。**默认 false** 是为了让这个纯函数保持"不过滤"的中立语义；
  /// **功能的默认值是 DCIM-only**，由 [PhotoBackupSnapshot.dcimOnly]（默认 true）
  /// 传给这里 —— 官方同构在功能层，不在工具层。
  static List<PhotoBackupItem> plan({
    required List<DeviceMediaAsset> assets,
    required Set<String> doneKeys,
    required List<RemotePhotoEntry> remote,
    bool includeVideos = true,
    bool dcimOnly = false,
  }) {
    final remoteKeys = {for (final r in remote) r.key};
    final out = <PhotoBackupItem>[];
    for (final asset in assets) {
      if (dcimOnly && !isDcimAsset(asset)) continue;
      if (!includeVideos && asset.isVideo) {
        out.add(
          PhotoBackupItem(asset, state: BackupItemState.skipped)
            ..skipReason = BackupSkipReason.videoExcluded,
        );
        continue;
      }
      if (doneKeys.contains(asset.stableKey)) {
        out.add(
          PhotoBackupItem(asset, state: BackupItemState.skipped)
            ..skipReason = BackupSkipReason.alreadyDone,
        );
        continue;
      }
      if (remoteKeys.contains(asset.remoteKey)) {
        out.add(
          PhotoBackupItem(asset, state: BackupItemState.skipped)
            ..skipReason = BackupSkipReason.existsOnNas,
        );
        continue;
      }
      out.add(PhotoBackupItem(asset));
    }
    return out;
  }
}

/// 上传一张照片（生产实现**按落点分派**：Photos → `FotoApi.uploadToFolder`，
/// Drive → `DriveApi.uploadPhotoForBackup`；测试里是假的）。
abstract class PhotoBackupUploader {
  /// 返回服务端回的 unit/item/file id（认不出回空串）。失败请抛异常。
  ///
  /// [destination] 必须由队列显式传进来（不是上传器猜）：同一个上传器
  /// 要能同时服务两个落点，落点由**本轮快照**决定。
  Future<String> upload({
    required DeviceMediaAsset asset,
    required String localPath,
    required String targetFolderId,
    required PhotoBackupDestination destination,
    void Function(int sent, int total)? onProgress,
  });
}

/// 内容哈希（官方同构的"抽样 MD5 + 全文件 MD4"）。
///
/// 官方证据（`docs/drive-parity-audit.md:274`）：
///   * **抽样** MD5：`util/MD5Utils.java:31-47` 一次读 `(1000+200)*1024` 字节，
///     文件 ≥ 该长度时只取这段的最后 `204800` 字节；
///   * **全文件** MD4：`PhotoBackupManager.java:298-306` `getMD4Hash(file)`，
///     与服务端 `FileInfo.hash` 比（`FileInfoVo.java:28`）。
///
/// 这里是接口：真实现走 `photo_backup_dedup.dart`（`dart:io` + pointycastle），
/// 纯逻辑单测注入假实现（默认 [NoopPhotoBackupHasher] = 不算哈希）。
abstract class PhotoBackupHasher {
  /// 抽样 MD5（小写 hex）。算不出来回空串。
  Future<String> sampledMd5(String localPath);

  /// 全文件 MD4（小写 hex）。算不出来回空串。
  Future<String> fullMd4(String localPath);
}

/// 不算哈希的实现：账本退化成只用 [DeviceMediaAsset.stableKey]
/// （老行为）。测试与"没装配哈希"的降级路径都用它。
class NoopPhotoBackupHasher implements PhotoBackupHasher {
  const NoopPhotoBackupHasher();

  @override
  Future<String> sampledMd5(String localPath) async => '';

  @override
  Future<String> fullMd4(String localPath) async => '';
}

/// 本地账本 + 用户开关的持久化。
///
/// ⚠️ **这是"某一个落点"的状态**，不是全局状态：`doneKeys` / 目标目录 /
/// 上次完成时间都属于 [destination]。两个落点的游标由 [PhotoBackupStore]
/// 分开存（切换落点绝不复用对方游标）。
class PhotoBackupSnapshot {
  const PhotoBackupSnapshot({
    this.destination = PhotoBackupDestination.synologyPhotos,
    this.doneKeys = const {},
    this.lastFinishedAtMs = 0,
    this.targetFolderId = '',
    this.targetFolderName = '',
    this.includeVideos = true,
    this.wifiOnly = false,
    this.enabled = false,
    this.chargeOnly = false,
    this.screenOffOnly = false,
    this.dcimOnly = true,
    this.uploadQuality = PhotoUploadQuality.original,
    this.structure = DriveBackupStructure.yearAndMonth,
  });

  /// 这个快照属于哪个落点
  final PhotoBackupDestination destination;

  /// 已成功备份的账本 token：`stableKey`，或抽样 MD5 形态
  /// `md5:<hex>|<size>`（官方 `BackupRecordTable._md5` 同构）
  final Set<String> doneKeys;

  /// 上次跑完的时间（毫秒；0 = 从没跑过）
  final int lastFinishedAtMs;

  /// 目标定位串：Photos = `Browse.Folder` 的真实 id；Drive = `/mydrive/...` 路径
  final String targetFolderId;
  final String targetFolderName;

  /// 是否备份视频
  final bool includeVideos;

  /// 仅 Wi-Fi（策略开关，前台队列按它决定要不要暂停；后台交给 WorkManager 约束）
  final bool wifiOnly;

  /// 自动备份开关（用户显式打开才会跑）
  final bool enabled;

  /// **仅充电**（官方 `PhotoBackupSettings.isUploadChargeOnly`，
  /// 默认 false；后台 WorkManager 的 `setRequiresCharging`）
  final bool chargeOnly;

  /// **息屏专注备份**（官方 `SleepBackupUtil` / `activity_sleep_backup`）
  final bool screenOffOnly;

  /// 只扫 DCIM（官方恒为 DCIM；这里做成可配置但**默认 true**）
  final bool dcimOnly;

  /// **P43 上传质量**（原图 / 压缩）。压缩是**纯客户端**行为：服务端
  /// `SYNO.Foto.Upload.so` 的请求里没有任何质量/尺寸参数，所以这里不碰协议。
  final PhotoUploadQuality uploadQuality;

  /// ★ D72 **按日期分目录**（官方 `BackupStructure`：`none` / `year` /
  /// `year_and_month`）。
  ///
  /// 官方出处（Drive 3.9.0-1113 反编译）：
  ///   * `backup/BackupStructure.smali`：三个枚举值 `none` / `year` /
  ///     `year_and_month`，`fromValue` 认不出时**回落 `year_and_month`**；
  ///   * `backup/BackupStructureKt.smali`：`VALUE_NONE="none"` /
  ///     `VALUE_YEAR="year"` / `VALUE_YEAR_AND_MONTH="year_and_month"`；
  ///   * `BackupStructure.getStructure(J)`：`none` → `""`；`year` →
  ///     `DateUtilities.getYearString()`（`"yyyy"`）；`yearAndMonth` →
  ///     `DateUtilities.getYearMonthString()`（`"yyyy/MM"`）；
  ///   * `PhotoBackupManager.smali:1596-1600`：落点目录 =
  ///     `getStructure(asset.getTakenTime())` 拼在设备目录之后
  ///     ⇒ 用**拍摄时间**分段，不是上传时间。
  ///
  /// 默认值就跟官方一致（`year_and_month`）。老 JSON 没这个键也按官方默认。
  final DriveBackupStructure structure;

  bool get hasFinished => lastFinishedAtMs > 0;

  PhotoBackupSnapshot copyWith({
    PhotoBackupDestination? destination,
    Set<String>? doneKeys,
    int? lastFinishedAtMs,
    String? targetFolderId,
    String? targetFolderName,
    bool? includeVideos,
    bool? wifiOnly,
    bool? enabled,
    bool? chargeOnly,
    bool? screenOffOnly,
    bool? dcimOnly,
    PhotoUploadQuality? uploadQuality,
    DriveBackupStructure? structure,
  }) => PhotoBackupSnapshot(
    destination: destination ?? this.destination,
    doneKeys: doneKeys ?? this.doneKeys,
    lastFinishedAtMs: lastFinishedAtMs ?? this.lastFinishedAtMs,
    targetFolderId: targetFolderId ?? this.targetFolderId,
    targetFolderName: targetFolderName ?? this.targetFolderName,
    includeVideos: includeVideos ?? this.includeVideos,
    wifiOnly: wifiOnly ?? this.wifiOnly,
    enabled: enabled ?? this.enabled,
    chargeOnly: chargeOnly ?? this.chargeOnly,
    screenOffOnly: screenOffOnly ?? this.screenOffOnly,
    dcimOnly: dcimOnly ?? this.dcimOnly,
    uploadQuality: uploadQuality ?? this.uploadQuality,
    structure: structure ?? this.structure,
  );

  Map<String, dynamic> toJson() => {
    'destination': destination.id,
    'done': doneKeys.toList(),
    'last_finished_at': lastFinishedAtMs,
    'target_folder_id': targetFolderId,
    'target_folder_name': targetFolderName,
    'include_videos': includeVideos,
    'wifi_only': wifiOnly,
    'enabled': enabled,
    'charge_only': chargeOnly,
    'screen_off_only': screenOffOnly,
    'dcim_only': dcimOnly,
    'upload_quality': uploadQuality.id,
    'backup_structure': structure.value,
  };

  static PhotoBackupSnapshot fromJson(Map<String, dynamic> j) =>
      PhotoBackupSnapshot(
        // 老 JSON 没有这个键 → synologyPhotos（老游标当初就写在 Photos 上）
        destination: PhotoBackupDestination.fromId(j['destination'] as String?),
        doneKeys: (j['done'] as List?)?.map((e) => '$e').toSet() ?? const {},
        lastFinishedAtMs: (j['last_finished_at'] as num?)?.toInt() ?? 0,
        targetFolderId: '${j['target_folder_id'] ?? ''}',
        targetFolderName: '${j['target_folder_name'] ?? ''}',
        includeVideos: j['include_videos'] != false,
        wifiOnly: j['wifi_only'] == true,
        enabled: j['enabled'] == true,
        chargeOnly: j['charge_only'] == true,
        screenOffOnly: j['screen_off_only'] == true,
        // 老 JSON 没有这个键 → true（官方恒 DCIM）
        dcimOnly: j['dcim_only'] != false,
        // 老 JSON 没有这个键 → original（零改动，最安全）
        uploadQuality: PhotoUploadQuality.fromId(j['upload_quality'] as String?),
        // 老 JSON 没有这个键 → 官方默认 year_and_month
        structure: DriveBackupStructure.fromValue(
          j['backup_structure'] as String?,
        ),
      );

  String encode() => jsonEncode(toJson());

  /// 脏数据一律当"什么都没记过"，别让它把备份功能整个卡死。
  static PhotoBackupSnapshot decode(String? raw) {
    if (raw == null || raw.isEmpty) return const PhotoBackupSnapshot();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const PhotoBackupSnapshot();
      return fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      return const PhotoBackupSnapshot();
    }
  }
}

/// 账本/开关的读写。
///
/// **落点隔离**是这一层的责任：`save(s)` 只写 `s.destination` 那一份游标，
/// 另一个落点的游标原封不动；切换落点时用 [loadFor] 取那个落点自己的游标
/// （全局选项沿用）。
abstract class PhotoBackupStore {
  Future<PhotoBackupSnapshot> load();

  Future<void> save(PhotoBackupSnapshot snapshot);

  /// 读另一个落点的游标（不落盘、不改动已保存的数据）。
  /// 该落点还没有记录时：游标清空、**全局选项沿用**当前快照。
  Future<PhotoBackupSnapshot> loadFor(PhotoBackupDestination destination);
}

/// 内存实现（离线测试用，也给"没装配持久化"的降级路径兜底）。
///
/// 和真实实现一样**按落点分桶**：同一个实例里存两张游标，互不覆盖。
class InMemoryPhotoBackupStore implements PhotoBackupStore {
  InMemoryPhotoBackupStore([
    PhotoBackupSnapshot snapshot = const PhotoBackupSnapshot(),
  ]) : _selected = snapshot.destination {
    _byDestination[snapshot.destination] = snapshot;
  }

  final Map<PhotoBackupDestination, PhotoBackupSnapshot> _byDestination = {};

  /// 当前选中的落点（跟最后一次 save/loadFor 走）
  PhotoBackupDestination _selected;

  /// 记了几次写（测试断言"状态有没有落盘"）
  int saveCount = 0;

  @override
  Future<PhotoBackupSnapshot> load() async =>
      _byDestination[_selected] ?? PhotoBackupSnapshot(destination: _selected);

  @override
  Future<PhotoBackupSnapshot> loadFor(
    PhotoBackupDestination destination,
  ) async {
    final options = await load(); // 切换前的快照：全局选项的来源
    _selected = destination;
    final existing = _byDestination[destination];
    if (existing != null) return existing;
    return options.copyWith(
      destination: destination,
      doneKeys: const {},
      lastFinishedAtMs: 0,
      targetFolderId: '',
      targetFolderName: '',
    );
  }

  @override
  Future<void> save(PhotoBackupSnapshot snapshot) async {
    _byDestination[snapshot.destination] = snapshot;
    _selected = snapshot.destination;
    saveCount++;
  }
}

/// 上传队列（受限并发 / 可暂停 / 可取消 / 失败隔离 + 自动重试一次）。
///
/// 状态机：
/// ```
/// pending ──(pump)──> uploading ──ok──> done
///    ↑                    └──fail──> pending(还有重试次数) | failed
///    └── retryFailed() ────────────────────────────┘
/// pause/resume 只影响"要不要继续调度"，不影响已在传的那几张；
/// cancel 把还没开始的全标成 failed(cancelled)，在传的让它自然结束。
/// ```
class PhotoBackupQueue extends ChangeNotifier {
  PhotoBackupQueue({
    required DeviceMediaLibrary media,
    required PhotoBackupUploader uploader,
    required PhotoBackupStore store,
    this.maxConcurrent = 2,
    this.maxAttempts = 2,
    PhotoBackupSnapshot snapshot = const PhotoBackupSnapshot(),
    PhotoBackupHasher hasher = const NoopPhotoBackupHasher(),
    Map<String, String> remoteHashes = const {},
    Future<bool> Function()? connectionGate,
    PhotoUploadCompressor? compressor,
  }) : _compressor = compressor,
       _media = media,
       _connectionGate = connectionGate,
       _uploader = uploader,
       _store = store,
       _snapshot = snapshot,
       _hasher = hasher,
       _remoteHashes = remoteHashes;

  /// P43：非空且档位≠原图时，上传前先压缩（**去重哈希仍用原文件**）。
  final PhotoUploadCompressor? _compressor;

  final DeviceMediaLibrary _media;
  final PhotoBackupUploader _uploader;
  final PhotoBackupStore _store;

  /// 内容哈希（抽样 MD5 / 全文件 MD4）；默认不算（老行为）。
  final PhotoBackupHasher _hasher;

  /// 服务端已有的**内容哈希**：`asset.remoteKey`（`name|size`）→ 服务端哈希。
  ///
  /// 官方同构：`PhotoBackupManager.java:298-306` 把本机文件的**全文件 MD4**
  /// 与服务端 `FileInfo.hash` 比，相同就不传。我们只在"同名同大小"的条目上
  /// 才算本机 MD4（贵，且只有这种情况才需要区分内容）。
  final Map<String, String> _remoteHashes;

  /// ★ D70（第 103 轮）：**运行中网络门禁**。
  ///
  /// 官方行为（`drive-parity-audit.md:270` 附近，D70 行）：仅 Wi-Fi 备份
  /// **每轮重算并暂停/恢复** —— WorkManager 的 `UNMETERED` 约束只管
  /// **后台任务起跑**；前台正在跑的队列在"切到计费网络"时也要停。
  /// 旧实现只做一次性门禁（起跑前查一次）⇒ 运行中切 4G 继续传。
  ///
  /// 注入 `connectionGate`（回 `true` = 当前网络可传）后：
  /// * 每次调度下一项前先问一次；
  /// * 不可传 ⇒ 自动 [pause]（用户/系统侧网络恢复后 [resume] 即续跑）。
  final Future<bool> Function()? _connectionGate;

  /// 并发上限（**官方相机备份恒为 1**：`PhotoBackupManager.java:493`
  /// `ThreadPoolExecutor(1,1,…)` + `BackupExecutor.java:112-146` 串行 `peek()`；
  /// 见 `docs/drive-parity-audit.md:278`。调用方应传 1。）
  final int maxConcurrent;

  /// 单项最多试几次（>1 表示失败后自动再试）
  final int maxAttempts;

  PhotoBackupSnapshot _snapshot;

  final List<PhotoBackupItem> _items = [];
  List<PhotoBackupItem> get items => List.unmodifiable(_items);

  bool _running = false;
  bool _paused = false;
  bool _cancelled = false;
  int _active = 0;

  /// 收尾通知（跑完/取消后调一次），给界面弹一句总结
  VoidCallback? onFinished;

  bool get running => _running;
  bool get paused => _paused;
  PhotoBackupSnapshot get snapshot => _snapshot;

  String get targetFolderId => _snapshot.targetFolderId;
  String get targetFolderName => _snapshot.targetFolderName;

  BackupCounts get counts => BackupCounts(
    pending: _items.where((i) => i.state == BackupItemState.pending).length,
    uploading: _items.where((i) => i.state == BackupItemState.uploading).length,
    done: _items.where((i) => i.state == BackupItemState.done).length,
    failed: _items.where((i) => i.state == BackupItemState.failed).length,
    skipped: _items.where((i) => i.state == BackupItemState.skipped).length,
  );

  List<PhotoBackupItem> get failedItems =>
      _items.where((i) => i.state == BackupItemState.failed).toList();

  /// 装上本轮计划（会清掉上一轮）。不自动开跑。
  void load(List<PhotoBackupItem> items) {
    _items
      ..clear()
      ..addAll(items);
    _cancelled = false;
    _paused = false;
    _active = 0;
    _running = false;
    notifyListeners();
  }

  /// 开始跑（幂等：已在跑就什么都不做）。
  void start() {
    if (_running && !_paused) return;
    if (_items.every((i) => !i.isActive)) {
      // 没得传了：直接进入收尾（要先把 running 立起来，否则 _finish 会空转）
      _running = true;
      _finish();
      return;
    }
    _cancelled = false;
    _paused = false;
    _running = true;
    notifyListeners();
    _pump();
  }

  void pause() {
    if (!_running || _paused) return;
    _paused = true;
    notifyListeners();
  }

  void resume() {
    if (!_running || !_paused) return;
    _paused = false;
    notifyListeners();
    _pump();
  }

  /// 取消：还没开始的标失败（`cancelled`），在传的让它结束。
  void cancel() {
    if (!_running) return;
    _cancelled = true;
    for (final item in _items) {
      if (item.state == BackupItemState.pending) {
        item.state = BackupItemState.failed;
        item.error = 'cancelled';
        item.cause = null;
      }
    }
    notifyListeners();
    if (_active == 0) _finish();
  }

  /// 手动重试失败项（清掉失败计数再排一次）。
  void retryFailed() {
    var any = false;
    for (final item in _items) {
      if (item.state == BackupItemState.failed) {
        item.state = BackupItemState.pending;
        item.attempts = 0;
        item.error = null;
        item.cause = null;
        any = true;
      }
    }
    if (!any) return;
    _cancelled = false;
    _running = true;
    _paused = false;
    notifyListeners();
    _pump();
  }

  /// 更新并落盘本地账本/开关（目标相册、仅 Wi-Fi 之类的用户选择）。
  Future<void> updateSnapshot(PhotoBackupSnapshot next) async {
    _snapshot = next;
    notifyListeners();
    await _store.save(_snapshot);
  }

  Future<void> _pump() async {
    if (_cancelled) {
      if (_active == 0) _finish();
      return;
    }
    if (_paused) {
      // 暂停只表示"不再调度新任务"；还有待传的项时**不能**收尾，
      // 否则 resume() 会因为 running=false 而失效。
      if (_active == 0 && _items.every((i) => !i.isActive)) _finish();
      return;
    }
    // ★ D70：运行中网络门禁 —— wifiOnly 且当前网络不合适 ⇒ 自动暂停。
    //   第一次实现把"查 gate"放在派发循环里 return/resume，
    //   结果 ok 时也 return ⇒ resume ⇒ 再 return 的**死循环**，永远派不出任务
    //   （被本文件新增的 D70 用例当场抓出来）。正确做法：**先 await gate，
    //   再进派发循环**。
    final gate = _connectionGate;
    if (_snapshot.wifiOnly && gate != null) {
      bool ok;
      try {
        ok = await gate();
      } catch (_) {
        ok = true; // 门禁本身坏了不该卡死备份（与"没装配 gate"同口径）
      }
      if (!_running || _cancelled) return;
      if (!ok) {
        _paused = true;
        notifyListeners();
        return;
      }
    }
    while (_active < maxConcurrent) {
      final next = _items
          .where((i) => i.state == BackupItemState.pending)
          .firstOrNull;
      if (next == null) break;
      _run(next);
    }
    if (_active == 0 && _items.every((i) => !i.isActive)) _finish();
  }

  void _run(PhotoBackupItem item) {
    _active++;
    item.state = BackupItemState.uploading;
    item.progress = null;
    notifyListeners();
    // 不 await：并发由 _active / maxConcurrent 控制
    _uploadOne(item).whenComplete(() {
      _active--;
      notifyListeners();
      _pump();
    });
  }

  /// 账本 token：抽样 MD5 优先（改名也能认出来），算不出哈希时退回落
  /// `stableKey`。`|<size>` 后缀是**必须**的：官方抽样只取 1.2MB 窗口的
  /// 最后 200KB，不同文件理论上可能撞哈希，带上大小把碰撞面收窄。
  static String ledgerToken(
    DeviceMediaAsset asset, {
    required String sampledMd5,
  }) => sampledMd5.isEmpty ? asset.stableKey : 'md5:$sampledMd5|${asset.size}';

  Future<void> _uploadOne(PhotoBackupItem item) async {
    item.attempts++;
    try {
      final path = await _media.materialize(item.asset);
      if (path == null || path.isEmpty) {
        throw StateError('本机文件打不开');
      }
      // ① 抽样 MD5 去重（官方 `MD5Utils.java:31-47` 的 (1000+200)KB 形态）：
      //    本机另一条记录（可能已被改名/移动）内容相同就不重复传。
      final sampled = await _hasher.sampledMd5(path);
      final token = ledgerToken(item.asset, sampledMd5: sampled);
      if (sampled.isNotEmpty && _snapshot.doneKeys.contains(token)) {
        item.state = BackupItemState.skipped;
        item.skipReason = BackupSkipReason.duplicateContent;
        item.progress = 1;
        return;
      }
      // ② 服务端内容哈希（官方全文件 MD4 vs `FileInfo.hash`）：同名同大小时
      //    才算本机 MD4；服务端没回 hash 就跳过这一步（best-effort）。
      final remoteHash = _remoteHashes[item.asset.remoteKey];
      if (remoteHash != null && remoteHash.isNotEmpty) {
        final localMd4 = await _hasher.fullMd4(path);
        if (localMd4.isNotEmpty &&
            localMd4.toLowerCase() == remoteHash.toLowerCase()) {
          item.state = BackupItemState.skipped;
          item.skipReason = BackupSkipReason.existsOnNas;
          item.progress = 1;
          _snapshot = _snapshot.copyWith(
            doneKeys: {..._snapshot.doneKeys, item.asset.stableKey, token},
          );
          await _store.save(_snapshot);
          return;
        }
      }
      // P43：压缩后的**待上传路径**（原图档 / 不支持格式 = 原路径）。
      // 注意去重哈希（抽样 MD5 / 全文件 MD4）用的是**原文件** —— 压缩会改变字节。
      var uploadPath = path;
      final compressor = _compressor;
      if (compressor != null &&
          _snapshot.uploadQuality != PhotoUploadQuality.original) {
        uploadPath = await compressor.compress(
          localPath: path,
          quality: _snapshot.uploadQuality,
        );
      }
      await _uploader.upload(
        asset: item.asset,
        localPath: uploadPath,
        targetFolderId: _snapshot.targetFolderId,
        destination: _snapshot.destination,
        onProgress: (sent, total) {
          if (total > 0) {
            item.progress = (sent / total).clamp(0, 1);
            notifyListeners();
          }
        },
      );
      item.state = BackupItemState.done;
      item.error = null;
      item.cause = null;
      item.progress = 1;
      // 两个 token 都记：`stableKey` 让下次**规划期**就能跳过（零哈希开销），
      // 抽样 MD5 让"同内容改了名"也能跳过（官方 `_md5` 列同构）。
      _snapshot = _snapshot.copyWith(
        doneKeys: {..._snapshot.doneKeys, item.asset.stableKey, token},
      );
      await _store.save(_snapshot);
    } catch (err) {
      // 失败隔离：这一张失败不影响别人；还有重试次数就回 pending 再排一次
      if (item.attempts < maxAttempts) {
        item.state = BackupItemState.pending;
      } else {
        item.state = BackupItemState.failed;
      }
      item.error = userFacingError(err);
      item.cause = err;
    }
  }

  void _finish() {
    if (!_running) return;
    _running = false;
    _paused = false;
    if (!_cancelled) {
      _snapshot = _snapshot.copyWith(
        lastFinishedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      // 收尾这最后一次写不阻塞界面
      _store.save(_snapshot);
    }
    notifyListeners();
    onFinished?.call();
  }
}
