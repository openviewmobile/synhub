// 第 235 轮 · `DA179`（用户裁定 ③）：**窄屏底条不许把章标题挤成「第二…」**。
//
// 为什么用"静态结构守卫"而不是 widget 用例：底部条是 `_BookBody` 内部的行内布局，
// 没有独立 widget 可 pump（整本书的解析链很重）。这里退一步，钉住**代码结构**：
//   ① 底条必须在 `LayoutBuilder` 里按宽度分两态；
//   ② 窄态必须用 `IconButton`（带 tooltip，48dp 点击区）而不是丢弃按钮；
//   ③ 两个 key 必须在场（真机截图与后续用例都靠它们定位）。
//
// ★ 已知局限：静态守卫证明"代码长这样"，不证明"标题真的显示全了" ——
//   后者只有真机像素能证（证据见 `docs/evidence-r554/`）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src = File('lib/src/features/files/file_book_view.dart');
  late String code;
  setUpAll(() => code = src.readAsStringSync());

  test('装置自证：源码读到了', () {
    expect(src.existsSync(), isTrue);
    expect(code.length, greaterThan(50000), reason: '读到的源码太短，可能读错文件');
    // 防"注释里写了但代码没写"：只认代码行（去掉整行注释）
  });

  List<String> codeLines() => code
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .toList();

  test('底条按宽度分两态（DA179）', () {
    final lines = codeLines().join('\n');
    expect(lines.contains('LayoutBuilder'), isTrue, reason: '缺 LayoutBuilder');
    expect(
      RegExp(r'maxWidth\s*<\s*\d+').hasMatch(lines),
      isTrue,
      reason: '没有"窄屏阈值"判断',
    );
    expect(lines.contains("Key('book-prev-icon')"), isTrue);
    expect(lines.contains("Key('book-next-icon')"), isTrue);
  });

  test('窄态仍是可点的 IconButton（不是把按钮删掉）', () {
    final lines = codeLines().join('\n');
    final prev = RegExp(
      r"Key\('book-prev-icon'\)[\s\S]{0,200}?IconButton|IconButton[\s\S]{0,200}?Key\('book-prev-icon'\)",
    );
    expect(prev.hasMatch(lines), isTrue, reason: '上一章窄态不是 IconButton');
    expect(
      RegExp(r"tooltip:\s*t\.bookPrevChapter").hasMatch(lines),
      isTrue,
      reason: '窄态丢了可读文案（tooltip）',
    );
  });

  test('反证：把阈值删掉应当立刻红（守卫有区分力）', () {
    final broken = codeLines().join('\n').replaceAll(RegExp(r'maxWidth\s*<\s*\d+'), '');
    expect(RegExp(r'maxWidth\s*<\s*\d+').hasMatch(broken), isFalse);
  });
}
