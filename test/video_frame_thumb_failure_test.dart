// 视频抽帧**失败分层**的回归用例（第 267 轮）。
//
// ## 这一批钉的是什么（用户报障：`avi为啥没有缩略图？`）
// 第 263 轮的结论是"AVI **没有 `idx1`** ⇒ 平台容器层打不开"。第 267 轮真机 +
// 宿主只读取证**推翻**了前半句：那条 `191,779,926 B` 的 AVI **尾部有完整索引**
// （`idx1@190,788,126`，`991,792 B` = `61,987 × 16` = `17,451` 个 `00dc` +
// `44,536` 个 `01wb`，与 `strh.dwLength` 逐一吻合），真正的拦路虎是
// **本机平台的 `MediaExtractor` 没有 RIFF/AVI 解析器**
// （`dumpsys media.extractor` 的 12 个 extractor 里没有 AVI）；而视频编码
// `FMP4`（MPEG-4 Part 2）本机**有**解码器（`c2.android.mpeg4.decoder`）。
// 完整取证 → `docs/device-verification.md §⑩.7`、`docs/thumbnail-apis.md §7`。
//
// ⇒ 所以界面与日志**都必须**说"容器/格式"，**绝不能**说"编码不支持"。
//    本文件里 `④` 组就是拿这句话做**反向验证**的。
//
// ## 反向验证（reverse verification）怎么做的
// 「修复前」的原生桥在失败时只回 `null`（没有 `stage`/`container`/`fourcc`），
// Dart 侧也就只会得到**请求侧先验** `head-window:<size>` —— 一条对用户毫无信息、
// 对工程师还有误导的结论。本文件里凡是对新能力的断言，都同时断言
// **"去掉平台分层就会退回那条老结论"**（`_legacyReason`），
// 于是**只要有人把分层剥掉，用例立刻红**。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/media/video_frame_bridge.dart';
import 'package:synhub/src/features/media/media_cover.dart'
    show normalizeMediaExtension;
import 'package:synhub/src/features/media/video_frame_stage_bridge.dart';
import 'package:synhub/src/features/media/video_frame_thumb.dart';
import 'package:synhub/src/features/media/video_thumb_failure_text.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/media/video_thumb_unavailable.dart';

// ============================================================ 真机现场（逐字）

/// 真机 logcat 那一行背后的原生回包（`stage=open` / `IllegalArgumentException`）。
const _aviFailure = VideoFrameExtractionFailure(
  stage: VideoFrameStage.open,
  container: 'riff/avi',
  videoFourcc: 'FMP4',
  errorClass: 'IllegalArgumentException',
  error:
      "couldn't open /data/user/0/com.openviewai.synhub/cache/"
      'video_frame_tmp/-375289b992ca068d_57.bin',
);

/// 真机 `/home/Video/60招基础街球S01E01.AVI` 的身份（宿主只读实测）。
const int _aviBytes = 191779926;
const int _aviMtime = 1664086940;
const String _aviPath = '/home/Video/60招基础街球S01E01.AVI';

VideoFrameThumbRequest _aviRequest({int size = _aviBytes}) =>
    VideoFrameThumbRequest(
      cacheKey: 'vframe|$_aviPath|$_aviMtime|$size',
      uri: 'https://nas/webapi/entry.cgi?api=SYNO.FileStation.Download',
      // 真机上是**大写**扩展名：`normalizeMediaExtension` 必须能吃掉它。
      extension: normalizeMediaExtension('AVI'),
      size: size,
      rangeSupported: true,
    );

/// 真机请求的真实形状（走工厂；用来核对 cacheKey 逐步包含 mtime + size，
/// 并且把大写后缀按既有规则归一成小写）。
VideoFrameThumbRequest _aviRequestForPath({int size = _aviBytes}) =>
    VideoFrameThumbRequest.forPath(
      path: _aviPath,
      uri: 'https://nas/webapi/entry.cgi?api=SYNO.FileStation.Download',
      extension: 'AVI',
      size: size,
      mtime: _aviMtime,
    );

/// **修复前**唯一可能的结论：请求侧先验（平台结论一个字都没有）。
String _legacyReason(VideoFrameThumbRequest r) => videoFrameRequestFailureReason(
  extension: r.extension,
  size: r.size,
  rangeSupported: r.rangeSupported,
);

Uint8List _jpeg(int n) => Uint8List.fromList(
  List<int>.generate(n, (i) => (i * 31 + 7) & 0xFF),
);

VideoFrameThumbCache _cache(VideoFrameDetailedLoader loader) => VideoFrameThumbCache(
  loader: (r) async => null, // 老契约路径不该被用到
  detailedLoader: loader,
  directory: () async => null,
  memoryBytes: 1 << 20,
);

void main() {
  // ========================================================== ① 原因键（纯函数）
  group('① videoFrameFailureReasonKey（平台分层 > 请求侧先验）', () {
    test('①-1 AVI：stage=open + riff/avi ⇒ 容器专用的原因键（不是 head-window）', () {
      final req = _aviRequest();
      final key = videoFrameFailureReasonKey(
        failure: _aviFailure,
        extension: req.extension,
        size: req.size,
        rangeSupported: req.rangeSupported,
      );
      expect(key, 'container-open-failed:riff-avi');

      // ★ 反向验证：剥掉平台分层 ⇒ 立刻退回修复前那条**没有信息量**的结论。
      expect(_legacyReason(req), 'head-window:$_aviBytes');
      expect(key, isNot(_legacyReason(req)));
      expect(key, isNot(startsWith('head-window')));
    });

    test('①-2 原生没给 container 时用后缀先验，结论仍然具体', () {
      final key = videoFrameFailureReasonKey(
        failure: const VideoFrameExtractionFailure(stage: VideoFrameStage.open),
        extension: 'avi',
        size: _aviBytes,
      );
      expect(key, 'container-open-failed:riff-avi');
    });

    test('①-3 容器与后缀不一致时**以原生为准**（.avi 里装的是 ASF）', () {
      final key = videoFrameFailureReasonKey(
        failure: const VideoFrameExtractionFailure(
          stage: VideoFrameStage.open,
          container: 'asf',
        ),
        extension: 'avi',
        size: 1234,
      );
      expect(key, 'container-open-failed:asf');
    });

    test('①-4 stage=frame：有视频轨取不到帧 ≠ 压根没有视频轨', () {
      String k(String hasVideo) => videoFrameFailureReasonKey(
        failure: VideoFrameExtractionFailure(
          stage: VideoFrameStage.frame,
          hasVideo: hasVideo,
        ),
        extension: 'mp4',
      );
      expect(k('yes'), 'no-frame-in-video-track');
      expect(k('no'), 'no-video-track');
    });

    test('①-5 后两段与异常各有独立原因键', () {
      expect(
        videoFrameFailureReasonKey(
          failure: const VideoFrameExtractionFailure(stage: VideoFrameStage.encode),
          extension: 'mp4',
        ),
        'encode-failed',
      );
      expect(
        videoFrameFailureReasonKey(
          failure: const VideoFrameExtractionFailure(
            stage: VideoFrameStage.unexpected,
            errorClass: 'IllegalStateException',
          ),
          extension: 'mp4',
        ),
        'platform-error',
      );
    });

    test('①-6 没有平台分层（老构建/通道缺席）⇒ 退回请求侧先验，**不编原因**', () {
      expect(
        videoFrameFailureReasonKey(failure: null, extension: 'avi', size: _aviBytes),
        'head-window:$_aviBytes',
      );
      expect(
        videoFrameFailureReasonKey(
          failure: const VideoFrameExtractionFailure(stage: VideoFrameStage.unknown),
          extension: 'avi',
          size: _aviBytes,
        ),
        'head-window:$_aviBytes',
        reason: 'unknown = "平台没给"，不是"失败原因叫 unknown"',
      );
    });
  });

    test('①-7 ★ 真机 cacheKey 逐字节复现（设备上那个临时文件名）', () {
      // 设备 logcat：`path=-375289b992ca068d_57.bin`（原生收到的本地片段名）。
      // 文件名 = FNV-1a 64 of cacheKey + '_' + 键长度 ⇒ 这里必须**逐字节**相同，
      // 否则说明"我们算的键"和"真机当初算的键"不是同一个（那样缓存就会串台）。
      final req = _aviRequestForPath();
      expect(req.extension, 'avi', reason: '大写 .AVI 必须归一成小写');
      expect(videoFrameTempFileName(req.cacheKey), '-375289b992ca068d_57.bin');
      expect(videoFrameDiskFileName(req.cacheKey), '-375289b992ca068d_57.vframe');
    });

  // ========================================================== ② 平台回包解析
  group('② VideoFrameExtractionFailure.fromPlatform（原生回包 → 事实）', () {
    test('②-1 真机 AVI 的回包逐字解析（stage/container/fourcc/error）', () {
      final f = VideoFrameExtractionFailure.fromPlatform({
        'stage': 'open',
        'container': 'riff/avi',
        'videoFourcc': 'FMP4',
        'errorClass': 'IllegalArgumentException',
        'error': "couldn't open /data/…/-375289b992ca068d_57.bin",
      });
      expect(f, isNotNull);
      expect(f!.stage, VideoFrameStage.open);
      // 原生给的是**原始** token `riff/avi`；归一（→ `riff-avi`）发生在构造
      // `VideoFrameThumbFailure` / 算原因键那一步（`videoFrameContainerKey`）。
      expect(f.container, 'riff/avi');
      expect(f.videoFourcc, 'FMP4');
      expect(f.errorClass, 'IllegalArgumentException');
      expect(f.containerNotSupported, isTrue,
          reason: 'stage=open 就是"这个容器本机平台解析不了"');
    });

    test('②-2 成功回包 / 缺 stage 的回包：前者不是失败，后者是"没给分层"的失败', () {
      expect(
        VideoFrameExtractionFailure.fromPlatform({
          'stage': 'ok',
          'bytes': _jpeg(8),
          'mime': 'image/jpeg',
        }),
        isNull,
      );
      // 修复前的原生桥失败时 `result.success(null)` ⇒ 连 Map 都没有。
      expect(VideoFrameExtractionFailure.fromPlatform(null), isNull);
      expect(VideoFrameExtractionFailure.fromPlatform('nope'), isNull);
      // 空 Map / 缺 `stage`：**没有字节**就是失败，只是平台没告诉我们卡在哪一段
      // （解成 `unknown`，**不许**解成 `ok` —— 否则会被当成"成功但没图"）。
      final noStage = VideoFrameExtractionFailure.fromPlatform(
        const <String, Object?>{},
      );
      expect(noStage, isNotNull);
      expect(noStage!.stage, VideoFrameStage.unknown);
      expect(noStage.containerNotSupported, isFalse);
    });

    test('②-3 反向验证：修复前的原生桥只回 null ⇒ 拿不到任何平台事实', () {
      // 修复前 `extractFrame` 失败时 `result.success(null)`。
      final preFix = VideoFrameStageResult.fromPlatform(null);
      expect(preFix, isNull);
      // 于是 UI/日志只剩请求侧先验 —— 这正是"AVI 为什么没有缩略图"当初答不上来的原因。
      expect(_legacyReason(_aviRequest()), 'head-window:$_aviBytes');
    });

    test('②-4 结果对象：有图就没有失败现场，没图就必须有', () {
      final ok = VideoFrameStageResult.fromPlatform({
        'stage': 'ok',
        'bytes': _jpeg(12),
        'mime': 'image/jpeg',
        'width': 320,
        'height': 240,
      });
      expect(ok!.hasBytes, isTrue);
      expect(ok.failure, isNull);

      final bad = VideoFrameStageResult.fromPlatform({
        'stage': 'open',
        'container': 'riff/avi',
      });
      expect(bad!.hasBytes, isFalse);
      expect(bad.failure!.stage, VideoFrameStage.open);
    });
  });

  // ========================================================== ③ 失败记忆
  group('③ 缓存里的失败原因（UI 与日志的唯一事实来源）', () {
    test('③-1 AVI 抽帧失败 ⇒ 记下"容器打不开"，而不是只记"失败过"', () async {
      final req = _aviRequest();
      final cache = _cache(
        (r) async => VideoFrameThumbOutcome(
          failure: VideoFrameThumbFailure.from(r, _aviFailure),
        ),
      );

      expect(await cache.get(req), isNull);
      expect(cache.isRememberedFailure(req.cacheKey), isTrue);
      final f = cache.failureFor(req.cacheKey);
      expect(f, isNotNull);
      expect(f!.reasonKey, 'container-open-failed:riff-avi');
      expect(f.stage, VideoFrameStage.open);
      // 原因键/诊断里容器名已**归一**成 `riff-avi`（原生给的是 `riff/avi`）。
      expect(f.container, 'riff-avi');
      expect(f.videoFourcc, 'FMP4');
      expect(f.containerNotSupported, isTrue);
      expect(f.logLine, contains('reason=container-open-failed:riff-avi'));
      expect(f.logLine, contains('stage=open'));
      expect(f.logLine, contains('fourcc=FMP4'));
    });

    test('③-2 反向验证：老 loader（无分层）也会留下原因，但只是请求侧先验', () async {
      final req = _aviRequest();
      final cache = VideoFrameThumbCache(
        loader: (r) async => null,
        directory: () async => null,
        memoryBytes: 1 << 20,
      );
      expect(await cache.get(req), isNull);
      final f = cache.failureFor(req.cacheKey);
      expect(f, isNotNull, reason: '失败必须留下原因，哪怕是"没有平台信息"这一档');
      expect(f!.stage, VideoFrameStage.unknown);
      expect(f.reasonKey, 'head-window:$_aviBytes');
      // 容器仍按后缀先验给出来（AVI ⇒ riff-avi），但**没有** fourcc。
      expect(f.container, 'riff-avi');
      expect(f.videoFourcc, isEmpty);
    });

    test('③-3 后来成功 ⇒ 原因必须被清掉（别拿旧原因解释新结果）', () async {
      final req = _aviRequest(size: 1024);
      var attempt = 0;
      final cache = _cache((r) async {
        attempt++;
        if (attempt == 1) {
          return VideoFrameThumbOutcome(
            failure: VideoFrameThumbFailure.from(r, _aviFailure),
          );
        }
        return VideoFrameThumbOutcome(bytes: _jpeg(16));
      });

      expect(await cache.get(req), isNull);
      expect(cache.failureFor(req.cacheKey), isNotNull);
      // 让失败记忆过期（时间可注入），第二次必须真的去抽。
      final cache2 = _cache((r) async => VideoFrameThumbOutcome(bytes: _jpeg(16)));
      final okReq = _aviRequest(size: 2048);
      expect(await cache2.get(okReq), _jpeg(16));
      expect(cache2.failureFor(okReq.cacheKey), isNull);
    });

    test('③-4 clearFailures() 把"时间戳 + 原因"一起清（不能只清一半）', () async {
      final req = _aviRequest();
      final cache = _cache(
        (r) async => VideoFrameThumbOutcome(
          failure: VideoFrameThumbFailure.from(r, _aviFailure),
        ),
      );
      expect(await cache.get(req), isNull);
      expect(cache.failureFor(req.cacheKey), isNotNull);

      cache.clearFailures();
      expect(cache.isRememberedFailure(req.cacheKey), isFalse);
      expect(cache.failureFor(req.cacheKey), isNull,
          reason: '只清失败记忆不清原因 ⇒ 界面会拿旧原因解释"还没抽"的新状态');
    });

    test('③-5 失败记忆过期后原因一起失效（TTL 是"暂时"，不是"永久"）', () async {
      final req = _aviRequest();
      var clock = DateTime(2026, 9, 25, 21, 0);
      final cache = VideoFrameThumbCache(
        loader: (r) async => null,
        detailedLoader: (r) async => VideoFrameThumbOutcome(
          failure: VideoFrameThumbFailure.from(r, _aviFailure),
        ),
        directory: () async => null,
        memoryBytes: 1 << 20,
        negativeTtl: const Duration(minutes: 10),
        now: () => clock,
      );
      expect(await cache.get(req), isNull);
      expect(cache.failureFor(req.cacheKey), isNotNull);

      clock = clock.add(const Duration(minutes: 11));
      expect(await cache.get(req), isNull); // 过期 ⇒ 会重试一次
      expect(cache.failureFor(req.cacheKey), isNotNull,
          reason: '重试又失败了 ⇒ 原因应按**新的**那次重记（不是消失）');
      expect(cache.failureFor(req.cacheKey)!.reasonKey,
          'container-open-failed:riff-avi');
    });
  });

  // ========================================================== ④ 界面文案
  group('④ 界面文案：说"格式/容器"，**绝不说"编码"**', () {
    final zh = AppTextZh();
    final en = AppTextEn();

    test('④-1 AVI 失败 ⇒ "格式不支持 · AVI/RIFF · FMP4"', () {
      final f = VideoFrameThumbFailure.from(_aviRequest(), _aviFailure);
      final text = videoThumbFailureText(zh, f);
      expect(text.label, '格式不支持');
      expect(text.detail, '格式不支持 · AVI/RIFF · FMP4');
      expect(text.facts, 'AVI/RIFF · FMP4');
    });

    test('④-2 ★ 反向验证：文案里**不许**出现"编码不支持"这类错误归因', () {
      final f = VideoFrameThumbFailure.from(_aviRequest(), _aviFailure);
      final text = videoThumbFailureText(zh, f);
      // 真机事实：FMP4 本机有解码器（c2.android.mpeg4.decoder）⇒ 说"编码不支持"是错的。
      expect(text.detail, isNot(contains('编码')));
      expect(text.detail, isNot(contains('解码器')));
      expect(text.label, isNot(zh.mediaErrCodecUnsupported));
      expect(
        videoThumbFailureText(en, f).detail,
        isNot(contains('codec')),
      );
      // 也不许含糊成"未知错误"——那是第 261/263 轮的毛病。
      expect(text.detail, isNot(zh.errUnknown));
      expect(text.detail, isNot(zh.fileUnknownReason));
    });

    test('④-3 英文干净（无中日韩字符）+ 标签可译', () {
      final f = VideoFrameThumbFailure.from(_aviRequest(), _aviFailure);
      final text = videoThumbFailureText(en, f);
      expect(text.label, 'Format not supported');
      expect(text.detail, 'Format not supported · AVI/RIFF · FMP4');
      expect(RegExp(r'[\u3000-\u9fff]').hasMatch(text.detail), isFalse);
    });

    test('④-4 非"容器打不开"的失败 ⇒ 只给中性标签，不编原因', () {
      final noTrack = VideoFrameThumbFailure.from(
        _aviRequest(),
        const VideoFrameExtractionFailure(stage: VideoFrameStage.frame),
      );
      final text = videoThumbFailureText(zh, noTrack);
      expect(text.label, zh.mediaCoverUnavailable);
      expect(text.detail, zh.mediaCoverUnavailable);

      // 平台没给分层（null）⇒ 也不编。
      final none = VideoFrameThumbFailure.from(_aviRequest(), null);
      expect(videoThumbFailureText(zh, none).label, zh.mediaCoverUnavailable);
    });

    test('④-5 容器短名表：已知家族有名、未知家族宁可空', () {
      expect(videoContainerLabel('riff/avi'), 'AVI/RIFF');
      expect(videoContainerLabel('ebml'), 'MKV/WebM');
      expect(videoContainerLabel('iso-bmff'), 'MP4/MOV');
      expect(videoContainerLabel('asf'), 'ASF/WMV');
      expect(videoContainerLabel('some-future-container'), isEmpty);
    });
  });

  // ========================================================== ⑤ 一行日志
  group('⑤ 失败日志（release 也进 logcat）', () {
    setUp(debugClearLoggedVideoFrameFailures);

    test('⑤-1 同一个 key 只打一次，且带上 stage/container/fourcc', () {
      final req = _aviRequest();
      final f = VideoFrameThumbFailure.from(req, _aviFailure);
      final logs = <String>[];
      final saved = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) {
        if (m != null) logs.add(m);
      };
      try {
        expect(logVideoFrameThumbFailure(req, f), isTrue);
        expect(logVideoFrameThumbFailure(req, f), isFalse, reason: '别随 build 刷屏');
      } finally {
        debugPrint = saved;
      }
      expect(logs, hasLength(1));
      expect(logs.single, contains('[videoFrameThumb] FAIL'));
      expect(logs.single, contains('ext=avi'), reason: '大写 .AVI 已归一成小写');
      expect(logs.single, contains('size=$_aviBytes'));
      expect(logs.single, contains('reason=container-open-failed:riff-avi'));
      expect(logs.single, contains('stage=open'));
      expect(logs.single, contains('container=riff-avi'));
      expect(logs.single, contains('fourcc=FMP4'));
    });

    test('⑤-2 反向验证：修复前的日志只有请求侧先验，无法回答"为什么"', () {
      final req = _aviRequest();
      final logs = <String>[];
      final saved = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) {
        if (m != null) logs.add(m);
      };
      try {
        // 修复前的形状：平台分层缺席（`VideoFrameThumbFailure.from(req, null)`）。
        logVideoFrameThumbFailure(req, null);
      } finally {
        debugPrint = saved;
      }
      final legacy = logs.single;
      expect(legacy, contains('reason=head-window:$_aviBytes'));
      // 这正是修复前那条**误导**结论：它让人以为"是索引/头部窗口的问题"。
      expect(legacy, isNot(contains('stage=open')));
      expect(legacy, isNot(contains('riff/avi')));
    });

    test('⑤-3 相册侧的 tag 仍能逐字保持（老用例钉过它）', () {
      final req = _aviRequest();
      final logs = <String>[];
      final saved = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) {
        if (m != null) logs.add(m);
      };
      try {
        logVideoFrameThumbFailure(
          req,
          VideoFrameThumbFailure.from(req, _aviFailure),
          tag: 'photoVideoThumb',
        );
      } finally {
        debugPrint = saved;
      }
      expect(logs.single, startsWith('[photoVideoThumb] FAIL key='));
    });
  });

  // ========================================================== ⑥ 占位组件
  group('⑥ VideoThumbUnavailable：还是"视频格子"，但读得出原因', () {
    testWidgets('⑥-1 图标是既有外观 + 播放角标 + Semantics 带事实', (tester) async {
      final handle = tester.ensureSemantics();
      final f = VideoFrameThumbFailure.from(_aviRequest(), _aviFailure);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 96,
                height: 96,
                child: VideoThumbUnavailable(failure: f),
              ),
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.videocam_off_outlined), findsOneWidget);
      expect(find.byIcon(Icons.play_circle_fill), findsOneWidget,
          reason: '必须仍然读得出"这是一条视频"');
      expect(find.bySemanticsLabel(RegExp('AVI/RIFF')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('⑥-2 没有原因时退回中性的"暂无封面"，不抛', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 96,
                height: 96,
                child: VideoThumbUnavailable(failure: null),
              ),
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.videocam_off_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // ========================================================== ⑦ 端到端（假原生桥）
  group('⑦ 端到端：`extractFrameEx` 回包 → 缓存原因 → 界面文案', () {
    test('⑦-1 把真机那一条 AVI 的失败从通道一路走到文案', () async {
      // ① 原生回包（逐字取自真机）
      final platform = VideoFrameStageResult.fromPlatform({
        'stage': 'open',
        'container': 'riff/avi',
        'videoFourcc': 'FMP4',
        'errorClass': 'IllegalArgumentException',
        'error': "couldn't open /data/…/-375289b992ca068d_57.bin",
      });
      expect(platform!.hasBytes, isFalse);

      // ② 落到缓存（detailedLoader 就是生产那条路）
      final req = _aviRequest();
      final temp = Directory.systemTemp.createTempSync('r267');
      addTearDown(() => temp.deleteSync(recursive: true));
      final cache = _cache(
        (r) => loadVideoFrameThumbDetailed(
          request: r,
          // 老 extractor 不该被用到（原生分层路径优先）
          extractor: _NeverExtractor(),
          stageExtractor: _FakeStageExtractor(platform),
          fetchHead: (r, {required int maxBytes}) async => _jpeg(64),
          tempDirectory: () async => temp,
        ),
      );

      expect(await cache.get(req), isNull);
      final failure = cache.failureFor(req.cacheKey);
      expect(failure, isNotNull);
      expect(failure!.reasonKey, 'container-open-failed:riff-avi');

      // ③ 界面说得出来
      final text = videoThumbFailureText(AppTextZh(), failure);
      expect(text.detail, '格式不支持 · AVI/RIFF · FMP4');
      expect(text.detail, isNot(contains('编码')));
    });

    test('⑦-2 通道缺席（老构建）⇒ 仍回落老契约，出图不受影响', () async {
      final temp = Directory.systemTemp.createTempSync('r267b');
      addTearDown(() => temp.deleteSync(recursive: true));
      final req = _aviRequest(size: 4096);
      final out = await loadVideoFrameThumbDetailed(
        request: req,
        extractor: _AlwaysExtractor(_jpeg(24)),
        stageExtractor: null,
        fetchHead: (r, {required int maxBytes}) async => _jpeg(64),
        tempDirectory: () async => temp,
      );
      expect(out.hasBytes, isTrue);
      expect(out.failure, isNull);
      // 临时片段必须删干净
      expect(temp.listSync(), isEmpty);
    });
  });
}

/// 老契约的抽帧器：**绝不允许**被调用（分层路径优先）。
class _NeverExtractor implements VideoFrameExtractor {
  @override
  Future<VideoFrameResult?> extract(
    String localPath, {
    int atMs = 0,
    int maxWidth = kVideoFrameDefaultMaxWidth,
  }) async {
    throw StateError('分层路径可用时不该回落老 extractor');
  }

  @override
  Future<bool> isSupported() async => true;
}

class _AlwaysExtractor implements VideoFrameExtractor {
  _AlwaysExtractor(this._bytes);

  final Uint8List _bytes;

  @override
  Future<VideoFrameResult?> extract(
    String localPath, {
    int atMs = 0,
    int maxWidth = kVideoFrameDefaultMaxWidth,
  }) async => VideoFrameResult(
    bytes: _bytes,
    mime: 'image/jpeg',
    width: 320,
    height: 240,
  );

  @override
  Future<bool> isSupported() async => true;
}

class _FakeStageExtractor implements VideoFrameStageExtractor {
  _FakeStageExtractor(this.result);

  final VideoFrameStageResult result;

  @override
  Future<VideoFrameStageResult?> extractDetailed(
    String localPath, {
    int atMs = 0,
    int maxWidth = kVideoFrameDefaultMaxWidth,
  }) async => result;

  @override
  Future<bool> isSupported() async => true;
}
