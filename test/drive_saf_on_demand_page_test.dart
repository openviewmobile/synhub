// ★★ ③Drive 第 246 轮 **D66**：SAF「按需下载」设置页的组件契约。
//
// 这页把凭据交给原生侧（provider 冷启动自登录用）。要点：
//   * 没保存密码 ⇒ **如实提示**，不静默失败；
//   * 原生侧报告已配置 ⇒ 显示"关闭"入口；
//   * 清缓存入口在；
//   * 必须写明"Kotlin 真机未验"（不许假装验证过）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/features/files/drive_saf_on_demand_page.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/files/drive_saf_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 第 55 轮：`synhub/drive_saf` 只有 Android 侧实现 ⇒ 调用点先问能力层。
  // 本文件用**假通道**模拟"原生侧已配置"，属"原生桥可用"前提 ⇒ 显式把门控
  // 强制打开（断言一条没改；真机 Android 上能力层本来就放行）。
  setUp(() => debugForceCapabilityGate = true);
  tearDown(() => debugForceCapabilityGate = false);

  testWidgets('★ 没配置凭据时显示"启用"，点它给出如实提示', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          driveSafSessionProvider.overrideWithValue(DriveSafSession()),
        ],
        child: MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: SingleChildScrollView(child: DriveSafOnDemandBody()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('启用按需下载'), findsOneWidget);
    expect(find.byKey(const Key('saf-on-demand-clear-cache')), findsOneWidget);
    // 未登录 ⇒ 点"启用"应当给提示而不是崩
    await tester.tap(find.text('启用按需下载'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('★ 原生侧已配置（假通道）⇒ 显示"关闭"与缓存大小', (tester) async {
    final channel = const MethodChannel(kDriveSafChannel);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == kDriveSafStatus) {
        return <Object?, Object?>{
          'configured': true,
          'onDemand': true,
          'baseUrl': 'https://nas.local/',
          'username': 'demo_user',
          'hasSid': true,
          'cachedBytes': 12345,
        };
      }
      if (call.method == kDriveSafClearCache) return 12345;
      if (call.method == kDriveSafClearCredentials) return true;
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          driveSafSessionProvider.overrideWithValue(DriveSafSession()),
        ],
        child: MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: SingleChildScrollView(child: DriveSafOnDemandBody()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('关闭按需下载'), findsOneWidget);
    expect(find.textContaining('12345'), findsOneWidget);

    // 清缓存：调用真到了通道上（返回值 12345 会出现在提示里）
    await tester.tap(find.byKey(const Key('saf-on-demand-clear-cache')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已释放缓存'), findsOneWidget);
  });

  testWidgets('★ 页面写明"真机未验"（不许假装验证过）', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: SingleChildScrollView(child: DriveSafOnDemandBody()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // ★ r378 订正（用户上线要求）：这条用例原先要求页面**必须**写「真机未验」——
    //   那是把**开发口吻**焊死在用户文案里（同族：R8 开发侧用语）。
    //   诚实意图保留、位置换掉：**用户**看到的是"按需下载是什么"，
    //   而"原生 Kotlin 路径本仓未真机验证"这件事属于**文档**（launch-readiness / AGENTS），
    //   不该印给用户看。判据 = ①说明句在 ②开发用语一个都不许在。
    expect(find.textContaining('按需下载'), findsWidgets);
    for (final devPhrase in <String>[
      '真机',
      '本仓库',
      '未验证',
      'Kotlin',
      'DocumentsProvider',
    ]) {
      expect(
        find.textContaining(devPhrase),
        findsNothing,
        reason: '用户文案里不许出现开发用语「$devPhrase」',
      );
    }
  });
}
