// 给"OPC / zip 容器类电子书"（XPS/OXPS、FB3、以及后续同类）用的**纯 Dart**
// 包容器工具 —— 不 import flutter / l10n。
//
// 这里只放**无状态、可复用**的几件东西，避免每个新格式各写一份：
//   * zip → `归一化路径（小写）→ 字节`；
//   * OPC 部件名解析（`/Documents/1/Pages/1.fpage` 与 `Pages/1.fpage` 两种写法）；
//   * 图片路径/字节的识别；
//   * HTML 转义（拼正文片段时防注入）。
//
// 与 `book_office.dart` 里的私有 `_unzip` 语义保持一致（zip 路径大小写不统一，
// 一律小写做键），但**不共享代码**：office 那份是它自己的实现细节，这里独立一份，
// 免得改一边崩另一边。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'book_text.dart' show normalizeBookPath;

/// zip 包 → `小写归一化路径 → 字节`。
///
/// [what] 只用于错误文案（`'XPS'` / `'FB3'`）。zip 里没有任何文件时明确报错，
/// 不让上层拿到一个空包继续往下猜。
Map<String, Uint8List> unzipBookPackage(List<int> bytes, String what) {
  final archive = ZipDecoder().decodeBytes(bytes, verify: false);
  final files = <String, Uint8List>{};
  for (final f in archive) {
    if (!f.isFile) continue;
    final name = normalizeBookPath(f.name).toLowerCase();
    if (name.isEmpty) continue;
    files[name] = Uint8List.fromList(f.content as List<int>);
  }
  if (files.isEmpty) throw FormatException('$what 是空的（zip 里没有文件）');
  return files;
}

/// 字节开头是不是 zip（`PK\x03\x04` / 空 zip 的 `PK\x05\x06`）。
///
/// FB3 既有"zip 包着的"也有"裸 XML"两种存世写法，靠它分流。
bool bookBytesAreZip(List<int> bytes) {
  if (bytes.length < 4) return false;
  if (bytes[0] != 0x50 || bytes[1] != 0x4B) return false;
  return (bytes[2] == 0x03 && bytes[3] == 0x04) ||
      (bytes[2] == 0x05 && bytes[3] == 0x06);
}

/// 是不是 zip 路径为图片（看后缀；`.svg` 也算，渲染层能显示 SVG）
bool bookLooksLikeImagePath(String path) {
  final p = path.toLowerCase();
  return p.endsWith('.jpg') ||
      p.endsWith('.jpeg') ||
      p.endsWith('.png') ||
      p.endsWith('.gif') ||
      p.endsWith('.webp') ||
      p.endsWith('.bmp') ||
      p.endsWith('.tif') ||
      p.endsWith('.tiff') ||
      p.endsWith('.svg');
}

/// 字节的 magic number → 图片后缀（不是图片返回 null）。
///
/// XPS 的图片部件**不一定**带图片后缀（资源名可以是任意 part name），所以除了
/// 看路径，还要能看字节。TIFF 也认：XPS 里 `.tif` 并不罕见。
String? bookImageKindOfBytes(Uint8List b) {
  if (b.length < 4) return null;
  if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'jpg';
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return 'png';
  }
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return 'gif';
  if (b[0] == 0x42 && b[1] == 0x4D) return 'bmp';
  if (b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return 'webp';
  }
  // TIFF：`II*\0` / `MM\0*`
  if (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0x00) {
    return 'tiff';
  }
  if (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0x00 && b[3] == 0x2A) {
    return 'tiff';
  }
  return null;
}

/// OPC 部件路径解析：`Source="/Documents/1/Pages/1.fpage"` 或相对写法都归一化。
///
/// [baseDir] 是引用方所在目录（带结尾 `/`，没有就传空串）。绝对路径（以 `/`
/// 开头）直接归一化，其余按 baseDir 拼。与 `file_book.dart` 里的 `_resolve`
/// 同款规则，但这里对**小写**做统一（zip 键是小写的）。
String bookResolvePart(String baseDir, String href) {
  final clean = href.split('#').first.split('?').first.replaceAll('\\', '/');
  final joined = clean.startsWith('/') ? clean.substring(1) : '$baseDir$clean';
  return normalizeBookPath(joined).toLowerCase();
}

/// `Documents/1/FixedDoc.fdoc` → `documents/1/`（小写，带结尾 `/`）
String bookDirOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i + 1);
}

String bookEscapeHtml(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String bookEscapeAttr(String s) =>
    bookEscapeHtml(s).replaceAll('"', '&quot;').replaceAll("'", '&#39;');

/// 去掉 XML/HTML 标签取纯文本（FB3/XPS 的元数据取值用）
String bookStripTags(String s) => s.replaceAll(RegExp(r'<[^>]*>'), '').trim();

/// 全部图片部件（zip 路径 → 字节）：路径后缀像图片，或字节 magic 像图片。
///
/// XPS 的资源名可能是 `Resources/Images/1` 这种没后缀的，所以两条判据都上。
Map<String, Uint8List> bookImageParts(Map<String, Uint8List> files) {
  final out = <String, Uint8List>{};
  files.forEach((path, data) {
    if (bookLooksLikeImagePath(path) || bookImageKindOfBytes(data) != null) {
      out[path] = data;
    }
  });
  return out;
}

/// 从 UTF-16LE/BE 带 BOM 或普通字节里解 XML 文本（探测失败回落 UTF-8 容错）。
///
/// `book_xml.dart` 的 `parseBookXmlBytes` 已经会做编码探测；这里只是给"想先看
/// 一眼根标签"的调用方一个轻量入口。
String decodeBookXmlText(List<int> bytes) {
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _utf16(bytes.sublist(2), littleEndian: true);
    }
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _utf16(bytes.sublist(2), littleEndian: false);
    }
  }
  return utf8.decode(bytes, allowMalformed: true);
}

String _utf16(List<int> b, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = 0; i + 1 < b.length; i += 2) {
    units.add(
      littleEndian ? (b[i] | (b[i + 1] << 8)) : ((b[i] << 8) | b[i + 1]),
    );
  }
  return String.fromCharCodes(units);
}
