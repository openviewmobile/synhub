// r653（`DA257`）：点通知栏的媒体卡 → **回到"正在播放"那一屏**。
//
// 真机证据（`docs/evidence-r653/07_tap_notification_from_chat.png`）：
// 用户在 Chat 里，点一下通知栏的卡片，App 回来还停在 Chat —— 音乐 App 的通行预期
// 是"点媒体卡 = 打开播放器"（Plexamp / Apple Music / Spotify 全是这样）。
//
// 原生侧（`MediaNotificationTapBridge.kt`）已把那次点击认出来：系统发来的 intent
// action 是 `com.ryanheise.audioservice.NOTIFICATION_CLICK`（`logcat` 的
// `ActivityTaskManager: START u0` 逐字为证），与"点桌面图标"（`ACTION_MAIN`）
// 可区分。这里只做落点：电台进播放面板、歌曲进单曲页，**与迷你条同一个入口**
// （`openNowPlaying`）。
//
// 三条纪律：
//   * **只认"正在播"**：`processingState == idle` 或没有 `mediaItem` 时什么都不做
//     （不能凭空给用户打开一个空播放页）；
//   * **冷启动要等**：`getPending` 可能在 `AudioService` 连上之前就到了 ⇒
//     有界轮询等 `mediaItem`（最多 ~3s），等不到就放弃，**不无限等**；
//   * **幂等**：`getPending` 与 `onMediaNotificationTap` 两条路都可能到，
//     用 `_busy` 去重，一次点击只跳一次。
import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../media/audio_handler.dart';
import 'audio_now_playing_route.dart';

/// 原生通道名（与 `MediaNotificationTapBridge.kt` 的 `CHANNEL` 逐字一致）。
const String kMediaNotificationTapChannel = 'synhub/media_notification_tap';

/// 冷启动时等 `AudioService` 连上的上限（20 × 150ms ≈ 3s）。
const int kMediaNotificationTapWaitTries = 20;
const Duration kMediaNotificationTapWaitStep = Duration(milliseconds: 150);

class MediaNotificationTapHost extends ConsumerStatefulWidget {
  const MediaNotificationTapHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<MediaNotificationTapHost> createState() =>
      _MediaNotificationTapHostState();
}

class _MediaNotificationTapHostState
    extends ConsumerState<MediaNotificationTapHost> {
  // gate-exempt: media-notification-tap —— 这条通道传的是「Android 媒体通知被
  // 点了一下」这件事；非 Android 宿主上没有媒体通知（定义域外），
  // 且下面所有调用都 try/catch 兜住 MissingPluginException。
  static const MethodChannel _channel = MethodChannel(
    kMediaNotificationTapChannel,
  );

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_onCall);
    unawaited(_drainPending());
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'onMediaNotificationTap') {
      // ★ 不 await：`_openNowPlaying` 里有"等音频服务连上"的有界延时，
      //   而通道回调是在**平台的调用帧**里跑的 —— await 它会让原生侧一直等，
      //   也让 fake-async 的用例死锁（r653 用例当场挂过两次）。
      unawaited(_openNowPlaying());
    }
    return null;
  }

  /// 冷启动兜底：`attach()` 之前到的 intent 存在原生侧，这里取走即清。
  // gate-exempt: media-notification-tap （同上，见 `_channel` 处理由）
  Future<void> _drainPending() async {
    try {
      final pending = await _channel.invokeMethod<bool>('getPending');
      if (pending == true) unawaited(_openNowPlaying());
    } catch (_) {
      // 通道不可用（非 Android / 引擎没起）：不做事，也绝不抛到 zone 外
    }
  }

  Future<void> _openNowPlaying() async {
    if (!mounted || _busy) return;
    final handler = ref.read(audioHandlerProvider);
    // 等"真的在播"：冷启动时音频服务可能晚一拍连上（`mediaItem` 先为 null），
    // 而 `playbackState` 永远有值（`BaseAudioHandler` 的初值就是 idle），
    // 所以判据是 **`mediaItem != null` 且 `processingState != idle`**。
    MediaItem? target;
    for (var i = 0; i < kMediaNotificationTapWaitTries; i++) {
      target = handler.mediaItem.value;
      final idle =
          handler.playbackState.value.processingState ==
          AudioProcessingState.idle;
      if (target != null && !idle) break;
      await Future<void>.delayed(kMediaNotificationTapWaitStep);
      if (!mounted) return;
    }
    final item = target;
    // 等不到就不跳 —— 不能凭空给用户打开一个空播放页
    if (item == null ||
        handler.playbackState.value.processingState ==
            AudioProcessingState.idle) {
      return;
    }
    _busy = true;
    try {
      await openNowPlaying(context, item: item);
    } catch (_) {
      // 页面打不开（守卫已卸载等极端情况）不许把异常抛进 zone
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
