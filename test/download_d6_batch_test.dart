// ⑥下载 **D-6 batch**：F1 eMule（本轮）；F5/F6/F14 的旧账核对。
//
// 本轮只做**能被证据支持**的断言：
// * F1 下载列表：`Task/list` v2 带 `type:["emule"]` 且**不带 `type_inverse`**
//   （官方 aMule 面板逐字；默认队列才带 `type_inverse:true`）；
// * F1 上传列表：`Task.eMule / list_upload` v1，`allowUser` 不含普通用户
//   ⇒ **管理员专属**，页面上必须包在 `AdminOnly` 里；
// * F1 开关：`Package.Service.get.enable_emule === true` 才出现入口。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/download_station.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/admin/admin_identity.dart';
import 'package:synhub/src/features/downloads/download_emule_page.dart';
import 'package:synhub/src/features/downloads/download_emule_providers.dart';
import 'package:synhub/src/features/downloads/download_page.dart';
import 'package:synhub/src/features/downloads/download_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/core/ui/hud_widgets.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _emuleTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.DownloadStation2.Task': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.DownloadStation2.Task.Statistic': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.DownloadStation2.Task.eMule': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.DownloadStation2.Package.Service': {
    'path': 'entry.cgi',
    'minVersion': 2,
    'maxVersion': 2,
  },
  'SYNO.DownloadStation2.Package.Info': {
    'path': 'entry.cgi',
    'minVersion': 2,
    'maxVersion': 2,
  },
  'SYNO.DownloadStation2.Package.Module': {
    'path': 'entry.cgi',
    'minVersion': 2,
    'maxVersion': 2,
  },
};

Map<String, dynamic> _emuleTask({
  Object id = 'e1',
  String title = 'ed2k://|file|ubuntu.iso|1024|hash|/',
  int status = 2,
}) => {
  'id': id,
  'title': title,
  'type': 'emule',
  'status': status,
  'size': 2048,
  'additional': {
    'transfer': {
      'size_downloaded': 1024,
      'speed_download': 512,
      'speed_upload': 0,
    },
  },
};

Future<({DsmWebApi api, DownloadStationApi ds, FakeTransport t})> _boot({
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, int> failures = const {},
}) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._emuleTable});
  t.failures.addAll(failures);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'demo_user', password: 'x');
  return (api: api, ds: DownloadStationApi(api), t: t);
}

ProviderContainer _container(DsmWebApi api, {bool admin = true}) =>
    ProviderContainer(
      overrides: [
        downloadApiProvider.overrideWithValue(DownloadStationApi(api)),
        isAdminProvider.overrideWith((ref) => admin),
      ],
    );

Future<void> _pumpPage(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  bool admin = true,
}) async {
  final t = FakeTransport(responses, {
    ...FakeTransport.table,
    ..._emuleTable,
  });
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
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  group('F1 数据层：eMule 下载/上传列表的参数逐字', () {
    test('emuleOnly=true 时 type=["emule"] 且**不带 type_inverse**', () async {
      final (api: _, :ds, :t) = await _boot(
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [_emuleTask()],
            'total': 1,
          },
        },
      );
      final page = await ds.listTasks(emuleOnly: true);
      final call = t.calls.lastWhere((c) => c['method'] == 'list');
      expect(call['type'], jsonEncode(['emule']));
      expect(call.containsKey('type_inverse'), isFalse,
          reason: '官方 aMule 面板不下发 type_inverse');
      expect(call['additional'], jsonEncode(['detail', 'transfer']));
      expect(page.items.single.type, 'emule');
    });

    test('默认队列仍然排除 eMule（type_inverse=true）—— 回归保护', () async {
      final (api: _, :ds, :t) = await _boot(
        responses: {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
        },
      );
      await ds.listTasks();
      expect(t.calls.lastWhere((c) => c['method'] == 'list')['type_inverse'], true);
    });

    test('emuleUploads：Task.eMule/list_upload v1 + offset/limit/sort_by/order', () async {
      final (api: _, :ds, :t) = await _boot(
        responses: {
          'SYNO.DownloadStation2.Task.eMule.list_upload': {
            'task': [
              {
                'id': 'u1',
                'client_name': 'peerX',
                'file_name': 'movie.mkv',
                'upload_speed': 4096,
                'size_uploaded': 1024,
                'wait_time': 3,
                'upload_time': 9,
              },
            ],
            'total': 1,
          },
        },
      );
      final page = await ds.emuleUploads(offset: 0, limit: 25);
      final call = t.calls.lastWhere((c) => c['method'] == 'list_upload');
      expect(call['api'], 'SYNO.DownloadStation2.Task.eMule');
      expect(call['version'], '1');
      expect(call['offset'], 0);
      expect(call['limit'], 25);
      expect(page.total, 1);
      expect(page.items.single.fileName, 'movie.mkv');
      expect(page.items.single.clientName, 'peerX');
      expect(page.items.single.uploadSpeed, 4096);
    });
  });

  group('F1 页面：门控与三态', () {
    testWidgets('enable_emule=false → eMule 入口**隐藏**（不给假入口）', (tester) async {
      await _pumpPage(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
          'SYNO.DownloadStation2.Package.Service.get': {
            'enable_emule': false,
            'enable_unzip': true,
          },
          'SYNO.DownloadStation2.Package.Info.get': {'major': 4},
          'SYNO.DownloadStation2.Package.Module.list': {'listItems': []},
        },
      );
      expect(find.byKey(const Key('ds-emule-open')), findsNothing);
    });

    testWidgets('enable_emule=true → 入口出现，点进去看到下载列表', (tester) async {
      await _pumpPage(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [_emuleTask(title: 'emule-file-a')],
            'total': 1,
          },
          'SYNO.DownloadStation2.Package.Service.get': {
            'enable_emule': true,
            'enable_unzip': true,
          },
          'SYNO.DownloadStation2.Package.Info.get': {'major': 4},
          'SYNO.DownloadStation2.Package.Module.list': {'listItems': []},
        },
      );
      expect(find.byKey(const Key('ds-emule-open')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ds-emule-open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ds-emule-task-e1')), findsOneWidget);
      expect(find.text('emule-file-a'), findsWidgets);
    });

    testWidgets('eMule 页：空列表 → 中性空态（不是"加载失败"）', (tester) async {
      await _pumpPage(
        tester,
        const DownloadEmulePage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
          'SYNO.DownloadStation2.Task.eMule.list_upload': {
            'task': [],
            'total': 0,
          },
        },
      );
      expect(find.byKey(const Key('ds-emule-empty')), findsOneWidget);
      expect(find.textContaining('加载失败'), findsNothing);
    });

    // ★★ DA63（r408 真机）：eMule 行只有体积、没有状态 ⇒ 任务卡住时用户
    //   看不出为什么。真机逐字是 `synhub-r408-smoke.bin` / `1.0 MB`。
    testWidgets('DA63：eMule 行必须显示状态文案（与主队列同一套判据）', (tester) async {
      await _pumpPage(
        tester,
        const DownloadEmulePage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [
              _emuleTask(id: 'e7', title: 'stuck.bin', status: 1),
            ],
            'total': 1,
          },
          'SYNO.DownloadStation2.Task.eMule.list_upload': {
            'task': [],
            'total': 0,
          },
        },
      );
      expect(find.byKey(const Key('ds-emule-task-e7')), findsOneWidget);
      // 状态 1 = 等待中（英文 locale 的测试环境里是 Waiting）
      expect(find.textContaining('等'), findsWidgets);
      // 体积那行还在（新增状态**不许**把原有信息挤掉）
      expect(find.textContaining('2.0 KB'), findsWidgets);
    });

    testWidgets('DA63 反向：错误态要用错误色那一支（status>=101）', (tester) async {
      await _pumpPage(
        tester,
        const DownloadEmulePage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [_emuleTask(id: 'e8', title: 'bad.bin', status: 102)],
            'total': 1,
          },
          'SYNO.DownloadStation2.Task.eMule.list_upload': {
            'task': [],
            'total': 0,
          },
        },
      );
      final tile = find.byKey(const Key('ds-emule-task-e8'));
      expect(tile, findsOneWidget);
      // 101..134 是**任务状态错误码区**，必须走错误文案，不许显示"等待中"
      expect(find.textContaining('等待中'), findsNothing);
      expect(
        find.descendant(of: tile, matching: find.byType(TelemetryLabel)),
        findsOneWidget,
      );
    });

    testWidgets('管理员：上传列表上屏；非管理员：**整段隐藏**（R2 隐藏而非提示）',
        (tester) async {
      await _pumpPage(
        tester,
        const DownloadEmulePage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
          'SYNO.DownloadStation2.Task.eMule.list_upload': {
            'task': [
              {
                'id': 'u1',
                'client_name': 'peerX',
                'file_name': 'movie.mkv',
                'upload_speed': 4096,
                'size_uploaded': 1024,
              },
            ],
            'total': 1,
          },
        },
      );
      expect(find.byKey(const Key('ds-emule-upload-0')), findsOneWidget);
      expect(find.text('movie.mkv'), findsWidgets);
    });

    testWidgets('非管理员：上传段完全不出现', (tester) async {
      await _pumpPage(
        tester,
        const DownloadEmulePage(),
        admin: false,
        responses: {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
          'SYNO.DownloadStation2.Task.eMule.list_upload': {
            'task': [
              {
                'id': 'u1',
                'client_name': 'peerX',
                'file_name': 'movie.mkv',
                'upload_speed': 4096,
                'size_uploaded': 1024,
              },
            ],
            'total': 1,
          },
        },
      );
      expect(find.byKey(const Key('ds-emule-upload-0')), findsNothing);
      expect(find.textContaining('movie.mkv'), findsNothing);
    });
  });

  group('F1 provider：暂停/继续/删除后重新拉列表', () {
    test('delete 会先调 Task/delete 再 refresh list', () async {
      final booted = await _boot(
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [_emuleTask()],
            'total': 1,
          },
          'SYNO.DownloadStation2.Task.delete': {'ok': true},
        },
      );
      final c = _container(booted.api);
      addTearDown(c.dispose);
      final sub = c.listen(emuleTasksProvider, (_, _) {});
      addTearDown(sub.close);
      await c.read(emuleTasksProvider.notifier).load();
      booted.t.calls.clear();

      await c.read(emuleTasksProvider.notifier).delete(['e1']);

      final methods = booted.t.calls.map((e) => e['method']).toList();
      expect(methods, contains('delete'));
      expect(methods.where((m) => m == 'list').isNotEmpty, isTrue,
          reason: '动作后要刷新');
    });
  });
}
