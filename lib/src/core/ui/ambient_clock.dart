// 常驻动效的**唯一**帧源（r287 新增）。
//
// 背景（r287 实测，macOS Release，800x600 窗口 / DPR 2）：
//   * 连接页/聊天页静止时进程 CPU **35–55%**，`sample` 的 53% 落在
//     `io.flutter.raster`（Impeller 重扫整棵 layer tree）；
//   * 临时把 `AppEffects.ambientAllowed` 钉成 `false` 后，**帧数 = 0、CPU ≈ 0%**
//     ⇒ 这些 CPU 全部来自"常驻动效在不停地排帧"。
//
// 机制：此前每个常驻动效各自持有 `AnimationController(vsync: …)..repeat()`。
// `repeat()` 挂在 vsync 上 ⇒ **每个 vsync 都请求一帧**（`Ticker` →
// `scheduleFrameCallback`），而各处只把 `_phase.value` 的手动更新限到
// `AppEffects.ambientTick`（20fps）。于是：
//   * 限频只限住了"画什么"，没限住"排帧"⇒ 引擎永远停在 60fps；
//   * 多个组件各挂一个 ticker，它们的并集更不可能低于 vsync 频率；
//   * `IndexedStack` 保活的**非当前 tab** 也照排不误（`IndexedStack` 只停绘制，
//     不停 ticker）—— 实测树里有 5 个 `_FieldBackdropState(ticker active)`。
//
// 契约（改这块前必读）：
//   ① 相位只由 [AmbientClock] 的**一个** `Timer.periodic(ambientTick)` 推进
//      ⇒ 全应用常驻动效合计最多 20fps，**任何情况下都不排 vsync 帧**；
//   ② `AppEffects.ambientAllowed == false`（减少动效 / flutter_test）时
//      **一个定时器都不建**，静止页面的帧数 = 0；
//   ③ 只有**真正可见**的部件才订阅（`Visibility.of(context)`：`IndexedStack`
//      的非选中页返回 `false`）⇒ 保活但不可见的页面不再产生任何重绘请求；
//   ④ 定时器**没有**任何"重试/退避"语义，纯装饰；`subscribe/unsubscribe`
//      必须成对，否则时钟会因计数漂移而常开（有用例钉住）。
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../theme/app_tokens.dart';

/// 全应用共享的常驻动效时钟。
class AmbientClock extends ChangeNotifier {
  AmbientClock._();

  static final AmbientClock instance = AmbientClock._();

  Duration _elapsed = Duration.zero;
  Timer? _timer;
  int _subscribers = 0;

  /// 时钟是否在走（= 有没有定时器）。
  bool get running => _timer != null;

  /// 当前订阅者数量（用例据此断言"成对"）。
  int get subscriberCount => _subscribers;

  /// 自时钟启动以来推进的（名义）时间。
  Duration get elapsed => _elapsed;

  /// 订阅。只在第一个订阅者到来时建定时器。
  void subscribe() {
    _subscribers++;
    if (_timer == null) _restart();
  }

  /// 退订。最后一个订阅者离开时把定时器拆掉。
  void unsubscribe() {
    if (_subscribers == 0) return;
    _subscribers--;
    if (_subscribers == 0) _stop();
  }

  /// 设置变化（"减少动效"开关）后重估——常开时开表、常关时停表。
  void resync() {
    if (_subscribers > 0) _restart();
  }

  void _restart() {
    _stop();
    if (!AppEffects.ambientAllowed) return; // 契约 ②：不建表
    _timer = Timer.periodic(AppEffects.ambientTick, (_) {
      _elapsed += AppEffects.ambientTick;
      notifyListeners();
    });
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// [period] 内的相位，0..1（各部件周期不同，共用同一个时钟取模即可）。
  double phase(Duration period) {
    final p = period.inMicroseconds;
    if (p <= 0) return 0;
    return (_elapsed.inMicroseconds % p) / p;
  }

  @visibleForTesting
  void debugReset() {
    _stop();
    _subscribers = 0;
    _elapsed = Duration.zero;
  }
}

/// 常驻动效部件的公共接线：共享时钟 + 可见性门 + 减少动效开关。
///
/// 用法：`class _XState extends State<X> with AmbientAnimation`，
/// 实现 [ambientPeriod]，用 [ambientPhase] 驱动 repaint（`CustomPaint(repaint:)`
/// 或 `AnimatedBuilder(animation:)`），**不要再自己 new `AnimationController`**。
mixin AmbientAnimation<T extends StatefulWidget> on State<T> {
  /// 一圈的时长（相位在 0..1 之间循环）。
  Duration get ambientPeriod;

  /// 当前相位 0..1。可见且允许动效时才推进；不可见时停在最后的值。
  final ValueNotifier<double> ambientPhase = ValueNotifier<double>(0);

  bool _subscribed = false;

  /// 相位波形：默认锯齿（0→1 循环）；置 true 为三角波（0→1→0）。
  bool get ambientPingPong => false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // `Visibility.of` 会建立依赖 ⇒ 切 tab（IndexedStack）时本方法再次触发，
    // 可见性变化能实时启停（契约 ③）。
    syncAmbient();
  }

  /// 供"减少动效"监听器调用（设置变化时重估）。
  void syncAmbient() {
    final want = AppEffects.ambientAllowed && Visibility.of(context);
    if (want && !_subscribed) {
      AmbientClock.instance.subscribe();
      AmbientClock.instance.addListener(_onAmbientTick);
      _subscribed = true;
      _onAmbientTick();
    } else if (!want && _subscribed) {
      AmbientClock.instance.removeListener(_onAmbientTick);
      AmbientClock.instance.unsubscribe();
      _subscribed = false;
    }
  }

  void _onAmbientTick() {
    final p = AmbientClock.instance.phase(ambientPeriod);
    ambientPhase.value = ambientPingPong
        ? (p < 0.5 ? p * 2 : (1 - p) * 2)
        : p;
  }

  @override
  void dispose() {
    if (_subscribed) {
      AmbientClock.instance.removeListener(_onAmbientTick);
      AmbientClock.instance.unsubscribe();
      _subscribed = false;
    }
    ambientPhase.dispose();
    super.dispose();
  }
}
