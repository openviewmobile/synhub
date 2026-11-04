// DJVU（.djvu）**容器层**：IFF/FORM 分块容器 + INFO + 文本层（TXTz/TXTa）+
// 注释（ANTz/ANTa）+ 书签（NAVM）+ 多页目录（DJVM 的 DIRM/INCL）—— 纯 Dart，
// 零 flutter / l10n 依赖。
//
// 为什么要自研：DjVuLibre 是 **GPL-2.0**（对闭源 App 是法务阻塞），pub.dev 上
// 也没有任何 Dart 实现的 DjVu 解码器。用户硬要求"所有电子书格式都要支持，
// 协议/许可证问题就自研"。所以这里按**公开的 DjVu3 格式规范**（AT&T/LizardTech
// 发布）从零实现容器与文本层；位图/小波解码在 `djvu_jb2.dart` / `djvu_iw44.dart`，
// 算术编码在 `djvu_zp.dart`，BZZ 在 `djvu_bzz.dart`。
//
// **参考与许可**：格式事实来自公开的 DjVu3 规范与 DjVuLibre 的 `IFFByteStream` /
// `DjVuInfo` / `DjVuText` / `DjVmDir` / `DjVmNav`（GPL-2.0，**仅作算法事实参考**）。
// 本文件是**独立重写的 Dart 实现**，没有引入上述工程的任何代码、头文件或依赖。
//
// **能力边界**（宁可给明确错误，也不吐乱码或半截）：
//
//   | 维度 | 支持 | 明确报错 |
//   |---|---|---|
//   | FORM | DJVU（单页）/ DJVM（多页，bundled）/ THUM（缩略图）/ DJVI | 其它 → 坏文件 |
//   | 分块 | 4 字节 ID + 大端长度 + 2 字节对齐；复合块带二级 ID | 越界/截断 → 坏文件 |
//   | 多页 | bundled（DIRM 里 offset/size 直取页字节） | **散装（indirect）** DJVM → 不支持 |
//   | INFO | 宽高/版本/DPI/gamma/方向 | 版本 ≥ 50 → 不支持 |
//   | 文本层 | TXTa（原样）/ TXTz（BZZ 解压），UTF-8 + VT/GS/US/LF 段落符 | —— |
//   | 书签 | NAVM（BZZ + 前序树）→ [DjvuBookmark] | 解析不了就退化为页码列表 |
//   | 注释 | ANTa / ANTz 原文（不解 XMP/文本注释语义） | —— |
//   | 掩码 | Sjbz（JB2）/ Djbz（字典） | Smmr(G4) → 不支持 |
//   | 背景/前景 | BG44 / FG44（IW44） | BGjp/FGjp/BG2k/FG2k → 不支持 |
//   | 加密 | —— | CELX / SINF → 不支持（secured djvu） |
//
// 所有"能力边界"抛 [DjvuUnsupportedException]，文件损坏/截断抛
// [DjvuFormatException]，由 `book_djvu.dart` 翻译成界面的"这本书打不开"。
import 'dart:convert';
import 'dart:typed_data';

import 'djvu_bzz.dart';
import '../../core/i18n/data_text.dart';
import 'djvu_errors.dart';

export 'djvu_errors.dart';

/// 单页最大解压上限（BZZ 解出文本层/目录时的保险）
const int _kMaxDecompressed = 64 * 1024 * 1024;

/// 一个 IFF 分块（数据区间是**绝对文件偏移**）。
class DjvuChunk {
  const DjvuChunk({
    required this.id,
    required this.offset,
    required this.length,
    required this.optional,
  });

  /// 4 字节 ID；复合块是 `FORM:XXXX` 形式。
  final String id;

  /// 数据起始（绝对偏移）
  final int offset;

  /// 数据长度
  final int length;

  /// 规范里"可选块"：ID 首字节是**小写字母**（`(b & 0x20) != 0`）。
  ///
  /// 注意：解码策略上我们**对齐 DjVuLibre 的宽松做法** —— 不认识的块一律跳过
  /// （不因为一个可选/未知块把整本书判死），只有"认识但做不到"的变体才报
  /// [DjvuUnsupportedException]。这个标志仍按规范如实记录。
  final bool optional;

  bool get isForm => id.startsWith('FORM:');
  String get formType => isForm ? id.substring(5) : '';

  @override
  String toString() => 'DjvuChunk($id, $offset+$length)';
}

/// 一个 FORM 容器及其顶层分块。
class DjvuForm {
  DjvuForm({
    required this.type,
    required this.chunks,
    required this.dataStart,
    required this.dataEnd,
  });

  final String type;
  final List<DjvuChunk> chunks;
  final int dataStart;
  final int dataEnd;

  DjvuChunk? find(String id) {
    for (final c in chunks) {
      if (c.id == id) return c;
    }
    return null;
  }

  List<DjvuChunk> all(String id) => [
    for (final c in chunks)
      if (c.id == id) c,
  ];
}

/// INFO 块的字段。
class DjvuInfo {
  const DjvuInfo({
    required this.width,
    required this.height,
    required this.version,
    required this.dpi,
    required this.gamma,
    required this.orientation,
  });

  final int width;
  final int height;
  final int version;
  final int dpi;
  final double gamma;

  /// 0 = 不旋转，1/2/3 = 逆时针 90/180/270 度
  final int orientation;

  /// 版本上限（DjVuLibre 的 `DJVUVERSION_TOO_NEW`）
  static const int maxVersion = 50;
}

/// 一个书签（NAVM 条目）。
class DjvuBookmark {
  const DjvuBookmark({
    required this.title,
    required this.url,
    required this.depth,
  });
  final String title;
  final String url;
  final int depth;
}

/// 多页文档目录（DIRM）里的一个成员文件。
class DjvuDirFile {
  const DjvuDirFile({
    required this.id,
    required this.name,
    required this.title,
    required this.offset,
    required this.size,
    required this.flags,
  });

  final String id;
  final String name;
  final String title;
  final int offset;
  final int size;
  final int flags;

  int get fileType => flags & 0x3f;
  bool get isPage => fileType == 1;
  bool get isThumbnails => fileType == 2;
  bool get isSharedAnno => fileType == 3;
}

/// 单页（FORM:DJVU）解出来的所有分块内容。
class DjvuPage {
  DjvuPage({
    required this.formType,
    required this.info,
    required this.title,
    required this.sjbz,
    required this.djbz,
    required this.bg44,
    required this.fg44,
    required this.th44,
    required this.text,
    required this.annotations,
    required this.unsupported,
    required this.unknownChunks,
    this.includes = const [],
  });

  final String formType;
  final DjvuInfo? info;

  /// 页标题（来自 DIRM 的 title/name；单页文件为空）
  final String title;

  /// JB2 前景掩码
  final Uint8List? sjbz;

  /// 页内 JB2 字典
  final Uint8List? djbz;

  /// 背景小波（可多块，渐进细化）
  final List<Uint8List> bg44;

  /// 前景小波
  final List<Uint8List> fg44;

  /// 缩略图小波
  final List<Uint8List> th44;

  /// 文本层原文（已按 VT/GS/US/LF 归一化换行）
  final String text;

  /// 注释原文（ANTa/ANTz 解出来的字节）
  final List<Uint8List> annotations;

  /// "认识但做不到"的分块 id（Smmr/BGjp/…）——只有真的要渲染时才报错
  final List<String> unsupported;

  /// 不认识的块 id（宽松跳过）
  final List<String> unknownChunks;

  /// 本页 `INCL` 引用的其它成员文件（通常是装着共享 `Djbz` 字典的 DJVI）。
  ///
  /// 多页 DJVU 的常见布局：每页的 `INCL` 指向同一个字典成员，页面自己的
  /// `Sjbz` 只写"我要用字典里的第 N 个符号"。解析时已把该成员的 `Djbz`
  /// 合并进 [djbz]（见 `_resolveIncludeDictionary`），这里保留原始名字供
  /// 探针/测试观察。
  final List<String> includes;

  bool get hasBitmap =>
      sjbz != null || bg44.isNotEmpty || fg44.isNotEmpty || th44.isNotEmpty;
}

/// 打开后的 DJVU 文档。
class DjvuArchive {
  DjvuArchive._({
    required this.bytes,
    required this.formType,
    required this.pages,
    required this.bookmarks,
    required this.directory,
    required this.thumbnail,
    required this.unsupported,
  });

  final Uint8List bytes;

  /// 顶层 FORM 类型：DJVU / DJVM / DJVI
  final String formType;

  /// 页面（DJVU 单页 = 1 个；DJVM = DIRM 里的 PAGE 顺序）
  final List<DjvuPage> pages;

  /// NAVM 书签（文档级；单页文件为空）
  final List<DjvuBookmark> bookmarks;

  /// DIRM 成员表（仅有 DJVM 时非空）
  final List<DjvuDirFile> directory;

  /// THUM 表单里的 TH44 缩略图原始块（可能多个，渐进）
  final List<Uint8List> thumbnail;

  /// 文档级"认识但做不到"的标记
  final List<String> unsupported;

  bool get isMultiPage => formType == 'DJVM';

  /// 是否是 DJVU 文件（容忍 `AT&T` 与 `SDJV` 前置魔数）
  static bool isDjvu(List<int> bytes) {
    if (bytes.length < 4) return false;
    int at(int i) => bytes[i];
    if (at(0) == 0x41 && at(1) == 0x54 && at(2) == 0x26 && at(3) == 0x54) {
      // "AT&T" 之后必须是 FORM（也可能隔一个 SDJV）
      return bytes.length >= 8 &&
          at(4) == 0x46 &&
          at(5) == 0x4F &&
          at(6) == 0x52 &&
          at(7) == 0x4D;
    }
    return at(0) == 0x46 && at(1) == 0x4F && at(2) == 0x52 && at(3) == 0x4D;
  }

  static DjvuArchive open(List<int> bytes) {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (data.length < 16) {
      throw DjvuFormatException('文件太小，不像 DJVU（连 FORM 头都不够）');
    }
    if (!isDjvu(data)) {
      throw DjvuFormatException('不是 DJVU 文件（找不到 FORM 签名）');
    }
    final form = _readForm(data, 0, data.length);
    if (form == null) throw DjvuFormatException('DJVU 顶层 FORM 头不完整');

    switch (form.type) {
      case 'DJVU':
      case 'DJVI':
        final page = _readPage(data, form, title: '');
        return DjvuArchive._(
          bytes: data,
          formType: form.type,
          pages: [page],
          bookmarks: const [],
          directory: const [],
          thumbnail: const [],
          unsupported: const [],
        );
      case 'DJVM':
        return _readDjvm(data, form);
      // 独立的缩略图 / IW44 图像表单：当成"只有一张背景图"的单页
      case 'THUM':
      case 'BM44':
      case 'PM44':
        final page = _readPage(data, form, title: '');
        return DjvuArchive._(
          bytes: data,
          formType: form.type,
          pages: [page],
          bookmarks: const [],
          directory: const [],
          thumbnail: page.th44,
          unsupported: const [],
        );
      default:
        throw DjvuFormatException('顶层 FORM 类型 "${form.type}" 不认识');
    }
  }

  // ------------------------------------------------------------ DJVM

  static DjvuArchive _readDjvm(Uint8List data, DjvuForm form) {
    final dirmChunk = form.find('DIRM');
    if (dirmChunk == null) {
      // 老式/散装 DJVM：没有 DIRM 时退化成"把内嵌的 DJVU 表单按顺序当页"
      final pages = <DjvuPage>[];
      for (final c in form.chunks) {
        if (!c.isForm) continue;
        final sub = _readForm(
          data,
          c.offset - (c.isForm ? 12 : 8),
          data.length,
        );
        if (sub == null) continue;
        if (sub.type == 'DJVU' || sub.type == 'DJVI') {
          pages.add(
            _readPage(data, sub, title: _bookPageTitle(pages.length + 1)),
          );
        }
      }
      if (pages.isEmpty) {
        throw DjvuFormatException('DJVM 里没有 DIRM，也没有内嵌的 DJVU 页');
      }
      return DjvuArchive._(
        bytes: data,
        formType: form.type,
        pages: pages,
        bookmarks: const [],
        directory: const [],
        thumbnail: const [],
        unsupported: const [],
      );
    }

    final dir = _readDirm(data, dirmChunk);
    final bundled = dir.bundled;
    if (!bundled) {
      throw DjvuUnsupportedException(
        '散装（indirect）DJVU：页在其它文件里（index 的 INCL 指向外部），'
        '当前只拿到这一个文件 → 缺少分页文件，无法读取',
      );
    }

    // 文档级书签
    var bookmarks = const <DjvuBookmark>[];
    final navm = form.find('NAVM');
    if (navm != null) {
      try {
        bookmarks = _readNavm(data, navm);
      } catch (_) {
        // 书签坏了不该毁掉整本书：退化为页码列表
        bookmarks = const [];
      }
    }

    // 缩略图表单（THUM）
    final thumbs = <Uint8List>[];
    for (final c in form.chunks) {
      if (!c.isForm || c.formType != 'THUM') continue;
      final sub = _readForm(data, c.offset - 12, data.length);
      if (sub == null) continue;
      for (final t in sub.all('TH44')) {
        thumbs.add(_slice(data, t));
      }
    }

    // 按 DIRM 顺序取每个 PAGE 成员的字节，再当单页 DJVU 解
    //
    // 先把**所有**成员（页 + DJVI/共享字典）按 id / name 建索引：多页文档的
    // 共享 `Djbz` 单独存在一个 `FORM:DJVI` 成员里，页面用 `INCL` 引用它。
    final components = <String, Uint8List>{};
    for (final f in dir.files) {
      final from = f.offset;
      final to = from + f.size;
      if (from < 0 || f.size <= 0 || to > data.length) continue;
      final sub = Uint8List.sublistView(data, from, to);
      if (f.id.isNotEmpty) components[f.id] = sub;
      if (f.name.isNotEmpty) components[f.name] = sub;
      final base = f.name.isNotEmpty ? f.name : f.id;
      final slash = base.lastIndexOf('/');
      if (slash >= 0) components[base.substring(slash + 1)] = sub;
    }

    final pages = <DjvuPage>[];
    final unsupported = <String>[];
    for (final f in dir.files) {
      if (!f.isPage) continue;
      final from = f.offset;
      final to = from + f.size;
      if (from < 0 || f.size <= 0 || to > data.length) {
        throw DjvuFormatException('DIRM 里 "${f.id}" 的区间越界');
      }
      final sub = Uint8List.sublistView(data, from, to);
      final pageForm = _readForm(sub, 0, sub.length);
      if (pageForm == null) {
        throw DjvuFormatException('DIRM 里 "${f.id}" 不是一个完整的 DJVU 表单');
      }
      if (pageForm.type != 'DJVU' && pageForm.type != 'DJVI') {
        unsupported.add('成员 ${f.id} 的 FORM:${pageForm.type}');
        continue;
      }
      pages.add(
        _readPage(
          sub,
          pageForm,
          title: f.title.isNotEmpty ? f.title : f.name,
          components: components,
        ),
      );
    }
    if (pages.isEmpty) {
      throw DjvuFormatException('DJVM 的 DIRM 里没有任何可读的页');
    }
    return DjvuArchive._(
      bytes: data,
      formType: form.type,
      pages: pages,
      bookmarks: bookmarks,
      directory: dir.files,
      thumbnail: thumbs,
      unsupported: unsupported,
    );
  }

  // ------------------------------------------------------------ 单页

  static DjvuPage _readPage(
    Uint8List data,
    DjvuForm form, {
    required String title,
    Map<String, Uint8List>? components,
  }) {
    DjvuInfo? info;
    Uint8List? sjbz;
    Uint8List? djbz;
    final bg44 = <Uint8List>[];
    final fg44 = <Uint8List>[];
    final th44 = <Uint8List>[];
    final annotations = <Uint8List>[];
    final unsupported = <String>[];
    final unknown = <String>[];
    final txts = <Uint8List>[];
    final includes = <String>[];

    for (final c in form.chunks) {
      switch (c.id) {
        case 'INFO':
          info = _readInfo(_slice(data, c));
        case 'Sjbz':
          sjbz = _slice(data, c);
        case 'Djbz':
          djbz = _slice(data, c);
        case 'BG44':
          bg44.add(_slice(data, c));
        case 'FG44':
          fg44.add(_slice(data, c));
        case 'TH44':
        case 'BM44':
        case 'PM44':
          th44.add(_slice(data, c));
        case 'TXTz':
        case 'TXTa':
          txts.add(_decodeTxtChunk(data, c));
        case 'ANTz':
        case 'ANTa':
          annotations.add(_decodeTxtChunk(data, c));
        case 'FGbz':
          // 调色板块：DjVuImage 的位图路径不消费它（直接读 FG44 颜色），
          // 只被 PostScript 导出用；这里对齐 `DjVuImage::get_pixmap` 忽略。
          break;
        case 'Smmr':
        case 'BGjp':
        case 'FGjp':
        case 'BG2k':
        case 'FG2k':
        case 'CELX':
        case 'SINF':
          unsupported.add(c.id);
        case 'INCL':
          // 多页文档里指向"装着共享 Djbz 的成员文件"
          final name = _normalizeInclName(_slice(data, c));
          if (name.isNotEmpty) includes.add(name);
        case 'NDIR':
        case 'METa':
        case 'METz':
        case 'LINK':
        case 'CIDa':
        case 'CINF':
        case 'FAKE':
        case 'FORM:ANNO':
          // 页面级不需要 / 另走别路（CIDa = 文本区信息，渲染不消费）
          break;
        default:
          if (!c.isForm) unknown.add(c.id);
      }
    }

    // INCL 指向的共享字典：页面自己没带 Djbz 时合并进来
    djbz ??= _resolveIncludeDictionary(
      data,
      includes,
      components,
      depth: 0,
      seen: <String>{},
    );

    // 多个 TXT 块（极少见）：按顺序拼接
    final textBuf = StringBuffer();
    for (final t in txts) {
      textBuf.write(djvuNormalizeHiddenText(t));
    }

    return DjvuPage(
      formType: form.type,
      info: info,
      title: title,
      sjbz: sjbz,
      djbz: djbz,
      bg44: bg44,
      fg44: fg44,
      th44: th44,
      text: textBuf.toString(),
      annotations: annotations,
      unsupported: unsupported,
      unknownChunks: unknown,
      includes: includes,
    );
  }
}

/// INCL 的名字：规范允许两端包着 `\n`，也可能写成 `./x.djvu` 或带路径。
String _normalizeInclName(Uint8List raw) {
  var s = String.fromCharCodes(raw.where((b) => b != 0));
  s = s.replaceAll('\r', '').replaceAll('\n', '').trim();
  s = s.replaceAll('\\', '/');
  while (s.startsWith('./')) {
    s = s.substring(2);
  }
  final slash = s.lastIndexOf('/');
  if (slash >= 0) s = s.substring(slash + 1);
  return s;
}

/// 顺着 `INCL` 找到共享 `Djbz` 字节。
///
/// 参考实现 `DjVuFile::process_incl_chunk` + `Djbz` 分支：被包含的成员是一份
/// `FORM:DJVI`，它的 `Djbz` 成为本页的符号字典。这里只在**同一个文件内**
/// （bundled DJVM）解析；找不到就返回 null，交给 JB2 层报明确错误。
Uint8List? _resolveIncludeDictionary(
  Uint8List data,
  List<String> includes,
  Map<String, Uint8List>? components, {
  required int depth,
  required Set<String> seen,
}) {
  if (components == null || includes.isEmpty || depth > 4) return null;
  for (final rawName in includes) {
    final name = _normalizeInclName(Uint8List.fromList(rawName.codeUnits));
    if (name.isEmpty || !seen.add(name)) continue;
    final sub = components[name] ?? components[name.toLowerCase()];
    if (sub == null) continue;
    final DjvuForm? form;
    try {
      form = _readForm(sub, 0, sub.length);
    } catch (_) {
      continue;
    }
    if (form == null) continue;
    final dict = form.find('Djbz');
    if (dict != null) return _slice(sub, dict);
    // 成员自己也可能 INCL 另一个成员（极少见）：继续追一层
    final nested = <String>[];
    for (final c in form.chunks) {
      if (c.id == 'INCL') {
        final n = _normalizeInclName(_slice(sub, c));
        if (n.isNotEmpty) nested.add(n);
      }
    }
    final deeper = _resolveIncludeDictionary(
      sub,
      nested,
      components,
      depth: depth + 1,
      seen: seen,
    );
    if (deeper != null) return deeper;
  }
  return null;
}

// ---------------------------------------------------------------- INFO

DjvuInfo _readInfo(Uint8List b) {
  if (b.length < 5) throw DjvuFormatException('INFO 块太短（不足 5 字节）');
  var width = (b[0] << 8) | b[1];
  var height = (b[2] << 8) | b[3];
  var version = b[4];
  if (b.length >= 6 && b[5] != 0xff) version = (b[5] << 8) | b[4];
  if (version >= DjvuInfo.maxVersion) {
    throw DjvuUnsupportedException(
      'DJVU 文件版本 $version 太新（本阅读器支持到 ${DjvuInfo.maxVersion - 1}）',
    );
  }
  var dpi = 300;
  if (b.length >= 8 && b[7] != 0xff) dpi = (b[7] << 8) | b[6];
  var gamma = 2.2;
  if (b.length >= 9) gamma = 0.1 * b[8];
  if (gamma < 0.3) gamma = 0.3;
  if (gamma > 5.0) gamma = 5.0;
  if (dpi < 25 || dpi > 6000) dpi = 300;
  var orientation = 0;
  if (b.length >= 10) {
    switch (b[9] & 0x7) {
      case 6:
        orientation = 1;
      case 2:
        orientation = 2;
      case 5:
        orientation = 3;
    }
  }
  if (width < 0 || height < 0) {
    throw DjvuFormatException('INFO 的宽高非法');
  }
  // width/height 是 u16，不会为负；仅保留规范性检查
  return DjvuInfo(
    width: width,
    height: height,
    version: version,
    dpi: dpi,
    gamma: gamma,
    orientation: orientation,
  );
}

// ---------------------------------------------------------------- 文本层

/// 解出 TXTz/TXTa 的**内部字节**（u24 长度 + UTF-8 文本 + 可选 zone 数据）。
///
/// * TXTa：原样；
/// * TXTz：先 BZZ 解压。
Uint8List _decodeTxtChunk(Uint8List data, DjvuChunk c) {
  final raw = _slice(data, c);
  if (c.id == 'TXTa' || c.id == 'ANTa') return raw;
  return djvuBzzDecode(raw, maxSize: _kMaxDecompressed);
}

/// 把 DjVu "隐藏文本层"的原始字节变成可读文本。
///
/// 结构是 `u24 长度` + UTF-8 文本（+ 可选 zone 记录）。文本里用控制符分段：
///   * `0x0A` LF  = 行尾
///   * `0x0B` VT  = 栏尾（column）
///   * `0x1D` GS  = 区域尾（region）
///   * `0x1F` US  = 段落尾（paragraph）
/// 这些控制符直接当换行；连续 3 个以上换行折叠成 2 个。
String djvuNormalizeHiddenText(Uint8List chunkBody) {
  if (chunkBody.length < 3) return '';
  final textSize = (chunkBody[0] << 16) | (chunkBody[1] << 8) | chunkBody[2];
  if (textSize < 0) return '';
  if (3 + textSize > chunkBody.length) {
    // 截断的文本层：只取实际有的部分（不抛，文本层缺失不影响图片阅读）
    final avail = chunkBody.length - 3;
    if (avail <= 0) return '';
    return _normalizeRawText(
      utf8.decode(Uint8List.sublistView(chunkBody, 3), allowMalformed: true),
    );
  }
  final raw = utf8.decode(
    Uint8List.sublistView(chunkBody, 3, 3 + textSize),
    allowMalformed: true,
  );
  return _normalizeRawText(raw);
}

String _normalizeRawText(String raw) {
  final buf = StringBuffer();
  for (final rune in raw.runes) {
    if (rune == 0x00) continue;
    if (rune == 0x0A || rune == 0x0B || rune == 0x1D || rune == 0x1F) {
      buf.write('\n');
    } else {
      buf.writeCharCode(rune);
    }
  }
  var s = buf.toString();
  // 折叠 >2 个换行，并去掉行首行尾空白
  s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  s = s.split('\n').map((l) => l.trim()).join('\n').trim();
  return s;
}

// ---------------------------------------------------------------- DIRM

class _DirmResult {
  _DirmResult({required this.bundled, required this.files});
  final bool bundled;
  final List<DjvuDirFile> files;
}

_DirmResult _readDirm(Uint8List data, DjvuChunk c) {
  final b = _slice(data, c);
  if (b.length < 3) throw DjvuFormatException('DIRM 块太短');
  var p = 0;
  final verByte = b[p++];
  final bundled = (verByte & 0x80) != 0;
  final ver = verByte & 0x7f;
  if (ver > 1) {
    throw DjvuUnsupportedException('DIRM 版本 $ver 未实现（只实现了 0/1）');
  }
  if (p + 2 > b.length) throw DjvuFormatException('DIRM 文件数越界');
  final files = (b[p] << 8) | b[p + 1];
  p += 2;

  final offsets = List<int>.filled(files, 0);
  final sizes = List<int>.filled(files, 0);

  for (var i = 0; i < files; i++) {
    if (bundled) {
      if (p + 4 > b.length) throw DjvuFormatException('DIRM offset 越界');
      offsets[i] = (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
      p += 4;
      if (ver == 0) {
        if (p + 3 > b.length) throw DjvuFormatException('DIRM size 越界');
        sizes[i] = (b[p] << 16) | (b[p + 1] << 8) | b[p + 2];
        p += 3;
      }
      if (offsets[i] == 0) {
        throw DjvuFormatException('DIRM 给了 offset=0（散装文档）');
      }
    }
  }

  // 余下的（size/flags/names）整体是 BZZ 流
  if (p > b.length) throw DjvuFormatException('DIRM 头越界');
  final body = Uint8List.sublistView(b, p);
  final Uint8List dec;
  try {
    dec = djvuBzzDecode(body, maxSize: _kMaxDecompressed);
  } on DjvuFormatException {
    throw DjvuFormatException('DIRM 的 BZZ 流解不开（文件可能损坏）');
  }

  var q = 0;
  int rd8() {
    if (q >= dec.length) throw DjvuFormatException('DIRM 解压数据不够');
    return dec[q++];
  }

  if (ver > 0) {
    for (var i = 0; i < files; i++) {
      sizes[i] = (rd8() << 16) | (rd8() << 8) | rd8();
    }
  }
  final flags = List<int>.filled(files, 0);
  for (var i = 0; i < files; i++) {
    flags[i] = rd8();
  }

  // 名字区：每个文件按顺序是 id\0 [name\0] [title\0]
  String readCStr() {
    final start = q;
    while (q < dec.length && dec[q] != 0) {
      q++;
    }
    final s = utf8.decode(
      Uint8List.sublistView(dec, start, q),
      allowMalformed: true,
    );
    if (q < dec.length) q++; // 吃掉 NUL
    return s;
  }

  final out = <DjvuDirFile>[];
  for (var i = 0; i < files; i++) {
    final id = readCStr();
    var name = id;
    var title = id;
    var f = flags[i];
    if (ver == 0) f = _convertFlags0(f);
    if ((f & 0x80) != 0) name = readCStr();
    if ((f & 0x40) != 0) title = readCStr();
    out.add(
      DjvuDirFile(
        id: id,
        name: name,
        title: title,
        offset: offsets[i],
        size: sizes[i],
        flags: f,
      ),
    );
  }
  return _DirmResult(bundled: bundled, files: out);
}

/// DIRM v0 的 flags → v1 的 flags（见 DjVmDir.h 的 FLAGS_0/FLAGS_1）
int _convertFlags0(int flags0) {
  var f1 = (flags0 & 0x01) != 0 ? 1 : 0; // IS_PAGE_0 → PAGE(1) / INCLUDE(0)
  if ((flags0 & 0x02) != 0) f1 |= 0x80; // HAS_NAME_0 → HAS_NAME
  if ((flags0 & 0x04) != 0) f1 |= 0x40; // HAS_TITLE_0 → HAS_TITLE
  return f1;
}

// ---------------------------------------------------------------- NAVM

/// 解 NAVM：整体是 BZZ 流；解出后是 `u16 书签数` + 一串"前序 + 子节点计数"记录。
List<DjvuBookmark> _readNavm(Uint8List data, DjvuChunk c) {
  final raw = djvuBzzDecode(_slice(data, c), maxSize: _kMaxDecompressed);
  if (raw.length < 2) return const [];
  var p = 0;
  int rd8() {
    if (p >= raw.length) throw DjvuFormatException('NAVM 数据不够');
    return raw[p++];
  }

  int rd16() => (rd8() << 8) | rd8();
  final total = rd16();
  if (total == 0) return const [];

  final out = <DjvuBookmark>[];

  // 一条记录：u8 count_low, u8 count_high（子节点数）, u16 标题长度, 标题,
  // u24 url 长度, url
  ({int count, String title, String url}) readEntry() {
    final countLow = rd8();
    final countHigh = rd8();
    final count = (countHigh << 8) | countLow;
    final titleLen = rd16();
    if (p + titleLen > raw.length) throw DjvuFormatException('NAVM 标题越界');
    final title = utf8.decode(
      Uint8List.sublistView(raw, p, p + titleLen),
      allowMalformed: true,
    );
    p += titleLen;
    final urlLen = (rd8() << 16) | (rd8() << 8) | rd8();
    if (p + urlLen > raw.length) throw DjvuFormatException('NAVM url 越界');
    final url = utf8.decode(
      Uint8List.sublistView(raw, p, p + urlLen),
      allowMalformed: true,
    );
    p += urlLen;
    return (count: count, title: title, url: url);
  }

  var consumed = 0;
  void walk(int depth) {
    if (consumed >= total) return;
    if (out.length > total + 8) {
      throw DjvuFormatException('NAVM 结构成环/异常');
    }
    final e = readEntry();
    consumed++;
    out.add(DjvuBookmark(title: e.title, url: e.url, depth: depth));
    for (var i = 0; i < e.count; i++) {
      walk(depth + 1);
    }
  }

  var guard = 0;
  while (consumed < total) {
    walk(0);
    if (++guard > total + 8) break;
  }
  return out;
}

// ---------------------------------------------------------------- IFF

/// 从 [pos] 读一个 FORM 头并枚举它的顶层分块。
///
/// 返回 null 表示这里不是一个完整的 FORM（调用方按上下文判为坏文件）。
DjvuForm? _readForm(Uint8List b, int pos, int limit) {
  var p = pos;
  p = _skipChunkIdMagic(b, p, limit);
  if (p < 0) return null;
  if (p + 8 > limit) return null;
  final id = _ascii(b, p, 4);
  if (id != 'FORM') return null;
  final size = _u32be(b, p + 4);
  final seekto = p + 8;
  var offEnd = seekto + size;
  if (offEnd < seekto || offEnd > b.length) {
    throw DjvuFormatException('FORM 的长度越界（声明 $size，文件只剩 ${b.length - seekto}）');
  }
  if (offEnd > limit) offEnd = limit;
  if (seekto + 4 > offEnd) {
    throw DjvuFormatException('FORM 缺少二级 ID');
  }
  final type = _ascii(b, seekto, 4);
  final dataStart = seekto + 4;
  final chunks = _readChunks(b, dataStart, offEnd);
  return DjvuForm(
    type: type,
    chunks: chunks,
    dataStart: dataStart,
    dataEnd: offEnd,
  );
}

/// 枚举 [start, end) 里的分块（含 2 字节对齐与 AT&T/SDJV 魔数跳过）。
List<DjvuChunk> _readChunks(Uint8List b, int start, int end) {
  final out = <DjvuChunk>[];
  var p = start;
  var guard = 0;
  while (p < end) {
    if (++guard > 4 * 1024 * 1024) {
      throw DjvuFormatException('分块数量异常（疑似损坏）');
    }
    if (p & 1 != 0) p += 1; // 2 字节对齐
    if (p >= end) break;
    final idPos = p;
    p = _skipChunkIdMagic(b, p, end);
    if (p < 0 || p + 8 > b.length) {
      throw DjvuFormatException('分块头越界（offset=$p）');
    }
    final id = _ascii(b, p, 4);
    final size = _u32be(b, p + 4);
    final seekto = p + 8;
    final offEnd = seekto + size;
    if (offEnd < seekto || offEnd > end || offEnd > b.length) {
      throw DjvuFormatException('分块 "$id" 的长度越界（声明 $size）');
    }
    final optional = _isOptionalId(id);
    if (_isCompositeId(id)) {
      if (seekto + 4 > offEnd) {
        throw DjvuFormatException('复合块 "$id" 缺少二级 ID');
      }
      final sub = _ascii(b, seekto, 4);
      out.add(
        DjvuChunk(
          id: '$id:$sub',
          offset: seekto + 4,
          length: offEnd - (seekto + 4),
          optional: optional,
        ),
      );
    } else {
      out.add(
        DjvuChunk(
          id: id,
          offset: seekto,
          length: offEnd - seekto,
          optional: optional,
        ),
      );
    }
    p = offEnd;
    if (p == idPos) break;
  }
  return out;
}

/// 读分块 ID 前跳过插入的魔数（`AT&T` / `SDJV`），返回真正的 ID 位置。
int _skipChunkIdMagic(Uint8List b, int pos, int limit) {
  var p = pos;
  var guard = 0;
  while (p + 4 <= limit && p + 4 <= b.length) {
    if (++guard > 1024) return -1;
    final s = _ascii(b, p, 4);
    if (s == 'AT&T' || s == 'SDJV') {
      p += 4;
      continue;
    }
    return p;
  }
  return p + 4 <= limit ? p : -1;
}

/// 规范里"可选块" = ID 首字节是小写字母
bool _isOptionalId(String id) =>
    id.isNotEmpty && (id.codeUnitAt(0) & 0x20) != 0;

bool _isCompositeId(String id) =>
    id == 'FORM' || id == 'LIST' || id == 'PROP' || id == 'CAT ';

// ---------------------------------------------------------------- 工具

Uint8List _slice(Uint8List b, DjvuChunk c) {
  if (c.offset < 0 || c.length < 0 || c.offset + c.length > b.length) {
    throw DjvuFormatException('分块 ${c.id} 的数据区间越界');
  }
  return Uint8List.sublistView(b, c.offset, c.offset + c.length);
}

int _u32be(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

String _ascii(Uint8List b, int o, int n) {
  if (o < 0 || o + n > b.length) return '';
  return String.fromCharCodes(b.sublist(o, o + n));
}

// ---------------------------------------------------------------- 探针

/// 给工具/调试用：不解位图，只回报容器与文本层的关键字段。
Map<String, Object?> djvuProbe(List<int> bytes) {
  try {
    final a = DjvuArchive.open(bytes);
    return {
      'form': a.formType,
      'pages': a.pages.length,
      'directory': a.directory.length,
      'bookmarks': a.bookmarks.length,
      'thumbnailChunks': a.thumbnail.length,
      'firstPage': {
        'width': a.pages.first.info?.width ?? 0,
        'height': a.pages.first.info?.height ?? 0,
        'version': a.pages.first.info?.version ?? 0,
        'dpi': a.pages.first.info?.dpi ?? 0,
        'textChars': a.pages.first.text.length,
        'hasSjbz': a.pages.first.sjbz != null,
        'bg44': a.pages.first.bg44.length,
        'fg44': a.pages.first.fg44.length,
        'unsupported': a.pages.first.unsupported,
        'unknown': a.pages.first.unknownChunks,
      },
      'titles': [for (final p in a.pages) p.title],
      'bookmarkTitles': [for (final b in a.bookmarks) b.title],
    };
  } catch (e) {
    return {'error': '$e'};
  }
}


/// 页码标题（`第 N 页`）：纯 Dart 层不能 i18n ⇒ 走 `dataText`。
String _bookPageTitle(int n) =>
    dataText('bookPageN', '第 {n} 页').replaceAll('{n}', '$n');
