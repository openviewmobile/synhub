// ★★ r132（iOS 逐屏截图审计）：**`HudChip` 里的长文本必须省略号，不许溢出**。
//
// ## 事实（真模拟器像素 + 渲染库日志，不是推断）
// iPhone 16 / iOS 18.6（393pt 宽，内容区 329pt）逐屏走查里，聊天页的**系统消息**
// 连着报 5 次：
//
// ```
// ══╡ EXCEPTION CAUGHT BY RENDERING LIBRARY ╞══
// A RenderFlex overflowed by 185 pixels on the right.
// The relevant error-causing widget was:
//   Row Row:file:///…/lib/src/core/ui/hud_widgets.dart:98:14
//   creator: Row ← Padding ← DecoratedBox ← Container ← HudChip ← Center ← Padding ←
//            _PostTile-[<'post-1138166333447-0'>] ← …
//   constraints: BoxConstraints(0.0<=w<=329.0, 0.0<=h<=Infinity)
//   size: Size(329.0, 13.0)
// ```
//
// 触发文案就是 `s022` 截图里那几句：`demo_user Cannot enter this channel;
// its permissions must be restored by another user.`（长句系统提示）。
//
// 机制：`TelemetryLabel` 里确实是 `Text(maxLines: 1, overflow: ellipsis)`，
// 但 `Row(mainAxisSize: MainAxisSize.min)` 给**非 flex 子项**的横向约束是
// **无界**的（`RenderFlex` 只约束交叉轴）⇒ `Text` 按自然宽度撑开、省略号永不生效
// ⇒ 芯片超出父约束 = 视觉裁切 + 黄黑条纹（release 同样画不下）。
//
// 修法：把 `TelemetryLabel` 套进 `Flexible`（拿到"剩余宽度"这个**有界**约束）。
//
// ## 反向验证（本仓规矩：证明用例真抓得住缺陷）
// 第 ① 条**用修复前的形态**（裸 `Row(mainAxisSize: min)` + 长 `TelemetryLabel`）
// ⇒ 必须真抛 `RenderFlex overflowed`；第 ② 条用 `HudChip` ⇒ 零异常且宽度 ≤ 约束。
// 把 `hud_widgets.dart` 里那个 `Flexible` 拆掉，第 ② 条当场红。
//
// ## 为什么必须按 393pt 量（AGENTS §2.0.21 铁律 3）
// 本仓既有用例多在 420pt / 800x600 的窗口里跑 —— 那条 185px 的溢出在宽屏上
// **根本量不到**（假绿温床）。所以这里把视图钉成 iPhone 16 的物理尺寸。
//
// 全程纯 `flutter test`（规程 §5.1：不碰真机/真 NAS）。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/ui/hud_widgets.dart';

/// 真机截图上那句系统消息（长度是关键，185px 就是它撑出来的）。
const String _longSystemMessage =
    'demo_user Cannot enter this channel; its permissions must be restored by '
    'another user.';

/// iPhone 16：逻辑 393×852，DPR 3。
const Size _iphone16 = Size(393, 852);
const double _dpr = 3;

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = Size(_iphone16.width * _dpr, _iphone16.height * _dpr);
  tester.view.devicePixelRatio = _dpr;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.light(),
      home: Scaffold(body: Center(child: child)),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('① 反向验证：修复前的形态（裸 Row + 长文本）在 393pt 上必须真的溢出',
      (tester) async {
    // 这就是 `hud_widgets.dart:98` 改动前的结构：
    // Container(padding) > Row(mainAxisSize: min) > [Icon, Gap, TelemetryLabel]
    await _pump(
      tester,
      Padding(
        // `_PostTile` 的系统消息分支外面是 `Padding(horizontal: Gap.xl)`
        // ⇒ 可用宽度 393 - 2*32 = 329pt（与真机日志里的 329.0 一致）。
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          color: const Color(0xFFE8EEF6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.circle, size: 11),
              const SizedBox(width: 5),
              TelemetryLabel(
                _longSystemMessage,
                size: 10.5,
                weight: FontWeight.w600,
                letterSpacing: 0.8,
              ),
            ],
          ),
        ),
      ),
    );
    final ex = tester.takeException();
    expect(ex, isNotNull,
        reason: '裸 Row(mainAxisSize: min) 里的长文本必须撑破 329pt —— '
            '这条为空说明本用例已经量不到缺陷（判据失效）');
    expect('$ex', contains('overflowed by'));
  });

  testWidgets('② HudChip 在同一宽度下不许溢出，且宽度不超过约束', (tester) async {
    await _pump(
      tester,
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: const HudChip(text: _longSystemMessage, dense: true),
      ),
    );
    expect(tester.takeException(), isNull,
        reason: 'r132 修复后 HudChip 必须自己省略号收住，不许溢出');
    final size = tester.getSize(find.byType(HudChip));
    expect(size.width, lessThanOrEqualTo(329 + 0.01),
        reason: '芯片宽度必须 ≤ 329pt（iPhone 16 内容区），实测 ${size.width}');
  });

  testWidgets('③ 省略号真的生效（不是靠裁剪糊过去）', (tester) async {
    await _pump(
      tester,
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: const HudChip(text: _longSystemMessage, dense: true),
      ),
    );
    final para = tester.renderObject<RenderParagraph>(
      find.text(_longSystemMessage),
    );
    expect(para.didExceedMaxLines, isTrue,
        reason: '长系统消息应被 maxLines:1 截断并画省略号（AGENTS §2.0.18 的验收口径）');
  });

  testWidgets('④ 短文本不许被改宽度（Flexible 不是恒过的副作用）', (tester) async {
    await _pump(tester, const HudChip(text: '已连接'));
    expect(tester.takeException(), isNull);
    final chip = tester.getSize(find.byType(HudChip));
    final label = tester.getSize(find.byType(TelemetryLabel));
    // 短文本时芯片宽度 = 内边距 + 文本自然宽度（不允许被压扁或拉满）。
    expect(chip.width, lessThan(140));
    expect(chip.width, greaterThan(label.width));
  });
}
