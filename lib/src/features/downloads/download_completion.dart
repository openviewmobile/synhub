// F12：下载任务的**完成/失败检测与通知**（纯客户端，无服务端 API）。
//
// 官方 App 用本地/FCM 通知面提示任务完成；服务端这边没有"订阅完成事件"的
// API，只能由客户端轮询 `Task/list` 并对比状态。本文件负责：
//   1. `diffDownloadCompletions` —— **纯函数**状态差分（可离线单测）；
//   2. `DownloadCompletionNotifier` —— 保存"上一次看到的状态"，产出完成事件；
//   3. `downloadNotifyProvider` —— 用户开关（本地持久化，默认开）。
//
// ★ 能力边界已解除（第 168 轮）：原生侧已加通用本地通知
//   `android/.../DownloadNotifications.kt`（通道
//   `synhub/download_notifications`：`available` / `show`），
//   Dart 出口在 `download_notification_sink.dart`。
//   于是本文件的事件流现在**同时**驱动：应用内 SnackBar（既有）+ **系统通知栏**
//   （本轮新增）。开关与差分的职责仍只在本文件，别处不要重复实现。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/data_text.dart';
import '../../data/download_station.dart';
import '../../data/dto/download_task_dto.dart';
import '../chat/chat_session_controller.dart' show chatStoreProvider;
import 'download_notification_sink.dart';
import 'download_providers.dart';

/// 一条"任务刚刚完成/失败"的事件。
class DownloadCompletionEvent {
  const DownloadCompletionEvent({
    required this.taskId,
    required this.title,
    required this.failed,
  });

  /// 任务 id（**内部标识，界面绝不显示**）。
  final String taskId;
  final String title;

  /// true = 失败（`status >= 101`）；false = 完成。
  final bool failed;
}

/// **纯函数**：把"上一次看到的状态快照"与"当前任务列表"做差分，
/// 产出刚刚进入**完成**或**失败**态的任务（F12）。
///
/// [previousStatus] 为空 = 首次加载：**不产出任何事件**（否则会把 App 启动前
/// 就已经完成的历史任务全部弹一遍）。
List<DownloadCompletionEvent> diffDownloadCompletions({
  required Map<String, int> previousStatus,
  required List<DownloadTaskDto> current,
}) {
  if (previousStatus.isEmpty) return const [];
  final events = <DownloadCompletionEvent>[];
  for (final task in current) {
    final terminal = task.isFinished || task.isError;
    if (!terminal) continue;
    final prev = previousStatus[task.id];
    if (prev == null) continue; // 首次见到（新建的）任务：不算"刚完成"
    final prevTerminal =
        DsTaskStatus.finishedGroup.contains(prev) || DsTaskStatus.isError(prev);
    if (prevTerminal) continue; // 已经是终态，不重复提醒
    events.add(
      DownloadCompletionEvent(
        taskId: task.id,
        title: task.title,
        failed: task.isError,
      ),
    );
  }
  return events;
}

/// 上一次看到的状态（`task id → status`），供差分使用。
class DownloadCompletionState {
  const DownloadCompletionState({
    this.previousStatus = const {},
    this.pending = const [],
  });

  final Map<String, int> previousStatus;

  /// 还没被界面消费掉的事件。
  final List<DownloadCompletionEvent> pending;
}

class DownloadCompletionNotifier extends Notifier<DownloadCompletionState> {
  @override
  DownloadCompletionState build() => const DownloadCompletionState();

  /// 每拿到一份任务列表就调一次：差分 → 追加事件 → 更新快照。
  ///
  /// 开关关掉时**只更新快照**，不产生事件（关掉开关后再打开不会补弹历史）。
  void record(List<DownloadTaskDto> tasks, {bool enabled = true}) {
    final events = enabled
        ? diffDownloadCompletions(
            previousStatus: state.previousStatus,
            current: tasks,
          )
        : const <DownloadCompletionEvent>[];
    state = DownloadCompletionState(
      previousStatus: {for (final t in tasks) t.id: t.status},
      pending: [...state.pending, ...events],
    );
  }

  /// 界面取走（并清空）待提示事件。
  List<DownloadCompletionEvent> consume() {
    final events = state.pending;
    if (events.isNotEmpty) {
      state = DownloadCompletionState(
        previousStatus: state.previousStatus,
        pending: const [],
      );
    }
    return events;
  }

  /// 主动轮询一次**全部**任务并做差分（F12）。
  ///
  /// 为什么单独拉一份"全部"而不是复用页面当前的过滤视图：用户可能正停在
  /// 「下载中」或「已完成」标签下，过滤后的列表看不到"刚刚进入完成态"这个
  /// 转移。返回本次新产生的事件数。出错时**静默**（网络抖动不该弹错误条）。
  Future<int> poll({bool enabled = true}) async {
    final api = ref.read(downloadApiProvider);
    if (api == null || !api.installed) return 0;
    try {
      final page = await api.listTasks(
        offset: 0,
        limit: DownloadStationApi.pageSize,
        category: DownloadTaskCategory.all,
      );
      final before = state.pending.length;
      record(page.items, enabled: enabled);
      final fresh = state.pending.sublist(before);
      final added = fresh.length;
      if (enabled && fresh.isNotEmpty) {
        await _pushSystem(fresh);
      }
      return added;
    } catch (_) {
      return 0;
    }
  }

  /// 把新事件推到**系统通知栏**（本地通知）。
  ///
  /// 系统不允许（Android 13+ 未授权）时**静默不推**：应用内提示仍然有效，
  /// 不让"没权限"变成下载页的错误。
  Future<void> _pushSystem(List<DownloadCompletionEvent> events) async {
    final sink = ref.read(downloadNotificationSinkProvider);
    if (!await sink.available()) return;
    for (final e in events) {
      await sink.show(
        id: e.taskId.hashCode,
        title: e.failed
            ? dataText('dsNotifyDownloadFailed', '下载失败')
            : dataText('dsNotifyDownloadDone', '下载完成'),
        text: e.title,
      );
    }
  }
}

final downloadCompletionProvider =
    NotifierProvider<DownloadCompletionNotifier, DownloadCompletionState>(
      DownloadCompletionNotifier.new,
    );

/// 「任务完成时提醒」开关的持久化 key（纯本地，走 `ChatStore` 的 KV 表）。
const String kDownloadNotifyKey = 'ds_notify_on_complete';

/// 「完成提醒开关」的最小存储接口。
///
/// 生产实现读写 `ChatStore` 的设置表；**测试覆盖成内存实现**，避免 widget
/// 测试里去打开真实 drift 数据库（否则会触发 drift 的 multiple-databases 警告）。
abstract class DownloadNotifyStore {
  Future<String?> read();
  Future<void> write(bool on);
}

/// 生产实现：`ChatStore.setting/setSetting`（与其它本地设置同一个 KV 表）。
class ChatDownloadNotifyStore implements DownloadNotifyStore {
  ChatDownloadNotifyStore(this.ref);

  final Ref ref;

  @override
  Future<String?> read() =>
      ref.read(chatStoreProvider).setting(kDownloadNotifyKey);

  @override
  Future<void> write(bool on) => ref
      .read(chatStoreProvider)
      .setSetting(kDownloadNotifyKey, on ? 'true' : 'false');
}

/// 测试可覆盖的内存实现。
class MemoryDownloadNotifyStore implements DownloadNotifyStore {
  MemoryDownloadNotifyStore([this._value]);

  String? _value;

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> write(bool on) async => _value = on ? 'true' : 'false';
}

final downloadNotifyStoreProvider = Provider<DownloadNotifyStore>(
  (ref) => ChatDownloadNotifyStore(ref),
);

/// F12 轮询间隔（默认 15s）。做成 provider 便于测试覆盖成 0/大值。
final downloadCompletionPollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 15),
);

/// 完成通知开关（默认开）。`DownloadPage` 首帧后调 [DownloadNotifyNotifier.preload]。
final downloadNotifyProvider =
    NotifierProvider<DownloadNotifyNotifier, bool>(
      DownloadNotifyNotifier.new,
    );

class DownloadNotifyNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  DownloadNotifyStore get _store => ref.read(downloadNotifyStoreProvider);

  /// 启动/进入下载页时把持久化的值读进来（读不到就当默认开，不抛）。
  Future<void> preload() async {
    try {
      final raw = await _store.read();
      if (raw != null && ref.mounted) state = raw == 'true';
    } catch (_) {
      // 本地库没起来（早启动/测试环境）：保持默认值
    }
  }

  Future<void> set(bool on) async {
    state = on;
    try {
      await _store.write(on);
    } catch (_) {
      // 写不进去不影响本次会话生效
    }
  }
}
