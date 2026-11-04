// 相册「释放手机空间」的**编排层**（界面与用例共用的唯一入口）。
//
// 三件事：
//   ① **核对**（[scan]）：权限 → 枚举本机相册 → 读备份账本 → **只读**拉 NAS 清单
//      → [PhotoFreeUpPlanner] 算出"可安全删除"的候选与可释放字节；
//   ② **执行**（[run]）：把候选交给平台删除能力，**平台必须弹系统确认框**；
//      把平台回的真实结局逐项落到 [FreeUpEntry.outcome]；
//   ③ **降级**（[openSystemSettings] / [clearAppCache]）。
//
// ## 安全不变量（用例逐条钉死）
//
//   1. **未备份的照片绝不进候选**（候选只在 [PhotoFreeUpPlanner] 里产生）；
//   2. **用户拒绝系统确认时不删任何文件**（`deletedUris` 为空 → 全部标 `kept`）；
//   3. **平台通道不可用时给人话说明，绝不假装成功**（走
//      [FreeUpRunOutcome.unsupported]，`deleted` 恒为 0）。
//
// ## §5.1 合规：本层**不对 NAS 发任何写操作**
//
// 只读调用：
//   * [PhotoBackupTargets.remoteEntries]（内部是 `Browse.Item/list` /
//     Drive `list`），而且**只用已保存的落点**；
//   * ⚠️ **绝不**调 [PhotoBackupTargets.ensureTarget] —— 那个会在目标不存在时
//     建目录（写操作）。所以没设过目标的用户只按本机账本判断（候选更少，保守）。
import 'package:flutter/foundation.dart';

import '../../data/media/device_media_library.dart';
import 'photo_backup_queue.dart';
import 'photo_backup_target.dart';
import 'photo_free_up_plan.dart';

/// 页面的阶段。
enum FreeUpPhase { idle, scanning, ready, deleting }

/// 一次释放尝试的结局（**只有 [deleted] 才算真释放了空间**）。
enum FreeUpRunOutcome {
  /// 系统确认后确实删掉了若干本地文件
  deleted,

  /// 用户拒绝了系统确认框 → 一项都没删
  rejected,

  /// 平台不支持由应用代删（系统版本太低 / 没装桥）→ 一项都没删
  unsupported,

  /// 用户确认了但一项都没删成（权限被回收 / 文件已不在…）
  failed,

  /// 根本没有候选
  nothing,
}

/// 一次释放尝试给界面看的报告。
@immutable
class FreeUpRunReport {
  const FreeUpRunReport({
    required this.outcome,
    required this.requested,
    required this.deleted,
    required this.failed,
    required this.bytesDeleted,
    this.support = MediaDeleteSupport.unsupported,
  });

  final FreeUpRunOutcome outcome;
  final int requested;

  /// 真的删掉的张数（[FreeUpRunOutcome.deleted] 之外恒为 0）
  final int deleted;
  final int failed;

  /// 真的释放掉的字节数
  final int bytesDeleted;
  final MediaDeleteSupport support;

  /// 没能删掉的张数
  int get kept => requested - deleted;

  bool get anyDeleted => deleted > 0;
}

/// 扫描 + 执行的编排器。
class PhotoFreeUpController extends ChangeNotifier {
  PhotoFreeUpController({
    required DeviceMediaLibrary media,
    required DeviceMediaDeleter? deleter,
    required PhotoBackupStore store,
    required PhotoBackupTargets targets,
    this.assetLimit = 2000,
  }) : _media = media,
       _deleter = deleter,
       _store = store,
       _targets = targets;

  final DeviceMediaLibrary _media;
  final DeviceMediaDeleter? _deleter;
  final PhotoBackupStore _store;
  final PhotoBackupTargets _targets;

  /// 一次枚举本机相册的上限（与相机备份同一量级）
  final int assetLimit;

  FreeUpPhase _phase = FreeUpPhase.idle;
  FreeUpPhase get phase => _phase;

  List<FreeUpEntry> _entries = const [];
  List<FreeUpEntry> get entries => List.unmodifiable(_entries);

  MediaPermission _permission = MediaPermission.denied;
  MediaPermission get permission => _permission;

  MediaDeleteSupport _support = MediaDeleteSupport.unsupported;
  MediaDeleteSupport get support => _support;

  /// 有没有装配"会动用户照片"的删除能力（测试/桌面没有 → 走降级）
  bool get hasDeleter => _deleter != null;

  int _scannedCount = 0;
  int get scannedCount => _scannedCount;

  int _keptCount = 0;

  /// 因"备份未确认"而**明确保留**的张数（绝不删）
  int get keptCount => _keptCount;

  /// 本轮是否成功读到了 NAS 清单
  bool _remoteChecked = false;
  bool get remoteChecked => _remoteChecked;

  /// 本机备份账本里记了多少条（0 = 从没备份过 / 换过设备）
  int _ledgerSize = 0;
  int get ledgerSize => _ledgerSize;

  /// NAS 还没连上（按落点可用性判断，只读）
  bool _notConnected = false;
  bool get notConnected => _notConnected;

  /// 稳定标记：`permission` / `error`；null = 没出问题
  String? _scanError;
  String? get scanError => _scanError;

  Object? _scanCause;
  Object? get scanCause => _scanCause;

  FreeUpRunReport? _lastRun;
  FreeUpRunReport? get lastRun => _lastRun;

  bool _cacheCleared = false;
  bool get cacheCleared => _cacheCleared;

  bool get scanning => _phase == FreeUpPhase.scanning;
  bool get deleting => _phase == FreeUpPhase.deleting;

  /// **还没被删掉**的候选可释放字节数（删过的要从"可释放"里去掉）
  int get reclaimableBytes => _entries
      .where((e) => e.outcome != FreeUpEntryOutcome.deleted)
      .fold(0, (sum, e) => sum + (e.asset.size < 0 ? 0 : e.asset.size));

  int get reclaimableCount =>
      _entries.where((e) => e.outcome != FreeUpEntryOutcome.deleted).length;

  int get deletedCount =>
      _entries.where((e) => e.outcome == FreeUpEntryOutcome.deleted).length;

  bool get isEmpty => _entries.isEmpty && _scanError == null;

  /// ① 核对：哪些本地照片已经在 NAS 上备份过了。
  Future<void> scan({bool interactive = true}) async {
    _phase = FreeUpPhase.scanning;
    _scanError = null;
    _scanCause = null;
    _lastRun = null;
    notifyListeners();
    try {
      _permission = await _media.ensurePermission(interactive: interactive);
      if (!_permission.isUsable) {
        // 部分授权也只看到"选中的那几张" → 不能据此判断整库，按"读不到"处理
        _entries = const [];
        _scannedCount = 0;
        _keptCount = 0;
        _phase = FreeUpPhase.ready;
        notifyListeners();
        return;
      }
      final snapshot = await _store.load();
      _ledgerSize = snapshot.doneKeys.length;
      final assets = await _media.list(
        includeVideos: snapshot.includeVideos,
        limit: assetLimit,
      );
      // ⚠️ 只读：**只**用已保存的落点；没设过就只按本机账本判断（不建目录）
      final info = _targets.info(snapshot.destination);
      _notConnected = info.gate == PhotoBackupTargetGate.notConnected;
      final hasTarget = snapshot.targetFolderId.isNotEmpty;
      final remote = (hasTarget && info.isUsable)
          ? await _targets.remoteEntries(
              snapshot.destination,
              ref: snapshot.targetFolderId,
            )
          : const <RemotePhotoEntry>[];
      _remoteChecked = hasTarget && info.isUsable;
      final plan = PhotoFreeUpPlanner.plan(
        assets: assets,
        doneKeys: snapshot.doneKeys,
        remote: remote,
        includeVideos: snapshot.includeVideos,
        dcimOnly: snapshot.dcimOnly,
      );
      _entries = plan.entries;
      _scannedCount = plan.scannedCount;
      _keptCount = plan.keptCount;
      _support = _deleter == null
          ? MediaDeleteSupport.unsupported
          : await _deleter.deleteSupport();
    } catch (err) {
      _entries = const [];
      _scannedCount = 0;
      _keptCount = 0;
      _scanError = 'error';
      _scanCause = err;
    }
    _phase = FreeUpPhase.ready;
    notifyListeners();
  }

  /// ② 执行：把候选交给平台删除能力（**平台必须弹系统确认框**）。
  ///
  /// 无论结局如何，[FreeUpEntry.outcome] 都只反映**平台回的真实结果**：
  /// 拒绝确认 / 不支持 / 失败时全部标 `kept`，[FreeUpRunReport.deleted] 为 0。
  Future<FreeUpRunReport> run() async {
    if (_phase == FreeUpPhase.deleting) {
      return _lastRun ??
          const FreeUpRunReport(
            outcome: FreeUpRunOutcome.nothing,
            requested: 0,
            deleted: 0,
            failed: 0,
            bytesDeleted: 0,
          );
    }
    final pending = _entries
        .where((e) => e.outcome != FreeUpEntryOutcome.deleted)
        .toList();
    if (pending.isEmpty) {
      return _finish(
        const FreeUpRunReport(
          outcome: FreeUpRunOutcome.nothing,
          requested: 0,
          deleted: 0,
          failed: 0,
          bytesDeleted: 0,
        ),
      );
    }
    final deleter = _deleter;
    if (deleter == null) {
      // **没有删除能力**：一项都不动，如实回"不支持"
      for (final e in pending) {
        e.outcome = FreeUpEntryOutcome.kept;
      }
      return _finish(
        FreeUpRunReport(
          outcome: FreeUpRunOutcome.unsupported,
          requested: pending.length,
          deleted: 0,
          failed: pending.length,
          bytesDeleted: 0,
        ),
      );
    }
    _phase = FreeUpPhase.deleting;
    notifyListeners();
    MediaDeleteOutcome result;
    try {
      result = await deleter.requestDelete([for (final e in pending) e.asset]);
    } catch (err) {
      // 平台侧炸了也算"什么都没删"（**绝不假装成功**）
      result = MediaDeleteOutcome(
        support: MediaDeleteSupport.unsupported,
        confirmed: false,
        requested: pending.length,
        error: '$err',
      );
    }
    final deletedUris = result.deletedUris.toSet();
    var deleted = 0;
    var bytes = 0;
    for (final e in pending) {
      if (result.confirmed && deletedUris.contains(e.asset.uri)) {
        e.outcome = FreeUpEntryOutcome.deleted;
        deleted++;
        bytes += e.asset.size < 0 ? 0 : e.asset.size;
      } else {
        e.outcome = FreeUpEntryOutcome.kept;
      }
    }
    final outcome = result.unsupported
        ? FreeUpRunOutcome.unsupported
        : deleted > 0
        ? FreeUpRunOutcome.deleted
        : result.confirmed
        ? FreeUpRunOutcome.failed
        : FreeUpRunOutcome.rejected;
    return _finish(
      FreeUpRunReport(
        outcome: outcome,
        requested: pending.length,
        deleted: deleted,
        failed: pending.length - deleted,
        bytesDeleted: bytes,
        support: result.support,
      ),
    );
  }

  FreeUpRunReport _finish(FreeUpRunReport report) {
    _lastRun = report;
    _phase = FreeUpPhase.ready;
    notifyListeners();
    return report;
  }

  /// ③ 降级：跳系统设置让用户手动清理。打不开回 false（**不假装跳过去了**）。
  Future<bool> openSystemSettings() async {
    final deleter = _deleter;
    if (deleter == null) return false;
    return deleter.openSystemSettings();
  }

  /// 清掉 App 上传时落下的临时副本（**不是**用户相册里的照片）。尽力而为。
  Future<bool> clearAppCache() async {
    final deleter = _deleter;
    if (deleter == null) return false;
    final ok = await deleter.clearUploadCache();
    _cacheCleared = ok;
    notifyListeners();
    return ok;
  }
}
