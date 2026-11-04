// 360 全景（等距柱状投影 / equirectangular）**视角控制器** —— 纯数学，无 Flutter。
//
// ## 为什么自己算
//
// 官方 Android 用 Google VR 原生库做球面渲染（`Photo360Activity` +
// `com.google.vr.sdk.widgets.pano.VrPanoramaView` → `System.loadLibrary("panorenderer")`），
// 官方 Web 用 `three.min.js` + `videojs/vr`。本仓**不引入新依赖**（硬约束），
// 所以自己做"等距柱状 → 透视视角"的重投影：把屏幕当视锥，对每个屏幕点反解出
// 世界方向，再映射回等距柱状图的 (u,v) 纹理坐标，交给 `Canvas.drawVertices`
// 用 `ImageShader` 采样（见 `photo_panorama_view.dart`）。
//
// ## 坐标系（写死在这里，别处不许另立一套）
//
//   * 相机在球心，`yaw == pitch == 0` 时看向 **+Z**；
//   * 屏幕点 → 相机空间方向 `d_cam = (nx, ny, 1)`，
//     `ny = (1 - 2*py/h) * tan(fov/2)`、`nx = (2*px/w - 1) * (w/h) * tan(fov/2)`；
//   * 世界方向 `d = R * d_cam`，`R = Ry(yaw) · Rx(pitch)`（见 [rotationMatrix]）；
//   * 经纬度：`λ = atan2(d.x, d.z)`、`φ = asin(d.y / |d|)`；
//   * 等距柱状纹理：`u = λ/(2π) + 0.5`、`v = 0.5 - φ/π`。
//
// 自检（离线用例也断言这几条）：`yaw=pitch=0`、屏幕正中 → `(u,v) = (0.5, 0.5)`；
// 向右拖 → `u` 变小（视角左转、画面右移）；向上拖 → `v` 变小（看到天顶方向）。
//
// `fov` 是**垂直**视场角（弧度）。默认 1.2 rad ≈ 68.8°，接近官方全景查看器的
// 默认视锥量级（官方没给常数，这个值是可调参数、不是"取证值"—— 如实标注）。
library;

import 'dart:math' as math;

/// 默认垂直视场角（弧度 ≈ 68.8°）。**不是取证值**，是可调的观感参数。
const double kPanoramaDefaultFov = 1.2;

/// `fov` 的下 / 上限（弧度）：约 20° ~ 110°，防止缩到看不见 / 拉到极点翻转。
const double kPanoramaMinFov = 0.35;
const double kPanoramaMaxFov = 1.92;

/// 俯仰角钳制：贴到 ±90° 会让"上方向"退化（`R` 在那个点是奇异的），留一点余量。
const double kPanoramaMaxPitch = math.pi / 2 - 0.02;

/// 一次手势里 `yaw` / `pitch` 的返回值（不可变，便于测试直接比大小）。
class PanoramaViewAngles {
  const PanoramaViewAngles({
    required this.yaw,
    required this.pitch,
    required this.fov,
  });

  final double yaw;
  final double pitch;
  final double fov;

  @override
  String toString() =>
      'PanoramaViewAngles(yaw: ${yaw.toStringAsFixed(4)}, '
      'pitch: ${pitch.toStringAsFixed(4)}, fov: ${fov.toStringAsFixed(4)})';

  @override
  bool operator ==(Object other) =>
      other is PanoramaViewAngles &&
      other.yaw == yaw &&
      other.pitch == pitch &&
      other.fov == fov;

  @override
  int get hashCode => Object.hash(yaw, pitch, fov);
}

/// 等距柱状图上的一个纹理坐标（归一化：`u` 可绕圈，`v` 在 [0,1]）。
class PanoramaUv {
  const PanoramaUv(this.u, this.v);

  /// 经度方向，`0.5` = 图像水平正中；可超出 [0,1)（用 `TileMode.repeat` 采样）。
  final double u;

  /// 纬度方向，`0` = 天顶、`1` = 天底。
  final double v;

  @override
  String toString() =>
      'PanoramaUv(${u.toStringAsFixed(4)}, ${v.toStringAsFixed(4)})';

  @override
  bool operator ==(Object other) =>
      other is PanoramaUv && other.u == u && other.v == v;

  @override
  int get hashCode => Object.hash(u, v);
}

/// 360 全景的视角状态机。**纯 Dart**：可以脱离 widget 直接单测。
class PanoramaViewController {
  PanoramaViewController({
    double yaw = 0,
    double pitch = 0,
    double fov = kPanoramaDefaultFov,
  }) : _yaw = yaw,
       _pitch = _clampPitch(pitch),
       _fov = _clampFov(fov);

  double _yaw;
  double _pitch;
  double _fov;

  double get yaw => _yaw;
  double get pitch => _pitch;
  double get fov => _fov;

  PanoramaViewAngles get angles =>
      PanoramaViewAngles(yaw: _yaw, pitch: _pitch, fov: _fov);

  /// 任意角度都合法（经度是圆的），但要**归一化到 (-π, π]** 免得无限增长。
  set yaw(double v) => _yaw = _wrapAngle(v);

  set pitch(double v) => _pitch = _clampPitch(v);

  set fov(double v) => _fov = _clampFov(v);

  /// 视角旋转矩阵 `R = Ry(yaw) · Rx(pitch)`，**行主序 3×3**。
  ///
  /// ```
  /// [  cy,  sy·sp,  sy·cp ]
  /// [  0,    cp,    -sp   ]
  /// [ -sy,  cy·sp,  cy·cp ]
  /// ```
  /// （`cy = cos(yaw)`、`sy = sin(yaw)`、`cp = cos(pitch)`、`sp = sin(pitch)`）
  ///
  /// 离线用例直接断言"拖动后矩阵变了"以及具体分量 —— 这就是"视角矩阵"，
  /// 不是 UI 里某个 opacity 之类的替身。
  List<double> get rotationMatrix {
    final cy = math.cos(_yaw), sy = math.sin(_yaw);
    final cp = math.cos(_pitch), sp = math.sin(_pitch);
    return <double>[
      cy, sy * sp, sy * cp, //
      0, cp, -sp, //
      -sy, cy * sp, cy * cp, //
    ];
  }

  /// 拖动手势（像素）。灵敏度与 [fov] 挂钩：视场越小 → 同样的像素走的角度越小，
  /// 这样"放大后拖动"的手感才一致。
  void dragBy(double dx, double dy) {
    final size = _referenceSize;
    final perPixel = _fov / size;
    _yaw = _wrapAngle(_yaw - dx * perPixel);
    _pitch = _clampPitch(_pitch + dy * perPixel);
  }

  /// 双指缩放：[scale] > 1 = 手指张开 = 放大 = 视场变小。
  void zoomBy(double scale) {
    if (scale <= 0 || !scale.isFinite) return;
    _fov = _clampFov(_fov / scale);
  }

  /// 回到初始视角（官方全景查看器有"复位"手势，这里给一个显式入口）。
  void reset() {
    _yaw = 0;
    _pitch = 0;
    _fov = kPanoramaDefaultFov;
  }

  /// 屏幕点 `(px, py)` → 等距柱状纹理坐标（归一化）。
  ///
  /// 反解流程就是文件头那套公式的逆运算（相机光线 → 世界方向 → 经纬度）。
  /// `size` 是绘制区尺寸；宽高非法时返回中心点，**不抛异常**
  /// （绘制期间的异常会让整帧黑掉，比一个退化值糟得多）。
  PanoramaUv equirectAt(double px, double py, math.Point<double> size) {
    final w = size.x, h = size.y;
    if (w <= 0 || h <= 0 || !w.isFinite || !h.isFinite) {
      return const PanoramaUv(0.5, 0.5);
    }
    final tanHalf = math.tan(_fov / 2);
    final nx = (2 * px / w - 1) * (w / h) * tanHalf;
    final ny = (1 - 2 * py / h) * tanHalf;
    return rayToEquirect(nx, ny, 1);
  }

  /// 相机空间方向 `(cx, cy, cz)` → 等距柱状纹理坐标。
  ///
  /// 单列出来是为了让用例能直接喂方向向量断言（不经屏幕坐标的浮点噪声）。
  PanoramaUv rayToEquirect(double cx, double cy, double cz) {
    final r = rotationMatrix;
    final wx = r[0] * cx + r[1] * cy + r[2] * cz;
    final wy = r[3] * cx + r[4] * cy + r[5] * cz;
    final wz = r[6] * cx + r[7] * cy + r[8] * cz;
    final len = math.sqrt(wx * wx + wy * wy + wz * wz);
    if (len == 0 || !len.isFinite) return const PanoramaUv(0.5, 0.5);
    final lon = math.atan2(wx, wz); // λ ∈ (-π, π]
    final lat = math.asin((wy / len).clamp(-1.0, 1.0)); // φ ∈ [-π/2, π/2]
    return PanoramaUv(lon / (2 * math.pi) + 0.5, 0.5 - lat / math.pi);
  }

  /// 拖动灵敏度的**参考边长**（逻辑像素）。取一个固定值而不是真实尺寸，
  /// 是为了让"同样一段拖动 = 同样一段视角变化"，与窗口大小无关（更好预期、
  /// 也更好测）。
  static const double _referenceSize = 500;

  static double _wrapAngle(double v) {
    if (!v.isFinite) return 0;
    const twoPi = 2 * math.pi;
    var out = v % twoPi;
    if (out <= -math.pi) out += twoPi;
    if (out > math.pi) out -= twoPi;
    return out;
  }

  static double _clampPitch(double v) {
    if (!v.isFinite) return 0;
    return v.clamp(-kPanoramaMaxPitch, kPanoramaMaxPitch).toDouble();
  }

  static double _clampFov(double v) {
    if (!v.isFinite) return kPanoramaDefaultFov;
    return v.clamp(kPanoramaMinFov, kPanoramaMaxFov).toDouble();
  }
}
