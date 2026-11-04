// `SYNO.SynologyDrive.Tasks/list` 的后台任务条目（Drive 侧的上传/下载/转存任务）。
//
// 权威事实：
//   * NAS 上装的 **Synology Drive 4.2.0-30058**（`/tmp/spk/export_SynologyDrive`）：
//     `webapi/SYNO.SynologyDrive.lib` → `SYNO.SynologyDrive.Tasks` **v1** =
//     `list get delete`，`allowUser` 含 `normal.*`；
//     `webapi/drive/tasks/SYNO.SynologyDrive.Tasks.so` 的内联键：
//     `items total task_id status result progress in_progress errors error message
//      moving_db enabled anonymous`；
//   * 官方 Drive 前端（`drive/synodrive_common.js`）的调用点：
//     `list_tasks:{api:"SYNO.SynologyDrive.Tasks",method:"list",version:1}`、
//     `get_task`、`delete_task`，且 `delete_task` 传 `{task_id:<id>}`，
//     遍历任务时看的是 `item.status == 'finished'`、
//     `item.result.action`（任务类型，如 `download`）、`item.result.names`、
//     `item.result.total_size`、`item.progress`、`item.task_id`。
//
// ⚠️ 与 File Station 的 `BackgroundTask` **不是一套**：那是文件模块的操作任务，
// 这是 Drive 自己的异步任务（上传/下载/跨空间转存）。两边各自独立，UI 也分开。
import '../../core/i18n/data_text.dart';

class DriveTaskDto {
  const DriveTaskDto({
    required this.taskId,
    required this.status,
    required this.action,
    required this.names,
    required this.totalSize,
    required this.progress,
    required this.inProgress,
    required this.errors,
    required this.message,
    required this.createdTime,
    required this.finishedTime,
    required this.resultTaskId,
  });

  /// 异步任务 id（`delete` 用它）
  final String taskId;

  /// 官方状态串（`finished` / `in_progress` / `error` …）
  final String status;

  /// 任务类型：`upload` / `download` / `copy` / `move` …（来自 `result.action`）
  final String action;

  /// 涉及的文件名（`result.names`，官方是数组）
  final List<String> names;

  /// 总字节数（`result.total_size`）
  final int totalSize;

  /// 0–100（`progress`；官方对 polling-only 的任务直接拿来画进度）
  final double progress;

  final bool inProgress;

  /// 服务端错误列表（有内容就是失败任务）
  final List<String> errors;

  final String message;
  final DateTime? createdTime;
  final DateTime? finishedTime;

  /// `result.task_id`（官方删的是这个，而不是外层 `task_id`；两者通常相同）
  final String resultTaskId;

  bool get finished => status == 'finished';

  bool get failed => errors.isNotEmpty || status == 'error';

  /// 删除/清理时优先用官方那个 id
  String get deleteId => resultTaskId.isNotEmpty ? resultTaskId : taskId;

  /// 一行标题：官方对未知 action 也照样显示原名
  ///
  /// 数据层拿不到 `BuildContext`，按 docs §4.6 走 `data_text.dart` 的 [dataText]；
  /// 没装翻译器就回落中文原文。
  String get title {
    final label = switch (action) {
      'upload' => dataText('dtoActionUpload', '上传'),
      'download' => dataText('dtoActionDownload', '下载'),
      'copy' => dataText('dtoActionCopy', '复制'),
      'move' => dataText('dtoActionMove', '移动'),
      'delete' => dataText('dtoActionDelete', '删除'),
      '' => dataText('dtoTaskGeneric', '任务'),
      _ => action,
    };
    if (names.isEmpty) return label;
    if (names.length == 1) return '$label · ${names.first}';
    return dataText('dtoTaskTitleMore', '{label} · {name} 等 {count} 项')
        .replaceAll('{label}', label)
        .replaceAll('{name}', names.first)
        .replaceAll('{count}', '${names.length}');
  }

  String get humanSize => formatBytes(totalSize);

  static DriveTaskDto fromJson(Map<String, dynamic> json) {
    final result =
        (json['result'] as Map?)?.cast<String, dynamic>() ?? const {};
    return DriveTaskDto(
      taskId: '${json['task_id'] ?? result['task_id'] ?? ''}',
      status: '${json['status'] ?? ''}',
      action: '${result['action'] ?? ''}',
      names: _strings(result['names']),
      totalSize: _int(result['total_size'] ?? json['total_size']),
      progress: _progress(json['progress']),
      inProgress: json['in_progress'] == true,
      errors: _strings(json['errors']),
      message: '${json['message'] ?? json['error'] ?? ''}',
      createdTime: _time(json['created_time'] ?? json['create_time']),
      finishedTime: _time(json['finished_time'] ?? json['finish_time']),
      resultTaskId: '${result['task_id'] ?? ''}',
    );
  }

  static List<DriveTaskDto> listFromJson(Map<String, dynamic> data) {
    final raw = data['items'];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) DriveTaskDto.fromJson(e.cast<String, dynamic>()),
    ];
  }

  static List<String> _strings(Object? raw) {
    if (raw is String && raw.isNotEmpty) return [raw];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is String && e.isNotEmpty) e,
    ];
  }

  static int _int(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? 0;
    return 0;
  }

  /// `progress` 可能是 0–100 的整数，也可能是 0–1 的小数（两种都见过），
  /// 统一成 0–100 用来画进度条。
  static double _progress(Object? raw) {
    var v = 0.0;
    if (raw is num) {
      v = raw.toDouble();
    } else if (raw is String) {
      v = double.tryParse(raw) ?? 0;
    }
    if (v > 0 && v <= 1) v *= 100;
    return v.clamp(0, 100).toDouble();
  }

  static DateTime? _time(Object? raw) {
    if (raw is num) {
      final n = raw.toInt();
      if (n <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(
        n < 100000000000 ? n * 1000 : n,
      );
    }
    if (raw is String && raw.isNotEmpty) return DateTime.tryParse(raw);
    return null;
  }
}

/// 字节数 → 人能读的字符串（Drive 任务里只有一个字节数，没必要依赖文件模块）
String formatBytes(int bytes) {
  if (bytes <= 0) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = value >= 100 || unit == 0
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}
