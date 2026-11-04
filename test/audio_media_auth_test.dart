// Audio Station **取流鉴权**回归用例（第 274 轮真机缺陷）。
//
// ════════════════════════════════════════════════════════════════════════
// 真机证据（Honor LGE-AN10 / DSM 7.4.1 / 2026-09-26）
// ════════════════════════════════════════════════════════════════════════
// 用户报：「Audio Station 播放音频一直是失败的」。`adb logcat` 逐字：
//
// ```
// E ExoPlayerImplInternal: Playback error
// E ExoPlayerImplInternal:   ud0: Source error
// E ExoPlayerImplInternal:   Caused by: jp2: None of the available extractors
//     (sg1, nl0, jh0, zu2, …) could read the stream.
//     {contentIsMalformed=false, dataType=1}
// E ExoPlayerImplInternal:   sniff failures: [NoDeclaredBrand, NoDeclaredBrand]
// E AudioPlayer: TYPE_SOURCE: None of the available extractors … could read the stream.
// ```
//
// **没有** `SSLPeerUnverifiedException`（所以不是证书），`dataType=1` = HTTP 读到了
// 字节 —— 是"响应根本不是音频"。主机侧只读复现（`_sid` 唯独少了 CSRF 令牌）：
//
// ```
// GET /webapi/AudioStation/stream.cgi/0.mp3?_sid=<sid>&api=SYNO.AudioStation.Stream
//     &version=1&method=stream&id=music_28045
// → HTTP 200  Content-Type: text/plain; charset="UTF-8"
//   {"error":{"code":105},"success":false}
// ```
//
// 同机 A/B（同一个 App 进程、同一个 just_audio/Media3 1.9.2）：
//   * 文件页 `/home/Music/*.mp3`（FileStation 腿，URL 带 `_sid` **+ `SynoToken`**）
//     → `MediaCodec::start()` / `AudioTrack … state:started`（播放正常）；
//   * 音频站同一批 mp3（本模块的 `streamUrl`，**只有 `_sid`**）→ 上面那段报错。
//
// ⇒ 根因：**Audio Station 这条手拼 URL 的腿漏了 `SynoToken`**。本文件把它钉死。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/data/dto/audio_station_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _asTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.AudioStation.Info': {
    'path': 'AudioStation/info.cgi',
    'minVersion': 1,
    'maxVersion': 6,
  },
  'SYNO.AudioStation.Song': {
    'path': 'AudioStation/song.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.AudioStation.Stream': {
    'path': 'AudioStation/stream.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.AudioStation.Download': {
    'path': 'AudioStation/download.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.AudioStation.Cover': {
    'path': 'AudioStation/cover.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
};

/// 登录一次；[withToken] = false 模拟"老 DSM 不给 `synotoken`"的会话。
Future<AudioStationApi> boot({bool withToken = true}) async {
  final t = FakeTransport(const {}, {
    ...FakeTransport.table,
    ..._asTable,
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  if (!withToken) api.transport.synoToken = null;
  return AudioStationApi(api);
}

AudioSongDto get _song => AudioSongDto.fromJson(const {
  'id': 'music_28045',
  'path': '/home/Music/Demo Song.mp3',
  'title': 'Demo Song',
  'artist': 'Demo Artist',
  'album': '00s Love Songs',
  'album_artist': 'Demo Artist',
  'duration': 231,
  'type': 'mp3',
});

void main() {
  group('AS 媒体直链必须带 SynoToken（第 274 轮真机缺陷）', () {
    test('streamUrl：会话有令牌 → 查询串里必须有 SynoToken', () async {
      final audio = await boot();
      final url = audio.streamUrl(_song);
      expect(
        url.contains('SynoToken=FAKE-TOKEN'),
        isTrue,
        reason: '缺了它服务端回 HTTP 200 + {"error":{"code":105}}，'
            'Media3 报 "None of the available extractors…"（真机逐字）',
      );
      // 顺序：`_sid` 之后紧跟 `SynoToken`（两者都是查询串鉴权）
      expect(url.contains('_sid=FAKE-SID&SynoToken=FAKE-TOKEN'), isTrue);
    });

    test('streamUrl：转码腿同样带 SynoToken', () async {
      final audio = await boot();
      final url = audio.streamUrl(_song, mode: AudioStreamMode.mp3);
      expect(url.contains('method=transcode'), isTrue);
      expect(url.contains('SynoToken=FAKE-TOKEN'), isTrue);
    });

    test('downloadUrl / songCoverUrl / albumCoverUrl 也带 SynoToken', () async {
      final audio = await boot();
      expect(
        audio.downloadUrl(const ['music_28045']).contains(
          'SynoToken=FAKE-TOKEN',
        ),
        isTrue,
        reason: '下载腿同样是"交给原生/浏览器的直链"',
      );
      expect(
        audio
            .songCoverUrl('music_28045')
            .contains('SynoToken=FAKE-TOKEN'),
        isTrue,
      );
      expect(
        audio
            .albumCoverUrl('00s Love Songs', albumArtist: 'Demo Artist')
            .contains('SynoToken=FAKE-TOKEN'),
        isTrue,
      );
    });

    test('会话**没有**令牌（老 DSM）→ 不强求 URL 带 SynoToken', () async {
      final audio = await boot(withToken: false);
      final url = audio.streamUrl(_song);
      expect(url.contains('_sid=FAKE-SID'), isTrue);
      expect(url.contains('SynoToken='), isFalse);
      // 自检必须认这个会话（不是"缺令牌"）
      expect(
        audioMediaAuthProblem(
          url,
          sessionHasSid: true,
          sessionHasSynoToken: false,
        ),
        AudioMediaAuthProblem.none,
      );
    });

    test('hasSynoToken 跟着会话走', () async {
      expect((await boot()).hasSynoToken, isTrue);
      expect((await boot(withToken: false)).hasSynoToken, isFalse);
    });
  });

  group('取流鉴权前置自检（纯函数）', () {
    // ★ 反向验证：**修复前的 URL 形态**（只有 `_sid`）必须被判成"缺令牌"。
    // 这条用例在修复前就是"真机上必挂的那种 URL"，所以它同时是回归保护。
    test('反向验证：只有 _sid 的 URL → missingSynoToken', () {
      const preFixUrl =
          'https://nas.example.com:5001/webapi/AudioStation/stream.cgi/0.mp3'
          '?_sid=SID&api=SYNO.AudioStation.Stream&version=1'
          '&method=stream&id=music_28045&_dc=1';
      expect(
        audioMediaAuthProblem(
          preFixUrl,
          sessionHasSid: true,
          sessionHasSynoToken: true,
        ),
        AudioMediaAuthProblem.missingSynoToken,
      );
      expect(
        audioMediaAuthProblemReason(
          AudioMediaAuthProblem.missingSynoToken,
          sessionHasSynoToken: true,
        ),
        contains('missing-synotoken'),
      );
    });

    test('修好之后的形态 → none', () {
      const fixedUrl =
          'https://nas/webapi/AudioStation/stream.cgi/0.mp3'
          '?_sid=SID&SynoToken=TOK&api=SYNO.AudioStation.Stream&version=1'
          '&method=stream&id=music_28045';
      expect(
        audioMediaAuthProblem(
          fixedUrl,
          sessionHasSid: true,
          sessionHasSynoToken: true,
        ),
        AudioMediaAuthProblem.none,
      );
    });

    test('会话没有 sid / 有 sid 但 URL 没有 → missingSid', () {
      expect(
        audioMediaAuthProblem(
          'https://nas/x?api=y',
          sessionHasSid: true,
          sessionHasSynoToken: false,
        ),
        AudioMediaAuthProblem.missingSid,
      );
      expect(
        audioMediaAuthProblem(
          'https://nas/x?api=y',
          sessionHasSid: false,
          sessionHasSynoToken: false,
        ),
        AudioMediaAuthProblem.none,
      );
    });

    test('原因串一律带 as-url-auth 前缀（logcat 可 grep）', () {
      for (final p in AudioMediaAuthProblem.values) {
        expect(
          audioMediaAuthProblemReason(p, sessionHasSynoToken: true),
          startsWith('as-url-auth'),
        );
      }
      expect(
        audioMediaAuthProblemReason(
          AudioMediaAuthProblem.none,
          sessionHasSynoToken: true,
        ),
        'as-url-auth ok',
      );
    });

    test('坏 URL 不抛异常（解析不了就当没问题，交给播放器报真实错）', () {
      expect(
        audioMediaAuthProblem(
          'not a url',
          sessionHasSid: true,
          sessionHasSynoToken: true,
        ),
        AudioMediaAuthProblem.missingSid,
      );
    });
  });
}
