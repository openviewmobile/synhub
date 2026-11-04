// 第 233 轮 · `DA177`：**弹层必须是信息层，不能"透着读"**（用户裁定 ③）。
//
// 真机现象：亮色下打开"主题"选择弹层，被它盖住的页面文字（"Set manually to on…"、
// "Messages & media"）**透过弹层显形** —— 读起来像渲染故障。
// 根因：`bottomSheetTheme` 用的是 `glassStrong` = surface @93%（亮）/ @88%（暗）。
//
// 判据：① 亮/暗两套主题的弹层底色必须**完全不透明**；② 必须等于设计令牌的 `surface`
//      （不能是别的近似色，否则"看着像但差一档"）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/design/design_palette.dart';

void _audit(ThemeData theme, DesignPalette p, String label) {
  final bg = theme.bottomSheetTheme.modalBackgroundColor;
  expect(bg, isNotNull, reason: '$label：弹层必须显式给底色');
  expect(
    bg!.a,
    1.0,
    reason: '$label：弹层底色必须不透明（下层文字透上来会被读成故障）',
  );
  expect(bg, p.surface, reason: '$label：弹层底色必须是令牌 surface');
  // 普通（非 modal）弹层同理
  expect(theme.bottomSheetTheme.backgroundColor, p.surface, reason: '$label：backgroundColor');
}

void main() {
  test('亮色：弹层底色不透明且等于令牌 surface（DA177）', () {
    _audit(AppTheme.light(), DesignPalette.light, 'light');
  });

  test('暗色：弹层底色不透明且等于令牌 surface（DA177）', () {
    _audit(AppTheme.dark(), DesignPalette.dark, 'dark');
  });

  test('反证：旧的 `glassStrong` 写法确实不透明度过不了（否则本条没有区分力）', () {
    // 令牌口径：glassStrong = surface @93%（light）/ @88%（dark）
    expect(DesignPalette.light.surface.withValues(alpha: 0.93).a, lessThan(1.0));
    expect(DesignPalette.dark.surface.withValues(alpha: 0.88).a, lessThan(1.0));
  });
}
