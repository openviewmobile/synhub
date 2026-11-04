// 「系统解码器不支持的格式」统一处置的离线测试。
//
// 覆盖三件事（用户报告「wma 这种音频格式不支持」的修复面）：
//   1. **能力登记**（`lib/src/data/media/media_format_support.dart`）：清单本身、
//      判定依据的完整性、以及 **fail-open 契约**（不误报 / 探针可推翻）；
//   2. **AudioStation 侧**：WMA/APE/WavPack/DSD 走 `method=transcode`
//      （参数与 docs/stage2-audio-download-api.md §2.3 A-1b 逐字一致），
//      MP3/FLAC/AAC 等**仍走直传**（零误报）；
//   3. **FileStation 直链侧**：WMA 得到 `formatUnsupported`（明确的"格式问题 +
//      用其他应用打开"），**不是**泛化的 `decodeFailed`；
//      事后真的失败时 `refinePlayerErrorForSource` 也会把它升级成同一类。
//
// 事实来源：
//   * `media3-extractor-1.9.2-runtime.jar` 的 Extractor 类清单（无 asf/ape/dsf/rm/midi）
//     —— docs/audio-codec-fallback.md §1；
//   * 官方 AudioStation `audio-utils.js` 的
//     `TRANSCODE_TYPE_LIST` / `POWER_DECODE_LIST` / `createStreamingModeSupportList`
//     —— docs/stage2-audio-download-api.md §2.3 A-1b。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/data/dto/audio_station_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/media/media_format_support.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/media/media_source.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _table = <String, Map<String, dynamic>>{
  'SYNO.FileStation.Download': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

/// 与真实 `DirectTransport` 同形：`_sid` + `SynoToken` 都在查询串里。
class _Transport extends FakeTransport {
  _Transport([super.responses, super.apiTable]);

  @override
  String authenticatedUrl(
    String path,
    Map<String, String> params, {
    String? sid,
  }) => DirectTransport.authenticatedQueryUrl(
    'https://nas.example.com:5001/webapi/$path',
    params,
    sid: sid ?? 'FAKE-SID',
    synoToken: synoToken ?? 'FAKE-TOKEN',
  );
}

Future<DsmWebApi> _api() async {
  final api = DsmWebApi(
    _Transport(const {}, {...FakeTransport.table, ..._table}),
  );
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

/// 有 `SynoToken` 但**丢掉 `_sid`** 的传输（会话丢了 / 还没登录）
class _NoSidTransport extends _Transport {
  _NoSidTransport([super.responses, super.apiTable]);

  @override
  String authenticatedUrl(
    String path,
    Map<String, String> params, {
    String? sid,
  }) => DirectTransport.authenticatedQueryUrl(
    'https://nas.example.com:5001/webapi/$path',
    params,
    sid: null,
    synoToken: 'FAKE-TOKEN',
  );
}

Future<DsmWebApi> _apiNoSid() async {
  final api = DsmWebApi(
    _NoSidTransport(const {}, {...FakeTransport.table, ..._table}),
  );
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

void main() {
  tearDown(() => setMediaCodecProbe(null));

  group('能力登记：清单与判定依据', () {
    test('每条登记都有稳定扩展名 + 非空依据原文；扩展名不重复', () {
      expect(kMediaFormatGaps, isNotEmpty);
      final seen = <String>{};
      for (final g in kMediaFormatGaps) {
        expect(g.extension, g.extension.toLowerCase(), reason: g.extension);
        expect(g.extension, isNot(contains('.')), reason: g.extension);
        expect(g.detail.trim(), isNotEmpty, reason: g.extension);
        // 依据原文必须引到**具体**证据，不许写"一般来说/可能"
        expect(
          g.detail.length,
          greaterThan(40),
          reason: '${g.extension} 的判定依据太短，不足以追溯',
        );
        expect(seen.add(g.extension), isTrue, reason: '${g.extension} 重复登记');
      }
    });

    test('任务书点名的格式都在清单里（WMA/ASF/WMV、APE、WavPack、DSD）', () {
      for (final ext in const [
        'wma',
        'asf',
        'wmv',
        'ape',
        'wv',
        'dsf',
        'dff',
        'rm',
        'rmvb',
        'mid',
        'midi',
      ]) {
        expect(
          kMediaFormatGapByExtension.containsKey(ext),
          isTrue,
          reason: '$ext 应在清单里',
        );
      }
    });

    test('WMA 一族（v1/v2/Pro/Lossless）依据是**容器层**缺失，不是"某个编码"', () {
      final wma = kMediaFormatGapByExtension['wma']!;
      expect(wma.evidence, MediaFormatGapEvidence.media3NoExtractor);
      expect(wma.detail, contains('ASF'));
      // v1/v2/Pro/Lossless 四种编码都要在依据里点名（它们共用 ASF 容器）
      for (final codec in const ['v1', 'v2', 'Pro', 'Lossless']) {
        expect(wma.detail, contains(codec), reason: '依据要覆盖 WMA $codec');
      }
    });

    test('AMR-WB **不在**清单里（Media3 有 AmrExtractor → fail-open 直放）', () {
      // 任务书写的是"AMR-WB?"（带问号）。查证结论：Media3 1.9.2 有
      // `amr/AmrExtractor`（NB/WB 都认），Android 也有 `audio/3gpp` /
      // `audio/amr-wb` 解码器 → **不列入**，绝不误报。
      expect(kMediaFormatGapByExtension.containsKey('amr'), isFalse);
      expect(mediaFormatNeedsFallback('a.amr'), isFalse);
      expect(mediaFormatNeedsFallback('a.awb'), isFalse);
    });
  });

  group('mediaFormatNeedsFallback：fail-open 契约', () {
    test('清单内 → true；清单外 → 一律 false（绝不因为清单改道）', () {
      for (final ext in const [
        'wma',
        'asf',
        'wmv',
        'ape',
        'wv',
        'dsf',
        'dff',
      ]) {
        expect(mediaFormatNeedsFallback('x.$ext'), isTrue, reason: ext);
      }
      for (final ext in const [
        'mp3',
        'mp2',
        'mpa',
        'm4a',
        'm4b',
        'aac',
        'ogg',
        'oga',
        'opus',
        'wav',
        'flac',
        'aiff',
        'aif',
        'mp4',
        'm4v',
        'mov',
        'mkv',
        'webm',
        'avi',
        'flv',
        'ts',
        'm2ts',
        '3gp',
        'amr',
        'mka',
        'ac3',
        'dts',
      ]) {
        expect(mediaFormatNeedsFallback('x.$ext'), isFalse, reason: ext);
      }
    });

    test('大小写不敏感；能接路径/文件名；没有扩展名 → false', () {
      expect(mediaFormatExtensionOf('/volume1/music/A.WMA'), 'wma');
      expect(mediaFormatExtensionOf('示例歌曲.WMA'), 'wma');
      // 传进来的是**文件名/路径**（displayName），不是完整 URL；
      // 文件名后带查询串时按第一个 `?` 截断
      expect(mediaFormatExtensionOf('a.ape?x=1'), 'ape');
      expect(mediaFormatExtensionOf('a.wv?token=T'), 'wv');
      expect(mediaFormatExtensionOf('/a/b/noext'), '');
      expect(mediaFormatExtensionOf('/a.b/c'), '');
      expect(mediaFormatExtensionOf('a.'), '');
      expect(mediaFormatNeedsFallback('noext'), isFalse);
      expect(mediaFormatNeedsFallback(''), isFalse);
      expect(mediaFormatNeedsFallback('A.APE'), isTrue);
    });

    test('探针说 true → **走直链**（fail-open 的唯一升级口）', () {
      bool? probe(String ext) => ext == 'wma' ? true : null;
      expect(mediaFormatNeedsFallback('a.wma', probe: probe), isFalse);
      expect(mediaFormatDirectPlayable('a.wma', probe: probe), isTrue);
      // 探针**没结论**的其它登记项照旧走替代路径
      expect(mediaFormatNeedsFallback('a.ape', probe: probe), isTrue);
    });

    test('探针说 false → 照旧走替代路径（不会因为"探过"就放过）', () {
      expect(mediaFormatNeedsFallback('a.wma', probe: (_) => false), isTrue);
    });

    test('全局探针：装/卸都生效（生产默认不装）', () {
      expect(mediaCodecProbe, isNull);
      setMediaCodecProbe((ext) => ext == 'wma' ? true : null);
      expect(mediaFormatNeedsFallback('a.wma'), isFalse);
      expect(mediaFormatNeedsFallback('a.ape'), isTrue);
      setMediaCodecProbe(null);
      expect(mediaFormatNeedsFallback('a.wma'), isTrue);
    });
  });

  group('AudioStation：格式 → 流形态（官方正视路径）', () {
    AudioSongDto songAt(String path) =>
        AudioSongDto.fromJson({'id': 'music_1', 'path': path});

    test('WMA → 转码（修复前被误判成直传，这是用户报告的根因）', () {
      expect(
        AudioStationApi.defaultStreamMode(songAt('/m/a.wma')),
        AudioStreamMode.wav,
      );
      expect(
        AudioStationApi.defaultStreamMode(
          songAt('/m/a.wma'),
          info: const AudioInfoDto(transcodeToMp3: true),
        ),
        AudioStreamMode.mp3,
      );
      // ASF 容器（音频在 .asf 里）同理
      expect(
        AudioStationApi.defaultStreamMode(songAt('/m/a.asf')),
        AudioStreamMode.wav,
      );
    });

    test('APE / WavPack / DSD → 转码', () {
      for (final p in const ['/m/a.ape', '/m/a.wv', '/m/a.dsf', '/m/a.dff']) {
        expect(
          AudioStationApi.defaultStreamMode(songAt(p)),
          AudioStreamMode.wav,
          reason: p,
        );
      }
    });

    test('能播的格式**零误报**：MP3/FLAC/AAC/M4A/OGG/WAV/AIFF 仍走直传', () {
      for (final p in const [
        '/m/a.mp3',
        '/m/a.MP3',
        '/m/a.flac',
        '/m/a.aac',
        '/m/a.m4a',
        '/m/a.m4b',
        '/m/a.ogg',
        '/m/a.wav',
        '/m/a.aiff',
        '/m/a.aif',
        '/m/a.mp2',
      ]) {
        expect(
          AudioStationApi.defaultStreamMode(songAt(p)),
          AudioStreamMode.direct,
          reason: p,
        );
      }
      // `.opus` **不在**改动前的直放集合里（改动前后都是转码）→ 不是本批的
      // 行为变化，如实按"保守转码"钉住，免得将来被误当成回归。
      expect(
        AudioStationApi.defaultStreamMode(songAt('/m/a.opus')),
        AudioStreamMode.wav,
      );
    });

    test('官方 `TRANSCODE_TYPE_LIST` 里**除 dsf/dff 外**我们一次都没多发转码请求', () {
      // 官方集合逐字：["mp1","mp2","mp3","mpa","m4a","m4b","m4p","aac","ogg",
      //                "wav","flac","ape","aiff","aif","wma","dsf","dff"]
      const official = [
        'mp1', 'mp2', 'mp3', 'mpa', 'm4a', 'm4b', 'm4p', 'aac', 'ogg', //
        'wav', 'flac', 'ape', 'aiff', 'aif', 'wma', 'dsf', 'dff',
      ];
      for (final ext in official) {
        final mode = AudioStationApi.defaultStreamMode(songAt('/m/a.$ext'));
        if (mediaFormatNeedsFallback('a.$ext') ||
            ext == 'dsf' ||
            ext == 'dff') {
          expect(mode, isNot(AudioStreamMode.direct), reason: '$ext 应在转码集合里');
        } else {
          expect(mode, AudioStreamMode.direct, reason: '$ext 应直传（零误报）');
        }
      }
    });

    test('登记里的每一项在 AudioStation 侧都**不会**走直传（清单↔模式不许漂移）', () {
      for (final g in kMediaFormatGaps) {
        expect(
          AudioStationApi.defaultStreamMode(songAt('/m/a.${g.extension}')),
          isNot(AudioStreamMode.direct),
          reason: '${g.extension} 命中登记却没走转码 —— 清单与直放集合漂移了',
        );
      }
    });

    test('探针说 WMA 能端到端播 → AudioStation 侧**改回直传**', () {
      expect(
        AudioStationApi.defaultStreamMode(
          songAt('/m/a.wma'),
          probe: (ext) => ext == 'wma' ? true : null,
        ),
        AudioStreamMode.direct,
      );
    });

    test('不在登记也不在直放集合（mka/未知）→ 与改动前一致，保守转码', () {
      expect(
        AudioStationApi.defaultStreamMode(songAt('/m/a.mka')),
        AudioStreamMode.wav,
      );
      expect(
        AudioStationApi.defaultStreamMode(songAt('/m/a.weird')),
        AudioStreamMode.wav,
      );
    });

    test(
      'WMA 转码 URL：stream.cgi/0.wav + method=transcode&format&position（逐字）',
      () async {
        final api = AudioStationApi(await _api());
        final song = songAt('/m/a.wma');
        final url = api.streamUrl(song, mode: AudioStreamMode.wav, position: 0);
        expect(
          url,
          startsWith(
            'https://nas.example.com:5001/webapi/AudioStation/stream.cgi/0.wav?',
          ),
        );
        expect(url, contains('api=SYNO.AudioStation.Stream'));
        // ① 版本号 = 1：官方安卓 `ApiEnumerator.getPlayUrl` 逐字（`versionStream = 1`，
        //    audio_station.dart:165）。此处原断言 `version=2` 在 2026-09-21 被真机证据推翻。
        expect(url, contains('version=1'));
        expect(url, contains('method=transcode'));
        expect(url, contains('format=wav'));
        // ② `position=0` 不发：真机只读实测（audio-parity-audit.md §1.7 结论 4）
        //    普通播放不带 position；只有非零定位才发（下一用例钉住）。
        expect(url, isNot(contains('position=')));
        expect(url, contains('id=music_1'));
        // ③ 鉴权 = `_sid=`：真机实测 `sid=` → 105、`_sid=` → 206
        //    （audio-parity-audit.md §1.6）。原断言写反（要求 `sid=` 且禁止 `_sid=`），
        //    2026-09-21 按真机证据纠正。
        expect(url, contains('_sid=FAKE-SID'));
        expect(url, isNot(contains('&sid=')));
        // ④ ★ 第 286 轮纠正：`SynoToken` **应当**在查询串里（旧断言写反了）。
        //    旧断言 `isNot(contains('SynoToken'))` 与两处既有事实同时冲突：
        //      * 本文件头部前提（第 38 行）：「与真实 `DirectTransport` 同形：
        //        `_sid` + `SynoToken` 都在查询串里」——断言与前提自相矛盾；
        //      * `lib/src/dsm/webapi.dart:725` 的实测记录：QuickConnect 隧道下
        //        内嵌音视频**必须**带 `SynoToken`，否则"文本能看、媒体不能播"。
        //    本用例真正要钉的是「鉴权走 `_sid=` 而不是 `sid=`」（真机 206 vs 105），
        //    "带不带 SynoToken"是另一件事 ⇒ 拆开表达，别再误伤。
        expect(url, contains('SynoToken=FAKE-TOKEN'));
      },
    );

    test('非零定位转码 URL：带上 position（真机 seek 可用）', () async {
      final api = AudioStationApi(await _api());
      final song = songAt('/m/a.wma');
      final url = api.streamUrl(song, mode: AudioStreamMode.wav, position: 60);
      // 真机 `position=60` → 总长精确减少 60*128k/8（audio-parity-audit.md §1.7）
      expect(url, contains('position=60'));
      expect(url, contains('method=transcode'));
      expect(url, contains('_sid=FAKE-SID'));
    });

    test('转码 bitrate 三档：只有 mp3 且档位合法才下发（真机 2432000/3648000/6080000）', () async {
      final api = AudioStationApi(await _api());
      final song = songAt('/m/a.flac');
      final d = api.streamUrl(song, mode: AudioStreamMode.mp3, bitrate: 128000);
      expect(d, contains('bitrate=128000'));
      final h = api.streamUrl(song, mode: AudioStreamMode.mp3, bitrate: 320000);
      expect(h, contains('bitrate=320000'));
      final bad = api.streamUrl(song, mode: AudioStreamMode.mp3, bitrate: 999);
      expect(bad, isNot(contains('bitrate=')));
      // wav 目标永远不带 bitrate（官方 TranscodeFormat 只有 {MP3,WAV}）
      final wav = api.streamUrl(
        song,
        mode: AudioStreamMode.wav,
        bitrate: 320000,
      );
      expect(wav, isNot(contains('bitrate=')));
      // 直传不带 transcode/format
      final direct = api.streamUrl(song, mode: AudioStreamMode.direct);
      expect(direct, isNot(contains('method=transcode')));
      expect(direct, isNot(contains('format=')));
    });

    test('usesServerTranscode：direct=false，mp3/wav=true', () {
      expect(
        AudioStationApi.usesServerTranscode(AudioStreamMode.direct),
        isFalse,
      );
      expect(AudioStationApi.usesServerTranscode(AudioStreamMode.mp3), isTrue);
      expect(AudioStationApi.usesServerTranscode(AudioStreamMode.wav), isTrue);
    });
  });

  group('FileStation 直链：格式缺口的明确语义（不是泛化"播放失败"）', () {
    test('WMA 直链 → formatUnsupported（明确提示 + 用其他应用打开）', () async {
      final src = resolveFileStationSource(
        displayName: 'a.wma',
        kind: MediaKind.audio,
        fs: FileStationApi(await _api()),
        path: '/home/a.wma',
      );
      expect(src.playable, isFalse);
      expect(src.uri, isEmpty);
      expect(src.reason, MediaUnavailableReason.formatUnsupported);
      // 与另外四类**必须**不同
      expect(src.reason, isNot(MediaUnavailableReason.decodeFailed));
      expect(src.reason, isNot(MediaUnavailableReason.codecUnsupported));
      expect(src.reason, isNot(MediaUnavailableReason.networkFailed));
      expect(src.reason, isNot(MediaUnavailableReason.sessionExpired));
      expect(src.reason, isNot(MediaUnavailableReason.streamRejected));
    });

    test('MP3/FLAC/M4A 直链**照旧可播**（零误报，且仍带 formatGap=null）', () async {
      final fs = FileStationApi(await _api());
      for (final name in const ['a.mp3', 'a.flac', 'a.m4a', 'a.aac']) {
        final src = resolveFileStationSource(
          displayName: name,
          kind: MediaKind.audio,
          fs: fs,
          path: '/home/$name',
        );
        expect(src.playable, isTrue, reason: name);
        expect(src.reason, isNull, reason: name);
        expect(src.supportsRange, isTrue, reason: name);
        expect(src.formatGap, isNull, reason: name);
      }
    });

    test('探针说能播 → WMA 直链可播，且带上 formatGap（事后失败可升级理由）', () async {
      final src = resolveFileStationSource(
        displayName: 'a.wma',
        kind: MediaKind.audio,
        fs: FileStationApi(await _api()),
        path: '/home/a.wma',
        probe: (ext) => ext == 'wma' ? true : null,
      );
      expect(src.playable, isTrue);
      expect(src.formatGap?.extension, 'wma');
    });

    test('缺鉴权排在格式判定**之前**：wma 但 URL 没 _sid → 仍是 sessionExpired', () async {
      // 依据：会话失效比"格式可能解不了"更根本 —— 这条顺序保证文件预览页
      // 不会把"请重新登录"说成"格式不支持"（R5 头号误报的反面）。
      final src = resolveFileStationSource(
        displayName: 'a.wma',
        kind: MediaKind.audio,
        fs: FileStationApi(await _apiNoSid()),
        path: '/home/a.wma',
      );
      expect(src.reason, MediaUnavailableReason.sessionExpired);
    });

    test('驱动格式也行：wmv/rmvb 直链同样给 formatUnsupported', () async {
      final fs = FileStationApi(await _api());
      for (final name in const ['a.wmv', 'a.rmvb', 'a.asf']) {
        final src = resolveFileStationSource(
          displayName: name,
          kind: MediaKind.video,
          fs: fs,
          path: '/home/$name',
        );
        expect(
          src.reason,
          MediaUnavailableReason.formatUnsupported,
          reason: name,
        );
      }
    });
  });

  group('refinePlayerErrorForSource：事后失败的升级（只升级兜底）', () {
    final gapSource = MediaSource(
      uri: 'https://x/a.wma',
      channel: MediaChannel.fileStation,
      kind: MediaKind.audio,
      displayName: 'a.wma',
      formatGap: kMediaFormatGapByExtension['wma'],
    );
    final plainSource = MediaSource(
      uri: 'https://x/a.mp3',
      channel: MediaChannel.fileStation,
      kind: MediaKind.audio,
      displayName: 'a.mp3',
    );

    test('命中缺口 + decodeFailed → formatUnsupported（笼统兜底被升级）', () {
      expect(
        refinePlayerErrorForSource(
          gapSource,
          MediaUnavailableReason.decodeFailed,
        ),
        MediaUnavailableReason.formatUnsupported,
      );
    });

    test('命中缺口但失败更具体（会话/网络/服务端拒绝/证书）→ **原样保留**', () {
      for (final r in const [
        MediaUnavailableReason.sessionExpired,
        MediaUnavailableReason.networkFailed,
        MediaUnavailableReason.streamRejected,
        MediaUnavailableReason.certificateUntrusted,
        MediaUnavailableReason.codecUnsupported,
      ]) {
        expect(refinePlayerErrorForSource(gapSource, r), r, reason: '$r');
      }
    });

    test('没命中缺口 → 一律原样（绝大多数文件不进这条）', () {
      expect(
        refinePlayerErrorForSource(
          plainSource,
          MediaUnavailableReason.decodeFailed,
        ),
        MediaUnavailableReason.decodeFailed,
      );
    });
  });
}
