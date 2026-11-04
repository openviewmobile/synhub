// ★ 仪器147 的自证守卫（r447）：条件等待**能等真的异步**、**超时如实返回 false**。
//
// 为什么守卫本身要存在：`pumpUntil` 是"治假红"的工具 —— 如果它自己只会返回 `true`
// （或超时抛异常），那四条偶发假红就会被**伪装成绿**。这里逐条把它的两个方向都钉住：
//   ① 真实异步（`Future.delayed` 真定时器 / 真文件 IO）能被等到；
//   ② 条件永不成立时**返回 false**（不是 true、也不是抛），且耗时 ≈ timeout；
//   ③ `pump` 侧也在推进（动画/帧依赖它）。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/pump_until.dart';

void main() {
  group('仪器147 · pumpUntil', () {
    testWidgets('真实异步（真定时器）能被等到 —— 固定睡眠会漏，条件等待不会', (tester) async {
      var fired = false;
      // 真定时器：只在 runAsync 的实时区里才会触发
      Future<void>.delayed(
        const Duration(milliseconds: 120),
        () => fired = true,
      );
      await tester.pumpWidget(const SizedBox());
      final ok = await pumpUntil(tester, () => fired);
      expect(ok, isTrue);
      expect(fired, isTrue);
    });

    testWidgets('条件永不成立 ⇒ 返回 false（不抛），且耗时 ≈ timeout', (tester) async {
      await tester.pumpWidget(const SizedBox());
      final t0 = DateTime.now();
      final ok = await pumpUntil(
        tester,
        () => false,
        timeout: const Duration(milliseconds: 200),
        step: const Duration(milliseconds: 20),
      );
      final ms = DateTime.now().difference(t0).inMilliseconds;
      expect(ok, isFalse, reason: '超时必须如实返回 false');
      expect(ms, greaterThanOrEqualTo(180), reason: '真的等满超时，而不是立刻返回');
    });

    testWidgets('pump 侧在推进：假时钟里的 Timer 只靠 pump(step) 触发', (tester) async {
      // 测试区里排的 Timer 是**假时钟**：`runAsync` 的实时小睡推不动它，
      // 只有 `pump(step)` 会把假时钟往前拨 ⇒ 这条能证明 helper 真的在推帧。
      var fired = false;
      Timer(const Duration(milliseconds: 300), () => fired = true);
      await tester.pumpWidget(const SizedBox());
      final ok = await pumpUntil(
        tester,
        () => fired,
        timeout: const Duration(seconds: 5),
      );
      expect(ok, isTrue, reason: '每次循环都要 pump(step) 才能推进假时钟');
      expect(fired, isTrue);
    });
  });

  group('仪器147 · pumpUntilFound', () {
    testWidgets('控件出现 ⇒ true；不出现 ⇒ false', (tester) async {
      var show = false;
      late StateSetter set;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              set = setState;
              return show
                  ? TextButton(
                      onPressed: () {},
                      child: const Text('出现了'),
                    )
                  : const SizedBox();
            },
          ),
        ),
      );
      expect(
        await pumpUntilFound(
          tester,
          find.text('出现了'),
          timeout: const Duration(milliseconds: 150),
        ),
        isFalse,
      );
      show = true;
      set(() {});
      expect(await pumpUntilFound(tester, find.text('出现了')), isTrue);
    });
  });

  group('仪器147 · pumpUntilAsync', () {
    testWidgets('真实异步判据（真文件出现）能被等到', (tester) async {
      final dir = Directory.systemTemp.createTempSync('r447_pump_until');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/x.bin');
      Future<void>.delayed(const Duration(milliseconds: 100), () {
        f.writeAsBytesSync(const [1, 2, 3]);
      });
      await tester.pumpWidget(const SizedBox());
      final ok = await pumpUntilAsync(tester, () async => f.existsSync());
      expect(ok, isTrue);
    });

    testWidgets('真实异步判据永不成立 ⇒ false', (tester) async {
      await tester.pumpWidget(const SizedBox());
      final ok = await pumpUntilAsync(
        tester,
        () async => false,
        timeout: const Duration(milliseconds: 150),
      );
      expect(ok, isFalse);
    });
  });

  group('仪器147 · pollUntilAsync（纯 Dart）', () {
    test('条件后来成立 ⇒ true', () async {
      var n = 0;
      final ok = await pollUntilAsync(() async => ++n >= 5);
      expect(ok, isTrue);
    });

    test('条件永不成立 ⇒ false，耗时 ≈ timeout', () async {
      final t0 = DateTime.now();
      final ok = await pollUntilAsync(
        () async => false,
        timeout: const Duration(milliseconds: 100),
      );
      expect(ok, isFalse);
      expect(
        DateTime.now().difference(t0).inMilliseconds,
        greaterThanOrEqualTo(90),
      );
    });
  });
}
