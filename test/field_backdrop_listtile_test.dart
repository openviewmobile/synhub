// ★★ r132（iOS 逐屏截图审计）：**`FieldBackdrop` 的底色 `ColoredBox` 必须
// 在"里侧"补一层透明 `Material`** —— 这是上一轮（r131）"逐页补 Material"的
// 根因收口修法。
//
// ## 事实（真模拟器像素 + 框架日志，不是推断）
// iPhone 16 / iOS 18.6 / `xcrun simctl io booted screenshot` 的逐屏走查里，
// 几乎**每个含 `ListTile` 的页面**都在刷同一句断言：
//
// ```
// ListTile background color or ink splashes may be invisible.
// The ListTile is wrapped in a ColoredBox that has a background color. …
// ListTile: ListTile(onTap: Closure: () => void, onLongPress: Closure: () => void)
// ColoredBox: ColoredBox(color: Color(alpha: 1.0000, red: 0.9451, green: 0.9608, blue: 0.9843))
// ```
//
// 实测计数：`s053`（Drive 源）12 次、`s102`（Audio Station 歌曲页）200 次、
// `s104`（下载"新建任务"）230 次、`s110`（"我的"页）237 次 —— 累积量词，
// 但分布跨了 8 个互不相关的模块 ⇒ **不是某一页的缺陷，而是外壳的**。
// r131 已经在 `drive_tasks_page` / `file_mount_page` / `file_offline_page` /
// `file_pages` / `webdav_page` / `drive_browse_view` **逐页**补过一次透明
// `Material`，iOS 走查证明那样永远补不完：只要新写一页 `ListTile` 就会复发。
//
// 根因：`FieldBackdrop` 的 `ColoredBox(color: hud.deep, …)` 是**带底色的
// 中间层**；`ListTile` 把底色/水波纹画在**最近的 `Material`** 上。
// 修法：在 `ColoredBox` 的**子节点那侧**加 `Material(type: transparency)`
// （`ListTile._findIntermediateWidget` 是**自下而上**找，先遇到 `Material`
// 就停 ⇒ 透明的这层正好挡住再往上的带色 `ColoredBox`）。
//
// ## 反向验证（本仓规矩：用例必须真抓得住缺陷）
// 第 ① 条**刻意用修复前的形态**（`ColoredBox` 直接包 `ListTile`）⇒
// 必须当场抛那条断言；第 ② / ③ 条用 `FieldBackdrop` 包同一个 `ListTile`
// ⇒ 必须零异常。把 `field_backdrop.dart` 里那层 `Material` 删掉，②③ 立刻红。
//
// 另外两条"不是恒过"的守卫：④ 插入 `Material` **不许改变继承的文字样式**
// （`Material` 默认会塞 `textTheme.bodyMedium`，我们显式回填
// `DefaultTextStyle.of(context).style`）；⑤ `enabled: false` 分支同样不许抛。
//
// 全程假数据、纯 `flutter test`（规程 §5.1：不碰真机/真 NAS）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/ui/field_backdrop.dart';

/// 与断言里那行 `ColoredBox` 同色（浅色主题的 `hud.deep`）。
const Color _deep = Color(0xFFF1F5FB);

final Key _tileKey = const Key('t-list-tile');

/// 走查里真实出现的形态：`onTap` + `onLongPress` 都有的行（Files/Drive/我的页）。
Widget _tile() => ListTile(
      key: _tileKey,
      leading: const Icon(Icons.folder_outlined),
      title: const Text('row title'),
      subtitle: const Text('row subtitle'),
      onTap: () {},
      onLongPress: () {},
    );

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(393 * 3, 852 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.light(),
      home: Scaffold(body: SizedBox.expand(child: child)),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('① 反向验证：修复前的形态（带色 ColoredBox 直接包 ListTile）必须抛断言',
      (tester) async {
    await _pump(tester, ColoredBox(color: _deep, child: _tile()));
    final ex = tester.takeException();
    expect(ex, isNotNull,
        reason: '带底色的 ColoredBox 直接包 ListTile 应触发 Flutter 的隐藏断言；'
            '若这里为空，说明本用例已经量不到缺陷了（判据失效）');
    expect('$ex', contains('ink splashes may be invisible'));
  });

  testWidgets('② FieldBackdrop(enabled) 里的 ListTile 不许抛断言，且中间有透明 Material',
      (tester) async {
    await _pump(tester, const FieldBackdrop(child: SizedBox.expand()));
    // 换成一个真的带 ListTile 的子树（FieldBackdrop 需要 child）。
    await _pump(tester, FieldBackdrop(child: ListView(children: [_tile()])));
    expect(tester.takeException(), isNull,
        reason: 'r132 修复后，FieldBackdrop 里的 ListTile 不应再抛断言');
    expect(find.byKey(_tileKey), findsOneWidget);

    // 结构守卫：从 ListTile 往上，先遇到 Material（透明），再遇到带色 ColoredBox。
    final ancestors = <String>[];
    final el = tester.element(find.byKey(_tileKey));
    el.visitAncestorElements((a) {
      final w = a.widget;
      if (w is Material) {
        ancestors.add('material:${w.type}');
        return false;
      }
      if (w is ColoredBox) ancestors.add('colored:${w.color}');
      return true;
    });
    expect(ancestors, isNotEmpty);
    expect(ancestors.first, 'material:MaterialType.transparency',
        reason: 'ListTile 之上**最近**的必须是透明 Material（否则水波纹/底色被盖住）');
  });

  testWidgets('③ enabled: false 分支（纯色兜底）同样不许抛断言', (tester) async {
    await _pump(
      tester,
      FieldBackdrop(enabled: false, child: ListView(children: [_tile()])),
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(_tileKey), findsOneWidget);
  });

  testWidgets('④ 插入的 Material 不许改变继承的文字样式（不是恒过的守卫）',
      (tester) async {
    const probe = Key('t-style-probe');
    // 外层刻意给一个"非 bodyMedium"的显式样式。
    const outer = TextStyle(fontSize: 21, fontWeight: FontWeight.w300);
    await _pump(
      tester,
      DefaultTextStyle(
        style: outer,
        child: FieldBackdrop(
          child: ListView(
            children: [Text('style probe', key: probe)],
          ),
        ),
      ),
    );
    final style = DefaultTextStyle.of(tester.element(find.byKey(probe))).style;
    expect(style.fontSize, outer.fontSize,
        reason: 'FieldBackdrop 里那层 Material 必须回填当前 DefaultTextStyle，'
            '不能把文字悄悄换成 textTheme.bodyMedium');
    expect(style.fontWeight, outer.fontWeight);
  });
}
