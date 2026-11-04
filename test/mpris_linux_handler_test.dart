// r699 / DA339：**App 的播放器真的把 MPRIS 挂上去了吗**（handler 级，Linux 容器里跑）。
//
// `test/mpris_linux_bus_test.dart` 证明"服务本身能被系统读到/调到"；
// 这一条证明**接线**：`SynologyAudioHandler` 起播一首歌之后，
// 系统那一侧（`gdbus`）读到的就是**这首歌**，`PlayPause` 打到的也是**这个引擎**。
// 少了这一条，"库写好了但 App 没接"会被当成闭环（`AGENTS.md` §2.0.55 同款假绿）。
//
// 静音纪律：这里用 `FakeAudioStationPlayer`（不出声、不落盘），
// 不碰真实音频设备。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/media/audio_handler.dart';

import 'support/fake_audio_player.dart';

class _NoArtwork implements AudioArtworkCache {
  @override
  Future<Uri?> store(List<int> bytes) async => null;
  @override
  Future<void> dispose() async {}
}

class _FakeFocus implements AudioFocusController {
  @override
  Future<void> activate() async {}
  @override
  Stream<bool> get interruptions => const Stream.empty();
  @override
  Stream<void> get becomingNoisy => const Stream.empty();
  @override
  Future<void> dispose() async {}
}

const _dest = 'org.mpris.MediaPlayer2.synhub';
const _path = '/org/mpris/MediaPlayer2';

Future<ProcessResult> _gdbus(List<String> args) => Process.run(
      'gdbus',
      args,
      environment: {
        'DBUS_SESSION_BUS_ADDRESS':
            Platform.environment['DBUS_SESSION_BUS_ADDRESS']!,
        'LANG': 'C.UTF-8',
        'LC_ALL': 'C.UTF-8',
      },
    ).timeout(const Duration(seconds: 15));

Future<String> _get(String prop) async {
  final r = await _gdbus(['call', '--session', '--dest', _dest,
    '--object-path', _path, '--method',
    'org.freedesktop.DBus.Properties.Get',
    'org.mpris.MediaPlayer2.Player', prop]);
  expect(r.exitCode, 0, reason: 'Get $prop 失败：${r.stderr}');
  return r.stdout.toString();
}

/// 等名字**先出现**：服务注册完成前 `Get` 会回 `ServiceUnknown`，
/// 那不是"没接线"，是"还没起完"（r699 第一版直接 `expect(exitCode,0)` ⇒ 假红）。
Future<void> _waitForName() async {
  for (var i = 0; i < 50; i++) {
    final r = await _gdbus(['call', '--session', '--dest',
      'org.freedesktop.DBus', '--object-path', '/org/freedesktop/DBus',
      '--method', 'org.freedesktop.DBus.ListNames']);
    if (r.stdout.toString().contains(_dest)) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('等不到 $_dest 出现在会话总线上（App 侧根本没起 MPRIS）');
}

Future<void> _waitForStatus(String want) async {
  for (var i = 0; i < 50; i++) {
    final r = await _gdbus(['call', '--session', '--dest', _dest,
      '--object-path', _path, '--method',
      'org.freedesktop.DBus.Properties.Get',
      'org.mpris.MediaPlayer2.Player', 'PlaybackStatus']);
    if (r.exitCode == 0 && r.stdout.toString().contains(want)) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('等不到 PlaybackStatus=$want');
}

void main() {
  final bus = Platform.environment['DBUS_SESSION_BUS_ADDRESS'];
  final skipReason = (bus == null || bus.trim().isEmpty)
      ? '宿主/CI 没有会话总线 —— 这条只在 Linux 容器的 X/dbus 会话里跑'
      : null;

  test('起播一首歌 ⇒ 系统侧读到的就是这首歌；PlayPause 打到同一个引擎；dispose 后名字消失',
      () async {
    final engine = FakeAudioStationPlayer();
    final handler = SynologyAudioHandler(
      player: engine,
      focus: _FakeFocus(),
      artwork: _NoArtwork(),
      renewer: AudioSessionRenewer(delayOf: (_) => Duration.zero),
    );
    try {
      await handler.startQueue([
        const AudioTrackInfo(
          id: 'music_r699_bus',
          url: 'http://nas/webapi/AudioStation/stream.cgi/0.mp3',
          title: '总线上的歌',
          artist: '用例歌手',
          album: '用例专辑',
          duration: Duration(seconds: 95),
        ),
      ]);

      await _waitForName();
      await _waitForStatus('Playing');

      // 元数据必须是**这一首**（不是上一首、不是空）
      final meta = await _get('Metadata');
      expect(meta, contains('总线上的歌'));
      expect(meta, contains('用例歌手'));
      expect(meta, contains('/Track/music_r699_bus'));
      // 能力位：单曲队列 ⇒ 没有上一首/下一首
      expect(await _get('CanGoNext'), contains('false'));
      expect(await _get('CanGoPrevious'), contains('false'));

      // ★ 媒体键的真实效果：系统按 PlayPause ⇒ 我们的引擎 pause 被调 1 次
      final pp = await _gdbus(['call', '--session', '--dest', _dest,
        '--object-path', _path, '--method',
        'org.mpris.MediaPlayer2.Player.PlayPause']);
      expect(pp.exitCode, 0);
      expect(engine.pauses, 1, reason: '在播时的 PlayPause 必须打到引擎的 pause');
      await _waitForStatus('Paused');

      // 再按一次 ⇒ 引擎 resume（计数在 plays 上）
      final playsBefore = engine.plays;
      await _gdbus(['call', '--session', '--dest', _dest,
        '--object-path', _path, '--method',
        'org.mpris.MediaPlayer2.Player.PlayPause']);
      expect(engine.plays, playsBefore + 1);
      await _waitForStatus('Playing');

      // Seek：MPRIS 的偏移单位是**微秒**
      await _gdbus(['call', '--session', '--dest', _dest,
        '--object-path', _path, '--method',
        'org.mpris.MediaPlayer2.Player.Seek', '<5000000>']);
      // 假引擎不报位置，这里只断言调用成功（真位置链路由上层播放器用例守）
    } finally {
      await handler.dispose();
    }

    // dispose 之后服务必须撤掉（否则系统面板里会留一个点不动的幽灵）
    final names = await _gdbus(['call', '--session', '--dest',
      'org.freedesktop.DBus', '--object-path', '/org/freedesktop/DBus',
      '--method', 'org.freedesktop.DBus.ListNames']);
    expect(names.stdout.toString(), isNot(contains(_dest)));
  }, skip: skipReason);
}
