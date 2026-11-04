/// 开发/调试入口的**总开关**（r378）。
///
/// 默认 **`false`**：release 包里「**设计预览画廊**」与「**诊断页**」的
/// **入口**（登录页 2 处 / 设置页 / 聊天页 ⋮ 面板）与**路由**都不存在。
///
/// 打开方式（只有本地开发/排查用）：
///
/// ```bash
/// flutter run --dart-define=SYNHUB_DEV_TOOLS=true
/// ```
///
/// ★ 为什么用 `bool.fromEnvironment`（编译期常量）而不是运行时开关：
///   AOT 会把 `if (kDevTools)` 的假分支**整个摇掉**，所以"最终安装包里没有临时页面"
///   这件事**由编译期保证**，而不是靠运行时藏起来（对照 `kOfficeProbe` 的同款做法）。
/// ★ 本开关只 `grep` 得动这两页；新增开发者入口必须一并挂到这个开关上，
///   并由 `test/dev_tools_gate_test.dart` 静态盯住。
const bool kDevTools = bool.fromEnvironment('SYNHUB_DEV_TOOLS');

/// 设计预览画廊的路由/入口是否可用（语义化别名，读起来更清楚）。
const bool kDesignPreviewEnabled = kDevTools;

/// 诊断页的路由/入口是否可用。
const bool kDiagnosticsEnabled = kDevTools;
