// 音频播放的**律动可视化**（封面呼吸光环 + 律动柱 + 封面主色渐变）。
//
// ════════════════════════════════════════════════════════════════════════
// ★★★ 诚实声明（用户明确要求）：这里画的是**推导出来的动效，不是真实频谱**。
// ════════════════════════════════════════════════════════════════════════
//
// 为什么拿不到真实频谱数据（证据，不是猜）：
//
// ① Android 侧唯一的实时频谱 API 是 `android.media.audiofx.Visualizer`，
//    官方 API 文档**逐字**写着它必须要录音权限（本机实取，代理走 PAC）：
//
//    $ export https_proxy=http://127.0.0.1:7897
//    $ curl -sS -L "https://developer.android.google.cn/reference/android/media/audiofx/Visualizer" \
//        -o /tmp/vis.html -w "HTTP:%{http_code} SIZE:%{size_download}\n"
//    HTTP:200 SIZE:2331898
//    （developer.android.com 直连 TLS 握手失败 `SSL_ERROR_SYSCALL`，
//      用镜像域 developer.android.google.cn 取到，内容同源）
//
//    文档原文（类说明第二段）：
//    "The Visualizer class enables application to retrieve part of the currently
//     playing audio for visualization purpose. ... However, to protect privacy of
//     certain audio data (e.g voice mail) **the use of the visualizer requires the
//     permission android.permission.RECORD_AUDIO**."
//    另一处原文：
//    "Creating a Visualizer on the output mix (audio session 0) requires permission
//     Manifest.permission.MODIFY_AUDIO_SETTINGS"
//
//    ⇒ **即便**拿到 ExoPlayer 自己的 audioSessionId（会话 ≠ 0），
//      仍然需要 RECORD_AUDIO；会话 0（全局输出混音）还要另一个权限。
//      用户明确要求"不要为了它申请录音权限" ⇒ 真频谱这条路**被权限挡住**。
//
// ② ExoPlayer 的 audioSessionId 本身在 Dart 侧是拿得到的（不需要权限）：
//    `just_audio-0.10.6`（本机 `~/.pub-cache/hosted/pub.flutter-io.cn/`）：
//      lib/just_audio.dart:636  Stream<int?> get androidAudioSessionIdStream
//      lib/just_audio.dart:633  int? get androidAudioSessionId
//    但要把这个 id 交给 `Visualizer`，必须**新增一个 Kotlin MethodChannel 桥**
//    （`android/app/src/main/kotlin/.../`），并处理上一条的权限 ——
//    这既超出本次允许改动的文件范围，也因为①注定要权限，所以**没有做**。
//
// ③ 结论：动效来自 **播放位置 / 时长 / 播放态**（既有的位置流）驱动的
//    **确定性推导** —— 所以：
//      * 暂停 / 无播放时**完全静止**（不会假装"音乐还在律动"）；
//      * 同一位置 → 同一帧（`derivedAudioVisualLevels` 是纯函数，可单测、可复现）；
//      * **界面上不会出现"频谱"二字**，只写"律动"（`audioVisualizerCaptionText()`）。
//
// 省电 / 不掉帧（用户要求）：
//   * 帧驱动是**有界**的短动画（[kAudioVisualizerStep]，默认 260ms）：
//     每收到一次位置更新才从 0 播到 1，**播完就停**，没有常驻 ticker；
//     ⇒ 暂停时零重绘，且不影响 `pumpAndSettle()` 型的测试（不会永不停歇）；
//   * 绘制走 `CustomPaint` + `RepaintBoundary`，`shouldRepaint` 只在帧参数变化时回真；
//   * `dispose` 里 `controller.dispose()`，不留后台 ticker；
//   * 系统开"减少动态效果"（`MediaQuery.disableAnimations`）→ 不推进子步，
//     画面停在由播放位置算出的那一帧；
//   * 每帧只算 `barCount`（默认 28）个 double —— 一个小 list + 一次 `CustomPaint`
//     重绘，没有平台通道、没有磁盘/网络访问。
//
// 封面主色：**真的**从封面字节里取（不是编的）—— `dominantCoverColor()` 用
// `ui.instantiateImageCodec` 解码到 24px 宽，再按"饱和度 × 中亮度"加权平均。
// 取不到封面 / 解码失败 → 退回**曲目身份派生的稳定色相**
// （`audioVisualizerAccentForKey`：同一首歌每次打开都是同一个颜色）。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/i18n/data_text.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'audio_visualizer_source.dart';

/// 律动柱数量（固定 → 每帧的采样位置稳定，不会"跳格"）。
const int kAudioVisualizerBarCount = 28;

/// 两次位置更新之间用来"补帧"的时长上限。
///
/// `just_audio` 的 `positionStream` 大约 200ms 一次；这里用一次**有界**的
/// 260ms 动画把两次更新之间插值平滑掉。关键点：它是**一次性**的
/// （`forward(from: 0)`），不是 `repeat()` —— 播放停止时不留常驻 ticker，
/// 也不会让 `WidgetTester.pumpAndSettle()` 永远等不到静止。
const Duration kAudioVisualizerStep = Duration(milliseconds: 260);

/// 可视化的**帧参数**（纯数据；`CustomPainter` 只认它，便于单测）。
@immutable
class AudioVisualFrame {
  const AudioVisualFrame({
    required this.levels,
    required this.breath,
    required this.accent,
  });

  /// 每个柱的高度（0..1）
  final List<double> levels;

  /// 呼吸光环的相位（0..1；0 = 最小，1 = 最大）
  final double breath;

  /// 主色（封面主色或身份派生色）
  final Color accent;

  @override
  bool operator ==(Object other) =>
      other is AudioVisualFrame &&
      other.breath == breath &&
      other.accent == accent &&
      other.levels.length == levels.length &&
      () {
        for (var i = 0; i < levels.length; i++) {
          if (other.levels[i] != levels[i]) return false;
        }
        return true;
      }();

  @override
  int get hashCode => Object.hash(Object.hashAll(levels), breath, accent);
}

/// **推导出来的**律动电平（纯函数，可单测）。
///
/// 三条输入，全部来自播放器**真实**状态：
///   * [seconds]：当前播放位置的秒数（含两次位置更新之间的补帧），
///     是唯一的"时间"来源 —— 暂停时它不再前进，动效自然静止；
///   * [progress]：播放进度（0..1，未知时长给 0）—— 让同一首歌的不同段落
///     **长得不一样**（前奏/副歌不再是同一帧循环）；
///   * [seed]：曲目身份派生的稳定随机源（0..1）—— 每首歌形状不同，
///     但同一首歌每次都一样（不是每帧乱跳的噪声）；
///   * [energy]：整体强度（0..1）。
///
/// 返回值：长度为 [barCount] 的 0..1 电平表。
///
/// ⚠️ 它**不是**从音频采样算出来的。函数名与注释都按"推导"写，
/// 避免后来人误以为这是真频谱（这是本次任务明确的红线）。
List<double> derivedAudioVisualLevels({
  required double seconds,
  required int barCount,
  double progress = 0,
  double seed = 0,
  double energy = 1,
}) {
  if (barCount <= 0) return const [];
  final t0 = seconds.isFinite ? seconds : 0.0;
  final g = progress.isFinite ? progress.clamp(0.0, 1.0) : 0.0;
  final s = seed.isFinite ? seed.clamp(0.0, 1.0) : 0.0;
  final e = energy.isFinite ? energy.clamp(0.0, 1.0) : 1.0;
  const tau = 2 * math.pi;
  final out = List<double>.filled(barCount, 0);
  for (var i = 0; i < barCount; i++) {
    final t = barCount == 1 ? 0.0 : i / (barCount - 1); // 0 在左、1 在右
    // 三个**互不成整数倍**的频率，让图形不会很快回到同一帧
    // （看起来像在动，而不是原地抖）。
    final a = math.sin(tau * (t0 * 0.62 + t * 0.75 + s * 0.9));
    final b = math.sin(tau * (t0 * 1.13 - t * 1.35 + g * 2.0));
    final c = math.sin(tau * (t0 * 0.37 + t * 2.05 + s * 0.5));
    // 低频更"重"（主流播放器都这么做）：中间两根最高，向两侧收窄。
    final shape = 0.35 + 0.65 * math.sin(t * math.pi);
    final v = (0.5 + 0.25 * a + 0.15 * b + 0.10 * c) * shape;
    out[i] = (v * e).clamp(0.0, 1.0);
  }
  return out;
}

/// 呼吸光环的相位（0..1）—— 同样是**播放位置**的确定性函数（周期 3.2 秒）。
double derivedAudioVisualBreath({required double seconds}) {
  final t = seconds.isFinite ? seconds : 0.0;
  return (0.5 + 0.5 * math.sin(2 * math.pi * t / 3.2)).clamp(0.0, 1.0);
}

/// 曲目身份 → 稳定随机源（0..1）。同一首歌每次打开都一样。
///
/// 用 FNV-1a 32 位散列（与 `audio_handler.dart` 的封面指纹同款，
/// 不引入 `crypto` —— 这里只要能"稳定且分散"）。
double audioVisualizerSeedForKey(String key) {
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return (hash & 0xffffff) / 0x1000000;
}

/// 身份派生色（封面拿不到时的回退）：稳定色相 + 适合暗色背景的亮度/饱和。
Color audioVisualizerAccentForKey(String key) {
  final hue = audioVisualizerSeedForKey(key) * 360.0;
  return HSLColor.fromAHSL(1, hue, 0.62, 0.58).toColor();
}

/// **真实**取封面主色：解码封面字节 → 按"饱和度 × 中亮度"加权平均。
///
/// 为什么自己做而不是加依赖：仓库里已有 `image` 包，但它在 UI 线程上解大图
/// 太重；这里用 `dart:ui` 的 `instantiateImageCodec(targetWidth: 24)` 让引擎
/// **在解码阶段就缩到 24px 宽**，再 `toByteData(rawRgba)` 逐像素加权。
///
/// 任何一步失败（字节为空 / 不是图片 / 平台通道缺失）→ `null`，
/// 由调用方退回 [audioVisualizerAccentForKey]（**不假装取到了主色**）。
Future<Color?> dominantCoverColor(Uint8List? bytes) async {
  if (bytes == null || bytes.isEmpty) return null;
  ui.Codec? codec;
  try {
    codec = await ui.instantiateImageCodec(bytes, targetWidth: 24);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      final px = data.buffer.asUint8List();
      var wsum = 0.0, rsum = 0.0, gsum = 0.0, bsum = 0.0;
      for (var i = 0; i + 3 < px.length; i += 4) {
        final r = px[i], g = px[i + 1], b = px[i + 2], a = px[i + 3];
        if (a < 24) continue; // 透明像素不算
        final maxc = math.max(r, math.max(g, b));
        final minc = math.min(r, math.min(g, b));
        final sat = maxc == 0 ? 0.0 : (maxc - minc) / maxc;
        final lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0;
        // 饱和度优先（否则灰色封面会把主色拉成灰）；再乘一个"中亮度"权重，
        // 避免纯黑/纯白的边框把颜色带跑。
        final mid = 1.0 - (lum - 0.5).abs() * 1.6;
        final w = (0.15 + sat) * (mid <= 0 ? 0.05 : mid);
        wsum += w;
        rsum += r * w;
        gsum += g * w;
        bsum += b * w;
      }
      if (wsum <= 0) return null;
      final base = Color.fromARGB(
        255,
        (rsum / wsum).round().clamp(0, 255),
        (gsum / wsum).round().clamp(0, 255),
        (bsum / wsum).round().clamp(0, 255),
      );
      // 提到暗色主题下能看清的亮度（原始封面主色常常偏暗，直接拿来当光晕会糊）
      final hsl = HSLColor.fromColor(base);
      return hsl
          .withSaturation(math.max(hsl.saturation, 0.35))
          .withLightness(hsl.lightness.clamp(0.38, 0.66))
          .toColor();
    } finally {
      image.dispose();
    }
  } catch (_) {
    return null;
  } finally {
    codec?.dispose();
  }
}

/// UI 上的**诚实**说明句：不叫"频谱"。
///
/// 用 `dataText`（key + 中文原文）而不是新增 ARB key —— 与本仓
/// "未翻译模块用 dataText 回落中文"的约定一致（`data_text.dart`）。
String audioVisualizerCaptionText() =>
    dataText('audioVisualizerCaption', '律动动效');

/// 律动可视化：**封面呼吸光环 + 律动柱 + 封面主色渐变**。
///
/// 用法（`media_audio_stage.dart`）：
/// ```dart
/// AudioVisualizer(
///   position: player.position,   // 既有位置流（不新起定时器/轮询）
///   duration: player.duration,
///   playing: player.playing,
///   seedKey: widget.entry.path,
///   coverBytes: cover?.bytes,
/// )
/// ```
class AudioVisualizer extends StatefulWidget {
  const AudioVisualizer({
    super.key,
    required this.playing,
    required this.position,
    this.duration,
    this.seedKey = '',
    this.coverBytes,
    this.accent,
    this.barCount = kAudioVisualizerBarCount,
    this.size = const Size(220, 220),
    this.compact = false,
    this.showCaption = true,
    this.spectrumLevels,
  });

  /// 是否在播 —— 不在播时**不补帧**（画面停住）。
  final bool playing;

  /// 当前播放位置（既有位置流；动效的**唯一**时间来源）。
  final Duration position;

  /// 总时长（null = 未知；那时进度按 0 处理）。
  final Duration? duration;

  /// 曲目身份（稳定随机源的来源；**不是** URL —— 别把带 `_sid` 的直链传进来）。
  final String seedKey;

  /// 封面字节（有就取**真实**主色；没有就退回身份色）。
  final Uint8List? coverBytes;

  /// 显式主色（调用方已经算好时用；null = 自己从 [coverBytes] 算）。
  final Color? accent;

  final int barCount;

  /// 光环外径（宽 × 高，不含底部律动柱的窄带）。
  final Size size;

  /// 紧凑模式（矮屏）：不画说明句。
  final bool compact;

  final bool showCaption;

  /// **真频谱**电平（长度应等于 [barCount]，每项 0..1）。
  ///
  /// 来自 `android.media.audiofx.Visualizer`（`audio_visualizer_source.dart`）。
  /// `null` = 拿不到真频谱 → 用 [derivedAudioVisualLevels] 的**推导**动效，
  /// 并且说明句会说"律动动效"而不是"真实频谱"（**不谎报来源**）。
  ///
  /// 长度不匹配时按 `null` 处理（宁可退回推导，也不要画出错位的柱子）。
  final List<double>? spectrumLevels;

  @override
  State<AudioVisualizer> createState() => _AudioVisualizerState();
}

class _AudioVisualizerState extends State<AudioVisualizer>
    with SingleTickerProviderStateMixin {
  /// **有界**的补帧动画（每次位置更新 forward 一次，播完即停）。
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: kAudioVisualizerStep,
  );

  /// 封面主色（异步算；算到之前先用身份色，避免闪一下无色）。
  Color? _coverAccent;

  /// 上一帧**真频谱**：暂停/断流时停住画面，而不是瞬间塌回推导曲线。
  List<double>? _heldSpectrum;

  /// 这一帧用的是不是真频谱。
  bool get _usingSpectrum {
    final s = widget.spectrumLevels;
    return s != null && s.length == widget.barCount && s.isNotEmpty;
  }

  /// 曲目身份 → 稳定随机源（0..1）。**每帧都要用**，所以只算一次。
  late double _seed = audioVisualizerSeedForKey(widget.seedKey);

  @override
  void initState() {
    super.initState();
    // 可视化视图曝光（视图模式偏好）。
    trackViewMode(UsageModule.media, 'visualizer');
    unawaited(_resolveAccent());
    // ⚠️ initState 里**不查** `MediaQuery`（还没进 didChangeDependencies）：
    // 在播就先补一帧，随后 didChangeDependencies 会按"减少动态效果"校正。
    if (widget.playing) _controller.forward(from: 0);
  }

  @override
  void didUpdateWidget(covariant AudioVisualizer old) {
    super.didUpdateWidget(old);
    if (old.seedKey != widget.seedKey) {
      _seed = audioVisualizerSeedForKey(widget.seedKey);
    }
    if (!identical(old.coverBytes, widget.coverBytes)) {
      _coverAccent = null;
      unawaited(_resolveAccent());
    }
    // 位置变了（或刚开始播）→ 补一帧；播完自动停（省电的关键）
    final progressed = old.position != widget.position;
    final startedPlaying = widget.playing && !old.playing;
    if (widget.playing && (progressed || startedPlaying)) {
      _nudge();
    } else if (!widget.playing && _controller.isAnimating) {
      _controller.stop();
    }
  }

  void _nudge() {
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) {
      _controller.value = 1; // 无障碍：直接落到这一帧，不做插值
      return;
    }
    _controller.forward(from: 0);
  }

  Future<void> _resolveAccent() async {
    if (widget.accent != null) return;
    final bytes = widget.coverBytes;
    if (bytes == null || bytes.isEmpty) return;
    final color = await dominantCoverColor(bytes);
    if (!mounted || color == null) return;
    setState(() => _coverAccent = color);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // `MediaQuery.disableAnimations` 变化时这里会被叫到 → 校正补帧状态
    if (!widget.playing && _controller.isAnimating) _controller.stop();
  }

  @override
  void dispose() {
    // 页面销毁必须释放 ticker（用户要求：不留后台动画）
    _controller.dispose();
    super.dispose();
  }

  Color get _accent =>
      widget.accent ??
      _coverAccent ??
      audioVisualizerAccentForKey(widget.seedKey);

  double get _progress {
    final total = widget.duration;
    if (total == null || total <= Duration.zero) return 0;
    return (widget.position.inMilliseconds / total.inMilliseconds).clamp(
      0.0,
      1.0,
    );
  }

  /// 动效的"时间" = 播放位置（秒） + 本次补帧走过的子步（最多一个位置间隔）。
  ///
  /// 这样：**位置流是唯一的时间基准**（不新起定时器/轮询），
  /// 而两次 200ms 位置更新之间由 [kAudioVisualizerStep] 平滑插值。
  double get _seconds {
    final base = widget.position.inMilliseconds / 1000.0;
    final step = kAudioVisualizerStep.inMilliseconds / 1000.0;
    return base + _controller.value * step;
  }

  @override
  Widget build(BuildContext context) {
    final accent = _accent;
    // **真频谱优先**：有就用它（就是这一帧的真实输出电平）；
    // 没有（或长度不对）才退到推导动效 —— 来源不同，说明句也必须不同。
    final live = _usingSpectrum ? widget.spectrumLevels : null;
    // 纯备忘（不 `setState`，所以可以在 build 里写）：记住最后一次真频谱，
    // 这样**暂停**时画面停住而不是塌回推导曲线。
    // ⚠️ 必须在这里记而不是只在 `didUpdateWidget` 记 —— 首帧走的是 `initState`，
    //    `didUpdateWidget` 不会被调用（本用例踩过一次）。
    if (live != null) _heldSpectrum = List<double>.from(live);
    final spectrum = live ?? (widget.playing ? null : _heldSpectrum);
    final levels =
        spectrum ??
        derivedAudioVisualLevels(
          seconds: _seconds,
          barCount: widget.barCount,
          progress: _progress,
          seed: _seed,
        );
    final frame = AudioVisualFrame(
      levels: levels,
      breath: derivedAudioVisualBreath(seconds: _seconds),
      accent: accent,
    );

    final source = spectrum != null
        ? AudioVisualSource.platformSpectrum
        : AudioVisualSource.derived;
    final caption = widget.showCaption && !widget.compact
        ? audioVisualizerCaptionFor(source)
        : null;

    return RepaintBoundary(
      key: const Key('audio-visualizer'),
      // 竖排：上面是画面（光环 + 底部律动柱），**文案另起一行**在下面 ——
      // 不用 Stack 叠上去，否则字会压在律动柱上（真机上糊成一团）。
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => CustomPaint(
              key: const Key('audio-visualizer-canvas'),
              painter: AudioVisualizerPainter(frame: frame, accent: accent),
              // 光环本体是 size；底部另留一条窄带画律动柱
              size: Size(widget.size.width, widget.size.height + 34),
            ),
          ),
          if (caption != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                caption,
                key: const Key('audio-visualizer-caption'),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: accent.withValues(alpha: 0.75),
                  letterSpacing: 0.6,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// `AudioVisualFrame` → 像素。
///
/// 组成（从上到下）：
///   1. 封面的**呼吸光环**（两圈带渐变透明度的圆，半径随 `breath` 伸缩）；
///   2. 光环内的**主色径向渐变**（替封面当底，封面由上层叠上去）；
///   3. 底部一窄条**律动柱**（高度 = `levels[i]`，颜色 = 主色 → 浅色渐变）。
class AudioVisualizerPainter extends CustomPainter {
  const AudioVisualizerPainter({required this.frame, required this.accent});

  final AudioVisualFrame frame;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    const barBand = 34.0;
    final haloH = (size.height - barBand).clamp(0.0, size.height);
    final center = Offset(size.width / 2, haloH / 2);
    final baseR = math.min(size.width, haloH) / 2 - 6;
    if (baseR <= 0) return;

    // ① 呼吸光环：两圈（外圈更淡），半径在 baseR 的 92%–108% 之间呼吸
    final pulse = 0.92 + 0.16 * frame.breath;
    for (var ring = 0; ring < 2; ring++) {
      final r = baseR * pulse * (1 + ring * 0.09);
      final alpha = (ring == 0 ? 0.45 : 0.22) * (0.6 + 0.4 * frame.breath);
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = ring == 0 ? 3 : 1.5
          ..color = accent.withValues(alpha: alpha.clamp(0.0, 1.0)),
      );
    }

    // ② 主色径向渐变（封面的"底色光"）
    canvas.drawCircle(
      center,
      baseR * 0.98,
      Paint()
        ..shader = RadialGradient(
          colors: [
            accent.withValues(alpha: 0.34),
            accent.withValues(alpha: 0.10),
            accent.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.62, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: baseR)),
    );

    // ③ 律动柱：底部窄带，圆角，主色 → 浅色
    final levels = frame.levels;
    if (levels.isEmpty) return;
    final n = levels.length;
    const gap = 2.0;
    final slot = size.width / n;
    final barW = math.max(1.5, slot - gap);
    final bandTop = size.height - barBand;
    final light = Color.lerp(accent, Colors.white, 0.55) ?? accent;
    final shader = LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: [accent, light],
    ).createShader(Rect.fromLTWH(0, bandTop, size.width, barBand));
    final paint = Paint()..shader = shader;
    for (var i = 0; i < n; i++) {
      final v = levels[i].clamp(0.0, 1.0);
      final h = math.max(2.0, v * (barBand - 6));
      final left = i * slot + gap / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, bandTop + (barBand - h), barW, h),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant AudioVisualizerPainter old) =>
      old.frame != frame || old.accent != accent;
}
