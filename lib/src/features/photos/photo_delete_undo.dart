// 相册**删除后撤销**：延迟删除的状态机（P29）。
//
// 官方证据（`photo-parity-audit.md:151`）：
//   * `string/str_undo_success=1 item restored`、`str_undo_success_plurals`；
//   * 服务端 API **不适用** —— 官方是"**延迟删除** + Snackbar 撤销"
//     （`parity-recount-drive-photos.md:294` 明确按"延迟删除"实现）。
//
// 为什么必须是**延迟删除**而不是"删完再还原"：`SYNO.Foto` 全表**没有回收站
// 还原 API**（P63 的取证结论：官方 Foto 无 `RecycleBin` 方法），所以"恢复"在
// 服务端根本做不到。官方那句 `1 item restored` 在 Foto 里只能是"请求还没发出去"。
//
// 语义：
//   1. 用户确认删除 → **先不发请求**，开一个 [photoDeleteGraceProvider] 的撤销窗口；
//   2. 窗口内点"撤销" → 定时器取消，**一个字节都不发给 NAS**；
//   3. 窗口到点 → 才真正发 `Browse.Item/delete` v7（走既有
//      `photoDeleteActionsProvider`，成功即 invalidate 各列表）。
//
// 纯逻辑都在本文件；界面在 `photo_widgets.dart` 的 `PhotoSelectionBar`。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'photo_providers.dart';

/// 撤销窗口时长（界面上的 Snackbar 也用它）。
///
/// 测试覆盖成很短的值即可（`overrideWithValue`），不用等 5 秒。
final photoDeleteGraceProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 5),
);

/// 一次延迟删除的结局。
class PhotoDeleteUndoResult {
  const PhotoDeleteUndoResult({
    required this.ids,
    this.undone = false,
    this.failed = const [],
    this.error,
  });

  /// 本次涉及的条目 id。
  final List<String> ids;

  /// true = 用户在窗口内撤销了（**没有发删除请求**）。
  final bool undone;

  /// 真正删除后失败的 id（空 = 全成功）。
  final List<String> failed;

  /// 删除请求整体抛出的异常（会话过期 / 网络）；为 null 表示请求发出并返回。
  final Object? error;

  int get deletedCount => undone ? 0 : ids.length - failed.length;
}

/// 延迟删除状态（当前是否有未决的撤销窗口）。
final photoDeleteUndoProvider =
    NotifierProvider<PhotoDeleteUndoNotifier, List<String>>(
      PhotoDeleteUndoNotifier.new,
    );

class PhotoDeleteUndoNotifier extends Notifier<List<String>> {
  Timer? _timer;
  Completer<PhotoDeleteUndoResult>? _pending;

  @override
  List<String> build() {
    ref.onDispose(() {
      // 容器销毁（App 退出）时**不再发网络请求**：取消定时器并把未决的窗口
      // 如实标成"没有删除"（一个字节都没发过）。
      _timer?.cancel();
      _timer = null;
      final p = _pending;
      if (p != null && !p.isCompleted) {
        _pending = null;
        p.complete(PhotoDeleteUndoResult(ids: state, undone: true));
      }
    });
    return const [];
  }

  bool get isPending => state.isNotEmpty;

  /// 开一个撤销窗口。返回的 Future 在"真删完"或"被撤销"后完成。
  ///
  /// 空 [ids] → 立刻返回一个 `undone` 的结果（调用方无需特判）。
  Future<PhotoDeleteUndoResult> begin(List<String> ids) {
    final clean = [
      for (final e in ids)
        if (e.isNotEmpty) e,
    ];
    if (clean.isEmpty) {
      return Future<PhotoDeleteUndoResult>.value(
        const PhotoDeleteUndoResult(ids: [], undone: true),
      );
    }
    // 上一个窗口还没结束就再来一次 → 先把上一个立刻提交（不丢删除）
    final prev = _pending;
    if (prev != null && !prev.isCompleted) {
      _timer?.cancel();
      final prevIds = state;
      _pending = null;
      unawaited(_commit(prevIds, prev));
    }
    final completer = Completer<PhotoDeleteUndoResult>();
    _pending = completer;
    state = clean;
    _timer = Timer(ref.read(photoDeleteGraceProvider), () {
      _timer = null;
      final p = _pending;
      _pending = null;
      if (p != null && !p.isCompleted) {
        state = const [];
        unawaited(_commit(clean, p));
      }
    });
    return completer.future;
  }

  /// 窗口内撤销：取消定时器，**不发任何请求**。
  bool undo() {
    final p = _pending;
    if (p == null || p.isCompleted) return false;
    _timer?.cancel();
    _timer = null;
    _pending = null;
    final ids = state;
    state = const [];
    p.complete(PhotoDeleteUndoResult(ids: ids, undone: true));
    return true;
  }

  Future<void> _commit(
    List<String> ids,
    Completer<PhotoDeleteUndoResult> completer,
  ) async {
    if (completer.isCompleted) return;
    List<String> failed;
    Object? error;
    try {
      failed = await ref.read(photoDeleteActionsProvider).delete(ids);
    } catch (err) {
      // 异常（会话过期 / 网络）→ 全部算失败；调用方拿到结构化结果后自行决定
      // 文案（用 [PhotoDeleteUndoResult.error] 走 `describePhotoError`）。
      failed = ids;
      error = err;
    }
    if (!completer.isCompleted) {
      completer.complete(
        PhotoDeleteUndoResult(ids: ids, failed: failed, error: error),
      );
    }
  }
}
