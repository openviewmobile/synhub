// ★★ **③Drive 第 54 轮：D49 的 UI 半边** —— 命中片段**真的被画出来**
//
// ## 为什么单独一份 widget 用例
// 数据层用例（`drive_search_snippet_test.dart`）只能证明 **DTO 拿到了片段**。
// 而 D49 的缺口原文是「命中无**片段 UI**」—— 属于**渲染**，
// 只有 widget 用例能证。**"动了 ≠ 动对了"**：DTO 有值但 UI 不画，
// 缺口依然在。
//
// ## 两条必须同时成立的断言
// ① 有片段 ⇒ 树上**能找到**那段文字；
// ② **没**片段 ⇒ 树上**完全没有**这个节点（不是空占位、不是空行）。
// 只测 ① 的话，一个"恒显示空 Text"的实现也能过 —— 那是**假绿**。
//
// 全程假传输，不碰真机（规程 §5.1）。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/drive/drive_search_page.dart';
import 'package:synhub/src/features/files/drive_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
};

/// 造一条搜索结果（可选带 `content_snippet`）。
///
/// ⚠️ `FakeTransport.responses` 存的是 **data**（不是完整信封）——
/// 我第一次塞了整个 `{success, data}` 进去，被传输层**再嵌一层**，
/// 于是 `data['items']` 取不到、页面显示"没有找到匹配项"。
Map<String, dynamic> _searchData({String? snippet}) => {
  'total': 1,
  'items': [
    {
      'file_id': 'fid-1',
      'name': '季度报告.docx',
      'type': 'file',
      'size': 2048,
      'content_type': 'application/vnd.openxmlformats',
      'display_path': '/mydrive/文档',
      'modified_time': 1700000000,
      'content_snippet': ?snippet,
    },
  ],
};

Future<void> _pump(WidgetTester tester, {String? snippet}) async {
  final responses = <String, Map<String, dynamic>>{
    'SYNO.SynologyDrive.Files.search': _searchData(snippet: snippet),
  };
  final t = FakeTransport(responses, {...FakeTransport.table, ..._table});
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    return {...?responses[key], 'success': true};
  };
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      driveApiProvider.overrideWithValue(DriveApi(api)),
    ],
  );
  addTearDown(c.dispose);
  addTearDown(db.close);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: DriveSearchPage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));

  // ★ 页面初始是"最近搜索/引导空态"，必须**真的触发一次搜索**
  // 才会渲染结果行 —— 不触发就测不到片段。
  await tester.enterText(find.byKey(const Key('drive-search-field')), '营收');
  await tester.tap(find.byKey(const Key('drive-search-submit')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('★ 有 `content_snippet` ⇒ 结果行里真的能看到那段文字', (tester) async {
    await _pump(tester, snippet: '…本季度营收同比增长 12%…');
    expect(find.text('季度报告.docx'), findsOneWidget, reason: '结果行本身要在');
    expect(
      find.text('…本季度营收同比增长 12%…'),
      findsOneWidget,
      reason: '★ D49 的缺口就是"命中无片段 UI"—— 这一步证明片段被画出来了',
    );
  });

  testWidgets('★★ **没有**片段 ⇒ 树上完全没有该节点（不是空占位）', (tester) async {
    await _pump(tester, snippet: null);
    expect(find.text('季度报告.docx'), findsOneWidget, reason: '结果行本身要在');
    // 关键：这一条防"恒显示一个空 Text"的假绿实现。
    // 片段文本此时为空串，`if (e.snippet.isNotEmpty)` 应让节点**不存在**。
    final empties = find.byWidgetPredicate((w) => w is Text && w.data == '');
    expect(
      empties,
      findsNothing,
      reason:
          '★ 空片段不能留一个空 Text —— 那会多出空白行，'
          '而且会让"有片段"的用例靠别的路径假绿',
    );
  });
}
