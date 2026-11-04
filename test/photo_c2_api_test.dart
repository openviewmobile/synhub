// C2（Photos 补齐）**协议层**测试：逐条钉死"API 名 + method + version + 参数形态"。
//
// 每一条的期望值都来自 `foto_c2_api.dart` 里引用的**原文证据**
// （官方 `SYNO.Foto.lib` / `ui/react_bundle.js` 模块 5137 的版本表 / 调用点）。
// 这里只测"发出去的东西"，不测服务端真实响应 —— 后者要真机，见实施记录的
// 「未核实边界」。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/foto_c2_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/foto_c2_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 官方版本表（`ui/react_bundle.js` 模块 5137）里这六个 API 的 maxVersion，
/// 逐字抄进能力表，确保 [FotoApi.negotiate] 选出的版本与官方客户端一致。
const _c2Table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Foto.Setting.User': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.Foto.Browse.Album': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 5,
  },
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 9,
  },
  'SYNO.Foto.Sharing.Misc': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Sharing.Passphrase': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Foto.PhotoRequest': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Foto.Browse.Geocoding': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
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
  'SYNO.Foto.Browse.ConditionAlbum': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.Foto.Browse.Similar': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Foto.Browse.SimilarItem': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Browse.SimilarTimeline': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

Map<String, dynamic> _item(String id) => {
  'id': id,
  'filename': 'IMG_$id.jpg',
  'filesize': 1024,
  'time': DateTime(2026, 9, 18, 10).millisecondsSinceEpoch ~/ 1000,
  'folder_id': '10',
  'type': 'photo',
  'additional': {
    'thumbnail': {'sm': 'sm_$id', 'm': 'm_$id', 'cache_key': 'ck_$id'},
  },
};

FakeTransport _transport({
  Map<String, Map<String, dynamic>> responses = const {},
}) {
  return FakeTransport(
    {
      'SYNO.Foto.Setting.User.get': {'enable_similar': true},
      ...responses,
    },
    {...FakeTransport.table, ..._c2Table},
  );
}

Future<FotoC2Api> _api(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return FotoC2Api(FotoApi(api));
}

Map<String, dynamic> _last(FakeTransport t, String apiName) =>
    t.calls.lastWhere((c) => c['api'] == apiName);

void main() {
  group('P17 相似堆叠分组（官方 SimilarVo 字段）', () {
    test('扁平行按分组 id 聚合；行的 item_id 才是图 id；top_pick 当封面', () {
      final groups = parseSimilarGroups({
        'list': [
          {
            'id': 77,
            'count': 3,
            'item_id': 101,
            'top_pick': 102,
            'filename': 'IMG_101.jpg',
            'additional': {
              'thumbnail': {'sm': 'sm_101', 'cache_key': 'ck_101'},
            },
          },
          {
            'id': 77,
            'count': 3,
            'item_id': 102,
            'top_pick': 102,
            'filename': 'IMG_102.jpg',
            'additional': {
              'thumbnail': {'sm': 'sm_102', 'cache_key': 'ck_102'},
            },
          },
          {
            'id': 88,
            'count': 2,
            'item_id': 201,
            'top_pick': 201,
            'filename': 'IMG_201.jpg',
          },
        ],
      });
      expect(groups, hasLength(2), reason: '同一个 id 的行 = 同一组');
      final g = groups.first;
      expect(g.id, '77');
      expect(g.count, 3);
      expect(g.itemIds, ['101', '102']);
      expect(g.items.first.id, '101', reason: '图的 id 取 item_id，不是分组 id');
      expect(g.items.first.thumb.cacheKey, 'ck_101');
      expect(g.cover!.id, '102', reason: '封面 = top_pick 那张');
      expect(groups[1].id, '88');
      expect(groups[1].itemIds, ['201']);
    });

    test('没有分组 id 的行整组丢弃（不编造操作目标）', () {
      final groups = parseSimilarGroups({
        'list': [
          {'item_id': 10, 'filename': 'b.jpg'},
          {'id': '', 'item_id': 11},
        ],
      });
      expect(groups, isEmpty);
    });

    test('count 缺失 ⇒ 回落成成员数；非 list 响应 ⇒ 空（不抛）', () {
      final groups = parseSimilarGroups({
        'list': [
          {'id': 5, 'item_id': 9, 'filename': 'a.jpg'},
        ],
      });
      expect(groups.single.count, 1);
      expect(groups.single.cover!.id, '9');
      expect(parseSimilarGroups(const {}), isEmpty);
      expect(parseSimilarGroups(const {'list': 'nope'}), isEmpty);
    });
  });

  group('相册分享（sharing_info / passphrase）', () {
    test('sharedWithMeAlbums → Sharing.Misc/list_shared_with_me_album（v2 优先）', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Sharing.Misc.list_shared_with_me_album': {
            'list': [
              {'id': 21, 'name': '别人的相册', 'shared': true},
            ],
          },
        },
      );
      final c2 = await _api(t);
      final albums = await c2.sharedWithMeAlbums();
      expect(albums.single.name, '别人的相册');
      final call = _last(t, 'SYNO.Foto.Sharing.Misc');
      expect(call['method'], 'list_shared_with_me_album');
      // 默认排序是官方 saga 的 share_modify_time / desc
      expect(call['sort_by'], 'share_modify_time');
      expect(call['sort_direction'], 'desc');
      expect(call['additional'], '["sharing_info","thumbnail","access_permission"]');
    });

    test('sharedByMeAlbums → Browse.Album/list，category=shared（v4 协商）', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.Album.list': {
            'list': [
              {'id': 31, 'name': '我共享的', 'shared': true},
            ],
          },
        },
      );
      final c2 = await _api(t);
      final albums = await c2.sharedByMeAlbums();
      expect(albums.single.id, '31');
      final call = _last(t, 'SYNO.Foto.Browse.Album');
      expect(call['method'], 'list');
      expect(call['category'], 'shared');
      expect(call['version'], '4', reason: '官方版本表 Browse.Album.list = 4');
      expect(call['additional'], '["sharing_info","thumbnail"]');
    });

    test(
      'albumSharingInfo → Browse.Album/get，id 是**数组**且 additional 取 sharing_info',
      () async {
        final t = _transport(
          responses: {
            'SYNO.Foto.Browse.Album.get': {
              'list': [
                {
                  'id': 11,
                  'name': '旅行',
                  'shared': true,
                  'additional': {
                    'sharing_info': {
                      'privacy_type': 'public-view',
                      'sharing_link': 'https://nas/photo/#/shared/abc',
                      'passphrase': 'abc',
                      'enable_password': false,
                      'expiration': 0,
                      'permission': [
                        {
                          'role': 'view',
                          'member': {'type': 'public'},
                        },
                        {
                          'role': 'download',
                          'member': {'type': 'user', 'id': 8, 'name': '阿明'},
                        },
                      ],
                      'owner': {'name': '老王'},
                    },
                  },
                },
              ],
            },
          },
        );
        final c2 = await _api(t);
        final info = await c2.albumSharingInfo('11');
        expect(info, isNotNull);
        expect(info!.privacyType, 'public-view');
        expect(info.sharingLink, isNotEmpty);
        expect(info.passphrase, 'abc');
        expect(info.enabled, isTrue);
        expect(info.ownerName, '老王');
        // public 成员单独拿出来；成员列表不含它
        expect(info.publicMember!.role, 'view');
        expect(info.userMembers.single.name, '阿明');
        expect(info.userMembers.single.type, 'user');
        final call = _last(t, 'SYNO.Foto.Browse.Album');
        expect(call['method'], 'get');
        // 官方版本表（模块 5137）`Browse.Album.get = 4`（能力表 maxVersion=5，
        // 所以协商结果必须是 4，不是 5）
        expect(call['version'], '4');
        // 官方 `NS`：{id:[e], additional:["sharing_info"]} —— id 必须是数组原文
        expect(call['id'], '[11]');
        expect(call['additional'], '["sharing_info"]');
      },
    );

    test('albumSharingInfo：album_id 非数字 → 不发请求、返回 null', () async {
      final t = _transport();
      final c2 = await _api(t);
      final before = t.calls.length;
      expect(await c2.albumSharingInfo('not-a-number'), isNull);
      expect(t.calls.length, before);
    });

    test('setAlbumShareLink → Passphrase/set_shared v1，policy=album', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Sharing.Passphrase.set_shared': {
            'sharing_link': 'https://nas/photo/#/shared/xyz',
            'passphrase': 'xyz',
          },
        },
      );
      final c2 = await _api(t);
      final r = await c2.setAlbumShareLink(albumId: '11', enabled: false);
      expect(r.sharingLink, contains('xyz'));
      expect(r.passphrase, 'xyz');
      final call = _last(t, 'SYNO.Foto.Sharing.Passphrase');
      expect(call['method'], 'set_shared');
      expect(call['version'], '1');
      expect(call['policy'], 'album');
      expect(call['album_id'], '11');
      expect(call['enabled'], 'false');
    });

    test('updateAlbumSharing：隐私级别 → public 成员的 action/role 原文形态', () async {
      final t = _transport(
        responses: {'SYNO.Foto.Sharing.Passphrase.update': <String, dynamic>{}},
      );
      final c2 = await _api(t);
      await c2.updateAlbumSharing(
        passphrase: 'xyz',
        privacyType: 'public-download',
      );
      final call = _last(t, 'SYNO.Foto.Sharing.Passphrase');
      expect(call['method'], 'update');
      expect(call['version'], '1');
      expect(call['passphrase'], 'xyz');
      final permission = call['permission'] as String;
      expect(
        permission,
        '[{"action":"update","role":"download","member":{"type":"public"}}]',
      );
      // ⚠️ 口令分享需要 `encryption:["password"]`，DsmWebApi 不支持 → 必须**不**
      // 出现 password 字段（宁缺毋滥，不能发明一个服务端会拒绝的参数）
      expect(call.containsKey('password'), isFalse);
    });

    test('updateAlbumSharing：private → delete public 成员', () async {
      final t = _transport(
        responses: {'SYNO.Foto.Sharing.Passphrase.update': <String, dynamic>{}},
      );
      final c2 = await _api(t);
      await c2.updateAlbumSharing(passphrase: 'xyz', privacyType: 'private');
      final permission =
          _last(t, 'SYNO.Foto.Sharing.Passphrase')['permission'] as String;
      expect(permission, '[{"action":"delete","member":{"type":"public"}}]');
    });

    test('updateAlbumSharing：加成员 / 踢成员分别是 update / delete', () async {
      final t = _transport(
        responses: {'SYNO.Foto.Sharing.Passphrase.update': <String, dynamic>{}},
      );
      final c2 = await _api(t);
      await c2.updateAlbumSharing(
        passphrase: 'xyz',
        members: const [
          FotoShareMemberDto(type: 'user', id: '8', role: 'download'),
        ],
        removedMembers: const [FotoShareMemberDto(type: 'group', id: '2')],
      );
      final permission =
          _last(t, 'SYNO.Foto.Sharing.Passphrase')['permission'] as String;
      expect(
        permission,
        '[{"action":"update","role":"download","member":{"type":"user","id":"8"}},'
        '{"action":"delete","member":{"type":"group","id":"2"}}]',
      );
    });

    test('updateAlbumSharing：什么都不改 → 不发 permission 字段', () async {
      final t = _transport(
        responses: {'SYNO.Foto.Sharing.Passphrase.update': <String, dynamic>{}},
      );
      final c2 = await _api(t);
      await c2.updateAlbumSharing(passphrase: 'xyz');
      final call = _last(t, 'SYNO.Foto.Sharing.Passphrase');
      expect(call.containsKey('permission'), isFalse);
    });
  });

  group('照片请求', () {
    test('photoRequests → PhotoRequest/list v1（limit 5000）', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.PhotoRequest.list': {
            'list': [
              {'passphrase': 'p1', 'name': '婚礼收图', 'item_count': 12},
            ],
          },
        },
      );
      final c2 = await _api(t);
      final list = await c2.photoRequests();
      expect(list.single.passphrase, 'p1');
      expect(list.single.itemCount, 12);
      final call = _last(t, 'SYNO.Foto.PhotoRequest');
      expect(call['method'], 'list');
      expect(call['version'], '1');
      expect(call['limit'], '5000');
      expect(call['offset'], '0');
      expect(call.containsKey('keyword'), isFalse);
    });

    test('photoRequests(keyword) → 带上 keyword', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.PhotoRequest.list': {'list': <Map<String, dynamic>>[]},
        },
      );
      final c2 = await _api(t);
      await c2.photoRequests(keyword: '婚礼');
      expect(_last(t, 'SYNO.Foto.PhotoRequest')['keyword'], '婚礼');
    });

    test('deletePhotoRequest → passphrase 是**数组**（官方 Fu 原文）', () async {
      final t = _transport(
        responses: {'SYNO.Foto.PhotoRequest.delete': <String, dynamic>{}},
      );
      final c2 = await _api(t);
      await c2.deletePhotoRequest('p1');
      final call = _last(t, 'SYNO.Foto.PhotoRequest');
      expect(call['method'], 'delete');
      expect(call['version'], '1');
      expect(call['passphrase'], '["p1"]');
    });

    test('createPhotoRequest → PhotoRequest/create v1，字段/取值逐字对齐官方 smali', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.PhotoRequest.create': <String, dynamic>{},
        },
      );
      final c2 = await _api(t);
      await c2.createPhotoRequest(
        subject: '婚礼收图',
        description: '请把当天的照片传上来',
        teamLibrary: true,
        folderHomePath: '/photo/2026',
        albumId: '31',
        albumPassphrase: 'pw',
        fileSizeLimitBytes: 20971520,
        expiration: 1790000000,
      );
      final call = _last(t, 'SYNO.Foto.PhotoRequest');
      expect(call['method'], 'create');
      expect(call['version'], '1');
      expect(call['subject'], '婚礼收图');
      expect(call['description'], '请把当天的照片传上来');
      expect(call['library'], 'shared_space', reason: '官方 isTeamLibToString');
      expect(call['folder_home_path'], '/photo/2026');
      expect(call['album_id'], '31');
      expect(call['album_passphrase'], 'pw');
      expect(call['filesize_limit'], '20971520', reason: 'UI 用 MB、线上传**字节**');
      expect(call['expiration'], '1790000000');
    });

    test('createPhotoRequest → 个人空间 library=personal_space；可选字段空则不发', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.PhotoRequest.create': <String, dynamic>{},
        },
      );
      final c2 = await _api(t);
      await c2.createPhotoRequest(subject: '收图', teamLibrary: false);
      final call = _last(t, 'SYNO.Foto.PhotoRequest');
      expect(call['library'], 'personal_space');
      for (final k in [
        'album_id',
        'album_passphrase',
        'filesize_limit',
        'expiration',
        'folder_home_path',
      ]) {
        expect(call.containsKey(k), isFalse, reason: '$k 没值就不该发');
      }
      expect(call['description'], '');
    });

    test('updatePhotoRequest → PhotoRequest/update v1，首字段是 passphrase', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.PhotoRequest.update': <String, dynamic>{},
        },
      );
      final c2 = await _api(t);
      await c2.updatePhotoRequest(
        passphrase: 'abc',
        subject: '改名后',
        teamLibrary: true,
        fileSizeLimitBytes: 1048576,
      );
      final call = _last(t, 'SYNO.Foto.PhotoRequest');
      expect(call['method'], 'update');
      expect(call['version'], '1');
      expect(call['passphrase'], 'abc');
      expect(call['subject'], '改名后');
      expect(call['library'], 'shared_space');
      expect(call['filesize_limit'], '1048576');
    });

    test('updatePhotoRequest：空 passphrase → **零请求**', () async {
      final t = _transport();
      final c2 = await _api(t);
      await c2.updatePhotoRequest(passphrase: '', subject: 'x', teamLibrary: false);
      expect(
        t.calls.where((c) => c['api'] == 'SYNO.Foto.PhotoRequest'),
        isEmpty,
      );
    });

    test('deletePhotoRequest：空 passphrase → 不发请求', () async {
      final t = _transport();
      final c2 = await _api(t);
      final before = t.calls.length;
      await c2.deletePhotoRequest('');
      expect(t.calls.length, before);
    });
  });

  group('地点', () {
    test('geocodingPlaces → Browse.Geocoding/list v1', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.Geocoding.list': {
            'list': [
              {
                'id': 101,
                'name': '东京',
                'country': '日本',
                'country_id': 'JP',
                'first_level': '关东',
                'item_count': 20,
                'additional': {
                  'thumbnail': {'sm': 's', 'm': 'm', 'cache_key': 'c'},
                },
              },
            ],
          },
        },
      );
      final c2 = await _api(t);
      final places = await c2.geocodingPlaces();
      expect(places.single.id, '101');
      expect(places.single.displayName, '东京');
      expect(places.single.countryId, 'JP');
      final call = _last(t, 'SYNO.Foto.Browse.Geocoding');
      expect(call['method'], 'list');
      expect(call['version'], '1');
      expect(call['additional'], '["thumbnail"]');
    });

    test('geocodingPlaces：名字缺失时按 country → first_level 回落', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.Geocoding.list': {
            'list': [
              {'id': 1, 'country': '日本'},
              {'id': 2, 'first_level': '关东'},
            ],
          },
        },
      );
      final c2 = await _api(t);
      final places = await c2.geocodingPlaces();
      expect(places[0].displayName, '日本');
      expect(places[1].displayName, '关东');
    });

    test('geocodingCount → Browse.Geocoding/count v1 → count', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.Geocoding.count': {'count': 42},
        },
      );
      final c2 = await _api(t);
      expect(await c2.geocodingCount(), 42);
      final call = _last(t, 'SYNO.Foto.Browse.Geocoding');
      expect(call['method'], 'count');
      expect(call['version'], '1');
    });
  });

  group('搜索', () {
    test('searchItems → Search.Search/list_item v7，filter 展开成查询参数', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Search.Search.list_item': {
            'list': [_item('1'), _item('2')],
          },
        },
      );
      final c2 = await _api(t);
      final items = await c2.searchItems({
        'keyword': '海边',
        'start_time': 100,
        'favorite': true,
      });
      expect(items.map((e) => e.id), ['1', '2']);
      final call = _last(t, 'SYNO.Foto.Search.Search');
      expect(call['method'], 'list_item');
      expect(call['version'], '7');
      expect(call['keyword'], '海边');
      expect(call['start_time'], '100');
      expect(call['favorite'], 'true');
      // 官方原文：additional:["thumbnail","resolution","orientation",
      //            "video_convert","video_meta","address","favorite"]
      expect(call['additional'], contains('video_meta'));
    });

    test('searchFilters → Search.Filter/list v4 且透传 params', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Search.Filter.list': {'person': <Map<String, dynamic>>[]},
        },
      );
      final c2 = await _api(t);
      await c2.searchFilters({
        'item_type': ['photo'],
        'limit': 10,
      });
      final call = _last(t, 'SYNO.Foto.Search.Filter');
      expect(call['method'], 'list');
      expect(call['version'], '4');
      expect(call['item_type'], '["photo"]');
      expect(call['limit'], '10');
    });

    test('filter 里的 list/map 一律编码成 JSON 串（服务端 Gson 约定）', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Search.Search.list_item': {
            'list': <Map<String, dynamic>>[],
          },
        },
      );
      final c2 = await _api(t);
      await c2.searchItems({
        'person': [
          {'id': 3},
        ],
        'folder_filter': {'folder_id': 9},
        'rating': 4,
      });
      final call = _last(t, 'SYNO.Foto.Search.Search');
      expect(call['person'], '[{"id":3}]');
      expect(call['folder_filter'], '{"folder_id":9}');
      expect(call['rating'], '4');
    });
  });

  group('条件相册', () {
    // 方法集/版本/载荷的出处见 `foto_c2_api.dart` 里各方法上方引用的官方原文，
    // 以及本轮固化的 `docs/photo-condition-album-evidence.md`（三处独立来源）。
    test('conditionAlbums → ConditionAlbum/list v4，offset/limit + additional', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.ConditionAlbum.list': {
            'list': [
              {
                'id': 31,
                'name': '海边的照片',
                'item_count': 12,
                'additional': {
                  'condition_object': {'geocoding': [1], 'logic': 'and'},
                },
              },
            ],
          },
        },
      );
      final c2 = await _api(t);
      final albums = await c2.conditionAlbums(offset: 0, limit: 100);
      expect(albums.single.id, '31');
      expect(albums.single.name, '海边的照片');
      final call = _last(t, 'SYNO.Foto.Browse.ConditionAlbum');
      expect(call['method'], 'list');
      expect(call['version'], '4');
      expect(call['offset'], '0');
      expect(call['limit'], '100');
      // 官方原文：additional:["thumbnail","condition_object"]
      expect(call['additional'], contains('condition_object'));
    });

    test('conditionAlbum → get v4，且 id 是**数组**、additional=condition_object', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.ConditionAlbum.get': {
            'list': [
              {
                'id': 31,
                'name': '海边的照片',
                'additional': {
                  'condition_object': {'person': [3], 'logic': 'or'},
                },
              },
            ],
          },
        },
      );
      final c2 = await _api(t);
      final album = await c2.conditionAlbum('31');
      expect(album, isNotNull);
      expect(album!.id, '31');
      final call = _last(t, 'SYNO.Foto.Browse.ConditionAlbum');
      expect(call['method'], 'get');
      expect(call['version'], '4');
      expect(call['id'], '[31]', reason: '官方原文：r.id=[t]');
      expect(call['additional'], contains('condition_object'));
    });

    test('conditionAlbum(非数字 id) → 零请求返回 null', () async {
      final t = _transport();
      final c2 = await _api(t);
      expect(await c2.conditionAlbum('abc'), isNull);
      expect(
        t.calls.where((c) => c['api'] == 'SYNO.Foto.Browse.ConditionAlbum'),
        isEmpty,
      );
    });

    test('createConditionAlbum → create v4，{name, condition} → 回包 album', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.ConditionAlbum.create': {
            'album': {'id': 41, 'name': '我的条件相册'},
          },
        },
      );
      final c2 = await _api(t);
      final album = await c2.createConditionAlbum(
        name: '我的条件相册',
        condition: {'logic': 'and', 'person': [1, 2]},
      );
      expect(album, isNotNull);
      expect(album!.id, '41');
      final call = _last(t, 'SYNO.Foto.Browse.ConditionAlbum');
      expect(call['method'], 'create');
      expect(call['version'], '4');
      expect(call['name'], '我的条件相册');
      // `condition` 走 JSON 串（服务端 Gson 约定，与本文件其它 map/list 参数一致）
      expect(call['condition'], contains('"logic"'));
      expect(call['condition'], contains('"person"'));
    });

    test('setConditionAlbumCondition → set_condition v4，{id, condition}', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.ConditionAlbum.set_condition': <String, dynamic>{},
        },
      );
      final c2 = await _api(t);
      await c2.setConditionAlbumCondition(
        albumId: '41',
        condition: {'logic': 'or', 'camera': ['X']},
      );
      final call = _last(t, 'SYNO.Foto.Browse.ConditionAlbum');
      expect(call['method'], 'set_condition');
      expect(call['version'], '4');
      expect(call['id'], '41', reason: 'set_condition 的 id 是**标量**（与 get 的数组不同）');
      expect(call['condition'], contains('"camera"'));
    });

    test('peekConditionItemCount → peek_item_count v4，只有 condition → count', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.ConditionAlbum.peek_item_count': {'count': 7},
        },
      );
      final c2 = await _api(t);
      expect(
        await c2.peekConditionItemCount({'logic': 'and', 'iso': [100, 200]}),
        7,
      );
      final call = _last(t, 'SYNO.Foto.Browse.ConditionAlbum');
      expect(call['method'], 'peek_item_count');
      expect(call['version'], '4');
      expect(call.keys.where((k) => k == 'condition').length, 1);
    });

    test('suggestConditionItems → suggest v4，{user_id, keyword, condition, additional}', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.ConditionAlbum.suggest': {
            'list': [
              {'name': 'Nikon', 'id': 1},
            ],
          },
        },
      );
      final c2 = await _api(t);
      final items = await c2.suggestConditionItems(
        userId: '3',
        keyword: 'nik',
        conditionTypes: const ['camera'],
      );
      expect(items.single['name'], 'Nikon');
      final call = _last(t, 'SYNO.Foto.Browse.ConditionAlbum');
      expect(call['method'], 'suggest');
      expect(call['version'], '4');
      expect(call['user_id'], '3');
      expect(call['keyword'], 'nik');
      expect(call['condition'], contains('camera'));
      expect(call['additional'], contains('thumbnail'));
    });

    // ★ **DA50**（r402）：真机回包是**类型 → 选项数组**的顶层 Map（以前按 {list:[…]} 解析 ⇒
    // 真机永远空、面板显示"没有可选值"）。这条用真形状当夹具。
    test('★ r402（DA50）：suggestConditionItems 认真机形状 {类型: [选项]}', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.ConditionAlbum.suggest': {
            'camera': [
              {'id': 23, 'name': 'LGE-AN10'},
            ],
            'general_tag': <dynamic>[],
          },
        },
      );
      final c2 = await _api(t);
      final items = await c2.suggestConditionItems(
        userId: '4',
        keyword: '%',
        conditionTypes: const ['camera', 'general_tag'],
      );
      expect(items, hasLength(1));
      expect(items.single['name'], 'LGE-AN10');
      expect(items.single['id'], 23);
      // 选项里带上来源类型，便于调用方区分（不参与渲染）
      expect(items.single['type'], 'camera');
      // 反向：不再把空组当成一条选项
      expect(items.any((e) => e['type'] == 'general_tag'), isFalse);
    });

    test('共享空间 → 同一套方法走 SYNO.FotoTeam.Browse.ConditionAlbum', () async {
      final t = FakeTransport(
        {
          'SYNO.Foto.Setting.User.get': {'enable_similar': true},
          'SYNO.FotoTeam.Browse.ConditionAlbum.list': {'list': []},
        },
        {
          ...FakeTransport.table,
          ..._c2Table,
          'SYNO.FotoTeam.Browse.ConditionAlbum': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 4,
          },
        },
      );
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final c2 = FotoC2Api(FotoApi(api, space: FotoSpace.team));
      await c2.conditionAlbums();
      expect(
        t.calls.any(
          (c) => c['api'] == 'SYNO.FotoTeam.Browse.ConditionAlbum',
        ),
        isTrue,
      );
    });
  });

  group('相似照片', () {
    test('similarStatus → Browse.Similar/get_status v1', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.Similar.get_status': {
            'is_similar_hash_migration_done': true,
            'stage': '',
            'waiting_count': 0,
          },
        },
      );
      final c2 = await _api(t);
      final status = await c2.similarStatus();
      expect(status.ready, isTrue);
      final call = _last(t, 'SYNO.Foto.Browse.Similar');
      expect(call['method'], 'get_status');
      expect(call['version'], '1');
    });

    test('similarStatus：还在索引 → not ready / running', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.Similar.get_status': {
            'is_similar_hash_migration_done': false,
            'stage': 'running',
            'waiting_count': 120,
          },
        },
      );
      final c2 = await _api(t);
      final status = await c2.similarStatus();
      expect(status.ready, isFalse);
      expect(status.running, isTrue);
      expect(status.waitingCount, 120);
    });

    test('similarAddItem → Browse.Similar/add_item v1，字段 id/item_id/top_pick', () async {
      final t = _transport(
        responses: {'SYNO.Foto.Browse.Similar.add_item': <String, dynamic>{}},
      );
      final c2 = await _api(t);
      await c2.similarAddItem(groupId: '31', itemId: '77', topPick: 1);
      final call = _last(t, 'SYNO.Foto.Browse.Similar');
      expect(call['method'], 'add_item');
      expect(call['version'], '1');
      expect(call['id'], '31');
      expect(call['item_id'], '77');
      expect(call['top_pick'], '1');
    });

    test('similarRemoveItem / similarSetTopPick → 字段名一致（官方 smali 逐字）', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.Similar.remove_item': <String, dynamic>{},
          'SYNO.Foto.Browse.Similar.set_top_pick': <String, dynamic>{},
        },
      );
      final c2 = await _api(t);
      await c2.similarRemoveItem(groupId: '31', itemId: '77');
      await c2.similarSetTopPick(groupId: '31', itemId: '77');
      final calls = t.calls
          .where((c) => c['api'] == 'SYNO.Foto.Browse.Similar')
          .toList();
      expect(calls.map((c) => c['method']), ['remove_item', 'set_top_pick']);
      for (final c in calls) {
        expect(c['version'], '1');
        expect(c['id'], '31');
        expect(c['item_id'], '77');
      }
      // remove_item **不带** top_pick（官方签名里没有）
      expect(calls.first.containsKey('top_pick'), isFalse);
    });

    test('similarUngroup → 只有 id（官方此方法 id 是 String）', () async {
      final t = _transport(
        responses: {'SYNO.Foto.Browse.Similar.ungroup': <String, dynamic>{}},
      );
      final c2 = await _api(t);
      await c2.similarUngroup(groupId: 'grp-9');
      final call = _last(t, 'SYNO.Foto.Browse.Similar');
      expect(call['method'], 'ungroup');
      expect(call['version'], '1');
      expect(call['id'], 'grp-9');
      expect(call.containsKey('item_id'), isFalse);
    });

    test('相似写操作：空 id / 空 item → **一个请求都不发**', () async {
      final t = _transport();
      final c2 = await _api(t);
      await c2.similarAddItem(groupId: '', itemId: '77');
      await c2.similarAddItem(groupId: '31', itemId: '');
      await c2.similarRemoveItem(groupId: '31', itemId: '');
      await c2.similarSetTopPick(groupId: '', itemId: '77');
      await c2.similarUngroup(groupId: '');
      expect(
        t.calls.where((c) => c['api'] == 'SYNO.Foto.Browse.Similar'),
        isEmpty,
      );
    });

    test('similarGroupItems → SimilarItem/list v2，filter 透传', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.SimilarItem.list': {
            'list': [_item('9')],
          },
        },
      );
      final c2 = await _api(t);
      final items = await c2.similarGroupItems(
        filter: const {'favorite': true},
      );
      expect(items.single.id, '9');
      final call = _last(t, 'SYNO.Foto.Browse.SimilarItem');
      expect(call['method'], 'list');
      expect(call['version'], '2');
      expect(call['favorite'], 'true');
    });
  });

  group('空间前缀', () {
    test('共享空间 → SYNO.FotoTeam.*（同一套方法与版本）', () async {
      final t = FakeTransport(
        {
          'SYNO.FotoTeam.Sharing.Misc.list_shared_with_me_album': {
            'list': [
              {'id': 3, 'name': '团队'},
            ],
          },
        },
        {
          ...FakeTransport.table,
          ..._c2Table,
          ...{
            'SYNO.FotoTeam.Sharing.Misc': {
              'path': 'entry.cgi',
              'minVersion': 1,
              'maxVersion': 2,
            },
          },
        },
      );
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final c2 = FotoC2Api(FotoApi(api).inSpace(FotoSpace.team));
      final albums = await c2.sharedWithMeAlbums();
      expect(albums.single.name, '团队');
      final call = _last(t, 'SYNO.FotoTeam.Sharing.Misc');
      expect(call['version'], '2');
    });
  });

  group('版本协商（老服务器）', () {
    test('能力表只到 v4 → Search.Search 发 v4 而不是 v7', () async {
      final t = FakeTransport(
        {
          'SYNO.Foto.Search.Search.list_item': {
            'list': <Map<String, dynamic>>[],
          },
        },
        {
          ...FakeTransport.table,
          ..._c2Table,
          'SYNO.Foto.Search.Search': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 4,
          },
        },
      );
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final c2 = FotoC2Api(FotoApi(api));
      await c2.searchItems(const {'keyword': 'x'});
      expect(_last(t, 'SYNO.Foto.Search.Search')['version'], '4');
    });

    test('能力表只到 v1 → Sharing.Misc 发 v1', () async {
      final t = FakeTransport(
        {
          'SYNO.Foto.Sharing.Misc.list_shared_with_me_album': {
            'list': <Map<String, dynamic>>[],
          },
        },
        {
          ...FakeTransport.table,
          ..._c2Table,
          'SYNO.Foto.Sharing.Misc': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
        },
      );
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final c2 = FotoC2Api(FotoApi(api));
      await c2.sharedWithMeAlbums();
      expect(_last(t, 'SYNO.Foto.Sharing.Misc')['version'], '1');
    });
  });

  group('错误码不被吞掉', () {
    test('105 原样抛给上层（由页面决定"无权限 → 隐藏入口"）', () async {
      final t = _transport();
      t.failures['SYNO.Foto.Sharing.Misc.list_shared_with_me_album'] = 105;
      final c2 = await _api(t);
      await expectLater(
        c2.sharedWithMeAlbums(),
        throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 105)),
      );
    });

    test('119（sid 失效）原样抛出，绝不当普通失败', () async {
      final t = _transport();
      t.failures['SYNO.Foto.Search.Search.list_item'] = 119;
      final c2 = await _api(t);
      await expectLater(
        c2.searchItems(const {'keyword': 'x'}),
        throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 119)),
      );
    });

    test('102（API 不存在）原样抛出', () async {
      final t = _transport();
      t.failures['SYNO.Foto.Browse.Similar.get_status'] = 102;
      final c2 = await _api(t);
      await expectLater(
        c2.similarStatus(),
        throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 102)),
      );
    });
  });
}
