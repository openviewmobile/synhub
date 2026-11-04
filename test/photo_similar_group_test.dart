// P17：相似堆叠分组写操作面板的离线用例（分组 id 取证自官方 `SimilarVo.id`）。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/foto_c2_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/photos/photo_c2_providers.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';
import 'package:synhub/src/features/photos/photo_similar_group.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _png = <int>[137, 80, 78, 71];

Map<String, dynamic> _row(
  String groupId,
  String itemId, {
  int count = 2,
  String? topPick,
}) => {
  'id': groupId,
  'count': count,
  'item_id': itemId,
  // 真实响应里同组每一行的 `top_pick` 都一样；这里允许显式指定
  'top_pick': topPick ?? itemId,
  'filename': 'IMG_$itemId.jpg',
  'type': 'photo',
  'additional': {
    'thumbnail': {'sm': 'sm_$itemId', 'cache_key': 'ck_$itemId'},
  },
};

const _photoTable = <String, Map<String, dynamic>>{
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
  'SYNO.Foto.Setting.User': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

Future<({FakeTransport t, ProviderContainer c})> _boot({
  Map<String, Map<String, dynamic>> byApi = const {},
  bool withTimelineApi = true,
}) async {
  final Map<String, Map<String, dynamic>> table = {
    ...FakeTransport.table,
    ..._photoTable,
    if (!withTimelineApi) ...{} ,
  };
  if (!withTimelineApi) table.remove('SYNO.Foto.Browse.SimilarTimeline');
  final t = FakeTransport(const {}, table);
  t.downloadBytes = _png;
  t.onCall = (params) => byApi['${params['api']}.${params['method']}'];
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final foto = FotoApi(api);
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fotoApiProvider.overrideWithValue(foto),
      fotoC2ApiProvider.overrideWithValue(FotoC2Api(foto)),
    ],
  );
  return (t: t, c: c);
}

Widget _host(FotoSimilarGroupDto group) => MaterialApp(theme: AppTheme.dark(), 
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => showPhotoSimilarGroupSheet(context, group),
        child: const Text('open'),
      ),
    ),
  ),
);

FotoSimilarGroupDto _group() => FotoSimilarGroupDto(
  id: '77',
  count: 2,
  topPickId: '102',
  // 注意：解析器已把行内的 `id`（分组 id）换成 `item_id`，手工构造要对齐
  items: [
    FotoItemDto.fromJson({..._row('77', '101'), 'id': '101'}),
    FotoItemDto.fromJson({..._row('77', '102'), 'id': '102'}),
  ],
);

void main() {
  group('P17 分组 provider', () {
    test('Timeline 响应按 id 聚合：image id 取 item_id，封面取 top_pick', () async {
      final boot = await _boot(
        byApi: {
          'SYNO.Foto.Browse.SimilarTimeline.get_similar': {
            'list': [
              _row('77', '101', topPick: '102'),
              _row('77', '102', topPick: '102'),
            ],
          },
        },
      );
      addTearDown(boot.c.dispose);
      final groups = await boot.c.read(
        photoSimilarGroupsProvider(200).future,
      );
      expect(groups.single.id, '77');
      expect(groups.single.itemIds, ['101', '102']);
      expect(groups.single.count, 2);
      expect(groups.single.cover!.id, '102');
      expect(groups.single.isActionable, isTrue);
      final call = boot.t.calls.firstWhere(
        (c) => c['method'] == 'get_similar',
      );
      expect(call['api'], 'SYNO.Foto.Browse.SimilarTimeline');
      expect(call['version'], '2');
    });

    test('没有分组 id（回落路径）⇒ 不可操作，不编造 group id', () async {
      final boot = await _boot(
        byApi: {
          'SYNO.Foto.Browse.SimilarItem.list': {
            'list': [
              {'id': 11, 'filename': 'a.jpg'},
              {'id': 12, 'filename': 'b.jpg'},
            ],
          },
        },
        withTimelineApi: false,
      );
      addTearDown(boot.c.dispose);
      final groups = await boot.c.read(
        photoSimilarGroupsProvider(200).future,
      );
      expect(groups, hasLength(2));
      expect(groups.every((g) => !g.isActionable), isTrue);
      expect(groups.every((g) => g.id.isEmpty), isTrue);
    });
  });

  group('P17 堆叠面板（UI）', () {
    testWidgets('点某一张 → similarSetTopPick：id 是分组 id、item_id 是那张', (tester) async {
      final boot = await _boot(
        byApi: {'SYNO.Foto.Browse.Similar.set_top_pick': <String, dynamic>{}},
      );
      addTearDown(boot.c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(container: boot.c, child: _host(_group())),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('photo-similar-group-sheet')), findsOneWidget);
      expect(find.byKey(const Key('photo-similar-member-101')), findsOneWidget);
      expect(find.byKey(const Key('photo-similar-member-102')), findsOneWidget);

      await tester.tap(find.byKey(const Key('photo-similar-member-101')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final call = boot.t.calls.lastWhere(
        (c) => c['method'] == 'set_top_pick',
      );
      expect(call['api'], 'SYNO.Foto.Browse.Similar');
      expect(call['id'], '77');
      expect(call['item_id'], '101');
    });

    testWidgets('× → 确认 → similarRemoveItem；取消 ⇒ 零请求', (tester) async {
      final boot = await _boot(
        byApi: {'SYNO.Foto.Browse.Similar.remove_item': <String, dynamic>{}},
      );
      addTearDown(boot.c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(container: boot.c, child: _host(_group())),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 先取消一次
      await tester.tap(find.byKey(const Key('photo-similar-remove-101')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('photo-similar-group-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        boot.t.calls.any((c) => c['method'] == 'remove_item'),
        isFalse,
        reason: '取消 = 一个请求都不发',
      );

      // 再来一次，这次确认
      await tester.tap(find.byKey(const Key('photo-similar-remove-101')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('photo-similar-group-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final call = boot.t.calls.lastWhere((c) => c['method'] == 'remove_item');
      expect(call['id'], '77');
      expect(call['item_id'], '101');
    });

    testWidgets('解散堆叠 → similarUngroup（只发 id）；确认框取消 ⇒ 零请求', (tester) async {
      final boot = await _boot(
        byApi: {'SYNO.Foto.Browse.Similar.ungroup': <String, dynamic>{}},
      );
      addTearDown(boot.c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(container: boot.c, child: _host(_group())),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('photo-similar-ungroup')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('photo-similar-group-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final call = boot.t.calls.lastWhere((c) => c['method'] == 'ungroup');
      expect(call['id'], '77');
      expect(call.containsKey('item_id'), isFalse);
    });

    testWidgets('不可操作的组（无分组 id）⇒ 面板只读，一个写请求都没有', (tester) async {
      final boot = await _boot();
      addTearDown(boot.c.dispose);
      final readonly = FotoSimilarGroupDto(
        id: '',
        count: 1,
        topPickId: '11',
        items: [FotoItemDto.fromJson({'id': 11, 'filename': 'a.jpg'})],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(container: boot.c, child: _host(readonly)),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('photo-similar-ungroup')), findsNothing);
      expect(find.byKey(const Key('photo-similar-remove-11')), findsNothing);
      await tester.tap(find.byKey(const Key('photo-similar-member-11')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        boot.t.calls.any(
          (c) =>
              c['method'] == 'set_top_pick' ||
              c['method'] == 'remove_item' ||
              c['method'] == 'ungroup',
        ),
        isFalse,
      );
    });
  });
}
