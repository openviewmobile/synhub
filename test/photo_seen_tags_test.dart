// r412 · DA70：相册**本机见过的标签**（本地记忆 + 补台口径）离线测试。
//
// 现场事实（`docs/evidence-r412/nas/r412_probe_tags_persons.log`）：
// 这台 NAS 上 `GeneralTag/list|count|get` **恒空**，而 `suggest{keyword}` 能查到
// `{"id":1,"name":"huihubtag"}`、`Item/list_with_filter{general_tag_id:[1]}` 能过滤出
// 它的照片 ⇒ 只认 `list` 的标签浏览页会永远写「还没有标签」。
//
// 本文件钉住的是**补台口径本身**（不是页面渲染，页面渲染在 `photo_wave2_test.dart`）：
//   * 服务端有数据 ⇒ **一律以服务端为准**（不是并集，避免把旧记忆当现状）；
//   * 服务端为空 ⇒ 用本机记忆补，并且**必须**能说出"这是补来的"；
//   * 空间隔离（个人 / 共享两边的 tag id 可能撞）；
//   * 记忆的落盘/回读/去重/上限。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/features/photos/photo_prefs_store.dart';
import 'package:synhub/src/features/photos/photo_seen_tags.dart';

class _MemPrefs implements PhotoPrefsStore {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);
}

FotoTagDto _tag(String id, String name, [int count = 0]) =>
    FotoTagDto(id: id, name: name, count: count);

void main() {
  group('★ r412 DA70：本机见过的标签 · 编解码', () {
    test('① 往返：encode → decode 逐条相同', () {
      const tags = [
        PhotoSeenTag(space: 'personal', id: '1', name: 'huihubtag', count: 1),
        PhotoSeenTag(space: 'team', id: '2', name: '团队', count: 0),
      ];
      final back = decodePhotoSeenTags(encodePhotoSeenTags(tags));
      expect(back.length, 2);
      expect(back[0].space, 'personal');
      expect(back[0].id, '1');
      expect(back[0].name, 'huihubtag');
      expect(back[0].count, 1);
      expect(back[1].space, 'team');
    });

    test('② 坏数据一律回空，绝不抛（本地记忆坏掉不许让相册崩）', () {
      expect(decodePhotoSeenTags(null), isEmpty);
      expect(decodePhotoSeenTags(''), isEmpty);
      expect(decodePhotoSeenTags('  '), isEmpty);
      expect(decodePhotoSeenTags('{不是数组}'), isEmpty);
      expect(decodePhotoSeenTags('乱码'), isEmpty);
      // 数组里混了坏项：好的留下、坏的丢掉
      final mixed = decodePhotoSeenTags(
        '[{"space":"personal","id":"1","name":"a"},'
        '{"space":"","id":"2","name":"b"},'
        '{"id":"3","name":"c"},'
        '"字符串",'
        '{"space":"personal","id":"4"},'
        '{"space":"personal","id":"1","name":"dup"}]',
      );
      expect(mixed.map((e) => e.id).toList(), ['1', '4']);
      // name 缺失时回落 id（宁可显示 id，也不显示空白行）
      expect(mixed[1].name, '4');
    });

    test('③ 上限：超出只留前 N 条', () {
      final many = [
        for (var i = 0; i < kPhotoSeenTagsLimit + 20; i++)
          PhotoSeenTag(space: 'personal', id: '$i', name: 't$i'),
      ];
      expect(decodePhotoSeenTags(encodePhotoSeenTags(many)).length,
          kPhotoSeenTagsLimit);
    });
  });

  group('★ r412 DA70：本机见过的标签 · 补台口径', () {
    test('① 服务端 list 空 + 本机有 ⇒ 补上，并**如实标出**这是补来的', () {
      final view = photoTagView(
        server: const [],
        seen: const [
          PhotoSeenTag(space: 'personal', id: '1', name: 'huihubtag', count: 1),
        ],
        space: 'personal',
      );
      expect(view.tags.length, 1);
      expect(view.tags.first.name, 'huihubtag');
      expect(view.serverIsEmptyButLocal, isTrue);
    });

    test('② 服务端 list 空 + 本机也空 ⇒ 空态（不许出现"补来的"说明）', () {
      final view = photoTagView(
        server: const [],
        seen: const [],
        space: 'personal',
      );
      expect(view.tags, isEmpty);
      expect(view.serverIsEmptyButLocal, isFalse);
    });

    test('③ 服务端 list 有数据 ⇒ **以服务端为准**（本机旧记忆不混进来）', () {
      final view = photoTagView(
        server: [_tag('9', '旅行', 4)],
        seen: const [
          PhotoSeenTag(space: 'personal', id: '1', name: 'huihubtag', count: 1),
        ],
        space: 'personal',
      );
      expect(view.tags.map((e) => e.id).toList(), ['9']);
      expect(view.serverIsEmptyButLocal, isFalse);
    });

    test('④ 空间隔离：别的空间的记忆不许补进本空间', () {
      final view = photoTagView(
        server: const [],
        seen: const [
          PhotoSeenTag(space: 'team', id: '1', name: '团队标签'),
        ],
        space: 'personal',
      );
      expect(view.tags, isEmpty);
      expect(view.serverIsEmptyButLocal, isFalse);
    });

    test('⑤ 补进来的多条按名字排序（渲染稳定），且去重按 id', () {
      final merged = mergePhotoTags(
        server: [_tag('9', '旅行')],
        seen: const [
          PhotoSeenTag(space: 'personal', id: '3', name: 'b'),
          PhotoSeenTag(space: 'personal', id: '2', name: 'A'),
          PhotoSeenTag(space: 'personal', id: '9', name: '旅行重复'),
        ],
        space: 'personal',
      );
      expect(merged.map((e) => e.id).toList(), ['9', '2', '3']);
      // 服务端那条**顺序不动**、名字也不被本地覆盖
      expect(merged.first.name, '旅行');
    });
  });

  group('★ r412 DA70：本机见过的标签 · 记忆与落盘', () {
    test('① remember 落盘 + state 最近在前 + 同 id 去重刷新', () async {
      final prefs = _MemPrefs();
      final c = ProviderContainer(
        overrides: [photoPrefsStoreProvider.overrideWithValue(prefs)],
      );
      addTearDown(c.dispose);
      final n = c.read(photoSeenTagsProvider.notifier);

      await n.remember('personal', [_tag('1', 'huihubtag', 1)]);
      expect(c.read(photoSeenTagsProvider).length, 1);
      expect(prefs.data[kPhotoSeenTagsSlot], isNotNull);

      await n.remember('personal', [_tag('2', '第二个')]);
      expect(c.read(photoSeenTagsProvider).map((e) => e.id).toList(), [
        '2',
        '1',
      ]);

      // 同一个 id 再来一次：不重复、且刷新 name/count（名字改过后要跟上）
      await n.remember('personal', [_tag('1', 'huihubtag2', 7)]);
      final state = c.read(photoSeenTagsProvider);
      expect(state.length, 2);
      expect(state.first.id, '1');
      expect(state.first.name, 'huihubtag2');
      expect(state.first.count, 7);
    });

    test('② forSpace 只回本空间的；空列表 remember 不写盘', () async {
      final prefs = _MemPrefs();
      final c = ProviderContainer(
        overrides: [photoPrefsStoreProvider.overrideWithValue(prefs)],
      );
      addTearDown(c.dispose);
      final n = c.read(photoSeenTagsProvider.notifier);

      await n.remember('personal', [_tag('1', '个人')]);
      await n.remember('team', [_tag('1', '团队')]);
      expect(n.forSpace('personal').single.name, '个人');
      expect(n.forSpace('team').single.name, '团队');

      final before = prefs.data[kPhotoSeenTagsSlot];
      await n.remember('personal', const []);
      expect(prefs.data[kPhotoSeenTagsSlot], before);
    });

    test('③ 冷启动：新建容器能从盘里回读（不受"这次没交互"影响）', () async {
      final prefs = _MemPrefs();
      prefs.data[kPhotoSeenTagsSlot] = encodePhotoSeenTags(const [
        PhotoSeenTag(space: 'personal', id: '1', name: 'huihubtag', count: 1),
      ]);
      final c = ProviderContainer(
        overrides: [photoPrefsStoreProvider.overrideWithValue(prefs)],
      );
      addTearDown(c.dispose);
      // build() 里是 unawaited(_restore())，等一个微任务轮次
      c.read(photoSeenTagsProvider);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(photoSeenTagsProvider).single.name, 'huihubtag');
      expect(
        c.read(photoSeenTagsProvider.notifier).forSpace('personal').length,
        1,
      );
    });
  });
}
