// r121 Android 逐屏截图审计 —— Download Station 三条缺陷的离线回归（D7 / D8 / D9）。
//
// 台账：`docs/android-ui-screenshot-audit.md` §2。
//   * D7① `dl_10.png` 标题被压成 `Downl...`（工具条给标题留的宽度不够）
//   * D7② `dl_10.png` 工具条里两个一模一样的 `⋮`（批量操作 vs 溢出入口）
//   * D7③ `dl_10.png` 状态行 `Total ↓ …  Total ↑ …  0`（标签重复 + 末尾裸数字）
//   * D8   `dl_10.png` 最后一个 chip 被右边缘齐边裁掉（看不出能横向滚）
//   * D9   `dl_10.png` `New task` 按钮与 `+ New task` FAB 重复（同一入口两份表示）
//
// 几何一律钉在**审计真机**上：1148×2492 @ DPR 2.75 ⇒ 417×906 逻辑像素。
// 本仓多数用例跑在 800×600（比真机宽近一倍）⇒ 这几条在那种窗口下量不到
// （假绿温床：AGENTS §2.0.21 铁律 3 / §2.0.10 铁律 3）。
//
// 每条缺陷都带**反向验证**：证明"修复前的形态"在这套几何下真的会出问题，
// 否则用例只是"恰好通过"，证不了它守得住。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/core/ui/adaptive_actions.dart';
import 'package:synhub/src/core/ui/app_states.dart';
import 'package:synhub/src/core/ui/hud_widgets.dart';
import 'package:synhub/src/data/download_station.dart';
import 'package:synhub/src/design/design_palette.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/downloads/download_page.dart';
import 'package:synhub/src/features/downloads/download_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// `dl_10.png` 的真机分辨率与像素密度 ⇒ 逻辑宽 ≈ 417.45dp。
const Size _kAuditPixels = Size(1148, 2492);
const double _kAuditDpr = 2.75;
const double _kAuditWidth = 1148 / 2.75;

/// 与 `test/download_page_test.dart` 同表（只保留本文件用到的条目）。
const _dsTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.DownloadStation2.Task': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.DownloadStation2.Task.Statistic': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.DownloadStation2.Task.List': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.DownloadStation2.Task.List.Polling': {
    'path': 'entry.cgi',
    'minVersion': 2,
    'maxVersion': 2,
  },
};

Map<String, dynamic> _task({Object id = 1, String title = 'ubuntu.iso'}) => {
  'id': id,
  'title': title,
  'type': 'bt',
  'status': 2,
  'size': 4096,
  'username': 'demo_user',
  'additional': {
    'detail': {'destination': '/volume1/downloads'},
    'transfer': {
      'size_downloaded': 1024,
      'speed_download': 2048,
      'speed_upload': 0,
    },
  },
};

/// 账单里的 `[]` 空列表响应（"一个任务都没有"那条路径）。
const Map<String, Map<String, dynamic>> _emptyList = {
  'SYNO.DownloadStation2.Task.list': {'task': <dynamic>[], 'total': 0},
};

Future<void> _pump(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = _emptyList,
  Size pixels = _kAuditPixels,
  double dpr = _kAuditDpr,
  // 默认走中文（审计截图就是中文界面）。注意：一旦显式给了
  // `localizationsDelegates`，测试环境的平台 locale（en_US）会命中
  // `supportedLocales.first = en` ⇒ 不写死 `zh` 的话文案会变英文。
  Locale? locale = const Locale('zh'),
}) async {
  tester.view.physicalSize = pixels;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
  final t = FakeTransport(responses, {...FakeTransport.table, ..._dsTable});
  final api = DsmWebApi(t);
  await api.discover();
  final c = ProviderContainer(
    overrides: [downloadApiProvider.overrideWithValue(DownloadStationApi(api))],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        // 每次 `_pump` 都建一棵**全新**的树：`const DownloadPage()` 是同一个实例，
        // 不给 key 的话 Flutter 会复用 element，`ref` 仍绑在上一个 container 上。
        key: UniqueKey(),
        locale: locale,
        localizationsDelegates: AppText.localizationsDelegates,
        supportedLocales: AppText.supportedLocales,
        home: page,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pumpAndSettle();
}

void main() {
  group('D7 toolbars / status row（417dp 审计真机几何）', () {
    testWidgets('D7① 英文标题拿到的宽度够放 `Downloads`（不再是 `Downl...`）', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await _pump(
        tester,
        const DownloadPage(),
        locale: const Locale('en'),
      );
      final title = find.text('Downloads');
      expect(title, findsOneWidget);
      // ★ r487：字号进了设计令牌（`DA123` 后标题是 `titleMedium` 15/600），
      //   `Ahem` 测试字体下 "Downloads" 的**固有宽度**必然 = 9 × 15 = 135dp ——
      //   拿"固有宽度 ≥160"当判据，等于在量字号而不是量"有没有被挤掉"（§2.0.18）。
      //   改量两件事：
      //     ① 标题的字号就是设计令牌（字号回归会红）；
      //     ② 标题**没有被截断**（`Ahem` 比真机字体更宽 ⇒ 这里不截，真机更不会截）。
      final style = tester.widget<Text>(title).style;
      final effective = style?.fontSize ??
          DefaultTextStyle.of(
            tester.element(title),
          ).style.fontSize ??
          0;
      expect(
        effective,
        DesignType.titleMediumSize.toDouble(),
        reason: '标题字号必须是设计令牌 titleMedium',
      );
      final para = tester.renderObject<RenderParagraph>(
        find.descendant(of: title, matching: find.byType(RichText)),
      );
      expect(
        para.didExceedMaxLines,
        isFalse,
        reason: '417dp 真机上标题不许被省略号截断',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('D7① 反向验证：修复前的 5 格工具条（reserve 112）标题只剩 ~121dp', (
      tester,
    ) async {
      tester.view.physicalSize = _kAuditPixels;
      tester.view.devicePixelRatio = _kAuditDpr;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppText.localizationsDelegates,
          supportedLocales: AppText.supportedLocales,
          home: Scaffold(
            appBar: AppBar(
              title: const Text('Downloads'),
              actions: adaptiveActions([
                for (var i = 0; i < 5; i++)
                  IconButton(
                    key: Key('pre-fix-$i'),
                    tooltip: 'pre-fix-$i',
                    icon: const Icon(Icons.circle_outlined),
                    onPressed: () {},
                  ),
              ]),
            ),
          ),
        ),
      );
      await tester.pump();
      final width = tester.getSize(find.text('Downloads')).width;
      expect(
        width,
        lessThan(160),
        reason:
            '这就是 `Downl...` 的几何：5 格 × 48dp = 240dp 挡住了标题，'
            '实测只剩 ${width.toStringAsFixed(1)}dp',
      );
      // 反向对照必须真在"同一块屏"上量，否则这个对照没意义。
      expect(_kAuditWidth, closeTo(417.45, 0.01));
    });

    testWidgets('D7② 工具条里只有一个 `⋮`，批量操作有自己的图标', (tester) async {
      await _pump(tester, const DownloadPage());
      final appBar = find.byType(AppBar);
      expect(
        find.descendant(of: appBar, matching: find.byIcon(Icons.more_vert)),
        findsOneWidget,
        reason: '审计里两个一模一样的 `⋮`：一个是批量操作、一个是折叠溢出入口',
      );
      expect(
        find.descendant(of: appBar, matching: find.byIcon(Icons.checklist)),
        findsOneWidget,
        reason: '批量操作必须是独立图标（`⋮` 只留给 FoldingActions 的溢出菜单）',
      );
      expect(find.byKey(const Key('ds-batch-menu')), findsOneWidget);
      expect(find.byKey(const Key('bar-overflow')), findsOneWidget);
      expect(find.byKey(const Key('ds-sort-menu')), findsOneWidget);
      expect(find.byKey(const Key('ds-search-open')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('D7③ 状态行两条速率不共用一个标签，末尾数字带标签', (tester) async {
      await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {
            'task': [_task()],
            'total': 1,
          },
          'SYNO.DownloadStation2.Task.Statistic.get': {
            'download_rate': 2048,
            'upload_rate': 0,
          },
        },
      );
      final bar = find.byKey(const Key('ds-stat-bar'));
      expect(bar, findsOneWidget);
      final labels = tester
          .widgetList<TelemetryLabel>(
            find.descendant(of: bar, matching: find.byType(TelemetryLabel)),
          )
          .map((l) => l.text)
          .toList();
      expect(labels, hasLength(3));
      expect(
        labels.toSet(),
        hasLength(3),
        reason: '审计里前两条都叫 `Total …`，看起来就是"标签重复"：$labels',
      );
      expect(labels.where((l) => l.contains('KB/s')), hasLength(2));
      expect(
        labels.where((l) => l.startsWith('Total') || l.startsWith('总')),
        isEmpty,
        reason: '同一个 `Total` 不许在状态行里出现两次：$labels',
      );
      expect(
        labels.any((l) => RegExp(r'^\d+$').hasMatch(l)),
        isFalse,
        reason: '末尾那个裸数字必须带标签，否则用户不知道它是"任务总数"：$labels',
      );
      expect(
        labels.any((l) => l.contains('个任务')),
        isTrue,
        reason: '末尾那条应当是带标签的计数：$labels',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('D8 chips 行（417dp）', () {
    testWidgets('D8 滚到底后最后一个 chip 完整可见；有内容在右边时给渐隐提示', (
      tester,
    ) async {
      await _pump(tester, const DownloadPage());
      final last = find.byKey(const Key('ds-cat-error'));
      expect(
        find.byKey(const Key('ds-category-fade')),
        findsOneWidget,
        reason: '右边还有 chip 时必须把"可以横向滚"显式画出来（D8 的缺陷就是看不出来）',
      );
      // 横向 `ListView` 是**懒构建**的 ⇒ 屏外（含 cacheExtent 之外）的 chip 根本
      // 还没进树。这正是"内容比屏宽"的硬证据，也复现了审计里
      // "最后一个 chip 被右边缘齐边裁掉、看着像内容就这么多"的形态。
      expect(
        last,
        findsNothing,
        reason: '最后一个分类初始时应在屏外（懒构建 ⇒ 尚未进树）',
      );
      final listView = tester.widget<ListView>(
        find.byKey(const Key('ds-category-list')),
      );
      final controller = listView.controller!;
      expect(
        controller.position.maxScrollExtent,
        greaterThan(0),
        reason: '417dp 上 chips 行必须真的可横向滚',
      );
      // 屏内最后一个**已构建**的 chip 的右缘必须越过屏宽 —— 就是"被右边缘裁掉"。
      const names = [
        'all',
        'active',
        'downloading',
        'waiting',
        'seeding',
        'hashChecking',
        'extracting',
        'paused',
        'finished',
        'error',
      ];
      final built = names
          .map((n) => find.byKey(Key('ds-cat-$n')))
          .where((f) => f.evaluate().isNotEmpty)
          .toList();
      expect(built, isNotEmpty);
      final tailRect = tester.getRect(built.last);
      expect(
        tailRect.right,
        greaterThan(_kAuditWidth),
        reason:
            '屏内最后一个已构建 chip 的右缘越过屏宽 ⇒ 正是审计里"齐边裁掉"的形态；'
            '实测 right=${tailRect.right.toStringAsFixed(1)}dp / 屏宽 $_kAuditWidth dp',
      );

      await tester.drag(
        find.byKey(const Key('ds-category-list')),
        const Offset(-2000, 0),
      );
      await tester.pumpAndSettle();

      // ★ 反向验证（本文件实现时真踩到过）：渐隐层的"有/无"如果包在 ListView
      //   外面，滚到右端那一帧会把 ListView **重建** ⇒ 偏移归零、用户被弹回开头。
      //   所以这里钉住"滚到底之后偏移仍在末端"，而不是只看最后一个 chip 在不在屏内。
      expect(
        controller.position.pixels,
        greaterThan(0),
        reason: '滚到底后横向偏移不许归零（渐隐显隐不得重建可滚动子树）',
      );
      expect(
        controller.position.pixels,
        closeTo(controller.position.maxScrollExtent, 1),
        reason: '应当停在最右端',
      );

      final after = tester.getRect(last);
      expect(after.left, greaterThanOrEqualTo(-0.01));
      expect(
        after.right,
        lessThanOrEqualTo(_kAuditWidth + 0.01),
        reason:
            '滚到底后必须完整落在屏内（保留滚动、不加省略号 ⇒ 内容可达）；'
            '实测 right=${after.right.toStringAsFixed(1)}dp',
      );
      expect(
        find.byKey(const Key('ds-category-fade')),
        findsNothing,
        reason: '滚到底后右边没有内容了，提示必须消失',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('D8 反向验证：宽度足够时没有渐隐，最后一个 chip 本来就在屏内', (
      tester,
    ) async {
      await _pump(
        tester,
        const DownloadPage(),
        pixels: const Size(2400, 1400),
        dpr: 1.0,
      );
      expect(
        find.byKey(const Key('ds-category-fade')),
        findsNothing,
        reason: '放得下就不该有"还能滚"的提示（否则提示变成常驻噪音）',
      );
      final r = tester.getRect(find.byKey(const Key('ds-cat-error')));
      expect(r.right, lessThanOrEqualTo(2400));
    });
  });

  group('D9 新建入口去重（417dp）', () {
    testWidgets('D9 空态（All）：只给按钮，不给 FAB', (tester) async {
      await _pump(tester, const DownloadPage());
      expect(
        find.byKey(const Key('ds-add-task')),
        findsNothing,
        reason: '空态里已经有 `New task` 按钮 ⇒ FAB 是同一个入口的第二份表示',
      );
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byType(AppEmptyState), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, '新建任务'),
        findsOneWidget,
        reason: '空态里那个按钮必须还在（不是"两个都砍掉"）',
      );
    });

    testWidgets('D9 有任务：只给 FAB，空态按钮不出现', (tester) async {
      await _pump(
        tester,
        const DownloadPage(),
        responses: {
          'SYNO.DownloadStation2.Task.list': {'task': [_task()], 'total': 1},
        },
      );
      expect(find.byKey(const Key('ds-add-task')), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(find.byType(AppEmptyState), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('D9 反向验证：空态恰好一个入口（按钮在、FAB 不在，二者互斥）', (tester) async {
      // 空态（All）：按钮在 ⇒ FAB 必须不在 —— 这两条是**同一个规格的两半**，
      // 必须同时成立（"两个都砍掉"和"两个都在"都是错的）。
      await _pump(tester, const DownloadPage());
      final hasButton = find
          .widgetWithText(FilledButton, '新建任务')
          .evaluate()
          .isNotEmpty;
      final hasFab = find.byType(FloatingActionButton).evaluate().isNotEmpty;
      expect(hasButton, isTrue, reason: '空态必须仍有入口，不能两个都砍');
      expect(
        hasFab,
        isFalse,
        reason: '空态下"按钮 + FAB"同时出现就是审计里的重复入口',
      );
      expect(
        hasButton ^ hasFab,
        isTrue,
        reason: '空态的可用入口必须**恰好一个**',
      );
    });

    testWidgets('D9 反向验证：筛选后为空（不是 All）时 FAB 是唯一入口', (tester) async {
      // 这是 `_emptyStateHasNewTask()` 的另一侧：`items` 空但分类不是 `All`
      // ⇒ 空态**不给**按钮（不给"在这个筛选下新建"的假语义），入口落在 FAB。
      // 用它证明 D9 的去重没有越界（不是"只要空就砍 FAB"，也不是"只要空就给按钮"）。
      await _pump(tester, const DownloadPage());
      await tester.tap(find.byKey(const Key('ds-cat-downloading')));
      await tester.pumpAndSettle();
      expect(find.byType(AppEmptyState), findsOneWidget);
      final hasButton = find
          .widgetWithText(FilledButton, '新建任务')
          .evaluate()
          .isNotEmpty;
      final hasFab = find.byType(FloatingActionButton).evaluate().isNotEmpty;
      expect(
        hasButton,
        isFalse,
        reason: '筛选态的空态不该给"新建任务"按钮（分类语义不同）',
      );
      expect(hasFab, isTrue, reason: '筛选态下入口必须落在 FAB，不许变成零入口');
      expect(hasButton ^ hasFab, isTrue, reason: '筛选态同样恰好一个入口');
      expect(tester.takeException(), isNull);
    });
  });
}
