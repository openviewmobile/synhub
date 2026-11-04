// 相册（Photos）视频缩略图 = **本机抽帧**的接线测试（第 261 轮补）。
//
// 背景（真机只读取证，`docs/thumbnail-apis.md` §1.8）：`SYNO.Foto.Thumbnail:get`
// 对视频**不成立** —— 视频条目的 `additional.thumbnail.sm/m/xl` 是状态串
// `ame_defect`，发请求必然 404。所以相册视频必须和 Files 侧一样走
// `video_frame_thumb.dart`（只取 6 MiB 头部 → 原生抽帧 → 缓存），**绝不**为视频
// 发那个注定失败的服务端请求。
//
// 全部离线：`FakeTransport` 只用来把 `SYNO.Foto.Download` 直链拼出来；
// 抽帧本身用假 loader（不碰 path_provider / 原生桥 / 网络）。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/media/video_frame_stage_bridge.dart';
import 'package:synhub/src/features/media/video_frame_thumb.dart';
import 'package:synhub/src/features/media/video_thumb_unavailable.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';
import 'package:synhub/src/features/photos/photo_widgets.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

/// 1x1 的真 PNG（能被 Flutter 解码）。
final Uint8List pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Foto.Download': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Streaming': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

/// 建一个假传输 + 登录好的 `FotoApi`（把传输也交出来，好断言"发过什么请求"）。
Future<({FotoApi api, FakeTransport t})> _apiWithTransport() async {
  final t = FakeTransport(<String, Map<String, dynamic>>{}, {
    ...FakeTransport.table,
    ..._table,
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (api: FotoApi(api), t: t);
}

Future<FotoApi> _api() async => (await _apiWithTransport()).api;

/// 真机形态的**视频**条目：缩略状态 `ame_defect`（⇒ `photoThumbRequest` 恒 null）。
FotoItemDto _videoItem({
  String id = '28045',
  String filename = 'IMG_28045.mp4',
  int filesize = 1876693,
  int time = 1758100000,
}) => FotoItemDto.fromJson({
  'id': id,
  'filename': filename,
  'type': 'video',
  'filesize': filesize,
  'time': time,
  'additional': {
    'thumbnail': {
      'sm': 'ame_defect',
      'm': 'ame_defect',
      'xl': 'ame_defect',
      'unit_id': '9429',
      'cache_key': 'ck_bad',
    },
  },
});

/// 相册视频格子（走真实 [PhotoThumb] 的 `isVideo` 分支）。
PhotoThumb _thumb(FotoItemDto item) => PhotoThumb(
  request: photoThumbRequest(item, FotoSpace.personal),
  isVideo: item.isVideo,
  videoItem: item.isVideo ? item : null,
  filename: item.filename,
);

/// 一棵最小的 widget 树 + 假抽帧 cache（`directory = null` ⇒ 不碰 path_provider）。
Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  FotoApi? api,
  bool overrideApi = true,
  required VideoFrameThumbCache cache,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (overrideApi) fotoSpaceApiProvider.overrideWithValue(api),
        videoFrameThumbCacheProvider.overrideWithValue(cache),
      ],
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 80, height: 80, child: child),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

VideoFrameThumbCache _cache(VideoFrameLoader loader) => VideoFrameThumbCache(
  loader: loader,
  directory: () async => null,
  memoryBytes: 1 << 20,
);

/// 第 267 轮：**带平台分层**的假 cache（生产路径就是 `detailedLoader`）。
VideoFrameThumbCache _detailedCache(VideoFrameDetailedLoader loader) =>
    VideoFrameThumbCache(
      loader: (r) async => null,
      detailedLoader: loader,
      directory: () async => null,
      memoryBytes: 1 << 20,
    );

void main() {
  group('相册视频 → 本机抽帧（不发注定 404 的 Foto.Thumbnail）', () {
    testWidgets('① 发起抽帧，且请求的 uri / extension / cacheKey 正确', (tester) async {
      final api = await _api();
      final seen = <VideoFrameThumbRequest>[];
      final cache = _cache((req) async {
        seen.add(req);
        return null;
      });

      final item = _videoItem();
      await _pump(tester, _thumb(item), api: api, cache: cache);

      expect(seen, hasLength(1), reason: '视频项必须发起一次抽帧');
      final req = seen.single;
      expect(req.extension, 'mp4');
      expect(
        req.cacheKey,
        'vframe|${photoVideoFrameCachePath(item, FotoSpace.personal)}'
        '|${item.time}|${item.filesize}',
        reason: '缓存键 = photos:<空间>:<itemId> + 拍摄时间 + 大小',
      );
      // 直链 = SYNO.Foto.Download（`resolvePhotosSource` 的 Download 腿）。
      final q = Uri.parse(req.uri).queryParameters;
      expect(q['api'], 'SYNO.Foto.Download', reason: req.uri);
      expect(q['method'], 'download', reason: req.uri);
      expect(q['item_id'], '[28045]', reason: req.uri);
      expect(req.uri, contains('_sid='), reason: '直链必须自带鉴权');
      expect(req.rangeSupported, isTrue, reason: 'Download 腿 Range 真机已证 206');
    });

    testWidgets('② 出帧后渲染出图片（不再是占位）', (tester) async {
      final api = await _api();
      final cache = _cache((req) async => pngBytes);

      await _pump(tester, _thumb(_videoItem()), api: api, cache: cache);

      expect(find.byType(Image), findsOneWidget);
      expect(
        find.byKey(const Key('photo-thumb-unavailable')),
        findsNothing,
        reason: '出帧了就绝不能还挂着"不可用"占位',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('③ 抽帧失败（回 null）⇒ 退回占位，不抛', (tester) async {
      final api = await _api();
      final cache = _cache((req) async => null);

      await _pump(tester, _thumb(_videoItem()), api: api, cache: cache);

      expect(
        find.byKey(const Key('photo-thumb-unavailable')),
        findsOneWidget,
      );
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.videocam_off_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('③b 抽帧抛异常 ⇒ 同样退回占位，不把异常漏到界面', (tester) async {
      final api = await _api();
      final cache = _cache((req) async => throw Exception('decode failed'));

      await _pump(tester, _thumb(_videoItem()), api: api, cache: cache);

      expect(
        find.byKey(const Key('photo-thumb-unavailable')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('④ 没有直链（未连接）⇒ 一次抽帧都不发，直接占位', (tester) async {
      var frameAsked = 0;
      final cache = _cache((req) async {
        frameAsked++;
        return pngBytes;
      });

      await _pump(
        tester,
        _thumb(_videoItem()),
        api: null,
        overrideApi: true,
        cache: cache,
      );

      expect(frameAsked, 0, reason: '拿不到直链就该直接占位，别发注定失败的抽帧');
      expect(
        find.byKey(const Key('photo-thumb-unavailable')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('⑤ 图片项行为不变：不碰抽帧 provider（0 次）', (tester) async {
      var frameAsked = 0;
      final cache = _cache((req) async {
        frameAsked++;
        return pngBytes;
      });

      const image = PhotoThumb(
        request: PhotoThumbRequest(
          itemId: '1',
          cacheKey: '1',
          space: FotoSpace.personal,
        ),
      );
      await _pump(tester, image, api: null, overrideApi: false, cache: cache);

      expect(frameAsked, 0, reason: '图片永远不该走视频抽帧');
      // 图片失败走的是它自己的占位（`image_outlined`），不是视频的不可用占位。
      expect(
        find.byKey(const Key('photo-thumb-unavailable')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('⑥ 出帧时播放角标仍然存在（产品要求）', (tester) async {
      final api = await _api();
      final cache = _cache((req) async => pngBytes);

      await _pump(tester, _thumb(_videoItem()), api: api, cache: cache);

      expect(find.byType(Image), findsOneWidget);
      expect(
        find.byIcon(Icons.play_circle_fill),
        findsOneWidget,
        reason: '抽到帧也必须保留"这是视频"的角标',
      );
    });

    // 第 263 轮：把"还在抽"和"确实失败"分开（AGENTS §2.0.17②）。
    // 之前两种态画的是**同一个**图标 ⇒ 用户分不清"慢"和"坏"，日志里也没落点。
    testWidgets('⑦ 抽帧进行中 ⇒ 骨架（不是"摄像机不可用"）', (tester) async {
      final api = await _api();
      // 永不完成：把 provider 钉在 loading 态。
      final gate = Completer<Uint8List?>();
      final cache = _cache((req) => gate.future);

      await _pump(tester, _thumb(_videoItem(id: '8801')), api: api, cache: cache);

      expect(
        find.byKey(const Key('photo-video-thumb-loading')),
        findsOneWidget,
        reason: '正在抽帧必须有**中性**的骨架，不能直接判"坏了"',
      );
      expect(
        find.byKey(const Key('photo-thumb-unavailable')),
        findsNothing,
        reason: '还在抽帧就不是不可用',
      );
      expect(find.byIcon(Icons.videocam_off_outlined), findsNothing);
      expect(tester.takeException(), isNull);

      // 收尾：让 future 完成，避免 pending timer 影响后续用例。
      gate.complete(null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const Key('photo-thumb-unavailable')),
        findsOneWidget,
        reason: '失败后要落到"不可用"占位（不是永远转圈）',
      );
    });

    testWidgets('⑧ 失败 == 可定位：打一条带请求侧原因的日志（只打一次）', (tester) async {
      final api = await _api();
      final cache = _cache((req) async => null);
      final logs = <String>[];
      final saved = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      try {
        await _pump(
          tester,
          _thumb(_videoItem(id: '8802')),
          api: api,
          cache: cache,
        );
        // 再 pump 几帧：失败日志**不许**随 build 反复刷屏。
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
      } finally {
        // ⚠️ 必须在**用例体内**还原：框架在 `_runTestBody` 结束时会校验
        // foundation 的调试变量没被改过，`addTearDown` 那时已经太晚。
        debugPrint = saved;
      }

      final fail = logs.where((l) => l.contains('[photoVideoThumb] FAIL'));
      expect(fail, hasLength(1), reason: '失败必须留下**一条**可查的日志：$logs');
      expect(fail.single, contains('reason=extract-failed'));
      expect(fail.single, contains('ext=mp4'));
      expect(fail.single, contains('size=1876693'));
      expect(fail.single, contains('range=true'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('⑩ 视频项：一次都不发 `SYNO.Foto.Thumbnail`（真机恒 404）', (tester) async {
      final boot = await _apiWithTransport();
      final seen = <VideoFrameThumbRequest>[];
      final cache = _cache((req) async {
        seen.add(req);
        return pngBytes;
      });

      await _pump(
        tester,
        _thumb(_videoItem(id: '8805')),
        api: boot.api,
        cache: cache,
      );

      // ① JSON 调用层：一次 `SYNO.Foto.Thumbnail` 都没有。
      expect(
        boot.t.calls.where((c) => c['api'] == 'SYNO.Foto.Thumbnail'),
        isEmpty,
        reason: '真机上视频的缩略状态恒 ame_defect ⇒ Thumbnail/get 必然 404，发了就是白发',
      );
      // ② 字节下载层：同样没有服务端缩略图直链。
      expect(
        boot.t.downloads.where((u) => u.contains('SYNO.Foto.Thumbnail')),
        isEmpty,
        reason: '字节腿也不许出现"白发一次必然 404"的请求',
      );
      // ③ 对照：自研抽帧确实走 Download 直链腿（不是"什么都没做"）。
      expect(seen, hasLength(1));
      expect(seen.single.uri, contains('SYNO.Foto.Download'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('⑨ 超 6 MiB 的非 faststart 视频 ⇒ 日志点名 head-window', (tester) async {
      final api = await _api();
      final cache = _cache((req) async => null);
      final logs = <String>[];
      final saved = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      try {
        // 40 MiB：> `kVideoFrameHeadBytes`(6 MiB) ⇒ 只给了头部，
        // `moov` 在文件尾时容器阶段必然解不出来（真机 AVI 取证）。
        await _pump(
          tester,
          _thumb(_videoItem(id: '8803', filesize: 40 * 1024 * 1024)),
          api: api,
          cache: cache,
        );
      } finally {
        debugPrint = saved; // 见 ⑧：必须在使用例体内还原
      }

      final fail = logs.firstWhere(
        (l) => l.contains('[photoVideoThumb] FAIL'),
        orElse: () => '',
      );
      expect(
        fail,
        contains('reason=head-window:${40 * 1024 * 1024}'),
        reason: '必须能一眼看出"是只取头部导致的"，而不是笼统 failed：$logs',
      );
    });
  });

  group('photoVideoFrameFailureReason（纯函数：请求侧可判定原因）', () {
    VideoFrameThumbRequest req({
      String uri = 'https://nas:5001/entry.cgi?_sid=s&api=x',
      String ext = 'mp4',
      int size = 1024,
      bool range = true,
    }) => VideoFrameThumbRequest(
      cacheKey: 'vframe|k|1|$size',
      uri: uri,
      extension: ext,
      size: size,
      rangeSupported: range,
    );

    test('没有请求 / 没有直链', () {
      expect(photoVideoFrameFailureReason(null), 'no-request');
      expect(photoVideoFrameFailureReason(req(uri: '')), 'no-url');
    });

    test('容器不在白名单', () {
      expect(
        photoVideoFrameFailureReason(req(ext: 'txt')),
        'unsupported-container:txt',
      );
    });

    test('服务端不支持 Range：大小未知 / 超上限 ⇔ 做不了', () {
      expect(
        photoVideoFrameFailureReason(req(range: false, size: 0)),
        'no-range-unknown-size',
      );
      expect(
        photoVideoFrameFailureReason(
          req(range: false, size: kVideoFrameHeadBytes + 1),
        ),
        'no-range-too-big',
      );
      // 小而完整 ⇒ 能整份下，只是可能抽不出来，不归到"做不了"。
      expect(
        photoVideoFrameFailureReason(req(range: false, size: 1024)),
        'extract-failed',
      );
    });

    test('大小未知 / 超头部窗口 / 其余一律 extract-failed', () {
      expect(photoVideoFrameFailureReason(req(size: 0)), 'unknown-size');
      expect(
        photoVideoFrameFailureReason(req(size: kVideoFrameHeadBytes + 1)),
        'head-window:${kVideoFrameHeadBytes + 1}',
      );
      expect(
        photoVideoFrameFailureReason(req(size: kVideoFrameHeadBytes)),
        'extract-failed',
        reason: '正好等于上限 = 整份下，不归"只给了头部"',
      );
    });
  });

  group('photoVideoFrameRequest（纯函数边界）', () {
    test('非视频后缀 / 未连接 ⇒ null（连抽帧都不该发）', () async {
      final api = await _api();
      expect(
        photoVideoFrameRequest(
          _videoItem(filename: 'notes.txt'),
          api,
          FotoSpace.personal,
        ),
        isNull,
      );
      expect(
        photoVideoFrameRequest(_videoItem(), null, FotoSpace.personal),
        isNull,
      );
    });

    test('cacheKey 随 itemId / 拍摄时间 / 大小变化（换内容不会命中旧图）', () {
      final a = _videoItem(id: '1', time: 100, filesize: 10);
      final b = _videoItem(id: '1', time: 200, filesize: 10);
      final c = _videoItem(id: '1', time: 100, filesize: 20);
      // 路径只含 `空间 + id`（同一条视频改名/重拍时 id 才变）；
      // time / size 由 `videoFrameCacheKey` 拼进**完整缓存键**。
      expect(photoVideoFrameCachePath(a, FotoSpace.personal), 'photos:personal:1');
      expect(
        photoVideoFrameCachePath(a, FotoSpace.team),
        isNot(photoVideoFrameCachePath(a, FotoSpace.personal)),
        reason: '共享空间与个人空间的 item id 可能相撞，缓存路径必须带空间',
      );
      expect(
        videoFrameCacheKey(
          path: photoVideoFrameCachePath(a, FotoSpace.personal),
          mtime: a.time,
          size: a.filesize,
        ),
        'vframe|photos:personal:1|100|10',
      );
      expect(
        videoFrameCacheKey(
          path: photoVideoFrameCachePath(b, FotoSpace.personal),
          mtime: b.time,
          size: b.filesize,
        ),
        'vframe|photos:personal:1|200|10',
      );
      expect(
        videoFrameCacheKey(
          path: photoVideoFrameCachePath(c, FotoSpace.personal),
          mtime: c.time,
          size: c.filesize,
        ),
        'vframe|photos:personal:1|100|20',
      );
    });
  });
    // 第 267 轮：用户报障「avi为啥没有缩略图？」——失败不再只是一个图标，
    // 必须**说得出原因**，而且原因必须是"容器/格式"（不是错误的"编码不支持"）。
    testWidgets('⑨ 抽帧失败 ⇒ 占位带上具体原因（容器 + fourcc），不是哑图标', (tester) async {
      final api = await _api();
      final cache = _detailedCache(
        (req) async => VideoFrameThumbOutcome(
          failure: VideoFrameThumbFailure.from(
            req,
            const VideoFrameExtractionFailure(
              stage: VideoFrameStage.open,
              container: 'riff/avi',
              videoFourcc: 'FMP4',
              errorClass: 'IllegalArgumentException',
              error: "couldn't open /data/…/-375289b992ca068d_57.bin",
            ),
          ),
        ),
      );

      await _pump(
        tester,
        _thumb(_videoItem(id: '9901', filename: '60招基础街球S01E01.AVI')),
        api: api,
        cache: cache,
      );

      final tile = tester.widget<VideoThumbUnavailable>(
        find.byType(VideoThumbUnavailable),
      );
      expect(tile.failure, isNotNull);
      expect(tile.failure!.reasonKey, 'container-open-failed:riff-avi');
      expect(tile.failure!.videoFourcc, 'FMP4');
      expect(tile.failure!.containerNotSupported, isTrue);
      // 既有外观不变：还是"摄像机不可用" + 播放角标 + 老 key。
      expect(
        find.byKey(const Key('photo-thumb-unavailable')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.videocam_off_outlined), findsOneWidget);
      expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    });

    // ★ 反向验证：把平台分层拿掉（= 修复前的形状）⇒ 界面**说不出**容器，
    // 只剩中性的「暂无封面」；也就是说"能说出原因"这条断言真的钉住了新能力。
    testWidgets('⑩ 反向验证：没有平台分层时，界面说不出原因（退回中性标签）', (tester) async {
      final api = await _api();
      final cache = _detailedCache(
        (req) async => VideoFrameThumbOutcome(
          failure: VideoFrameThumbFailure.from(req, null),
        ),
      );

      await _pump(
        tester,
        _thumb(_videoItem(id: '9902', filename: '60招基础街球S01E01.AVI')),
        api: api,
        cache: cache,
      );

      final tile = tester.widget<VideoThumbUnavailable>(
        find.byType(VideoThumbUnavailable),
      );
      expect(tile.failure!.stage, VideoFrameStage.unknown);
      expect(tile.failure!.videoFourcc, isEmpty);
      expect(
        tile.failure!.reasonKey,
        'extract-failed',
        reason: '修复前只剩请求侧先验（≤6 MiB 的 mp4 就是这一条）'
            ' —— 这正是当初答不上"为什么"的原因',
      );
    });

}
