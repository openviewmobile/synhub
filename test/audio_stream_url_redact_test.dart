// ★★★ r131（macOS 逐屏走查）：串流地址里的**会话凭据**必须在界面上打码。
//
// 像素证据（`m11_audio_song.png` / `m12_audio_playing.png`）：Music 单曲页的
// `Streaming URL` 卡把整串地址渲染成可选文本，连 `_sid=<会话 id>` 与
// `SynoToken=<CSRF 令牌>` 一起显示，旁边还有复制按钮 ⇒ 一张截图就等于交出会话。
// 落地：`redactStreamUrl()`（`lib/src/features/audio/audio_song_page.dart`）。
// 本用例做**反向验证**：未打码的旧文本必须被检测出仍含令牌。

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/audio/audio_song_page.dart';

const _raw =
    'https://nas.example.com:5001/webapi/AudioStation/stream.cgi/0.mp3'
    '?_sid=TEST-SESSION-ID-NOT-REAL-0001&SynoToken=TESTTOKEN0002'
    '&api=SYNO.AudioStation.Stream&version=1&method=stream&id=music_28045'
    '&_dc=1790473662010';

void main() {
  test('★★★ r131：redactStreamUrl 打码 _sid 与 SynoToken，其余参数逐字保留', () {
    final masked = redactStreamUrl(_raw);
    expect(masked, isNot(contains('TEST-SESSION-ID-NOT-REAL-0001')));
    expect(masked, isNot(contains('TESTTOKEN0002')));
    expect(masked, contains('_sid=***'));
    expect(masked, contains('SynoToken=***'));
    // 非敏感部分必须一字不变（否则"打码"会顺手改坏地址语义）。
    expect(masked, contains('api=SYNO.AudioStation.Stream'));
    expect(masked, contains('version=1'));
    expect(masked, contains('method=stream'));
    expect(masked, contains('id=music_28045'));
    expect(masked, contains('_dc=1790473662010'));
    expect(masked.startsWith('https://nas.example.com:5001/'), isTrue);

    // 反向验证：同一个判据用在**未打码**的原文上必须报"含令牌"。
    bool looksMasked(String u) =>
        !u.contains('TEST-SESSION-ID-NOT-REAL-0001') &&
        !u.contains('TESTTOKEN0002');
    expect(looksMasked(_raw), isFalse, reason: '旧写法必须被判为未打码');
    expect(looksMasked(masked), isTrue);
  });

  test('redactStreamUrl 对没有凭据的地址是恒等变换', () {
    const clean = 'https://nas.example/webapi/stream.cgi/0.mp3?id=1';
    expect(redactStreamUrl(clean), clean);
    expect(redactStreamUrl(''), '');
  });
}
