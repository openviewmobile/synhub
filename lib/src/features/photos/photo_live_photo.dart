// 实况照片（Live Photo）/ 动态照片（Motion Photo）—— P13。
//
// ## 服务端到底给了什么（逐字取证，**不猜**）
//
// 有**两条完全不同的通路**，官方自己也是分开实现的（APK 2.4.0-644，jadx）：
//
// ### 1. Motion Photo（`type == "motion_photo"`）—— 静图与短视频**在同一条目里**
//    * 配对信息 = `additional.motion_photo`，形态是**对象**（`video_meta` 形状）：
//      `ImageTableAdditional.java:43-44`
//      ```java
//      @SerializedName(ApiBrowseItem.ADDITIONAL_MOTION_PHOTO)
//      private ImageTableVideoMeta motionPhoto;
//      ```
//    * 取短视频字节：`ConnectionManager.composeVideoPlayInfo:8441-8458` 造的是
//      ```java
//      api=SYNO.Foto.Streaming&version=<min(server,2)>&method=streaming
//        &id=<unitId>&quality="motion_photo"&type="item"&_sid=…
//      ```
//      （`:8445-8446` 明确：`quality == motion_photo` 时才 `type="item"`，否则 `"unit"`）
//      `getMotionPhotoVideoUri:8354-8438` 在 `additional.motion_photo` 为空时
//      **直接返回 `Uri.EMPTY`** —— 所以"有没有短视频"的判据就是这个键在不在。
//    * 官方 Web 前端**完全一致**（`react_bundle.js`）：
//      `{videoMeta: r.getIn(["additional","motion_photo"]).toJS(),
//        quality: "motion_photo", videoConvertStatus: Ready}` →
//      `i_({id, type, quality: "motion_photo", …})`。
//
//    ⇒ **不需要在客户端把两个条目拼起来**：静图是条目本身，视频走同一 item id 的
//      `Streaming(quality=motion_photo)`。
//
// ### 2. Live Photo（`type == "live"` + `live_type`）—— 是**一组条目**
//    * `ImageTable.LiveType`（`ImageTable.java:1469-1471`）：
//      `PHOTO:"photo"` / `VIDEO:"video"` / `LIVE:"live"`。
//    * 官方按 **unit 分组**，在组里找 `live_type == "video"` 的那个成员当短视频：
//      `ConnectionManager.getLiveVideoUnitUri:8796-8873`（匹配
//      `ImageType.VIDEO.getStringValue()`），字节走
//      `SYNO.Foto.Download&method=download&unit_id=[…]`；静图侧
//      `getLivePhotoUri:8711-8788` 匹配 `PHOTO` → `item_id=[…]`。
//      官方 Web 也是同一个判据：`e.find(e => e.get("live_type") === M6.VIDEO)`。
//
// ## 本仓怎么落地（**如实标注**）
//   * Motion Photo：**服务端给了配对信息**，直接照官方走
//     `Streaming(quality=motion_photo, type=item)`。**不编造配对。**
//   * Live Photo：配对键 `live_type` 有，但本仓没有 `Browse.Unit` 分组链路，
//     所以**在客户端配对**（任务允许的形态）：在**同一批条目**里找
//     `live_type == "video"` 的成员，按"同目录 + 拍摄时间最近 + 文件名主干相同"
//     排序取最优。这是**客户端启发式**，判据全部写在下面对应函数的注释里，
//     也不假装它是服务端分组。
import 'package:flutter/material.dart';

import '../../data/dto/foto_dto.dart';
import '../media/media_player_view.dart';
import '../media/media_source.dart';
import 'photo_media_text.dart';

/// 客户端配对 Live Photo 的**拍摄时间容差**（秒）。
///
/// 同一张实况照片拆出来的两个条目，拍摄时间由同一台设备写入，通常**逐秒相同**；
/// 给 2 秒余量是为了容忍索引器取整差异。**不是取证值**，是保守上限。
const int kFotoLivePairingTimeToleranceSeconds = 2;

/// 播放开关距离舞台底边的**默认**留白（没有宿主常驻控件时用这个）。
const double kLivePhotoControlsDefaultInset = 12;

/// 在 [items] 里给一张实况照片静图找**配对的那段短视频**（客户端启发式）。
///
/// 判据（按优先级，全部基于服务端真实给到的字段）：
///   1. 候选必须是 `live_type == "video"`（官方 Web/APK 的同一判据）；
///   2. 同一个 `folder_id`（非空时才算这一条）—— 不同目录不该配在一起；
///   3. `|候选.time - 静图.time| <= [kFotoLivePairingTimeToleranceSeconds]`；
///   4. 打分排序：**文件名主干相同**（`IMG_1.JPG` ↔ `IMG_1.MOV`）优先，
///      然后拍摄时间差更小优先。
///
/// 返回 `null` = 没配上（界面**必须**据此说明"短视频不可用"，不许假装能播）。
FotoItemDto? pairLivePhotoVideo(FotoItemDto still, List<FotoItemDto> items) {
  FotoItemDto? best;
  var bestScore = -1;
  final stillStem = _filenameStem(still.filename);
  for (final cand in items) {
    if (identical(cand, still) || cand.id == still.id) continue;
    if (!cand.isLiveVideoMember) continue;
    if (still.folderId.isNotEmpty &&
        cand.folderId.isNotEmpty &&
        cand.folderId != still.folderId) {
      continue;
    }
    final delta = (cand.time - still.time).abs();
    if (delta > kFotoLivePairingTimeToleranceSeconds) continue;
    var score = 100 - delta; // 时间越近越高
    if (stillStem.isNotEmpty && _filenameStem(cand.filename) == stillStem) {
      score += 1000; // 主干相同 = 几乎确定
    }
    if (score > bestScore) {
      bestScore = score;
      best = cand;
    }
  }
  return best;
}

String _filenameStem(String name) {
  final dot = name.lastIndexOf('.');
  final stem = dot <= 0 ? name : name.substring(0, dot);
  return stem.toLowerCase();
}

/// 「这条能播实况短视频吗」的**纯判定**（便于离线断言）。
///
/// 返回的 [LivePhotoPlayback] 里：
///   * [LivePhotoPlayback.streamingQuality] 非 null → 走
///     `Streaming(id=<item id>, type="item", quality="motion_photo")`；
///   * [LivePhotoPlayback.pairedVideoItemId] 非 null → 走配对出的视频条目；
///   * 两者都为 null → **不可播**，界面必须如实说明。
class LivePhotoPlayback {
  const LivePhotoPlayback({
    this.streamingQuality,
    this.pairedVideoItemId,
    this.pairedVideoItem,
  });

  /// `Streaming` 的 `quality`（动态照片恒为 `'motion_photo'`）。
  final String? streamingQuality;

  /// 配对出的短视频条目 id（Live Photo 分组）。
  final String? pairedVideoItemId;

  /// 配对出的短视频条目（界面侧要拿它的文件名/体积）。
  final FotoItemDto? pairedVideoItem;

  bool get available =>
      streamingQuality != null || (pairedVideoItemId ?? '').isNotEmpty;

  /// 服务端只给了配对信息、需要客户端配对的那条路。
  static const LivePhotoPlayback unavailable = LivePhotoPlayback();

  @override
  String toString() =>
      'LivePhotoPlayback(streamingQuality: $streamingQuality, '
      'pairedVideoItemId: $pairedVideoItemId)';
}

/// 解析一条实况/动态照片的播放素材。
///
/// * `type == "motion_photo"` **且**服务端给了 `additional.motion_photo`
///   → [LivePhotoPlayback.streamingQuality] = `'motion_photo'`（官方 `getMotionPhotoVideoUri`
///   的非空分支）；**键缺失 → 不可播**（官方在那里返回 `Uri.EMPTY`）。
/// * `type == "live"` → 在 [items] 里客户端配对（判据见 [pairLivePhotoVideo]）。
LivePhotoPlayback resolveLivePhotoPlayback(
  FotoItemDto item, {
  List<FotoItemDto> items = const [],
}) {
  if (item.isMotionPhoto) {
    if (item.hasMotionPhotoVideo) {
      return const LivePhotoPlayback(streamingQuality: 'motion_photo');
    }
    return LivePhotoPlayback.unavailable;
  }
  if (item.isLivePhoto) {
    final paired = pairLivePhotoVideo(item, items);
    if (paired == null) return LivePhotoPlayback.unavailable;
    return LivePhotoPlayback(
      pairedVideoItemId: paired.id,
      pairedVideoItem: paired,
    );
  }
  return LivePhotoPlayback.unavailable;
}

/// 实况照片舞台：静图 + 可选的内嵌短视频层 + LIVE 徽标 / 播放开关。
///
/// 行为（**离线用例断言的正是这些**）：
///   * `playing == false` → 只渲染 [still]，不存在 `photo-live-video-layer`；
///   * `playing == true` 且素材可用 → **视频层出现**（`photo-live-video-layer`），
///     里头是既有的内嵌播放器 [MediaPlayerView]（复用，不另造播放器）；
///   * `playing == true` 但素材不可用 → 出现 `photo-live-unavailable` 说明层
///     （**不做假动画**冒充能播）。
class LivePhotoStage extends StatelessWidget {
  const LivePhotoStage({
    super.key,
    required this.item,
    required this.still,
    required this.playback,
    required this.videoSource,
    required this.playing,
    required this.onToggle,
    this.playingLabel,
    this.controlsBottomInset = kLivePhotoControlsDefaultInset,
  });

  final FotoItemDto item;

  /// 静图那一层（调用方给，通常是既有的大图组件）。
  final Widget still;

  /// 播放素材判定（[resolveLivePhotoPlayback] 的结果）。
  final LivePhotoPlayback playback;

  /// 实际交给播放器的媒体源；`null` = 还没解析出来 / 不可用。
  final MediaSource? videoSource;

  final bool playing;

  /// 点按 / 长按的开关（官方：`onClick` 播放、`onLongClick` 播放、`onTouchUp` 停止）。
  final VoidCallback onToggle;

  /// 播放态文案（自定义，默认用「实况照片」）。
  final String? playingLabel;

  /// 右下角播放开关距离舞台底边的留白（含按钮自身的 48 逻辑像素半高）。
  ///
  /// **为什么必须是参数**：宿主页面右下角可能还停着它**自己的**常驻控件，
  /// 而这类控件（[Scaffold] 的 `floatingActionButton`）是由 Scaffold **画在
  /// body 之上**并优先命中手势的 —— 舞台自己再多画一层也没用。
  /// 查看器正是这种情况：默认 `bottom: 12` 的开关中心落在 `(1164, 2364)`，
  /// 而「收藏」FAB 实测占 `LTRB(1128, 2328, 1184, 2384)`（56×56 + 16 外边距）
  /// ⇒ 整颗按钮被 FAB 完全压住（真机上同样点不到，不是测试假象）。
  /// 宿主把这个占位高度传进来，开关就抬到它上面（查看器传的是
  /// `kPhotoViewerLiveControlsInset`）。
  final double controlsBottomInset;

  bool get _canPlay => playback.available;

  @override
  Widget build(BuildContext context) {
    final badge = item.isMotionPhoto
        ? photoMedia(PhotoMediaTextKeys.motionBadge, '动态照片')
        : photoMedia(PhotoMediaTextKeys.liveBadge, '实况照片');
    return Stack(
      key: const Key('photo-live-stage'),
      fit: StackFit.expand,
      children: [
        still,
        if (playing && videoSource != null && videoSource!.playable)
          Positioned.fill(
            key: const Key('photo-live-video-layer'),
            child: MediaPlayerView(
              key: const Key('photo-live-player'),
              source: videoSource!,
              autoPlay: true,
              // 短视频跟静图同一块画布：不给全屏按钮，避免和查看器的
              // 手势 / 翻页打架（官方也是原地播放、松手即停）。
              showFullscreenButton: false,
            ),
          )
        else if (playing)
          Positioned.fill(
            key: const Key('photo-live-unavailable'),
            child: ColoredBox(
              color: Colors.black87,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    photoMedia(
                      PhotoMediaTextKeys.liveUnavailable,
                      '这段实况短视频不可用（服务端没有给出可播放的视频）。',
                    ),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          left: 12,
          top: 12,
          child: IgnorePointer(
            child: Container(
              key: const Key('photo-live-badge'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                playing ? (playingLabel ?? badge) : badge,
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          ),
        ),
        Positioned(
          right: 12,
          bottom: controlsBottomInset,
          child: GestureDetector(
            // 长按 = 播放（官方 `onLongClick` → `playLivePhoto()`）。
            onLongPress: _canPlay ? onToggle : null,
            child: IconButton(
              key: const Key('photo-live-toggle'),
              onPressed: _canPlay ? onToggle : null,
              tooltip: playing
                  ? photoMedia(PhotoMediaTextKeys.liveStopTooltip, '停止实况播放')
                  : photoMedia(
                      PhotoMediaTextKeys.livePlayTooltip,
                      '播放实况短视频',
                    ),
              icon: Icon(
                playing
                    ? Icons.stop_circle_outlined
                    : Icons.play_circle_outline,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
