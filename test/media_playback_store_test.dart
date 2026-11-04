// W1-2：播放偏好/队列持久化（`media_playback_store.dart`）的离线单测。
//
// 关注四件事：
//   1. 倍速**吸附到合法档位**（旧值/脏值不能把界面带到菜单外）；
//   2. 队列快照的**核对规则**（丢已删、留顺序、加新增、恢复当前下标）；
//   3. JSON 落盘**跨实例**可读（= 进程重启后还在）；
//   4. 坏 JSON / 读不出来 → 当没存过，**不抛**。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/media/media_playback_store.dart';

MediaQueueRef _ref(String name, {String? path}) =>
    MediaQueueRef(path: path ?? '/v/$name', name: name);

void main() {
  group('倍速吸附', () {
    test('正好等于档位 → 原样', () {
      for (final s in kMediaPlaybackSpeeds) {
        expect(normalizeMediaPlaybackSpeed(s), s);
      }
    });

    test('脏值/越界吸附到最近档位或 1.0', () {
      expect(normalizeMediaPlaybackSpeed(1.9), 2.0);
      expect(normalizeMediaPlaybackSpeed(0.6), 0.5);
      expect(normalizeMediaPlaybackSpeed(0.9), 1.0);
      expect(normalizeMediaPlaybackSpeed(3.0), 2.0);
      expect(normalizeMediaPlaybackSpeed(0), 1.0);
      expect(normalizeMediaPlaybackSpeed(-2), 1.0);
      expect(normalizeMediaPlaybackSpeed(double.nan), 1.0);
      expect(normalizeMediaPlaybackSpeed(double.infinity), 1.0);
    });
  });

  group('队列快照核对', () {
    test('顺序来自快照；已消失的丢掉；新增的补到末尾', () {
      final snap = MediaQueueSnapshot(
        queueKey: '/v',
        items: [_ref('ep3.mp4'), _ref('ep1.mp4'), _ref('gone.mp4')],
        currentPath: '/v/ep1.mp4',
      );
      final available = [_ref('ep1.mp4'), _ref('ep2.mp4'), _ref('ep3.mp4')];
      final r = reconcileMediaQueue(snap, available)!;
      expect(r.paths, ['/v/ep3.mp4', '/v/ep1.mp4', '/v/ep2.mp4']);
      expect(r.index, 1, reason: '上次播的 ep1 在新顺序里的下标');
    });

    test('当前条目已不存在 → 下标退回 0（不假装恢复成功）', () {
      final snap = MediaQueueSnapshot(
        queueKey: '/v',
        items: [_ref('gone.mp4')],
        currentPath: '/v/gone.mp4',
      );
      final r = reconcileMediaQueue(snap, [_ref('a.mp4'), _ref('b.mp4')])!;
      expect(r.paths, ['/v/a.mp4', '/v/b.mp4']);
      expect(r.index, 0);
    });

    test('可用条目为空 → null（调用方不恢复）', () {
      final snap = MediaQueueSnapshot(
        queueKey: '/v',
        items: [_ref('a.mp4')],
        currentPath: '/v/a.mp4',
      );
      expect(reconcileMediaQueue(snap, const []), isNull);
    });

    test('快照里的重复路径只保留一次', () {
      final snap = MediaQueueSnapshot(
        queueKey: '/v',
        items: [_ref('a.mp4'), _ref('a.mp4'), _ref('b.mp4')],
        currentPath: '/v/a.mp4',
      );
      final r = reconcileMediaQueue(snap, [_ref('a.mp4'), _ref('b.mp4')])!;
      expect(r.paths, ['/v/a.mp4', '/v/b.mp4']);
    });
  });

  group('JSON 落盘（跨实例 = 重启后还在）', () {
    test('倍速 / 字幕 / 队列都能跨 store 实例读回', () async {
      final dir = await Directory.systemTemp.createTemp('media_prefs_test');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File('${dir.path}/prefs.json');

      final first = AppMediaPlaybackStore(fileResolver: () async => file);
      await first.saveSpeed(1.5);
      await first.saveSubtitle('/v/ep1.mp4|100', 'external:ep1.zh.srt');
      await first.saveQueue(
        MediaQueueSnapshot(
          queueKey: '/v',
          items: [_ref('ep3.mp4'), _ref('ep1.mp4')],
          currentPath: '/v/ep1.mp4',
        ),
      );

      // 新实例 = 模拟进程重启
      final second = AppMediaPlaybackStore(fileResolver: () async => file);
      expect(await second.loadSpeed(), 1.5);
      expect(
        await second.loadSubtitle('/v/ep1.mp4|100'),
        'external:ep1.zh.srt',
      );
      final queue = await second.loadQueue('/v');
      expect(queue, isNotNull);
      expect(queue!.items.map((e) => e.name), ['ep3.mp4', 'ep1.mp4']);
      expect(queue.currentPath, '/v/ep1.mp4');
    });

    test('坏 JSON → 当没存过，不抛', () async {
      final dir = await Directory.systemTemp.createTemp('media_prefs_bad');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File('${dir.path}/prefs.json')..writeAsStringSync('{oops');
      final store = AppMediaPlaybackStore(fileResolver: () async => file);
      expect(await store.loadSpeed(), isNull);
      expect(await store.loadSubtitle('a'), isNull);
      expect(await store.loadQueue('/v'), isNull);
    });

    test('脏倍速落盘前已被吸附（菜单里一定找得到）', () async {
      final dir = await Directory.systemTemp.createTemp('media_prefs_dirty');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File('${dir.path}/prefs.json');
      final store = AppMediaPlaybackStore(fileResolver: () async => file);
      await store.saveSpeed(1.9);
      final raw = jsonDecode(await file.readAsString()) as Map;
      expect(raw['speed'], 2.0);
      expect(await store.loadSpeed(), 2.0);
    });

    test('文件解析器给 null（无平台通道）→ 退回内存，仍能记住', () async {
      final store = AppMediaPlaybackStore(fileResolver: () async => null);
      await store.saveSpeed(0.75);
      expect(await store.loadSpeed(), 0.75);
      await store.saveSubtitle('k', 'off');
      expect(await store.loadSubtitle('k'), 'off');
    });
  });

  group('内存实现', () {
    test('saveSubtitle(null) 是删除', () async {
      final store = InMemoryMediaPlaybackStore();
      await store.saveSubtitle('k', 'off');
      expect(await store.loadSubtitle('k'), 'off');
      await store.saveSubtitle('k', null);
      expect(await store.loadSubtitle('k'), isNull);
    });

    test('空队列不落（避免把"取消"存成一条空队列）', () async {
      final store = InMemoryMediaPlaybackStore();
      await store.saveQueue(
        const MediaQueueSnapshot(queueKey: '/v', items: [], currentPath: ''),
      );
      expect(await store.loadQueue('/v'), isNull);
    });
  });
}
