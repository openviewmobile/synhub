// NoteStation **N4（位置 / 地理标签）** 离线套件。
//
// 证据（逐字）：
//   * 写：`Note/set` 发 `latitude`/`longitude`（Gson→JSON **数字**，非 null 就发）
//     + `location`（**非空才发**）—— APK
//     `callables/operations/SetNoteOperation.java:233-244`；回包字段同名
//     `vos/api/NoteVo.java:41-44`；官方 Web `setNote` 白名单
//     `…latitude,longitude,location,…`。
//   * 查：`SYNO.NoteStation.Info` **v1** `searchplace`，线参
//     `{format:true, radius:500, location:"<lat>,<lng>", query:"<关键字>"}`
//     —— 官方 Web `Map.Panel.getSearchStore`/`beforeload`；方法表出处
//     SPK `webapi/SYNO.NoteStation.lib`（v1/v2/v3 都含 `searchplace`）；
//     真机只读探针非空合法 `location` → `{"data":[],"success":true}`。
//   * 显：官方 `getLocationDisplayText` 的三分支（Web `ui/notestation.js`）。
//
// ★ 四个必测反例（红 → 原字节还原 → sha256 一致 → 绿）见本批报告 §5。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/data/region/device_location.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/notes/note_info_sheet.dart';
import 'package:synhub/src/features/notes/note_location.dart';
import 'package:synhub/src/features/notes/note_location_sheet.dart';
import 'package:synhub/src/features/notes/note_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

const String kInfoApi = 'SYNO.NoteStation.Info';
const String kNoteApi = 'SYNO.NoteStation.Note';

const _noteTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  kNoteApi: {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 4},
  'SYNO.NoteStation.Notebook': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  kInfoApi: {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 3},
};

Map<String, dynamic> _callOf(FakeTransport t, String api, String method) =>
    t.calls.lastWhere((c) => c['api'] == api && c['method'] == method);

List<Map<String, dynamic>> _callsOf(
  FakeTransport t,
  String api,
  String method,
) => t.calls.where((c) => c['api'] == api && c['method'] == method).toList();

/// `FakeTransport` 只会把回包包成 `{success:true,data:<Map>}`；而 `searchplace`
/// 的 `data` 在真机上是**裸数组**（`{"data":[],"success":true}`）。
/// 这里只把这条 API 覆写成"list 形态"，其余仍走 harness 的假传输
/// （**不改 `test/support/chat_harness.dart`**，避免影响并行批次）。
class _ListTransport extends FakeTransport {
  _ListTransport([super.responses, super.apiTable]);

  /// (api, method) → 该次回包的 `data` 是数组
  final Map<String, List<Map<String, dynamic>>> listData = {};

  @override
  Future<String> postForm(
    String path,
    Map<String, dynamic> params, {
    String? module,
  }) {
    final list = listData['${params['api']}.${params['method']}'];
    if (list == null) return super.postForm(path, params);
    calls.add(Map<String, dynamic>.from(params));
    return Future<String>.value(jsonEncode({'success': true, 'data': list}));
  }
}

Future<({_ListTransport t, NoteStationApi notes})> _apiBoot([
  Map<String, Map<String, dynamic>> responses = const {},
]) async {
  final t = _ListTransport(responses, {...FakeTransport.table, ..._noteTable});
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (t: t, notes: NoteStationApi(api));
}

// ---------------------------------------------------------------- UI 装配

ServiceAvailabilitySnapshot _snap(Set<String> apis) =>
    ServiceAvailabilitySnapshot(
      states: {
        for (final s in StationService.values) s: AvailabilityState.available,
      },
      apis: apis,
      checkedAt: DateTime(2026, 1, 1),
    );

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);

  final ServiceAvailabilitySnapshot snapshot;

  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

/// 假的设备定位探针（能钉死"没权限/没能力时不伪造位置"）。
class _FakeProbe implements DeviceLocationProbe {
  _FakeProbe({this.permission = LocationPermission.unsupported, this.fix});

  LocationPermission permission;
  DeviceLocation? fix;
  bool interactiveAsked = false;

  @override
  Future<LocationPermission> ensurePermission({bool interactive = true}) async {
    if (interactive) interactiveAsked = true;
    return permission;
  }

  @override
  Future<bool> serviceEnabled() async => true;

  @override
  Future<DeviceLocation?> current() async => fix;

  @override
  Future<void> clearCache() async {}
}

Future<({_ListTransport t, ProviderContainer c})> _uiBoot(
  Map<String, Map<String, dynamic>> responses, {
  Set<String>? apis,
  DeviceLocationProbe? probe,
  Map<String, List<Map<String, dynamic>>> listData = const {},
}) async {
  final t = _ListTransport(responses, {...FakeTransport.table, ..._noteTable});
  t.listData.addAll(listData);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final container = ProviderContainer(
    overrides: [
      noteApiProvider.overrideWithValue(NoteStationApi(api)),
      if (probe != null)
        noteDeviceLocationProbeProvider.overrideWithValue(probe),
      chatDatabaseProvider.overrideWith((ref) {
        final db = ChatDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return db;
      }),
      serviceAvailabilityProvider.overrideWith(
        () => _FixedAvailability(_snap(apis ?? {kNoteApi, kInfoApi})),
      ),
    ],
  );
  addTearDown(container.dispose);
  return (t: t, c: container);
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget child,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: child,
        localizationsDelegates: const [
          FlutterQuillLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: FlutterQuillLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
}

/// 打开位置面板的宿主页（走真 modal 路由，`保存` 后的 `pop` 才有地方可退）。
class _SheetHost extends StatelessWidget {
  const _SheetHost({required this.note});

  final NoteDto note;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Consumer(
      builder: (context, ref, _) => Center(
        child: ElevatedButton(
          key: const Key('open-location-sheet'),
          onPressed: () => showNoteLocationSheet(context, ref, note),
          child: const Text('open'),
        ),
      ),
    ),
  );
}

NoteDto _note({String id = 'N1', double? lat, double? lng, String? location}) =>
    NoteDto(
      objectId: id,
      title: 'T',
      parentId: 'nb1',
      ver: 'v1',
      latitude: lat,
      longitude: lng,
      location: location,
    );

void main() {
  // ------------------------------------------------------------ 显示口径
  group('N4 显示口径 = 官方 getLocationDisplayText（逐字三分支）', () {
    test('名字 + 非零坐标 → "名字 (lat,lng)"（2 位小数）', () {
      expect(
        noteLocationDisplayText('Taipei 101', 25.050433, 121.518649),
        'Taipei 101 (25.05,121.52)',
      );
    });

    test('无名字 + 非零坐标 → "(lat,lng)"', () {
      expect(noteLocationDisplayText('', 25.0, 121.5), '(25.00,121.50)');
      expect(
        noteLocationDisplayText(null, -33.8688, 151.2093),
        '(-33.87,151.21)',
      );
    });

    test('坐标 0（= 已删除 GPS）→ 只出名字，绝不编坐标', () {
      expect(noteLocationDisplayText('Taipei', 0, 0), 'Taipei');
      expect(noteLocationDisplayText('', 0, 0), '');
      expect(noteLocationDisplayText(null, null, null), '');
      // 半截坐标（只有纬度）也不算有效位置
      expect(noteLocationDisplayText('Taipei', 25.0, null), 'Taipei');
    });

    test('noteHasLocation 只认"会显示出来的东西"', () {
      expect(noteHasLocation(_note(lat: 25.0, lng: 121.5)), isTrue);
      expect(noteHasLocation(_note(location: 'Taipei')), isTrue);
      expect(noteHasLocation(_note(lat: 0, lng: 0)), isFalse);
      expect(noteHasLocation(_note()), isFalse);
    });
  });

  // ------------------------------------------------------------ 写：Note/set
  group('N4 Note/set 位置线参（APK SetNoteOperation.java:233-244）', () {
    test('latitude/longitude 是 JSON 数字、location 是带引号串', () async {
      final b = await _apiBoot({
        '$kNoteApi.set': {'data': []},
      });
      await b.notes.setNote(
        objectId: 'N1',
        ver: 'v1',
        latitude: 25.050433,
        longitude: 121.518649,
        location: 'Taipei 101',
      );
      final call = _callOf(b.t, kNoteApi, 'set');
      // ★ 数字形态：**不能**被包成字符串
      expect(call['latitude'], '25.050433');
      expect(jsonDecode(call['latitude']), isA<num>());
      expect(call['longitude'], '121.518649');
      expect(jsonDecode(call['longitude']), isA<num>());
      expect(call['location'], '"Taipei 101"');
    });

    test('删除 GPS：0 也发（非 null 就发）；空 location 不发', () async {
      final b = await _apiBoot({
        '$kNoteApi.set': {'data': []},
      });
      await b.notes.setNote(
        objectId: 'N1',
        ver: 'v1',
        latitude: 0,
        longitude: 0,
        location: '',
      );
      final call = _callOf(b.t, kNoteApi, 'set');
      expect(call['latitude'], '0.0');
      expect(call['longitude'], '0.0');
      // 官方 `!TextUtils.isEmpty(str2)` 才 putParam ⇒ 空串清不掉位置名
      expect(call.containsKey('location'), isFalse);
    });

    test('不传位置字段时请求里一个都不出现（不误伤 source_url 路径）', () async {
      final b = await _apiBoot({
        '$kNoteApi.set': {'data': []},
      });
      await b.notes.setNote(objectId: 'N1', ver: 'v1', sourceUrl: 'https://x');
      final call = _callOf(b.t, kNoteApi, 'set');
      expect(call.containsKey('latitude'), isFalse);
      expect(call.containsKey('longitude'), isFalse);
      expect(call.containsKey('location'), isFalse);
      expect(call['source_url'], '"https://x"');
    });
  });

  // ------------------------------------------------------ 查：Info/searchplace
  group('N4 Info/searchplace 线参（官方 Web Map.Panel.getSearchStore）', () {
    test('location = "纬度,经度"（纬度在前）+ format/radius/query', () async {
      final b = await _apiBoot();
      b.t.listData['$kInfoApi.searchplace'] = [];
      await b.notes.searchPlace(
        latitude: 25.05,
        longitude: 121.51,
        query: 'Taipei',
      );
      final call = _callOf(b.t, kInfoApi, 'searchplace');
      expect(call['api'], kInfoApi);
      expect(call['method'], 'searchplace');
      // 服务端 `.lib` 的 v1 就有 searchplace ⇒ 官方 Web 写死 version:1
      expect(call['version'], '1');
      // ★ 真机只读实测：合法 location → 200；缺/空/非法 → 请求挂到超时
      expect(call['location'], '"25.05,121.51"');
      expect(call['query'], '"Taipei"');
      expect(call['radius'], '500');
      expect(call['format'], 'true');
      expect(call.containsKey('_sid'), isTrue);
    });

    test('回包 gps 对象 / 缺失坐标都能解（含 local 项）', () async {
      final b = await _apiBoot();
      b.t.listData['$kInfoApi.searchplace'] = [
        {
          'name': 'Taipei 101',
          'address': 'Xinyi Rd',
          'gps': {'lat': 25.033, 'lng': 121.5645},
          'placeID': 'PLACE-ID-SECRET',
          'type': 'search',
        },
        {
          'name': 'Taipei',
          'address': '',
          'gps': '',
          'placeID': '',
          'type': 'local',
        },
      ];
      final places = await b.notes.searchPlace(
        latitude: 25.05,
        longitude: 121.51,
        query: 'Taipei',
      );
      expect(places, hasLength(2));
      expect(places.first.name, 'Taipei 101');
      expect(places.first.address, 'Xinyi Rd');
      expect(places.first.latitude, 25.033);
      expect(places.first.longitude, 121.5645);
      expect(places.first.hasGps, isTrue);
      expect(places.first.isLocal, isFalse);
      expect(places.last.isLocal, isTrue);
      expect(places.last.hasGps, isFalse);
      // `placeID` 留在数据层（不上屏，见 UI 用例）
      expect(places.first.placeId, 'PLACE-ID-SECRET');
    });

    test('数据是裸数组：不被 _okData 折成 {} 而丢失', () async {
      final b = await _apiBoot();
      b.t.listData['$kInfoApi.searchplace'] = [
        {
          'name': 'A',
          'gps': {'lat': 1.5, 'lng': 2.5},
          'type': 'search',
        },
      ];
      final places = await b.notes.searchPlace(
        latitude: 1,
        longitude: 2,
        query: 'A',
      );
      expect(places, hasLength(1));
      expect(places.first.latitude, 1.5);
    });

    test('success:false → DsmApiException 带原码', () async {
      final b = await _apiBoot();
      // 让 transport 回一个错误信封（走 harness 的 failures 分支）
      b.t.failures['$kInfoApi.searchplace'] = 102;
      await expectLater(
        b.notes.searchPlace(latitude: 1, longitude: 2, query: 'A'),
        throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 102)),
      );
    });
  });

  group('NotePlaceDto 容错', () {
    test('gps 缺失 / 数组 / 直挂坐标', () {
      expect(NotePlaceDto.fromJson({'name': 'x'}).hasGps, isFalse);
      expect(
        NotePlaceDto.fromJson({
          'name': 'x',
          'gps': [1.25, 2.5],
        }).latitude,
        1.25,
      );
      expect(
        NotePlaceDto.fromJson({
          'name': 'x',
          'latitude': 3.5,
          'longitude': 4.5,
        }).longitude,
        4.5,
      );
    });
  });

  // ----------------------------------------------------------------- UI
  group('N4 信息面板：位置展示 + 内部 id 不上屏', () {
    testWidgets('有位置 → 显示 "名字 (lat,lng)"；object_id 不上屏', (tester) async {
      final b = await _uiBoot({
        'SYNO.NoteStation.Notebook.list': {'notebooks': []},
      });
      final note = _note(
        id: 'OBJECT-ID-SECRET',
        lat: 25.050433,
        lng: 121.518649,
        location: 'Taipei 101',
      );
      await _pump(tester, b.c, Scaffold(body: NoteInfoSheet(note: note)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('note-info-location')), findsOneWidget);
      expect(find.text('Taipei 101 (25.05,121.52)'), findsOneWidget);
      expect(find.textContaining('OBJECT-ID-SECRET'), findsNothing);
    });

    testWidgets('无位置 → 只出占位符，绝不伪造坐标（Falsification ③）', (tester) async {
      final b = await _uiBoot({
        'SYNO.NoteStation.Notebook.list': {'notebooks': []},
      });
      // 坐标 0/0 = 官方"已删除 GPS"
      final note = _note(id: 'N9', lat: 0, lng: 0);
      await _pump(tester, b.c, Scaffold(body: NoteInfoSheet(note: note)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('note-info-location')), findsOneWidget);
      expect(find.text('—'), findsWidgets);
      // 任何形如 (数字,数字) 的坐标都不许凭空出现
      expect(find.textContaining(RegExp(r'\(-?\d+\.\d\d,')), findsNothing);
    });

    testWidgets('能力位缺 SYNO.NoteStation.Info → 位置入口隐藏（门控）', (tester) async {
      final b = await _uiBoot(
        {
          'SYNO.NoteStation.Notebook.list': {'notebooks': []},
        },
        apis: {kNoteApi}, // 没有 Info
      );
      final note = _note(lat: 25.0, lng: 121.5, location: 'Taipei');
      await _pump(tester, b.c, Scaffold(body: NoteInfoSheet(note: note)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('note-info-location')), findsNothing);
      expect(find.byKey(const Key('note-info-location-edit')), findsNothing);
      expect(find.textContaining('(25.00,121.50)'), findsNothing);
    });
  });

  group('N4 位置面板：搜索 → 选择 → 保存', () {
    testWidgets('搜索结果落点后 Note/set 带上选中坐标与名称', (tester) async {
      final b = await _uiBoot(
        {
          '$kNoteApi.set': {'data': []},
        },
        listData: {
          '$kInfoApi.searchplace': [
            {
              'name': 'Taipei 101',
              'address': 'Xinyi Rd',
              'gps': {'lat': 25.033, 'lng': 121.5645},
              'placeID': 'PLACE-ID-SECRET',
              'type': 'search',
            },
          ],
        },
      );
      // 已有坐标 → 搜索中心点就在（官方也是拿地图中心当 location）
      final note = _note(lat: 25.05, lng: 121.51);
      await _pump(tester, b.c, _SheetHost(note: note));
      await tester.tap(find.byKey(const Key('open-location-sheet')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('note-location-search')),
        'Taipei',
      );
      await tester.tap(find.byKey(const Key('note-location-search-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('note-location-result-0')), findsOneWidget);
      // `placeID` 是内部标识，不上屏
      expect(find.textContaining('PLACE-ID-SECRET'), findsNothing);

      await tester.tap(find.byKey(const Key('note-location-result-0')));
      await tester.pumpAndSettle();
      expect(find.text('Taipei 101 (25.03,121.56)'), findsOneWidget);

      await tester.tap(find.byKey(const Key('note-location-save')));
      await tester.pumpAndSettle();
      final call = _callOf(b.t, kNoteApi, 'set');
      expect(call['latitude'], '25.033');
      expect(call['longitude'], '121.5645');
      expect(call['location'], '"Taipei 101"');
    });

    testWidgets('删除 GPS → 保存写 0/0 且不发 location', (tester) async {
      final b = await _uiBoot({
        '$kNoteApi.set': {'data': []},
      });
      final note = _note(lat: 25.05, lng: 121.51, location: 'Taipei 101');
      await _pump(tester, b.c, _SheetHost(note: note));
      await tester.tap(find.byKey(const Key('open-location-sheet')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('note-location-delete-gps')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('note-location-save')));
      await tester.pumpAndSettle();
      final call = _callOf(b.t, kNoteApi, 'set');
      expect(call['latitude'], '0.0');
      expect(call['longitude'], '0.0');
      expect(call.containsKey('location'), isFalse);
    });

    testWidgets('没有中心点就搜索 → 不发 searchplace（真机会挂到超时）', (tester) async {
      final probe = _FakeProbe(permission: LocationPermission.unsupported);
      final b = await _uiBoot(
        const {},
        probe: probe,
        listData: {'$kInfoApi.searchplace': []},
      );
      final note = _note(); // 没有任何坐标
      await _pump(tester, b.c, _SheetHost(note: note));
      await tester.tap(find.byKey(const Key('open-location-sheet')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('note-location-search')),
        'Taipei',
      );
      await tester.tap(find.byKey(const Key('note-location-search-submit')));
      await tester.pumpAndSettle();
      expect(_callsOf(b.t, kInfoApi, 'searchplace'), isEmpty);
      expect(find.text('先设置或获取一个位置，才能搜索附近地点'), findsOneWidget);
      // 没能力时"用当前位置"入口不出现（能力位降级）
      expect(find.byKey(const Key('note-location-use-current')), findsNothing);
    });

    testWidgets('搜索失败如实报错，不装成"没结果"空态', (tester) async {
      final b = await _uiBoot({
        '$kNoteApi.set': {'data': []},
      });
      b.t.failures['$kInfoApi.searchplace'] = 105;
      final note = _note(lat: 25.05, lng: 121.51);
      await _pump(tester, b.c, _SheetHost(note: note));
      await tester.tap(find.byKey(const Key('open-location-sheet')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('note-location-search')),
        'Taipei',
      );
      await tester.tap(find.byKey(const Key('note-location-search-submit')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('note-location-search-error')),
        findsOneWidget,
      );
      // ★ 不许把失败渲染成"未找到相符项目"的空态
      expect(find.byKey(const Key('note-location-no-result')), findsNothing);
    });

    testWidgets('用当前位置：有权限才出现，落点是探针给的真坐标', (tester) async {
      final probe = _FakeProbe(
        permission: LocationPermission.granted,
        fix: const DeviceLocation(
          latitude: 25.033,
          longitude: 121.5645,
          timeMs: 1700000000000,
        ),
      );
      final b = await _uiBoot({
        '$kNoteApi.set': {'data': []},
      }, probe: probe);
      final note = _note();
      await _pump(tester, b.c, _SheetHost(note: note));
      await tester.tap(find.byKey(const Key('open-location-sheet')));
      await tester.pumpAndSettle();

      final useCurrent = find.byKey(const Key('note-location-use-current'));
      expect(useCurrent, findsOneWidget);
      await tester.tap(useCurrent);
      await tester.pumpAndSettle();
      expect(find.text('(25.03,121.56)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('note-location-save')));
      await tester.pumpAndSettle();
      final call = _callOf(b.t, kNoteApi, 'set');
      expect(call['latitude'], '25.033');
      expect(call['longitude'], '121.5645');
      // 官方 `getCurrentGPS` 只给坐标、不给地名
      expect(call.containsKey('location'), isFalse);
    });
  });
}
