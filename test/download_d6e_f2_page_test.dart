// ⑥下载 **D-6e**：F2 管理员页面（eMule 服务器/Kad）—— 门控 + 上屏 + 动作。
//
// 新规 R2：非管理员**入口隐藏**（不是提示"无权限"）；管理员才看得到。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/download_station.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/admin/admin_identity.dart';
import 'package:synhub/src/features/downloads/download_emule_page.dart';
import 'package:synhub/src/features/downloads/download_emule_server_page.dart';
import 'package:synhub/src/features/downloads/download_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _srv = 'SYNO.DownloadStation2.eMule.Server';
const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.DownloadStation2.Task': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  _srv: {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
};

const _responses = {
  '$_srv.list': {
    'results': [
      {
        'id': 's1',
        'ip': '1.2.3.4',
        'port': 4661,
        'name': 'Donkey',
        'user_count': 10,
        'user_max': 100,
      },
    ],
    'total': 1,
  },
  '$_srv.get_status': {
    'ed2k': {'status': 'connected'},
    'kad': {'status': 'connecting'},
  },
  '$_srv.connect': {'ok': true},
  '$_srv.connect_kad': {'ok': true},
  '$_srv.disconnect': {'ok': true},
  '$_srv.delete': {'ok': true},
  '$_srv.add': {'ok': true},
  'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
};

Future<FakeTransport> _pump(
  WidgetTester tester,
  Widget page, {
  bool admin = true,
}) async {
  final t = FakeTransport(_responses, {...FakeTransport.table, ..._table});
  final api = DsmWebApi(t);
  await api.discover();
  final c = ProviderContainer(
    overrides: [
      downloadApiProvider.overrideWithValue(DownloadStationApi(api)),
      isAdminProvider.overrideWith((ref) => admin),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return t;
}

void main() {
  testWidgets('管理员：入口出现，页面上屏服务器与 ED2K/Kad 状态', (tester) async {
    await _pump(tester, const DownloadEmulePage());
    expect(find.byKey(const Key('ds-emule-servers-open')), findsOneWidget);

    await tester.tap(find.byKey(const Key('ds-emule-servers-open')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ds-emule-srv-0')), findsOneWidget);
    expect(find.text('Donkey'), findsOneWidget);
    expect(find.textContaining('1.2.3.4:4661'), findsOneWidget);
    final status = tester.widget<Text>(
      find.byKey(const Key('ds-emule-srv-status')),
    );
    expect(status.data, contains('connected'));
    expect(status.data, contains('connecting'));
  });

  testWidgets('非管理员：入口**隐藏**（R2），直接进深链也给门控页', (tester) async {
    await _pump(tester, const DownloadEmulePage(), admin: false);
    expect(find.byKey(const Key('ds-emule-servers-open')), findsNothing);

    await _pump(tester, const DownloadEmuleServerPage(), admin: false);
    expect(find.byKey(const Key('admin-page-gate')), findsOneWidget);
    expect(find.byKey(const Key('ds-emule-srv-0')), findsNothing);
  });

  testWidgets('连接服务器 / 连接 Kad / 断开 都打到对应方法', (tester) async {
    final t = await _pump(tester, const DownloadEmuleServerPage());
    t.calls.clear();

    await tester.tap(find.byKey(const Key('ds-emule-srv-menu-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接').last);
    await tester.pumpAndSettle();
    expect(t.calls.any((c) => c['method'] == 'connect'), isTrue);

    await tester.tap(find.byKey(const Key('ds-emule-srv-kad')));
    await tester.pumpAndSettle();
    expect(t.calls.any((c) => c['method'] == 'connect_kad'), isTrue);

    await tester.tap(find.byKey(const Key('ds-emule-srv-disconnect')));
    await tester.pumpAndSettle();
    expect(t.calls.any((c) => c['method'] == 'disconnect'), isTrue);
  });

  testWidgets('添加服务器：填 IP/端口 → add 带 {ip,port}；删除选中 → delete 数组', (tester) async {
    final t = await _pump(tester, const DownloadEmuleServerPage());
    t.calls.clear();

    await tester.tap(find.byKey(const Key('ds-emule-srv-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('ds-emule-srv-ip')),
      '9.9.9.9',
    );
    await tester.tap(find.byKey(const Key('ds-emule-srv-save')));
    await tester.pumpAndSettle();
    final add = t.calls.lastWhere((c) => c['method'] == 'add');
    expect(add['ip'], '9.9.9.9');
    expect(add['port'], 4661);

    await tester.tap(find.byKey(const Key('ds-emule-srv-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ds-emule-srv-delete-selected')));
    await tester.pumpAndSettle();
    final del = t.calls.lastWhere((c) => c['method'] == 'delete');
    expect(del['id'], '["s1"]');
  });
}
