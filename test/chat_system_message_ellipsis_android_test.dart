// r121 Android 逐屏截图审计 —— D5：聊天页**系统消息**在右边缘被从字符中间切断、无省略号。
//
// 台账：`docs/android-ui-screenshot-audit.md` §2 D5 / §1.4（截图 `chat_10_crop_v.png`）。
//
// ## 事实（截图逐字）
// `chat_10_crop_v.png` 里那条系统消息逐字是：
//   `Channel flt-p9v-vote-670106 was closed. Reason: kokukaka closed this channel.`
// 芯片左边缘在 x≈72px 处开始，文字一直画到裁剪图的右边界**被从字符中间切断**，
// 没有省略号 —— 也就是 `TelemetryLabel` 的 `overflow: ellipsis` 根本没生效。
//
// ## 机制与修法（与 iOS r132 同源，`hud_widgets.dart`）
// `Row(mainAxisSize: MainAxisSize.min)` 给**非 flex 子项**的横向约束是**无界**的
// （`RenderFlex` 只约束交叉轴）⇒ `Text` 按自然宽度撑开、省略号永不生效。修法是把
// `TelemetryLabel` 套进 `Flexible`（拿到"剩余宽度"这个有界约束）。iOS 侧回归在
// `test/hud_chip_overflow_test.dart`（393pt）—— 它由**另一个代理**持有，本文件不重复也不改它。
//
// ## 为什么另有这一份（Android 几何）
// AGENTS §2.0.21 铁律 3 / §2.0.10 铁律 3：本仓用例默认窗口比手机宽 ⇒ 量不到这类缺陷。
// 这里把视图钉成**审计真机**：1148×2492 @ DPR 2.75 ⇒ 417.45dp，内容区
// 417.45 − 2×`Gap.xl`(24) = 369.45dp（`chat_page.dart:2521` 的
// `Padding(horizontal: Gap.xl) > Center > HudChip(dense: true)` 就是审计现场）。
//
// 全程纯 `flutter test`（规程 §5.1：不碰真机/真 NAS）。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_tokens.dart';
import 'package:synhub/src/core/ui/hud_widgets.dart';

/// `chat_10_crop_v.png` 上那条系统消息（逐字，见文件头）。
const String _auditSystemMessage =
    'Channel flt-p9v-vote-670106 was closed. Reason: kokukaka closed this '
    'channel.';

/// 审计真机几何：1148×2492 @ 2.75 ⇒ 417.45dp 宽。
const Size _kAuditPixels = Size(1148, 2492);
const double _kAuditDpr = 2.75;
const double _kAuditWidth = 1148 / 2.75;

/// 系统消息内容区宽度 = 屏宽 − 2×`Gap.xl`（`chat_page.dart` 的
/// `Padding(horizontal: Gap.xl) > Center > HudChip`）。
const double _kContentWidth = _kAuditWidth - 2 * Gap.xl;

/// 照抄 `_PostTile` 的系统消息分支（`chat_page.dart:2520-2539`）。
Widget _systemMessage(String text) => Padding(
  padding: const EdgeInsets.symmetric(horizontal: Gap.xl, vertical: Gap.sm),
  child: Center(child: HudChip(text: text, dense: true)),
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = _kAuditPixels;
  tester.view.devicePixelRatio = _kAuditDpr;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: child)),
  );
  await tester.pump();
}

void main() {
  testWidgets('D5 反向验证：修复前的形态（裸 Row + 长系统消息）在 417dp 上真的溢出', (
    tester,
  ) async {
    // 这就是 `hud_widgets.dart` 里 `HudChip` 改动前的结构：
    // Container(padding) > Row(mainAxisSize: min) > [Icon, Gap, TelemetryLabel]
    await _pump(
      tester,
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          color: const Color(0xFF23303F),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.circle, size: 11),
              const SizedBox(width: 5),
              TelemetryLabel(
                _auditSystemMessage,
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
    expect(
      ex,
      isNotNull,
      reason:
          '裸 Row(mainAxisSize: min) 里的长文本必须撑破 $_kContentWidth dp —— '
          '这条为空说明本用例已经量不到缺陷（判据失效）',
    );
    expect('$ex', contains('overflowed by'));
  });

  testWidgets('D5 HudChip 在 417dp 上不许溢出，且完整落在内容区里', (tester) async {
    await _pump(tester, _systemMessage(_auditSystemMessage));
    expect(
      tester.takeException(),
      isNull,
      reason: '审计里的缺陷就是"画到屏幕外被切断"，这里必须零异常',
    );
    final rect = tester.getRect(find.byType(HudChip));
    expect(
      rect.right,
      lessThanOrEqualTo(_kAuditWidth - Gap.xl + 0.01),
      reason:
          '芯片右边缘不得越过内容区右缘（= 截图上"从字符中间切断"的那个位置）；'
          '实测 right=${rect.right.toStringAsFixed(1)}dp，'
          '内容区右缘 ${(_kAuditWidth - Gap.xl).toStringAsFixed(1)}dp'
          '（内容宽 $_kContentWidth dp）',
    );
    expect(rect.width, greaterThan(0));
  });

  testWidgets('D5 省略号真的生效（不是靠裁剪糊过去）', (tester) async {
    await _pump(tester, _systemMessage(_auditSystemMessage));
    final para = tester.renderObject<RenderParagraph>(
      find.text(_auditSystemMessage),
    );
    expect(
      para.didExceedMaxLines,
      isTrue,
      reason:
          'AGENTS §2.0.18 的验收口径：长文本必须被 `maxLines: 1` 截断并画省略号；'
          'false 说明文本仍按自然宽度铺开（就是 D5 的原始缺陷）',
    );
    // 反过来说明判据灵敏：同一段文字在足够宽的屏上**不该**被截断。
    tester.view.physicalSize = const Size(3000, 1200);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(
      MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: _systemMessage(_auditSystemMessage))),
    );
    await tester.pump();
    final wide = tester.renderObject<RenderParagraph>(
      find.text(_auditSystemMessage),
    );
    expect(
      wide.didExceedMaxLines,
      isFalse,
      reason: '宽屏（3000dp）上这段文字放得下 ⇒ 上一条的 true 才有意义',
    );
  });
}
