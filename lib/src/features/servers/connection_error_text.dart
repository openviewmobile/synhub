import '../../core/i18n/data_text.dart';
import '../../core/user_facing_error.dart';

/// 把**连接/登录阶段**的异常翻译成用户看得懂的话。
///
/// ## 为什么必须要有（真机实测缺陷）
///
/// 2026-09-22 真机（HONOR `LGE-AN10`）：QuickConnect 查询超时后，**连接页**上的
/// `LINK LOG` 逐字显示：
///
/// ```
/// QuickConnect 查询失败，稍后重试：
///   DioException [connection timeout]: The request connection took longer …
/// DioException [connection timeout]: The request connection took longer than
///   0:00:30.000000 and it was aborted. To get rid of this exception, try …
/// ```
///
/// **这是用户打开 App 看到的【第一屏】。** 问题与 Office 那条错误横幅同类：
/// 1. 暴露 `DioException` 这个 Dart/三方库的**内部类型名**；
/// 2. 暴露 `0:00:30.000000` 这种**内部超时字面量**；
/// 3. 甚至把**给开发者看的建议**（"To get rid of this exception, try…"）甩给用户。
///
/// 而用户真正需要知道的只有一件事：**连不上，以及下一步能做什么**。
///
/// ## 设计原则（与 `office_error_text.dart` 一致）
/// * **用户语言在前**：先说结论 + 可操作建议；
/// * **不认识的异常也绝不丢原文**：给通用人话，原文只进 `debugPrint`；
/// * **保留可报障的信息**：DSM 错误码保留（例如 `DSM 402`），因为客服/论坛要靠它；
/// * **不泄露**：类型名、堆栈、内部时长字面量、三方库的开发者提示。
///
/// ## 为什么不直接"闭嘴"（不显示任何错误）
/// 连接失败**必须**让用户知道，否则界面会看起来"卡住了"。
/// 这个函数的作用是**换一种说法**，不是**不说**。
String connectionUserFacingError(Object error) {
  // 具体分类（dio 各 `DioExceptionType`、`DsmTransportException`、
  // `DsmApiException`、系统网络异常、未知兜底）已收敛到全仓唯一出口
  // `lib/src/core/user_facing_error.dart`，这里只提供**连接场景**的兜底文案。
  //
  // 之所以保留这个薄封装：连接页（用户第一屏）的测试锁定在这里，
  // 且连接失败需要的兜底话术与通用"操作未能完成"不同 —— 必须告诉用户
  // "检查服务器地址与网络"。
  //
  // ★ r677（`DA309`）：这里原来传的是**硬编码中文** —— 于是英文界面里"未知异常"
  //   这一支会蹦出中文（iOS 模拟器 `locale=ja-JP` 的 `DUMP` 实证：
  //   `连接失败：请检查服务器地址与网络后重试` 夹在整屏英文里）。
  //   兜底文案必须和上面每一条一样走 `dataText(key, 中文原文)`。
  return userFacingError(
    error,
    fallback: dataText(
      'errConnectFailed',
      '连接失败：请检查服务器地址与网络后重试',
    ),
  );
}

/// 供诊断用：把异常原文打到日志（**不**进界面）。
///
/// 连接阶段的原始异常对排查很有用（尤其 QuickConnect 打洞），
/// 所以**不丢**，只是改走日志。
void logConnectionErrorForDiagnostics(String where, Object error, [StackTrace? st]) {
  // ignore: avoid_print
  print('[session:$where] $error');
  if (st != null) {
    // ignore: avoid_print
    print('[session:$where] $st');
  }
}
