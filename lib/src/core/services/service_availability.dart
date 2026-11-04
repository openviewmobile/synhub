// 统一服务可用性状态层（见 `docs/service-availability-design.md` §2.2）。
//
// **多信号检测（2026-09-21 用户要求）**：
//   * 信号 1（权威）= `SYNO.Core.Desktop.Initdata:get` 的 `AppPrivilege`
//     （普通用户可读；"这个用户能不能用"）；
//   * 信号 2 = `SYNO.API.Info` 能力表（`DsmWebApi.discover()`；"这套件注册了
//     哪些 WebAPI"）；
//   * 信号 3 = 首次调用的错误码回填（[ServiceAvailabilityNotifier.reportError]）。
//   合并规则在 `service_registry.dart` 的纯函数 [classifyMultiSignal]（含
//   "信号 2 缺席 + 信号 1 命中 → uncertain，绝不 absent"这条 MailPlus 规则）。
// 结果缓存进 Drift KV（`ChatStore.setting`，带时间戳），支持手动
// [ServiceAvailabilityNotifier.refresh] 与登录 / 会话续期后的自动重测。
//
// **不变量（最容易做错的地方）**：
//   * `absent` 只能来自"能力表明确缺失 **且** 信号 1 明确缺席"或明确 `102`
//     （apiNotFound）；
//   * `uncertain`（两信号矛盾）→ 可见（fail-open），**绝不**当 absent；
//   * `119`（sidNotFound）/ `105`（noPermission）/ `106`（sessionTimeout）
//     → `unauthorized`，**绝不**当 absent；
//   * 网络 / 握手失败 → `unreachable`，**绝不**隐藏 tab。
// 判定逻辑在 `service_registry.dart` 的纯函数里（[classifyApiTable] /
// [classifyMultiSignal] / [classifyErrorCode]），本文件只负责取数、缓存与状态承载。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../dsm/webapi.dart';
import '../../features/chat/chat_session_controller.dart'
    show chatStoreProvider;
import '../../features/admin/admin_identity.dart'
    show sessionEntitlementProvider;
import '../../features/servers/session_controller.dart';
import 'service_registry.dart';
import 'service_reporting_api.dart';

/// Drift KV 里的缓存键（带版本，将来改结构可无痛失效）。
const String kServiceAvailabilityKey = 'service_availability.v1';

/// 检测用的 API 客户端来源。生产取当前会话；测试可直接覆盖成假传输背后的 api。
final availabilityApiProvider = Provider<DsmWebApi?>((ref) {
  return ref.watch(sessionControllerProvider).connection?.api;
});

/// 一次检测的完整结果快照。
class ServiceAvailabilitySnapshot {
  const ServiceAvailabilitySnapshot({
    this.states = const {},
    this.apis = const {},
    this.privilege,
    this.checkedAt,
    this.probing = false,
  });

  /// 服务 → 状态。缺省 = `unknown`（不判死）。
  final Map<StationService, AvailabilityState> states;

  /// 能力表里存在的 API 名集合（工作台按可选能力位精确降级用）。
  final Set<String> apis;

  /// **信号 1** 快照：`Core.Desktop.Initdata:get` 的 `AppPrivilege`。
  ///
  /// * `null` = 本次没探测到 / 该服务器不提供这个信号（→ 判定退回信号 2）；
  /// * `known == false` 的情况不会出现在这里（解析失败一律折成 null）。
  final AppPrivilegeSignal? privilege;

  /// 上次检测完成时间（来自缓存或本次）。
  final DateTime? checkedAt;

  /// 是否正在检测（UI 可显示转圈）。
  final bool probing;

  AvailabilityState stateOf(StationService service) =>
      states[service] ?? AvailabilityState.unknown;

  /// 供纯函数 [visibleTabs] 用的映射（保证 13 个服务都有确定值）。
  Map<StationService, AvailabilityState> get resolvedStates => {
    for (final s in StationService.values) s: stateOf(s),
  };

  /// 某个可选 API 是否在能力表里。
  ///
  /// 只有"确定检测过且服务可用"时才敢据此降级；`unknown` /
  /// `unreachable` / `unauthorized` / `absent` / `uncertain` 一律返回 true
  /// （**不因不确定而隐藏功能**）。
  bool hasApi(StationService service, String api) {
    final st = stateOf(service);
    switch (st) {
      case AvailabilityState.available:
      case AvailabilityState.partial:
        return apis.contains(api);
      case AvailabilityState.unknown:
      case AvailabilityState.absent:
      case AvailabilityState.uncertain:
      case AvailabilityState.unauthorized:
      case AvailabilityState.sessionExpired:
      case AvailabilityState.unreachable:
        return true;
    }
  }

  /// 某个 API 是否在能力表里 —— 给**不属于任何 [StationService]** 的横切能力
  /// 用（目前只有 `SYNO.Finder.*`；见 `service_registry.dart` 的 Finder 常量）。
  ///
  /// 语义与 [hasApi] 的 fail-open 纪律一致：**还没检测过**（`apis` 为空）或
  /// 检测失败时返回 true（**不因不确定而隐藏功能**）；只有拿到过能力表、
  /// 且表里明确没有这个 API 才返回 false。
  bool apiPresent(String api) {
    if (apis.isEmpty) return true;
    return apis.contains(api);
  }

  ServiceAvailabilitySnapshot copyWith({
    Map<StationService, AvailabilityState>? states,
    Set<String>? apis,
    AppPrivilegeSignal? privilege,
    DateTime? checkedAt,
    bool? probing,
  }) => ServiceAvailabilitySnapshot(
    states: states ?? this.states,
    apis: apis ?? this.apis,
    privilege: privilege ?? this.privilege,
    checkedAt: checkedAt ?? this.checkedAt,
    probing: probing ?? this.probing,
  );
}

/// 服务可用性的唯一入口。UI 只 watch [serviceAvailabilityProvider]。
final serviceAvailabilityProvider =
    NotifierProvider<ServiceAvailabilityNotifier, ServiceAvailabilitySnapshot>(
      ServiceAvailabilityNotifier.new,
    );

class ServiceAvailabilityNotifier
    extends Notifier<ServiceAvailabilitySnapshot> {
  bool _disposed = false;
  Future<void>? _inFlight;

  @override
  ServiceAvailabilitySnapshot build() {
    ref.onDispose(() => _disposed = true);
    // 登录 / 会话续期 / 登出 → 自动重测（用户无感）。
    ref.listen<SessionState>(sessionControllerProvider, (prev, next) {
      final connChanged =
          (prev?.connection == null) != (next.connection == null);
      final sidChanged = prev?.session?.sid != next.session?.sid;
      if (connChanged || sidChanged) unawaited(refresh());
    });
    // 冷启动：先把上次的缓存放出来（tab 不会因为"还没检测"闪空白），
    // 有会话时再用能力表刷新一次。
    unawaited(_restoreThenProbe());
    return const ServiceAvailabilitySnapshot();
  }

  /// 手动"重新检测"（设置页 / 受限模式首页 / 工作台用）。
  ///
  /// 会**强制重新拉** `SYNO.API.Info`（`discover()` 每次都重查），所以服务端
  /// 刚装上 / 刚卸掉的套件能被重新识别，不会把 tab 永久藏死。
  Future<void> refresh() {
    final running = _inFlight;
    if (running != null) return running;
    final f = _runProbe();
    _inFlight = f;
    return f.whenComplete(() => _inFlight = null);
  }

  /// 模块首次调用失败时回填状态（S2 各模块接入点）。
  ///
  /// 这就是"119 不被当成 absent"的守卫：错误码一律过 [classifyErrorCode]，
  /// 只有 102 才会变 [AvailabilityState.absent]。网络异常（非 DsmApiException）
  /// 归 `unreachable`，同样不隐藏。
  void reportError(StationService service, Object error) {
    final AvailabilityState next;
    if (error is DsmApiException) {
      next = classifyErrorCode(error.code);
    } else {
      next = AvailabilityState.unreachable;
    }
    if (next == AvailabilityState.unknown) return; // 认不出来就别动状态
    _apply({...state.states, service: next});
  }

  /// 显式回填某个错误码（测试 / 需要细判的调用方）。
  void reportErrorCode(StationService service, int code) {
    final next = classifyErrorCode(code);
    if (next == AvailabilityState.unknown) return;
    _apply({...state.states, service: next});
  }

  /// **统一错误出口的回填入口**（S2 接线点）：`ServiceReportingApi.call`
  /// 失败时回调到这里。
  ///
  /// 比 [reportError] 多知道"是哪个 API 出的错"，用来避免一个经典误伤：
  /// 可选能力位（如 `SYNO.FileStation.Thumb`）在部分 NAS 上会单独回 102，
  /// 若直接按 [classifyErrorCode] 判成 `absent`，会把整个模块藏掉。
  /// 设计 §2.2 明确 `absent` 只能来自"**必需** API 缺失"，所以：
  /// `102` 且该 API 不是这个服务的必需项 → `partial`（功能降级，不隐藏）。
  void reportApiError(StationService service, String apiName, Object error) {
    if (error is DsmApiException &&
        error.code == kApiNotFoundCode &&
        !isRequiredApiOf(service, apiName)) {
      if (_disposed) return;
      _apply({...state.states, service: AvailabilityState.partial});
      return;
    }
    reportError(service, error);
  }

  /// 把统一错误出口挂到当前 API 上（[ServiceReportingApi] 才需要）。
  void _attachReporter(DsmWebApi api) {
    if (api is ServiceReportingApi) {
      api.onApiFailure = reportApiError;
    }
  }

  void _apply(Map<StationService, AvailabilityState> states) {
    if (_disposed) return;
    state = state.copyWith(states: states, checkedAt: DateTime.now());
    unawaited(_persist());
  }

  // ------------------------------------------------------------ 内部

  Future<void> _restoreThenProbe() async {
    final cached = await _readCache();
    if (_disposed) return;
    if (cached != null) {
      state = cached.copyWith(probing: state.probing);
    }
    if (ref.read(availabilityApiProvider) != null) {
      await refresh();
    }
  }

  Future<void> _runProbe() async {
    final api = ref.read(availabilityApiProvider);
    if (api == null) {
      // 未连接：不是"服务端没提供"，保持缓存 / unknown，**不隐藏**。
      return;
    }
    // 模块调用的统一错误出口：挂上回填回调（幂等，重测时再挂一次无妨）。
    _attachReporter(api);
    if (!_disposed) state = state.copyWith(probing: true);
    Map<StationService, AvailabilityState> states;
    var apis = state.apis;
    AppPrivilegeSignal? privilege;
    try {
      // 每次都重查：discover() 会重新打 SYNO.API.Info。
      final table = await api.discover();
      apis = table.keys.toSet();
      // 信号 1：`Core.Desktop.Initdata:get` 的 AppPrivilege（普通用户可读）。
      // 拿不到就 null —— 判定退回信号 2，**绝不因此隐藏或因此不隐藏**。
      privilege = await _probePrivilege(api);
      states = {
        for (final entry in kServiceRegistry.entries)
          entry.key: classifyMultiSignal(entry.value, apis, privilege),
      };
    } catch (_) {
      // 网络 / 握手失败 → unreachable。**不隐藏**，只给"重试"。
      privilege = null;
      states = {
        for (final entry in kServiceRegistry.entries)
          entry.key: entry.value.requiredApis.isEmpty
              ? AvailabilityState
                    .available // ai 等无服务端依赖的恒可用
              : AvailabilityState.unreachable,
      };
    }
    if (_disposed) return;
    state = ServiceAvailabilitySnapshot(
      states: states,
      apis: apis,
      privilege: privilege,
      checkedAt: DateTime.now(),
      probing: false,
    );
    await _persist();
  }

  /// 取**信号 1**（`AppPrivilege`）。
  ///
  /// ★ 第 254 轮起**优先复用会话权限画像**（`sessionEntitlementProvider`）：
  /// 身份通道在登录后已经打过一次 `Initdata:get`，模块可见性没有理由再打
  /// 第二次（旧实现在同一次登录里会打两遍整包 3.1 MB 的 Initdata）。
  ///
  /// 顺序（**都不把服务判死**，失败一律退回信号 2）：
  /// ① 会话权限画像里已经有 `AppPrivilege` ⇒ 直接用；
  /// ② 画像还没到 / 拿不到（未登录、老 DSM 没这个方法、形状不对）⇒
  ///    自己打一次 `Initdata:get` 兜底（保持旧行为）；
  /// ③ 连兜底也失败（`119` / `106` / 网络 / 形状不对）⇒ `null`。
  Future<AppPrivilegeSignal?> _probePrivilege(DsmWebApi api) async {
    try {
      final ent = await ref.read(sessionEntitlementProvider.future);
      if (ent.appPrivilege.known) return ent.appPrivilege;
    } catch (_) {
      // 画像不可用 ⇒ 走兜底
    }
    try {
      final data = await api.call(kDesktopInitdataApi, 'get');
      final signal = AppPrivilegeSignal.fromInitdata(data);
      return signal.known ? signal : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _persist() async {
    if (_disposed || state.states.isEmpty) return;
    try {
      final store = ref.read(chatStoreProvider);
      await store.setSetting(kServiceAvailabilityKey, _encode(state));
    } catch (_) {
      // 落盘失败不该让检测结果失效
    }
  }

  Future<ServiceAvailabilitySnapshot?> _readCache() async {
    try {
      final store = ref.read(chatStoreProvider);
      final raw = await store.setting(kServiceAvailabilityKey);
      if (raw == null || raw.isEmpty) return null;
      return _decode(raw);
    } catch (_) {
      return null;
    }
  }

  static String _encode(ServiceAvailabilitySnapshot s) => jsonEncode({
    'at': (s.checkedAt ?? DateTime.now()).millisecondsSinceEpoch,
    'apis': s.apis.toList(),
    'states': {for (final e in s.states.entries) e.key.name: e.value.name},
    // 信号 1 也落盘：设置页/诊断能看到"上次检测时 AppPrivilege 是什么"。
    // 缺字段（旧缓存）→ 解出 null，判定按信号 2 走。
    if (s.privilege != null) 'priv': s.privilege!.toJson(),
    if (s.privilege != null) 'privAllowAll': s.privilege!.allowAll,
  });

  static ServiceAvailabilitySnapshot? _decode(String raw) {
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final rawStates = map['states'];
      final states = <StationService, AvailabilityState>{};
      if (rawStates is Map) {
        for (final entry in rawStates.entries) {
          final service = _serviceByName('${entry.key}');
          final st = _stateByName('${entry.value}');
          if (service != null && st != null) states[service] = st;
        }
      }
      final apis = <String>{};
      final rawApis = map['apis'];
      if (rawApis is List) {
        for (final a in rawApis) {
          apis.add('$a');
        }
      }
      AppPrivilegeSignal? privilege;
      final rawPriv = map['priv'];
      if (rawPriv is Map) {
        final entries = <String, bool>{};
        rawPriv.forEach((k, v) {
          if (v is bool) entries['$k'] = v;
        });
        privilege = AppPrivilegeSignal(
          entries: entries,
          allowAll: map['privAllowAll'] == true,
        );
      }
      final at = map['at'];
      return ServiceAvailabilitySnapshot(
        states: states,
        apis: apis,
        privilege: privilege,
        checkedAt: at is int ? DateTime.fromMillisecondsSinceEpoch(at) : null,
      );
    } catch (_) {
      return null;
    }
  }

  static StationService? _serviceByName(String name) {
    for (final s in StationService.values) {
      if (s.name == name) return s;
    }
    return null;
  }

  static AvailabilityState? _stateByName(String name) {
    for (final s in AvailabilityState.values) {
      if (s.name == name) return s;
    }
    return null;
  }
}

// ---------------------------------------------------------------- 安全阀

/// 「临时显示隐藏的模块」的 KV 键（设置 → 服务检测）。
const String kShowHiddenServicesKey = 'service_show_hidden.v1';

/// 安全阀：用户在「设置 → 服务检测」里打开后，被判 `absent` / `unauthorized`
/// 的模块**临时**恢复可见（用户自己决定要不要看，避免"想用却永远找不回来"）。
final showHiddenServicesProvider =
    NotifierProvider<ShowHiddenServicesNotifier, bool>(
      ShowHiddenServicesNotifier.new,
    );

class ShowHiddenServicesNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// 冷启动读回本地偏好（`app.dart` 启动时调用）。
  Future<void> preload() async {
    try {
      final raw = await ref
          .read(chatStoreProvider)
          .setting(kShowHiddenServicesKey);
      if (raw == 'true') state = true;
    } catch (_) {
      // 读失败就用默认（false）
    }
  }

  Future<void> set(bool value) async {
    state = value;
    try {
      await ref
          .read(chatStoreProvider)
          .setSetting(kShowHiddenServicesKey, value ? 'true' : 'false');
    } catch (_) {
      // 落盘失败不影响本次会话
    }
  }
}
