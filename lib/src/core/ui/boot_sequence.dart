// 科幻层组件 ④：启动自检（BootSequence）—— 英雄页的"开场"。
//
// 逐条打出一串系统遥测（版本/协议/加密握手），配一条扫描进度；总时长约 1.5s，
// 点一下可以立刻跳过。**只在真机 + 允许动效时出现**（测试与"减少动效"下自动跳过），
// 因为它是纯装饰，不能影响可用性与测试稳定性。
import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'hud_widgets.dart';

class BootSequence extends StatefulWidget {
  const BootSequence({
    super.key,
    required this.child,
    this.lines = const [
      'SELF-TEST · MEM OK',
      'LINK · SRM 1.3 HANDSHAKE',
      'CRYPTO · AES-256 READY',
      'HUD · ONLINE',
    ],
    this.duration = const Duration(milliseconds: 1500),
    this.enabled,
  });

  final Widget child;
  final List<String> lines;
  final Duration duration;

  /// 默认：真机 + 允许动效才播；测试/减少动效直接显示内容
  final bool? enabled;

  /// 是否该播（给测试/调用方复用）
  static bool get shouldPlay => !AppEffects.isFlutterTest && Motion.enabled;

  @override
  State<BootSequence> createState() => _BootSequenceState();
}

class _BootSequenceState extends State<BootSequence>
    with SingleTickerProviderStateMixin {
  late final bool _play = widget.enabled ?? BootSequence.shouldPlay;
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.resolve(widget.duration),
  );
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (_play) {
      _c.forward();
      _timer = Timer(widget.duration + const Duration(milliseconds: 120), () {
        if (mounted) setState(() => _done = true);
      });
    } else {
      _done = true;
    }
  }

  bool _done = false;

  void _skip() {
    _timer?.cancel();
    _c.value = 1;
    setState(() => _done = true);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hud = HudTokens.of(context);
    return Stack(
      children: [
        widget.child,
        if (_play && !_done)
          Positioned.fill(
            child: GestureDetector(
              onTap: _skip,
              behavior: HitTestBehavior.opaque,
              child: ColoredBox(
                color: hud.deep,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.xl),
                    child: AnimatedBuilder(
                      animation: _c,
                      builder: (context, _) {
                        final shown = (_c.value * (widget.lines.length + 0.999))
                            .floor()
                            .clamp(0, widget.lines.length);
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                PulseDot(
                                  pulsing: true,
                                  size: 4,
                                  color: scheme.primary,
                                ),
                                const SizedBox(width: Gap.sm),
                                TelemetryLabel(
                                  'SYSTEM BOOT',
                                  size: 11,
                                  letterSpacing: 1.6,
                                  color: scheme.primary,
                                ),
                              ],
                            ),
                            const SizedBox(height: Gap.lg),
                            for (var i = 0; i < shown; i++) ...[
                              TelemetryLabel(
                                '> ${widget.lines[i]}',
                                size: 11,
                                letterSpacing: 0.6,
                                color: i == shown - 1
                                    ? scheme.onSurface
                                    : hud.meta,
                              ),
                              const SizedBox(height: Gap.xs),
                            ],
                            const SizedBox(height: Gap.md),
                            SizedBox(
                              width: 220,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: _c.value,
                                  minHeight: 3,
                                  backgroundColor: scheme.onSurface.withValues(
                                    alpha: 0.12,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: Gap.sm),
                            TelemetryLabel('TAP TO SKIP', size: 9),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
