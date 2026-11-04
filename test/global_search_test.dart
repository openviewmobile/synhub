// 任务 2 用例：`SYNO.Finder.*` 全局搜索（Universal Search）的存在性探测 +
// 入口显隐 + 结果分组。
//
// 关键纪律（父 agent 2026-09-21 更正）：
//   * 官方 JS 里**没有** `SYNO.Finder.FileIndexing.Search` 的请求体原文 →
//     **不发送猜测参数的 Finder 请求**；Finder 只做存在性门控；
//   * 搜索本体复用**参数有逐字证据**的模块 API：`SYNO.FileStation.Search`
//     （`filestation_api.dart:632`）+ `SYNO.NoteStation.FTS`
//     （官方 `notestation_plugin.js` 的 `{keyword,offset,limit}`）；
//   * `105`（allowUser 未验证）→ 入口自禁用（隐藏）；`119` → 提示但**不隐藏**。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart'
    show AppTextZh;
import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/finder_api.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/notes/note_providers.dart';
import 'package:synhub/src/features/search/global_search_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

Map<String, Map<String, dynamic>> _table({required bool finder}) {
  final table = <String, Map<String, dynamic>>{...FakeTransport.table};
  for (final spec in kServiceRegistry.values) {
    for (final api in spec.allApis) {
      table[api] = {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 9};
    }
  }
  table['SYNO.NoteStation.FTS'] = {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  };
  if (finder) {
    table[FinderApi.gateApi] = {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    };
  }
  return table;
}

Map<String, Map<String, dynamic>> _responses() => {
  'SYNO.FileStation.Search.start': {'taskid': 't-1', 'finished': true},
  'SYNO.FileStation.Search.list': {
    'total': 1,
    'offset': 0,
    'files': [
      {'path': '/volume1/report.pdf', 'name': 'report.pdf', 'isdir': false},
    ],
  },
  'SYNO.FileStation.Search.stop': <String, dynamic>{},
  'SYNO.FileStation.Search.clean': <String, dynamic>{},
  'SYNO.NoteStation.FTS.search': {
    'matches': [
      {
        'object_id': 'note-1',
        'title': '会议纪要',
        'parent_id': 'nb-1',
        'brief': '报告要点',
        'mtime': 1700000000,
      },
    ],
  },
};

Future<ChatHarness> _boot({
  required bool finder,
  Map<String, Map<String, dynamic>> extra = const {},
}) async {
  // 与 `service_capability_degrade_test.dart` 同款：能力检测 / 模块 API 用
  // "盒子"在 boot 之后指向同一条假传输（不依赖会话状态的时机）。
  DsmWebApi? availBox;
  FileStationApi? fileBox;
  NoteStationApi? noteBox;
  final h = await bootChat(
    extra: {..._responses(), ...extra},
    apiTable: _table(finder: finder),
    moreOverrides: <Object>[
      availabilityApiProvider.overrideWith((ref) => availBox),
      fileApiProvider.overrideWith((ref) => fileBox),
      noteApiProvider.overrideWith((ref) => noteBox),
    ],
  );
  availBox = h.api;
  fileBox = FileStationApi(h.api);
  noteBox = NoteStationApi(h.api);
  await h.container.read(serviceAvailabilityProvider.notifier).refresh();
  return h;
}

Future<void> _pumpEntry(WidgetTester tester, ChatHarness h) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: GlobalSearchEntry())),
    ),
  );
  await tester.pump();
}

/// 提交一次全局搜索（跳过骨架动画，用显式 pump）。
Future<void> _submit(WidgetTester tester, String keyword) async {
  await tester.enterText(find.byKey(const Key('global-search-field')), keyword);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('classifyFinderGate（纯判定）', () {
    test('没拿到能力表（未检测）→ unknown，fail-open 不隐藏', () {
      final s = classifyFinderGate(probed: false, apiNames: const {});
      expect(s, FinderGateState.unknown);
      expect(hidesFinderEntry(s), isFalse);
    });

    test('能力表里有 FileIndexing.Search → available', () {
      final s = classifyFinderGate(probed: true, apiNames: {FinderApi.gateApi});
      expect(s, FinderGateState.available);
      expect(hidesFinderEntry(s), isFalse);
    });

    test('能力表里明确没有 → absent（隐藏入口）', () {
      final s = classifyFinderGate(
        probed: true,
        apiNames: {'SYNO.FileStation.List'},
      );
      expect(s, FinderGateState.absent);
      expect(hidesFinderEntry(s), isTrue);
    });

    test('105 / 160 → noPermission（隐藏，即便表里有）', () {
      for (final code in [105, 160]) {
        final s = classifyFinderGate(
          probed: true,
          apiNames: {FinderApi.gateApi},
          errorCode: code,
        );
        expect(s, FinderGateState.noPermission);
        expect(hidesFinderEntry(s), isTrue);
      }
    });

    test('119 / 106 → sessionExpired（**绝不隐藏**，即便表里没有）', () {
      for (final code in [119, 106]) {
        final s = classifyFinderGate(
          probed: true,
          apiNames: const {},
          errorCode: code,
        );
        expect(s, FinderGateState.sessionExpired);
        expect(hidesFinderEntry(s), isFalse);
      }
    });
  });

  group('全局搜索入口 + 结果分组', () {
    testWidgets('① 有 Finder → 入口出现；搜索后结果按「文件 / 笔记」分组', (tester) async {
      final h = await _boot(finder: true);
      await _pumpEntry(tester, h);

      expect(find.byKey(const Key('global-search-entry')), findsOneWidget);
      await tester.tap(find.byKey(const Key('global-search-entry')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('global-search-page')), findsOneWidget);

      await _submit(tester, '报告');

      expect(
        find.byKey(const Key('global-search-group-files')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('global-search-group-notes')),
        findsOneWidget,
      );
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('会议纪要'), findsOneWidget);

      // 参数形态：文件搜索发了 `pattern`，笔记搜索发了官方原文的
      // `keyword/offset/limit`（不猜字段名）。
      final calls = h.transport.calls;
      final fs = calls.firstWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.FileStation.Search.start',
      );
      expect(fs['pattern'], '报告');
      final fts = calls.firstWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.NoteStation.FTS.search',
      );
      expect(fts['keyword'], '报告');
      expect(fts['limit'], 50);
      expect(fts.containsKey('offset'), isTrue);

      // **不发**任何猜测参数的 Finder 请求。
      expect(
        calls.any((c) => '${c['api']}'.startsWith('SYNO.Finder.')),
        isFalse,
        reason: '参数未取证 → 绝不发送 Finder 搜索请求',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('② 无 Finder → 入口隐藏', (tester) async {
      final h = await _boot(finder: false);
      await _pumpEntry(tester, h);

      expect(find.byKey(const Key('global-search-entry')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('③ 搜索调用返回 105 → 无权限提示 + 入口隐藏（自禁用）', (tester) async {
      final h = await _boot(finder: true);
      h.transport.failures['SYNO.FileStation.Search.start'] = 105;
      await _pumpEntry(tester, h);
      await tester.tap(find.byKey(const Key('global-search-entry')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await _submit(tester, '报告');
      expect(find.text(AppTextZh().errNoAppPrivilege), findsWidgets);

      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const Key('global-search-entry')),
        findsNothing,
        reason: 'allowUser 未验证 → 105 时入口自禁用',
      );
    });

    testWidgets('④ 会话失效（119）→ 入口保留但置灰，不隐藏', (tester) async {
      final h = await _boot(finder: true);
      h.container.read(finderCallErrorProvider.notifier).report(119);
      await _pumpEntry(tester, h);

      expect(find.byKey(const Key('global-search-entry')), findsOneWidget);
      expect(find.text(AppTextZh().serviceEntrySessionExpired), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
