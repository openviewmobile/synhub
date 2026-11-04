// ★★★ **会话级管理员身份缓存**（用户 2026-09-23 新规 · 第 76 轮）
//
// ## 用户的要求（本轮直接照做）
// 「`Desktop.Initdata` 可以作为整个 App 的全局用来判断是否管理员的接口吧，
//   在用户登陆成功之后调用」
//
// ⇒ 本文件实现：
// * **登录成功后调用一次**（`SessionController.login/restore` 末尾触发）；
// * 结果**缓存在会话里**，全局门控都读这一份，不重复打接口；
// * **登出/切换账号时清空**（否则 A 的管理员身份会留给 B —— 这是权限泄漏）；
// * 顺带缓存 DS finder 用来门控界面的能力位（`support_wol` / `support_findme`…），
//   因为它们和 `is_admin` **来自同一个响应**（`ApiInitDataVo.smali` 字段表）。
//
// ## 为什么不是"只用 Initdata"
// 用户提议用 Initdata 作**全局主通道** —— 采纳。但**不能只留它一条**：
// `SYNO.Core.Desktop.Initdata` 在其余 5 个官方 APK 里 0 命中
// ⇒ 它是 DS finder 专属，不保证每台 NAS 都有。
// 所以保留**两棒**接力（Initdata → NormalUser），Initdata 是**第一棒**。
//
// ## ★ 第 254 轮：第三棒"`105` 探测"已按用户指令**删除**
// 用户 2026-09-25：「用你推荐的方式改掉之前用 `105` 探测的办法吧」。
// 旧第三棒是"故意调 `SYNO.Core.System` v3 `info`，把 `105` 读成'不是管理员'"。
// 现在身份与模块权限都从**服务端下发的**权限画像里读
// （`Session.is_admin` / `AppPrivilege`，真机载荷实测存在）：
// * 一次 Initdata 同时喂饱身份门控与模块可见性（少打一次最敏感的接口）；
// * 不会把"网络/限流/`160`"误读成"你不是管理员"；
// * 证据与边界见 `docs/session-entitlement.md`。
// 两棒都无结论 ⇒ `false`（fail-closed，**不猜**）。
//
// ## fail-closed 不变
// 正在加载 / 加载失败 / 未连接 ⇒ `isAdmin == false`（一律隐藏管理入口）。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/provider_retry.dart';
import '../../core/entitlement/session_entitlement.dart';
import '../../data/auth_extra_api.dart';
import '../../data/system_admin_api.dart';
import '../servers/session_controller.dart';

/// 一次 Initdata 快照的**会话级**视图。
class AdminIdentity {
  const AdminIdentity({
    required this.isAdmin,
    this.supportWol,
    this.supportFindme,
    this.hostname,
    this.serialNumber,
    this.source = AdminIdentitySource.unresolved,
    this.entitlement = SessionEntitlement.unavailable,
  });

  /// 由**会话权限画像**构造（第 254 轮起的唯一入口）。
  ///
  /// [isAdmin] 传空 = 用画像里的 `Session.is_admin`；仍为空则 `false`
  /// （fail-closed：宁可少显示管理入口）。
  factory AdminIdentity.fromEntitlement(
    SessionEntitlement e,
    AdminIdentitySource source, {
    bool? isAdmin,
  }) => AdminIdentity(
    isAdmin: isAdmin ?? e.isAdmin ?? false,
    supportWol: e.supportWol,
    supportFindme: e.supportFindme,
    hostname: e.hostname,
    serialNumber: e.serialNumber,
    source: source,
    entitlement: e,
  );

  /// 未连接 / 还没加载完时的初始值：**不是管理员**（fail-closed）。
  static const AdminIdentity unknown = AdminIdentity(
    isAdmin: false,
    source: AdminIdentitySource.unresolved,
  );

  /// ★ D7（§2.0.7③ 三态语义）：解析**失败**时的值。
  ///
  /// 和 [unknown] 一样是 fail-closed（`isAdmin == false`，门控不放松），
  /// 但 [source] 是 [AdminIdentitySource.failed] —— 外部能区分
  /// 「还在探测」与「探测失败」。失败**不是**结论，所以调用方可以（也应该）
  /// 在下次需要时重试。
  static const AdminIdentity failed = AdminIdentity(
    isAdmin: false,
    source: AdminIdentitySource.failed,
  );

  final bool isAdmin;

  /// 设备能力位（与 `is_admin` 同一次响应）。
  /// `null` = **不知道**，不要当 `false` 用（会让弱网下功能凭空消失）。
  final bool? supportWol;
  final bool? supportFindme;

  final String? hostname;
  final String? serialNumber;

  /// 身份是从哪一棒得到的 —— 排查"为什么管理员看不到入口"时靠它。
  final AdminIdentitySource source;

  /// 这一次身份解析**顺带**拿到的会话权限画像（`AppPrivilege` /
  /// `ActionPrivilege` / 设备能力位）。模块可见性（信号 1）读的就是它，
  /// **不再重复打 Initdata**。
  final SessionEntitlement entitlement;
}

/// 身份来源。刻意做成枚举而不是字符串：日志/用例里要能断言。
enum AdminIdentitySource {
  /// 还没解析（还没轮到 / 通道还没接上）—— **不含"解析失败"**
  unresolved,

  /// ★ D7：解析**失败**（异常 / 通道不可用）。
  ///
  /// 与 [unresolved] 的差别是语义上的：`unresolved` = "还在探测"，
  /// `failed` = "这一轮探测没成，可以重试"。两者都 fail-closed
  /// （`is_admin` 一律 `false`），但只有 [failed] 会被当成"需要重试"的信号。
  failed,

  /// `SYNO.Core.Desktop.Initdata`（**官方 DS finder 通道**）
  initData,

  /// `SYNO.Core.NormalUser`
  normalUser,

  /// 两棒都没结论 ⇒ 按普通用户处理（**不再有 `105` 探测那一棒**）
  fallback,
}

/// 会话级身份控制器。
class AdminIdentityController extends AsyncNotifier<AdminIdentity> {
  /// 已加载的会话标识，用于判断"是否需要重新加载"。
  /// 用 connection 的对象身份 + 会话 sid 一起判定：
  /// 换 NAS（connection 变）或换账号（sid 变）都要重新解析。
  Object? _loadedFor;

  /// ★ D7 残留修复（P1）：**本会话是否已经自动重试过**。
  ///
  /// `admin_identity.dart` 上一轮已让"解析失败"可重试（[failed] + `_loadedFor`
  /// 不被写死），但**没有人触发**：登录那次 `refresh()` 失败后若无人再调，
  /// 管理入口会一直隐藏（缺陷只解除一半）。
  ///
  /// 触发点（两个，共用这一份预算）：
  /// * ①首个管理员门控界面被查询时（`isAdminProvider` 结算见 [failed]）；
  /// * ②应用回到前台时（`app.dart` 的 lifecycle `resumed`）。
  ///
  /// 每会话**至多自动重试一次**：防请求风暴 / 防"失败 → 触发 → 失败"的循环；
  /// 重试**再失败就保持 [failed]**、不再自动重试（手动 `refresh(force:true)`
  /// 不受此限）。会话切换（`build()`/`clear()`）时预算重置。
  bool _autoRetried = false;

  @override
  Future<AdminIdentity> build() async {
    // 跟随会话：连接变了就自动重置（切 NAS / 登出）
    final conn = ref.watch(sessionControllerProvider).connection;
    _loadedFor = null;
    _autoRetried = false;
    if (conn == null) return AdminIdentity.unknown;
    return AdminIdentity.unknown;
  }

  /// ★ D7 残留修复：自动重试的**唯一入口**（两个触发点都调它）。
  ///
  /// 返回 `true` = 本次**真的**发起了重试（机制量，用例据此断言"尝试数 +1"）。
  /// 只有"当前是 [AdminIdentitySource.failed] 且本会话还没自动重试过"才触发。
  ///
  /// 刻意做成同步返回 bool：调用方（provider / lifecycle）不必 await，
  /// 也不会因为重复调用产生第二次请求（`_autoRetried` 一置即生效）。
  bool triggerAutoRetry() {
    if (_autoRetried) return false;
    final cur = state.value;
    if (cur == null || cur.source != AdminIdentitySource.failed) return false;
    _autoRetried = true;
    // ★ 必须 `force: true`：非 force 的 `refresh()` 会复用
    // `sessionEntitlementProvider` 那份**已缓存的失败 future**（首棒直接回放
    // 同一个错误）⇒ 自动重试永远不可能成功。`force` 顺带重取权限画像，
    // 与"重试 = 重新解析一次"的语义一致。
    unawaited(refresh(force: true));
    return true;
  }

  /// ★ 登录成功后由 `SessionController` 调用。
  ///
  /// 幂等：同一会话重复调用不会重复打接口（除非 [force]）。
  Future<void> refresh({bool force = false}) async {
    final s = ref.read(sessionControllerProvider);
    // ★ 身份通道由 `authExtraApiProvider` 提供 —— 控制器**不自己 new**
    // `AuthExtraApi`。好处：接线只有一处（换传输/加代理都只改那里），
    // 而且测试可以直接覆盖这一条，不必伪造整个会话连接。
    final api = ref.read(authExtraApiProvider);
    if (api == null) {
      state = const AsyncData(AdminIdentity.unknown);
      return;
    }
    // 会话指纹：换 NAS(connection) 或换账号(sid) 都要重算；
    // 没有 connection 时退化为按 `api` 实例判定（覆盖的是同一批对象）。
    final key = Object.hash(s.connection ?? api, s.session?.sid);
    // ★ D7：`_loadedFor` 只在**成功**解析后写（见下面 `_resolve` 之后那句）。
    // 失败时它被清成 `null`（不是写成本会话的 key）⇒ 下一次 `refresh()`
    // 仍会重新解析。这里的 `source != unresolved` 是防"未解析却判已加载"的
    // 兜底；**不要**再往这里加"排除 failed"，否则一旦 `_loadedFor` 被写死，
    // 失败态就会被当成"本会话已解析"而永不重试（那正是 D7 的机制量）。
    if (!force &&
        _loadedFor == key &&
        state.value != null &&
        state.value!.source != AdminIdentitySource.unresolved) {
      return; // 本会话已解析过
    }

    // ★ `force` = 切账号 / 手动重试：权限画像也必须重取（否则拿的是上一个
    // 会话的 `AppPrivilege` ⇒ 模块可见性串台）。
    if (force) ref.invalidate(sessionEntitlementProvider);

    // 保留上一份值（加载中门控按 fail-closed 处理，这里只是别把已知值抹掉）
    state = const AsyncLoading<AdminIdentity>();
    try {
      final id = await _resolve(api);
      // ★ D7 残留修复：自动重试是**fire-and-forget**（见 [triggerAutoRetry]），
      // 解析途中容器/会话可能已经被释放（登出、ProviderContainer.dispose）。
      // Riverpod 会拒绝在已释放的 Ref 上写 `state`（实测抛
      // `Cannot use the Ref … after it has been disposed`）⇒ 每次异步间隙后
      // 先查 `ref.mounted`。只影响"没人再等这份结果"的场合，awaited 调用方
      // 的行为不变。
      if (!ref.mounted) return;
      _loadedFor = key;
      state = AsyncData(id);
    } catch (_) {
      // ★ D7：解析不出来 ⇒ fail-closed（当普通用户），但**不建立"已加载"标记**。
      //   * 写 `_loadedFor = key` 会让下一次 `refresh()` 走上面的 early-return
      //     ⇒ 首次一失败就永久停在"未解析"，管理员也永远看不到管理入口；
      //   * 因此这里**清空** `_loadedFor`（而不是写成本会话 key），
      //     状态给 [AdminIdentitySource.failed]（与"还没解析"区分开）⇒ 可重试。
      if (!ref.mounted) return;
      _loadedFor = null;
      state = const AsyncData(AdminIdentity.failed);
    }
  }

  /// **两棒接力**（第 254 轮起没有第三棒）+ 设备能力位。
  ///
  /// * 第①棒 = **会话权限画像**（`SYNO.Core.Desktop.Initdata:get`，
  ///   官方 DS finder 通道）。这一次调用**同时**给出 `Session.is_admin`
  ///   与 `AppPrivilege`，所以身份门控与模块可见性**共用一次请求**；
  /// * 第②棒 = `SYNO.Core.NormalUser:get`（Initdata 不存在的服务器）；
  /// * 都没有结论 ⇒ 普通用户（fail-closed）。
  ///
  /// ⚠️ **不再**用"调 adminOnly 接口看回不回 `105`"来猜身份：那是拿一次
  /// 被拒绝的调用反推静态权限，既多打最敏感的接口，又会把网络/限流/`160`
  /// 混进结论里（见文件头注释与 `docs/session-entitlement.md`）。
  Future<AdminIdentity> _resolve(AuthExtraApi api) async {
    // ── 第①棒：会话权限画像（内里只打一次 Initdata）───────────────
    final ent = await ref.read(sessionEntitlementProvider.future);
    if (ent.isAdmin != null) {
      return AdminIdentity.fromEntitlement(ent, AdminIdentitySource.initData);
    }

    // ── 第②棒：通用身份接口 ─────────────────────────────────────
    bool? viaNormal;
    try {
      viaNormal = await api.normalUserIsAdminOrNull();
    } catch (_) {
      viaNormal = null;
    }
    if (viaNormal != null) {
      return AdminIdentity.fromEntitlement(
        ent,
        AdminIdentitySource.normalUser,
        isAdmin: viaNormal,
      );
    }

    // ── 都没结论 ⇒ 普通用户（安全方向）──────────────────────────
    return AdminIdentity.fromEntitlement(
      ent,
      AdminIdentitySource.fallback,
      isAdmin: false,
    );
  }

  /// 登出时清空（`SessionController.logout` 调用）。
  ///
  /// ★ 权限画像**必须一起清**：否则 A 的 `AppPrivilege` 会留给 B
  /// ⇒ 模块可见性跟着串台（同"管理员身份不能留给下一个账号"一个道理）。
  void clear() {
    _loadedFor = null;
    _autoRetried = false;
    try {
      ref.invalidate(sessionEntitlementProvider);
    } catch (_) {
      // provider 未挂载（测试/极端时序）不该阻塞登出
    }
    state = const AsyncData(AdminIdentity.unknown);
  }
}

/// ★★★ **会话权限画像控制器**（第 254 轮新增）。
///
/// 一次 `Initdata:get` 只在这里发生（登录后触发；换 NAS / 换账号自动重算）：
/// * 身份门控读 `Session.is_admin`（[adminIdentityProvider] 的第①棒）；
/// * 模块可见性读 `AppPrivilege`（`service_availability` 的信号 1 直接复用，
///   **不再自己打第二次 Initdata**）。
///
/// 拿不到就 [SessionEntitlement.unavailable] —— 那是"不知道"，
/// **不是**"这个用户没有权限"，调用方各自按 fail-open / fail-closed 处理。
class SessionEntitlementController extends AsyncNotifier<SessionEntitlement> {
  @override
  Future<SessionEntitlement> build() async {
    // 跟随会话：连接变了（切 NAS / 登出）自动重算。
    final api = ref.watch(authExtraApiProvider);
    if (api == null) return SessionEntitlement.unavailable;
    try {
      return await api.sessionEntitlement();
    } catch (_) {
      // 通道不可用（老 DSM / 网络）⇒ "不知道"，绝不编结论
      return SessionEntitlement.unavailable;
    }
  }

  /// 强制重取（登录后 / 会话续期 / 设置页手动重测）。
  void refresh() => ref.invalidateSelf();
}

/// 会话级权限画像。**界面别直接 watch**（诊断/门控内部用）。
final sessionEntitlementProvider =
    AsyncNotifierProvider<SessionEntitlementController, SessionEntitlement>(
      SessionEntitlementController.new,
      retry: noRetry,
    );

/// `AuthExtraApi`（身份通道）—— 与 `driveApiProvider` 同一条接线形状。
final authExtraApiProvider = Provider<AuthExtraApi?>((ref) {
  final conn = ref.watch(sessionControllerProvider).connection;
  return conn == null ? null : AuthExtraApi(conn.api);
});

/// `SystemAdminApi`（DS finder 管理接口）—— 同样只在这里接线。
final systemAdminApiProvider = Provider<SystemAdminApi?>((ref) {
  final conn = ref.watch(sessionControllerProvider).connection;
  if (conn == null) return null;
  return SystemAdminApi(
    conn.api,
    discover: (name, cands) => AuthExtraApi(conn.api).negotiate(name, cands),
  );
});

/// 会话级身份。**界面不要直接 watch 它** —— 用 `AdminOnly`。
final adminIdentityProvider =
    AsyncNotifierProvider<AdminIdentityController, AdminIdentity>(
      AdminIdentityController.new,
      retry: noRetry,
    );

/// 派生出的"是不是管理员"（`AdminOnly` / `adminOnlyVisible` 用这一条）。
///
/// 保留它作为**独立 provider** 是刻意的：门控用例可以只覆盖这一条，
/// 不必构造整个身份控制器。
final isAdminProvider = FutureProvider<bool>((ref) async {
  final id = await ref.watch(adminIdentityProvider.future);
  // ★ D7 残留修复（触发点①）：**首个管理员门控界面被查询时**，如果身份是
  // `failed`，就自动补一次解析（每会话至多一次，见 [AdminIdentityController.
  // triggerAutoRetry]）。这是全仓唯一门控读点（`AdminOnly` / `adminOnlyVisible`
  // / `AdminPageGate` 都经它）⇒ 放这里等于"任何一个门控界面被问到"。
  //
  // 用 microtask 延后：此刻仍在 `isAdminProvider` 的 build 里，不能同步改
  // 依赖它的 `adminIdentityProvider`（Riverpod 会在构建期拒绝）。
  if (id.source == AdminIdentitySource.failed) {
    final notifier = ref.read(adminIdentityProvider.notifier);
    scheduleMicrotask(notifier.triggerAutoRetry);
  }
  return id.isAdmin;
}, retry: noRetry);

/// 设备能力位（`support_wol` 等）—— 与 `is_admin` 同一次响应。
/// `null` 表示**不知道**。
final adminCapabilitiesProvider = FutureProvider<AdminIdentity>((ref) async {
  return ref.watch(adminIdentityProvider.future);
}, retry: noRetry);
