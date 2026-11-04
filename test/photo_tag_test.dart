// 相册「批量打标签」离线测试。
//
// 覆盖：
//   * 接口层：`GeneralTag/list|create|suggest`、`Browse.Item/get_tag|add_tag|remove_tag`
//     的**参数形态**（数字数组 + JSON 串、v7/v2）、50 一批、`error_list` 部分失败、
//     会话过期要冒出去（不能当普通失败吞掉）；
//   * 页面层：长按进多选、全选、计数、批量操作条 → 标签弹层 → 提交 add_tag。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/photos/photo_browse_page.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';
import 'package:synhub/src/features/photos/photo_prefs_store.dart';
import 'package:synhub/src/features/photos/photo_seen_tags.dart';
import 'package:synhub/src/features/photos/photo_tag_sheet.dart';
import 'package:synhub/src/features/photos/photo_widgets.dart';
import 'package:synhub/src/design/kit/design_kit.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 内存版偏好存储（r412：本机见过的标签要能可控预置/读出）。
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

const _fotoTable = {
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
  'SYNO.Foto.Thumbnail': {
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
    'favorite': false,
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
}) {
  final t = FakeTransport(
    {
      'SYNO.Foto.Setting.User.get': {
        'team_space_permission': 'none',
        'timeline_group_unit': 'day',
      },
      'SYNO.Foto.Browse.Item.list': {'list': []},
      ...responses,
    },
    {...FakeTransport.table, ..._fotoTable},
  );
  t.downloadBytes = _png;
  return t;
}

void main() {
  group('标签接口', () {
    test('generalTags：GeneralTag/list v2 → list', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.GeneralTag.list': {
            'list': [
              {'id': 1, 'name': '旅行', 'count': 3},
              {'id': 2, 'name': '家人'},
            ],
          },
        },
      );
      final api = await _loggedIn(t);
      final tags = await FotoApi(api).generalTags();
      expect(tags.map((e) => e.name), ['旅行', '家人']);
      expect(tags.first.count, 3);
      final call = t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Foto.Browse.GeneralTag',
      );
      expect(call['method'], 'list');
      expect(call['version'], '2');
    });

    test('createTag：{name} → {tag:[{id,name}]}', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.GeneralTag.create': {
            'tag': [
              {'id': 9, 'name': '风景'},
            ],
          },
        },
      );
      final api = await _loggedIn(t);
      final tag = await FotoApi(api).createTag('风景');
      expect(tag!.id, '9');
      expect(tag.name, '风景');
      final call = t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Foto.Browse.GeneralTag',
      );
      expect(call['method'], 'create');
      expect(call['name'], '风景');
    });

    test('createTag：现场 NAS 回单对象 {tag:{id,name}} 也要认（真机踩坑）', () async {
      final t = _transport(
        responses: {
          // DSM 7.x 实测形状：tag 是**对象**不是数组，id 是数字
          'SYNO.Foto.Browse.GeneralTag.create': {
            'tag': {'id': 1, 'name': 'huihubtag'},
          },
        },
      );
      final api = await _loggedIn(t);
      final tag = await FotoApi(api).createTag('huihubtag');
      expect(tag, isNotNull);
      expect(tag!.id, '1');
      expect(tag.name, 'huihubtag');
    });

    test('createTag：官方 {tag:[{…}]} 形状照旧', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.GeneralTag.create': {
            'tag': [
              {'id': 7, 'name': '旅行'},
            ],
          },
        },
      );
      final api = await _loggedIn(t);
      final tag = await FotoApi(api).createTag('旅行');
      expect(tag!.id, '7');
    });

    test('createTag：完全认不出来时回 null（调用方要给提示）', () async {
      final t = _transport(
        responses: {'SYNO.Foto.Browse.GeneralTag.create': <String, dynamic>{}},
      );
      final api = await _loggedIn(t);
      expect(await FotoApi(api).createTag('x'), isNull);
    });

    test('suggestTags：{keyword, limit} → list', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.GeneralTag.suggest': {
            'list': [
              {'id': 1, 'name': '旅行'},
            ],
          },
        },
      );
      final api = await _loggedIn(t);
      final tags = await FotoApi(api).suggestTags('旅', limit: 5);
      expect(tags.single.name, '旅行');
      final call = t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Foto.Browse.GeneralTag',
      );
      expect(call['keyword'], '旅');
      expect(call['limit'], '5');
    });

    test('itemTagIds：get_tag → intersection（只回 id）', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.Item.get_tag': {
            'intersection': [3, 5],
          },
        },
      );
      final api = await _loggedIn(t);
      final ids = await FotoApi(api).itemTagIds(['11', '12']);
      expect(ids, ['3', '5']);
      final call = t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Foto.Browse.Item',
      );
      expect(call['method'], 'get_tag');
      expect(call['version'], '7');
      expect(jsonDecode(call['id'] as String), [11, 12]);
    });

    test('addTags：v7 + 数字数组 JSON 串，50 一批', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.Item.add_tag': {'error_list': []},
        },
      );
      final api = await _loggedIn(t);
      final failed = await FotoApi(api).addTags(
        itemIds: [for (var i = 1; i <= 51; i++) '$i'],
        tagIds: ['7', '8'],
      );
      expect(failed, isEmpty);
      final calls = t.calls
          .where(
            (c) =>
                c['api'] == 'SYNO.Foto.Browse.Item' && c['method'] == 'add_tag',
          )
          .toList();
      expect(calls.length, 2);
      expect(calls.first['version'], '7');
      expect(jsonDecode(calls.first['id'] as String).length, 50);
      expect(jsonDecode(calls.last['id'] as String), [51]);
      expect(jsonDecode(calls.first['tag'] as String), [7, 8]);
    });

    test('removeTags：形态同 add_tag', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.Item.remove_tag': {
            'error_list': [
              {'id': 12},
            ],
          },
        },
      );
      final api = await _loggedIn(t);
      final failed = await FotoApi(
        api,
      ).removeTags(itemIds: ['11', '12'], tagIds: ['7']);
      expect(failed, ['12'], reason: '部分失败要回传，不抛');
      final call = t.calls.lastWhere((c) => c['method'] == 'remove_tag');
      expect(jsonDecode(call['id'] as String), [11, 12]);
      expect(jsonDecode(call['tag'] as String), [7]);
    });

    test('空入参不发请求', () async {
      final t = _transport();
      final api = await _loggedIn(t);
      expect(await FotoApi(api).addTags(itemIds: [], tagIds: ['1']), isEmpty);
      expect(await FotoApi(api).addTags(itemIds: ['1'], tagIds: []), isEmpty);
      expect(await FotoApi(api).itemTagIds([]), isEmpty);
      expect(t.calls.where((c) => '${c['method']}'.contains('tag')), isEmpty);
    });

    test('会话过期（119）要冒出去，不能当普通失败吞掉', () async {
      final t = _transport();
      t.failures['SYNO.Foto.Browse.Item.add_tag'] = 119;
      final api = await _loggedIn(t);
      expect(
        () => FotoApi(api).addTags(itemIds: ['1'], tagIds: ['2']),
        throwsA(isA<DsmApiException>()),
      );
    });

    test('网络/参数类错误 → 记这一批失败，不抛出', () async {
      final t = _transport();
      t.failures['SYNO.Foto.Browse.Item.add_tag'] = 120;
      final api = await _loggedIn(t);
      final failed = await FotoApi(
        api,
      ).addTags(itemIds: ['1', '2'], tagIds: ['3']);
      expect(failed, ['1', '2']);
    });
  });

  group('多选 + 批量打标签页面', () {
    Future<({FakeTransport t, ProviderContainer c})> pump(
      WidgetTester tester, {
      Map<String, Map<String, dynamic>> responses = const {},
      List<Map<String, dynamic>>? items,
      PhotoPrefsStore? prefs,
    }) async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.Item.list': {
            'list': items ?? [_item('11'), _item('12'), _item('13')],
          },
          ...responses,
        },
      );
      final api = await _loggedIn(t);
      final db = ChatDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          fotoApiProvider.overrideWithValue(FotoApi(api)),
          if (prefs != null) photoPrefsStoreProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(db.close);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: PhotoBrowsePage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      return (t: t, c: c);
    }

    testWidgets('长按进多选 → 计数 + 全选 → 批量操作条', (tester) async {
      await pump(tester);
      expect(find.byKey(const Key('photo-selection-tag')), findsNothing);
      await tester.longPress(find.byType(PhotoCell).first);
      await tester.pump();
      expect(find.text('已选 1 张'), findsWidgets);
      await tester.tap(find.byKey(const Key('photo-selection-all')));
      await tester.pump();
      expect(find.text('已选 3 张'), findsWidgets);
      expect(find.byKey(const Key('photo-selection-tag')), findsOneWidget);
      // 退出多选
      await tester.tap(find.byKey(const Key('photo-selection-close')));
      await tester.pump();
      expect(find.byKey(const Key('photo-selection-tag')), findsNothing);
    });

    testWidgets('弹层列出标签并提交 add_tag（多张 + 标签 id）', (tester) async {
      final boot = await pump(
        tester,
        responses: {
          'SYNO.Foto.Browse.GeneralTag.list': {
            'list': [
              {'id': 1, 'name': '旅行'},
            ],
          },
          'SYNO.Foto.Browse.Item.get_tag': {'intersection': []},
          'SYNO.Foto.Browse.Item.add_tag': {'error_list': []},
        },
      );
      await tester.longPress(find.byType(PhotoCell).first);
      await tester.pump();
      await tester.tap(find.byKey(const Key('photo-selection-all')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('photo-selection-tag')));
      await tester.pumpAndSettle();
      expect(find.text('标签（已选 3 张）'), findsOneWidget);
      expect(find.text('旅行'), findsOneWidget);

      await tester.tap(find.byKey(const Key('photo-tag-1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('photo-tag-apply')));
      await tester.pumpAndSettle();

      final call = boot.t.calls.lastWhere((c) => c['method'] == 'add_tag');
      expect(jsonDecode(call['id'] as String), [11, 12, 13]);
      expect(jsonDecode(call['tag'] as String), [1]);
    });

    testWidgets('已有共同标签 → 取消勾选后提交 remove_tag', (tester) async {
      final boot = await pump(
        tester,
        responses: {
          'SYNO.Foto.Browse.GeneralTag.list': {
            'list': [
              {'id': 4, 'name': '家人'},
            ],
          },
          'SYNO.Foto.Browse.Item.get_tag': {
            'intersection': [4],
          },
          'SYNO.Foto.Browse.Item.remove_tag': {'error_list': []},
        },
      );
      await tester.longPress(find.byType(PhotoCell).first);
      await tester.pump();
      await tester.tap(find.byKey(const Key('photo-selection-tag')));
      await tester.pumpAndSettle();
      // 初始已勾上（共同标签）
      // r513：换皮成设计组件 `DesignCheckRow`（`value` 语义不变）
      final checkbox = tester.widget<DesignCheckRow>(
        find.byKey(const Key('photo-tag-4')),
      );
      expect(checkbox.value, isTrue);
      await tester.tap(find.byKey(const Key('photo-tag-4')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('photo-tag-apply')));
      await tester.pumpAndSettle();
      final call = boot.t.calls.lastWhere((c) => c['method'] == 'remove_tag');
      expect(jsonDecode(call['id'] as String), [11]);
      expect(jsonDecode(call['tag'] as String), [4]);
    });

    testWidgets('没有标签 → 空态提示；输入可新建', (tester) async {
      final boot = await pump(
        tester,
        responses: {
          'SYNO.Foto.Browse.GeneralTag.list': {'list': []},
          'SYNO.Foto.Browse.GeneralTag.suggest': {'list': []},
          'SYNO.Foto.Browse.GeneralTag.create': {
            'tag': [
              {'id': 6, 'name': '新标签'},
            ],
          },
          'SYNO.Foto.Browse.Item.get_tag': {'intersection': []},
          'SYNO.Foto.Browse.Item.add_tag': {'error_list': []},
        },
      );
      await tester.longPress(find.byType(PhotoCell).first);
      await tester.pump();
      await tester.tap(find.byKey(const Key('photo-selection-tag')));
      await tester.pumpAndSettle();
      expect(find.text('还没有标签'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('photo-tag-search')), '新标签');
      await tester.pump();
      expect(find.byKey(const Key('photo-tag-create')), findsOneWidget);
      await tester.tap(find.byKey(const Key('photo-tag-create')));
      await tester.pumpAndSettle();
      expect(boot.t.calls.where((c) => c['method'] == 'create'), isNotEmpty);
      // 新建后直接勾上，提交时带上新标签 id
      await tester.tap(find.byKey(const Key('photo-tag-apply')));
      await tester.pumpAndSettle();
      final call = boot.t.calls.lastWhere((c) => c['method'] == 'add_tag');
      expect(jsonDecode(call['tag'] as String), [6]);
    });

    testWidgets('文件夹页：长按多选 → 批量打标签（备份目录也能标）', (tester) async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.Folder.list': {'list': []},
          'SYNO.Foto.Browse.Item.list': {
            'list': [_item('21'), _item('22')],
          },
          'SYNO.Foto.Browse.GeneralTag.list': {
            'list': [
              {'id': 1, 'name': '旅行'},
            ],
          },
          'SYNO.Foto.Browse.Item.get_tag': {'intersection': []},
          'SYNO.Foto.Browse.Item.add_tag': {'error_list': []},
        },
      );
      final api = await _loggedIn(t);
      final db = ChatDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          fotoApiProvider.overrideWithValue(FotoApi(api)),
        ],
      );
      addTearDown(db.close);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(
            home: PhotoFolderPage(
              folder: FotoFolderDto(id: '7', name: '手机备份'),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('photo-selection-tag')), findsNothing);
      await tester.longPress(find.byType(PhotoCell).first);
      await tester.pump();
      expect(find.text('已选 1 张'), findsWidgets);
      await tester.tap(find.byKey(const Key('photo-selection-all')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('photo-selection-tag')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-tag-1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('photo-tag-apply')));
      await tester.pumpAndSettle();
      final call = t.calls.lastWhere((c) => c['method'] == 'add_tag');
      expect(jsonDecode(call['id'] as String), [21, 22]);
      expect(jsonDecode(call['tag'] as String), [1]);
    });

    testWidgets('部分失败 → 提示失败数量，不崩', (tester) async {
      await pump(
        tester,
        responses: {
          'SYNO.Foto.Browse.GeneralTag.list': {
            'list': [
              {'id': 1, 'name': '旅行'},
            ],
          },
          'SYNO.Foto.Browse.Item.get_tag': {'intersection': []},
          'SYNO.Foto.Browse.Item.add_tag': {
            'error_list': [
              {'id': 12},
            ],
          },
        },
      );
      await tester.longPress(find.byType(PhotoCell).first);
      await tester.pump();
      await tester.tap(find.byKey(const Key('photo-selection-all')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('photo-selection-tag')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-tag-1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('photo-tag-apply')));
      await tester.pumpAndSettle();
      expect(find.text('1 个操作失败'), findsOneWidget);
    });

    testWidgets('边打边联想：list 空但 suggest 有 → 打字就能看到并可勾选', (tester) async {
      final boot = await pump(
        tester,
        responses: {
          // 现场 NAS：list 对新标签一直回空，suggest 才搜得到
          'SYNO.Foto.Browse.GeneralTag.list': {'list': []},
          'SYNO.Foto.Browse.GeneralTag.suggest': {
            'list': [
              {'id': 1, 'name': 'huihubtag'},
            ],
          },
          'SYNO.Foto.Browse.Item.get_tag': {'intersection': []},
          'SYNO.Foto.Browse.Item.add_tag': {'error_list': []},
        },
      );
      await tester.longPress(find.byType(PhotoCell).first);
      await tester.pump();
      await tester.tap(find.byKey(const Key('photo-selection-tag')));
      await tester.pumpAndSettle();
      expect(find.text('还没有标签'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('photo-tag-search')), 'hui');
      await tester.pump(const Duration(milliseconds: 400)); // 过防抖
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-tag-1')), findsOneWidget);
      await tester.tap(find.byKey(const Key('photo-tag-1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('photo-tag-apply')));
      await tester.pumpAndSettle();
      final call = boot.t.calls.lastWhere((c) => c['method'] == 'add_tag');
      expect(jsonDecode(call['tag'] as String), [1]);
    });

    testWidgets('新建拿不到可解析标签 → 给失败提示（不再静默）', (tester) async {
      await pump(
        tester,
        responses: {
          'SYNO.Foto.Browse.GeneralTag.list': {'list': []},
          'SYNO.Foto.Browse.GeneralTag.suggest': {'list': []},
          'SYNO.Foto.Browse.GeneralTag.create': <String, dynamic>{},
          'SYNO.Foto.Browse.Item.get_tag': {'intersection': []},
        },
      );
      await tester.longPress(find.byType(PhotoCell).first);
      await tester.pump();
      await tester.tap(find.byKey(const Key('photo-selection-tag')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('photo-tag-search')), '空回');
      await tester.pump();
      await tester.tap(find.byKey(const Key('photo-tag-create')));
      await tester.pumpAndSettle();
      expect(find.textContaining('新建标签失败'), findsOneWidget);
    });

    // 真机踩坑回归：主题里 FilledButton 的 minimumSize 是 `Size.fromHeight(48)`
    // （全宽），而 Row 给非 flex 子项的是**无界宽度** → 渲染层直接报
    // "BoxConstraints forces an infinite width"；Release 下不报错，只是把
    // "已选 N 个标签" 挤成竖排、保存按钮飞出屏幕。这里用真机同尺寸的底部
    // 弹层（showModalBottomSheet + 真实主题）钉住修复。
    testWidgets('标签弹层在真机尺寸下不炸布局，保存按钮在屏幕内', (tester) async {
      tester.view.physicalSize = const Size(1148, 2492);
      tester.view.devicePixelRatio = 490 / 160; // HONOR LGE-AN10
      addTearDown(tester.view.reset);
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.GeneralTag.list': {'list': []},
        },
      );
      final api = await _loggedIn(t);
      final db = ChatDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          fotoApiProvider.overrideWithValue(FotoApi(api)),
        ],
      );
      addTearDown(db.close);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: Scaffold(
              body: Consumer(
                builder: (ctx, ref, _) => TextButton(
                  onPressed: () =>
                      showPhotoTagSheet(ctx, ref, itemIds: const ['1', '2']),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final apply = find.byKey(const Key('photo-tag-apply'));
      expect(apply, findsOneWidget);
      final rect = tester.getRect(apply);
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(rect.right, lessThanOrEqualTo(screen.width));
      expect(rect.left, greaterThan(0));
      // 计数文案必须是一行（真机上曾被挤成"竖排"）
      final count = tester.getRect(find.text('已选 0 个标签'));
      expect(count.width, greaterThan(80));
      expect(count.height, lessThan(40));
    });

    // ★ r412 DA70：这两条钉住"见过就记住"的**唯一两个时机**。
    // 这台 NAS 上 `GeneralTag/list` 恒空（现场原始码见
    // `docs/evidence-r412/nas/r412_probe_tags_persons.log`），标签浏览页只能靠
    // 这份本地记忆补台 ⇒ 不记 = "在弹层里搜得到、回标签页又没了"。
    testWidgets('r412 ① suggest 命中的标签被记进本机记忆', (tester) async {
      final prefs = _MemPrefs();
      final boot = await pump(
        tester,
        prefs: prefs,
        responses: {
          'SYNO.Foto.Browse.GeneralTag.list': {'list': []},
          'SYNO.Foto.Browse.GeneralTag.suggest': {
            'list': [
              {'id': 1, 'name': 'huihubtag'},
            ],
          },
          'SYNO.Foto.Browse.Item.get_tag': {'intersection': []},
        },
      );
      await tester.longPress(find.byType(PhotoCell).first);
      await tester.pump();
      await tester.tap(find.byKey(const Key('photo-selection-tag')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-tag-1')), findsNothing);

      await tester.enterText(find.byKey(const Key('photo-tag-search')), 'hui');
      await tester.pump(const Duration(milliseconds: 400)); // 过防抖
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-tag-1')), findsOneWidget);

      final seen = boot.c.read(photoSeenTagsProvider);
      expect(seen.length, 1);
      expect(seen.single.id, '1');
      expect(seen.single.name, 'huihubtag');
      expect(seen.single.space, 'personal');
      // 同时**真的落盘**了（冷启动才有意义）
      expect(prefs.data[kPhotoSeenTagsSlot], isNotNull);
    });

    testWidgets('r412 ② 新建成功返回的标签也被记进本机记忆', (tester) async {
      final prefs = _MemPrefs();
      final boot = await pump(
        tester,
        prefs: prefs,
        responses: {
          'SYNO.Foto.Browse.GeneralTag.list': {'list': []},
          'SYNO.Foto.Browse.GeneralTag.suggest': {'list': []},
          'SYNO.Foto.Browse.GeneralTag.create': {
            'tag': {'id': 5, 'name': '新标签'},
          },
          'SYNO.Foto.Browse.Item.get_tag': {'intersection': []},
        },
      );
      await tester.longPress(find.byType(PhotoCell).first);
      await tester.pump();
      await tester.tap(find.byKey(const Key('photo-selection-tag')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('photo-tag-search')), '新标签');
      await tester.pump();
      await tester.tap(find.byKey(const Key('photo-tag-create')));
      await tester.pumpAndSettle();

      final seen = boot.c.read(photoSeenTagsProvider);
      expect(seen.length, 1);
      expect(seen.single.id, '5');
      expect(seen.single.name, '新标签');
      // 新标签已经勾上（原有行为不许被这次改动碰坏）
      expect(find.byKey(const Key('photo-tag-5')), findsOneWidget);
    });
  });
}
