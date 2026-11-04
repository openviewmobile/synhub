// 端侧模型页的**因机而异**界面行为（第 253 轮，用户要求）。
//
// 三条要钉住的：
//   ① 硬件太差（2GB/低内存）⇒ 端侧档位整段不出现 + 明确说明"已隐藏"；
//   ② 4GB 机器 ⇒ 只推荐跑得动的（LFM），跑不动的（Qwen）进"本机不适用"并说原因；
//   ③ 安装动作有硬件守卫：绕过界面直接调 `install()` 也会被挡（不发起下载）。
//
// 用 `deviceCapabilityProvider.overrideWith` 注入合成快照 —— 测试宿主不是手机，
// 真实探测会回 `source: 'host'`（不门控），那测不出门控逻辑。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/device/device_capability.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/ai/ai_device_fit.dart';
import 'package:synhub/src/features/ai/ai_model_page.dart';
import 'package:synhub/src/features/ai/ai_providers.dart';
import 'package:synhub/src/features/ai/cloud_settings.dart';
import 'package:synhub/src/features/ai/on_device_ai.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/l10n/gen/app_localizations.dart';
import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';

const int _gb = 1024 * 1024 * 1024;

DeviceCapabilitySnapshot _snap({
  required int ramGb,
  int freeGb = 64,
  String soc = 'SM8650',
  String gl = 'Adreno (TM) 740',
  bool opencl = true,
  bool lowRam = false,
  int cores = 8,
}) => DeviceCapabilitySnapshot(
  socModel: soc,
  hardware: soc.toLowerCase(),
  model: 'test-device',
  brand: 'test',
  sdkInt: 34,
  abis: const ['arm64-v8a'],
  cpuCores: cores,
  totalRamBytes: ramGb * _gb,
  lowRamDevice: lowRam,
  freeStorageBytes: freeGb * _gb,
  glRenderer: gl,
  openclLibrary: opencl,
  nnapiFeature: true,
  source: 'platform',
);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required DeviceCapability profile,
  Locale locale = const Locale('zh'),
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
        locale: locale,
        localizationsDelegates: AppText.localizationsDelegates,
        supportedLocales: AppText.supportedLocales,
        home: const AiModelPage(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  // 档位切到端侧（走 runAsync：select() 会写 Drift）
  await tester.runAsync(
    () => container.read(aiTierProvider.notifier).select(AiTier.onDevice),
  );
  await tester.pump(const Duration(milliseconds: 300));
  return container;
}

void main() {
  final t = AppTextZh();

  testWidgets('2GB 弱机 ⇒ 端侧档位隐藏，页面明说"已在本机隐藏"', (tester) async {
    await _pump(tester, profile: classifyDevice(_snap(ramGb: 2, soc: 'MT6765', gl: 'Mali-G52')));

    expect(find.text(t.aiDeviceCapabilityTitle), findsOneWidget);
    expect(find.text(t.aiDeviceModuleHidden), findsOneWidget);
    // 端侧档位段不在（"端侧模型"这个 segment 文案找不到）
    expect(find.text(t.aiEngineOnDevice), findsNothing);
    // 模型目录整段不在
    expect(find.text(t.aiModelTiers), findsNothing);
    // 但 AI 服务的其它档位还在（云端/内置摘要）—— 弱机不该连云端配置都没了
    expect(find.text(t.aiTierCloud), findsOneWidget);
    expect(find.text(t.aiEngineExtractive), findsOneWidget);
  });

  // ── ★ r131（macOS 走查实拍到的像素缺陷）─────────────────────────────
  // 桌面宿主（`source: 'host'`）上 `classifyDevice` 回的是 `ungatedHost` +
  // **占位档位** `mainstream` + **空快照**。页面原来照原样画，真机像素是
  // 「Tier Mainstream / SoC — / RAM 0 MB / Free storage 0 MB /
  //  GPU No OpenCL detected / NPU No NNAPI」——既下档位结论、又全是取不到值的
  // 占位。口径（AGENTS §2.0.6③）：宿主**不判档、不编数字**，但**不隐藏模块**。
  testWidgets('★★★ r131：桌面宿主不编数字、不报档位，但模块照旧可见', (tester) async {
    final host = classifyDevice(const DeviceCapabilitySnapshot(source: 'host'));
    expect(host.ungatedHost, isTrue, reason: '前提：宿主快照必须被判成 ungatedHost');
    await _pump(tester, profile: host);

    // ① 如实说明，不假装探到了
    expect(find.text(t.aiDeviceHostUnknown), findsOneWidget);
    // ② 卡内不许出现"0 MB"这种把"取不到"说成"是 0"的字样
    //    （只在能力卡里断言：模型体积那一行的 0 MB 是另一回事）
    final card = find.byKey(const Key('ai-device-capability-card'));
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.textContaining('0 MB')),
      findsNothing,
      reason: '宿主上内存/存储取不到 ⇒ 不能画成 0 MB（那是编数字）',
    );
    expect(find.descendant(of: card, matching: find.text('—')), findsNWidgets(6));
    // ③ 不许报**任何**一个档位结论（逐个档位名断言，不是只看 mainstream）
    expect(
      host.tier,
      DeviceComputeTier.unknown,
      reason: 'B1：零事实 ⇒ 未判定；改动前分类器硬编码 mainstream',
    );
    expect(
      host.moduleVisible,
      isTrue,
      reason: 'B1 反向：不许靠"隐藏模块"通过；宿主可见性由 ungatedHost 保证',
    );
    for (final label in [
      t.aiDeviceTierUnsupported,
      t.aiDeviceTierEntry,
      t.aiDeviceTierMainstream,
      t.aiDeviceTierHigh,
      t.aiDeviceTierFlagship,
    ]) {
      expect(
        find.descendant(of: card, matching: find.text(label)),
        findsNothing,
        reason: '宿主上不许出现任何档位文案「$label」',
      );
    }
    expect(find.text(t.aiDeviceGpuNone), findsNothing);
    expect(find.text(t.aiDeviceNpuNone), findsNothing);
    // ④ 也不许把模块藏掉（宿主不门控）
    expect(find.text(t.aiDeviceModuleHidden), findsNothing);
    expect(find.text(t.aiTierCloud), findsOneWidget);
  });

  testWidgets('★★★ 第 255 轮：图生图设置**不在**这一页（拆开独立配置）', (tester) async {
    await _pump(tester, profile: classifyDevice(_snap(ramGb: 8)));
    // 用户 2026-09-25：「图生图设置怎么和大语言模型设置混在一起了？
    // 能否拆开独立配置？」⇒ 本页只留"聊天用哪个模型"。
    expect(
      find.byKey(const Key('image-edit-settings-card')),
      findsNothing,
      reason: '★★★ 图生图（照片 AI 美化）的设置卡必须已经在'
          ' `photo_ai_edit_settings_page.dart` 里，不许再挂在这页',
    );
    for (final k in const [
      'image-edit-settings-enable',
      'image-edit-settings-backend',
      'image-edit-settings-backend',
      'image-edit-settings-key',
      'image-edit-settings-cap',
      'image-edit-settings-wifi-only',
      'image-edit-settings-revoke',
    ]) {
      expect(
        find.byKey(Key(k)),
        findsNothing,
        reason: '$k 也不该出现在大语言模型页',
      );
    }
  });

  testWidgets('低内存设备（系统标记）同样隐藏，理由写"低内存设备"', (tester) async {
    await _pump(
      tester,
      profile: classifyDevice(_snap(ramGb: 8, lowRam: true)),
    );
    expect(find.text(t.aiDeviceModuleHidden), findsOneWidget);
    expect(find.textContaining(t.aiDeviceVetoLowRam), findsOneWidget);
  });

  testWidgets('4GB 机器 ⇒ 只推荐 LFM；Qwen 进"本机不适用"并给出原因', (tester) async {
    final profile = classifyDevice(
      _snap(ramGb: 4, soc: 'SM6225', gl: 'Adreno (TM) 610'),
    );
    await _pump(tester, profile: profile);

    expect(find.text(t.aiDeviceModuleHidden), findsNothing);
    // LFM 有卡片，Qwen 不在推荐区里
    expect(find.text('LFM2.5 230M（int4）'), findsOneWidget);
    expect(find.text('Qwen3 0.6B'), findsOneWidget); // 出现在"不适用"段
    expect(find.text(t.aiBlockedModelsTitle(1)), findsOneWidget);
    expect(find.textContaining(t.aiBlockedReasonTier), findsOneWidget);
    // ★ 第 145 轮①：**有内存事实**时照旧给"内存不足"判词（不得被"未判定"文案吞掉）。
    //   这是上面那条反向用例的对照面：判可用性的文案必须同时有两种形态。
    expect(
      find.textContaining('内存不足'),
      findsOneWidget,
      reason: '已知 4GB 确实不够 6GB 门槛 ⇒ 必须如实说"内存不足"，不是"无法验证"',
    );
    expect(find.text(t.aiBlockedReasonUndetermined), findsNothing);
    expect(
      find.text(t.aiBlockedModelsTitleUndetermined(1)),
      findsNothing,
      reason: '已知事实足够下结论时，不许用"无法验证"当挡箭牌',
    );
  });

  testWidgets('8GB 旗舰 ⇒ 两个模型都在推荐区，没有"不适用"段', (tester) async {
    await _pump(tester, profile: classifyDevice(_snap(ramGb: 8)));
    expect(find.text('LFM2.5 230M（int4）'), findsOneWidget);
    expect(find.text('Qwen3 0.6B'), findsOneWidget);
    expect(find.textContaining('本机不适用的模型'), findsNothing);
  });

  testWidgets('安装守卫：本机跑不动的模型即使被直接调用也不发起下载', (tester) async {
    final container = await _pump(
      tester,
      profile: classifyDevice(
        _snap(ramGb: 4, soc: 'SM6225', gl: 'Adreno (TM) 610'),
      ),
    );
    final qwen = kOnDeviceModels.firstWhere((m) => m.id == 'qwen3-0.6b');
    final notifier = container.read(aiModelInstallProvider.notifier);
    final ok = await tester.runAsync(() => notifier.install(qwen));
    expect(ok, isFalse);
    final state = container.read(aiModelInstallProvider);
    expect(state.busy, isFalse);
    expect(state.error, t.aiDeviceModelBlocked);
  });

  // ── ★ B2：未知不得渲染成数字 ─────────────────────────────────────────
  // 证据（缺陷文档 §5 B2）：同一个面板里 `SoC` 空值渲染 `—`，而 `RAM`/`Free storage`
  // 渲染 `0 MB` —— 两套约定并存。这里钉住"未知 ⇒ `—`，绝不 `0 MB`"。
  // 覆盖 iOS 同症（`source != host` 但探测拿不到内存）：第 145 轮起档位是
  // `unknown`（不下结论、**不隐藏**），展示层再把未知值画成 `—`。
  testWidgets('★★★ B2：非宿主但内存/存储取不到 ⇒ 画 —，绝不画 0 MB', (tester) async {
    final bare = classifyDevice(_snap(ramGb: 0, freeGb: 0));
    expect(bare.ungatedHost, isFalse, reason: '前提：这是"手机但取不到值"，不是宿主');
    expect(bare.ramUnknown, isTrue, reason: '前提：RAM 事实确实缺失');
    expect(
      bare.tier,
      DeviceComputeTier.unknown,
      reason: 'iOS 同型：没有内存事实 ⇒ 不下结论（改动前是 unsupported）',
    );
    expect(bare.moduleVisible, isTrue, reason: '未判定不许隐藏（§2.0.6②）');
    await _pump(tester, profile: bare);

    final card = find.byKey(const Key('ai-device-capability-card'));
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.textContaining('0 MB')),
      findsNothing,
      reason: '未知内存/存储不许画成 0 MB（那是编了一个测量值）',
    );
    expect(
      find.descendant(of: card, matching: find.text('—')),
      findsWidgets,
      reason: '未知要按本卡既有约定画 —（SoC 空值一直是这样）',
    );
    // ★ 验收 1：档位行**不显示任何具体档位名**
    for (final label in [
      t.aiDeviceTierUnsupported,
      t.aiDeviceTierEntry,
      t.aiDeviceTierMainstream,
      t.aiDeviceTierHigh,
      t.aiDeviceTierFlagship,
    ]) {
      expect(
        find.descendant(of: card, matching: find.text(label)),
        findsNothing,
        reason: '内存未知 ⇒ 不许印任何档位结论「$label」',
      );
    }
  });

  // ── ★ B3：标签列必须容得下最长的标签 ──────────────────────────────────
  // 证据（缺陷文档 §1）：2560x1440 像素里「Free storage」折成两行，其余五个标签
  // 都是一行。原实现把标签列写死 `SizedBox(width: 76)`。用**英文** locale 复现
  // （中文标签「可用存储」短，测不出这个宽度问题）。
  testWidgets('★★★ B3：标签列容得下最长的英文标签「Free storage」，不折行', (tester) async {
    await _pump(
      tester,
      profile: classifyDevice(_snap(ramGb: 8)),
      locale: const Locale('en'),
    );
    final en = AppTextEn();
    final storage = tester.getSize(find.text(en.aiDeviceStorageLabel));
    final soc = tester.getSize(find.text(en.aiDeviceSocLabel));
    final tier = tester.getSize(find.text(en.aiDeviceTierLabel));
    expect(
      storage.height,
      soc.height,
      reason: '「${en.aiDeviceStorageLabel}」折成两行会让高度翻倍（其余标签都是一行）',
    );
    expect(storage.height, tier.height, reason: '所有标签行高应一致（都只有一行）');
    // ★ 更强的一条：渲染宽度必须 ≥ "不折行所需的宽度"。`Table` 的单元格会被撑到
    // 列宽，所以**不能**拿别的标签比宽度；跟"自然单行宽度"比才有判别力。
    final rp = tester.renderObject<RenderParagraph>(
      find.text(en.aiDeviceStorageLabel),
    );
    final natural = TextPainter(
      text: rp.text,
      textDirection: TextDirection.ltr,
    )..layout();
    expect(
      rp.size.width,
      greaterThanOrEqualTo(natural.width - 0.5),
      reason: '标签列宽 <「${en.aiDeviceStorageLabel}」单行宽度 ⇒ 会折行（这正是缺陷）',
    );
  });

  // ── ★ 第 145 轮：**未判定 ≠ 不够**（判"模型可用性"的文案与动作）────────────
  // §2.0.26 的病从"模块可见性"挪到了"模型可用性"：`unknown` 时模块可见了，但模型行
  // 原来仍会因 `tier.rank(0) < minTier.rank` / `totalRamBytes(0) < needRam` 显示
  // 「机器档位不足 / 内存不足（需 6 GB，本机 0 GB）」—— **没有数据却给结论**，
  // 而且那个 `0 GB` 就是 B2 同一个病。
  //
  // 两条守卫**必须同时**在（缺一条这套就是空的）：
  //   ① 已知事实不足 ⇒ 照旧给判词并挡住；
  //   ② `tier == unknown` ⇒ 一句判词都不许出现，只能说"无法验证"，且照样 fail-closed。
  testWidgets('★★★ 第145轮①反向：已知事实不足（2GB）⇒ 仍给判词 + 模块隐藏', (tester) async {
    // 纯逻辑面：**有**内存事实 ⇒ `ram`/`tier` blocker 真的在（不是"未判定"那一路）。
    final weak = classifyDevice(_snap(ramGb: 2, soc: 'MT6765', gl: 'Mali-G52'));
    expect(weak.tier, DeviceComputeTier.unsupported);
    expect(weak.hardwareUndetermined, isFalse, reason: '2GB 是"已知太少"，不是"没读到"');
    expect(weak.moduleVisible, isFalse);
    final fits = fitModelsFor(weak);
    expect(fits, isNotEmpty);
    for (final f in fits) {
      expect(f.eligible, isFalse, reason: '真弱机一个都不许放行');
      expect(f.blockers, contains(AiFitBlocker.moduleHidden));
    }
    // 界面面：整段隐藏 + 如实说明"不满足最低要求"
    await _pump(tester, profile: weak);
    expect(find.text(t.aiDeviceModuleHidden), findsOneWidget);
    expect(find.text(t.aiModelTiers), findsNothing);
  });

  testWidgets('★★★ 第145轮②反向：tier==unknown ⇒ 绝不出现判词，只能说"无法验证"', (tester) async {
    final bare = classifyDevice(_snap(ramGb: 0, freeGb: 0));
    expect(bare.tier, DeviceComputeTier.unknown);
    expect(bare.hardwareUndetermined, isTrue);
    expect(bare.moduleVisible, isTrue, reason: '未判定不许隐藏（§2.0.6②）');

    // ── 纯逻辑面 ────────────────────────────────────────────────────────
    final fits = fitModelsFor(bare);
    expect(fits, isNotEmpty);
    for (final f in fits) {
      expect(
        f.eligible,
        isFalse,
        reason: '★ 动作 fail-closed：无法验证是否适配 ⇒ 不许放行下载',
      );
      expect(
        f.blockers,
        isNot(contains(AiFitBlocker.ram)),
        reason: '★ 没有内存事实 ⇒ 连"差多少"都不许算（否则会画成"本机 0 GB"）',
      );
      expect(
        f.blockers,
        isNot(contains(AiFitBlocker.npu)),
        reason: '同理：没读到事实时不许断言"本机没有厂商 NPU"',
      );
    }

    // ── 界面面 ──────────────────────────────────────────────────────────
    final container = await _pump(tester, profile: bare);
    // ②a 一句判词都不许出现
    expect(find.textContaining(t.aiBlockedReasonTier), findsNothing);
    expect(find.textContaining('内存不足'), findsNothing);
    expect(find.textContaining('档位不足'), findsNothing);
    expect(
      find.text(t.aiBlockedModelsTitle(fits.length)),
      findsNothing,
      reason: '段标题也不许下"不适用"的判词 —— 我们是"没法验证"',
    );
    // ②b 必须如实说"无法验证"，且说明**为什么**
    expect(
      find.text(t.aiBlockedReasonUndetermined),
      findsWidgets,
      reason: '原因文案要说清是"拿不到本机硬件信息"，不是"本机不行"',
    );
    expect(find.text(t.aiBlockedModelsTitleUndetermined(fits.length)), findsOneWidget);

    // ── 动作 fail-closed，且错误理由是真实的那个 ────────────────────────
    final qwen = kOnDeviceModels.firstWhere((m) => m.id == 'qwen3-0.6b');
    final notifier = container.read(aiModelInstallProvider.notifier);
    final ok = await tester.runAsync(() => notifier.install(qwen));
    expect(ok, isFalse, reason: '未判定 ⇒ 不发起下载');
    final state = container.read(aiModelInstallProvider);
    expect(state.busy, isFalse);
    expect(
      state.error,
      t.aiDeviceModelUnverifiable,
      reason: '★ 拦下载的理由必须是"无法验证是否适配"，不是"本机硬件不满足要求"',
    );
    expect(state.error, isNot(t.aiDeviceModelBlocked));
  });
}
