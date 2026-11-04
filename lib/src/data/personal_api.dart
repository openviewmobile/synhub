// `SYNO.Personal.Profile`（个人资料）**只读**协议层。
//
// ## 为什么单独一个文件
// 本仓的数据层按"服务端 API 家族"分文件（`filestation_api.dart` /
// `foto_api.dart` / `foto_c2_api.dart` …）。`SYNO.Personal.Profile` 不属于
// 任何一个站点的 `StationService`，它是 DSM 的个人资料端点，所以单独落在这里，
// 而不是塞进 `chat_api.dart`（那里只有 `Personal.Profile.Photo / delete` 一条，
// 是"删头像"的写路径，与本文件的只读 `get` 不是一回事）。
//
// ## 事实来源（真机只读实测，原文见 docs/device-readonly-verification-evidence-r16.md §12）
//
// ```console
// SYNO.Personal.Profile/get  path=entry.cgi  v1..3  （无参）
//   → {"id":"a83c54f9-4b31-424e-b82b-9653697f921f",
//      "email":"","emails":[],"nickName":"","isGuest":false}
// ```
//
// ⇒ 三件已取证的事：
//   1. **path = `entry.cgi`** —— 但本文件**不写死 path**：一律走
//      `DsmWebApi.call` → `_prepare`，由 `SYNO.API.Info` 的能力表决定路径
//      （规程 §1.4）。
//   2. **版本区间 v1..v3** —— 本文件**不写死版本**：候选 `[3,2,1]` 交给
//      [negotiate] 按能力表收敛（规程 §5.3）。
//   3. 回包是**裸对象**（不是 `{data:{…}}` 包装）。
//
// ## 只读承诺（规程 §5.1）
// 本文件**只有 `get`**，没有任何 `set`/`update`/`edit`/`save`/`delete` 调用。
library;

import '../core/net/traffic_meter.dart';
import '../dsm/webapi.dart';

/// `SYNO.Personal.Profile` 的 API 名。
const String kPersonalProfileApi = 'SYNO.Personal.Profile';

/// 当前账号的个人资料（`SYNO.Personal.Profile / get`）。
///
/// 字段名**逐字**来自真机回包（见文件头）：
///   * `id` —— 账号的稳定标识（真机是 UUID 形态）；
///   * `email` —— 主邮箱；真机可为空串；
///   * `emails` —— 邮箱**数组**（真机为 `[]`）；空数组是正常状态，不是错误；
///   * `nickName` —— 昵称；真机可为空串；
///   * `isGuest` —— 是否访客账号。
///
/// ⚠️ 解析**不补默认值**：服务端给空串就是空串，界面据此显示"未设置"
/// （`nickName`/`email` 都是空串时**不能**编一个名字出来）。
class PersonalProfileDto {
  const PersonalProfileDto({
    this.id = '',
    this.email = '',
    this.emails = const [],
    this.nickName = '',
    this.isGuest = false,
  });

  factory PersonalProfileDto.fromJson(Map<String, dynamic> json) {
    return PersonalProfileDto(
      id: _str(json['id']),
      email: _str(json['email']),
      emails: _strList(json['emails']),
      // 服务端用 `nickName`（大写 N）；`nickname` 只是**宽松兜底**
      // —— 老版本服务端若换过键名不至于整块不显示，但**不作为主键**。
      nickName: _str(json['nickName'] ?? json['nickname']),
      isGuest: json['isGuest'] == true,
    );
  }

  /// 账号标识（真机是 UUID；可能为空 —— 服务端没给就如实空着）
  final String id;

  /// 主邮箱（可能是空串 ⇒ 界面显示"未设置"）
  final String email;

  /// 邮箱数组（可能是空数组 ⇒ 界面走空态，**不是**错误）
  final List<String> emails;

  /// 昵称（可能是空串 ⇒ 界面显示"未设置"）
  final String nickName;

  /// 是否访客账号（真机回 `false`）
  final bool isGuest;

  /// 昵称是否**真的**有值（全空白视同没设置）
  bool get hasNickName => nickName.trim().isNotEmpty;

  /// 主邮箱是否有值
  bool get hasEmail => email.trim().isNotEmpty;

  /// 邮箱数组里去掉空串后的有效项
  List<String> get validEmails => [
    for (final e in emails)
      if (e.trim().isNotEmpty) e,
  ];

  /// 是否有**任何**可显示的邮箱（主邮箱或数组里任一项）
  bool get hasAnyEmail => hasEmail || validEmails.isNotEmpty;

  static String _str(Object? v) => v == null ? '' : '$v';

  static List<String> _strList(Object? v) {
    if (v is! List) return const [];
    return [
      for (final e in v)
        if (e != null) '$e',
    ];
  }

  @override
  String toString() =>
      'PersonalProfileDto(id=$id, nickName=$nickName, '
      'email=$email, emails=${emails.length}, isGuest=$isGuest)';
}

/// `SYNO.Personal.Profile` 的只读客户端。
///
/// 与 `FileStationApi` / `FotoApi` 同一套约定：自己只负责**协商版本 + 组装参数
/// + 解析**，path 与 `_sid`/CSRF 全部由 [DsmWebApi] 处理。
class PersonalApi {
  PersonalApi(DsmWebApi api) : api = api.withModule(TrafficModules.settings);

  final DsmWebApi api;

  /// 候选版本里挑一个服务器真正支持的（与 `ChatApi.negotiate` /
  /// `FileStationApi.negotiate` 同规则）。
  ///
  /// 真机 `SYNO.Personal.Profile` 是 `minVersion=1, maxVersion=3`，
  /// 候选 `[3,2,1]` ⇒ 收敛到 3。能力表还没拉到（未登录）时**不猜**，
  /// 取候选里的最高档交给服务端裁决（`call` 里 `_prepare` 还会再收敛一次）。
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

  /// 服务器有没有这个 API（能力表为空 = 未知，按"有"处理，交给调用兜底）。
  bool hasApi(String apiName) {
    final table = api.apiTable;
    if (table == null) return true;
    return table.containsKey(apiName);
  }

  /// 当前账号资料 —— `SYNO.Personal.Profile / get`（**只读**，无参数）。
  ///
  /// 版本走 [negotiate]（候选 `[3,2,1]`，真机 v1..3）；path 由 `SYNO.API.Info`
  /// 决定（真机 `entry.cgi`），本方法**不写死路径**。
  ///
  /// 回包是裸对象（见 [PersonalProfileDto] 的字段证据），所以直接把 `data`
  /// 交给 DTO 解析。
  Future<PersonalProfileDto> profile() async {
    final data = await api.call(
      kPersonalProfileApi,
      'get',
      preferredVersion: negotiate(kPersonalProfileApi, const [3, 2, 1]),
      params: const {},
    );
    return PersonalProfileDto.fromJson(data);
  }
}
