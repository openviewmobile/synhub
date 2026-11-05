// r699 / DA339：Linux **MPRIS**（媒体键 / 系统媒体面板）的判据。
//
// 背景（为什么这是"缺功能"而不是"没需求"）：
//   * `audio_service` **在 Linux 上没有平台实现**，`AudioService.init` 失败后被
//     try/catch 降级 ⇒「不崩」但**没有**系统媒体卡，也没有键盘/蓝牙媒体键；
//   * Linux 桌面的公共契约是 D-Bus 上的 `org.mpris.MediaPlayer2`：媒体键守护进程
//     读 `PlaybackStatus`/`Metadata`，调 `PlayPause`/`Next`/`Previous`/`Seek`；
//   * 本仓此前**没有** `dbus` 依赖 ⇒ 这条路从来没接过（`docs/platform-linux-acceptance.md`
//     的 C6b 欠账）。r699 起自己实现。
//
// 本文件只锁**离线可判**的部分（元数据编码 / 状态串 / 无总线时降级）；
// 真总线上的行为由 `test/mpris_linux_bus_test.dart` 在容器里跑（宿主自动跳过）。
import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/mpris_linux.dart';

void main() {
  test('PlaybackStatus 三态串：Stopped / Playing / Paused（不许自创词）', () {
    expect(
      const MprisPlaybackSnapshot(stopped: true, playing: false).playbackStatus,
      'Stopped',
    );
    expect(
      const MprisPlaybackSnapshot(stopped: false, playing: true).playbackStatus,
      'Playing',
    );
    expect(
      const MprisPlaybackSnapshot(stopped: false, playing: false)
          .playbackStatus,
      'Paused',
    );
  });

  test('Metadata：trackid 是 object path，非法字符换下划线（身份不许丢）', () {
    final v = mprisMetadataOf(
      const MprisPlaybackSnapshot(
        stopped: false,
        playing: true,
        trackId: 'music_ab-cd/ef:12',
        title: '夜航',
        artist: '某人',
        album: '某专辑',
      ),
    );
    // DBusDict.stringVariant 的键顺序不保证 ⇒ 逐个键查
    final map = _asMap(v);
    expect(
      map['mpris:trackid']!.asObjectPath().value,
      '/org/mpris/MediaPlayer2/Track/music_ab_cd_ef_12',
      reason: '曲目身份必须能回到原曲（只做字符替换，不做截断/哈希）',
    );
    expect(map['xesam:title']!.asString(), '夜航');
    expect(map['xesam:album']!.asString(), '某专辑');
    expect(map['xesam:artist']!.asStringArray(), ['某人'],
        reason: 'MPRIS 规定 xesam:artist 是数组');
  });

  test('Metadata：不知道时长就**不给** mpris:length（null ≠ 0）', () {
    final unknown = _asMap(
      mprisMetadataOf(
        const MprisPlaybackSnapshot(
          stopped: false,
          playing: true,
          trackId: 'radio_3',
          title: '在线电台',
        ),
      ),
    );
    expect(unknown.containsKey('mpris:length'), isFalse,
        reason: '电台没有总时长；给 0 会让面板显示 0:00 并允许拖到 0');

    final known = _asMap(
      mprisMetadataOf(
        const MprisPlaybackSnapshot(
          stopped: false,
          playing: true,
          trackId: 'music_1',
          duration: Duration(seconds: 213),
        ),
      ),
    );
    expect(known['mpris:length']!.asInt64(), 213000000,
        reason: 'MPRIS 的 length 单位是**微秒**');
  });

  test('空标题/空歌手/空专辑**不写**（别把空串画成一行空白）', () {
    final map = _asMap(
      mprisMetadataOf(
        const MprisPlaybackSnapshot(
          stopped: false,
          playing: true,
          trackId: 'music_1',
          title: '',
          artist: '',
          album: '',
        ),
      ),
    );
    expect(map.containsKey('xesam:title'), isFalse);
    expect(map.containsKey('xesam:artist'), isFalse);
    expect(map.containsKey('xesam:album'), isFalse);
  });

  test('没有曲目时 trackid 落到 /Track/none（不留空 path）', () {
    final map = _asMap(
      mprisMetadataOf(const MprisPlaybackSnapshot(stopped: true, playing: false)),
    );
    expect(map['mpris:trackid']!.asObjectPath().value,
        '/org/mpris/MediaPlayer2/Track/none');
  });

  test('拿不到会话总线时 start() 返回 null 且**不抛**（播放不许被挡住）', () async {
    // 用注入的"拿不到总线"工厂，而不是看宿主机有没有总线：
    // macOS 宿主没有总线、Linux CI 反而有一个 ⇒ 靠环境判断两边结论相反。
    var calls = 0;
    final svc = await MprisLinuxService.start(
      callbacks: const MprisCallbacks(),
      sessionFactory: () {
        calls++;
        throw StateError('no session bus');
      },
    );
    expect(calls, 1, reason: '降级路径必须真的去连一次，不是提前短路');
    expect(svc, isNull);
  });
}

/// `DBusDict.stringVariant` → `Map<String, DBusValue>`（用例侧解包）。
Map<String, DBusValue> _asMap(DBusValue v) {
  final dict = v as DBusDict;
  final out = <String, DBusValue>{};
  for (final entry in dict.children.entries) {
    final key = (entry.key as DBusString).value;
    final val = entry.value;
    out[key] = val is DBusVariant ? val.value : val;
  }
  return out;
}
