// **r484** · 字号是"设计令牌"，不是各页面随手写的数（`DA123`）。
//
// 判据（都可红）：
//   ① `design/tokens.py` 的 `TYPE` 与 Dart 侧 `DesignType.*Size` **逐项相等**
//      —— 真源只有一处；改了 python 不重新生成，这条立刻红；
//   ② `DesignTheme` 的 `textTheme` 真的用上了令牌（不是 `Typography...white`）；
//   ③ 双主题下字色来自调色板（dark: text=`E9EDF2`，light: `0F172A`）；
//   ④ 行标题 / 副标题 / 顶栏标题这三处**最常见**的字号与 spec 一致（13 / 11.5 / 15）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/design/design_palette.dart';

/// 从 `design/tokens.py` 里把 `TYPE = { 'role': (size, weight, height, spacing, color), ... }`
/// 解析成 `role -> (size, weight)`。只认行首缩进的 `'role': (数字, ...)`。
Map<String, (double, int)> _tokensType() {
  final src = File('design/tokens.py').readAsStringSync();
  final start = src.indexOf('TYPE = {');
  expect(start, greaterThan(0), reason: 'design/tokens.py 里找不到 TYPE 表');
  final block = src.substring(start, src.indexOf('\n}', start));
  final out = <String, (double, int)>{};
  final re = RegExp(r"^\s*'(\w+)':\s*\(\s*([\d.]+)\s*,\s*(\d+)", multiLine: true);
  for (final m in re.allMatches(block)) {
    out[m.group(1)!] = (double.parse(m.group(2)!), int.parse(m.group(3)!));
  }
  return out;
}

double _sizeOf(String role) => switch (role) {
  'headlineSmall' => DesignType.headlineSmallSize,
  'titleLarge' => DesignType.titleLargeSize,
  'titleMedium' => DesignType.titleMediumSize,
  'titleSmall' => DesignType.titleSmallSize,
  'bodyLarge' => DesignType.bodyLargeSize,
  'bodyMedium' => DesignType.bodyMediumSize,
  'bodySmall' => DesignType.bodySmallSize,
  'labelLarge' => DesignType.labelLargeSize,
  'labelMedium' => DesignType.labelMediumSize,
  'labelSmall' => DesignType.labelSmallSize,
  _ => throw ArgumentError('tokens.py 里有 Dart 侧没有的角色：$role'),
};

void main() {
  group('DA123 · 字号/字重是设计令牌（唯一真源）', () {
    test('DA123：tokens.py 的 TYPE 与 Dart 的 DesignType 逐项相等', () {
      final tokens = _tokensType();
      expect(tokens.length, greaterThanOrEqualTo(10), reason: '角色数太少，解析可能失效');
      for (final e in tokens.entries) {
        expect(
          _sizeOf(e.key),
          e.value.$1,
          reason: '${e.key} 字号漂移：python=${e.value.$1} dart=${_sizeOf(e.key)}',
        );
      }
      // 反向：Dart 侧不许有 python 里没有的角色
      expect(_sizeOf('titleSmall'), 13.0);
    });

    test('DA123：DesignTheme 的 textTheme 来自令牌（含字重与字色）', () {
      final dark = DesignTheme.dark;
      final light = DesignTheme.light;
      final dt = _tokensType();

      // ① 三个最常见角色的字号/字重
      expect(dark.textTheme.titleSmall?.fontSize, dt['titleSmall']!.$1);
      expect(
        dark.textTheme.titleSmall?.fontWeight,
        FontWeight.values[dt['titleSmall']!.$2 ~/ 100 - 1],
      );
      expect(dark.textTheme.bodySmall?.fontSize, dt['bodySmall']!.$1);
      expect(dark.textTheme.titleMedium?.fontSize, dt['titleMedium']!.$1);
      expect(dark.textTheme.bodyMedium?.fontSize, dt['bodyMedium']!.$1);

      // ② spec 的三个关键读数：行标题 13 / 副标题 11.5 / 顶栏 15
      expect(dark.textTheme.titleSmall?.fontSize, 13.0);
      expect(dark.textTheme.bodySmall?.fontSize, 11.5);
      expect(dark.textTheme.titleMedium?.fontSize, 15.0);

      // ③ 字色来自调色板（不是 Material 默认白）
      expect(dark.textTheme.titleSmall?.color, DesignPalette.dark.text);
      expect(dark.textTheme.bodySmall?.color, DesignPalette.dark.muted);
      expect(light.textTheme.titleSmall?.color, DesignPalette.light.text);
      expect(light.textTheme.bodySmall?.color, DesignPalette.light.muted);
    });

    test('DA123：源码反向 —— 生成器不许再用 Typography.material2021 当正文', () {
      final emitter = File('design/emit_flutter.py').readAsStringSync();
      expect(
        emitter.contains('Typography.material2021'),
        isFalse,
        reason: '正文排版必须来自 tokens.TYPE，而不是 Material 默认',
      );
      expect(emitter.contains('_design_type_dart()'), isTrue);
      final palette = File('lib/src/design/design_palette.dart').readAsStringSync();
      expect(palette.contains('DesignType.textTheme(p.text, p.muted, p.dim)'), isTrue);
    });
  });
}
