// 属性面板的"服务端实测"三行 + MD5 校验（页面层）。
//
// 这几行都是**按需问服务端**的（`Property.*` / `MD5`），所以要断言两件事：
//   1. 页面渲染：拿到什么显示什么；拿不到所有者时只少一行、不整页报错；
//   2. 发出去的请求：MD5 是"start → 每秒 status → 完成即停"，参数形态与官方
//      FileStation Web 端（FileProperty.js）一致。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/files/file_sheets.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.FileStation.List': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.MD5': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.Property.CompressSize': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.FileStation.Property.Mtime': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.FileStation.Property.ACLOwner': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

FileEntryDto _file({bool withRealPath = false}) => FileEntryDto.fromJson({
  'name': 'report.pdf',
  'path': '/home/report.pdf',
  'isdir': false,
  'filesize': 2048,
  'mtime': 1789000000,
  'crtime': 1788000000,
  'owner': 'demo_user',
  'additional': {
    // 浏览列表**默认不带 real_path**（与真实的 FileAdditional.browse 一致：
    // 官方 getFiles 调用点就没有这一项），所以属性面板要自己 getinfo 补。
    if (withRealPath) 'real_path': '/volume1/home/report.pdf',
    'size': 2048,
  },
});

Future<({FakeTransport t, ProviderContainer c})> _pumpSheet(
  WidgetTester tester, {
  Map<String, Map<String, dynamic>> responses = const {},
  Set<String> failures = const {},
  bool withRealPath = false,
}) async {
  final t = FakeTransport(<String, Map<String, dynamic>>{}, {
    ...FakeTransport.table,
    ..._table,
  });
  for (final e in responses.entries) {
    t.responses[e.key] = e.value;
  }
  for (final f in failures) {
    t.failures[f] = 403;
  }
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fileApiProvider.overrideWithValue(FileStationApi(api)),
    ],
  );
  addTearDown(() async {
    c.dispose();
    await db.close();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showFilePropertiesSheet(
                context,
                _file(withRealPath: withRealPath),
              ),
              child: const Text('打开属性'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开属性'));
  await tester.pumpAndSettle();
  return (t: t, c: c);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('属性面板 · 服务端实测三行', () {
    testWidgets('占盘大小 / 真实修改时间 / 所有者都按回包显示', (tester) async {
      await _pumpSheet(
        tester,
        withRealPath: true,
        responses: {
          // 真机回的是字符串数字（这一条是实测形态）
          'SYNO.FileStation.Property.CompressSize.get': {'diskSize': '1916928'},
          'SYNO.FileStation.Property.Mtime.get': {'mtime': '1789000123'},
          'SYNO.FileStation.Property.ACLOwner.get': {
            'name': 'demo_user',
            'type': 'user',
            'value': 'user:demo_user',
            'hasPrivilege': true,
          },
        },
      );
      await tester.pumpAndSettle();

      expect(find.text('服务端实测'), findsOneWidget);
      expect(find.textContaining('1916928 字节'), findsOneWidget);
      expect(find.text('所有者'), findsOneWidget);
      expect(find.text('user:demo_user'), findsOneWidget);
    });

    testWidgets('所有者拿不到（403）→ 只解释这一行，别的行照常', (tester) async {
      await _pumpSheet(
        tester,
        withRealPath: true,
        responses: {
          'SYNO.FileStation.Property.CompressSize.get': {'diskSize': 4096},
        },
        failures: {'SYNO.FileStation.Property.ACLOwner.get'},
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('4096 字节'), findsOneWidget);
      expect(find.textContaining('看不到（'), findsOneWidget);
      expect(find.text('服务端实测'), findsOneWidget); // 面板正常开着，没被 403 掀翻
    });

    testWidgets('列表没带 real_path → 先 getinfo 拿到真实路径再用它发 Property.*', (
      tester,
    ) async {
      final r = await _pumpSheet(
        tester,
        responses: {
          // getinfo 真机回的是 `{files:[…]}`，不是裸条目
          'SYNO.FileStation.List.getinfo': {
            'files': [
              {
                'name': 'report.pdf',
                'path': '/home/report.pdf',
                'isdir': false,
                'additional': {
                  'real_path': '/volume1/home/report.pdf',
                  'size': 2048,
                },
              },
            ],
          },
          'SYNO.FileStation.Property.CompressSize.get': {'diskSize': '1916928'},
          'SYNO.FileStation.Property.Mtime.get': {'mtime': '1789716730'},
          'SYNO.FileStation.Property.ACLOwner.get': {
            'name': 'demo_user',
            'type': 'user',
            'value': 'user:demo_user',
          },
        },
      );
      await tester.pumpAndSettle();

      expect(
        r.t.calls.any(
          (c) =>
              c['api'] == 'SYNO.FileStation.List' && c['method'] == 'getinfo',
        ),
        isTrue,
        reason: '没有 real_path 时应该补一次 getinfo',
      );
      final call = r.t.calls.firstWhere(
        (c) => c['api'] == 'SYNO.FileStation.Property.CompressSize',
      );
      expect(call['file'], '/volume1/home/report.pdf');
      // 字符串数字也要显示出来（真机就是字符串）
      expect(find.textContaining('1916928 字节'), findsOneWidget);
      expect(find.text('user:demo_user'), findsOneWidget);
    });

    testWidgets('Property.* 用 real_path 发（虚拟路径会被服务端 401/407）', (tester) async {
      final r = await _pumpSheet(
        tester,
        withRealPath: true,
        responses: {
          'SYNO.FileStation.Property.CompressSize.get': {'diskSize': 4096},
          'SYNO.FileStation.Property.Mtime.get': {'mtime': 1789000123},
          'SYNO.FileStation.Property.ACLOwner.get': {
            'name': 'demo_user',
            'type': 'user',
            'value': 'user:demo_user',
          },
        },
      );
      await tester.pumpAndSettle();

      expect(
        r.t.calls.any(
          (c) =>
              c['api'] == 'SYNO.FileStation.List' && c['method'] == 'getinfo',
        ),
        isFalse,
        reason: '列表已经带了 real_path，不该多问一次',
      );
      for (final method in ['get']) {
        for (final api in [
          'SYNO.FileStation.Property.CompressSize',
          'SYNO.FileStation.Property.Mtime',
          'SYNO.FileStation.Property.ACLOwner',
        ]) {
          final call = r.t.calls.firstWhere(
            (c) => c['api'] == api && c['method'] == method,
          );
          expect(
            call['file'],
            '/volume1/home/report.pdf',
            reason: '$api 必须发真实路径',
          );
        }
      }
      // MD5 用的是"虚拟路径"（真机上发 real_path 会 407）
      r.t.responses['SYNO.FileStation.MD5.start'] = {'taskid': 'M-9'};
      await tester.tap(find.byKey(const Key('file-md5-start')));
      await tester.pumpAndSettle();
      final start = r.t.calls.firstWhere((c) => c['method'] == 'start');
      expect(start['file_path'], '["/home/report.pdf"]');
    });

    testWidgets('服务端什么都没给 → 只有 MD5 那一行，不白屏也不报错', (tester) async {
      await _pumpSheet(tester);
      await tester.pumpAndSettle();
      expect(find.text('占盘大小'), findsNothing);
      expect(find.text('MD5'), findsOneWidget);
    });
  });

  group('属性面板 · MD5 校验', () {
    // 真机事实：这台 DSM 上 MD5 任务只活 25~50ms，所以客户端是
    // 「start → 立刻 status（0ms）→ 没过再 20/50/100ms → 还不行整对重来」。
    testWidgets('点计算 → start + 立刻 status：一次就出结果', (tester) async {
      final r = await _pumpSheet(
        tester,
        responses: {
          'SYNO.FileStation.MD5.start': {'taskid': 'M-1'},
          'SYNO.FileStation.MD5.status': {
            'finished': true,
            'md5': 'abc123def456',
          },
        },
      );

      await tester.tap(find.byKey(const Key('file-md5-start')));
      await tester.pump(); // running 态至少渲染一帧
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      final start = r.t.calls.firstWhere((c) => c['method'] == 'start');
      expect(start['api'], 'SYNO.FileStation.MD5');
      expect(start['file_path'], '["/home/report.pdf"]');
      expect('${start['version']}', '2');
      expect(find.text('abc123def456'), findsOneWidget);

      final n = r.t.calls.where((c) => c['method'] == 'status').length;
      expect(n, 1, reason: '第一拍就 finished，不该再问');
      await tester.pump(const Duration(seconds: 3));
      expect(r.t.calls.where((c) => c['method'] == 'status').length, 1);
    });

    testWidgets('结果被回收（599）→ 整对重来 4 轮后明说原因', (tester) async {
      final r = await _pumpSheet(
        tester,
        responses: {
          'SYNO.FileStation.MD5.start': {'taskid': 'M-2'},
        },
      );
      r.t.failures['SYNO.FileStation.MD5.status'] = 599;

      await tester.tap(find.byKey(const Key('file-md5-start')));
      await tester.pumpAndSettle();

      expect(
        r.t.calls.where((c) => c['method'] == 'start').length,
        4,
        reason: '任务被回收时应该重发 start，而不是干等到超时',
      );
      expect(find.textContaining('没保住结果'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('服务端说算不了（errors）→ 给出解释并可重试', (tester) async {
      await _pumpSheet(
        tester,
        responses: {
          'SYNO.FileStation.MD5.start': {'taskid': 'M-3'},
          'SYNO.FileStation.MD5.status': {
            'finished': false,
            'errors': [
              {'code': 408, 'path': '/home/report.pdf'},
            ],
          },
        },
      );

      await tester.tap(find.byKey(const Key('file-md5-start')));
      await tester.pumpAndSettle();

      expect(find.textContaining('算不了'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('start 失败 → 显示原因，按钮变重试', (tester) async {
      await _pumpSheet(tester, failures: {'SYNO.FileStation.MD5.start'});
      await tester.tap(find.byKey(const Key('file-md5-start')));
      await tester.pumpAndSettle();
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('正在计算…'), findsNothing);
    });

    testWidgets('复制：写入剪贴板 + 图标变对勾（面板是模态的，SnackBar 会被挡）', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add('${(call.arguments as Map)['text']}');
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await _pumpSheet(
        tester,
        responses: {
          'SYNO.FileStation.MD5.start': {'taskid': 'M-5'},
          'SYNO.FileStation.MD5.status': {
            'finished': true,
            'md5': 'abc123def456',
          },
        },
      );
      await tester.tap(find.byKey(const Key('file-md5-start')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('file-md5-copy')));
      await tester.pumpAndSettle();

      expect(copied, ['abc123def456']);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      // 1.5s 后恢复成复制图标
      await tester.pump(const Duration(seconds: 2));
      expect(find.byIcon(Icons.check_circle_outline), findsNothing);
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
    });

    testWidgets('算的过程中显示"正在计算…"（start 还没回时）', (tester) async {
      await _pumpSheet(
        tester,
        responses: {
          'SYNO.FileStation.MD5.start': {'taskid': 'M-4'},
          'SYNO.FileStation.MD5.status': {'finished': false},
        },
      );
      await tester.tap(find.byKey(const Key('file-md5-start')));
      await tester.pump();
      expect(find.text('正在计算…'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('正在计算…'), findsNothing);
    });
  });
}
