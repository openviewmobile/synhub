// 对应缺陷 **DA214**（设计壳把"色相层"丢了 ⇒ 同一页里两把尺子给出两个主色）。
//
// 现场（r631 真机，同一个 App、同一次安装）：
//   * 音乐单曲页的主播放键 = **深青 `(51,99,131)`**（它读 `Theme.colorScheme.primary`）；
//   * 网络电台页/弹层的主色 = **蓝 `(42,77,208)`**（它读 `DesignPalette.of(context).primary`）。
// 真因：`DesignScaffold` 用 `DesignTheme.of(p, …)` 造内层主题时**没有把
// `HudDynamicHue` 带下去**（`ThemeData.copyWith` 不传 `extensions`）⇒
//   * 内层的 `colorScheme.primary` 是外面算好的 `p.primary`（带壁纸色相）；
//   * 内层的 `DesignPalette.of(context)` 读不到色相层 ⇒ 退回**常量令牌蓝**。
// 于是"同一页里换个 API 取主色就换个颜色"，模块之间看着像两套主题。
//
// 判据（本用例）：壳**里面**的 `DesignPalette.of` 必须与壳**外面**算出的一致；
// 且两条取色路径（`colorScheme.primary` 与令牌 `primary`）必须同色 ——
// 这条就是"两把尺子"的机器判据，改了任何一边都会红。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/design/design_palette.dart';
import 'package:synhub/src/design/kit/design_kit.dart';

void main() {
  final wallpaperSeed = const Color(0xFF007FAC); // 真机读到的系统主题色（青）

  testWidgets('DA214：设计壳里外的主色必须同一个（动态色相不许在壳里丢掉）', (tester) async {
    final scheme = ColorScheme.fromSeed(seedColor: wallpaperSeed);
    late DesignPalette outside;
    late DesignPalette inside;
    late Color schemePrimaryInside;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(dynamic: scheme),
        home: Builder(
          builder: (context) {
            outside = DesignPalette.of(context);
            return DesignScaffold(
              body: Builder(
                builder: (inner) {
                  inside = DesignPalette.of(inner);
                  schemePrimaryInside =
                      Theme.of(inner).colorScheme.primary;
                  return const SizedBox(key: Key('probe'));
                },
              ),
            );
          },
        ),
      ),
    );

    // ① 壳外的色相层生效了（壁纸青不是常量蓝）—— 前提自证，否则本用例没意义
    expect(outside.primary, scheme.primary);
    expect(outside.primary, isNot(DesignPalette.light.primary));

    // ② 壳里读到的令牌必须**同一个**
    expect(
      inside.primary,
      outside.primary,
      reason: 'DA214：设计壳把 HudDynamicHue 丢了 ⇒ 壳里退回常量蓝',
    );
    // ③ 两条取色路径必须同色（"两把尺子"判据）
    expect(
      schemePrimaryInside,
      inside.primary,
      reason: 'DA214：colorScheme.primary 与令牌 primary 必须是同一个色',
    );
  });

  testWidgets('DA214 反向：没开动态取色时不许凭空造色相层', (tester) async {
    late DesignPalette inside;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: DesignScaffold(
          body: Builder(
            builder: (inner) {
              inside = DesignPalette.of(inner);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    expect(inside.primary, DesignPalette.light.primary);
    expect(inside.surface, DesignPalette.light.surface);
  });
}
