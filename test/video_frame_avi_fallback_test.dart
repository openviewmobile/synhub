// 自研 **AVI 首帧抽取**的离线回归用例（第 269 轮）。
//
// ## 背景（用户裁决）
// 「avi 如果你能自研抽取首帧也可以」。第 267 轮已定案：那条 183 MB 的
// `/home/Video/60招基础街球S01E01.AVI` 抽不出帧，**不是**编码问题
// （`FMP4` = MPEG-4 Part 2，本机有 `c2.android.mpeg4.decoder`）、**不是**索引问题
// （尾部 `idx1@190,788,126` 完整），而是**平台 `MediaExtractor` 没有 RIFF/AVI 解析器**。
// ⇒ 缺的只是**容器解析**：原生新增 `AviFirstFrame.kt`（自写 RIFF 走查 + 平台 `MediaCodec`），
// `VideoFrameBridge` 在 `stage=open` 且容器为 `riff/avi` 时走它。
//
// ## 本文件能证明什么 / 不能证明什么（**诚实分栏**）
// ✅ 能（不依赖设备）：容器闸门规则、fourcc→MIME 表、窗口/上限判据、四档新 stage 的
//    原因键映射、原生回包解析、MP4/MKV **不会**被判成 AVI 路径、界面归因不串。
// ❌ 不能：**真机上到底有没有出图**。离线跑不了 `MediaCodec`，也跑不了真容器字节；
//    那需要装包 + `logcat`/`screencap`（父 agent 做）。本文件里的 "真机回包" 都是
//    **按契约构造**的（契约由 `AviFirstFrame.kt` 的 stage/字段定义），不是设备实测。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/features/media/video_frame_stage_bridge.dart';
import 'package:synhub/src/features/media/video_frame_thumb.dart';
import 'package:synhub/src/features/media/video_thumb_failure_text.dart';

// ============================================================ 真机/真字节事实（只读取证）

/// `/home/Video/60招基础街球S01E01.AVI`（宿主只读 Range 实测，`/tmp/r269_probe.out`）
const int _aviBytes = 191779926;
const String _aviPath = '/home/Video/60招基础街球S01E01.AVI';
// movi 起点与第一个视频块（绝对偏移，payload 起点 9918、块头 9910）
const int _moviOffset = 9898;
const int _firstChunkOffset = 9910;
const int _firstChunkSize = 902;
// 头 512 KiB 窗口里顺序走查到的视频块数 / ES 字节
const int _probeEsFrames = 48;
const int _probeEsBytes = 498295;

VideoFrameThumbRequest _aviRequest({int size = _aviBytes}) =>
    VideoFrameThumbRequest(
      cacheKey: 'vframe|$_aviPath|1664086940|$size',
      uri: 'https://nas/webapi/entry.cgi?api=SYNO.FileStation.Download',
      extension: 'avi',
      size: size,
      rangeSupported: true,
    );

Uint8List _jpeg(int n) =>
    Uint8List.fromList(List<int>.generate(n, (i) => (i * 31 + 7) & 0xFF));

/// 文案用例的便捷构造：请求侧固定成那条真机 AVI。
VideoThumbFailureText _text(AppText t, VideoFrameExtractionFailure f) =>
    videoThumbFailureText(t, VideoFrameThumbFailure.from(_aviRequest(), f));

void main() {
  // ========================================================== ① 容器闸门
  group('① aviFallbackApplies：只有 RIFF/AVI 才进自研路径', () {
    test('①-1 riff/avi（原生写法）与 riff-avi（后缀先验）都为真', () {
      expect(aviFallbackApplies('riff/avi'), isTrue);
      expect(aviFallbackApplies('riff-avi'), isTrue,
          reason: '两种写法必须收敛（videoFrameContainerKey 归一）');
    });

    test('①-2 ★ MP4/MKV/其它容器一律为假（快路径绝不进自研 AVI）', () {
      for (final c in [
        'iso-bmff', // mp4/mov/3gp
        'ebml', // mkv/webm
        'asf', // wmv/asf
        'mpeg-ts',
        'mpeg-ps',
        'ogg',
        'flv',
        'riff', // 是 RIFF，但 form 不是 `AVI `（如 WAV）
        'unknown',
        '',
      ]) {
        expect(aviFallbackApplies(c), isFalse, reason: '$c 不是 AVI');
      }
    });

    test('①-3 反向验证：闸门放宽成"所有 riff"⇒ 立刻把 WAV 也当 AVI', () {
      // 修复前那种"看后缀/看 RIFF 就上"的写法（反面例子，仅用于证明闸门有区分度）
      bool loose(String c) => videoFrameContainerKey(c).startsWith('riff');
      expect(loose('riff'), isTrue);
      expect(aviFallbackApplies('riff'), isFalse,
          reason: '严格闸门不认纯 riff（WAV/AIFF 也是 RIFF）');
    });
  });

  // ========================================================== ② fourcc → MIME
  group('② aviFourccMime：fourcc → 平台解码器 MIME（与 AviFirstFrame.kt 同表）', () {
    test('②-1 MPEG-4 Part 2 家族 → video/mp4v-es（真机那条 AVI 的 FMP4）', () {
      for (final f in ['FMP4', 'XVID', 'DIVX', 'DX50', 'MP4V', 'MP4S', 'M4S2']) {
        expect(aviFourccMime(f), 'video/mp4v-es', reason: f);
      }
    });

    test('②-2 MJPG / H264 / HEVC 各自归到自己的 MIME', () {
      expect(aviFourccMime('MJPG'), 'video/mjpeg');
      expect(aviFourccMime('MJPEG'), 'video/mjpeg');
      expect(aviFourccMime('H264'), 'video/avc');
      expect(aviFourccMime('X264'), 'video/avc');
      expect(aviFourccMime('AVC1'), 'video/avc');
      expect(aviFourccMime('H265'), 'video/hevc');
      expect(aviFourccMime('HEVC'), 'video/hevc');
      expect(aviFourccMime('HVC1'), 'video/hevc');
    });

    test('②-3 不认识 / 空 / 十六进制 → 空串（**绝不许猜 MIME**）', () {
      expect(aviFourccMime(''), isEmpty);
      expect(aviFourccMime('ZZZZ'), isEmpty);
      expect(aviFourccMime('0x00000001'), isEmpty, reason: '音频那种非可打印 fourcc');
      expect(aviFourccMime('RMVB'), isEmpty);
      // 表里没有任何一项是空值/占位
      for (final e in kAviFourccMime.entries) {
        expect(e.value, isNotEmpty, reason: e.key);
        expect(e.value, contains('/'));
      }
    });

    test('②-4 大小写与两端空白容错（AVI 里 fourcc 常是大写，也可能有填充）', () {
      expect(aviFourccMime('fmp4'), 'video/mp4v-es');
      expect(aviFourccMime(' Xvid '), 'video/mp4v-es');
      expect(aviFourccMime('mJpG'), 'video/mjpeg');
    });
  });

  // ========================================================== ③ 窗口 / 上限纪律
  group('③ 窗口与上限（**绝不为一张缩略图下整份 191 MB**）', () {
    test('③-1 真字节：关键帧在 6 MiB 头部窗口内', () {
      expect(
        aviKeyframeInsideWindow(
          chunkOffset: _firstChunkOffset,
          chunkSize: _firstChunkSize,
        ),
        isTrue,
      );
      // 块头 9910 + 902 = 10,812（负载 9918..10820），远小于 6 MiB
      expect(_firstChunkOffset + _firstChunkSize, 10812);
      expect(_firstChunkOffset + _firstChunkSize, lessThan(kVideoFrameHeadBytes));
    });

    test('③-2 关键帧在窗口外 / 未知偏移 ⇒ false（诚实失败，不下更多字节）', () {
      expect(
        aviKeyframeInsideWindow(
          chunkOffset: 7 * 1024 * 1024,
          chunkSize: 902,
        ),
        isFalse,
      );
      expect(aviKeyframeInsideWindow(chunkOffset: -1, chunkSize: 902), isFalse);
      expect(aviKeyframeInsideWindow(chunkOffset: 100, chunkSize: 0), isFalse);
      // 边界：正好贴住窗口上沿算"在里面"
      expect(
        aviKeyframeInsideWindow(
          chunkOffset: kVideoFrameHeadBytes - 902,
          chunkSize: 902,
        ),
        isTrue,
      );
      expect(
        aviKeyframeInsideWindow(
          chunkOffset: kVideoFrameHeadBytes - 901,
          chunkSize: 902,
        ),
        isFalse,
      );
    });

    test('③-3 aviCapElementaryStream：64 块 / 2 MiB 两条上限都生效', () {
      // 块数上限
      final many = List<int>.filled(200, 1024);
      final r1 = aviCapElementaryStream(many);
      expect(r1.frames, kAviMaxEsFrames);
      expect(r1.bytes, kAviMaxEsFrames * 1024);

      // 字节上限：第一块就 3 MiB ⇒ 一块都不喂
      expect(aviCapElementaryStream([3 * 1024 * 1024]).frames, 0);
      // 正好 2 MiB 收下，再来一块就得停
      final r2 = aviCapElementaryStream([2 * 1024 * 1024, 1]);
      expect(r2.frames, 1);
      expect(r2.bytes, kAviMaxEsBytes);
      // 空表 / 非正大小被跳过
      expect(aviCapElementaryStream(const []).frames, 0);
      expect(aviCapElementaryStream([0, -5, 100]).frames, 1);
    });

    test('③-4 ★ 真字节 ES 在两条上限内（宿主探针实测 48 块 / 498,295 B）', () {
      // 探针给的是"头 512 KiB 窗口里顺序走查到的合计"，这里用同口径复核上限余量。
      expect(_probeEsFrames, lessThanOrEqualTo(kAviMaxEsFrames));
      expect(_probeEsBytes, lessThanOrEqualTo(kAviMaxEsBytes));
      // 重建 48 块的近似分布（均值），验证上限不会误伤真实样本
      final sizes = List<int>.filled(_probeEsFrames, _probeEsBytes ~/ _probeEsFrames);
      final r = aviCapElementaryStream(sizes);
      expect(r.frames, _probeEsFrames);
      expect(r.bytes, lessThanOrEqualTo(kAviMaxEsBytes));
    });
  });

  // ========================================================== ④ stage 词表
  group('④ VideoFrameStage：四档新 stage 的 key/parse 往返', () {
    test('④-1 四个 avi-* 逐一往返，且与原生 stage= 逐字一致', () {
      const map = {
        'avi-parse': VideoFrameStage.aviParse,
        'avi-keyframe': VideoFrameStage.aviKeyframe,
        'avi-codec': VideoFrameStage.aviCodec,
        'avi-decode': VideoFrameStage.aviDecode,
      };
      map.forEach((raw, stage) {
        expect(VideoFrameStage.parse(raw), stage, reason: raw);
        expect(stage.key, raw, reason: 'key 必须与 logcat 的 stage= 逐字相同');
        expect(stage.aviFallbackStage, isTrue);
      });
    });

    test('④-2 老 stage 不受影响，未知串仍是 unknown（不是"失败原因=unknown"）', () {
      expect(VideoFrameStage.parse('open'), VideoFrameStage.open);
      expect(VideoFrameStage.parse('frame'), VideoFrameStage.frame);
      expect(VideoFrameStage.parse('encode'), VideoFrameStage.encode);
      expect(VideoFrameStage.parse('avi-nope'), VideoFrameStage.unknown);
      expect(VideoFrameStage.open.aviFallbackStage, isFalse);
      expect(VideoFrameStage.frame.aviFallbackStage, isFalse);
      expect(VideoFrameStage.unknown.aviFallbackStage, isFalse);
    });
  });

  // ========================================================== ⑤ 原因键映射
  group('⑤ videoFrameFailureReasonKey：自研 AVI 四档各说各的', () {
    String key(VideoFrameExtractionFailure f, {int size = _aviBytes}) =>
        videoFrameFailureReasonKey(failure: f, extension: 'avi', size: size);

    test('⑤-1 avi-parse：容器头都解不出', () {
      expect(
        key(const VideoFrameExtractionFailure(
          stage: VideoFrameStage.aviParse,
          container: 'riff/avi',
        )),
        'avi-parse-failed:riff-avi',
      );
    });

    test('⑤-2 avi-keyframe：关键帧在头部窗口外（带上大小便于对数）', () {
      expect(
        key(const VideoFrameExtractionFailure(
          stage: VideoFrameStage.aviKeyframe,
          container: 'riff/avi',
          videoFourcc: 'FMP4',
        )),
        'avi-keyframe-outside-window:$_aviBytes',
      );
      expect(
        key(
          const VideoFrameExtractionFailure(stage: VideoFrameStage.aviKeyframe),
          size: 0,
        ),
        'avi-keyframe-outside-window:$kVideoFrameHeadBytes',
        reason: '大小未知时用窗口上限，不编数字',
      );
    });

    test('⑤-3 avi-codec：容器解出来了，卡在编码（fourcc 是关键事实）', () {
      expect(
        key(const VideoFrameExtractionFailure(
          stage: VideoFrameStage.aviCodec,
          container: 'riff/avi',
          videoFourcc: 'MJPG',
          codecMime: 'video/mjpeg',
        )),
        'avi-codec-unsupported:MJPG',
      );
      expect(
        key(const VideoFrameExtractionFailure(stage: VideoFrameStage.aviCodec)),
        'avi-codec-unsupported',
        reason: 'fourcc 读不到时不要编一个',
      );
    });

    test('⑤-4 avi-decode：解码器在但没出帧', () {
      expect(
        key(const VideoFrameExtractionFailure(
          stage: VideoFrameStage.aviDecode,
          container: 'riff/avi',
          videoFourcc: 'FMP4',
        )),
        'avi-decode-failed',
      );
    });

    test('⑤-5 ★ 反向验证：剥掉平台分层 ⇒ 又退回没有信息量的 head-window', () {
      final legacy = videoFrameRequestFailureReason(
        extension: 'avi',
        size: _aviBytes,
        rangeSupported: true,
      );
      expect(legacy, 'head-window:$_aviBytes');
      for (final f in [
        const VideoFrameExtractionFailure(stage: VideoFrameStage.aviParse),
        const VideoFrameExtractionFailure(stage: VideoFrameStage.aviKeyframe),
        const VideoFrameExtractionFailure(stage: VideoFrameStage.aviCodec),
        const VideoFrameExtractionFailure(stage: VideoFrameStage.aviDecode),
      ]) {
        expect(key(f), isNot(legacy));
      }
      // 老那档 `stage=open` 仍是容器原因键（第 267 轮契约不变）
      expect(
        key(const VideoFrameExtractionFailure(
          stage: VideoFrameStage.open,
          container: 'riff/avi',
          videoFourcc: 'FMP4',
        )),
        'container-open-failed:riff-avi',
      );
    });

    test('⑤-6 四档原因键互不相同（别把"容器不支持 / 编码不支持"混成一个）', () {
      final keys = {
        key(const VideoFrameExtractionFailure(
          stage: VideoFrameStage.open,
          container: 'riff/avi',
        )),
        key(const VideoFrameExtractionFailure(
          stage: VideoFrameStage.aviParse,
          container: 'riff/avi',
        )),
        key(const VideoFrameExtractionFailure(
          stage: VideoFrameStage.aviKeyframe,
          container: 'riff/avi',
        )),
        key(const VideoFrameExtractionFailure(
          stage: VideoFrameStage.aviCodec,
          container: 'riff/avi',
          videoFourcc: 'MJPG',
        )),
        key(const VideoFrameExtractionFailure(
          stage: VideoFrameStage.aviDecode,
          container: 'riff/avi',
        )),
      };
      expect(keys, hasLength(5));
    });
  });

  // ========================================================== ⑥ 原生回包 → 事实
  group('⑥ 原生回包（契约形状）→ 失败现场 / 成功结果', () {
    test('⑥-1 自研 AVI 成功回包：有图 + via=avi-fallback，且没有 failure', () {
      final r = VideoFrameStageResult.fromPlatform({
        'stage': 'ok',
        'via': 'avi-fallback',
        'bytes': _jpeg(24),
        'encoding': 'jpeg',
        'mime': 'image/jpeg',
        'width': 320,
        'height': 240,
        'container': 'riff/avi',
        'videoFourcc': 'FMP4',
        'codecMime': 'video/mp4v-es',
      });
      expect(r, isNotNull);
      expect(r!.hasBytes, isTrue);
      expect(r.mime, 'image/jpeg');
      expect(r.width, 320);
      expect(r.height, 240);
      expect(r.viaAviFallback, isTrue);
      expect(r.failure, isNull, reason: '有图就不该同时有失败现场');
    });

    test('⑥-2 avi-codec 失败回包：fourcc/mime/原因/现场字段全部落地', () {
      final r = VideoFrameStageResult.fromPlatform({
        'stage': 'avi-codec',
        'container': 'riff/avi',
        'videoFourcc': 'MJPG',
        'codecMime': 'video/mjpeg',
        'aviReason': 'fourcc-unsupported:MJPG',
        'aviMoviOffset': _moviOffset,
        'aviChunkOffset': _firstChunkOffset,
        'aviChunkSize': _firstChunkSize,
        'aviEsFrames': _probeEsFrames,
        'aviEsBytes': _probeEsBytes,
        'aviScannedChunks': 168,
      });
      expect(r!.hasBytes, isFalse);
      final f = r.failure!;
      expect(f.stage, VideoFrameStage.aviCodec);
      expect(f.container, 'riff/avi');
      expect(f.videoFourcc, 'MJPG');
      expect(f.codecMime, 'video/mjpeg');
      expect(f.reason, 'fourcc-unsupported:MJPG');
      expect(f.codecUnsupported, isTrue);
      expect(f.containerNotSupported, isFalse,
          reason: '容器解出来了，就不许说"容器不支持"');
      expect(f.moviOffset, _moviOffset);
      expect(f.chunkOffset, _firstChunkOffset);
      expect(f.chunkSize, _firstChunkSize);
      expect(f.esFrames, _probeEsFrames);
      expect(f.esBytes, _probeEsBytes);
      expect(f.scannedChunks, 168);
    });

    test('⑥-3 avi-keyframe 失败回包：现场数字一个不丢', () {
      final f = VideoFrameExtractionFailure.fromPlatform({
        'stage': 'avi-keyframe',
        'container': 'riff/avi',
        'videoFourcc': 'FMP4',
        'aviReason': 'keyframe-outside-window:scanned=4096:windowBytes=6291456:movi=9898',
        'aviMoviOffset': _moviOffset,
        'aviChunkOffset': -1,
        'aviChunkSize': 0,
        'aviScannedChunks': 4096,
      });
      expect(f!.stage, VideoFrameStage.aviKeyframe);
      expect(f.reason, startsWith('keyframe-outside-window:'));
      expect(f.scannedChunks, 4096);
      expect(f.chunkOffset, -1);
    });

    test('⑥-4 老回包没有新字段时全为默认（不抛、不编事实）', () {
      final f = VideoFrameExtractionFailure.fromPlatform({
        'stage': 'open',
        'container': 'riff/avi',
        'videoFourcc': 'FMP4',
        'errorClass': 'IllegalArgumentException',
        'error': "couldn't open /data/…/-375289b992ca068d_57.bin",
      });
      expect(f!.reason, isEmpty, reason: 'reason 只认 aviReason，老回包没有');
      expect(f.codecMime, isEmpty);
      expect(f.via, isEmpty);
      expect(f.esFrames, 0);
      expect(f.aviFallbackUsed, isFalse);
    });
  });

  // ========================================================== ⑦ MP4/MKV 不进 AVI 路径
  group('⑦ ★ MP4 / MKV 不会被判成 AVI 路径（非回归守卫）', () {
    test('⑦-1 MP4 失败：原因键仍是 iso-bmff，否则就是回归', () {
      final f = VideoFrameExtractionFailure.fromPlatform({
        'stage': 'open',
        'container': 'iso-bmff',
        'errorClass': 'IllegalArgumentException',
        'error': "couldn't open /data/…/x.bin",
      });
      expect(f!.stage, VideoFrameStage.open);
      expect(f.stage.aviFallbackStage, isFalse);
      expect(aviFallbackApplies(f.container), isFalse);
      expect(
        videoFrameFailureReasonKey(failure: f, extension: 'mp4', size: 1234),
        'container-open-failed:iso-bmff',
      );
    });

    test('⑦-2 MKV 失败：原因键仍是 ebml', () {
      final f = VideoFrameExtractionFailure.fromPlatform({
        'stage': 'open',
        'container': 'ebml',
      });
      expect(aviFallbackApplies(f!.container), isFalse);
      expect(f.containerNotSupported, isTrue);
      expect(
        videoFrameFailureReasonKey(failure: f, extension: 'mkv'),
        'container-open-failed:ebml',
      );
    });

    test('⑦-3 MP4 成功：via 为空 ⇒ 不算自研 AVI 路径', () {
      final r = VideoFrameStageResult.fromPlatform({
        'stage': 'ok',
        'bytes': _jpeg(8),
        'mime': 'image/jpeg',
        'width': 1280,
        'height': 720,
      });
      expect(r!.viaAviFallback, isFalse);
      expect(r.via, isEmpty);
    });

    test('⑦-4 自研路径失败时 `via` 也会落下（诊断能分辨"哪条路报的"）', () {
      final f = VideoFrameExtractionFailure.fromPlatform({
        'stage': 'avi-decode',
        'container': 'riff/avi',
        'via': 'avi-fallback',
      });
      expect(f!.aviFallbackUsed, isTrue);
    });
  });

  // ========================================================== ⑧ 界面归因不串
  group('⑧ 文案：容器不支持 vs 编码不支持，**不许互相借用**', () {
    final zh = AppTextZh();
    final en = AppTextEn();

    test('⑧-1 avi-codec（自研解出容器、卡在编码）⇒ 才说"编码不支持"', () {
      final t = _text(zh, const VideoFrameExtractionFailure(
          stage: VideoFrameStage.aviCodec,
          container: 'riff/avi',
          videoFourcc: 'MJPG',
          codecMime: 'video/mjpeg',
          reason: 'fourcc-unsupported:MJPG',
        ),
      );
      expect(t.label, zh.mediaErrCodecUnsupported);
      expect(t.detail, contains('AVI/RIFF'));
      expect(t.detail, contains('MJPG'));
    });

    test('⑧-2 ★ 反向：stage=open 仍说"格式不支持"，**绝不说**编码', () {
      final t = _text(zh, const VideoFrameExtractionFailure(
          stage: VideoFrameStage.open,
          container: 'riff/avi',
          videoFourcc: 'FMP4',
        ),
      );
      expect(t.label, zh.photoFormatUnsupportedBadge);
      expect(t.label, isNot(zh.mediaErrCodecUnsupported));
      expect(t.detail, isNot(contains('编码')));
    });

    test('⑧-3 avi-parse / avi-keyframe / avi-decode ⇒ 中性占位，不编归因', () {
      for (final f in [
        const VideoFrameExtractionFailure(
          stage: VideoFrameStage.aviParse,
          container: 'riff/avi',
        ),
        const VideoFrameExtractionFailure(
          stage: VideoFrameStage.aviKeyframe,
          container: 'riff/avi',
        ),
        const VideoFrameExtractionFailure(
          stage: VideoFrameStage.aviDecode,
          container: 'riff/avi',
        ),
      ]) {
        final t = _text(zh, f);
        expect(t.label, zh.mediaCoverUnavailable, reason: f.stage.key);
        expect(t.detail, zh.mediaCoverUnavailable);
        // 事实仍留在 facts（诊断用），但不进用户那行
        expect(t.facts, contains('AVI/RIFF'));
      }
    });

    test('⑧-4 英文 avi-codec 文案干净（无中日韩字符）', () {
      final t = _text(en, const VideoFrameExtractionFailure(
          stage: VideoFrameStage.aviCodec,
          container: 'riff/avi',
          videoFourcc: 'MJPG',
        ),
      );
      expect(RegExp(r'[\u3000-\u9fff]').hasMatch(t.detail), isFalse);
    });
  });

  // ========================================================== ⑨ 日志 / 缓存
  group('⑨ 日志与失败记忆（release 也进 logcat）', () {
    test('⑨-1 logLine 带 reason/stage/container/fourcc/mime/via/why', () {
      final failure = VideoFrameThumbFailure.from(
        _aviRequest(),
        const VideoFrameExtractionFailure(
          stage: VideoFrameStage.aviCodec,
          container: 'riff/avi',
          videoFourcc: 'MJPG',
          codecMime: 'video/mjpeg',
          via: 'avi-fallback',
          reason: 'fourcc-unsupported:MJPG',
        ),
      );
      expect(failure.reasonKey, 'avi-codec-unsupported:MJPG');
      expect(failure.container, 'riff-avi', reason: '容器名归一');
      expect(failure.codecMime, 'video/mjpeg');
      expect(failure.via, 'avi-fallback');
      expect(failure.aviFallbackUsed, isTrue);
      expect(failure.codecUnsupported, isTrue);
      final line = failure.logLine;
      expect(line, contains('reason=avi-codec-unsupported:MJPG'));
      expect(line, contains('stage=avi-codec'));
      expect(line, contains('container=riff-avi'));
      expect(line, contains('fourcc=MJPG'));
      expect(line, contains('mime=video/mjpeg'));
      expect(line, contains('via=avi-fallback'));
      expect(line, contains('why=fourcc-unsupported:MJPG'));
    });

    test('⑨-2 失败记忆存下的是自研路径的原因，不是请求侧先验', () async {
      final cache = VideoFrameThumbCache(
        loader: (r) async => null,
        detailedLoader: (r) async => VideoFrameThumbOutcome(
          failure: VideoFrameThumbFailure.from(
            r,
            const VideoFrameExtractionFailure(
              stage: VideoFrameStage.aviKeyframe,
              container: 'riff/avi',
              videoFourcc: 'FMP4',
              reason: 'keyframe-outside-window:scanned=4096',
            ),
          ),
        ),
        directory: () async => null,
        memoryBytes: 1 << 20,
      );
      final req = _aviRequest();
      expect(await cache.get(req), isNull);
      final f = cache.failureFor(req.cacheKey);
      expect(f, isNotNull);
      expect(f!.reasonKey, 'avi-keyframe-outside-window:$_aviBytes');
      expect(f.stage, VideoFrameStage.aviKeyframe);
      expect(f.reason, contains('keyframe-outside-window'));
    });

    test('⑨-3 MP4 走 detailedLoader 出错时原因键不变（非回归）', () async {
      final req = VideoFrameThumbRequest(
        cacheKey: 'vframe|/home/Video/x.mp4|1|2048',
        uri: 'https://nas/d',
        extension: 'mp4',
        size: 2048,
        rangeSupported: true,
      );
      final cache = VideoFrameThumbCache(
        loader: (r) async => null,
        detailedLoader: (r) async => VideoFrameThumbOutcome(
          failure: VideoFrameThumbFailure.from(
            r,
            const VideoFrameExtractionFailure(
              stage: VideoFrameStage.open,
              container: 'iso-bmff',
            ),
          ),
        ),
        directory: () async => null,
        memoryBytes: 1 << 20,
      );
      expect(await cache.get(req), isNull);
      expect(
        cache.failureFor(req.cacheKey)!.reasonKey,
        'container-open-failed:iso-bmff',
      );
    });
  });
}

