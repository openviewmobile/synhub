// ★★★ **r442** · 播放列表「加歌」接线（`admin-parity-requirement.md` §68.4 的诚实剩余
// 「"把歌曲加入播放列表"（官方 = `updatesongs` 带 `offset=已有曲数`）UI 未接」）。
//
// 契约**不是猜的**：真机探针 `tool/r442_playlist_songs_probe_test.dart` 在真 NAS 上
// 有界写实测（只动自建临时列表、收尾删净、残留 0）得到 —— 见 `docs/evidence-r442/`：
//   * `updatesongs {id, offset: 已有曲数, limit: 0, songs: 逗号串}` ⇒ **追加**；
//   * 一次调用可加多首；`offset` 越界被钳到末尾；
//   * **重复**加同一首 ⇒ 服务端回 **411**（`AUDIO_ERR_DUPLICATE_SONGS`）；
//   * `getinfo` 带 `songs_limit=1` 时 `additional.songs_total` 仍是全量。
//
// 本文件还钉住 **`DA96`**：音频业务码在「异常 → 用户文案」出口上必须走音频表
// （通用表把 411 解释成「账号已锁定」—— 与事实相反）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/user_facing_error.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'audio_station_test.dart' show boot, callOf;

const _as = 'SYNO.AudioStation';

/// 一条 `Playlist.getinfo` 回包（`songs_total` 是权威计数）。
Map<String, dynamic> _getinfo({
  String id = 'pl_1',
  String name = '示例歌曲集',
  int songsTotal = 3,
  List<Map<String, dynamic>> songs = const [
    {'id': 'music_9', 'title': '旧歌'},
  ],
}) => {
  'playlists': [
    {
      'id': id,
      'name': name,
      'library': 'personal',
      'additional': {'songs': songs, 'songs_total': songsTotal},
    },
  ],
};

void main() {
  group('r442 加歌：`addSongsToPlaylist`（真机契约）', () {
    test('★ 先 `getinfo(songs_limit=1)` 取 `songs_total`，再 `updatesongs(offset=总数, limit=0)`',
        () async {
      final (api, t) = await boot(
        responses: {
          '$_as.Playlist.getinfo': _getinfo(songsTotal: 3),
          '$_as.Playlist.updatesongs': {},
        },
      );
      await api.addSongsToPlaylist(id: 'pl_1', songIds: const ['music_7']);

      final g = callOf(t, '$_as.Playlist', 'getinfo');
      expect(g['id'], 'pl_1');
      expect(
        g['songs_limit'],
        1,
        reason: '只借 `songs_total` ⇒ 不许为了算 offset 拉全量曲目',
      );

      final u = callOf(t, '$_as.Playlist', 'updatesongs');
      expect(
        u['offset'],
        3,
        reason: '加歌 = offset 放到**已有曲数**（真机 1→2、2→3 实测）',
      );
      expect(u['limit'], 0, reason: 'limit=0（真机实测：段替换长度为 0 = 纯追加）');
      expect(u['songs'], 'music_7');
      expect(u['id'], 'pl_1');
    });

    test('★ 一次加多首：`songs` 是逗号串（真机 3→5 实测）', () async {
      final (api, t) = await boot(
        responses: {
          '$_as.Playlist.getinfo': _getinfo(songsTotal: 5),
          '$_as.Playlist.updatesongs': {},
        },
      );
      await api.addSongsToPlaylist(
        id: 'pl_2',
        songIds: const ['music_7', 'music_8', 'music_9'],
      );
      final u = callOf(t, '$_as.Playlist', 'updatesongs');
      expect(u['songs'], 'music_7,music_8,music_9');
      expect(u['offset'], 5);
    });

    test('★ 空列表：`songs_total=0` 时用实到曲目数兜底（真机 0→1 实测）', () async {
      final (api, t) = await boot(
        responses: {
          '$_as.Playlist.getinfo': _getinfo(songsTotal: 0, songs: const []),
          '$_as.Playlist.updatesongs': {},
        },
      );
      await api.addSongsToPlaylist(id: 'pl_3', songIds: const ['music_1']);
      expect(callOf(t, '$_as.Playlist', 'updatesongs')['offset'], 0);
    });

    test('★ `songs_total` 缺失时用实到曲目数兜底（不把 offset 算成 0 而误覆盖）', () async {
      final (api, t) = await boot(
        responses: {
          '$_as.Playlist.getinfo': {
            'playlists': [
              {
                'id': 'pl_4',
                'name': 'x',
                'additional': {
                  'songs': [
                    {'id': 'music_1'},
                    {'id': 'music_2'},
                  ],
                },
              },
            ],
          },
          '$_as.Playlist.updatesongs': {},
        },
      );
      await api.addSongsToPlaylist(id: 'pl_4', songIds: const ['music_3']);
      expect(callOf(t, '$_as.Playlist', 'updatesongs')['offset'], 2);
    });

    test('★ 列表不存在 ⇒ 抛 407（`AUDIO_ERR_PLAYLIST_NOT_EXISTS`），不发写请求', () async {
      final (api, t) = await boot(
        responses: {'$_as.Playlist.getinfo': {'playlists': []}},
      );
      await expectLater(
        api.addSongsToPlaylist(id: 'gone', songIds: const ['music_1']),
        throwsA(
          isA<DsmApiException>().having((e) => e.code, 'code', 407),
        ),
      );
      expect(
        t.calls.any((c) => c['method'] == 'updatesongs'),
        isFalse,
        reason: '列表都不存在 ⇒ 不许再发写动词',
      );
    });

    test('★ 空 songIds ⇒ 连读都不发（不动服务端）', () async {
      final (api, t) = await boot();
      await api.addSongsToPlaylist(id: 'pl_1', songIds: const []);
      expect(t.calls.any((c) => c['api'] == '$_as.Playlist'), isFalse);
    });
  });

  group('DA96 音频业务码文案：`userFacingError` 出口必须与音频表一致', () {
    // 官方 `getErrCodeMapping` 的音频业务码全集（`audio_station.dart` 逐字抄的同一批）。
    const codes = <int>[
      101, 406, 407, 409, 410, 411, 412, 501, 1006, 1007, 1010, 1011, 1201, 1202,
    ];

    test('★ 逐码比对：`DsmErrorCode.describe(AudioStation)` == `describeAudioError`', () {
      for (final code in codes) {
        final method = '$_as.Playlist.updatesongs';
        expect(
          DsmErrorCode.describe(code, method: method),
          describeAudioError(DsmApiException(code, method: method)),
          reason: '码 $code：两张表漂移了（DA96）',
        );
      }
    });

    test('★★★ 411 = 「有重复的歌曲」，**绝不是**通用表的「账号已锁定」', () {
      const method = '$_as.Playlist.updatesongs';
      // 通用表（不带 method）里 411 是 Auth 码 —— 这个事实本身要留住。
      expect(DsmErrorCode.messages[DsmErrorCode.authAccountLocked], '账号已锁定');
      // 但带音频 method 时必须翻案。
      expect(DsmErrorCode.describe(411, method: method), '有重复的歌曲');
      expect(DsmErrorCode.describe(411), '账号已锁定', reason: '不带 method 时通用码语义不变');
      // 用户真正看到的那句话：
      final text = userFacingError(DsmApiException(411, method: method));
      expect(text, contains('411'));
      expect(text, contains('有重复的歌曲'));
      expect(
        text,
        isNot(contains('账号已锁定')),
        reason: 'DA96：修前这里是「DSM 411：账号已锁定」—— 与事实相反（真机同轮控制实验证明账号从未被锁）',
      );
    });

    test('★ 非音频 method 不受影响（Chat 仍走聊天表 / 无 method 走通用表）', () {
      expect(
        DsmErrorCode.describe(DsmErrorCode.authAccountLocked),
        '账号已锁定',
      );
      // FileStation 的 407 是权限不足，不能被音频表抢走。
      expect(
        DsmErrorCode.describe(407, method: 'SYNO.FileStation.List'),
        '没有权限访问该位置',
      );
      expect(
        DsmErrorCode.describe(407, method: '$_as.Playlist.updatesongs'),
        '播放列表不存在（DSM 可能正在重建索引）',
      );
    });
  });
}
