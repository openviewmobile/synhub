// ★★★ ③Drive **D61「PDF 批注 / 签名」** 的界面 + 导出 —— 第 219 轮。
//
// 官方：包内带 `pdftool`/pdfium/pdfbox，App 内直接批注/签名后存回 Drive。
// 我方：**批注层 + sidecar 持久化 + 烙平导出 + 存回 Drive**（`Files/upload`）。
// ⚠️ 我们不往 PDF 对象层写注释对象（导出即烙平）—— 与官方实现方式不同，如实登记。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import '../../design/design_palette.dart';
import '../../core/ui/adaptive_actions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/i18n/l10n.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfx/pdfx.dart' as pdfx;

import '../../core/media/pdf_local_copy.dart';
import '../files/pdf_poppler_view.dart';

import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import 'drive_gaps_text.dart';
import '../files/drive_providers.dart';
import 'drive_pdf_annot_export.dart';
import 'drive_pdf_text_layer.dart';
import 'drive_pdf_markup.dart';

String _zh(String key, String zh) => driveGap(key, zh);

/// 把 PDF 每页渲染成位图（可注入 ⇒ 离线用例不依赖 pdfx 的平台通道）。
typedef PdfPageRasterizer =
    Future<List<PdfPageBitmap>> Function(Uint8List pdf);

Future<List<PdfPageBitmap>> defaultPdfPageRasterizer(Uint8List pdf) async {
  // ★ r434：不用 `openData`（插件会把整份 PDF 写到缓存根层、清不掉），
  //   改走我们自己的本地副本（落在登记的 `pdf_renderer_cache/`）。
  final doc = await pdfx.PdfDocument.openFile(await defaultPdfLocalCopy(pdf));
  try {
    final out = <PdfPageBitmap>[];
    for (var i = 1; i <= doc.pagesCount; i++) {
      final page = await doc.getPage(i);
      final img = await page.render(width: 1240, height: 1754);
      final bytes = img?.bytes;
      final w = img?.width ?? 0;
      final h = img?.height ?? 0;
      await page.close();
      if (bytes == null) continue;
      out.add(
        PdfPageBitmap(
          page: i - 1,
          width: w,
          height: h,
          pngBytes: bytes,
        ),
      );
    }
    return out;
  } finally {
    await doc.close();
  }
}

/// ★ r695（`DA337`）：**Linux 上没有 `pdfx`** —— 批注页以前直接调
/// `defaultPdfPageRasterizer` ⇒ 一推进来就抛
/// `PlatformNotSupportedException: Actual platform not supported by it method`
/// （整轮 Linux 走查在第 155 屏被打红）。查看器（`DA330`）与封面早已按平台分流，
/// 这里漏了同一条路：**同一个能力有几个入口，就得有几处分流**。
///
/// Linux → poppler（`pdftoppm`，与查看器/封面同一条 CPU 渲染链）；
/// 其它平台仍走 pdfx（Android 用系统 `PdfRenderer`，不额外带库）。
final pdfPageRasterizerProvider = Provider<PdfPageRasterizer>((ref) {
  if (defaultTargetPlatform != TargetPlatform.linux) {
    return defaultPdfPageRasterizer;
  }
  final run = ref.watch(pdfRasterRunnerProvider);
  return (pdf) => rasterizePdfPagesWithPoppler(pdf, run);
});

/// poppler 版"整份 PDF 逐页出图"。
///
/// 契约与 `defaultPdfPageRasterizer` **逐字一致**：`PdfPageBitmap.page` 是 **0 基**，
/// `pngBytes` 是这一页的 PNG。差别只在渲染后端（一次一页、纯 CPU）。
///
/// 页数从 `pdfinfo` 的 `Pages:` 行取；读不到就只渲第 1 页（**不编页数**）。
Future<List<PdfPageBitmap>> rasterizePdfPagesWithPoppler(
  Uint8List pdf,
  PdfRasterRunner run,
) async {
  final count = await popplerPageCount(pdf, run);
  final total = (count == null || count < 1) ? 1 : count;
  final out = <PdfPageBitmap>[];
  for (var i = 1; i <= total; i++) {
    final png = await popplerRenderPage(pdf, page: i, dpi: 110, run: run);
    final size = _pngPixelSize(png);
    out.add(
      PdfPageBitmap(
        page: i - 1,
        width: size.$1,
        height: size.$2,
        pngBytes: png,
      ),
    );
  }
  return out;
}

/// PNG 的像素尺寸 = IHDR 里的宽高（字节 16..24，大端）。
///
/// 为什么自己读：poppler 只给 PNG 字节，不给宽高；而 `PdfPageBitmap` 要用它算
/// 批注层坐标。读不到就退 0（调用方按"未知尺寸"处理，不编一个像真的数字）。
(int, int) _pngPixelSize(Uint8List png) {
  const sig = <int>[137, 80, 78, 71, 13, 10, 26, 10];
  if (png.length < 24) return (0, 0);
  for (var i = 0; i < sig.length; i++) {
    if (png[i] != sig[i]) return (0, 0);
  }
  final w = (png[16] << 24) | (png[17] << 16) | (png[18] << 8) | png[19];
  final h = (png[20] << 24) | (png[21] << 16) | (png[22] << 8) | png[23];
  return (w, h);
}

final pdfMarkupStoreProvider = Provider<PdfMarkupStore>(
  (ref) => const SidecarPdfMarkupStore(),
);

/// 某一页 + 该页批注 → 烙平进 PDF。
///
/// 用 `pdf` 包的画布原语（矩形/线/文字）而不是 `dart:ui` 位图合成：
/// 这样导出是**纯 Dart**，离线用例能在没有 GPU/平台通道的情况下验证。
Future<Uint8List> flattenPdfMarkups({
  required List<PdfPageBitmap> pages,
  required PdfMarkupDoc doc,
}) async {
  final out = pw.Document();
  for (final p in pages) {
    final w = p.width.toDouble().clamp(1, 100000).toDouble();
    final h = p.height.toDouble().clamp(1, 100000).toDouble();
    final ops = pdfPageDrawOps(doc, p.page, w, h);
    final image = pw.MemoryImage(Uint8List.fromList(p.pngBytes));
    out.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(w, h, marginAll: 0),
        build: (ctx) => pw.Stack(
          children: [
            pw.Positioned.fill(child: pw.Image(image, fit: pw.BoxFit.fill)),
            for (final op in ops)
              if (op.kind == PdfMarkupKind.highlight)
                pw.Positioned(
                  left: op.rect.left,
                  top: op.rect.top,
                  child: pw.Container(
                    width: (op.rect.right - op.rect.left).clamp(1, w).toDouble(),
                    height: (op.rect.bottom - op.rect.top).clamp(1, h).toDouble(),
                    color: PdfColor.fromInt(op.color),
                  ),
                )
              else if (op.kind == PdfMarkupKind.note)
                pw.Positioned(
                  left: op.rect.left,
                  top: op.rect.top,
                  child: pw.Container(
                    padding: const pw.EdgeInsets.all(4),
                    color: PdfColors.yellow,
                    child: pw.Text(
                      op.note,
                      style: const pw.TextStyle(fontSize: 10),
                    ),
                  ),
                )
              else
                pw.Positioned.fill(
                  child: pw.CustomPaint(
                    size: PdfPoint(w, h),
                    painter: (canvas, size) {
                      canvas
                        ..setStrokeColor(PdfColor.fromInt(op.color))
                        ..setLineWidth(2.4);
                      if (op.points.isEmpty) return;
                      canvas.moveTo(op.points.first.dx, h - op.points.first.dy);
                      for (final pt in op.points.skip(1)) {
                        canvas.lineTo(pt.dx, h - pt.dy);
                      }
                      canvas.strokePath();
                    },
                  ),
                ),
          ],
        ),
      ),
    );
  }
  return Uint8List.fromList(await out.save());
}

enum PdfMarkupMode { highlight, ink, note }

class DrivePdfMarkupPage extends ConsumerStatefulWidget {
  const DrivePdfMarkupPage({
    super.key,
    required this.filePath,
    required this.fileName,
    required this.bytes,
    this.folderId,
  });

  /// 本地路径（sidecar 放它旁边）
  final String filePath;
  final String fileName;
  final Uint8List bytes;

  /// 有 Drive 目录 id 时可以把导出的 PDF 存回 Drive
  final String? folderId;

  @override
  ConsumerState<DrivePdfMarkupPage> createState() => _DrivePdfMarkupPageState();
}

class _DrivePdfMarkupPageState extends ConsumerState<DrivePdfMarkupPage> {
  PdfMarkupDoc _doc = PdfMarkupDoc();
  List<PdfPageBitmap> _pages = const [];
  PdfMarkupMode _mode = PdfMarkupMode.highlight;
  int _page = 0;
  bool _loading = true;
  bool _saving = false;
  /// ★ 245 轮 D61：自研**文字层**（框选文字 → 真实行四边形）
  PdfTextLayer _textLayer = const PdfTextLayer.empty();
  String? _error;
  String? _savedTo;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final store = ref.read(pdfMarkupStoreProvider);
      final doc = await store.load(widget.filePath);
      final pages = await ref.read(pdfPageRasterizerProvider)(widget.bytes);
      // ★ 245 轮：抽文字层（纯本地；解析不了就 parsed=false，绝不猜坐标）
      PdfTextLayer layer = const PdfTextLayer.empty();
      try {
        layer = extractPdfTextLayer(widget.bytes);
      } catch (_) {
        layer = const PdfTextLayer.empty();
      }
      if (!mounted) return;
      setState(() {
        _textLayer = layer;
        _doc = doc;
        _pages = pages;
        _loading = false;
        if (pages.isEmpty) {
          _error = _zh('drive_pdf_no_page', '这份 PDF 没有可渲染的页面');
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error =
            '${_zh('drive_pdf_render_failed', '渲染失败')}'
            '${_zh('driveGapLabelSep', '：')}$e';
      });
    }
  }

  Future<void> _persist() async {
    await ref.read(pdfMarkupStoreProvider).save(widget.filePath, _doc);
  }

  /// ★ 245 轮 D61：高亮落点时**先问文字层**——框选到文字就按"行"写
  /// 四边形（`/QuadPoints`），并把选中的文字存进批注；没有文字层
  /// （或没框到文字）才退回普通矩形，并如实提示。
  void _addHighlight({
    required PdfPageBitmap page,
    required double x0,
    required double y0,
    required double x1,
    required double y1,
    required double cw,
    required double ch,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final layerPage = _textLayer.pages.length > page.page
        ? _textLayer.pages[page.page]
        : null;
    final l = (x0 < x1 ? x0 : x1) / cw;
    final r = (x0 < x1 ? x1 : x0) / cw;
    final t = (y0 < y1 ? y0 : y1) / ch;
    final b = (y0 < y1 ? y1 : y0) / ch;
    if (layerPage != null && layerPage.parsed) {
      final sel = pdfTextSelectionToQuote(
        spans: layerPage.spans,
        left: l,
        top: t,
        right: r,
        bottom: b,
        pageWidth: page.width.toDouble(),
        pageHeight: page.height.toDouble(),
      );
      if (!sel.isEmpty) {
        final ql = sel.rect[0] / page.width;
        final qb = 1 - sel.rect[1] / page.height;
        final qr = sel.rect[2] / page.width;
        final qt = 1 - sel.rect[3] / page.height;
        _addMarkup(
          PdfMarkup(
            id: 'hl_${DateTime.now().microsecondsSinceEpoch}',
            page: page.page,
            kind: PdfMarkupKind.highlight,
            left: ql.clamp(0.0, 1.0),
            top: qt.clamp(0.0, 1.0),
            right: qr.clamp(0.0, 1.0),
            bottom: qb.clamp(0.0, 1.0),
            quads: sel.quads,
            selectedText: sel.text,
            createdAtMs: now,
          ),
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.t.drivePdfTextSelectedDetail(
                sel.text.length > 40
                    ? '${sel.text.substring(0, 40)}…'
                    : sel.text,
              ),
            ),
          ),
        );
        return;
      }
    }
    _addMarkup(
      normalizePdfHighlight(
        id: 'hl_${DateTime.now().microsecondsSinceEpoch}',
        page: page.page,
        x0: x0,
        y0: y0,
        x1: x1,
        y1: y1,
        width: cw,
        height: ch,
        createdAtMs: now,
      ),
    );
    if (layerPage == null || !layerPage.parsed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${_zh('drive_pdf_no_text_layer', '本页文字层不可用，按矩形高亮')}'
            '${layerPage != null && layerPage.reason.isNotEmpty ? '${_zh('driveGapLabelSep', '：')}${layerPage.reason}' : ''}',
          ),
        ),
      );
    }
  }

  void _addMarkup(PdfMarkup m) {
    setState(() => _doc.add(m));
    _persist();
  }

  void _removeLast() {
    final mine = widget.filePath.isEmpty ? null : _doc.marks.lastOrNull;
    if (mine == null) return;
    setState(() => _doc.remove(mine.id));
    _persist();
  }

  Future<void> _addNote() async {
    // ⚠️ 控制器必须由**对话框自己**持有并释放：在 `showDialog` 返回后立刻
    // `dispose()` 会在退场动画期间被 TextField 再读一次 ⇒
    // "A TextEditingController was used after being disposed"（用例当场抓到）。
    final text = await showDialog<String>(
      context: context,
      builder: (_) => const _NoteDialog(),
    );
    if (text == null || text.trim().isEmpty) return;
    _addMarkup(
      PdfMarkup(
        id: 'note_${DateTime.now().microsecondsSinceEpoch}',
        page: _page,
        kind: PdfMarkupKind.note,
        left: 0.08,
        top: 0.08 + _doc.marksForPage(_page).length * 0.04,
        note: text.trim(),
        color: 0xFFFFF176,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// ★ 244 轮 D61：把批注**写回原文件**（原字节 + 增量更新），
  /// 本地落 `<名>_写回.pdf`；有 Drive 目录时按**同名**上传 ⇒ Drive 侧成新版本。
  Future<void> _writeBack({required bool toDrive}) async {
    if (_pages.isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
      _savedTo = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final pdfBytes = await writeBackPdfAnnotations(
        original: widget.bytes,
        doc: _doc,
        pages: _pages,
      );
      final dir = await getTemporaryDirectory();
      final name = widget.fileName.replaceAll(
        RegExp(r'\.pdf$', caseSensitive: false),
        '',
      );
      final out = File(
        '${dir.path}/$name${_zh('drivePdfWrittenSuffix', '_写回')}.pdf',
      );
      await out.writeAsBytes(pdfBytes);
      if (toDrive) {
        final api = ref.read(driveApiProvider);
        final folderId = widget.folderId;
        if (api == null || folderId == null || folderId.isEmpty) {
          throw StateError(_zh('setNotConnected', '未连接'));
        }
        // 同名上传 ⇒ Drive 端写回"原文件"的新版本（conflict_action=version）
        await api.uploadFile(
          folderId: folderId,
          filePath: out.path,
          fileName: widget.fileName,
          mimeType: 'application/pdf',
        );
      }
      if (!mounted) return;
      setState(() {
        _saving = false;
        _savedTo = toDrive
            ? _zh('drive_pdf_written_drive', '已写回原文件（Drive 新版本）')
            : '${_zh('drive_pdf_written_local', '已写回')}'
                  '${_zh('driveGapLabelSep', '：')}${out.path}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error =
            '${_zh('drive_pdf_writeback_failed', '写回失败')}'
            '${_zh('driveGapLabelSep', '：')}$e';
      });
    }
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text('${_doc.count} ${_zh('drive_pdf_marks', '条批注')}')),
    );
  }

  Future<void> _export({required bool toDrive}) async {
    if (_pages.isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
      _savedTo = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      // ★ 231 轮 D61：导出**带注释对象**（/Annots）的副本 —— 其他阅读器的
      // 批注面板能列出来；视觉层同时保留（不看面板的阅读器一样看得到）。
      final pdfBytes = await flattenPdfMarkupsAnnotated(
        pages: _pages,
        doc: _doc,
      );
      final dir = await getTemporaryDirectory();
      final name = widget.fileName.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
      final out = File(
        '${dir.path}/$name${_zh('drivePdfAnnotSuffix', '_批注')}.pdf',
      );
      await out.writeAsBytes(pdfBytes);
      if (toDrive) {
        final api = ref.read(driveApiProvider);
        final folderId = widget.folderId;
        if (api == null || folderId == null || folderId.isEmpty) {
          throw StateError(_zh('setNotConnected', '未连接'));
        }
        await api.uploadFile(
          folderId: folderId,
          filePath: out.path,
          fileName: '$name${_zh('drivePdfAnnotSuffix', '_批注')}.pdf',
          mimeType: 'application/pdf',
        );
      }
      if (!mounted) return;
      setState(() {
        _saving = false;
        _savedTo = toDrive
            ? _zh('drive_pdf_saved_drive', '已存回 Drive')
            : '${_zh('drive_pdf_saved_local', '已导出')}'
                  '${_zh('driveGapLabelSep', '：')}${out.path}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error =
            '${_zh('drive_pdf_export_failed', '导出失败')}'
            '${_zh('driveGapLabelSep', '：')}$e';
      });
    }
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text('${_doc.count} ${_zh('drive_pdf_marks', '条批注')}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Scaffold(
      key: const Key('drive-pdf-markup-page'),
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(widget.fileName),
        actions: adaptiveActions([
          IconButton(
            key: const Key('drive-pdf-undo'),
            tooltip: _zh('drive_pdf_undo', '撤销上一条'),
            icon: const Icon(Icons.undo),
            onPressed: _doc.isEmpty ? null : _removeLast,
          ),
          IconButton(
            key: const Key('drive-pdf-export'),
            tooltip: _zh('drive_pdf_export', '导出批注版 PDF'),
            icon: const Icon(Icons.picture_as_pdf_outlined),
            onPressed: _saving ? null : () => _export(toDrive: false),
          ),
          // ★ 244 轮 D61：**写回原文件**（自研 PDF 增量更新；不是导出副本）。
          IconButton(
            key: const Key('drive-pdf-writeback'),
            tooltip: _zh('drive_pdf_writeback', '写回原文件（增量更新）'),
            icon: const Icon(Icons.edit_document),
            onPressed: _saving || _doc.isEmpty
                ? null
                : () => _writeBack(toDrive: widget.folderId != null),
          ),
          if (widget.folderId != null)
            IconButton(
              key: const Key('drive-pdf-save-drive'),
              tooltip: _zh('drive_pdf_save_drive', '保存到 Drive'),
              icon: const Icon(Icons.cloud_upload_outlined),
              onPressed: _saving ? null : () => _export(toDrive: true),
            ),
        ]),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _toolbar(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(Gap.sm),
                    child: Text(
                      key: const Key('drive-pdf-error'),
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (_savedTo != null)
                  Padding(
                    padding: const EdgeInsets.all(Gap.sm),
                    child: Text(
                      key: const Key('drive-pdf-saved'),
                      _savedTo!,
                      style: TextStyle(color: Theme.of(context).colorScheme.primary),
                    ),
                  ),
                Expanded(
                  child: _pages.isEmpty
                      ? AppEmptyState(
                          icon: Icons.picture_as_pdf_outlined,
                          title: widget.fileName,
                          message: _zh('drive_pdf_no_page', '这份 PDF 没有可渲染的页面'),
                        )
                      : ListView.builder(
                          itemCount: _pages.length,
                          itemBuilder: (context, i) => _pageView(_pages[i]),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _toolbar() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
    child: Wrap(
      spacing: Gap.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SegmentedButton<PdfMarkupMode>(
          key: const Key('drive-pdf-mode'),
          segments: [
            ButtonSegment(
              value: PdfMarkupMode.highlight,
              label: Text(_zh('drive_pdf_highlight', '高亮')),
              icon: const Icon(Icons.highlight_outlined),
            ),
            ButtonSegment(
              value: PdfMarkupMode.ink,
              label: Text(_zh('drive_pdf_ink', '手写/签名')),
              icon: const Icon(Icons.draw_outlined),
            ),
            ButtonSegment(
              value: PdfMarkupMode.note,
              label: Text(_zh('drive_pdf_note', '便签')),
              icon: const Icon(Icons.sticky_note_2_outlined),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: (s) {
            final m = s.first;
            setState(() => _mode = m);
            if (m == PdfMarkupMode.note) _addNote();
          },
        ),
        Text('${_doc.count} ${_zh('drive_pdf_marks', '条批注')}'),
        Text('· ${_zh('drive_pdf_pages', '页')} ${_pages.length}'),
      ],
    ),
  );

  Widget _pageView(PdfPageBitmap page) {
    final w = page.width.toDouble().clamp(1, 100000).toDouble();
    final h = page.height.toDouble().clamp(1, 100000).toDouble();
    final pending = <double>[];
    return Padding(
      padding: const EdgeInsets.all(Gap.md),
      child: AspectRatio(
        aspectRatio: w / h,
        child: LayoutBuilder(
          builder: (context, box) {
            final cw = box.maxWidth;
            final ch = box.maxHeight;
            return GestureDetector(
              key: Key('drive-pdf-page-${page.page}'),
              onTapDown: (_) => setState(() => _page = page.page),
              onPanStart: _mode == PdfMarkupMode.ink
                  ? (d) {
                      pending
                        ..clear()
                        ..addAll([d.localPosition.dx, d.localPosition.dy]);
                    }
                  : null,
              onPanUpdate: _mode == PdfMarkupMode.ink
                  ? (d) => pending.addAll([d.localPosition.dx, d.localPosition.dy])
                  : null,
              onPanEnd: _mode == PdfMarkupMode.ink
                  ? (_) {
                      if (pending.length >= 4) {
                        _addMarkup(
                          normalizePdfInk(
                            id: 'ink_${DateTime.now().microsecondsSinceEpoch}',
                            page: page.page,
                            pixelPoints: pending,
                            width: cw,
                            height: ch,
                            color: 0xFFE53935,
                            createdAtMs: DateTime.now().millisecondsSinceEpoch,
                          ),
                        );
                      }
                    }
                  : null,
              onLongPressStart: _mode == PdfMarkupMode.highlight
                  ? (d) => _highlightStart = d.localPosition
                  : null,
              onLongPressEnd: _mode == PdfMarkupMode.highlight
                  ? (d) {
                      final s = _highlightStart;
                      if (s == null) return;
                      _addHighlight(
                        page: page,
                        x0: s.dx,
                        y0: s.dy,
                        x1: d.localPosition.dx,
                        y1: d.localPosition.dy,
                        cw: cw,
                        ch: ch,
                      );
                    }
                  : null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(
                    Uint8List.fromList(page.pngBytes),
                    fit: BoxFit.fill,
                    gaplessPlayback: true,
                  ),
                  IgnorePointer(
                    child: CustomPaint(
                      painter: _MarkupPainter(
                        ops: pdfPageDrawOps(_doc, page.page, cw, ch),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  ui.Offset? _highlightStart;
}

/// 只负责"把批注画到页面上"（几何与导出共用 `pdfPageDrawOps`）
class _MarkupPainter extends CustomPainter {
  const _MarkupPainter({required this.ops});

  final List<PdfPageDrawOp> ops;

  @override
  void paint(Canvas canvas, Size size) {
    for (final op in ops) {
      final color = Color(op.color);
      if (op.kind == PdfMarkupKind.highlight) {
        canvas.drawRect(
          Rect.fromLTRB(op.rect.left, op.rect.top, op.rect.right, op.rect.bottom),
          Paint()
            ..color = color.withValues(alpha: 0.35)
            ..style = PaintingStyle.fill,
        );
      } else if (op.kind == PdfMarkupKind.note) {
        final tp = TextPainter(
          text: TextSpan(
            text: op.note,
            style: const TextStyle(fontSize: 11, color: Colors.black),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: size.width * 0.5);
        final r = Rect.fromLTWH(
          op.rect.left,
          op.rect.top,
          tp.width + 6,
          tp.height + 4,
        );
        canvas.drawRect(r, Paint()..color = Colors.yellow.withValues(alpha: 0.9));
        tp.paint(canvas, Offset(r.left + 3, r.top + 2));
      } else if (op.points.length >= 2) {
        final path = Path()
          ..moveTo(op.points.first.dx, op.points.first.dy);
        for (final p in op.points.skip(1)) {
          path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..strokeWidth = 2.4
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MarkupPainter old) =>
      old.ops.length != ops.length ||
      old.ops.map((o) => '${o.kind}${o.rect}').join() !=
          ops.map((o) => '${o.kind}${o.rect}').join();
}

/// 便签输入对话框（自己持有控制器，退场动画结束后才释放）
class _NoteDialog extends StatefulWidget {
  const _NoteDialog();

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_zh('drive_pdf_note', '便签')),
    content: TextField(
      key: const Key('drive-pdf-note-field'),
      controller: _ctl,
      autofocus: true,
      maxLines: 3,
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(_zh('common_cancel', '取消')),
      ),
      FilledButton(
        key: const Key('drive-pdf-note-save'),
        onPressed: () => Navigator.of(context).pop(_ctl.text),
        child: Text(_zh('common_save', '保存')),
      ),
    ],
  );
}
