// Linux（以及没有 `pdfx` 实现的桌面）上的 PDF 出图 —— 走 **poppler**（`pdftoppm`）。
//
// 为什么需要它：`pdfx` 在 Linux 上没有实现（插件只声明 Android/iOS/macOS/Windows）
// ⇒ 以前 Linux 点 PDF 只能"交系统应用"，用户被踢出浏览路径。
// r690 的验收里这是 **C1 欠账**；本轮（r691）用 poppler 把它补上。
//
// 为什么选 poppler 而不是 `pdfrx`：
//   * `pdfrx 2.11` 依赖 `pdfium_flutter` / `pdfrx_engine`，要用 Dart **native assets**
//     构建钩子在构建期取 PDFium 二进制 —— 这条链在**离线/受限网络**的构建里
//     历史上失败过（`file_pdf_view.dart` 的文件头记着这次教训）；
//   * poppler 是**发行版里的普通包**（`apt install poppler-utils`，国内源一条命令），
//     `pdftoppm` 把某一页渲成 PNG，**纯 CPU**（软件渲染也出图）⇒ 容器里就能验像素。
//
// 代价（如实写在台账里）：**运行期依赖本机有 `poppler-utils`**；没有时这一页
// 给的是**明确**的"装一个"提示，而不是空白/转圈。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../design/design_palette.dart';

/// 一次外部进程调用的结果（只留需要的三项；`stdout/stderr` 已经转成字符串）。
class PdfRasterResult {
  const PdfRasterResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get ok => exitCode == 0;
}

/// 进程执行器（可注入 ⇒ 单测不真起子进程、也不依赖本机装没装 poppler）。
typedef PdfRasterRunner =
    Future<PdfRasterResult> Function(String executable, List<String> args);

Future<PdfRasterResult> _runProcess(String exe, List<String> args) async {
  final r = await Process.run(exe, args);
  return PdfRasterResult(
    exitCode: r.exitCode,
    stdout: '${r.stdout}',
    stderr: '${r.stderr}',
  );
}

final pdfRasterRunnerProvider = Provider<PdfRasterRunner>(
  (ref) => _runProcess,
);

/// `pdftoppm` 在本机是否可用（`-v` 会把版本打到 stderr，退出码 0）。
Future<bool> popplerAvailable(PdfRasterRunner run) async {
  try {
    final r = await run('pdftoppm', const ['-v']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// 一份 PDF 有几页（`pdfinfo` 的 `Pages:` 行）。
///
/// 读不到就返回 null —— 调用方按"未知页数"处理（只给上一页/下一页，
/// 不给"共 N 页"，不编数字）。
Future<int?> popplerPageCount(Uint8List bytes, PdfRasterRunner run) async {
  Directory? dir;
  try {
    dir = await Directory.systemTemp.createTemp('synhub_pdf_info_');
    final input = '${dir.path}/in.pdf';
    await File(input).writeAsBytes(bytes, flush: true);
    final r = await run('pdfinfo', [input]);
    if (!r.ok) return null;
    for (final line in r.stdout.split('\n')) {
      final m = RegExp(r'^Pages:\s*(\d+)').firstMatch(line.trim());
      if (m != null) {
        final n = int.tryParse(m.group(1)!);
        if (n != null && n > 0) return n;
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    try {
      await dir?.delete(recursive: true);
    } catch (_) {}
  }
}

/// 把第 [page] 页（1 基）渲成 PNG 字节。
///
/// 失败（没装 poppler、加密 PDF、坏文件）→ 抛 [PdfRasterException]（带原因码），
/// **不吞**：这一页要告诉用户到底怎么了。
Future<Uint8List> popplerRenderPage(
  Uint8List bytes, {
  required int page,
  int dpi = 120,
  PdfRasterRunner? run,
}) async {
  final runner = run ?? _runProcess;
  Directory? dir;
  try {
    dir = await Directory.systemTemp.createTemp('synhub_pdf_page_');
    final input = '${dir.path}/in.pdf';
    final out = '${dir.path}/page';
    await File(input).writeAsBytes(bytes, flush: true);
    final r = await runner('pdftoppm', [
      '-f',
      '$page',
      '-l',
      '$page',
      '-r',
      '$dpi',
      '-png',
      '-singlefile',
      input,
      out,
    ]);
    if (!r.ok) {
      throw PdfRasterException(
        PdfRasterFailure.toolFailed,
        'pdftoppm exit=${r.exitCode} ${r.stderr}'.trim(),
      );
    }
    final f = File('$out.png');
    if (!f.existsSync()) {
      throw PdfRasterException(
        PdfRasterFailure.noOutput,
        'pdftoppm 没有产出 $out.png（stderr=${r.stderr}）',
      );
    }
    final data = await f.readAsBytes();
    if (data.isEmpty) {
      throw PdfRasterException(PdfRasterFailure.noOutput, '产出的 PNG 是 0 字节');
    }
    return data;
  } on PdfRasterException {
    rethrow;
  } on ProcessException catch (e) {
    // `pdftoppm` 不存在时就是这里（ENOENT）
    throw PdfRasterException(PdfRasterFailure.toolMissing, e.message);
  } finally {
    try {
      await dir?.delete(recursive: true);
    } catch (_) {}
  }
}

enum PdfRasterFailure {
  /// 本机没有 `pdftoppm`（poppler-utils 没装）
  toolMissing,

  /// 装了但这次调用失败（加密/损坏/权限…）
  toolFailed,

  /// 调用成功但没有可用的输出文件
  noOutput,
}

class PdfRasterException implements Exception {
  PdfRasterException(this.failure, this.detail);

  final PdfRasterFailure failure;
  final String detail;

  @override
  String toString() => 'PdfRasterException(${failure.name}): $detail';
}

/// 底部操作条的页数/跳页契约与 `PdfTocBar` 一致，这里只做"看图 + 翻页"。
///
/// 滚动手势与 `pdfx` 那条链**不共享**（poppler 每次只给一页位图），所以：
///   * 竖向滚动 = 看这一页的长图（`InteractiveViewer` 可缩放）；
///   * 翻页用底部按钮（上一页/下一页），一次只渲一页，内存可控。
class PopplerPdfView extends ConsumerStatefulWidget {
  const PopplerPdfView({
    super.key,
    required this.bytes,
    this.dpi = 120,
    this.onPage,
  });

  final Uint8List bytes;

  /// 页面变化回调（外层的目录条要显示"第 x / y 页"并支持跳页）
  final void Function(int page, int? pageCount)? onPage;

  /// 渲染分辨率。120 dpi 对 A4 ≈ 992×1403，够看清正文；
  /// 放大靠 `InteractiveViewer`（矢量放大做不到，但 PDF 的位图放大也够用）。
  final int dpi;

  @override
  ConsumerState<PopplerPdfView> createState() => PopplerPdfViewState();
}

class PopplerPdfViewState extends ConsumerState<PopplerPdfView> {
  int _page = 1;
  int? _pageCount;
  Uint8List? _image;
  Object? _error;
  bool _loading = false;

  /// 供外部（页面级目录跳转）读当前页
  int get page => _page;

  /// 总页数（读不到 = null；不编数字）
  int? get pageCount => _pageCount;

  /// 目录跳页：钳到 [1, pageCount]，并重新渲染那一页。
  Future<void> jumpTo(int page) async {
    final total = _pageCount;
    var target = page;
    if (total != null) target = target.clamp(1, total);
    if (target < 1) target = 1;
    if (target != _page || _image == null) await _render(target);
  }

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void didUpdateWidget(covariant PopplerPdfView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bytes != widget.bytes) {
      _page = 1;
      _pageCount = null;
      _image = null;
      _error = null;
      _boot();
    }
  }

  Future<void> _boot() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final run = ref.read(pdfRasterRunnerProvider);
    final total = await popplerPageCount(widget.bytes, run);
    if (!mounted) return;
    _pageCount = total;
    await _render(_page);
    widget.onPage?.call(_page, _pageCount);
  }

  Future<void> _render(int page) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final img = await popplerRenderPage(
        widget.bytes,
        page: page,
        dpi: widget.dpi,
        run: ref.read(pdfRasterRunnerProvider),
      );
      if (!mounted) return;
      setState(() {
        _page = page;
        _image = img;
        _loading = false;
      });
      widget.onPage?.call(_page, _pageCount);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    if (_error != null) {
      return _PdfRasterErrorView(error: _error!, onRetry: () => _render(_page));
    }
    final img = _image;
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              if (img == null)
                Center(
                  child: Text(
                    context.t.pdfParsing,
                    style: TextStyle(color: hud.dim),
                  ),
                )
              else
                Positioned.fill(
                  child: InteractiveViewer(
                    maxScale: 5,
                    child: Image.memory(
                      img,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                ),
              if (_loading)
                const Positioned(
                  right: 16,
                  top: 16,
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
        ),
        _PdfPager(
          page: _page,
          pageCount: _pageCount,
          onPrev: _page > 1 && !_loading ? () => _render(_page - 1) : null,
          onNext: (_pageCount == null || _page < _pageCount!) && !_loading
              ? () => _render(_page + 1)
              : null,
        ),
      ],
    );
  }
}

class _PdfPager extends StatelessWidget {
  const _PdfPager({
    required this.page,
    required this.pageCount,
    required this.onPrev,
    required this.onNext,
  });

  final int page;
  final int? pageCount;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final total = pageCount;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              key: const Key('pdf-poppler-prev'),
              onPressed: onPrev,
              icon: const Icon(Icons.chevron_left),
              tooltip: context.t.pdfPrevPage,
            ),
            Text(
              total == null
                  ? context.t.pdfPageN(page)
                  : context.t.pdfPageOfTotal(page, total),
              key: const Key('pdf-poppler-page-indicator'),
              style: TextStyle(color: hud.dim),
            ),
            IconButton(
              key: const Key('pdf-poppler-next'),
              onPressed: onNext,
              icon: const Icon(Icons.chevron_right),
              tooltip: context.t.pdfNextPage,
            ),
          ],
        ),
      ),
    );
  }
}

class _PdfRasterErrorView extends StatelessWidget {
  const _PdfRasterErrorView({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final e = error;
    final missing = e is PdfRasterException &&
        e.failure == PdfRasterFailure.toolMissing;
    final detail = e is PdfRasterException ? e.detail : '$e';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              missing ? Icons.extension_off_outlined : Icons.error_outline,
              color: hud.dim,
            ),
            const SizedBox(height: 12),
            Text(
              missing
                  ? t.pdfLinuxNoPoppler
                  : t.pdfOpenFailedDetail(detail),
              key: const Key('pdf-poppler-error'),
              textAlign: TextAlign.center,
              style: TextStyle(color: hud.dim),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(t.photoRetry),
            ),
          ],
        ),
      ),
    );
  }
}
