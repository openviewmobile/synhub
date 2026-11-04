// 埋点**模式 / 隐私 / 边界 / 失败原因**的离线验证（第 275 轮）。
//
// 这一份盯的是"能不能安全地长期收集"：
//   * 参数是**类型化且稳定**的（原因码归一、detail 键集中登记）；
//   * **无 PII**：静态扫描每个 track* 调用点，禁止出现 name/path/title/**host**
//     这类键；运行时 `recordFailure` 也绝不能把 message（含文件名）落库；
//   * **有界**：保留天数与条数上限真的生效（`prune(maxEvents:)`）；
//   * **失败原因可传播**：`reason` → 落库 → `UsageStats.byFailureReason`
//     → `InsightKind.failureReason`，页面才能回答"为什么失败"。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/local/analytics_database.dart';
import 'package:synhub/src/features/analytics/usage_analysis.dart';
import 'package:synhub/src/features/analytics/usage_event.dart';
import 'package:synhub/src/features/analytics/usage_log.dart';

/// 测试用：一个带稳定 `id` 的功能侧原因枚举（模拟 `MediaUnavailableReason`）
enum _FakeFeatureReason {
  emptyUrl('empty_url'),
  decodeFailed('decode_failed');

  const _FakeFeatureReason(this.id);
  final String id;
}

/// 测试用：一个没有 `id` 的普通枚举 → 走 `name`
enum _PlainReason { offline, timeout }

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('原因码归一（类型化参数）', () {
    test('本枚举走 id', () {
      expect(reasonCodeOf(UsageFailureReason.decode), 'decode');
      expect(reasonCodeOf(UsageFailureReason.auth), 'auth');
    });

    test('功能枚举优先 id，没有 id 才用 name', () {
      expect(reasonCodeOf(_FakeFeatureReason.emptyUrl), 'empty_url');
      expect(reasonCodeOf(_FakeFeatureReason.decodeFailed), 'decode_failed');
      expect(reasonCodeOf(_PlainReason.offline), 'offline');
      expect(reasonCodeOf(_PlainReason.timeout), 'timeout');
    });

    test('异常/任意对象 → unknown（绝不留 message）', () {
      expect(
        reasonCodeOf(StateError('/volume1/secret/客户合同.pdf 不存在')),
        'unknown',
      );
      expect(reasonCodeOf(null), 'unknown');
      expect(reasonCodeOf(42), 'unknown');
    });

    test('字符串原样保留但截断到 40 字符', () {
      expect(reasonCodeOf('send_failed'), 'send_failed');
      expect(reasonCodeOf('x' * 80).length, 40);
      expect(reasonCodeOf('   '), 'unknown');
    });

    test('每个 UsageFailureReason 都有非空稳定 id 与中文回落', () {
      for (final r in UsageFailureReason.values) {
        expect(r.id.trim(), isNotEmpty);
        expect(r.label.trim(), isNotEmpty);
        expect(UsageFailureReason.byId(r.id), r);
      }
    });
  });

  group('detail 键登记 / 禁用键', () {
    test('禁用键集合覆盖隐私红线', () {
      for (final k in ['name', 'path', 'title', 'content', 'host']) {
        expect(UsageDetailKeys.forbidden, contains(k));
      }
    });

    test('登记键不与禁用键冲突', () {
      const registered = [
        UsageDetailKeys.source,
        UsageDetailKeys.kind,
        UsageDetailKeys.via,
        UsageDetailKeys.failedAction,
        UsageDetailKeys.reason,
        UsageDetailKeys.error,
        UsageDetailKeys.view,
        UsageDetailKeys.section,
        UsageDetailKeys.lang,
        UsageDetailKeys.preset,
        UsageDetailKeys.durationMs,
        UsageDetailKeys.count,
        UsageDetailKeys.hasResult,
      ];
      for (final k in registered) {
        expect(
          UsageDetailKeys.forbidden,
          isNot(contains(k)),
          reason: '登记键 $k 撞了禁用键',
        );
      }
    });
  });

  group('无 PII：静态扫描所有 track* 调用点', () {
    test('lib/src/features/** 的 track* 参数里没有禁用键字面量', () {
      final root = Directory('lib/src/features');
      expect(root.existsSync(), isTrue, reason: '必须在仓库根目录跑');
      final callRe = RegExp(r'\btrack[A-Za-z]*\s*\(');
      final offenders = <String>[];
      for (final f in root.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        if (f.path.contains('/analytics/')) continue; // 定义本身
        final src = f.readAsStringSync();
        for (final m in callRe.allMatches(src)) {
          final args = _balancedArgs(src, m.end - 1);
          for (final k in UsageDetailKeys.forbidden) {
            // 只看**键位**（`'name': …`）；把 'message' 当 objectType **值**是允许的
            final keyPat = RegExp("['\"]$k['\"]\\s*:");
            if (keyPat.hasMatch(args)) {
              offenders.add('${f.path}: $k');
            }
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: '这些埋点把内容类字段写进了日志：\n${offenders.join('\n')}',
      );
    });
  });

  group('失败原因传播（落库 → 聚合 → 结论）', () {
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

    test('recordFailure 落 reason，且 error 只留类型名', () async {
      log.recordFailure(
        UsageModule.chat,
        UsageAction.create,
        objectType: 'dm',
        reason: _FakeFeatureReason.emptyUrl,
        error: StateError('/volume1/客户合同.pdf boom'),
      );
      await log.flush();
      final e = (await log.recent()).single;
      expect(e.action, UsageAction.failure);
      expect(e.detail[UsageDetailKeys.failedAction], 'create');
      expect(e.detail[UsageDetailKeys.reason], 'empty_url');
      expect('${e.detail[UsageDetailKeys.error]}'.trim(), isNotEmpty);
      expect('${e.detail[UsageDetailKeys.error]}', isNot(contains('客户合同')));
      expect(e.detail.toString(), isNot(contains('/volume1')));
    });

    test('reason → byFailureReason → failureReason 结论', () async {
      for (var i = 0; i < 30; i++) {
        log.recordFailure(
          UsageModule.media,
          UsageAction.play,
          objectType: 'video',
          reason: _FakeFeatureReason.decodeFailed,
          at: DateTime(2026, 9, 1, 9, i),
        );
      }
      for (var i = 0; i < 5; i++) {
        log.record(
          UsageModule.files,
          UsageAction.open,
          at: DateTime(2026, 9, 1, 10, i),
        );
      }
      await log.flush();
      final stats = computeUsageStats(await log.range());
      expect(stats.byFailureReason['media.decode_failed'], 30);
      // 原因里没有 message / 路径
      for (final k in stats.byFailureReason.keys) {
        expect(k, isNot(contains('/')));
        expect(k, isNot(contains('.pdf')));
      }
      final insight = buildInsights(
        stats,
      ).firstWhere((i) => i.kind == InsightKind.failureReason);
      expect(insight.evidence['reasons'], isA<Map>());
      expect(insight.score, greaterThan(0));
    });
  });

  group('有界（保留策略真的生效）', () {
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

    test('保留常量是有界的', () {
      expect(kRetentionDays, greaterThan(0));
      expect(kRetentionDays, lessThanOrEqualTo(366));
      expect(kMaxEvents, greaterThan(0));
      expect(kMaxEvents, lessThanOrEqualTo(200000));
      expect(kFlushSize, greaterThan(0));
    });

    test('超过条数上限时删最老的（prune maxEvents 注入）', () async {
      for (var i = 0; i < 10; i++) {
        log.record(
          UsageModule.files,
          UsageAction.open,
          at: DateTime(2026, 9, 1, 9, i),
        );
      }
      await log.flush();
      expect(await log.eventCount(), 10);
      await log.prune(maxEvents: 4);
      expect(await log.eventCount(), 4);
      // 留下的是**最新**的 4 条（9:06–9:09）
      final left = await log.recent();
      final hours = left.map((e) => e.at.minute).toSet();
      expect(hours, {6, 7, 8, 9});
    });

    test('超过保留天数的事件在 flush 时被裁掉', () async {
      final old = DateTime.now().subtract(
        const Duration(days: kRetentionDays + 3),
      );
      log.record(UsageModule.files, UsageAction.open, at: old);
      log.record(UsageModule.files, UsageAction.open);
      await log.flush();
      expect(await log.eventCount(), 1);
    });
  });

  group('偏好维度聚合数学', () {
    UsageEvent ev(UsageModule m, UsageAction a, {String object = '', int value = 0, Map<String, Object?> detail = const {}}) =>
        UsageEvent(
          at: DateTime(2026, 9, 1, 9),
          module: m,
          action: a,
          objectType: object,
          value: value,
          detail: detail,
        );

    test('byViewMode / byScreen / 时长平均 都算对', () {
      final stats = computeUsageStats([
        ev(UsageModule.photos, UsageAction.switchView, object: 'timeline'),
        ev(UsageModule.photos, UsageAction.switchView, object: 'grid'),
        ev(UsageModule.photos, UsageAction.switchView, object: 'timeline'),
        ev(UsageModule.media, UsageAction.view, object: 'player'),
        ev(
          UsageModule.media,
          UsageAction.complete,
          object: 'video',
          value: 120000,
          detail: {UsageDetailKeys.preset: 'play'},
        ),
        ev(
          UsageModule.media,
          UsageAction.complete,
          object: 'video',
          value: 180000,
          detail: {UsageDetailKeys.preset: 'play'},
        ),
      ]);
      expect(stats.byViewMode['photos.timeline'], 2);
      expect(stats.byViewMode['photos.grid'], 1);
      expect(stats.byScreen['media.player'], 1);
      expect(stats.durationCount['media.play'], 2);
      // (120000+180000)/2 = 150000ms = 2.5min → 3
      expect(stats.avgMinutesOf('media.play'), 3);
    });

    test('功能采用：外壳模块不计入采用率', () {
      final stats = computeUsageStats([
        ev(UsageModule.files, UsageAction.open),
        ev(UsageModule.workspace, UsageAction.open),
        ev(UsageModule.settings, UsageAction.select),
      ]);
      expect(stats.adoptedModules, contains('files'));
      expect(stats.adoptedModules, isNot(contains('workspace')));
      expect(stats.adoptedModules, isNot(contains('settings')));
      expect(stats.unusedModules, contains('audio'));
      expect(
        stats.adoptionTotal,
        stats.adoptedModules.length + stats.unusedModules.length,
      );
    });
  });
}

/// 从 `(` 位置起，取出**括号配平**的参数文本（跳过字符串里的括号）。
String _balancedArgs(String src, int openParen) {
  var depth = 0;
  var i = openParen;
  var inStr = false;
  var quote = '';
  for (; i < src.length; i++) {
    final c = src[i];
    if (inStr) {
      if (c == r'\') {
        i++;
        continue;
      }
      if (c == quote) inStr = false;
      continue;
    }
    if (c == "'" || c == '"') {
      inStr = true;
      quote = c;
      continue;
    }
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return src.substring(openParen, i + 1);
    }
  }
  return src.substring(openParen);
}
