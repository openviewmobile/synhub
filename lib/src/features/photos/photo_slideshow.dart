// 相册**幻灯片播放**：设置 + 顺序算法（P49）。
//
// 官方证据（`photo-parity-audit.md:171`）：
//   * `str_slideshow`、`str_slideshow_settings`、`str_slideshow_speed`、
//     `str_slideshow_play_order=Shuffle`、`id/action_slideshow`；
//   * 服务端 API **不适用** —— 纯客户端；图片来源就是已经取到的
//     `Download/download` / `Thumbnail/get` 字节。
//
// 本文件是**纯逻辑层**（可单测）：
//   * [PhotoSlideshowOrder]（顺序 / 随机）；
//   * 播放间隔档位（秒）；
//   * [slideshowSequence] —— 给定条目数与顺序模式生成播放下标序列
//     （随机用**固定种子**，便于测试与"可复现的随机"）；
//   * 设置落盘（走 [photoPrefsStoreProvider]）。
//
// 播放循环本身在 `photo_viewer_page.dart`（页面层）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'photo_prefs_store.dart';

/// 播放顺序（官方 `str_slideshow_play_order=Shuffle`）。
enum PhotoSlideshowOrder {
  sequential('sequential'),
  shuffle('shuffle');

  const PhotoSlideshowOrder(this.wire);

  /// 落盘字面量（改这个字符串会让用户旧选择读不回来）。
  final String wire;

  static PhotoSlideshowOrder fromWire(Object? raw) =>
      raw == shuffle.wire ? shuffle : sequential;
}

/// 官方 `str_slideshow_speed` 的档位（秒）。
const List<int> kPhotoSlideshowSeconds = <int>[3, 5, 10, 15];

/// 默认 5 秒（官方默认档）。
const int kPhotoSlideshowDefaultSeconds = 5;

/// 随机模式的可复现种子：同一次"开始幻灯片"内一致，重开一次换一个。
const int kPhotoSlideshowShuffleSeed = 20260922;

/// 生成播放下标序列。
///
/// [indices] 是**可播条目**在 viewer 列表里的下标（视频等不参与幻灯片的项
/// 已经被调用方剔除）。[seed] 只在 [order] 是随机时使用。
List<int> slideshowSequence(
  List<int> indices, {
  PhotoSlideshowOrder order = PhotoSlideshowOrder.sequential,
  int seed = kPhotoSlideshowShuffleSeed,
}) {
  if (order == PhotoSlideshowOrder.sequential) return List<int>.of(indices);
  final out = List<int>.of(indices);
  out.shuffle(Random(seed));
  return out;
}

/// 幻灯片设置（不可变）。
class PhotoSlideshowSettings {
  const PhotoSlideshowSettings({
    this.seconds = kPhotoSlideshowDefaultSeconds,
    this.order = PhotoSlideshowOrder.sequential,
  });

  /// 每张停留秒数（必须在 [kPhotoSlideshowSeconds] 里，读坏时收敛到默认）。
  final int seconds;
  final PhotoSlideshowOrder order;

  Duration get interval => Duration(seconds: seconds);

  PhotoSlideshowSettings copyWith({int? seconds, PhotoSlideshowOrder? order}) =>
      PhotoSlideshowSettings(
        seconds: normalizeSlideshowSeconds(seconds ?? this.seconds),
        order: order ?? this.order,
      );

  Map<String, dynamic> toJson() => {'seconds': seconds, 'order': order.wire};

  String encode() => jsonEncode(toJson());

  static PhotoSlideshowSettings parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const PhotoSlideshowSettings();
    }
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return const PhotoSlideshowSettings();
      final s = m['seconds'];
      return PhotoSlideshowSettings(
        seconds: normalizeSlideshowSeconds(
          s is num ? s.toInt() : int.tryParse('${s ?? ''}'),
        ),
        order: PhotoSlideshowOrder.fromWire(m['order']),
      );
    } catch (_) {
      return const PhotoSlideshowSettings();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PhotoSlideshowSettings &&
      other.seconds == seconds &&
      other.order == order;

  @override
  int get hashCode => Object.hash(seconds, order);
}

/// 把任意输入收敛到最近的合法秒档（认不出 → 默认 5 秒）。
int normalizeSlideshowSeconds(Object? raw) {
  final n = raw is int ? raw : int.tryParse('${raw ?? ''}');
  if (n == null) return kPhotoSlideshowDefaultSeconds;
  if (kPhotoSlideshowSeconds.contains(n)) return n;
  var best = kPhotoSlideshowSeconds.first;
  for (final s in kPhotoSlideshowSeconds) {
    if ((s - n).abs() < (best - n).abs()) best = s;
  }
  return best;
}

/// 幻灯片设置（落盘：`photo_slideshow_settings_v1`）。
final photoSlideshowSettingsProvider =
    NotifierProvider<PhotoSlideshowSettingsNotifier, PhotoSlideshowSettings>(
      PhotoSlideshowSettingsNotifier.new,
    );

class PhotoSlideshowSettingsNotifier extends Notifier<PhotoSlideshowSettings> {
  /// 用户是否已经改过（改过之后异步恢复不许把新设置冲掉）。
  bool _touched = false;

  @override
  PhotoSlideshowSettings build() {
    unawaited(_restore());
    return const PhotoSlideshowSettings();
  }

  Future<void> _restore() async {
    final raw = await ref
        .read(photoPrefsStoreProvider)
        .read(kPhotoSlideshowSettingsSlot);
    if (!ref.mounted || _touched) return;
    final restored = PhotoSlideshowSettings.parse(raw);
    if (restored != state) state = restored;
  }

  Future<void> _update(PhotoSlideshowSettings next) async {
    _touched = true;
    state = next;
    await ref
        .read(photoPrefsStoreProvider)
        .write(kPhotoSlideshowSettingsSlot, next.encode());
  }

  Future<void> setSeconds(int seconds) =>
      _update(state.copyWith(seconds: normalizeSlideshowSeconds(seconds)));

  Future<void> setOrder(PhotoSlideshowOrder order) =>
      _update(state.copyWith(order: order));
}
