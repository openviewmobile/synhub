// PDF 封面（把第一页渲成小图）——客户端自己出图。
//
// **为什么自己渲**：`SYNO.FileStation.Thumb.get` 对 PDF 也会回 **404 + 一页
// HTML**（真机验证：同一目录下 `cover.jpg` 200 带真 JPEG 字节，`outline.pdf`
// 404 带 11.9KB 错误页）。所以列表里想让 PDF 有封面，只有两条路：
//   * 让 `pdfx`（Android 走系统 `PdfRenderer`）把第一页渲出来 —— 走这条；
//   * 或者不管，永远显示 PDF 分类图标 —— 官方 Drive 客户端是渲的，我们跟上。
//
// 渲染参数按"列表小图"来定，不是按阅读来定：A4 是 595×842 pt，1:1 渲出来
// 就接近 0.5 MP，按 3x 是 18MB 的位图 —— 一屏十几个 PDF 直接把内存打爆。
// 所以这里固定渲到 ~320px 宽、JPEG 80，成品通常 <60KB（和缩略图一个量级）。
//
// 平台通道在单测里不可用 → 渲染器做成**可注入**的 provider（与
// `filePdfViewerProvider` 同一套路），测试注入假实现，只验证"封面链路选对了路"。
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfx/pdfx.dart' as pdfx;

import '../../core/media/pdf_local_copy.dart';
import 'pdf_poppler_view.dart';

/// 一张封面的目标宽度（像素）。列表行只要 40dp，网格也就 120dp 上下；
/// 320 已经能在 3x 屏上铺满，再大只是浪费内存。
const int kPdfCoverWidth = 320;

/// 字节 → 封面图字节（JPEG）。渲不出来 → null（**不抛**，调用方退分类图标）。
typedef PdfCoverRenderer = Future<Uint8List?> Function(Uint8List pdfBytes);

/// 真实实现：`pdfx` 打开文档 → 取第 1 页 → 等比渲成小 JPEG。
Future<Uint8List?> renderPdfFirstPageCover(Uint8List bytes) async {
  pdfx.PdfDocument? doc;
  pdfx.PdfPage? page;
  try {
    // ★ r434：走我们自己的本地副本（落在登记的 `pdf_renderer_cache/`），
    //   不用 `openData` —— 否则 pdfx 会把整份 PDF 写到缓存根层、清不掉。
    doc = await pdfx.PdfDocument.openFile(await defaultPdfLocalCopy(bytes));
    if (doc.pagesCount < 1) return null;
    page = await doc.getPage(1);
    // 页面尺寸单位是 pt；按目标宽度等比缩，长边限一下防止极端长页（海报/长图）
    final scale = kPdfCoverWidth / page.width;
    final w = (page.width * scale).clamp(32.0, 2048.0);
    final h = (page.height * scale).clamp(32.0, 2048.0);
    final img = await page.render(
      width: w,
      height: h,
      format: pdfx.PdfPageImageFormat.jpeg,
      quality: 80,
    );
    final out = img?.bytes;
    return (out == null || out.isEmpty) ? null : out;
  } catch (_) {
    // 加密 PDF、损坏文件、平台不支持：都退"没有封面"。
    // 敢吞的理由：这是列表里的装饰性缩略图，调用方本就有分类图标兜底；
    // 真正的阅读错误由 `file_pdf_view.dart` 那条链路报给用户。
    return null;
  } finally {
    // 两个 close 各自兜异常：`close()` 在文档已被自动关闭时会抛
    // （Android 侧 `autoCloseAndroid` 的时序不受我们控制）
    try {
      await page?.close();
    } catch (_) {}
    try {
      await doc?.close();
    } catch (_) {}
  }
}

/// ★ r691（`DA330`）：Linux 上 `pdfx` 没有实现 ⇒ 列表里的 PDF 封面会恒为空。
/// 改成按平台分流：Linux 用 poppler 渲第一页（`-r 60` ⇒ 320px 量级），
/// 其它平台仍是 pdfx（Android 走系统 `PdfRenderer`，不额外带库）。
final pdfCoverRendererProvider = Provider<PdfCoverRenderer>(
  (ref) => defaultTargetPlatform == TargetPlatform.linux
      ? renderPdfFirstPageCoverWithPoppler
      : renderPdfFirstPageCover,
);

/// poppler 版封面：`pdftoppm` 渲第 1 页到 60 dpi（A4 ≈ 496×702，列表足够）。
///
/// 失败（没装 poppler / 加密 / 坏文件）→ null，调用方退分类图标 ——
/// 与 pdfx 那条路的契约**逐字一致**，不引入第二种"封面失败"表现。
Future<Uint8List?> renderPdfFirstPageCoverWithPoppler(Uint8List bytes) async {
  try {
    final png = await popplerRenderPage(bytes, page: 1, dpi: 60);
    return png.isEmpty ? null : png;
  } catch (_) {
    return null;
  }
}
