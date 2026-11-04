// ★★ ④笔记 第 238 轮：**E12「笔记内行内待办清单」** 的补证用例。
//
// E12 的实现散在 `note_html.dart` 的两头：
//   * 读：落库态 `<img content_id="#checkbox_checked">` / 编辑器态 `<input
//     class="…syno-notestation-editor-checkbox[-checked]">` ⇒ `list:'checked'|'unchecked'`；
//   * 写：`noteDeltaToNoteHtml` 把 `list:'checked'|'unchecked'` 渲染成**每行一个
//     `<div>` + 官方勾选框**（`syno_checkbox` 插件形态，**不是** `<ul>`）。
//
// 此前只有"读"的一半被断言（`note_html_test`），本轮把"写"和**往返不丢勾选**补上，
// 否则重开笔记丢勾选这类回归没人拦。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/notes/note_html.dart';

void main() {
  group('E12 行内待办 · 官方勾选框 HTML', () {
    test('checked / unchecked 逐字用官方 TinyMCE `syno_checkbox` 两张图', () {
      final on = noteCheckboxHtml('checked');
      final off = noteCheckboxHtml('unchecked');
      expect(on, contains('syno-notestation-editor-checkbox-checked'));
      expect(off, isNot(contains('editor-checkbox-checked')));
      expect(on, contains('editor_checkbox_03.png'));
      expect(off, contains('editor_checkbox_01.png'));
      expect(on, contains('type="image"'));
      expect(on, contains('syno-notestation-editor-checkbox'));
    });

    test('非 checked 的一切取值都当未勾选（不抛、不猜）', () {
      for (final s in ['unchecked', '', 'x', 'CHECKED']) {
        if (s == 'unchecked' || s.isEmpty || s == 'x' || s == 'CHECKED') {
          expect(
            noteCheckboxHtml(s),
            isNot(contains('editor-checkbox-checked')),
            reason: '只有字面量 checked 才算勾上',
          );
        }
      }
    });
  });

  group('E12 行内待办 · delta ⇄ HTML 往返', () {
    test('★ checked / unchecked 两行 → 两个 <div>（不是 <ul>），各自带勾选框', () {
      // ⚠️ Quill 口径：**行属性挂在换行符那个 insert 上**，不是挂在文字上
      // （238 轮第一版写错，实测渲染成 <p>）。
      final html = noteDeltaToNoteHtml([
        {'insert': '买牛奶'},
        {
          'insert': '\n',
          'attributes': {'list': 'checked'},
        },
        {'insert': '倒垃圾'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked'},
        },
      ]);
      expect(html, contains('<div>'));
      expect(html, isNot(contains('<ul>')));
      expect(html, contains('editor_checkbox_03.png'), reason: '第一行是勾上的');
      expect(html, contains('editor_checkbox_01.png'), reason: '第二行没勾');
      expect(html, contains('买牛奶'));
      expect(html, contains('倒垃圾'));
    });

    test('★ 往返：落库态 → delta → 落库态，勾选状态一个都不变', () {
      const stored =
          '<div><img class="syno-notestation-editor-checkbox" '
          'content_id="#checkbox_checked">已完成的事</div>'
          '<div><img class="syno-notestation-editor-checkbox" '
          'content_id="#checkbox_unchecked">没做的事</div>';
      final delta = noteHtmlToDelta(stored);
      final back = noteDeltaToNoteHtml(delta);
      expect(back, contains('editor_checkbox_03.png'), reason: '勾选不能丢');
      expect(back, contains('editor_checkbox_01.png'));
      expect(back, contains('已完成的事'));
      expect(back, contains('没做的事'));
      // 再走一轮也必须稳定（幂等）
      final again = noteDeltaToNoteHtml(noteHtmlToDelta(back));
      expect(
        'checked'.allMatches(
          again.contains('editor_checkbox_03.png') ? 'checked' : '',
        ).length,
        1,
      );
      expect(again, contains('没做的事'));
    });

    test('普通项目符号列表仍然用 <ul>（没被清单分支抢走）', () {
      final html = noteDeltaToNoteHtml([
        {'insert': '普通条目'},
        {
          'insert': '\n',
          'attributes': {'list': 'bullet'},
        },
      ]);
      expect(html, contains('<ul>'));
      expect(html, isNot(contains('syno-notestation-editor-checkbox')));
    });
  });
}
