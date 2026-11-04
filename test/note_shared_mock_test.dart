// ★★★ 第 117 轮 / 台账 J11：官方有**两个**伪集合 ——
// "Joined Notes"（共享给我，`all_joined_notes`）与 "Shared Notes"
// （**我分享出去的**，`all_shared_notes`，`res/values/strings.xml:39/41`，
// 使用点 `NotebookListAppWidgetAdapter`）。我方此前只有前者。
//
// 这里用 Mock 证明分类函数把两边**分得开**（方向相反，字段同一套）。
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/features/notes/note_providers.dart';

NotebookDto _nb({
  required String id,
  String? owner,
  bool shared = false,
}) => NotebookDto(
  objectId: id,
  title: id,
  ownerName: owner,
  individualShared: shared,
);

NoteDto _note({
  required String id,
  String? owner,
  bool shared = false,
  bool joined = false,
}) => NoteDto(
  objectId: id,
  title: id,
  ownerName: owner,
  individualShared: shared,
  individualJoined: joined,
  hasContent: true,
);

void main() {
  group('117. J11 我分享出去的（官方 all_shared_notes）', () {
    test('★ 笔记本：我分享的 ∈ shared，别人分享给我的 ∉ shared', () {
      expect(isSharedNotebook(_nb(id: 'a', owner: 'me', shared: true), 'me'), isTrue);
      expect(
        isSharedNotebook(_nb(id: 'b', owner: 'other', shared: true), 'me'),
        isFalse,
        reason: '别人分享的且 owner 不是我 ⇒ 属于 joined，不属于 shared',
      );
      expect(isSharedNotebook(_nb(id: 'c', owner: 'me'), 'me'), isFalse,
          reason: '没有 individual_shared ⇒ 没分享出去');
    });

    test('★ 笔记本：owner 缺失时按"我的"处理（服务端对自有内容可能不带 owner）', () {
      expect(isSharedNotebook(_nb(id: 'a', shared: true), 'me'), isTrue);
      expect(isSharedNotebook(_nb(id: 'a', shared: true), null), isTrue);
    });

    test('★ 笔记：与 joined 方向相反（同一字段两套判定）', () {
      final mine = _note(id: 'n1', owner: 'me', shared: true);
      final theirs = _note(id: 'n2', owner: 'other', shared: true);
      // ⚠️ owner 缺失时 `individual_shared` 语义**两可**（服务端不区分
      //    "谁分享的"）⇒ 此时两边都可能命中，属已知降级情形，不在此断言。
      expect(isSharedNote(mine, 'me'), isTrue);
      expect(isJoinedNote(mine, 'me'), isFalse);
      expect(isSharedNote(theirs, 'me'), isFalse);
      expect(isJoinedNote(theirs, 'me'), isTrue);
    });

    test('★ 两个集合互斥（同一条内容不会同时出现在两边）', () {
      for (final nb in [
        _nb(id: 'a', owner: 'me', shared: true),
        _nb(id: 'b', owner: 'other', shared: true),
        _nb(id: 'c', owner: 'me'),
      ]) {
        expect(
          isSharedNotebook(nb, 'me') && isJoinedNotebook(nb, 'me'),
          isFalse,
          reason: '${nb.objectId} 不能两边都算',
        );
      }
    });
  });
}
