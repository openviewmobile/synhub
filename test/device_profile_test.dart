// 目标机性能档位 → 效果默认值的离线验证。
//
// 规则是：**规格定档位（纯函数）** → **档位定默认值** → **手动的覆盖值优先**，
// 覆盖值为 null 时"恢复自动"。这里把三段分开测。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/device/device_profile.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/features/settings/settings_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

/// 带指定设备档位启动（覆盖 `deviceProfileProvider`，其余走 harness 的内存库）
Future<ChatHarness> _boot(DeviceProfile profile) =>
    bootChat(moreOverrides: [deviceProfileProvider.overrideWithValue(profile)]);

void main() {
  group('档位判定（纯函数）', () {
    test('4 核或更低 → 入门（不管内存多大）', () {
      expect(DeviceProfile.classify(cores: 4, ramMb: 8192), DeviceTier.low);
      expect(DeviceProfile.classify(cores: 2, ramMb: 4096), DeviceTier.low);
    });

    test('内存 ≤3GB → 入门', () {
      expect(DeviceProfile.classify(cores: 8, ramMb: 3072), DeviceTier.low);
      expect(DeviceProfile.classify(cores: 8, ramMb: 2048), DeviceTier.low);
    });

    test('Android 7 及以下 → 入门', () {
      expect(
        DeviceProfile.classify(cores: 8, ramMb: 8192, sdkInt: 25),
        DeviceTier.low,
      );
      expect(
        DeviceProfile.classify(cores: 8, ramMb: 8192, sdkInt: 26),
        DeviceTier.high,
      );
    });

    test('内存 ≤4.5GB（但核数够）→ 中端', () {
      expect(DeviceProfile.classify(cores: 8, ramMb: 4096), DeviceTier.medium);
      expect(DeviceProfile.classify(cores: 8, ramMb: 4608), DeviceTier.medium);
    });

    test('6 核 + 7GB（例：LGE-AN10）→ 高端', () {
      expect(
        DeviceProfile.classify(cores: 6, ramMb: 7090, sdkInt: 31),
        DeviceTier.high,
      );
      expect(DeviceProfile.classify(cores: 8, ramMb: 6144), DeviceTier.high);
    });

    test('规格全拿不到 → 兜底当高端（效果全开，同改造前）', () {
      expect(DeviceProfile.fallback.tier, DeviceTier.high);
      expect(DeviceProfile.fallback.preferBlur, isTrue);
      expect(DeviceProfile.fallback.preferReducedMotion, isFalse);
      expect(DeviceProfile.fallback.preferChatGrid, isTrue);
    });
  });

  group('档位 → 默认效果', () {
    test('入门：关毛玻璃 / 减少动效 / 关网格', () {
      final p = DeviceProfile.of(cores: 4, ramMb: 2048);
      expect(p.tier, DeviceTier.low);
      expect(p.preferBlur, isFalse);
      expect(p.preferReducedMotion, isTrue);
      expect(p.preferChatGrid, isFalse);
    });

    test('中端：关毛玻璃 / 完整动效 / 开网格', () {
      final p = DeviceProfile.of(cores: 8, ramMb: 4096);
      expect(p.tier, DeviceTier.medium);
      expect(p.preferBlur, isFalse);
      expect(p.preferReducedMotion, isFalse);
      expect(p.preferChatGrid, isTrue);
    });

    test('高端：开毛玻璃 / 完整动效 / 开网格', () {
      final p = DeviceProfile.of(cores: 8, ramMb: 8192);
      expect(p.tier, DeviceTier.high);
      expect(p.preferBlur, isTrue);
      expect(p.preferReducedMotion, isFalse);
      expect(p.preferChatGrid, isTrue);
    });

    test('遥测串按缺项省略', () {
      expect(
        DeviceProfile.of(cores: 6, ramMb: 7090, sdkInt: 31).specLabel,
        '6 核 · 6.9 GB · Android SDK 31',
      );
      expect(DeviceProfile.fallback.specLabel, '规格未知');
      expect(DeviceProfile.of(cores: 8, ramMb: 0).specLabel, '8 核');
    });
  });

  group('覆盖值优先 / 恢复自动', () {
    test('入门机上"性能模式"默认就是开的（设备档位给的）', () async {
      final h = await _boot(DeviceProfile.of(cores: 4, ramMb: 2048));
      final c = h.container;
      // settingsServiceProvider 读的是真 store（内存库）
      expect(c.read(perfModeProvider), isTrue, reason: '入门机默认无毛玻璃');
      expect(c.read(reducedMotionProvider), isTrue);
      expect(c.read(chatGridProvider), isFalse);
    });

    test('高端机上三个默认值都是"效果全开"', () async {
      final h = await _boot(DeviceProfile.of(cores: 8, ramMb: 8192));
      final c = h.container;
      expect(c.read(perfModeProvider), isFalse);
      expect(c.read(reducedMotionProvider), isFalse);
      expect(c.read(chatGridProvider), isTrue);
    });

    test('手动覆盖压过设备档位，恢复自动后回到档位默认', () async {
      final h = await _boot(DeviceProfile.of(cores: 4, ramMb: 2048));
      final c = h.container;
      final notifier = c.read(
        effectOverrideProvider(EffectKind.perfMode).notifier,
      );

      await notifier.set(false); // 用户偏要毛玻璃
      expect(c.read(perfModeProvider), isFalse);
      expect(c.read(effectOverrideProvider(EffectKind.perfMode)), isFalse);

      await notifier.set(null); // 恢复自动
      expect(c.read(effectOverrideProvider(EffectKind.perfMode)), isNull);
      expect(c.read(perfModeProvider), isTrue);
    });

    test('覆盖值落盘、恢复自动把键删掉（下次启动还是自动）', () async {
      final h = await bootChat();
      final svc = h.container.read(settingsServiceProvider);

      expect(await svc.perfModeOverride(), isNull, reason: '没存过 = 自动');
      await svc.setPerfModeOverride(false);
      expect(await svc.perfModeOverride(), isFalse);
      await svc.setPerfModeOverride(null);
      expect(await svc.perfModeOverride(), isNull, reason: '删掉 = 回到自动');

      await svc.setReducedMotionOverride(true);
      expect(await svc.reducedMotionOverride(), isTrue);
      await svc.setReducedMotionOverride(null);
      expect(await svc.reducedMotionOverride(), isNull);

      await svc.setChatGridOverride(false);
      expect(await svc.chatGridOverride(), isFalse);
      await svc.setChatGridOverride(null);
      expect(await svc.chatGridOverride(), isNull);
    });
  });

  group('设置页', () {
    testWidgets('自动文案按档位给，且"性能模式"与"网格底纹"不会反着说', (tester) async {
      Future<void> show(DeviceProfile p) async {
        final h = await _boot(p);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: h.container,
            child: MaterialApp(theme: AppTheme.dark(), home: SettingsPage()),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      // ★ r494：「聊天页网格底纹」这一行已从设置页删除（底纹退役 ⇒ 它是死功能）。
      //   剩下两个开关：性能模式、减少动效。
      //   高端：两者默认关 ⇒ 两条"默认关闭"，没有"默认开启"。
      await show(DeviceProfile.of(cores: 8, ramMb: 8192));
      expect(find.textContaining('自动（按设备性能默认开启）'), findsNothing);
      expect(find.textContaining('自动（按设备性能默认关闭）'), findsNWidgets(2));

      // 入门：两者默认开 ⇒ 两条"默认开启"。
      await show(DeviceProfile.of(cores: 4, ramMb: 2048));
      expect(find.textContaining('自动（按设备性能默认开启）'), findsNWidgets(2));
      expect(find.textContaining('自动（按设备性能默认关闭）'), findsNothing);

      // ★ r425：设置页的缓存用量 provider 改成了 `autoDispose`（`DA84`）——
      // Riverpod 3.4 在最后一个监听者消失时会 `_DefaultVsync.scheduleDispose`
      // 排一个 **0 时长 Timer**。测试体里主动把树拆掉再走一帧把它跑完，
      // 否则 framework 在拆卸后检查"仍有 pending Timer"会当场失败
      // （实测：只有这条用例红，且红在 `!timersPending` 断言上）。
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('显示设备档位遥测 + 自动语义，拨一下出现「恢复自动」', (tester) async {
      final h = await _boot(DeviceProfile.of(cores: 4, ramMb: 2048));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: SettingsPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('设备性能档位：入门'), findsOneWidget);
      // 两个开关默认都是"自动"（r494：网格底纹行已删）
      expect(find.textContaining('自动（按设备性能默认'), findsNWidgets(2));
      expect(find.text('恢复自动'), findsNothing);

      // 手动拨一下 → 变成"已手动"并给出恢复入口
      await tester.tap(find.text('性能模式'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('已手动关闭'), findsOneWidget);
      expect(find.text('恢复自动'), findsOneWidget);

      await tester.tap(find.text('恢复自动'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('恢复自动'), findsNothing);
      expect(find.textContaining('自动（按设备性能默认'), findsNWidgets(2));
    });
  });

  // ★ 第 296 轮（P1-5）：macOS 上真实探测内存，不再退化成 ramMb=0。
  group('真机/宿主探测（macOS 走 sysctl hw.memsize）', () {
    test(
      'detect() 在 macOS 上拿到非零内存，且档位由真实规格决定',
      () {
        final p = DeviceProfile.detect();
        expect(p.cores, greaterThan(0));
        expect(
          p.ramMb,
          greaterThan(0),
          reason: 'macOS 没有 /proc/meminfo，但 sysctl -n hw.memsize 必须读得到',
        );
        // 读到的是字节数换算成的 MB：不可能小于 512MB，也不可能大于 4TB
        expect(p.ramMb, inInclusiveRange(512, 4 * 1024 * 1024));
        // 档位必须与"用同样的规格再算一次"一致（没有别的分支偷偷改档）
        expect(
          p.tier,
          DeviceProfile.classify(cores: p.cores, ramMb: p.ramMb),
        );
        // 典型桌面机（≥6 核 + >4.5GB）应当落在高端，别因为读不到内存退化
        if (p.cores >= 6 && p.ramMb > 4608) {
          expect(p.tier, DeviceTier.high);
        }
      },
      skip: Platform.isMacOS ? null : '仅 macOS 宿主上可验证（其他平台走 /proc）',
    );
  });
}
