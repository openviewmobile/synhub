// 相册 wave2（搜索筛选 / 标签浏览 / 人物人脸）离线测试。
//
// 覆盖：
//   * 接口层请求形状（api / method / version / params）：
//     `GeneralTag/count|get|list`、`Browse.Item/list_with_filter`（`general_tag_id`
//     + `offset`/`limit`）、`Person/suggest`（v3）、`Person/list_face`（v1）、
//     `Search.Search/get_search_timeline`（v7）；
//   * DTO：`Search.Filter/list` 回包解析（顶层"组名 → 选项数组"+ 容错形态）；
//   * provider：搜索结果分页（`offset` 递增、去重、收尾）；
//   * 页面层：筛选面板（成功 / 认不出 / 失败三态）、标签入口 + 标签详情、
//     人物入口能力门控（缺 `SYNO.Foto.Browse.Person` → 隐藏）、人物相册人脸条数。
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/dto/foto_c2_dto.dart';
import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/foto_c2_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/photos/photo_c2_page.dart';
import 'package:synhub/src/features/photos/photo_prefs_store.dart';
import 'package:synhub/src/features/photos/photo_seen_tags.dart';
import 'package:synhub/src/features/photos/photo_c2_providers.dart';
import 'package:synhub/src/features/photos/photo_c2_sections.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';
import 'package:synhub/src/features/photos/photo_wave2_page.dart';
import 'package:synhub/src/features/photos/photo_wave2_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

/// 内存版偏好存储：标签页的"本机见过"记忆要能**可控地**预置/读出。
class _MemPrefs implements PhotoPrefsStore {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);
}

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

const _wave2Table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Foto.Setting.User': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 9,
  },
  'SYNO.Foto.Browse.Album': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 5,
  },
  'SYNO.Foto.Browse.Folder': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 5,
  },
  'SYNO.Foto.Browse.GeneralTag': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Browse.Person': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  // P19：概念写操作要用到；缺了它会直接 102（能力表缺失 ≠ 方法不存在）
  'SYNO.Foto.Browse.Concept': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Search.Search': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 7,
  },
  'SYNO.Foto.Search.Filter': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.Foto.Thumbnail': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

Map<String, dynamic> _item(String id) => {
  'id': id,
  'filename': 'IMG_$id.jpg',
  'filesize': 2048,
  'time': DateTime(2026, 9, 18, 10).millisecondsSinceEpoch ~/ 1000,
  'folder_id': '10',
  'type': 'photo',
  'additional': {
    'thumbnail': {'sm': 'sm_$id', 'm': 'm_$id', 'cache_key': 'ck_$id'},
  },
};

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

FakeTransport _transport({
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, int> failures = const {},
  Map<String, dynamic>? Function(Map<String, dynamic> params)? onCall,
}) {
  final t = FakeTransport(
    {...responses},
    {...FakeTransport.table, ..._wave2Table},
  );
  t.downloadBytes = _png;
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    if (key == 'SYNO.Foto.Setting.User.get') {
      return {
        'team_space_permission': 'none',
        'enable_person': true,
        'timeline_group_unit': 'day',
      };
    }
    final custom = onCall?.call(params);
    if (custom != null) return custom;
    return responses[key] ?? const <String, dynamic>{};
  };
  t.failures.addAll(failures);
  return t;
}

// ================================================================ 接口层

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('标签接口（wave2 新增）', () {
    test('generalTagCount：GeneralTag/count v2（无参）→ count', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.GeneralTag.count': {'count': 7},
        },
      );
      final api = await _loggedIn(t);
      expect(await FotoApi(api).generalTagCount(), 7);
      final call = t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Foto.Browse.GeneralTag',
      );
      expect(call['method'], 'count');
      expect(call['version'], '2');
    });

    test('tagDetails：GeneralTag/get v2 + id 数字数组 JSON 串', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.GeneralTag.get': {
            'list': [
              {'id': 3, 'name': '旅行', 'count': 12},
            ],
          },
        },
      );
      final api = await _loggedIn(t);
      final tags = await FotoApi(api).tagDetails(['3', '5']);
      expect(tags.single.name, '旅行');
      expect(tags.single.count, 12);
      final call = t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Foto.Browse.GeneralTag',
      );
      expect(call['method'], 'get');
      expect(call['version'], '2');
      expect(jsonDecode(call['id'] as String), [3, 5]);
    });

    test('tagDetails：空入参 / 非数字 → 不发请求', () async {
      final t = _transport();
      final api = await _loggedIn(t);
      expect(await FotoApi(api).tagDetails(const []), isEmpty);
      expect(await FotoApi(api).tagDetails(['abc']), isEmpty);
      expect(t.calls.where((c) => c['method'] == 'get'), isEmpty);
    });

    test(
      'tagItems：Browse.Item/list_with_filter v7 + general_tag_id（数字）+ offset',
      () async {
        final t = _transport(
          responses: {
            'SYNO.Foto.Browse.Item.list_with_filter': {
              'list': [_item('11')],
            },
          },
        );
        final api = await _loggedIn(t);
        final items = await FotoApi(api).tagItems('9');
        expect(items.single.id, '11');
        final call = t.calls.lastWhere(
          (c) => c['method'] == 'list_with_filter',
        );
        expect(call['api'], 'SYNO.Foto.Browse.Item');
        expect(call['version'], '7');
        expect(call['general_tag_id'], '9'); // 裸数字，不是数组
        expect(call['offset'], '0');
        expect(call['limit'], '$kFotoTagItemsPageSize');
        expect(jsonDecode(call['additional'] as String), contains('thumbnail'));
      },
    );

    test('tagItems：第二页带 offset=100', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.Item.list_with_filter': {'list': []},
        },
      );
      final api = await _loggedIn(t);
      await FotoApi(api).tagItems('9', offset: 100);
      final call = t.calls.lastWhere((c) => c['method'] == 'list_with_filter');
      expect(call['offset'], '100');
    });
  });

  group('人物接口（wave2 新增）', () {
      test('P18 personSetName → Person/set，字段 id + name（官方 smali 逐字）', () async {
        final t = _transport(
          responses: {'SYNO.Foto.Browse.Person.set': <String, dynamic>{}},
        );
        final api = await _loggedIn(t);
        await FotoApi(api).personSetName(personId: '12', name: '小明');
        final call = t.calls.lastWhere((c) => c['api'] == 'SYNO.Foto.Browse.Person');
        expect(call['method'], 'set');
        expect(call['id'], '12');
        expect(call['name'], '小明');
      });

      test('P18 personSetCover → Person/set_cover，字段 id + photo_id', () async {
        final t = _transport(
          responses: {'SYNO.Foto.Browse.Person.set_cover': <String, dynamic>{}},
        );
        final api = await _loggedIn(t);
        await FotoApi(api).personSetCover(personId: '12', photoId: '99');
        final call = t.calls.lastWhere((c) => c['api'] == 'SYNO.Foto.Browse.Person');
        expect(call['method'], 'set_cover');
        expect(call['id'], '12');
        expect(call['photo_id'], '99');
      });

      test('P18 personDeleteFace → Person/delete_face，字段 person_id + face_id', () async {
        final t = _transport(
          responses: {'SYNO.Foto.Browse.Person.delete_face': <String, dynamic>{}},
        );
        final api = await _loggedIn(t);
        await FotoApi(api).personDeleteFace(personId: '12', faceIds: ['31']);
        final call = t.calls.lastWhere((c) => c['api'] == 'SYNO.Foto.Browse.Person');
        expect(call['method'], 'delete_face');
        expect(call['person_id'], '12');
        expect(jsonDecode(call['face_id'] as String), [31]);
      });

      test('P18 personSeparateFace → Person/separate（face_id 必带，name/target_id 可选）', () async {
        final t = _transport(
          responses: {'SYNO.Foto.Browse.Person.separate': <String, dynamic>{}},
        );
        final api = await _loggedIn(t);
        await FotoApi(api).personSeparateFace(faceIds: ['31']);
        var call = t.calls.lastWhere((c) => c['api'] == 'SYNO.Foto.Browse.Person');
        expect(call['method'], 'separate');
        expect(jsonDecode(call['face_id'] as String), [31]);
        expect(call.containsKey('name'), isFalse, reason: '空值不发');
        expect(call.containsKey('target_id'), isFalse);

        await FotoApi(api).personSeparateFace(
          faceIds: ['32'],
          name: '新人物',
          targetId: '12',
        );
        call = t.calls.lastWhere((c) => c['api'] == 'SYNO.Foto.Browse.Person');
        expect(call['name'], '新人物');
        expect(call['target_id'], '12');
      });

      test('P18 personMerge → Person/merge v2，字段 target_id + merged_id(数组) + name', () async {
        final t = _transport(
          responses: {'SYNO.Foto.Browse.Person.merge': <String, dynamic>{}},
        );
        final api = await _loggedIn(t);
        await FotoApi(api).personMerge(
          targetId: '7',
          mergedIds: ['8', '9'],
          name: '小明',
        );
        final call = t.calls.lastWhere((c) => c['api'] == 'SYNO.Foto.Browse.Person');
        expect(call['method'], 'merge');
        expect(call['version'], '2', reason: '官方 Web 方法表钉 merge:2');
        expect(call['target_id'], '7');
        expect(jsonDecode(call['merged_id'] as String), [8, 9]);
        expect(call['name'], '小明');
      });

      test('P18 personMerge：省略 name 就不发；空 mergedIds / 非数字 target → 零请求', () async {
        final t = _transport(
          responses: {'SYNO.Foto.Browse.Person.merge': <String, dynamic>{}},
        );
        final api = await _loggedIn(t);
        await FotoApi(api).personMerge(targetId: '7', mergedIds: ['8']);
        var call = t.calls.lastWhere((c) => c['api'] == 'SYNO.Foto.Browse.Person');
        expect(call.containsKey('name'), isFalse);

        final before = t.calls.length;
        await FotoApi(api).personMerge(targetId: '7', mergedIds: const []);
        await FotoApi(api).personMerge(targetId: 'x', mergedIds: ['8']);
        expect(t.calls.length, before, reason: '空/非法入参一个请求都不发');
      });

      test('P18 personShow → Person/show v1，id 数组 + show 布尔字符串', () async {
        final t = _transport(
          responses: {'SYNO.Foto.Browse.Person.show': <String, dynamic>{}},
        );
        final api = await _loggedIn(t);
        await FotoApi(api).personShow(personIds: ['7', '8'], show: false);
        final call = t.calls.lastWhere((c) => c['api'] == 'SYNO.Foto.Browse.Person');
        expect(call['method'], 'show');
        expect(call['version'], '1');
        expect(jsonDecode(call['id'] as String), [7, 8]);
        expect(call['show'], 'false');
      });

      test('P18 personShow：空 id 列表 → 零请求（不猜"隐藏全部"）', () async {
        final t = _transport();
        final api = await _loggedIn(t);
        await FotoApi(api).personShow(personIds: const [], show: true);
        expect(
          t.calls.where((c) => c['method'] == 'show'),
          isEmpty,
        );
      });

      test('P18/P19 写操作：空 id → 一个请求都不发', () async {
        final t = _transport();
        final api = await _loggedIn(t);
        final foto = FotoApi(api);
        await foto.personSetName(personId: '', name: 'x');
        await foto.personSetName(personId: '1', name: '');
        await foto.personSetCover(personId: '', photoId: '9');
        await foto.personDeleteFace(personId: '1', faceIds: const []);
        await foto.personSeparateFace(faceIds: const []);
        await foto.conceptHideItem(conceptId: '1', itemId: '');
        await foto.conceptSetCover(conceptId: '', photoId: '9');
        expect(
          t.calls.where(
            (c) =>
                c['api'] == 'SYNO.Foto.Browse.Person' ||
                c['api'] == 'SYNO.Foto.Browse.Concept',
          ),
          isEmpty,
        );
      });

      test('P19 conceptHideItem → Concept/hide_item，字段 id + item_id', () async {
        final t = _transport(
          responses: {'SYNO.Foto.Browse.Concept.hide_item': <String, dynamic>{}},
        );
        final api = await _loggedIn(t);
        await FotoApi(api).conceptHideItem(conceptId: '5', itemId: '77');
        final call = t.calls.lastWhere((c) => c['api'] == 'SYNO.Foto.Browse.Concept');
        expect(call['method'], 'hide_item');
        expect(call['id'], '5');
        expect(call['item_id'], '77');
      });

      test('P19 conceptSetCover → Concept/set_cover，字段 id + photo_id', () async {
        final t = _transport(
          responses: {'SYNO.Foto.Browse.Concept.set_cover': <String, dynamic>{}},
        );
        final api = await _loggedIn(t);
        await FotoApi(api).conceptSetCover(conceptId: '5', photoId: '88');
        final call = t.calls.lastWhere((c) => c['api'] == 'SYNO.Foto.Browse.Concept');
        expect(call['method'], 'set_cover');
        expect(call['id'], '5');
        expect(call['photo_id'], '88');
      });

    test('personSuggest：Person/suggest v3 + name_prefix/limit/additional', () async {
        final t = _transport(
          responses: {
            'SYNO.Foto.Browse.Person.suggest': {
              'list': [
                {'id': 3, 'name': '小美', 'item_count': 5},
              ],
            },
          },
        );
        final api = await _loggedIn(t);
        final people = await FotoApi(api).personSuggest('小');
        expect(people.single.name, '小美');
        final call = t.calls.lastWhere(
          (c) => c['api'] == 'SYNO.Foto.Browse.Person',
        );
        expect(call['method'], 'suggest');
        expect(call['version'], '3'); // 官方钉死 suggest:3
        expect(call['name_prefix'], '小');
        expect(call['limit'], '$kFotoPersonSuggestionLimit');
        expect(jsonDecode(call['additional'] as String), ['thumbnail']);
      },
    );

    test(
      'personFaces：Person/list_face v1 + person_id 裸数字 + item_id 数组',
      () async {
        final t = _transport(
          responses: {
            'SYNO.Foto.Browse.Person.list_face': {
              'list': [
                {'face_id': 1},
                {'face_id': 2},
              ],
            },
          },
        );
        final api = await _loggedIn(t);
        final faces = await FotoApi(
          api,
        ).personFaces('7', itemIds: ['11', '12']);
        expect(faces.length, 2);
        final call = t.calls.lastWhere(
          (c) => c['api'] == 'SYNO.Foto.Browse.Person',
        );
        expect(call['method'], 'list_face');
        expect(call['version'], '1');
        expect(call['person_id'], '7');
        expect(jsonDecode(call['item_id'] as String), [11, 12]);
      },
    );

    test('personFaces：itemIds 为空 → 不发请求', () async {
      final t = _transport();
      final api = await _loggedIn(t);
      expect(await FotoApi(api).personFaces('7', itemIds: const []), isEmpty);
      expect(t.calls.where((c) => c['method'] == 'list_face'), isEmpty);
    });
  });

  group('搜索时间轴 / 筛选回包', () {
    test('searchTimeline：get_search_timeline v7 + filter 原样透传', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Search.Search.get_search_timeline': {
            'list': [
              {'year': 2026, 'month': 9, 'item_count': 3},
            ],
          },
        },
      );
      final api = await _loggedIn(t);
      final data = await FotoC2Api(
        FotoApi(api),
      ).searchTimeline({'keyword': '海边', 'timeline_group_unit': 'day'});
      expect(data['list'], isA<List>());
      final call = t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Foto.Search.Search',
      );
      expect(call['method'], 'get_search_timeline');
      expect(call['version'], '7');
      expect(call['keyword'], '海边');
      expect(call['timeline_group_unit'], 'day');
    });

    test('FotoSearchFilterGroupDto.parse：顶层"组名 → 选项数组"', () {
      final groups = FotoSearchFilterGroupDto.parse({
        'aperture': [
          {'id': 1, 'name': 'f/2.8'},
          {'id': 'abc'}, // 没有可显示文案 → 丢弃，绝不显示内部 id
        ],
        'camera': [
          {'id': 9, 'name': 'iPhone 15'},
        ],
        'meta': 'not-a-list', // 非数组 → 忽略
      });
      expect(groups.map((g) => g.key), ['aperture', 'camera']);
      expect(groups.first.options.single.label, 'f/2.8');
      expect(groups.first.options.single.value, 1);
    });

    test('FotoSearchFilterGroupDto.parse：{list:[…]} 容错形态 + 区间组回填对象', () {
      final groups = FotoSearchFilterGroupDto.parse({
        'list': [
          {
            'key': 'exposure_time_group',
            'values': [
              {'name': '1/60 - 1/125', 'start': 1, 'end': 2},
            ],
          },
        ],
      });
      expect(groups.single.key, 'exposure_time_group');
      expect(groups.single.options.single.value, isA<Map>());
    });

    test('parse：认不出来 → 空列表（调用方给"不可用"，不当空结果）', () {
      expect(
        FotoSearchFilterGroupDto.parse(const <String, dynamic>{}),
        isEmpty,
      );
      expect(FotoSearchFilterGroupDto.parse(null), isEmpty);
    });
  });

  group('搜索结果分页（provider）', () {
    test('offset 递增 + 去重 + 收尾（第二页不重复）', () async {
      var listCalls = 0;
      final t = _transport(
        onCall: (params) {
          if ('${params['api']}.${params['method']}' ==
              'SYNO.Foto.Search.Search.list_item') {
            listCalls++;
            final offset = int.tryParse('${params['offset']}') ?? 0;
            if (offset == 0) {
              return {
                'list': [
                  for (var i = 0; i < kFotoSearchPageSize; i++) _item('$i'),
                ],
              };
            }
            return {
              'list': [_item('$offset')],
            };
          }
          return null;
        },
      );
      final api = await _loggedIn(t);
      final c = ProviderContainer(
        overrides: [fotoApiProvider.overrideWithValue(FotoApi(api))],
      );
      addTearDown(c.dispose);

      await c.read(photoSearchResultsProvider.notifier).search(keyword: '海边');
      var state = c.read(photoSearchResultsProvider).value!;
      expect(state.items.length, kFotoSearchPageSize);
      expect(state.hasMore, isTrue);
      expect(
        t.calls.firstWhere((x) => x['method'] == 'list_item')['offset'],
        '0',
      );

      await c.read(photoSearchResultsProvider.notifier).loadMore();
      state = c.read(photoSearchResultsProvider).value!;
      // 第二页 = 第一页之外的那 1 张（去重后 +1）
      expect(state.items.length, kFotoSearchPageSize + 1);
      expect(state.hasMore, isFalse);
      final offsets = t.calls
          .where((x) => x['method'] == 'list_item')
          .map((x) => x['offset'])
          .toList();
      expect(offsets, ['0', '$kFotoSearchPageSize']);
      expect(listCalls, 2);
    });

    test('失败 → AsyncError（不是空结果）', () async {
      final t = _transport(
        failures: const {'SYNO.Foto.Search.Search.list_item': 105},
      );
      final api = await _loggedIn(t);
      final c = ProviderContainer(
        overrides: [fotoApiProvider.overrideWithValue(FotoApi(api))],
      );
      addTearDown(c.dispose);
      await c.read(photoSearchResultsProvider.notifier).search(keyword: '海边');
      final value = c.read(photoSearchResultsProvider);
      expect(value.hasError, isTrue);
      expect(value, isA<AsyncError<PhotoSearchState>>());
    });
  });

  // ================================================================ 页面层

  group('搜索页（筛选面板 + 分页）', () {
    testWidgets('① 关键词 → list_item（offset=0）出网格', (tester) async {
      final r = await _pump(
        tester,
        const PhotoSearchPage(),
        responses: {
          'SYNO.Foto.Search.Search.list_item': {
            'list': [_item('1'), _item('2')],
          },
        },
      );
      expect(find.byKey(const Key('photo-c2-search-empty')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('photo-c2-search-field')),
        '海边',
      );
      await _tap(tester, 'photo-c2-search-go');
      expect(find.byKey(const Key('photo-c2-search-grid')), findsOneWidget);
      final call = r.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Foto.Search.Search',
      );
      expect(call['method'], 'list_item');
      expect(call['keyword'], '海边');
      expect(call['offset'], '0');
    });

    testWidgets('② 筛选面板：真实分组 → 勾选 → 应用后搜索带上该组', (tester) async {
      final r = await _pump(
        tester,
        const PhotoSearchPage(),
        responses: {
          'SYNO.Foto.Search.Filter.list': {
            'camera': [
              {'id': 9, 'name': 'iPhone 15'},
            ],
          },
          'SYNO.Foto.Search.Search.list_item': {
            'list': [_item('1')],
          },
        },
      );
      await _tap(tester, 'photo-c2-search-filter');
      expect(
        find.byKey(const Key('photo-c2-search-filter-sheet')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('photo-c2-search-filter-group-camera')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('photo-c2-search-filter-option-camera-iPhone 15')),
      );
      await tester.pump();
      await _tap(tester, 'photo-c2-search-filter-apply');
      final call = r.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Foto.Search.Search',
      );
      expect(call['camera'], isNotNull);
      expect(jsonDecode(call['camera'] as String), [9]);
      // 筛选生效的标志
      expect(
        find.byKey(const Key('photo-c2-search-filter-active')),
        findsOneWidget,
      );
    });

    testWidgets('③ 筛选回包认不出 → "筛选项暂时不可用"（不是空面板）', (tester) async {
      await _pump(
        tester,
        const PhotoSearchPage(),
        responses: {'SYNO.Foto.Search.Filter.list': <String, dynamic>{}},
      );
      await _tap(tester, 'photo-c2-search-filter');
      expect(find.text('筛选项暂时不可用'), findsOneWidget);
    });

    testWidgets('④ 筛选请求失败 → 加载失败 + 重试（不是空面板）', (tester) async {
      await _pump(
        tester,
        const PhotoSearchPage(),
        failures: const {'SYNO.Foto.Search.Filter.list': 105},
      );
      await _tap(tester, 'photo-c2-search-filter');
      expect(find.text('没有权限'), findsOneWidget);
      expect(
        find.byKey(const Key('photo-c2-search-filter')),
        findsOneWidget,
        reason: '面板打开后入口仍在（数据失败不影响入口）',
      );
    });

    testWidgets('⑤ 搜索失败（105）→ 明确提示，不显示成空结果', (tester) async {
      await _pump(
        tester,
        const PhotoSearchPage(),
        failures: const {'SYNO.Foto.Search.Search.list_item': 105},
      );
      await tester.enterText(
        find.byKey(const Key('photo-c2-search-field')),
        '海边',
      );
      await _tap(tester, 'photo-c2-search-go');
      expect(find.text('没有匹配的照片'), findsNothing);
      expect(find.text('没有权限'), findsOneWidget);
    });
  });

  group('标签页', () {
    testWidgets('① 标签列表 → 点开 → 详情走 list_with_filter', (tester) async {
      final r = await _pump(
        tester,
        const PhotoTagsPage(),
        responses: {
          'SYNO.Foto.Browse.GeneralTag.list': {
            'list': [
              {'id': 9, 'name': '旅行', 'count': 4},
            ],
          },
          'SYNO.Foto.Browse.GeneralTag.count': {'count': 1},
          'SYNO.Foto.Browse.GeneralTag.get': {
            'list': [
              {'id': 9, 'name': '旅行', 'count': 4},
            ],
          },
          'SYNO.Foto.Browse.Item.list_with_filter': {
            'list': [_item('11'), _item('12')],
          },
        },
      );
      expect(find.byKey(const Key('photo-c2-tag-total')), findsOneWidget);
      expect(find.byKey(const Key('photo-c2-tag-9')), findsOneWidget);
      await tester.tap(find.byKey(const Key('photo-c2-tag-9')));
      await _settle(tester);
      expect(find.byKey(const Key('photo-c2-tag-detail-grid')), findsOneWidget);
      final call = r.t.calls.lastWhere(
        (c) => c['method'] == 'list_with_filter',
      );
      expect(call['general_tag_id'], '9');
      expect(call['offset'], '0');
    });

    testWidgets('② 标签列表失败 → 加载失败 + 重试（不是空态）', (tester) async {
      await _pump(
        tester,
        const PhotoTagsPage(),
        failures: const {'SYNO.Foto.Browse.GeneralTag.list': 120},
      );
      expect(find.text('还没有标签'), findsNothing);
      expect(find.text('加载失败'), findsWidgets);
    });
  });

  group('★ r412 DA70：标签页补「本机见过」的标签', () {
    // 现场事实（`docs/evidence-r412/nas/r412_probe_tags_persons.log`）：
    // `GeneralTag/list` / `count` 恒空，而 `suggest` 能查到 `{"id":1,
    // "name":"huihubtag"}`、`list_with_filter?general_tag_id=[1]` 能过滤出照片。
    // ⇒ 只认 list 的标签页会永远写「还没有标签」，本 App 建的标签看不到。

    testWidgets('① 服务端 list 空 + 本机见过 ⇒ 列表出现 + 数字同源 + 如实说明来源', (tester) async {
      final prefs = _MemPrefs();
      prefs.data[kPhotoSeenTagsSlot] = encodePhotoSeenTags(const [
        PhotoSeenTag(space: 'personal', id: '1', name: 'huihubtag', count: 1),
      ]);
      final r = await _pump(
        tester,
        const PhotoTagsPage(),
        prefs: prefs,
        responses: {
          'SYNO.Foto.Browse.GeneralTag.list': {'list': <dynamic>[]},
          'SYNO.Foto.Browse.GeneralTag.count': {'count': 0},
          'SYNO.Foto.Browse.Item.list_with_filter': {
            'list': [_item('9552')],
          },
        },
      );
      // 标签出现了（改前这里是空态）
      expect(find.byKey(const Key('photo-c2-tag-1')), findsOneWidget);
      expect(find.text('huihubtag'), findsOneWidget);
      expect(find.text('还没有标签'), findsNothing);
      // 表头数字必须与屏上那份一致：服务端 count=0 时不能再写 0
      expect(find.byKey(const Key('photo-c2-tag-total')), findsOneWidget);
      expect(find.text('共 1 个标签'), findsOneWidget);
      expect(find.text('共 0 个标签'), findsNothing);
      // 补来的东西要说明来源（不静默）
      expect(find.byKey(const Key('photo-c2-tag-local-note')), findsOneWidget);
      // 点得进去 ⇒ `PhotoTagDetailPage` 在真机/离线都可达（r353 的"未验"根因）
      await tester.tap(find.byKey(const Key('photo-c2-tag-1')));
      await _settle(tester);
      expect(find.byKey(const Key('photo-c2-tag-detail-grid')), findsOneWidget);
      final call = r.t.calls.lastWhere(
        (c) => c['method'] == 'list_with_filter',
      );
      expect(call['general_tag_id'], '1');
    });

    testWidgets('② 反向：本机没记过 ⇒ 仍是空态，且**不许**出现来源说明', (tester) async {
      await _pump(
        tester,
        const PhotoTagsPage(),
        prefs: _MemPrefs(),
        responses: {
          'SYNO.Foto.Browse.GeneralTag.list': {'list': <dynamic>[]},
          'SYNO.Foto.Browse.GeneralTag.count': {'count': 0},
        },
      );
      expect(find.text('还没有标签'), findsOneWidget);
      expect(find.byKey(const Key('photo-c2-tag-local-note')), findsNothing);
      expect(find.text('共 0 个标签'), findsOneWidget);
    });

    testWidgets('③ 服务端 list 有数据 ⇒ 一律以服务端为准（本机那条不混进来、无说明）', (tester) async {
      final prefs = _MemPrefs();
      prefs.data[kPhotoSeenTagsSlot] = encodePhotoSeenTags(const [
        PhotoSeenTag(space: 'personal', id: '999', name: '本机旧的', count: 0),
      ]);
      await _pump(
        tester,
        const PhotoTagsPage(),
        prefs: prefs,
        responses: {
          'SYNO.Foto.Browse.GeneralTag.list': {
            'list': [
              {'id': 9, 'name': '旅行', 'count': 4},
            ],
          },
          'SYNO.Foto.Browse.GeneralTag.count': {'count': 1},
        },
      );
      expect(find.byKey(const Key('photo-c2-tag-9')), findsOneWidget);
      expect(find.text('本机旧的'), findsNothing);
      expect(find.byKey(const Key('photo-c2-tag-local-note')), findsNothing);
      expect(find.text('共 1 个标签'), findsOneWidget);
    });

    testWidgets('④ 服务端 list 失败 ⇒ 仍旧给"加载失败 + 重试"（不许拿本机记忆冒充成功）', (tester) async {
      final prefs = _MemPrefs();
      prefs.data[kPhotoSeenTagsSlot] = encodePhotoSeenTags(const [
        PhotoSeenTag(space: 'personal', id: '1', name: 'huihubtag'),
      ]);
      await _pump(
        tester,
        const PhotoTagsPage(),
        prefs: prefs,
        failures: const {'SYNO.Foto.Browse.GeneralTag.list': 120},
        responses: {
          'SYNO.Foto.Browse.GeneralTag.count': {'count': 0},
        },
      );
      expect(find.text('加载失败'), findsWidgets);
      expect(find.byKey(const Key('photo-c2-tag-1')), findsNothing);
      expect(find.byKey(const Key('photo-c2-tag-local-note')), findsNothing);
    });

    testWidgets('⑤ 空间隔离：共享空间的记忆不许出现在个人空间的标签页', (tester) async {
      final prefs = _MemPrefs();
      prefs.data[kPhotoSeenTagsSlot] = encodePhotoSeenTags(const [
        PhotoSeenTag(space: 'team', id: '1', name: '团队标签'),
      ]);
      await _pump(
        tester,
        const PhotoTagsPage(),
        prefs: prefs,
        responses: {
          'SYNO.Foto.Browse.GeneralTag.list': {'list': <dynamic>[]},
          'SYNO.Foto.Browse.GeneralTag.count': {'count': 0},
        },
      );
      expect(find.text('团队标签'), findsNothing);
      expect(find.text('还没有标签'), findsOneWidget);
    });
  });

  group('★ r412 DA71：标签详情的表头不许拿「已加载」冒充总数', () {
    // 真机读数（`docs/evidence-r412/device/r412_08_tag_detail_page.xml` 与
    // `r412_td_bottom` 像素）：标签 `huihubtag` 实际 **112** 张，而首屏（分页
    // 100/页）表头写 `100 photos`，滚到底 footer 才写 `All loaded (112 photos)`。
    // 根因：表头是 `detail.value?.count ?? state.items.length`，而
    // `GeneralTag/get` 在这台 NAS 上**恒空**（DA70 同一现场事实）⇒ 永远走兜底。

    testWidgets('① get 回空（拿不到真总数）⇒ 表头写「已加载 N 张」，不写"N 张照片"', (tester) async {
      await _pump(
        tester,
        PhotoTagDetailPage(tag: const FotoTagDto(id: '1', name: 'huihubtag')),
        responses: {
          'SYNO.Foto.Browse.Item.list_with_filter': {
            'list': [_item('11'), _item('12')],
          },
          'SYNO.Foto.Browse.GeneralTag.get': {'list': <dynamic>[]},
        },
      );
      expect(find.byKey(const Key('photo-c2-tag-detail-count')), findsOneWidget);
      expect(find.text('已加载 2 张'), findsOneWidget);
      expect(find.text('2 张照片'), findsNothing);
    });

    testWidgets('② 反向：服务端给了真总数 ⇒ 照旧写「N 张照片」（不许一律降级）', (tester) async {
      await _pump(
        tester,
        PhotoTagDetailPage(tag: const FotoTagDto(id: '9', name: '旅行')),
        responses: {
          'SYNO.Foto.Browse.Item.list_with_filter': {
            'list': [_item('11')],
          },
          'SYNO.Foto.Browse.GeneralTag.get': {
            'list': [
              {'id': 9, 'name': '旅行', 'count': 7},
            ],
          },
        },
      );
      expect(find.text('7 张照片'), findsOneWidget);
      expect(find.text('已加载 1 张'), findsNothing);
    });
  });

  group('人物页', () {
    testWidgets('① 人物网格 → 人物相册（list_face 条数）', (tester) async {
      final r = await _pump(
        tester,
        const PhotoPersonsPage(),
        responses: {
          'SYNO.Foto.Browse.Person.list': {
            'list': [
              {'id': 7, 'name': '小美', 'item_count': 2},
            ],
          },
          'SYNO.Foto.Browse.Item.list': {
            'list': [_item('11'), _item('12')],
          },
          'SYNO.Foto.Browse.Person.list_face': {
            'list': [
              {'face_id': 1},
              {'face_id': 2},
            ],
          },
        },
      );
      expect(find.byKey(const Key('photo-c2-person-7')), findsOneWidget);
      await tester.tap(find.byKey(const Key('photo-c2-person-7')));
      await _settle(tester);
      expect(
        find.byKey(const Key('photo-c2-person-album-grid')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('photo-c2-person-faces-count')),
        findsOneWidget,
      );
      final call = r.t.calls.lastWhere(
        (c) =>
            c['api'] == 'SYNO.Foto.Browse.Person' && c['method'] == 'list_face',
      );
      expect(call['version'], '1');
      expect(call['person_id'], '7');
    });

    testWidgets('② 输入前缀 → Person/suggest v3', (tester) async {
      final r = await _pump(
        tester,
        const PhotoPersonsPage(),
        responses: {
          'SYNO.Foto.Browse.Person.list': {'list': <Map<String, dynamic>>[]},
          'SYNO.Foto.Browse.Person.suggest': {
            'list': [
              {'id': 3, 'name': '小美'},
            ],
          },
        },
      );
      await tester.enterText(
        find.byKey(const Key('photo-c2-person-search')),
        '小',
      );
      await _settle(tester);
      final call = r.t.calls.lastWhere(
        (c) =>
            c['api'] == 'SYNO.Foto.Browse.Person' && c['method'] == 'suggest',
      );
      expect(call['version'], '3');
      expect(call['name_prefix'], '小');
      expect(find.byKey(const Key('photo-c2-person-3')), findsOneWidget);
    });

    testWidgets('③ list_face 失败 → 人脸行给重试，不假装 0', (tester) async {
      await _pump(
        tester,
        const PhotoPersonAlbumPage(personId: '7', name: '小美'),
        responses: {
          'SYNO.Foto.Browse.Item.list': {
            'list': [_item('11')],
          },
        },
        failures: const {'SYNO.Foto.Browse.Person.list_face': 120},
      );
      expect(
        find.byKey(const Key('photo-c2-person-faces-error')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('photo-c2-person-faces-retry')),
        findsOneWidget,
      );
    });
  });

  group('hub 入口能力门控（wave2）', () {
    testWidgets('① 能力位都在 → 标签 / 人物入口都在', (tester) async {
      await _pump(tester, const PhotoC2Page(), apis: _allWave2Apis);
      expect(find.byKey(const Key('photo-c2-entry-tags')), findsOneWidget);
      expect(find.byKey(const Key('photo-c2-entry-persons')), findsOneWidget);
    });

    testWidgets('② 缺 SYNO.Foto.Browse.Person → 人物入口消失，标签照常，且不发探测', (
      tester,
    ) async {
      final r = await _pump(
        tester,
        const PhotoC2Page(),
        apis: {..._allWave2Apis}..remove(kFotoPersonApi),
      );
      expect(find.byKey(const Key('photo-c2-entry-persons')), findsNothing);
      expect(find.byKey(const Key('photo-c2-entry-tags')), findsOneWidget);
      expect(_callCount(r.t, 'SYNO.Foto.Browse.Person.count'), 0);
    });

    testWidgets('③ 缺 SYNO.Foto.Browse.GeneralTag → 标签入口消失，人物照常', (
      tester,
    ) async {
      await _pump(
        tester,
        const PhotoC2Page(),
        apis: {..._allWave2Apis}..remove(kFotoGeneralTagApi),
      );
      expect(find.byKey(const Key('photo-c2-entry-tags')), findsNothing);
      expect(find.byKey(const Key('photo-c2-entry-persons')), findsOneWidget);
    });
  });
}

// ================================================================ 测试脚手架

const _allWave2Apis = {
  'SYNO.Foto.Browse.Item',
  'SYNO.Foto.Browse.Album',
  'SYNO.Foto.Streaming',
  'SYNO.Foto.Thumbnail',
  'SYNO.Foto.Download',
  'SYNO.Foto.Setting.User',
  kFotoSharingApi,
  kFotoPhotoRequestApi,
  kFotoGeocodingApi,
  kFotoSearchApi,
  kFotoSearchFilterApi,
  kFotoConditionAlbumApi,
  kFotoSimilarApi,
  kFotoGeneralTagApi,
  kFotoPersonApi,
};

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);

  final ServiceAvailabilitySnapshot snapshot;

  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

ServiceAvailabilitySnapshot _snap(Set<String> apis) =>
    ServiceAvailabilitySnapshot(
      states: {
        for (final s in StationService.values)
          s: s == StationService.photo
              ? classifyApiTable(kServiceRegistry[StationService.photo]!, apis)
              : AvailabilityState.available,
      },
      apis: apis,
      checkedAt: DateTime(2026, 9, 22),
    );

int _callCount(FakeTransport t, String key) =>
    t.calls.where((c) => '${c['api']}.${c['method']}' == key).length;

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(Key(key)));
  await _settle(tester);
}

Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  Set<String> apis = _allWave2Apis,
  Map<String, int> failures = const {},
  PhotoPrefsStore? prefs,
}) async {
  final t = _transport(responses: responses, failures: failures);
  final api = await _loggedIn(t);
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fotoApiProvider.overrideWithValue(FotoApi(api)),
      serviceAvailabilityProvider.overrideWith(
        () => _FixedAvailability(_snap(apis)),
      ),
      if (prefs != null) photoPrefsStoreProvider.overrideWithValue(prefs),
    ],
  );
  addTearDown(c.dispose);
  addTearDown(db.close);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await _settle(tester);
  return (t: t, c: c);
}
