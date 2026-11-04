// 使用日志库的**连接层（web 桩）**（第 334 轮）。
//
// web 上**还没有**存储后端：drift 在 web 上要 `drift/wasm.dart` +
// `sqlite3.wasm` 资产（或换 `sqlite3_web`），这属于"本地库在 web 上怎么存"的
// 产品决策，本轮**不假实现**（§2.0.45：答不上来就先不接）。
//
// 因此这里如实抛 `UnsupportedError`：
//   * 调用方（`analytics_database.dart`）已按"日志功能可降级但不崩"设计
//     —— 降级路径见同文件的 `.memory()` 兜底与 `usage_log.dart` 的开关；
//   * `flutter build web` 因此可以**编过**（web 站 P0 的一半），
//     但"web 上使用日志真的能写"仍是**未实现**，不许写成"已支持"。
library;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

// ★ 第 338 轮：诊断串**内联在 `UnsupportedError(...)` 里**（原来抽成
// `kAnalyticsWebUnsupported` 顶层常量）—— 那条常量在全仓**零引用**（§2.0.45
// "封装了没有 caller = 死功能"），而且 `i18n_hardcoded_cjk_test` 只豁免
// "异常实参"里的中文（文件头第 4 条），抽成常量会被判成硬编码界面文案。
/// ★★ 第 338 轮（D36）**订正**：web 上其实**已经有** drift 的 wasm 后端
/// —— `ChatDatabase` 走的就是 `driftDatabase(web: DriftWebOptions(...))`
/// （`web/sqlite3.wasm` + `web/drift_worker.dart.js`，首屏探针里
/// `WORKER.created drift_worker.dart.js` + `WasmStorageImplementation.sharedIndexedDb`
/// 是实测读数）。r334 把这条连接写成"如实抛"之后，`usageLogProvider` 在 web 上
/// **必然停在错误态**，启动时把 `ProviderException` 喷给每个读者（详见
/// `docs/evidence-r338/README.md`）⇒ 这里改成与 chat 库**同一条** wasm 后端
/// （库名不同：`synology_analytics`，与 io 侧一致）。
QueryExecutor analyticsConnection() => driftDatabase(
  name: 'synology_analytics',
  web: DriftWebOptions(
    sqlite3Wasm: Uri.parse('sqlite3.wasm'),
    driftWorker: Uri.parse('drift_worker.dart.js'),
  ),
);

/// web 上没有"同步建内存库"这条路（drift 的内存库在 web 上要 wasm + 异步装配）
/// ⇒ 这里如实抛；调用方（`usageLogProvider`）已经按"兜底也失败 ⇒ 日志关闭"处理。
///
/// ⚠️ **不要**改成 `LazyDatabase(() async => throw …)`："构造得出来、访问才异步抛"
/// 会把失败报进 zone（浏览器/测试里都是未捕获异常）。见 `UsageLog.disabled()`。
QueryExecutor analyticsMemoryConnection() => throw UnsupportedError(
    '使用日志库在 web 上没有同步内存后端（drift 的内存库在 web 上要 wasm 异步装配）');

