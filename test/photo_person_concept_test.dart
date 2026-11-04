// 相册「人物 / 场景」浏览离线测试（P2 阶段二 C 最后一块）。
//
// 覆盖：
//   * 接口层：`Browse.Person/list|count|get|get_migration_status`（v1）、
//     `Browse.Concept/list|count|get`（v2）、`Browse.Item/list` + `person_id` /
//     `concept_id`（v7）的**参数形态**（分页 offset/limit、show_hidden/show_more、
//     `additional`、数字数组 id），以及**共享空间**（`SYNO.FotoTeam.` 前缀）；
//   * DTO：人物 / 场景 / 迁移进度的解析，含**缺字段 / null / 空封面**；
//   * 页面层：人物段 / 场景段列表、未开启人脸/场景识别的**引导态**（且不发请求）、
//     空态、错误态（801 无权限 / 901 迁移未完成）、详情页网格与查看器入口。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/photos/photo_browse_page.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';
import 'package:synhub/src/features/photos/photo_widgets.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

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
  'SYNO.Foto.Thumbnail': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FotoTeam.Setting.User': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.FotoTeam.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 9,
  },
  'SYNO.FotoTeam.Browse.Person': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.FotoTeam.Browse.Concept': {
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
    'thumbnail': {'sm': 'sm_$id', 'cache_key': 'ck_$id'},
    'favorite': false,
  },
};

Map<String, dynamic> _person(
  String id,
  String name, {
  int count = 0,
  bool? show,
  Map<String, dynamic>? cover,
  Map<String, dynamic>? additional,
}) => {
  'id': id,
  'name': name,
  'item_count': count,
  if (show != null) 'show': show,
  if (cover != null) 'cover': cover,
  if (additional != null) 'additional': additional,
};

/// 场景/主题条目（与 `_person` 同形：`id` / `name` / `item_count` / `cover`）。
Map<String, dynamic> _concept(
  String id,
  String name, {
  int count = 0,
  Map<String, dynamic>? cover,
}) => {
  'id': id,
  'name': name,
  'item_count': count,
  if (cover != null) 'cover': cover,
};

/// 最后一次打到某个大 api 的调用。
///
/// `calls` 里还混着 `SYNO.API.Info` / `SYNO.API.Auth.login`，所以不能用 `.single`。
Map<String, dynamic> _lastFor(FakeTransport t, String api) =>
    t.calls.lastWhere((c) => c['api'] == api);

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

/// 只伪造相册接口的传输层；`byApi` 的键是 `api.method`。
FakeTransport _transport({
  Map<String, Map<String, dynamic>> byApi = const {},
  Map<String, int> failures = const {},
}) {
  final t = FakeTransport(const {}, {...FakeTransport.table, ..._fotoTable});
  t.downloadBytes = _png;
  t.onCall = (params) => byApi['${params['api']}.${params['method']}'];
  t.failures.addAll(failures);
  return t;
}

/// 挂相册页（可配置人物 / 场景开关）
Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester, {
  Map<String, Map<String, dynamic>> byApi = const {},
  Map<String, int> failures = const {},
  bool enablePerson = true,
  bool enableConcept = true,
  Widget? page,
}) async {
  final t = FakeTransport(const {}, {...FakeTransport.table, ..._fotoTable});
  t.downloadBytes = _png;
  t.onCall = (params) {
    final api = '${params['api']}';
    final method = '${params['method']}';
    if (api.endsWith('Setting.User') && method == 'get') {
      return {
        'team_space_permission': 'none',
        'enable_person': enablePerson,
        'enable_concept': enableConcept,
        'timeline_group_unit': 'day',
        'item_sort_by': 'takentime',
        'sort_direction': 'desc',
      };
    }
    return byApi['$api.$method'];
  };
  t.failures.addAll(failures);
  final api = await _loggedIn(t);
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fotoApiProvider.overrideWithValue(FotoApi(api)),
    ],
  );
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

/// 点分段控件切到某一段（懒构建：多给两帧让该段的请求落地）
Future<void> _openSection(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('人物接口', () {
    test('persons：Browse.Person/list v1 + 分页/show_more/show_hidden', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Browse.Person.list': {
            'list': [_person('7', '小明', count: 12), _person('8', '', count: 0)],
            'total': 2,
          },
        },
      );
      final api = await _loggedIn(t);
      final people = await FotoApi(api).persons();

      expect(people.length, 2);
      expect(people.first.name, '小明');
      expect(people.first.itemCount, 12);
      final call = _lastFor(t, 'SYNO.Foto.Browse.Person');
      expect(call['api'], 'SYNO.Foto.Browse.Person');
      expect(call['method'], 'list');
      expect(call['version'], '1', reason: '官方前端把 list 钉死在 v1');
      expect(call['offset'], '0');
      expect(call['limit'], '100', reason: 'AUTO_SMART_ALBUM = 100');
      expect(call['show_more'], 'false');
      expect(call['show_hidden'], 'false');
      expect(call['additional'], '["thumbnail"]');
    });

    test('persons：offset/limit/showHidden/showMore 原样透传', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Browse.Person.list': {'list': const []},
        },
      );
      final api = await _loggedIn(t);
      await FotoApi(
        api,
      ).persons(offset: 100, limit: 50, showHidden: true, showMore: true);
      final call = _lastFor(t, 'SYNO.Foto.Browse.Person');
      expect(call['offset'], '100');
      expect(call['limit'], '50');
      expect(call['show_hidden'], 'true');
      expect(call['show_more'], 'true');
    });

    test('personMigrationStatus：无参 v1 → status/completion/total', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Browse.Person.get_migration_status': {
            'status': 'migrating',
            'completion': 3,
            'total': 10,
          },
        },
      );
      final api = await _loggedIn(t);
      final m = await FotoApi(api).personMigrationStatus();
      expect(m.status, 'migrating');
      expect(m.completion, 3);
      expect(m.total, 10);
      expect(m.hasProgress, isTrue);
      expect(m.ratio, closeTo(0.3, 1e-9));
      final call = _lastFor(t, 'SYNO.Foto.Browse.Person');
      expect(call['method'], 'get_migration_status');
      expect(call['version'], '1');
    });

    test('personMigrationStatus：103（方法不存在）→ 空进度，不抛', () async {
      final t = _transport(
        failures: {'SYNO.Foto.Browse.Person.get_migration_status': 103},
      );
      final api = await _loggedIn(t);
      final m = await FotoApi(api).personMigrationStatus();
      expect(m.hasProgress, isFalse);
      expect(m.status, '');
    });

    test('personItems：Browse.Item/list v7 + person_id（分页）', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Browse.Item.list': {
            'list': [_item('1'), _item('2')],
            'total': 2,
          },
        },
      );
      final api = await _loggedIn(t);
      final items = await FotoApi(api).personItems('7', offset: 20, limit: 10);
      expect(items.length, 2);
      final call = _lastFor(t, 'SYNO.Foto.Browse.Item');
      expect(call['api'], 'SYNO.Foto.Browse.Item');
      expect(call['version'], '7');
      expect(call['person_id'], '7');
      expect(call['offset'], '20');
      expect(call['limit'], '10');
      expect(call['additional'], contains('thumbnail'));
      expect(call.containsKey('concept_id'), isFalse);
    });
  });

  group('场景接口', () {
    test('concepts：Browse.Concept/list v2（没有 show_more）', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Browse.Concept.list': {
            'list': [
              {
                'id': '3',
                'name': '海滩',
                'item_count': 9,
                'show': true,
                'type': 'concept',
              },
            ],
            'total': 1,
          },
        },
      );
      final api = await _loggedIn(t);
      final concepts = await FotoApi(api).concepts();
      expect(concepts.single.name, '海滩');
      expect(concepts.single.itemCount, 9);
      final call = _lastFor(t, 'SYNO.Foto.Browse.Concept');
      expect(call['api'], 'SYNO.Foto.Browse.Concept');
      expect(call['version'], '2', reason: '官方前端把 Concept 的读方法钉死在 v2');
      expect(call['show_hidden'], 'false');
      expect(call.containsKey('show_more'), isFalse);
      expect(call['additional'], '["thumbnail"]');
    });

    test('conceptItems：Browse.Item/list v7 + concept_id', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Browse.Item.list': {
            'list': [_item('5')],
            'total': 1,
          },
        },
      );
      final api = await _loggedIn(t);
      final items = await FotoApi(api).conceptItems('3');
      expect(items.single.id, '5');
      final call = _lastFor(t, 'SYNO.Foto.Browse.Item');
      expect(call['concept_id'], '3');
      expect(call['version'], '7');
      expect(call.containsKey('person_id'), isFalse);
    });
  });

  group('P18 可见性（UI）', () {
    testWidgets('点眼睛 → Person/show v1，id 数组 + 取反后的 show', (tester) async {
      final boot = await _pump(
        tester,
        byApi: {
          'SYNO.Foto.Browse.Person.list': {
            'list': [
              _person('7', '小明', count: 12),
              _person('8', '小红', count: 3, show: false),
            ],
            'total': 2,
          },
          'SYNO.Foto.Browse.Person.show': <String, dynamic>{},
        },
      );
      await _openSection(tester, '人物');
      // 可见的人 → 点一下变"隐藏"（show=false）
      await tester.tap(find.byKey(const Key('photo-person-visibility-7')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      var call = boot.t.calls.lastWhere((c) => c['method'] == 'show');
      expect(call['api'], 'SYNO.Foto.Browse.Person');
      expect(call['version'], '1');
      expect(jsonDecode(call['id'] as String), [7]);
      expect(call['show'], 'false');

      // 已隐藏的人 → 点一下变"显示"
      await tester.tap(find.byKey(const Key('photo-person-visibility-8')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      call = boot.t.calls.lastWhere((c) => c['method'] == 'show');
      expect(jsonDecode(call['id'] as String), [8]);
      expect(call['show'], 'true');
    });

    testWidgets('写失败（105）→ 明确提示，不装作成功', (tester) async {
      await _pump(
        tester,
        byApi: {
          'SYNO.Foto.Browse.Person.list': {
            'list': [_person('7', '小明', count: 12)],
            'total': 1,
          },
        },
        failures: {'SYNO.Foto.Browse.Person.show': 105},
      );
      await _openSection(tester, '人物');
      await tester.tap(find.byKey(const Key('photo-person-visibility-7')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SnackBar), findsOneWidget);
    });
  });

  group('P18 合并（UI）', () {
    testWidgets('人物详情 → 选目标 → 确认：Person/merge v2（target_id + merged_id 数组）', (
      tester,
    ) async {
      final boot = await _pump(
        tester,
        byApi: {
          'SYNO.Foto.Browse.Person.list': {
            'list': [
              _person('7', '小明', count: 12),
              _person('8', '小红', count: 3),
            ],
            'total': 2,
          },
          'SYNO.Foto.Browse.Person.get': {
            'list': [_person('7', '小明', count: 12)],
          },
          'SYNO.Foto.Browse.Item.list': {'list': [_item('11')]},
          'SYNO.Foto.Browse.Person.merge': <String, dynamic>{},
        },
      );
      await _openSection(tester, '人物');
      await tester.tap(find.text('小明'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byKey(const Key('photo-person-merge')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('photo-person-merge-picker')), findsOneWidget);
      // 目标列表里**不该出现自己**
      expect(find.byKey(const Key('photo-person-merge-target-7')), findsNothing);
      await tester.tap(find.byKey(const Key('photo-person-merge-target-8')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byKey(const Key('photo-person-merge-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final call = boot.t.calls.lastWhere((c) => c['method'] == 'merge');
      expect(call['api'], 'SYNO.Foto.Browse.Person');
      expect(call['version'], '2');
      expect(call['target_id'], '8');
      expect(jsonDecode(call['merged_id'] as String), [7]);
    });

    testWidgets('合并确认里点取消 ⇒ 零请求', (tester) async {
      final boot = await _pump(
        tester,
        byApi: {
          'SYNO.Foto.Browse.Person.list': {
            'list': [
              _person('7', '小明', count: 12),
              _person('8', '小红', count: 3),
            ],
            'total': 2,
          },
          'SYNO.Foto.Browse.Person.get': {
            'list': [_person('7', '小明', count: 12)],
          },
          'SYNO.Foto.Browse.Item.list': {'list': [_item('11')]},
        },
      );
      await _openSection(tester, '人物');
      await tester.tap(find.text('小明'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('photo-person-merge')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('photo-person-merge-target-8')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('photo-person-merge-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        boot.t.calls.any((c) => c['method'] == 'merge'),
        isFalse,
        reason: '取消 = 一个请求都不发',
      );
    });
  });

  group('P18/P19 智能相册写操作（UI）', () {
    testWidgets('P18 人物改名：确认 → Person/set（id+name）；取消 → 零请求', (tester) async {
      final boot = await _pump(
        tester,
        page: const PhotoSmartAlbumPage(
          kind: PhotoSmartAlbumKind.person,
          id: '7',
          title: '小明',
        ),
        byApi: {
          'SYNO.Foto.Browse.Person.get': {
            'list': [_person('7', '小明', count: 12)],
          },
          'SYNO.Foto.Browse.Item.list': {'list': [_item('11'), _item('12')]},
          'SYNO.Foto.Browse.Person.set': <String, dynamic>{},
        },
      );
      expect(find.byKey(const Key('photo-person-rename')), findsOneWidget);

      // ① 取消 → 一个写请求都不发
      await tester.tap(find.byKey(const Key('photo-person-rename')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(
        find.byKey(const Key('photo-person-rename-field')),
        '小红',
      );
      await tester.tap(find.byKey(const Key('photo-person-rename-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        boot.t.calls.any((c) => c['method'] == 'set'),
        isFalse,
        reason: '取消 = 零请求',
      );

      // ② 改名并保存 → Person/set，字段 id + name 逐字对齐官方 smali
      await tester.tap(find.byKey(const Key('photo-person-rename')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(
        find.byKey(const Key('photo-person-rename-field')),
        '小红',
      );
      await tester.tap(find.byKey(const Key('photo-person-rename-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final call = boot.t.calls.lastWhere((c) => c['method'] == 'set');
      expect(call['api'], 'SYNO.Foto.Browse.Person');
      expect(call['id'], '7');
      expect(call['name'], '小红');
    });

    testWidgets('P19 概念：多选 → 「从该场景移除」取消零请求 / 确认逐张 hide_item', (
      tester,
    ) async {
      final boot = await _pump(
        tester,
        page: const PhotoSmartAlbumPage(
          kind: PhotoSmartAlbumKind.concept,
          id: '5',
          title: '海边',
        ),
        byApi: {
          'SYNO.Foto.Browse.Concept.get': {
            'list': [_concept('5', '海边', count: 2)],
          },
          'SYNO.Foto.Browse.Item.list': {'list': [_item('11'), _item('12')]},
          'SYNO.Foto.Browse.Concept.hide_item': <String, dynamic>{},
        },
      );
      // 长按进多选
      await tester.longPress(find.byType(PhotoThumb).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const Key('photo-selection-remove-smart')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('photo-selection-set-cover')), findsOneWidget);

      // 取消 → 零请求
      await tester.tap(find.byKey(const Key('photo-selection-remove-smart')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('photo-smart-remove-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        boot.t.calls.any((c) => c['method'] == 'hide_item'),
        isFalse,
        reason: '取消 = 零请求',
      );

      // 确认 → Concept/hide_item，字段 id + item_id
      await tester.tap(find.byKey(const Key('photo-selection-remove-smart')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('photo-smart-remove-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      final call = boot.t.calls.lastWhere(
        (c) => c['method'] == 'hide_item',
      );
      expect(call['api'], 'SYNO.Foto.Browse.Concept');
      expect(call['id'], '5');
      expect(call['item_id'], isNotNull);
    });
  });

  group('共享空间（team 前缀）', () {
    test('persons / concepts / personItems 都换成 SYNO.FotoTeam.', () async {
      final t = _transport(
        byApi: {
          'SYNO.FotoTeam.Browse.Person.list': {'list': const []},
          'SYNO.FotoTeam.Browse.Concept.list': {'list': const []},
          'SYNO.FotoTeam.Browse.Item.list': {'list': const []},
        },
      );
      final api = await _loggedIn(t);
      final team = FotoApi(api, space: FotoSpace.team);
      await team.persons();
      await team.concepts();
      await team.personItems('7');
      final apis = t.calls
          .map((c) => '${c['api']}')
          .where((a) => a.startsWith('SYNO.Foto'))
          .toList();
      expect(apis, [
        'SYNO.FotoTeam.Browse.Person',
        'SYNO.FotoTeam.Browse.Concept',
        'SYNO.FotoTeam.Browse.Item',
      ]);
    });
  });

  group('人物 / 场景 DTO', () {
    test('FotoPersonDto：完整字段 + additional.thumbnail 封面', () {
      final p = FotoPersonDto.fromJson({
        'id': 7,
        'name': '小明',
        'item_count': 12,
        'show': true,
        'type': 'person',
        'additional': {
          'thumbnail': {'unit_id': 99, 'cache_key': 'ck'},
        },
      });
      expect(p.id, '7');
      expect(p.name, '小明');
      expect(p.itemCount, 12);
      expect(p.show, isTrue);
      expect(p.type, 'person');
      expect(p.cover?.unitId, '99');
      expect(p.cover?.cacheKey, 'ck');
    });

    test('FotoPersonDto：缺字段 / null → 安全默认', () {
      final p = FotoPersonDto.fromJson({'id': null, 'name': null});
      expect(p.id, '');
      expect(p.name, '');
      expect(p.itemCount, 0);
      expect(p.show, isTrue, reason: '没给 show 当"可见"');
      expect(p.type, 'person');
      expect(p.cover, isNull);
      expect(FotoPersonDto.fromJson({'id': '1', 'show': false}).show, isFalse);
    });

    test('封面：顶层 cover 优先；List 取第一张；空 Map → null', () {
      final fromList = FotoPersonDto.fromJson({
        'id': '1',
        'cover': [
          {'unit_id': 'u1', 'cache_key': 'k1'},
        ],
      });
      expect(fromList.cover?.unitId, 'u1');
      final empty = FotoPersonDto.fromJson({
        'id': '2',
        'cover': {},
        'additional': {
          'thumbnail': {'unit_id': 'u2'},
        },
      });
      expect(empty.cover?.unitId, 'u2', reason: '空 cover 不算封面，退回 thumbnail');
    });

    test('FotoConceptDto：null / 缺字段 + 封面 List', () {
      final c = FotoConceptDto.fromJson({
        'id': 3,
        'name': '海滩',
        'item_count': '9',
        'additional': {
          'thumbnail': [
            {'sm': 'ready', 'cache_key': 'ck'},
          ],
        },
      });
      expect(c.id, '3');
      expect(c.itemCount, 9);
      expect(c.type, 'concept');
      expect(c.cover?.sm, 'ready');
      final empty = FotoConceptDto.fromJson({});
      expect(empty.name, '');
      expect(empty.show, isTrue);
      expect(empty.cover, isNull);
    });

    test('FotoPersonMigrationDto：进度比值夹在 0..1', () {
      final m = FotoPersonMigrationDto.fromJson({
        'status': 'migrating',
        'completion': 3,
        'total': 10,
      });
      expect(m.ratio, closeTo(0.3, 1e-9));
      expect(FotoPersonMigrationDto.fromJson({'completion': 5}).ratio, 0);
      expect(
        FotoPersonMigrationDto.fromJson({'completion': 20, 'total': 10}).ratio,
        1.0,
      );
    });
  });

  group('智能相册封面请求', () {
    test('有 unit_id → type=unit + id=unit_id', () {
      // `sm: 'ready'` 是"缩略图就绪"的真实状态值；本文件下方 748-756 行已钉死
      // "非 ready（`sm: 'broken'`）→ null"。旧写法只给 unit_id、不给就绪态，
      // 属于"假就绪"，与真机语义不符（`docs/thumbnail-apis.md` §1.8）。
      final req = photoSmartAlbumCoverRequest(
        const FotoThumbDto(sm: 'ready', unitId: 'u1', cacheKey: 'ck'),
        FotoSpace.personal,
        type: 'person',
        id: '7',
      );
      expect(req, isNotNull);
      expect(req!.thumbType, 'unit');
      expect(req.itemId, 'u1');
    });

    test('只有 sm 状态 → type=实体类型 + id=实体 id', () {
      final req = photoSmartAlbumCoverRequest(
        const FotoThumbDto(sm: 'ready', cacheKey: 'ck'),
        FotoSpace.personal,
        type: 'concept',
        id: '3',
      );
      expect(req!.thumbType, 'concept');
      expect(req.itemId, '3');
    });

    test('没有封面 / 拿不到任何档位 → null（不发必然报错的请求）', () {
      expect(
        photoSmartAlbumCoverRequest(
          null,
          FotoSpace.personal,
          type: 'person',
          id: '7',
        ),
        isNull,
      );
      expect(
        photoSmartAlbumCoverRequest(
          const FotoThumbDto(sm: 'broken'),
          FotoSpace.personal,
          type: 'person',
          id: '7',
        ),
        isNull,
      );
    });
  });

  group('人物段页面', () {
    testWidgets('列出人物 + 计数；请求带分页与 show_more', (tester) async {
      final boot = await _pump(
        tester,
        byApi: {
          'SYNO.Foto.Browse.Person.list': {
            'list': [_person('7', '小明', count: 12), _person('8', '', count: 3)],
            'total': 2,
          },
        },
      );
      await _openSection(tester, '人物');

      expect(find.text('小明'), findsOneWidget);
      expect(find.text('未命名人物'), findsOneWidget, reason: '空名字回落');
      expect(find.text('12 张照片'), findsOneWidget);
      final call = boot.t.calls.firstWhere(
        (c) => c['api'] == 'SYNO.Foto.Browse.Person',
      );
      expect(call['method'], 'list');
      expect(call['offset'], '0');
      expect(call['limit'], '100');
    });

    testWidgets('列表为空 → 空态（不发第二次 show_more 也算过）', (tester) async {
      await _pump(
        tester,
        byApi: {
          'SYNO.Foto.Browse.Person.list': {'list': const []},
        },
      );
      await _openSection(tester, '人物');
      expect(find.text('还没有识别到人物'), findsOneWidget);
    });

    testWidgets('未开启人脸识别 → 引导态，且**不发** Person/list 请求', (tester) async {
      final boot = await _pump(tester, enablePerson: false);
      await _openSection(tester, '人物');
      expect(find.text('未开启人脸识别'), findsOneWidget);
      expect(
        boot.t.calls.any((c) => '${c['api']}'.contains('Browse.Person')),
        isFalse,
        reason: '官方前端也是先过 enable_person 这道门，不发必然空的请求',
      );
    });

    testWidgets('801 无权限 → 错误态说人话 + 可重试', (tester) async {
      await _pump(tester, failures: {'SYNO.Foto.Browse.Person.list': 801});
      await _openSection(tester, '人物');
      expect(find.textContaining('没有这个空间的权限'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('901（迁移未完成）→ "正在整理"文案，不是通用报错', (tester) async {
      await _pump(tester, failures: {'SYNO.Foto.Browse.Person.list': 901});
      await _openSection(tester, '人物');
      expect(find.textContaining('人脸识别'), findsWidgets);
      expect(find.textContaining('没有这个空间的权限'), findsNothing);
    });

    testWidgets('901 + 有迁移进度 → 文案带"已整理 N%"（接线 get_migration_status）', (
      tester,
    ) async {
      await _pump(
        tester,
        failures: {'SYNO.Foto.Browse.Person.list': 901},
        byApi: {
          'SYNO.Foto.Browse.Person.get_migration_status': {
            'status': 'migrating',
            'completion': 42,
            'total': 100,
          },
        },
      );
      await _openSection(tester, '人物');
      // 901 态落地后才 watch 迁移进度 → 多给几拍让它 resolve
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.textContaining('已整理 42%'), findsOneWidget);
    });

    testWidgets('901 + 拿不到进度 → 退回纯"整理中"文案，不谎报数字', (tester) async {
      await _pump(tester, failures: {'SYNO.Foto.Browse.Person.list': 901});
      await _openSection(tester, '人物');
      expect(find.textContaining('已整理'), findsNothing);
      expect(find.textContaining('人脸识别'), findsWidgets);
    });

    testWidgets('点人物 → 详情页走 Browse.Item/list + person_id', (tester) async {
      final boot = await _pump(
        tester,
        byApi: {
          'SYNO.Foto.Browse.Person.list': {
            'list': [_person('7', '小明', count: 3)],
            'total': 1,
          },
          'SYNO.Foto.Browse.Item.list': {
            'list': [_item('1'), _item('2')],
            'total': 2,
          },
        },
      );
      await _openSection(tester, '人物');
      await tester.tap(find.text('小明'));
      await tester.pumpAndSettle();

      expect(find.byType(PhotoSmartAlbumPage), findsOneWidget);
      final call = boot.t.calls.firstWhere(
        (c) => c['api'] == 'SYNO.Foto.Browse.Item' && c['person_id'] != null,
      );
      expect(call['person_id'], '7');
      expect(call['version'], '7');
    });

    testWidgets('人物详情为空 → 专属空态', (tester) async {
      await _pump(
        tester,
        byApi: {
          'SYNO.Foto.Browse.Person.list': {
            'list': [_person('7', '小明', count: 0)],
            'total': 1,
          },
          'SYNO.Foto.Browse.Item.list': {'list': const []},
        },
      );
      await _openSection(tester, '人物');
      await tester.tap(find.text('小明'));
      await tester.pumpAndSettle();
      expect(find.text('这个人名下还没有照片'), findsOneWidget);
    });
  });

  group('场景段页面', () {
    testWidgets('列出场景 + 计数；详情走 concept_id', (tester) async {
      final boot = await _pump(
        tester,
        byApi: {
          'SYNO.Foto.Browse.Concept.list': {
            'list': [
              {'id': '3', 'name': '海滩', 'item_count': 9, 'type': 'concept'},
            ],
            'total': 1,
          },
          'SYNO.Foto.Browse.Item.list': {
            'list': [_item('1')],
            'total': 1,
          },
        },
      );
      await _openSection(tester, '场景');
      expect(find.text('海滩'), findsOneWidget);
      expect(find.text('9 张照片'), findsOneWidget);

      await tester.tap(find.text('海滩'));
      await tester.pumpAndSettle();
      expect(find.byType(PhotoSmartAlbumPage), findsOneWidget);
      final call = boot.t.calls.firstWhere(
        (c) => c['api'] == 'SYNO.Foto.Browse.Item' && c['concept_id'] != null,
      );
      expect(call['concept_id'], '3');
    });

    testWidgets('未开启场景识别 → 引导态', (tester) async {
      await _pump(tester, enableConcept: false);
      await _openSection(tester, '场景');
      expect(find.text('未开启场景识别'), findsOneWidget);
    });

    testWidgets('场景空列表 → 空态', (tester) async {
      await _pump(
        tester,
        byApi: {
          'SYNO.Foto.Browse.Concept.list': {'list': const []},
        },
      );
      await _openSection(tester, '场景');
      expect(find.text('还没有识别到场景'), findsOneWidget);
    });

    testWidgets('场景接口 102（没装）→ 说人话', (tester) async {
      await _pump(tester, failures: {'SYNO.Foto.Browse.Concept.list': 102});
      await _openSection(tester, '场景');
      expect(find.textContaining('没有安装 Synology Photos'), findsOneWidget);
    });
  });
}
