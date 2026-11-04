// 相册「最近添加」（`Browse.RecentlyAdded/list`）离线测试。
//
// 契约全部来自**权威证据**（见交付报告）：
//   * APK `ApiBrowseRecentlyAdded.java:21-38`：apiId `Browse.RecentlyAdded`、
//     method `list`、线参 `offset / limit / start_time / end_time / additional`；
//   * 真机只读探针（2026-09-22）：
//       - `list v1|v4|v6 {offset:0, limit:3}` → 真实数据（首条 `SVID_…mp4`）；
//       - `{limit:3}` → `120 {"name":"offset","reason":"required"}`（**offset 必需**）；
//       - `{offset:0}` → `120 {"name":"limit","reason":"required"}`（limit 必需）；
//       - `additional:["thumbnail"]`（JSON 串）→ 回包带 `additional.thumbnail`。
//
// 覆盖：接口层请求形状（名字动态前缀 = 个人/共享）、分页必需参数、
// provider 解析、hub 入口门控（能力位缺失 → 隐藏）。

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/photos/photo_c2_page.dart';
import 'package:synhub/src/features/photos/photo_c2_providers.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';
import 'package:synhub/src/features/photos/photo_recent_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _table = {
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
  'SYNO.Foto.Browse.RecentlyAdded': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 6,
  },
  'SYNO.FotoTeam.Browse.RecentlyAdded': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 6,
  },
};

/// 真机回包逐字（截取首条）：
/// `{"data":{"list":[{"filename":"SVID_20250606_193253_1.mp4","filesize":1876693,
///   "folder_id":1030,"id":9659,"indexed_time":1789950912936,
///   "owner_user_id":4,"time":1749238389,"type":"video"}, …]}}`
Map<String, dynamic> _recentReply() => {
  'list': [
    {
      'filename': 'SVID_20250606_193253_1.mp4',
      'filesize': 1876693,
      'folder_id': 1030,
      'id': 9659,
      'indexed_time': 1789950912936,
      'owner_user_id': 4,
      'time': 1749238389,
      'type': 'video',
    },
    {
      'filename': 'Screenshot_20250816_203226.jpg',
      'filesize': 89093,
      'folder_id': 1030,
      'id': 9658,
      'time': 1755376346,
      'type': 'photo',
    },
  ],
};

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

FakeTransport _transport({
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, dynamic>? Function(Map<String, dynamic> params)? onCall,
}) {
  final t = FakeTransport({...responses}, {...FakeTransport.table, ..._table});
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    if (key == 'SYNO.Foto.Setting.User.get') {
      return {
        'team_space_permission': 'none',
        'enable_person': true,
        'enable_similar': true,
      };
    }
    final custom = onCall?.call(params);
    if (custom != null) return custom;
    return responses[key] ?? const <String, dynamic>{};
  };
  return t;
}

Map<String, dynamic> _callOf(FakeTransport t, String api) =>
    t.calls.lastWhere((c) => c['api'] == api);

const _allApis = {
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
  kFotoRecentlyAddedApi,
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

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  Set<String> apis = _allApis,
}) async {
  final t = _transport(responses: responses);
  final api = await _loggedIn(t);
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fotoApiProvider.overrideWithValue(FotoApi(api)),
      serviceAvailabilityProvider.overrideWith(
        () => _FixedAvailability(_snap(apis)),
      ),
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

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('① 接口层：Browse.RecentlyAdded/list', () {
    test('个人空间：api 名走 SYNO.Foto. 前缀，version 协商到 6', () async {
      final t = _transport(
        responses: {'SYNO.Foto.Browse.RecentlyAdded.list': _recentReply()},
      );
      final api = await _loggedIn(t);
      final items = await FotoApi(api).recentlyAdded();

      final call = _callOf(t, 'SYNO.Foto.Browse.RecentlyAdded');
      expect(call['method'], 'list');
      // 能力表 maxVersion=6 → 协商出 6
      expect(call['version'], '6');
      // 两个**必需**参数恒定下发（真机缺一即 120）
      expect(call['offset'], '0');
      expect(call['limit'], '$kFotoRecentlyAddedPageSize');
      // additional 是 JSON 数组**字符串**。
      // ⚠️ 这里**不能**用 `jsonEncode(kFotoItemAdditional)`：那只是**基础键**，
      // 而实际下发要经过 `itemAdditional()` 的**能力位裁剪** —— 本用例的能力表
      // 把 rating(P40) 与 motion_photo(P13) 都打开了，所以真实请求多这两个键。
      // 钉住完整列表（严格等值），基础常量与裁剪逻辑各自另有断言覆盖。
      expect(
        call['additional'],
        '["thumbnail","favorite","gps","rating","motion_photo"]',
      );
      // 基础常量本身仍是"最小必备集"，两者不可混用。
      expect(kFotoItemAdditional, ['thumbnail', 'favorite', 'gps']);

      expect(items, hasLength(2));
      expect(items.first.id, '9659');
      expect(items.first.filename, 'SVID_20250606_193253_1.mp4');
      expect(items.first.isVideo, isTrue);
    });

    test('共享空间：api 名走 SYNO.FotoTeam. 前缀（动态拼名）', () async {
      final t = _transport(
        responses: {'SYNO.FotoTeam.Browse.RecentlyAdded.list': _recentReply()},
      );
      final api = await _loggedIn(t);
      final items = await FotoApi(
        api,
        space: FotoSpace.team,
      ).recentlyAdded(offset: 20, limit: 3);

      final call = _callOf(t, 'SYNO.FotoTeam.Browse.RecentlyAdded');
      expect(call['method'], 'list');
      expect(call['offset'], '20');
      expect(call['limit'], '3');
      expect(items, hasLength(2));
    });

    test('start_time / end_time 只有显式给了才发（epoch 秒）', () async {
      final t = _transport(
        responses: {'SYNO.Foto.Browse.RecentlyAdded.list': _recentReply()},
      );
      final api = await _loggedIn(t);
      await FotoApi(api).recentlyAdded(
        offset: 0,
        limit: 5,
        startTime: 1700000000,
        endTime: 1750000000,
      );
      final call = _callOf(t, 'SYNO.Foto.Browse.RecentlyAdded');
      expect(call['start_time'], '1700000000');
      expect(call['end_time'], '1750000000');

      // 不给就不发（默认无限界）
      await FotoApi(api).recentlyAdded();
      final plain = _callOf(t, 'SYNO.Foto.Browse.RecentlyAdded');
      expect(plain.containsKey('start_time'), isFalse);
      expect(plain.containsKey('end_time'), isFalse);
    });
  });

  group('② provider：photoRecentlyAddedProvider', () {
    test('解析出 FotoItemDto 列表', () async {
      final t = _transport(
        responses: {'SYNO.Foto.Browse.RecentlyAdded.list': _recentReply()},
      );
      final api = await _loggedIn(t);
      final c = ProviderContainer(
        overrides: [fotoApiProvider.overrideWithValue(FotoApi(api))],
      );
      addTearDown(c.dispose);
      final items = await c.read(photoRecentlyAddedProvider.future);
      expect(items.map((e) => e.id), ['9659', '9658']);
    });
  });

  group('③ hub 入口门控（能力位缺失 → 隐藏，且不发探测）', () {
    testWidgets('能力表缺 RecentlyAdded → 入口不出现', (tester) async {
      final r = await _pump(
        tester,
        const PhotoC2Page(),
        responses: {'SYNO.Foto.Browse.RecentlyAdded.list': _recentReply()},
        apis: {..._allApis}..remove(kFotoRecentlyAddedApi),
      );
      expect(find.byKey(const Key('photo-c2-entry-recent')), findsNothing);
      // 能力位缺失 → **连探测都不发**
      expect(r.t.calls.any((c) => c['api'] == kFotoRecentlyAddedApi), isFalse);
    });

    testWidgets('能力位在 → 入口出现，点开是「最近添加」页（网格，无内部 id）', (tester) async {
      final r = await _pump(
        tester,
        const PhotoC2Page(),
        responses: {'SYNO.Foto.Browse.RecentlyAdded.list': _recentReply()},
      );
      expect(find.byKey(const Key('photo-c2-entry-recent')), findsOneWidget);

      await tester.tap(find.byKey(const Key('photo-c2-entry-recent')));
      await _settle(tester);
      expect(find.byType(PhotoRecentlyAddedPage), findsOneWidget);
      expect(find.byKey(const Key('photo-c2-recent-grid')), findsOneWidget);
      // 内部 id（9659）**绝不上屏**
      expect(find.textContaining('9659'), findsNothing);
      expect(r.t.calls.any((c) => c['api'] == kFotoRecentlyAddedApi), isTrue);
    });
  });
}
