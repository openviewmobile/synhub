// 视频首帧缩略图（自研抽帧）单测（第 261 轮）。
//
// 设计纪律（照任务书）：
//   * **纯 Dart 单测**：原生桥用**接口注入的假实现**（`FakeVideoFrameExtractor`），
//     测试**不依赖 Android 运行时**（`debugForceAndroid` 只用来把通道"打通"，
//     真正的字节来自 `TestDefaultBinaryMessengerBinding` 的 mock handler）；
//   * 覆盖：缓存键、LRU（内存 + 磁盘）、失败记忆、限流、取消、判定函数、
//     下载上限、临时文件生命周期、provider 接线；
//   * 含**反向验证**：故意把缓存键做成"不含 mtime" ⇒ 覆盖文件后仍用旧图
//     ⇒ 用例抓住；换生产键（含 mtime）⇒ 重新取到新图。
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/media/video_frame_bridge.dart';
import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/media/video_frame_stage_bridge.dart';
import 'package:synhub/src/features/media/video_frame_thumb.dart';

// ------------------------------------------------------------ 假实现

/// 可注入的假抽帧器：记录调用参数，返回预设结果。
class FakeVideoFrameExtractor implements VideoFrameExtractor {
  FakeVideoFrameExtractor(this.handler);

  Future<VideoFrameResult?> Function(String path, int atMs, int maxWidth)
  handler;

  int calls = 0;
  String? lastPath;
  int? lastAtMs;
  int? lastMaxWidth;

  /// 抽帧当时那个本地文件的内容（用来证明"临时文件真的写好了才交给原生"）
  Uint8List? lastFileBytes;
  bool lastFileExisted = false;

  @override
  Future<VideoFrameResult?> extract(
    String localPath, {
    int atMs = 0,
    int maxWidth = kVideoFrameDefaultMaxWidth,
  }) async {
    calls++;
    lastPath = localPath;
    lastAtMs = atMs;
    lastMaxWidth = maxWidth;
    final f = File(localPath);
    lastFileExisted = await f.exists();
    if (lastFileExisted) lastFileBytes = await f.readAsBytes();
    return handler(localPath, atMs, maxWidth);
  }

  @override
  Future<bool> isSupported() async => true;
}

/// 假的"取头部片段"：记录每次请求的 maxBytes，返回预设字节。
class FakeHeadFetcher {
  FakeHeadFetcher(this.bytes);

  Uint8List bytes;
  final List<int> requested = [];
  final List<String> uris = [];

  Future<Uint8List> call(
    VideoFrameThumbRequest request, {
    required int maxBytes,
  }) async {
    requested.add(maxBytes);
    uris.add(request.uri);
    return bytes;
  }
}

Uint8List _bytes(int length, int fill) =>
    Uint8List.fromList(List<int>.filled(length, fill));

/// 合成的 JPEG 头（`FF D8 FF`），用来断言"桥返回的是 JPEG 编码".
Uint8List _jpeg([int seed = 1]) =>
    Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, seed, seed + 1]);

VideoFrameResult _frame([int seed = 1]) => VideoFrameResult(
  bytes: _jpeg(seed),
  mime: 'image/jpeg',
  width: 320,
  height: 180,
);

VideoFrameThumbRequest _req(
  String key, {
  int size = 10,
  bool range = true,
  String ext = 'mp4',
}) => VideoFrameThumbRequest(
  cacheKey: key,
  uri: 'https://nas/entry.cgi?_sid=x&path=$key',
  extension: ext,
  size: size,
  rangeSupported: range,
);

Future<void> _tick() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ============================================================ 缓存键

  group('缓存键', () {
    test('键里同时含 mtime 与 size（任一变化 ⇒ 键变化）', () {
      final base = videoFrameCacheKey(path: '/home/a.mp4', mtime: 100, size: 5);
      final otherMtime = videoFrameCacheKey(
        path: '/home/a.mp4',
        mtime: 101,
        size: 5,
      );
      final otherSize = videoFrameCacheKey(
        path: '/home/a.mp4',
        mtime: 100,
        size: 6,
      );
      final otherPath = videoFrameCacheKey(
        path: '/home/b.mp4',
        mtime: 100,
        size: 5,
      );
      expect(base, 'vframe|/home/a.mp4|100|5');
      expect({base, otherMtime, otherSize, otherPath}.length, 4);
    });

    test('forPath 归一化后缀；forDrive 用 file_id + version', () {
      final p = VideoFrameThumbRequest.forPath(
        path: '/home/A.MP4',
        uri: 'u',
        extension: '.MP4',
        size: 9,
        mtime: 3,
      );
      expect(p.extension, 'mp4');
      expect(p.cacheKey, 'vframe|/home/A.MP4|3|9');

      final d1 = VideoFrameThumbRequest.forDrive(
        fileId: '123',
        uri: 'u',
        extension: 'mp4',
        size: 9,
        version: 'v1',
      );
      final d2 = VideoFrameThumbRequest.forDrive(
        fileId: '123',
        uri: 'u',
        extension: 'mp4',
        size: 9,
        version: 'v2',
      );
      expect(d1.cacheKey, 'vframe|id:123|v1|9');
      expect(d1.cacheKey, isNot(d2.cacheKey));
      // Drive 写死 `Accept-Ranges: none` ⇒ 默认不支持 Range
      expect(d1.rangeSupported, isFalse);
    });

    test('★ 反向验证：键不含 mtime ⇒ 覆盖文件后仍用旧图；生产键 ⇒ 重新取新图', () async {
      var content = _bytes(4, 1);
      var loaderCalls = 0;
      final cache = VideoFrameThumbCache(
        loader: (request) async {
          loaderCalls++;
          return content;
        },
        memoryBytes: kVideoFrameMemoryBytes,
      );

      /// **故意做错**：只用路径当键（不含 mtime / size）
      String naiveKey(String path) => 'vframe|$path';
      final path = '/home/video/clip.mp4';

      final first = await cache.get(
        VideoFrameThumbRequest(
          cacheKey: naiveKey(path),
          uri: 'u',
          extension: 'mp4',
          size: 4,
        ),
      );
      expect(first, [1, 1, 1, 1]);
      expect(loaderCalls, 1);

      // 文件被覆盖：内容变了、mtime 也变了，但**键没变**
      content = _bytes(4, 2);
      final stale = await cache.get(
        VideoFrameThumbRequest(
          cacheKey: naiveKey(path),
          uri: 'u',
          extension: 'mp4',
          size: 4,
        ),
      );
      expect(stale, [1, 1, 1, 1], reason: '这就是"不含 mtime"的缺陷：仍拿到旧图');
      expect(loaderCalls, 1, reason: '键没变 ⇒ 根本没回源');

      // 生产键（含 mtime）在同一场景下会取到新内容
      final fresh = await cache.get(
        VideoFrameThumbRequest(
          cacheKey: videoFrameCacheKey(path: path, mtime: 200, size: 4),
          uri: 'u',
          extension: 'mp4',
          size: 4,
        ),
      );
      expect(fresh, [2, 2, 2, 2]);
      expect(loaderCalls, 2);

      // 再覆盖一次但 mtime 假装没变 ⇒ 仍然用旧图（说明"键不变就用旧图"是机制，
      // 修复点在"mtime 进了键"，不在别处）
      content = _bytes(4, 3);
      final again = await cache.get(
        VideoFrameThumbRequest(
          cacheKey: videoFrameCacheKey(path: path, mtime: 200, size: 4),
          uri: 'u',
          extension: 'mp4',
          size: 4,
        ),
      );
      expect(again, [2, 2, 2, 2]);
      expect(loaderCalls, 2);
    });
  });

  // ============================================================ 判定函数

  group('能不能做（判定函数）', () {
    test('空 uri / 非视频后缀 → 不能做', () {
      expect(videoFrameThumbSupported(null), isFalse);
      expect(
        videoFrameThumbSupported(
          const VideoFrameThumbRequest(
            cacheKey: 'k',
            uri: '',
            extension: 'mp4',
          ),
        ),
        isFalse,
      );
      expect(
        videoFrameThumbSupported(
          const VideoFrameThumbRequest(
            cacheKey: 'k',
            uri: 'u',
            extension: 'jpg',
          ),
        ),
        isFalse,
      );
      expect(
        videoFrameThumbSupported(
          const VideoFrameThumbRequest(
            cacheKey: 'k',
            uri: 'u',
            extension: '',
          ),
        ),
        isFalse,
      );
    });

    test('常见视频容器 → 能做；图片/文档 → 不能', () {
      for (final ext in ['mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi', '3gp']) {
        expect(
          videoFrameThumbSupported(
            VideoFrameThumbRequest(
              cacheKey: 'k',
              uri: 'u',
              extension: ext,
            ),
          ),
          isTrue,
          reason: ext,
        );
      }
      for (final ext in ['jpg', 'png', 'pdf', 'docx', 'mp3', 'flac']) {
        expect(
          videoFrameThumbSupported(
            VideoFrameThumbRequest(
              cacheKey: 'k',
              uri: 'u',
              extension: ext,
            ),
          ),
          isFalse,
          reason: ext,
        );
      }
    });

    test('不支持 Range 时"必须已知大小且 ≤ 6 MiB"；支持 Range 则多大都行', () {
      final big = _req('k', size: kVideoFrameHeadBytes + 1, range: false);
      expect(videoFrameThumbSupported(big), isFalse);
      expect(
        videoFrameThumbSupported(
          _req('k', size: kVideoFrameHeadBytes + 1, range: true),
        ),
        isTrue,
        reason: '支持 Range（FileStation 真机实测 206）⇒ 只取头部，多大都行',
      );
      expect(
        videoFrameThumbSupported(_req('k', size: 1024, range: false)),
        isTrue,
      );
      expect(
        videoFrameThumbSupported(_req('k', size: 0, range: false)),
        isFalse,
        reason: '不支持 Range 又不知道大小 ⇒ **fail-closed**：宁可不出图，'
            '也不赌一把把 4.7 GB 的 MKV 拉下来',
      );
      expect(
        videoFrameThumbSupported(_req('k', size: 0, range: true)),
        isTrue,
        reason: '支持 Range 且大小未知 ⇒ 用 6 MiB 上限先试一次',
      );
    });

    test('★ 真 NAS `/home/Video` 的四个真实样本：绝不整份下载', () {
      // 只读探针实测的大小（父 agent 提供；`/home/Video` 大写 V）
      const samples = <(String, String, int)>[
        ('01_1._The_Rate_of_Chemical_Reactions__10-12.mp4', 'mp4', 13646152),
        ('60招基础街球S01E01.AVI', 'avi', 191779926),
        (
          'U01M01 The essence of calculus--- [ FreeCourseWeb.com ] ---.mp4',
          'mp4',
          249957807,
        ),
        ('Citizen Kane (1941).mkv', 'mkv', 4693969377), // 4.7 GB
      ];
      for (final (name, ext, size) in samples) {
        // FileStation `Download` 真机实测支持 206 ⇒ 只取头部
        final req = _req(name, size: size, ext: ext);
        expect(videoFrameThumbSupported(req), isTrue, reason: name);
        final plan = videoFrameDownloadPlan(req);
        expect(plan.maxBytes, kVideoFrameHeadBytes, reason: '$name：只取 6 MiB 头部');
        expect(plan.wholeFile, isFalse, reason: '$name：不是整份');
      }
      // 4.7 GB 的 MKV 若是"不支持 Range"的通道（Drive）⇒ 直接判做不了
      expect(
        videoFrameThumbSupported(
          _req('Citizen Kane (1941).mkv', size: 4693969377, ext: 'mkv', range: false),
        ),
        isFalse,
      );
    });

    test('下载计划：小文件按整份要、大文件只要头部', () {
      expect(
        videoFrameDownloadPlan(_req('k', size: 1024)),
        const VideoFrameDownloadPlan(maxBytes: 1024, wholeFile: true),
      );
      expect(
        videoFrameDownloadPlan(_req('k', size: kVideoFrameHeadBytes * 3)),
        const VideoFrameDownloadPlan(
          maxBytes: kVideoFrameHeadBytes,
          wholeFile: false,
        ),
      );
      // 大小未知 ⇒ 头部上限，且标记"不是整份"
      expect(
        videoFrameDownloadPlan(_req('k', size: 0)),
        const VideoFrameDownloadPlan(
          maxBytes: kVideoFrameHeadBytes,
          wholeFile: false,
        ),
      );
    });
  });

  // ============================================================ 缓存行为

  group('缓存：内存 LRU / 磁盘 LRU / 失败记忆 / 合流', () {
    test('内存 LRU：超上限淘汰最久未用', () async {
      final cache = VideoFrameThumbCache(
        loader: (request) async => _bytes(100, request.cacheKey.codeUnitAt(0)),
        memoryBytes: 300,
      );
      await cache.get(_req('a'));
      await cache.get(_req('b'));
      await cache.get(_req('c'));
      expect(cache.memoryUsed, 300);
      await cache.get(_req('a')); // 命中 ⇒ a 变成"最近使用"
      await cache.get(_req('d')); // 400 > 300 ⇒ 淘汰最久未用（b）
      // 顺序 = 由旧到新：c（最旧）、a（刚命中）、d（最新）
      expect(cache.debugMemoryKeys(), ['c', 'a', 'd']);
      expect(cache.memoryUsed, 300);
      expect(cache.stats.hits, 1);
    });

    test('磁盘 LRU：按总字节淘汰最久未用（按 mtime）', () async {
      final dir = await Directory.systemTemp.createTemp('vframe_disk_');
      addTearDown(() => dir.delete(recursive: true));
      final now = DateTime.now();
      Future<void> seed(String name, DateTime at) async {
        final f = File('${dir.path}/$name.vframe');
        await f.writeAsBytes(_bytes(100, 7));
        await f.setLastModified(at);
      }

      await seed('old', now.subtract(const Duration(seconds: 30)));
      await seed('mid', now.subtract(const Duration(seconds: 20)));
      await seed('new', now.subtract(const Duration(seconds: 10)));

      final cache = VideoFrameThumbCache(
        loader: (request) async => _bytes(100, 9),
        memoryBytes: 0,
        diskBytes: 250,
        directory: () async => dir,
      );
      await cache.get(_req('fresh'));

      // 写 fresh(100) 后总量 400 > 250 ⇒ 删 old(300) ⇒ 再删 mid(200)
      expect(await File('${dir.path}/old.vframe').exists(), isFalse);
      expect(await File('${dir.path}/mid.vframe').exists(), isFalse);
      expect(await File('${dir.path}/new.vframe').exists(), isTrue);
      expect(cache.stats.diskEvictedFiles, 2);

      var files = 0;
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.vframe')) files++;
      }
      expect(files, 2, reason: '只剩 new + fresh');
    });

    test('磁盘命中：第二次不再调 loader，并刷新 mtime（LRU 的"最近使用"）', () async {
      final dir = await Directory.systemTemp.createTemp('vframe_hit_');
      addTearDown(() => dir.delete(recursive: true));
      var calls = 0;
      final cache = VideoFrameThumbCache(
        loader: (request) async {
          calls++;
          return _jpeg(3);
        },
        memoryBytes: 0,
        directory: () async => dir,
      );
      expect(await cache.get(_req('a')), isNotNull);
      expect(calls, 1);
      // 清内存不影响磁盘
      cache.clearMemory();
      expect(await cache.get(_req('a')), isNotNull);
      expect(calls, 1);
      expect(cache.stats.hits, 1);
    });

    test('失败记忆：失败只撞一次；TTL 过后才重试', () async {
      var clock = DateTime(2026, 1, 1);
      var calls = 0;
      final cache = VideoFrameThumbCache(
        loader: (request) async {
          calls++;
          return null; // 永远抽不出来
        },
        memoryBytes: 0,
        negativeTtl: const Duration(minutes: 10),
        now: () => clock,
      );
      expect(await cache.get(_req('bad')), isNull);
      expect(calls, 1);
      expect(cache.isRememberedFailure('bad'), isTrue);

      expect(await cache.get(_req('bad')), isNull);
      expect(calls, 1, reason: '失败记忆命中 ⇒ 不重复下载 6 MB');
      // failures 里含"失败记忆命中"这一次（口径同 `ThumbCache`）
      expect(cache.stats.failures, 2);

      clock = clock.add(const Duration(minutes: 11));
      expect(await cache.get(_req('bad')), isNull);
      expect(calls, 2, reason: 'TTL 过后允许再试一次');

      cache.clearFailures();
      expect(cache.failuresRemembered, 0);
    });

    test('合流：同一键并发只要一次', () async {
      final gate = Completer<Uint8List?>();
      var calls = 0;
      final cache = VideoFrameThumbCache(
        loader: (request) {
          calls++;
          return gate.future;
        },
        memoryBytes: 0,
      );
      final f1 = cache.get(_req('a'));
      final f2 = cache.get(_req('a'));
      await _tick();
      expect(calls, 1);
      gate.complete(_jpeg(5));
      expect(await f1, isNotNull);
      expect(await f2, isNotNull);
      expect(cache.stats.deduped, 1);
    });
  });

  group('并发限流与取消', () {
    test('最多 2 并发；排队者拿到名额后立刻开跑', () async {
      final pending = <String, Completer<Uint8List?>>{};
      var calls = 0;
      var running = 0;
      var maxRunning = 0;
      final cache = VideoFrameThumbCache(
        loader: (request) {
          calls++;
          running++;
          maxRunning = math.max(maxRunning, running);
          final c = Completer<Uint8List?>();
          pending[request.cacheKey] = c;
          return c.future.whenComplete(() => running--);
        },
        memoryBytes: 0,
        maxConcurrent: 2,
      );

      final f1 = cache.get(_req('a'));
      final f2 = cache.get(_req('b'));
      final f3 = cache.get(_req('c'));
      await _tick();
      expect(calls, 2, reason: '第 3 个被限流挡住');
      expect(maxRunning, 2);

      pending['a']!.complete(_jpeg(6));
      await _tick();
      expect(calls, 3, reason: '名额让给排队者');
      expect(maxRunning, 2, reason: '全程不超过 2 并发');

      pending['b']!.complete(_jpeg(7));
      pending['c']!.complete(_jpeg(8));
      await Future.wait([f1, f2, f3]);
      expect(maxRunning, 2);
    });

    test('取消：排队中的请求不再下载，且不算失败', () async {
      final pending = <String, Completer<Uint8List?>>{};
      var calls = 0;
      final cache = VideoFrameThumbCache(
        loader: (request) {
          calls++;
          final c = Completer<Uint8List?>();
          pending[request.cacheKey] = c;
          return c.future;
        },
        memoryBytes: 0,
        maxConcurrent: 1,
      );

      final f1 = cache.get(_req('a'));
      await _tick();
      expect(calls, 1);

      final f2 = cache.get(_req('b'));
      await _tick(); // 让 b 走到"排队等名额"这一步
      cache.cancel('b');

      pending['a']!.complete(_jpeg(9));
      await _tick();
      expect(calls, 1, reason: 'b 被取消 ⇒ 一次下载都不发');
      expect(await f2, isNull);
      expect(cache.stats.cancelled, 1);
      expect(cache.isRememberedFailure('b'), isFalse, reason: '取消不是失败');
      expect(await f1, isNotNull);
    });
  });

  // ============================================================ 抽帧流水线

  group('下载 → 临时文件 → 抽帧', () {
    test('头部字节真的写进临时文件、原生吃的是本地路径、抽完临时文件被删', () async {
      final tmp = await Directory.systemTemp.createTemp('vframe_tmp_');
      addTearDown(() => tmp.delete(recursive: true));
      final head = _bytes(2048, 0x42);
      final fetch = FakeHeadFetcher(head);
      final extractor = FakeVideoFrameExtractor(
        (path, atMs, maxWidth) async => _frame(11),
      );

      final out = await loadVideoFrameThumb(
        request: _req('k', size: 4096),
        extractor: extractor,
        fetchHead: fetch.call,
        tempDirectory: () async => tmp,
      );

      expect(out, isNotNull);
      // ★ 返回的是 JPEG（FF D8 FF），不是 PNG
      expect(out!.sublist(0, 3), [0xFF, 0xD8, 0xFF]);
      expect(fetch.requested, [4096], reason: '文件 ≤ 上限 ⇒ 按整份要');
      expect(fetch.uris.single, contains('_sid=x'));
      expect(extractor.calls, 1);
      expect(extractor.lastFileExisted, isTrue);
      expect(extractor.lastFileBytes, head, reason: '临时文件内容 == 下载到的头部字节');
      expect(extractor.lastPath, startsWith(tmp.path));
      expect(extractor.lastAtMs, 0);
      expect(extractor.lastMaxWidth, kVideoFrameThumbMaxWidth);

      final left = await tmp.list().toList();
      expect(left, isEmpty, reason: '临时片段必须删掉（6 MB 量级的中间物）');
    });

    test('大文件只要头部（maxBytes 有上限）', () async {
      final tmp = await Directory.systemTemp.createTemp('vframe_cap_');
      addTearDown(() => tmp.delete(recursive: true));
      final fetch = FakeHeadFetcher(_bytes(64, 1));
      await loadVideoFrameThumb(
        request: _req('k', size: kVideoFrameHeadBytes * 4),
        extractor: FakeVideoFrameExtractor((p, a, w) async => _frame()),
        fetchHead: fetch.call,
        tempDirectory: () async => tmp,
      );
      expect(fetch.requested, [kVideoFrameHeadBytes]);
    });

    test('抽帧失败（原生回 null）⇒ 返回 null 且临时文件照样删掉', () async {
      final tmp = await Directory.systemTemp.createTemp('vframe_fail_');
      addTearDown(() => tmp.delete(recursive: true));
      final out = await loadVideoFrameThumb(
        request: _req('k'),
        extractor: FakeVideoFrameExtractor((p, a, w) async => null),
        fetchHead: FakeHeadFetcher(_bytes(32, 2)).call,
        tempDirectory: () async => tmp,
      );
      expect(out, isNull);
      expect(await tmp.list().toList(), isEmpty);
    });

    test('★ moov 在文件尾的 MP4：头部抽帧失败 ⇒ 记住失败 + 占位，不偷偷下整份', () async {
      // 现实场景：非 fast-start 的 mp4，`moov` 在文件尾 ⇒
      // `MediaMetadataRetriever` 拿文件头解析不出视频轨 ⇒ 原生回 null。
      final tmp = await Directory.systemTemp.createTemp('vframe_moov_');
      addTearDown(() => tmp.delete(recursive: true));
      final fetch = FakeHeadFetcher(_bytes(1024, 0x11));
      final extractor = FakeVideoFrameExtractor((p, a, w) async => null);

      final cache = VideoFrameThumbCache(
        loader: (request) => loadVideoFrameThumb(
          request: request,
          extractor: extractor,
          fetchHead: fetch.call,
          tempDirectory: () async => tmp,
        ),
        memoryBytes: 0,
        negativeTtl: const Duration(minutes: 10),
      );

      // 4.7 GB 的 MKV（FileStation 支持 Range ⇒ 只下 6 MiB 头部）
      final big = _req('Citizen Kane (1941).mkv', size: 4693969377, ext: 'mkv');
      expect(await cache.get(big), isNull);
      expect(fetch.requested, [kVideoFrameHeadBytes], reason: '只下 6 MiB 头部');
      expect(extractor.lastFileBytes!.length, 1024, reason: '原生只拿到头部片段');

      // 列表滚动里第二次要同一张图 ⇒ **不再下载、不再抽帧**
      expect(await cache.get(big), isNull);
      expect(fetch.requested, [kVideoFrameHeadBytes], reason: '失败已记住，不反复重试');
      expect(extractor.calls, 1);
      expect(cache.isRememberedFailure(big.cacheKey), isTrue);
      expect(cache.stats.loaded, 0);
      // 临时文件也没留下
      expect(await tmp.list().toList(), isEmpty);
    });

    test('请求本身做不了 ⇒ 连下载都不发', () async {
      final fetch = FakeHeadFetcher(_bytes(32, 2));
      final extractor = FakeVideoFrameExtractor((p, a, w) async => _frame());
      final out = await loadVideoFrameThumb(
        request: VideoFrameThumbRequest(
          cacheKey: 'k',
          uri: 'u',
          extension: 'mp4',
          size: kVideoFrameHeadBytes * 2,
          rangeSupported: false, // 不支持 Range 又超过上限 ⇒ 做不了
        ),
        extractor: extractor,
        fetchHead: fetch.call,
        tempDirectory: () async => Directory.systemTemp,
      );
      expect(out, isNull);
      expect(fetch.requested, isEmpty);
      expect(extractor.calls, 0);
    });
  });

  // ============================================================ 原生桥

  group('原生桥（mock 通道，不依赖 Android 运行时）', () {
    const channel = MethodChannel(kVideoFrameChannel);
    final calls = <MethodCall>[];

    void setHandler(
      Future<Object?> Function(MethodCall call) handler,
    ) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return handler(call);
          });
    }

    setUp(() {
      calls.clear();
      MethodChannelVideoFrameExtractor.debugForceAndroid = true;
    });

    tearDown(() {
      MethodChannelVideoFrameExtractor.debugForceAndroid = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('fromPlatform：正常 Map 解析；坏形状一律 null（不抛）', () {
      final ok = VideoFrameResult.fromPlatform(<Object?, Object?>{
        'bytes': _jpeg(),
        'mime': 'image/jpeg',
        'width': 320,
        'height': 180,
      });
      expect(ok, isNotNull);
      expect(ok!.bytes.length, 6);
      expect(ok.mime, 'image/jpeg');
      expect(ok.width, 320);
      expect(ok.height, 180);

      // mime 缺失/类型不对 ⇒ 回落 image/jpeg（编码事实是 JPEG）
      final noMime = VideoFrameResult.fromPlatform(<Object?, Object?>{
        'bytes': _jpeg(),
        'mime': 7,
      });
      expect(noMime!.mime, 'image/jpeg');
      expect(noMime.width, 0);

      // 空字节 / 缺 bytes / bytes 类型不对 / 不是 Map / null ⇒ null
      expect(
        VideoFrameResult.fromPlatform(<Object?, Object?>{
          'bytes': Uint8List(0),
        }),
        isNull,
      );
      expect(VideoFrameResult.fromPlatform(<Object?, Object?>{}), isNull);
      expect(
        VideoFrameResult.fromPlatform(<Object?, Object?>{
          'bytes': <int>[1, 2, 3],
        }),
        isNull,
      );
      expect(VideoFrameResult.fromPlatform('nope'), isNull);
      expect(VideoFrameResult.fromPlatform(null), isNull);
    });

    test('extractFrame：参数逐字下发，回包解成 JPEG 字节', () async {
      setHandler((call) async {
        if (call.method == 'isSupported') return true;
        return <Object?, Object?>{
          'bytes': _jpeg(4),
          'mime': 'image/jpeg',
          'encoding': 'jpeg',
          'width': 160,
          'height': 90,
        };
      });
      const extractor = MethodChannelVideoFrameExtractor();
      expect(await extractor.isSupported(), isTrue);
      final r = await extractor.extract('/tmp/a.bin', atMs: 1500, maxWidth: 200);
      expect(r, isNotNull);
      expect(r!.bytes, _jpeg(4));
      expect(r.mime, 'image/jpeg');
      expect(r.width, 160);
      expect(r.height, 90);
      expect(calls.length, 2);
      expect(calls[1].method, 'extractFrame');
      expect(calls[1].arguments, {
        'path': '/tmp/a.bin',
        'atMs': 1500,
        'maxWidth': 200,
      });
    });

    test('原生抛 PlatformException / 回 null ⇒ Dart 侧一律 null（不抛）', () async {
      setHandler(
        (call) async => throw PlatformException(code: 'decode_failed'),
      );
      const extractor = MethodChannelVideoFrameExtractor();
      expect(await extractor.extract('/tmp/a.bin'), isNull);
      expect(await extractor.isSupported(), isFalse);

      setHandler((call) async => null);
      expect(await extractor.extract('/tmp/a.bin'), isNull);
    });

    test('非 Android（宿主）⇒ 直接 null，且一个通道消息都不发', () async {
      MethodChannelVideoFrameExtractor.debugForceAndroid = false;
      setHandler((call) async => true);
      const extractor = MethodChannelVideoFrameExtractor();
      expect(await extractor.isSupported(), isFalse);
      expect(await extractor.extract('/tmp/a.bin'), isNull);
      expect(await extractor.extract(''), isNull);
      expect(calls, isEmpty);
    });
  });

  // ============================================================ 能力门（第 76 轮回归）
  //
  // ## 钉的是什么（真机回归，用户可见）
  // 两个抽帧桥的 `_isAndroid` 一度写成 `canUse(AppCapability.videoFrameExtraction)`。
  // `canUse` = `capabilities.can` = **只有 `available` 才为 true**；而 Android 上
  // 这条能力的静态结论是 `unknown`（桥在不在要问了才知道），且
  // `AppPlatformCapabilities.current()` 是**工厂**（不读探测结果）⇒ 真机上恒 false
  // ⇒ 三条抽帧路连通道都不碰就返回 null ⇒ 视频行只剩图标、缓存全空、**无任何日志**。
  //
  // 下面两条是**反向验证**：能力 `unknown`（Android）必须**尝试**调通道；
  // 能力 `unavailable`（macOS/Linux/Windows）必须**一个消息都不发**。
  // 谁把 `capabilityGateAllows` 换回 `canUse`，第一条当场红。
  group('能力门：unknown 放行 / unavailable 拦下（第 76 轮回归）', () {
    const channel = MethodChannel(kVideoFrameChannel);
    final calls = <MethodCall>[];

    void setHandler() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'isSupported') return true;
            return <Object?, Object?>{
              'bytes': _jpeg(4),
              'mime': 'image/jpeg',
              'width': 320,
              'height': 180,
            };
          });
    }

    setUp(() {
      calls.clear();
      // 两个桥都不许用 `debugForceAndroid` 抄近路 —— 本组测的就是能力门本身。
      MethodChannelVideoFrameExtractor.debugForceAndroid = false;
      MethodChannelVideoFrameStageExtractor.debugForceAndroid = false;
      setHandler();
    });

    tearDown(() {
      debugForceAppHost = null;
      MethodChannelVideoFrameExtractor.debugForceAndroid = false;
      MethodChannelVideoFrameStageExtractor.debugForceAndroid = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('Android 宿主（能力静态 unknown）⇒ 两个桥都必须放行去试通道', () async {
      debugForceAppHost = AppHost.android;
      const core = MethodChannelVideoFrameExtractor();
      expect(await core.isSupported(), isTrue);
      expect(await core.extract('/tmp/a.bin'), isNotNull);

      const stage = MethodChannelVideoFrameStageExtractor();
      expect(await stage.isSupported(), isTrue);
      expect(await stage.extractDetailed('/tmp/a.bin'), isNotNull);
      expect(
        await stage.extractDetailedUrl('https://h/x.mp4', const {}),
        isNotNull,
      );
      expect(
        await stage.extractFrameViaPlayer('https://h/x.mp4', const {}),
        isNotNull,
      );

      final methods = calls.map((c) => c.method).toList();
      expect(methods, contains('extractFrame'));
      expect(methods, contains('extractFrameEx'));
      expect(methods, contains('extractFramePlayer'));
    });

    test('macOS 宿主（能力 unavailable）⇒ 两个桥都不碰通道', () async {
      debugForceAppHost = AppHost.macos;
      const core = MethodChannelVideoFrameExtractor();
      expect(await core.isSupported(), isFalse);
      expect(await core.extract('/tmp/a.bin'), isNull);

      const stage = MethodChannelVideoFrameStageExtractor();
      expect(await stage.isSupported(), isFalse);
      expect(await stage.extractDetailed('/tmp/a.bin'), isNull);
      expect(
        await stage.extractDetailedUrl('https://h/x.mp4', const {}),
        isNull,
      );
      expect(
        await stage.extractFrameViaPlayer('https://h/x.mp4', const {}),
        isNull,
      );
      expect(calls, isEmpty);
    });
  });

  // ============================================================ Riverpod 接线

  group('provider 接线', () {
    test('videoFrameThumbProvider 走缓存与加载器；做不了的请求直接 null', () async {
      var loaderCalls = 0;
      final container = ProviderContainer(
        overrides: [
          // 第 267 轮起生产缓存优先用 **detailedLoader**（能带回失败分层）；
          // 老 `videoFrameLoaderProvider` 退化成回退路径（缺 detailedLoader 时才用）。
          videoFrameDetailedLoaderProvider.overrideWithValue((request) async {
            loaderCalls++;
            return VideoFrameThumbOutcome(bytes: _jpeg(21));
          }),
        ],
      );
      addTearDown(container.dispose);

      final ok = _req('a');
      // ⚠️ `autoDispose` provider 没有监听者时会在读到 future 之后立刻被回收，
      // 回收会触发 `ref.onDispose` ⇒ `cache.cancel(...)`（这正是"滚出去就取消"
      // 的机制）。所以要**先订阅**，模拟"列表项还在屏幕上"。
      final sub = container.listen(videoFrameThumbProvider(ok), (_, _) {});
      addTearDown(sub.close);

      expect(await container.read(videoFrameThumbProvider(ok).future), _jpeg(21));
      expect(loaderCalls, 1);
      // 第二次由 **FutureProvider 自己的状态**直接给值（连缓存都不用问）
      expect(await container.read(videoFrameThumbProvider(ok).future), _jpeg(21));
      expect(loaderCalls, 1);
      expect(container.read(videoFrameThumbCacheProvider).stats.loaded, 1);

      // 判定为"做不了"的请求（Drive 大文件）⇒ null，且不碰加载器
      final bad = VideoFrameThumbRequest(
        cacheKey: 'bad',
        uri: 'u',
        extension: 'mp4',
        size: kVideoFrameHeadBytes * 2,
        rangeSupported: false,
      );
      expect(await container.read(videoFrameThumbProvider(bad).future), isNull);
      expect(loaderCalls, 1);
      expect(container.read(videoFrameThumbSupportedProvider(bad)), isFalse);
      expect(container.read(videoFrameThumbSupportedProvider(ok)), isTrue);
    });

    test('videoFrameThumbRequestFor：只有"视频条目 + 视频来源 + 容器后缀"才给请求', () {
      final video = _src('a.mp4', MediaKind.video);
      // 目录
      expect(
        videoFrameThumbRequestFor(
          _entry('Movies', isDir: true),
          _src('a.mp4', MediaKind.video),
        ),
        isNull,
      );
      // 来源不是视频
      expect(
        videoFrameThumbRequestFor(
          _entry('a.mp4'),
          _src('a.mp4', MediaKind.audio),
        ),
        isNull,
      );
      // 直链空（还没登录 / 服务端不给直链）
      expect(
        videoFrameThumbRequestFor(
          _entry('a.mp4'),
          _src('a.mp4', MediaKind.video, uri: ''),
        ),
        isNull,
      );
      // 后缀不在容器白名单
      expect(
        videoFrameThumbRequestFor(
          _entry('a.jpg'),
          _src('a.jpg', MediaKind.video),
        ),
        isNull,
      );

      // Drive 的视频来源：`playable == false`（写死 Accept-Ranges: none）
      // 但 uri 在 ⇒ **仍然要出请求**，只是 rangeSupported=false
      final drive = videoFrameThumbRequestFor(
        _entry('a.mp4', size: 2048, mtime: 77),
        _src('a.mp4', MediaKind.video, range: false),
      );
      expect(drive, isNotNull);
      expect(drive!.cacheKey, 'vframe|/home/a.mp4|77|2048');
      expect(drive.rangeSupported, isFalse);
      expect(drive.extension, 'mp4');
      expect(videoFrameThumbSupported(drive), isTrue);
      expect(videoFrameThumbRequestFor(_entry('a.mp4', mtime: 77), video), isNotNull);
    });
  });
}

// ------------------------------------------------------------ DTO 夹具

FileEntryDto _entry(
  String name, {
  bool isDir = false,
  int size = 10,
  int mtime = 1,
}) => FileEntryDto(
  name: name,
  path: '/home/$name',
  isDir: isDir,
  size: size,
  mtime: mtime,
);

MediaSource _src(
  String displayName,
  MediaKind kind, {
  String uri = 'https://nas/entry.cgi?_sid=x',
  bool range = true,
}) => MediaSource(
  uri: uri,
  channel: MediaChannel.fileStation,
  kind: kind,
  displayName: displayName,
  supportsRange: range,
);
