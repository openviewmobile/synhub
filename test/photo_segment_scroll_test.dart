// 第 237 轮 · `DA181`（用户裁定 ③）：**选中的段必须完整落在可视区内**。
//
// 真机（亮色，Photos 分段条）：点最后一个「人物」后，胶囊被屏幕右缘切掉一半，
// 只剩「Peop」——因为 `PhotoSegment` 只是横向 `SingleChildScrollView`，
// 从来没有"把选中项滚进视野"的动作。
//
// 判据（行为级，不看代码长什么样）：
//   ① 窄屏 + 选项多、`index` 指向最后一项 ⇒ 该项矩形必须完整落在屏幕内；
//   ② 改选中间项后滚到该项，也完整可见；
//   ③ 反证：把 ensureVisible 的等价条件（完全可见）拿去量"改前"的布局推导会失败 ——
//      这里用"横向内容宽 > 视口宽"来证明本条用例确有溢出前提。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/photos/photo_widgets.dart';

const _labels = [
  '时间轴',
  '相册',
  '文件夹',
  '收藏',
  '人物',
  '场景',
];

Future<void> _pump(WidgetTester tester, int index) async {
  // 320dp：保证选项条**必然溢出**（测试字体比真机窄，393 下反而不溢出 ——
  // 仪器：「测试字体不是真机字体」，别用真机宽度当前提）
  tester.view.physicalSize = const Size(320 * 3, 851 * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: PhotoSegment(
            labels: _labels,
            index: index,
            onChanged: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Rect _rectOf(WidgetTester tester, String label) {
  return tester.getRect(
    find.ancestor(of: find.text(label), matching: find.byType(Material)).first,
  );
}

void main() {
  testWidgets('选中最后一段：必须完整可见（DA181）', (tester) async {
    await _pump(tester, _labels.length - 1);
    final screen = tester.getRect(find.byType(Scaffold));
    final r = _rectOf(tester, '场景');
    expect(r.left, greaterThanOrEqualTo(screen.left - 0.5),
        reason: '左缘被切：$r / 屏幕 $screen');
    expect(r.right, lessThanOrEqualTo(screen.right + 0.5),
        reason: '右缘被切：$r / 屏幕 $screen');
  });

  testWidgets('改选中间段：滚到它，也完整可见', (tester) async {
    await _pump(tester, 3);
    final screen = tester.getRect(find.byType(Scaffold));
    final r = _rectOf(tester, '收藏');
    expect(r.left, greaterThanOrEqualTo(screen.left - 0.5), reason: '$r / $screen');
    expect(r.right, lessThanOrEqualTo(screen.right + 0.5), reason: '$r / $screen');
  });

  testWidgets('前提自证：这个宽度下选项条确实会溢出（否则上述用例没有区分力）',
      (tester) async {
    await _pump(tester, 0);
    final viewport = tester.getRect(find.byType(SingleChildScrollView));
    final row = tester.getRect(find.byType(Row).first);
    expect(row.width, greaterThan(viewport.width),
        reason: '内容 ${row.width} 未超过视口 ${viewport.width}，'
            '说明本条用例测不到"切掉"的场景');
  });
}
