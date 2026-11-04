// `SYNO.Personal.Notification.*`（**站内通知 / 移动端配对**）协议层。
//
// ## 为什么单独一个文件，而不是塞进 `chat_api.dart` / `personal_api.dart`
//
// * `chat_api.dart` 只装 `SYNO.Chat.*`；
// * `personal_api.dart` 在文件头**明确承诺"只读"**（只有 `get`，没有任何
//   `set`/`delete`），把本家族的写路径塞进去会**打破它自己写下的契约**；
// * 本家族是 DSM **平台级**端点（不属于任何 Station，也不属于任何 SPK），
//   和 `SYNO.Personal.Profile` 同类，所以按同一条理由单独成文件。
//
// ## 事实来源与**证据等级**（这一点必须说清楚）
//
// **方法名与版本区间**：`docs/api-server-authoritative.md:977-990`，逐版本原文：
//
// ```
// Conf        v1-2: get, set                        普通用户
// Device      v1: list, unpair ｜ v2: list          普通用户
// Event       v1: delete, get, list, send ｜ v2: delete, list   普通用户
// Filter      v1: list, set                         普通用户
// GDPR        v1: get, set                          普通用户
// Identifier  v1: get                               普通用户
// Mobile      v1-3: pair, stat, unpair              普通用户
// Settings    v1: get, set, setup ｜ v2: get, set    普通用户
// Token       v1: get                               普通用户
// VapidPublicKey v1: get                            普通用户
// ```
//
// **真机存在性**：`SYNO.Personal.Notification.{Mobile,Settings,Token}` 三个在
// `test/fixtures/api_table.json`（`SYNO.API.Info` 实况快照）里**确实存在**，
// 版本区间与上表一致（Mobile v1-3 / Settings v1-2 / Token v1）。
//
// ⚠️ **证据等级的诚实声明**：
//   1. 上表来自**仓库内的文档**，不是 `.lib` 二进制实证。为了不让 Mock 变成
//      "方法名不校验"的空壳，`tool/mock_dsm/build_catalog.py` 的
//      `DOC_METHOD_OVERLAY` 把这些方法灌进了目录，并把 `source` 标成
//      `"doc:api-server-authoritative"` —— **一眼可分辨它不是 `spk`**。
//   2. 本文件**只实现只读方法**（`get` / `list` / `stat`）。
//      写方法（`set` / `pair` / `unpair` / `delete` / `send` / `setup`）
//      **参数形状没有证据** —— 按本会话铁律「不猜」，**故不实现**，
//      并在差距表登记"方法有据、参数形状无据"。
//
// ## 只读承诺（规程 §5.1）
// 本文件**只有** `get` / `list` / `stat` 三类只读动词。
// 全文件 `grep -E "'(set|delete|pair|unpair|send|setup)'"` → 0。
library;

import '../core/net/traffic_meter.dart';
import '../dsm/webapi.dart';

/// `SYNO.Personal.Notification.*` 的只读封装。
class PersonalNotificationApi {
  PersonalNotificationApi(DsmWebApi api)
    : api = api.withModule(TrafficModules.settings);

  final DsmWebApi api;

  /// 候选版本里挑一个服务器真正支持的（与 [ChatApi.negotiate] 同一套规则，
  /// 但本文件不依赖 `chat_api.dart`，避免把两个家族耦在一起）。
  ///
  /// 规则照抄 APK 的 `Api.getMaxAvailableVersion`：取"不超过服务器 maxVersion
  /// 的最大候选"；服务器区间完全落在候选之外时退到区间端点。
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

  // ── 通知设置 ─────────────────────────────────────────────────────────

  /// `SYNO.Personal.Notification.Settings / get`（候选 v2、v1）。
  ///
  /// 回包**原样返回**：本文件**不发明字段名**。真机形态尚未采样，
  /// 编一个 DTO 出来只会把猜测固化成"接口"。
  Future<Map<String, dynamic>> settingsGet() {
    return _get('SYNO.Personal.Notification.Settings', 'get', const [2, 1]);
  }

  // ── 全局通知配置 ─────────────────────────────────────────────────────

  /// `SYNO.Personal.Notification.Conf / get`（候选 v2、v1）。
  Future<Map<String, dynamic>> confGet() {
    return _get('SYNO.Personal.Notification.Conf', 'get', const [2, 1]);
  }

  // ── 已配对设备 ───────────────────────────────────────────────────────

  /// `SYNO.Personal.Notification.Device / list`（候选 v2、v1）。
  ///
  /// 注意：**不是 `get`** —— 文档给的是 `list`/`unpair`。
  /// 把 `data` 里的 `list` 数组原样取出；取不到就回空表（服务端少给字段
  /// 不该让界面崩）。
  Future<List<dynamic>> deviceList() async {
    final data = await api.call(
      'SYNO.Personal.Notification.Device',
      'list',
      preferredVersion: negotiate('SYNO.Personal.Notification.Device', const [
        2,
        1,
      ]),
      params: const {},
    );
    final raw = data['list'] ?? data['devices'] ?? data['items'];
    return raw is List ? raw : const [];
  }

  // ── 通知事件 ─────────────────────────────────────────────────────────

  /// `SYNO.Personal.Notification.Event / list`（候选 v2、v1）。
  Future<List<dynamic>> eventList() async {
    final data = await api.call(
      'SYNO.Personal.Notification.Event',
      'list',
      preferredVersion: negotiate('SYNO.Personal.Notification.Event', const [
        2,
        1,
      ]),
      params: const {},
    );
    final raw = data['list'] ?? data['events'] ?? data['items'];
    return raw is List ? raw : const [];
  }

  // ── 通知过滤规则 ─────────────────────────────────────────────────────

  /// `SYNO.Personal.Notification.Filter / list`（**只有 v1**）。
  Future<Map<String, dynamic>> filterList() {
    return _get('SYNO.Personal.Notification.Filter', 'list', const [1]);
  }

  // ── GDPR ─────────────────────────────────────────────────────────────

  /// `SYNO.Personal.Notification.GDPR / get`（**只有 v1**）。
  Future<Map<String, dynamic>> gdprGet() {
    return _get('SYNO.Personal.Notification.GDPR', 'get', const [1]);
  }

  // ── 设备标识 ─────────────────────────────────────────────────────────

  /// `SYNO.Personal.Notification.Identifier / get`（**只有 v1**）。
  Future<Map<String, dynamic>> identifierGet() {
    return _get('SYNO.Personal.Notification.Identifier', 'get', const [1]);
  }

  // ── 移动端配对状态 ───────────────────────────────────────────────────

  /// `SYNO.Personal.Notification.Mobile / stat`（候选 v3、v2、v1）。
  ///
  /// ⚠️ 是 **`stat` 不是 `get`** —— 这一点很关键：官方 Chat APK 里这个方法
  /// 出现在 `queryGuestAccount` 附近，所以行 261（Guest 登录）的取证要从它入手。
  Future<Map<String, dynamic>> mobileStat() {
    return _get('SYNO.Personal.Notification.Mobile', 'stat', const [3, 2, 1]);
  }

  // ── 推送令牌 ─────────────────────────────────────────────────────────

  /// `SYNO.Personal.Notification.Token / get`（**只有 v1**）。
  ///
  /// **真机只读实测回包**（2026-09-23，`docs/incident-2026-09-23-profile-photo-delete.md`
  /// 同批探针，动词是 `get`、只读）：
  /// ```json
  /// {"oauth_id": 6036730795258706916,
  ///  "pushbrowser_server": "https://notification.synology.com/..."}
  /// ```
  /// ⇒ 两个字段名**是实测的**，不是编的。返回原 map，不裁剪字段。
  Future<Map<String, dynamic>> tokenGet() {
    return _get('SYNO.Personal.Notification.Token', 'get', const [1]);
  }

  // ── Web Push 公钥 ────────────────────────────────────────────────────

  /// `SYNO.Personal.Notification.VapidPublicKey / get`（**只有 v1**）。
  ///
  /// VAPID = Web Push 的公钥；DSM 用它给浏览器做免账号推送。
  /// 回包原样返回（`data` 里通常是 `{"public_key": "..."}`）。
  Future<Map<String, dynamic>> vapidPublicKeyGet() {
    return _get('SYNO.Personal.Notification.VapidPublicKey', 'get', const [1]);
  }

  // ── 内部 ─────────────────────────────────────────────────────────────

  /// 只读 `get` 的统一入口 —— 把"声明候选版本 + 交给能力表收敛"收在一处。
  ///
  /// * **不写死 path**：一律走 `DsmWebApi.call` → `_prepare`，由
  ///   `SYNO.API.Info` 的能力表决定路径（规程 §1.4）。
  /// * **不写死版本**：候选交给 [negotiate]（规程 §5.3）。
  Future<Map<String, dynamic>> _get(
    String apiName,
    String method,
    List<int> candidates,
  ) {
    return api.call(
      apiName,
      method,
      preferredVersion: negotiate(apiName, candidates),
      params: const {},
    );
  }
}

/// 本家族在权威目录里的 API 名单（10 个）—— 供用例与审计脚本对照。
///
/// **刻意用 `const` 列在代码里**：以后有人往上面加方法时，会让这份清单
/// 和真实调用同时被 review 到，不容易静默漂移。
const List<String> kPersonalNotificationApis = [
  'SYNO.Personal.Notification.Conf',
  'SYNO.Personal.Notification.Device',
  'SYNO.Personal.Notification.Event',
  'SYNO.Personal.Notification.Filter',
  'SYNO.Personal.Notification.GDPR',
  'SYNO.Personal.Notification.Identifier',
  'SYNO.Personal.Notification.Mobile',
  'SYNO.Personal.Notification.Settings',
  'SYNO.Personal.Notification.Token',
  'SYNO.Personal.Notification.VapidPublicKey',
];
