// G3 笔记高级搜索 + G7 排除子标签 —— **接口层 / 纯逻辑**离线用例。
//
// 覆盖：
//   * 查询构造（时间换算、标签标题→标签 id、空条件判定、清除）；
//   * **线上参数编码**（只发行为已取证的参数名；被服务端静默忽略的名字一个都不发）；
//   * **版本协商**（`FTS/search` v1；能力表缺失时回落，不臆造高版本）；
//   * G7 的子标签展开与"排除标签及其子标签"集合运算。
//
// 取证口径见 `lib/src/data/note_api.dart#searchNotes` 与
// `lib/src/features/notes/note_adv_search.dart` 顶部注释。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/notes/note_adv_search.dart';

import 'support/chat_harness.dart' show FakeTransport;

const String kFtsApi = 'SYNO.NoteStation.FTS';

/// 真机 `SYNO.API.Info` 快照子集（本批用到的都在）。
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

FakeTransport _transport(
  Map<String, Map<String, dynamic>> responses, {
  Map<String, Map<String, dynamic>> table = const {},
}) =>
    FakeTransport(responses, {...FakeTransport.table, ..._noteTable, ...table});

Future<NoteStationApi> _api(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return NoteStationApi(api);
}

Map<String, dynamic> _callOf(FakeTransport t, String api, String method) =>
    t.calls.lastWhere((c) => c['api'] == api && c['method'] == method);

/// `Tag/list` 的投影（标题 + 该标签**直接**挂的笔记 id）。
List<({String title, List<String> itemIds})> _tree(
  Map<String, List<String>> byTitle,
) => [for (final e in byTitle.entries) (title: e.key, itemIds: e.value)];

void main() {
  // ============================================================ 查询构造

  group('NoteAdvSearchQuery · 条件构造', () {
    test('时间：下界取当天 0 点，上界取**次日** 0 点（官方 setTo 的 add(6,1)）', () {
      final q = NoteAdvSearchQuery(
        mtimeFrom: DateTime(2026, 1, 5, 15, 30),
        mtimeTo: DateTime(2026, 1, 5, 9, 1),
        ctimeFrom: DateTime(2026, 2, 1, 23, 59),
        ctimeTo: DateTime(2026, 2, 1),
      );
      final day = DateTime(2026, 1, 5).millisecondsSinceEpoch ~/ 1000;
      final next = DateTime(2026, 1, 6).millisecondsSinceEpoch ~/ 1000;
      final cday = DateTime(2026, 2, 1).millisecondsSinceEpoch ~/ 1000;
      final cnext = DateTime(2026, 2, 2).millisecondsSinceEpoch ~/ 1000;

      expect(q.mtimeFromSeconds, day, reason: '下界含当天 0 点');
      expect(q.mtimeToSeconds, next, reason: '上界是次日 0 点（开区间）');
      expect(q.ctimeFromSeconds, cday);
      expect(q.ctimeToSeconds, cnext);
      expect(q.mtimeToSeconds! - q.mtimeFromSeconds!, 86400);
    });

    test('标签标题 → 服务端要的标签 id（取不到的丢掉，顺序保持）', () {
      const q = NoteAdvSearchQuery(tagTitles: ['工作', '知识/灵感', '不存在']);
      final ids = q.resolvedTagIds(const {
        '工作': '工作@1028',
        '知识/灵感': '知识/灵感@1028',
      });
      expect(ids, ['工作@1028', '知识/灵感@1028']);
    });

    test('空条件判定：任何一格有值就不算空（含"只排除标签"）', () {
      expect(const NoteAdvSearchQuery().isEmpty, isTrue);
      expect(const NoteAdvSearchQuery(keyword: '周报').isEmpty, isFalse);
      expect(const NoteAdvSearchQuery(title: '周报').isEmpty, isFalse);
      expect(const NoteAdvSearchQuery(tagTitles: ['工作']).isEmpty, isFalse);
      expect(
        const NoteAdvSearchQuery(excludeTagTitles: ['工作']).isEmpty,
        isFalse,
        reason: '只设"排除标签"也是有效条件',
      );
      expect(NoteAdvSearchQuery(mtimeFrom: DateTime(2026)).isEmpty, isFalse);
      expect(const NoteAdvSearchQuery(keyword: '   ').isEmpty, isTrue);
    });

    test('copyWith：能清除单个时间端点，不影响别的格', () {
      final q = NoteAdvSearchQuery(
        keyword: '周报',
        mtimeFrom: DateTime(2026, 1, 1),
        mtimeTo: DateTime(2026, 1, 31),
      );
      final cleared = q.copyWith(clearMtimeFrom: true);
      expect(cleared.mtimeFrom, isNull);
      expect(cleared.mtimeTo, DateTime(2026, 1, 31));
      expect(cleared.keyword, '周报');
      expect(q.mtimeFrom, isNotNull, reason: '不可变：原对象不动');
    });

    test('日期区间校验：起始晚于结束报错，相等/未设不报错', () {
      expect(
        noteAdvSearchDateOrderError(DateTime(2026, 1, 2), DateTime(2026, 1, 1)),
        'noteAdvSearchDateInvalid',
      );
      expect(
        noteAdvSearchDateOrderError(DateTime(2026, 1, 1), DateTime(2026, 1, 1)),
        isNull,
      );
      expect(noteAdvSearchDateOrderError(null, DateTime(2026, 1, 1)), isNull);
    });
  });

  // ============================================================ G7 子标签

  group('G7 · 排除子标签（客户端集合运算）', () {
    test('子树展开：含自身 + 全部后代；不误伤同前缀的"兄弟"', () {
      final all = ['work', 'work/urgent', 'work/urgent/今天', 'workshop', '个人'];
      expect(
        noteTagSubtreeTitles(all, 'work'),
        containsAll(<String>['work', 'work/urgent', 'work/urgent/今天']),
      );
      final subtree = noteTagSubtreeTitles(all, 'work');
      expect(subtree, isNot(contains('workshop')), reason: 'workshop 不是子标签');
      expect(subtree, isNot(contains('个人')));
      expect(
        noteTagSubtreeTitles(all, 'work', includeRoot: false),
        isNot(contains('work')),
      );
    });

    test('排除"某标签及其子标签"：并上这些标签的直接成员', () {
      final tags = _tree({
        'work': ['n1'],
        'work/urgent': ['n2', 'n3'],
        'workshop': ['n9'],
        '个人': ['n8'],
      });
      final excluded = excludedNoteIdsForTags(tags, ['work']);
      expect(excluded, {'n1', 'n2', 'n3'}, reason: '自身 + 子标签；不碰 workshop/个人');
      final descendantsOnly = excludedNoteIdsForTags(tags, [
        'work',
      ], includeRoot: false);
      expect(descendantsOnly, {'n2', 'n3'});
    });

    test('clientExcludedNoteIds：排除标签含自身；"不含子标签"只排后代', () {
      final tags = _tree({
        'work': ['n1'],
        'work/urgent': ['n2'],
        'archive': ['n7'],
        'archive/2025': ['n8'],
      });

      // ① 显式排除标签 → 连子标签
      const q1 = NoteAdvSearchQuery(excludeTagTitles: ['archive']);
      expect(q1.clientExcludedNoteIds(tags), {'n7', 'n8'});

      // ② 选中标签但关闭"包含子标签" → 只排该标签的**后代**
      const q2 = NoteAdvSearchQuery(tagTitles: ['work'], includeSubTags: false);
      expect(q2.clientExcludedNoteIds(tags), {
        'n2',
      }, reason: '不能把 work 自己的命中（n1）也排掉');

      // ③ 打开"包含子标签" → 不排任何东西
      const q3 = NoteAdvSearchQuery(tagTitles: ['work'], includeSubTags: true);
      expect(q3.clientExcludedNoteIds(tags), isEmpty);

      // ④ 两者叠加
      const q4 = NoteAdvSearchQuery(
        tagTitles: ['work'],
        includeSubTags: false,
        excludeTagTitles: ['archive'],
      );
      expect(q4.clientExcludedNoteIds(tags), {'n2', 'n7', 'n8'});
    });

    test('结果过滤保持服务器返回顺序，只摘 id 命中的', () {
      final rows = [
        NoteDto(objectId: 'n1', title: 'a'),
        NoteDto(objectId: 'n2', title: 'b'),
        NoteDto(objectId: 'n3', title: 'c'),
      ];
      final kept = applyNoteIdExclusions(rows, (n) => n.objectId, {'n2'});
      expect(kept.map((n) => n.objectId).toList(), ['n1', 'n3']);
      expect(
        applyNoteIdExclusions(rows, (n) => n.objectId, const <String>{}),
        same(rows),
        reason: '空集合不做无谓拷贝',
      );
    });
  });

  // ============================================================ 线上参数

  group('FTS/search · 线上参数编码（行为已取证的名字）', () {
    test(
      '★全条件：只发 keyword/title/tag/parent_id/mtime_*/ctime_*/offset/limit',
      () async {
        final t = _transport({
          '$kFtsApi.search': {'matches': <dynamic>[]},
        });
        final api = await _api(t);

        await api.searchNotes(
          keyword: '周报',
          title: '周报',
          tagIds: ['工作@1028'],
          parentIds: ['1028_nb1'],
          mtimeStart: 100,
          mtimeEnd: 200,
          ctimeStart: 300,
          ctimeEnd: 400,
          limit: 20,
        );

        final c = _callOf(t, kFtsApi, 'search');
        expect(c['keyword'], '周报');
        // NoteStation 的字符串参数走 Gson 引号串；真机两种形态都吃（已探针）。
        expect(c['title'], '"周报"');
        expect(c['tag'], '["工作@1028"]');
        expect(c['parent_id'], '["1028_nb1"]');
        expect(c['mtime_start'], 100);
        expect(c['mtime_end'], 200);
        expect(c['ctime_start'], 300);
        expect(c['ctime_end'], 400);
        expect(c['offset'], 0);
        expect(c['limit'], 20);
      },
    );

    test('★绝不发被服务端静默忽略的名字（行为对照已证它们不过滤）', () async {
      final t = _transport({
        '$kFtsApi.search': {'matches': <dynamic>[]},
      });
      final api = await _api(t);
      await api.searchNotes(
        keyword: '周报',
        title: '周报',
        tagIds: ['t@1028'],
        parentIds: ['nb'],
        mtimeStart: 1,
        mtimeEnd: 2,
        ctimeStart: 3,
        ctimeEnd: 4,
      );
      final c = _callOf(t, kFtsApi, 'search');
      for (final banned in const [
        'note_title',
        'title_contains',
        'notebook',
        'parent_ids',
        'notebooks',
        'date_from',
        'date_to',
        'start_date',
        'end_date',
        'date_start',
        'date_end',
        'time_from',
        'time_to',
        'mtime_from',
        'mtime_to',
        'exclude_tag',
        'exclude_tags',
        'tag_exclude_subtag',
        'smart_id',
      ]) {
        expect(c.containsKey(banned), isFalse, reason: '不许发 $banned');
      }
    });

    test('空 keyword 不发（真机空 keyword 回 0 条）→ 支持"只按标题搜"', () async {
      final t = _transport({
        '$kFtsApi.search': {
          'matches': [
            {'object_id': 'n1', 'title': '周报'},
          ],
        },
      });
      final api = await _api(t);
      final rows = await api.searchNotes(
        keyword: '   ',
        title: '周报',
        limit: 50,
      );
      expect(rows.single.objectId, 'n1');
      final c = _callOf(t, kFtsApi, 'search');
      expect(c.containsKey('keyword'), isFalse);
      expect(c['title'], '"周报"');
    });

    test('未设置的条件一律不下发（opts-off 全空 → 只剩分页）', () async {
      final t = _transport({
        '$kFtsApi.search': {'matches': <dynamic>[]},
      });
      final api = await _api(t);
      await api.searchNotes(keyword: 'a');
      final c = _callOf(t, kFtsApi, 'search');
      expect(c.containsKey('title'), isFalse);
      expect(c.containsKey('tag'), isFalse);
      expect(c.containsKey('parent_id'), isFalse);
      expect(c.containsKey('mtime_start'), isFalse);
      expect(c.containsKey('ctime_end'), isFalse);
    });

    test('结果取 root data.matches；非列表时安全回空', () async {
      final t = _transport({
        '$kFtsApi.search': {
          'matches': [
            {'object_id': 'n1', 'title': '甲', 'mtime': 10},
            {'object_id': 'n2', 'title': '乙', 'mtime': 20},
          ],
        },
      });
      final api = await _api(t);
      final rows = await api.searchNotes(keyword: 'a');
      expect(rows.map((n) => n.objectId).toList(), ['n1', 'n2']);
      expect(rows.first.title, '甲');
    });

    test('服务端失败：如实抛错（不静默回空列表）', () async {
      final t = _transport({
        '$kFtsApi.search': {'matches': <dynamic>[]},
      });
      t.failures['$kFtsApi.search'] = 160;
      final api = await _api(t);
      await expectLater(
        api.searchNotes(keyword: 'a'),
        throwsA(isA<DsmApiException>()),
      );
    });
  });

  // ============================================================ 版本协商

  group('FTS/search · 版本协商', () {
    test('能力表 maxVersion=1 → 请求 version=1', () async {
      final t = _transport({
        '$kFtsApi.search': {'matches': <dynamic>[]},
      });
      final api = await _api(t);
      await api.searchNotes(keyword: 'a');
      expect(_callOf(t, kFtsApi, 'search')['version'], '1');
    });

    test('能力表里没有 FTS → 回落候选首项（不臆造高版本）', () async {
      final t = _transport(
        {
          '$kFtsApi.search': {'matches': <dynamic>[]},
        },
        table: {
          kFtsApi: {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
        },
      );
      // 覆盖掉表里的 FTS 后仍应是 v1
      final api = await _api(t);
      await api.searchNotes(keyword: 'a');
      expect(_callOf(t, kFtsApi, 'search')['version'], '1');
    });

    test('能力表说 maxVersion=2（假想新服务器）也不越界：仍发 v1', () async {
      final t = FakeTransport(
        {
          '$kFtsApi.search': {'matches': <dynamic>[]},
        },
        {
          ...FakeTransport.table,
          ..._noteTable,
          kFtsApi: {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2},
        },
      );
      final api = await _api(t);
      await api.searchNotes(keyword: 'a');
      expect(_callOf(t, kFtsApi, 'search')['version'], '1');
    });
  });
}
