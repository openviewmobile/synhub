// D10（第 2 轮）：Android Notes 列表「附件行比普通行高出一行」的机制定位与回归。
//
// 真机证据链：
//   ① 像素（r135 `100_notes.png` 对 r121 `note_10.png`）：附件行**三行结构**
//      （标题 → 预览 → meta），而 1–3 行是**两行结构**（标题 → meta）。
//   ② 真 NAS **只读**探针原文（`tool/note_brief_probe.dart` → `/tmp/note_brief2.log`）：
//      `test`/`rddffff`/`ffggggggg` 三条的 `brief` 是 `""` 或 `"\n"`（**没有预览行**），
//      而附件那条 `title = "l1.png / nf.png"`、`brief = "l1.png\n\nnf.png"`
//      —— 预览 `l1.png nf.png` **一个字都不比标题多**。
//   ③ 机制量（本文件用 `tester.getSize` 量，修复前实测）：
//      * 普通行（图标 + 标题 + meta，无预览） = **52.0dp**；
//      * 附件行（缩略图 + 标题 + **重复的预览** + meta） = **70.0dp**
//        ⇒ 多 **18.0dp** = 一个 `bodySmall` 行盒（16.0）+ 预览前的 `SizedBox(height: 2)`；
//      * 把预览去掉、但缩略图仍是默认 40×50（+2） ⇒ **68.0dp**
//        ⇒ 缩略图槽位 52.0dp **超过**两行文字高 36.0dp，再贡献 **16.0dp**。
//   ⇒ 两个机制各占一份，**只修其中一个都不够**（见下面两条反向用例）。
//
// 修复（两处，都在 notes 模块内，未动字号 / 未用 FittedBox）：
//   ① `listBriefFor(title, brief)`：预览里**每个可见词元都已在标题里**时不渲染预览
//      —— 标题仍完整显示 `l1.png` 与 `nf.png`（**不丢信息**，见"反向下限"用例）；
//   ② `NoteThumb.maxSlotHeight = listRowThumbSlotHeight(36)`：**行高由文字决定**，
//      缩略图多出的高度用 `BoxFit.cover` 裁掉（宽度不变）。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/features/notes/note_body.dart'
    show NoteThumb, listRowThumbSlotHeight;
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/notes/note_widgets.dart';

/// ★ 真 NAS 上那条附件笔记的 `title` / `brief` **原文**（`/tmp/note_brief2.log`）。
const String _kTitle = 'l1.png / nf.png';
const String _kBrief = 'l1.png\n\nnf.png';

/// 1–3 行那三条普通笔记的 `brief` 原文（同上日志）—— 它们是"两行结构"。
const String _kNormalBrief = '\n';

/// 行高差值阈值：1.0dp（测试里 DPR = 3.0 ⇒ ≈3px）。真机像素上那多出的一行
/// 是 ~52.7px（≈16.97dp）⇒ 这条阈值比缺陷量小一个数量级，抓得住。
const double _kMaxRowDeltaDp = 1.0;

NoteDto _note({
  String title = _kTitle,
  String brief = _kBrief,
  bool withThumb = true,
  bool encrypt = false,
}) => NoteDto(
  objectId: '1028_l3GXh1S5IMs7nlnza3apt6',
  title: title,
  brief: brief,
  mtime: 1789724125,
  encrypt: encrypt,
  thumb: withThumb
      ? const NoteThumbDto(source: 'file-id-1', type: 'image/jpeg')
      : null,
);

/// 真机列表是 `ListView.separated` + 1px `Divider`（`notes_page.dart:615`）；
/// 行高只有在**无界高度**里才是它自己的自然高度 ⇒ 用例照这个形态泵。
Future<void> _pumpRows(WidgetTester tester, List<Widget> rows) async {
  await tester.binding.setSurfaceSize(const Size(420, 1000)); // 真机 ≈417dp 宽
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) => rows[i],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

double _h(WidgetTester tester, String key) =>
    tester.getSize(find.byKey(Key(key))).height;

/// ★ 验收主判据（协调方第 218 轮纠正 + §2.0.30②）：一次渲染中有**几个行盒**。
///
/// 真机列表**没有** `itemExtent`/`prototypeItem`（`grep` 0 命中）⇒ 行高是内在尺寸，
/// 不存在"固定行距被内容顶破"这回事；缺陷的机制量是**行盒数多一个**
/// （多渲染了一个 `Text`）与**标题是否被 `maxLines` 截断**（信息有没有丢）。
///
/// `RenderParagraph` 不公开行数 ⇒ 用同一个 `InlineSpan` / 约束宽度 / `textScaler` /
/// `maxLines` 重排一次来数（`computeLineMetrics()`）。
int _boxesOf(RenderParagraph p) {
  final tp = TextPainter(
    text: p.text,
    textDirection: TextDirection.ltr,
    textScaler: p.textScaler,
    maxLines: p.maxLines,
  )..layout(maxWidth: p.constraints.maxWidth);
  return tp.computeLineMetrics().length;
}

/// 一整行（`NoteRow`）里所有 `Text` 的行盒数之和。
int _rowLineBoxes(WidgetTester tester, String key) => find
    .descendant(of: find.byKey(Key(key)), matching: find.byType(Text))
    .evaluate()
    .map((e) => _boxesOf(e.renderObject! as RenderParagraph))
    .fold(0, (a, b) => a + b);

/// 该 `Text` 是不是被 `maxLines` 截掉了（信息有没有丢）。
bool _truncated(WidgetTester tester, Finder f) =>
    tester.renderObject<RenderParagraph>(f).didExceedMaxLines;

void main() {
  // ---------------------------------------------------------------- 机制量：行高
  group('NoteRow 实际行高（机制量，`tester.getSize`；不看"某文本在不在"）', () {
    testWidgets('★★ 验收主判据：附件行与相邻普通行**行盒数相同**（都是 2）', (tester) async {
      await _pumpRows(tester, [
        NoteRow(
          key: const Key('normal-1'),
          note: _note(title: 'test', brief: _kNormalBrief, withThumb: false),
          notebookTitle: 'My notebook',
        ),
        NoteRow(
          key: const Key('attach'),
          note: _note(),
          notebookTitle: 'My notebook',
        ),
      ]);

      final normal = _rowLineBoxes(tester, 'normal-1');
      final attach = _rowLineBoxes(tester, 'attach');
      // ignore: avoid_print
      print('[D10] lineBoxes attach=$attach normal=$normal');
      expect(normal, 2, reason: '普通行 = 标题 + meta');
      expect(
        attach,
        normal,
        reason: '★ 修复前 attach = 3（标题 + 与标题重复的预览 + meta）'
            '、normal = 2 ⇒ 这一条当场红',
      );

      // 信息没丢：标题完整（未被 maxLines 截断），两个附件名都在屏上
      final title = find.text(_kTitle);
      expect(title, findsOneWidget);
      expect(_truncated(tester, title), isFalse);
      expect(
        find.text(listBriefOf(_kBrief)),
        findsNothing,
        reason: '★ 与标题重复的预览行不再渲染（修复前 findsOneWidget）',
      );
    });

    testWidgets('★ 附件行高 == 相邻普通行高（差值 ≤ 1.0dp）', (tester) async {
      await _pumpRows(tester, [
        // 真机 1–3 行的形态：图标 + 标题 + meta，`brief` 是空的/换行
        NoteRow(
          key: const Key('normal-1'),
          note: _note(title: 'test', brief: _kNormalBrief, withThumb: false),
          notebookTitle: 'My notebook',
        ),
        NoteRow(
          key: const Key('normal-2'),
          note: _note(
            title: 'ffggggggg',
            brief: _kNormalBrief,
            withThumb: false,
          ),
          notebookTitle: 'My notebook',
        ),
        // 真机第 4 行（附件行）
        NoteRow(
          key: const Key('attach'),
          note: _note(),
          notebookTitle: 'My notebook',
        ),
      ]);

      final attach = _h(tester, 'attach');
      final n1 = _h(tester, 'normal-1');
      final n2 = _h(tester, 'normal-2');
      // ignore: avoid_print
      print('[D10] attach=$attach normal-1=$n1 normal-2=$n2');

      expect(
        (attach - n1).abs(),
        lessThanOrEqualTo(_kMaxRowDeltaDp),
        reason: '★ 附件行（$attach）必须与相邻普通行（$n1）等高 —— '
            '修复前是 70.0 vs 52.0（+18.0dp）',
      );
      expect((attach - n2).abs(), lessThanOrEqualTo(_kMaxRowDeltaDp));
    });

    testWidgets('机制①：附件行的预览行与标题是同一份信息 ⇒ 不渲染（附行数不变）', (
      tester,
    ) async {
      await _pumpRows(tester, [NoteRow(key: const Key('attach'), note: _note())]);

      // 预核算式（修复前的判据）确实"有一条预览"……
      expect(
        listBriefOf(_kBrief),
        'l1.png nf.png',
        reason: '折叠空行后的预览文本（= 修复前要渲染的那一行）',
      );
      // ……但在这一行上它不渲染（修复后）
      expect(
        find.text('l1.png nf.png'),
        findsNothing,
        reason: '★ 修复前这里 findsOneWidget（就是多出来的那一行）',
      );
      // ★ 不丢信息：标题仍在，且两个附件名都在标题里、没有被 maxLines 截断
      final title = find.text(_kTitle);
      expect(title, findsOneWidget);
      final p = tester.renderObject<RenderParagraph>(title);
      expect(
        p.didExceedMaxLines,
        isFalse,
        reason: '★ 标题必须完整显示两个附件名（没被截断）',
      );
      expect(_kTitle.contains('l1.png') && _kTitle.contains('nf.png'), isTrue);
    });

    testWidgets('机制②：缩略图不决定行高 —— 槽位 = 两行文字高（36dp）', (
      tester,
    ) async {
      await _pumpRows(tester, [NoteRow(key: const Key('attach'), note: _note())]);
      final slot = tester.getSize(find.byType(NoteThumb));
      // ignore: avoid_print
      print('[D10] thumb slot=$slot listRowThumbSlotHeight=$listRowThumbSlotHeight');
      expect(
        slot.height,
        lessThanOrEqualTo(listRowThumbSlotHeight),
        reason: '★ 缩略图槽位不许超过两行文字高（36dp）；'
            '修复前 = 40×50 + top 2 = 52.0dp',
      );
      // 行高由文字决定 ⇒ 同样文字下，有缩略图与只有图标必须**等高**
      await _pumpRows(tester, [
        NoteRow(key: const Key('a'), note: _note()),
        NoteRow(
          key: const Key('b'),
          note: _note(withThumb: false),
        ),
      ]);
      final withThumb = _h(tester, 'a');
      final withIcon = _h(tester, 'b');
      // ignore: avoid_print
      print('[D10] withThumb=$withThumb withIcon=$withIcon');
      expect(
        (withThumb - withIcon).abs(),
        lessThanOrEqualTo(_kMaxRowDeltaDp),
        reason: '★ 缩略图只是装饰，不许把行撑高（修复前 68.0 vs 52.0）',
      );
    });

    // ---------------------------------------------------------------- 反向验证
    testWidgets('★ 反向 A：不封槽（缩略图 40×50）⇒ 槽位 52dp，比两行文字高 16dp', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(420, 1000));
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: ListView(
                children: [
                  NoteThumb(
                    objectId: 'o',
                    thumb: const NoteThumbDto(
                      source: 'file-id-1',
                      type: 'image/jpeg',
                    ),
                    size: 40, // 修复前的写法：不传 maxSlotHeight
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final pre = tester.getSize(find.byType(NoteThumb)).height;
      // ignore: avoid_print
      print('[D10] pre-fix thumb slot=$pre capped=$listRowThumbSlotHeight');
      expect(pre, 52.0, reason: '修复前：40×50 + top 2 = 52.0dp');
      expect(
        pre - listRowThumbSlotHeight,
        greaterThan(_kMaxRowDeltaDp * 8),
        reason: '★ 这 16.0dp 的差值 ≫ 阈值 ⇒ 若把 `maxSlotHeight:` 去掉，'
            '上面那条"等高"断言立刻变红',
      );
    });

    testWidgets('★ 反向 B：预览照渲染（修复前的判据）⇒ 行高 70dp，比普通行高 18dp', (
      tester,
    ) async {
      // 修复前的判据 = `listBriefOf(brief).isNotEmpty` ⇒ 它在这里是 true（要渲染）
      expect(listBriefOf(_kBrief).isNotEmpty, isTrue);
      expect(
        listBriefFor(_kTitle, _kBrief),
        isEmpty,
        reason: '★ 修复后：预览不提供标题里没有的信息 ⇒ 不渲染',
      );
      // 同一段预览一旦被渲染（用一个"标题不含这些词元"的笔记走真实产品路径），
      // 行高就是 70dp —— 比普通行高 18dp，正是真机像素上那多出来的一行。
      await _pumpRows(tester, [
        NoteRow(
          key: const Key('normal'),
          note: _note(title: 'test', brief: _kNormalBrief, withThumb: false),
          notebookTitle: 'My notebook',
        ),
        NoteRow(
          key: const Key('rendered-preview'),
          note: _note(title: 'x', brief: _kBrief),
          notebookTitle: 'My notebook',
        ),
      ]);
      final normal = _h(tester, 'normal');
      final withPreview = _h(tester, 'rendered-preview');
      // ignore: avoid_print
      print('[D10] normal=$normal previewRendered=$withPreview');
      expect(withPreview - normal, greaterThanOrEqualTo(8.0));
      // 主判据的反向：预览一旦被渲染，行盒数就是 3（≠ 普通行的 2）
      expect(_rowLineBoxes(tester, 'normal'), 2);
      expect(_rowLineBoxes(tester, 'rendered-preview'), 3);
      expect(
        (withPreview - normal).abs(),
        greaterThan(_kMaxRowDeltaDp),
        reason: '★ 若把 `listBriefFor` 改回 `listBriefOf` 直接渲染，附件行会变成这个'
            '高度 ⇒ 上面"等高"断言变红',
      );
    });

    testWidgets('★ 反向下限：有信息量的预览必须照常渲染（不是"把预览全删了"）', (
      tester,
    ) async {
      await _pumpRows(tester, [
        NoteRow(
          key: const Key('unique'),
          note: _note(title: '会议纪要', brief: '预算 与 排期'),
        ),
      ]);
      expect(
        find.text('预算 与 排期'),
        findsOneWidget,
        reason: '★ 预览带来新信息时必须还在（反向下限：不许靠"删掉预览"消除不一致）',
      );
      expect(_h(tester, 'unique'), greaterThan(52.0));
    });
  });

  // ------------------------------------------------------------ 纯函数（唯一换算）
  group('listBriefFor（列表行/网格卡真正要渲染的预览）', () {
    test('真机原文：预览只是标题的重复 ⇒ 空（不占一个行盒）', () {
      expect(listBriefFor(_kTitle, _kBrief), isEmpty);
      expect(listBriefOf(_kBrief), 'l1.png nf.png', reason: '数据没被丢，只是不重复渲染');
    });

    test('预览里有标题没有的词元 ⇒ 照常返回（不做任何削减）', () {
      expect(listBriefFor('会议纪要', '预算 与 排期'), '预算 与 排期');
      expect(listBriefFor('test', 'test 之外还有内容'), 'test 之外还有内容');
      expect(listBriefFor('', 'l1.png nf.png'), 'l1.png nf.png',
          reason: '标题为空（"无标题笔记"）⇒ 预览是唯一入口，必须渲染');
    });

    test('预览本身为空 / 全是空行 ⇒ 空', () {
      expect(listBriefFor('t', ''), isEmpty);
      expect(listBriefFor('t', _kNormalBrief), isEmpty);
      expect(listBriefFor('t', '\n\n \t\n'), isEmpty);
    });

    test('切不出词元的文字（非拉丁/非 CJK）不许乱去重：只认逐字相等', () {
      expect(listBriefFor('Привет', 'Привет'), isEmpty);
      expect(listBriefFor('Привет', 'другой текст'), 'другой текст',
          reason: '★ 词元切不出来时保守：宁可多渲染一行，也不许把信息去没');
    });

    test('大小写 / 各类分隔符都按同一组词元比较', () {
      expect(listBriefFor('L1.PNG / NF.PNG', 'l1.png\nnf.png'), isEmpty);
      expect(listBriefFor('a-b_c', 'a b c'), isEmpty);
    });
  });
}
