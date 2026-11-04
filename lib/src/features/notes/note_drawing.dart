// 笔记手绘/涂鸦的**纯逻辑**层：笔画模型、撤销/重做、抽稀、PNG 导出。
//
// 为什么单独一层：导出必须**能确定地测**（固定尺寸画布 + 固定几条线 → PNG
// 字节非空 + PNG 魔数 + IHDR 宽高），所以渲染不依赖 widget 树，只吃
// [NoteStroke] 列表 + 逻辑尺寸。UI（`note_drawing_page.dart`）只负责手势与工具。
//
// 证据（官方 DS note 1.12.0-346，jadx）：
//   * 绘图板是 `activities/PainterActivity.java` + Paintroid 的 `DrawingSurface`，
//     画笔/橡皮/撤销/重做/清空/颜色/粗细（`BRUSH_SIZE_MIN=2`…`MAX=64`，
//     `BRUSH_SIZE_DEFAULT=8`）；
//   * 落盘 `utils/NoteUtils.saveBitmapToFile()` **用 JPEG/90 写进 `.png` 文件**
//     （官方命名与内容不一致的怪癖）；我们导出**真正的 PNG**（PNG 魔数可断言），
//     文件名仍是官方规则 `file_<ts>.png`（见 page 层）。服务端只认 `format:"raw"`
//     + 附件，不看图片编码，所以 PNG 是安全的改进，不引入新依赖。
//
// ★ 本文件**不许** import `package:flutter/material.dart`（只要 `dart:ui`），
//   保证 `dart run tool/*.dart` 之外的纯逻辑测试不拉起 widget 树。
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 抽稀阈值：相邻两点距离小于它就丢弃（触控点密集且抖动大）。
const double kNoteDrawingMinPointDistance = 2.0;

/// 单条笔画最多保留的点数（防止一条长划把内存/路径撑爆）。
const int kNoteDrawingMaxPointsPerStroke = 2000;

/// 导出最长边上限（像素）。画布逻辑尺寸 × DPR 超过它时按比例缩到它，
/// **绝不允许导出分辨率随画布无限增长**。
const double kNoteDrawingMaxExportEdge = 2048.0;

/// 一条笔画。点坐标是**画布逻辑坐标**（导出时统一按比例缩放）。
class NoteStroke {
  const NoteStroke({
    required this.points,
    required this.color,
    required this.width,
    this.eraser = false,
  });

  final List<ui.Offset> points;
  final ui.Color color;

  /// 线宽（逻辑像素）
  final double width;

  /// 橡皮：用 `BlendMode.clear` 真正擦除像素（而不是拿背景色盖）
  final bool eraser;

  NoteStroke copyWith({List<ui.Offset>? points}) => NoteStroke(
    points: points ?? this.points,
    color: color,
    width: width,
    eraser: eraser,
  );
}

/// 触控点抽稀：**最小距离采样** —— 只有离上一个保留点足够远才收。
///
/// 简单、无状态、可单测：输入 `[(0,0),(0.5,0),(2,0),(2.5,0)]`、阈值 2 →
/// `[(0,0),(2,0)]`。同时按 [maxPoints] 封顶。
List<ui.Offset> noteSimplifyStroke(
  Iterable<ui.Offset> raw, {
  double minDistance = kNoteDrawingMinPointDistance,
  int maxPoints = kNoteDrawingMaxPointsPerStroke,
}) {
  final out = <ui.Offset>[];
  if (maxPoints <= 0) return out;
  for (final p in raw) {
    if (out.isEmpty || (p - out.last).distance >= minDistance) {
      out.add(p);
      if (out.length >= maxPoints) break;
    }
  }
  return out;
}

/// 画布模型：笔画集合 + 撤销/重做（**快照式**，撤销能真正还原像素）。
///
/// 快照存的是"操作前"的笔画列表；`undo` 把当前态压进 redo 再整体换回旧态。
/// 所以 `clear()` 也可撤销 —— 不是只清一个索引/标志位。
class NoteDrawingModel {
  final List<NoteStroke> _strokes = [];
  final List<List<NoteStroke>> _undoStack = [];
  final List<List<NoteStroke>> _redoStack = [];

  List<NoteStroke> get strokes => List<NoteStroke>.unmodifiable(_strokes);
  bool get isEmpty => _strokes.isEmpty;
  bool get isNotEmpty => _strokes.isNotEmpty;
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  /// 记一次"操作前"快照（任何改动前必须调它）
  void _snapshot() {
    _undoStack.add(List<NoteStroke>.of(_strokes));
    _redoStack.clear();
  }

  void add(NoteStroke stroke) {
    if (stroke.points.isEmpty) return;
    _snapshot();
    _strokes.add(stroke);
  }

  /// 清空画布（可撤销）
  void clear() {
    if (_strokes.isEmpty) return;
    _snapshot();
    _strokes.clear();
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(List<NoteStroke>.of(_strokes));
    final prev = _undoStack.removeLast();
    _strokes
      ..clear()
      ..addAll(prev);
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(List<NoteStroke>.of(_strokes));
    final next = _redoStack.removeLast();
    _strokes
      ..clear()
      ..addAll(next);
  }
}

/// 导出分辨率：逻辑尺寸 × DPR，**最长边封顶** [maxEdge]（并保证 ≥1px）。
ui.Size noteDrawingExportSize(
  ui.Size logical,
  double devicePixelRatio, {
  double maxEdge = kNoteDrawingMaxExportEdge,
}) {
  if (logical.width <= 0 || logical.height <= 0) return const ui.Size(1, 1);
  final dpr = devicePixelRatio.isFinite && devicePixelRatio > 0
      ? devicePixelRatio
      : 1.0;
  var w = logical.width * dpr;
  var h = logical.height * dpr;
  final longest = w > h ? w : h;
  if (longest > maxEdge) {
    final k = maxEdge / longest;
    w *= k;
    h *= k;
  }
  double clampPx(double v) => v.isFinite && v >= 1 ? v : 1;
  return ui.Size(clampPx(w).roundToDouble(), clampPx(h).roundToDouble());
}

/// 把笔画画到 canvas 上（逻辑坐标；调用方负责缩放）。
///
/// 必须在 `saveLayer` 之后调用，橡皮的 `BlendMode.clear` 才作用于这一层
/// （否则会连底图一起清掉 / 透明背景擦不掉）。
void paintNoteDrawing(ui.Canvas canvas, List<NoteStroke> strokes) {
  for (final s in strokes) {
    if (s.points.isEmpty) continue;
    final blend = s.eraser ? ui.BlendMode.clear : ui.BlendMode.srcOver;
    if (s.points.length == 1) {
      // 单点：一个圆点（手指点一下也算一笔）
      canvas.drawCircle(
        s.points.first,
        s.width / 2,
        ui.Paint()
          ..color = s.eraser ? const ui.Color(0x00000000) : s.color
          ..blendMode = blend
          ..style = ui.PaintingStyle.fill,
      );
      continue;
    }
    final path = ui.Path()..moveTo(s.points.first.dx, s.points.first.dy);
    for (final p in s.points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      ui.Paint()
        ..color = s.eraser ? const ui.Color(0x00000000) : s.color
        ..strokeWidth = s.width
        ..strokeCap = ui.StrokeCap.round
        ..strokeJoin = ui.StrokeJoin.round
        ..style = ui.PaintingStyle.stroke
        ..blendMode = blend,
    );
  }
}

/// 导出 PNG 字节。
///
/// * [logicalSize] 画布逻辑尺寸（手势坐标的量纲）；
/// * [pixelSize] 导出像素尺寸（由 [noteDrawingExportSize] 算出，已封顶）；
/// * [background] 背景色；`alpha == 0`（透明）时不铺底。
///
/// 用 `dart:ui` 的 `PictureRecorder` + `toImage` + `toByteData(format: png)`，
/// **零新依赖**。
Future<Uint8List> renderNoteDrawingPng({
  required List<NoteStroke> strokes,
  required ui.Size logicalSize,
  required ui.Size pixelSize,
  required ui.Color background,
}) async {
  if (logicalSize.width <= 0 || logicalSize.height <= 0) {
    throw ArgumentError.value(logicalSize, 'logicalSize', '画布尺寸必须是正数');
  }
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final rect = ui.Offset.zero & logicalSize;
  canvas.scale(
    pixelSize.width / logicalSize.width,
    pixelSize.height / logicalSize.height,
  );
  canvas.saveLayer(rect, ui.Paint());
  if (background.a > 0) {
    canvas.drawRect(rect, ui.Paint()..color = background);
  }
  paintNoteDrawing(canvas, strokes);
  canvas.restore();

  final picture = recorder.endRecording();
  final image = await picture.toImage(
    pixelSize.width.round(),
    pixelSize.height.round(),
  );
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw StateError('导出 PNG 失败：toByteData 返回 null');
    }
    return data.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

/// PNG 魔数（`\x89PNG\r\n\x1a\n`）——导出成功与否的确定性判据之一。
const List<int> kPngMagic = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// 是否是 PNG（魔数判定，不解析内容）。
bool looksLikePng(List<int> bytes) {
  if (bytes.length < kPngMagic.length) return false;
  for (var i = 0; i < kPngMagic.length; i++) {
    if (bytes[i] != kPngMagic[i]) return false;
  }
  return true;
}
