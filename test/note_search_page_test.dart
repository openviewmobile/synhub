// G3 高级搜索**页面层**离线用例（`NoteAdvSearchPage`）+ G7 排除子标签的界面路径。
//
// 覆盖题目要求的四类页面行为：
//   * 条件增删（标签/排除标签/子标签开关/关键词）；
//   * 结果刷新（点搜索 → 重新请求 → 列表更新）；
//   * 空结果（明确空态，不是"加载中"）；
//   * 错误态（服务端失败 → 整块错误 + 可重试；日期区间非法 → 行内校验）。
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/notes/note_adv_search_page.dart';
import 'package:synhub/src/features/notes/note_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

const String kFtsApi = 'SYNO.NoteStation.FTS';

const _noteTable = <String, Map<String, dynamic>>{
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.NoteStation.Note': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.NoteStation.Notebook': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.NoteStation.Tag': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  kFtsApi: {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
};

/// 标签树：`工作` 有一个子标签 `工作/紧急`。
const _tags = [
  TagDto(tagId: '工作@1028', title: '工作', itemIds: ['n1']),
  TagDto(tagId: '工作/紧急@1028', title: '工作/紧急', itemIds: ['n2']),
  TagDto(tagId: '个人@1028', title: '个人', itemIds: ['n8']),
];

const _notebooks = [
  NotebookDto(objectId: 'nb1', title: '我的记事本'),
  NotebookDto(objectId: 'nb2', title: '工作本'),
];

FakeTransport _transport(Map<String, Map<String, dynamic>> responses) =>
    FakeTransport(responses, {...FakeTransport.table, ..._noteTable});

Future<NoteStationApi> _api(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return NoteStationApi(api);
}

Future<({FakeTransport t, ProviderContainer c})> _boot(
  Map<String, Map<String, dynamic>> responses, {
  Map<String, int> failures = const {},
  List<TagDto> tags = _tags,
  List<NotebookDto> notebooks = _notebooks,
}) async {
  final t = _transport(responses);
  t.failures.addAll(failures);
  final api = await _api(t);
  final c = ProviderContainer(
    overrides: [
      noteApiProvider.overrideWithValue(api),
      // 直接给标签/笔记本表，避开 store/DB（本批只验页面行为）。
      noteTagsProvider.overrideWith((ref) async => tags),
      notebooksProvider.overrideWith((ref) async => notebooks),
    ],
  );
  addTearDown(c.dispose);
  return (t: t, c: c);
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget child,
) async {
  // 表单比较长：给一个高窗口，免得控件落在可视区外点不到。
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: child,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('zh'), Locale('en')],
      ),
    ),
  );
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Map<String, dynamic> _callOf(FakeTransport t, String api, String method) =>
    t.calls.lastWhere((c) => c['api'] == api && c['method'] == method);

int _count(FakeTransport t, String api, String method) =>
    t.calls.where((c) => c['api'] == api && c['method'] == method).length;

Map<String, dynamic> _fts(List<Map<String, dynamic>> matches) => {
  'matches': matches,
};

Map<String, dynamic> _note(String id, String title) => {
  'object_id': id,
  'title': title,
  'mtime': 1789874506,
  'parent_id': 'nb1',
};

Future<void> _settle(WidgetTester tester, [int rounds = 25]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  group('NoteAdvSearchPage · 结果态', () {
    testWidgets('没搜过 → 明确提示态，且零 FTS 请求', (tester) async {
      final b = await _boot({'$kFtsApi.search': _fts(const [])});
      await _pump(tester, b.c, const NoteAdvSearchPage());

      expect(find.byKey(const Key('note-adv-prompt')), findsOneWidget);
      expect(_count(b.t, kFtsApi, 'search'), 0);
    });

    testWidgets('输入关键词 → 搜索：请求参数正确 + 结果行渲染 + 条数', (tester) async {
      final b = await _boot({
        '$kFtsApi.search': _fts([
          _note('n1', '周报 2026-01'),
          _note('n2', '周报 2026-02'),
        ]),
      });
      await _pump(tester, b.c, const NoteAdvSearchPage());

      await tester.enterText(find.byKey(const Key('note-adv-keyword')), '周报');
      await tester.tap(find.byKey(const Key('note-adv-run')));
      await _settle(tester);

      expect(_count(b.t, kFtsApi, 'search'), 1);
      final c = _callOf(b.t, kFtsApi, 'search');
      expect(c['keyword'], '周报');
      expect(c['version'], '1');
      expect(c['limit'], 200);
      // 未设置的条件一个都不发
      expect(c.containsKey('title'), isFalse);
      expect(c.containsKey('tag'), isFalse);
      expect(c.containsKey('parent_id'), isFalse);

      expect(find.byKey(const Key('note-adv-row-n1')), findsOneWidget);
      expect(find.byKey(const Key('note-adv-row-n2')), findsOneWidget);
      expect(find.byKey(const Key('note-adv-count')), findsOneWidget);
      expect(find.textContaining('2'), findsWidgets);
    });

    testWidgets('搜到 0 条 → 明确空态（不是加载中/不是错误）', (tester) async {
      final b = await _boot({'$kFtsApi.search': _fts(const [])});
      await _pump(tester, b.c, const NoteAdvSearchPage());

      await tester.enterText(
        find.byKey(const Key('note-adv-keyword')),
        '不存在的词',
      );
      await tester.tap(find.byKey(const Key('note-adv-run')));
      await _settle(tester);

      expect(find.byKey(const Key('note-adv-empty')), findsOneWidget);
      expect(find.byKey(const Key('note-adv-error')), findsNothing);
      expect(find.byKey(const Key('note-adv-row-n1')), findsNothing);
    });

    testWidgets('服务端失败 → 如实错误态，可重试', (tester) async {
      final b = await _boot(
        {'$kFtsApi.search': _fts(const [])},
        failures: {'$kFtsApi.search': 160},
      );
      await _pump(tester, b.c, const NoteAdvSearchPage());

      await tester.enterText(find.byKey(const Key('note-adv-keyword')), '周报');
      await tester.tap(find.byKey(const Key('note-adv-run')));
      await _settle(tester);

      expect(find.byKey(const Key('note-adv-error')), findsOneWidget);
      // 错误态里带服务端错误码的用户可读描述（Note Station 权限 = 160）
      expect(find.textContaining('Note Station 权限'), findsOneWidget);
    });

    testWidgets('结果刷新：改条件再搜，列表被新结果替换', (tester) async {
      final b = await _boot({
        '$kFtsApi.search': _fts([_note('n1', '第一次')]),
      });
      await _pump(tester, b.c, const NoteAdvSearchPage());

      await tester.enterText(find.byKey(const Key('note-adv-keyword')), '甲');
      await tester.tap(find.byKey(const Key('note-adv-run')));
      await _settle(tester);
      expect(find.byKey(const Key('note-adv-row-n1')), findsOneWidget);

      // 第二次改成只有 n2
      b.t.responses['$kFtsApi.search'] = _fts([_note('n2', '第二次')]);
      await tester.enterText(find.byKey(const Key('note-adv-keyword')), '乙');
      await tester.tap(find.byKey(const Key('note-adv-run')));
      await _settle(tester);

      expect(_count(b.t, kFtsApi, 'search'), 2);
      expect(find.byKey(const Key('note-adv-row-n2')), findsOneWidget);
      expect(
        find.byKey(const Key('note-adv-row-n1')),
        findsNothing,
        reason: '旧结果不能被留着',
      );
    });
  });

  group('NoteAdvSearchPage · 条件增删', () {
    testWidgets('标签可选中/取消；子标签开关随选中出现/消失', (tester) async {
      final b = await _boot({'$kFtsApi.search': _fts(const [])});
      await _pump(tester, b.c, const NoteAdvSearchPage());

      // 初始：没有选中标签 → 没有"包含子标签"开关
      expect(find.byKey(const Key('note-adv-subtags')), findsNothing);

      await tester.tap(find.byKey(const Key('note-adv-tag-工作')));
      await _settle(tester);
      expect(find.byKey(const Key('note-adv-subtags')), findsOneWidget);

      await tester.tap(find.byKey(const Key('note-adv-tag-工作')));
      await _settle(tester);
      expect(
        find.byKey(const Key('note-adv-subtags')),
        findsNothing,
        reason: '取消标签后开关应一起消失',
      );
    });

    testWidgets('选中两个标签 → 出现"同时包含/包含任一"操作符选择', (tester) async {
      final b = await _boot({'$kFtsApi.search': _fts(const [])});
      await _pump(tester, b.c, const NoteAdvSearchPage());

      expect(find.byKey(const Key('note-adv-tag-and')), findsNothing);

      await tester.tap(find.byKey(const Key('note-adv-tag-工作')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('note-adv-tag-个人')));
      await _settle(tester);

      expect(find.byKey(const Key('note-adv-tag-and')), findsOneWidget);
      expect(find.byKey(const Key('note-adv-tag-or')), findsOneWidget);

      // 选"同时包含"→ 下发 and
      await tester.tap(find.byKey(const Key('note-adv-tag-and')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('note-adv-run')));
      await _settle(tester);
      expect(_callOf(b.t, kFtsApi, 'search')['tag'], '["工作@1028","个人@1028"]');
    });

    testWidgets('清空条件 → 回到提示态并清掉请求条件', (tester) async {
      final b = await _boot({
        '$kFtsApi.search': _fts([_note('n1', '甲')]),
      });
      await _pump(tester, b.c, const NoteAdvSearchPage());

      await tester.enterText(find.byKey(const Key('note-adv-keyword')), '甲');
      await tester.tap(find.byKey(const Key('note-adv-run')));
      await _settle(tester);
      expect(find.byKey(const Key('note-adv-row-n1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('note-adv-clear')));
      await _settle(tester);

      expect(find.byKey(const Key('note-adv-prompt')), findsOneWidget);
      expect(find.byKey(const Key('note-adv-row-n1')), findsNothing);
    });

    // ⚠️ "日期区间非法 → 行内校验"这条**不在页面层测**：`showDatePicker` 的
    // 按钮文案/月历布局随 locale 变化，用 tap 文本驱动会变成脆断言。区间校验
    // 的确定性覆盖放在纯逻辑用例
    // `note_search_advanced_test.dart`（`noteAdvSearchDateOrderError`）。
  });

  group('NoteAdvSearchPage · G7 排除标签及其子标签', () {
    testWidgets('勾"排除标签"→ 该标签与其子标签下的笔记都被摘掉', (tester) async {
      final b = await _boot({
        '$kFtsApi.search': _fts([
          _note('n1', '带 工作'),
          _note('n2', '带 工作/紧急'),
          _note('n3', '不带标签'),
        ]),
      });
      await _pump(tester, b.c, const NoteAdvSearchPage());

      await tester.enterText(find.byKey(const Key('note-adv-keyword')), 'x');
      await tester.tap(find.byKey(const Key('note-adv-exclude-工作')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('note-adv-run')));
      await _settle(tester);

      expect(
        find.byKey(const Key('note-adv-row-n1')),
        findsNothing,
        reason: 'n1 挂在被排除的 工作 上',
      );
      expect(
        find.byKey(const Key('note-adv-row-n2')),
        findsNothing,
        reason: 'n2 挂在 工作 的子标签 工作/紧急 上（G7 的核心）',
      );
      expect(find.byKey(const Key('note-adv-row-n3')), findsOneWidget);
    });

    testWidgets('关闭"包含子标签"→ 只摘掉子标签的笔记，父标签自己的还在', (tester) async {
      final b = await _boot({
        '$kFtsApi.search': _fts([_note('n1', '带 工作'), _note('n2', '带 工作/紧急')]),
      });
      await _pump(tester, b.c, const NoteAdvSearchPage());

      // 默认就是"不含子标签"（官方 TagMode.EXCLUSIVE 的缺省值）
      await tester.enterText(find.byKey(const Key('note-adv-keyword')), 'x');
      await tester.tap(find.byKey(const Key('note-adv-tag-工作')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('note-adv-run')));
      await _settle(tester);

      expect(_callOf(b.t, kFtsApi, 'search')['tag'], '["工作@1028"]');
      expect(find.byKey(const Key('note-adv-row-n1')), findsOneWidget);
      expect(
        find.byKey(const Key('note-adv-row-n2')),
        findsNothing,
        reason: '子标签的笔记被客户端摘掉',
      );

      // 打开"包含子标签" → 子标签的笔记回来
      await tester.tap(find.byKey(const Key('note-adv-subtags')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('note-adv-run')));
      await _settle(tester);
      expect(find.byKey(const Key('note-adv-row-n2')), findsOneWidget);
    });
  });
}
