// 相册两个**全局**（非空间前缀）只读接口的 VO：
//   * `SYNO.Foto.BackgroundTask.Info:list_user_task`（**v1**）—— 用户后台任务；
//   * `SYNO.Foto.Migration:get_status`（**v1**）—— PhotoStation/Moments 迁移状态。
//
// 这两个 API **没有 `SYNO.FotoTeam.` 对应体**（`/tmp/spk/export_SynologyPhotos/
// usr/webapi/SYNO.Foto.lib` 里只有 `SYNO.Foto.BackgroundTask.Info` 与
// `SYNO.Foto.Migration`；`SYNO.FotoTeam.*` 里只有 `BackgroundTask.File`），
// 所以**不套个人/共享空间前缀**（见 `foto_g6_api.dart`）。
//
// ## 权威事实（逐条可查）
//
// ### `BackgroundTask.Info:list_user_task`
// * 方法表：`SYNO.Foto.lib` 逐字 `minVersion: 1, maxVersion: 1`，
//   `methods: {1:[abort_task, clear_completed_task, get_error_detail,
//   get_status, list_user_task]}`，`allowUser` 含普通用户。
// * **条目字段**：官方 Web 前端（`/tmp/spk/export_SynologyPhotos/ui/
//   react_bundle.js`，任务模块的 `listUserTask()` 映射函数）逐字：
//   ```js
//   ts = function (e) {
//     var t = e.target_folder, n = ta(e.extra_info);
//     return { taskType: BACKGROUND, id: e.id, library: t.owner_user_id,
//              targetFolderId: t.id, operationType: e.operation,
//              status: e.status, numTotal: e.total,
//              numCompletion: e.completion, numError: e.error,
//              numSkip: e.skip, numOverwrite: e.overwrite,
//              creationTime: e.create_time,
//              sourceFolderIds: n.sourceFolderIds || [], sourceLibrary: n.sourceLibrary };
//   }
//   ```
// * **状态枚举**（同 bundle 的 `Object.freeze`）：`waiting` / `processing` /
//   `aborting` / `done`；`operation` 枚举：`copy` / `move`；
//   重复处理枚举：`skip` / `overwrite`。
// * **真机只读实测**（`docs/g6-api-probe-facts.md:38`）：无参调用 →
//   `{"list": []}` ⇒ **无必填参数**；本账号没有后台任务
//   （**空态是这台 NAS 上的真实表现**）。
//
// ### `Migration:get_status`
// * 方法表：`SYNO.Foto.lib` 逐字 `minVersion: 1, maxVersion: 1`，
//   `methods: {1:[get_status]}`。
// * **回包字段**：`usr/lib/libwebapi-impl-migration.so` 的字符串常量
//   `current` / `status` / `title_key` / `total`。
// * **状态字面值**（同 `.so`）：`done` / `running`
//   （另有阶段名 `migration_finished` / `migrating_photo_station` /
//   `migrating_moments_personal` 出现在 `synofoto-bin-migrate-tool`，
//   作为 `title_key` 的候选）。
// * **真机只读实测**（`docs/g6-api-probe-facts.md:39`）：
//   `{"current": 2, "status": "done", "title_key": "", "total": 0}`
//   ⇒ **无必填参数**；`status` 是**枚举串**（不是布尔）。
//
// ## 纪律
//
// * `id` / `target_folder.id` / `owner_user_id` 都是**内部 id**，
//   **绝不上屏**（只在 Key / 断言 / `toString()` 里）；
// * `status` / `operation` / `title_key` 都是**枚举串**：只映射到 ARB key，
//   **认不出来的取值一律不进界面**（`null` → UI 不画那一行），
//   绝不把服务端原文透给用户。

/// 一个用户后台任务（`BackgroundTask.Info:list_user_task` 条目）。
class FotoBackgroundTaskDto {
  const FotoBackgroundTaskDto({
    required this.id,
    required this.operation,
    required this.status,
    required this.total,
    required this.completion,
    required this.error,
    required this.skip,
    required this.overwrite,
    required this.createTime,
  });

  /// 内部任务 id（**不上屏**，只用 Key）
  final String id;

  /// 操作类型（`copy` / `move`）
  final String operation;

  /// 状态（`waiting` / `processing` / `aborting` / `done`）
  final String status;

  /// 总条目数
  final int total;

  /// 已完成条目数
  final int completion;

  /// 失败条目数
  final int error;

  /// 跳过条目数
  final int skip;

  /// 覆盖条目数
  final int overwrite;

  /// 创建时间（**epoch 秒**；0 = 服务端没给）
  final int createTime;

  /// 未完成（还在排队 / 进行 / 正在中止）
  bool get isPending =>
      status == 'waiting' || status == 'processing' || status == 'aborting';

  /// 已完成
  bool get isDone => status == 'done';

  /// 有失败条目
  bool get hasErrors => error > 0;

  /// 进度 0–1（`total <= 0` 时返回 0，不做除零）
  double get ratio =>
      total <= 0 ? 0 : (completion / total).clamp(0.0, 1.0).toDouble();

  /// 操作文案 key（**null = 不认识 → UI 不画**，绝不透原文）
  String? get operationLabelKey => switch (operation) {
    'copy' => 'photoG6TaskOperationCopy',
    'move' => 'photoG6TaskOperationMove',
    _ => null,
  };

  /// 状态文案 key（**null = 不认识 → UI 不画**，绝不透原文）
  String? get statusLabelKey => switch (status) {
    'waiting' => 'photoG6TaskStatusWaiting',
    'processing' => 'photoG6TaskStatusProcessing',
    'aborting' => 'photoG6TaskStatusAborting',
    'done' => 'photoG6TaskStatusDone',
    _ => null,
  };

  static String _str(Object? v) => v == null ? '' : '$v';

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static FotoBackgroundTaskDto fromJson(Map<String, dynamic> json) =>
      FotoBackgroundTaskDto(
        id: _str(json['id']),
        operation: _str(json['operation']),
        status: _str(json['status']),
        total: _int(json['total']),
        completion: _int(json['completion']),
        error: _int(json['error']),
        skip: _int(json['skip']),
        overwrite: _int(json['overwrite']),
        createTime: _int(json['create_time']),
      );

  @override
  String toString() =>
      'FotoBackgroundTaskDto(id: $id, operation: $operation, '
      'status: $status, $completion/$total, error: $error)';
}

/// 迁移状态（`Migration:get_status` 回包）。
class FotoMigrationStatusDto {
  const FotoMigrationStatusDto({
    required this.current,
    required this.status,
    required this.titleKey,
    required this.total,
  });

  /// 当前阶段序号（官方 `current`）
  final int current;

  /// 原始状态串（官方 `status`）—— **不上屏**，UI 只用 [state]
  final String status;

  /// 原始阶段 key（官方 `title_key`）—— **不上屏**，UI 只用 [stageLabelKey]
  final String titleKey;

  /// 总阶段数（官方 `total`；0 = 服务端没给）
  final int total;

  /// 枚举化后的状态。
  FotoMigrationState get state => FotoMigrationState.fromWire(status);

  /// 阶段文案 key（**null = 不认识 → UI 不画**，绝不透原文）。
  ///
  /// 三个有证据的取值来自 `synofoto-bin-migrate-tool` 的字符串常量。
  String? get stageLabelKey => switch (titleKey.trim()) {
    'migrating_photo_station' => 'photoG6MigrationStagePhotoStation',
    'migrating_moments_personal' => 'photoG6MigrationStageMomentsPersonal',
    'photos_migrating_photostation' => 'photoG6MigrationStagePhotoStation',
    'photos_migrating_moments_personal' =>
      'photoG6MigrationStageMomentsPersonal',
    'photos_migrating_photostation_moments_personal' =>
      'photoG6MigrationStageBoth',
    _ => null,
  };

  /// 进度 0–1（`total <= 0` 时 0，不做除零）
  double get ratio =>
      total <= 0 ? 0 : (current / total).clamp(0.0, 1.0).toDouble();

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static FotoMigrationStatusDto fromJson(Map<String, dynamic> data) =>
      FotoMigrationStatusDto(
        current: _int(data['current']),
        status: data['status'] == null ? '' : '${data['status']}',
        titleKey: data['title_key'] == null ? '' : '${data['title_key']}',
        total: _int(data['total']),
      );

  @override
  String toString() =>
      'FotoMigrationStatusDto(current: $current/$total, status: $status)';
}

/// `Migration:get_status` 的 **`status` 枚举**（枚举串，不是布尔）。
///
/// * `done` —— 有证据（真机实测 + `.so` 字面值）；
/// * `running` —— 有证据（`.so` 字面值）；
/// * `failed` —— **任务要求覆盖**（本轮未在真机/二进制里取到该字面值，
///   按"失败"显式建模，避免以后服务端新增时被当"未知"）；
/// * [unknown] —— **不认识的值一律走这里**，UI 给通用人话，
///   **绝不把服务端原文透出去**。
enum FotoMigrationState {
  done('done'),
  running('running'),
  failed('failed'),
  unknown('');

  const FotoMigrationState(this.wire);

  final String wire;

  /// `migration_finished` 是阶段名，语义等同已完成，一并收敛到 [done]。
  static FotoMigrationState fromWire(String? raw) {
    return switch ((raw ?? '').trim().toLowerCase()) {
      'done' => FotoMigrationState.done,
      'migration_finished' => FotoMigrationState.done,
      'running' => FotoMigrationState.running,
      'failed' => FotoMigrationState.failed,
      _ => FotoMigrationState.unknown,
    };
  }

  /// 文案 key（**unknown 也有一条人话**，不透原文）
  String get labelKey => switch (this) {
    FotoMigrationState.done => 'photoG6MigrationStatusDone',
    FotoMigrationState.running => 'photoG6MigrationStatusRunning',
    FotoMigrationState.failed => 'photoG6MigrationStatusFailed',
    FotoMigrationState.unknown => 'photoG6MigrationStatusUnknown',
  };
}
