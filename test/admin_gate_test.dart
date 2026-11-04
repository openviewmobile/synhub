// ★★★ **管理员门控的成对验证**（用户 2026-09-23 新规 · 第 73 轮）
//
// 新规 R2/R3 的本质是**两种状态都要对**：
// * 非管理员 ⇒ 管理入口**隐藏**（`findsNothing`）；
// * 管理员 ⇒ 管理入口**展示**（`findsOneWidget`）。
//
// ## 为什么本文件必须"成对"
// 只测"管理员能看到" ⇒ 门控根本没生效也会全绿（因为默认就是能看到）；
// 只测"非管理员看不到" ⇒ 把入口删掉也全绿。
// **两个方向同时测，才排除了这两类假绿。**
//
// ## fail-closed 的三个负向状态也要测
// 身份**还在查** / **查失败** / **未连接** ⇒ 都必须**藏**。
// 这三条是权限泄漏最可能发生的缝隙（"还没读到就先显示出来"）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/features/admin/admin_gate.dart';
import 'package:synhub/src/features/settings/settings_page.dart';
import 'package:synhub/src/features/files/file_tools_sheet.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

/// 用给定身份构建一个带门控入口的界面。
Widget _host(Widget child) => MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: child));

const _adminEntry = Text('套件中心', key: Key('admin-entry'));

void main() {
  /// 覆盖 `isAdminProvider`：这是**客户端 Mock**（新规 R4）。
  Future<void> pumpWith(WidgetTester tester, AsyncValue<bool> value) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isAdminProvider.overrideWith((ref) => Future.value(value.value)),
        ],
        child: _host(const AdminOnly(child: _adminEntry)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  group('AG1. ★★★ 成对：非管理员隐藏 / 管理员展示', () {
    testWidgets('★★★ 管理员 ⇒ 入口**展示**（R3）', (tester) async {
      await pumpWith(tester, const AsyncData(true));
      expect(
        find.byKey(const Key('admin-entry')),
        findsOneWidget,
        reason: '★ R3：管理员登录后管理功能必须正常展示',
      );
    });

    testWidgets('★★★ 非管理员 ⇒ 入口**隐藏**（R2）', (tester) async {
      await pumpWith(tester, const AsyncData(false));
      expect(
        find.byKey(const Key('admin-entry')),
        findsNothing,
        reason: '★ R2：非管理员必须**看不到**管理入口（不是禁用、不是报错）',
      );
      expect(
        find.text('套件中心'),
        findsNothing,
        reason: '★ 连文字都不该出现 —— 藏得不彻底等于没藏',
      );
    });
  });

  group('AG2. ★★★ fail-closed：身份未知时一律藏', () {
    testWidgets('★★★ 身份**还在查** ⇒ 藏（不能"先显示再说"）', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAdminProvider.overrideWith(
              (ref) => Completer<bool>().future, // 永不完成
            ),
          ],
          child: _host(const AdminOnly(child: _adminEntry)),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('admin-entry')),
        findsNothing,
        reason:
            '★★★ 这是权限泄漏最典型的缝隙：'
            '"还没读到身份就先渲染出来"——非管理员会看到一闪而过的管理入口。'
            '必须先藏，读到 true 再显示',
      );
    });

    testWidgets('★★★ 身份查询**失败** ⇒ 藏', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAdminProvider.overrideWith((ref) => Future<bool>.error('boom')),
          ],
          child: _host(const AdminOnly(child: _adminEntry)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(
        find.byKey(const Key('admin-entry')),
        findsNothing,
        reason: '★ 弱网/超时下宁可不显示（刷新即恢复），也不猜成管理员',
      );
    });

    testWidgets('★★ 提供了 fallback 时，非管理员看到的是 fallback 而不是入口', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAdminProvider.overrideWith((ref) => Future.value(false)),
          ],
          child: _host(
            const AdminOnly(
              fallback: Text('占位', key: Key('admin-fallback')),
              child: _adminEntry,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.byKey(const Key('admin-fallback')), findsOneWidget);
      expect(find.byKey(const Key('admin-entry')), findsNothing);
    });
  });

  group('AG3. 非 widget 场合（菜单列表）与整页门控', () {
    // ⚠️ 刻意**不写成循环**：同一 `tester` 上反复 `pumpWidget` 会把
    // 上一次的 `ProviderScope`/状态一起复用，导致第二次断言看到旧树
    //（本项目此前踩过这个坑）。两个方向各写一条，互相独立。
    testWidgets('★★ `adminOnlyVisible()`：管理员 ⇒ true', (tester) async {
      late bool got;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAdminProvider.overrideWith((ref) => Future.value(true)),
          ],
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Consumer(
              builder: (context, ref, _) {
                got = adminOnlyVisible(ref);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(got, isTrue);
    });

    testWidgets('★★ `adminOnlyVisible()`：非管理员 ⇒ false', (tester) async {
      late bool got;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAdminProvider.overrideWith((ref) => Future.value(false)),
          ],
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Consumer(
              builder: (context, ref, _) {
                got = adminOnlyVisible(ref);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(got, isFalse);
    });

    testWidgets('★★★ 深链进入管理页：管理员见内容', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAdminProvider.overrideWith((ref) => Future.value(true)),
          ],
          child: MaterialApp(theme: AppTheme.dark(), 
            home: AdminPageGate(
              title: '套件中心',
              child: Text('管理内容', key: Key('admin-page-body')),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.byKey(const Key('admin-page-body')), findsOneWidget);
      expect(find.byKey(const Key('admin-page-gate')), findsNothing);
    });

    testWidgets('★★★ 深链进入管理页：非管理员见说明（不是白屏、更不是内容）', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAdminProvider.overrideWith((ref) => Future.value(false)),
          ],
          child: MaterialApp(theme: AppTheme.dark(), 
            home: AdminPageGate(
              title: '套件中心',
              child: Text('管理内容', key: Key('admin-page-body')),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(
        find.byKey(const Key('admin-page-body')),
        findsNothing,
        reason: '★ 非管理员**不能**看到管理内容',
      );
      expect(
        find.byKey(const Key('admin-page-gate')),
        findsOneWidget,
        reason: '★ 深链/竞态下给一句说明，比白屏好',
      );
      expect(find.textContaining('需要管理员权限'), findsOneWidget);
    });
  });

  group('AG4. ★★★ 端到端：设置页的「管理工具」入口真的被门控住', () {
    // 第 73 轮门控就位但**没有页面消费** ⇒ 等于没验证过端到端。
    // 这里渲染**真实的设置页**（用 `bootChat()` 拿到有会话的容器 ——
    // 没有会话时设置页**整页不渲染**，直接 pump 会得到假绿）。
    Future<void> pumpSettings(WidgetTester tester, bool admin) async {
      // ★ 必须把 override 交给 `bootChat` 的**同一个**容器。
      // 第一版写成 `UncontrolledProviderScope(container: h.container,
      // child: ProviderScope(overrides: [...]))` —— 内层 `ProviderScope`
      // 会**新建一个容器**，把带会话的外层整个绕过去，
      // 于是设置页整页不渲染，两条断言全错（一条假绿、一条假红）。
      final h = await bootChat(
        moreOverrides: [
          isAdminProvider.overrideWith((ref) => Future.value(admin)),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: const _SettingsHost(),
        ),
      );
      await tester.pumpAndSettle();
      // ★ 必须滚到列表底部：设置页是多行的 `ListView`，
      // **屏外的条目根本没被构建**，直接 `find.byKey` 会找不到
      //（本用例第二版就栽在这里 —— 那不是"入口被藏了"，是"还没滚到"）。
      // 所以先滚动，再做可见性断言。
      for (var i = 0; i < 8; i++) {
        await tester.drag(find.byType(ListView).first, const Offset(0, -400));
        await tester.pumpAndSettle();
      }
    }

    testWidgets('★★★ 非管理员 ⇒ 设置页**没有**「管理工具」条目（R2）', (tester) async {
      await pumpSettings(tester, false);
      // ⚠️ **对照断言**：先证明"设置页确实渲染出来了"。
      // 否则"看不到管理工具"可能只是因为整页都没渲染 —— 那是假绿。
      // （本用例第一版就踩了这个坑，是对照断言把它抓出来的。）
      expect(find.text('设置'), findsWidgets, reason: '对照：设置页确实渲染出来了，本用例才有意义');
      expect(
        find.byKey(const Key('set-personal-profile')),
        findsOneWidget,
        reason: '对照：已经滚到底部，底部其它条目可见 ⇒ 可见性断言有效',
      );
      expect(
        find.byKey(const Key('set-admin-tools')),
        findsNothing,
        reason: '★★★ 新规 R2 的**真实落点**：非管理员在设置页里看不到任何管理入口',
      );
      expect(find.text('管理工具'), findsNothing, reason: '★ 连文字都不该出现');
    });

    testWidgets('★★★ 管理员 ⇒ 设置页**有**「管理工具」条目（R3）', (tester) async {
      await pumpSettings(tester, true);
      expect(
        find.byKey(const Key('set-personal-profile')),
        findsOneWidget,
        reason: '对照：已经滚到底部，底部其它条目可见',
      );
      expect(
        find.byKey(const Key('set-admin-tools')),
        findsOneWidget,
        reason: '★★★ 新规 R3：管理员必须能正常看到并使用管理功能',
      );
    });
  });
  group('AG7. ★★ 文件工具面板：外接设备（USB）是管理员专属', () {
    testWidgets('非管理员 ⇒ USB 入口隐藏，但其它三个工具都在', (tester) async {
      await _pumpToolsSheet(tester, const AsyncData(false));
      expect(
        find.byKey(const Key('file-tools-usb')),
        findsNothing,
        reason: '★★ R2：非管理员不许看到外接设备入口',
      );
      expect(find.text('外接设备'), findsNothing, reason: '★ 连文字都不该出现');
      // 反向断言：同面板的其它工具必须**照常可见**（排除"整块没渲染"的假绿）
      expect(find.byKey(const Key('file-tools-offline')), findsOneWidget);
      expect(find.byKey(const Key('file-tools-saf-on-demand')), findsOneWidget);
      expect(find.byKey(const Key('file-tools-webdav')), findsOneWidget);
    });

    testWidgets('管理员 ⇒ USB 入口展示（R3）', (tester) async {
      await _pumpToolsSheet(tester, const AsyncData(true));
      expect(find.byKey(const Key('file-tools-usb')), findsOneWidget);
      expect(find.text('外接设备'), findsOneWidget);
    });

    testWidgets('身份未定（fail-closed）⇒ 也不显示 USB 入口', (tester) async {
      await _pumpToolsSheet(tester, const AsyncLoading<bool>());
      expect(find.byKey(const Key('file-tools-usb')), findsNothing);
      // 同一个面板里其它工具正常 —— 证明"藏"的确是门控
      expect(find.byKey(const Key('file-tools-offline')), findsOneWidget);
    });
  });

}

/// ★★ r371（用户新规 R2 的**真实落点之二**）：文件模块「文件工具」面板里的
/// **外接设备（USB）入口**是管理员专属，非管理员**看不见**。
///
/// 判据（两层，见 `file_tools_sheet.dart` 的注释）：
///   * 服务端：普通账号调 `Core.ExternalDevice.Storage.USB/list` 拿到 DSM 404
///     （r370 真机：U 盘在插、`Files` 能进那个盘，本页仍回 404）；
///   * 官方前端：DSM 自带 FileStation 的 `initExtDeviceInfo` / eject 都在
///     `_S("is_admin") && …` 之下 ⇒ DSM 侧这条列表只给管理员。
///
/// 三道判据缺一不可：
///   ① 非管理员 ⇒ USB 行**没有**，但同面板其它三个工具**都在**
///      （证明是"门控生效"，不是"整块没渲染"）；
///   ② 管理员 ⇒ USB 行**在**（证明不是"把入口删了"）；
///   ③ fail-closed（还没查完）⇒ 也**没有**（R2 的缝隙）。
Widget _toolsHost() => MaterialApp(
  theme: AppTheme.dark(),
  home: Scaffold(
    body: Builder(
      builder: (ctx) => ElevatedButton(
        onPressed: () => showFileToolsSheet(ctx),
        child: const Text('open-tools'),
      ),
    ),
  ),
);

Future<void> _pumpToolsSheet(
  WidgetTester tester,
  AsyncValue<bool> identity,
) async {
  final completer = Completer<bool>();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        isAdminProvider.overrideWith((ref) {
          if (identity is AsyncData<bool>) {
            return Future.value(identity.value);
          }
          // 还在查：永远不完成 —— 模拟"身份未知"这一帧
          return completer.future;
        }),
      ],
      child: _toolsHost(),
    ),
  );
  await tester.tap(find.text('open-tools'));
  await tester.pumpAndSettle();
}

/// 与仓库其它设置页测试一致的宿主：带 `AppText.delegate` 与中文 locale。
class _SettingsHost extends ConsumerWidget {
  const _SettingsHost();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(theme: AppTheme.dark(), 
      locale: const Locale('zh'),
      localizationsDelegates: const [
        AppText.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      supportedLocales: AppText.supportedLocales,
      home: const SettingsPage(),
    );
  }
}
