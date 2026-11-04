// Synology Calendar 客户端（`SYNO.Cal.*`，Calendar 3.0.3-21434）。
//
// 官方**没有日历安卓 App**，所以形态以**包内 Web UI**（`/tmp/spk/export_Calendar/ui/
// synocalendar-app.js`、`synocalendar.bundle.min.js`）为准，再逐条真机验证。
// 全部事实与实证写在 `docs/api-server-authoritative.md` §18，这里只重复最容易踩的：
//
// | 接口 | 版本 | 参数 |
// |---|---|---|
// | `Cal/list` | **5** | `{cal_type:"event"}`；空参回 **9009**，v1 回 `{}` |
// | `Setting/get` | 5（v1 也行） | `{}` |
// | `Event/list` | **6**（v5 同形） | `{cal_id_list:'["/demo_user/home/"]', start:'<epoch秒>', end:'<epoch秒>'}` |
// | `Event/get` | 6（v5 多回 `evt_ical`） | `{evt_id:'1017'}` —— **裸串**，加引号回 9009 |
// | `Event/create` | 6 | 字符串字段要 **Gson 引号串**（裸串 9009），epoch/布尔要**裸串**，数组要 JSON 数组串 |
// | `Event/delete` | 6 | `{evt_id:'1017'}` —— 裸串 |
// | `Todo/list` | 6（v5 同形，v1 回 117） | `{cal_id_list:'["…"]', filter_complete:'no'}` |
// | `Todo/create` | 5/6 | `{original_cal_id, summary, description, has_start_time, has_end_time, percent_complete, tz_id, is_all_day, dtstart?, due?, notify_setting, from_syno_app_url}` |
// | `Todo/set` | 5/6 | 同 create + `{evt_id（裸串）, dav_etag, priority_order}` |
// | `Todo/delete` | 5/6 | `{evt_id:'1017'}` —— 裸串 |
// | `Todo/clean_complete` | **只有 v1** | `{cal_id_list:'["…"]'}`（v5/v6 回 103） |
// | `Todo/get` | 5/6 | `{evt_id:'1017'}` —— 裸串 |
//
// ⚠️ `Event/list` **v4 回 121（找不到对应的模块入口）**——版本协商只能给 5/6，
// 不能照 `maxVersion` 一路降到 4。
//
// ⚠️ `Todo/clean_complete`/`set_order` **只存在于 v1**：方法分散在不互相包含的版本里，
// 必须按方法选版本（`analyze_package.py apis --method clean_complete` 实测）。
//
// ⚠️ 事件和待办是**两套日历**：待办日历要 `Cal/list {cal_type:"todo"}` 拿；
// 把事件日历 id 丢给 `Todo/list` 会看不到官方 Web UI 里建的待办。
//
// 参数编码的通用口径（`js` = `jsonEncode`）：
//   * 字符串标量 → `js('x')`（服务器按 Gson 反解，裸串会让 create 回 9009）；
//   * 数字/布尔（`dtstart`/`dtend`/`evt_id`/`is_all_day`）→ 裸串；
//   * 数组（`cal_id_list`/`participant`/`notify_setting`）→ **JSON 数组串**，
//     用逗号拼或只给一个标量都会回 9009（真机逐种编码试过）。
import 'dart:convert';

import '../core/i18n/data_text.dart';
import '../core/net/traffic_meter.dart';
import '../dsm/webapi.dart';
import 'dto/calendar_dto.dart';

/// Synology 的 WebAPI 参数是"表单值"，字符串要 Gson 引号串（和 NoteStation 同口径）。
Object? _js(Object? v) => jsonEncode(v);

/// Calendar 套件**自己的**错误码（`error.code` 之外的模块级码）。
///
/// 原文出处：包内文件 `/tmp/spk/export_Calendar/ui/syno-cal-err-code.json`
/// （Calendar 3.0.3-21434，2026 年打包产物，**整个文件就是这张表**）：
///
/// ```json
/// { "9001":"error:exceed_attach_quota",
///   ...
///   "9009":"error:invalid_parameter",
///   ...
///   "9023":"error:api_relay_failed" }
/// ```
///
/// 也就是说 `9009` = **`error:invalid_parameter`（参数无效）**，
/// **不是**"没有日历"、也不是"未安装"。真机取证（`docs/live-nas-verification.md`
/// §6.1）：`SYNO.Cal.Cal/list` v5 **不带 `cal_type`** → 9009；
/// 带上 `{cal_type:"event"}` → 0（`docs/api-server-authoritative.md:507`）。
class CalApiErrorCode {
  const CalApiErrorCode._();

  /// `error:invalid_parameter` —— 参数无效（round-trip 里最常见的一个）
  static const int invalidParameter = 9009;

  /// `error:no_permission`
  static const int noPermission = 9007;

  /// `error:database_operation_failed`
  static const int databaseOperationFailed = 9006;
}

/// 把 Calendar 的异常翻成**用户可以看懂、且不误导**的一句话。
///
/// 纪律（对应用户要求）：`9009` **绝不能**被显示成"没有日历"——
/// 它是"我们发的参数服务端不接受"，文案必须带"可重试"。
/// `DsmErrorCode.internalError`(117) 在本机是 Calendar 家族的通用
/// "条件不满足"码（真机 `AuthForeign/*`、`Todo/list` v1 都是 117，
/// 见 `docs/live-nas-verification.md` §6.1），所以也按"服务端拒绝/暂不可用 + 可重试"
/// 处理，**不**说成"没有数据"。
String describeCalendarError(Object error, {String? detail}) {
  final extra = detail ?? '';
  if (error is DsmApiException) {
    switch (error.code) {
      case CalApiErrorCode.invalidParameter:
        return dataText(
          'calErrInvalidParameter',
          '服务端拒绝了这次请求的参数（9009 invalid_parameter）。可以点重试再试一次。',
        );
      case CalApiErrorCode.noPermission:
        return dataText('calErrNoPermission', '这个账号没有执行该操作的权限。');
      case DsmErrorCode.internalError:
        return dataText(
          'calErrServerCondition',
          '服务端暂时无法完成这个操作（117）。可以点重试再试一次。',
        );
      case DsmErrorCode.apiNotFound:
        return dataText('calErrNotInstalled', '这台 NAS 没有安装 Calendar');
      case DsmErrorCode.noPermission:
        return dataText('calErrNoPermission', '这个账号没有执行该操作的权限。');
      case DsmErrorCode.methodNotFound:
      case DsmErrorCode.notSupportedVersion:
        return dataText('calErrVersionUnsupported', '服务端不支持这个操作（版本不匹配）。');
      default:
        break;
    }
    return dataText(
      'calErrCode',
      '请求失败（错误码 {code}）',
    ).replaceAll('{code}', '${error.code}');
  }
  return dataText(
    'calErrGeneric',
    '加载失败：{error}',
  ).replaceAll('{error}', extra.isEmpty ? '$error' : extra);
}

class CalendarApi {
  CalendarApi(DsmWebApi api) : api = api.withModule(TrafficModules.calendar);

  final DsmWebApi api;

  static const String calApi = 'SYNO.Cal.Cal';
  static const String eventApi = 'SYNO.Cal.Event';
  static const String settingApi = 'SYNO.Cal.Setting';
  static const String todoApi = 'SYNO.Cal.Todo';
  static const String proxyApi = 'SYNO.Cal.Proxy';
  static const String authForeignApi = 'SYNO.Cal.AuthForeign';

  /// `SYNO.Cal.Contact` —— 受邀人候选（NAS 用户列表）。**只读**。
  static const String contactApi = 'SYNO.Cal.Contact';

  // ---------------------------------------------------------------- wave1 新增
  //
  // 每个常量后面都跟着"证据在哪"，**没有证据的一个都没加**。

  /// `SYNO.Cal.Sharing` —— 某日历的共享成员（`get` 只读 / `set` 全量替换）。
  ///
  /// 方法表：v1 只有 `get, set`（包内 `webapi/SYNO.Cal.lib`）。
  static const String sharingApi = 'SYNO.Cal.Sharing';

  /// `SYNO.Cal.Share.Priv` —— 共享**候选账号**（用户/群组）。只读。
  ///
  /// 方法表：v1 只有 `list`。⚠️ 与 NoteStation 的 `SYNO.NoteStation.Share.Priv/list`
  /// 是**两套不同的 API**（后者回包只有 `{name, type}`、参数是 `{query}`）。
  static const String sharePrivApi = 'SYNO.Cal.Share.Priv';

  /// `SYNO.Cal.Timezone` —— 时区表（`list`）。只读。
  static const String timezoneApi = 'SYNO.Cal.Timezone';

  /// `SYNO.Cal.InviteMail`（`reply`）—— 邀请邮件回复页。
  ///
  /// ⚠️ **依赖邮件套件**：真机 `reply` v1 回的是 **HTML 页面**而不是 JSON
  /// （见 `docs/calendar-gaps-wave1.md`），说明它不是给客户端调的 JSON 接口。
  /// 本 App **不做**，只暴露能力位 + 原因（[inviteMailUnavailableReason]）。
  static const String inviteMailApi = 'SYNO.Cal.InviteMail';

  /// `SYNO.Cal.InviteMailInit`（`token`/`tokens`）—— **仅管理员**（包内 `.lib`
  /// 的 `allowUser` 不含 `normal.*`），真机 `token` 回 **117**。
  static const String inviteMailInitApi = 'SYNO.Cal.InviteMailInit';

  /// `SYNO.Cal.SendMail`（`send_cancel`）—— **仅管理员**，真机回 **117**。
  static const String sendMailApi = 'SYNO.Cal.SendMail';

  /// 这台 NAS 有没有 `SYNO.Cal.Sharing`（共享日历的读/写）。
  ///
  /// `service_registry.dart` 是禁改区，所以可选入口一律**直接看能力表**，
  /// 不新增能力位（和 [hasContactApi] 同一口径）。
  bool get hasSharingApi => api.apiTable?.containsKey(sharingApi) ?? false;

  /// 这台 NAS 有没有 `SYNO.Cal.Share.Priv`（共享候选账号来源）。
  bool get hasSharePrivApi => api.apiTable?.containsKey(sharePrivApi) ?? false;

  /// 这台 NAS 有没有 `SYNO.Cal.Timezone`（时区选择）。
  bool get hasTimezoneApi => api.apiTable?.containsKey(timezoneApi) ?? false;

  /// `SYNO.Cal.Event` 的 `maxVersion >= 6` 才有 `list_color` / `create_from_ics`
  /// （包内 `webapi/SYNO.Cal.lib`：这两个方法**只在 v6**）。
  bool get hasEventV6Api => (api.apiTable?[eventApi]?.maxVersion ?? 0) >= 6;

  /// 邀请邮件三条**为什么不做**——**如实登记，不硬做**。
  ///
  /// 证据（真机 2026-09-22 + 包内 `.lib` 的 `allowUser`）：
  /// * `InviteMailInit:token` → **117**；`.lib` 里 `allowUser` **不含 `normal.*`**
  ///   ⇒ 仅管理员；
  /// * `SendMail:send_cancel` → **117**；同样**仅管理员**；
  /// * `InviteMail:reply` v1 回的是 **HTML 页面**（不是 JSON）⇒ 面向邮件套件的
  ///   网页入口，**依赖"邮件套件已安装/已配置"**。
  ///
  /// 所以三条都是"**依赖邮件套件 / 仅管理员**"，能力门控 + 明说原因，
  /// **不给会失败的按钮**。
  static String get inviteMailUnavailableReason => dataText(
    'calInviteMailUnavailable',
    '邀请邮件需要 NAS 上的邮件套件（MailPlus 或邮件服务器）配合，'
        '且需要管理员账号。此功能当前不可用。',
  );

  /// ICS 导入**为什么只做骨架**——参数未取证，**绝不臆造参数名**。
  ///
  /// 证据：
  /// * 方法/版本**已钉**：`Cal.Event:create_from_ics` **只有 v6**
  ///   （包内 `.lib` + `webapi/SYNO.Cal.Event.so` 的 `CreateFromICS_v6`），
  ///   真机 v6 无参 → **9009 invalid_parameter**；
  /// * 参数名**未取证**：官方客户端 `ui/` **全目录没有调用点**
  ///   （grep `create_from_ics` = 0），`openapi.json` 也没有对应 path；
  ///   二进制里只找到**候选**（`SYNO.Cal.Event.so` 的 `ics_file` / `ics_file_name`
  ///   属于外部日历导入任务表 `syno_cal_map`，`libcalwebapi.so` 里另有裸串 `ics`），
  ///   三者**互相矛盾、无法判定** ⇒ 按项目纪律**不写死**。
  static String get icsImportUnavailableReason => dataText(
    'calIcsImportUnavailable',
    'ICS 导入暂不支持：服务端方法（Cal.Event:create_from_ics，仅 v6）已确认，'
        '但参数名还没有取证到，写死会做成"点了就失败"的入口。',
  );

  /// 这台 NAS 有没有"邀请邮件"能力（**门控用**）。
  ///
  /// 三条 API 只要有一条在能力表里，就说明这台机器装了会发邀请邮件的套件；
  /// 但**我们仍然不做**（[inviteMailUnavailableReason]）—— 门控的意义是
  /// "没有这条能力时连'暂不支持'的说明都不显示"。
  bool get hasInviteMailApi =>
      (api.apiTable?.containsKey(inviteMailApi) ?? false) ||
      (api.apiTable?.containsKey(inviteMailInitApi) ?? false) ||
      (api.apiTable?.containsKey(sendMailApi) ?? false);

  /// 这台 NAS 是否有 `SYNO.Cal.Contact`（受邀人候选来源）。
  ///
  /// ⚠️ 这是**可选入口**：没有它时"从 NAS 用户选择"整个隐藏，只留手输邮箱
  /// （手输邮箱不需要任何额外 API），**不隐藏日历模块**。`service_registry.dart`
  /// 是禁改区，所以这里直接看 `SYNO.API.Info` 能力表，不新增能力位。
  bool get hasContactApi => api.apiTable?.containsKey(contactApi) ?? false;

  /// 在候选版本里挑一个服务端真的有的（表里没有就按候选里最高的试）。
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

  /// `Cal/list` v5 `{cal_type:"event"}` —— 事件日历列表（共享/团队日历也在这里）。
  ///
  /// 真机：`cal_type` 不给或给空 → **9009**；v1 不认识这个参数，回 `{}`。
  Future<List<CalendarDto>> listCalendars({String calType = 'event'}) async {
    final data = await api.call(
      calApi,
      'list',
      preferredVersion: _negotiate(calApi, const [5]),
      params: {'cal_type': calType},
    );
    return CalendarDto.listFromJson(data);
  }

  /// `Setting/get` —— 个人设置（时区/周起始日/日期格式）。
  Future<CalSettingDto> setting() async {
    final data = await api.call(
      settingApi,
      'get',
      preferredVersion: _negotiate(settingApi, const [5, 1]),
      params: const {},
    );
    return CalSettingDto.fromJson(data);
  }

  /// `SYNO.Cal.Contact/list` v1 —— **受邀人候选**（NAS 用户列表，只读）。
  ///
  /// 原文证据（Calendar 3.0.3-21434）：
  /// * 方法表：`Contact_list:{api:"SYNO.Cal.Contact",method:"list",version:1}`
  ///   （`ui/synocalendar.bundle.min.js`）；
  /// * 调用点：`listContactUsers(){const e=await this.runAPI("Contact_list",{});…}`
  ///   —— **空参数**；老 Web UI 同名（`{api:"Contact_list"}`）；
  /// * 回包元素 `user_contact_obj_0`（`webapi/openapi.json`，GET `/contact`）：
  ///   `{user_name, display_name, email, is_real_email, type, has_set_email}`，
  ///   data 的键是 **`list`**（老 UI `processFetchedData: t.list`）。
  Future<List<CalContactDto>> calContacts() async {
    final data = await api.call(
      contactApi,
      'list',
      preferredVersion: _negotiate(contactApi, const [1]),
      params: const {},
    );
    return CalContactDto.listFromJson(data);
  }

  // ------------------------------------------------------- 外部日历（只读部分）
  //
  // 外部日历的**完整链路**（官方原文）：
  //   1. `AuthForeign/create`（**写**、Google OAuth）：老 Web UI
  //      `ui/synocalendar-app.js`：
  //      `sendPromise("Auth_create",{auth_type:"google",remote_account:t.email,
  //        auth_info:{access_token:t.token, refresh_token:t.refresh_token}})`
  //      新 Vue UI `synocalendar.bundle.min.js`：
  //      `authForeignCreate(e,t){return this.runAPI("Auth_create",
  //        {remoteAccount:e, authInfo:t, authType:"google"})}`（参数层转 snake_case）。
  //      服务端字段在 `webapi/SYNO.Cal.AuthForeign.so` 的 `syno_auth_foreign` 表里：
  //      `auth_id / auth_type / local_uid / remote_account / auth_info /
  //       modify_time(out) / extra_info`。
  //   2. `Proxy/cal_list {auth_id}` → 该账号下的远端日历（见 [remoteCalendars]）。
  //
  // ⚠️ **本 App 不实现 `AuthForeign/*`**（登记在 `docs/calendar-contacts-c4.md`
  // 的待取证清单）：`auth_info` 要 Google OAuth 的 `access_token`/`refresh_token`，
  // 我们拿不到；而且真机上 `AuthForeign/list`（只读！）对**所有**候选入参都回
  // **117**（`docs/live-nas-verification.md` §6.1），连"列出已连接的外部账号"
  // 这一步都没跑通 ⇒ 界面上**不给会失败的入口**，只在日历选择器里放一条
  // "暂不支持（原因见文档）"的说明。

  /// `SYNO.Cal.Proxy/cal_list`（v1）—— 某个外部账号下的**远端日历列表**（只读）。
  ///
  /// 参数与回包证据（官方明文 JS）：
  /// ```js
  /// Proxy_cal_list:{api:"SYNO.Cal.Proxy",method:"cal_list",version:1}
  /// sendPromise("Proxy_cal_list",{auth_id:t.auth_id})          // ui/synocalendar-app.js
  /// remoteCalendarList(e){return this.runAPI("Proxy_cal_list",{authId:e})}
  ///                                                            // synocalendar.bundle.min.js
  /// ```
  /// 每个远端日历的字段（老 UI 的导入流程原文）：
  /// `remote_cal_id` / `remote_cal_displayname` / `remote_cal_type` / `cal_color`。
  ///
  /// ⚠️ 两个**未真机验证**的边界（如实登记，别当成已验证）：
  ///   * 回包 `data` 是**裸 JSON 数组**（老 UI 直接 `store.loadData(t)`，
  ///     新 UI `e.map(...)`），而 `DsmWebApi.call` 只接受 Map 形态的 `data`
  ///     （`_okData` 对非 Map 返回 `{}`）—— 所以这里**不走 `call`**，
  ///     改用带 `_sid`+`SynoToken` 的鉴权 URL + `getBytes` 自己解 JSON；
  ///   * 官方用的是 POST，这里用 GET（`entry.cgi` 的 WebAPI 通常两者都收），
  ///     **没有真机验证过**。因为拿不到 `auth_id`（见上），本方法当前**没有 UI
  ///     调用点**，所以不会给用户造成"点了就失败"的入口。
  Future<List<RemoteCalendarDto>> remoteCalendars(String authId) async {
    if (authId.isEmpty) return const [];
    const what = 'SYNO.Cal.Proxy.cal_list';
    final url = api.authenticatedUrl(api.apiPath(proxyApi), {
      'api': proxyApi,
      'version': '${_negotiate(proxyApi, const [1])}',
      'method': 'cal_list',
      'auth_id': authId,
    });
    if (url.isEmpty) {
      throw DsmApiException(DsmErrorCode.internalError, method: what);
    }
    final bytes = await api.getBytes(url);
    final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (decoded['success'] != true) {
      final err = decoded['error'];
      final code = (err is Map && err['code'] is num)
          ? (err['code'] as num).toInt()
          : DsmErrorCode.unknown;
      throw DsmApiException(code, method: what, raw: decoded);
    }
    return RemoteCalendarDto.listFromJson(decoded['data']);
  }

  /// `Event/list` v6 —— 取 [from]–[to] 之间的事件。
  ///
  /// `cal_id_list` 是 **JSON 数组字符串**；`start`/`end` 是 **UTC epoch 秒**裸串。
  Future<List<CalEventDto>> listEvents({
    required List<String> calendarIds,
    required DateTime from,
    required DateTime to,
  }) async {
    final data = await api.call(
      eventApi,
      'list',
      preferredVersion: _negotiate(eventApi, const [6, 5]),
      params: {
        if (calendarIds.isNotEmpty) 'cal_id_list': _js(calendarIds),
        'start': '${from.millisecondsSinceEpoch ~/ 1000}',
        'end': '${to.millisecondsSinceEpoch ~/ 1000}',
      },
    );
    return CalEventDto.listFromJson(data);
  }

  /// `Event/get` v6 —— 单条事件（v5 会多回 `evt_ical`）。
  Future<CalEventDto?> event(String evtId) async {
    final data = await api.call(
      eventApi,
      'get',
      preferredVersion: _negotiate(eventApi, const [6, 5]),
      params: {'evt_id': evtId},
    );
    final list = CalEventDto.listFromJson({
      'list': [data],
    });
    return list.isEmpty ? null : list.first;
  }

  /// `Event/create` v6 —— 参数照包内 UI 的 `_evtCreateRequiredParams`。
  ///
  /// [start] / [end] 是**墙上时间**（本地时区），这里换算成 epoch 秒：
  /// 官方 Web UI 走的是"浏览器时区"（`getUTCSecondsByTzId(date, 浏览器时区)`），
  /// 所以设备本地时区 = 事件时区时，两种算法结果一致。
  ///
  /// [participants] 是受邀人（`participant`，openapi 里是 **required** 字段）。
  /// 官方 `_evtCreateRequiredParams` 里就是 `participant:t[l.attendee]||[]`，
  /// 每一项的形状见 [CalParticipantDto.toApiJson]（**`display_name` 不发**）。
  Future<CalEventDto> createEvent({
    required String calendarId,
    required String originalCalendarId,
    required String summary,
    required DateTime start,
    required DateTime end,
    bool isAllDay = false,
    String timeZone = '',
    String description = '',
    String color = '',
    CalRepeatRule? repeat,
    List<CalParticipantDto> participants = const [],
  }) async {
    final repeatBool = repeat != null;
    final epoch = eventEpoch(start: start, end: end, isAllDay: isAllDay);
    final data = await api.call(
      eventApi,
      'create',
      preferredVersion: _negotiate(eventApi, const [6, 5]),
      params: {
        'cal_id': _js(calendarId),
        'original_cal_id': _js(originalCalendarId),
        'summary': _js(summary),
        'is_all_day': '$isAllDay',
        'tz_id': _js(isAllDay ? '' : timeZone),
        'dtstart': '${epoch.start}',
        'dtend': '${epoch.end}',
        // 重复规则：服务端字段名是 `repeat_setting`（包内 `EventUtils.repeat`），
        // 值是**同一套 Gson 编码**的 JSON 串；`repeat_setting` 为 null 时官方客户端
        // 会**整个键都不发**（它的参数层会过滤 null），所以这里也只在有规则时带。
        'is_repeat_evt': '$repeatBool',
        if (repeat != null)
          'repeat_setting': _js(repeat.toJson(allDay: isAllDay)),
        'color': _js(color),
        'description': _js(description),
        'participant': _js([for (final p in participants) p.toApiJson()]),
        'notify_setting': _js(const <Object>[]),
      },
    );
    return CalEventDto.fromJson(data);
  }

  /// 事件开始/结束的编码，照官方 `SYNO.Cal.DateUtils`（包内 `_evtSetRequiredParams`）：
  ///
  /// * **非全天**：`getNonAllDayUTCSeconds` —— 本地墙上时间的 epoch 秒；
  /// * **全天**：`getAllDayUTCSeconds` —— 取**本地日期的 UTC 零点**，而且
  ///   `dtend` 是**结束日的次日零点（exclusive）**：官方写的是
  ///   `getAllDayUTCSeconds(end.add(Date.DAY, 1))`。
  ///
  /// 我们以前全天事件直接把 `end` 当端点发，官方客户端会把这种事件显示成
  /// 1 小时（真机对齐后修正）。
  static ({int start, int end}) eventEpoch({
    required DateTime start,
    required DateTime end,
    required bool isAllDay,
  }) {
    if (!isAllDay) {
      return (
        start: start.millisecondsSinceEpoch ~/ 1000,
        end: end.millisecondsSinceEpoch ~/ 1000,
      );
    }
    final from = DateTime.utc(start.year, start.month, start.day);
    var lastDay = DateTime.utc(end.year, end.month, end.day);
    if (lastDay.isBefore(from)) lastDay = from;
    return (
      start: from.millisecondsSinceEpoch ~/ 1000,
      end: lastDay.add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000,
    );
  }

  /// `Event/set` v6 —— **改一条已存在的日程**（= 官方 `PUT /event`）。
  ///
  /// 参数表来自包内 `webapi/openapi.json` 的 `PUT /event`（"Modify an event"，
  /// required 16 项）与 `synocalendar-app.js` 的 `_evtSetRequiredParams`：
  ///
  /// ```text
  /// evt_id(裸串) cal_id original_cal_id summary color description dav_etag
  /// is_all_day tz_id dtstart dtend is_repeat_evt repeat_setting
  /// participant notify_setting location_info attachments
  /// ```
  ///
  /// 三个"整体替换"字段（`participant` / `notify_setting` / `location_info` /
  /// `attachments`）**必须原样回传源事件的原始 JSON**，否则改个标题就会把
  /// 受邀人、提醒、地点一起清空 —— 这也是 [source] 参数存在的理由。
  /// `dav_etag` 是乐观锁：和服务端记录不一致时服务端会拒绝（官方注释：
  /// "If this value differs from the server's recorded value..."）。
  ///
  /// [participants] 传了就用它（受邀人编辑），不传就照旧回传
  /// [CalEventDto.participantsRaw]（"只改标题"不会清空受邀人）。
  Future<CalEventDto> updateEvent({
    required CalEventDto source,
    required String calendarId,
    required String originalCalendarId,
    required String summary,
    required DateTime start,
    required DateTime end,
    bool? isAllDay,
    String? timeZone,
    String? description,
    CalRepeatRule? repeat,
    List<CalParticipantDto>? participants,
    String? color,
  }) async {
    final allDay = isAllDay ?? source.isAllDay;
    final repeatBool = repeat != null;
    final epoch = eventEpoch(start: start, end: end, isAllDay: allDay);
    final data = await api.call(
      eventApi,
      'set',
      preferredVersion: _negotiate(eventApi, const [6, 5]),
      params: {
        // evt_id 是**裸串**（引号串回 9009，和 delete/get 同口径）
        'evt_id': source.evtId,
        'cal_id': _js(calendarId),
        'original_cal_id': _js(originalCalendarId),
        'summary': _js(summary),
        'color': _js(color ?? source.color),
        'description': _js(description ?? source.description),
        'dav_etag': _js(source.davEtag),
        'is_all_day': '$allDay',
        'tz_id': _js(allDay ? '' : (timeZone ?? source.tzId)),
        'dtstart': '${epoch.start}',
        'dtend': '${epoch.end}',
        'is_repeat_evt': '$repeatBool',
        if (repeat != null)
          'repeat_setting': _js(repeat.toJson(allDay: allDay)),
        'participant': participants != null
            ? _js([for (final p in participants) p.toApiJson()])
            : _js(source.participantsRaw),
        'notify_setting': _js(source.notifySetting),
        'location_info': _js(source.locationRaw),
        'attachments': _js(source.attachments),
      },
    );
    return CalEventDto.fromJson(data);
  }

  /// `Event/subevent_set` v6 —— **只改重复事件里的这一次**（官方 `setSingleEvent`）。
  ///
  /// 真机实测（2026-09-20，探针第 4b 段）：
  /// ```text
  /// 只发 openapi 的 required 14 项 + recurrence_id（裸串/引号串都试过） → 9009
  /// 再补上 participant / location_info / is_repeat_evt                 → OK
  /// ```
  /// 也就是**必须带 `participant` / `location_info` / `is_repeat_evt`**（和 `set` 一样，
  /// 这四个字段是"整体替换"语义）。改完回读：只有目标那一次换了标题，其它几次照旧。
  ///
  /// `recurrence_id` 是这一次的身份：官方老 Web UI 是
  /// `t[recurrenceId] = t[recurrenceId] || t[startStr]`，本机服务端回的实例
  /// `recurrence_id` 是空，所以退化成这一次的 `dtstart_string`（裸串，和 `set_exdate`
  /// 同口径：这里的 `recurrence_id` 按日期字段解析，不能包 Gson 引号）。
  Future<CalEventDto> updateSubEvent({
    required CalEventDto instance,
    required String calendarId,
    required String originalCalendarId,
    required String summary,
    required DateTime start,
    required DateTime end,
    bool? isAllDay,
    String? timeZone,
    String? description,
    String? color,
  }) async {
    final allDay = isAllDay ?? instance.isAllDay;
    final epoch = eventEpoch(start: start, end: end, isAllDay: allDay);
    final recurrenceId = instance.recurrenceId.isNotEmpty
        ? instance.recurrenceId
        : instance.dtstartString;
    final data = await api.call(
      eventApi,
      'subevent_set',
      preferredVersion: 6,
      params: {
        'evt_id': instance.evtId,
        'recurrence_id': recurrenceId,
        'cal_id': _js(calendarId),
        'original_cal_id': _js(originalCalendarId),
        'summary': _js(summary),
        'color': _js(color ?? instance.color),
        'description': _js(description ?? instance.description),
        'dav_etag': _js(instance.davEtag),
        'is_all_day': '$allDay',
        'tz_id': _js(allDay ? '' : (timeZone ?? instance.tzId)),
        'dtstart': '${epoch.start}',
        'dtend': '${epoch.end}',
        // 真机实测：这三项漏了就 9009（subevent_set 同样是"整体替换"语义）
        'is_repeat_evt': 'true',
        'participant': _js(instance.participantsRaw),
        'location_info': _js(instance.locationRaw),
        'notify_setting': _js(instance.notifySetting),
        'attachments': _js(instance.attachments),
      },
    );
    return CalEventDto.fromJson(data);
  }

  /// `Event/set_exdate` v5/v6 —— **只删重复事件里的这一次**。
  ///
  /// 参数照包内 Web UI 的 `_deleteSingleEvt`（`synocalendar-app.js`）：
  /// `{evt_id, dav_etag, exdate}`，其中 `exdate` 是**这一次的身份** ——
  /// 服务端在重复实例上回 `recurrence_id`（本机实测是 `null`，于是退化成
  /// 这一条实例自己的 `dtstart_string`，如 `20260927T090000`）。
  /// 母事件本身不动，所以其它几次照常出现。
  ///
  /// ⚠️ 真机逐条实测（2026-09-20，探针 x1–x6）：
  /// ```text
  /// v6 + exdate 裸串            → OK     （唯一能通的组合）
  /// v6 + exdate 引号串          → 9009
  /// v5 + 任意                   → 9009
  /// evt_id 引号串               → 9009
  /// 把已经排除过的日期再排除一次 → 9009（服务端当非法参数）
  /// ```
  /// 也就是说：`exdate` 与服务端的其它字符串参数不同，**不能包 Gson 引号**
  /// （它按日期字段解析），而且 `set_exdate` 只认 **v6**。
  Future<void> setEventExdate({
    required String evtId,
    required String davEtag,
    required String exdate,
  }) async {
    await api.call(
      eventApi,
      'set_exdate',
      // 只认 v6：v5 真机也是 9009（包内老 Web UI 用的就是 v5，本机服务端不吃）
      preferredVersion: 6,
      params: {
        'evt_id': evtId,
        'dav_etag': _js(davEtag),
        // 裸串！引号串真机回 9009（见上面的注释）
        'exdate': exdate,
      },
    );
  }

  /// `Event/delete` v6 —— `evt_id` 是**裸串**（加引号回 9009）。
  Future<void> deleteEvent(String evtId) async {
    await api.call(
      eventApi,
      'delete',
      preferredVersion: _negotiate(eventApi, const [6, 5]),
      params: {'evt_id': evtId},
    );
  }

  /// `Todo/list` v6 —— 日历里的待办（和 NoteStation 的待办是两套）。
  Future<List<CalTodoDto>> listTodos({
    required List<String> calendarIds,
    String filterComplete = 'no',
  }) async {
    final data = await api.call(
      todoApi,
      'list',
      preferredVersion: _negotiate(todoApi, const [6, 5]),
      params: {
        if (calendarIds.isNotEmpty) 'cal_id_list': _js(calendarIds),
        'filter_complete': filterComplete,
      },
    );
    return CalTodoDto.listFromJson(data);
  }

  /// `Cal/list {cal_type:"todo"}` —— **待办日历**（官方 Web UI 的待办列表来源）。
  ///
  /// ⚠️ 事件和待办是两套日历：老代码把事件日历的 id 丢给 `Todo/list`，用户在
  /// 官方 Web UI 里建的待办（挂在 `…/home_todo/` 之类的待办日历下）就一条也看不到。
  Future<List<CalendarDto>> listTodoCalendars() async =>
      listCalendars(calType: 'todo');

  /// `Todo/create` v5/v6 —— 参数形态照包内 Web UI 的 `_todoCreateRequiredParams`
  /// 与 `SYNO.Cal.Todo.so` 的实现（详见 `docs/api-server-authoritative.md` §18.4）：
  ///
  /// 必填 7 个：`original_cal_id` / `summary` / `description` /
  /// `has_start_time` / `has_end_time` / `percent_complete` / `tz_id`；
  /// 可选：`is_all_day` / `dtstart` / `due` / `notify_setting` / `from_syno_app_url`。
  ///
  /// 编码口径与 `Event/create` **完全一致**（同一套 Gson 参数层，真机验过）：
  /// 字符串 → 引号串、数字/布尔 → 裸串、数组/对象 → JSON 串。
  Future<CalTodoDto> createTodo({
    required String originalCalendarId,
    required String summary,
    String description = '',
    DateTime? due,
    DateTime? start,
    bool isAllDay = false,
    String timeZone = '',
    int percentComplete = 0,
  }) async {
    final data = await api.call(
      todoApi,
      'create',
      preferredVersion: _negotiate(todoApi, const [6, 5]),
      params: {
        'original_cal_id': _js(originalCalendarId),
        'summary': _js(summary),
        'description': _js(description),
        'has_start_time': '${start != null}',
        'has_end_time': '${due != null}',
        'percent_complete': '$percentComplete',
        'is_all_day': '$isAllDay',
        // 全天待办的 tz 必须为空串（服务端会校验："tzid must be empty when
        // is_all_day is true"）
        'tz_id': _js(isAllDay ? '' : timeZone),
        if (start != null) 'dtstart': '${start.millisecondsSinceEpoch ~/ 1000}',
        if (due != null) 'due': '${due.millisecondsSinceEpoch ~/ 1000}',
        'notify_setting': _js(const <Object>[]),
        'from_syno_app_url': _js(const <String, Object>{}),
      },
    );
    return CalTodoDto.fromJson(data);
  }

  /// `Todo/set` v5/v6 —— 改标题/备注/时间/完成度。
  ///
  /// 必填比 create 多两个：`evt_id`（**裸串**）和 `dav_etag`（乐观锁，回包带了就
  /// 必须原样回传）以及 `priority_order`。其余字段按**当前这条**原样带上，
  /// 不打参数的服务端会当成"要清空"（官方 Web UI 也是全量提交）。
  ///
  /// [due] 不给就沿用原值；要**清掉**截止时间就传 `clearDue: true`
  /// （这是唯一能表达"删掉 due"的方式，因为 null 和"不改"没法区分）。
  Future<CalTodoDto> setTodo(
    CalTodoDto todo, {
    String? summary,
    String? description,
    DateTime? due,
    bool clearDue = false,
    int? percentComplete,
    bool? isAllDay,
    String? timeZone,
  }) async {
    final nextSummary = summary ?? todo.summary;
    final nextDescription = description ?? todo.description;
    final nextPercent = percentComplete ?? todo.percentComplete;
    final nextAllDay = isAllDay ?? todo.isAllDay;
    final nextTz = timeZone ?? todo.tzId;
    final nextDue = clearDue ? null : (due ?? todo.dueAt);
    final nextStart = todo.hasStart ? todo.startAt : null;
    final orgCalId = todo.originalCalId.isEmpty
        ? todo.calId
        : todo.originalCalId;
    final data = await api.call(
      todoApi,
      'set',
      preferredVersion: _negotiate(todoApi, const [6, 5]),
      params: {
        'evt_id': todo.evtId,
        'original_cal_id': _js(orgCalId),
        'dav_etag': _js(todo.davEtag),
        'summary': _js(nextSummary),
        'description': _js(nextDescription),
        'has_start_time': '${nextStart != null}',
        'has_end_time': '${nextDue != null}',
        'percent_complete': '$nextPercent',
        'priority_order': '${todo.priorityOrder}',
        'is_all_day': '$nextAllDay',
        'tz_id': _js(nextAllDay ? '' : nextTz),
        if (nextStart != null)
          'dtstart': '${nextStart.millisecondsSinceEpoch ~/ 1000}',
        if (nextDue != null) 'due': '${nextDue.millisecondsSinceEpoch ~/ 1000}',
        'notify_setting': _js(const <Object>[]),
      },
    );
    return CalTodoDto.fromJson(data);
  }

  /// `Todo/delete` v5/v6 —— `evt_id` 是**裸串**（与 `Event/delete` 同口径）。
  Future<void> deleteTodo(String evtId) async {
    await api.call(
      todoApi,
      'delete',
      preferredVersion: _negotiate(todoApi, const [6, 5]),
      params: {'evt_id': evtId},
    );
  }

  /// `Todo/clean_complete` —— **只有 v1 有这个方法**（v5/v6 调会回 103）。
  ///
  /// 参数：`cal_id_list` → JSON 数组串（官方 Web UI 的 `Todo_clear_complete`）。
  Future<void> cleanCompletedTodos(List<String> calendarIds) async {
    if (calendarIds.isEmpty) return;
    await api.call(
      todoApi,
      'clean_complete',
      preferredVersion: _negotiate(todoApi, const [1]),
      params: {'cal_id_list': _js(calendarIds)},
    );
  }

  // ==========================================================================
  // wave1（2026-09-22）
  //
  // 事实来源**逐条标注**：
  //   * `*_apiNames / versions` —— 包内 `webapi/SYNO.Cal.lib`（权威方法表）；
  //   * `*_params` —— 要么是官方客户端明文 JS（`ui/synocalendar*.js`）、要么是
  //     真机回包；**两者都没有的，这个方法就不写**（只留骨架 + 原因）。
  // ==========================================================================

  /// 一次 `entry.cgi` 的**裸回包**（`data` 可以是 Map，也可以是**裸数组**）。
  ///
  /// 为什么不能走 [DsmWebApi.call]：它的 `_okData` **只认 Map 形态的 `data`**，
  /// 非 Map（数组）会被静默丢成 `{}` —— 真机 `Cal.Timezone/list` 回的正是
  /// **裸数组**，那样会"成功但一条都没有"，把接口问题伪装成空数据。
  ///
  /// 走 `postBytesForm`（表单 body + `_sid` + `X-SYNO-TOKEN` 头），与官方
  /// Web UI 的 POST 同形；GET 那条路（`remoteCalendars` 用的）在这里**没采用**，
  /// 因为 `Timezone/list` 官方就是 POST，没必要赌 `entry.cgi` 收 GET。
  Future<Object?> _rawCall(
    String apiName,
    String method,
    List<int> candidates,
  ) async {
    final what = '$apiName.$method';
    final bytes = await api.postBytesForm(api.apiPath(apiName), {
      'api': apiName,
      'version': '${_negotiate(apiName, candidates)}',
      'method': method,
    });
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      throw DsmApiException(DsmErrorCode.unknown, method: what);
    }
    if (decoded is Map) {
      if (decoded['success'] == true) return decoded['data'];
      final err = decoded['error'];
      final code = (err is Map && err['code'] is num)
          ? (err['code'] as num).toInt()
          : DsmErrorCode.unknown;
      throw DsmApiException(
        code,
        method: what,
        raw: Map<String, dynamic>.from(decoded),
      );
    }
    // 裸数组 / 裸对象（真机 `Cal.Timezone/list` 走的就是这条）
    return decoded;
  }

  /// `Event/list_color` **v6** —— 事件配色候选。
  ///
  /// 证据：
  /// * 方法表：`SYNO.Cal.Event` 的 `list_color` **只在 v6**（`SYNO.Cal.lib`；
  ///   真机 v1–v5 全 **103**，v6 ✅）；
  /// * 参数：**无参可调**（真机 2026-09-22 无参成功）；
  /// * 回包：**形状未取证**（官方客户端没有调用点、`openapi.json` 也没有对应
  ///   path）⇒ [CalEventColorDto.listFromJson] 走宽松解析；
  /// * 走 [_rawCall]（不是 `call`）：万一服务端回**裸数组**也不会被丢成 `{}`。
  ///
  /// 解析不出来就回**空列表**，界面照实说"服务端没有回配色" —— **不回退到写死的
  /// 调色板**（那会把"接口没接通"伪装成"功能正常"）。
  Future<List<CalEventColorDto>> listEventColors() async {
    final data = await _rawCall(eventApi, 'list_color', const [6]);
    return CalEventColorDto.listFromJson(data);
  }

  /// `Todo/count_todo` —— 待办**数量**（角标用）。
  ///
  /// 证据：
  /// * 方法表：`SYNO.Cal.Todo` 的 `count_todo` 在 **v1 / v5 / v6**（`SYNO.Cal.lib`）；
  ///   真机 **v1 无参** ✅ 回 `{"data":{"result":{}}}`（空 = 没有待办）；
  /// * 参数名来自**官方客户端**（`ui/synocalendar-todo.js` 的
  ///   `fetchUncompleteTodoCount` 与 `synocalendar.bundle.min.js` 的
  ///   `countUncompleteItem` / `countCompleteItem`，两处独立印证）：
  ///   `filter_due`（`all` / `yes` / `no`）、`filter_complete`（`yes`/`no`/`all`）、
  ///   可选的 `due`（epoch 秒）与 `cal_id_list`（JSON 数组串）；
  /// * 回包取 **`data.result`**（官方客户端逐字：`a[0].data.result`）。
  ///
  /// ⚠️ **未逐字取证**：真机只验过"v1 无参"，上面这套带筛选参数的形状是
  /// **客户端取证**。所以调用方（provider）必须把失败当作"角标不显示"，
  /// **不能当成 0**（见 `calTodoUncompletedCountProvider`）。
  ///
  /// [filterDue] 默认 `all` + [filterComplete] 默认 `no` —— 与官方
  /// `countUncompleteItem` 的第一段请求逐字一致。
  Future<int> countTodos({
    String filterDue = 'all',
    String filterComplete = 'no',
    DateTime? due,
    List<String> calendarIds = const [],
  }) async {
    final data = await api.call(
      todoApi,
      'count_todo',
      preferredVersion: _negotiate(todoApi, const [6, 5, 1]),
      params: {
        // 枚举串是**裸串**（`Todo/list` 的 `filter_complete` 同理，真机验过）
        'filter_due': filterDue,
        'filter_complete': filterComplete,
        if (due != null) 'due': '${due.millisecondsSinceEpoch ~/ 1000}',
        if (calendarIds.isNotEmpty) 'cal_id_list': _js(calendarIds),
      },
    );
    return _parseTodoCount(data['result']);
  }

  /// `Sharing/get` **v1** —— 某个日历的共享成员（**只读**）。
  ///
  /// 证据（真机 2026-09-22，普通用户）：
  /// ```text
  /// {cal_id:"/demo_user/home/"}
  /// → {"data":{"/demo_user/home/":{"DSM_GROUP":[],"DSM_USER":[]}}}
  /// ```
  /// * 参数名就是 **`cal_id`**（传 `id` → **117**）；**裸串**（不包 Gson 引号）；
  /// * **不能用 v2**（真机 → **104**）；方法表里 `Sharing` 也只有 v1；
  /// * 回包**按 `cal_id` 分组**，成员分 `DSM_USER` / `DSM_GROUP` 两个数组。
  Future<List<CalShareMemberDto>> calendarSharing(String calId) async {
    if (calId.isEmpty) return const [];
    final data = await api.call(
      sharingApi,
      'get',
      preferredVersion: _negotiate(sharingApi, const [1]),
      params: {'cal_id': calId},
    );
    return CalShareMemberDto.listFromJson(data, calId);
  }

  /// `Sharing/set` **v1** —— **整体替换**某个日历的共享成员。
  ///
  /// 参数取自**官方客户端**（`ui/synocalendar.bundle.min.js` 的
  /// `setSharingCalendar(e, t)`）：
  /// ```js
  /// const n = {DSM_USER: [], DSM_GROUP: []};
  /// for (const e of t) {
  ///   const t = {ug_name: e.isUser ? e.userName : e.displayName,
  ///              cal_privilege: e.permission};
  ///   e.isUser ? n.DSM_USER.push(t) : n.DSM_GROUP.push(t);
  /// }
  /// this.runAPI("Sharing_set", {calId: e, calShareSetting: n}, {shallow: true});
  /// ```
  /// 参数层把 `calId`/`calShareSetting` 转成 `cal_id`/`cal_share_setting`；
  /// 嵌套对象照 `notify_setting` 的口径发 **JSON 串**，`cal_id` 照 `Sharing/get`
  /// 真机口径发**裸串**。
  ///
  /// ✅ **已真机验证（2026-09-22，普通用户）**：以**空成员**调用 `set` 返回成功，
  /// 且**改前/改后 `Sharing/get` 逐字一致**（语义空操作）——证明参数名
  /// **`cal_share_setting`** 与 **`{DSM_USER:[], DSM_GROUP:[]}`** 的 JSON 形状
  /// 均被服务端接受。本机共享列表本身为空，**非空成员的往返未试**。
  /// 界面仍把失败**明说**（[describeCalendarError]），绝不静默（见 falsification ⑤）。
  /// 包内 `webapi/SYNO.Cal.Sharing.so` 的 schema 也独立印证了字段名
  /// （`DSM_ug{ug_name}`、`cal_acl{cal_privilege}`）。
  ///
  /// [members] 为**空列表** = 取消这个日历的全部共享（服务端 `set` 是全量语义）。
  Future<List<CalShareMemberDto>> setCalendarSharing({
    required String calId,
    required List<CalShareMemberDto> members,
  }) async {
    final users = [
      for (final m in members)
        if (m.isUser) m.toApiJson(),
    ];
    final groups = [
      for (final m in members)
        if (!m.isUser) m.toApiJson(),
    ];
    final data = await api.call(
      sharingApi,
      'set',
      preferredVersion: _negotiate(sharingApi, const [1]),
      params: {
        'cal_id': calId,
        'cal_share_setting': _js({'DSM_USER': users, 'DSM_GROUP': groups}),
      },
    );
    return CalShareMemberDto.listFromJson(data, calId);
  }

  /// `Share.Priv/list` **v1** —— 共享候选账号（用户 / 群组）。**只读**。
  ///
  /// 证据（真机 2026-09-22，普通用户，**无参**）：
  /// ```json
  /// {"data":{"list":[{"name":"admin","type":"user","uid":1024,"value":"user:admin"}, …]}}
  /// ```
  /// 方法表：`SYNO.Cal.Share.Priv` 只有 v1 的 `list`。
  Future<List<CalSharePrincipalDto>> sharePrincipals() async {
    final data = await api.call(
      sharePrivApi,
      'list',
      preferredVersion: _negotiate(sharePrivApi, const [1]),
      params: const {},
    );
    return CalSharePrincipalDto.listFromJson(data);
  }

  /// `Timezone/list` —— 时区表（新建/编辑事件时的 `tz_id`）。
  ///
  /// 证据：
  /// * 方法表：`SYNO.Cal.Timezone` v1–2 / v5 都有 `list`；
  /// * 真机 2026-09-22（普通用户，**无参**）回的是 **裸数组**：
  ///   `[{"temp":"Africa/Abidjan","tzid":"Africa/Abidjan","vtimezone":"BEGIN:VTIMEZONE…"}]`
  ///   —— **不是** `{data:{list}}`，所以必须走 [_rawCall]；
  /// * 包内 `openapi.json` 的 `GET /timezone`（`x-syno-version: 5`）是同一份语义、
  ///   包成 `data.list[timezone_obj_0]` ⇒ `listFromJson` 两种形状都收。
  Future<List<CalTimezoneDto>> timezones() async {
    final data = await _rawCall(timezoneApi, 'list', const [5, 2, 1]);
    return CalTimezoneDto.listFromJson(data);
  }

  // ==========================================================================
  // wave2（2026-09-22）—— 日历导出（只读） + 待办搜索（只读）
  //
  // 纪律与 wave1 相同：方法/版本/参数/回包**逐条有出处**（真机回包 + 包内
  // `webapi/*.lib` 的方法表），没有出处的一律不写。
  // ==========================================================================

  /// `Cal.Cal/export` **v1** —— 导出整个日历为 **ICS 文本**。
  ///
  /// 证据（**真机 2026-09-22，普通用户**）：
  /// ```text
  /// SYNO.Cal.Cal / export / v1 / {cal_id:"/demo_user/home/"}
  /// → 裸 ICS 文本：
  ///   BEGIN:VCALENDAR\r\nPRODID:-//davical.org//NONSGML AWL Calendar//EN\r\n
  ///   VERSION:2.0\r\nCALSCALE:GREGORIAN\r\nX-WR-CALNAME:My Calendar\r\n
  ///   END:VCALENDAR
  /// ```
  /// * 事件日历（`/demo_user/home/`）与待办日历（`/demo_user/home_todo/`）
  ///   **同一个 `cal_id` 参数**都能导（真机两者都调通）；
  /// * **必须 v1**：v2–v5 都回 **103**（方法只在 v1）。包内
  ///   `webapi/SYNO.Cal.lib` 的方法表独立印证：`export` 只出现在
  ///   `SYNO.Cal.Cal` 的 `methods["1"]` 里，且 `"allowDownload": true`、
  ///   `allowUser` 含 `normal.*`（普通用户可用）；
  /// * **`cal_id` 是必需参数**：不给 → **117**。`cal_type` **不需要**
  ///   （带上也成功、回包相同，所以这里**不发**）；
  /// * ⚠️ **回包不是 JSON**：是 `text/calendar` 裸文本。走 [postBytesForm]
  ///   取原始字节 + [decodeCalendarIcsExport] 解码，**绝不走 `api.call`**
  ///   （`_okData` 只认 Map 形态的 `data`）。
  ///
  /// 失败（如 117/103）时服务端回的是**JSON 错误体**，由
  /// [decodeCalendarIcsExport] 认出来后抛 [DsmApiException]（**不静默**）。
  Future<String> exportCalendarIcs(String calId) async {
    if (calId.isEmpty) {
      // 真机无参 = 117；本地先拦下来，别发一个已知必失败的请求。
      throw DsmApiException(
        DsmErrorCode.internalError,
        method: '$calApi.export',
      );
    }
    final what = '$calApi.export';
    final bytes = await api.postBytesForm(api.apiPath(calApi), {
      'api': calApi,
      // 方法只在 v1：v2–v5 全 103（真机逐版试过）
      'version': '${_negotiate(calApi, const [1])}',
      'method': 'export',
      // 裸串（与 `Sharing/get` 的 `cal_id` 同口径；真机就是这么调的）
      'cal_id': calId,
    });
    return decodeCalendarIcsExport(bytes, what: what);
  }

  /// `Todo/search` **v1** —— 按 `cal_id` **或** `keyword` 搜待办。
  ///
  /// 证据（**真机 2026-09-22，普通用户**）：
  /// * `cal_id` 与 `keyword` **两者都实测可调**；
  /// * 回包逐字：`{"data":{"evt_list_result":[],"total":0}}`
  ///   —— root 是 **`evt_list_result`**（不是 `todolist`）；
  /// * 方法只在 **v1**：包内 `webapi/SYNO.Cal.lib` 的 `SYNO.Cal.Todo`
  ///   方法表里 `search` 只出现在 `methods["1"]`；
  /// * `keyword` 在包内 `lib/libcalwebapi.so` 的参数簇里与 `cal_id_list` /
  ///   `limit` / `filter_visible` 同段，服务端按 `jIn["keyword"].isString()`
  ///   判定 ⇒ 发**裸串**（不包 Gson 引号）。
  ///
  /// [calId] 与 [keyword] 都为空时**按 v1 原样发**（真机空参也是合法调用，
  /// 回空结果）；要限定范围就传 [calId]，要搜内容就传 [keyword]。
  Future<CalTodoSearchResultDto> searchTodos({
    String calId = '',
    String keyword = '',
  }) async {
    final data = await api.call(
      todoApi,
      'search',
      preferredVersion: _negotiate(todoApi, const [1]),
      params: {
        // 两者都是裸串；服务端 `jIn["keyword"].isString()` 只要求它是字符串
        if (calId.isNotEmpty) 'cal_id': calId,
        if (keyword.isNotEmpty) 'keyword': keyword,
      },
    );
    return CalTodoSearchResultDto.fromJson(data);
  }

  /// `Event/create_from_ics` **v6** —— ICS 导入。**骨架 + 明确 TODO**。
  ///
  /// 方法/版本已钉（见 [icsImportUnavailableReason]），但**参数名未取证**，
  /// 按项目纪律**不写死**：一写死就是"点了必然 9009"的入口。
  /// 真机探测结果：v6 无参 → **9009 invalid_parameter**。
  ///
  /// TODO（拿到权威参数名后照这个签名补齐，别改调用方）：
  /// 1. 参数名 —— 候选（**互相矛盾，未判定**）：`ics_file`/`ics_file_name`
  ///    （`SYNO.Cal.Event.so` 的 `syno_cal_map`，但那看起来属于外部日历导入
  ///    任务）、裸串 `ics`（`libcalwebapi.so` 的参数簇）；
  /// 2. 目标日历参数（`cal_id` / `original_cal_id`？）与冲突策略；
  /// 3. 回包是"单个事件"还是"导入结果汇总"。
  Future<Never> createEventFromIcs() async {
    // r378：异常措辞也不许夹开发用语 / 接口路径（它可能被错误条直接渲染给用户）。
    // 技术依据在上面的 /// 注释里，不进用户可见的字符串。
    throw UnsupportedError('本应用暂不支持从 .ics 文件导入日历事件。');
  }
}

/// `count_todo` 的 `data.result` → int。
///
/// 真机空库回 **`{"result":{}}`**（**空对象**！不是 `0`），所以"宽松解析"是
/// 必须的：数字直接用、数字串解析、空对象/空串当 0、取不到就当 0。
/// 解析不出来的**非空**结构也回 0（宁可显示 0 也不要抛异常把整页带崩）。
int _parseTodoCount(Object? raw) {
  if (raw == null) return 0;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw) ?? 0;
  if (raw is Map) {
    // 形状未取证时的兜底：取第一个数字值（不猜键名）
    for (final v in raw.values) {
      final n = _parseTodoCount(v);
      if (n != 0) return n;
    }
    return 0;
  }
  if (raw is List) return raw.length;
  return 0;
}

/// `Cal.Cal/export` 的**裸文本**回包解码。
///
/// 成功回的是 `text/calendar` 裸 ICS（`BEGIN:VCALENDAR…`），**不是 JSON**
/// —— 真机逐字见 [CalendarApi.exportCalendarIcs]。所以这里**不**做
/// `jsonDecode`：那样一行都解不出来（falsification ②）。
///
/// 唯一要解 JSON 的情况是**错误回包**：DSM 的 API 错误（117 / 103 / 9009…）
/// 是 HTTP 200 + `{"success":false,"error":{"code":…}}`。判据只认"第一个非空白
/// 字符是 `{`"这一条 —— ICS 文本不可能以 `{` 开头（必须以 `BEGIN:VCALENDAR`
/// 开头），所以不会把正常回包误判成错误体。解不出 JSON 就按文本原样返回
/// （宁可把原文交给调用方，也不吞掉内容）。
String decodeCalendarIcsExport(List<int> bytes, {required String what}) {
  final text = utf8.decode(bytes, allowMalformed: true);
  final head = text.trimLeft();
  if (!head.startsWith('{')) return text;
  final Object? decoded;
  try {
    decoded = jsonDecode(head);
  } catch (_) {
    return text;
  }
  if (decoded is Map && decoded['success'] != true) {
    final err = decoded['error'];
    final code = (err is Map && err['code'] is num)
        ? (err['code'] as num).toInt()
        : DsmErrorCode.unknown;
    throw DsmApiException(
      code,
      method: what,
      raw: Map<String, dynamic>.from(decoded),
    );
  }
  return text;
}
