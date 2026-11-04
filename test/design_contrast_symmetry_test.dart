// 第 232 轮（用户裁定 ③「亮色要与暗色同等精细」）：**两套主题的对比度必须同等达标**。
//
// 为什么需要它：此前只零散地量过几屏像素，`primary` 当"选中芯片文字"时
// （`primary` on `primarySoft`）亮色只有 **4.24:1**、暗色 **4.36:1**，都低于 AA，
// 而**没有任何机检会红**（`DA172`/`DA174` 只查"用了哪个色"，不查"对比够不够"）。
//
// 判据（逐条都是"用户能读到字"的最低线）：
//   ① `text` / `muted` / `dim` 在 `bg` 与 `surface` 上都 ≥ 4.5（正文与次级文字）；
//   ② `primary` 当**文字**时（在 `surface` 与 `primarySoft` 上）≥ 4.5；
//   ③ `onPrimary` 当**按钮文字**压在 `primary` 上 ≥ 4.5；
//   ④ `danger` 在 `surface` 上 ≥ 4.5；`ok` 在 `surface` 上 ≥ 3.0（图标/徽标语义色）；
//   ⑤ 亮/暗**两套都必须过**——一条判据跑两遍，而不是只测暗色。
//
// 仪器自证：黑白必须量出 21.0:1（否则阈值不可信）。
//
// ★ 第 244 轮（`DA188`）：矩阵从 11 对扩到 21 对（补 `surface2` 软底与 `primarySoft` 选中底），
//   当场红了三条 —— 亮 `danger` on `surface2` 4.14、亮 `muted` on `primarySoft` 4.47、
//   暗 `dim` on `surface2` 3.74。三个令牌各推一档后全绿：
//   `design/tokens.py` 亮 danger `#DC2626`→`#C81E1E`、亮 muted `#5B6B7F`→`#566578`、
//   暗 dim `#7C8996`→`#8D9AA8`（`design_palette.dart` 同步）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/design/design_palette.dart';
import 'package:synhub/src/design/kit/design_kit.dart';

/// Flutter 自带的相对亮度（WCAG 同口径；不再手搓幂函数 —— 手搓的仪器本身就是风险）。
double _lum(Color c) => c.computeLuminance();

double ratio(Color a, Color b) {
  final la = _lum(a);
  final lb = _lum(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void _audit(String name, DesignPalette p, {required bool dark}) {
  final pairs = <String, (Color, Color, double)>{
    'text on bg': (p.text, p.bg, 4.5),
    'text on surface': (p.text, p.surface, 4.5),
    'muted on bg': (p.muted, p.bg, 4.5),
    'muted on surface': (p.muted, p.surface, 4.5),
    'dim on bg': (p.dim, p.bg, 4.5),
    'dim on surface': (p.dim, p.surface, 4.5),
    'primary on surface': (p.primary, p.surface, 4.5),
    'primary on primarySoft': (p.primary, p.primarySoft, 4.5),
    'onPrimary on primary': (p.onPrimary, p.primary, 4.5),
    'danger on surface': (p.danger, p.surface, 4.5),
    'ok on surface': (p.ok, p.surface, 3.0),
    // ★ 第 244 轮扩展（用户裁定 ③ 的"同等精细"落到**全部底色**上）：
    //   以前只测 `bg`/`surface`，可卡片里的软底是 `surface2`，
    //   而"选中芯片上的次级文字"压在 `primarySoft` 上 —— 这两类此前没人量。
    'text on surface2': (p.text, p.surface2, 4.5),
    'muted on surface2': (p.muted, p.surface2, 4.5),
    'dim on surface2': (p.dim, p.surface2, 4.5),
    'primary on surface2': (p.primary, p.surface2, 4.5),
    'danger on surface2': (p.danger, p.surface2, 4.5),
    'onPrimary on danger': (p.onPrimary, p.danger, 4.5),
    'accent on surface': (p.accent, p.surface, 4.5),
    'accent on bg': (p.accent, p.bg, 4.5),
    'muted on primarySoft': (p.muted, p.primarySoft, 4.5),
    'text on primarySoft': (p.text, p.primarySoft, 4.5),
    // ★ 刻意**不**把 `line on bg` 放进矩阵：发丝分隔线是装饰性描边，
    //   不承载"这是可操作边界"的信息（真正的可操作边界另有 `outline` 语义与
    //   点击区判据）。硬要 ≥3.0 会把 1px 分隔线逼成粗黑线，属于拿错标准卡设计。
  };
  final bad = <String>[];
  pairs.forEach((label, v) {
    final r = ratio(v.$1, v.$2);
    if (r < v.$3) {
      bad.add('$name / $label = ${r.toStringAsFixed(2)}:1（要求 ≥ ${v.$3}）');
    }
  });
  expect(bad, isEmpty, reason: '对比度不达标：\n${bad.join('\n')}');
}

void main() {
  test('仪器自证：黑白必须是 21.0:1', () {
    expect(
      ratio(const Color(0xFF000000), const Color(0xFFFFFFFF)),
      closeTo(21.0, 0.1),
    );
  });

  test('★ 亮色：全部文字/语义配色 ≥ AA', () {
    _audit('light', DesignPalette.light, dark: false);
  });

  test('★ 暗色：全部文字/语义配色 ≥ AA', () {
    _audit('dark', DesignPalette.dark, dark: true);
  });

  test('两套主题的 primary 不许"换主题就掉到 AA 以下"', () {
    expect(
      ratio(DesignPalette.light.primary, DesignPalette.light.primarySoft),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      ratio(DesignPalette.dark.primary, DesignPalette.dark.primarySoft),
      greaterThanOrEqualTo(4.5),
    );
  });

  test('★ Material 组件读的 scheme.primary 也必须 ≥ AA（芯片选中文案）', () {
    // 品牌种子 → fromSeed 的 primary 并不是令牌值；动态取色 → 壁纸色相。
    // 两条路径都要能用"选中芯片"读得清：primary on primaryContainer。
    for (final seed in const [
      Color(0xFF1B69C1), // 品牌蓝
      Color(0xFF007FAC), // 本机读到的 systemAccent
      Color(0xFFB00020), // 红
      Color(0xFF2E7D32), // 绿
    ]) {
      for (final b in const [Brightness.light, Brightness.dark]) {
        final th = b == Brightness.light
            ? AppTheme.light(dynamic: ColorScheme.fromSeed(seedColor: seed))
            : AppTheme.dark(
                dynamic: ColorScheme.fromSeed(
                  seedColor: seed,
                  brightness: Brightness.dark,
                ),
              );
        final cs = th.colorScheme;
        expect(
          ratio(cs.primary, cs.primaryContainer),
          greaterThanOrEqualTo(4.5),
          reason: 'seed=$seed ${b.name}：选中芯片文字仍不够',
        );
        expect(
          ratio(cs.primary, cs.surface),
          greaterThanOrEqualTo(4.5),
          reason: 'seed=$seed ${b.name}：主色当文字压在卡片上仍不够',
        );
      }
    }
  });
  _rowSelectedSubtitleAudit();
}

// ★ DA199（真机 2026-10-22，播放队列选中行）：`DesignRowTile(selected: true)` 的
// 副标题用的是**按白底挑的**灰（`dim`/`muted`），而选中底色换成 `primarySoft`。
// 静态令牌下 `dim on primarySoft` 恰好 4.51（勉强过），但设备开着**动态取色**
// （系统 accent `#007fac`），真机 `primarySoft` 被染成 `(203,230,252)` ⇒ 实测
// **4.24:1**（未达 AA）。这里按真机那种被染色后的底复现，判据是"用户读得到字"。
void _rowSelectedSubtitleAudit() {
  group('DA199 选中行（动态取色后的底）', () {
    for (final tinted in <Color>[
      const Color(0xFFCBE6FC), // 真机（系统 accent #007fac）
      const Color(0xFFDBEAFE), // 静态亮色令牌
      const Color(0xFFFDE2E4), // 极端：偏红的底（壁纸是暖色时可能出）
    ]) {
      testWidgets('底色被染成 ${tinted.toARGB32().toRadixString(16)} 时行内每种灰都 ≥4.5', (
        tester,
      ) async {
        late DesignPalette p;
        late Color fill;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light().copyWith(
              extensions: <ThemeExtension<dynamic>>[
                HudDynamicHue(primarySoft: tinted),
              ],
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  p = DesignPalette.of(context);
                  fill = DesignPalette.selectedRowFill(p);
                  return DesignRowTile(
                    selected: true,
                    title: const Text('Demo Song'),
                    // ★ 复现真机那一行：`audio_song_page` 把颜色写在 Text 上。
                    subtitle: Text(
                      '3:51 · 320 kbps',
                      style: TextStyle(fontSize: 12, color: p.dim),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        for (final fg in <Color>[p.text, p.muted, p.dim]) {
          final r = DesignPalette.contrastRatio(fg, fill);
          expect(
            r,
            greaterThanOrEqualTo(4.5),
            reason: '$fg on 选中底 $fill 只有 ${r.toStringAsFixed(2)}:1（DA199）',
          );
        }
        // 静态令牌那一档必须**原样**（设计稿的选中底不许被悄悄改）
        if (tinted == const Color(0xFFDBEAFE)) {
          expect(fill, const Color(0xFFDBEAFE));
        }
        // 真渲染的底色也必须是校正后的那个
        // 底色画在 `Material`（`DesignRowShell`）上，不是那个带边框的 Container。
        final rendered = tester
            .widget<Material>(
              find
                  .descendant(
                    of: find.byType(DesignRowTile),
                    matching: find.byType(Material),
                  )
                  .first,
            )
            .color;
        expect(rendered, fill, reason: '画出去的底色必须就是被校验过的那个（DA182 的老教训）');
      });
    }
  });
}
