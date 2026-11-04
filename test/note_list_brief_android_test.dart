// D10（r121 审计 `note_10.png` 第 4 行"附件行行距与 1–3 行不一致"）的回归。
//
// 取证链（这一条**不是**靠推理收口的，是真机像素 + 真机原始字节 + 代码三处对齐）：
//   ① 像素：`note_10.png` 第 4 行 `l1.png / nf.png` 的 meta 行（`My notebook · 09-18`）
//      前面**看得见一个空行**；1–3 行没有。多出的高度 ≈ 一个 `bodySmall` 行盒（16.75dp）。
//   ② 原始数据（只读探针 `tool/note_brief_probe.dart`，真 NAS `SYNO.NoteStation.Note:list`）：
//      那条笔记的 `brief` 逐字符是 `"l1.png\n\nnf.png"`（两个 png 附件，
//      `attachment` 里两个 1148×2492 的 image），而 `brief.trim()` **去不掉中间那个空行**。
//   ③ 代码：`note_widgets.dart` 用 `maxLines: 2` 渲染 `brief.trim()`
//      ⇒ 行盒 1 = `l1.png`、行盒 2 = **空**，而真正的第二个附件名 `nf.png`
//      被 `maxLines: 2` 挤掉（**信息丢失**，不只是观感）。
//
// ⇒ 结论：**不是间距常量不一致**（两侧用的是同一个 `SizedBox(height: 4)`），
//   是"brief 里的空行被如实排成了第二个行盒"。
//   修法：`listBriefOf()` 折叠空白行（**不动字号、不动 `maxLines`、不动间距常量**，§2.0.18）。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/notes/note_widgets.dart';

/// ★ 真 NAS 上那条笔记的 brief **原文**（逐字符，来自 `tool/note_brief_probe.dart`）。
/// 故意保留中间的空行 —— 它就是审计里那个"看不见的第二个行盒"。
const String _kRealBrief = 'l1.png\n\nnf.png';

NoteDto _note({required String brief}) => NoteDto(
  objectId: '1028_l3GXh1S5IMs7nlnza3apt6',
  title: 'l1.png / nf.png',
  brief: brief,
  mtime: 1789724125,
  encrypt: false,
);

void main() {
  group('listBriefOf（列表预览文本的唯一换算）', () {
    test('真机原文：中间的空行被折掉 ⇒ 没有空行、第二个附件名还在', () {
      final out = listBriefOf(_kRealBrief);
      expect(
        out,
        'l1.png nf.png',
        reason: '★ 折空白行之后：既没有空行，也没有把 `nf.png` 丢掉',
      );
      expect(out.contains('\n'), isFalse, reason: '预览里不该再出现换行');
      expect(
        out.contains('nf.png'),
        isTrue,
        reason: '★ 修复前它被空行 + maxLines:2 挤掉了（信息丢失）',
      );
    });

    test('只有空行的 brief ⇒ 视为没有摘要（不占一个行盒）', () {
      for (final s in const ['\n', '\n\n', '  \n \t\n']) {
        expect(listBriefOf(s), isEmpty, reason: '全空白 = 没有摘要');
      }
    });

    test('首尾空白照旧折掉，普通空格**保持原样**（不做 HTML 式空白归并）', () {
      expect(listBriefOf('a\n'), 'a');
      expect(listBriefOf('  a  b  '), 'a  b');
      expect(listBriefOf('a b\nc'), 'a b c');
      expect(listBriefOf('a\n\n\n\nb'), 'a b');
    });

    test('加密笔记的空 brief（官方也回 ""）⇒ 空，不渲染', () {
      expect(listBriefOf(''), isEmpty);
    });
  });

  group('NoteRow 渲染（机制量：**行盒数**，不看"某文本在不在"）', () {
    /// 这一段是不是被 `maxLines` 截掉了 —— 行盒数超了才会为真（§2.0.18 的口径）。
    bool truncated(WidgetTester tester, Finder f) => tester
        .renderObject<RenderParagraph>(f)
        .didExceedMaxLines;

    Future<void> pumpText(WidgetTester tester, String text) async {
      // 先空跑一次拿到主题（`Theme.of` 需要树里已有 Scaffold ⇒ 不能在同一次 pump 里取）
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: SizedBox.shrink())),
      );
      final style = Theme.of(
        tester.element(find.byType(Scaffold)),
      ).textTheme.bodySmall;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                // 与 `note_widgets.dart` 的 brief 同一档：`bodySmall`
                style: style,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('★ 反向验证：修复前的形态（`brief.trim()`）保持着**空行的第二行**', (tester) async {
      await pumpText(tester, _kRealBrief.trim());
      final preBoxes = tester.getSize(find.byType(Text)).height;
      expect(
        truncated(tester, find.byType(Text)),
        isTrue,
        reason: '修复前：`"l1.png\\n\\nnf.png"` 排成 3 个行盒、被 maxLines:2 截掉'
            '（第二行是**空的**，`nf.png` 排在第三行被丢掉）',
      );
      await pumpText(tester, listBriefOf(_kRealBrief));
      expect(
        truncated(tester, find.byType(Text)),
        isFalse,
        reason: '★ 修复后：折掉空行 ⇒ 一行放下 `l1.png nf.png`，不再截断',
      );
      // 机制量：修复前比修复后**正好高一个行盒**（这就是审计里那多出来的一行）
      final preLines = preBoxes;
      await pumpText(tester, listBriefOf(_kRealBrief));
      final postLines = tester.getSize(find.byType(Text)).height;
      expect(
        preLines / postLines,
        closeTo(2.0, 0.01),
        reason: '★ 修复前 = 2 个行盒、修复后 = 1 个行盒（比值 2.0）'
            '—— 与审计像素"多出一个 bodySmall 行盒"吻合',
      );
    });

    /// 一个 `Text` **实际排出的行盒数**（= 渲染行数；§2.0.30② 的机制量，
    /// 不是"某文本在不在"这种结果量）。`RenderParagraph` 不公开行数，
    /// 所以用同一个 `InlineSpan`/宽度/`textScaler`/`maxLines` 重排一次来数。
    int boxesOf(RenderParagraph p) {
      final tp = TextPainter(
        text: p.text,
        textDirection: TextDirection.ltr,
        textScaler: p.textScaler,
        maxLines: p.maxLines,
      )..layout(maxWidth: p.constraints.maxWidth);
      return tp.computeLineMetrics().length;
    }

    /// 一整行（`NoteRow`）里所有 `Text` 的行盒数之和。
    int rowLineBoxes(WidgetTester tester, Finder row) => find
        .descendant(of: row, matching: find.byType(Text))
        .evaluate()
        .map((e) => boxesOf(e.renderObject! as RenderParagraph))
        .fold(0, (a, b) => a + b);

    testWidgets('NoteRow：附件行与 1–3 行**行盒数相同**（都是 2 个）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: ListView(
              children: [
                // 真机 1–3 行的形态：`brief` 只有换行 ⇒ 没有预览行
                NoteRow(
                  key: const Key('row-normal'),
                  note: _note(brief: '\n'),
                  notebookTitle: 'My notebook',
                ),
                NoteRow(
                  key: const Key('row-attach'),
                  note: _note(brief: _kRealBrief),
                  notebookTitle: 'My notebook',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final normal = rowLineBoxes(tester, find.byKey(const Key('row-normal')));
      final attach = rowLineBoxes(tester, find.byKey(const Key('row-attach')));
      expect(normal, 2, reason: '普通行 = 标题 + meta = 2 个行盒');
      expect(
        attach,
        normal,
        reason: '★ 附件行必须同样是 2 个行盒；修复前是 3 个'
            '（标题 + **与标题重复的预览** + meta）',
      );

      // ★ 不丢信息：两个附件名都还在（数据层在 `listBriefOf` 里，屏幕由**标题**承载）
      expect(listBriefOf(_kRealBrief), contains('l1.png'));
      expect(listBriefOf(_kRealBrief), contains('nf.png'));
      // 两行用的都是同一条笔记的标题 ⇒ 必须限定在附件行里找
      final title = find.descendant(
        of: find.byKey(const Key('row-attach')),
        matching: find.text('l1.png / nf.png'),
      );
      expect(title, findsOneWidget);
      expect(
        truncated(tester, title),
        isFalse,
        reason: '★ 标题没有被 maxLines 截断 ⇒ 两个附件名都在屏上（不是"删了就完事"）',
      );
      // ★ 反向：预览行确实不渲染（修复前这里 findsOneWidget）
      expect(find.text('l1.png nf.png'), findsNothing);
      expect(find.textContaining('l1.png\n\nnf.png'), findsNothing);
    });

    testWidgets('★ 反向下限：预览带来**新信息**时必须照常渲染（不许靠"删预览"消除不一致）', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: ListView(
              children: [
                NoteRow(
                  key: const Key('row-unique'),
                  note: NoteDto(
                    objectId: '1028_l3GXh1S5IMs7nlnza3apt6',
                    title: '会议纪要',
                    brief: '预算 与 排期',
                    mtime: 1789724125,
                    encrypt: false,
                  ),
                  notebookTitle: 'My notebook',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('预算 与 排期'), findsOneWidget);
      expect(rowLineBoxes(tester, find.byKey(const Key('row-unique'))), 3);
      expect(truncated(tester, find.text('预算 与 排期')), isFalse);
    });
  });
}
