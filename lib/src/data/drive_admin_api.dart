// ③Drive **管理员接口**（新规 B1：管理员相关接口一律走 Mock Server 验证并必须通过）。
//
// ## 逐字证据（三处交叉，**全部是只读方法**）
//
// ① 权威方法表：`SynologyDrive/webapi/drive/SYNO.SynologyDrive.lib`
//    （SPK 原件，`tool/mock_dsm/catalog.json` 里的 `source: "spk"` 条目同一份）：
//    * `SYNO.SynologyDrive.Settings`   v1   authLevel=1 `allowUser` 仅 admin ⇒ adminOnly
//      methods: `list`（+ v2 起 `list_targets`、`update`）
//    * `SYNO.SynologyDrive.Config`     v1   adminOnly，methods: `get` / `set`
//    * `SYNO.SynologyDrive.DBUsage`    v1   adminOnly，methods: `get` / `start` / `status` / `stop`
//    * `SYNO.SynologyDrive.Privilege`  v1   adminOnly，methods: `list` / `set` / `status`
//
// ② 官方**管理端 Web JS**（同一个 SPK 的 `ui/cloudstation.js` /
//    `ui/cloudstation_explorer.js`）里逐字抄下来的调用形态：
//    * `{api:"SYNO.SynologyDrive.Settings", method:"list", version:1}` —— **无 params**；
//    * `SYNO.SDS.CSTN.WebAPI.Config.api`（= `SYNO.SynologyDrive.Config`）
//      `method:"get", version:1` —— **无 params**；
//      其 `set` 的 params 是 `db_volume / use_del_by_cnt / del_cnt /
//      use_del_by_span / del_span / enable_vmtouch / enable_mlock /
//      vmtouch_reserve_mem`（**本文件不实现 set**，§5.1）；
//    * `{api:…+".DBUsage", version:1, method:"get", params:{}}`、
//      `method:"status", params:{}` —— 参数是**空对象**（有意写成显式 `{}`）；
//    * `SYNO.SynologyDrive.Privilege` `method:"list", version:"1"` 的
//      `setApiParams()` 返回 `{additional:["status","enabled"]}`，
//      store 字段 `["name","enable","status"]`。
//
// ③ 页面字段来源同样来自 ②：`Settings/list` 的回包被直接
//    `form.setValues()`，所以字段名就是表单字段名（`enable_public_sharing`
//    等）；`DBUsage` 的 `usage` / `last_update_usage_time` / `finish` / `time`
//    出现在 `updateUsage` / `getCachedDBUsageCB`。
//
// ## 只实现「读」
//
// `Settings/update`、`Config/set`、`DBUsage/start|stop`、`Privilege/set` 都是
// **变更动词** —— 按 §5.1 本条一律不实现、不调用（写了就会动服务端配置）。
import '../core/net/traffic_meter.dart';
import 'package:synhub/src/dsm/webapi.dart';

/// Drive 管理端只读接口。
///
/// 只包住**逐字取证过**的 5 个调用；每个方法都标注了官方出处。
class DriveAdminApi {
  DriveAdminApi(DsmWebApi api) : api = api.withModule(TrafficModules.admin);

  final DsmWebApi api;

  /// `Settings/list` **v1**（官方管理端 `method:"list", version:1`，无 params）。
  ///
  /// 回包字段（官方 `loadFormDoneSuccess` 直接 `setValues`）：
  /// `enable_public_sharing` / `enable_normal_user_sharing` /
  /// `use_del_by_cnt` / `del_cnt` / `use_del_by_span` / `del_span` /
  /// `enable_vmtouch` / `enable_mlock` / `vmtouch_reserve_mem` /
  /// `volume_list` / `support_moving_repository`。
  Future<Map<String, dynamic>> settings() async {
    final data = await api.call(
      'SYNO.SynologyDrive.Settings',
      'list',
      preferredVersion: 1,
      params: const <String, Object?>{},
    );
    return Map<String, dynamic>.from(data);
  }

  /// `Config/get` **v1**（官方管理端 `method:"get", version:1`，无 params）。
  Future<Map<String, dynamic>> config() async {
    final data = await api.call(
      'SYNO.SynologyDrive.Config',
      'get',
      preferredVersion: 1,
      params: const <String, Object?>{},
    );
    return Map<String, dynamic>.from(data);
  }

  /// `DBUsage/get` **v1**（官方 `params:{}`；回 `usage` / `last_update_usage_time`）。
  Future<Map<String, dynamic>> dbUsage() async {
    final data = await api.call(
      'SYNO.SynologyDrive.DBUsage',
      'get',
      preferredVersion: 1,
      params: const <String, Object?>{},
    );
    return Map<String, dynamic>.from(data);
  }

  /// `DBUsage/status` **v1**（官方 `params:{}`；回 `usage` / `finish` / `time`）。
  Future<Map<String, dynamic>> dbUsageStatus() async {
    final data = await api.call(
      'SYNO.SynologyDrive.DBUsage',
      'status',
      preferredVersion: 1,
      params: const <String, Object?>{},
    );
    return Map<String, dynamic>.from(data);
  }

  /// `Privilege/list` **v1** —— 官方 `setApiParams()` 逐字：
  /// `{additional: ["status","enabled"]}`；条目字段 `name` / `enable` / `status`。
  ///
  /// ⚠️ 官方还带了 user-chooser 的分页/过滤参数（`substr` / `offset` / `limit`），
  /// 那是 ExtJS store 的通用参数，**不是这个接口的要求** —— 本方法不传，
  /// 保持"最小且逐字"的调用面。
  Future<List<Map<String, dynamic>>> privileges() async {
    final data = await api.call(
      'SYNO.SynologyDrive.Privilege',
      'list',
      preferredVersion: 1,
      params: const <String, Object?>{
        'additional': ['status', 'enabled'],
      },
    );
    final raw = data['items'] ?? data['users'] ?? const <dynamic>[];
    return [
      for (final e in raw)
        if (e is Map) Map<String, dynamic>.from(e.cast<String, dynamic>()),
    ];
  }
}
