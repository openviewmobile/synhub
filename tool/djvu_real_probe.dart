// 真实 DJVU 样本的**结构与渲染探针**（样本只在 /tmp，不入库）。
//
//   dart run tool/djvu_real_probe.dart <文件或目录> [...]
//
// 打印：顶层表单 / 页数 / 每页 INFO / 分块清单 / 不支持项 / 渲染结果（尺寸 + 灰度
// 直方图）/ `parseDjvuBook` 结果。用来对真实文件做"能不能读、读成什么样"的体检。
//
// 若本机装了 `djvulibre`（`ddjvu`/`djvudump`），配合 `tool/djvu_real_compare.dart`
// 可做像素级对照；本探针不依赖外部工具。
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:synhub/src/features/files/book_djvu.dart';
import 'package:synhub/src/features/files/djvu_archive.dart';
import 'package:synhub/src/features/files/djvu_render.dart';
import 'package:synhub/src/features/files/file_book.dart';

String _err(Object e) => '${e.runtimeType}: $e';

({int min, int max, double mean, int nonzeroPct}) _stats(DjvuRgba img) {
  var mn = 255, mx = 0, sum = 0, nz = 0;
  final px = img.pixels;
  final n = img.width * img.height;
  for (var i = 0; i < n; i++) {
    final r = px[i * 4], g = px[i * 4 + 1], b = px[i * 4 + 2];
    final v = (r + g + b) ~/ 3;
    if (v < mn) mn = v;
    if (v > mx) mx = v;
    sum += v;
    if (v < 250) nz++;
  }
  return (
    min: mn,
    max: mx,
    mean: n == 0 ? 0 : sum / n,
    nonzeroPct: n == 0 ? 0 : (nz * 100 / n).round(),
  );
}

void _report(String path) {
  print('================ $path');
  final bytes = File(path).readAsBytesSync();
  print('  字节: ${bytes.length}');
  final DjvuArchive arc;
  try {
    arc = DjvuArchive.open(bytes);
  } catch (e) {
    print('  ✗ open 失败: ${_err(e)}');
    return;
  }
  print(
    '  顶层 FORM: ${arc.formType}  isMultiPage=${arc.isMultiPage}  '
    'pages=${arc.pages.length}  bookmarks=${arc.bookmarks.length}  '
    'dir=${arc.directory.length}  thumb=${arc.thumbnail.length}  '
    'archiveUnsupported=${arc.unsupported}',
  );
  for (var i = 0; i < arc.pages.length; i++) {
    final p = arc.pages[i];
    final info = p.info;
    print(
      '  [页 ${i + 1}] title="${p.title}" '
      'INFO=${info == null ? "无" : "${info.width}x${info.height} v${info.version} dpi${info.dpi} rot${info.orientation} γ${info.gamma}"} '
      'sjbz=${p.sjbz?.length ?? "-"} djbz=${p.djbz?.length ?? "-"} '
      'bg44=${p.bg44.length} fg44=${p.fg44.length} th44=${p.th44.length} '
      'text=${p.text.length} unsupported=${p.unsupported} unknown=${p.unknownChunks}',
    );
    if (!p.hasBitmap) {
      if (p.text.isEmpty) {
        print('       ⚠ 既没有位图也没有文本');
      }
      continue;
    }
    try {
      final rgba = djvuRenderPage(p);
      final s = _stats(rgba);
      print(
        '       ✓ 渲染 ${rgba.width}x${rgba.height}  '
        'gray min=${s.min} max=${s.max} mean=${s.mean.toStringAsFixed(1)} '
        '非白=${s.nonzeroPct}%',
      );
    } catch (e) {
      print('       ✗ 渲染失败: ${_err(e)}');
    }
  }
  // 内容层：走 reader 真正会走的那个入口（含封面）。
  try {
    final r = parseDjvuBook(bytes, format: BookFormat.djvu);
    if (r.error != null) {
      print('  parseDjvuBook → ✗ ${r.errorKind}: ${r.error}');
    } else {
      final total = r.content.pages.fold<int>(0, (a, p) => a + p.length);
      print(
        '  parseDjvuBook → ✓ pages=${r.content.pages.length} '
        '(${total ~/ 1024} KiB) chapters=${r.content.chapters.length} '
        'toc=${r.content.toc.length}',
      );
    }
    final cover = djvuCoverBytes(bytes);
    print('  封面: ${cover == null ? "无" : "${cover.length} B PNG"}');
  } catch (e) {
    print('  parseDjvuBook → ✗ 抛异常: ${_err(e)}');
  }
}

void main(List<String> args) {
  final paths = <String>[];
  for (final a in args) {
    final d = Directory(a);
    if (d.existsSync()) {
      final found =
          d
              .listSync()
              .whereType<File>()
              .where((f) => f.path.toLowerCase().endsWith('.djvu'))
              .map((f) => f.path)
              .toList()
            ..sort();
      paths.addAll(found);
    } else {
      paths.add(a);
    }
  }
  if (paths.isEmpty) {
    print('用法: dart run tool/djvu_real_probe.dart <文件或目录> [...]');
    exit(2);
  }
  for (final p in paths) {
    _report(p);
  }
}
