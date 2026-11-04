// 用**真实 MOBI / AZW3** 对自研解析器（PalmDB + PalmDOC LZ77 + EXTH）做离线验证。
//
// 只调 `lib/src/features/files/book_mobi.dart` 与 `file_book.dart` 的公开 API，
// 不 import flutter / l10n，`dart run` 即可。
//
// 用法：
//   dart run tool/mobi_real_probe.dart <book.mobi|book.azw3>
//
// 输出：BookFormat 判定 / 书名 / 作者 / 章节数 / 封面字节与图片类型 /
// 前三章开头 80 字，以及头部关键字段（mobiVersion、EXTH 121 边界、EXTH 125…）
// 用来判定"纯 KF8"还是"joint MOBI+KF8"。
//
// 样本只放 /tmp，不提交进仓库。
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:synhub/src/features/files/book_mobi.dart';
import 'package:synhub/src/features/files/file_book.dart';

// PalmDB / MOBI 头是**大端**
int _u16(Uint8List b, int o) => (b[o] << 8) | b[o + 1];

int _i32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

String _ascii(Uint8List b, int o, int n) =>
    String.fromCharCodes(b.sublist(o, o + n));

String stripTags(String s) => s
    .replaceAll(RegExp(r'<[^>]*>'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String imageKind(Uint8List b) {
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return 'jpeg';
  }
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    return 'png';
  }
  if (b.length >= 6 && _ascii(b, 0, 3) == 'GIF') return 'gif';
  if (b.length >= 12 &&
      _ascii(b, 0, 4) == 'RIFF' &&
      _ascii(b, 8, 4) == 'WEBP') {
    return 'webp';
  }
  return 'unknown(${b.length >= 4 ? b.sublist(0, 4).map((x) => x.toRadixString(16).padLeft(2, '0')).join() : ''})';
}

/// 独立的 PalmDB/EXTH 轻探针（仅用于报告原始字段，不参与解析判定）。
Map<String, Object?> rawHeader(Uint8List bytes) {
  try {
    final n = _u16(bytes, 76);
    if (78 + n * 8 > bytes.length) return {'error': '记录表越界'};
    int off(int i) => _i32(bytes, 78 + i * 8);
    final rec0 = Uint8List.sublistView(bytes, off(0), off(1));
    final out = <String, Object?>{
      'records': n,
      'palmType': _ascii(bytes, 60, 4),
      'palmCreator': _ascii(bytes, 64, 4),
      'compression': _u16(rec0, 0),
      'textLength': _i32(rec0, 4),
      'textRecordCount': _u16(rec0, 8),
      'encryptionType': _u16(rec0, 12),
    };
    if (_ascii(rec0, 16, 4) == 'MOBI') {
      final hlen = _i32(rec0, 20);
      out['mobiHeaderLen'] = hlen;
      out['mobiType'] = _i32(rec0, 24);
      out['textEncoding'] = _i32(rec0, 28);
      out['mobiVersion'] = _i32(rec0, 36);
      out['firstNonBookIndex'] = _i32(rec0, 80);
      out['firstImageIndex'] = _i32(rec0, 108);
      out['huffRecordOffset'] = _i32(rec0, 112);
      out['huffRecordCount'] = _i32(rec0, 116);
      out['exthFlags'] = _i32(rec0, 128);
      // 真实位置：MOBI 头相对 0xE0 → record 0 绝对 0xF2（u16 大端）
      out['traildataFlags@0xF2'] = _u16(rec0, 0xF2);
      out['INDXoffset@0xE4'] = _i32(rec0, 0xE4);

      final exthOff = 16 + hlen;
      if (exthOff + 12 <= rec0.length && _ascii(rec0, exthOff, 4) == 'EXTH') {
        final cnt = _i32(rec0, exthOff + 8);
        var p = exthOff + 12;
        final exth = <int, List<Uint8List>>{};
        for (var i = 0; i < cnt && p + 8 <= rec0.length; i++) {
          final t = _i32(rec0, p);
          final l = _i32(rec0, p + 4);
          if (l < 8 || p + l > rec0.length) break;
          exth
              .putIfAbsent(t, () => [])
              .add(Uint8List.sublistView(rec0, p + 8, p + l));
          p += l;
        }
        out['exthCount'] = cnt;
        for (final t in [100, 201, 503, 121, 125, 131, 129, 106]) {
          final v = exth[t];
          if (v == null) continue;
          final d = v.first;
          if (t == 121 || t == 201 || t == 125 || t == 131) {
            out['EXTH$t'] = d.length >= 4 ? _i32(d, 0) : d[0];
          } else {
            out['EXTH$t'] = String.fromCharCodes(d.where((c) => c != 0)).trim();
          }
        }
        // 边界记录：EXTH 121 指向的记录首 4 字节是否为 "BOUNDARY"
        final b = exth[121];
        if (b != null && b.isNotEmpty && b.first.length >= 4) {
          final bnum = _i32(b.first, 0);
          if (bnum > 0 && bnum < n) {
            final bo = off(bnum);
            out['boundaryRecord$bnum'] = bo + 16 <= bytes.length
                ? _ascii(bytes, bo, 8)
                : 'oob';
          }
        }
      }
    }
    return out;
  } catch (e) {
    return {'error': '$e'};
  }
}

/// 找 KF8 头（record 0 里 `\xeaDRMION\xee` 之类不做；这里找 BOUNDARY/KF8 标识）
String? findBoundary(Uint8List bytes) {
  final needle = 'BOUNDARY'.codeUnits;
  for (var i = 0; i + needle.length <= bytes.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return '在文件偏移 $i 找到 BOUNDARY 标记';
  }
  return null;
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tool/mobi_real_probe.dart <book>');
    exit(2);
  }
  final path = args[0];
  final bytes = File(path).readAsBytesSync();
  final ext = path.split('.').last.toLowerCase();
  final format = bookFormatOf(ext);

  print('===== MOBI/AZW3 真实样本探针 =====');
  print('样本: $path (${bytes.length} 字节, 扩展名 .$ext)');
  print('BookFormat 判定: ${format.name} (label=${format.label})');
  print('原始头部: ${rawHeader(bytes)}');
  final boundary = findBoundary(bytes);
  print('BOUNDARY 标记: ${boundary ?? "未找到（纯 KF8 无边界记录）"}');

  final r = parseMobiBook(bytes, format: format);
  print('');
  print('--- parseMobiBook ---');
  print('ok=${r.ok} error=${r.error} kind=${r.errorKind?.name}');
  print('title=${r.content.title}');
  print('author=${r.content.author}');
  print(
    'chapters=${r.content.chapters.length} toc=${r.content.toc.length} '
    'anchors=${r.content.anchors.length} resources=${r.content.resources.length}',
  );

  for (var i = 0; i < r.content.chapters.length && i < 3; i++) {
    final c = r.content.chapters[i];
    final text = stripTags(c.html);
    print(
      '  第 ${i + 1} 章 title="${c.title}" 开头80字: '
      '${text.length > 80 ? text.substring(0, 80) : text}',
    );
  }
  if (r.content.chapters.isEmpty) {
    print('  （没有章节 —— 解析未产出正文）');
  }

  // 正文完整性：尾部 extra data 没剥 / 剥错时，正文每 ~4KB 会混进乱码
  final all = r.content.chapters.map((c) => c.html).join('\n');
  final fffd = '\uFFFD'.allMatches(all).length;
  final controls = all.runes.where((c) => c < 9 || (c > 13 && c < 32)).length;
  print(
    '正文完整性: 替换字符 U+FFFD=$fffd, C0 控制字符=$controls'
    '${(fffd == 0 && controls == 0) ? "（干净）" : "（有垃圾字节！）"}',
  );

  final cover = mobiCoverBytes(bytes);
  if (cover == null) {
    print('封面: null（未取到）');
  } else {
    print('封面: ${cover.length} 字节, 类型=${imageKind(cover)}');
  }
}
