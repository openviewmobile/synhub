// 360 全景**球面浏览**控件（P14）：把等距柱状投影图重投影到"可拖动视角"的视锥里。
//
// 实现方式（**零新依赖**，硬约束）：
//   * 视角数学在 `photo_panorama_math.dart`（纯 Dart，可单测）；
//   * 本文件把绘制区切成三角网：对每个网格顶点的**屏幕坐标**反解出等距柱状
//     纹理坐标 `(u,v)`（就是球面重投影），再用 `Canvas.drawVertices` +
//     `ImageShader` 采样，得到真正的透视视角画面；
//   * 拖动 / 双指缩放只改 `PanoramaViewController`，网格随之重建。
//
// 为什么不是 `InteractiveViewer`：`InteractiveViewer` 只能做**仿射**变换
// （平移/缩放/旋转都是 2×3 矩阵），而等距柱状 → 透视是**非仿射**的（球面到平面
// 的投影），仿射变换在数学上做不到 —— 用它只会得到"一张被拉伸的平面图"，
// 那正是任务里明令禁止的"做假动画充数"。所以这里用逐顶点反解的真重投影。
//
// 降级：官方在 ABIs 不含 Google VR 时也会退回平面显示
// （`ImageTable.java:1411-1425` 的 `isTraditionalPhoto()/isTraditionalVideo()`：
// `this == PHOTO360 && !AbiUtil.supportsGoogleVR()`）—— 本仓的解码失败分支
// 就是同一姿势的如实降级（文案用官方 `str_360Photo_Disable_Click_Indicator`
// 的中文直译）。
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'photo_media_text.dart';
import 'photo_panorama_math.dart';

/// 网格密度（列 × 行）。密度越高越细腻、顶点越多。
///
/// 40×24 = 960 个四边形 → 3840 顶点 / 5760 索引，`drawVertices` 一帧内很轻。
/// 每个四边形**独占** 4 个顶点（不在四边形之间共享）—— 这是为了让接缝处的
/// 纹理坐标能各自"解绕"，共享顶点做不到。
const int kPanoramaMeshColumns = 40;
const int kPanoramaMeshRows = 24;

/// 360 全景查看器。
class PanoramaView extends StatefulWidget {
  const PanoramaView({
    super.key,
    this.bytes,
    this.image,
    this.controller,
    this.onAnglesChanged,
    this.onReset,
    this.showHint = true,
  }) : assert(
         bytes != null || image != null,
         'PanoramaView 需要 bytes 或 image 之一',
       );

  /// 静图的原始字节（球面重投影的源图；由调用方走已有鉴权字节链路取回）。
  ///
  /// 与 [image] **二选一**。传 [image] 时跳过解码（调用方已经解好；测试里由
  /// `tester.runAsync` 解好后传进来，因为 widget test 的 FakeAsync 区里
  /// `decodeImageFromList` 这类引擎真异步**永远不会完成**）——
  /// 那张 `ui.Image` 由**调用方**负责释放，本组件不会 dispose 它。
  final Uint8List? bytes;

  /// 已解码好的源图（见 [bytes]）。
  final ui.Image? image;

  /// 外部持有的视角控制器（不传则内部自建）。
  final PanoramaViewController? controller;

  /// 视角变化回调（拖动 / 缩放 / 复位后各触发一次）。
  final ValueChanged<PanoramaViewAngles>? onAnglesChanged;

  /// 复位回调（不给就只改视角，不通知外部）。
  final VoidCallback? onReset;

  /// 是否显示"拖动查看"提示（官方 `str_360Photo_Click_Indicator`）。
  final bool showHint;

  @override
  State<PanoramaView> createState() => _PanoramaViewState();
}

class _PanoramaViewState extends State<PanoramaView> {
  late final PanoramaViewController _controller =
      widget.controller ?? PanoramaViewController();
  bool get _ownsController => widget.controller == null;

  ui.Image? _image;
  Object? _decodeError;
  bool _decoding = false;
  int _decodeToken = 0;

  /// 当前这张图是不是**我们自己解出来的**（自己解的才由自己释放；
  /// 调用方通过 [PanoramaView.image] 交进来的那张归调用方）。
  bool _imageOwned = false;

  /// 一次手势里累计的拖动距离，用来在用户真的拖动过之后**收起提示**
  /// （官方也是"拖动即开始浏览"；提示一直压在图上是多余的）。
  double _dragDistance = 0;

  @override
  void initState() {
    super.initState();
    if (widget.image != null) {
      _image = widget.image;
      _imageOwned = false;
    } else {
      unawaited(_decode());
    }
  }

  @override
  void didUpdateWidget(covariant PanoramaView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.image, widget.image) &&
        identical(oldWidget.bytes, widget.bytes)) {
      return;
    }
    if (widget.image != null) {
      _releaseDecoded();
      setState(() {
        _image = widget.image;
        _imageOwned = false;
        _decoding = false;
        _decodeError = null;
      });
      return;
    }
    unawaited(_decode());
  }

  @override
  void dispose() {
    _releaseDecoded();
    if (_ownsController) {
      // 控制器是纯值对象，没有需要释放的资源（显式写出以免误以为漏了）。
    }
    super.dispose();
  }

  /// 只释放**我们解出来的**那张（外部注入的归外部）。
  void _releaseDecoded() {
    if (_imageOwned) _image?.dispose();
    _image = null;
    _imageOwned = false;
  }

  Future<void> _decode() async {
    final bytes = widget.bytes;
    if (bytes == null) return;
    final token = ++_decodeToken;
    setState(() {
      _decoding = true;
      _decodeError = null;
    });
    try {
      final image = await decodeImageFromList(bytes);
      if (!mounted || token != _decodeToken) {
        image.dispose();
        return;
      }
      _releaseDecoded();
      setState(() {
        _image = image;
        _imageOwned = true;
        _decoding = false;
      });
    } catch (err) {
      if (!mounted || token != _decodeToken) return;
      setState(() {
        _decodeError = err;
        _decoding = false;
      });
    }
  }

  void _notify() => widget.onAnglesChanged?.call(_controller.angles);

  /// 统一的"视角变了"收尾：只在真的变了时重绘 + 通知外部。
  void _applyView(void Function() mutate) {
    final before = _controller.angles;
    mutate();
    if (_controller.angles != before) {
      setState(() {});
      _notify();
    }
  }

  void _onScaleStart(ScaleStartDetails _) => _dragDistance = 0;

  /// 单指拖动与双指缩放**共用一个识别器**：`GestureDetector` 不允许同时给
  /// `onPan*` 和 `onScale*`（scale 是 pan 的超集，Flutter 会直接断言报错）。
  /// 所以单指走 `focalPointDelta`（焦距点位移，等价于 pan delta），
  /// 双指在位移之外再叠加缩放。
  void _onScaleUpdate(ScaleUpdateDetails d) {
    _dragDistance += d.focalPointDelta.distance;
    _applyView(() {
      if (d.focalPointDelta != Offset.zero) {
        _controller.dragBy(d.focalPointDelta.dx, d.focalPointDelta.dy);
      }
      if (d.pointerCount > 1 && d.scale != 1.0) {
        _controller.zoomBy(d.scale);
      }
    });
  }

  void _reset() {
    _controller.reset();
    setState(() {});
    _notify();
    widget.onReset?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (_decoding) {
      return const Center(
        key: Key('photo-pano-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (_decodeError != null || _image == null) {
      return Center(
        key: const Key('photo-pano-error'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            photoMedia(
              PhotoMediaTextKeys.panoPhotoFailed,
              '无法载入 360 照片。',
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return Stack(
      key: const Key('photo-pano-view'),
      fit: StackFit.expand,
      children: [
        // 拖动改视角 + 双指缩放，**同一个** scale 识别器（`GestureDetector`
        // 不允许 pan 与 scale 并存：scale 是 pan 的超集，会直接断言报错）。
        // 单指 → `focalPointDelta` 当 pan；双指 → 再叠一层缩放。
        GestureDetector(
          key: const Key('photo-pano-gesture'),
          behavior: HitTestBehavior.opaque,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          child: RepaintBoundary(
            key: const Key('photo-pano-boundary'),
            child: CustomPaint(
              key: const Key('photo-pano-canvas'),
              painter: PanoramaMeshPainter(
                image: _image!,
                controller: _controller,
              ),
              size: Size.infinite,
            ),
          ),
        ),
        if (widget.showHint && _dragDistance < 24)
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  key: const Key('photo-pano-hint'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    photoMedia(
                      PhotoMediaTextKeys.panoPhotoHint,
                      '点按并拖动查看 360 照片。',
                    ),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          right: 12,
          top: 12,
          child: IconButton(
            key: const Key('photo-pano-reset'),
            tooltip: photoMedia(
              PhotoMediaTextKeys.panoResetView,
              '回到初始视角',
            ),
            onPressed: _reset,
            icon: const Icon(Icons.center_focus_strong, color: Colors.white),
          ),
        ),
      ],
    );
  }
}

/// 等距柱状 → 透视的三角网绘制器（**真正的球面重投影**）。
///
/// 对每个网格顶点：屏幕坐标 → 相机光线 → 世界方向 → `(λ, φ)` → 纹理 `(u, v)`。
/// 相邻四边形的 `u` 会在 ±π 处跳变，所以**每个四边形单独解绕**（见 `_unwrapped`），
/// 配合 `ImageShader` 的 `TileMode.repeat`，接缝两侧采样到的是同一块图。
@visibleForTesting
class PanoramaMeshPainter extends CustomPainter {
  PanoramaMeshPainter({required this.image, required this.controller});

  final ui.Image image;
  final PanoramaViewController controller;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final cols = kPanoramaMeshColumns;
    final rows = kPanoramaMeshRows;
    final cellW = size.width / cols;
    final cellH = size.height / rows;
    final imgW = image.width.toDouble();
    final imgH = image.height.toDouble();

    final positions = <Offset>[];
    final texCoords = <Offset>[];
    final indices = <int>[];
    final point = math.Point(size.width, size.height);

    for (var j = 0; j < rows; j++) {
      for (var i = 0; i < cols; i++) {
        final x0 = i * cellW;
        final x1 = (i + 1) * cellW;
        final y0 = j * cellH;
        final y1 = (j + 1) * cellH;
        final corners = <Offset>[
          Offset(x0, y0),
          Offset(x1, y0),
          Offset(x1, y1),
          Offset(x0, y1),
        ];
        final uvs = <PanoramaUv>[
          for (final c in corners)
            controller.equirectAt(c.dx, c.dy, point),
        ];
        // 解绕经度：四边形横跨 ±π 时，把偏小的那一半 +1 圈。
        // （`u` 是归一化的，跨接缝时四个角的最大最小差会 > 0.5。）
        final us = [for (final uv in uvs) uv.u];
        final minU = us.reduce((a, b) => a < b ? a : b);
        final maxU = us.reduce((a, b) => a > b ? a : b);
        if (maxU - minU > 0.5) {
          final mid = (minU + maxU) / 2;
          for (var k = 0; k < us.length; k++) {
            if (us[k] < mid) us[k] += 1.0;
          }
        }
        final base = positions.length;
        for (var k = 0; k < 4; k++) {
          positions.add(corners[k]);
          // 纹理坐标用**图像像素**（`drawVertices` + `ImageShader` 的约定）。
          final v = uvs[k].v.clamp(0.0, 1.0);
          texCoords.add(Offset(us[k] * imgW, v * imgH));
        }
        indices.addAll([base, base + 1, base + 2, base, base + 2, base + 3]);
      }
    }

    final paint = Paint()
      ..shader = ui.ImageShader(
        image,
        TileMode.repeated,
        TileMode.clamp,
        Float64List.fromList(<double>[
          1, 0, 0, 0, //
          0, 1, 0, 0, //
          0, 0, 1, 0, //
          0, 0, 0, 1, //
        ]),
        filterQuality: FilterQuality.medium,
      )
      ..isAntiAlias = false;
    final vertices = ui.Vertices(
      ui.VertexMode.triangles,
      positions,
      textureCoordinates: texCoords,
      indices: indices,
    );
    canvas.drawVertices(vertices, BlendMode.srcOver, paint);
  }

  @override
  bool shouldRepaint(covariant PanoramaMeshPainter old) =>
      old.image != image ||
      old.controller.angles != controller.angles ||
      old.image.width != image.width ||
      old.image.height != image.height;
}
