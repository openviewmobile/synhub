// W1-3 收尾：Audio Station 播放队列**持久化 + 按 id 回填**的离线单测。
//
// 关注四件事：
//   1. 快照只存 **id/标题**（不存带 `_sid` 的流式 URL）、去重、顺序保持；
//   2. 回填规则：跳过被删/无权限的（记进 skipped），**不清空**其余；
//   3. 回填预算：逐条 `Song.getinfo` 不能因为队列很长就打爆 NAS；
//   4. 存储**复用** `media_playback.json` 的同一套约定（跨实例/坏文件/无通道）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/audio_station_dto.dart';
import 'package:synhub/src/features/audio/audio_queue_memory.dart';
import 'package:synhub/src/features/media/media_playback_store.dart';

AudioSongDto _song(String id, {String? title}) =>
    AudioSongDto(id: id, path: '/m/$id.mp3', title: title ?? id);

AudioQueueRef _ref(String id, {String? title}) =>
    AudioQueueRef(id: id, title: title ?? id);

void main() {
  group('快照：只存 id/标题、去重、顺序', () {
    test('顺序与 currentId 来自列表下标；空 id 丢掉', () {
      final queue = [
        _song('music_1', title: 'a'),
        const AudioSongDto(id: ''),
        _song('music_2', title: 'b'),
      ];
      final snap = audioQueueSnapshotOf(queue, 2)!;
      expect(snap.items.map((e) => e.id), ['music_1', 'music_2']);
      expect(snap.items.map((e) => e.title), ['a', 'b']);
      expect(snap.currentId, 'music_2');
      // 只存身份：JSON 里绝不该出现带 `_sid` 的流式 URL
      expect(jsonEncode(snap.toJson()).contains('_sid'), isFalse);
      expect(jsonEncode(snap.toJson()).contains('stream.cgi'), isFalse);
      // 退化情形：下标落在"没有 id 的条目"上 → 退回第一条，不崩
      expect(audioQueueSnapshotOf(queue, 1)!.currentId, 'music_1');
    });

    test('重复 id 只留第一条；空队列 / 全空 id → 不落盘（null）', () {
      final snap = audioQueueSnapshotOf([
        _song('music_1'),
        _song('music_1'),
      ], 0)!;
      expect(snap.items.length, 1);
      expect(audioQueueSnapshotOf(const [], 0), isNull);
      expect(audioQueueSnapshotOf([const AudioSongDto(id: '')], 0), isNull);
    });

    test('JSON 往返解析会去重，坏元素丢掉；空表 → null', () {
      final snap = AudioQueueSnapshot.fromJson({
        'items': [
          {'id': 'music_1', 'title': 'a'},
          {'id': 'music_1', 'title': 'a'},
          {'id': '', 'title': 'bad'},
          {'title': 'no id'},
        ],
        'currentId': 'music_1',
      })!;
      expect(snap.items.map((e) => e.id), ['music_1']);
      expect(snap.currentId, 'music_1');
      expect(AudioQueueSnapshot.fromJson({'items': []}), isNull);
      expect(AudioQueueSnapshot.fromJson(null), isNull);
    });
  });

  group('按 id 回填（Song.getinfo）', () {
    test('顺序 = 快照顺序；下标优先"这次打开的那一首"', () async {
      final snap = AudioQueueSnapshot(
        items: [_ref('music_3'), _ref('music_1'), _ref('music_2')],
        currentId: 'music_3',
      );
      final asked = <String>[];
      final r = await restoreAudioQueue(
        snapshot: snap,
        preferId: 'music_1',
        fetch: (id) async {
          asked.add(id);
          return _song(id);
        },
      );
      expect(asked, ['music_3', 'music_1', 'music_2'], reason: '按快照顺序逐条回填');
      expect(r.songs.map((s) => s.id), ['music_3', 'music_1', 'music_2']);
      expect(r.index, 1, reason: '下标 = 这次点开的那一首，不抢用户选择');
      expect(r.skipped, isEmpty);
    });

    test('preferId 不在快照里 → 退回 snapshot.currentId 的下标', () async {
      final snap = AudioQueueSnapshot(
        items: [_ref('music_1'), _ref('music_2')],
        currentId: 'music_2',
      );
      final r = await restoreAudioQueue(
        snapshot: snap,
        preferId: 'music_x',
        fetch: (id) async => _song(id),
      );
      expect(r.index, 1);
    });

    test('被删 / 无权限（null 或抛）→ 只跳过该首并告知，其余照常恢复', () async {
      final snap = AudioQueueSnapshot(
        items: [
          _ref('gone', title: '被删的歌'),
          _ref('music_2'),
          _ref('denied', title: '没权限的歌'),
        ],
        currentId: 'music_2',
      );
      final r = await restoreAudioQueue(
        snapshot: snap,
        fetch: (id) async {
          if (id == 'gone') return null;
          if (id == 'denied') throw Exception('403');
          return _song(id);
        },
      );
      expect(r.songs.map((s) => s.id), ['music_2']);
      expect(r.index, 0);
      expect(r.skipped, ['被删的歌', '没权限的歌'], reason: '失败的要能告知用户');
    });

    test('全部失效 → 空结果 + skipped 齐全（调用方不得据此清空快照）', () async {
      final snap = AudioQueueSnapshot(
        items: [
          _ref('a', title: 'A'),
          _ref('b', title: 'B'),
        ],
        currentId: 'a',
      );
      final r = await restoreAudioQueue(
        snapshot: snap,
        fetch: (id) async => null,
      );
      expect(r.songs, isEmpty);
      expect(r.skipped, ['A', 'B']);
      expect(r.index, 0);
    });

    test('回填预算：队列超预算时最多 maxItems 次请求，且"打开的那首"一定在', () async {
      final items = [for (var i = 0; i < 12; i++) _ref('music_$i')];
      final snap = AudioQueueSnapshot(items: items, currentId: 'music_0');
      final asked = <String>[];
      final r = await restoreAudioQueue(
        snapshot: snap,
        preferId: 'music_11',
        maxItems: 3,
        fetch: (id) async {
          asked.add(id);
          return _song(id);
        },
      );
      expect(asked.length, 3, reason: '不能按 8192 的队列上限逐条打服务端');
      expect(
        asked,
        contains('music_11'),
        reason: '被预算截在外的"这次打开的那首"要替进预算，否则用户点开也播不了',
      );
      expect(r.songs.length, 3);
      expect(r.index, 2, reason: '替进来的那首落在最后一条');
    });
  });

  group('存储复用 media_playback.json（跨实例 = 重启后还在）', () {
    test('AS 队列与倍速同文件共存，跨 store 实例读回', () async {
      final dir = await Directory.systemTemp.createTemp('as_queue_test');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File('${dir.path}/prefs.json');

      final first = AppMediaPlaybackStore(fileResolver: () async => file);
      await first.saveSpeed(1.25);
      await first.saveAudioQueue(
        AudioQueueSnapshot(
          items: [
            _ref('music_1', title: 'a'),
            _ref('music_2', title: 'b'),
          ],
          currentId: 'music_2',
        ),
      );

      final second = AppMediaPlaybackStore(fileResolver: () async => file);
      final queue = await second.loadAudioQueue();
      expect(queue, isNotNull);
      expect(queue!.items.map((e) => e.id), ['music_1', 'music_2']);
      expect(queue.currentId, 'music_2');
      expect(await second.loadSpeed(), 1.25, reason: '两套数据共用同一个文件');
    });

    test('坏 JSON → AS 队列当没存过，不抛', () async {
      final dir = await Directory.systemTemp.createTemp('as_queue_bad');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File('${dir.path}/prefs.json')..writeAsStringSync('{oops');
      final store = AppMediaPlaybackStore(fileResolver: () async => file);
      expect(await store.loadAudioQueue(), isNull);
    });

    test('无平台通道（resolver → null）→ 退回内存，进程内仍记得', () async {
      final store = AppMediaPlaybackStore(fileResolver: () async => null);
      await store.saveAudioQueue(
        AudioQueueSnapshot(items: [_ref('music_1')], currentId: 'music_1'),
      );
      expect((await store.loadAudioQueue())!.items.single.id, 'music_1');
    });

    test('空快照是删除（不把"取消"存成一条空队列）', () async {
      final dir = await Directory.systemTemp.createTemp('as_queue_empty');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File('${dir.path}/prefs.json');
      final store = AppMediaPlaybackStore(fileResolver: () async => file);
      await store.saveAudioQueue(
        AudioQueueSnapshot(items: [_ref('music_1')], currentId: 'music_1'),
      );
      await store.saveAudioQueue(
        const AudioQueueSnapshot(items: [], currentId: ''),
      );
      expect(
        await AppMediaPlaybackStore(
          fileResolver: () async => file,
        ).loadAudioQueue(),
        isNull,
      );

      final mem = InMemoryMediaPlaybackStore();
      await mem.saveAudioQueue(
        const AudioQueueSnapshot(items: [], currentId: ''),
      );
      expect(await mem.loadAudioQueue(), isNull);
    });

    test('内存实现可预置快照（页面测试注入用）', () async {
      final store = InMemoryMediaPlaybackStore(
        audioQueue: AudioQueueSnapshot(
          items: [_ref('music_9')],
          currentId: 'music_9',
        ),
      );
      expect((await store.loadAudioQueue())!.currentId, 'music_9');
    });
  });
}
