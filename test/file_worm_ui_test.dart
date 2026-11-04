// 属性面板 WriteOnce / WORM 分区（页面层）。
//
// 三条硬规则各一个用例（对应真机"没有 WORM 是常态"这一事实）：
//   1. 服务端回 `def_lock_mode` ∈ {Manual, Normal} ⇒ 显示**未启用**，**不是**错误；
//   2. `SYNO.FileStation.Worm` 不在能力表里 ⇒ 整块隐藏且**不发探测**；
//   3. 分区里只出现模式/启用态/时长/状态名 —— **内部 path / pid 不上屏**。
//
// 真机数据来自本会话只读探针（`def_lock_mode:2, subvol_mode:1, lock_wait_time:-1,
// def_lock_duration:-1`），枚举数值来自官方 `FileBrowserUtil.js`。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
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

const _baseTable = <String, Map<String, dynamic>>{
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
  'SYNO.FileStation.Worm': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

FileEntryDto _file() => FileEntryDto.fromJson({
  'name': 'report.pdf',
  'path': '/home/report.pdf',
  'isdir': false,
  'filesize': 2048,
  'mtime': 1789000000,
  'owner': 'demo_user',
  'additional': {'size': 2048},
});

Future<FakeTransport> _pump(
  WidgetTester tester, {
  Map<String, Map<String, dynamic>> responses = const {},
  bool withWormApi = true,
}) async {
  final table = Map<String, Map<String, dynamic>>.from(_baseTable);
  if (!withWormApi) table.remove('SYNO.FileStation.Worm');
  final t = FakeTransport(<String, Map<String, dynamic>>{}, {
    ...FakeTransport.table,
    ...table,
  });
  for (final e in responses.entries) {
    t.responses[e.key] = e.value;
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
              onPressed: () => showFilePropertiesSheet(context, _file()),
              child: const Text('打开属性'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开属性'));
  await tester.pumpAndSettle();
  return t;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('自动锁定为 Immutable ⇒ 模式 + 已启用 + 等待时间 + 锁定期间', (tester) async {
    await _pump(
      tester,
      responses: {
        'SYNO.FileStation.Worm.get_share_info': {
          'subvol_mode': 3, // Compliance
          'def_lock_mode': 3, // Immutable ⇒ 启用
          'lock_wait_time': 3600, // 1 小时
          'def_lock_duration': 604800, // 7 天
        },
      },
    );
    await tester.pumpAndSettle();

    expect(find.text('WriteOnce'), findsOneWidget);
    expect(find.text('Compliance'), findsOneWidget);
    expect(find.text('已启用'), findsOneWidget);
    expect(find.text('1 小时'), findsOneWidget);
    expect(find.text('7 天'), findsOneWidget);
  });

  testWidgets('真机值（def_lock_mode=2 Normal）⇒ 显示未启用，且**不报错**', (tester) async {
    await _pump(
      tester,
      responses: {
        'SYNO.FileStation.Worm.get_share_info': {
          'subvol_mode': 1,
          'def_lock_mode': 2,
          'lock_wait_time': -1,
          'def_lock_duration': -1,
        },
      },
    );
    await tester.pumpAndSettle();

    expect(find.text('WriteOnce'), findsOneWidget);
    expect(find.text('Normal'), findsOneWidget);
    expect(find.text('未启用'), findsOneWidget);
    // 未启用时不该出现任何"错误/失败/不可用"文案
    for (final bad in ['失败', '错误', '不可用', '加载失败', '403', '1500']) {
      expect(find.textContaining(bad), findsNothing, reason: '未启用不是错误');
    }
    // 未启用时也不该把"-1"这种内部值直接上屏（只查整串，别误伤日期里的 "09-10"）
    expect(find.text('-1'), findsNothing);
  });

  testWidgets('服务端没有 Worm API ⇒ 整块隐藏，且**不发探测**', (tester) async {
    final t = await _pump(tester, withWormApi: false);
    await tester.pumpAndSettle();

    expect(find.text('WriteOnce'), findsNothing);
    expect(
      t.calls.any((c) => '${c['api']}'.contains('Worm')),
      isFalse,
      reason: '缺失 → 隐藏，且不发探测（规程 §4.5）',
    );
  });

  testWidgets('属性页只出现一次路径：WORM 分区不上屏内部 path/id', (tester) async {
    await _pump(
      tester,
      responses: {
        'SYNO.FileStation.Worm.get_share_info': {
          'subvol_mode': 1,
          'def_lock_mode': 3,
          'lock_wait_time': 0,
          'def_lock_duration': 0,
        },
        'SYNO.FileStation.Worm.get': {
          'worm_state': 4,
          'lock_time': 1789000000,
          'unlock_time': 1800000000,
          'pid': 31101,
        },
      },
    );
    await tester.pumpAndSettle();

    // 已有的"路径"行只有一条；WORM 分区不得再插一条
    expect(
      find.text('/home/report.pdf'),
      findsOneWidget,
      reason: '内部 path 只能在既有的路径行出现一次',
    );
    expect(find.textContaining('31101'), findsNothing, reason: 'pid 是内部 id');
    expect(find.text('锁定 (不可变)'), findsOneWidget);
  });
}
