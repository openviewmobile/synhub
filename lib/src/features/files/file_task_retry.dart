// M58：后台任务的**重试计划**（纯函数，无 `BuildContext` / 无网络）。
//
// 官方 `BackgroundTaskFragment.java:849-851` 的任务行有 `RELOAD` / `retry`：
// 服务端 `BackgroundTask` **只有** `list` / `clear_finished`（注册表），
// "重试"在官方就是客户端**用原参数把原任务再发一遍**。
//
// 因此重试的可行性完全取决于"原参数还在不在"：
//   * 服务端 `BackgroundTask.list` 的条目带 `params`（`TaskListVo.Task`，
//     见 `FileTaskDto` 的字段注释）→ **优先原样复用这份快照**；
//   * 快照没给（老服务端 / 该类型不回 params）→ 只有**参数都在任务自带字段里**
//     的类型能重建：`path` / `file_path` 就是任务条目的顶层 `path`，
//     `Delete` / `DirSize` / `MD5` 三者只靠它一个字段。
//   * `CopyMove` / `Compress` / `Extract` 的**目标**（`dest_folder_path` /
//     `dest_file_path`）顶层字段里没有 → 快照缺失时**不可重试**（返回 null），
//     宁可少一个按钮，也不猜目标路径。
//
// ⚠️ 未取证：真机 `BackgroundTask.list` 是否真的回 `params` 尚未钉过（本批
// 只有离线假服务端）。见 `docs/filestation-gaps-wave2.md` §8 取证清单。
import '../../data/dto/file_entry_dto.dart';

/// ★★ 第 303 轮：这个参数名是不是**秘密**（详情页必须打码）？
///
/// 背景（真机缺陷）：`BackgroundTask/list` 的 `params` 快照会把压缩/解压的
/// **口令原样回下来**，任务详情页照原样渲染 ⇒ 屏幕上直接出现明文密码
/// （第 303 轮真机：`password  r303Zz9pw`，见 `docs/evidence-r303/`）。
///
/// 判据是**键名**（大小写/下划线/连字符无关），不做值形状猜测：
/// `password` / `passwd` / `pass` / `passphrase` / `pwd` / `secret` /
/// `apikey` / `api_key` / `token` / `credential`。
///
/// ⚠️ 只用于**显示**：重试计划（[fileTaskRetryPlan]）必须原样复用快照里的
/// 口令，否则加密包的"重试"会变成一次注定的失败。
///
/// ## ★★ 第二层判据：`codepage` 只允许是**已知编码 token**（第 303 轮真机追加）
///
/// 键名打码挡不住 DSM 的**错位回显**：真机三次复现（DSM 7.4.1-90080），
/// 带口令的 `Extract/start` 在任务快照里**没有 `password` 键**，口令被记在
/// **`codepage`** 键上（逐字：`codepage  r303Zz9pw`），且该任务确实用这个口令
/// 解开了加密包（错口令那次另行报「1 个文件失败」）⇒ 是**服务端记账键名**，
/// 不是我们发错。`codepage` 本身是**枚举值**参数（官方 `getCodePage()`），
/// 不在 [kFileCodepageTokens] 里的值不可能是我们发的编码 ⇒ 一律当秘密打码。
bool isSecretTaskParamKey(String key, {String? value}) {
  final k = key.toLowerCase().replaceAll('_', '').replaceAll('-', '');
  if (const {
    'password',
    'passwd',
    'pass',
    'passphrase',
    'pwd',
    'secret',
    'apikey',
    'token',
    'credential',
  }.contains(k)) {
    return true;
  }
  // `codepage` = 枚举；值不在集合里 ⇒ 是服务端错位回显的口令。
  if (k == 'codepage' && value != null) {
    return !kFileCodepageTokens.contains(value.trim().toLowerCase());
  }
  return false;
}

/// 官方 `getCodePage()` 会发的编码 token（与 `ExtractCodepage` 枚举同集合）。
const Set<String> kFileCodepageTokens = {
  'utf8',
  'chs',
  'cht',
  'jpn',
  'krn',
  'enu',
};

/// 重发原任务所需的 api / method / 参数。
class FileTaskRetryPlan {
  const FileTaskRetryPlan({
    required this.api,
    required this.method,
    required this.params,
  });

  final String api;
  final String method;
  final Map<String, dynamic> params;
}

/// 该任务能否重试；不能则返回 `null`。
///
/// 判定顺序：参数快照 → 单路径重建。**不猜**任何参数名：每个 API 的必需键
/// 都来自对应 `start` 方法的既有封装（`filestation_api.dart`）。
FileTaskRetryPlan? fileTaskRetryPlan(FileTaskDto task) {
  final api = task.api;
  if (api.isEmpty) return null;
  final method = task.method.isEmpty ? 'start' : task.method;

  // 允许的方法：Delete 有 start（进回收站）/ delete（永久删除）两支；
  // 其余异步任务只有 start。`Rename` 等不在重试白名单。
  final bool isDelete = api.endsWith('Delete');
  final allowed = isDelete ? const {'start', 'delete'} : const {'start'};
  if (!allowed.contains(method)) return null;

  final snapshot = Map<String, dynamic>.from(task.params)
    ..remove('taskid')
    ..remove('search_taskid');

  List<String> requiredKeys;
  if (api.endsWith('CopyMove')) {
    requiredKeys = const ['path', 'dest_folder_path'];
  } else if (api.endsWith('Compress')) {
    requiredKeys = const ['path', 'dest_file_path'];
  } else if (api.endsWith('Extract')) {
    requiredKeys = const ['file_path', 'dest_folder_path'];
  } else if (isDelete) {
    requiredKeys = const ['path'];
  } else if (api.endsWith('DirSize')) {
    requiredKeys = const ['file_path'];
  } else if (api.endsWith('MD5')) {
    requiredKeys = const ['file_path'];
  } else {
    return null;
  }

  final snapshotComplete = requiredKeys.every(
    (k) => snapshot[k] != null && '${snapshot[k]}'.isNotEmpty,
  );
  if (snapshotComplete) {
    return FileTaskRetryPlan(api: api, method: method, params: snapshot);
  }

  // ---- 快照缺失时的重建：只对"单路径即可"的类型 ----
  final onePath = task.path.isEmpty ? null : task.path;
  if (onePath == null) return null;
  final encoded = FileEntryDto.encodePaths([onePath]);
  if (isDelete) {
    return FileTaskRetryPlan(
      api: api,
      method: method,
      params: {'path': encoded, 'recursive': true},
    );
  }
  if (api.endsWith('DirSize') || api.endsWith('MD5')) {
    return FileTaskRetryPlan(
      api: api,
      method: method,
      params: {'file_path': encoded},
    );
  }
  // CopyMove / Compress / Extract 缺目标 → 不可重试
  return null;
}

// ---- 未完成任务的"已运行多久"（纯函数，可测）----------------------------------

/// 未完成任务的运行时长，按 [crtime]（服务端下发的 epoch 秒）算。
///
/// **为什么要有这个**（第 303 轮真机缺陷）：一个**卡死**的压缩任务会永远显示
/// `0%` + `任务错误：没有错误`，客户端不报错、也不提示"可能已失效"，用户唯一的
/// 出路是自己点「停止任务」—— 但他**没有任何事实依据**判断该不该停。
///
/// 这里**只提供事实（已经跑了多久），不猜"卡住"**：不设"超过 N 分钟就是死了"
/// 这种没有依据的阈值（§2.0.36「门槛必须有依据」）。时长本身就能让"1 秒的任务
/// 跑了 25 分钟"这个矛盾可见。
///
/// 返回 `(hours: null 或小时数, minutes: 分钟数)`；拿不到/不合法 ⇒ `null`
/// （**不编造**：字段缺失时宁可不显示）。
({int? hours, int minutes})? fileTaskElapsed(String crtime, {DateTime? now}) {
  final created = int.tryParse(crtime.trim());
  if (created == null || created <= 0) return null;
  var d = (now ?? DateTime.now())
      .difference(DateTime.fromMillisecondsSinceEpoch(created * 1000));
  if (d.isNegative) d = Duration.zero; // 服务端时钟比本机快 ⇒ 显示 0 分钟，不倒着算
  final minutes = d.inMinutes;
  if (minutes < 60) return (hours: null, minutes: minutes);
  return (hours: minutes ~/ 60, minutes: minutes % 60);
}
