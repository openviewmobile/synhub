// 第 240 轮 · `DA184`（用户裁定 ③）：**黑底查看器里的按钮不许是"跟着壁纸走的淡色板"**。
//
// 真机事实：大图查看器是 `backgroundColor: Colors.black`；`FilledButton.tonalIcon`
// 的底是 `secondaryContainer`（亮色下淡紫）⇒ 黑底上出现一块浅色板子，
// 和 `DA168`（媒体兜底面板）是同一类问题。
//
// 判据：
//   ① 「让 NAS 生成预览」按钮的解析底色必须是 `colorScheme.primary`（不是 secondaryContainer）；
//   ② 文字/图标对底色 ≥4.5:1；
//   ③ 反证：tonal 的默认底色确实**不是** primary（否则本用例没有区分力）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/photos/photo_format_fallback.dart';

double _ratio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  testWidgets('黑底查看器兜底按钮：底色是 primary 且可读（DA184）', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            backgroundColor: Colors.black,
            body: PhotoFormatFallback(
              filename: 'IMG_0001.HEIC',
              onDownload: () {},
              onOpenExternal: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final btn = tester.widget<FilledButton>(
      find.byKey(const Key('photo-heic-regenerate')),
    );
    final ctx = tester.element(find.byKey(const Key('photo-heic-regenerate')));
    final scheme = Theme.of(ctx).colorScheme;
    // `InlineButtonStyle.filled` 只改尺寸/形状、不改颜色 ⇒ 底色落到 FilledButton 的默认
    // （`colorScheme.primary`）。tonalIcon 则会被解析成 `secondaryContainer` ——
    // 所以下面这条断言对"回退成 tonal"有区分力。
    final bg = btn.style?.backgroundColor?.resolve({}) ?? scheme.primary;
    expect(bg, scheme.primary, reason: '黑底上的按钮必须用 primary，不能用 secondaryContainer');
    expect(bg, isNot(scheme.secondaryContainer));

    final fg = btn.style?.foregroundColor?.resolve({}) ?? scheme.onPrimary;
    final r = _ratio(fg, bg);
    expect(r, greaterThanOrEqualTo(4.5), reason: '按钮文字 $fg on $bg = ${r.toStringAsFixed(2)}:1');
    // 对黑底也要看得出边界（按钮不是隐形）
    expect(_ratio(bg, Colors.black), greaterThanOrEqualTo(3.0));
  });

  test('反证：tonal 的默认底不是 primary', () {
    final theme = AppTheme.light();
    final scheme = theme.colorScheme;
    expect(scheme.secondaryContainer, isNot(scheme.primary));
    // 淡紫色板子对纯黑的对比很高（≈14:1）——它的问题不是"看不清"，是"在白底观看的黑页里突兀"，
    // 这里只钉"它不是 primary"这一条。
    expect(_ratio(scheme.secondaryContainer, Colors.black), greaterThan(10));
  });
}
