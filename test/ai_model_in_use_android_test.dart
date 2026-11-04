// D6（r121 安卓逐屏审计 `ai_11_ond.png` / `ai_21_s.png`）：
// 页首写「还没有下载模型」，`Qwen3 0.6B` 那一行却写 `In use` —— **同一个屏幕上两个结论打架**。
//
// 语义裁定（只读取证，第 134 轮）：
//   * 页首**是对的**：`aiReadinessNeedsModel` / `aiEngineReadyNoModel` 由
//     `FlutterGemma.listInstalledModels()` 为空驱动 ⇒ 说的是"文件在不在这台机器上"；
//   * `In use` **是错的**：它只判 `choice.id == m.id`（"档位指针指向谁"），
//     而 `aiModelChoiceProvider` 默认指向推荐档（`Qwen3 0.6B`）且**删模型时从不清空**
//     ⇒ 文件删了，指针还指着它 ⇒ 两个语义被一个词混在一起。
//
// 所以这里钉两件事（一个正向、一个反向，缺一不可）：
//   ① 正向：装好且选中 ⇒ `In use` **必须**在（防"把徽标整个关掉"）；
//   ② 反向：没装 / 删掉之后 ⇒ `In use` **一处都不许有**（D6 的原始矛盾）；
//   ③ 根因：删掉**当前档位**那份模型 ⇒ 选择状态被清空（不是只遮显示层）。
//
// 测试宿主不是手机（`aiPlatformSupported` 为假），所以注入合成算力快照 +
// 假引擎（`AiAutoEngine.gemma` 是注入点），并直接覆盖 `aiInstalledModelsProvider`
// ——它是"已装清单"的唯一来源，覆盖它等价于"这台机器上确实装了这些文件"。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/device/device_capability.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/ai/ai_model_page.dart';
import 'package:synhub/src/features/ai/ai_providers.dart';
import 'package:synhub/src/features/ai/cloud_settings.dart' show AiTier;
import 'package:synhub/src/features/ai/llm_engine.dart';
import 'package:synhub/src/features/ai/on_device_ai.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/l10n/gen/app_localizations.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';

/// 审计那台上的两个档位（`ai_11_ond.png`）：推荐档 Qwen3 0.6B + 最小的 LFM。
final AiModelInfo _qwen = kOnDeviceModels.firstWhere((m) => m.id == 'qwen3-0.6b');
final AiModelInfo _lfm = kOnDeviceModels.firstWhere(
  (m) => m.id == 'lfm25-230m-int4',
);

/// 假引擎：只实现"列已装文件 / 卸载"两件事，够驱动 `remove()` 这条真实路径。
class _FakeGemma extends GemmaLlmEngine {
  _FakeGemma(this.files);

  final List<String> files;

  @override
  Future<List<String>> installedFiles() async => List.of(files);

  @override
  Future<void> uninstall(AiModelInfo info) async {
    files.removeWhere((f) => f == info.fileName || f == info.id);
  }

  @override
  Future<void> uninstallFile(String fileName) async {
    files.removeWhere((f) => f == fileName);
  }
}

class _FakeAutoEngine extends AiAutoEngine {
  _FakeAutoEngine(this._g);

  final _FakeGemma _g;

  @override
  GemmaLlmEngine get gemma => _g;
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required List<String> installed,
  Locale locale = const Locale('zh'),
  _FakeAutoEngine? engine,
}) async {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  final db = ChatDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final fake = engine ?? _FakeAutoEngine(_FakeGemma(installed));
  final container = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      deviceCapabilityProvider.overrideWith(
        (ref) async => classifyDevice(
          DeviceCapabilitySnapshot(
            socModel: 'SM8650',
            hardware: 'sm8650',
            model: 'test-device',
            brand: 'test',
            sdkInt: 34,
            abis: const ['arm64-v8a'],
            cpuCores: 8,
            totalRamBytes: 8 * 1024 * 1024 * 1024,
            lowRamDevice: false,
            freeStorageBytes: 64 * 1024 * 1024 * 1024,
            glRenderer: 'Adreno (TM) 740',
            openclLibrary: true,
            nnapiFeature: true,
            source: 'platform',
          ),
        ),
      ),
      // 宿主上 `aiPlatformSupported` 为假 ⇒ 原 provider 直接回空表。
      // 这里保留同一语义（"已装清单 = 引擎报的文件"），只是不套平台门。
      aiInstalledModelsProvider.overrideWith(
        (ref) => ref.watch(onDeviceEngineProvider).gemma.installedFiles(),
      ),
      onDeviceEngineProvider.overrideWithValue(fake),
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

/// 某一行上的"在使用中 / 设为当前"按钮（可观测 key，见 `_modelCard`）。
Finder _choiceButton(AiModelInfo m) =>
    find.byKey(Key('ai-model-choice-${m.id}'));

void main() {
  final t = AppTextZh();

  testWidgets('D6 正向：已装 + 已选中 ⇒ 该行必须写"在使用中"，别的行写"设为当前"', (
    tester,
  ) async {
    final container = await _pump(tester, installed: [_qwen.fileName]);
    await tester.runAsync(
      () => container.read(aiModelChoiceProvider.notifier).select(_qwen),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.descendant(of: _choiceButton(_qwen), matching: find.text(t.aiInUse)),
      findsOneWidget,
      reason: '装好且选中的那一行必须写"在使用中"（这正是 §2.0.29 的反向：'
          '不许为了让 D6 转绿把徽标整个关掉）',
    );
    expect(
      find.descendant(
        of: _choiceButton(_lfm),
        matching: find.text(t.aiSetCurrent),
      ),
      findsOneWidget,
      reason: '没选中的那一行写"设为当前"',
    );
    expect(find.text(t.aiInUse), findsOneWidget, reason: '全局只有一行在使用中');
  });

  testWidgets('D6 反向：模型没装（页首说"还没下载"）⇒ 任何一行都不许写"在使用中"', (
    tester,
  ) async {
    // 这正是审计截图那一幕：文件列表为空（页首因此说"还没有下载模型"），
    // 而档位指针仍指向默认推荐的 Qwen3 ⇒ 修复前行内写 `In use`。
    final container = await _pump(tester, installed: const []);
    await tester.runAsync(
      () => container.read(aiModelChoiceProvider.notifier).select(_qwen),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      container.read(aiInstalledModelsProvider).value ?? const [],
      isEmpty,
      reason: '前提：这台机器上一份模型都没有（页首据此说"还没有下载模型"）',
    );
    expect(
      find.text(t.aiInUse),
      findsNothing,
      reason: '★ D6 原缺陷：没有装任何模型时不许出现"在使用中"'
          '（页首说"还没下载"，行内说"在用"就是自相矛盾）',
    );
    expect(
      find.descendant(
        of: _choiceButton(_qwen),
        matching: find.text(t.aiSetCurrent),
      ),
      findsOneWidget,
      reason: '★ 反向验证的另一半：这一行**必须还在**，只是文案回到"设为当前"'
          '（不是把一个行/按钮整个删掉来"消除矛盾"）',
    );
  });

  testWidgets('D6 根因：删掉当前选中的那份模型 ⇒ 选择状态被清空，行内不再"在使用中"', (
    tester,
  ) async {
    final gemma = _FakeGemma([_qwen.fileName]);
    final engine = _FakeAutoEngine(gemma);
    final container = await _pump(
      tester,
      installed: [_qwen.fileName],
      engine: engine,
    );
    await tester.runAsync(
      () => container.read(aiModelChoiceProvider.notifier).select(_qwen),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(container.read(aiModelChoiceProvider)?.id, _qwen.id, reason: '前提：它被选中');

    // 走**真实的**删除路径（`remove()` → 引擎卸载 → 作废选择）
    await tester.runAsync(
      () => container.read(aiModelInstallProvider.notifier).remove(_qwen),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(gemma.files, isEmpty, reason: '前提：文件真的被卸载了');
    expect(
      container.read(aiModelChoiceProvider),
      isNull,
      reason: '★ 根因：删掉的就是当前档位 ⇒ 选择必须一起作废'
          '（`ai_model_id` 是持久化的，不清掉下次启动还会指着一个不存在的文件）',
    );
    expect(
      find.text(t.aiInUse),
      findsNothing,
      reason: '★ 删完之后界面上一处"在使用中"都不能剩',
    );
    expect(
      find.descendant(
        of: _choiceButton(_qwen),
        matching: find.text(t.aiSetCurrent),
      ),
      findsOneWidget,
      reason: '★ 反向验证的另一半：那一行还在，只是回到"设为当前"',
    );
  });

  testWidgets('D6 根因反向：删掉的是**别的**模型 ⇒ 当前选择不许被顺手清掉', (
    tester,
  ) async {
    final engine = _FakeAutoEngine(
      _FakeGemma([_qwen.fileName, _lfm.fileName]),
    );
    final container = await _pump(
      tester,
      installed: [_qwen.fileName, _lfm.fileName],
      engine: engine,
    );
    await tester.runAsync(
      () => container.read(aiModelChoiceProvider.notifier).select(_qwen),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.runAsync(
      () => container.read(aiModelInstallProvider.notifier).remove(_lfm),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      container.read(aiModelChoiceProvider)?.id,
      _qwen.id,
      reason: '★ 反向：删别的模型不许把当前选择也清掉（否则"删一个动全身"）',
    );
    expect(
      find.descendant(of: _choiceButton(_qwen), matching: find.text(t.aiInUse)),
      findsOneWidget,
      reason: '★ 反向：Qwen3 还装着、还是当前档 ⇒ 必须仍然写"在使用中"',
    );
  });
}
