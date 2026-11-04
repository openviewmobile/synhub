// **token 用量与费用估算**（数据层 + 记录落库），全部离线。
//
// 要点：这只是**本地估算**，不是服务端账单——单价来自手工维护的价目表，
// 所以测试同时盯住"边界如实说明"：缺 usage 要估算并标注、负数要清掉、
// 单价未知要单独计数而不是算成 0 元。
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/core/settings/cloud_key_store.dart';
import 'package:synhub/src/data/ai/cloud_pricing.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/ai/cloud_settings.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider, chatStoreProvider;

ProviderContainer _container(ChatDatabase db) => ProviderContainer(
  overrides: [
    chatDatabaseProvider.overrideWithValue(db),
    cloudKeyStoreProvider.overrideWithValue(MemoryCloudKeyStore()),
  ],
);

CloudUsageRecord _rec({
  required int atMs,
  required String model,
  int prompt = 0,
  int completion = 0,
  int total = 0,
  double cost = 0,
  bool priced = true,
  bool estimated = false,
  bool ok = true,
}) => CloudUsageRecord(
  atMs: atMs,
  usage: CloudTokenUsage(
    promptTokens: prompt,
    completionTokens: completion,
    totalTokens: total == 0 ? prompt + completion : total,
    estimated: estimated,
  ),
  model: model,
  costUsd: cost,
  priced: priced,
  ok: ok,
);

void main() {
  group('usage 解析（三种协议 + 边界）', () {
    test('OpenAI：prompt/completion/total 与推理 tokens', () {
      final u = cloudUsageFromJson({
        'prompt_tokens': 120,
        'completion_tokens': 340,
        'total_tokens': 460,
        'completion_tokens_details': {'reasoning_tokens': 300},
      });
      expect(u.promptTokens, 120);
      expect(u.completionTokens, 340);
      expect(u.totalTokens, 460);
      expect(u.reasoningTokens, 300);
      expect(u.estimated, isFalse);
    });

    test('Claude：input/output tokens', () {
      final u = cloudUsageFromJson({'input_tokens': 50, 'output_tokens': 70});
      expect(u.promptTokens, 50);
      expect(u.completionTokens, 70);
      expect(u.totalTokens, 120);
    });

    test(
      'Gemini：promptTokenCount/candidatesTokenCount/totalTokenCount/thoughtsTokenCount',
      () {
        final u = cloudUsageFromJson({
          'promptTokenCount': 8,
          'candidatesTokenCount': 21,
          'totalTokenCount': 40,
          'thoughtsTokenCount': 11,
        });
        expect(u.promptTokens, 8);
        expect(u.completionTokens, 21);
        expect(u.totalTokens, 40);
        expect(u.reasoningTokens, 11);
      },
    );

    test('缺字段 / 空对象：干净地当成 0（不抛）', () {
      expect(cloudUsageFromJson(null).isEmpty, isTrue);
      expect(cloudUsageFromJson(const {}).isEmpty, isTrue);
      expect(cloudUsageFromJson('不是 map').isEmpty, isTrue);
      final u = cloudUsageFromJson({'prompt_tokens': 5});
      expect(u.totalTokens, 5);
    });

    test('负数被清掉；total 小于 prompt+completion 时按后者兜底', () {
      final u = cloudUsageFromJson({
        'prompt_tokens': 100,
        'completion_tokens': -20,
        'total_tokens': -5,
      }).sanitized();
      expect(u.promptTokens, 100);
      expect(u.completionTokens, 0);
      expect(u.totalTokens, 100);
    });

    test('字符串数字也认（有的网关把 token 给成字符串）', () {
      final u = cloudUsageFromJson({
        'prompt_tokens': '12',
        'completion_tokens': '3',
        'total_tokens': '15',
      });
      expect(u.totalTokens, 15);
    });

    test('缺 usage 时按文本估算：中文≈1 字 1 token、英文≈4 字符 1 token', () {
      final u = estimateUsageFromText(
        promptText: '你好世界', // 4 个汉字
        completionText: 'abcdefgh', // 8 字符 → 2
      );
      expect(u.promptTokens, 4);
      expect(u.completionTokens, 2);
      expect(u.estimated, isTrue);
      expect(u.totalTokens, 6);
    });

    test('估算也把思考字符算进去', () {
      final u = estimateUsageFromText(
        promptText: '',
        completionText: 'ok',
        reasoningChars: 7,
      );
      expect(u.completionTokens, 1 + 7);
    });
  });

  group('价目表与费用估算', () {
    test('最长子串匹配：gpt-4o-mini 不会被 gpt-4o 抢走', () {
      expect(cloudPriceFor('gpt-4o-mini')?.match, 'gpt-4o-mini');
      expect(cloudPriceFor('GPT-4O')?.match, 'gpt-4o');
      expect(cloudPriceFor('gpt-4o-2024-08-06')?.match, 'gpt-4o');
      expect(cloudPriceFor('deepseek-reasoner')?.match, 'deepseek-reasoner');
      expect(cloudPriceFor('who-knows'), isNull);
      expect(cloudPriceFor(''), isNull);
    });

    test('费用 = 输入/输出分别计（1M token 单价）', () {
      final q = estimateCloudCost(
        model: 'gpt-4o-mini',
        baseUrl: 'https://api.openai.com/v1',
        usage: const CloudTokenUsage(
          promptTokens: 1000000,
          completionTokens: 1000000,
          totalTokens: 2000000,
        ),
      );
      expect(q.priced, isTrue);
      expect(q.usd, closeTo(0.15 + 0.60, 1e-9));
    });

    test('本地/私网端点：不估算费用（自家机器不按 token 计费）', () {
      for (final url in [
        'http://localhost:11434/v1',
        'http://127.0.0.1:8000/v1',
        'http://192.168.1.10:1234/v1',
        'http://10.0.0.7:8080/v1',
        'http://172.20.3.4:8000/v1',
      ]) {
        final q = estimateCloudCost(
          model: 'gpt-4o',
          baseUrl: url,
          usage: const CloudTokenUsage(promptTokens: 1000, totalTokens: 1000),
        );
        expect(q.priced, isTrue, reason: url);
        expect(q.usd, 0, reason: url);
      }
      expect(cloudIsLocalEndpoint('https://api.openai.com/v1'), isFalse);
      expect(cloudIsLocalEndpoint('http://172.40.0.1/v1'), isFalse);
    });

    test('未知模型：priced=false（界面显示"单价未知"，不能当 0 元混进合计）', () {
      final q = estimateCloudCost(
        model: 'some-new-model',
        baseUrl: 'https://api.example.com/v1',
        usage: const CloudTokenUsage(promptTokens: 5000, totalTokens: 5000),
      );
      expect(q.priced, isFalse);
      expect(q.usd, 0);
    });

    test('负数用量不会算出负费用', () {
      final q = estimateCloudCost(
        model: 'gpt-4o',
        baseUrl: 'https://api.openai.com/v1',
        usage: const CloudTokenUsage(
          promptTokens: -1000,
          completionTokens: -1000,
          totalTokens: -2000,
        ),
      );
      expect(q.usd, 0);
    });

    test('价目表带更新月份，界面上要标出来', () {
      expect(kCloudPricingUpdatedAt, isNotEmpty);
      expect(kCloudModelPrices, isNotEmpty);
    });
  });

  group('汇总（按模型 / 按天 / 时间窗）', () {
    final day1 = DateTime(2026, 9, 1, 10).millisecondsSinceEpoch;
    final day2 = DateTime(2026, 9, 2, 10).millisecondsSinceEpoch;

    test('总量、分组、排序都对', () {
      final s = summarizeCloudUsage([
        _rec(
          atMs: day1,
          model: 'gpt-4o',
          prompt: 100,
          completion: 50,
          cost: 0.01,
        ),
        _rec(
          atMs: day1,
          model: 'gpt-4o',
          prompt: 200,
          completion: 60,
          cost: 0.02,
        ),
        _rec(
          atMs: day2,
          model: 'gpt-4o-mini',
          prompt: 300,
          completion: 70,
          cost: 0.005,
        ),
      ]);
      expect(s.overall.calls, 3);
      expect(s.overall.promptTokens, 600);
      expect(s.overall.completionTokens, 180);
      expect(s.overall.totalTokens, 780);
      expect(s.overall.costUsd, closeTo(0.035, 1e-9));
      // 按模型：费用高的在前
      expect(s.byModel.map((b) => b.key).toList(), ['gpt-4o', 'gpt-4o-mini']);
      expect(s.byModel.first.totals.calls, 2);
      // 按天：新到旧
      expect(s.byDay.map((b) => b.key).toList(), ['2026-09-02', '2026-09-01']);
    });

    test('时间窗过滤：7 天视图不会算进更早的调用', () {
      final s = summarizeCloudUsage([
        _rec(atMs: day1, model: 'gpt-4o', prompt: 1000),
        _rec(atMs: day2, model: 'gpt-4o', prompt: 2000),
      ], sinceMs: day2);
      expect(s.overall.calls, 1);
      expect(s.overall.promptTokens, 2000);
    });

    test('按模型过滤', () {
      final s = summarizeCloudUsage([
        _rec(atMs: day1, model: 'a', prompt: 10),
        _rec(atMs: day1, model: 'b', prompt: 20),
      ], model: 'b');
      expect(s.overall.promptTokens, 20);
      expect(s.byModel.single.key, 'b');
    });

    test('估算次数与"单价未知"次数分开统计（不藏进合计里）', () {
      final s = summarizeCloudUsage([
        _rec(atMs: day1, model: 'x', prompt: 10, estimated: true),
        _rec(atMs: day1, model: 'y', prompt: 10, priced: false),
        _rec(atMs: day1, model: 'z', prompt: 10),
      ]);
      expect(s.overall.calls, 3);
      expect(s.overall.estimatedCalls, 1);
      expect(s.overall.unpricedCalls, 1);
    });

    test('超预算的一次调用（服务端返回的 completion 比本地 maxTokens 大）照样计入', () {
      // 推理模型的思考也计费：本地给 1024，服务端算出 6000
      final s = summarizeCloudUsage([
        _rec(
          atMs: day1,
          model: 'deepseek-reasoner',
          prompt: 800,
          completion: 6000,
          cost: 0.02,
          ok: false, // 这次"没有正文"，但确实花了 token
        ),
      ]);
      expect(s.overall.calls, 1);
      expect(s.overall.completionTokens, 6000);
      expect(s.overall.costUsd, closeTo(0.02, 1e-9));
    });

    test('记录里的负 token / 负费用会被清掉，不会把合计做低', () {
      final s = summarizeCloudUsage([
        CloudUsageRecord(
          atMs: day1,
          usage: const CloudTokenUsage(
            promptTokens: -500,
            completionTokens: 100,
            totalTokens: -400,
          ),
          model: 'gpt-4o',
          costUsd: -1,
        ),
      ]);
      expect(s.overall.promptTokens, 0);
      expect(s.overall.completionTokens, 100);
      expect(s.overall.totalTokens, 100);
      expect(s.overall.costUsd, 0);
    });

    test('模型名为空时分组用占位符，不会崩', () {
      final s = summarizeCloudUsage([_rec(atMs: day1, model: '', prompt: 1)]);
      expect(s.byModel.single.key, '—');
    });

    test('空记录：全 0，不抛', () {
      final s = summarizeCloudUsage(const []);
      expect(s.overall.calls, 0);
      expect(s.byModel, isEmpty);
      expect(s.byDay, isEmpty);
    });

    test('上限 500：超出丢最旧的', () {
      var list = <CloudUsageRecord>[];
      for (var i = 0; i < 520; i++) {
        list = appendCloudUsage(
          list,
          _rec(atMs: day1 + i, model: 'm', prompt: 1),
        );
      }
      expect(list, hasLength(kCloudUsageMaxRecords));
      expect(list.first.atMs, day1 + 20);
      expect(list.last.atMs, day1 + 519);
    });
  });

  group('JSON 编解码（落库格式）', () {
    test('往返一致；坏数据不炸整份统计', () {
      final list = [
        _rec(atMs: 1, model: 'gpt-4o', prompt: 3, completion: 4, cost: 0.01),
      ];
      final back = decodeCloudUsage(encodeCloudUsage(list));
      expect(back, hasLength(1));
      expect(back.first.usage.totalTokens, 7);
      expect(back.first.costUsd, closeTo(0.01, 1e-9));

      expect(decodeCloudUsage(null), isEmpty);
      expect(decodeCloudUsage(''), isEmpty);
      expect(decodeCloudUsage('{不是数组'), isEmpty);
      expect(decodeCloudUsage('[1,2,3]'), isEmpty);
      // 数组里混一条坏的：坏的那条被跳过，好的留下
      final mixed = decodeCloudUsage(
        '[{"at":5,"usage":{"prompt_tokens":2},"model":"m"},"垃圾"]',
      );
      expect(mixed, hasLength(1));
      expect(mixed.first.usage.promptTokens, 2);
    });
  });

  group('调用记录落库（接口层）', () {
    test('recordUsage 写进 KV；冷启动读回；clearUsage 清空', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);

      await n.recordUsage(
        CloudUsageRecord(
          atMs: 1000,
          usage: const CloudTokenUsage(
            promptTokens: 10,
            completionTokens: 5,
            totalTokens: 15,
          ),
          model: 'gpt-4o-mini',
          providerId: 'openai',
          costUsd: 0.001,
          priced: true,
        ),
      );
      await n.recordUsage(
        CloudUsageRecord(
          atMs: 2000,
          usage: const CloudTokenUsage(promptTokens: 20, totalTokens: 20),
          model: 'deepseek-reasoner',
          providerId: 'deepseek',
          priced: false,
        ),
      );

      // 直接读 KV，确认真的落盘了（不是只在内存里）
      final raw = await SettingsService(
        c.read(chatStoreProvider),
      ).aiCloudUsage();
      expect(raw, contains('gpt-4o-mini'));
      expect(raw, isNot(contains('sk-')));

      final c2 = _container(db);
      addTearDown(c2.dispose);
      await c2.read(cloudSettingsProvider.notifier).preload();
      final s = c2.read(cloudSettingsProvider);
      expect(s.usage, hasLength(2));
      final sum = s.usageSummary;
      expect(sum.overall.calls, 2);
      expect(sum.overall.totalTokens, 35);
      expect(sum.overall.costUsd, closeTo(0.001, 1e-9));
      expect(sum.overall.unpricedCalls, 1);

      await c2.read(cloudSettingsProvider.notifier).clearUsage();
      expect(c2.read(cloudSettingsProvider).usage, isEmpty);
      expect(
        await SettingsService(c2.read(chatStoreProvider)).aiCloudUsage(),
        anyOf(isNull, isEmpty),
      );
    });

    test('测试连接也会记一笔（kind=test），费用按模型估算', () async {
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = _container(db);
      addTearDown(c.dispose);
      final n = c.read(cloudSettingsProvider.notifier);
      await n.selectProvider('openai');
      await n.setModel('gpt-4o-mini');
      await n.setKey('k');
      // 假传输：非流式回 "ok"（不发真网络）
      final before = c.read(cloudSettingsProvider).usage.length;
      await n.recordUsage(
        CloudUsageRecord(
          atMs: DateTime.now().millisecondsSinceEpoch,
          usage: estimateUsageFromText(promptText: '你好', completionText: 'ok'),
          model: 'gpt-4o-mini',
          providerId: 'openai',
          kind: 'test',
          costUsd: 0.000001,
          priced: true,
        ),
      );
      final s = c.read(cloudSettingsProvider);
      expect(s.usage.length, before + 1);
      expect(s.usage.last.kind, 'test');
      expect(s.usage.last.usage.estimated, isTrue);
    });
  });
}
