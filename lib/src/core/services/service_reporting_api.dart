// 统一错误出口 —— 把"模块调用失败"回填成服务可用性状态（设计 §2.2 / §5 S2）。
//
// 为什么放在这一层（而不是在每个模块的 provider 里各写一遍 catch）：
//   * `DsmWebApi.call` 是 DSM 各模块调用的**唯一主干**（全仓 300+ 处），
//     且 102 / 105 / 160 / 119 / 106 这些错误码都在 `_okData` / `_prepare`
//     统一抛出。这里覆写一次 [call] 就覆盖了全部 12 个模块的主链路；
//   * API 名 → 服务 的映射集中在 `service_registry.dart` 的纯函数
//     [serviceForApiName]，模块侧不需要知道"自己是谁"。
//
// ⚠️ **绝不允许把 119/106 回填成隐藏**：
//   本类只负责"抓到错误 → 交给出错的服务"，**不做任何状态判定**——
//   判定仍是 `classifyErrorCode` 的纯函数（119/106 → sessionExpired，
//   `hidesModule` 为 false）。网络异常（非 `DsmApiException`）同样只当
//   `unreachable`，不隐藏。
//
// 边界（已知且刻意）：只有走 [call] 的失败会被回填；`postMultipart` /
// `getBytes` / `postBytesForm` 这几条**二进制/上传**旁路没有统一的 API 名，
// 不在本类覆盖范围内（上传失败仍由各模块自己的错误 UI 兜底，不隐藏模块）。
library;

import '../../dsm/webapi.dart';
import 'service_registry.dart';

/// 一次失败的回调签名：哪个服务、哪个 API、原始错误。
typedef ApiFailureReporter =
    void Function(StationService service, String apiName, Object error);

/// `DsmWebApi` 的薄包装：**原样转发一切**，只在 [call] 失败时多回调一次
/// [onApiFailure]。不改变任何返回值 / 异常类型（`rethrow` 原样保留）。
///
/// 注意：这是**子类**而非组合包装——`_apis` / `_session` 等状态都在父类实例
/// 自己身上，业务客户端拿到的就是这一个实例（见 `connection_service.dart`），
/// 所以 `discover()` / `login()` / 自动重登的行为完全不变。
class ServiceReportingApi extends DsmWebApi {
  ServiceReportingApi(super.transport);

  /// 失败回调。由 `service_availability.dart` 在探测时挂上；
  /// 为空时本类退化成**完全等价**的 `DsmWebApi`（测试里直接 new 也安全）。
  ApiFailureReporter? onApiFailure;

  @override
  Future<Map<String, dynamic>> call(
    String api,
    String method, {
    int preferredVersion = 1,
    Map<String, dynamic> params = const {},
    bool requiresAuth = true,
  }) async {
    try {
      return await super.call(
        api,
        method,
        preferredVersion: preferredVersion,
        params: params,
        requiresAuth: requiresAuth,
      );
    } catch (error) {
      _report(api, error);
      rethrow;
    }
  }

  void _report(String apiName, Object error) {
    final reporter = onApiFailure;
    if (reporter == null) return;
    // 认不出所属服务的 API（Auth / Info / Entry.Request …）不参与降级。
    final service = serviceForApiName(apiName);
    if (service == null) return;
    reporter(service, apiName, error);
  }
}
