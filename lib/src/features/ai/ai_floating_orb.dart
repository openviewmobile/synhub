// AI 助手悬浮球：**可拖动、贴边吸附、向边缘一滑就收起、反方向一滑再展开**。
//
// 为什么不是"固定在右上角的图标"（用户原话："AI工具可以做成一个能拖动改变位置的
// 悬浮球，并且可以吸附在屏幕左右两边，手指滑动展开和隐藏"）：
//   * 手机上一只手只能舒适地够到屏幕的**下半部分和两侧**，右上角的图标对拇指是
//     最远的地方 —— 阅读器里"划词问 AI"又是高频动作，位置必须由用户自己定；
//   * 内容本身要占满屏幕（阅读器没有多余空间放常驻按钮），所以 AI 只留一个球，
//     不想看到它的时候滑一下就收进侧边。
//
// 交互契约（都有单测钉住）：
//   * **拖动**：跟着手指走，松手后动画吸附到**最近的左边或右边**；
//   * **收起**：松手时朝该侧边缘的拖动距离超过 [hideDragDistance]，球滑进屏幕
//     边缘只留一条 20dp 的把手（`collapsed`）；
//   * **展开**：把手状态下向外拖超过同样阈值（或点一下把手）→ 动画展开回完整球；
//   * **点击**：完整球点一下 → [onTap]（打开 AI 面板）；把手点一下只展开，不误触
//     发请求。
//
// 位置会**落库**（`kAiOrbKey`）：用户把它挪到哪、收没收起，下次进来还在那儿。
// 换句话说，这个组件对"用户偏好"是持久的，但对"页面"是无状态的。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/settings/app_settings.dart';
import '../../core/theme/app_tokens.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';

/// 球贴在哪一边
enum OrbSide {
  left(0),
  right(1);

  const OrbSide(this.code);

  final int code;

  static OrbSide fromCode(int code) => code == 0 ? OrbSide.left : OrbSide.right;
}

/// 悬浮球的位置与状态（可持久化）
@immutable
class AiOrbState {
  const AiOrbState({
    this.side = OrbSide.right,
    this.t = 0.62,
    this.collapsed = false,
  });

  /// 贴边方向
  final OrbSide side;

  /// 垂直位置：0 = 顶部，1 = 底部（比例，跟屏幕高度无关）
  final double t;

  /// 是否收起成边缘把手
  final bool collapsed;

  AiOrbState copyWith({OrbSide? side, double? t, bool? collapsed}) =>
      AiOrbState(
        side: side ?? this.side,
        t: t ?? this.t,
        collapsed: collapsed ?? this.collapsed,
      );

  /// `'right|0.62|0'`；坏数据一律回默认值（**不抛**：设置项坏掉不该白屏）
  static AiOrbState parse(String? raw) {
    if (raw == null || raw.isEmpty) return const AiOrbState();
    final parts = raw.split('|');
    if (parts.length < 2) return const AiOrbState();
    final t = double.tryParse(parts[1]);
    if (t == null || t.isNaN) return const AiOrbState();
    return AiOrbState(
      side: parts[0] == 'left' ? OrbSide.left : OrbSide.right,
      t: t.clamp(0.0, 1.0),
      collapsed: parts.length > 2 && parts[2] == '1',
    );
  }

  String encode() =>
      '${side == OrbSide.left ? 'left' : 'right'}|${t.toStringAsFixed(3)}'
      '|${collapsed ? 1 : 0}';

  @override
  bool operator ==(Object other) =>
      other is AiOrbState &&
      other.side == side &&
      other.t == t &&
      other.collapsed == collapsed;

  @override
  int get hashCode => Object.hash(side, t, collapsed);
}

/// 悬浮球位置（首次用到时从设置里读一次）
final aiOrbProvider = NotifierProvider<AiOrbNotifier, AiOrbState>(
  AiOrbNotifier.new,
);

class AiOrbNotifier extends Notifier<AiOrbState> {
  @override
  AiOrbState build() => const AiOrbState();

  /// 读落库的位置。
  ///
  /// 刻意**不做**"只读一次"的标记：notifier 可能被 `invalidate` 重建
  /// （主题切换、测试里换实例……），而标记会跟着旧实例残留成 true，
  /// 于是新实例永远读不到盘、一直用默认值 —— 这个坑真踩过。
  /// 读一次设置是很便宜的本地查询，重复读的代价小于"位置莫名回到右边"。
  ///
  /// 唯一要防的是**竞态**：读盘期间用户已经在拖球了，那就别拿旧值盖掉。
  Future<void> preload() async {
    final raw = await ref.read(settingsServiceProvider).aiOrbRaw();
    if (!ref.mounted) return;
    if (state != const AiOrbState()) return;
    state = AiOrbState.parse(raw);
  }

  /// 拖动过程中的**临时**位置：不落库（一次拖动会调几十次）
  void preview(AiOrbState state) => this.state = state;

  /// 松手后的最终位置：落库
  Future<void> settle(AiOrbState state) async {
    this.state = state;
    await ref.read(settingsServiceProvider).setAiOrbRaw(state.encode());
  }
}

/// 悬浮球本体。
///
/// 放在宿主页面的 `Stack` 里（`Positioned.fill` 自己撑满），空白处**不拦截**手势，
/// 所以它不会挡住下面的内容。
class AiFloatingOrb extends ConsumerStatefulWidget {
  const AiFloatingOrb({
    super.key,
    required this.onTap,
    this.diameter = 48,
    this.margin = Gap.sm,
    this.tooltip = '',
    this.busy = false,
  });

  /// 点完整球要做的事（把手状态下点击只展开）
  final VoidCallback onTap;

  final double diameter;

  /// 离屏幕边缘的最小留白
  final double margin;

  /// 悬浮球提示文案；留空用「AI 助手」（按当前语言取）
  final String tooltip;

  /// 正在准备（例如 PDF 在读文字）：球上转圈，并且点它不再触发 [onTap]，
  /// 免得用户连点堆起好几个请求
  final bool busy;

  @override
  ConsumerState<AiFloatingOrb> createState() => _AiFloatingOrbState();
}

class _AiFloatingOrbState extends ConsumerState<AiFloatingOrb> {
  /// 收起到边缘后还露在外面的宽度。
  ///
  /// 不能太窄：收起后**只有这一段能点**（球身已经被屏幕边缘裁掉），
  /// 20dp 点起来太勉强，26dp 既能看出是个把手又不误触。
  static const double _handleWidth = 26;

  /// 松手时"朝边缘这一下"拖多远才算要收起 / 展开。
  ///
  /// 取 24dp 是量出来的：球停在贴边的位置上时，离屏幕边缘只剩 `margin`（8dp），
  /// 手指最多也就能再往边上推 30dp 左右 —— 阈值比这还高的话，用户"往边上一推"
  /// 永远触发不了收起（真机上就是这么发现的）。24dp 既能轻松触发，又不至于
  /// 把正常的左右拖动误判成收起。
  static const double hideDragDistance = 24;

  /// 拖动中：不加动画（跟手），松手后才动画吸附
  bool _dragging = false;

  /// 拖动中球的**实际**左上角（跟随手指的自由位置）。
  ///
  /// 为什么要有它：球闲下来时只在"贴左 / 贴右"两个位置上，但拖动过程中必须
  /// 能跟着手指走到任意位置 —— 早期版本只按**单个事件的位移**判断要不要换边，
  /// 结果真机上手指划了半屏、球却纹丝不动（事件位移都是几个像素），单测里
  /// 一步 -280px 的假手势又恰好能过。现在改成累计实际位置，单测也补了
  /// "多步小位移"的用例。
  double? _dragLeft;
  double? _dragTop;

  /// 拖动起点（松手吸附要用）
  double _startLeft = 0;
  double _startTop = 0;

  /// 本次拖动累计的"朝当前贴边方向"的水平位移（正 = 朝屏幕里，负 = 朝边缘外）
  double _edgeRun = 0;

  @override
  void initState() {
    super.initState();
    // 首次使用读一次落库位置
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(aiOrbProvider.notifier).preload();
    });
  }

  /// 闲下来时的左坐标（由 side/collapsed 决定）
  double _restLeft(AiOrbState state, double w, double d) {
    final visible = state.collapsed ? _handleWidth : d;
    return state.side == OrbSide.left
        ? (state.collapsed ? -d + visible : widget.margin)
        : (state.collapsed ? w - visible : w - d - widget.margin);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(aiOrbProvider);
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          final h = box.maxHeight;
          final d = widget.diameter;
          final maxTop = math.max(0.0, h - d);
          final left = _dragLeft ?? _restLeft(state, w, d);
          final top =
              _dragTop ?? (state.t * maxTop).clamp(0.0, maxTop).toDouble();

          return Stack(
            children: [
              AnimatedPositioned(
                duration: _dragging
                    ? Duration.zero
                    : const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                left: left,
                top: top,
                width: d,
                height: d,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (widget.busy) return;
                    if (state.collapsed) {
                      HapticFeedback.selectionClick();
                      ref
                          .read(aiOrbProvider.notifier)
                          .settle(state.copyWith(collapsed: false));
                    } else {
                      trackView(UsageModule.ai, screen: 'assistant');
                      widget.onTap();
                    }
                  },
                  onPanStart: (_) {
                    setState(() {
                      _dragging = true;
                      _edgeRun = 0;
                      _startLeft = left;
                      _startTop = top;
                      _dragLeft = left;
                      _dragTop = top;
                    });
                  },
                  onPanUpdate: (e) {
                    // 手指走到哪球就到哪（横向允许顶/推出边缘一点，方便表达
                    // "我要把它收起来"）
                    final rawLeft = (_dragLeft ?? _startLeft) + e.delta.dx;
                    final minLeft = -d * 0.6;
                    final maxLeft = w - d * 0.4;
                    setState(() {
                      _dragLeft = rawLeft.clamp(minLeft, maxLeft).toDouble();
                      _dragTop = ((_dragTop ?? _startTop) + e.delta.dy)
                          .clamp(0.0, maxTop)
                          .toDouble();
                      // 朝"当前贴边方向"累计：正 = 朝屏幕里，负 = 朝边缘外
                      _edgeRun += state.side == OrbSide.left
                          ? e.delta.dx
                          : -e.delta.dx;
                    });
                  },
                  onPanEnd: (_) async {
                    final current = ref.read(aiOrbProvider);
                    final dl = _dragLeft ?? _startLeft;
                    final dt = _dragTop ?? _startTop;
                    final side = (dl + d / 2) < w / 2
                        ? OrbSide.left
                        : OrbSide.right;
                    // 朝边缘拖够了 → 收起；从把手朝外拖够了 → 展开。
                    // 两者用同一个阈值，手感对称。
                    final collapse =
                        !current.collapsed && _edgeRun <= -hideDragDistance;
                    final expand =
                        current.collapsed && _edgeRun >= hideDragDistance;
                    final next = current.copyWith(
                      side: side,
                      t: maxTop <= 0 ? 0 : (dt / maxTop).clamp(0.0, 1.0),
                      collapsed: collapse
                          ? true
                          : (expand ? false : current.collapsed),
                    );
                    if (next.collapsed != current.collapsed) {
                      HapticFeedback.selectionClick();
                    }
                    setState(() {
                      _dragging = false;
                      _dragLeft = null;
                      _dragTop = null;
                    });
                    await ref.read(aiOrbProvider.notifier).settle(next);
                  },
                  child: Tooltip(
                    message: state.collapsed
                        ? context.t.aiExpandAssistant
                        : (widget.tooltip.isEmpty
                              ? context.t.aiAssistant
                              : widget.tooltip),
                    child: _OrbBody(
                      collapsed: state.collapsed,
                      side: state.side,
                      handleWidth: _handleWidth,
                      diameter: d,
                      busy: widget.busy,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 球的外观：品牌渐变 + 柔光 + 图标；收起时只画露出来的那一条
class _OrbBody extends StatelessWidget {
  const _OrbBody({
    required this.collapsed,
    required this.side,
    required this.handleWidth,
    required this.diameter,
    this.busy = false,
  });

  final bool collapsed;
  final OrbSide side;
  final double handleWidth;
  final double diameter;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Widget icon = busy
        ? SizedBox(
            width: collapsed ? 12 : 18,
            height: collapsed ? 12 : 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: scheme.onPrimaryContainer,
            ),
          )
        : Icon(
            Icons.auto_awesome,
            size: collapsed ? 14 : 22,
            color: scheme.onPrimaryContainer,
          );
    // 收起时是"贴在侧边的把手"（只有朝屏幕里那一侧是圆角），展开时是正圆。
    // 注意：`shape` 和 `borderRadius` 不能同时给，给了会断言失败。
    final radius = collapsed
        ? BorderRadius.horizontal(
            left: side == OrbSide.right
                ? const Radius.circular(12)
                : Radius.zero,
            right: side == OrbSide.left
                ? const Radius.circular(12)
                : Radius.zero,
          )
        : null;
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: collapsed ? BoxShape.rectangle : BoxShape.circle,
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primaryContainer, scheme.primary],
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.28),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Center(
        child: Padding(
          padding: EdgeInsets.only(
            left: collapsed && side == OrbSide.left ? 2 : 0,
            right: collapsed && side == OrbSide.right ? 2 : 0,
          ),
          child: icon,
        ),
      ),
    );
  }
}
