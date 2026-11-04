// P13 · 实况照片 / 动态照片 —— 接口层 + 页面层离线用例。
//
// 两条通路（逐字证据见 `photo_live_photo.dart` 文件头）：
//   * **动态照片** `type == "motion_photo"`：静图与短视频**同一条目**，视频走
//     `SYNO.Foto.Streaming&method=streaming&id=<item id>&type=item&quality=motion_photo`
//     （官方 `composeVideoPlayInfo:8445-8446`：`quality==motion_photo` 才 `type=item`）；
//     判据 = `additional.motion_photo` 这个键在不在（官方那里为空就返回 `Uri.EMPTY`）。
//   * **实况照片** `type == "live"` + `live_type`：服务端给的是**配对信息**，
//     本仓没有 unit 分组链路 → 在客户端按 `live_type == "video"` 配对
//     （任务书明确允许："若服务端只给了配对信息，就在客户端配对"）。
//
// 断言的是**具体行为**：URL 的查询参数、配对选中的是哪一条、播放时视频层出现、
// 不可播时给的是说明而不是假动画。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/foto_media_kinds.dart';
import 'package:synhub/src/features/media/media_player_view.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/photos/photo_live_photo.dart';
import 'package:synhub/src/features/photos/photo_viewer_page.dart';

import 'photo_media_harness.dart';

/// 一张普通照片条目 + `live_type`。
FotoItemDto liveMember(
  String id,
  String role, {
  int time = 0,
  String folder = '10',
}) => FotoItemDto.fromJson(
  photoMediaItem(
    id,
    type: 'live',
    liveType: role,
    time: time,
    folderId: folder,
    filename: role == 'video' ? 'IMG_$id.mov' : 'IMG_$id.jpg',
  ),
);

void main() {
  group('① 类型识别：motion_photo / live（官方 ImageType）', () {
    test('motion_photo 认成动态照片，且是**静图**（不是 video 条目）', () {
      final item = FotoItemDto.fromJson(
        photoMediaItem(
          '1',
          type: 'motion_photo',
          motionPhoto: motionPhotoMeta(),
        ),
      );
      expect(item.isMotionPhoto, isTrue);
      expect(item.isVideo, isFalse);
      expect(item.isLiveOrMotion, isTrue);
      expect(item.hasMotionPhotoVideo, isTrue);
    });

    test('live 条目按 live_type 分角色（官方 LiveType: photo/video/live）', () {
      expect(liveMember('1', 'photo').isLivePhoto, isTrue);
      expect(liveMember('1', 'photo').isLiveVideoMember, isFalse);
      expect(liveMember('2', 'video').isLiveVideoMember, isTrue);
      // `live_type == "video"` 的成员本身就是一段视频
      expect(liveMember('2', 'video').isVideo, isTrue);
    });

    test('live_type 缺失 → 认不出角色（不当成"能播"）', () {
      final item = FotoItemDto.fromJson(photoMediaItem('1', type: 'live'));
      expect(item.liveTypeRole, FotoLiveType.none);
      expect(item.isLiveVideoMember, isFalse);
      // 官方 isLivePhoto() 要求 liveType.isLive()，缺了就不算实况照片
      expect(item.isLivePhoto, isFalse);
      expect(item.isLiveOrMotion, isFalse);
    });
  });

  group('② 客户端配对：live_type == "video" 的那一条', () {
    test('同一目录 + 拍摄时间相同 → 选中 video 成员（而不是 photo 成员）', () {
      final still = liveMember('1', 'photo', time: 1000);
      final items = [
        still,
        liveMember('2', 'video', time: 1000),
        // 另一张同名不同组：时间差太远 → 不选
        liveMember('3', 'video', time: 5000),
      ];
      final paired = pairLivePhotoVideo(still, items);
      expect(paired, isNotNull);
      expect(paired!.id, '2');
    });

    test('没有 video 成员 → null（界面必须据此说"不可用"）', () {
      final still = liveMember('1', 'photo', time: 1000);
      final paired = pairLivePhotoVideo(still, [
        still,
        liveMember('4', 'photo', time: 1000),
      ]);
      expect(paired, isNull);
    });

    test('超出时间容差 → 不配对（容差是 kFotoLivePairingTimeToleranceSeconds）', () {
      final still = liveMember('1', 'photo', time: 1000);
      final items = [
        still,
        liveMember(
          '2',
          'video',
          time: 1000 + kFotoLivePairingTimeToleranceSeconds + 1,
        ),
      ];
      expect(pairLivePhotoVideo(still, items), isNull);
      // 刚好在容差内 → 配得上
      final ok = [
        still,
        liveMember(
          '2',
          'video',
          time: 1000 + kFotoLivePairingTimeToleranceSeconds,
        ),
      ];
      expect(pairLivePhotoVideo(still, ok)?.id, '2');
    });

    test('不同目录不配（folder_id 不同 → 跳过）', () {
      final still = liveMember('1', 'photo', time: 1000, folder: '10');
      final items = [still, liveMember('2', 'video', time: 1000, folder: '99')];
      expect(pairLivePhotoVideo(still, items), isNull);
    });

    test('多条候选：文件名主干相同者胜出（IMG_9 ↔ IMG_9）', () {
      final still = FotoItemDto.fromJson(
        photoMediaItem(
          '1',
          type: 'live',
          liveType: 'photo',
          time: 1000,
          filename: 'IMG_9.jpg',
        ),
      );
      final closer = FotoItemDto.fromJson(
        photoMediaItem(
          '2',
          type: 'live',
          liveType: 'video',
          time: 1000,
          filename: 'IMG_8.mov',
        ),
      );
      final sameStem = FotoItemDto.fromJson(
        photoMediaItem(
          '3',
          type: 'live',
          liveType: 'video',
          time: 1001,
          filename: 'IMG_9.mov',
        ),
      );
      final paired = pairLivePhotoVideo(still, [still, closer, sameStem]);
      expect(paired!.id, '3');
    });

    test('不会把自己配给自己', () {
      final still = liveMember('1', 'video', time: 1000);
      expect(pairLivePhotoVideo(still, [still]), isNull);
    });
  });

  group('③ 播放素材判定：服务端没说能播就不许"假装能播"', () {
    test('动态照片 + additional 有 motion_photo → 走 Streaming 的 motion_photo 档', () {
      final item = FotoItemDto.fromJson(
        photoMediaItem(
          '1',
          type: 'motion_photo',
          motionPhoto: motionPhotoMeta(),
        ),
      );
      final pb = resolveLivePhotoPlayback(item);
      expect(pb.available, isTrue);
      expect(pb.streamingQuality, 'motion_photo');
      expect(pb.pairedVideoItemId, isNull);
    });

    test('动态照片但 additional **没有** motion_photo → 不可播', () {
      final item = FotoItemDto.fromJson(
        photoMediaItem('1', type: 'motion_photo'),
      );
      expect(resolveLivePhotoPlayback(item).available, isFalse);
    });

    test('实况照片 → 客户端配对出的视频条目 id', () {
      final still = liveMember('1', 'photo', time: 1000);
      final pb = resolveLivePhotoPlayback(
        still,
        items: [still, liveMember('2', 'video', time: 1000)],
      );
      expect(pb.available, isTrue);
      expect(pb.pairedVideoItemId, '2');
      expect(pb.streamingQuality, isNull);
    });

    test('实况照片但配不上 → 不可播', () {
      final still = liveMember('1', 'photo', time: 1000);
      expect(
        resolveLivePhotoPlayback(still, items: [still]).available,
        isFalse,
      );
    });

    test('普通照片 / 普通视频 → 永远不可播（不误伤）', () {
      final photo = FotoItemDto.fromJson(photoMediaItem('1', type: 'photo'));
      final video = FotoItemDto.fromJson(photoMediaItem('2', type: 'video'));
      expect(resolveLivePhotoPlayback(photo).available, isFalse);
      expect(resolveLivePhotoPlayback(video).available, isFalse);
    });
  });

  group('④ 接口层：取流直链的查询参数', () {
    test('streamingUrl：quality=motion_photo 且 type=item，id 是条目 id', () async {
      final r = await photoMediaApi();
      final url = r.api.streamingUrl(itemId: '9659', quality: 'motion_photo');
      final q = queryOf(url);
      expect(q['api'], 'SYNO.Foto.Streaming');
      expect(q['method'], 'streaming');
      expect(q['id'], '9659');
      expect(q['type'], kFotoStreamingTypeItem);
      expect(q['quality'], 'motion_photo');
      // 版本走协商（服务器给 v2）
      expect(q['version'], '2');
    });

    test('不带 quality 时**不出现** quality 参数（普通视频取流不受影响）', () async {
      final r = await photoMediaApi();
      final q = queryOf(r.api.streamingUrl(itemId: '1'));
      expect(q.containsKey('quality'), isFalse);
      expect(q['type'], 'item');
    });

    test(
      'resolvePhotosSource(streamingPrimary + motion_photo) → 可播且带对参数',
      () async {
        final r = await photoMediaApi();
        final source = resolvePhotosSource(
          displayName: 'IMG_1.jpg',
          kind: MediaKind.video,
          itemId: '9659',
          foto: r.api,
          streamingQuality: 'motion_photo',
          streamingPrimary: true,
        );
        expect(source.playable, isTrue);
        final q = queryOf(source.uri);
        expect(q['quality'], 'motion_photo');
        expect(q['type'], 'item');
        expect(q['id'], '9659');
        // Streaming 通道 Range 未取证 → 恒不可 seek（不能跟着 Download 一起打开）
        expect(source.supportsRange, isFalse);
      },
    );

    test('kFotoStreamingRangeProven 仍是 false（真机零字节证据）', () {
      expect(kFotoStreamingRangeProven, isFalse);
    });
  });

  group('⑤ LivePhotoStage：播放 → 视频层出现；不可播 → 说明层', () {
    Widget wrap(
      FotoItemDto item, {
      required LivePhotoPlayback playback,
      MediaSource? source,
      required bool playing,
      VoidCallback? onToggle,
    }) => Scaffold(
      body: LivePhotoStage(
        item: item,
        still: const ColoredBox(color: Colors.black),
        playback: playback,
        videoSource: source,
        playing: playing,
        onToggle: onToggle ?? () {},
      ),
    );

    testWidgets('① playing=false → 只有静图，**没有**视频层', (tester) async {
      final item = FotoItemDto.fromJson(
        photoMediaItem(
          '1',
          type: 'motion_photo',
          motionPhoto: motionPhotoMeta(),
        ),
      );
      await pumpPhotoMedia(
        tester,
        wrap(
          item,
          playback: const LivePhotoPlayback(streamingQuality: 'motion_photo'),
          playing: false,
        ),
      );
      expect(find.byKey(const Key('photo-live-stage')), findsOne);
      expect(find.byKey(const Key('photo-live-video-layer')), findsNothing);
      expect(find.byKey(const Key('photo-live-badge')), findsOne);
    });

    testWidgets('② playing=true 且素材可播 → **视频层出现**，里头是内嵌播放器', (tester) async {
      final r = await photoMediaApi();
      final source = resolvePhotosSource(
        displayName: 'IMG_1.jpg',
        kind: MediaKind.video,
        itemId: '9659',
        foto: r.api,
        streamingQuality: 'motion_photo',
        streamingPrimary: true,
      );
      final item = FotoItemDto.fromJson(
        photoMediaItem(
          '1',
          type: 'motion_photo',
          motionPhoto: motionPhotoMeta(),
        ),
      );
      await pumpPhotoMedia(
        tester,
        wrap(
          item,
          playback: const LivePhotoPlayback(streamingQuality: 'motion_photo'),
          source: source,
          playing: true,
        ),
      );
      expect(find.byKey(const Key('photo-live-video-layer')), findsOne);
      expect(find.byKey(const Key('photo-live-player')), findsOne);
      expect(find.byType(MediaPlayerView), findsOne);
      // 交给播放器的就是 motion_photo 那条流
      final player = tester.widget<MediaPlayerView>(
        find.byKey(const Key('photo-live-player')),
      );
      expect(queryOf(player.source.uri)['quality'], 'motion_photo');
      expect(queryOf(player.source.uri)['type'], 'item');
    });

    testWidgets('③ playing=true 但素材不可用 → 说明层，且播放按钮是**禁用**的', (tester) async {
      final item = FotoItemDto.fromJson(
        photoMediaItem('1', type: 'motion_photo'),
      );
      await pumpPhotoMedia(
        tester,
        wrap(item, playback: LivePhotoPlayback.unavailable, playing: true),
      );
      expect(find.byKey(const Key('photo-live-video-layer')), findsNothing);
      expect(find.byKey(const Key('photo-live-unavailable')), findsOne);
      final button = tester.widget<IconButton>(
        find.byKey(const Key('photo-live-toggle')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('④ 点播放按钮 → 回调触发（开关交给调用方）', (tester) async {
      final item = FotoItemDto.fromJson(
        photoMediaItem(
          '1',
          type: 'motion_photo',
          motionPhoto: motionPhotoMeta(),
        ),
      );
      var toggles = 0;
      await pumpPhotoMedia(
        tester,
        wrap(
          item,
          playback: const LivePhotoPlayback(streamingQuality: 'motion_photo'),
          playing: false,
          onToggle: () => toggles++,
        ),
      );
      await tester.tap(find.byKey(const Key('photo-live-toggle')));
      await settlePhotoMedia(tester);
      expect(toggles, 1);
    });
  });

  group('⑥ 查看器接线：LIVE 徽标 / 播放出层 / 翻页即停 / 不可播不进死路', () {
    testWidgets('① 动态照片 → 出现"动态照片"徽标 + 播放入口', (tester) async {
      final items = photoMediaItems([
        photoMediaItem(
          '1',
          type: 'motion_photo',
          filename: 'IMG_1.jpg',
          motionPhoto: motionPhotoMeta(),
        ),
      ]);
      await pumpPhotoMedia(tester, PhotoViewerPage(items: items));
      expect(find.byKey(const Key('photo-live-stage')), findsOne);
      expect(find.byKey(const Key('photo-live-badge')), findsOne);
      expect(find.text('动态照片'), findsOne);
      expect(find.byKey(const Key('photo-live-toggle')), findsOne);
      // 没点之前不能有视频层
      expect(find.byKey(const Key('photo-live-video-layer')), findsNothing);
    });

    testWidgets('② 点播放 → 视频层真的出现，且用的是 motion_photo 取流', (tester) async {
      final items = photoMediaItems([
        photoMediaItem(
          '1',
          type: 'motion_photo',
          filename: 'IMG_1.jpg',
          motionPhoto: motionPhotoMeta(),
        ),
      ]);
      await pumpPhotoMedia(tester, PhotoViewerPage(items: items));
      await tapPhotoMediaKey(tester, 'photo-live-toggle');
      expect(find.byKey(const Key('photo-live-video-layer')), findsOne);
      final player = tester.widget<MediaPlayerView>(
        find.byKey(const Key('photo-live-player')),
      );
      final q = queryOf(player.source.uri);
      expect(q['quality'], 'motion_photo');
      expect(q['type'], 'item');
      expect(q['id'], '1');
    });

    testWidgets('③ 再点一次 → 停止，视频层消失（回到静图）', (tester) async {
      final items = photoMediaItems([
        photoMediaItem(
          '1',
          type: 'motion_photo',
          filename: 'IMG_1.jpg',
          motionPhoto: motionPhotoMeta(),
        ),
      ]);
      await pumpPhotoMedia(tester, PhotoViewerPage(items: items));
      await tapPhotoMediaKey(tester, 'photo-live-toggle');
      expect(find.byKey(const Key('photo-live-video-layer')), findsOne);
      await tapPhotoMediaKey(tester, 'photo-live-toggle');
      expect(find.byKey(const Key('photo-live-video-layer')), findsNothing);
    });

    testWidgets('④ 翻到下一张 → 播放态自动失效（视频层不会盖住别的照片）', (tester) async {
      final items = photoMediaItems([
        photoMediaItem(
          '1',
          type: 'motion_photo',
          filename: 'IMG_1.jpg',
          motionPhoto: motionPhotoMeta(),
        ),
        photoMediaItem('2', type: 'photo', filename: 'IMG_2.jpg'),
      ]);
      await pumpPhotoMedia(tester, PhotoViewerPage(items: items));
      await tapPhotoMediaKey(tester, 'photo-live-toggle');
      expect(find.byKey(const Key('photo-live-video-layer')), findsOne);
      // 翻页（模拟用户横滑）。
      //
      // 这里用 `fling` 而不是 `drag(Offset(-500, 0))`：本套用例的画布是
      // **1200 逻辑像素宽**（`pumpPhotoMedia` 的默认值，为的是让顶栏动作都进树），
      // 而 `drag` 的事件序列算不出稳定的甩动速度 —— 实测 -500 时 page 只到
      // **0.0114**（`PageScrollPhysics` 需要越过半页 600px 或带速度才换页），
      // 连 -601 都是 0.0138（与实况无关，纯拖拽距离/速度不够）。也就是说：
      // **不是产品没接线，是这个手势根本翻不动页**。换成带速度的横滑后与画布
      // 宽度无关，落在同一页。
      await tester.fling(
        find.byKey(const Key('photo-live-stage')),
        const Offset(-400, 0),
        1200,
      );
      // 弹簧落定（`onPageChanged` 在 page≈0.83 就触发了，但旧页要等落定才拆）
      await settlePhotoMediaPager(tester);
      expect(find.byKey(const Key('photo-live-video-layer')), findsNothing);
      expect(find.byKey(const Key('photo-live-stage')), findsNothing);
    });

    testWidgets('⑤ 实况照片但服务端没有配对视频 → 徽标在、按钮禁用、不产生视频层', (tester) async {
      final items = photoMediaItems([
        photoMediaItem(
          '1',
          type: 'live',
          liveType: 'photo',
          filename: 'IMG_1.jpg',
        ),
      ]);
      await pumpPhotoMedia(tester, PhotoViewerPage(items: items));
      expect(find.byKey(const Key('photo-live-stage')), findsOne);
      expect(find.text('实况照片'), findsOne);
      final button = tester.widget<IconButton>(
        find.byKey(const Key('photo-live-toggle')),
      );
      expect(button.onPressed, isNull);
      expect(find.byKey(const Key('photo-live-video-layer')), findsNothing);
    });

    testWidgets('⑥ 实况照片能在同一批条目里配对出 video 成员 → 播放走那条视频条目', (tester) async {
      final items = photoMediaItems([
        photoMediaItem(
          '1',
          type: 'live',
          liveType: 'photo',
          filename: 'IMG_10.jpg',
        ),
        photoMediaItem(
          '2',
          type: 'live',
          liveType: 'video',
          filename: 'IMG_10.mov',
        ),
      ]);
      await pumpPhotoMedia(tester, PhotoViewerPage(items: items));
      // 第一条是静图（实况组里的 photo 成员）
      await tapPhotoMediaKey(tester, 'photo-live-toggle');
      expect(find.byKey(const Key('photo-live-video-layer')), findsOne);
      final player = tester.widget<MediaPlayerView>(
        find.byKey(const Key('photo-live-player')),
      );
      // 配对的是一条**普通视频条目** → 走 Download 原文件（不是 motion_photo 档）
      final q = queryOf(player.source.uri);
      expect(q['api'], 'SYNO.Foto.Download');
      expect(q.containsKey('quality'), isFalse);
      expect(q['item_id'], contains('2'));
    });

    testWidgets('⑦ 普通照片不出现实况徽标（不误伤）', (tester) async {
      final items = photoMediaItems([
        photoMediaItem('1', type: 'photo', filename: 'IMG_1.jpg'),
      ]);
      await pumpPhotoMedia(tester, PhotoViewerPage(items: items));
      expect(find.byKey(const Key('photo-live-stage')), findsNothing);
      expect(find.byKey(const Key('photo-live-toggle')), findsNothing);
    });
  });
}
