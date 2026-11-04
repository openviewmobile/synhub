// ⑦相册 **管理员**接口与页面的 Mock 核实（新规 B1：必须通过）。
//
// 权威出处：`SynologyPhotos/usr/webapi/SYNO.Foto.lib`
//   * `SYNO.Foto.Setting.Admin` v1 → `get`
//   * `SYNO.Foto.Development.Admin` v1 → `refetch_geocoding`
//
// 全部走 `FakeTransport`（不发真请求）；页面门控走 `isAdminProvider` 覆盖，
// 非管理员必须**一个字都不显示**。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/foto_c2_api.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/admin/admin_gate.dart';
import 'package:synhub/src/features/photos/photo_admin_page.dart';
import 'package:synhub/src/features/photos/photo_c2_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _table = <String, Map<String, dynamic>>{
  'SYNO.Foto.Setting.Admin': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Foto.Development.Admin': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.FotoTeam.Setting.Admin': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

Future<({FakeTransport t, DsmWebApi api})> _api({
  Map<String, int> failures = const {},
}) async {
  final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
  t.failures.addAll(failures);
  t.onCall = (p) {
    switch (p['method']) {
      case 'get':
        return {'enable_geocoding': true, 'concept_threshold': 0.6};
      case 'refetch_geocoding':
        return {'finished': true};
    }
    return null;
  };
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (t: t, api: api);
}

Future<void> _pump(
  WidgetTester tester, {
  required bool admin,
  required DsmWebApi api,
}) async {
  final c = ProviderContainer(
    overrides: [
      isAdminProvider.overrideWith((ref) => admin),
      fotoC2ApiProvider.overrideWithValue(FotoC2Api(FotoApi(api))),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: PhotoAdminPage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  group('管理员 API（Mock）', () {
    test('adminSettings：SYNO.Foto.Setting.Admin/get v1，无参', () async {
      final b = await _api();
      final settings = await FotoC2Api(FotoApi(b.api)).adminSettings();
      final call = b.t.calls.lastWhere((c) => c['method'] == 'get');
      expect(call['api'], 'SYNO.Foto.Setting.Admin');
      expect(call['version'], '1');
      // FakeTransport 对"无参"给 null（真机侧就是不带 params 字段）
      expect(call['params'] ?? const <String, Object?>{}, isEmpty);
      expect(settings['enable_geocoding'], true);
    });

    test('adminRefetchGeocoding：SYNO.Foto.Development.Admin/refetch_geocoding v1', () async {
      final b = await _api();
      final r = await FotoC2Api(FotoApi(b.api)).adminRefetchGeocoding();
      final call = b.t.calls.lastWhere(
        (c) => c['method'] == 'refetch_geocoding',
      );
      expect(call['api'], 'SYNO.Foto.Development.Admin');
      expect(call['version'], '1');
      expect(call['params'] ?? const <String, Object?>{}, isEmpty);
      expect(r['finished'], true);
    });

    test('团队空间用 SYNO.FotoTeam 前缀（同方法名，不同空间）', () async {
      final b = await _api();
      final team = FotoC2Api(FotoApi(b.api, space: FotoSpace.team));
      await team.adminSettings();
      expect(
        b.t.calls.lastWhere((c) => c['method'] == 'get')['api'],
        'SYNO.FotoTeam.Setting.Admin',
      );
    });
  });

  group('管理员页面门控（fail-closed）', () {
    testWidgets('非管理员：不显示任何管理内容', (tester) async {
      final b = await _api();
      await _pump(tester, admin: false, api: b.api);
      expect(find.byKey(const Key('photo-admin-page')), findsNothing);
      expect(find.byKey(const Key('photo-admin-refetch')), findsNothing);
      expect(find.byKey(const Key('photo-admin-denied')), findsOneWidget);
      // 门控严格：非管理员一次管理接口都不该发
      expect(b.t.calls.where((c) => c['api'].toString().contains('Admin')), isEmpty);
    });

    testWidgets('管理员：列出服务端字段（不猜字段）', (tester) async {
      final b = await _api();
      await _pump(tester, admin: true, api: b.api);
      expect(find.byKey(const Key('photo-admin-page')), findsOneWidget);
      expect(find.byKey(const Key('photo-admin-field-enable_geocoding')), findsOneWidget);
      // 服务端没给的字段不许出现
      expect(find.byKey(const Key('photo-admin-field-not_in_response')), findsNothing);
    });

    testWidgets('重新地理编码：取消 ⇒ 零调用；确认 ⇒ 恰好一次', (tester) async {
      final b = await _api();
      await _pump(tester, admin: true, api: b.api);
      await tester.tap(find.byKey(const Key('photo-admin-refetch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-admin-refetch-cancel')));
      await tester.pumpAndSettle();
      expect(
        b.t.calls.where((c) => c['method'] == 'refetch_geocoding'),
        isEmpty,
        reason: '取消就必须零调用',
      );

      await tester.tap(find.byKey(const Key('photo-admin-refetch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-admin-refetch-ok')));
      await tester.pumpAndSettle();
      expect(
        b.t.calls.where((c) => c['method'] == 'refetch_geocoding').length,
        1,
      );
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('失败 ⇒ 明确报错（不假装成功）', (tester) async {
      final b = await _api(failures: {'SYNO.Foto.Development.Admin.refetch_geocoding': 105});
      await _pump(tester, admin: true, api: b.api);
      await tester.tap(find.byKey(const Key('photo-admin-refetch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-admin-refetch-ok')));
      await tester.pumpAndSettle();
      expect(find.textContaining('请求失败'), findsOneWidget);
    });
  });
}
