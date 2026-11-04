// 「这条电台刚刚没播出来」—— **跨页面/面板共享的失败态**（r641 / `DA234`）。
//
// 为什么需要一个 provider，而不是页面里一个 bool：
// 失败提示条画在**页面**的 `Scaffold` 上，而播放器面板是 `Navigator` 的弹层。
// 真机上用户只看见面板，提示条在它下面（或被播放条盖住）⇒ 面板必须能**读到**
// 同一个失败事实，否则"失败后打开面板"看到的还是一条一切正常的界面。
//
// 口径（与 r631/r640 一致）：
//   * 只记 **`MediaItem.id`**（不记 DTO、不记 URL）—— 界面按 id 比对，
//     不会把 A 电台的失败挂到 B 上；
//   * 只存**最近一次**失败（多存没有意义，用户只会看当前这条）；
//   * 新的起播请求 / 重试 / 关闭播放 ⇒ 立刻清空（不许"边说没播边出声"）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 最近一次"起播失败"的条目 id（`null` = 当前没有失败）。
class RadioPlaybackFailureController extends Notifier<String?> {
  @override
  String? build() => null;

  /// 记下"这条没播出来"。
  void mark(String mediaId) {
    if (mediaId.isEmpty) return;
    if (state != mediaId) state = mediaId;
  }

  /// 清空（新的起播请求 / 重试 / 停止播放 / 关闭播放条都该调它）。
  void clear() {
    if (state != null) state = null;
  }

  /// 这条是不是刚失败的那条。
  bool isFailed(String? mediaId) => mediaId != null && state == mediaId;
}

final radioPlaybackFailureProvider =
    NotifierProvider<RadioPlaybackFailureController, String?>(
      RadioPlaybackFailureController.new,
    );
