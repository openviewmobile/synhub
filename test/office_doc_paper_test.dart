// O1（`.odoc` 重做）—— **纸面分页**的离线用例（纯 Dart，无 widget）。
//
// 分页是**估算**（真机 5 份 `.odoc` 的 `page`/`page_break` 计数全为 0，
// 见 `docs/office-doc-redesign-report.md` §六），所以这里断言的是**不变量**：
//   * 一个块都不会丢（估算偏小只会让纸长高，绝不裁字）；
//   * 真实 `page_break` 是权威边界（强制换页）；
//   * 每页的估算高度不超过内容高（除非单块本身就超高）。
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/office/office_doc_paper.dart';

void main() {
  const contentWidth = 601.73;
  const contentHeight = 930.53; // A4 1122.53 − 2×96

  OfficeDocHeightInput para(String text, {double pt = 11}) =>
      OfficeDocHeightInput(kind: 'paragraph', text: text, fontSizePt: pt);

  test('L1. 顶部块的估算高度单调：字号越大越高、文本越长越高', () {
    final short = OfficeDocPaginator.estimateHeight(
      para('短句。'),
      contentWidth: contentWidth,
    );
    final long = OfficeDocPaginator.estimateHeight(
      para('很长的一段文字。' * 40),
      contentWidth: contentWidth,
    );
    final big = OfficeDocPaginator.estimateHeight(
      para('短句。', pt: 24),
      contentWidth: contentWidth,
    );
    expect(long, greaterThan(short));
    expect(big, greaterThan(short));
  });

  test('L2. 空段落也占一行（不塌成 0）', () {
    final h = OfficeDocPaginator.estimateHeight(
      const OfficeDocHeightInput(kind: 'paragraph', text: ''),
      contentWidth: contentWidth,
    );
    expect(h, greaterThanOrEqualTo(OfficeDocPaginator.minLineHeight));
  });

  test('L3. 分页不丢块：所有下标恰好出现一次，且顺序保持', () {
    final inputs = <OfficeDocHeightInput>[
      for (var i = 0; i < 60; i++) para('第 $i 段：一段普通长度的正文文字。'),
    ];
    final pagination = OfficeDocPaginator.paginate(
      inputs,
      contentWidth: contentWidth,
      contentHeight: contentHeight,
    );
    expect(pagination.pageCount, greaterThan(1));
    final flat = <int>[
      for (final page in pagination.pages) ...page.blockIndices,
    ];
    expect(flat.length, inputs.length);
    expect(flat, List<int>.generate(inputs.length, (i) => i));
  });

  test('L4. 真实 page_break 是权威边界（该块之前强制换页）', () {
    final inputs = <OfficeDocHeightInput>[
      para('第一页内容的最后一段。'),
      const OfficeDocHeightInput(kind: 'pageBreak', forcedBreakBefore: true),
      para('第二页的第一段。'),
    ];
    final pagination = OfficeDocPaginator.paginate(
      inputs,
      contentWidth: contentWidth,
      contentHeight: contentHeight,
    );
    expect(pagination.pageCount, 2);
    expect(pagination.pages[0].blockIndices, <int>[0]);
    expect(pagination.pages[1].blockIndices, <int>[1, 2]);
  });

  test('L5. 单块高于整页时也**不裁**：它独占一页并允许纸面长高', () {
    final inputs = <OfficeDocHeightInput>[
      OfficeDocHeightInput(kind: 'table', declaredHeight: contentHeight * 2),
      para('后面还有内容。'),
    ];
    final pagination = OfficeDocPaginator.paginate(
      inputs,
      contentWidth: contentWidth,
      contentHeight: contentHeight,
    );
    expect(pagination.pages[0].blockIndices, <int>[0]);
    expect(pagination.pages[1].blockIndices, <int>[1]);
  });

  test('L6. 页码换算：offsetOfPage / pageIndexAtOffset 自洽', () {
    final inputs = <OfficeDocHeightInput>[
      for (var i = 0; i < 40; i++) para('第 $i 段。'),
    ];
    final pagination = OfficeDocPaginator.paginate(
      inputs,
      contentWidth: contentWidth,
      contentHeight: contentHeight,
      gap: 24,
    );
    expect(pagination.pageCount, greaterThan(1));
    expect(pagination.pageIndexAtOffset(0), 0);
    for (var i = 0; i < pagination.pageCount; i++) {
      expect(pagination.pageIndexAtOffset(pagination.offsetOfPage(i)), i);
    }
    expect(
      pagination.pageIndexAtOffset(pagination.totalEstimatedHeight + 100),
      pagination.pageCount - 1,
    );
  });

  test('L7. 空输入 → 空分页（页面据此显示空状态，而不是崩）', () {
    final pagination = OfficeDocPaginator.paginate(
      const <OfficeDocHeightInput>[],
      contentWidth: contentWidth,
      contentHeight: contentHeight,
    );
    expect(pagination.isEmpty, isTrue);
    expect(pagination.pageCount, 0);
  });

  test('L8. 表格/图片按**声明高度**参与分页（不是按行数猜）', () {
    expect(
      OfficeDocPaginator.estimateHeight(
        const OfficeDocHeightInput(kind: 'table', declaredHeight: 140),
        contentWidth: contentWidth,
      ),
      140,
    );
    expect(
      OfficeDocPaginator.estimateHeight(
        const OfficeDocHeightInput(kind: 'image', declaredHeight: 220),
        contentWidth: contentWidth,
      ),
      220,
    );
  });
}
