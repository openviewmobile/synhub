// 笔记手绘/涂鸦的**绘图板页面** + 能力位门控。
//
// 官方 DS note 1.12.0-346 的对应物（jadx）：
//   * `activities/PainterActivity.java`：画笔/橡皮切换、颜色选择器、粗细 SeekBar
//     （2…64，默认 8）、撤销/重做、`mDrawingSurface.getBitmapCopy()` 落盘后
//     回传文件路径；**没有服务端"绘画对象"接口**。
//   * `activities/EditorActivity.java`（case 106）：入口生成
//     `file_<System.currentTimeMillis()>.png` 的临时路径 + `generateRef`，
//     打开 `PainterActivity`；回来 `createInlineAttachment(uri, PAINTING)`。
//   * `Common.CMD_INSERT_PAINTING = "insertPainting"`；编辑器 JS
//     `syno-editor.js` 的 `insertpainting.exec` 插入
//     `<img class="syno-notestation-image-object syno-dsnote-painting-object" …>`。
//   * `loaders/CreateAttachmentLoader.AttachType.PAINTING` 只是**本地**枚举；
//     上传仍走 `SYNO.NoteStation.Note / set` v2 的 multipart，附件只带
//     `action/name/format=raw/ref/convert`（见 `docs/note-drawing-implementation.md`）。
//
// 所以"手绘"的能力位就是**笔记附件接口** `SYNO.NoteStation.Note`：能力表里没有它
// → 隐藏入口并给出原因（降级门控，绝不删）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../../design/design_palette.dart';
import '../../core/ui/adaptive_actions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/theme/app_tokens.dart';
import 'note_drawing.dart';
import 'note_drawing_text.dart';
import 'note_picker.dart';
import '../../core/user_facing_error.dart';

/// 手绘依赖的**服务端能力位**：附件随 `SYNO.NoteStation.Note / set` 上传。
///
/// 服务端 `.lib` 原文（NoteStation 2.6.10-3938，
/// `/tmp/spk/export_NoteStation/webapi/SYNO.NoteStation.lib`）里 `Note` 的 v1/v2
/// `set` 都带 `"allowUpload":true`；服务端 `.so` 里出现的字段是
/// `attachment/action/create/modify/delete/format/raw/convert/name/file_id`，
/// **没有 painting** —— 绘画在服务端就是普通 raw 附件。所以能力位取附件 API。
const String kNotePaintingApi = 'SYNO.NoteStation.Note';

/// "手绘"入口是否可用（能力位缺失 → false → 隐藏入口）。
///
/// 为什么不用 `hasApi`：`SYNO.NoteStation.Note` 是笔记模块的**必需** API，缺了它
/// 模块本身就是 `absent`，而 `hasApi` 对 `absent` 一律 fail-open（不因不确定隐藏）
/// —— 那样"入口缺失"永远测不出来。这里用横切能力位的 [apiPresent] 语义：
/// **能力表非空且明确没有**这个 API → 隐藏；未检测 / 检测失败 → fail-open 保留。
final notePaintingAvailableProvider = Provider<bool>((ref) {
  final snapshot = ref.watch(serviceAvailabilityProvider);
  return snapshot.apiPresent(kNotePaintingApi);
});

/// 导出 PNG 之后的落盘方式（可注入：测试里替换掉，避免真写文件）。
typedef NotePaintingSaver = Future<NotePickedImage> Function(Uint8List png);

final notePaintingSaverProvider = Provider<NotePaintingSaver>(
  (ref) => saveNotePaintingToTemp,
);

/// 默认落盘：临时目录 + 官方命名规则 `painting_<ts>.png`（真 PNG 字节）。
Future<NotePickedImage> saveNotePaintingToTemp(Uint8List png) async {
  final dir = await getTemporaryDirectory();
  final name = 'painting_${DateTime.now().millisecondsSinceEpoch}.png';
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(png, flush: true);
  return NotePickedImage(path: file.path, name: name, mimeType: 'image/png');
}

/// 绘图板：单指绘制，导出 PNG 后 `pop` 一个 [NotePickedImage]。
class NoteDrawingPage extends ConsumerStatefulWidget {
  const NoteDrawingPage({super.key, this.devicePixelRatio});

  /// 测试可注入固定 DPR；null → 取 `MediaQuery.devicePixelRatioOf`。
  final double? devicePixelRatio;

  @override
  ConsumerState<NoteDrawingPage> createState() => _NoteDrawingPageState();
}

class _NoteDrawingPageState extends ConsumerState<NoteDrawingPage> {
  final NoteDrawingModel _model = NoteDrawingModel();

  static const List<Color> _palette = [
    Color(0xFF000000),
    Color(0xFFD61E18),
    Color(0xFFFF7400),
    Color(0xFF8CC812),
    Color(0xFF009CD0),
    Color(0xFF0052B8),
    Color(0xFF601AB6),
    Color(0xFFC0504E),
    Color(0xFFF69646),
    Color(0xFF9BBA5A),
    Color(0xFF4BACC6),
    Color(0xFF548CD4),
    Color(0xFF8064A2),
    Color(0xFFC6C7C8),
    Color(0xFF646566),
    Color(0xFFFFFFFF),
  ];

  Color _color = const Color(0xFF000000);
  double _width = 8; // 官方 BRUSH_SIZE_DEFAULT = 8
  bool _eraser = false;
  bool _whiteBackground = true;
  bool _busy = false;
  bool _drawing = false;

  /// 当前这一笔的**原始**触控点（提交时才抽稀）
  final List<Offset> _live = [];

  /// 画布逻辑尺寸（手势坐标量纲；导出分辨率以它 × DPR 为基准并封顶）
  Size _canvasSize = Size.zero;

  Color get _background =>
      _whiteBackground ? const Color(0xFFFFFFFF) : const Color(0x00000000);

  NoteStroke? get _liveStroke {
    if (_live.isEmpty) return null;
    final pts = noteSimplifyStroke(_live);
    if (pts.isEmpty) return null;
    return NoteStroke(
      points: pts,
      color: _color,
      width: _width,
      eraser: _eraser,
    );
  }

  void _onPanStart(DragStartDetails d) {
    setState(() {
      _drawing = true;
      _live
        ..clear()
        ..add(d.localPosition);
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (!_drawing) return;
    setState(() => _live.add(d.localPosition));
  }

  void _onPanEnd(DragEndDetails d) {
    final stroke = _liveStroke;
    setState(() {
      _drawing = false;
      _live.clear();
      if (stroke != null) _model.add(stroke);
    });
  }

  void _onPanCancel() {
    setState(() {
      _drawing = false;
      _live.clear();
    });
  }

  Future<void> _insert() async {
    if (_model.isEmpty) {
      _toast(noteDrawingText(NoteDrawingTextKeys.empty, '画布还是空的'));
      return;
    }
    setState(() => _busy = true);
    try {
      final dpr =
          widget.devicePixelRatio ??
          MediaQuery.devicePixelRatioOf(context);
      final pixelSize = noteDrawingExportSize(_canvasSize, dpr);
      final bytes = await renderNoteDrawingPng(
        strokes: _model.strokes,
        logicalSize: _canvasSize,
        pixelSize: pixelSize,
        background: _background,
      );
      final saver = ref.read(notePaintingSaverProvider);
      final picked = await saver(bytes);
      if (!mounted) return;
      Navigator.of(context).pop(picked);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast(
        noteDrawingFill(NoteDrawingTextKeys.exportFailed, '手绘导出失败：{error}', {
          'error': userFacingError(e),
        }),
      );
    }
  }

  void _toast(String message) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(noteDrawingText(NoteDrawingTextKeys.title, '手绘')),
        actions: adaptiveActions([
          IconButton(
            key: const Key('note-drawing-undo'),
            tooltip: noteDrawingText(NoteDrawingTextKeys.undo, '撤销'),
            icon: const Icon(Icons.undo),
            onPressed: _busy || !_model.canUndo ? null : () => setState(_model.undo),
          ),
          IconButton(
            key: const Key('note-drawing-redo'),
            tooltip: noteDrawingText(NoteDrawingTextKeys.redo, '重做'),
            icon: const Icon(Icons.redo),
            onPressed: _busy || !_model.canRedo ? null : () => setState(_model.redo),
          ),
          IconButton(
            key: const Key('note-drawing-clear'),
            tooltip: noteDrawingText(NoteDrawingTextKeys.clear, '清空'),
            icon: const Icon(Icons.delete_outline),
            onPressed: _busy || _model.isEmpty ? null : () => setState(_model.clear),
          ),
          TextButton(
            key: const Key('note-drawing-insert'),
            onPressed: _busy ? null : _insert,
            child: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(noteDrawingText(NoteDrawingTextKeys.insert, '插入')),
          ),
        ]),
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  _canvasSize = Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  );
                  final live = _liveStroke;
                  return GestureDetector(
                    key: const Key('note-drawing-canvas'),
                    behavior: HitTestBehavior.opaque,
                    // 只认单指 pan：多指不会被当成两笔（官方也只有一个
                    // DrawingSurface 触摸监听）。缩放/滚动不参与，避免冲突。
                    onPanStart: _busy ? null : _onPanStart,
                    onPanUpdate: _busy ? null : _onPanUpdate,
                    onPanEnd: _busy ? null : _onPanEnd,
                    onPanCancel: _busy ? null : _onPanCancel,
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: _NoteDrawingPainter(
                          strokes: [
                            ..._model.strokes,
                            if (live != null) live,
                          ],
                          background: _background,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          _controls(context),
        ],
      ),
    );
  }

  Widget _controls(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<bool>(
                  key: const Key('note-drawing-tool'),
                  segments: [
                    ButtonSegment(
                      value: false,
                      icon: const Icon(Icons.brush_outlined),
                      label: Text(noteDrawingText(NoteDrawingTextKeys.brush, '画笔')),
                    ),
                    ButtonSegment(
                      value: true,
                      icon: const Icon(Icons.cleaning_services_outlined),
                      label: Text(noteDrawingText(NoteDrawingTextKeys.eraser, '橡皮')),
                    ),
                  ],
                  selected: {_eraser},
                  onSelectionChanged: _busy
                      ? null
                      : (v) => setState(() => _eraser = v.first),
                ),
                SegmentedButton<bool>(
                  key: const Key('note-drawing-bg'),
                  segments: [
                    ButtonSegment(
                      value: true,
                      label: Text(
                        noteDrawingText(
                          NoteDrawingTextKeys.backgroundWhite,
                          '白底',
                        ),
                      ),
                    ),
                    ButtonSegment(
                      value: false,
                      label: Text(
                        noteDrawingText(
                          NoteDrawingTextKeys.backgroundTransparent,
                          '透明',
                        ),
                      ),
                    ),
                  ],
                  selected: {_whiteBackground},
                  onSelectionChanged: _busy
                      ? null
                      : (v) => setState(() => _whiteBackground = v.first),
                ),
              ],
            ),
            const SizedBox(height: Gap.sm),
            Row(
              children: [
                Icon(
                  Icons.line_weight,
                  size: 16,
                  color: DesignPalette.of(context).dim,
                  semanticLabel: noteDrawingText(
                    NoteDrawingTextKeys.width,
                    '粗细',
                  ),
                ),
                Expanded(
                  child: Slider(
                    key: const Key('note-drawing-width'),
                    value: _width,
                    min: 2,
                    max: 64,
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _width = v),
                  ),
                ),
                Text('${_width.round()}'),
              ],
            ),
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.xs,
              children: [
                for (final c in _palette)
                  _Swatch(
                    key: Key('note-drawing-color-${c.toARGB32()}'),
                    color: c,
                    selected: !_eraser && c.toARGB32() == _color.toARGB32(),
                    onTap: _busy
                        ? null
                        : () => setState(() {
                            _color = c;
                            _eraser = false;
                          }),
                  ),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Text(
              // ★ r716（`D23`）：桌面宿主写**指针**措辞。原来不分平台，
              //   macOS 像素上出现 `Draw with one finger…`（手机手势）。
              //   判据用 `Theme.of(context).platform`（与本 App 其它平台分支同源），
              //   不另起一套 `Platform.isMacOS`。
              // ★ 文案走 ARB（`noteDrawHintDesktop` / `noteDrawHint`），
              //   不在这里写中文字面量（`i18n_source_scan_test` 会红）。
              _isPointerHost(Theme.of(context).platform)
                  ? context.t.noteDrawHintDesktop
                  : context.t.noteDrawHint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? hud.surface2 : hud.line,
            width: selected ? 3 : 1,
          ),
        ),
      ),
    );
  }
}

/// 画布绘制：先铺背景（透明则不铺），再画笔画。
///
/// `saveLayer` 是为了橡皮的 `BlendMode.clear` 只在画布层内生效。
class _NoteDrawingPainter extends CustomPainter {
  _NoteDrawingPainter({required this.strokes, required this.background});

  final List<NoteStroke> strokes;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.saveLayer(rect, Paint());
    if (background.a > 0) {
      canvas.drawRect(rect, Paint()..color = background);
    }
    paintNoteDrawing(canvas, strokes);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _NoteDrawingPainter oldDelegate) =>
      oldDelegate.strokes != strokes || oldDelegate.background != background;
}

/// 指针类宿主（桌面）＝ 触控板/鼠标；其余按触摸措辞。
bool _isPointerHost(TargetPlatform platform) => switch (platform) {
  TargetPlatform.macOS || TargetPlatform.windows || TargetPlatform.linux => true,
  _ => false,
};
