// NoteStation 业务 API —— 把 `SYNO.NoteStation.*` 收敛成强类型方法。
//
// ★ 参数形态**逐一对照反编译的 DS note 1.12.0-346**（源在
//   `/tmp/synoapks/jadx_DSnote/sources/com/synology/dsnote/`）：
//
//     * `net/ApiNS*.java`                     —— API 名 + 版本常量
//     * `tasks/FetchNoteTask.java`            —— Note/get 的 `object_id`/`ver`/`field`
//     * `callables/operations/CreateNoteOperation.java` / `SetNoteOperationV2.java`
//                                             —— Note/create / set 的全部字段
//     * `callables/operations/DeleteNoteOperation.java` —— delete 的 `recycle`
//     * `callables/SyncPullCallable.java`     —— Notebook/list 的 `filter`、
//                                               Note/list 的 `field`
//
// ⚠️ 这些接口的参数是 **Gson 二次编码**：字符串要带引号（`"xxx"`）、对象/数组
//    要整体当一个 JSON 串传（`{"archive":false}`）。写错的表现是"参数无效 120"。
//
// ⚠️ NoteStation 有 **DSM 应用权限**：账号没被授权时 `session=NoteStation` 登录
//    直接 402，`Info/get`/`Tag/list` 之类回 160。真机实测见
//    `docs/p1-notestation-implementation.md`。
library;

import 'dart:convert';

import '../dsm/cgi_encryption.dart';
import '../core/device/device_model.dart';
import '../core/net/traffic_meter.dart';
import '../dsm/webapi.dart';
import 'dto/note_acl_dto.dart';
import 'dto/note_c3_dto.dart';
import 'dto/note_dto.dart';

/// Java 的 `String.hashCode()`（32 位有符号）。
///
/// 笔记附件的 multipart **字段名**用的是它：官方 DS note（Android）
/// `SetNoteOperationV2` 里 `Integer.toString(file.getName().hashCode())`，
/// `ApiRequest` 里 `addFormDataPart(Integer.toString(file.getName().hashCode()), …)`。
/// 这不是"随便一个 id"——字段名和 `attachment[].name` **必须一致**，
/// 用 Dart 的 `String.hashCode` 会得到另一个数（Dart 是 30 位变体），服务端就找不到文件。
int javaStringHashCode(String value) {
  var hash = 0;
  for (final unit in value.codeUnits) {
    hash = (31 * hash + unit) & 0xFFFFFFFF;
  }
  // 折成 32 位有符号（Java 的 int）
  return hash >= 0x80000000 ? hash - 0x100000000 : hash;
}

/// 要上传的一个笔记附件（对应官方 App 的 `FileInfo`）
class NoteAttachmentUpload {
  const NoteAttachmentUpload({
    required this.path,
    required this.fileName,
    this.action = 'create',
    this.ref,
    this.convert = true,
    this.mimeType,
    this.remoteFileId,
  });

  /// 本地文件路径
  final String path;

  /// 原始文件名（`Content-Disposition` 的 filename，服务端按它取名）
  final String fileName;

  /// `create` / `modify` / `delete`
  final String action;

  /// 编辑器 HTML 里 `<img ref="…">` 的值（不填则用 base64(ts+name) 生成）
  final String? ref;

  /// 是否让服务端生成缩略图（官方 `FileInfo.needThumb`）
  final bool convert;

  final String? mimeType;

  /// `delete`/`modify` 时要指定的远端 file_id
  final String? remoteFileId;

  /// multipart 字段名 = 文件名 hashCode（官方 App 就是这么发的）
  String get field => '${javaStringHashCode(fileName)}';
}

/// 批量写（`Note/delete` / `Note/set` 数组形态）的逐条结果。
///
/// `Note/set` 的回包本来就带 `errors[]`（逐条失败码），删除的 `BasicVo` 不带
/// —— 所以删除在老服务端走逐条回退时才有 [failed]；新服务端只保证整体成败。
class NoteBatchResult {
  const NoteBatchResult({required this.objectIds, this.failed = const {}});

  final List<String> objectIds;

  /// `object_id` → 服务端错误码
  final Map<String, int> failed;

  int get succeeded => objectIds.length - failed.length;
  bool get hasFailure => failed.isNotEmpty;
  bool get allFailed => failed.length == objectIds.length;
}

class NoteStationApi {
  NoteStationApi(
    DsmWebApi api, {
    DsmCgiEncryption Function(DsmCipherData data)? cipherFactory,
  }) : api = api.withModule(TrafficModules.notes),
       _cipherFactory = cipherFactory ?? DsmCgiEncryption.new;

  final DsmWebApi api;

  /// `SYNO.API.Encryption getinfo` 之后构造 `CgiEncryption` 的方式。
  ///
  /// 默认就是官方的 `DsmCgiEncryption`；**测试**可以注入一个子类来记录
  /// "到底把哪些参数交给了 CGI 加密"（改口令的 `cipher_key` 路线靠它钉死）。
  final DsmCgiEncryption Function(DsmCipherData data) _cipherFactory;

  static const String noteApi = 'SYNO.NoteStation.Note';

  /// 剪藏的**优先**写入口（官方 `ClipperService.createNoteByURL` 先探它）。
  ///
  /// [E2] `net/ApiNSNoteGhost.java`：`NAME = "SYNO.NoteStation.Note.Ghost"`、
  /// `VERSION = 2`、`Method.CREATE = "create"`；
  /// `services/ClipperService.java` 的判定是
  /// `NetUtils.supportApi(ctx, ApiNSNoteGhost.NAME, 2)` → 支持才走 Ghost，
  /// 否则退回 `ApiNSNote` v**2**。
  static const String noteGhostApi = 'SYNO.NoteStation.Note.Ghost';

  static const String notebookApi = 'SYNO.NoteStation.Notebook';
  static const String tagApi = 'SYNO.NoteStation.Tag';
  static const String todoApi = 'SYNO.NoteStation.Todo';

  /// 快捷方式（`SYNO.NoteStation.Shortcut` **v1**：`list` / `set` / `delete`）。
  ///
  /// [E2] 官方 `net/ApiNSShortcut.java`：`NAME = "SYNO.NoteStation.Shortcut"`、
  /// `VERSION = 1`、`Method = list/set/delete`；服务端
  /// `webapi/SYNO.NoteStation.lib` 同（`minVersion=maxVersion=1`，`allowUser`
  /// 全含 `normal.*`）。回包形状见 `vos/api/ShortcutListVo.java` 的
  /// `ShortcutsDataVo`（`offset` / `total` / `shortcuts[]`）。
  static const String shortcutApi = 'SYNO.NoteStation.Shortcut';

  /// 智能 / 条件笔记本（`SYNO.NoteStation.Smart` **v1**）。
  ///
  /// [E2] 官方 `net/ApiNSSmart.java`：`NAME = "SYNO.NoteStation.Smart"`、
  /// `VERSION = 1`、`Method = create/list/set/delete/get`。
  /// 注意官方 **没有** `SYNO.NoteStation.Stack` —— Shelf 是
  /// `Notebook/set` **v2** 的 `stack` 字段（见 [setNotebookStack]）。
  static const String smartApi = 'SYNO.NoteStation.Smart';
  static const String infoApi = 'SYNO.NoteStation.Info';
  static const String settingApi = 'SYNO.NoteStation.Setting';
  static const String versionApi = 'SYNO.NoteStation.Note.Version';
  static const String encryptApi = 'SYNO.NoteStation.Note.Encrypt';
  static const String sharePrivApi = 'SYNO.NoteStation.Share.Priv';
  static const String pollingApi = 'SYNO.NoteStation.Note.Polling';

  /// 笔记本归档（A14）。
  ///
  /// ★ 取证：这是**独立 API**，不是 `Notebook/set` 的字段。
  ///   * 服务端 `webapi/SYNO.NoteStation.lib`：
  ///     `SYNO.NoteStation.Notebook.Polling` **v1** = `archive` / `archive_status`
  ///     / `archive_stop`；
  ///   * 官方 Web `ui/notestation.js`：
  ///     ```js
  ///     archiveNotebook:function(t){this.appWindow.sendWebAPI({api:"SYNO.NoteStation.Notebook.Polling",
  ///       version:1,method:"archive",params:Ext.copyTo({},t,"object_id,enable"),...
  ///     pollingArchiveNotebookStatus:{api:...,method:"archive_status",params:{task_id:t}}
  ///     pollingArchiveNotebookDone:{api:...,method:"archive_stop",params:{task_id:t}}
  ///     ```
  ///     （`Notebook/set` 的白名单只有 `object_id`/`title`/`stack` ——
  ///      APK `SetNotebookOperation.java:17-19` 同，**没有** `archive`）。
  static const String notebookPollingApi = 'SYNO.NoteStation.Notebook.Polling';
  static const String permissionApi = 'SYNO.NoteStation.Permission';
  static const String permissionPublicApi =
      'SYNO.NoteStation.Permission.Public';
  static const String permissionUserApi = 'SYNO.NoteStation.Permission.User';
  static const String permissionGroupApi = 'SYNO.NoteStation.Permission.Group';
  static const String shardLinkApi = 'SYNO.NoteStation.Shard.Link';

  /// 全文检索（Universal Search 的笔记来源）。
  ///
  /// 方法/权限出处：`docs/api-server-authoritative.md:169`
  /// （`SYNO.NoteStation.FTS` v1：`search`，**普通用户**）。
  static const String ftsApi = 'SYNO.NoteStation.FTS';

  // ------------------------------------------------------ C3：导出 / 导入
  //
  // 方法/版本逐字出处：NoteStation-x86_64-2.6.10-3938 的
  // `webapi/SYNO.NoteStation.lib`（35 个 API 的方法表）——
  //   * `SYNO.NoteStation.Export.Word`      v1: start status stop download
  //   * `SYNO.NoteStation.Export.Note`      v1: start status stop download
  //   * `SYNO.NoteStation.Export.Notebook`  v1: start status stop（**无 download**）
  //   * `SYNO.NoteStation.Import.Enex`      v1: start status stop
  //   * `SYNO.NoteStation.Import.Notebook`  v1: start status stop
  //   * `SYNO.NoteStation.Import.Evernote`  v1: init/get_status/get_polling_task/
  //     prepare_notebooks/prepare_notebooks_status/list_notebooks/add_import_task/
  //     import/import_status/import_stop/import_lock/get_oauth_url/get_oauth_token/
  //     check_oauth_token
  static const String exportWordApi = 'SYNO.NoteStation.Export.Word';
  static const String exportNoteApi = 'SYNO.NoteStation.Export.Note';
  static const String exportNotebookApi = 'SYNO.NoteStation.Export.Notebook';
  static const String importEnexApi = 'SYNO.NoteStation.Import.Enex';
  static const String importNotebookApi = 'SYNO.NoteStation.Import.Notebook';
  static const String importEvernoteApi = 'SYNO.NoteStation.Import.Evernote';

  /// 版本候选里挑一个服务器真正支持的（与 `FileStationApi.negotiate` 同规则）
  int negotiate(String apiName, List<int> candidates) {
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

  bool hasApi(String apiName) => api.apiTable?.containsKey(apiName) ?? true;

  /// `Info/searchplace` 能不能用。
  ///
  /// ⚠️ `SYNO.API.Info` 的**能力表只给 API 名与版本区间，不给方法名**，
  /// 所以这里只能按"`SYNO.NoteStation.Info` 在不在能力表里"判定；
  /// 未检测（能力表还没拉下来）→ fail-open（true），与 [hasApi] 同一纪律。
  bool supportsSearchPlace() => hasApi(infoApi);

  // ---------------------------------------------------------------- 编码

  /// Gson 的字符串编码：带引号的 JSON 串
  static String js(Object? v) => jsonEncode(v);

  /// G4：`Note/list` 的 `tag_operator` 取值（官方 Web `AdvancedSearch` 的
  /// `tag_operator` 勾选框：勾了 = `"and"`，不勾 = `"or"`）。
  static const String tagOperatorAnd = 'and';
  static const String tagOperatorOr = 'or';

  // ------------------------------------------------- N4：位置 / 地理标签

  /// 地理编码查询方法：`SYNO.NoteStation.Info` 的 **`searchplace`**（v1）。
  ///
  /// ★ 取证（三路一致）：
  ///   * 服务端 `webapi/SYNO.NoteStation.lib` —— `SYNO.NoteStation.Info`
  ///     **v1/v2/v3 都是 `get` + `searchplace`**（`allowUser` 含 `normal.*`，
  ///     `grantable:false` 但 `allowDemo:true`）；
  ///   * 官方 Web `ui/notestation.js` 的 `Map.Panel.getSearchStore`：
  ///     ```js
  ///     new SYNO.API.Store({api:"SYNO.NoteStation.Info", version:1,
  ///       method:"searchplace", queryParam:"query",
  ///       baseParams:{format:true, radius:500, location:""}, …})
  ///     beforeload: t.setBaseParam("location",
  ///       this.gmapWrapper.getCenter().lat()+","+this.gmapWrapper.getCenter().lng())
  ///     ```
  ///     reader 字段 = `["name","address","gps","placeID","type"]`；
  ///   * 真机只读探针（2026-09-22）：非空合法 `location` → `200 {"data":[],"success":true}`。
  static const String searchPlaceMethod = 'searchplace';

  /// `searchplace` 的默认搜索半径（米）——官方 Web `baseParams.radius`。
  static const int searchPlaceRadiusMeters = 500;

  /// 笔记列表/详情都要求带 `field` 开关，否则拿不到共享信息
  static String _field({
    bool individualShared = true,
    bool individualJoined = true,
    bool oldParentId = true,
  }) => jsonEncode({
    'old_parent_id': oldParentId,
    'individual_joined': individualJoined,
    'individual_shared': individualShared,
  });

  // ---------------------------------------------------------------- 自检

  /// `SYNO.NoteStation.Info / get`（v3 → v1）。返回 null 表示账号没权限。
  Future<NoteInfoDto?> info() async {
    final v = negotiate(infoApi, const [3, 2, 1]);
    final data = await api.call(
      infoApi,
      'get',
      preferredVersion: v,
      params: const {'field': '[]'},
    );
    return NoteInfoDto.fromJson(data);
  }

  /// `SYNO.NoteStation.Setting / get` v2
  Future<Map<String, dynamic>> settings() => api.call(
    settingApi,
    'get',
    preferredVersion: negotiate(settingApi, const [2, 1]),
    params: const {},
  );

  /// `SYNO.NoteStation.Info / searchplace` **v1** —— 按坐标找附近地点（地理编码）。
  ///
  /// ★ 线参逐字取自官方 Web `Map.Panel.getSearchStore` / `beforeload`：
  ///   `{format:true, radius:500, location:"<lat>,<lng>", query:"<关键字>"}`。
  ///   **`location` 是"纬度,经度"**（`center.lat()+","+center.lng()`，纬度在前）；
  ///   数值都用 Gson 风格编码 ⇒ `radius`/`format` 走 JSON 字面量（数字/布尔），
  ///   `location`/`query` 是带引号的字符串。
  ///
  /// ⚠️ 为什么**不走 `api.call`**：`searchplace` 的回包 `data` 是**裸数组**
  /// （真机逐字：`{"data":[],"success":true}`），而 `DsmWebApi.call` 的
  /// `_okData()` 只认 `data` 为对象、遇到数组一律折成 `const {}`
  /// （`lib/src/dsm/webapi.dart:1671`，该目录本轮**禁改**）。所以这里按
  /// `_prepare` 的同一规则（能力表 path + 版本收敛 + `_sid`）自己发一次
  /// 表单请求。**代价**：这条路径没有 `api.call` 的 `119 → 重登 → 重放`
  /// （会话过期会直接把 [DsmApiException] 抛给上层）。
  ///
  /// ⚠️ 真机实测（只读）：**`location` 缺失 / 为空 / 非法（`"abc"`、`"0,0"`）
  /// 时服务端不回包（请求挂到超时）**；只有合法经纬度才立刻回
  /// `{"data":[],"success":true}`。⇒ 调用方**必须**先拿到一个有效中心点，
  /// 拿不到就不要发（见 `note_location.dart` 的能力位降级）。
  Future<List<NotePlaceDto>> searchPlace({
    required double latitude,
    required double longitude,
    required String query,
    int radius = searchPlaceRadiusMeters,
  }) async {
    final entry = api.apiTable?[infoApi];
    final version = entry?.negotiate(1) ?? 1;
    final path = (entry != null && entry.path.isNotEmpty)
        ? entry.path
        : 'entry.cgi';
    final params = <String, dynamic>{
      'api': infoApi,
      'version': '$version',
      'method': searchPlaceMethod,
      'format': js(true),
      'radius': js(radius),
      'location': js(noteLatLng(latitude, longitude)),
      'query': js(query),
      if (api.session != null) '_sid': api.session!.sid,
    };
    final body = await api.transport.postForm(path, params);
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      throw DsmApiException(
        DsmErrorCode.unknown,
        method: '$infoApi.$searchPlaceMethod',
      );
    }
    if (decoded is! Map) {
      throw DsmApiException(
        DsmErrorCode.unknown,
        method: '$infoApi.$searchPlaceMethod',
      );
    }
    final json = Map<String, dynamic>.from(decoded);
    if (json['success'] != true) {
      final err = json['error'];
      final code = (err is Map && err['code'] is num)
          ? (err['code'] as num).toInt()
          : DsmErrorCode.unknown;
      throw DsmApiException(
        code,
        method: '$infoApi.$searchPlaceMethod',
        raw: json,
      );
    }
    final data = json['data'];
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((e) => NotePlaceDto.fromJson(Map<String, dynamic>.from(e)))
        .toList(growable: false);
  }

  /// 服务端是否支持 `Note/get_attachment_text`（`Note` **v4**）。
  bool supportsAttachmentText() =>
      (api.apiTable?[noteApi]?.maxVersion ?? 0) >= 4;

  /// `Setting/get` v2 的 `search_attachment` 能力位（附件文本搜索）。
  ///
  /// ★ 取证：
  ///   * 官方 Web `ui/notestation.js` 通用设置面板读写同一个字段
  ///     （`Setting/set` 的 `search_attachment`、`e.result[0].data`）；
  ///   * 官方 Android `vos/api/SettingVo.java`：`SettingDataVo.search_attachment`
  ///     （`isSearchAttachment()`），登录 / PULL 时落到本地
  ///     `ns_enable_attachment_text_search`。
  ///
  /// 形如 `{"success":true,"data":{"search_attachment":true,…}}`，取不到按 **false**
  /// （关闭 = 不搜、不报错）。
  Future<bool> searchAttachmentEnabled() async {
    try {
      final data = await settings();
      // 容错：直挂 / `data` 再包一层都接受
      if (data.containsKey('search_attachment')) {
        return asBool(data['search_attachment']);
      }
      final inner = data['data'];
      if (inner is Map) return asBool(inner['search_attachment']);
      return false;
    } catch (_) {
      // 设置读不到（老服务端 / 权限）→ 视为关闭，绝不把错误抛给搜索 UI
      return false;
    }
  }

  /// `Setting / set` v2 —— 写服务端 `search_attachment`（官方 Web 就是这么存的）。
  Future<void> setSearchAttachment(bool enabled) => api.call(
    settingApi,
    'set',
    preferredVersion: negotiate(settingApi, const [2, 1]),
    params: {'search_attachment': js(enabled)},
  );

  // ---------------------------------------------------------------- 笔记本

  /// `SYNO.NoteStation.Notebook / list`（v2 带 `filter={"archive":false}`）
  Future<List<NotebookDto>> listNotebooks({
    bool includeArchived = false,
  }) async {
    final v = negotiate(notebookApi, const [2, 1]);
    final params = <String, dynamic>{};
    if (v >= 2) {
      params['filter'] = js({'archive': includeArchived});
    }
    final data = await api.call(
      notebookApi,
      'list',
      preferredVersion: v,
      params: params,
    );
    final list = data['notebooks'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => NotebookDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// `SYNO.NoteStation.Notebook / get` v1
  Future<NotebookDto> getNotebook(String objectId) async {
    final data = await api.call(
      notebookApi,
      'get',
      preferredVersion: 1,
      params: {'object_id': js(objectId)},
    );
    return NotebookDto.fromJson(data);
  }

  /// `SYNO.NoteStation.Notebook / create` v1。
  ///
  /// 字段照反编译的 `CreateNotebookOperation`：`title` + `ctime`（都 Gson 编码）。
  Future<String> createNotebook(String title, {int? ctime}) async {
    final data = await api.call(
      notebookApi,
      'create',
      preferredVersion: 1,
      params: {
        'title': js(title),
        'ctime': js(noteEpochSecondsNormalize(ctime ?? noteEpochSeconds())),
      },
    );
    return asText(data['object_id']);
  }

  /// `SYNO.NoteStation.Notebook / set` v2（改名）
  Future<void> renameNotebook(
    String objectId, {
    String? title,
    required String ver,
  }) async {
    await api.call(
      notebookApi,
      'set',
      preferredVersion: negotiate(notebookApi, const [2, 1]),
      params: {
        'object_id': js(objectId),
        'ver': js(ver),
        if (title != null) 'title': js(title),
      },
    );
  }

  /// `SYNO.NoteStation.Notebook / delete` v1
  Future<void> deleteNotebook(String objectId) => api.call(
    notebookApi,
    'delete',
    preferredVersion: 1,
    params: {'object_id': js(objectId)},
  );

  /// `SYNO.NoteStation.Notebook / set` **v2** 的 `stack` —— 笔记本分层（Shelf）。
  ///
  /// 取证（审计 U2 的答案）：官方 APK 里**没有** `SYNO.NoteStation.Stack`
  /// 这个命名空间，Shelf 全靠 `Notebook/set` v2 的 `stack` 字段：
  /// * `net/ApiNSNotebook.java`：`VERSION_2_STACK = 2`；
  /// * `callables/operations/SetNotebookOperation.java`：`putParam("stack",
  ///   sGson.toJson(str3))`（**总是发**，`null` 就是移出 Shelf）；
  /// * `loaders/GenerateStacksLoader.java` 从本地 `NotebookTable.STACK` 取
  ///   `stack` 去重成 Shelf 列表（`stack collate nocase asc`）。
  ///
  /// [stack] 为 null 或空串 = 移出 Shelf（官方「remove_from_stack」）。
  Future<void> setNotebookStack(String objectId, {String? stack}) => api.call(
    notebookApi,
    'set',
    preferredVersion: negotiate(notebookApi, const [2, 1]),
    params: {
      'object_id': js(objectId),
      'stack': js(stack == null || stack.isEmpty ? null : stack),
    },
  );

  /// `SYNO.NoteStation.Notebook.Polling / archive` **v1** —— 归档 / 取消归档。
  ///
  /// 参数与轮询形态逐字来自官方 Web `ui/notestation.js`（见
  /// [notebookPollingApi] 的注释）：`archive {object_id, enable}` →
  /// `archive_status {task_id}`（`finish` 为真才结束）→ `archive_stop {task_id}`。
  ///
  /// 与 Note 家族一致，参数走 Gson 的 JSON 串形态（本仓库 Note/Notebook
  /// 写接口的真机验证形态）。失败**绝不静默**：`archive_status` 回包里带了
  /// `errors` 就按错误码抛出。
  Future<void> archiveNotebook(
    String objectId, {
    required bool enable,
    void Function(int poll)? onPoll,
  }) async {
    final version = negotiate(notebookPollingApi, const [1]);
    final started = await api.call(
      notebookPollingApi,
      'archive',
      preferredVersion: version,
      params: {'object_id': js(objectId), 'enable': js(enable)},
    );
    final taskId = asText(started['task_id']);
    if (taskId.isEmpty) {
      throw DsmApiException(
        120,
        method: '$notebookPollingApi.archive',
        raw: started,
      );
    }
    for (var i = 0; i < pollingMaxPolls; i++) {
      if (i > 0) await Future<void>.delayed(pollingInterval);
      onPoll?.call(i);
      final status = await api.call(
        notebookPollingApi,
        'archive_status',
        preferredVersion: version,
        params: {'task_id': js(taskId)},
      );
      final errors = status['errors'];
      if (errors is Map && errors.isNotEmpty) {
        throw DsmApiException(
          asEpoch(errors['code']),
          method: '$notebookPollingApi.archive_status',
          raw: status,
        );
      }
      if (status['finish'] == true) {
        // 官方在 archive_stop 之后才回调（pollingArchiveNotebookDone）
        await api.call(
          notebookPollingApi,
          'archive_stop',
          preferredVersion: version,
          params: {'task_id': js(taskId)},
        );
        return;
      }
    }
    // 超时：如实报（119 = 任务没在预期时间内结束），不假装成功
    throw DsmApiException(119, method: '$notebookPollingApi.archive_status');
  }

  // ---------------------------------------------------------------- 智能笔记本

  /// `SYNO.NoteStation.Smart / list` v1 —— 自己的智能笔记本。
  ///
  /// [E2] 官方 `callables/SyncPullCallable.generateSmartListJsonObject`：
  /// `{api, method:"list", version:1, field:{query:true}}`；回包
  /// `SmartListVo.data.smarts[]`（每项就是 `SmartVo.data`，带 `query`）。
  Future<List<SmartNotebookDto>> listSmartNotebooks() async {
    final data = await api.call(
      smartApi,
      'list',
      preferredVersion: negotiate(smartApi, const [1]),
      params: {
        'field': js({'query': true}),
      },
    );
    final list = data['smarts'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => SmartNotebookDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// `SYNO.NoteStation.Smart / get` v1（官方 `ApiNSSmart.Method.GET`）。
  Future<SmartNotebookDto> getSmartNotebook(String objectId) async {
    final data = await api.call(
      smartApi,
      'get',
      preferredVersion: negotiate(smartApi, const [1]),
      params: {'object_id': js(objectId)},
    );
    return SmartNotebookDto.fromJson(data);
  }

  /// `SYNO.NoteStation.Smart / create` v1。
  ///
  /// [E2] 官方 `callables/operations/CreateSmartOperation.createSmart`：
  /// `title`（Gson）、`query`（Gson 的 `SmartVo.QueryVo`）、
  /// `commit_msg`（Gson 的 `{device: Build.MODEL}`）。
  Future<String> createSmartNotebook({
    required String title,
    required NoteSmartQuery query,
  }) async {
    final data = await api.call(
      smartApi,
      'create',
      preferredVersion: negotiate(smartApi, const [1]),
      params: {
        'title': js(title),
        'query': js(query.toJson()),
        'commit_msg': js({'device': deviceName}),
      },
    );
    return asText(data['object_id']);
  }

  /// `SYNO.NoteStation.Smart / set` v1。
  ///
  /// [E2] 官方 `SetSmartOperation.setSmart`：`object_id` 必发；
  /// `title` / `query` **只在非空时发**（`TextUtils.isEmpty` / `!= null`）。
  Future<void> updateSmartNotebook({
    required String objectId,
    String? title,
    NoteSmartQuery? query,
  }) => api.call(
    smartApi,
    'set',
    preferredVersion: negotiate(smartApi, const [1]),
    params: {
      'object_id': js(objectId),
      if (title != null && title.isNotEmpty) 'title': js(title),
      if (query != null) 'query': js(query.toJson()),
    },
  );

  /// `SYNO.NoteStation.Smart / delete` v1（`object_id`）
  Future<void> deleteSmartNotebook(String objectId) => api.call(
    smartApi,
    'delete',
    preferredVersion: negotiate(smartApi, const [1]),
    params: {'object_id': js(objectId)},
  );

  // ---------------------------------------------------------------- 笔记

  /// `SYNO.NoteStation.Note / list`。
  ///
  /// 官方 App 就是"全量拉下来本地筛"（`SyncPullCallable.generateNoteListJsonObject`
  /// 不带 notebook 过滤，靠本地 SQLite 查）—— 我们也一样：一次拿回标题/摘要/时间，
  /// 打开某条时才 `get` 正文。
  Future<({List<NoteDto> notes, int total})> listNotes({
    int offset = 0,
    int limit = 0,
    String sortBy = 'mtime',
    String sortDirection = 'desc',
    List<String>? tags,
    String? tagOperator,
  }) async {
    final v = negotiate(noteApi, const [4, 3, 2, 1]);
    final params = <String, dynamic>{
      'field': _field(),
      if (offset > 0) 'offset': offset,
      if (limit > 0) 'limit': limit,
      if (sortBy.isNotEmpty) 'sort_by': sortBy,
      if (sortDirection.isNotEmpty) 'sort_direction': sortDirection,
      // G4：标签过滤 + AND/OR 操作符。官方 Web `NotePanel.query_params`
      // 就是这两个字段（见 [tagOperatorAnd] / [tagOperatorOr]）：
      // `tag:[…]` + `tag_operator:"and"|"or"`。
      if (tags != null && tags.isNotEmpty) 'tag': js(tags),
      if (tags != null && tags.isNotEmpty && tagOperator != null)
        'tag_operator': js(tagOperator),
    };
    final data = await api.call(
      noteApi,
      'list',
      preferredVersion: v,
      params: params,
    );
    final list = data['notes'];
    final notes = list is List
        ? list
              .whereType<Map>()
              .map((e) => NoteDto.fromJson(Map<String, dynamic>.from(e)))
              .toList()
        : <NoteDto>[];
    return (notes: notes, total: asEpoch(data['total']));
  }

  /// `SYNO.NoteStation.FTS / search` v1 —— 全文检索（全局搜索的笔记来源）。
  ///
  /// **基础参数形态逐字来自官方 Universal Search 插件**：
  /// `/tmp/spk/export_NoteStation/ui/notestation_finder.js`
  /// （`SYNO.SDS.NoteStation.SynoFinder.Plugin.getSearchParam`）里
  /// ```js
  /// var b=Ext.apply({api:"SYNO.NoteStation.FTS",version:1,method:"search",
  ///                  keyword:f,offset:e,limit:d},i);
  /// ```
  /// （`f` = 关键词，`e` = offset，`d` = limit）；响应里的结果数组是
  /// `matches`（同文件 `getSearchResults`：`a.result[0].data.matches`）。
  /// 因此这里**不猜字段名**。
  ///
  /// ## G3 高级搜索的可选条件 —— **真机只读行为对照**（不是"发了不报错"）
  ///
  /// 2026-09-22 用 `/tmp/live_probe_lib.py`（GET-only）对 DSM 7.2 / 普通用户
  /// 做**行为对照**：同一 `keyword=test` 下把候选过滤条件设成**必然排除该笔记**
  /// 的值，看 `data.matches` 是否变空。**只有变空才说明参数真在服务端起过滤**。
  ///
  /// ✅ **真起过滤（行为已证）**：
  ///   * `title`（标题包含）—— `title=zzz` → 0 条；`title=test` → 1 条；
  ///     且 `title` **可脱离 keyword 单独用**（`{title:"test"}` → 1 条）。
  ///   * `tag`（**标签 id**，如 `test@1028`；字符串或数组都吃）
  ///     —— `tag=zzz_nope` → 0 条。数组是 **OR/并集**：
  ///     `tag=["test@1028","zzz_nope@1028"]` → 1 条。
  ///   * `parent_id`（笔记本 id；字符串或数组都吃）—— `parent_id=zzz_nope` → 0 条。
  ///   * `mtime_start` / `mtime_end` / `ctime_start` / `ctime_end`
  ///     （**epoch 秒**）—— `mtime_start=<未来>` → 0 条。命名与官方
  ///     `SmartVo.QueryVo` 一致（`mtime_start`/`mtime_end`/`ctime_start`/`ctime_end`）。
  ///   * `offset` / `limit` —— `offset=10` → 0 条；`limit=0` → 0 条。
  ///
  /// ❌ **被服务端忽略（发了不报错但不过滤，行为已证）**：
  ///   `note_title`、`title_contains`、`notebook`、`parent_ids`、`notebooks`、
  ///   `date_from`、`date_to`、`start_date`、`end_date`、`date_start`、`date_end`、
  ///   `time_from`、`time_to`、`mtime_from`、`mtime_to`、
  ///   `exclude_tag`、`exclude_tags`、`tag_exclude_subtag`、`smart_id`。
  ///
  /// ⚠️ **本条修正** `docs/evidence-gap-resolution-2026-09-22.md` §4：那里据
  /// "既非 114 也非 120 ⇒ 名称可用"记 `date_from`/`date_to`/`notebook`/`note_title`
  /// 可用；行为对照证明它们**只是被静默忽略**。真正可用的日期名是
  /// `mtime_start/end`、`ctime_start/end`。
  ///
  /// ⚠️ `tag_exclude_subtag`（G7）**没有任何服务端过滤效果** ⇒ 排除子标签
  /// 只能是**客户端**行为（官方 Android 也确实如此，见
  /// `fragments/NoteListFragment.java:151-160,380-430,935-945` 的
  /// `TagMode.EXCLUSIVE/INCLUDE`）；本方法的 Dart 侧调用方自行做客户端排除。
  ///
  /// 所有条件对**已设置**的都下发；未设置的**不发**（Gson 默认忽略 null）。
  /// `keyword` 为空时**不发**（真机：空 keyword 回 0 条），以便"只按标题/
  /// 标签/时间搜"。
  Future<List<NoteDto>> searchNotes({
    String keyword = '',
    String? title,
    List<String>? tagIds,
    List<String>? parentIds,
    int? mtimeStart,
    int? mtimeEnd,
    int? ctimeStart,
    int? ctimeEnd,
    int offset = 0,
    int limit = 50,
  }) async {
    final trimmedTitle = (title ?? '').trim();
    final data = await api.call(
      ftsApi,
      'search',
      preferredVersion: negotiate(ftsApi, const [1]),
      params: {
        if (keyword.trim().isNotEmpty) 'keyword': keyword,
        if (trimmedTitle.isNotEmpty) 'title': js(trimmedTitle),
        if (tagIds != null && tagIds.isNotEmpty) 'tag': js(tagIds),
        if (parentIds != null && parentIds.isNotEmpty)
          'parent_id': js(parentIds),
        'mtime_start': ?mtimeStart,
        'mtime_end': ?mtimeEnd,
        'ctime_start': ?ctimeStart,
        'ctime_end': ?ctimeEnd,
        'offset': offset,
        'limit': limit,
      },
    );
    final list = data['matches'];
    return list is List
        ? list
              .whereType<Map>()
              .map((e) => NoteDto.fromJson(Map<String, dynamic>.from(e)))
              .toList()
        : <NoteDto>[];
  }

  /// `SYNO.NoteStation.Note / get` v1 —— 取一条笔记（含正文 HTML）
  Future<NoteDto> getNote(String objectId, {String? ver}) async {
    final data = await api.call(
      noteApi,
      'get',
      preferredVersion: 1,
      params: {
        'object_id': js(objectId),
        'field': js({'individual_shared': true}),
        if (ver != null && ver.isNotEmpty) 'ver': js(ver),
      },
    );
    return NoteDto.fromJson(data);
  }

  /// Web Clipper（浏览器扩展）的入参：**顶层** `source_url` / `clipper_url` /
  /// `clipper_mode` / `clipper_user_agent`。
  ///
  /// 逐字证据（官方 NoteStation-x86_64-2.6.10-3938）：
  ///   * `webapi/note/SYNO.NoteStation.Note.so` 里有这些字面量
  ///     （文件偏移 301953 `source_url`、301813 `clipper_mode`、
  ///     301826 `clipper_url`、301838 `clipper_user_agent`、301978 `clipper`、
  ///     302020 `clipper_error_type`）；
  ///   * 反汇编（`objdump -d`，同 .so）在 0x1f514 / 0x1f54f / 0x1f589 处
  ///     以 `clipper_mode` / `clipper_url` / `clipper_user_agent` 为 key、
  ///     从**顶层参数对象**取值 —— 所以这三个字段与 `source_url` 平级；
  ///   * 官方包 `ui/notestation.js` 的 `SYNO.NoteStation.*` 名里**没有 Clipper
  ///     API**（只有 `Utils.clipperExtensionId` 指向 Chrome 扩展
  ///     `pcfbfimijgibligmbglggnbiobgjgmbk`）→ 扩展就是借 `Note/create` /
  ///     `Note/set` 写入，因此这里把它补成同一批可选字段。
  ///
  /// 官方剪藏 UA（[E2] `ClipperService.java` 的 `MOBILE_USER_AGENT` /
  /// `TABLET_USER_AGENT` 常量**逐字原文**）：
  ///
  /// ```java
  /// private static final String MOBILE_USER_AGENT = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko) Chrome/40.0.2214.89 Mobile Safari/537.36";
  /// private static final String TABLET_USER_AGENT = "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko) Chrome/40.0.2214.89 Safari/537.36";
  /// ```
  ///
  /// 选择规则同官方：`DeviceUtil.isTablet(ctx) && !DeviceUtil.is7inchTablet(ctx)`
  /// → 平板 UA，否则移动 UA。Dart 侧没有可靠的设备形态探测，**默认发移动 UA**
  /// （服务端只拿它去抓网页，二者都是官方法定取值）。
  static const String clipperMobileUserAgent =
      'Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/40.0.2214.89 Mobile Safari/537.36';

  static const String clipperTabletUserAgent =
      'Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/40.0.2214.89 Safari/537.36';

  /// `clipper_mode` 的两个官方取值（[E2] `ClipperService.createNoteByURL`）：
  ///
  /// ```java
  /// if (Intrinsics.areEqual(retrieveType, "whole"))            clipMode = "fullpage";
  /// else if (Intrinsics.areEqual(retrieveType, "simplified"))  clipMode = "simplepage";
  /// else                                                       clipMode = "simplepage";
  /// ```
  /// 注意 `retrieveType` 来自设置键 `Common.CLIPPER_RETRIEVE_TYPE`
  /// （= `"clipper_retrieve_type"`），取值 `simplified` / `whole`。
  static const String clipperModeSimplified = 'simplepage';
  static const String clipperModeFull = 'fullpage';

  /// 由 `clipper_retrieve_type` 设置值映射出 `clipper_mode`（官方规则）
  static String clipperModeFor(String retrieveType) =>
      retrieveType == 'whole' ? clipperModeFull : clipperModeSimplified;

  /// 我们**额外**在 `Note/create` 顶层携带 `source_url`（官方 Android 剪藏
  /// **不发**它，见 U8；官方只在 `EditSourceURLDialogFragment` 走 `Note/set`
  /// 写这条元数据）。`NoteStation.Note.so` 里确有 `source_url` 字面量且从顶层
  /// 取值，所以保留为**本项目的扩展**；剪藏主路径不再带它。
  static Map<String, dynamic> clipperParams({
    required String sourceUrl,
    String? clipperUrl,
    String? clipperMode,
    String? clipperUserAgent,
    bool allowEmptySourceUrl = false,
  }) => {
    // N3：`Note/set` 的 `source_url` 要能**清空**（官方 Web `Info.Panel` 允许
    // 把来源链接改成空串），所以 set 路径传 `allowEmptySourceUrl: true`；
    // `Note/create` 保持旧行为（空串就不发这个字段）。
    if (sourceUrl.isNotEmpty || allowEmptySourceUrl)
      'source_url': js(sourceUrl),
    if (clipperUrl != null && clipperUrl.isNotEmpty)
      'clipper_url': js(clipperUrl),
    if (clipperMode != null && clipperMode.isNotEmpty)
      'clipper_mode': js(clipperMode),
    if (clipperUserAgent != null && clipperUserAgent.isNotEmpty)
      'clipper_user_agent': js(clipperUserAgent),
  };

  /// `SYNO.NoteStation.Note / create`（**v3**）—— 新建（`ctime` 由客户端给，服务端认）。
  ///
  /// ★ 参数全集按官方 `ui/notestation.js` 的 `create` + 真机写入批次取证
  ///   （`docs/live-write-verification.md` §5.4）：
  ///   `{title, parent_id, encrypt, content, brief, ctime, mtime, latitude,
  ///     longitude}`，外加**必需的外壳** `commit_msg{device, listable:false}`。
  ///   * **版本是 3**：官方 UI 明确 `version:3`（真机 `{}`/`{notebook_id}` → `114`）；
  ///   * **是 `parent_id`，不是 `notebook_id`** —— 真机 `{notebook_id}` → `114`；
  ///   * `commit_msg` 少了它服务端按"缺参数"处理（客户端历史上那条 `114` 就出在这里）。
  ///
  /// ⚠️ 普通笔记的**真机路径**曾走 `Note.Polling/create`（加密/大笔记，DV:1747），
  /// 因此这条直连分支历史上没有真机证据（审计 U13）；本批按官方真形状
  /// （v3 + `commit_msg` + `parent_id`）修正，仍未上真机（见未验证边界）。
  Future<({String objectId, String ver})> createNote({
    required String title,
    required String parentId,
    String html = '',
    String brief = '',
    bool encrypt = false,
    int? ctime,
    int? mtime,
    double? latitude,
    double? longitude,
    String? sourceUrl,
    String? clipperUrl,
    String? clipperMode,
    String? clipperUserAgent,
  }) async {
    final data = await api.call(
      noteApi,
      'create',
      preferredVersion: negotiate(noteApi, const [3]),
      params: {
        'title': js(title),
        'parent_id': js(parentId),
        'ctime': js(noteEpochSecondsNormalize(ctime ?? noteEpochSeconds())),
        if (mtime != null) 'mtime': js(noteEpochSecondsNormalize(mtime)),
        // 真机参数全集里 encrypt 是**常发字段**（官方 JS 也是每次都发）
        'encrypt': js(encrypt),
        if (html.isNotEmpty) 'content': js(html),
        if (brief.isNotEmpty) 'brief': js(brief),
        if (latitude != null) 'latitude': js(latitude),
        if (longitude != null) 'longitude': js(longitude),
        if (sourceUrl != null)
          ...clipperParams(
            sourceUrl: sourceUrl,
            clipperUrl: clipperUrl,
            clipperMode: clipperMode,
            clipperUserAgent: clipperUserAgent,
          ),
        // 必需外壳（真机 §5.4：create 的 commit_msg 带 listable:false）
        'commit_msg': js(commitMsg()),
      },
    );
    return (objectId: asText(data['object_id']), ver: asText(data['ver']));
  }

  /// 服务端是否支持官方剪藏优先的 `Note.Ghost/create` v2。
  ///
  /// 官方判定：`NetUtils.supportApi(ctx, ApiNSNoteGhost.NAME, 2)`。
  bool supportsGhostCreate() {
    final entry = api.apiTable?[noteGhostApi];
    if (entry == null) return false;
    return entry.minVersion <= 2 && entry.maxVersion >= 2;
  }

  /// `SYNO.NoteStation.Note.Ghost / create` **v2** —— 剪藏**优先**路径。
  ///
  /// [E2] `ClipperService.createNoteByURL` 的参数与顺序（逐条对照）：
  /// ```java
  /// apiNSNote.putParam("clipper_url", gson.toJson(urlString));
  /// apiNSNote.putParam("title",       gson.toJson(subject));
  /// apiNSNote.putParam("clipper_mode", gson.toJson(mode));      // simplepage/fullpage
  /// apiNSNote.putParam("parent_id",   gson.toJson(remoteNotebookId));
  /// if (tags != null && !tags.isEmpty()) apiNSNote.putParam("tag", gson.toJson(tagTitles));
  /// jsonObject.addProperty("device", Build.MODEL);
  /// apiNSNote.putParam("commit_msg",  gson.toJson(jsonObject)); // **只有 device**
  /// apiNSNote.putParam("clipper_user_agent", gson.toJson(ua));
  /// ```
  /// **不发** `content`（服务端按 `clipper_url` 抓正文）、**不发** `source_url`。
  /// 回包是 `BasicVo`（只有 success/error，**没有 `object_id`** —— 新笔记要等
  /// 一次 sync 才出现，官方是 5s 后触发 `SyncService` PULL）。
  Future<void> createGhostNote({
    required String url,
    required String title,
    required String parentId,
    required String clipperMode,
    String? clipperUserAgent,
    List<String> tags = const [],
  }) => api.call(
    noteGhostApi,
    'create',
    preferredVersion: negotiate(noteGhostApi, const [2]),
    params: {
      'clipper_url': js(url),
      'title': js(title),
      'clipper_mode': js(clipperMode),
      'parent_id': js(parentId),
      if (tags.isNotEmpty) 'tag': js(tags),
      // 官方的 Ghost commit_msg **只有 device**（没有 listable）
      'commit_msg': js({'device': deviceName}),
      'clipper_user_agent': js(
        (clipperUserAgent == null || clipperUserAgent.isEmpty)
            ? clipperMobileUserAgent
            : clipperUserAgent,
      ),
    },
  );

  /// 剪藏**回退**路径：官方在 Ghost 不支持时用 `Note/create` **v2**，
  /// 参数与 [createGhostNote] 同集合（同样不发 `content` / `source_url`）。
  /// 返回 `object_id`（服务端可能给也可能不给，不给则空串）。
  Future<String> createClipperNote({
    required String url,
    required String title,
    required String parentId,
    required String clipperMode,
    String? clipperUserAgent,
    List<String> tags = const [],
  }) async {
    final data = await api.call(
      noteApi,
      'create',
      // ClipperService 回退时写死 `setApiVersion(2)`
      preferredVersion: negotiate(noteApi, const [2]),
      params: {
        'clipper_url': js(url),
        'title': js(title),
        'clipper_mode': js(clipperMode),
        'parent_id': js(parentId),
        if (tags.isNotEmpty) 'tag': js(tags),
        'commit_msg': js({'device': deviceName}),
        'clipper_user_agent': js(
          (clipperUserAgent == null || clipperUserAgent.isEmpty)
              ? clipperMobileUserAgent
              : clipperUserAgent,
        ),
      },
    );
    return asText(data['object_id']);
  }

  /// `SYNO.NoteStation.Note / set` v2 —— 保存。
  ///
  /// `ver` 是乐观锁：必须回传最近一次 `get`/`list` 给的版本号，
  /// 否则服务端会拒（冲突）。只传要改的字段。
  ///
  /// ★ N4 位置字段（`latitude`/`longitude`/`location`）的**发与不发**逐字对齐
  ///   官方 `callables/operations/SetNoteOperation.java:233-244`：
  ///   ```java
  ///   Double d = this.mData.latitude;  if (d != null)  t.putParam("latitude",  sGson.toJson(d));
  ///   Double d2 = this.mData.longitude; if (d2 != null) t.putParam("longitude", sGson.toJson(d2));
  ///   String str2 = this.mData.location; if (!TextUtils.isEmpty(str2)) t.putParam("location", sGson.toJson(str2));
  ///   ```
  ///   即：坐标是 **JSON 数字**（`25.05` 而不是 `"25.05"`）、**非 null 就发**
  ///   （`0` 也发 —— 官方"删除 GPS"就是写 0/0）；`location` **只在非空时发**
  ///   （空串清不掉位置名，与官方一致）。
  Future<NoteDto?> setNote({
    required String objectId,
    required String ver,
    String? title,
    String? html,
    String? parentId,
    List<String>? tags,
    bool? encrypt,
    String? token,
    int? mtime,
    int? ctime,
    String? sourceUrl,
    String? brief,
    String? clipperUrl,
    String? clipperMode,
    String? clipperUserAgent,
    double? latitude,
    double? longitude,
    String? location,
  }) async {
    final params = <String, dynamic>{
      'object_id': js(objectId),
      'ver': js(ver),
      if (title != null) 'title': js(title),
      if (html != null) 'content': js(html),
      if (parentId != null) 'parent_id': js(parentId),
      if (tags != null) 'tag': js(tags),
      if (encrypt != null) 'encrypt': js(encrypt),
      // 加密笔记解锁后保存要带 token（官方 Web `setNote` 的 token 字段）
      if (token != null && token.isNotEmpty) 'token': js(token),
      if (mtime != null) 'mtime': js(noteEpochSecondsNormalize(mtime)),
      if (ctime != null) 'ctime': js(noteEpochSecondsNormalize(ctime)),
      if (sourceUrl != null)
        ...clipperParams(
          sourceUrl: sourceUrl,
          clipperUrl: clipperUrl,
          clipperMode: clipperMode,
          clipperUserAgent: clipperUserAgent,
          allowEmptySourceUrl: true,
        ),
      if (brief != null) 'brief': js(brief),
      // N4：位置（APK SetNoteOperation.java:233-244 逐字）
      if (latitude != null) 'latitude': js(latitude),
      if (longitude != null) 'longitude': js(longitude),
      if (location != null && location.isNotEmpty) 'location': js(location),
      // 官方每个写操作都带 commit_msg（版本历史里显示来源设备）
      'commit_msg': js({'device': deviceName}),
    };
    final data = await api.call(
      noteApi,
      'set',
      preferredVersion: negotiate(noteApi, const [2, 1]),
      params: params,
    );
    // ★ `Note/set` 的回包形状与 `list`/`get` **不一样**（反编译 NoteVoV2）：
    //   `{data: {data: [noteVo…], errors: [{code, object_id}…]}}`
    //   一个请求可以同时成功几条、失败几条。
    return _unwrapSetResponse(data, '$noteApi.set');
  }

  /// 解 `Note/set` 的 `{data:[…], errors:[…]}` 回包
  NoteDto? _unwrapSetResponse(Map<String, dynamic> data, String what) {
    final inner = data['data'];
    if (inner is List && inner.isNotEmpty) {
      final first = inner.first;
      if (first is Map) {
        return NoteDto.fromJson(Map<String, dynamic>.from(first));
      }
    }
    final errors = data['errors'];
    if (errors is List && errors.isNotEmpty) {
      final e = errors.first;
      final code = e is Map ? asEpoch(e['code']) : 0;
      throw DsmApiException(code, method: what, raw: {'errors': errors});
    }
    return null;
  }

  /// 加密笔记的解锁令牌时长（秒）。
  ///
  /// 官方两个客户端不一致：Web 给 120、Android 给 **600**
  /// （`SetNoteOperation.createToken` 里 `duration: 600`）。这里对齐 **Android**，
  /// 少一点来回解锁的打扰。
  static const int unlockDurationSeconds = 600;

  /// `SYNO.NoteStation.Note.Encrypt / create` v1 —— 换取"解锁令牌"。
  ///
  /// ★ 参数按 **Android DS note 1.12.0-346** 的做法走 DSM 的 CGI 参数加密
  ///   （`SYNO.API.Encryption getinfo` → `CgiEncryption`）：先把
  ///   `object_id/password/duration` 拼成明文串，用服务端给的 RSA 公钥加密后
  ///   以 `cipher_key=<base64>` 单个字段提交。Web 端图省事直接发明文 password，
  ///   服务端两种都收，我们跟手机端保持一致（口令不裸奔）。
  Future<String> createEncryptToken({
    required String objectId,
    required String password,
    String? sessionPassword,
    int duration = unlockDurationSeconds,
  }) async {
    final info = await api.call(
      'SYNO.API.Encryption',
      'getinfo',
      preferredVersion: 1,
      requiresAuth: false,
    );
    final cipher = _cipherFactory(DsmCipherData.fromJson(info));
    final params = cipher.encryptFromParamList({
      'object_id': objectId,
      'password': password,
      'duration': '$duration',
    });
    final data = await api.call(
      encryptApi,
      'create',
      preferredVersion: 1,
      params: params,
    );
    return asText(data['token']);
  }

  /// `SYNO.NoteStation.Note.Encrypt / check` v1 —— 令牌还有效吗。
  ///
  /// 官方语义：**有效时接口成功、失效时接口报错**（Android
  /// `SetNoteOperation.checkToken` 就是"失败 → 重新 create"），所以这里把
  /// 异常吞成 `false`。
  Future<bool> checkEncryptToken({
    required String objectId,
    required String token,
  }) async {
    if (token.isEmpty) return false;
    try {
      await api.call(
        encryptApi,
        'check',
        preferredVersion: 1,
        params: {'object_id': js(objectId), 'token': js(token)},
      );
      return true;
    } on DsmApiException {
      return false;
    }
  }

  /// `SYNO.NoteStation.Note.Encrypt / delete` v1 —— 主动丢弃解锁令牌。
  Future<void> deleteEncryptToken({
    required String objectId,
    required String token,
  }) async {
    if (token.isEmpty) return;
    await api.call(
      encryptApi,
      'delete',
      preferredVersion: 1,
      params: {'object_id': js(objectId), 'token': js(token)},
    );
  }

  /// `SYNO.NoteStation.Note / delete` v1（`recycle=true` 进回收站）
  Future<void> deleteNote(String objectId, {bool recycle = true}) => api.call(
    noteApi,
    'delete',
    preferredVersion: 1,
    params: {'object_id': js(objectId), 'recycle': js(recycle)},
  );

  /// 服务端是否支持 `object_id` 装**数组**的批量写（`Note` v3）。
  ///
  /// 官方 **Web** 客户端（NoteStation-x86_64-2.6.10-3938 的 `ui/notestation.js`）
  /// 的 list/set/delete 全部写死 `version:3`，批量操作把 id 数组塞进同一个
  /// `object_id` 字段；`Note` v3 才收数组，v1 只收标量。
  bool get supportsNoteBatch => (api.apiTable?[noteApi]?.maxVersion ?? 0) >= 3;

  /// `SYNO.NoteStation.Note / delete` **v3** —— 批量删除。
  ///
  /// ★ 取证（官方 Web 客户端 `ui/notestation.js`）：
  ///   * `SYNO.SDS.NoteStation.Storage.deleteNoteAsync`：
  ///     `sendWebAPIPromise({api:"SYNO.NoteStation.Note", version:3,
  ///       method:"delete", params:Ext.copyTo({},t,
  ///       "object_id,recycle,perm_from,smart_id")})` —— `t.object_id` **原样透传**；
  ///   * `emptyRecycleBin` 直接把整筐 id 数组传进 `deleteNoteAsync`；
  ///   * 调用点 `Object.assign({object_id:t}, e)`，`t` 可为**数组**。
  ///
  /// 也就是说：单条是标量、批量是同一个 `object_id` 字段装**数组**（服务端两种
  /// 都收）。Android `DeleteNoteOperation`（v1 标量 + 逐条循环）是另一条官方实现，
  /// 本方法在 v3 不可用时也退回那条路径（见下）。
  ///
  /// 回包是 `BasicVo`（只有 success/error，**没有逐条错误列表**）—— 与官方 Web
  /// 一致：批量删除只能整体成功/失败。老服务端（`Note` maxVer < 3）退回逐条
  /// 标量调用并把失败项收集成 [NoteBatchResult]，让 UI 能逐条回报。
  Future<NoteBatchResult> deleteNotes(
    List<String> objectIds, {
    bool recycle = true,
  }) async {
    if (objectIds.isEmpty) {
      return const NoteBatchResult(objectIds: []);
    }
    if (supportsNoteBatch) {
      await api.call(
        noteApi,
        'delete',
        preferredVersion: negotiate(noteApi, const [3, 2, 1]),
        params: {'object_id': js(objectIds), 'recycle': js(recycle)},
      );
      return NoteBatchResult(objectIds: objectIds);
    }
    // 回退：v1 标量逐条（官方 Android `DeleteNoteLoader` 就是这么做的）
    final failed = <String, int>{};
    for (final id in objectIds) {
      try {
        await deleteNote(id, recycle: recycle);
      } on DsmApiException catch (e) {
        failed[id] = e.code;
      }
    }
    return NoteBatchResult(objectIds: objectIds, failed: failed);
  }

  /// `SYNO.NoteStation.Note / set` —— 批量移动到同一笔记本（`object_id` 数组）。
  ///
  /// ★ 取证（官方 Web 客户端 `ui/notestation.js`）：
  ///   * `moveNotesToNotebook`：`n = Ext.apply({}, {parent_id:e, object_id:t})`
  ///     后调 `getStorage().setNote(n)`，`t` 是**选中的 id 数组**；
  ///   * `Storage.setNote` 写死 `version:3`，把 `object_id` 原样透传，并在回包处
  ///     明确分支 `if (!0!==e || Ext.isArray(t.object_id)) return void callback(...)`
  ///     —— **数组 `object_id` 是官方认可形态**；
  ///   * 回包 `{data:[noteVo…], errors:[{code, object_id}…]}`，逐条成败都带。
  ///
  /// 老服务端（v3 不可用）退回逐条 `setNote` 并在本地汇总失败项。
  Future<NoteBatchResult> moveNotes(
    List<String> objectIds, {
    required String parentId,
  }) async {
    if (objectIds.isEmpty) {
      return const NoteBatchResult(objectIds: []);
    }
    if (!supportsNoteBatch) {
      final failed = <String, int>{};
      for (final id in objectIds) {
        try {
          final current = await getNote(id);
          await setNote(objectId: id, ver: current.ver, parentId: parentId);
        } on DsmApiException catch (e) {
          failed[id] = e.code;
        }
      }
      return NoteBatchResult(objectIds: objectIds, failed: failed);
    }
    final data = await api.call(
      noteApi,
      'set',
      preferredVersion: negotiate(noteApi, const [3, 2, 1]),
      params: {
        'object_id': js(objectIds),
        'parent_id': js(parentId),
        'commit_msg': js({'device': deviceName}),
      },
    );
    final failed = <String, int>{};
    final errors = data['errors'];
    if (errors is List) {
      for (final e in errors) {
        if (e is Map) failed[asText(e['object_id'])] = asEpoch(e['code']);
      }
    }
    return NoteBatchResult(objectIds: objectIds, failed: failed);
  }

  /// `SYNO.NoteStation.Note / copy` v1 —— 复制笔记（也用于加密↔明文转换）。
  ///
  /// 两处证据（互为补充）：
  /// * 官方 Web `Info.History.Preview.Window.onClickCopyTo`（`ui/notestation.js`）
  ///   —— `copyNote({object_id, title, parent_id, ver})`，`ver` 是**要复制的那一版**；
  /// * 官方 Android [E2] `callables/operations/CopyNoteOperation.copyNote`：
  ///   `object_id` / `title` / `parent_id` **都发**；转换加密态时再加
  ///   `encrypt`（Gson 布尔）与 `content`（Gson 字符串）：
  ///   - **明文 → 加密** / 加密 → 加密：`encrypt=true` + `content`（已加密正文）
  ///   - **加密 → 明文**：`encrypt=false` + `content`（已解密正文）
  ///   - 普通复制（NONE）：不发这两个字段
  ///   （`CopyMoveDialogFragment.EncAction.PLAIN_TO_ENCRYPT/ENCRYPT_TO_PLAIN`）。
  ///
  /// 有附件的加密转换官方走 `Note.Polling/copy` + `copy_status`/`copy_stop`；
  /// 本方法只覆盖 **`Note/copy` 一次性**分支（无附件 / 纯转换场景）。
  Future<String> copyNote(
    String objectId, {
    String? parentId,
    String? title,
    String? ver,
    bool? encrypt,
    String? content,
  }) async {
    final data = await api.call(
      noteApi,
      'copy',
      preferredVersion: 1,
      params: {
        'object_id': js(objectId),
        if (parentId != null) 'parent_id': js(parentId),
        if (title != null && title.isNotEmpty) 'title': js(title),
        if (ver != null && ver.isNotEmpty) 'ver': js(ver),
        if (encrypt != null) 'encrypt': js(encrypt),
        if (content != null) 'content': js(content),
      },
    );
    return asText(data['object_id']);
  }

  /// `Note.Polling / copy` + `cipher_key` —— **改口令**（带附件的加密笔记）。
  ///
  /// ★ 取证（APK `callables/operations/CopyNoteOperation.copyEncrypt` +
  ///   `encryptParams`，字节级对照 `smali_classes2/.../CopyNoteOperation.smali`
  ///   `:88-254`）：
  ///   * 方法：`SYNO.NoteStation.Note.Polling / copy`
  ///     （服务端 `.lib`：v1/v2/v3 都有 `copy`；本仓库既有轮询走 v3）；
  ///   * 参数：`object_id` / `title` / `parent_id`（Gson 串）、加密转换时
  ///     `encrypt=true`、非空时 `content`（客户端**已用新口令重加密**的密文），
  ///     再并入 `encryptParams()` 的产物；
  ///   * `encryptParams()` = `SYNO.API.Encryption / getinfo` 取公钥后
  ///     `CgiEncryption.encryptFromParamList([old_password,new_password])`
  ///     ⇒ **单个** `cipher_key=<base64>` 字段（与 [createEncryptToken] 同一套
  ///     `DsmCgiEncryption`）。**不需要**官方 Web 的顶层
  ///     `encryption:["old_password","new_password"]` —— 那是 `synowebapi`
  ///     传输层选项，`DsmWebApi.call()` 只收 `params`（`lib/src/dsm/**` 禁改）；
  ///     Android 的 `cipher_key` 路线语义等价且口令不裸奔。
  ///   * 之后 `copy_status {task_id}` 轮询 → `copy_stop {task_id}`。
  ///
  /// 返回**新笔记**（官方改口令就是"复制一份再改标题"，见
  /// `ChangePasswordDialogFragment` / Web `Encrypt.Modify.Window`）。
  Future<String> copyNoteEncryptPolling({
    required String objectId,
    required String title,
    required String parentId,
    required String oldPassword,
    required String newPassword,
    required String encryptedContent,
    void Function(int poll)? onPoll,
  }) async {
    final info = await api.call(
      'SYNO.API.Encryption',
      'getinfo',
      preferredVersion: 1,
      requiresAuth: false,
    );
    final cipher = _cipherFactory(DsmCipherData.fromJson(info));
    final enc = cipher.encryptFromParamList({
      'old_password': js(oldPassword),
      'new_password': js(newPassword),
    });
    final data = await _runPolling('copy', {
      'object_id': js(objectId),
      'title': js(title),
      'parent_id': js(parentId),
      'encrypt': js(true),
      'content': js(encryptedContent),
      ...enc,
      'commit_msg': js({'device': deviceName}),
    }, onPoll: onPoll);
    if (data.isEmpty || data.first is! Map) {
      throw DsmApiException(119, method: '$pollingApi.copy');
    }
    final newId = asText((data.first as Map)['object_id']);
    if (newId.isEmpty) {
      throw DsmApiException(119, method: '$pollingApi.copy');
    }
    return newId;
  }

  /// `SYNO.NoteStation.Note / get_attachment_text` v4 —— 附件的文本预览
  Future<String> attachmentText(String objectId, String fileId) async {
    final data = await api.call(
      noteApi,
      'get_attachment_text',
      preferredVersion: negotiate(noteApi, const [4, 3, 2, 1]),
      params: {'object_id': js(objectId), 'file_id': js(fileId)},
    );
    return asText(data['text']);
  }

  /// `SYNO.NoteStation.Note / download` **v1** —— 附件**二进制下载**。
  ///
  /// ★ 第 118 轮（台账 J9 的剩余部分）取证：
  /// SPK 权威方法表 `NoteStation/webapi/SYNO.NoteStation.lib` 里
  /// `SYNO.NoteStation.Note` 的 v1 方法列表**含 `download`**，且带
  /// `"allowDownload": true, "skipCheckIP": true`（下载类特例）；
  /// 官方 APK 的 `net/ApiNSNote$Method` 枚举里也有 `"download"`。
  ///
  /// 走 `getBytes`（附件是**原始字节**，不是 JSON 信封）：URL 由
  /// `apiPath('SYNO.NoteStation.Note')` + `authenticatedUrl` 拼，参数与
  /// `get_attachment_text` 同形（`object_id` + `file_id`）—— 服务端这一族
  /// 附件接口都用这两个字段（`Attachment.file_id` 在上传回包里拿）。
  ///
  /// [onProgress] 交给传输层（大附件时页面能显示进度）。
  Future<List<int>> downloadAttachment(
    String objectId,
    String fileId, {
    void Function(int received, int total)? onProgress,
  }) async {
    final path = api.apiPath(noteApi);
    final url = api.authenticatedUrl(path, {
      'api': noteApi,
      'method': 'download',
      'version': '1',
      'object_id': objectId,
      'file_id': fileId,
    });
    return api.getBytes(url, onProgress: onProgress);
  }

  // ---------------------------------------------------------------- 版本

  /// `SYNO.NoteStation.Note.Version / list` v2 —— 版本历史。
  ///
  /// 参数逐字来自官方 Web（NoteStation-x86_64-2.6.10-3938 的 `ui/notestation.js`，
  /// `Info.History.Window.getHistoryGridPanel` 里的 `SYNO.API.Store`）：
  /// ```js
  /// baseParams:Ext.copyTo({object_id:this.noteId, limit:this.itemsPerPage,
  ///   filter:{listable:!0}}, this.owner.notePerm, "perm_from,smart_id")
  /// ```
  /// 其中 `itemsPerPage:100`；`perm_from`/`smart_id` 是共享笔记的权限上下文
  /// （本客户端目前不持有，留给调用方按需传）。回包 `{versions:[…], total}`，
  /// 版本行字段 `id/author/version/mtime/commit_msg/last_version`。
  ///
  /// ★ 真机复测（2026-09-22）：**v1** 只传 `{object_id: <JSON 串>}` 就回
  /// `count:4` 的完整版本列表（每版 6 字段 `author/commit_msg/id/last_version/
  /// mtime/version`）——所以 `limit`/`filter` 只在协商到 v2 时发。
  /// **主键是 `object_id`（不是 `id`）**，且要 Gson 二次编码。
  Future<List<Map<String, dynamic>>> listVersions(
    String objectId, {
    int limit = 100,
    String? permFrom,
    String? smartId,
  }) async {
    // `limit` + `filter` 是 **v2** 的形态（官方 Web `Info.History.Window`）。
    // v1 只认 `object_id`（真机复测逐字：`{object_id}` → 4 条版本），多发这两个
    // 参数在老服务端是"参数无效"。所以按**协商出来的版本**决定发不发。
    final version = negotiate(versionApi, const [2, 1]);
    final data = await api.call(
      versionApi,
      'list',
      preferredVersion: version,
      params: {
        'object_id': js(objectId),
        if (version >= 2) ...{
          'limit': limit,
          // `filter.listable:true` 官方就是这么发的（不是空对象）
          'filter': js({'listable': true}),
        },
        if (permFrom != null && permFrom.isNotEmpty) 'perm_from': js(permFrom),
        if (smartId != null && smartId.isNotEmpty) 'smart_id': js(smartId),
      },
    );
    final list = data['versions'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// `SYNO.NoteStation.Note.Version / get` v1 —— **官方 Web 不用它**。
  ///
  /// 预览某个版本内容时，官方走的是 `Note/get` + `ver`
  /// （`Info.History.Preview.Window.loadNote`：`getNote({object_id, ver:…})`），
  /// 所以本客户端沿用 [getNote]（见 `note_view_page.dart` 的版本预览），
  /// **不实现**这个方法：它的参数形态在包里没有原文证据（待取证，见文档）。

  /// 回滚到某个历史版本（`SYNO.NoteStation.Note.Version / restore` v2）。
  ///
  /// ★ 参数名是 **`ver`**，不是 `version` —— 两处原文互相印证：
  ///   1. 官方 Web `restoreNoteVersion`
  ///      （`ui/notestation.js`）：
  ///      `method:"restore",params:Ext.copyTo({},t,"object_id,ver,perm_from,smart_id")`
  ///      且 `onClickRestore` 传的 `t` 是 `this.noteData`（`{object_id, ver, …}`）；
  ///   2. 服务端 `webapi/note/SYNO.NoteStation.Note.so` 的
  ///      `RestoreSelf` 分支有 `!ver.Get(jParm)` 的字符串（该 .so 偏移 303257），
  ///      即 restore 从参数里取 `ver`。
  Future<void> restoreVersion(
    String objectId,
    String ver, {
    String? permFrom,
    String? smartId,
  }) => api.call(
    versionApi,
    'restore',
    preferredVersion: negotiate(versionApi, const [2, 1]),
    params: {
      'object_id': js(objectId),
      'ver': js(ver),
      if (permFrom != null && permFrom.isNotEmpty) 'perm_from': js(permFrom),
      if (smartId != null && smartId.isNotEmpty) 'smart_id': js(smartId),
    },
  );

  // ---------------------------------------------------------------- 标签 / 待办

  /// `SYNO.NoteStation.Tag / list`（v2 支持 `filter` 里的 owner 过滤）
  Future<List<TagDto>> listTags() async {
    final data = await api.call(
      tagApi,
      'list',
      preferredVersion: negotiate(tagApi, const [2, 1]),
      params: {'filter': js({})},
    );
    final list = data['tags'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => TagDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// `SYNO.NoteStation.Todo / list`
  Future<List<TodoDto>> listTodos({bool? done}) async {
    final data = await api.call(
      todoApi,
      'list',
      preferredVersion: negotiate(todoApi, const [2, 1]),
      params: done == null
          ? const {}
          : {
              'filter': js({'done': done}),
            },
    );
    final list = data['todos'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => TodoDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// `SYNO.NoteStation.Todo / list_timeout`（**v1 / v2 都有这个方法**）。
  ///
  /// ★ 取证：
  ///   * 服务端 `webapi/SYNO.NoteStation.lib` 的 `Todo` v1 与 v2 方法表里
  ///     `list` 旁边就是 `list_timeout`（`allowDemo`/`allowTimeout`，
  ///     `allowUser` 全含 `normal.*`，authLevel 1）；
  ///   * 回包与 `list` 同族（`TodoListVo.TodoListDataVo`：
  ///     `count` / `offset` / `total` / `todos[]`）；**空回包没有 `todos`**
  ///     ——真机逐字 `{"data":{"count":0,"offset":0,"total":0}}`。
  ///
  /// 分页参数是 `offset` / `limit`（与 `Todo/list` 同一套）；只为 0 时不发，
  /// 与 [listTodos] 的保守形态一致。
  Future<NoteTimeoutTodos> listTimeoutTodos({
    int offset = 0,
    int limit = 0,
  }) async {
    final data = await api.call(
      todoApi,
      'list_timeout',
      preferredVersion: negotiate(todoApi, const [2, 1]),
      params: {if (offset > 0) 'offset': offset, if (limit > 0) 'limit': limit},
    );
    return NoteTimeoutTodos.fromJson(data);
  }

  /// `SYNO.NoteStation.Shortcut / list` **v1** —— 快捷方式列表。
  ///
  /// [E2] 官方 `net/ApiNSShortcut.java` 只有 v1；Web 端的 `listShortcut`
  /// 也是 `{api:"SYNO.NoteStation.Shortcut",version:1,method:"list"}`
  /// （`ui/notestation.js`），复合调用 `listAllAsync` 里同样**不带参数**。
  ///
  /// 回包 `ShortcutsDataVo`：`{offset, total, shortcuts:[{id, category,
  /// title, items, owner, acl}]}`；**列表为空时没有 `shortcuts` 键**。
  Future<List<ShortcutDto>> listShortcuts() async {
    final data = await api.call(
      shortcutApi,
      'list',
      preferredVersion: negotiate(shortcutApi, const [1]),
      params: const {},
    );
    final list = data['shortcuts'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => ShortcutDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// `SYNO.NoteStation.Shortcut / set` **v1** —— 把对象加入快捷方式（F5）。
  ///
  /// ★ 参数名两处原文互相印证：
  ///   * 官方 Android `callables/operations/SetShortcutOperation.java`：
  ///     `setObjectShortcut` 发 `putParam("object_id", sGson.toJson(id))`，
  ///     `setTagShortcut` 发 `putParam("tag_id", sGson.toJson(id))` ——
  ///     值都是 **Gson 二次编码**（带引号的 JSON 串），且**只会出现一个 key**；
  ///   * 官方 Web `ui/notestation.js` 的 `setShortcut`：
  ///     `Ext.copyTo({},t,"tag_id,object_id,stack_id")`（同一组 key）。
  ///
  /// `objectId` 与 `tagId` 必须给一个；都给时按官方 Web 原样都发。
  Future<void> setShortcut({String? objectId, String? tagId}) {
    final params = _shortcutParams(objectId: objectId, tagId: tagId);
    return api.call(
      shortcutApi,
      'set',
      preferredVersion: negotiate(shortcutApi, const [1]),
      params: params,
    );
  }

  /// `SYNO.NoteStation.Shortcut / delete` **v1** —— 取消快捷方式（F5）。
  ///
  /// 参数与 [setShortcut] 完全同源（官方 `DeleteShortcutOperation.java` 的
  /// `deleteObjectShortcut`/`deleteTagShortcut` 与 Web 的 `deleteShortcut`）。
  Future<void> deleteShortcut({String? objectId, String? tagId}) {
    final params = _shortcutParams(objectId: objectId, tagId: tagId);
    return api.call(
      shortcutApi,
      'delete',
      preferredVersion: negotiate(shortcutApi, const [1]),
      params: params,
    );
  }

  /// Shortcut 写接口的参数拼装：`object_id` / `tag_id`，值都是 Gson 二次编码。
  ///
  /// 两个都给不了就抛 [ArgumentError]（宁可本地报错，也不发一个 114 的空请求）。
  Map<String, dynamic> _shortcutParams({String? objectId, String? tagId}) {
    final hasObject = objectId != null && objectId.isNotEmpty;
    final hasTag = tagId != null && tagId.isNotEmpty;
    if (!hasObject && !hasTag) {
      throw ArgumentError('Shortcut/set|delete 需要 object_id 或 tag_id');
    }
    return {
      if (hasObject) 'object_id': js(objectId),
      if (hasTag) 'tag_id': js(tagId),
    };
  }

  /// `SYNO.NoteStation.Todo / set` v1/v2（勾选完成）。
  ///
  /// ⚠️ 官方 `SetTodoOperation` 的形态（照抄，别自己简化）：
  /// * `object_id` 是 **JSON 数组**（批量接口），不是标量；
  /// * `done` 每次都发；
  /// * **顶层待办**（无 `parent_id`）还要回发 `due_date` / `priority` /
  ///   `reminder_offset` / `comment` / `star` —— 少发哪个服务端就把哪个清掉；
  /// * **子待办**只发 `parent_id`，其余字段由父任务管。
  Future<void> setTodoDone(TodoDto todo, bool done) => api.call(
    todoApi,
    'set',
    preferredVersion: negotiate(todoApi, const [2, 1]),
    params: {
      'object_id': js([todo.objectId]),
      if (todo.title.isNotEmpty) 'title': js(todo.title),
      'done': js(done),
      if (todo.parentId.isEmpty) ...{
        'due_date': js(todo.dueDate),
        'priority': js(todo.priority),
        'reminder_offset': js(todo.reminderOffset),
        if (todo.noteId.isNotEmpty) 'note_id': js(todo.noteId),
        'comment': js(todo.comment),
        'star': js(todo.star),
      } else
        'parent_id': js(todo.parentId),
    },
  );

  /// `SYNO.NoteStation.Todo / set` v1/v2 —— **完整编辑**（不是只改 done）。
  ///
  /// 官方 `SetTodoOperation` 的字段规则与 `setTodoDone` 完全一致（顶层任务回发
  /// 全部字段、子任务只发 `parent_id`），这里把 `title` 也一起发（编辑标题）。
  Future<void> updateTodo({
    required String objectId,
    String? title,
    bool? done,
    int? dueDate,
    int? priority,
    int? reminderOffset,
    String? noteId,
    String? comment,
    bool? star,
    String? parentId,
  }) => api.call(
    todoApi,
    'set',
    preferredVersion: negotiate(todoApi, const [2, 1]),
    params: {
      'object_id': js([objectId]),
      if (title != null && title.isNotEmpty) 'title': js(title),
      'done': js(done ?? false),
      if (parentId == null || parentId.isEmpty) ...{
        'due_date': js(dueDate ?? -1),
        'priority': js(priority ?? -1),
        'reminder_offset': js(reminderOffset ?? -1),
        if (noteId != null && noteId.isNotEmpty) 'note_id': js(noteId),
        'comment': js(comment ?? ''),
        'star': js(star ?? false),
      } else
        'parent_id': js(parentId),
    },
  );

  /// `SYNO.NoteStation.Todo / create`（官方 `CreateTodoOperation` + Web 端 v2）。
  ///
  /// ⚠️ `priority` 是**枚举**，不是 1/2/3：
  /// 真机实测传 `1` 会被服务端判成 `114 缺少必需参数`（错误码完全驴唇不对马嘴），
  /// 合法值只有 `none=-1 / low=100 / medium=200 / high=300`
  /// （Web 端 `Utils.getPriorityCode`）。`due_date=-1` = 无截止日期。
  Future<TodoDto> createTodo({
    required String title,
    bool done = false,
    int dueDate = -1,
    int priority = -1,
    int reminderOffset = 0,
    String? noteId,
    String? comment,
    bool star = false,
    String? parentId,
  }) async {
    if (title.isEmpty) {
      throw ArgumentError('todo task title is empty');
    }
    final data = await api.call(
      todoApi,
      'create',
      preferredVersion: negotiate(todoApi, const [2, 1]),
      params: {
        'title': js(title),
        'done': js(done),
        if (parentId == null || parentId.isEmpty) ...{
          'due_date': js(dueDate),
          'priority': js(priority),
          'reminder_offset': js(reminderOffset),
          if (noteId != null && noteId.isNotEmpty) 'note_id': js(noteId),
          if (comment != null && comment.isNotEmpty) 'comment': js(comment),
          'star': js(star),
        } else
          'parent_id': js(parentId),
      },
    );
    // 真机回包是**扁平的** TodoVo（`{title,done,due_date,…,object_id}`），
    // 不是 `{data:{…}}`；两种都兼容。
    final inner = data['data'];
    if (inner is Map) {
      return TodoDto.fromJson(Map<String, dynamic>.from(inner));
    }
    if (data['object_id'] != null) return TodoDto.fromJson(data);
    return TodoDto(objectId: '', title: title);
  }

  /// `SYNO.NoteStation.Todo / delete` v1（`object_id` 同样是数组）
  Future<void> deleteTodos(List<String> objectIds) => api.call(
    todoApi,
    'delete',
    preferredVersion: 1,
    params: {'object_id': js(objectIds)},
  );

  /// `SYNO.NoteStation.Note / restore` v1（回收站还原）
  Future<void> restoreNote(String objectId) => api.call(
    noteApi,
    'restore',
    preferredVersion: 1,
    params: {'object_id': js(objectId)},
  );

  /// `SYNO.NoteStation.Tag / set` v1 —— **只能重命名**。
  ///
  /// ⚠️ 真机实测：不带 `tag_id` → `101 请求无效`，`tag_id` 为空串 →
  /// `1003`。标签**没有独立的创建接口**，它是由 `Note/set` 的 `tag: [标题]`
  /// 隐式创建的（官方 App 的 `SetTagOperation` 也只用于改名）。
  Future<void> renameTag({required String tagId, required String title}) =>
      api.call(
        tagApi,
        'set',
        preferredVersion: 1,
        params: {'tag_id': js(tagId), 'title': js(title)},
      );

  /// `SYNO.NoteStation.Tag / delete` v1（官方一次只删一个：`tag_id` 是**标量**）
  Future<void> deleteTag(String tagId) => api.call(
    tagApi,
    'delete',
    preferredVersion: 1,
    params: {'tag_id': js(tagId)},
  );

  // ------------------------------------------------------------ 附件（图片）

  /// 官方 App 在 `commit_msg` 里报的设备名（`SetNoteOperationV2` 用 `Build.MODEL`）。
  ///
  /// ★ 第 112 轮（台账 L6）：从**硬编码 `'Flutter'`** 改成
  /// **真设备型号**（`DeviceModelBridge` → `Build.MODEL`，官方三个 smali
  /// 调用点取证：`SyncPushCallable`/`LoginTask`/`SyncCallable`）。
  /// 启动时由 `initNoteDeviceName()` 填一次；拿不到（测试/桌面）仍是
  /// `'Flutter'` —— **不假装**是具体机型。
  static String deviceName = 'Flutter';

  /// 用原生型号覆盖 [deviceName]（**只接受非空**；空/失败保持原值）。
  ///
  /// 官方只对**空**做保护，不做净化（净化是照片备份目录名的需求，别混）。
  static void useDeviceModel(String? model) {
    final trimmed = (model ?? '').trim();
    if (trimmed.isNotEmpty) deviceName = trimmed;
  }

  /// 启动时调一次：读原生 `Build.MODEL` 并落进 [deviceName]。
  static Future<void> initNoteDeviceName() async {
    useDeviceModel(await readDeviceModel());
  }

  /// 写操作必需的 `commit_msg` 外壳：`{device, listable}`。
  ///
  /// 真机/官方 JS 证据（`docs/live-write-verification.md` §5.4）：
  /// `Note/create` 的参数外壳是 `commit_msg:{device:"desktop", listable:false}`
  /// ——**它是必需的外壳**（少了它服务端按缺参数处理）。`device` 只是版本历史里
  /// 的来源标签（官方 Web `desktop` / Android `Build.MODEL`）；**`listable` 是
  /// 结构位**，普通用户写笔记发 `false`。
  static Map<String, dynamic> commitMsg({bool listable = false}) => {
    'device': deviceName,
    'listable': listable,
  };

  /// 上传笔记附件（图片）—— `SYNO.NoteStation.Note / set` **v2 + multipart**。
  ///
  /// ★ 这条流程是照官方实现 1:1 抄的，两处**必须一致**的地方：
  ///
  ///   1. `attachment[].name` 与 multipart 字段名都用
  ///      **文件名 hashCode 的字符串**（[javaStringHashCode]）——
  ///      Android `SetNoteOperationV2.name = Integer.toString(name.hashCode())`，
  ///      且 `ApiRequest` 用同一个值当 `addFormDataPart` 的 name；
  ///   2. 文件部分的 `filename=` 是**真实文件名**（服务端据此取名）。
  ///
  /// `content` 里的 `<img … ref="…">` 与 `attachment[].ref` 对应，
  /// 上传后服务端会把 ref 换成真正的 `file_id`（见 `docs` 里记的真机回包）。
  ///
  /// 官方 Web 端还会带 `format:"raw"` + `rotate:true`；Android 端带
  /// `format:"raw"` + `convert`（是否需要缩略图）+ `extra`（本地 fileId）。
  /// 这里按 **Android 端**（我们的基准 App）来。
  Future<NoteDto?> uploadAttachments({
    required String objectId,
    required String ver,
    required List<NoteAttachmentUpload> files,
    String? html,
    String? title,
    bool? encrypt,
    String? token,
    void Function(int sent, int total)? onProgress,
  }) async {
    if (files.isEmpty) return null;
    final attachments = <Map<String, dynamic>>[];
    final parts = <MultipartUploadFile>[];
    for (final f in files) {
      final ref =
          f.ref ??
          base64Encode(
            utf8.encode(
              '${DateTime.now().millisecondsSinceEpoch}${f.fileName}',
            ),
          );
      attachments.add({
        'action': f.action,
        'name': f.field,
        'format': 'raw',
        'ref': ref,
        'convert': f.convert,
        if (f.remoteFileId != null) 'file_id': f.remoteFileId,
      });
      parts.add(
        MultipartUploadFile(
          field: f.field,
          path: f.path,
          fileName: f.fileName,
          mimeType: f.mimeType,
        ),
      );
    }
    final raw = await api.postMultipart(
      api.apiPath(noteApi),
      query: {'_sid': api.session?.sid ?? ''},
      fields: {
        // 元数据全在 multipart 的表单字段里（官方 App 也把 api/method/version 当字段发）
        'api': noteApi,
        'method': 'set',
        'version': '${negotiate(noteApi, const [2, 1])}',
        'object_id': js(objectId),
        'ver': js(ver),
        'commit_msg': js({'device': deviceName}),
        if (title != null) 'title': js(title),
        if (html != null) 'content': js(html),
        // 加密笔记的图片上传同样走 `Note/set`：正文要是密文，并带 token
        if (encrypt != null) 'encrypt': js(encrypt),
        if (token != null && token.isNotEmpty) 'token': js(token),
        'attachment': js(attachments),
      },
      files: parts,
      onProgress: onProgress,
    );
    final data = api.decodeData(raw, '$noteApi.set');
    return _unwrapSetResponse(data, '$noteApi.set');
  }

  /// 删除笔记附件 —— 官方 `option_attachment` `remove` → `Note/set` v2。
  ///
  /// ★ [E2] `callables/operations/SetNoteOperationV2.java` 的 `delete` 分支：
  /// ```java
  /// case "delete":
  ///     builder.setName(fileInfo.remoteFileId);   // name **就是** file_id
  ///     builder.setFileId(fileInfo.remoteFileId);
  /// ```
  /// 而且这一支**没有对应的 multipart 文件部分**（只有 `create`/`modify` 才把
  /// 本地文件挂上去）。所以删除**不能**复用 [uploadAttachments]（那会给每个
  /// "要删的附件"再造一个空文件 part → 服务端拒绝/静默失败）。
  Future<NoteDto?> deleteNoteAttachments({
    required String objectId,
    required String ver,
    required List<String> fileIds,
    String? token,
    bool? encrypt,
  }) async {
    if (fileIds.isEmpty) return null;
    final data = await api.call(
      noteApi,
      'set',
      preferredVersion: negotiate(noteApi, const [2, 1]),
      params: {
        'object_id': js(objectId),
        'ver': js(ver),
        'attachment': js([
          for (final id in fileIds)
            {'action': 'delete', 'name': id, 'file_id': id},
        ]),
        if (encrypt != null) 'encrypt': js(encrypt),
        if (token != null && token.isNotEmpty) 'token': js(token),
        'commit_msg': js({'device': deviceName}),
      },
    );
    return _unwrapSetResponse(data, '$noteApi.set');
  }

  /// `SYNO.NoteStation.Note / download` v1 —— 附件的直链（带 `_sid`）。
  ///
  /// 参数照 `DownloadTask.download()`：`object_id` + `file_id` +
  /// `format=raw` + `thumb`（要缩略图时 true）。
  String attachmentUrl(
    String objectId,
    String fileId, {
    bool thumb = false,
    int preferredVersion = 1,
  }) {
    return api.authenticatedUrl(api.apiPath(noteApi), {
      'api': noteApi,
      'method': 'download',
      'version': '$preferredVersion',
      'object_id': js(objectId),
      'file_id': js(fileId),
      'format': js('raw'),
      'thumb': js(thumb),
    });
  }

  // ---------------------------------------------------------------- 加密
  // ------------------------------------------------- 大/加密笔记：轮询保存
  //
  // 官方依据（NoteStation 2.6.10-3938 的 `ui/notestation.js`，逐字）：
  //   * 官方**只在两种情况下**用轮询：`true === noteData.encrypt`（加密笔记）
  //     与 `noteParams.token`（带解锁 token 的冲突覆盖），其它一律 `Note/set`；
  //   * 流程：`Note.Polling/set`（v3）→ `{task_id}` →
  //     `Note.Polling/set_status {task_id}` → `{succ, resp}`；`resp.finish` 之前
  //     每 1s 再问一次（官方 `Ext.defer(…, 1e3)`）；`finish && success` →
  //     `Note.Polling/set_stop {task_id}` → 再用 `resp.data[0].ver` 重新 `getNote`；
  //   * `success:false` 时把 `resp.error` 原样报出去。
  //
  // 我们**多一种触发**：正文特别大时也走轮询（`pollingThresholdBytes`）。
  // 这条是我们的保守启发式，不是官方行为 —— 官方 Web 没有按大小判断，
  // 但直连 `Note/set` 的超时风险只跟大小有关，所以留了这个开关并在文档里标明。

  /// 正文超过这个字节数就走轮询（**本项目的启发式**，非官方阈值）
  static const int pollingThresholdBytes = 512 * 1024;

  /// 轮询间隔（官方 1s）
  static const Duration pollingInterval = Duration(seconds: 1);

  /// 最多轮询多少次（≈ [pollingMaxPolls] × 1s，超了当失败）
  static const int pollingMaxPolls = 120;

  /// 这次保存要不要走轮询
  static bool needsPolling({
    required String html,
    bool encrypt = false,
    String? token,
  }) =>
      encrypt ||
      (token != null && token.isNotEmpty) ||
      utf8.encode(html).length >= pollingThresholdBytes;

  /// 跑一段 `Note.Polling/<op>` + `<op>_status` + `<op>_stop` 的轮询。
  ///
  /// [op] ∈ `set` / `create` / `copy`；返回 `resp.data`（`finish` 时的载荷）。
  Future<List<dynamic>> _runPolling(
    String op,
    Map<String, dynamic> params, {
    void Function(int poll)? onPoll,
  }) async {
    final version = negotiate(pollingApi, const [3, 2, 1]);
    var lastError = 0;
    final started = await api.call(
      pollingApi,
      op,
      preferredVersion: version,
      params: params,
    );
    final taskId = asText(started['task_id']);
    if (taskId.isEmpty) {
      throw DsmApiException(120, method: '$pollingApi.$op', raw: started);
    }
    for (var i = 0; i < pollingMaxPolls; i++) {
      if (i > 0) await Future<void>.delayed(pollingInterval);
      onPoll?.call(i);
      final status = await api.call(
        pollingApi,
        '${op}_status',
        preferredVersion: version,
        params: {'task_id': js(taskId)},
      );
      // ★ 回包形状（**真机实测**，与官方 JS 读的 `{succ, resp}` 不完全一致）：
      //   服务端 `data` 直接就是任务状态对象
      //   `{auto_remove, error:{code}, finish, info:{…原始请求参数…}, success}`，
      //   **没有 `succ`/`resp` 外壳**：官方 JS 里的 `{succ, resp}` 是
      //   `synowebapi` 那层包装（`succ` = 这次 API 调用成功，`resp` = `data`），
      //   所以照官方语义读就是：`resp` = 这个 `data`。两种形状都兼容。
      final wrapped = status.containsKey('succ');
      final Map<String, dynamic> respMap = wrapped
          ? (status['resp'] is Map
                ? (status['resp'] as Map).cast<String, dynamic>()
                : const <String, dynamic>{})
          : status;
      if (wrapped && status['succ'] != true) {
        // 老式 `{succ, resp}` 包装：调用层面就失败了
        final inner = status['resp'];
        throw DsmApiException(
          asEpoch(inner is Map ? (inner['code'] ?? inner['error']) : inner),
          method: '$pollingApi.${op}_status',
          raw: status,
        );
      }
      if (respMap['finish'] != true) {
        // 还没做完：官方就是每秒再问一次（`error` 里的 117 此时只是
        // "任务还在跑" 的占位，**不能**当失败）
        lastError = respMap['error'] is Map
            ? asEpoch((respMap['error'] as Map)['code'])
            : lastError;
        continue;
      }
      if (respMap['success'] != true) {
        throw DsmApiException(
          asEpoch(
            respMap['error'] is Map
                ? (respMap['error'] as Map)['code']
                : respMap['error'],
          ),
          method: '$pollingApi.${op}_status',
          raw: respMap,
        );
      }
      // 官方在 set_stop 之后才去 getNote
      await api.call(
        pollingApi,
        '${op}_stop',
        preferredVersion: version,
        params: {'task_id': js(taskId)},
      );
      final data = respMap['data'];
      return data is List ? data : const [];
    }
    // 超时：把"最后看到的那次错误码"报出去（通常就是任务失败的原因）
    throw DsmApiException(
      lastError == 0 ? 119 : lastError,
      method: '$pollingApi.${op}_status',
    );
  }

  /// 轮询版保存：`Note.Polling/set` + `set_status` + `set_stop` → 重新 `getNote`。
  ///
  /// 参数与 [setNote] 一致（官方两者共用同一份 `copyTo` 白名单）。
  Future<NoteDto?> setNotePolling({
    required String objectId,
    required String ver,
    String? title,
    String? html,
    String? parentId,
    List<String>? tags,
    bool? encrypt,
    String? token,
    int? mtime,
    String? sourceUrl,
    String? brief,
    String? clipperUrl,
    String? clipperMode,
    String? clipperUserAgent,
    void Function(int poll)? onPoll,
  }) async {
    final data = await _runPolling('set', {
      'object_id': js(objectId),
      'ver': js(ver),
      if (title != null) 'title': js(title),
      if (html != null) 'content': js(html),
      if (parentId != null) 'parent_id': js(parentId),
      if (tags != null) 'tag': js(tags),
      if (encrypt != null) 'encrypt': js(encrypt),
      if (token != null && token.isNotEmpty) 'token': js(token),
      if (mtime != null) 'mtime': js(noteEpochSecondsNormalize(mtime)),
      if (sourceUrl != null)
        ...clipperParams(
          sourceUrl: sourceUrl,
          clipperUrl: clipperUrl,
          clipperMode: clipperMode,
          clipperUserAgent: clipperUserAgent,
          allowEmptySourceUrl: true,
        ),
      if (brief != null) 'brief': js(brief),
      'commit_msg': js({'device': deviceName}),
    }, onPoll: onPoll);
    return _reloadAfterPolling(objectId, data);
  }

  /// 轮询版新建（`Polling/create` + `create_status` + `create_stop`）
  Future<NoteDto?> createNotePolling({
    required String title,
    required String parentId,
    String html = '',
    bool encrypt = false,
    int? ctime,
    void Function(int poll)? onPoll,
  }) async {
    final data = await _runPolling('create', {
      'title': js(title),
      'parent_id': js(parentId),
      'ctime': js(noteEpochSecondsNormalize(ctime ?? noteEpochSeconds())),
      if (encrypt) 'encrypt': js(true),
      if (html.isNotEmpty) 'content': js(html),
      // 与 [createNote] 同一份真机外壳（create 的 commit_msg 带 listable:false）
      'commit_msg': js(commitMsg()),
    }, onPoll: onPoll);
    if (data.isEmpty || data.first is! Map) return null;
    final first = (data.first as Map).cast<String, dynamic>();
    final objectId = asText(first['object_id']);
    if (objectId.isEmpty) return null;
    final reloaded = await _reloadAfterPolling(objectId, data);
    return reloaded ??
        NoteDto.fromJson({'object_id': objectId, 'ver': first['ver']});
  }

  /// 轮询版复制（`Polling/copy` + `copy_status` + `copy_stop`）
  Future<NoteDto?> copyNotePolling({
    required String objectId,
    required String ver,
    String? title,
    String? parentId,
    void Function(int poll)? onPoll,
  }) async {
    final data = await _runPolling('copy', {
      'object_id': js(objectId),
      'ver': js(ver),
      if (title != null) 'title': js(title),
      if (parentId != null) 'parent_id': js(parentId),
      'commit_msg': js({'device': deviceName}),
    }, onPoll: onPoll);
    if (data.isEmpty || data.first is! Map) return null;
    final first = (data.first as Map).cast<String, dynamic>();
    final newId = asText(first['object_id']);
    if (newId.isEmpty) return null;
    final reloaded = await _reloadAfterPolling(newId, data);
    return reloaded ??
        NoteDto.fromJson({'object_id': newId, 'ver': first['ver']});
  }

  /// 轮询结束后按官方做法重新 `getNote`（`ver` 用轮询回包里的那个）
  Future<NoteDto?> _reloadAfterPolling(
    String objectId,
    List<dynamic> data,
  ) async {
    String? ver;
    if (data.isNotEmpty && data.first is Map) {
      final v = asText((data.first as Map)['ver']);
      if (v.isNotEmpty) ver = v;
    }
    try {
      return await getNote(objectId, ver: ver);
    } catch (_) {
      // getNote 失败不该把"已经保存成功"变成失败
      return null;
    }
  }

  // ------------------------------------------------------------ 笔记共享
  //
  // 官方依据（`ui/notestation.js` 的共享对话框 `setPermission`，逐字）：
  //   * 先 `SYNO.NoteStation.Permission / set` v1 `{object_id, enabled:true}`
  //     打开总开关，然后按对象类型 compound 提交：
  //     `Permission.Public / set` v1 `{object_id, perm}`（`perm` 是 `"ro"`/`"rw"`）；
  //     `Permission.User / set` v1 `{object_id, username, perm, uid}`；
  //     `Permission.Group / set` v1 `{object_id, groupname, perm, gid}`；
  //   * 取消：`Permission.Public / delete {object_id}`、
  //     `Permission.User / delete {object_id, username}`（也可只给 uid）；
  //   * 公开分享链接：`Shard.Link / get` v1 `{object_id, mode:"public"}` → `{url}`；
  //   * 候选账号：`Share.Priv / list` v2，`baseParams:{query:""}`，
  //     回包 `list[]`（`{name, type}`，`type` 为 `"group"` 或用户）。

  /// 打开/关闭这份笔记的共享总开关
  /// （官方在公开分享/加人前都会先发这一条）
  Future<void> setPermissionEnabled({
    required String objectId,
    required bool enabled,
  }) async {
    await api.call(
      permissionApi,
      'set',
      preferredVersion: negotiate(permissionApi, const [1]),
      params: {'object_id': js(objectId), 'enabled': js(enabled)},
    );
  }

  /// 公开分享（`perm` 为 `ro`=只读 / `rw`=可编辑）
  Future<void> setPublicPermission({
    required String objectId,
    required NoteSharePerm perm,
    bool enableAcl = true,
  }) async {
    if (enableAcl) {
      await setPermissionEnabled(objectId: objectId, enabled: true);
    }
    await api.call(
      permissionPublicApi,
      'set',
      preferredVersion: negotiate(permissionPublicApi, const [1]),
      params: {'object_id': js(objectId), 'perm': js(perm.code)},
    );
  }

  /// 取消公开分享
  Future<void> deletePublicPermission(String objectId) async {
    await api.call(
      permissionPublicApi,
      'delete',
      preferredVersion: negotiate(permissionPublicApi, const [1]),
      params: {'object_id': js(objectId)},
    );
  }

  /// 分享给某个 DSM 用户
  Future<void> setUserPermission({
    required String objectId,
    required String username,
    required NoteSharePerm perm,
    String? uid,
    bool enableAcl = true,
  }) async {
    if (enableAcl) {
      await setPermissionEnabled(objectId: objectId, enabled: true);
    }
    await api.call(
      permissionUserApi,
      'set',
      preferredVersion: negotiate(permissionUserApi, const [1]),
      params: {
        'object_id': js(objectId),
        'username': js(username),
        'perm': js(perm.code),
        if (uid != null && uid.isNotEmpty) 'uid': js(uid),
      },
    );
  }

  /// 取消某个用户的共享
  Future<void> deleteUserPermission({
    required String objectId,
    required String username,
    String? uid,
  }) async {
    await api.call(
      permissionUserApi,
      'delete',
      preferredVersion: negotiate(permissionUserApi, const [1]),
      params: {
        'object_id': js(objectId),
        if (username.isNotEmpty) 'username': js(username),
        if (uid != null && uid.isNotEmpty) 'uid': js(uid),
      },
    );
  }

  /// 分享给某个 DSM 群组
  Future<void> setGroupPermission({
    required String objectId,
    required String groupname,
    required NoteSharePerm perm,
    String? gid,
    bool enableAcl = true,
  }) async {
    if (enableAcl) {
      await setPermissionEnabled(objectId: objectId, enabled: true);
    }
    await api.call(
      permissionGroupApi,
      'set',
      preferredVersion: negotiate(permissionGroupApi, const [1]),
      params: {
        'object_id': js(objectId),
        'groupname': js(groupname),
        'perm': js(perm.code),
        if (gid != null && gid.isNotEmpty) 'gid': js(gid),
      },
    );
  }

  /// 取消某个群组的共享
  Future<void> deleteGroupPermission({
    required String objectId,
    required String groupname,
    String? gid,
  }) async {
    await api.call(
      permissionGroupApi,
      'delete',
      preferredVersion: negotiate(permissionGroupApi, const [1]),
      params: {
        'object_id': js(objectId),
        if (groupname.isNotEmpty) 'groupname': js(groupname),
        if (gid != null && gid.isNotEmpty) 'gid': js(gid),
      },
    );
  }

  /// 公开分享的链接（`Shard.Link/get` v1，`mode:"public"`）
  Future<String> publicShareUrl(String objectId) async {
    final data = await api.call(
      shardLinkApi,
      'get',
      preferredVersion: negotiate(shardLinkApi, const [1]),
      params: {'object_id': js(objectId), 'mode': js('public')},
    );
    return asText(data['url']);
  }

  /// 可分享的 DSM 账号/群组（`Share.Priv/list` v1/v2）。
  ///
  /// ★ 两种**真机回包形态都要吃**（同一个方法、不同版本）：
  ///   * **v1**：`{"data":{"offset":0,"total":4,"user_list":["admin",
  ///     "demo_admin","demo_user","demo_user"]}}` —— `user_list` 是**裸字符串
  ///     数组**，没有 `type`，一律当用户；
  ///   * **v2**：`{"list":[{"name":…,"type":"user"|"group"},…]}` ——
  ///     `list[]` 每项带 `name` / `type`。
  ///
  /// 官方 Android `tasks/FetchSharePrivTask.parsePrivUserList` 就是**同时**读
  /// `data.user_list`（→ `type:"user"`）和 `data.list`；官方 Web
  /// `notestation.js` 的 store 写死 v2 `baseParams:{query:""}`、reader
  /// `root:"list"`。因此这里两边都解析、按出现顺序去重，**只解析一种必错**。
  Future<List<({String name, String type})>> sharePrincipals({
    String query = '',
  }) async {
    final data = await api.call(
      sharePrivApi,
      'list',
      preferredVersion: negotiate(sharePrivApi, const [2, 1]),
      params: {'query': query},
    );
    final out = <({String name, String type})>[];
    // v1：`user_list` 是裸用户名数组
    final users = data['user_list'];
    if (users is List) {
      for (final e in users) {
        final name = '$e'.trim();
        if (name.isNotEmpty) out.add((name: name, type: 'user'));
      }
    }
    // v2：`list[]` 是 `{name, type}`
    final raw = data['list'];
    if (raw is List) {
      for (final e in raw.whereType<Map>()) {
        final name = '${e['name'] ?? ''}'.trim();
        if (name.isEmpty) continue;
        final type = '${e['type'] ?? ''}'.trim();
        out.add((name: name, type: type.isEmpty ? 'user' : type));
      }
    }
    final seen = <String>{};
    return [
      for (final p in out)
        if (seen.add('${p.type}\u0000${p.name}')) p,
    ];
  }

  // ============================================================ C3：导出
  //
  // 参数形态**逐字对照官方 Web**（NoteStation-x86_64-2.6.10-3938 的
  // `ui/notestation.js`，`SYNO.SDS.NoteStation.Application` 之上那层 backend）：
  //
  //   exportNote / exportWord（单笔记右键「导出 / 导出为 Word」）：
  //     exportNote:  {api:"SYNO.NoteStation.Export.Note",version:1,method:"start",
  //                   params:Ext.copyTo({},t,"object_id,timezone_offset,token")}
  //     exportWord:  {…"SYNO.NoteStation.Export.Word"…,
  //                   params:Ext.copyTo({},t,"object_id,token")}
  //     → 回包 `{task_id}`；
  //     status:      params:{task_id:t} → 回包 `{finish, filename}`（`i.finish`）
  //     每 1200ms 轮询一次（`Ext.defer(…,1200,this)`）；
  //     download:    {task_id:t, remove:!0} + 前端的 `filename:o.filename`
  //
  //   exportNotebook（笔记本「导出向导」）：
  //     {api:"SYNO.NoteStation.Export.Notebook",version:1,method:"start",
  //      params:Ext.copyTo({},t,"object_id,save_config,dest,export_todo")}
  //     —— **没有 download 方法**：服务端写到 NAS 上的 `dest` 目录
  //     （向导的 `choosed_share_path` 由 FileChooser 选共享文件夹）。
  //
  // ⚠️ 导出接口的参数是**普通字符串/数字**（服务端走 `GetAndCheckString` /
  //    `GetAndCheckInt`），**不是** Note 写接口那种 Gson 二次编码 —— 所以这里
  //    一律**不加引号**。`timezone_offset` 是 `-60*new Date().getTimezoneOffset()`。

  /// 官方 `-60 * new Date().getTimezoneOffset()`（分钟）。
  static int timezoneOffsetMinutes([DateTime? now]) =>
      -((now ?? DateTime.now()).timeZoneOffset.inMinutes);

  String _exportDownloadUrl(String apiName, String taskId) =>
      api.authenticatedUrl(api.apiPath(apiName), {
        'api': apiName,
        'method': 'download',
        'version': '1',
        'task_id': taskId,
        // 官方 `downloadWebAPI` 固定带 `remove:!0`（下完让服务端清临时文件）
        'remove': 'true',
      });

  /// `SYNO.NoteStation.Export.Word / start` v1 → `{task_id}`。
  ///
  /// 参数：`object_id` +（加密笔记）`token`；**不含** `timezone_offset`
  /// （官方 Web 的 `exportWord` 就没传，`timezone_offset` 只出现在 `exportNote`）。
  Future<String> startWordExport(String objectId, {String? token}) async {
    final data = await api.call(
      exportWordApi,
      'start',
      preferredVersion: 1,
      params: {
        'object_id': objectId,
        if (token != null && token.isNotEmpty) 'token': token,
      },
    );
    return asText(data['task_id']);
  }

  /// `SYNO.NoteStation.Export.Word / status` v1 → `{finish, filename}`
  Future<NoteExportTaskDto> wordExportStatus(String taskId) async {
    final data = await api.call(
      exportWordApi,
      'status',
      preferredVersion: 1,
      params: {'task_id': taskId},
    );
    return NoteExportTaskDto.fromJson(data);
  }

  /// `SYNO.NoteStation.Export.Word / stop` v1（取消导出任务）
  Future<void> stopWordExport(String taskId) => api.call(
    exportWordApi,
    'stop',
    preferredVersion: 1,
    params: {'task_id': taskId},
  );

  /// `SYNO.NoteStation.Export.Word / download` v1 的直链（带 `_sid`+`remove`）
  String wordExportUrl(String taskId) =>
      _exportDownloadUrl(exportWordApi, taskId);

  /// `SYNO.NoteStation.Export.Note / start` v1 → `{task_id}`。
  ///
  /// 参数：`object_id` + `timezone_offset` +（加密笔记）`token`。
  /// 产物是 NoteStation 自己的归档（`.nsx`）—— 官方导入向导过滤的扩展名就是
  /// `nsx`（`createFileInputFromDS` 的 `return t.file_extension||"nsx"`；
  /// `createFileInputFromPC` 的 `accept:"."+(t.file_extension||"nsx")`）。
  /// 具体文件名以 `status` 回的 `filename` 为准，客户端**不猜扩展名**。
  Future<String> startNoteExport(
    String objectId, {
    String? token,
    int? timezoneOffset,
  }) async {
    final data = await api.call(
      exportNoteApi,
      'start',
      preferredVersion: 1,
      params: {
        'object_id': objectId,
        'timezone_offset': timezoneOffset ?? timezoneOffsetMinutes(),
        if (token != null && token.isNotEmpty) 'token': token,
      },
    );
    return asText(data['task_id']);
  }

  /// `SYNO.NoteStation.Export.Note / status` v1 → `{finish, filename}`
  Future<NoteExportTaskDto> noteExportStatus(String taskId) async {
    final data = await api.call(
      exportNoteApi,
      'status',
      preferredVersion: 1,
      params: {'task_id': taskId},
    );
    return NoteExportTaskDto.fromJson(data);
  }

  /// `SYNO.NoteStation.Export.Note / stop` v1
  Future<void> stopNoteExport(String taskId) => api.call(
    exportNoteApi,
    'stop',
    preferredVersion: 1,
    params: {'task_id': taskId},
  );

  /// `SYNO.NoteStation.Export.Note / download` v1 的直链
  String noteExportUrl(String taskId) =>
      _exportDownloadUrl(exportNoteApi, taskId);

  /// `SYNO.NoteStation.Export.Notebook / start` v1 → `{task_id}`。
  ///
  /// 参数：`object_id`（笔记本）/ `save_config`（是否带上应用设置）/
  /// `export_todo`（是否带上待办）/ `dest`（NAS 上的目标共享目录路径）。
  /// `dest` 必须非空 —— 官方 backend 第一句就是
  /// `!(!this.checkObject(t)||Ext.isEmpty(t.dest))&&(this.backend.exportNotebook(t),!0)`。
  ///
  /// ⚠️ 官方向导支持一次选**多个**笔记本（`this.choosed_notebooks`），但包里
  /// `sendWebAPI` 是如何把数组序列化进 `object_id` 的**没有原文可判** → 本方法
  /// 只支持**单个**笔记本 id（待取证：多选序列化形态）。
  Future<String> startNotebookExport({
    required String notebookId,
    required String dest,
    bool saveConfig = false,
    bool exportTodo = false,
  }) async {
    final data = await api.call(
      exportNotebookApi,
      'start',
      preferredVersion: 1,
      params: {
        'object_id': notebookId,
        'dest': dest,
        'save_config': saveConfig,
        'export_todo': exportTodo,
      },
    );
    return asText(data['task_id']);
  }

  /// `SYNO.NoteStation.Export.Notebook / status` v1（无 task_id，见官方轮询）
  Future<NoteImportStatusDto> notebookExportStatus() async {
    final data = await api.call(
      exportNotebookApi,
      'status',
      preferredVersion: 1,
      params: const {},
    );
    return NoteImportStatusDto.fromJson(data);
  }

  /// `SYNO.NoteStation.Export.Notebook / stop` v1
  Future<void> stopNotebookExport() => api.call(
    exportNotebookApi,
    'stop',
    preferredVersion: 1,
    params: const {},
  );

  // ============================================================ C3：导入
  //
  // 官方 Web（同 `ui/notestation.js`）：
  //   * `importEnex` / `importNotebook` 走 **multipart**（`isUpload:!0`）——
  //     `SYNO.SDS.HTML5Utils.isSupportHTML5Upload()` 分支：
  //     ```js
  //     Ext.iterate(t.file, function(k,v){
  //       if ("raw"===k.format) { e.append(k.name,k.source);       // 一个文件一个字段
  //                               o.push({format:"raw",name:k.name}); }
  //       else o.push(k);
  //     });
  //     e.append("file", Ext.encode(o));                          // file = 元数据 JSON 数组
  //     n.html5upload=!0; n.uploadData=e;
  //     ```
  //     `file_extension` 只是**客户端**过滤扩展名（`"enex"` / 默认 `"nsx"`），
  //     不是 API 参数。
  //   * `status` **不带参数**（官方 compound 轮询里就是
  //     `{api:"SYNO.NoteStation.Import.Enex",version:1,method:"status"}`），
  //     回包 `{finish, data:{current,total,finish_time}}`
  //     （`updateNotebookStatus`）。
  //   * `Import.Evernote` 是**账号云导入**：`get_oauth_url {server}` →
  //     `check_oauth_token` → `list_notebooks {limit}` →
  //     `add_import_task {notebook_guid, merge_notebook}` → `import`；
  //     `get_status` / `import_lock` / `import_stop` 都不带参数
  //     （`ui/notestation.js` 的 `Import.Evernote` 向导）。

  Future<String> _startImportUpload(
    String apiName, {
    required String path,
    required String fileName,
  }) async {
    final raw = await api.postMultipart(
      api.apiPath(apiName),
      query: {'_sid': api.session?.sid ?? ''},
      fields: {
        'api': apiName,
        'method': 'start',
        'version': '1',
        // 官方：`file` = `[{"format":"raw","name":"<文件名>"}]`
        'file': jsonEncode([
          {'format': 'raw', 'name': fileName},
        ]),
      },
      // 官方：每个原始文件以**文件名**当 multipart 字段名
      files: [
        MultipartUploadFile(field: fileName, path: path, fileName: fileName),
      ],
    );
    final data = api.decodeData(raw, '$apiName.start');
    return asText(data['task_id']);
  }

  /// `SYNO.NoteStation.Import.Enex / start` v1 → `{task_id}`（Evernote `.enex`）
  Future<String> startEnexImport({
    required String path,
    required String fileName,
  }) => _startImportUpload(importEnexApi, path: path, fileName: fileName);

  /// `SYNO.NoteStation.Import.Enex / status` v1
  Future<NoteImportStatusDto> enexImportStatus() async {
    final data = await api.call(
      importEnexApi,
      'status',
      preferredVersion: 1,
      params: const {},
    );
    return NoteImportStatusDto.fromJson(data);
  }

  /// `SYNO.NoteStation.Import.Enex / stop` v1
  Future<void> stopEnexImport() =>
      api.call(importEnexApi, 'stop', preferredVersion: 1, params: const {});

  /// `SYNO.NoteStation.Import.Notebook / start` v1 → `{task_id}`（`.nsx` 归档）
  Future<String> startNotebookImport({
    required String path,
    required String fileName,
  }) => _startImportUpload(importNotebookApi, path: path, fileName: fileName);

  /// `SYNO.NoteStation.Import.Notebook / status` v1
  Future<NoteImportStatusDto> notebookImportStatus() async {
    final data = await api.call(
      importNotebookApi,
      'status',
      preferredVersion: 1,
      params: const {},
    );
    return NoteImportStatusDto.fromJson(data);
  }

  /// `SYNO.NoteStation.Import.Notebook / stop` v1
  Future<void> stopNotebookImport() => api.call(
    importNotebookApi,
    'stop',
    preferredVersion: 1,
    params: const {},
  );

  // ---- Evernote 账号云导入 ----

  /// `SYNO.NoteStation.Import.Evernote / get_oauth_url` v1 的 URL。
  ///
  /// 官方：`getBaseURL({api:…,method:"get_oauth_url",params:{server:getServerName()}})`
  /// 然后 `window.open(t)` —— 所以它返回的是一个**授权页 URL**，不是 JSON。
  String evernoteOAuthUrl(String server) =>
      api.authenticatedUrl(api.apiPath(importEvernoteApi), {
        'api': importEvernoteApi,
        'method': 'get_oauth_url',
        'version': '1',
        'server': server,
      });

  /// `SYNO.NoteStation.Import.Evernote / check_oauth_token` v1
  /// （授权完成前失败；完成后成功 —— 官方靠它轮询）
  Future<void> checkEvernoteOAuthToken() => api.call(
    importEvernoteApi,
    'check_oauth_token',
    preferredVersion: 1,
    params: const {},
  );

  /// `SYNO.NoteStation.Import.Evernote / get_status` v1
  Future<NoteEvernoteStatusDto> evernoteStatus() async {
    final data = await api.call(
      importEvernoteApi,
      'get_status',
      preferredVersion: 1,
      params: const {},
    );
    return NoteEvernoteStatusDto.fromJson(data);
  }

  /// `SYNO.NoteStation.Import.Evernote / import_lock` v1 → `{lock}`
  Future<String> evernoteImportLock() async {
    final data = await api.call(
      importEvernoteApi,
      'import_lock',
      preferredVersion: 1,
      params: const {},
    );
    return asText(data['lock']);
  }

  /// `SYNO.NoteStation.Import.Evernote / prepare_notebooks` v1 → `{task_id}`
  Future<String> evernotePrepareNotebooks() async {
    final data = await api.call(
      importEvernoteApi,
      'prepare_notebooks',
      preferredVersion: 1,
      params: const {},
    );
    return asText(data['task_id']);
  }

  /// `SYNO.NoteStation.Import.Evernote / prepare_notebooks_status` v1 → `{finish}`
  Future<bool> evernotePrepareNotebooksStatus() async {
    final data = await api.call(
      importEvernoteApi,
      'prepare_notebooks_status',
      preferredVersion: 1,
      params: const {},
    );
    return data['finish'] == true;
  }

  /// `SYNO.NoteStation.Import.Evernote / list_notebooks` v1。
  ///
  /// 官方 `SelectNotebook` 的 `baseParams:{limit:this.itemPerPage}`（50），
  /// reader `root:"notebooks"`、字段
  /// `guid/name/checked/ctime/mtime/stack`。
  Future<List<NoteEvernoteNotebookDto>> evernoteListNotebooks({
    int limit = 50,
  }) async {
    final data = await api.call(
      importEvernoteApi,
      'list_notebooks',
      preferredVersion: 1,
      params: {'limit': limit},
    );
    final list = data['notebooks'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map(
          (e) => NoteEvernoteNotebookDto.fromJson(Map<String, dynamic>.from(e)),
        )
        .toList();
  }

  /// `SYNO.NoteStation.Import.Evernote / add_import_task` v1
  /// （`{notebook_guid, merge_notebook}`）
  Future<void> evernoteAddImportTask({
    required String notebookGuid,
    bool mergeNotebook = false,
  }) => api.call(
    importEvernoteApi,
    'add_import_task',
    preferredVersion: 1,
    params: {
      'notebook_guid': js(notebookGuid),
      'merge_notebook': js(mergeNotebook),
    },
  );

  /// `SYNO.NoteStation.Import.Evernote / import` v1（无参数）
  Future<void> startEvernoteImport() => api.call(
    importEvernoteApi,
    'import',
    preferredVersion: 1,
    params: const {},
  );

  /// `SYNO.NoteStation.Import.Evernote / import_stop` v1（无参数）
  Future<void> stopEvernoteImport() => api.call(
    importEvernoteApi,
    'import_stop',
    preferredVersion: 1,
    params: const {},
  );
}
