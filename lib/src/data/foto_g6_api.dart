// 相册**全局**（非个人/共享空间）只读接口的客户端：
//   * `SYNO.Foto.BackgroundTask.Info:list_user_task`（**v1**）；
//   * `SYNO.Foto.Migration:get_status`（**v1**）。
//
// ## 为什么不放进 `foto_api.dart` / `foto_c2_api.dart`
//
// 那两个类都建立在 `FotoApi` 的**空间前缀**上（`_name(apiId)` =
// `${space.prefix}$apiId`，个人空间 `SYNO.Foto.` / 共享空间 `SYNO.FotoTeam.`）。
// 这两个 API **没有 `SYNO.FotoTeam.` 对应体**（证据见 `dto/foto_g6_dto.dart`
// 文件头），套前缀会拼出不存在的 API 名 → `102`。
// 所以这里直接拿 [DsmWebApi]，API 名**逐字**写 `SYNO.Foto.*`。
//
// ## 版本协商（硬规则 §5.3：**不得硬编码 maxVersion**）
//
// 与 `DriveApi._negotiate` / `FotoApi.negotiate` **同一份规则**：候选版本
// 与 `SYNO.API.Info` 里该 API 的 `[minVersion, maxVersion]` 取交集，
// 取交集里最大的；交集为空时收敛到区间端点。**绝不直接发 `maxVersion`。**
library;

import '../core/net/traffic_meter.dart';
import '../dsm/webapi.dart';
import 'dto/foto_g6_dto.dart';

class FotoG6Api {
  FotoG6Api(DsmWebApi api) : api = api.withModule(TrafficModules.photos);

  final DsmWebApi api;

  /// `SYNO.Foto.BackgroundTask.Info` 已实测可用的版本（`SYNO.Foto.lib`
  /// `minVersion:1, maxVersion:1`）——**候选列表**，不是"写死的版本"。
  static const List<int> kBackgroundTaskInfoVersions = [1];

  /// `SYNO.Foto.Migration` 已实测可用的版本（`minVersion:1, maxVersion:1`）。
  static const List<int> kMigrationVersions = [1];

  /// 候选版本里挑服务器真正支持的最大版本
  /// （与 `DriveApi._negotiate` / `FotoApi.negotiate` 同规则）
  int _negotiate(String apiName, List<int> candidates) {
    final entry = api.apiTable?[apiName];
    if (entry == null || candidates.isEmpty) {
      return candidates.isEmpty ? 1 : candidates.first;
    }
    final within = candidates.where(
      (c) => c >= entry.minVersion && c <= entry.maxVersion,
    );
    if (within.isNotEmpty) return within.reduce((a, b) => a > b ? a : b);
    return entry.maxVersion < candidates.last
        ? entry.maxVersion
        : entry.minVersion;
  }

  /// `BackgroundTask.Info / list_user_task`（v1）：**当前用户**的后台任务。
  ///
  /// 真机只读实测（`docs/g6-api-probe-facts.md:38`）：**无必填参数**，
  /// 回 `{"list": []}`。回包没有 `total`，`total` 就是 `list.length`。
  Future<List<FotoBackgroundTaskDto>> listUserTasks() async {
    const apiName = 'SYNO.Foto.BackgroundTask.Info';
    final data = await api.call(
      apiName,
      'list_user_task',
      preferredVersion: _negotiate(apiName, kBackgroundTaskInfoVersions),
    );
    return _list(data, FotoBackgroundTaskDto.fromJson);
  }

  /// `Migration / get_status`（v1）：PhotoStation / Moments 的迁移状态。
  ///
  /// 真机只读实测（`docs/g6-api-probe-facts.md:39`）：**无必填参数**，
  /// 回 `{"current": 2, "status": "done", "title_key": "", "total": 0}`。
  Future<FotoMigrationStatusDto> migrationStatus() async {
    const apiName = 'SYNO.Foto.Migration';
    final data = await api.call(
      apiName,
      'get_status',
      preferredVersion: _negotiate(apiName, kMigrationVersions),
    );
    return FotoMigrationStatusDto.fromJson(data);
  }

  /// `data.list` → DTO 列表（回包不是 `list` 就返回空，**不抛**：
  /// 空态是真机上的正常表现，不该变成错误页）。
  static List<T> _list<T>(
    Map<String, dynamic> data,
    T Function(Map<String, dynamic>) parse,
  ) {
    final raw = data['list'];
    if (raw is! List) return const [];
    final out = <T>[];
    for (final e in raw) {
      if (e is Map) out.add(parse(e.cast<String, dynamic>()));
    }
    return List.unmodifiable(out);
  }
}
