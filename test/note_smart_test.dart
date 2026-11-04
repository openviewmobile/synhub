// 智能笔记本 / Shelf / 共享入口的纯逻辑用例（批次 B / F2、F6、J5）。
//
// 离线：只测 DTO 编解码与本地匹配/分组，不联网。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/features/notes/note_providers.dart';
import 'package:synhub/src/features/notes/note_shelf_page.dart';

NoteDto _note({
  String id = 'n1',
  String title = '会议记录',
  String brief = '本周排期',
  String parentId = 'nb1',
  List<String> tags = const [],
  int mtime = 1000,
  int ctime = 1000,
  bool individualJoined = false,
  bool individualShared = false,
  String? ownerName,
}) => NoteDto(
  objectId: id,
  title: title,
  brief: brief,
  parentId: parentId,
  tags: tags,
  mtime: mtime,
  ctime: ctime,
  individualJoined: individualJoined,
  individualShared: individualShared,
  ownerName: ownerName,
);

NotebookDto _nb(
  String id,
  String title, {
  String? stack,
  String? ownerName,
  bool individualShared = false,
}) => NotebookDto(
  objectId: id,
  title: title,
  stack: stack,
  ownerName: ownerName,
  individualShared: individualShared,
);

void main() {
  group('NoteSmartQuery · Gson 形态', () {
    test('create 的 query 总是带 tag_operator；null 字段不发', () {
      const q = NoteSmartQuery(keyword: '周报', tagAndOperator: true);
      expect(q.toJson(), {'keyword': '周报', 'tag_operator': 'and'});
      const or = NoteSmartQuery();
      expect(or.toJson(), {'tag_operator': 'or'});
    });

    test('全字段的 key 名与官方 QueryVo 一致', () {
      const q = NoteSmartQuery(
        parentIds: ['nb1'],
        tags: ['t1', 't2'],
        title: '标题',
        keyword: 'kw',
        mtimeStart: 10,
        mtimeEnd: 20,
        ctimeStart: 30,
        ctimeEnd: 40,
        tagAndOperator: true,
      );
      expect(q.toJson(), {
        'parent_id': ['nb1'],
        'tag': ['t1', 't2'],
        'mtime_end': 20,
        'mtime_start': 10,
        'ctime_end': 40,
        'ctime_start': 30,
        'title': '标题',
        'keyword': 'kw',
        'tag_operator': 'and',
      });
    });

    test('fromJson 去掉 tag 的 @uid 后缀，并识别 and/or', () {
      final q = NoteSmartQuery.fromJson({
        'parent_id': ['nb1'],
        'tag': ['t1@1028', 't2@1028'],
        'tag_operator': 'and',
        'keyword': 'kw',
      });
      expect(q.tags, ['t1', 't2']);
      expect(q.tagAndOperator, isTrue);
      expect(q.parentIds, ['nb1']);
      expect(q.keyword, 'kw');
      expect(normalizeTagId('abc@100'), 'abc');
      expect(normalizeTagId('abc'), 'abc');
    });

    test('相等性（family 复用需要）', () {
      const a = NoteSmartQuery(tags: ['x'], keyword: 'k');
      const b = NoteSmartQuery(tags: ['x'], keyword: 'k');
      const c = NoteSmartQuery(tags: ['x'], keyword: 'k2');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('NoteSmartQuery · 本地匹配', () {
    test('关键词命中标题 / 摘要 / 标签', () {
      final n = _note(title: '会议记录', brief: '本周排期', tags: ['work']);
      expect(const NoteSmartQuery(keyword: '会议').matches(n), isTrue);
      expect(const NoteSmartQuery(keyword: '排期').matches(n), isTrue);
      expect(const NoteSmartQuery(keyword: 'work').matches(n), isTrue);
      expect(const NoteSmartQuery(keyword: '无关').matches(n), isFalse);
    });

    test('标题是"包含"，不是等值', () {
      final n = _note(title: '会议记录');
      expect(const NoteSmartQuery(title: '会议').matches(n), isTrue);
      expect(const NoteSmartQuery(title: '记录').matches(n), isTrue);
      expect(const NoteSmartQuery(title: '会议记录').matches(n), isTrue);
      expect(const NoteSmartQuery(title: '其它').matches(n), isFalse);
    });

    test('标签 or 是"含任意"，and 是"全含"', () {
      final n = _note(tags: ['a@1', 'b@1']);
      expect(
        const NoteSmartQuery(
          tags: ['a', 'c'],
          tagAndOperator: false,
        ).matches(n),
        isTrue,
      );
      expect(
        const NoteSmartQuery(tags: ['a', 'c'], tagAndOperator: true).matches(n),
        isFalse,
      );
      expect(
        const NoteSmartQuery(tags: ['a', 'b'], tagAndOperator: true).matches(n),
        isTrue,
      );
    });

    test('限定笔记本', () {
      final n = _note(parentId: 'nb1');
      expect(const NoteSmartQuery(parentIds: ['nb1']).matches(n), isTrue);
      expect(const NoteSmartQuery(parentIds: ['nb2']).matches(n), isFalse);
    });

    test('日期区间按 mtime，闭区间', () {
      final n = _note(mtime: 1000);
      expect(
        const NoteSmartQuery(mtimeStart: 1000, mtimeEnd: 2000).matches(n),
        isTrue,
      );
      expect(const NoteSmartQuery(mtimeStart: 1001).matches(n), isFalse);
      expect(const NoteSmartQuery(mtimeEnd: 999).matches(n), isFalse);
    });

    test('没设的条件不参与：空 query 全命中', () {
      expect(const NoteSmartQuery().matches(_note()), isTrue);
      expect(const NoteSmartQuery().isEmpty, isTrue);
      expect(const NoteSmartQuery(keyword: 'x').isEmpty, isFalse);
    });

    test('多条件是与关系（keyword + tag 同时满足）', () {
      final n = _note(title: '会议记录', tags: ['work']);
      const q = NoteSmartQuery(keyword: '会议', tags: ['work']);
      expect(q.matches(n), isTrue);
      const q2 = NoteSmartQuery(keyword: '会议', tags: ['home']);
      expect(q2.matches(n), isFalse);
    });
  });

  group('SmartNotebookDto', () {
    test('解析官方 SmartVo.SmartDataVo 字段', () {
      final dto = SmartNotebookDto.fromJson({
        'object_id': 's1',
        'title': '工作',
        'query': {'keyword': 'k', 'tag_operator': 'or'},
        'ctime': 1,
        'mtime': 2,
        'category': 'c',
        'link_id': 'l',
        'perm': 'rw',
        'owner': {'username': 'alice'},
      });
      expect(dto.objectId, 's1');
      expect(dto.title, '工作');
      expect(dto.query.keyword, 'k');
      expect(dto.ownerName, 'alice');
      expect(dto.displayTitle, '工作');
    });

    test('空标题回落到"未命名智能笔记本"', () {
      expect(
        SmartNotebookDto.fromJson(const {'object_id': 's'}).displayTitle,
        '未命名智能笔记本',
      );
    });
  });

  group('Shelf 分组（F2）', () {
    test('按 stack 分组；空 stack 归"未分组"；组内 nocase 排序', () {
      final groups = groupNotebooksByStack([
        _nb('1', 'beta', stack: 'Work'),
        _nb('2', 'Alpha', stack: 'work'),
        _nb('3', 'NoStack'),
        _nb('4', 'Gamma', stack: 'Home'),
      ]);
      expect(groups.keys.toSet(), {'Work', 'work', 'Home', kNoteNoShelf});
      expect(groups[kNoteNoShelf]!.single.objectId, '3');
      expect(groups['Work']!.map((e) => e.objectId), ['1']);
      expect(groups['work']!.map((e) => e.objectId), ['2']);
    });

    test('Shelf 名去重（TreeSet 语义，大小写敏感）+ nocase 排序；不含"未分组"', () {
      final names = shelfNames([
        _nb('1', 'a', stack: 'Work'),
        _nb('2', 'b', stack: 'work'),
        _nb('3', 'c', stack: 'Home'),
        _nb('4', 'd'),
      ]);
      // 官方 `GenerateStacksLoader` 是 `TreeSet`（大小写不敏感的去重**没有**），
      // 但 SQL 的 `order by stack collate nocase` 让 Work/work 相邻
      expect(names, ['Home', 'Work', 'work']);
    });
  });

  group('共享给我（J5）', () {
    test('笔记本：individual_shared 或 owner 不是我', () {
      expect(
        isJoinedNotebook(_nb('1', 'x', individualShared: true), 'me'),
        isTrue,
      );
      expect(isJoinedNotebook(_nb('2', 'x', ownerName: 'bob'), 'me'), isTrue);
      expect(isJoinedNotebook(_nb('3', 'x', ownerName: 'me'), 'me'), isFalse);
      expect(isJoinedNotebook(_nb('4', 'x'), 'me'), isFalse);
      // 不知道"我是谁"时只有标志位可信（不能把别人的当自己的）
      expect(isJoinedNotebook(_nb('5', 'x', ownerName: 'bob'), null), isFalse);
    });

    test('笔记：individual_joined / individual_shared / owner 不是我', () {
      expect(isJoinedNote(_note(individualJoined: true), 'me'), isTrue);
      expect(isJoinedNote(_note(individualShared: true), 'me'), isTrue);
      expect(isJoinedNote(_note(ownerName: 'bob'), 'me'), isTrue);
      expect(isJoinedNote(_note(ownerName: 'me'), 'me'), isFalse);
      expect(isJoinedNote(_note(), 'me'), isFalse);
    });
  });
}
