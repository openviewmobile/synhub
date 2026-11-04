// 「网络流量」页：排行 / 时段 / 精确-估算拆分 / 未归属 / 空态 / 范围切换。
//
// 数据是真写到 drift 内存库、再经 provider 读回来的 —— 这样页面上的数字
// 就是"库里那些字节"的函数，而不是页内自己算的假数。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/net/device_traffic.dart';
import 'package:synhub/src/core/net/traffic_meter.dart';
import 'package:synhub/src/data/local/analytics_database.dart';
import 'package:synhub/src/features/analytics/analytics_providers.dart';
import 'package:synhub/src/features/analytics/traffic_analysis.dart';
import 'package:synhub/src/features/analytics/traffic_log.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/analytics/traffic_page.dart';

class _NullProbe implements DeviceTrafficProbe {
  @override
  Future<DeviceTrafficSnapshot?> snapshot() async => null;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AnalyticsDatabase db;

  setUp(() => db = AnalyticsDatabase.memory());
  tearDown(() => db.close());

  Future<void> seed(
    WidgetTester tester, {
    required List<TrafficSample> samples,
    List<TrafficEstimate> estimates = const [],
  }) async {
    await tester.runAsync(() async {
      final log = TrafficLog(db);
      for (final s in samples) {
        log.addExact(s);
      }
      for (final e in estimates) {
        log.addEstimate(e);
      }
      await log.flush();
      log.dispose();
    });
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        analyticsDatabaseProvider.overrideWithValue(db),
        deviceTrafficProbeProvider.overrideWithValue(_NullProbe()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.dark(), home: TrafficPage()),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  TrafficSample sample(
    DateTime at,
    String module,
    TrafficDirection dir,
    int bytes, {
    TrafficTier tier = TrafficTier.exact,
  }) => TrafficSample(
    at: at,
    module: module,
    direction: dir,
    bytes: bytes,
    tier: tier,
  );

  DateTime hourNow() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day, n.hour);
  }

  testWidgets('空库：给诚实空态 + 两个档位各自要什么', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('traffic-empty')), findsOneWidget);
    expect(find.textContaining('还没有流量数据'), findsOneWidget);
    // 没有任何模块行
    expect(find.byKey(const Key('traffic-ranking')), findsNothing);
  });

  testWidgets('有数据：合计 / 精确-估算拆分 / 排行 / 时段柱都在', (tester) async {
    final h = hourNow();
    await seed(
      tester,
      samples: [
        sample(h.add(const Duration(minutes: 3)), TrafficModules.files,
            TrafficDirection.down, 1000),
        sample(h.add(const Duration(minutes: 4)), TrafficModules.files,
            TrafficDirection.up, 100),
        sample(h.add(const Duration(minutes: 5)), TrafficModules.chat,
            TrafficDirection.down, 500),
      ],
      estimates: [
        TrafficEstimate(
          from: h.add(const Duration(minutes: 10)),
          to: h.add(const Duration(minutes: 20)),
          module: TrafficModules.media,
          direction: TrafficDirection.down,
          bytes: 300,
        ),
      ],
    );
    await pump(tester);
    expect(find.byKey(const Key('traffic-empty')), findsNothing);
    // 合计 = 1000 + 100 + 500 + 300(估算)
    expect(find.byKey(const Key('traffic-total-bytes')), findsOneWidget);
    expect(find.text('1.86 KB'), findsOneWidget);
    // 精确 1600 / 估算 300 / 未归属 0
    expect(find.byKey(const Key('traffic-tag-exact')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('traffic-tag-exact')),
        matching: find.textContaining('1.56 KB'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('traffic-tag-estimated')),
        matching: find.textContaining('300 B'),
      ),
      findsOneWidget,
    );
    // 排行：三个模块都在
    expect(find.byKey(const Key('traffic-ranking')), findsOneWidget);
    for (final m in [
      TrafficModules.files,
      TrafficModules.chat,
      TrafficModules.media,
    ]) {
      expect(find.byKey(Key('traffic-rank-$m')), findsOneWidget);
    }
    // 时段柱（24 根）
    expect(find.byKey(const Key('traffic-hours')), findsOneWidget);
    // 平台读不到 UID 计数 → 如实说，不假装有对比
    expect(find.byKey(const Key('traffic-os-unavailable')), findsOneWidget);
  });

  testWidgets('方向切换：只看上传时下载模块消失', (tester) async {
    final h = hourNow();
    await seed(
      tester,
      samples: [
        sample(h, TrafficModules.files, TrafficDirection.down, 1000),
        sample(h, TrafficModules.files, TrafficDirection.up, 100),
        sample(h, TrafficModules.chat, TrafficDirection.down, 500),
      ],
    );
    await pump(tester);
    expect(find.byKey(const Key('traffic-rank-chat')), findsOneWidget);
    await tester.tap(find.byKey(const Key('traffic-dir-up')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('traffic-rank-files')), findsOneWidget);
    expect(
      find.byKey(const Key('traffic-rank-chat')),
      findsNothing,
      reason: 'chat 只有下载，切到上传就该消失',
    );
  });

  testWidgets('范围切换：近 24 小时把两天前的桶排除', (tester) async {
    final h = hourNow();
    await seed(
      tester,
      samples: [
        sample(h, TrafficModules.files, TrafficDirection.down, 1024),
        sample(h.subtract(const Duration(days: 2)), TrafficModules.chat,
            TrafficDirection.down, 1024),
      ],
    );
    await pump(tester);
    expect(find.byKey(const Key('traffic-rank-chat')), findsOneWidget);
    await tester.tap(find.byKey(const Key('traffic-range-day')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(find.byKey(const Key('traffic-rank-files')), findsOneWidget);
    expect(
      find.byKey(const Key('traffic-rank-chat')),
      findsNothing,
      reason: '2 天前的桶不该出现在"近 24 小时"里',
    );
  });

  testWidgets('格式化用 ASCII 单位（不出现中文单位）', (tester) async {
    expect(formatTrafficBytes(1024 * 1024).contains('MB'), isTrue);
    expect(formatTrafficBytes(1024 * 1024).contains('兆'), isFalse);
  });
}
