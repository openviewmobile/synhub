// ★★★ 会话级**权限画像**（SessionEntitlement）—— 一次
// `SYNO.Core.Desktop.Initdata:get` 拿全"这个用户在**这台** NAS 上能用什么"。
//
// ## 为什么有这个文件（用户 2026-09-25 指令）
//
// 用户原话：「用你推荐的方式改掉之前用 `105` 探测的办法吧」。
// 所谓"`105` 探测"= **故意去调一个 adminOnly / 受限接口，再把
// `105`(noPermission) 读成"我没有权限"**。它有四个毛病：
//   ① 它是**猜测**：把"服务端拒绝"当成"这个用户的静态权限"，
//      权限之外的失败（代理、限流、`160`、`471`…）都会污染结论；
//   ② 它**多打一次服务端**，还是打最敏感的那类接口；
//   ③ 它**答不出"为什么"**：只能得到"不行"，拿不到"哪个模块不行"；
//   ④ 每次登录后都要跑，等于把"猜权限"常态化。
// 而服务端**本来就下发** per-user 权限：官方桌面前端在启动时把
// Initdata 的整包拆成全局表 —— 见
// `/tmp/dsmroot/usr/syno/synoman/webman/sds/dist/dsm.sds.bundle.js`：
//
// ```js
// SYNO.SDS.Session = o[0].Session,
// SYNO.SDS.AppPrivilege = o[0].AppPrivilege,
// SYNO.SDS.ActionPrivilege.AllowList = o[0].ActionPrivilege,
// SYNO.SDS.ServiceStatus = o[0].ServiceStatus
// ```
//
// ⇒ **官方前端判"这个用户能不能开这个 app"读的就是 `AppPrivilege`**，
//    不是"调一下看会不会 105"。本文件把同一份数据解析成我们自己的模型，
//    让身份（`Session.is_admin`）与模块可见性（`AppPrivilege`）**共用一次调用**。
//
// ## 真实载荷形状（DSM 7.4.1-90080，普通用户 demo_user，实测）
//
// 顶层 9 键：`ActionPrivilege / AppPrivilege / CSSFiles / GroupSettings /
// JSConfig / ServiceStatus / Session / Strings / UserSettings`
// （整包 3.1 MB ⇒ **只留解析后的小结构，不缓存原始 map**）。
//
// | 键 | 实测 | 我们用它做什么 |
// |---|---|---|
// | `AppPrivilege` | 22 条 `SYNO.SDS.<App>...` → `true` | 模块可见性（信号 1） |
// | `Session.is_admin` | `false`（该账号是普通用户） | 管理员门控 |
// | `Session.user` | `"demo_user"` | 诊断显示 |
// | `ActionPrivilege` | `[]` >= 空 | 动作级权限（空 = **不知道**，见下） |
// | `ServiceStatus` | `{}` | 服务启用位（空 = 没信息） |
//
// ## 语义（照抄官方，不发明）
//
// * 键**存在且为 `true`** ⇒ 放行；
// * 键**存在且为 `false`** ⇒ 明确拒绝（有 `SYNO.ALLOW.ALL.APPLICATIONS`
//   通配键时被抵消 —— 这三元判断在 `AppPrivilegeSignal` 里，复用不重写）；
// * 键**不存在** ⇒ 官方前端判**不放行**（`void 0 !== P[e]` 为假）。
//
// ⚠️ **空 `ActionPrivilege` 不许当"全部拒绝"**：真机普通用户就是 `[]`，
// 若按"空列表 ⇒ 无权限"处理，会把所有动作级功能对普通用户关掉。
// 所以 [allowsAction] 在列表为空时返回 **`null`（不知道）**，由调用方
// 决定 fail-open/fail-closed，而不是替他判死。
//
// ## 纯 Dart 纪律
//
// 本文件**不得** import `package:flutter/**` / `package:l10n/**` / dio ——
// `tool/*.dart` 的探针要在纯 Dart VM 里直接加载它（同
// `core/services/service_registry.dart` 的纪律）。
library;

import '../services/service_registry.dart'
    show AppPrivilegeSignal, kAppPrivilegeAllowAllKey;

/// 权限画像是从哪来的。
enum SessionEntitlementSource {
  /// `SYNO.Core.Desktop.Initdata:get` 的真实响应（正常路径）。
  initData,

  /// 没拿到（未登录 / 老 DSM 没这个方法 / 形状不对）。
  /// **不是**"这个用户没有任何权限"——调用方不许把它读成拒绝。
  unavailable,
}

/// 一次 `Initdata:get` 解析出的**会话级**权限画像（不可变、可离线构造）。
class SessionEntitlement {
  const SessionEntitlement({
    required this.appPrivilege,
    this.isAdmin,
    this.user,
    this.actionAllowList = const [],
    this.serviceStatus = const {},
    this.supportWol,
    this.supportFindme,
    this.hostname,
    this.serialNumber,
    this.source = SessionEntitlementSource.initData,
  });

  /// 拿不到画像时的值：**一切"不知道"**，任何"拒绝"都不许由此得出。
  static const SessionEntitlement unavailable = SessionEntitlement(
    appPrivilege: AppPrivilegeSignal.unavailable,
    source: SessionEntitlementSource.unavailable,
  );

  /// `AppPrivilege`（per-user、per-app；[AppPrivilegeSignal] 已实现官方三元语义）。
  final AppPrivilegeSignal appPrivilege;

  /// `Session.is_admin`。`null` = 载荷里没有 / 类型不对（**别当 `false`**，
  /// 兜底方向由调用方决定；身份门控是 fail-closed）。
  final bool? isAdmin;

  /// `Session.user`（诊断/展示用）。
  final String? user;

  /// `ActionPrivilege` 的字符串项（官方 JS 里叫 `AllowList`）。
  /// 空列表 = **不知道**（真机普通用户就是这样），见 [allowsAction]。
  final List<String> actionAllowList;

  /// `ServiceStatus`（服务启用位）。空 map = 没有信息。
  final Map<String, bool> serviceStatus;

  /// DS finder 用的设备能力位（与身份**同一次**响应；拿不到 = `null`）。
  final bool? supportWol;
  final bool? supportFindme;
  final String? hostname;
  final String? serialNumber;

  final SessionEntitlementSource source;

  /// 真的读到过 Initdata（而不是 [unavailable]）。
  bool get known => source == SessionEntitlementSource.initData;

  /// 这个用户是否能开某模块（[keys] = 该模块在 `AppPrivilege` 里的键，
  /// 见 `ServiceSpec.appPrivilegeKeys`；**任一命中**即算命中，与官方一致）。
  bool allowsApp(List<String> keys) => appPrivilege.isPresent(keys);

  /// 该模块是否被**明确拒绝**（键存在且为 `false`，且没有键放行）。
  /// 与"键不存在"（官方判不允许，但**没明说拒绝**）区分开。
  bool deniedApp(List<String> keys) => appPrivilege.isDenied(keys);

  /// 通配键是否打开（`SYNO.ALLOW.ALL.APPLICATIONS`）。
  bool get allowAllApps => appPrivilege.allowAll;

  /// 动作级权限的三态查询：`true` 允许 / `false` 拒绝 / `null` **不知道**。
  ///
  /// `AllowList` 为空 ⇒ `null`（真机普通用户就是空列表，
  /// 把它读成"全拒"会误伤；这一点**故意**与 [allowsApp] 不同）。
  bool? allowsAction(String action) {
    if (actionAllowList.isEmpty) return null;
    return actionAllowList.contains(action);
  }

  /// 从 `Initdata:get` 的 `data` 解析。
  ///
  /// 只有"既没有 `AppPrivilege` 也没有 `Session`"才算 [unavailable]：
  /// 两者只要有一个可用，就有可用的结论（有的老服务器只给其中一个）。
  static SessionEntitlement fromInitdata(Map<String, dynamic> data) {
    final privilege = AppPrivilegeSignal.fromInitdata(data);
    final session = data['Session'];
    final sessionMap = session is Map ? session : const {};

    // 身份位：**真机形状是 `Session.is_admin`**（DSM 7.4.1-90080 实测）；
    // 顶层 `is_admin` 是历史假设的形状（部分服务器 / 早期文档），
    // 作为兼容读一次 —— 两者都按"必须是真 bool"处理，不做宽松转换。
    final rawAdmin = sessionMap['is_admin'] ?? data['is_admin'];
    final isAdmin = rawAdmin is bool ? rawAdmin : null;

    final rawUser = sessionMap['user'];
    final user = rawUser is String && rawUser.isNotEmpty ? rawUser : null;

    if (!privilege.known && isAdmin == null) {
      return SessionEntitlement.unavailable;
    }

    return SessionEntitlement(
      appPrivilege: privilege,
      isAdmin: isAdmin,
      user: user,
      actionAllowList: _stringList(data['ActionPrivilege']),
      serviceStatus: _boolMap(data['ServiceStatus']),
      supportWol: _bool(data['support_wol']),
      supportFindme: _bool(data['support_findme']),
      hostname: _string(data['hostname']),
      serialNumber: _string(data['serial_number']),
      source: SessionEntitlementSource.initData,
    );
  }

  /// 诊断用的一行摘要（**不含**任何大字段；设置页/日志可打印）。
  String describe() {
    if (!known) return 'entitlement: unavailable';
    final apps = appPrivilege.entries.length;
    final deny = appPrivilege.entries.entries
        .where((e) => !e.value)
        .map((e) => e.key)
        .toList();
    return 'entitlement: user=$user admin=$isAdmin apps=$apps'
        '${allowAllApps ? ' allowAll' : ''}'
        '${deny.isEmpty ? '' : ' denied=${deny.join(',')}'}'
        ' actions=${actionAllowList.length}';
  }

  @override
  String toString() => describe();

  static bool? _bool(Object? v) => v is bool ? v : null;

  static String? _string(Object? v) =>
      v is String && v.isNotEmpty ? v : null;

  static List<String> _stringList(Object? v) {
    if (v is! List) return const [];
    return [for (final e in v) if (e is String && e.isNotEmpty) e];
  }

  static Map<String, bool> _boolMap(Object? v) {
    if (v is! Map) return const {};
    return {
      for (final e in v.entries)
        if (e.value is bool) '${e.key}': e.value as bool,
    };
  }
}

/// 官方"全应用放行"通配键（**只**用来抵消 `false`；语义见
/// `service_registry.dart` 的同名常量，这里刻意不复制逻辑）。
const String kEntitlementAllowAllKey = kAppPrivilegeAllowAllKey;
