// r699 / DA339：**真会话总线**上的 MPRIS 闭环（只在 Linux 容器里跑，宿主自动跳过）。
//
// 为什么不能用宿主用例代替：这一条的判据是"**别的进程**能不能读到/调到我们"，
// 自己的对象自己读一遍不算数（`AGENTS.md` §2.0.55：「响应体成功 ≠ 界面成功」的同类）。
// 这里用 `gdbus`（GLib 的官方命令行客户端）当"系统那一侧"：
//   ① 名字真的在总线上（`org.mpris.MediaPlayer2.synhub`）；
//   ② `Properties.Get PlaybackStatus` / `Metadata` 读出我们推的值；
//   ③ `Player.PlayPause` 能把**我们 App 的回调**叫起来（媒体键的真实路径）；
//   ④ 属性是只读的：系统拖音量必须**报错**，不许"接受了但没生效"；
//   ⑤ `dispose()` 之后名字真的没了（不留幽灵服务）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/mpris_linux.dart';

const _dest = MprisLinuxService.busName;
const _path = MprisLinuxService.objectPath;

Future<ProcessResult> _gdbus(List<String> args) => Process.run(
      'gdbus',
      args,
      // ★ gdbus 按 **locale** 决定非 ASCII 怎么打印：容器默认 `LANG=C` 时
      //   中文会变成 `????`（不是我们的编码错）。显式给 UTF-8 locale，
      //   这条用例才是在验"中文元数据能不能过总线"，而不是在验 locale。
      environment: {
        if (Platform.environment['DBUS_SESSION_BUS_ADDRESS'] != null)
          'DBUS_SESSION_BUS_ADDRESS':
              Platform.environment['DBUS_SESSION_BUS_ADDRESS']!,
        'LANG': 'C.UTF-8',
        'LC_ALL': 'C.UTF-8',
      },
    ).timeout(const Duration(seconds: 15));

Future<ProcessResult> _get(String iface, String prop) =>
    _gdbus(['call', '--session', '--dest', _dest, '--object-path', _path,
      '--method', 'org.freedesktop.DBus.Properties.Get', iface, prop]);

Future<ProcessResult> _call(String method, [List<String> extra = const []]) =>
    _gdbus(['call', '--session', '--dest', _dest, '--object-path', _path,
      '--method', 'org.mpris.MediaPlayer2.Player.$method', ...extra]);

void main() {
  final bus = Platform.environment['DBUS_SESSION_BUS_ADDRESS'];
  final skipReason = (bus == null || bus.trim().isEmpty)
      ? '宿主/CI 没有会话总线 —— 这条只在 Linux 容器的 X/dbus 会话里跑'
      : null;

  test('真总线：名字可被发现、属性可读、PlayPause 真调到我们的回调、只读属性明确报错、dispose 后名字消失',
      () async {
    var playCalls = 0;
    var pauseCalls = 0;
    final svc = await MprisLinuxService.start(
      callbacks: MprisCallbacks(
        play: () async => playCalls++,
        pause: () async => pauseCalls++,
      ),
    );
    expect(svc, isNotNull, reason: '容器里有会话总线 ⇒ 服务必须起来');

    try {
      await svc!.update(
        const MprisPlaybackSnapshot(
          stopped: false,
          playing: true,
          trackId: 'music_deadbeef',
          title: '真总线上的歌',
          artist: '用例歌手',
          album: '用例专辑',
          duration: Duration(seconds: 187),
          position: Duration(seconds: 12),
          canNext: true,
          canPrevious: false,
        ),
      );

      // ① 名字在总线上
      final names = await _gdbus(['call', '--session', '--dest',
        'org.freedesktop.DBus', '--object-path', '/org/freedesktop/DBus',
        '--method', 'org.freedesktop.DBus.ListNames']);
      expect(names.stdout.toString(), contains('org.mpris.MediaPlayer2.synhub'));

      // ② 属性：状态 / 元数据 / 能力位 / 位置
      final status = await _get('org.mpris.MediaPlayer2.Player', 'PlaybackStatus');
      expect(status.stdout.toString(), contains('Playing'));
      final meta = await _get('org.mpris.MediaPlayer2.Player', 'Metadata');
      expect(meta.stdout.toString(), contains('真总线上的歌'));
      expect(meta.stdout.toString(), contains('用例歌手'));
      expect(meta.stdout.toString(),
          contains('/org/mpris/MediaPlayer2/Track/music_deadbeef'));
      final canNext = await _get('org.mpris.MediaPlayer2.Player', 'CanGoNext');
      expect(canNext.stdout.toString(), contains('true'));
      final pos = await _get('org.mpris.MediaPlayer2.Player', 'Position');
      expect(pos.stdout.toString(), contains('12000000'),
          reason: '位置单位是微秒（12 s ⇒ 12000000）');

      // ③ 媒体键的真实路径：系统调 PlayPause ⇒ 我们在播 ⇒ 必须走 pause
      final pp = await _call('PlayPause');
      expect(pp.exitCode, 0, reason: 'PlayPause 必须成功（stderr: ${pp.stderr}）');
      expect(pauseCalls, 1, reason: '在播时 PlayPause = 暂停');
      expect(playCalls, 0);

      // 暂停态再按一次 ⇒ 走 play
      await svc.update(
        const MprisPlaybackSnapshot(
          stopped: false,
          playing: false,
          trackId: 'music_deadbeef',
          title: '真总线上的歌',
        ),
      );
      await _call('PlayPause');
      expect(playCalls, 1, reason: '暂停时 PlayPause = 播放');

      // ④ 只读属性必须**明确报错**（假控件比没控件更坏）
      final setVol = await _gdbus(['call', '--session', '--dest', _dest,
        '--object-path', _path, '--method',
        'org.freedesktop.DBus.Properties.Set',
        'org.mpris.MediaPlayer2.Player', 'Volume', '<1.0>']);
      expect(setVol.exitCode, isNot(0),
          reason: 'Volume 是只读的：Set 必须失败，不许静默接受');

      // ⑤ 内省里真的有 MPRIS 规定的那些方法与属性
      // `gdbus introspect` 默认打**人类可读树**；判方法/属性名要看 `--xml`
      // （第一次写成默认输出 ⇒ 断言恒红，是仪器错不是服务错）。
      final introspect = await _gdbus(['introspect', '--xml', '--session',
        '--dest', _dest, '--object-path', _path]);
      final xml = introspect.stdout.toString();
      for (final m in const ['Play', 'Pause', 'PlayPause', 'Next', 'Previous',
        'Stop', 'Seek', 'SetPosition']) {
        expect(xml, contains('method name="$m"'), reason: '缺方法 $m');
      }
      for (final p in const ['PlaybackStatus', 'Metadata', 'Position',
        'CanGoNext', 'CanControl']) {
        expect(xml, contains('property name="$p"'), reason: '缺属性 $p');
      }
    } finally {
      await svc?.dispose();
    }

    // dispose 之后名字必须消失（不留幽灵服务）
    final after = await _gdbus(['call', '--session', '--dest',
      'org.freedesktop.DBus', '--object-path', '/org/freedesktop/DBus',
      '--method', 'org.freedesktop.DBus.ListNames']);
    expect(after.stdout.toString(), isNot(contains('org.mpris.MediaPlayer2.synhub')));
  }, skip: skipReason);
}
