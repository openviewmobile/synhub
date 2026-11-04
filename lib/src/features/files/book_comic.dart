// CB7 / CBT（漫画包）→ BookContent —— **纯 Dart**，不 import flutter / l10n。
//
//   * **CBZ** 是 zip（`file_book.dart` 已有）；**CBT** 是 tar → `archive` 直接解，
//     和 CBZ 一样产出 `BookContent.pages`，复用同一个 `_ComicView` 翻页器。
//   * **CB7** 是 7z。`archive ^4.3.0` **没有 7z 解码器**（只有 zip/tar/gzip/
//     bzip2/xz/zlib）。按本批的硬约束：**明确报"不支持 7z（无可用解压实现）"**，
//     绝不用"把 7z 当 zip 硬解"这种半成品糊过去。
//   * **CBR** 是 RAR，同样没有纯 Dart 实现 → 在 `file_book.dart` 里就不进这条路。
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'book_text.dart' show normalizeBookPath;
import 'file_book.dart';

/// `.cbt`：tar 包里的图片 → 漫画页
BookContent parseCbtBook(List<int> bytes, {required BookFormat format}) {
  final archive = TarDecoder().decodeBytes(bytes, verify: false);
  final entries = <({String name, Uint8List data})>[];
  for (final f in archive) {
    if (!f.isFile) continue;
    final name = normalizeBookPath(f.name);
    if (name.startsWith('__MACOSX/')) continue;
    if (!_looksLikeImage(name)) continue;
    entries.add((name: name, data: Uint8List.fromList(f.content as List<int>)));
  }
  if (entries.isEmpty) {
    throw const FormatException('CBT（tar）里没有图片');
  }
  entries.sort((a, b) => _naturalCompare(a.name, b.name));
  return BookContent(format: format, pages: [for (final e in entries) e.data]);
}

/// `.cb7`：7z 包。
///
/// 认识这个格式、也认识它的文件头，但**没有纯 Dart 解压实现** —— 所以给
/// "明确的能力边界错误"（`BookUnsupportedException` → 界面文案"不支持"），
/// 而不是把 7z 字节当图片一样乱解。
BookContent parseCb7Book(List<int> bytes, {required BookFormat format}) {
  if (!is7z(bytes)) {
    throw const FormatException('不是有效的 7z 文件（文件头不匹配）');
  }
  throw BookUnsupportedException(
    '不支持 7z（无可用解压实现）',
    reason: BookUnsupportedReason.compression,
  );
}

/// 7z 文件头：`37 7A BC AF 27 1C`
bool is7z(List<int> bytes) =>
    bytes.length >= 6 &&
    bytes[0] == 0x37 &&
    bytes[1] == 0x7A &&
    bytes[2] == 0xBC &&
    bytes[3] == 0xAF &&
    bytes[4] == 0x27 &&
    bytes[5] == 0x1C;

bool _looksLikeImage(String path) {
  final p = path.toLowerCase();
  return p.endsWith('.jpg') ||
      p.endsWith('.jpeg') ||
      p.endsWith('.png') ||
      p.endsWith('.gif') ||
      p.endsWith('.webp') ||
      p.endsWith('.bmp');
}

/// 文件名自然序（`p2` < `p10`）—— 漫画页顺序错了整个阅读体验就废了
int _naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+|\D+)');
  final as = re.allMatches(a).map((m) => m.group(0)!).toList();
  final bs = re.allMatches(b).map((m) => m.group(0)!).toList();
  for (var i = 0; i < as.length && i < bs.length; i++) {
    final x = as[i], y = bs[i];
    final nx = int.tryParse(x), ny = int.tryParse(y);
    if (nx != null && ny != null) {
      final c = nx.compareTo(ny);
      if (c != 0) return c;
    } else {
      final c = x.toLowerCase().compareTo(y.toLowerCase());
      if (c != 0) return c;
    }
  }
  return as.length.compareTo(bs.length);
}
