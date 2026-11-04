// 真机缺陷回归（r320）：`AppEmptyState` 的主行动图标**写死刷新圈**。
//
// ## 缺陷原文（像素：`docs/evidence-r320/img/06_download_before.png`）
// 下载页空队列时的「New task」按钮左侧是**刷新箭头**（`Icons.refresh`）——
// 它来自 `AppEmptyState` 里 `FilledButton.tonalIcon(icon: const Icon(Icons.refresh))`
// 这一行**写死**的图标。同一个组件被全仓 **35 个站点**当作"空态主行动"用，
// 于是凡"行动 ≠ 重试"的地方都顶着刷新圈（"新建频道"/"清除筛选"等）。
//
// ## 本用例锁住的不变量
// ① `AppEmptyState(actionIcon: …)` 传什么就画什么（新参数真的接上了）；
// ② **不传时仍是 `Icons.refresh`** —— 35 个站点里 34 个是重试语义，
//    默认值不许顺手改（改默认值 = 同时动 34 个站点，属"顺手改一片"）；
// ③ 三个**非重试**站点必须显式传图标（谁把参数删了就红）：
//    下载页「New task」、文件页「清除筛选」、频道列表「新建频道/加入」；
// ④ 反向验证：`asOpenFailed`（"打开失败"）**不许**出现在 `actionLabel:` 右侧
//    —— 那是报错文案，不是按钮标签（§2.0.47 ④ 诊断串不许当用户文案）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/core/ui/app_states.dart';

Future<void> _pumpEmptyState(
  WidgetTester tester, {
  IconData? actionIcon,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppText.localizationsDelegates,
      supportedLocales: AppText.supportedLocales,
      home: Scaffold(
        // ★ 两个分支**必须分开写**：`actionIcon` 默认值就是被锁定的不变量之一，
        //   用 `?? Icons.refresh` 兜一下会把"默认值"这条用例变成同义反复。
        body: actionIcon == null
            ? AppEmptyState(
                icon: Icons.download_outlined,
                title: 'No download tasks yet',
                actionLabel: 'New task',
                onAction: () {},
              )
            : AppEmptyState(
                icon: Icons.download_outlined,
                title: 'No download tasks yet',
                actionLabel: 'New task',
                onAction: () {},
                actionIcon: actionIcon,
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 空态按钮**子树里**的图标集合（判据只看那个按钮，不看标题旁的大图标）。
Set<IconData> _buttonIcons(WidgetTester tester) {
  final btn = find.widgetWithText(FilledButton, 'New task');
  expect(btn, findsOneWidget, reason: '空态主行动按钮必须在（§2.0.29：不许删到 0 个入口）');
  return {
    for (final e in find.descendant(of: btn, matching: find.byType(Icon)).evaluate())
      (e.widget as Icon).icon!,
  };
}

String _read(String rel) => File(rel).readAsStringSync();

void main() {
  group('AppEmptyState 主行动图标（r320）', () {
    testWidgets('① 传了 actionIcon 就画它（不是刷新圈）', (tester) async {
      await _pumpEmptyState(tester, actionIcon: Icons.add);
      final icons = _buttonIcons(tester);
      expect(icons, contains(Icons.add));
      expect(
        icons,
        isNot(contains(Icons.refresh)),
        reason: '★ 传了 add 还画刷新圈 ⇒ 参数没接上（就是本缺陷的原文）',
      );
    });

    testWidgets('② 不传时仍是 refresh（34 个重试站点不受影响）', (tester) async {
      await _pumpEmptyState(tester);
      expect(_buttonIcons(tester), contains(Icons.refresh));
    });

    test('③ 三个非重试站点必须显式传 actionIcon', () {
      final sites = <String, String>{
        'lib/src/features/downloads/download_page.dart': 'download 空态「New task」',
        'lib/src/features/files/file_browse_page.dart': '文件页「清除筛选」',
        'lib/src/features/chat/channel_list_page.dart': '频道列表「新建频道/加入」',
      };
      for (final e in sites.entries) {
        final src = _read(e.key);
        expect(
          src.contains('actionIcon:'),
          isTrue,
          reason: '${e.value} 是非重试行动 ⇒ 必须显式给图标（${e.key}）',
        );
      }
      // 下载页的具体值：`Icons.add`（"新建任务"）
      final dl = _read('lib/src/features/downloads/download_page.dart');
      expect(dl.contains('actionIcon: Icons.add'), isTrue);
    });

    test('④ 反向验证：报错文案不许挂到 actionLabel 上', () {
      // 先自证扫描器能命中已知样本（§2.0.35：扫不到先怀疑模式）
      const sample = "actionLabel: t.asOpenFailed,";
      expect(
        RegExp(r'actionLabel:\s*t\.asOpenFailed').hasMatch(sample),
        isTrue,
        reason: '扫描模式必须能命中"曾经真的存在过"的那一行',
      );
      final bad = <String>[];
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final src = f.readAsStringSync();
        if (RegExp(r'actionLabel:\s*t\.asOpenFailed').hasMatch(src)) {
          bad.add(f.path);
        }
      }
      expect(
        bad,
        isEmpty,
        reason: '★ `asOpenFailed` 是诊断串（"Failed to open"），不许当按钮标签：$bad',
      );
    });
  });
}
