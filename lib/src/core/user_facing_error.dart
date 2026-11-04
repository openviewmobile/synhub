// 全仓**唯一**的「异常 → 用户文案」出口。
//
// ## 为什么必须存在（真机实测缺陷，2026-09-22，HONOR `LGE-AN10`）
//
// 连接页（用户打开 App 看到的**第一屏**）的 `LINK LOG` 逐字显示：
//
// ```
// QuickConnect 查询失败，稍后重试：
//   DioException [connection timeout]: The request connection took longer …
// DioException [connection timeout]: The request connection took longer than
//   0:00:30.000000 and it was aborted. To get rid of this exception, try …
// ```
//
// 三个问题，都是从用户角度不可接受：
// 1. 暴露 `DioException` 这个**三方库内部类型名**；
// 2. 暴露 `0:00:30.000000` 这种**内部超时字面量**；
// 3. 把**给开发者看的建议**（"To get rid of this exception, try…"）甩给用户。
//
// 根因不是一个地方：全仓曾有 170 处 `Text(...'$e')` / `error: '$e'` /
// `showSnackBar(Text(t.xxx('$e')))` 把异常整体 `toString()` 进了界面。
//
// ## 设计原则（照抄已真机验证过的
// `features/office/office_error_text.dart` 与
// `features/servers/connection_error_text.dart` 的精神）
//
// * **用户语言在前**：先说结论 + 可操作建议（"连不上，检查网络"），
//   而不是"发生了什么异常"；
// * **不认识的异常也绝不丢原文**：给通用人话，原文只进
//   [logErrorForDiagnostics] 的日志；
// * **保留可报障的信息**：DSM 错误码（`DSM 402`）、HTTP 状态码要保留，
//   用户报障 / 客服排查靠它；
// * **绝不泄露**：Dart / 三方库类型名、堆栈、内部时长字面量、
//   三方库的开发者提示、`package:` 路径、JSON 报文。
//
// ## 依赖方向
//
// 本文件只依赖 `dart:async` / `dart:io` / `package:dio` / `../dsm/webapi.dart`
// （`dsm/webapi.dart` 本身是纯 Dart 可加载的）。**不 import `features/**`** ——
// core 不能反向依赖 feature；feature 特有的异常在各自的 feature 层再包装。
//
// 已存在的、有测试锁定的具体文案由薄封装转发到这里：
//   * `features/office/office_error_text.dart`（OfficeCollab* 分支保留）
//   * `features/servers/connection_error_text.dart`
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../dsm/webapi.dart';
import 'i18n/data_text.dart';

/// 把任意异常翻译成**能给用户看的一行话**。
///
/// [fallback] 是"完全不认识的异常"时用的兜底文案。调用方可以传一句
/// 更贴合场景的话（例如连接页传"连接失败：请检查服务器地址与网络后重试"），
/// 但**绝不能**传进异常原文 —— 那会把本函数的意义抹掉。
///
/// 返回值保证：
/// * 不含 Dart / 三方库类型名（`Exception`、`DioException`…）；
/// * 不含堆栈（`#0`、`StackTrace`、`package:`）；
/// * 不含内部时长字面量（`0:00:30.000000`）；
/// * 不含三方库的开发者提示（`To get rid of this exception`…）；
/// * 不含原始 JSON 报文；
/// * 非空。
String userFacingError(Object error, {String? fallback}) {
  // 第 281 轮：本函数是全仓唯一的「异常 → 用户文案」出口。**兜底与各类文案都必须走
  // dataText**，否则一旦被英文模板拼进去（如 `xxx('{error}')`）就会中英混排 ——
  // 第 280 轮 macOS 真机像素实证：`Realtime channel not ready: 操作未能完成`。
  final String fb = fallback ?? dataText('errGenericFailed', '操作未能完成');
  // ---- dio：传输层。先按 `DioExceptionType` 分类，**绝不**读 `error.message`。
  //
  // ⚠️ 必须覆盖全部枚举成员（exhaustive switch）：dio 5.4+ 新增了
  // `transformTimeout`，漏掉会让"解析阶段超时"掉进兜底，丢掉"超时"这个
  // 用户能理解的关键词。
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return dataText('errConnectTimeout', '连接超时：服务器没有及时响应，请检查网络后重试');
      case DioExceptionType.connectionError:
        return dataText('errCannotReachServer', '无法连接到服务器：请检查地址与网络');
      case DioExceptionType.badCertificate:
        return dataText('errBadCertificate', '服务器证书校验未通过');
      case DioExceptionType.badResponse:
        // HTTP 状态码对报障有用，保留。
        final code = error.response?.statusCode;
        return code == null ? dataText('errAbnormalResponse', '服务器返回了异常响应') : dataText('errHttpStatus', '服务器返回 HTTP {code}').replaceAll('{code}', '$code');
      case DioExceptionType.cancel:
        return dataText('errCancelled', '操作已取消');
      case DioExceptionType.unknown:
        break;
    }
  }

  // ---- 本仓传输层自己的包装（API 层本来就刻意不暴露 dio 类型）----
  if (error is DsmTransportException) {
    final code = error.statusCode;
    return code == null ? dataText('errNetworkConnectFailed', '网络连接失败：请检查网络后重试') : dataText('errHttpStatus', '服务器返回 HTTP {code}').replaceAll('{code}', '$code');
  }

  // ---- DSM 业务错误码：保留码值（用户报障要靠它），但不带报文 ----
  //
  // 码值一定保留；`describe` 给出的人话只在**确实认识这个码**时追加，
  // 否则会得到 `DSM 402：错误码 402` 这种同等啰嗦且更长的结果。
  if (error is DsmApiException) {
    final described = DsmErrorCode.describe(error.code, method: error.method);
    if (described.isEmpty || described == _unknownCodeText(error.code)) {
      return 'DSM ${error.code}';
    }
    return dataText('errDsmCodeWithDetail', 'DSM {code}：{detail}')
        .replaceAll('{code}', '${error.code}')
        .replaceAll('{detail}', described);
  }

  // ---- 系统 / dart 核心异常 ----
  if (error is SocketException) {
    return dataText('errNetworkUnreachable', '网络不可达：请检查 Wi-Fi 或移动网络');
  }
  if (error is HandshakeException) {
    return dataText('errTlsHandshakeFailed', '与服务器的加密握手失败（可能是证书或代理问题）');
  }
  if (error is HttpException) {
    return dataText('errNetworkRequestFailed', '网络请求失败：请稍后重试');
  }
  if (error is FormatException) {
    return dataText('errBadDataFormat', '数据格式不正确，无法处理');
  }
  if (error is FileSystemException) {
    return dataText('errFileIoFailed', '读写文件失败：请检查存储空间与权限');
  }
  if (error is TimeoutException) {
    return dataText('errOperationTimeout', '操作超时：请稍后重试');
  }
  // `StateError` / `Error` 通常是**代码缺陷**而不是用户操作错误：
  // 给通用人话，原文只进日志，绝不把类型名透出去。
  if (error is StateError || error is Error) {
    return fb;
  }

  // ---- 兜底：仍是用户语言，**绝不**拼接原文 ----
  return fb;
}

/// `DsmErrorCode.describe` 对**不认识的码**会返回的那句通用文案。
///
/// 用它来判断"describe 是否真的提供了额外信息"，避免
/// `DSM 402：错误码 402` 这种重复。
String _unknownCodeText(int code) =>
    dataText('apiUnknownErrorCode', '错误码 {code}').replaceAll('{code}', '$code');

/// 供诊断用：把异常原文打到日志（**不**进界面）。
///
/// 用 `print` 而不是 `debugPrint`，与
/// `office_error_text.dart` / `connection_error_text.dart` 的既有实现一致 ——
/// 这两条日志路径在真机排查（尤其 QuickConnect 打洞）时很关键，必须保留。
void logErrorForDiagnostics(String where, Object error, [StackTrace? st]) {
  // ignore: avoid_print
  print('[error:$where] $error');
  if (st != null) {
    // ignore: avoid_print
    print('[error:$where] $st');
  }
}
