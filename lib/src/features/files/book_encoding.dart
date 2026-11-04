// 纯文本电子书（TXT / TCR / PalmDOC）的**编码探测与解码** —— 纯 Dart，
// 不 import flutter / l10n（`dart run tool/*.dart` 必须能编译）。
//
// 为什么需要它：`.txt` 里最常见的中文编码不是 UTF-8 —— 老书是 **GBK/GB2312**，
// 少数是 **GB18030**，繁体书是 **Big5**，Windows 记事本存的又是 **UTF-16**。
// 直接 `utf8.decode(allowMalformed: true)` 会把整本书变成 `���`。
//
// 设计原则是**保守**：只有"能确定"时才选非 UTF-8 编码，判不出来一律回落
// UTF-8 容错解码（宁可留几个 `�`，也不要拿错误编码把整本书解成乱码）。
//
// 探测顺序：
//   1. BOM（UTF-8 / UTF-16 LE / UTF-16 BE）—— 一锤定音；
//   2. 无 BOM 的 UTF-16：按"隔字节大量 0x00"的分布猜 LE/BE；
//   3. 严格 UTF-8 解码成功 → UTF-8（含纯 ASCII，这是绝大多数情况）；
//   4. GB18030 / Big5 严格解码，两个都成功时按**中文常用度打分**选高的；
//   5. 都不行 → UTF-8 容错解码（把坏字节变成 `�`，至少正文还在）。
//
// 解码表在 `book_charset_table.dart`（由标准映射导出，见该文件头）。
import 'dart:convert';
import 'dart:typed_data';

import 'book_charset_table.dart';

/// 探测到的编码名（只用于日志/探针，界面不显示）
enum BookTextEncoding {
  utf8('utf-8'),
  utf16le('utf-16le'),
  utf16be('utf-16be'),
  gb18030('gb18030'),
  big5('big5'),

  /// 认不出来 → UTF-8 容错解码
  utf8Lossy('utf-8(lossy)');

  const BookTextEncoding(this.label);
  final String label;
}

/// 探测 + 解码的结果
class BookDecodedText {
  const BookDecodedText(this.text, this.encoding);

  final String text;
  final BookTextEncoding encoding;
}

/// 主入口：把一段纯文本字节解成 String（**不抛异常**）。
BookDecodedText detectAndDecodeBookText(List<int> bytes) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

  // 1. BOM
  if (data.length >= 3 &&
      data[0] == 0xEF &&
      data[1] == 0xBB &&
      data[2] == 0xBF) {
    return BookDecodedText(
      utf8.decode(Uint8List.sublistView(data, 3), allowMalformed: true),
      BookTextEncoding.utf8,
    );
  }
  if (data.length >= 2 && data[0] == 0xFF && data[1] == 0xFE) {
    return BookDecodedText(
      _decodeUtf16(Uint8List.sublistView(data, 2), littleEndian: true),
      BookTextEncoding.utf16le,
    );
  }
  if (data.length >= 2 && data[0] == 0xFE && data[1] == 0xFF) {
    return BookDecodedText(
      _decodeUtf16(Uint8List.sublistView(data, 2), littleEndian: false),
      BookTextEncoding.utf16be,
    );
  }

  // 2. 无 BOM 的 UTF-16：偶数位大量 0x00 → BE，奇数位大量 0x00 → LE
  final bomless = _guessBomlessUtf16(data);
  if (bomless != null) return bomless;

  // 3. 严格 UTF-8
  try {
    return BookDecodedText(
      const Utf8Decoder(allowMalformed: false).convert(data),
      BookTextEncoding.utf8,
    );
  } on FormatException {
    // 落到多字节中文编码
  }

  // 3.5 无 BOM 的 UTF-16 **汉字正文**：这类字节流一个 0x00 都没有，上面的
  // "隔字节 0x00" 判据完全失效；而它又**常常能**被 GB18030 严格解出来（解成
  // 生僻字/扩展区），于是整本书变乱码。见 [_guessBomlessUtf16Cjk]。
  final cjk16 = _guessBomlessUtf16Cjk(data);
  if (cjk16 != null) return cjk16;

  // 4. GB18030 / Big5
  final gb = decodeGb18030(data, strict: true);
  final b5 = decodeBig5(data, strict: true);
  final gbScore = gb == null ? null : _cjkScore(gb);
  final b5Score = b5 == null ? null : _cjkScore(b5);
  if (gb != null && b5 != null) {
    // 两种都"合法"时，谁更像中文正文用谁；分数相同优先 GB18030（覆盖面更大）
    return b5Score! > gbScore!
        ? BookDecodedText(b5, BookTextEncoding.big5)
        : BookDecodedText(gb, BookTextEncoding.gb18030);
  }
  if (gb != null) return BookDecodedText(gb, BookTextEncoding.gb18030);
  if (b5 != null) return BookDecodedText(b5, BookTextEncoding.big5);

  // 5. 兜底
  return BookDecodedText(
    utf8.decode(data, allowMalformed: true),
    BookTextEncoding.utf8Lossy,
  );
}

/// 只解码，不带探测结论（给已有明确编码的场景）
String decodeBookText(List<int> bytes) => detectAndDecodeBookText(bytes).text;

// ------------------------------------------------------------------ UTF-16

BookDecodedText? _guessBomlessUtf16(Uint8List data) {
  if (data.length < 8 || data.length.isOdd) return null;
  var evenZeros = 0;
  var oddZeros = 0;
  final n = data.length ~/ 2;
  for (var i = 0; i < data.length; i += 2) {
    if (data[i] == 0) evenZeros++;
    if (data[i + 1] == 0) oddZeros++;
  }
  // 拉丁/中文的 UTF-16 里，高位字节对 ASCII 是 0，对 CJK 不是；真实样本里
  // 总有一侧明显偏高。阈值取 30%，比任何"猜编码"都保守。
  if (evenZeros > n * 0.3 && oddZeros < n * 0.05) {
    return BookDecodedText(
      _decodeUtf16(data, littleEndian: false),
      BookTextEncoding.utf16be,
    );
  }
  if (oddZeros > n * 0.3 && evenZeros < n * 0.05) {
    return BookDecodedText(
      _decodeUtf16(data, littleEndian: true),
      BookTextEncoding.utf16le,
    );
  }
  return null;
}

/// UTF-16 里"高位字节合法集"：ASCII 的高字节是 0x00；常用汉字（U+4E00–U+9FFF）
/// 的高字节是 0x4E–0x9F；中日韩标点/假名（U+3000–U+33FF）是 0x30–0x33；全角
/// 形式（U+FF00–U+FFEF）是 0xFF。
bool _isUtf16HighByte(int b) =>
    b == 0x00 || (b >= 0x30 && b <= 0x33) || (b >= 0x4E && b <= 0x9F) || b == 0xFF;

/// 无 BOM 的 UTF-16 **汉字正文**探测（没有 0x00 可依赖时的兜底）。
///
/// 为什么需要单独一条：全是汉字的 UTF-16 里高位字节是 0x4E–0x9F、低字节铺满
/// 0x00–0xFF，**一个 0x00 都没有**，[_guessBomlessUtf16] 因此完全不触发；而这段
/// 字节流又常常能通过 GB18030 的严格解码（把每两字节读成一个生僻字/扩展区字），
/// 于是整本书被解成乱码。改动前的真实行为：UTF-16LE 的「中文测试正文内容」被
/// 判成 GB18030，产出 `-N噀Km諎ck噀匭筟`。
///
/// 判据（**只认强信号**，任一不满足就返回 null 交给 GB18030/Big5）：
///   * 每两个字节看一组，**某一奇偶位置**的字节 ≥90% 落在高位合法集里 ——
///     真实 UTF-16 的"高位字节"那一侧几乎必然如此；
///   * **另一奇偶位置** ≤60% 落在该集合里（低字节是铺开的）—— 两侧都"像高位"
///     说明这不是 UTF-16，宁可退给 GB18030；
///   * 只有一侧成立才采用，两侧都成立视为歧义、放弃。
///
/// GBK/Big5 的实际字节（首字节 0x81–0xFE / 尾字节 0x40–0xFE）在任一奇偶位置
/// 都远远达不到 90%，所以这条判据不会把既有 GBK/Big5 书抢走（回归由
/// `test/file_book_text_test.dart` 的 GBK/Big5/乱码样本钉住）。
BookDecodedText? _guessBomlessUtf16Cjk(Uint8List data) {
  if (data.length < 8 || data.length.isOdd) return null;
  var evenHigh = 0;
  var oddHigh = 0;
  final n = data.length ~/ 2;
  for (var i = 0; i < data.length; i += 2) {
    if (_isUtf16HighByte(data[i])) evenHigh++;
    if (_isUtf16HighByte(data[i + 1])) oddHigh++;
  }
  final evenRatio = evenHigh / n;
  final oddRatio = oddHigh / n;
  final be = evenRatio >= 0.90 && oddRatio <= 0.60;
  final le = oddRatio >= 0.90 && evenRatio <= 0.60;
  if (be == le) return null; // 两侧都像 / 都不像 → 不下结论
  return le
      ? BookDecodedText(
          _decodeUtf16(data, littleEndian: true),
          BookTextEncoding.utf16le,
        )
      : BookDecodedText(
          _decodeUtf16(data, littleEndian: false),
          BookTextEncoding.utf16be,
        );
}

String _decodeUtf16(Uint8List data, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = 0; i + 1 < data.length; i += 2) {
    units.add(
      littleEndian
          ? data[i] | (data[i + 1] << 8)
          : (data[i] << 8) | data[i + 1],
    );
  }
  return String.fromCharCodes(units);
}

// ------------------------------------------------------------------ GB18030

/// GB18030（含 GBK / GB2312）解码。
///
/// [strict] = true 时遇到不认识的字节序列返回 null（探测用）；
/// false 时输出 U+FFFD（解码用，但本文件的探测路径一律先用 strict 试）。
String? decodeGb18030(List<int> bytes, {required bool strict}) {
  final out = StringBuffer();
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    if (b < 0x80) {
      out.writeCharCode(b);
      i++;
      continue;
    }
    // 0x80 在 GBK 里是欧元符（不是合法双字节首字节）
    if (b == 0x80) {
      out.writeCharCode(0x20AC);
      i++;
      continue;
    }
    if (b == 0xFF || i + 1 >= bytes.length) {
      if (strict) return null;
      out.writeCharCode(0xFFFD);
      i++;
      continue;
    }
    final t = bytes[i + 1];
    if (t >= 0x30 && t <= 0x39) {
      // 四字节：GB18030 的扩展区
      if (i + 3 >= bytes.length) {
        if (strict) return null;
        out.writeCharCode(0xFFFD);
        i++;
        continue;
      }
      final b3 = bytes[i + 2];
      final b4 = bytes[i + 3];
      if (b3 < 0x81 || b3 > 0xFE || b4 < 0x30 || b4 > 0x39) {
        if (strict) return null;
        out.writeCharCode(0xFFFD);
        i++;
        continue;
      }
      final idx =
          ((b - 0x81) * 10 + (t - 0x30)) * 1260 +
          (b3 - 0x81) * 10 +
          (b4 - 0x30);
      final cp = _gbFourByteLookup(idx);
      if (cp == null) {
        if (strict) return null;
        out.writeCharCode(0xFFFD);
      } else {
        out.writeCharCode(cp);
      }
      i += 4;
      continue;
    }
    if (_gbTrail(t)) {
      final cp = _gbTwoByteLookup(b, t);
      if (cp == null) {
        if (strict) return null;
        out.writeCharCode(0xFFFD);
      } else {
        out.writeCharCode(cp);
      }
      i += 2;
      continue;
    }
    if (strict) return null;
    out.writeCharCode(0xFFFD);
    i++;
  }
  return out.toString();
}

bool _gbTrail(int t) => (t >= 0x40 && t <= 0x7E) || (t >= 0x80 && t <= 0xFE);

int _trailIndex(int trail) => trail <= 0x7E ? trail - 0x40 : trail - 0x80 + 63;

int? _gbTwoByteLookup(int lead, int trail) {
  if (lead < 0x81 || lead > 0xFE) return null;
  final idx = (lead - 0x81) * 190 + _trailIndex(trail);
  if (idx < 0 || idx >= kGbkTwoByteTable.length) return null;
  final cp = kGbkTwoByteTable.codeUnitAt(idx);
  return cp == 0xFFFD ? null : cp;
}

/// 四字节区间表里查（区间表见 `book_charset_table.dart`）
int? _gbFourByteLookup(int idx) {
  var lo = 0;
  var hi = kGbkFourByteRanges.length ~/ 4 - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final a = kGbkFourByteRanges[mid * 4];
    final b = kGbkFourByteRanges[mid * 4 + 1];
    if (idx < a) {
      hi = mid - 1;
    } else if (idx > b) {
      lo = mid + 1;
    } else {
      return kGbkFourByteRanges[mid * 4 + 2] + (idx - a);
    }
  }
  return null;
}

// ------------------------------------------------------------------ Big5

/// Big5（繁体中文）解码；语义同 [decodeGb18030]。
String? decodeBig5(List<int> bytes, {required bool strict}) {
  final out = StringBuffer();
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i];
    if (b < 0x80) {
      out.writeCharCode(b);
      i++;
      continue;
    }
    if (i + 1 >= bytes.length) {
      if (strict) return null;
      out.writeCharCode(0xFFFD);
      i++;
      continue;
    }
    final t = bytes[i + 1];
    final ok = (t >= 0x40 && t <= 0x7E) || (t >= 0xA1 && t <= 0xFE);
    if (!ok) {
      if (strict) return null;
      out.writeCharCode(0xFFFD);
      i++;
      continue;
    }
    final idx = (b - 0x81) * 190 + _trailIndex(t);
    final cp = idx >= 0 && idx < kBig5TwoByteTable.length
        ? kBig5TwoByteTable.codeUnitAt(idx)
        : 0xFFFD;
    if (cp == 0xFFFD) {
      if (strict) return null;
      out.writeCharCode(0xFFFD);
    } else {
      out.writeCharCode(cp);
    }
    i += 2;
  }
  return out.toString();
}

// ------------------------------------------------------------------ 打分

/// 粗略判断"这段解码结果像不像中文正文"。
///
/// 为什么用打分而不是"先试哪个"：GB18030 与 Big5 的字节范围高度重叠，
/// Big5 字节串常常也能被 GB18030 严格解出来（只是解成生僻字/扩展区字），
/// 光看"能不能解"会选错。这里对常用汉字加分，对扩展区生僻字与控制符扣分。
int _cjkScore(String s) {
  var score = 0;
  for (final r in s.runes) {
    if (r >= 0x4E00 && r <= 0x9FFF) {
      score += 2; // 常用汉字区（GB2312/Big5 的正文几乎都落在这里）
    } else if (r >= 0x3400 && r <= 0x4DBF) {
      score -= 2; // 扩展 A：解码错了才会大量出现
    } else if (r >= 0x20000) {
      score -= 3; // 扩展 B 及以上：基本可以断定选错编码
    } else if (r >= 0xE000 && r <= 0xF8FF) {
      score -= 3; // 私有区
    } else if (r == 0xFFFD) {
      score -= 5;
    } else if (r < 0x20 && r != 0x09 && r != 0x0A && r != 0x0D) {
      score -= 4; // 控制符
    } else if (r >= 0x80 && r <= 0x9F) {
      score -= 2; // C1 控制符
    } else if (r >= 0xFF00 && r <= 0xFFEF) {
      score += 1; // 全角标点，中文正文常见
    }
  }
  return score;
}
