// r287：常驻动效**帧源**的机制量用例。
//
// 缺陷（r287 实测，macOS Release / 800x600 窗口）：连接页静止时进程 CPU
// **35–55%**，`sample` 里 53% 落在 `io.flutter.raster`；把 `ambientAllowed`
// 临时钉成 `false` 后 **帧数 = 0、CPU ≈ 0%** ⇒ 这些 CPU 全部来自"常驻动效
// 在不停地排帧"：每个常驻动效各自 `AnimationController(vsync:)..repeat()`，
// 而 `repeat()` 的本义就是"**每个 vsync 都请求一帧**" —— 各处只把
// `_phase.value` 的手动更新限到 `AppEffects.ambientTick`（20fps），
// **限住了"画什么"，没限住"排帧"**。
//
// 本文件钉的是**机制量**（见 AGENTS.md §2.0.30②：钉偏移/计数/状态，别钉
// "某元素此刻可不可见"这种结果量）：
//   ① `flutter_test` 下常驻动效恒关 ⇒ 既不建定时器，也**不留 vsync ticker**；
//   ② 开启后 1 秒内的推进次数**恰好** 1000 / ambientTick（= 20），不是 60/120；
//   ③ `subscribe`/`unsubscribe` 成对，最后一个订阅者走了**必须停表**；
//   ④ 可见的 `FieldBackdrop` **不挂 ticker** ⇒ 状态未变时引擎不排帧；
//   ⑤ `IndexedStack` 保活的非当前 tab **不订阅**（保活 ≠ 该重绘）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_tokens.dart';
import 'package:synhub/src/core/ui/ambient_clock.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/core/ui/field_backdrop.dart';

Widget _wrap(Widget child) =>
    MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: Center(child: child)));

void main() {
  setUp(() {
    AmbientClock.instance.debugReset();
    AppEffects.debugAmbientAllowedOverride = null;
  });
  tearDown(() {
    AmbientClock.instance.debugReset();
    AppEffects.debugAmbientAllowedOverride = null;
  });

  test('① 默认（flutter_test）恒关：不建表、不排帧 —— 生产路径行为不变', () {
    expect(
      AppEffects.debugAmbientAllowedOverride,
      isNull,
      reason: '测试缝只允许用例自己设置，默认必须是 null',
    );
    expect(AppEffects.isFlutterTest, isTrue);
    expect(AppEffects.ambientAllowed, isFalse);

    // 即便有人硬订阅，也不能建表（契约②）
    AmbientClock.instance.subscribe();
    expect(AmbientClock.instance.running, isFalse);
    expect(AmbientClock.instance.subscriberCount, 1, reason: '计数仍要准');
    AmbientClock.instance.unsubscribe();
  });

  // ② ③ 用 `testWidgets` 自带的假时钟（`tester.pump(Duration)` 会 elapse
  // `FakeAsync` 区里的定时器）—— 这样**不需要**给 pubspec 加 `fake_async`
  // 依赖（直接 import 会被 `depend_on_referenced_packages` 判 info）。
  testWidgets('② 开启后 1 秒推进次数 = 1000/ambientTick（20），不是 vsync 频率', (
    tester,
  ) async {
    AppEffects.debugAmbientAllowedOverride = true;
    var n = 0;
    void onTick() => n++;
    AmbientClock.instance.addListener(onTick);
    addTearDown(() => AmbientClock.instance.removeListener(onTick));
    AmbientClock.instance.subscribe();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));

    // 机制量：**上限**。修前是 `repeat()` 的 vsync 频率（60/120），
    // 与"状态有没有变"无关。
    expect(n, 1000 ~/ AppEffects.ambientTick.inMilliseconds);
    expect(n, 20);

    // 线性、不 burst：再来 2 秒就再 +40
    await tester.pump(const Duration(seconds: 2));
    expect(n, 60, reason: '必须是稳定 20fps，不是"补一帧"式的 burst');

    // 用例结束前必须退订：留着周期定时器会被测试框架判"pending timer"
    AmbientClock.instance.unsubscribe();
    expect(AmbientClock.instance.running, isFalse);
  });

  testWidgets('③ 退订成对：还有订阅者不许停表，最后一个走了必须立刻停表', (
    tester,
  ) async {
    AppEffects.debugAmbientAllowedOverride = true;
    var n = 0;
    void onTick() => n++;
    AmbientClock.instance.addListener(onTick);
    addTearDown(() => AmbientClock.instance.removeListener(onTick));

    await tester.pumpWidget(const SizedBox.shrink());
    AmbientClock.instance.subscribe();
    AmbientClock.instance.subscribe();
    expect(AmbientClock.instance.subscriberCount, 2);
    await tester.pump(const Duration(milliseconds: 200));
    expect(n, 4);
    expect(AmbientClock.instance.running, isTrue);

    AmbientClock.instance.unsubscribe();
    expect(
      AmbientClock.instance.running,
      isTrue,
      reason: '还有订阅者 ⇒ 不许停表（否则可见页面会被误停）',
    );

    AmbientClock.instance.unsubscribe();
    expect(AmbientClock.instance.subscriberCount, 0);
    expect(
      AmbientClock.instance.running,
      isFalse,
      reason: '没人看 ⇒ 必须停表（这就是"停掉空转"）',
    );

    await tester.pump(const Duration(seconds: 10));
    expect(n, 4, reason: '停表之后一次推进都不许有');
  });

  testWidgets('④ 可见的常驻动效不挂 vsync ticker（状态未变 ⇒ 不排帧）', (
    tester,
  ) async {
    AppEffects.debugAmbientAllowedOverride = true;
    await tester.pumpWidget(
      _wrap(const FieldBackdrop(child: SizedBox.expand())),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // 契约①：相位由共享时钟推进，**没有任何** `Ticker` 挂在 vsync 上。
    // 反向验证：把 `field_backdrop.dart` 还原成 `repeat()` 版本 ⇒ 这里 = 1，用例红。
    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: '常驻动效不许把引擎钉在"每个 vsync 都排帧"上',
    );
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('⑤ IndexedStack 保活的非当前 tab 不订阅、不重绘', (tester) async {
    AppEffects.debugAmbientAllowedOverride = true;
    final index = ValueNotifier<int>(0);
    addTearDown(index.dispose);

    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), 
        home: ValueListenableBuilder<int>(
          valueListenable: index,
          builder: (context, i, _) => IndexedStack(
            index: i,
            children: const [
              FieldBackdrop(child: SizedBox.expand()),
              FieldBackdrop(child: SizedBox.expand()),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // 窗口期里 5 个 tab 全在树上（`IndexedStack` 只停**绘制**，不停 ticker）
    // ⇒ 只有真正可见的那一页才该订阅。
    expect(
      AmbientClock.instance.subscriberCount,
      1,
      reason: '保活 ≠ 该重绘：不可见页面不许占订阅位',
    );

    index.value = 1;
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      AmbientClock.instance.subscriberCount,
      1,
      reason: '切 tab 后仍是"恰好一个"（旧的退了、新的进了）',
    );
  });
}
