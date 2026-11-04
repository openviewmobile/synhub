// 相册备份的**持久化**：选项走既有键值表，游标走 v12 新增的每落点表。
//
// 为什么分成两半：
//   * **选项**（是否备份视频 / 仅 Wi-Fi / 仅充电 / 息屏 / 只扫 DCIM / 自动开关 /
//     当前选中的落点）是**全局**的，用户切落点不该把它们重置。它们继续放在老的
//     `photo_backup_state` 这个 JSON 里（键值表 `key_value_rows`，schema 不动）。
//   * **游标**（doneKeys / 上次完成时间 / 目标目录）是**每落点**的。切到 Drive
//     后如果还用 Photos 的 doneKeys，就会认为"都传过了"而一张都不传（反向亦然）。
//     所以它落在 v12 新增的 `photo_backup_target_rows`（主键 = 落点）。
//
// **向前兼容（老库 + 老数据）**：
//   * 表：`ChatDatabase` v11 → v12 只是 `createTable`，老库一行数据都不动；
//   * 数据：老 JSON 里的 `done` / `target_folder_id` / `last_finished_at` 属于
//     Photos 落点（历史上我们只备份到 Photos），首次读取时**补种**进 Photos 那一行
//     （[_seedFromLegacy]）。补种失败也还有回落：行不存在时 [load] 直接用老 JSON
//     里的游标，绝不因为迁移把用户的账本清零。
import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import '../../core/settings/app_settings.dart' show SettingsService;
import '../../data/local/database.dart';
import 'photo_backup_queue.dart';

/// Drift 生产实现。
class DriftPhotoBackupStore implements PhotoBackupStore {
  DriftPhotoBackupStore(this._settings, this._db);

  final SettingsService _settings;
  final ChatDatabase _db;

  @override
  Future<PhotoBackupSnapshot> load() async {
    final options = PhotoBackupSnapshot.decode(
      await _settings.photoBackupRaw(),
    );
    await _seedFromLegacy(options);
    return _merge(options, options.destination);
  }

  @override
  Future<PhotoBackupSnapshot> loadFor(
    PhotoBackupDestination destination,
  ) async {
    final options = PhotoBackupSnapshot.decode(
      await _settings.photoBackupRaw(),
    );
    await _seedFromLegacy(options);
    return _merge(options, destination);
  }

  @override
  Future<void> save(PhotoBackupSnapshot snapshot) async {
    // 先写游标行（真值），再写选项 JSON：任何一步失败都不会出现
    // "选项更新了但游标丢了"。
    await _db
        .into(_db.photoBackupTargetRows)
        .insertOnConflictUpdate(
          PhotoBackupTargetRowsCompanion.insert(
            destination: snapshot.destination.id,
            doneKeys: Value(jsonEncode(snapshot.doneKeys.toList())),
            lastFinishedAt: Value(snapshot.lastFinishedAtMs),
            targetRef: Value(snapshot.targetFolderId),
            targetName: Value(snapshot.targetFolderName),
            updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
          ),
        );
    // 选项 JSON 里**清空游标字段**：游标只有表里那一份真值，
    // 防止两处不一致（老格式仍可读，见 [_seedFromLegacy]）。
    await _settings.setPhotoBackupRaw(
      snapshot
          .copyWith(
            doneKeys: const {},
            lastFinishedAtMs: 0,
            targetFolderId: '',
            targetFolderName: '',
          )
          .encode(),
    );
  }

  /// 选项 + 指定落点的游标行 → 一个快照。
  Future<PhotoBackupSnapshot> _merge(
    PhotoBackupSnapshot options,
    PhotoBackupDestination destination,
  ) async {
    final row = await (_db.select(
      _db.photoBackupTargetRows,
    )..where((t) => t.destination.equals(destination.id))).getSingleOrNull();
    if (row == null) {
      // 这个落点还没有行：
      //   * 就是"选中的那个" → 老 JSON 里可能还带着老游标，原样用（兼容）；
      //   * 别的落点 → 游标清空，但全局选项沿用。
      if (options.destination == destination) return options;
      return options.copyWith(
        destination: destination,
        doneKeys: const {},
        lastFinishedAtMs: 0,
        targetFolderId: '',
        targetFolderName: '',
      );
    }
    return options.copyWith(
      destination: destination,
      doneKeys: _decodeKeys(row.doneKeys),
      lastFinishedAtMs: row.lastFinishedAt,
      targetFolderId: row.targetRef,
      targetFolderName: row.targetName,
    );
  }

  /// 把老 JSON（v11 及以前）里的游标补种到它所属落点的那一行。
  ///
  /// 幂等：行已存在就什么都不做；老 JSON 里游标本来就是空的也直接返回。
  /// 落点取 `options.destination`（老 JSON 没写 → 默认 Photos，与历史一致）。
  Future<void> _seedFromLegacy(PhotoBackupSnapshot legacy) async {
    final hasCursor =
        legacy.doneKeys.isNotEmpty ||
        legacy.targetFolderId.isNotEmpty ||
        legacy.lastFinishedAtMs > 0;
    if (!hasCursor) return;
    final existing =
        await (_db.select(_db.photoBackupTargetRows)
              ..where((t) => t.destination.equals(legacy.destination.id)))
            .getSingleOrNull();
    if (existing != null) return;
    await _db
        .into(_db.photoBackupTargetRows)
        .insertOnConflictUpdate(
          PhotoBackupTargetRowsCompanion.insert(
            destination: legacy.destination.id,
            doneKeys: Value(jsonEncode(legacy.doneKeys.toList())),
            lastFinishedAt: Value(legacy.lastFinishedAtMs),
            targetRef: Value(legacy.targetFolderId),
            targetName: Value(legacy.targetFolderName),
            updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
          ),
        );
  }

  static Set<String> _decodeKeys(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const {};
      return {for (final e in decoded) '$e'};
    } catch (_) {
      return const {};
    }
  }
}
