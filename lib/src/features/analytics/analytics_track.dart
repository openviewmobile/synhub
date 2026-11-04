// 埋点入口：`track(ref, 模块, 动作)` —— 一行接入，失败静默。
//
// 为什么做成这样：
//   * 调用点只关心"我要记一笔"，不该关心缓冲、会话、脱敏（都在 [UsageLog]）；
//   * **拿不到 ref 的地方**（回调里、非 Widget 层）用 [trackOnce]（全局单例）；
//   * 记录绝不能抛异常：这里整段 try/catch，最坏情况就是少一条日志。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'usage_event.dart';
import 'usage_log.dart';

/// 全局日志单例：由 `app.dart` 启动时注入（`setGlobalUsageLog`）。
///
/// ⚠️ 为什么**只**用全局单例、不在埋点里 `ref.read(usageLogProvider)`：
/// 页面级 widget 测试不会跑 `app.dart`，一旦埋点自己去读 provider，就会在测试里
/// 懒打开磁盘上的日志库（拿不到应用目录 → 报错）、并留下 5 秒的 flush 定时器
/// （`flutter_test` 会断言 "A Timer is still pending"）。全局未注入时埋点就是
/// 纯粹的 no-op —— 页面代码因此永远不持有数据库。
UsageLog? _globalLog;

/// 启动时注入全局日志（`app.dart` 调用一次）
void setGlobalUsageLog(UsageLog? log) => _globalLog = log;

/// 当前是否已注入（App 跑起来了）
bool get usageTrackingArmed => _globalLog != null;

/// 记录一条事件（有 `WidgetRef` 的地方用；`ref` 只用于将来做"按账号/按会话"的
/// 分流，现在统一走全局单例）
void track(
  WidgetRef ref,
  UsageModule module,
  UsageAction action, {
  String objectType = '',
  int value = 0,
  Map<String, Object?> detail = const {},
}) {
  try {
    _globalLog?.record(
      module,
      action,
      objectType: objectType,
      value: value,
      detail: detail,
    );
  } catch (_) {
    // 日志失败不影响业务
  }
}

/// 同上，但用于拿不到 `WidgetRef` 的场景（service / controller）
void trackOnce(
  UsageModule module,
  UsageAction action, {
  String objectType = '',
  int value = 0,
  Map<String, Object?> detail = const {},
}) {
  try {
    _globalLog?.record(
      module,
      action,
      objectType: objectType,
      value: value,
      detail: detail,
    );
  } catch (_) {}
}

/// 记一条失败事件
void trackFailure(
  UsageModule module,
  UsageAction action, {
  String objectType = '',
  Object? reason,
  Object? error,
}) {
  try {
    _globalLog?.recordFailure(
      module,
      action,
      objectType: objectType,
      reason: reason,
      error: error,
    );
  } catch (_) {}
}

/// 同上，但用于拿不到 `WidgetRef` 的场景（service / controller）
void trackOnceFailure(
  UsageModule module,
  UsageAction action, {
  String objectType = '',
  Object? reason,
  Object? error,
}) {
  try {
    _globalLog?.recordFailure(
      module,
      action,
      objectType: objectType,
      reason: reason,
      error: error,
    );
  } catch (_) {}
}

// ── 第 275 轮：行为偏好类埋点助手 ────────────────────────────────────────
// 目标是"能回答偏好问题"：进了哪些页面、选了哪种视图、筛/排了什么、
// 模板选了哪个、一次播放/阅读花了多久、失败原因是什么。

/// 进入页面/打开一个可分析的界面（曝光）。[screen] 是稳定页面 id（不是标题）。
void trackView(
  UsageModule module, {
  required String screen,
  Map<String, Object?> detail = const {},
}) => trackOnce(
  module,
  UsageAction.view,
  objectType: screen,
  detail: detail,
);

/// 视图模式偏好（栅格/列表/时间线/歌词/可视化…）。[view] 是稳定枚举值。
void trackViewMode(
  UsageModule module,
  String view, {
  Map<String, Object?> detail = const {},
}) => trackOnce(
  module,
  UsageAction.switchView,
  objectType: view,
  detail: {UsageDetailKeys.view: view, ...detail},
);

/// 筛选/排序偏好。[key] 是稳定字段名，[value] 是稳定选项 id。
void trackFilter(
  UsageModule module, {
  required String key,
  required String value,
}) => trackOnce(
  module,
  UsageAction.filter,
  detail: {key: value},
);

void trackSort(UsageModule module, String value) => trackOnce(
  module,
  UsageAction.sort,
  objectType: value,
  detail: {UsageDetailKeys.preset: value},
);

/// 选择类偏好（模板 / 预设 / 音质 / 主题 / 语言…）。[choice] 是稳定选项 id。
void trackSelect(
  UsageModule module,
  String choice, {
  String kind = '',
}) => trackOnce(
  module,
  UsageAction.select,
  objectType: choice,
  detail: {
    UsageDetailKeys.preset: choice,
    if (kind.isNotEmpty) UsageDetailKeys.kind: kind,
  },
);

/// 一次**有时长**的使用完成（播放/阅读/预览…）：`action=complete`，
/// `value` = 毫秒，`detail.duration_ms` 同样落一份便于分组。
void trackComplete(
  UsageModule module, {
  required UsageAction action,
  required Duration duration,
  String objectType = '',
  Map<String, Object?> detail = const {},
}) {
  final ms = duration.inMilliseconds < 0 ? 0 : duration.inMilliseconds;
  trackOnce(
    module,
    UsageAction.complete,
    objectType: objectType,
    value: ms,
    detail: {
      UsageDetailKeys.durationMs: ms,
      UsageDetailKeys.preset: action.id,
      ...detail,
    },
  );
}

/// 播放/阅读"开始"（配 [trackComplete] 成对使用）
void trackStart(
  UsageModule module,
  UsageAction action, {
  String objectType = '',
  Map<String, Object?> detail = const {},
}) => trackOnce(
  module,
  UsageAction.start,
  objectType: objectType,
  detail: {UsageDetailKeys.preset: action.id, ...detail},
);

/// 从文件名取"类型"（只留扩展名，**不留文件名**）
String trackObjectOf(String fileName) => extensionOf(fileName);

/// 常用组合：文件类操作
void trackFile(
  WidgetRef ref,
  UsageModule module,
  UsageAction action,
  String fileName, {
  int size = 0,
  Map<String, Object?> detail = const {},
}) => track(
  ref,
  module,
  action,
  objectType: extensionOf(fileName),
  value: size,
  detail: detail,
);
