// P18：人脸条的离线用例（字段形状取证自官方 Web `react_bundle.js` 的
// `renderFace`：`id` / `additional.thumbnail` / `hidden`）。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/photos/photo_faces.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _png = <int>[137, 80, 78, 71];

Map<String, dynamic> _faceJson(String id, {bool hidden = false}) => {
  'id': id,
  'filename': 'IMG_$id.jpg',
  'filesize': 1024,
  'time': DateTime(2026, 9, 18, 10).millisecondsSinceEpoch ~/ 1000,
  'folder_id': '10',
  'type': 'photo',
  'hidden': hidden,
  'additional': {
    'thumbnail': {'sm': 'sm_$id', 'cache_key': 'ck_$id'},
  },
};

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

Future<({FakeTransport t, ProviderContainer c})> _pumpStrip(
  WidgetTester tester, {
  required List<String> itemIds,
  Map<String, Map<String, dynamic>> byApi = const {},
  List<Object> extra = const [],
}) async {
  final t = FakeTransport(const {}, {...FakeTransport.table, ..._photoTable});
  t.downloadBytes = _png;
  t.onCall = (params) => byApi['${params['api']}.${params['method']}'];
  final api = await _loggedIn(t);
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fotoApiProvider.overrideWithValue(FotoApi(api)),
      ...extra.cast(),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: PhotoFaceStrip(personId: '7', itemIds: itemIds),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return (t: t, c: c);
}

const _photoTable = <String, Map<String, dynamic>>{
  'SYNO.Foto.Browse.Person': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 7,
  },
  'SYNO.Foto.Setting.User': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

void main() {
  group('P18 人脸条目解析', () {
    test('id / additional.thumbnail / hidden 三件套（官方 renderFace 用法）', () {
      final f = PhotoFaceDto.tryParse(_faceJson('31', hidden: true))!;
      expect(f.id, '31');
      expect(f.hidden, isTrue);
      expect(f.item.thumb.cacheKey, 'ck_31');
      expect(f.item.filename, 'IMG_31.jpg');
    });

    test('没有 id 的条目直接丢弃（不造空壳）', () {
      expect(PhotoFaceDto.tryParse(const {'hidden': true}), isNull);
      expect(PhotoFaceDto.tryParse('not a map'), isNull);
    });

    test('查询条件按值相等（provider family 不会因新 List 实例重复请求）', () {
      const a = PhotoFacesQuery(personId: '7', itemIds: ['1', '2']);
      const b = PhotoFacesQuery(personId: '7', itemIds: ['1', '2']);
      const c = PhotoFacesQuery(personId: '7', itemIds: ['2', '1']);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('P18 人脸条（UI）', () {
    testWidgets('itemIds 为空 → 一个请求都不发、也不渲染', (tester) async {
      final boot = await _pumpStrip(tester, itemIds: const []);
      expect(find.byKey(const Key('photo-face-strip')), findsNothing);
      expect(
        boot.t.calls.any((c) => c['method'] == 'list_face'),
        isFalse,
      );
    });

    testWidgets('渲染人脸；点一张 → 选「移出该人物」→ 确认 → delete_face（face_id 数组）', (
      tester,
    ) async {
      final boot = await _pumpStrip(
        tester,
        itemIds: const ['11', '12'],
        byApi: {
          'SYNO.Foto.Browse.Person.list_face': {
            'list': [_faceJson('31'), _faceJson('32', hidden: true)],
          },
          'SYNO.Foto.Browse.Person.delete_face': <String, dynamic>{},
        },
      );
      expect(find.byKey(const Key('photo-face-strip')), findsOneWidget);
      expect(find.byKey(const Key('photo-face-31')), findsOneWidget);
      expect(find.byKey(const Key('photo-face-32')), findsOneWidget);

      final listCall = boot.t.calls.firstWhere((c) => c['method'] == 'list_face');
      expect(listCall['version'], '1');
      expect(jsonDecode(listCall['item_id'] as String), [11, 12]);
      expect(listCall['person_id'], '7');

      await tester.tap(find.byKey(const Key('photo-face-31')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('photo-face-actions')), findsOneWidget);
      await tester.tap(find.byKey(const Key('photo-face-remove')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('photo-face-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final call = boot.t.calls.lastWhere((c) => c['method'] == 'delete_face');
      expect(call['person_id'], '7');
      expect(jsonDecode(call['face_id'] as String), [31]);
    });

    testWidgets('确认框点取消 → 零请求', (tester) async {
      final boot = await _pumpStrip(
        tester,
        itemIds: const ['11'],
        byApi: {
          'SYNO.Foto.Browse.Person.list_face': {
            'list': [_faceJson('31')],
          },
        },
      );
      await tester.tap(find.byKey(const Key('photo-face-31')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('photo-face-separate')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('photo-face-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        boot.t.calls.any(
          (c) => c['method'] == 'delete_face' || c['method'] == 'separate',
        ),
        isFalse,
      );
    });

    testWidgets('拆分为新人物 → separate（face_id 数组、不带 name/target_id）', (tester) async {
      final boot = await _pumpStrip(
        tester,
        itemIds: const ['11'],
        byApi: {
          'SYNO.Foto.Browse.Person.list_face': {
            'list': [_faceJson('31')],
          },
          'SYNO.Foto.Browse.Person.separate': <String, dynamic>{},
        },
      );
      await tester.tap(find.byKey(const Key('photo-face-31')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('photo-face-separate')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('photo-face-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final call = boot.t.calls.lastWhere((c) => c['method'] == 'separate');
      expect(jsonDecode(call['face_id'] as String), [31]);
      expect(call.containsKey('name'), isFalse);
      expect(call.containsKey('target_id'), isFalse);
    });
  });
}
