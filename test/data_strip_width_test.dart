// `DA283`（r664）回归：底部滚动遥测带（`DataStrip`）**必须吃满父级宽度**。
//
// 缺陷现场：`DataStrip` 外层 `SizedBox` 只给了 `height`，里面是
// `ClipRect → LayoutBuilder → Stack`，而 Stack 的子节点**全是 `Positioned`**
// ⇒ Stack 量出来 0×0 ⇒ 整条带子塌成 32×30.8 的灰方块（iOS/Web 像素取证），
// 遥测文字被 ClipRect 全裁掉，等于这条信息带从来没显示过。
//
// 判据（像素/几何两条都钉住）：
//   ① 宽度 == 父级宽度（300），不是 32；
//   ② 高度 == `height`；
//   ③ 条带里的文字**真的在树里**（不是被裁掉的空容器）；
//   ④ 反向：把宽度写死成 32 的那种"塌陷"尺寸不再出现。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/ui/tech_frame.dart';

void main() {
  testWidgets('DA283 DataStrip 吃满父级宽度（不再塌成 32 宽的灰方块）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  DataStrip(
                    prefix: 'TELEMETRY',
                    items: ['NODE DIRECT', 'TARGET nas.example.com', 'APP v1'],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final size = tester.getSize(find.byType(DataStrip));
    expect(size.width, 300, reason: 'DA283：宽度必须吃满父级（塌陷时是 32）');
    expect(size.width, isNot(32));
    expect(size.height, 22, reason: '高度仍由 height 参数决定');
    expect(
      find.textContaining('NODE DIRECT'),
      findsOneWidget,
      reason: 'DA283：滚动的遥测文字必须真的在树里（以前被零宽 ClipRect 裁掉）',
    );
  });
}
