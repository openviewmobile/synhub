// 「正在输入」状态（对齐原版 `ChannelPresenter` + `SocketHelper.typingChannelV2`）。
//
// 收：服务端广播 `client.channel.typing_v2`，载荷是
//   `{"channel_id": N, "0": [userId, ...]}`（`TypingVo`：typing 状态挂在 "0" 键下）
//   老协议 `client.channel.typing` 是 `{"<channelId>": [userId, ...]}` 的 map。
//   两种情况都要**把自己剔除**（原版 `queryMembers` 前先 remove 自己）。
// 发：见 [ChatSessionController.typing] —— 10 秒内只发一次，且 10 秒后自动 clear。
//
// 原版没有接收侧的过期计时器（完全依赖服务端那条空列表事件）；这里多兜一层
// TTL，避免丢事件之后"正在输入"永远挂着 —— 这是**有意的偏离**，写在
// docs/phase4-protocol.md 里。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 频道 id → 正在输入的用户 id（不含自己）
class TypingState extends Notifier<Map<int, List<int>>> {
  final _timers = <int, Timer>{};

  /// 收不到"停止输入"时最多显示多久
  static const Duration ttl = Duration(seconds: 12);

  @override
  Map<int, List<int>> build() {
    ref.onDispose(() {
      for (final t in _timers.values) {
        t.cancel();
      }
      _timers.clear();
    });
    return const {};
  }

  /// `client.channel.typing_v2`：`{channel_id, "0": [ids]}`
  void applyV2(Map<String, dynamic> payload, {required int myUserId}) {
    final channelId = _int(payload['channel_id']);
    if (channelId <= 0) return;
    _apply(channelId, payload['0'], myUserId: myUserId);
  }

  /// 老协议 `client.channel.typing`：`{"<channelId>": [ids]}`
  void applyV1(Map<String, dynamic> payload, {required int myUserId}) {
    for (final e in payload.entries) {
      final channelId = _int(e.key);
      if (channelId <= 0) continue;
      _apply(channelId, e.value, myUserId: myUserId);
    }
  }

  void _apply(int channelId, Object? raw, {required int myUserId}) {
    final ids = raw is List
        ? raw
              .map(_int)
              .where((id) => id > 0 && id != myUserId)
              .toList(growable: false)
        : const <int>[];
    _timers.remove(channelId)?.cancel();
    if (ids.isEmpty) {
      if (state.containsKey(channelId)) {
        final next = Map<int, List<int>>.from(state)..remove(channelId);
        state = next;
      }
      return;
    }
    state = Map<int, List<int>>.from(state)..[channelId] = ids;
    _timers[channelId] = Timer(ttl, () => clear(channelId));
  }

  /// 手动清（离开频道 / 发完消息 / 断开连接时用）
  void clear([int? channelId]) {
    if (channelId == null) {
      for (final t in _timers.values) {
        t.cancel();
      }
      _timers.clear();
      if (state.isNotEmpty) state = const {};
      return;
    }
    _timers.remove(channelId)?.cancel();
    if (state.containsKey(channelId)) {
      state = Map<int, List<int>>.from(state)..remove(channelId);
    }
  }

  /// 离线测试用：不做 TTL 只写状态？不需要 —— 直接把 [ttl] 当真实时长即可。
  static int _int(Object? v) {
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }
}

final typingProvider = NotifierProvider<TypingState, Map<int, List<int>>>(
  TypingState.new,
);

/// 某个频道正在输入的用户 id（空列表 = 没人）
final typingUsersProvider = Provider.family<List<int>, int>(
  (ref, channelId) => ref.watch(typingProvider)[channelId] ?? const [],
);
