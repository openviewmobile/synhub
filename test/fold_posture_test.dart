// 折叠**姿态**（铰链角）→ 折痕带（合成 `DisplayFeature`）的守卫。
//
// 覆盖（逐条对应交付要求）：
//   §1 三态映射 `foldPostureForAngle`：**成对边界**（160.0/159.9、20.0/19.9）
//      + `null` / 非有限值 / 越界值 ⇒ `unknown`；以及实测角度逐点；
//   §2 合成折痕带的**几何**：把短边对半分、横屏取横带 / 竖屏取竖带，
//      并用既有的 `verticalObstructingBand` / `horizontalObstructingBand`
//      断言它能被既有筛选器接住；`rectHitsBands` 的命中/不命中；
//      **交集 px² = 0**（真机报告里的同一个机制量）；
//   §3 并进 `displayFeatures` 的三条规则（fail-open / 不叠加 / 只在半折）；
//   §4 反向验证：把 `unknown` 强行当"半折"处理 ⇒ 不变量立刻为假；
//   §5 host-gating：非 Android（含 `FLUTTER_TEST`）**不建通道**且恒 `unknown`。
//
// ★ 门槛数字（160 / 20 / 34dp）的**依据**写在
//   `lib/src/core/ui/fold_posture.dart` 文件头，这里只钉住行为。
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/ui/adaptive_layout.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/core/ui/fold_posture.dart';

// ─────────────────────────────────────────────── 真机尺寸常量（逐位保留）

/// Mate X2 内屏逻辑尺寸（2200×2480 @520dpi / dpr 3.25；r292 实测）。
const double kMateX2DpShort = 2200 / 3.25; // 676.9230769…
const double kMateX2DpLong = 2480 / 3.25; // 763.0769230…

/// 横屏：短边在竖直方向 ⇒ 合成带必须是**横带**（任务书说的"中间横带"）。
const Size kMateX2Landscape = Size(kMateX2DpLong, kMateX2DpShort);

/// 竖屏：短边在水平方向 ⇒ 同一个物理折痕在窗口坐标里是**竖带**。
const Size kMateX2Portrait = Size(kMateX2DpShort, kMateX2DpLong);

/// 两个矩形的交集**像素面积**（px²）。不相交 ⇒ 0（不是负数的乘积）。
double overlapPx2(Rect a, Rect b) {
  final i = a.intersect(b);
  return math.max(0.0, i.width) * math.max(0.0, i.height);
}

// ─────────────────────────────────────────────── 假数据源

class _FakeFeed extends FoldPostureFeed {
  final StreamController<FoldPostureReading> _c =
      StreamController<FoldPostureReading>.broadcast();

  @override
  Stream<FoldPostureReading> get readings => _c.stream;

  void push(FoldPostureReading r) => _c.add(r);

  void close() => unawaited(_c.close());
}

/// 推一个读数并**推进两帧**：广播流的送达在微任务里，第一帧只负责送达、
/// 第二帧才是重建（只 pump 一次断言必然读到旧姿态 —— 这点已实测）。
Future<void> _push(
  WidgetTester tester,
  _FakeFeed feed,
  FoldPostureReading r,
) async {
  feed.push(r);
  await tester.pump();
  await tester.pump();
}

// ─────────────────────────────────────────────── 测试装置

/// 把 [size] 钉成窗口逻辑尺寸（dpr=1），并把姿态流换成 [feed]。
Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required Size size,
  required _FakeFeed feed,
  List<ui.DisplayFeature> platform = const <ui.DisplayFeature>[],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final c = ProviderContainer(
    overrides: [foldPostureFeedProvider.overrideWithValue(feed)],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), 
        // 与生产接线同构：`FoldPostureLayout` 在 `MaterialApp` **里面**
        // （`lib/src/app.dart` 的 `builder`），读的是 `MaterialApp` 那层
        // `MediaQuery`。合成 `displayFeatures` 注入方式与
        // `adaptive_layout_matrix_test.dart` 一致。
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(displayFeatures: platform),
          child: FoldPostureLayout(child: child ?? const SizedBox.shrink()),
        ),
        home: const Scaffold(
          body: AdaptiveScaffold(
            master: SizedBox.expand(key: Key('fold-master')),
            detail: null,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return c;
}

/// `fold-master` 到根之间有几层 `MediaQuery`（机制量：多包了一层没有）。
int _mediaQueryLayers(WidgetTester tester) => find
    .ancestor(
      of: find.byKey(const Key('fold-master')),
      matching: find.byType(MediaQuery),
    )
    .evaluate()
    .length;

/// 从 `fold-master` 位置读该处生效的 `displayFeatures`。
List<ui.DisplayFeature> _featuresAtMaster(WidgetTester tester) =>
    MediaQuery.displayFeaturesOf(
      tester.element(find.byKey(const Key('fold-master'))),
    );

void main() {
  // ═══════════════════════════════════════════ §1 三态映射
  group('§1 foldPostureForAngle：三态与成对边界', () {
    test('实测角度逐点（第 293 轮录制）', () {
      expect(foldPostureForAngle(179.34), FoldPosture.flat); // 摊平
      expect(foldPostureForAngle(179.88), FoldPosture.flat); // 再摊平
      expect(foldPostureForAngle(86.80), FoldPosture.halfOpened); // 手摆 90°
      expect(foldPostureForAngle(42.20), FoldPosture.halfOpened); // 手摆 45°
      expect(foldPostureForAngle(1.2), FoldPosture.closed); // 完全合上
    });

    test('★ 成对边界 160：160.0 = flat，159.9 = halfOpened', () {
      expect(foldPostureForAngle(160.0), FoldPosture.flat);
      expect(foldPostureForAngle(160.1), FoldPosture.flat);
      expect(foldPostureForAngle(159.9), FoldPosture.halfOpened);
      expect(foldPostureForAngle(159.999), FoldPosture.halfOpened);
    });

    test('★ 成对边界 20：20.0 = halfOpened，19.9 = closed', () {
      expect(foldPostureForAngle(20.0), FoldPosture.halfOpened);
      expect(foldPostureForAngle(20.001), FoldPosture.halfOpened);
      expect(foldPostureForAngle(19.9), FoldPosture.closed);
      expect(foldPostureForAngle(19.999), FoldPosture.closed);
    });

    test('0 / 360 是合法域端值（360 = 可翻折机型的"摊平"）', () {
      expect(foldPostureForAngle(0.0), FoldPosture.closed);
      expect(foldPostureForAngle(360.0), FoldPosture.flat);
    });

    test('★ null / 非有限 / 越界 ⇒ unknown（绝不编一个角度）', () {
      expect(foldPostureForAngle(null), FoldPosture.unknown);
      expect(foldPostureForAngle(double.nan), FoldPosture.unknown);
      expect(foldPostureForAngle(double.infinity), FoldPosture.unknown);
      expect(foldPostureForAngle(double.negativeInfinity), FoldPosture.unknown);
      expect(foldPostureForAngle(-0.001), FoldPosture.unknown);
      expect(foldPostureForAngle(360.001), FoldPosture.unknown);
      expect(foldPostureForAngle(9999), FoldPosture.unknown);
    });

    test('三态互斥：needsFoldBand 只在 halfOpened 为真', () {
      for (final p in FoldPosture.values) {
        expect(p.needsFoldBand, p == FoldPosture.halfOpened, reason: '$p');
      }
      expect(FoldPosture.unknown.isKnown, isFalse);
      expect(FoldPosture.flat.isKnown, isTrue);
    });

    test('读数解析：类型容错 + 认不出就是 unknown', () {
      final half = FoldPostureReading.fromChannel(<String, Object?>{
        'angleDegrees': 86.8,
        'postureCode': 0.51,
        'source': 'posture',
        'subscribed': true,
      });
      expect(half.posture, FoldPosture.halfOpened);
      expect(half.postureCode, 0.51); // 原样保留（取整会变成 1）
      expect(half.source, FoldPostureSource.posture);
      expect(half.subscribed, isTrue);

      // 数字被服务端/桥回成字符串也要认（§2.0.12 类型容错）
      final flat = FoldPostureReading.fromChannel(<String, Object?>{
        'angleDegrees': '179.34',
        'source': 'hinge_angle',
        'subscribed': 1,
      });
      expect(flat.posture, FoldPosture.flat);
      expect(flat.subscribed, isTrue);

      final none = FoldPostureReading.fromChannel(const <String, Object?>{});
      expect(none.angleDegrees, isNull);
      expect(none.posture, FoldPosture.unknown);
      expect(none.source, FoldPostureSource.unknown);
      expect(none.subscribed, isFalse);

      // 认不出的载荷 ⇒ null（**不**回落成"摊平"）
      expect(FoldPostureReading.tryParse(42), isNull);
      expect(FoldPostureReading.tryParse('179'), isNull);
    });
  });

  // ═══════════════════════════════════════════ §2 合成带几何
  group('§2 合成折痕带：几何 + 既有筛选器 + 交集 px²', () {
    test('横屏（763.077×676.923）⇒ 占短边中间的**横带**、沿长边贯穿', () {
      final band = syntheticFoldBand(kMateX2Landscape);
      expect(band.height, kSyntheticFoldBandDp);
      expect(band.width, kMateX2Landscape.width);
      expect(band.top, (kMateX2Landscape.height - kSyntheticFoldBandDp) / 2);
      expect(band.center.dy, kMateX2Landscape.height / 2);
      expect(band.center.dx, kMateX2Landscape.width / 2);
    });

    test('竖屏（676.923×763.077）⇒ 同一个物理折痕是**竖带**', () {
      final band = syntheticFoldBand(kMateX2Portrait);
      expect(band.width, kSyntheticFoldBandDp);
      expect(band.height, kMateX2Portrait.height);
      expect(band.center.dx, kMateX2Portrait.width / 2);
    });

    test('★ 既有的两个筛选器**接得住**合成带（否则等于白加）', () {
      final size = kMateX2Landscape;
      final feature = syntheticFoldFeature(size);
      expect(feature.type, ui.DisplayFeatureType.fold);
      expect(
        horizontalObstructingBand(<ui.DisplayFeature>[feature], size),
        syntheticFoldBand(size),
      );
      expect(
        verticalObstructingBand(<ui.DisplayFeature>[feature], size),
        isNull,
      );

      final pSize = kMateX2Portrait;
      final pFeature = syntheticFoldFeature(pSize);
      expect(
        verticalObstructingBand(<ui.DisplayFeature>[pFeature], pSize),
        syntheticFoldBand(pSize),
      );
      expect(
        horizontalObstructingBand(<ui.DisplayFeature>[pFeature], pSize),
        isNull,
      );
    });

    test('★ 半折时"上半屏内容块"与带**恰好贴边** ⇒ 交集 px² = 0', () {
      final size = kMateX2Landscape;
      final band = syntheticFoldBand(size);
      // 上半屏内容块：占满宽度、到带的上沿为止（= AdaptiveScaffold 实际给的高度）
      final topPane = Rect.fromLTWH(0, 0, size.width, band.top);
      expect(rectHitsBands(topPane, <Rect>[band]), isFalse);
      expect(overlapPx2(topPane, band), 0.0);
      // 同样量一下"整页区域"（真机报告里量的是它）
      expect(overlapPx2(band, Rect.fromLTWH(0, 0, size.width, band.top)), 0.0);
    });

    test('跨在折痕带上的内容块 ⇒ 命中，且交集 px² > 0（判据抓得住）', () {
      final size = kMateX2Landscape;
      final band = syntheticFoldBand(size);
      final crossing = Rect.fromLTWH(0, band.top - 10, size.width, 20);
      expect(rectHitsBands(crossing, <Rect>[band]), isTrue);
      // crossing 与带的重叠只有下半 10px（带从 band.top 开始）
      expect(overlapPx2(crossing, band), size.width * 10);
      // 带内的内容块
      final inside = Rect.fromLTWH(100, band.top + 1, 10, 2);
      expect(rectHitsBands(inside, <Rect>[band]), isTrue);
      expect(overlapPx2(inside, band), 10 * 2);
    });

    test('极窄窗口：带缩到 0 ⇒ 筛选器主动跳过（不改布局，不出现负宽度）', () {
      final band = syntheticFoldBand(const Size(40, 40));
      expect(band.width, greaterThanOrEqualTo(0));
      expect(band.height, greaterThanOrEqualTo(0));
      final feature = syntheticFoldFeature(const Size(40, 40));
      expect(
        horizontalObstructingBand(<ui.DisplayFeature>[feature], const Size(40, 40)),
        isNull,
      );
      expect(
        verticalObstructingBand(<ui.DisplayFeature>[feature], const Size(40, 40)),
        isNull,
      );
    });
  });

  // ═══════════════════════════════════════════ §3 并进 displayFeatures
  group('§3 foldFeaturesForPosture：三条规则', () {
    const empty = <ui.DisplayFeature>[];
    final platformFold = <ui.DisplayFeature>[
      ui.DisplayFeature(
        bounds: const Rect.fromLTWH(700, 0, 34, 600),
        type: ui.DisplayFeatureType.fold,
        state: ui.DisplayFeatureState.postureHalfOpened,
      ),
    ];

    test('★ fail-open：unknown / flat / closed ⇒ 原样返回**同一个实例**', () {
      for (final p in <FoldPosture>[
        FoldPosture.unknown,
        FoldPosture.flat,
        FoldPosture.closed,
      ]) {
        expect(
          identical(foldFeaturesForPosture(empty, p, kMateX2Landscape), empty),
          isTrue,
          reason: '$p 不许新增任何 DisplayFeature',
        );
      }
    });

    test('unknown 与 flat 结果**逐字节相同**（都等于改造前那份列表）', () {
      final a = foldFeaturesForPosture(empty, FoldPosture.unknown, kMateX2Landscape);
      final b = foldFeaturesForPosture(empty, FoldPosture.flat, kMateX2Landscape);
      expect(identical(a, b), isTrue);
      expect(a, isEmpty);
    });

    test('半折 + 平台没有带 ⇒ 恰好加一条 fold 带，bounds 就是合成几何', () {
      final merged = foldFeaturesForPosture(
        empty,
        FoldPosture.halfOpened,
        kMateX2Landscape,
      );
      expect(merged, hasLength(1));
      expect(merged.single.type, ui.DisplayFeatureType.fold);
      expect(merged.single.bounds, syntheticFoldBand(kMateX2Landscape));
    });

    test('★ 平台**已经**报了带 ⇒ 不叠加第二条（§2.0.26 同一语义两份表示）', () {
      final merged = foldFeaturesForPosture(
        platformFold,
        FoldPosture.halfOpened,
        kMateX2Landscape,
      );
      expect(identical(merged, platformFold), isTrue);
    });

    test('平台带原样保留（半折 + 平台带 ⇒ 平台那份不动）', () {
      final merged = foldFeaturesForPosture(
        platformFold,
        FoldPosture.flat,
        kMateX2Landscape,
      );
      expect(identical(merged, platformFold), isTrue);
    });

    test('窗口太小 ⇒ 不塞一条"谁也不认"的 DisplayFeature', () {
      final merged = foldFeaturesForPosture(
        empty,
        FoldPosture.halfOpened,
        const Size(40, 40),
      );
      expect(identical(merged, empty), isTrue);
    });
  });

  // ═══════════════════════════════════════════ §4 反向验证 + 接进既有避让
  group('§4 接进 FoldAvoidingLayout / AdaptiveScaffold（含反向验证）', () {
    test('★ 反向验证①：把 unknown 强行当"半折"处理，这条不变量立刻为假', () {
      const empty = <ui.DisplayFeature>[];
      final correct = foldFeaturesForPosture(
        empty,
        foldPostureForAngle(null),
        kMateX2Landscape,
      );
      expect(
        identical(correct, empty),
        isTrue,
        reason: 'unknown 必须 fail-open（原样返回平台那份列表）',
      );
      // 错误实现：unknown 当 halfOpened 处理
      final wrong = foldFeaturesForPosture(
        empty,
        FoldPosture.halfOpened,
        kMateX2Landscape,
      );
      expect(
        identical(wrong, empty),
        isFalse,
        reason: '若这里为 true，说明用例抓不住"unknown 当半折"这个错误',
      );
      // 而且这条差异**真的会改布局**（不是看不见的差异）
      final band = horizontalObstructingBand(wrong, kMateX2Landscape);
      expect(band, isNotNull);
      final fullScreen = Rect.fromLTWH(
        0,
        0,
        kMateX2Landscape.width,
        kMateX2Landscape.height,
      );
      expect(
        overlapPx2(fullScreen, band!),
        greaterThan(0),
        reason: '错误的合成带会把整页内容判成"压在折痕上"',
      );
    });

    testWidgets('外部来源给 third-party 通道：非 Android 宿主**不建通道**且恒 unknown', (
      tester,
    ) async {
      // 生产用的是 `FoldPostureFeed.forHost()`；测试进程里 `FLUTTER_TEST` 已置位
      final feed = FoldPostureFeed.forHost();
      expect(
        feed,
        isA<NullFoldPostureFeed>(),
        reason: '`FLUTTER_TEST` 下必须是 null 实现（连通道对象都不建）',
      );
      expect(feed, isNot(isA<PlatformFoldPostureFeed>()));
      final readings = await feed.readings.toList();
      expect(readings, hasLength(1));
      expect(readings.single, FoldPostureReading.none);
      expect(readings.single.posture, FoldPosture.unknown);
    });

    testWidgets('★ unknown ⇒ 与"今天"完全一致：不多包 MediaQuery、master 占满整页', (
      tester,
    ) async {
      final feed = _FakeFeed();
      addTearDown(feed.close);
      await _pump(tester, size: kMateX2Landscape, feed: feed);

      // 没有读数（AsyncLoading）⇒ unknown
      final baseLayers = _mediaQueryLayers(tester);
      expect(_featuresAtMaster(tester), isEmpty);
      var master = tester.getRect(find.byKey(const Key('fold-master')));
      expect(master.height, kMateX2Landscape.height, reason: '不避让 ⇒ 整页');

      // 明确喂一个 unknown
      await _push(tester, feed, FoldPostureReading.none);
      expect(
        _mediaQueryLayers(tester),
        baseLayers,
        reason: 'unknown 不许新增任何 MediaQuery 层（= 零新增 render object）',
      );
      expect(_featuresAtMaster(tester), isEmpty);

      // 明确喂一个"摊平"（实测 179.34°）
      await _push(
        tester,
        feed,
        const FoldPostureReading(
          angleDegrees: 179.34,
          source: FoldPostureSource.hingeAngle,
          subscribed: true,
        ),
      );
      expect(_mediaQueryLayers(tester), baseLayers);
      expect(_featuresAtMaster(tester), isEmpty);
      master = tester.getRect(find.byKey(const Key('fold-master')));
      expect(master.height, kMateX2Landscape.height);
    });

    testWidgets('★ 半折（实测 86.80°）⇒ 恰好多一层 MediaQuery，内容不跨折痕带（px²=0）', (
      tester,
    ) async {
      final feed = _FakeFeed();
      addTearDown(feed.close);
      await _pump(tester, size: kMateX2Landscape, feed: feed);
      final baseLayers = _mediaQueryLayers(tester);
      expect(_featuresAtMaster(tester), isEmpty);

      await _push(
        tester,
        feed,
        const FoldPostureReading(
          angleDegrees: 86.80,
          postureCode: 0.51,
          source: FoldPostureSource.posture,
          subscribed: true,
        ),
      );

      // ① 合成带确实进了 MediaQuery，且**只多一层**
      expect(_mediaQueryLayers(tester), baseLayers + 1);
      final features = _featuresAtMaster(tester);
      expect(features, hasLength(1));
      final band = features.single.bounds;
      expect(band, syntheticFoldBand(kMateX2Landscape));
      expect(features.single.type, ui.DisplayFeatureType.fold);

      // ② 机制量：内容块 Rect 与折痕带 Rect 的**交集 px² = 0**
      final master = tester.getRect(find.byKey(const Key('fold-master')));
      expect(
        overlapPx2(master, band),
        0.0,
        reason: 'master $master 压在折痕带 $band 上',
      );
      expect(rectHitsBands(master, <Rect>[band]), isFalse);
      // 内容块真的被挤到一侧（不是"整页恰好没压线"）
      expect(master.height, band.top);
      expect(master.height, lessThan(kMateX2Landscape.height));
    });

    testWidgets('竖屏半折（同一个物理折痕）⇒ 竖带，内容块同样 px²=0', (tester) async {
      final feed = _FakeFeed();
      addTearDown(feed.close);
      await _pump(tester, size: kMateX2Portrait, feed: feed);
      await _push(
        tester,
        feed,
        const FoldPostureReading(
          angleDegrees: 42.20,
          source: FoldPostureSource.posture,
          subscribed: true,
        ),
      );
      final band = _featuresAtMaster(tester).single.bounds;
      expect(band, syntheticFoldBand(kMateX2Portrait));
      final master = tester.getRect(find.byKey(const Key('fold-master')));
      expect(overlapPx2(master, band), 0.0);
      expect(master.width, band.left);
    });

    testWidgets('完全合上（实测 1.2°）⇒ 不合成带（与摊平一样 fail-open）', (
      tester,
    ) async {
      final feed = _FakeFeed();
      addTearDown(feed.close);
      await _pump(tester, size: kMateX2Landscape, feed: feed);
      final baseLayers = _mediaQueryLayers(tester);
      await _push(
        tester,
        feed,
        const FoldPostureReading(
          angleDegrees: 1.2,
          source: FoldPostureSource.posture,
          subscribed: true,
        ),
      );
      expect(_mediaQueryLayers(tester), baseLayers);
      expect(_featuresAtMaster(tester), isEmpty);
    });

    testWidgets('关掉 enabled ⇒ 恒等于 child（反向验证用的开关有效）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: FoldPostureLayout(
            enabled: false,
            child: SizedBox(key: Key('off-child')),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('off-child')), findsOneWidget);
    });
  });
}
