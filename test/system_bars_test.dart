// DA102（第 455 轮）：**全局系统栏口径**的宿主判据。
//
// 缺陷是什么、为什么这么修，见 `lib/src/core/ui/system_bars.dart` 的文件头
// 与 `docs/android-ui-audit-r454.md`（取证）/`docs/android-ui-audit-r455.md`（修法）。
//
// 这份用例要钉死四件事（缺一条都会让"灰带"回来）：
//   ① 口径本身：状态栏**透明** + 图标明暗**随主题**，且**不碰导航栏**；
//   ② 没有 AppBar 的页（外壳五个 Tab / 连接页 / 登录页）在**树根**就拿到了它；
//   ③ 有 AppBar 的页**一字不变** —— AppBar 自己发布的样式仍在它自己的子树里，
//      且按绘制顺序仍然**最后生效**（反向判据，不是"看起来没坏"）；
//   ④ 接线守卫：`app.dart` 必须真的挂着 `SystemBarsScope`、
//      两个 `styles.xml` 必须声明透明状态栏（"第一帧之前"的地板）——
//      否则有人把接线拆了，前三组用例照样全绿。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/ui/system_bars.dart';

/// 录下所有发往平台通道的 `SystemChrome.*` 调用（判定"最终下发了什么"）。
List<MethodCall> _recordChromeCalls(WidgetTester tester) {
  final calls = <MethodCall>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method.startsWith('SystemChrome.')) calls.add(call);
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return calls;
}

/// 平台通道里最后一次"设置系统栏样式"的参数表。
Map<Object?, Object?>? _lastOverlayArgs(List<MethodCall> calls) {
  final styleCalls = calls
      .where((c) => c.method == 'SystemChrome.setSystemUIOverlayStyle')
      .toList();
  if (styleCalls.isEmpty) return null;
  return (styleCalls.last.arguments as Map).cast<Object?, Object?>();
}

/// 从 `app.dart` 的 `builder:` 里抓 `SystemBarsScope` 的接线（静态守卫用）。
String _readRepoFile(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: '文件不存在：$path');
  return file.readAsStringSync();
}

void main() {
  group('DA102 系统栏口径（App 自己声明，不再靠 ROM 默认值）', () {
    test('DA102 ① 口径：状态栏透明 + 图标明暗随主题 + 不碰导航栏', () {
      final light = synhubSystemBarStyle(Brightness.light);
      expect(light.statusBarColor, const Color(0x00000000));
      expect(light.statusBarIconBrightness, Brightness.dark,
          reason: '浅色页面上图标必须深色');
      expect(light.statusBarBrightness, Brightness.light);
      expect(light.systemStatusBarContrastEnforced, isFalse,
          reason: '挡掉"个别 ROM 在透明状态栏上再画一层 scrim"');

      final dark = synhubSystemBarStyle(Brightness.dark);
      expect(dark.statusBarColor, const Color(0x00000000));
      expect(dark.statusBarIconBrightness, Brightness.light,
          reason: '深色页面上图标必须浅色');

      // 与 M3 `AppBar` 口径一致的另一半：导航栏一个字段都不设。
      // （AppBar 发布的样式里导航栏就是 `null`；另起一套会与 AppBar 页打架。）
      for (final style in [light, dark]) {
        expect(style.systemNavigationBarColor, isNull);
        expect(style.systemNavigationBarIconBrightness, isNull);
      }
    });

    testWidgets('DA102 ② 没有 AppBar 的页：树根就发布了透明状态栏（浅/深两档）',
        (tester) async {
      for (final entry in <ThemeMode, Brightness>{
        ThemeMode.light: Brightness.light,
        ThemeMode.dark: Brightness.dark,
      }.entries) {
        final calls = _recordChromeCalls(tester);
        final appKey = UniqueKey();
        await tester.pumpWidget(
          MaterialApp(
            key: appKey,
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            themeMode: entry.key,
            // 与 `lib/src/app.dart` 同形：`builder` 里最外层包 `SystemBarsScope`
            builder: (context, child) =>
                SystemBarsScope(child: child ?? const SizedBox.shrink()),
            home: const Scaffold(body: SizedBox.shrink()), // ★ 故意没有 AppBar
          ),
        );
        await tester.pump();

        final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
          find
              .descendant(
                of: find.byType(SystemBarsScope),
                matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
              )
              .first,
        );
        expect(region.value.statusBarColor, const Color(0x00000000));
        expect(region.value.statusBarIconBrightness,
            synhubSystemBarStyle(entry.value).statusBarIconBrightness);

        // 光有 `AnnotatedRegion` 还不够：平台通道上必须真的下发过一次
        final args = _lastOverlayArgs(calls);
        expect(args, isNotNull,
            reason: '没有 AppBar 的页必须由 SystemBarsScope 主动下发一次');
        expect(args!['statusBarColor'], 0x00000000);
        expect(args['systemStatusBarContrastEnforced'], isFalse);
        final expected = entry.value == Brightness.dark
            ? 'Brightness.light'
            : 'Brightness.dark';
        expect('${args['statusBarIconBrightness']}', expected,
            reason: '图标明暗必须跟 App 内主题走（${entry.key}）');
      }
    });

    testWidgets('DA102 ③ 有 AppBar 的页一字不变：AppBar 自己那套仍在最后生效',
        (tester) async {
      final calls = _recordChromeCalls(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          builder: (context, child) =>
              SystemBarsScope(child: child ?? const SizedBox.shrink()),
          home: Scaffold(appBar: AppBar(title: const Text('x'))),
        ),
      );
      await tester.pump();

      // ① AppBar 的子子树里仍然有它**自己**发布的那一个 region（我们没顶掉它）
      final inner = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
        find
            .descendant(
              of: find.byType(AppBar),
              matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
            )
            .first,
      );
      // M3 默认：透明 + 不设对比度强制（`null`），与我们的口径只差这一个字段
      expect(inner.value.statusBarColor, const Color(0x00000000));
      expect(inner.value.systemStatusBarContrastEnforced, isNull);

      // ② 反向判据：**最终生效的必须仍是 AppBar 那一套**。
      //    判据钉在"谁的字段"上：AppBar 发布的样式里
      //    `systemStatusBarContrastEnforced` 是 `null`（它照抄
      //    `SystemUiOverlayStyle.light/.dark` 的 null），我们的口径里是 `false`
      //    ⇒ 这个字段的取值就等于"最后生效的是谁"，不依赖"看着没坏"。
      //    （框架侧真身：`RenderView._updateSystemChrome` 在状态栏中心点做
      //    `layer.find<SystemUiOverlayStyle>(top)`，而
      //    `AnnotatedRegionLayer.findAnnotations(onlyFirst: true)` 是
      //    **先找子层、找不到才用自己** ⇒ 更深的 AppBar 永远盖得住根上的我们。）
      final args = _lastOverlayArgs(calls);
      expect(args, isNotNull);
      expect(args!['systemStatusBarContrastEnforced'], isNull,
          reason: '有 AppBar 的页必须仍是 AppBar 说了算（它是更深的那个标注）');
      expect(args['statusBarColor'], 0x00000000);
      expect('${args['statusBarIconBrightness']}', 'Brightness.dark');
    });

    testWidgets('DA102 ④ 主题档位一换就重发（反向：不换不许重复发）', (tester) async {
      final calls = _recordChromeCalls(tester);
      Widget app(ThemeMode mode) => MaterialApp(
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            themeMode: mode,
            builder: (context, child) =>
                SystemBarsScope(child: child ?? const SizedBox.shrink()),
            home: const Scaffold(body: SizedBox.shrink()),
          );

      await tester.pumpWidget(app(ThemeMode.light));
      await tester.pump();
      final afterLight = calls.length;
      expect(afterLight, greaterThan(0));

      // 同一个亮度再重建一次：**不许**再发（否则每帧一条平台消息）
      await tester.pumpWidget(app(ThemeMode.light));
      await tester.pump();
      expect(calls.length, afterLight, reason: '亮度没变就不该重复下发');

      // 换成深色：必须重发，且图标变浅色。
      // ★ `MaterialApp` 内部是 `AnimatedTheme`（200ms 插值）⇒ 要等它走完，
      //   否则读到的还是插值中的浅色亮度（第一版就栽在这里）。
      await tester.pumpWidget(app(ThemeMode.dark));
      await tester.pumpAndSettle();
      expect(calls.length, greaterThan(afterLight));
      expect('${_lastOverlayArgs(calls)!['statusBarIconBrightness']}',
          'Brightness.light');
    });
  });

  group('DA102 接线守卫（拆了接线这三组用例照样绿 ⇒ 静态钉住它）', () {
    test('DA102 ⑤ app.dart 的 builder 里必须最外层挂着 SystemBarsScope', () {
      final src = _readRepoFile('lib/src/app.dart');
      final builderAt = src.indexOf('builder: (context, child) =>');
      expect(builderAt, greaterThan(0), reason: 'MaterialApp.builder 不在了？');
      final head = src.substring(builderAt, builderAt + 400);
      expect(head.contains('SystemBarsScope('), isTrue,
          reason: 'builder 最外层必须是 SystemBarsScope，否则没有 AppBar 的页又回灰带');
      expect(head.contains('FoldPostureLayout('), isTrue,
          reason: '原有的 FoldPostureLayout 必须还在（别把它挤掉）');
    });

    test('DA102 ⑥ 两个 styles.xml 都必须声明透明状态栏 + 图标明暗', () {
      for (final entry in <String, String>{
        'android/app/src/main/res/values/styles.xml':
            '<item name="android:windowLightStatusBar">true</item>',
        'android/app/src/main/res/values-night/styles.xml':
            '<item name="android:windowLightStatusBar">false</item>',
      }.entries) {
        final xml = _readRepoFile(entry.key);
        // LaunchTheme 与 NormalTheme **两个**都要（splash → 正常窗口两段都不能有灰带）
        expect('<item name="android:statusBarColor">@android:color/transparent</item>'
                .allMatches(xml).length,
            2,
            reason: '${entry.key}：LaunchTheme/NormalTheme 都要声明透明状态栏');
        expect(xml, contains(entry.value));
        // AGENTS §2.0.19：XML 注释正文里出现 `--` 会让 release 资源解析直接失败
        final inner = xml.replaceAll('<!--', '').replaceAll('-->', '');
        expect(inner.contains('--'), isFalse,
            reason: '${entry.key}：注释正文里不许出现 `--`');
      }
    });

    test('DA102 ⑦ 全仓只有这一处声明样式（别处再冒一个就是两把尺子）', () {
      final offenders = <String>[];
      final root = Directory('lib');
      final pattern = RegExp(r'SystemUiOverlayStyle');
      for (final entity in root.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final rel = entity.path.replaceAll('\\', '/');
        // 播放器那条是 `SystemUiMode`（隐藏系统栏），不是样式；它出现
        // `SystemUiOverlayStyle` 才算出界 —— 用同一份文件名单锁住。
        if (rel == 'lib/src/core/ui/system_bars.dart') continue;
        if (pattern.hasMatch(entity.readAsStringSync())) offenders.add(rel);
      }
      expect(offenders, isEmpty,
          reason: '样式必须只从 system_bars.dart 出（AppBar 的是框架内部行为）：$offenders');
    });
  });
}
