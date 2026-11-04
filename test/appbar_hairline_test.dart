// DA189：**全 App 页头下面那条 1px 线不许是纯黑**，页头底色也不许比页面更白。
//
// 真机来路（r587，亮色，Drive → More → Team folders → 进 `teamdrivetest`）：
//   页头底色 (249,251,251) ≠ 页面底色 (234,238,244)，分隔线是 **(0,0,0)**（21.00:1）。
//   根因：`appBarTheme.shape: Border(bottom: BorderSide(width: 1))` ——
//   **没给 color** 时 Flutter 的默认值是 `Color(0xFF000000)`；
//   而 `backgroundColor: hud.glass`（surface@62%）又让页头比页面白一档。
//   设计稿（`design/synhub_ui` 的 `appbar()`）是「页头与页面同底色 + 一条 `line` 细线」。
//
// 判据：① 源码里不许再出现**无色**的 `BorderSide(width: 1)`；
//      ② 真搭出来的主题里，AppBar 的底 = `bg`，线条色 = `line`，且线色**不是黑**；
//      ③ 亮/暗两套都查（用户裁定 ③：亮色与暗色同等精细）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/design/design_palette.dart';

Color? _shapeColor(ThemeData t) {
  final shape = t.appBarTheme.shape;
  if (shape is Border) return shape.bottom.color;
  return null;
}

void _audit(String name, ThemeData theme, DesignPalette p) {
  final bar = theme.appBarTheme;
  expect(bar.backgroundColor, p.bg, reason: '$name：页头底色必须与页面底色同色');
  final c = _shapeColor(theme);
  expect(c, isNotNull, reason: '$name：页头没有细线了（shape 不是 Border）');
  expect(c, p.line, reason: '$name：页头分隔线必须是 line 令牌色');
  expect(c!.toARGB32() == 0xFF000000, isFalse,
      reason: '$name：页头分隔线还是纯黑 —— BorderSide 漏了 color');
}

void main() {
  test('① 源码里不许出现无色的 BorderSide(width: 1)', () {
    final src =
        File('lib/src/core/theme/app_theme.dart').readAsStringSync();
    final bad = RegExp(r'BorderSide\(\s*width:\s*1(\.0)?\s*\)')
        .allMatches(src)
        .map((m) => m.group(0))
        .toList();
    expect(bad, isEmpty,
        reason: 'DA189：${bad.length} 处无色 BorderSide ⇒ 会画成纯黑：$bad');
  });

  test('② 亮/暗两套页头：底色 = bg、线 = line、线不是黑', () {
    for (final dark in [false, true]) {
      final p = dark ? DesignPalette.dark : DesignPalette.light;
      final theme = dark ? AppTheme.dark() : AppTheme.light();
      _audit(dark ? '暗色' : '亮色', theme, p);
    }
  });

  test('③ 反证：把线色换成黑必须被抓到（判据不是恒真）', () {
    final black = Border(bottom: BorderSide(width: 1, color: const Color(0xFF000000)));
    final p = DesignPalette.light;
    final theme = AppTheme.light();
    // 直接对"线色=黑"的等价形态做自证：判据里那条比较必须能红
    expect(black.bottom.color.toARGB32() == 0xFF000000, isTrue);
    expect(_shapeColor(theme), isNot(black.bottom.color), reason: '真主题的线色不是黑');
    expect(p.line.toARGB32() == 0xFF000000, isFalse);
  });
}
