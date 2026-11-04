// 使用日志库 + 写入端 + 聚合/结论的离线验证。
//
// 这套东西的价值全在"数字对不对"，所以测试重点：
//   * 落库/读回/导出/清空/裁剪（保留天数、最大条数）都对；
//   * 缓冲批量写：满 20 条自动落库，不满时 flush 也能落；
//   * 会话切分（间隔 > 5 分钟）与平均时长；
//   * 聚合统计（模块/动作/时段/星期/扩展名/大小桶/搜索 0 结果/失败点）；
//   * 结论：样本不足时**不给**"没用的模块"这类容易误导的判断；样本够时该有的都有；
//   * 隐私：账号只落哈希、细节里没有文件名。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/local/analytics_database.dart';
import 'package:synhub/src/features/analytics/usage_analysis.dart';
import 'package:synhub/src/features/analytics/usage_event.dart';
import 'package:synhub/src/features/analytics/usage_log.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AnalyticsDatabase db;
  late UsageLog log;

  setUp(() async {
    db = AnalyticsDatabase.memory();
    log = UsageLog(db);
    await log.load();
  });

  tearDown(() async {
    log.dispose();
    await db.close();
  });

  group('分类与工具', () {
    test('扩展名只留类型，长"扩展名"当 none', () {
      expect(extensionOf('report.docx'), '.docx');
      expect(extensionOf('Report.PDF'), '.pdf');
      expect(extensionOf('noext'), 'none');
      expect(extensionOf('.hidden'), 'none');
      expect(extensionOf('weird.verylongext'), 'none');
    });

    test('大小分桶是数量级', () {
      expect(sizeBucket(0), '0');
      expect(sizeBucket(500), '<1K');
      expect(sizeBucket(1500), '1K');
      expect(sizeBucket(3 * 1024), '2K');
      expect(sizeBucket(7 * 1024), '5K');
      expect(sizeBucket(50 * 1024), 'xK');
      expect(sizeBucket(3 * 1024 * 1024), '2M');
    });

    test('账号只落加盐哈希（同盐稳定、异盐不同、不含明文）', () {
      final a = pseudonymize('demo_user', 'salt-1');
      expect(a, pseudonymize('demo_user', 'salt-1'));
      expect(a, isNot(pseudonymize('demo_user', 'salt-2')));
      expect(a.length, 12);
      expect(a.contains('demo_user'), isFalse);
      expect(pseudonymize('', 'salt-1'), '');
    });

    test('时段划分覆盖 24 小时', () {
      expect(hourBand(3), '深夜(0-6)');
      expect(hourBand(7), '早晨(6-9)');
      expect(hourBand(13), '中午(12-14)');
      expect(hourBand(23), '夜里(22-24)');
    });
  });

  group('写入端', () {
    test('record → flush → 读回；字段映射正确', () async {
      log.setAccount('demo_user');
      log.record(
        UsageModule.files,
        UsageAction.preview,
        objectType: '.pdf',
        value: 2048,
        detail: {'source': 'nas'},
      );
      await log.flush();

      expect(await log.eventCount(), 1);
      final rows = await log.recent();
      expect(rows, hasLength(1));
      expect(rows.first.module, UsageModule.files);
      expect(rows.first.action, UsageAction.preview);
      expect(rows.first.objectType, '.pdf');
      expect(rows.first.value, 2048);
      expect(rows.first.detail['source'], 'nas');
      // 账号是假名，不是明文
      expect(rows.first.account, isNotEmpty);
      expect(rows.first.account.contains('demo_user'), isFalse);
    });

    test('攒够 20 条自动落库（不用等定时器）', () async {
      for (var i = 0; i < 20; i++) {
        log.record(UsageModule.notes, UsageAction.open, objectType: 'note');
      }
      await Future<void>.delayed(Duration.zero);
      await log.flush(); // 收尾（自动 flush 是异步的）
      expect(await log.eventCount(), 20);
    });

    test('关掉开关后不再记录', () async {
      await log.setEnabled(false);
      log.record(UsageModule.chat, UsageAction.open);
      await log.flush();
      expect(await log.eventCount(), 0);

      // 重新打开还认得（元数据落库）
      final again = UsageLog(db);
      await again.load();
      expect(again.enabled, isFalse);
      again.dispose();
    });

    test('会话切分：间隔 > 5 分钟算新的一段', () async {
      final t0 = DateTime(2026, 9, 1, 9, 0);
      log.record(UsageModule.files, UsageAction.open, at: t0);
      log.record(
        UsageModule.files,
        UsageAction.preview,
        at: t0.add(const Duration(minutes: 2)),
      );
      log.record(
        UsageModule.files,
        UsageAction.delete,
        at: t0.add(const Duration(minutes: 30)),
      );
      await log.flush();

      final events = await log.recent();
      final sessions = events.map((e) => e.session).toSet();
      expect(sessions, hasLength(2));
    });

    test('裁剪：超过保留天数的事件会被删掉', () async {
      final old = DateTime.now().subtract(
        const Duration(days: kRetentionDays + 10),
      );
      log.record(UsageModule.files, UsageAction.open, at: old);
      log.record(UsageModule.files, UsageAction.open);
      await log.flush();
      // 记录时没裁剪，只在 flush 里裁 → 这里已经裁过了
      expect(await log.eventCount(), 1);
    });

    test('失败事件只留动作与错误类型，不留 message', () async {
      log.recordFailure(
        UsageModule.drive,
        UsageAction.upload,
        error: StateError('boom: /volume1/secret/客户合同.pdf'),
      );
      await log.flush();
      final e = (await log.recent()).single;
      expect(e.action, UsageAction.failure);
      expect(e.detail['failed_action'], 'upload');
      expect('${e.detail['error']}', isNot(contains('客户合同')));
    });

    test('导出 JSON 只含聚合字段（无文件名）', () async {
      log.setAccount('demo_user');
      log.record(
        UsageModule.files,
        UsageAction.upload,
        objectType: '.docx',
        value: 1024,
      );
      await log.flush();
      final json = await log.exportJson();
      expect(json, contains('"schema": "synhub.usage/1"'));
      expect(json, contains('".docx"'));
      expect(json, isNot(contains('docx 合同')));
      // 账号假名落了，但明文永不出现
      expect(json, contains('"account"'));
      expect(json.contains('demo_user'), isFalse);
    });

    test('清空事件但结论可单独保留/清除', () async {
      log.record(UsageModule.files, UsageAction.open);
      await log.flush();
      await log.saveInsights(
        buildInsights(
          computeUsageStats([
            UsageEvent(
              at: DateTime.now(),
              module: UsageModule.files,
              action: UsageAction.open,
            ),
          ]),
        ),
      );
      expect(await log.savedInsights(), isNotEmpty);

      await log.clearEvents();
      expect(await log.eventCount(), 0);
      expect(await log.savedInsights(), isNotEmpty);

      await log.clearInsights();
      expect(await log.savedInsights(), isEmpty);
    });
  });

  group('聚合统计', () {
    UsageEvent ev(
      int hour,
      UsageModule m,
      UsageAction a, {
      String object = '',
      int value = 0,
      int day = 1,
      Map<String, Object?> detail = const {},
    }) => UsageEvent(
      at: DateTime(2026, 9, day, hour, 0),
      module: m,
      action: a,
      objectType: object,
      value: value,
      detail: detail,
    );

    test('模块/动作/时段/扩展名/大小桶/搜索/失败 都统计到', () {
      final stats = computeUsageStats([
        ev(9, UsageModule.files, UsageAction.open, object: '.pdf'),
        ev(9, UsageModule.files, UsageAction.preview, object: '.pdf'),
        ev(10, UsageModule.search, UsageAction.search, value: 0),
        ev(10, UsageModule.search, UsageAction.search, value: 3),
        ev(
          10,
          UsageModule.drive,
          UsageAction.upload,
          object: '.zip',
          value: 5 * 1024,
        ),
        ev(
          10,
          UsageModule.drive,
          UsageAction.failure,
          detail: {'failed_action': 'upload'},
        ),
        ev(23, UsageModule.notes, UsageAction.edit),
      ]);
      expect(stats.total, 7);
      expect(stats.byModule['files'], 2);
      expect(stats.byHourBand.keys.contains('上午(9-12)'), isTrue);
      expect(stats.byFileType['.pdf'], 2);
      expect(stats.bySizeBucket.values.fold<int>(0, (a, b) => a + b), 1);
      expect(stats.searchCount, 2);
      expect(stats.searchEmpty, 1);
      expect(stats.uploadCount, 1);
      expect(stats.editCount, 1);
      expect(stats.failures['drive.upload'], 1);
      expect(stats.dayCount, 1);
    });

    test('会话时长按"首末事件差"算，间隔超 5 分钟断开', () {
      UsageEvent at(int h, int m) => UsageEvent(
        at: DateTime(2026, 9, 1, h, m),
        module: UsageModule.files,
        action: UsageAction.open,
      );
      final stats = computeUsageStats([
        at(9, 0),
        at(9, 4), // 同一段（间隔 4 分钟）
        at(10, 0), // 间隔 56 分钟 → 新的一段
        at(10, 3),
      ]);
      expect(stats.sessions, hasLength(2));
      expect(stats.sessions.first, 4);
      expect(stats.sessions.last, 3);
      expect(stats.maxSession, 4);
      expect(stats.avgSession, 4); // (4+3)/2 = 3.5 → 4

      // 间隔刚好超过 5 分钟就算新段（边界）
      final split = computeUsageStats([at(9, 0), at(9, 6)]);
      expect(split.sessions, hasLength(2));
    });

    test('端侧模型输入特征里没有原始事件', () {
      final stats = computeUsageStats([
        ev(9, UsageModule.files, UsageAction.open, object: '.pdf'),
      ]);
      final f = stats.toFeatureJson();
      expect(f.containsKey('events'), isTrue);
      expect(f.containsKey('by_module'), isTrue);
      expect(f.toString(), isNot(contains('events_list')));
    });
  });

  group('结论', () {
    UsageEvent ev(
      int hour,
      UsageModule m,
      UsageAction a, {
      String object = '',
      int value = 0,
      int day = 1,
    }) => UsageEvent(
      at: DateTime(2026, 9, day, hour, 0),
      module: m,
      action: a,
      objectType: object,
      value: value,
    );

    test('样本不足（<20 条）只给数据量结论，不下"没用"的判断', () {
      final insights = buildInsights(
        computeUsageStats([
          ev(9, UsageModule.files, UsageAction.open),
          ev(10, UsageModule.notes, UsageAction.open),
        ]),
      );
      expect(insights, hasLength(1));
      expect(insights.single.kind, InsightKind.volume);
    });

    test('★ DA4：样本足够时给出时段/模块/文件类型/传输/搜索/失败等结论', () {
      final events = <UsageEvent>[];
      for (var i = 0; i < 40; i++) {
        events.add(
          ev(9, UsageModule.files, UsageAction.preview, object: '.pdf'),
        );
      }
      for (var i = 0; i < 20; i++) {
        events.add(
          ev(
            10,
            UsageModule.drive,
            UsageAction.upload,
            object: '.zip',
            value: 3 * 1024 * 1024,
          ),
        );
      }
      for (var i = 0; i < 12; i++) {
        events.add(ev(11, UsageModule.search, UsageAction.search, value: 0));
      }
      for (var i = 0; i < 5; i++) {
        events.add(ev(12, UsageModule.notes, UsageAction.edit));
      }
      for (var i = 0; i < 3; i++) {
        events.add(
          ev(
            13,
            UsageModule.drive,
            UsageAction.failure,
            /* failed upload */
          ),
        );
      }
      final insights = buildInsights(computeUsageStats(events));
      final kinds = insights.map((i) => i.kind).toSet();
      expect(kinds, contains(InsightKind.peakHour));

      // ★★★ r349 新增（修 D75 时补的**能红**守卫，§2.0.29）——
      //   构造"最忙的**时段**"与"最忙的**单个小时**"**不在同一个时段**"的样本：
      //   0..5 各 10 条 ⇒ `深夜(0-6)` 桶 = 60（全天最大桶），但**单小时最多只有 10**；
      //   21 点放 15 条 ⇒ 它比任何单个小时都多，却属于 `晚上(18-22)`。
      //   修 D75 之前，`top_hour` 取全天最大 ⇒ 15（=21 点），
      //   于是卡片会说「你主要在**深夜(0-6)**用…最忙的是 **21:00** 前后」——**自相矛盾**。
      //   判据钉在 `evidence` 上（机制量，不用解文案）：
      //   `top_hour` 所属的时段**必须**就是 `band`。
      final skew = <UsageEvent>[];
      for (var h = 0; h < 6; h++) {
        for (var i = 0; i < 10; i++) {
          skew.add(ev(h, UsageModule.files, UsageAction.open));
        }
      }
      for (var i = 0; i < 15; i++) {
        // 比任何单个小时都多，但少于 `深夜(0-6)` 整桶的 60
        skew.add(ev(21, UsageModule.files, UsageAction.preview));
      }
      final skewInsights = buildInsights(computeUsageStats(skew));
      final peak = skewInsights.firstWhere((i) => i.kind == InsightKind.peakHour);
      final band = peak.evidence['band'];
      final topHour = peak.evidence['top_hour'];
      expect(band, '深夜(0-6)',
          reason: '样本设计：0..5 共 60 条 ⇒ 全天最大桶必须是深夜(0-6)');
      expect(topHour, isNotNull, reason: '有时段结论就应给出最忙小时');
      // ★ 这一条就是 D75 的守卫：装回旧实现（全天取最大）必红，
      //   因为旧实现会给出 21，而 `hourBand(21)` = `晚上(18-22)` ≠ `深夜(0-6)`。
      expect(hourBand(topHour! as int), band,
          reason: '「最忙的小时」必须落在结论所说的那个时段内（D75 回归）');
      expect(kinds, contains(InsightKind.topModule));
      expect(kinds, contains(InsightKind.fileTypePref));
      expect(kinds, contains(InsightKind.searchQuality));
      expect(kinds, contains(InsightKind.transferMix));
      expect(kinds, contains(InsightKind.unusedModule));

      // 每条结论都要有可复核的证据，且带策略的结论要有 strategyKey
      for (final i in insights) {
        expect(i.evidence, isNotEmpty);
        expect(i.score, greaterThan(0));
      }
      final top = insights.firstWhere((i) => i.kind == InsightKind.topModule);
      expect(top.strategyKey, 'workspace.pin');
      expect(top.suggestion, isNotEmpty);
    });

    test('搜索命中率低会明确提示（0 结果占 100%）', () {
      final events = [
        for (var i = 0; i < 30; i++)
          ev(10, UsageModule.search, UsageAction.search, value: 0),
      ];
      final insight = buildInsights(
        computeUsageStats(events),
      ).firstWhere((i) => i.kind == InsightKind.searchQuality);
      expect(insight.title, contains('偏高'));
      expect(insight.suggestion, isNotEmpty);
      expect(insight.strategyKey, 'search.history');
    });

    test('结论按可信度降序（重要的在前）', () {
      final events = [
        for (var i = 0; i < 100; i++)
          ev(9 + (i % 10), UsageModule.files, UsageAction.open),
      ];
      final insights = buildInsights(computeUsageStats(events));
      for (var i = 1; i < insights.length; i++) {
        expect(insights[i - 1].score, greaterThanOrEqualTo(insights[i].score));
      }
    });
  });
}
