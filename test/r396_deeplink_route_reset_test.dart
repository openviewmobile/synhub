// r396 · **DA40 守卫**：掐掉「外部 `ACTION_VIEW` 把子页弹回外壳」。
//
// ## 真机现象（r389 登记为候选 DA40，r396 定性）
//
// 在 **Me → Settings**（一个 push 出来的子页）上投递 `ACTION_VIEW`：
//
// | 投递 | 结果 | 读数 |
// |---|---|---|
// | `-a VIEW -d synochat://design-preview` | **子页被弹掉** → Me 根 | `6adfb54a… → 660eb348…` |
// | `-a VIEW -d synochatzz://x`（**未注册** scheme） | **同样弹掉**，且**同一屏** | `→ 660eb348…` |
// | `-a VIEW`（**不带 data**） | 不动 | `→ 6adfb54a…`（同 sha） |
// | `am start -n …/.MainActivity`（无 action/data） | 不动 | `→ 6adfb54a…` |
// | `-a VIEW -d https://example.com/x` | 整屏 **Page not found** | `→ 12e19692…` |
// | `-a VIEW -d http://example.com/y` | 整屏 **Page not found** | `→ bf1fd64b…` |
//
// 关键否定证据：**未注册的 scheme 也一样弹** ⇒ 不是我方 `DeepLinkBridge`；
// 不带 data **完全不弹** ⇒ 触发条件是 `intent.getData() != null`。
//
// ## 根因（tier-1：release embedding jar 的字节码，`javap -c -p` 逐条读）
//
// * `FlutterActivityLaunchConfigs.deepLinkEnabled(Bundle)`：
//   `bundle.containsKey("flutter_deeplinking_enabled") ? bundle.getBoolean(…) : **true**`
//   ⇒ **没声明 = 打开**（这就是为什么"我没配过"不等于"没开"）。
// * `FlutterActivityAndFragmentDelegate.onNewIntent(Intent)`：
//   `maybeGetInitialRouteFromIntent(intent)` → 非空则
//   `flutterEngine.getNavigationChannel().pushRouteInformation(route)`。
// * `maybeGetInitialRouteFromIntent`：`shouldHandleDeeplinking() && intent.getData() != null`
//   ⇒ 返回 `uri.toString()`。
//
// Dart 侧 Router（GoRouter）收到这条 route information 就会导航：
// 自定义 scheme（host 有值、path 空）被规整成根 ⇒ 弹回当前 tab 根；
// http(s) 的 path 没有对应路由 ⇒ `errorBuilder`（真机那两屏「Page not found」）。
//
// ## 修法
//
// 在 `MainActivity` 上显式声明 `flutter_deeplinking_enabled = false`。
// 我们的深链**不依赖**它：`DeepLinkBridge` 在 `onCreate`/`onNewIntent` 里自己读
// `address`/`account` extras；`GoRouter` 也显式给了 `initialLocation`，不读
// `defaultRouteName`。下面每条断言都配了**反向验证**（改坏必须变红）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String kManifestPath = 'android/app/src/main/AndroidManifest.xml';
const String kMainActivityPath =
    'android/app/src/main/kotlin/com/openviewai/synhub/MainActivity.kt';
const String kRouterPath = 'lib/src/core/router/app_router.dart';

/// 剥 XML 注释：上面 r396 的注释里**逐字**写了 `flutter_deeplinking_enabled`，
/// 不剥就会把注释当成真声明（假绿）。
String stripXmlComments(String xml) =>
    xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

/// `MainActivity` 那个 `<activity …>…</activity>` 块（剥注释后）。
String? mainActivityBlock(String xml) {
  final stripped = stripXmlComments(xml);
  final m = RegExp(
    r'<activity[^>]*android:name="\.MainActivity".*?</activity>',
    dotAll: true,
  ).firstMatch(stripped);
  return m?.group(0);
}

/// 判据：**在 MainActivity 块内**声明了 `flutter_deeplinking_enabled="false"`。
bool manifestDisablesFlutterDeepLinking(String xml) {
  final blk = mainActivityBlock(xml);
  if (blk == null) return false;
  return RegExp(
    r'<meta-data\s+android:name="flutter_deeplinking_enabled"\s+android:value="false"\s*/>',
  ).hasMatch(blk);
}

/// 判据：源码里不读 `PlatformDispatcher.defaultRouteName`（读它才会受引擎
/// `initialRoute` 影响；不读 ⇒ 关掉引擎深链不会改变启动落点）。
bool sourceIgnoresDefaultRouteName(String source) =>
    !source.contains('defaultRouteName');

/// 判据：GoRouter 显式给了 `initialLocation`。
bool routerHasExplicitInitialLocation(String source) =>
    source.contains('initialLocation:');

/// 取 `MainActivity.kt` 里 `onNewIntent` 的函数体。
String? onNewIntentBody(String kotlin) {
  final m = RegExp(
    r'override fun onNewIntent\(intent: Intent\)\s*\{(.*?)\n    \}',
    dotAll: true,
  ).firstMatch(kotlin);
  return m?.group(1);
}

void main() {
  group('r396 · DA40：MainActivity 必须显式关掉引擎 deep-linking 路由推送', () {
    final manifest = File(kManifestPath).readAsStringSync();

    test('真实 AndroidManifest.xml：MainActivity 块里 false（且只有一条）', () {
      expect(mainActivityBlock(manifest), isNotNull,
          reason: '找不到 .MainActivity 的 <activity> 块 —— 用例本身要复核');
      expect(manifestDisablesFlutterDeepLinking(manifest), isTrue,
          reason: '未声明时框架缺省 = true ⇒ 任何带 data 的 VIEW intent 都会推路由');

      final stripped = stripXmlComments(manifest);
      expect(
        RegExp('flutter_deeplinking_enabled').allMatches(stripped).length,
        1,
        reason: '只许有一条声明，多了会互相遮蔽（谁生效说不清）',
      );
      // 反例守卫：不许出现 true
      expect(
        RegExp(r'flutter_deeplinking_enabled"\s+android:value="true"')
            .hasMatch(stripped),
        isFalse,
      );
    });

    test('反向验证①：把 false 改成 true ⇒ 判据必须为假', () {
      final mutated = manifest.replaceFirst(
        'android:name="flutter_deeplinking_enabled"\n              android:value="false"',
        'android:name="flutter_deeplinking_enabled"\n              android:value="true"',
      );
      expect(mutated, isNot(manifest), reason: '替换没生效 ⇒ 反证无效');
      expect(manifestDisablesFlutterDeepLinking(mutated), isFalse);
    });

    test('反向验证②：删掉这条 meta-data ⇒ 判据必须为假', () {
      final mutated = manifest.replaceFirst(
        RegExp(
          r'\s*<meta-data\s+android:name="flutter_deeplinking_enabled"\s+android:value="false"\s*/>',
        ),
        '',
      );
      expect(mutated, isNot(manifest));
      expect(manifestDisablesFlutterDeepLinking(mutated), isFalse);
    });

    test('反向验证③：声明挪到别的 activity ⇒ 判据必须为假（不许"文件里有就算"）', () {
      final stripped = stripXmlComments(manifest);
      final blk = mainActivityBlock(manifest)!;
      final withoutIt = stripped.replaceFirst(
        RegExp(
          r'<meta-data\s+android:name="flutter_deeplinking_enabled"\s+android:value="false"\s*/>',
        ),
        '',
      );
      expect(withoutIt, isNot(stripped));
      final planted = withoutIt.replaceFirst(
        '<activity',
        '<activity android:name=".SomeOtherActivity">'
            '<meta-data android:name="flutter_deeplinking_enabled" android:value="false"/></activity><activity',
      );
      expect(planted, contains('SomeOtherActivity'));
      expect(manifestDisablesFlutterDeepLinking(planted), isFalse);
      // 顺带确认原本那块仍被判为真（说明判据确实钉在 MainActivity 上）
      expect(blk, contains('flutter_deeplinking_enabled'));
    });
  });

  group('r396 · DA40：关掉引擎深链不许有副作用（启动落点 + 我方深链入口）', () {
    test('lib/ 全量：没有任何源码读 PlatformDispatcher.defaultRouteName', () {
      final offenders = <String>[];
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final src = e.readAsStringSync();
        if (!sourceIgnoresDefaultRouteName(src)) offenders.add(e.path);
      }
      expect(offenders, isEmpty,
          reason: '有源码读 defaultRouteName ⇒ 关掉引擎深链会改变它的启动落点');

      // 反向验证：把关键字塞进去，判据必须变假
      expect(sourceIgnoresDefaultRouteName('final x = defaultRouteName;'), isFalse);
    });

    test('GoRouter 显式给了 initialLocation（不依赖引擎传来的 initial route）', () {
      final src = File(kRouterPath).readAsStringSync();
      expect(routerHasExplicitInitialLocation(src), isTrue);
      expect(
        routerHasExplicitInitialLocation(
          src.replaceFirst('initialLocation:', 'initialLocations:'),
        ),
        isFalse,
        reason: '反向验证：判据必须真的盯着 initialLocation',
      );
    });

    test('MainActivity.onNewIntent 仍转发四条自研桥（深链不靠引擎）', () {
      final kotlin = File(kMainActivityPath).readAsStringSync();
      final body = onNewIntentBody(kotlin);
      expect(body, isNotNull, reason: '取不到 onNewIntent 函数体 —— 用例要复核');
      for (final bridge in const [
        'ShareIntentBridge.handleIntent(intent)',
        'ShortcutBridge.handleIntent(intent)',
        'DeepLinkBridge.handleIntent(intent)',
        'SynologyWidgetBridge.handleIntent(intent)',
      ]) {
        expect(body, contains(bridge),
            reason: 'onNewIntent 少了 $bridge ⇒ 前台深链/分享/快捷方式会失效');
      }
      // 反向验证：拿掉一行，判据必须能看出来
      final broken = body!.replaceFirst('DeepLinkBridge.handleIntent(intent)', '');
      expect(broken.contains('DeepLinkBridge.handleIntent(intent)'), isFalse);
    });
  });
}
