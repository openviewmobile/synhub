// r448 · **QA 合成画像**（`qa_device_capability.json`）的守卫用例。
//
// 为什么有这个仪器：本机是 8 GB / 8 核 / arm64，按规则永远 `high`
// ⇒ 「弱机 ⇒ 端侧模块隐藏」这条分支**在真机上不可能自然出现**
// （`docs/device-llm-capability.md` §6.3 记的就是这个开口）。
// r448 把它做成一个**显式、一次性、可撤**的诊断入口：应用私有目录里放一个
// JSON 文件 ⇒ 用它当"本机能力"；文件不在 ⇒ 走真实硬件（**默认路径不变**）。
//
// 本文件钉住四件事：
//   ① 文件不在 / 坏 JSON / 非 Map ⇒ 一律回 `null`（＝走真实硬件，绝不抛）；
//   ② 文件在场 ⇒ 解析出 `source == 'synthetic'`，且**界面会明说这是合成画像**；
//   ③ 合成画像的**档位**照样走生产判定：2 GB ⇒ `unsupported` ＋ 隐藏 ＋ 写出原因；
//      8 GB ⇒ 可见 —— **隐藏不是"文件在场"造成的，是档位造成的**；
//   ④ 默认解析（`fromPlatformMap(map)`）**不许**被改成 synthetic。
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/device/device_capability.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/ai/ai_model_page.dart';
import 'package:synhub/src/features/ai/ai_providers.dart';
import 'package:synhub/src/features/ai/cloud_settings.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/l10n/gen/app_localizations.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';

const int _gb = 1024 * 1024 * 1024;

/// 一张**真实值**的硬件事实（8 GB / 8 核 / arm64 / Adreno + OpenCL）。
Map<String, Object?> _realMap() => <String, Object?>{
  'manufacturer': 'HONOR',
  'brand': 'HONOR',
  'model': 'LGE-AN10',
  'socModel': 'SM8450',
  'socManufacturer': 'QTI',
  'hardware': 'qcom',
  'board': 'taro',
  'sdkInt': 31,
  'release': '12',
  'abis': const ['arm64-v8a', 'armeabi-v7a', 'armeabi'],
  'cpuCores': 8,
  'cpuFeatures': 'asimdhp i8mm',
  'cpuMaxFreqKhz': 1785600,
  'totalRamBytes': 7259836000,
  'availRamBytes': 3000000000,
  'lowMemory': false,
  'lowRamDevice': false,
  'freeStorageBytes': 167 * _gb,
  'totalStorageBytes': 220 * _gb,
  'glRenderer': 'Adreno (TM) 730',
  'glVendor': 'Qualcomm',
  'glVersion': 'OpenGL ES 3.2 V@0611.0',
  'openclLibrary': true,
  'nnapiFeature': true,
  'thermalStatus': 0,
};

/// 弱机画像：2 GB（< 3 GB 门槛）＋ 低端 SoC。
Map<String, Object?> _weakMap() => <String, Object?>{
  ..._realMap(),
  'socModel': 'MT6765',
  'hardware': 'mt6765',
  'totalRamBytes': 2 * _gb,
  'availRamBytes': _gb,
  'cpuCores': 4,
  'glRenderer': 'Mali-G52',
  'openclLibrary': false,
  'freeStorageBytes': 16 * _gb,
};

/// 低内存标记（系统自己说这是低内存机）—— 与内存数值无关的**硬否决**。
Map<String, Object?> _lowRamMap() => <String, Object?>{
  ..._realMap(),
  'totalRamBytes': 6 * _gb,
  'lowRamDevice': true,
};

Future<Directory> _tmpDir() async {
  final d = Directory.systemTemp.createTempSync('r448_qa_cap');
  addTearDown(() {
    if (d.existsSync()) d.deleteSync(recursive: true);
  });
  return d;
}

File _write(Directory d, Object? json) {
  final f = File('${d.path}/$kQaSyntheticCapabilityFileName');
  f.writeAsStringSync(json is String ? json : jsonEncode(json));
  return f;
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required DeviceCapability profile,
}) async {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  final db = ChatDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      deviceCapabilityProvider.overrideWith((ref) async => profile),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        locale: const Locale('zh'),
        localizationsDelegates: AppText.localizationsDelegates,
        supportedLocales: AppText.supportedLocales,
        home: const AiModelPage(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.runAsync(
    () => container.read(aiTierProvider.notifier).select(AiTier.onDevice),
  );
  await tester.pump(const Duration(milliseconds: 300));
  return container;
}

void main() {
  final t = AppTextZh();

  group('SP · QA 合成画像的读取（默认路径不许被改动）', () {
    test('SP1 文件不在 ⇒ null（＝走真实硬件）', () async {
      final d = await _tmpDir();
      expect(await readQaSyntheticCapability(dir: d), isNull);
    });

    test('SP2 坏 JSON / 非 Map ⇒ null，且**不抛**', () async {
      final d = await _tmpDir();
      _write(d, '{ 这不是 JSON');
      expect(await readQaSyntheticCapability(dir: d), isNull);
      _write(d, const [1, 2, 3]);
      expect(await readQaSyntheticCapability(dir: d), isNull);
      _write(d, '"just a string"');
      expect(await readQaSyntheticCapability(dir: d), isNull);
    });

    test('SP3 目录不存在 ⇒ null，且**不抛**', () async {
      final d = Directory('${Directory.systemTemp.path}/r448_no_such_dir_xyz');
      expect(await readQaSyntheticCapability(dir: d), isNull);
    });

    test('SP4 ★ 默认解析仍是 `platform`，不许被改成 synthetic', () {
      final s = DeviceCapabilitySnapshot.fromPlatformMap(_realMap());
      expect(s.source, 'platform', reason: '生产解析路径的 source 一字不许改');
      expect(s.syntheticProfile, isFalse);
      expect(s.totalRamBytes, 7259836000);
    });

    test('SP5 文件在场 ⇒ `source == synthetic` ＋ 数值逐个照抄', () async {
      final d = await _tmpDir();
      _write(d, _realMap());
      final s = await readQaSyntheticCapability(dir: d);
      expect(s, isNotNull);
      expect(s!.source, 'synthetic');
      expect(s.syntheticProfile, isTrue, reason: '合成画像必须有**唯一**判据');
      expect(s.socModel, 'SM8450');
      expect(s.totalRamBytes, 7259836000);
      expect(s.abis, contains('arm64-v8a'));
      expect(s.glRenderer, 'Adreno (TM) 730');
      expect(s.openclLibrary, isTrue);
    });
  });

  group('SP · 合成画像照样走生产档位判定（②/③）', () {
    test('SP6 2 GB ⇒ `unsupported` ＋ 模块隐藏', () async {
      final d = await _tmpDir();
      _write(d, _weakMap());
      final snap = (await readQaSyntheticCapability(dir: d))!;
      final p = classifyDevice(snap);
      expect(p.tier, DeviceComputeTier.unsupported);
      expect(p.moduleVisible, isFalse);
      // 判据取**合成数值真的流进了判定**（不是只看档位名）：
      // `ram:` 是 2 GB 的字节数、`gpu:mali` 说明 GPU 家族也是从画像里认出来的。
      expect(p.notes, contains('ram:2147483648'));
      expect(p.notes, contains('gpu:mali'));
      // ★ 口径（实测）：内存已经小于门槛时**不再算 SoC 调整** ⇒ 这里没有 `soc:` 条目。
      //   这是既有规则，本轮不改；把它写下来，省得下一轮又以为是漏了。
      expect(p.notes.where((n) => n.startsWith('soc:')), isEmpty);
    });

    test('SP7 低内存标记 ⇒ `unsupported`（与内存数值无关的硬否决）', () async {
      final d = await _tmpDir();
      _write(d, _lowRamMap());
      final p = classifyDevice((await readQaSyntheticCapability(dir: d))!);
      expect(p.tier, DeviceComputeTier.unsupported);
      expect(p.moduleVisible, isFalse);
      expect(p.notes, contains('veto:lowRamDevice'));
    });

    test('SP8 ★ 阴性腿：8 GB 合成画像 ⇒ `high` ＋ 模块**可见**', () async {
      final d = await _tmpDir();
      _write(d, _realMap());
      final p = classifyDevice((await readQaSyntheticCapability(dir: d))!);
      expect(
        p.tier,
        DeviceComputeTier.high,
        reason: '真机事实（SM8450 + 7.26 GB）本来就是 high，合成一份真实值必须复现它',
      );
      expect(
        p.moduleVisible,
        isTrue,
        reason: '★ 判据：隐藏是**档位**造成的，不是"文件在场"造成的',
      );
    });
  });

  group('SP · 界面端到端（文件 ⇒ 解析 ⇒ 档位 ⇒ 页面）', () {
    testWidgets('SP9 弱机合成画像 ⇒ 明说已隐藏 ＋ 写出原因 ＋ 明说这是合成画像', (tester) async {
      final d = await _tmpDir();
      _write(d, _weakMap());
      final p = classifyDevice((await readQaSyntheticCapability(dir: d))!);
      await _pump(tester, profile: p);

      expect(find.text(t.aiDeviceCapabilityTitle), findsOneWidget);
      expect(find.text(t.aiDeviceModuleHidden), findsOneWidget);
      // 原因逐字来自生产代码（`_hiddenReason`）：内存低于门槛
      expect(
        find.textContaining('低于端侧模型最低要求'),
        findsOneWidget,
        reason: '隐藏必须**写出原因**，不是只给一个开关',
      );
      // ★ 合成画像必须在界面上被明说（这张卡的意义就是"如实说本机是什么"）
      expect(find.text(t.aiDeviceSyntheticProfile), findsOneWidget);
      // 端侧档位整段不在；云端/内置摘要仍在
      expect(find.text(t.aiEngineOnDevice), findsNothing);
      expect(find.text(t.aiModelTiers), findsNothing);
      expect(find.text(t.aiTierCloud), findsOneWidget);
      expect(find.text(t.aiEngineExtractive), findsOneWidget);
    });

    testWidgets('SP10 低内存标记合成画像 ⇒ 原因写"低内存设备"', (tester) async {
      final d = await _tmpDir();
      _write(d, _lowRamMap());
      final p = classifyDevice((await readQaSyntheticCapability(dir: d))!);
      await _pump(tester, profile: p);
      expect(find.text(t.aiDeviceModuleHidden), findsOneWidget);
      expect(find.textContaining(t.aiDeviceVetoLowRam), findsOneWidget);
    });

    testWidgets('SP11 ★ 阴性腿：8 GB 合成画像 ⇒ 端侧档位在场（但**仍然**明说是合成画像）', (tester) async {
      final d = await _tmpDir();
      _write(d, _realMap());
      final p = classifyDevice((await readQaSyntheticCapability(dir: d))!);
      await _pump(tester, profile: p);

      expect(find.text(t.aiDeviceModuleHidden), findsNothing);
      expect(find.text(t.aiEngineOnDevice), findsWidgets);
      expect(
        find.text(t.aiDeviceSyntheticProfile),
        findsOneWidget,
        reason: '合成就是合成 —— 可见腿也要明说，不能因为"看起来正常"就不标',
      );
    });

    testWidgets('SP12 没有文件（真实解析）⇒ 端侧档位在场且**不出现**合成画像提示', (tester) async {
      final p = classifyDevice(DeviceCapabilitySnapshot.fromPlatformMap(_realMap()));
      await _pump(tester, profile: p);
      expect(find.text(t.aiDeviceModuleHidden), findsNothing);
      expect(find.text(t.aiEngineOnDevice), findsWidgets);
      expect(
        find.text(t.aiDeviceSyntheticProfile),
        findsNothing,
        reason: '默认路径不许被贴上"合成"标签',
      );
    });
  });
}
