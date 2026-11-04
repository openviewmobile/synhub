// NoteStation HTML ⇄ Quill Delta 转换 + 净化的离线测试。
//
// 这一层最容易出的错不是"崩"，而是**静默丢格式**：加粗没上去、列表变成一行、
// 别人的笔记里带 `<script>` 被渲染出来。所以用例都盯着"格式有没有留住"。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/features/notes/note_html.dart';

/// 取 Delta 里的纯文本（去掉行尾换行），方便断言
String deltaText(List<Map<String, dynamic>> ops) => ops
    .where((o) => o['insert'] is String)
    .map((o) => o['insert'] as String)
    .join()
    .replaceAll('\n', '');

/// 所有行尾换行上挂的行属性
List<Map<String, dynamic>> lineAttrs(List<Map<String, dynamic>> ops) => ops
    .where((o) => o['insert'] == '\n' && o['attributes'] != null)
    .map((o) => Map<String, dynamic>.from(o['attributes'] as Map))
    .toList();

void main() {
  group('净化', () {
    test('去掉 script/iframe/style 与事件属性', () {
      final out = sanitizeNoteHtml(
        '<p onclick="alert(1)">hi</p><script>alert(1)</script>'
        '<iframe src="http://x"></iframe><b>ok</b>',
      );
      expect(out, contains('<p>hi</p>'));
      expect(out, isNot(contains('script')));
      expect(out, isNot(contains('iframe')));
      expect(out, isNot(contains('onclick')));
      expect(out, contains('<b>ok</b>'));
    });

    test('危险 URL 清掉，图片 data: 留着', () {
      expect(
        sanitizeNoteHtml('<a href="javascript:alert(1)">x</a>'),
        isNot(contains('javascript')),
      );
      expect(
        sanitizeNoteHtml('<img src="data:text/html;base64,xx">'),
        isNot(contains('data:text/html')),
      );
      expect(
        sanitizeNoteHtml('<img src="data:image/png;base64,AA">'),
        contains('data:image/png'),
      );
      expect(
        sanitizeNoteHtml('<a href="https://a.b">x</a>'),
        contains('https://a.b'),
      );
    });

    test('保留 style 里的颜色/字号，删掉杂属性', () {
      final out = sanitizeNoteHtml(
        '<span style="color:#f00" data-x="1" id="y">红</span>',
      );
      expect(out, contains('color:#f00'));
      expect(out, isNot(contains('data-x')));
      expect(out, isNot(contains('id=')));
    });
  });

  group('纯文本', () {
    test('折叠空白、去标签（列表摘要用）', () {
      expect(notePlainText('<h1>标题</h1>\n<p>正  文<br>第二行</p>'), '标题 正 文 第二行');
      expect(notePlainText(''), '');
    });

    test('取出图片 URL', () {
      expect(
        noteImageSources(
          '<p>a</p><img src="note://x/1">'
          '<img src="javascript:x">',
        ),
        ['note://x/1'],
      );
    });
  });

  group('HTML → Delta', () {
    test('标题挂 header，正文是普通行', () {
      final ops = noteHtmlToDelta('<h2>标题</h2><p>正文</p>');
      expect(deltaText(ops), '标题正文');
      expect(lineAttrs(ops)[0]['header'], 2);
      expect(ops.last['insert'], '\n');
    });

    test('行内格式挂在文字 insert 上（不是行尾）', () {
      final ops = noteHtmlToDelta('<p>a<b>粗</b><i>斜</i><u>下</u></p>');
      final bold = ops.firstWhere((o) => o['insert'] == '粗');
      expect(bold['attributes'], {'bold': true});
      final italic = ops.firstWhere((o) => o['insert'] == '斜');
      expect(italic['attributes'], {'italic': true});
    });

    test('链接与颜色', () {
      final ops = noteHtmlToDelta(
        '<p><a href="https://a.b">看这个</a>'
        '<span style="color:#ff0000">红</span></p>',
      );
      expect(ops.firstWhere((o) => o['insert'] == '看这个')['attributes'], {
        'link': 'https://a.b',
      });
      expect(ops.firstWhere((o) => o['insert'] == '红')['attributes'], {
        'color': '#ff0000',
      });
    });

    test('无序/有序列表 + 嵌套缩进', () {
      final ops = noteHtmlToDelta(
        '<ul><li>甲<ul><li>甲一</li></ul></li><li>乙</li></ul>'
        '<ol><li>一</li></ol>',
      );
      final attrs = lineAttrs(ops);
      expect(attrs[0]['list'], 'bullet');
      expect(attrs[1]['list'], 'bullet');
      expect(attrs[1]['indent'], 1);
      expect(attrs[2]['list'], 'bullet');
      expect(attrs[3]['list'], 'ordered');
      expect(deltaText(ops), '甲甲一乙一');
    });

    test('★ 真机形态：正文里裸放的 <img ref> 不会丢', () {
      // `Note/get` 回来的就是这一串（l1.png/nf.png 实测）
      const real =
          '<p>l1.png</p>'
          '<img class="syno-notestation-image-object" '
          'src="webman/3rdparty/NoteStation/images/transparent.gif" '
          'data-mce-src="webman/3rdparty/NoteStation/images/transparent.gif" '
          'ref="MTc4OTcyNDEyNTI3M2wxLnBuZw==" adjust="true">'
          '<p>nf.png</p>'
          '<img class="syno-notestation-image-object" '
          'src="webman/3rdparty/NoteStation/images/transparent.gif" '
          'ref="MTc4OTcyNDEyNTI3M25mLnBuZw==" adjust="true">';
      final resolver = NoteImageResolver.ofAttachments({
        'file-1': const NoteAttachmentDto(
          fileId: 'file-1',
          name: 'l1.png',
          ref: 'MTc4OTcyNDEyNTI3M2wxLnBuZw==',
        ),
        'file-2': const NoteAttachmentDto(
          fileId: 'file-2',
          name: 'nf.png',
          ref: 'MTc4OTcyNDEyNTI3M25mLnBuZw==',
        ),
      });
      final ops = noteHtmlToDelta(real, resolver: resolver);
      expect(deltaText(ops), 'l1.pngnf.png');
      final images = ops
          .where(
            (o) => o['insert'] is Map && (o['insert'] as Map)['image'] != null,
          )
          .map((o) => (o['insert'] as Map)['image'])
          .toList();
      expect(images, [
        'file-1',
        'file-2',
      ], reason: '图片要挂到附件 file_id 上，渲染时才能带鉴权下载');
    });

    test('★ 服务端"再规范化"后的形态（div + border + 自闭合）也能出图', () {
      // 真机：上传后过一会儿再 Note/get，正文被服务端改写成了这样
      const normalized =
          '<p>l1.png</p>'
          '<div><img class="syno-notestation-image-object" '
          'src="webman/3rdparty/NoteStation/images/transparent.gif" border="0" '
          'ref="REF-1" adjust="true" /></div>'
          '<p>nf.png</p>'
          '<div><img class="syno-notestation-image-object" '
          'src="webman/3rdparty/NoteStation/images/transparent.gif" border="0" '
          'ref="REF-2" adjust="true" /></div>';
      final resolver = NoteImageResolver.ofAttachments({
        'f1': const NoteAttachmentDto(
          fileId: 'f1',
          name: 'l1.png',
          ref: 'REF-1',
        ),
        'f2': const NoteAttachmentDto(
          fileId: 'f2',
          name: 'nf.png',
          ref: 'REF-2',
        ),
      });
      final ops = noteHtmlToDelta(normalized, resolver: resolver);
      final images = ops
          .where(
            (o) => o['insert'] is Map && (o['insert'] as Map)['image'] != null,
          )
          .map((o) => (o['insert'] as Map)['image'])
          .toList();
      expect(images, ['f1', 'f2']);
      expect(deltaText(ops), contains('l1.png'));
      expect(deltaText(ops), contains('nf.png'));
    });

    test('▲ 没有附件表时，ref 原样保留（不丢图）', () {
      final ops = noteHtmlToDelta('<img src="x.png" ref="REF-1">');
      expect((ops.first['insert'] as Map)['image'], 'REF-1');
    });

    test('▲ Web 端保存后用的是 content_id（值=file_id）', () {
      final ops = noteHtmlToDelta('<img content_id="file-9" src="/ns/dv/x">');
      expect((ops.first['insert'] as Map)['image'], 'file-9');
    });

    test('引用 / 代码块 / 图片', () {
      final ops = noteHtmlToDelta(
        '<blockquote>引</blockquote>'
        '<pre>code();\nline2</pre><p><img src="note://a/1"></p>',
      );
      expect(lineAttrs(ops).any((a) => a['blockquote'] == true), isTrue);
      final code = ops.firstWhere(
        (o) => o['attributes']?['code-block'] == true,
      );
      expect(code['insert'], 'code();\nline2\n');
      final image = ops.firstWhere(
        (o) => o['insert'] is Map && (o['insert'] as Map)['image'] != null,
      );
      expect((image['insert'] as Map)['image'], 'note://a/1');
    });

    test('`<br>` 拆成两行；空段落不会消失', () {
      final ops = noteHtmlToDelta('<p>上<br>下</p><p><br></p>');
      expect(deltaText(ops), '上下');
      expect(ops.where((o) => o['insert'] == '\n').length, 3);
    });

    test('空 HTML 也要有合法的 Delta（只有换行）', () {
      expect(noteHtmlToDelta(''), [
        {'insert': '\n'},
      ]);
    });

    test('表格拍平但不丢内容', () {
      final ops = noteHtmlToDelta(
        '<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>',
      );
      expect(deltaText(ops), 'a | bc | d');
    });
  });

  group('Delta → HTML', () {
    test('标题/列表/引用/粗斜体都能回去', () {
      final html = noteDeltaToNoteHtml([
        {'insert': '标题'},
        {
          'insert': '\n',
          'attributes': {'header': 1},
        },
        {
          'insert': '粗',
          'attributes': {'bold': true},
        },
        {'insert': '正文'},
        {'insert': '\n'},
        {'insert': '甲'},
        {
          'insert': '\n',
          'attributes': {'list': 'bullet'},
        },
        {'insert': '乙'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'},
        },
        {'insert': '引'},
        {
          'insert': '\n',
          'attributes': {'blockquote': true},
        },
      ]);
      expect(html, contains('<h1>标题</h1>'));
      expect(html, contains('<b>粗</b>正文'));
      expect(html, contains('<ul><li>甲</li></ul>'));
      expect(html, contains('<ol><li>乙</li></ol>'));
      expect(html, contains('<blockquote>引</blockquote>'));
    });

    test('链接/颜色/图片/代码块', () {
      final html = noteDeltaToNoteHtml([
        {
          'insert': '点',
          'attributes': {'link': 'https://a.b'},
        },
        {
          'insert': '红',
          'attributes': {'color': '#f00'},
        },
        {'insert': '\n'},
        {
          'insert': {'image': 'REF-1'},
        },
        {'insert': '\n'},
        {
          'insert': 'code\n',
          'attributes': {'code-block': true},
        },
      ]);
      expect(html, contains('<a href="https://a.b">点</a>'));
      expect(html, contains('color:#f00'));
      // 官方编辑器的 img 片段（服务端原样保存，靠 ref 找附件）
      expect(html, contains('ref="REF-1"'));
      expect(html, contains('class="syno-notestation-image-object"'));
      expect(html, contains('<pre>code</pre>'));
    });

    test('图片 file_id 用附件表换回原 ref', () {
      final html = noteDeltaToNoteHtml([
        {
          'insert': {'image': 'file-1'},
        },
        {'insert': '\n'},
      ], refOf: (id) => id == 'file-1' ? 'REF-ORIG' : null);
      expect(html, contains('ref="REF-ORIG"'));
      expect(html, isNot(contains('file-1')));
    });

    test('文本里的尖括号要转义（不能造出标签）', () {
      final html = noteDeltaToNoteHtml([
        {'insert': '<script>alert(1)</script>'},
        {'insert': '\n'},
      ]);
      expect(html, isNot(contains('<script>')));
      expect(html, contains('&lt;script&gt;'));
    });
  });

  group('往返', () {
    test('HTML → Delta → HTML 不丢主要结构', () {
      const source =
          '<h2>标题</h2><p>正文<b>粗</b></p>'
          '<ul><li>甲</li><li>乙</li></ul><blockquote>引</blockquote>';
      final html = noteDeltaToNoteHtml(noteHtmlToDelta(source));
      expect(html, contains('<h2>标题</h2>'));
      expect(html, contains('正文<b>粗</b>'));
      expect(html, contains('<li>甲</li>'));
      expect(html, contains('<li>乙</li>'));
      expect(html, contains('<blockquote>引</blockquote>'));
    });

    test('★ 真机 img 往返：ref 不丢', () {
      const ref = 'MTc4OTcyNDEyNTI3M2wxLnBuZw==';
      const src =
          '<p>l1.png</p><img class="syno-notestation-image-object" '
          'src="webman/3rdparty/NoteStation/images/transparent.gif" '
          'ref="$ref" adjust="true">';
      final resolver = NoteImageResolver.ofAttachments({
        'file-1': const NoteAttachmentDto(
          fileId: 'file-1',
          name: 'l1.png',
          ref: ref,
        ),
      });
      final html = noteDeltaToNoteHtml(
        noteHtmlToDelta(src, resolver: resolver),
        refOf: (id) => id == 'file-1' ? ref : null,
      );
      expect(html, contains('ref="$ref"'));
      expect(html, contains('l1.png'));
    });

    test('脏 HTML（脚本 + 事件）往返后仍然干净', () {
      final delta = noteHtmlToDelta(
        '<p onclick="x()">a</p><script>bad()</script><p>b</p>',
      );
      final html = noteDeltaToNoteHtml(delta);
      expect(html, isNot(contains('script')));
      expect(html, isNot(contains('onclick')));
      expect(notePlainText(html), 'a b');
    });
  });

  // ------------------------------------------------- 批次 A：格式补齐（对照官方 CMD_*）

  group('批次 A · 清单勾选状态（官方 syno_checkbox）', () {
    test('编辑器态 <input class=…> → list: checked/unchecked 行属性', () {
      final delta = noteHtmlToDelta(
        '<div><input type="image" class="syno-notestation-editor-checkbox '
        'syno-notestation-editor-checkbox-checked">买牛奶</div>'
        '<div><input type="image" class="syno-notestation-editor-checkbox">'
        '写周报</div>',
      );
      expect(deltaText(delta), '买牛奶写周报');
      final attrs = lineAttrs(delta);
      expect(attrs[0]['list'], 'checked');
      expect(attrs[1]['list'], 'unchecked');
    });

    test('落库态 <img content_id="#checkbox_checked"> 也认（否则重开丢勾选）', () {
      final delta = noteHtmlToDelta(
        '<img content_id="#checkbox_checked" '
        'class="syno-notestation-editor-checkbox '
        'syno-notestation-editor-checkbox-checked">任务',
      );
      expect(lineAttrs(delta).first['list'], 'checked');
    });

    test('Delta → HTML：勾选框带官方 class，勾选/未勾选可区分', () {
      final html = noteDeltaToNoteHtml([
        {'insert': '买牛奶'},
        {
          'insert': '\n',
          'attributes': {'list': 'checked'},
        },
      ]);
      expect(html, contains('syno-notestation-editor-checkbox'));
      expect(html, contains('syno-notestation-editor-checkbox-checked'));
      expect(html, contains('editor_checkbox_03.png'));
      expect(html, contains('买牛奶'));

      final unchecked = noteDeltaToNoteHtml([
        {'insert': 'x'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked'},
        },
      ]);
      expect(unchecked, contains('editor_checkbox_01.png'));
      expect(unchecked, isNot(contains('checkbox-checked')));
    });

    test('往返：勾选状态不丢', () {
      const src =
          '<div><input type="image" class="syno-notestation-editor-checkbox '
          'syno-notestation-editor-checkbox-checked"></input>任务A</div>';
      final round = noteDeltaToNoteHtml(noteHtmlToDelta(src));
      final back = noteHtmlToDelta(round);
      expect(lineAttrs(back).first['list'], 'checked');
    });
  });

  group('批次 A · 对齐（官方 justify*）/ 分割线 / 字号 / 笔记链接', () {
    test('text-align → Quill align 行属性，再回写 text-align', () {
      final delta = noteHtmlToDelta('<p style="text-align:center">居中</p>');
      expect(lineAttrs(delta).first['align'], 'center');
      final html = noteDeltaToNoteHtml(delta);
      expect(html, contains('text-align:center'));
      expect(html, contains('居中'));
    });

    test('align 属性（老 HTML）也认', () {
      final delta = noteHtmlToDelta('<div align="right">右</div>');
      expect(lineAttrs(delta).first['align'], 'right');
    });

    test('hr → 自定义块 embed，往返仍是 <hr>', () {
      final delta = noteHtmlToDelta('<p>a</p><hr><p>b</p>');
      expect(
        delta.any(
          (o) => o['insert'] is Map && (o['insert'] as Map)['hr'] != null,
        ),
        isTrue,
      );
      final html = noteDeltaToNoteHtml(delta);
      expect(html, contains('<hr>'));
      expect(notePlainText(html), 'a b');
    });

    test('syno-fontsize-* class 往返不丢', () {
      final delta = noteHtmlToDelta(
        '<p><span class="syno-fontsize-x-large">大</span></p>',
      );
      expect(delta.firstWhere((o) => o['insert'] == '大')['attributes'], {
        'size': 'syno-fontsize-x-large',
      });
      final html = noteDeltaToNoteHtml(delta);
      expect(html, contains('class="syno-fontsize-x-large"'));
    });

    test('inline font-size 映射到最近的官方档', () {
      final delta = noteHtmlToDelta(
        '<p><span style="font-size:24pt">大</span></p>',
      );
      expect(
        delta.firstWhere((o) => o['insert'] == '大')['attributes']['size'],
        'syno-fontsize-x-large',
      );
    });

    test('笔记链接 notestation:// 不被净化掉', () {
      final delta = noteHtmlToDelta(
        '<p><a href="notestation://local/self/n9">另一条</a></p>',
      );
      expect(delta.firstWhere((o) => o['insert'] == '另一条')['attributes'], {
        'link': 'notestation://local/self/n9',
      });
      final html = noteDeltaToNoteHtml(delta);
      expect(html, contains('notestation://local/self/n9'));
    });

    test('H4-H6 往返', () {
      final delta = noteHtmlToDelta('<h4>四</h4><h5>五</h5><h6>六</h6>');
      expect(lineAttrs(delta)[0]['header'], 4);
      expect(lineAttrs(delta)[1]['header'], 5);
      expect(lineAttrs(delta)[2]['header'], 6);
      final html = noteDeltaToNoteHtml(delta);
      expect(html, contains('<h4>四</h4>'));
      expect(html, contains('<h5>五</h5>'));
      expect(html, contains('<h6>六</h6>'));
    });

    test('上下标已在（script）——回归确认', () {
      final delta = noteHtmlToDelta('<p>a<sub>底</sub><sup>顶</sup></p>');
      expect(delta.firstWhere((o) => o['insert'] == '底')['attributes'], {
        'script': 'sub',
      });
      expect(delta.firstWhere((o) => o['insert'] == '顶')['attributes'], {
        'script': 'super',
      });
    });
  });
}
