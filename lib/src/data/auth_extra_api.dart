// **登录/账户相关的补充只读 API** —— ②聊天 的 API 级对照缺口（第 33 轮）。
//
// ## 为什么单独一个文件
// 本仓的登录由 [DsmWebApi.login] 自己实现（`SYNO.API.Auth` + 加密），
// 那部分**不拆**。这里放的是**登录外围**、独立成族、且官方安卓客户端
// 确实列在已知 API 表里的几个端点：
//
//   * `SYNO.API.Auth.Type`              —— 问服务端"登录方式是什么"
//   * `SYNO.Auth.RescueEmail`           —— 救援邮箱状态（找回账号）
//   * `SYNO.ActiveInsight.Package`      —— Active Insight 是否启用
//
// ## ★ 事实来源：**官方 Web JS 的调用点**（不是猜的）
//
// 官方 Web JS 是本会话允许的三类事实源之一。以下片段是从
// `/tmp/spk/ex_AI_pat/usr/syno/synoman/...` 里抓的**原文**：
//
// ```js
// // ── SYNO.API.Auth.Type ──  dsm.common.bundle.js
// synowebapi.promises.request({
//   api: "SYNO.API.Auth.Type", version: 1, method: "get"     // ← 无 params
// })
//
// // ── SYNO.Auth.RescueEmail / get ──  WelcomeApp/PromotionApp.js
// synowebapi.promises.request({
//   api: "SYNO.Auth.RescueEmail", method: "get", version: 1  // ← 无 params
// }).then(e => { this.verified = e.verified })
//
// // ── SYNO.Auth.RescueEmail / verify ──  同上
// synowebapi.promises.request({ api: "SYNO.Auth.RescueEmail",
//   method: "verify", version: 1 })                          // ← 无 params
// // 回包用到 attempted / verified / hasEmail 三个字段
//
// // ── SYNO.ActiveInsight.Package / get_status ── 同上
// const { enabled: e } = await synowebapi.promises.request({
//   api: "SYNO.ActiveInsight.Package", version: 2, method: "get_status" })
// ```
//
// ⇒ **三个 `get` 类方法都无必填参数**，且回包字段名（`verified` / `enabled`）
//   也是从官方 JS 里读出来的，**不是我编的**。
//
// ## 只读承诺（规程 §5.1）
// 本文件**只有 `get` / `get_status`**。
// ⚠️ 同一族里还有**未实现**的写/敏感方法，理由逐条写在文件末尾的
// [kAuthExtraNotImplemented] 里 —— **不是忘了**。
library;

import '../core/entitlement/session_entitlement.dart';
import '../core/net/traffic_meter.dart';
import '../dsm/webapi.dart';

/// `SYNO.API.Auth.Type` 的 API 名。
const String kAuthTypeApi = 'SYNO.API.Auth.Type';

/// `SYNO.Auth.RescueEmail` 的 API 名。
const String kRescueEmailApi = 'SYNO.Auth.RescueEmail';

/// `SYNO.ActiveInsight.Package` 的 API 名。
const String kActiveInsightApi = 'SYNO.ActiveInsight.Package';

/// `SYNO.Core.NormalUser` —— DSM 标准的「当前用户资料」接口。
///
/// ★ 用户 2026-09-23 新规要求：**管理员功能必须实现且按身份门控**
/// （非管理员隐藏、管理员展示）。门控的前提是**客户端知道当前用户是不是管理员**，
/// 这个常量就是那条身份通道的入口。
///
/// `.lib` 权威表（`tool/mock_dsm/catalog.json`）：
/// `min 1 / max 2`，**v1 只有 `get`**，v2 才有 `set`；`adminOnly: false`
/// ⇒ 普通用户可以调用 `get`（所以它能当身份探测用）。
/// **只用 v1 的 `get`** —— `set` 是写动词，本仓不做。
const String kNormalUserApi = 'SYNO.Core.NormalUser';

// ⚠️ **`kAdminProbeApi`（`SYNO.Core.System` v3 `info`）已删除**
// （第 254 轮，用户 2026-09-25 指令：「用你推荐的方式改掉之前用 `105` 探测的办法」）。
//
// 它当初的作用是"调一个 adminOnly 只读接口，把 `105` 读成'我不是管理员'"。
// 现在**不再需要**：Initdata 的 `Session.is_admin` 是**服务端下发的结论**
// （真机载荷实测存在，见 `docs/session-entitlement.md`），
// 没必要再拿一次"被拒绝"去反推身份 —— 那既多打一次最敏感的接口，
// 又把"网络/限流/`160`"之类的失败混进权限结论里。

/// ★★★ **官方 DS finder 用的身份通道**（第 75 轮 smali 实证）。
///
/// 证据链：
/// * `Android-DSfinder.2.5.7-484.ww.apk` 反编译，
///   `data/remote/vo/webapi/ApiInitDataVo.smali` 里有
///   `.field private is_admin:Z`；
/// * 同目录 `data/remote/api/ApiInit.smali` 里
///   `const-string "SYNO.Core.Desktop.Initdata"`，方法常量 `get`；
/// * `.lib`（`tool/mock_dsm/catalog.json`）：`adminOnly: false` / `normal: true`，
///   v1 = `get_user_lang, get_user_service, get_ui_config, get`
///   ⇒ **普通用户可以调 `get`**，是合法的身份通道。
///
/// ★ 同一个响应里还带 `support_wol` / `support_findme` / `hostname` /
/// `serial_number` —— 即 DS finder 用**一次** Initdata 同时拿到
/// "我是不是管理员"和"这台 NAS 支持哪些能力"，据此门控界面。
const String kInitDataApi = 'SYNO.Core.Desktop.Initdata';

/// `SYNO.SecureSignIn.AMFA.SuggestConn` —— 自适应 MFA 的连接建议。
///
/// ★ 事实来源：`SecureSignIn-x86_64-1.1.5-0362.spk` 的
/// `webapi/amfa/SYNO.SecureSignIn.AMFA.lib`（从 DSM PAT 里解出）：
/// ```
/// v1: ['get']   allowUser: [admin.*, normal.*]   authLevel: 1
/// ```
/// ⇒ **只有 `get`，且普通用户也能调**。
///
/// ⚠️ 待办背景（`docs/chat-apk-parity.md`）：官方 App 在**强制 2FA** 的
/// NAS 上登录时可能需要它。本仓当前只走 `SYNO.API.Auth`。
/// **在拿到"它确实是登录必经步骤"的证据之前，不把它接进登录流程**
/// —— 不猜流程。这里只提供**可验证的读取能力**。
const String kAmfaSuggestConnApi = 'SYNO.SecureSignIn.AMFA.SuggestConn';

/// `SYNO.SecureSignIn.AMFA.SuggestConn:get` 的版本（官方 smali 注解为 `0x1`）。
const int kAmfaSuggestConnVersion = 1;

/// `SYNO.SecureSignIn.AMFA.SuggestConn:get` 的结果。
///
/// ⚠️ **不断言字段名**：官方 smali 只给了 API/method/version，
/// 没给响应字段名，真机也未观察到（本机 NAS 未强制 2FA）。
/// 因此保留**原始 map**，由调用方按存在的键取值 —— 不臆造字段。
class AmfaSuggestConn {
  const AmfaSuggestConn(this.raw);

  /// 原始响应（键名未经验证）。
  final Map<String, dynamic> raw;

  /// 建议的连接方式（若有）。**仅在响应真的带了这些键时才非空。**
  String? get suggest =>
      (raw['suggest'] ?? raw['suggest_conn'] ?? raw['connection']) as String?;

  @override
  String toString() => 'AmfaSuggestConn($raw)';
}

/// 登录外围的只读端点。
class AuthExtraApi {
  AuthExtraApi(DsmWebApi api) : api = api.withModule(TrafficModules.settings);

  final DsmWebApi api;

  /// 候选版本里挑服务器支持的最大者（与 [ChatApi.negotiate] 同规则；
  /// 本文件不依赖 `chat_api.dart`，避免把两个家族耦在一起）。
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

  /// `SYNO.API.Auth.Type / get`（**v1**，官方 JS 里就是 `version: 1`）。
  ///
  /// **无必填参数**（官方 JS 原文见文件头）。回包原样返回 —— 官方 JS 只把它
  /// 当作"探活/探测登录类型"，具体字段在客户端没有进一步消费，
  /// 所以这里**不发明 DTO**。
  Future<Map<String, dynamic>> authType() async {
    return api.call(
      kAuthTypeApi,
      'get',
      preferredVersion: negotiate(kAuthTypeApi, const [1]),
      params: const {},
    );
  }

  /// `SYNO.Auth.RescueEmail / get`（**v1**）—— 救援邮箱是否已验证。
  ///
  /// 官方 JS：`.then(e => { this.verified = e.verified })`
  /// ⇒ **回包字段名 `verified` 有出处**。
  Future<bool> rescueEmailVerified() async {
    final data = await api.call(
      kRescueEmailApi,
      'get',
      preferredVersion: negotiate(kRescueEmailApi, const [1]),
      params: const {},
    );
    return data['verified'] == true;
  }

  /// `SYNO.ActiveInsight.Package / get_status`（候选 **v2、v1**）。
  ///
  /// 官方 JS 用的是 `version: 2` 且解构 `{enabled}` ⇒ 字段名有出处。
  /// 候选里保留 v1 是因为 `.lib` 里 v1/v2 都有 `get_status`。
  /// ⚠️★ **这是仅管理员 API**：`.lib` 里 `allowUser` 只有 `admin.*`
  /// （`admin.local` / `admin.domain` / `admin.ldap`）⇒ 普通用户调用拿 **105**
  /// （`noPermission`）。保留它是因为官方安卓客户端把它列在已知 API 表里
  /// （API 级对齐），且用户 2026-09-23 新规 B1 要求"涉及管理员的接口一律走
  /// Mock Server 模拟测试"。**Mock 用例已按 B1 双档验证**
  /// （非管理员 → 105；管理员 → 通过）。**界面不要对普通用户暴露它。**
  /// 当前登录用户**是不是管理员**。
  ///
  /// ## 字段名 `is_admin` 的证据
  /// * ★ **本仓已有可用先例**：`lib/src/data/dto/note_dto.dart:841`
  ///   从 `SYNO.NoteStation.Info/get` 的响应里读的就是 `is_admin`
  ///   （`isAdmin: asBool(j['is_admin'])`）—— 说明这是 DSM 服务**通用**的字段名，
  ///   不是某一个包的私有叫法；
  /// * DSM 官方桌面 JS 里 `is_admin` 也是全局身份位
  ///   （`dsm.desktop.bundle.js`：`_S("is_admin")` 用于门控管理入口）。
  ///
  /// ## ⚠️ 尚未证实的一点（不掩盖）
  /// `SYNO.Core.NormalUser:get` 的**响应里确实有 `is_admin`** 这件事，
  /// 本轮**没能**在真 NAS 上实测确认 —— 本机凭据登录返回 **`402`**
  /// （权限拒绝），探针拿不到回包。所以这里对**字段名有旁证、
  /// 但对该接口没有直证**。
  ///
  /// 兜底设计（正因为没直证，所以必须兜底）：
  /// * 字段缺失 / 类型不对 ⇒ **返回 `false`**（当普通用户处理）。
  ///   这个方向的错**安全**：宁可少显示管理功能，也**不能**把普通用户
  ///   当管理员而把管理入口摆出来（那会让用户点进去吃 `105`）。
  /// * 真机一旦能验，用实测把这里替换成直证结论。
  Future<bool> normalUserIsAdmin() async =>
      (await normalUserIsAdminOrNull()) ?? false;

  /// 同 [normalUserIsAdmin]，但**区分"字段说不是"与"字段缺失"**。
  ///
  /// * 字段**在**且为真 ⇒ `true`（明确是管理员）
  /// * 字段**在**且为假 ⇒ `false`（明确不是）
  /// * 字段**缺失/类型不对** ⇒ **`null`**（**不知道**）
  ///
  /// 为什么要区分：`null` 是"我的证据不够"，此时应当**继续走下一棒**
  /// （`resolveIsAdmin` 的接力链），而不是直接当普通用户。
  /// 早期版本把两者压成同一个 `false`，虽然方向安全，
  /// 但会让"字段改名/服务端差异"**永久**表现成"所有管理员都看不到管理功能"，
  /// 且我们**永远不会知道**自己判错了。
  ///
  /// ⚠️ 第 254 轮起，接力链**只有两棒**（Initdata → NormalUser）：
  /// 原先的第三棒"`105` 探测"已按用户指令删除，改为采信服务端下发的
  /// `Session.is_admin` / `AppPrivilege`（见 `docs/session-entitlement.md`）。
  Future<bool?> normalUserIsAdminOrNull() async {
    final data = await api.call(
      kNormalUserApi,
      'get',
      // 只用 v1 的 `get`：v2 只多一个 `set`（写动词，不做），
      // 且 `.lib` 里 `get` 在 v1 就有 ⇒ 没有必要上 v2。
      preferredVersion: negotiate(kNormalUserApi, const [1]),
      params: const {},
    );
    final raw = data['is_admin'];
    if (raw is bool) return raw;
    // 类型不对（字符串 "true"、数字 1）⇒ **不**做宽松转换。
    // 宽松转换会在字段语义变化时静默放行管理入口。
    return null;
  }

  /// ★★ **合并判定**（界面门控应该用这个，而不是上面任何一个单独用）。
  ///
  /// ① 先读 `is_admin`：有明确布尔就**采信**（最便宜，一次调用）；
  /// ② 字段缺失 ⇒ 用 `105` 探测；
  /// ③ 两者都拿不到结论 ⇒ **`false`**（当普通用户，方向安全）。
  Future<bool> resolveIsAdmin() async {
    // ★★★ 两棒接力（第 254 轮起**不再**有第三棒）：
    // ① `Desktop.Initdata` —— **官方 DS finder 就是走这条**（smali 实证），
    //    优先用它，因为"对齐官方"是本项目的验收口径；
    // ② `NormalUser:get` —— 通用身份接口（DSM 7 标准）。
    // 每一棒失败都**只是"这一棒不知道"**，不能中断整条链。
    // 两棒都无结论 ⇒ `false`（fail-closed，**不用 105 探测去猜**）。
    for (final probe in <Future<bool?> Function()>[
      initDataIsAdminOrNull,
      normalUserIsAdminOrNull,
    ]) {
      try {
        final r = await probe();
        if (r != null) return r;
      } catch (_) {
        // 该通道不可用（103 / 网络 / 未登录…）⇒ 交给下一棒
      }
    }
    return false;
  }

  /// ★★★ `SYNO.Core.Desktop.Initdata:get` 的 `is_admin`
  /// —— **官方 DS finder 用的就是这条**（见 [kInitDataApi] 的 smali 证据）。
  ///
  /// 返回 `null` 表示**这条通道给不出结论**（方法不存在 / 字段缺失 /
  /// 类型不对 / 网络错误），调用方应继续走下一棒。
  ///
  /// ⚠️ 与 [normalUserIsAdminOrNull] 不同，本方法**自己吞掉异常**并返回
  /// `null`：它处在接力链的**第一棒**，渠道不可用是**正常情况**
  ///（老服务器可能没有这个方法），不该让整条链崩掉。
  Future<bool?> initDataIsAdminOrNull() async {
    final data = await initDataSnapshot();
    if (data == null) return null;
    // ★ 真机形状（DSM 7.4.1-90080 实测）：身份位在 **`Session.is_admin`**，
    // 不在顶层。用画像解析器读，顺带把 `Session` / `AppPrivilege` 一起收下。
    final ent = SessionEntitlement.fromInitdata(data);
    if (ent.isAdmin != null) return ent.isAdmin;
    // 兼容历史假设的顶层 `is_admin`（有些服务器 / 老文档是这种形状）；
    // 类型不对**不**做宽松转换（字符串 "true" / 数字 1 都不算真）。
    final raw = data['is_admin'];
    return raw is bool ? raw : null;
  }

  /// ★★★ **一次拿全** Initdata 的整包响应。
  ///
  /// 为什么需要它：DS finder 用**同一个** Initdata 同时得到
  /// `is_admin` 与 `support_wol`/`support_findme` 等能力位
  ///（见 `ApiInitDataVo.smali` 的字段表）。
  /// 如果按位逐个调 [initDataCapability]，同一次登录要打好几次同一个接口 ——
  /// 那是**我们的**实现缺陷，不是官方行为。
  ///
  /// 返回 `null` 表示该通道不可用（方法不存在 / 网络错误）。
  /// 拿到 `{}`（空 map）表示通道可用但服务端没给任何字段。
  Future<Map<String, dynamic>?> initDataSnapshot() async {
    try {
      final data = await api.call(
        kInitDataApi,
        'get',
        preferredVersion: negotiate(kInitDataApi, const [1]),
        params: const {},
      );
      return data;
    } catch (_) {
      return null;
    }
  }

  /// ★★★ **一次拿全的会话级权限画像**（第 254 轮新增，用户 2026-09-25 指令）。
  ///
  /// 与 [initDataSnapshot] 的区别：这里**解析好**再返回（只留小结构，
  /// 不把 3 MB 的整包往上层传），并且**同时**给出：
  /// * 身份（`Session.is_admin`）—— 管理门控；
  /// * 模块权限（`AppPrivilege`）—— 模块可见性（信号 1）；
  /// * 动作权限（`ActionPrivilege`）与设备能力位。
  ///
  /// 拿不到（方法不存在 / 未登录 / 形状不对）⇒
  /// [SessionEntitlement.unavailable]（**不是**"什么权限都没有"）。
  Future<SessionEntitlement> sessionEntitlement() async {
    final data = await initDataSnapshot();
    if (data == null) return SessionEntitlement.unavailable;
    return SessionEntitlement.fromInitdata(data);
  }

  /// 同一个 Initdata 响应里的**设备能力位**（DS finder 用它们门控界面）。
  ///
  /// ⚠️ 只读、可空：拿不到就返回 `null`，**不要**用 `false` 冒充
  /// "不支持" —— 那会让用户在弱网下看到被砍掉的功能。
  Future<bool?> initDataCapability(String key) async {
    final data = await initDataSnapshot();
    if (data == null) return null;
    final raw = data[key];
    return raw is bool ? raw : null;
  }

  Future<bool> activeInsightEnabled() async {
    final data = await api.call(
      kActiveInsightApi,
      'get_status',
      preferredVersion: negotiate(kActiveInsightApi, const [2, 1]),
      params: const {},
    );
    return data['enabled'] == true;
  }

  /// `SYNO.SecureSignIn.AMFA.SuggestConn:get` v1 —— 自适应 MFA 的**游客/连接建议**。
  ///
  /// ★ 为什么做它：官方 `SynologyChat 2.11.1-607` 的
  /// `com/synology/sylibx/login/api/SuggestConnWebApi.smali` 在**登录流程**里
  /// 调它，注解为 `path=SYNO.SecureSignIn.AMFA.SuggestConn, method="get", version=0x1`
  /// —— 与 `SecureSignIn-1.1.5-0362.spk` 的
  /// `webapi/amfa/SYNO.SecureSignIn.AMFA.lib`（`v1: ['get']`）**完全一致**。
  /// ⇒ 两来源互证（`.lib` + smali），这是我做它的依据。
  ///
  /// ★ `.lib` 的 `allowUser` 含 `normal.*` ⇒ **普通用户也能调**，
  /// 所以不做管理员门控，且失败必须**不阻断登录**（见 `login()` 的调用点）。
  Future<AmfaSuggestConn?> suggestConn() async {
    final data = await api.call(
      kAmfaSuggestConnApi,
      'get',
      preferredVersion: kAmfaSuggestConnVersion,
      params: const {},
    );
    return AmfaSuggestConn(data);
  }
}

/// 本族**刻意不实现**的方法，以及理由 —— 写下来是为了让"缺"是**选择**，
/// 而不是遗漏。每条都注明了缺的是什么证据或为什么不需要。
const Map<String, String> kAuthExtraNotImplemented = {
  // ⚠️ 写动词。且我方登录是自己实现的加密直连，不需要它。
  'SYNO.Auth.RescueEmail / set':
      '写动词（改救援邮箱）；且 `docs/api-server-authoritative.md` 记的是 '
      '`SYNO.User.NormalUser / set v2` 那条路。**本仓无消费场景** ⇒ 不做。',
  'SYNO.Auth.RescueEmail / verify':
      '官方 JS 里确实是 `verify` v1 无参（见文件头），但它会**触发服务端发验证邮件** '
      '⇒ 有副作用。本仓没有"重发验证邮件"的界面 ⇒ 不做。',
  'SYNO.ActiveInsight.Package / start_mib | stop_mib | change_mode':
      '官方 JS 里 `start_mib` 的参数是 `{basic_opt, advance_opt}`（有据），'
      '但它们是 **Active Insight 遥测的开启/关闭**，属"同意与否"的一次性设置，'
      '不是移动客户端功能 ⇒ ➖ 不做（**不是**缺证据）。',
  'SYNO.API.Auth.RedirectURI / run | check':
      '`.lib` 里 v1 有 `run, check`，但**在所有官方 Web JS 里零命中** '
      '⇒ **调用形状无证据**。它是 SSO/重定向登录的一环，'
      '本仓走直连登录 ⇒ **按铁律不猜**，登记待判。',
  'SYNO.Core.Desktop.SessionData / getjs | getjs_mobile | getjs_forgotpass':
      '`.lib` 里 v1 有这三个方法，但**返回的是 JS 文本**，服务于 DSM **网页桌面壳**；'
      '原生客户端不需要 ⇒ ➖ 不做。⚠️ 参数形状也**无证据**。',
  'SYNO.SAS.Encryption / exchange | status':
      '`docs/api-server-authoritative.md:991` 记 v1 有 `exchange, status`（普通用户），'
      '但 **官方 Web JS 里零命中** ⇒ 调用形状无证据。'
      '我方聊天的端到端加密走 `SYNO.Chat.User / update_key` 这条**已有且已验证**的路，'
      '与 SAS 不是同一机制 ⇒ **不猜、不重复实现**。',
  'SYNO.SecureSignIn.AMFA.SuggestConn / (整个 API)':
      '真机存在，但**目录里没有方法表**（live 快照只给版本），'
      '且官方 Web JS 零命中 ⇒ **方法名与参数都无证据** ⇒ 不猜。',
  'SYNO.Bee.Available / (整个 API)':
      '**真机上不存在**（不在 `SYNO.API.Info` 快照里）⇒ 这是 Synology Bee/C2 '
      '的能力探针，本 NAS 不提供 ⇒ ➖ 非缺口。',
};
