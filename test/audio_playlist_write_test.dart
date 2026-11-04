// ★★★ 第 132 轮 / 台账 C6：播放列表**写**操作（官方 APK 参数逐字）。
//
// 事实来源：官方 `DSaudio.apk` 反编译
//   * `ApiEnumerator.doCreatePlaylist` → `create` + `{name, library, songs}`
//   * `PlaylistEditor.doRenameNormalPlaylist` → `rename` + `{id, new_name}`
//   * `PlaylistEditor` DELETE → `delete` + `{id}`
//   * `PlaylistEditor.doUpdatePlaylist` → `updatesongs` + `{id, offset, limit, songs}`
//   * `PlaylistEditor` COPYTOLIBRARY → `copytolibrary` + `{id, library}`
//   * 智能列表 `updatesmart` → `{id, new_name, library, conj_rule, rules_json}`
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/audio_station_dto.dart';

import 'audio_station_test.dart' show boot, callOf;

void main() {
  test('★ C6 create：`{name, library, songs}` + 回包取 data.playlists[0].id', () async {
    final (api, t) = await boot(responses: {
      'SYNO.AudioStation.Playlist.create': {
        'playlists': [
          {'id': 'pl_new', 'name': '示例歌曲合集'},
        ],
      },
    });
    final id = await api.createPlaylist(
      name: '示例歌曲合集',
      songIds: const ['music_1', 'music_2'],
      library: AudioLibrary.shared,
    );
    final c = callOf(t, 'SYNO.AudioStation.Playlist', 'create');
    expect(c['name'], '示例歌曲合集');
    expect(c['library'], 'shared');
    expect(c['songs'], 'music_1,music_2', reason: '官方 songs 是**逗号串**');
    expect(id, 'pl_new');
  });

  test('★ C6 rename / delete：`{id, new_name}`、`{id}`', () async {
    final (api, t) = await boot(responses: {
      'SYNO.AudioStation.Playlist.rename': {},
      'SYNO.AudioStation.Playlist.delete': {},
    });
    await api.renamePlaylist('pl_1', '新名字');
    await api.deletePlaylist('pl_2');
    expect(callOf(t, 'SYNO.AudioStation.Playlist', 'rename'),
        containsPair('new_name', '新名字'));
    expect(callOf(t, 'SYNO.AudioStation.Playlist', 'rename')['id'], 'pl_1');
    expect(callOf(t, 'SYNO.AudioStation.Playlist', 'delete')['id'], 'pl_2');
  });

  test('★ C6 updatesongs：`{id, offset, limit, songs}`（官方默认 offset=0/limit=-1）',
      () async {
    final (api, t) = await boot(responses: {
      'SYNO.AudioStation.Playlist.updatesongs': {},
    });
    await api.updatePlaylistSongs(id: 'pl_1', songIds: const ['music_3']);
    final p = callOf(t, 'SYNO.AudioStation.Playlist', 'updatesongs');
    expect(p['id'], 'pl_1');
    expect(p['offset'], 0);
    expect(p['limit'], -1);
    expect(p['songs'], 'music_3');
  });

  test('★ C6 copytolibrary / saveplaying', () async {
    final (api, t) = await boot(responses: {
      'SYNO.AudioStation.Playlist.copytolibrary': {},
      'SYNO.AudioStation.Playlist.saveplaying': {
        'playlists': [
          {'id': 'pl_saved'},
        ],
      },
    });
    await api.copyPlaylistToLibrary('pl_1', AudioLibrary.shared);
    final saved = await api.savePlayingQueue(
        name: '队列快照', songIds: const ['music_9']);
    expect(callOf(t, 'SYNO.AudioStation.Playlist', 'copytolibrary')['id'], 'pl_1');
    expect(callOf(t, 'SYNO.AudioStation.Playlist', 'copytolibrary')['library'], 'shared');
    expect(callOf(t, 'SYNO.AudioStation.Playlist', 'saveplaying')['songs'],
        'music_9');
    expect(saved, 'pl_saved');
  });

  test('★ C6/A17 智能列表：`rules_json` 是 JSON 数组 + `conj_rule`', () async {
    final (api, t) = await boot(responses: {
      'SYNO.AudioStation.Playlist.createsmart': {'id': 'smart_1'},
      'SYNO.AudioStation.Playlist.updatesmart': {},
    });
    final id = await api.createSmartPlaylist(
      name: '我的 5 星',
      conjunction: 'and',
      rules: [
        {'field': 'rating', 'operator': 'gte', 'value': '5'},
      ],
    );
    final p = callOf(t, 'SYNO.AudioStation.Playlist', 'createsmart');
    expect(p['name'], '我的 5 星');
    expect(p['conj_rule'], 'and');
    expect(p['rules_json'], '[{"field":"rating","operator":"gte","value":"5"}]',
        reason: 'rules_json 必须是 JSON 串（官方直接序列化数组）');

    await api.updateSmartPlaylist(
      id: 'smart_1',
      newName: '改名后',
      conjunction: 'or',
      rules: [
        {'field': 'genre', 'operator': 'eq', 'value': 'Jazz'},
      ],
    );
    final u = callOf(t, 'SYNO.AudioStation.Playlist', 'updatesmart');
    expect(u['id'], 'smart_1');
    expect(u['new_name'], '改名后');
    expect(u['conj_rule'], 'or');
    expect(id, 'smart_1');
  });

  test('★ A17 getinfo(additional=rules)：解析 data.playlists[0].additional', () async {
    final (api, t) = await boot(responses: {
      'SYNO.AudioStation.Playlist.getinfo': {
        'playlists': [
          {
            'id': 'smart_1',
            'name': '高评分',
            'type': 'smart',
            'additional': {
              'rules_conjunction': 'and',
              'rules': [
                {'field': 'rating', 'operator': 'greater', 'value': '3'},
              ],
            },
          },
        ],
      },
    });
    final r = await api.getPlaylistRules(id: 'smart_1');
    final c = callOf(t, 'SYNO.AudioStation.Playlist', 'getinfo');
    expect(c['id'], 'smart_1');
    expect(c['additional'], 'rules', reason: '官方 additional 逐字是 rules');
    expect(r, isNotNull);
    expect(r!.conjunction, 'and', reason: '官方读 rules_conjunction');
    expect(r.rules.single['field'], 'rating');
    expect(r.rules.single['operator'], 'greater');
  });

  test('★ A17 getinfo(additional=rules)：缺规则 → null（不硬编空规则）', () async {
    final (api, _) = await boot(responses: {
      'SYNO.AudioStation.Playlist.getinfo': {
        'playlists': [
          {'id': 'plain', 'type': 'normal'},
        ],
      },
    });
    expect(await api.getPlaylistRules(id: 'plain'), isNull);
  });

  test('★ A17 updatesmart：改智能列表名必须原样回传 conj_rule + rules_json', () async {
    final (api, t) = await boot(responses: {
      'SYNO.AudioStation.Playlist.updatesmart': {},
    });
    await api.updateSmartPlaylist(
      id: 'smart_1',
      newName: '新名字',
      conjunction: 'and',
      rules: [
        {'field': 'rating', 'operator': 'greater', 'value': '3'},
      ],
      library: AudioLibrary.personal,
    );
    final c = callOf(t, 'SYNO.AudioStation.Playlist', 'updatesmart');
    expect(c['id'], 'smart_1');
    expect(c['new_name'], '新名字');
    expect(c['library'], 'personal');
    expect(c['conj_rule'], 'and');
    expect(
      c['rules_json'],
      '[{"field":"rating","operator":"greater","value":"3"}]',
      reason: 'rules_json 是**序列化后的 JSON 串**',
    );
  });

  // ------------------------------------------------ C4 远程播放器（RemotePlayer）
  test('★ C4 RemotePlayer.list：v1、防御式取数组（未知根键不臆造）', () async {
    final (api, t) = await boot(responses: {
      'SYNO.AudioStation.RemotePlayer.list': {
        'players': [
          {'id': 'p1', 'name': 'Living Room TV'},
        ],
      },
    }, apiTable: const {
      'SYNO.AudioStation.RemotePlayer': {
        'path': 'remote_player.cgi',
        'maxVersion': 3,
      },
    });
    final list = await api.listRemotePlayers();
    final c = callOf(t, 'SYNO.AudioStation.RemotePlayer', 'list');
    expect(c['api'], 'SYNO.AudioStation.RemotePlayer');
    expect(list.single['name'], 'Living Room TV');
  });

  test('★ C4 RemotePlayer.control：`{id, action, value}` 逐字对齐官方', () async {
    final (api, t) = await boot(responses: {
      'SYNO.AudioStation.RemotePlayer.control': {},
    }, apiTable: const {
      'SYNO.AudioStation.RemotePlayer': {
        'path': 'remote_player.cgi',
        'maxVersion': 3,
      },
    });
    await api.controlRemote(id: 'p1', action: 'set_volume', value: '42');
    final c = callOf(t, 'SYNO.AudioStation.RemotePlayer', 'control');
    expect(c['id'], 'p1');
    expect(c['action'], 'set_volume');
    expect(c['value'], '42');
  });

  test('★ C4 RemotePlayerStatus 优先，失败回落 RemotePlayer/getstatus', () async {
    final (api, t) = await boot(
      responses: {
        'SYNO.AudioStation.RemotePlayer.getstatus': {'status': 'playing'},
      },
      apiTable: const {
        // 故意**不**给 RemotePlayerStatus（模拟老 NAS 没有这个接口）
        'SYNO.AudioStation.RemotePlayer': {
          'path': 'remote_player.cgi',
          'maxVersion': 3,
        },
      },
    );
    final st = await api.getRemoteStatus(id: 'p1');
    expect(st['status'], 'playing', reason: 'Status 接口不可用时必须回落');
  });

  test('★ C1 fix：RemotePlayer.updateplaylist 必须带 updated_index（官方形态）', () async {
    final (api, t) = await boot(responses: {
      'SYNO.AudioStation.RemotePlayer.updateplaylist': {},
    }, apiTable: const {
      'SYNO.AudioStation.RemotePlayer': {
        'path': 'remote_player.cgi',
        'maxVersion': 3,
      },
    });
    await api.updateRemotePlaylist(
      id: 'p1',
      songIds: const ['music_1', 'music_2'],
      limit: 2,
      updatedIndex: -1,
      keepShuffleOrder: false,
    );
    final c = callOf(t, 'SYNO.AudioStation.RemotePlayer', 'updateplaylist');
    expect(c['id'], 'p1');
    expect(c['offset'], 0);
    expect(c['limit'], 2);
    expect(c['songs'], 'music_1,music_2');
    expect(c['updated_index'], -1, reason: '138 轮漏掉的官方参数');
    expect(c['keep_shuffle_order'], 'false');
  });
}
