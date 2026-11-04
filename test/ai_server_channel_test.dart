// 任务 1 用例：**服务端 AI（NAS AI Console）是可选项，不是模块开关**。
//
// 覆盖三条用例：
//   ① 缺 `SYNO.AI.Completion` → 服务端 AI UI 隐藏、端侧 / 云端 AI 仍可用；
//   ② 有 → 服务端 AI UI 出现；
//   ③ 现网（真机 977 API 含 34 个 `SYNO.AI.*`）→ 行为不变（UI 出现）。
//
// 判定链：`kServiceRegistry[ai].optionalApis` → `classifyApiTable`（partial，
// 不隐藏）→ `ServiceAvailabilitySnapshot.hasApi` → `ServerAiChannel` →
// `ai-server-channel` 卡片显隐。AI 模块本身**永不**因服务端 AI 缺失而隐藏。
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/ai/ai_model_page.dart';
import 'package:synhub/src/features/ai/server_ai_channel.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;

/// 构造一个"检测过"的快照：`ai` 的状态由能力表算出，其余服务给 available。
ServiceAvailabilitySnapshot _snapshot(Set<String> apis) =>
    ServiceAvailabilitySnapshot(
      states: {
        for (final s in StationService.values)
          s: s == StationService.ai
              ? classifyApiTable(kServiceRegistry[StationService.ai]!, apis)
              : AvailabilityState.available,
      },
      apis: apis,
      checkedAt: DateTime(2026, 9, 21),
    );

const _allServerAi = {
  kAiCompletionApi,
  kAiThreadApi,
  kAiConfigApi,
  kAiMetricsApi,
};

Future<void> _pumpPage(WidgetTester tester, ServerAiChannel channel) async {
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  final db = ChatDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      serverAiChannelProvider.overrideWithValue(channel),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), home: const AiModelPage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('ServerAiChannel（纯判定）', () {
    test('缺 Completion → 服务端通道关闭，但 ai 服务仍不隐藏（partial）', () {
      final snap = _snapshot({kAiThreadApi, kAiConfigApi, kAiMetricsApi});
      expect(snap.stateOf(StationService.ai), AvailabilityState.partial);
      expect(hidesModule(snap.stateOf(StationService.ai)), isFalse);

      final channel = ServerAiChannel.of(snap);
      expect(channel.generation, isFalse, reason: '缺 Completion → 服务端选项隐藏');
      expect(channel.any, isTrue, reason: '其它服务端能力位仍在');
    });

    test('有 Completion → 服务端通道打开', () {
      final channel = ServerAiChannel.of(_snapshot({..._allServerAi}));
      expect(channel.generation, isTrue);
      expect(channel.thread, isTrue);
      expect(channel.config, isTrue);
      expect(channel.metrics, isTrue);
      expect(channel.detectedApis, hasLength(4));
    });

    test('还没检测过（apis 为空）→ fail-open，不因不确定隐藏服务端选项', () {
      final snap = ServiceAvailabilitySnapshot(
        states: {
          for (final s in StationService.values) s: AvailabilityState.unknown,
        },
      );
      expect(ServerAiChannel.of(snap).generation, isTrue);
      expect(snap.apiPresent(kFinderFileIndexingSearchApi), isTrue);
    });

    test('现网能力表（test/fixtures/api_table.json）：34 个 SYNO.AI.*，行为不变', () {
      final raw = File('test/fixtures/api_table.json').readAsStringSync();
      final table = (jsonDecode(raw) as Map).cast<String, dynamic>();
      final aiApis = table.keys.where((k) => k.startsWith('SYNO.AI.')).toSet();
      // 2026-09-23 重新只读抓取：1047（旧快照 977 是**不完整的**
      // —— 它连 `SYNO.AudioStation.*`(27) / `SYNO.Personal.*`(17) 都没收进来。
      // 新旧是严格超集关系：0 条流失、+70 条新增，所以这不是"放宽断言"。）
      expect(table.keys, hasLength(1047), reason: '真机 SYNO.API.Info 全量');
      expect(aiApis, hasLength(34), reason: '真机 34 个 SYNO.AI.*');
      for (final api in _allServerAi) {
        expect(aiApis, contains(api));
      }
      final snap = _snapshot(table.keys.toSet());
      expect(snap.stateOf(StationService.ai), AvailabilityState.available);
      expect(ServerAiChannel.of(snap).generation, isTrue, reason: '现网行为不变');
    });
  });

  group('AI 服务设置页的显隐（ai-server-channel）', () {
    testWidgets('① 缺 Completion → 服务端 AI UI 隐藏，端侧 / 云端 AI 仍在', (tester) async {
      await _pumpPage(
        tester,
        const ServerAiChannel(
          completion: false,
          thread: false,
          config: false,
          metrics: false,
        ),
      );
      expect(find.byKey(const Key('ai-server-channel')), findsNothing);
      // 模块本身没被隐藏：档位选择（云端 / 端侧 / 内置摘要）照常渲染。
      expect(find.text('云端大模型'), findsWidgets);
      expect(find.text('端侧模型'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('② 有 Completion → 服务端 AI UI 出现', (tester) async {
      await _pumpPage(
        tester,
        const ServerAiChannel(
          completion: true,
          thread: true,
          config: false,
          metrics: false,
        ),
      );
      expect(find.byKey(const Key('ai-server-channel')), findsOneWidget);
      // ★ r342 D46：段标题不再是硬编码英文，跟着 ARB 走
      expect(find.text('NAS 端 AI 通道'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
