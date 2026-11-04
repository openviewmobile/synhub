// 相册 P0 收尾：**公开 API 面覆盖补齐**。
//
// 背景（父 agent 的检查点要求）：早先一次脚本化"删死代码"误删了
// `test/photo_c2_api_test.dart` 10 块 + `test/photo_person_concept_test.dart` 5 块，
// 于是这些方法一度"方法在、没人测"。本文件**重新写**（不是还原原文）等价用例：
// 每个方法至少覆盖 **请求形状（api/method/version/参数名）** + **成功解析**，
// 有明确错误分支的再补 **错误码**。
//
// 事实来源仍是官方口径：
//   * 服务端方法表（SPK `usr/webapi/SYNO.Foto.lib`）的 method/version；
//   * 官方 Android 2.4.0-644（jadx）：`id` 一律是**数字数组的 JSON 串**；
//   * 官方 Web `ui/react_bundle.js`：`condition` / `additional` 都 JSON 编码。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/foto_c2_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Foto.Browse.Person': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.Foto.Browse.Concept': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Browse.ConditionAlbum': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 7,
  },
  'SYNO.Foto.Browse.NormalAlbum': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.Foto.Browse.SimilarTimeline': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Sharing.Misc': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Foto.Search.Search': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 7,
  },
  'SYNO.FotoTeam.Browse.Person': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
};

FakeTransport _transport({
  Map<String, Map<String, dynamic>> byApi = const {},
  Map<String, int> failures = const {},
}) {
  final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
  t.onCall = (params) => byApi['${params['api']}.${params['method']}'];
  t.failures.addAll(failures);
  return t;
}

Future<FotoApi> _foto(
  FakeTransport t, {
  FotoSpace space = FotoSpace.personal,
}) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return FotoApi(api, space: space);
}

Future<FotoC2Api> _c2(FakeTransport t) async => FotoC2Api(await _foto(t));

Map<String, dynamic> _last(FakeTransport t, String api) =>
    t.calls.lastWhere((c) => c['api'] == api);

void main() {
  group('人物 / 场景计数与详情（foto_api.dart）', () {
    test('personCount：Browse.Person/count，版本取服务端上限内，回 count', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Browse.Person.count': {'count': 12},
        },
      );
      final api = await _foto(t);
      expect(await api.personCount(showMore: true), 12);
      final call = _last(t, 'SYNO.Foto.Browse.Person');
      expect(call['method'], 'count');
      expect(call['show_more'], 'true');
      expect(call['show_hidden'], 'false');
    });

    test('personCount：缺 count 字段 → 0（不抛）', () async {
      final t = _transport();
      final api = await _foto(t);
      expect(await api.personCount(), 0);
    });

    test('personDetails：Browse.Person/get，id 是数字数组且过滤非数字', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Browse.Person.get': {
            'list': [
              {
                'id': 7,
                'name': '小明',
                'item_count': 3,
                'additional': {
                  'thumbnail': {'sm': 'sm_7'},
                },
              },
            ],
          },
        },
      );
      final api = await _foto(t);
      final people = await api.personDetails(['7', 'unit_xyz']);
      expect(people, hasLength(1));
      expect(people.single.id, '7');
      expect(people.single.name, '小明');
      expect(people.single.itemCount, 3);
      final call = _last(t, 'SYNO.Foto.Browse.Person');
      expect(call['method'], 'get');
      expect(call['id'], '[7]');
      expect('${call['additional']}', contains('thumbnail'));
    });

    test('personDetails：全非数字 / 空 → 不发请求', () async {
      final t = _transport();
      final api = await _foto(t);
      expect(await api.personDetails(const []), isEmpty);
      expect(await api.personDetails(const ['x']), isEmpty);
      expect(
        t.calls.where((c) => c['api'] == 'SYNO.Foto.Browse.Person'),
        isEmpty,
      );
    });

    test('conceptCount：Browse.Concept/count + show_hidden', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Browse.Concept.count': {'count': 5},
        },
      );
      final api = await _foto(t);
      expect(await api.conceptCount(showHidden: true), 5);
      final call = _last(t, 'SYNO.Foto.Browse.Concept');
      expect(call['method'], 'count');
      expect(call['show_hidden'], 'true');
    });

    test('conceptDetails：Browse.Concept/get v2，id 数字数组', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Browse.Concept.get': {
            'list': [
              {'id': 3, 'name': '海边', 'item_count': 9},
            ],
          },
        },
      );
      final api = await _foto(t);
      final concepts = await api.conceptDetails(['3', '草']);
      expect(concepts.single.id, '3');
      expect(concepts.single.name, '海边');
      final call = _last(t, 'SYNO.Foto.Browse.Concept');
      expect(call['method'], 'get');
      expect('${call['version']}', '2');
      expect(call['id'], '[3]');
    });

    test('conceptDetails：全非数字 / 空 → 不发请求', () async {
      final t = _transport();
      final api = await _foto(t);
      expect(await api.conceptDetails(const ['x']), isEmpty);
      expect(
        t.calls.where((c) => c['api'] == 'SYNO.Foto.Browse.Concept'),
        isEmpty,
      );
    });
  });

  group('C2：共享成员 / 搜索建议 / 相似时间轴（foto_c2_api.dart）', () {
    test('sharableMembers：Sharing.Misc/list_user_group v1 → 成员列表', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Sharing.Misc.list_user_group': {
            'list': [
              {'id': 'u1', 'name': 'Alice', 'type': 'user'},
              {'id': 'g1', 'nickname': 'Group', 'member_type': 'group'},
            ],
          },
        },
      );
      final c2 = await _c2(t);
      final list = await c2.sharableMembers(teamSpaceSharableList: true);
      expect(list, hasLength(2));
      expect(list.first.id, 'u1');
      expect(list.first.name, 'Alice');
      expect(list.last.type, 'group');
      final call = _last(t, 'SYNO.Foto.Sharing.Misc');
      expect(call['method'], 'list_user_group');
      expect('${call['version']}', '1');
      expect(call['team_space_sharable_list'], 'true');
    });

    test('sharableMembers：不传 teamSpaceSharableList → 不带该参数', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Sharing.Misc.list_user_group': {'list': <dynamic>[]},
        },
      );
      final c2 = await _c2(t);
      await c2.sharableMembers();
      expect(
        _last(
          t,
          'SYNO.Foto.Sharing.Misc',
        ).containsKey('team_space_sharable_list'),
        isFalse,
      );
    });

    test('searchSuggest：Search.Search/suggest v7 + 顶层 keyword', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Search.Search.suggest': {
            'list': [
              {'type': 'keyword', 'value': '海边'},
            ],
          },
        },
      );
      final c2 = await _c2(t);
      final s = await c2.searchSuggest('海');
      expect(s, hasLength(1));
      expect(s.single['value'], '海边');
      final call = _last(t, 'SYNO.Foto.Search.Search');
      expect(call['method'], 'suggest');
      expect('${call['version']}', '7');
      expect(call['keyword'], '海');
    });

    test('searchSuggest：空关键词 → 不发请求', () async {
      final t = _transport();
      final c2 = await _c2(t);
      expect(await c2.searchSuggest(''), isEmpty);
      expect(
        t.calls.where((c) => c['api'] == 'SYNO.Foto.Search.Search'),
        isEmpty,
      );
    });

    test(
      'searchCount：Search.Search/count_item v7，filter 透传 + 回 count',
      () async {
        final t = _transport(
          byApi: {
            'SYNO.Foto.Search.Search.count_item': {'count': 42},
          },
        );
        final c2 = await _c2(t);
        expect(await c2.searchCount({'keyword': '海边'}), 42);
        final call = _last(t, 'SYNO.Foto.Search.Search');
        expect(call['method'], 'count_item');
        expect(call['keyword'], '海边');
      },
    );

    test(
      'similarTimeline：Browse.SimilarTimeline/get_similar v2，filter JSON 透传',
      () async {
        final t = _transport(
          byApi: {
            'SYNO.Foto.Browse.SimilarTimeline.get_similar': {
              'list': <dynamic>[],
              'total': 0,
            },
          },
        );
        final c2 = await _c2(t);
        final data = await c2.similarTimeline({'unit_id': 5, 'limit': 10});
        expect(data['total'], 0);
        final call = _last(t, 'SYNO.Foto.Browse.SimilarTimeline');
        expect(call['method'], 'get_similar');
        expect('${call['version']}', '2');
        expect(call['unit_id'], '5', reason: 'filter 的值一律字符串化（官方同款）');
        expect(call['limit'], '10');
      },
    );

    test('similarTimeline：103（方法不存在）→ 抛出，让调用方降级', () async {
      final t = _transport(
        failures: {'SYNO.Foto.Browse.SimilarTimeline.get_similar': 103},
      );
      final c2 = await _c2(t);
      await expectLater(
        c2.similarTimeline(const {}),
        throwsA(isA<DsmApiException>()),
      );
    });
  });

  group('C2：条件相册创建 / 编辑（foto_c2_api.dart）', () {
    test(
      'createConditionAlbum：Browse.ConditionAlbum/create v4，condition JSON 串，回 album',
      () async {
        final t = _transport(
          byApi: {
            'SYNO.Foto.Browse.ConditionAlbum.create': {
              'album': {'id': 31, 'name': '去年夏天', 'item_count': 3},
            },
          },
        );
        final c2 = await _c2(t);
        final album = await c2.createConditionAlbum(
          name: '去年夏天',
          condition: {
            'time': [
              {'start_time': 1, 'end_time': 2},
            ],
          },
        );
        expect(album?.id, '31');
        expect(album?.name, '去年夏天');
        final call = _last(t, 'SYNO.Foto.Browse.ConditionAlbum');
        expect(call['method'], 'create');
        expect('${call['version']}', '4');
        expect(call['name'], '去年夏天');
        expect('${call['condition']}', contains('start_time'));
      },
    );

    test('createConditionAlbum：响应没有 album → null（不抛）', () async {
      final t = _transport();
      final c2 = await _c2(t);
      expect(
        await c2.createConditionAlbum(name: 'x', condition: const {}),
        isNull,
      );
    });

    test(
      'setConditionAlbumCondition：set_condition + id/condition 都是字符串形态',
      () async {
        final t = _transport();
        final c2 = await _c2(t);
        await c2.setConditionAlbumCondition(
          albumId: '31',
          condition: {
            'person': [7],
          },
        );
        final call = _last(t, 'SYNO.Foto.Browse.ConditionAlbum');
        expect(call['method'], 'set_condition');
        expect(call['id'], '31');
        expect('${call['condition']}', contains('person'));
      },
    );

    test('setConditionAlbumCondition：非数字 albumId → 不发请求', () async {
      final t = _transport();
      final c2 = await _c2(t);
      await c2.setConditionAlbumCondition(albumId: 'x', condition: const {});
      expect(
        t.calls.where((c) => c['api'] == 'SYNO.Foto.Browse.ConditionAlbum'),
        isEmpty,
      );
    });

    test(
      'suggestConditionItems：suggest + user_id/condition/additional',
      () async {
        final t = _transport(
          byApi: {
            'SYNO.Foto.Browse.ConditionAlbum.suggest': {
              'list': [
                {'id': 7, 'name': '小明'},
              ],
            },
          },
        );
        final c2 = await _c2(t);
        final items = await c2.suggestConditionItems(
          userId: 'u1',
          keyword: '小',
        );
        expect(items.single['name'], '小明');
        final call = _last(t, 'SYNO.Foto.Browse.ConditionAlbum');
        expect(call['method'], 'suggest');
        expect(call['user_id'], 'u1');
        expect(call['keyword'], '小');
        expect('${call['condition']}', isNotEmpty);
      },
    );

    // ★ r402 就地订正：老用例原来断言"空 keyword → **不带** keyword 参数"，
    // 那正是 DA49 的根因写法 —— 真机 `suggest` 的 `keyword` 是**必填**
    // （空参 → `120 {"name":"user_id","reason":"required"}`；
    //  给了 user_id → `120 {"name":"keyword","reason":"required"}`；
    //  空串同样判 required；`'%'` → 全部值）。
    // 所以现在**无论空不空都要发**，空搜索框发服务端 LIKE 通配 `%`。
    test('suggestConditionItems：空 keyword → 发通配 %（不是不带）', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Browse.ConditionAlbum.suggest': {'list': <dynamic>[]},
        },
      );
      final c2 = await _c2(t);
      await c2.suggestConditionItems(userId: 'u1');
      final call = _last(t, 'SYNO.Foto.Browse.ConditionAlbum');
      expect(call.containsKey('keyword'), isTrue);
      expect(call['keyword'], '%');
      expect(call['keyword'], isNot(''));
    });

    test('peekConditionItemCount：peek_item_count → count', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Browse.ConditionAlbum.peek_item_count': {'count': 88},
        },
      );
      final c2 = await _c2(t);
      expect(await c2.peekConditionItemCount({'time': <dynamic>[]}), 88);
      final call = _last(t, 'SYNO.Foto.Browse.ConditionAlbum');
      expect(call['method'], 'peek_item_count');
      expect('${call['condition']}', contains('time'));
    });

    test('conditionAlbum(id)：Browse.ConditionAlbum/get v4，id 是数组', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Browse.ConditionAlbum.get': {
            'list': [
              {
                'id': 31,
                'name': '去年夏天',
                'item_count': 88,
                'additional': {
                  'condition_object': {
                    'time': [
                      {'start_time': 1, 'end_time': 2},
                    ],
                  },
                },
              },
            ],
          },
        },
      );
      final c2 = await _c2(t);
      final album = await c2.conditionAlbum('31');
      expect(album?.id, '31');
      expect(album?.itemCount, 88);
      final call = _last(t, 'SYNO.Foto.Browse.ConditionAlbum');
      expect(call['method'], 'get');
      expect('${call['version']}', '4');
      expect(call['id'], '[31]');
    });

    test('conditionAlbum(id)：非数字 → 不发请求回 null', () async {
      final t = _transport();
      final c2 = await _c2(t);
      expect(await c2.conditionAlbum('草'), isNull);
      expect(
        t.calls.where((c) => c['api'] == 'SYNO.Foto.Browse.ConditionAlbum'),
        isEmpty,
      );
    });
  });

  group('相册/文件夹列表与收藏（foto_api.dart，页面经 provider 使用）', () {
    test('albumItems：Browse.Item/list v7 + album_id/additional', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Browse.Item.list': {
            'list': [
              {
                'id': 11,
                'filename': 'IMG_11.jpg',
                'type': 'photo',
                'folder_id': 10,
                'additional': {
                  'thumbnail': {'sm': 'sm_11'},
                },
              },
            ],
          },
        },
      );
      final api = await _foto(t);
      final items = await api.albumItems('7', limit: 50);
      expect(items.single.id, '11');
      final call = _last(t, 'SYNO.Foto.Browse.Item');
      expect(call['method'], 'list');
      expect('${call['version']}', '7');
      expect(call['album_id'], '7');
      expect(call['limit'], '50');
      expect('${call['additional']}', contains('favorite'));
    });

    test('folderItems：Browse.Item/list v7 + folder_id', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Browse.Item.list': {
            'list': [
              {
                'id': 21,
                'filename': 'IMG_21.jpg',
                'type': 'photo',
                'folder_id': 3,
              },
            ],
          },
        },
      );
      final api = await _foto(t);
      expect((await api.folderItems('3')).single.id, '21');
      final call = _last(t, 'SYNO.Foto.Browse.Item');
      expect(call['folder_id'], '3');
      expect(call.containsKey('album_id'), isFalse);
    });

    test(
      'normalAlbums：Browse.NormalAlbum/list v3 + additional=thumbnail',
      () async {
        final t = _transport(
          byApi: {
            'SYNO.Foto.Browse.NormalAlbum.list': {
              'list': [
                {'id': 7, 'name': '旅行', 'item_count': 4},
              ],
            },
          },
        );
        final api = await _foto(t);
        final albums = await api.normalAlbums();
        expect(albums.single.id, '7');
        expect(albums.single.name, '旅行');
        final call = _last(t, 'SYNO.Foto.Browse.NormalAlbum');
        expect(call['method'], 'list');
        expect('${call['version']}', '3');
        expect('${call['additional']}', contains('thumbnail'));
      },
    );

    test('setFavorite：set_favorite v7，id 是**数字**数组（非数字被剔除）', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Browse.Item.set_favorite': {'success': true},
        },
      );
      final api = await _foto(t);
      await api.setFavorite(['11', '12', 'unit_x'], true);
      final call = _last(t, 'SYNO.Foto.Browse.Item');
      expect(call['method'], 'set_favorite');
      expect('${call['version']}', '7');
      expect(call['id'], '[11,12]', reason: '官方 id 是 List<Long>，字符串/null 都不合法');
      expect(call['favorite'], 'true');
    });

    test('setFavorite：取消收藏 → favorite=false', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Browse.Item.set_favorite': {'success': true},
        },
      );
      final api = await _foto(t);
      await api.setFavorite(['11'], false);
      expect(_last(t, 'SYNO.Foto.Browse.Item')['favorite'], 'false');
    });
  });

  group('条件相册列表（foto_c2_api.dart，能力探测 + 列表页）', () {
    test(
      'conditionAlbums：Browse.ConditionAlbum/list v4 + additional 带 condition_object',
      () async {
        final t = _transport(
          byApi: {
            'SYNO.Foto.Browse.ConditionAlbum.list': {
              'list': [
                {'id': 31, 'name': '去年夏天', 'item_count': 88},
              ],
            },
          },
        );
        final c2 = await _c2(t);
        final albums = await c2.conditionAlbums(limit: 10);
        expect(albums.single.id, '31');
        final call = _last(t, 'SYNO.Foto.Browse.ConditionAlbum');
        expect(call['method'], 'list');
        expect('${call['version']}', '4');
        expect('${call['additional']}', contains('condition_object'));
        expect(call['limit'], '10');
      },
    );
  });

  group('相册内移出（foto_api.dart，批量入口已接线）', () {
    test(
      'removeItemsFromAlbum：NormalAlbum/delete_item v4 + id/item 数字数组',
      () async {
        final t = _transport(
          byApi: {
            'SYNO.Foto.Browse.NormalAlbum.delete_item': {
              'error_list': <dynamic>[],
            },
          },
        );
        final api = await _foto(t);
        await api.removeItemsFromAlbum(albumId: '7', itemIds: ['11', '12']);
        final call = _last(t, 'SYNO.Foto.Browse.NormalAlbum');
        expect(call['method'], 'delete_item');
        expect('${call['version']}', '4');
        expect(call['id'], '7');
        expect(call['item'], '[11,12]');
      },
    );

    test('removeItemsFromAlbum：空列表 / 非数字 → 不发请求', () async {
      final t = _transport();
      final api = await _foto(t);
      await api.removeItemsFromAlbum(albumId: '7', itemIds: const []);
      await api.removeItemsFromAlbum(albumId: '7', itemIds: const ['草']);
      expect(
        t.calls.where((c) => c['api'] == 'SYNO.Foto.Browse.NormalAlbum'),
        isEmpty,
      );
    });

    test('removeItemsFromAlbum：整批失败 → 抛出（调用方如实报错，不静默）', () async {
      final t = _transport(
        failures: {'SYNO.Foto.Browse.NormalAlbum.delete_item': 500},
      );
      final api = await _foto(t);
      await expectLater(
        api.removeItemsFromAlbum(albumId: '7', itemIds: ['11']),
        throwsA(isA<DsmApiException>()),
      );
    });
  });
}
