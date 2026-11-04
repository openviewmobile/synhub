// 相册写操作（P2 续）：离线测试。
//
// 形态全部来自真机取证（`tool/photo_album_write4_probe.dart`）：
//   * `Browse.NormalAlbum/create`   v4 `{name, item:"[int,…]"}`
//   * `Browse.NormalAlbum/add_item` v4 `{id:裸, item:"[int,…]"}`
//   * `Browse.NormalAlbum/delete_item` v4 `{id:裸, item:"[int,…]"}`
//   * `Browse.Album/set_cover`      v5 `{id:裸, id_item:裸}`
//   * `Browse.Album/set_name`       v5 `{id:裸, name}`
//   * `Browse.Album/delete`         v5 `{id:"[int,…]"}`  ← 必须数组串
//
// 这一层测的是"参数形态是否与官方一致"—— 写错形态在真机上表现为 120 / 静默
// 无效（delete 传裸 id 就是回 {} 但什么都不做），离线用例是唯一能钉死的地方。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/photos/photo_browse_page.dart';
import 'package:synhub/src/features/photos/photo_c2_sections.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';
import 'package:synhub/src/features/photos/photo_viewer_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _albumTable = {
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
  'SYNO.Foto.Browse.NormalAlbum': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 7,
  },
};

Map<String, dynamic> _albumJson(
  String id,
  String name, {
  int itemCount = 0,
  String type = 'normal',
}) => {
  'id': id,
  'name': name,
  'item_count': itemCount,
  'type': type,
  'shared': false,
  'owner_user_id': '4',
  'additional': {'thumbnail': <String, dynamic>{}},
};

Map<String, dynamic> _itemJson(String id) => {
  'id': id,
  'filename': 'IMG_$id.jpg',
  'filesize': 1024,
  'time': DateTime(2026, 9, 18, 10).millisecondsSinceEpoch ~/ 1000,
  'indexed_time': DateTime(2026, 9, 18, 11).millisecondsSinceEpoch ~/ 1000,
  'folder_id': '10',
  'type': 'photo',
  'additional': {
    'thumbnail': {
      'sm': 'sm_$id',
      'm': 'm_$id',
      'xl': 'xl_$id',
      'cache_key': 'ck',
    },
    'favorite': false,
  },
};

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

void main() {
  group('FotoApi 相册写操作（参数形态）', () {
    late FakeTransport t;
    late FotoApi foto;

    setUp(() async {
      t = FakeTransport(<String, Map<String, dynamic>>{}, {
        ...FakeTransport.table,
        ..._albumTable,
      });
      t.onCall = (params) {
        final method = '${params['method']}';
        final api = '${params['api']}';
        if (api.contains('Setting.User')) {
          return {
            'team_space_permission': 'none',
            'timeline_group_unit': 'day',
            'item_sort_by': 'takentime',
            'sort_direction': 'desc',
          };
        }
        if (api.endsWith('Browse.NormalAlbum') && method == 'list') {
          return {
            'list': [_albumJson('7', '旅行')],
            'total': 1,
          };
        }
        if (api.endsWith('Browse.NormalAlbum') && method == 'create') {
          return {
            'album': _albumJson('9', '${params['name']}'),
            'error_list': <dynamic>[],
          };
        }
        if (api.endsWith('Browse.NormalAlbum') && method == 'add_item') {
          // 用例可以用 `t.responses` 覆盖（比如造 error_list）
          return t.responses['$api.$method'] ?? {'error_list': <dynamic>[]};
        }
        if (api.endsWith('Browse.Album') && method == 'list') {
          return {
            'list': [_albumJson('7', '旅行')],
            'total': 1,
          };
        }
        return const <String, dynamic>{};
      };
      foto = FotoApi(await _loggedIn(t));
    });

    Map<String, dynamic> lastCall(String method) => t.calls.lastWhere(
      (c) => '${c['method']}' == method,
      orElse: () => throw StateError('没有发起过 $method'),
    );

    test('新建相册：NormalAlbum/create v4，item 是数字数组', () async {
      final album = await foto.createAlbum(name: '旅行', itemIds: ['9547']);
      expect(album.id, '9');
      final call = lastCall('create');
      expect(call['api'], 'SYNO.Foto.Browse.NormalAlbum');
      expect('${call['version']}', '4');
      expect(call['name'], '旅行');
      expect(call['item'], '[9547]');
    });

    test('新建相册不带照片时不发 item 参数', () async {
      await foto.createAlbum(name: '空相册');
      expect(lastCall('create').containsKey('item'), isFalse);
    });

    test('非数字 id 被丢掉（服务端只认数字，否则 120）', () async {
      await foto.createAlbum(name: 'x', itemIds: ['9547', 'album-cover']);
      expect(lastCall('create')['item'], '[9547]');
    });

    test('加照片：add_item v4，id 裸值 + item 数字数组', () async {
      final failed = await foto.addItemsToAlbum(
        albumId: '7',
        itemIds: ['9547', '9546'],
      );
      expect(failed, isEmpty);
      final call = lastCall('add_item');
      expect('${call['version']}', '4');
      expect(call['id'], '7', reason: 'id 不能被数组化');
      expect(call['item'], '[9547,9546]');
    });

    test('加照片没进去的会在 error_list 里返回', () async {
      t.responses['SYNO.Foto.Browse.NormalAlbum.add_item'] = {
        'error_list': [
          {'id': 9546, 'code': 1234},
        ],
      };
      final failed = await foto.addItemsToAlbum(
        albumId: '7',
        itemIds: ['9547', '9546'],
      );
      expect(failed, ['9546']);
    });

    test('移出相册：delete_item v4（照片本身不删）', () async {
      await foto.removeItemsFromAlbum(albumId: '7', itemIds: ['9547']);
      final call = lastCall('delete_item');
      expect('${call['version']}', '4');
      expect(call['id'], '7');
      expect(call['item'], '[9547]');
    });

    test('改封面 / 改名：Album v5，id 与 id_item 都是裸值', () async {
      await foto.setAlbumCover(albumId: '7', itemId: '9547');
      final cover = lastCall('set_cover');
      expect('${cover['version']}', '5');
      expect(cover['id'], '7');
      expect(cover['id_item'], '9547');

      await foto.renameAlbum(albumId: '7', name: '新名字');
      final name = lastCall('set_name');
      expect('${name['version']}', '5');
      expect(name['id'], '7');
      expect(name['name'], '新名字');
    });

    test('删相册：Album/delete v5，id 必须是数组串（裸 id 静默无效）', () async {
      await foto.deleteAlbums(['7', '9']);
      final call = lastCall('delete');
      expect('${call['version']}', '5');
      expect(call['id'], '[7,9]');
    });

    test('空 id 列表不发请求', () async {
      final before = t.calls.length;
      await foto.deleteAlbums(const []);
      await foto.addItemsToAlbum(albumId: '7', itemIds: const []);
      expect(t.calls.length, before);
    });
  });

  group('★ DA75 相册共享入口（r417）', () {
    // 缺陷：共享页（外链 / 成员 / 口令）此前**只有**"已共享相册列表里点一行"
    // 这一个入口 —— 两个列表都空时整个共享功能在 App 内进不去（首个共享相册
    // 建不出来）。修法 = 相册详情页 `⋮` 里加「共享」直达。
    //
    // 这一组钉两件事：① 入口在、点了能进共享页；② 进页后真的发的是官方形态的
    // `Browse.Album/get`（additional=sharing_info）与 `Sharing.Passphrase/set_shared`。
    FakeTransport makeTransport({String privacy = 'private'}) {
      final t = FakeTransport(<String, Map<String, dynamic>>{}, {
        ...FakeTransport.table,
        ..._albumTable,
        'SYNO.Foto.Sharing.Passphrase': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 1,
        },
      });
      t.onCall = (params) {
        final method = '${params['method']}';
        final api = '${params['api']}';
        if (api.contains('Setting.User')) {
          return {
            'team_space_permission': 'none',
            'timeline_group_unit': 'day',
            'item_sort_by': 'takentime',
            'sort_direction': 'desc',
          };
        }
        if (api.endsWith('Browse.Album') && method == 'get') {
          return {
            'list': [
              {
                ..._albumJson('7', '旅行', itemCount: 2),
                'additional': {
                  'thumbnail': <String, dynamic>{},
                  'sharing_info': {
                    'privacy_type': privacy,
                    'sharing_link': privacy == 'private'
                        ? ''
                        : 'https://nas.example.com/mo/sharing/abc',
                    'passphrase': privacy == 'private' ? '' : 'abcdef',
                    'enable_password': false,
                    'expiration': 0,
                    'permission': <dynamic>[],
                    'owner': {'id': -1, 'name': ''},
                    'type': 'album',
                  },
                },
              },
            ],
            'total': 1,
          };
        }
        if (api.endsWith('Sharing.Passphrase') && method == 'set_shared') {
          return {
            'sharing_link': 'https://nas.example.com/mo/sharing/abc',
            'passphrase': 'abcdef',
          };
        }
        if (api.endsWith('Browse.Item') && method == 'list') {
          return {
            'list': [_itemJson('9547')],
            'total': 1,
          };
        }
        return const <String, dynamic>{};
      };
      return t;
    }

    Future<FakeTransport> pumpAlbum(WidgetTester tester) async {
      final t = makeTransport();
      final api = await _loggedIn(t);
      final c = ProviderContainer(
        overrides: [fotoApiProvider.overrideWithValue(FotoApi(api))],
      );
      addTearDown(c.dispose);
      final album = FotoAlbumDto.fromJson(_albumJson('7', '旅行', itemCount: 2));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: PhotoAlbumItemsPage(album: album),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return t;
    }

    testWidgets('相册详情页 ⋮ 里有「共享」（正向）', (tester) async {
      await pumpAlbum(tester);
      await tester.tap(find.byTooltip('相册操作'));
      await tester.pumpAndSettle();
      expect(find.text('共享'), findsOneWidget, reason: '★ DA75：入口必须有');
      expect(find.text('重命名'), findsOneWidget);
      expect(find.text('删除相册'), findsOneWidget);
    });

    testWidgets('点「共享」进共享页，并发 sharing_info 的 get', (tester) async {
      final t = await pumpAlbum(tester);
      await tester.tap(find.byTooltip('相册操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('共享'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('photo-c2-share-detail-page')),
        findsOneWidget,
        reason: '★ DA75：点进去必须是共享页（外链 / 成员 / 口令）',
      );
      final call = t.calls.firstWhere(
        (c) => c['method'] == 'get' && '${c['api']}'.endsWith('Browse.Album'),
      );
      expect(call['id'], '[7]', reason: '官方形态：id 是数组');
      expect('${call['additional']}', '["sharing_info"]');
    });

    testWidgets('共享页「生成共享链接」发 set_shared(enabled=false)', (tester) async {
      final t = await pumpAlbum(tester);
      await tester.tap(find.byTooltip('相册操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('共享'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('photo-c2-share-link-create')));
      await tester.pumpAndSettle();

      final call = t.calls.firstWhere(
        (c) => c['method'] == 'set_shared',
      );
      expect('${call['api']}', 'SYNO.Foto.Sharing.Passphrase');
      expect('${call['version']}', '1');
      expect(call['policy'], 'album');
      expect(call['album_id'], '7');
      expect('${call['enabled']}', 'false', reason: '只生成链接，不改可见性');
    });

    testWidgets('非共享列表进来的路径仍可用（回归：已共享行 → 详情）', (tester) async {
      // 反向：入口不止一个 ⇒ 修 DA75 不许把老入口改坏
      final t = makeTransport();
      final api = await _loggedIn(t);
      final c = ProviderContainer(
        overrides: [fotoApiProvider.overrideWithValue(FotoApi(api))],
      );
      addTearDown(c.dispose);
      final album = FotoAlbumDto.fromJson(_albumJson('7', '旅行', itemCount: 2));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: AlbumSharingDetailPage(album: album),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('photo-c2-share-detail-page')), findsOneWidget);
      expect(find.byKey(const Key('photo-c2-share-link-create')), findsOneWidget);
    });
  });

  group('★ DA76 生成外链之后要能"打开外链分享"（r417）', () {
    // 缺陷（真机读数，r417）：`set_shared(enabled:false)` 只生成**口令**，
    // 服务端在未公开时 `sharing_info.sharing_link` 是**空串**；界面原判据
    // 是 `sharingLink.isNotEmpty` ⇒ 「打开外链分享」入口**永不出现**，
    // 外链分享在 App 内走不通（相册也永远进不了"我共享的"列表）。
    //
    // 修法：链接文本优先用服务端、回落"生成时的回包"；入口判据改成
    // "口令存在（= 链接已生成）"，且打开前若还没有口令就先补一次 `enabled:false`。
    ({FakeTransport t, List<Map<String, dynamic>> calls}) makeTransport({
      String passphrase = '',
      String link = '',
      bool shared = false,
      String privacy = 'private',
      bool updateOnSetShared = true,
    }) {
      // 真实的"服务端状态"：`set_shared` 之后口令就存在了（`get` 会回它）
      var pass = passphrase;
      var storedLink = link;
      var storedShared = shared;
      final t = FakeTransport(<String, Map<String, dynamic>>{}, {
        ...FakeTransport.table,
        ..._albumTable,
        'SYNO.Foto.Sharing.Passphrase': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 1,
        },
      });
      t.onCall = (params) {
        final method = '${params['method']}';
        final api = '${params['api']}';
        if (api.contains('Setting.User')) {
          return {
            'team_space_permission': 'none',
            'timeline_group_unit': 'day',
            'item_sort_by': 'takentime',
            'sort_direction': 'desc',
          };
        }
        if (api.endsWith('Sharing.Passphrase') && method == 'set_shared') {
          // 服务端行为：生成后回包里**有**链接；`get` 那边口令也变成有值，
          // 但 `sharing_info.sharing_link` **仍是空串**（这就是 DA76 的坑）。
          if (updateOnSetShared) pass = 'xyz';
          return {
            'sharing_link': 'https://nas.example.com/mo/sharing/xyz',
            'passphrase': 'xyz',
          };
        }
        if (api.endsWith('Browse.Album') && method == 'get') {
          return {
            'list': [
              {
                ..._albumJson('9', 'r417share', itemCount: 0),
                'shared': storedShared,
                'additional': {
                  'thumbnail': <String, dynamic>{},
                  'sharing_info': {
                    'privacy_type': privacy,
                    'sharing_link': storedLink,
                    'passphrase': pass,
                    'enable_password': false,
                    'expiration': 0,
                    'permission': <dynamic>[],
                    'owner': {'id': -1, 'name': ''},
                    'type': 'album',
                  },
                },
              },
            ],
            'total': 1,
          };
        }
        return const <String, dynamic>{};
      };
      return (t: t, calls: t.calls);
    }

    Future<FakeTransport> pumpShare(
      WidgetTester tester,
      FakeTransport t,
    ) async {
      final api = await _loggedIn(t);
      final c = ProviderContainer(
        overrides: [fotoApiProvider.overrideWithValue(FotoApi(api))],
      );
      addTearDown(c.dispose);
      final album = FotoAlbumDto.fromJson(_albumJson('9', 'r417share'));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: AlbumSharingDetailPage(album: album),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return t;
    }

    testWidgets('只有口令、服务端不回链接时也有「打开外链分享」', (tester) async {
      final made = makeTransport(passphrase: 'abcdef');
      await pumpShare(tester, made.t);
      expect(
        find.byKey(const Key('photo-c2-share-link-enable')),
        findsOneWidget,
        reason: '★ DA76：口令在就是"链接已生成"，入口必须在',
      );
      expect(
        find.byKey(const Key('photo-c2-share-link-create')),
        findsNothing,
        reason: '已经有口令了，不该再让人点"生成共享链接"',
      );
    });

    testWidgets('生成链接后用回包里的链接显示（服务端 get 仍是空串）', (tester) async {
      final made = makeTransport();
      await pumpShare(tester, made.t);
      await tester.tap(find.byKey(const Key('photo-c2-share-link-create')));
      await tester.pumpAndSettle();
      expect(
        find.text('https://nas.example.com/mo/sharing/xyz'),
        findsOneWidget,
        reason: '★ DA76：链接在回包里，界面要显示出来',
      );
      expect(
        find.byKey(const Key('photo-c2-share-link-enable')),
        findsOneWidget,
      );
    });

    testWidgets('打开外链：生成(true) 之前的那次(false) 之后不再重复', (tester) async {
      final made = makeTransport();
      await pumpShare(tester, made.t);
      await tester.tap(find.byKey(const Key('photo-c2-share-link-create')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-c2-share-link-enable')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-c2-share-link-enable-ok')));
      await tester.pumpAndSettle();

      final sets = made.t.calls
          .where((c) => c['method'] == 'set_shared')
          .toList();
      expect(
        sets.length,
        2,
        reason: '★ DA76：口令已在服务端 ⇒ 不该再多发一次 enabled:false',
      );
      expect('${sets[0]['enabled']}', 'false', reason: '第一次是"生成链接"');
      expect('${sets[1]['enabled']}', 'true', reason: '第二次是"打开外链"');
      expect('${sets[1]['policy']}', 'album');
      expect(sets[1]['album_id'], '9');
    });

    testWidgets('防御分支：服务端还没回口令时，打开前先补一次 set_shared(false)', (tester) async {
      // 极端时序（`get` 还没刷新到"有口令"）：本会话生成过链接 ⇒ 入口在，
      // 但服务端读数说没有口令 ⇒ 打开前必须先把链接要出来（否则可能 120）。
      final made = makeTransport(updateOnSetShared: false);
      await pumpShare(tester, made.t);
      await tester.tap(find.byKey(const Key('photo-c2-share-link-create')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-c2-share-link-enable')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-c2-share-link-enable-ok')));
      await tester.pumpAndSettle();

      final sets = made.t.calls
          .where((c) => c['method'] == 'set_shared')
          .toList();
      expect(sets.length, 3);
      expect(['false', 'false', 'true'], [
        for (final c in sets) '${c['enabled']}',
      ]);
    });

    testWidgets('已公开时不再显示「打开」，而是「关闭外链分享」', (tester) async {
      final made = makeTransport(
        passphrase: 'abcdef',
        link: 'https://nas.example.com/mo/sharing/xyz',
        shared: true,
        privacy: 'public-view',
      );
      await pumpShare(tester, made.t);
      expect(find.byKey(const Key('photo-c2-share-link-enable')), findsNothing);
      expect(find.byKey(const Key('photo-c2-share-disable')), findsOneWidget);
    });
  });

  group('★ DA77 关闭外链分享必须真的关掉（r417）', () {
    // 缺陷（真机 + NAS 侧原始读数，r417）：点「关闭外链分享」→ 确认 → 界面弹
    // `Link sharing turned off`，但同刻界面仍显示外链 + `Turn off link sharing`，
    // NAS 侧 `shared` 仍 `true`、`category=shared` 仍有它。
    // `tool/probe_r417_disable_shapes.dart` 逐个形状打同一台 NAS 的原始回包：
    //   ① `update {permission:delete public}` → `OK {}`，状态**没变**
    //   ② `update {privacy_type:private}`     → `OK {}`，状态**没变**
    //   ③ ①+② 一起                          → `OK {}`，状态**没变**
    //   ④ `set_shared {enabled:false}`        → `shared=false`、`link` 清空、
    //                                          `category=shared` 0 ✅
    // ⇒ 关闭外链 = `set_shared(enabled:false)`，不是 `Passphrase/update`。
    ({
      FakeTransport t,
      List<Map<String, dynamic>> calls,
    })
    makeTransport() {
      var shared = true;
      var link = 'https://nas.example.com/mo/sharing/xyz';
      final t = FakeTransport(<String, Map<String, dynamic>>{}, {
        ...FakeTransport.table,
        ..._albumTable,
        'SYNO.Foto.Sharing.Passphrase': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 1,
        },
      });
      t.onCall = (params) {
        final api = '${params['api']}';
        final method = '${params['method']}';
        if (api.contains('Setting.User')) {
          return {
            'team_space_permission': 'none',
            'timeline_group_unit': 'day',
            'item_sort_by': 'takentime',
            'sort_direction': 'desc',
          };
        }
        if (api.endsWith('Sharing.Passphrase') && method == 'set_shared') {
          final enabled = '${params['enabled']}' == 'true';
          shared = enabled;
          // ★ 真服务器行为（真机读数 ④）：**关闭时回包照样带那条正在作废的链接**
          //   ⇒ 夹具也必须这样回，否则用例不可能红（仪器⑯）。
          final echoed = link;
          if (!enabled) link = '';
          return {
            'sharing_link': enabled
                ? 'https://nas.example.com/mo/sharing/xyz'
                : echoed,
            'passphrase': 'xyz',
          };
        }
        if (api.endsWith('Browse.Album') && method == 'get') {
          return {
            'list': [
              {
                ..._albumJson('9', 'r417share', itemCount: 0),
                'shared': shared,
                'additional': {
                  'thumbnail': <String, dynamic>{},
                  'sharing_info': {
                    'privacy_type': 'private',
                    'sharing_link': link,
                    'passphrase': 'xyz',
                    'enable_password': false,
                    'expiration': 0,
                    'permission': <dynamic>[],
                    'owner': {'id': -1, 'name': ''},
                    'type': 'album',
                  },
                },
              },
            ],
            'total': 1,
          };
        }
        return const <String, dynamic>{};
      };
      return (t: t, calls: t.calls);
    }

    Future<void> pumpShare(WidgetTester tester, FakeTransport t) async {
      final api = await _loggedIn(t);
      final c = ProviderContainer(
        overrides: [fotoApiProvider.overrideWithValue(FotoApi(api))],
      );
      addTearDown(c.dispose);
      final album = FotoAlbumDto.fromJson(_albumJson('9', 'r417share'));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: AlbumSharingDetailPage(album: album),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('关闭外链发的是 set_shared(enabled:false)，不是 Passphrase/update', (
      tester,
    ) async {
      final made = makeTransport();
      await pumpShare(tester, made.t);
      await tester.tap(find.byKey(const Key('photo-c2-share-disable')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-c2-share-disable-ok')));
      await tester.pumpAndSettle();

      final setShared = made.calls
          .where((c) => c['method'] == 'set_shared')
          .toList();
      final updates = made.calls
          .where((c) => c['method'] == 'update')
          .toList();
      expect(
        setShared.length,
        1,
        reason: '★ DA77：关闭外链只认 set_shared(enabled:false)',
      );
      expect('${setShared.first['enabled']}', 'false');
      expect('${setShared.first['policy']}', 'album');
      expect(setShared.first['album_id'], '9');
      expect(
        updates,
        isEmpty,
        reason: '★ DA77：update 那条在真机上是"回 success 但什么都不改"',
      );
    });

    testWidgets('关闭后状态推进：出现「打开外链分享」，旧链接不再显示', (tester) async {
      final made = makeTransport();
      await pumpShare(tester, made.t);
      expect(find.text('https://nas.example.com/mo/sharing/xyz'), findsOneWidget);

      await tester.tap(find.byKey(const Key('photo-c2-share-disable')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-c2-share-disable-ok')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('photo-c2-share-link-enable')),
        findsOneWidget,
        reason: '★ DA77：关掉之后要能再打开（不然用户没法回退）',
      );
      expect(
        find.text('https://nas.example.com/mo/sharing/xyz'),
        findsNothing,
        reason: '★ DA77：已作废的外链不许继续挂在界面上（服务端回包里还会带着它）',
      );
      final copy = tester.widget<IconButton>(
        find.byKey(const Key('photo-c2-share-link-copy')),
      );
      expect(copy.onPressed, isNull, reason: '没有有效外链时"复制链接"必须变灰');
    });

    testWidgets('回归：二次确认点取消 ⇒ 一个请求都不发', (tester) async {
      final made = makeTransport();
      await pumpShare(tester, made.t);
      await tester.tap(find.byKey(const Key('photo-c2-share-disable')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-c2-share-disable-cancel')));
      await tester.pumpAndSettle();
      expect(
        made.calls.where(
          (c) => c['method'] == 'set_shared' || c['method'] == 'update',
        ),
        isEmpty,
      );
    });
  });

  group('相册写操作的页面链路', () {
    Future<({FakeTransport t, ProviderContainer c})> pump(
      WidgetTester tester, {
      Widget? page,
    }) async {
      // 服务端当前的名字（改名成功后 `list` 返回新名字）
      String? renamed;
      final t = FakeTransport(<String, Map<String, dynamic>>{}, {
        ...FakeTransport.table,
        ..._albumTable,
      });
      t.onCall = (params) {
        final method = '${params['method']}';
        final api = '${params['api']}';
        if (api.contains('Setting.User')) {
          return {
            'team_space_permission': 'none',
            'timeline_group_unit': 'day',
            'item_sort_by': 'takentime',
            'sort_direction': 'desc',
          };
        }
        if (api.endsWith('Browse.NormalAlbum') && method == 'list') {
          return {
            'list': [_albumJson('7', renamed ?? '旅行', itemCount: 2)],
            'total': 1,
          };
        }
        if (api.endsWith('Browse.Album') && method == 'set_name') {
          renamed = '${params['name']}';
          return const <String, dynamic>{};
        }
        if (api.endsWith('Browse.Album') && method == 'list') {
          return {
            'list': [<String, dynamic>{}],
            'total': 0,
          };
        }
        if (api.endsWith('Browse.Item') && method == 'list') {
          return {
            'list': [_itemJson('9547')],
            'total': 1,
          };
        }
        if (api.endsWith('Browse.NormalAlbum') && method == 'create') {
          return {
            'album': _albumJson('9', '${params['name']}'),
            'error_list': <dynamic>[],
          };
        }
        return const <String, dynamic>{};
      };
      final api = await _loggedIn(t);
      final c = ProviderContainer(
        overrides: [fotoApiProvider.overrideWithValue(FotoApi(api))],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: page ?? const PhotoBrowsePage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return (t: t, c: c);
    }

    testWidgets('相册段有「新建相册」，建完落在服务端', (tester) async {
      final r = await pump(tester);
      // 切到相册段（页标题也叫「相册」，取最后一个 = chip）
      await tester.tap(find.text('相册').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('photo-album-create')), findsOneWidget);

      // 时间轴段也有自己的 FAB → 切换时 Scaffold 有 FAB 过渡动画，
      // 等它走完再点，避免命中正在淡出的旧 FAB
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-album-create')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('photo-album-name')), '周末');
      await tester.tap(find.byKey(const Key('photo-album-create-ok')));
      await tester.pumpAndSettle();

      final call = r.t.calls.firstWhere((c) => c['method'] == 'create');
      expect(call['api'], 'SYNO.Foto.Browse.NormalAlbum');
      expect(call['name'], '周末');
      expect('${call['version']}', '4');
    });

    testWidgets('相册详情页能改名（Album/set_name）', (tester) async {
      final album = FotoAlbumDto.fromJson(_albumJson('7', '旅行', itemCount: 1));
      final r = await pump(tester, page: PhotoAlbumItemsPage(album: album));
      await tester.tap(find.byTooltip('相册操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('photo-album-rename')), '夏天');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final call = r.t.calls.firstWhere((c) => c['method'] == 'set_name');
      expect(call['id'], '7');
      expect(call['name'], '夏天');
      expect('${call['version']}', '5');
    });

    testWidgets('改名之后标题跟着变（别停在打开这一页时的旧名字）', (tester) async {
      final album = FotoAlbumDto.fromJson(_albumJson('7', '旅行', itemCount: 1));
      await pump(tester, page: PhotoAlbumItemsPage(album: album));
      expect(find.text('旅行'), findsWidgets);

      await tester.tap(find.byTooltip('相册操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('photo-album-rename')), '夏天');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      // 服务端那边名字变了 → 列表 provider 刷新 → 标题也要是新的，
      // 删除确认框里念的也得是新名字（真机上这里曾经还是"旅行"）
      expect(find.text('夏天'), findsWidgets);
      await tester.tap(find.byTooltip('相册操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除相册'));
      await tester.pumpAndSettle();
      // 两处都该是新名字：底部提示 + 确认框正文
      expect(find.textContaining('「夏天」'), findsWidgets);
    });

    testWidgets('相册详情页能删除，且删的是数组串', (tester) async {
      final album = FotoAlbumDto.fromJson(_albumJson('7', '旅行', itemCount: 1));
      final r = await pump(tester, page: PhotoAlbumItemsPage(album: album));
      await tester.tap(find.byTooltip('相册操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除相册'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-album-delete-ok')));
      await tester.pumpAndSettle();

      final call = r.t.calls.firstWhere((c) => c['method'] == 'delete');
      expect(call['id'], '[7]');
      expect('${call['version']}', '5');
    });

    testWidgets('大图页「加入相册」→ 选相册 → add_item', (tester) async {
      final r = await pump(
        tester,
        page: PhotoViewerPage(items: [FotoItemDto.fromJson(_itemJson('9547'))]),
      );
      await tester.tap(find.byTooltip('加入相册'));
      await tester.pumpAndSettle();
      expect(find.text('旅行'), findsOneWidget);
      await tester.tap(find.text('旅行'));
      await tester.pumpAndSettle();

      final call = r.t.calls.firstWhere((c) => c['method'] == 'add_item');
      expect(call['id'], '7');
      expect(call['item'], '[9547]');
    });

    testWidgets('相册里的大图页有「设为封面 / 移出相册」', (tester) async {
      final r = await pump(
        tester,
        page: PhotoViewerPage(
          items: [FotoItemDto.fromJson(_itemJson('9547'))],
          albumId: '7',
          albumName: '旅行',
        ),
      );
      await tester.tap(find.byTooltip('相册操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设为相册封面'));
      await tester.pumpAndSettle();
      final cover = r.t.calls.firstWhere((c) => c['method'] == 'set_cover');
      expect(cover['id'], '7');
      expect(cover['id_item'], '9547');

      await tester.tap(find.byTooltip('相册操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('移出'));
      await tester.pumpAndSettle();
      final del = r.t.calls.firstWhere((c) => c['method'] == 'delete_item');
      expect(del['id'], '7');
      expect(del['item'], '[9547]');
    });
  });
}
