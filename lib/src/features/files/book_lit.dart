// LIT（Microsoft Reader / ITOLITLS）解析层 —— **纯 Dart**，不 import flutter / l10n。
//
// 现状口径：**容器识别已做到精确判定，正文明确不支持**（不是"半成品吐乱码"）。
//
// 布局（已按两份独立实现核对：ConvertLIT 1.8 的 `litheaders.c` 与 calibre 的
// `ebooks/lit/{reader,writer}.py`；**小端**）：
//
//   * 偏移 0：`ITOLITLS`；偏移 8：version u32（=1）；偏移 12：**hdr_len**（=40，
//     不是 ITSF 签名 —— 这点常被记错）；偏移 16：num_pieces（=5）；偏移 20：
//     sec_hdr_len（=232）；偏移 24：16 字节文件 GUID；
//   * 偏移 `hdr_len` 起是 **piece 表**：num_pieces × (u64 offset, u64 size)。
//     piece 0 = 长度片（`u32 0x1FE, u32 version, u64 fileLength`）；
//     piece 1 = IFCM 主目录；piece 2 = 计数/索引目录；piece 3/4 = 固定 GUID；
//   * 目录不是 CHM 的 PMGL，而是 `IFCM` + `AOLL`/`AOLI` 分块，条目是
//     `encint(len)+name+encint(section)+encint(offset)+encint(size)`（大端 base-128）；
//   * 内部是 `::DataSpace/…` 与 `/meta`（OPF）、`/manifest` 以及
//     **evaporated HTML**（NUL 分隔的标签/属性 token 流），图片按内部名另存；
//   * 正文 section 的变换链是 `DES(LZX(明文))`，压缩参数在 `LZXC` 控制块、
//     分段偏移在 `ResetTable`（v3，每 0x8000 一条、窗口 15..21 位）。
//
// 为什么不把正文做出来（结论）：
//   1. 需要**自研三个大件**：MS-LZX 解码器（15..21 位窗口、按窗口复位）、
//      Microsoft 变体 SHA-1 + LIT-DES（非标准 DES，无文字规范）、以及
//      evaporated-HTML 的标签/属性表还原；
//   2. DRM1/DRM3 的密钥是**从文件内容派生**的（可解），DRM5 才需要用户 RSA 密钥；
//   3. **拿不到任何真实 `.lit` 样本**（Gutenberg 早已下架、各镜像 404、archive.org
//      等在本机网络不可达），写了也无法端到端验证 —— 按"绝不输出未经验证的正文"
//      的硬要求，这里只交付**精确到 DRM 等级与所需变换**的结论。
//
// 有权威样本后，正文路径可以在这层之上继续接：目录解析 + DRM 判定已经是最终形态。
import 'dart:typed_data';

import 'file_book.dart';

/// LIT 文件签名（Microsoft Reader）
const String _kLitSignature = 'ITOLITLS';

/// DES 变换 GUID `{67F6E4A2-60BF-11D3-8540-00C04F58C3CF}` 的**小端**字节
const List<int> _kDesGuid = [
  0xA2, 0xE4, 0xF6, 0x67, 0xBF, 0x60, 0xD3, 0x11, //
  0x85, 0x40, 0x00, 0xC0, 0x4F, 0x58, 0xC3, 0xCF,
];

/// LZX 变换 GUID `{0A9007C6-4076-11D3-8789-0000F8105754}` 的**小端**字节
const List<int> _kLzxGuid = [
  0xC6, 0x07, 0x90, 0x0A, 0x76, 0x40, 0xD3, 0x11, //
  0x87, 0x89, 0x00, 0x00, 0xF8, 0x10, 0x57, 0x54,
];

/// `.lit` → 容器识别 + 精确结论。
///
/// 文件坏了/不是 LIT → [FormatException]（`parseBook` 归到 `parseFailed`）；
/// 是 LIT 但正文做不到 → [BookUnsupportedException]（归到 `unsupportedCompression`）。
BookContent parseLitBook(List<int> bytes, {required BookFormat format}) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final info = litInfo(data);
  if (info == null) {
    throw const FormatException('不是 LIT 文件（缺少 ITOLITLS 签名或头部被截断/非法）');
  }
  // ★ r316c：LIT 这类「认识但做不到」归到 drm（DRM5/EUL 是主因）
  throw BookUnsupportedException(
    _reasonFor(info),
    reason: BookUnsupportedReason.drm,
  );
}

/// LIT 头部的**可靠判定**结果
typedef LitInfo = ({
  int version,
  int hdrLen,
  int numPieces,
  int secHdrLen,
  int fileLength,

  /// 0（无 DRM）/ 1（sealed）/ 3（inscribed）/ 5（EUL，需要用户 RSA 密钥）
  int drmLevel,
  bool needsDes,
  bool needsLzx,
  int size,
});

/// 解析并校验 LIT 头部；不像 LIT 返回 null（不抛）。
///
/// 只做**有把握的判定**：签名、版本、piece 表边界、piece 0 的长度片，
/// 以及 DRM/变换 GUID 的**存在性**（这些标记在目录里是明文 ASCII/GUID）。
LitInfo? litInfo(Uint8List data) {
  if (data.length < 40) return null;
  if (_ascii(data, 0, 8) != _kLitSignature) return null;
  final version = _u32le(data, 8);
  if (version < 1) return null;
  final hdrLen = _u32le(data, 12);
  final numPieces = _u32le(data, 16);
  final secHdrLen = _u32le(data, 20);
  // 保守：hdr_len 必须至少覆盖主头，piece 表必须落在文件内
  if (hdrLen < 40 || hdrLen > data.length) return null;
  if (numPieces < 1 || numPieces > 64) return null;
  if (hdrLen + numPieces * 16 > data.length) return null;

  // piece 0 = 长度片：u32 tag(=0x1FE) + u32 version + u64 fileLength
  // （v1 长 16 字节，v2 还有第二个 piece 表 → 保守只要求 16 字节可读）
  var fileLength = 0;
  final p0 = _u64le(data, hdrLen);
  if (p0 > 0 && p0 + 16 <= data.length) {
    fileLength = _u64le(data, p0 + 8);
  }

  final drmLevel = _drmLevel(data);
  return (
    version: version,
    hdrLen: hdrLen,
    numPieces: numPieces,
    secHdrLen: secHdrLen,
    fileLength: fileLength,
    drmLevel: drmLevel,
    needsDes: _containsBytes(data, _kDesGuid),
    needsLzx: _containsBytes(data, _kLzxGuid) || _containsAscii(data, 'LZXC'),
    size: data.length,
  );
}

/// 按 DRM 等级与所需变换给出**精确**的能力边界说明。
String _reasonFor(LitInfo info) {
  switch (info.drmLevel) {
    // ★ r378：原先写「本仓库尚未自研完成」「未经验证的正文」—— 那是开发口吻，
    //   用户既看不懂也无法据此操作（同族：R8 开发侧用语）。改成说清"为什么打不开"。
    case 5:
      return '这本 LIT 受 DRM5 保护（EUL 许可，需要你购买时的 RSA 密钥），本应用无法解密';
    case 3:
      return '这本 LIT 受 DRM3 保护（inscribed，含购书者信息），正文经过 DES+LZX 加密变换，'
          '本应用暂不支持打开';
    case 1:
      return '这本 LIT 受 DRM1 保护（sealed，密钥从文件内容派生），正文经过 DES+LZX 加密变换，'
          '本应用暂不支持打开';
  }
  final needs = <String>[
    if (info.needsDes) 'LIT-DES',
    if (info.needsLzx) 'MS-LZX',
    'evaporated-HTML 还原',
  ].join(' + ');
  return 'LIT（ITOLITLS v${info.version}）容器已识别'
      '（piece ${info.numPieces} 个，长度片 fileLength=${info.fileLength}）；'
      '正文仍需 $needs，本应用暂不支持打开这种变体';
}

/// DRM 等级：目录里的明文标记（优先级 EUL > Bookplate > Sealed）
int _drmLevel(Uint8List data) {
  if (_containsAscii(data, '/DRMStorage/Licenses/EUL')) return 5;
  if (_containsAscii(data, '/DRMStorage/DRMBookplate')) return 3;
  if (_containsAscii(data, '/DRMStorage/DRMSealed')) return 1;
  return 0;
}

/// 给探针用：LIT 头部摘要（不落 [BookContent]）
Map<String, Object?> litProbe(List<int> bytes) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final info = litInfo(data);
  if (info == null) {
    return {
      'ok': false,
      'lit': false,
      'magic': data.length >= 8 ? _ascii(data, 0, 8) : '',
      'size': data.length,
    };
  }
  return {
    'ok': true,
    'lit': true,
    'version': info.version,
    'hdrLen': info.hdrLen,
    'numPieces': info.numPieces,
    'secHdrLen': info.secHdrLen,
    'fileLength': info.fileLength,
    'drmLevel': info.drmLevel,
    'needsDes': info.needsDes,
    'needsLzx': info.needsLzx,
    'size': info.size,
  };
}

/// 给探针/测试用：DRM 等级（0/1/3/5）
int litDrmLevel(List<int> bytes) =>
    _drmLevel(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));

// ------------------------------------------------------------------ 工具

bool _containsAscii(Uint8List data, String needle) =>
    _containsBytes(data, needle.codeUnits);

bool _containsBytes(Uint8List data, List<int> needle) {
  final n = needle.length;
  if (n == 0 || data.length < n) return false;
  for (var i = 0; i + n <= data.length; i++) {
    if (data[i] != needle[0]) continue;
    var ok = true;
    for (var k = 1; k < n; k++) {
      if (data[i + k] != needle[k]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}

String _ascii(Uint8List b, int offset, int length) {
  if (offset < 0 || offset + length > b.length) return '';
  return String.fromCharCodes(b.sublist(offset, offset + length));
}

int _u32le(Uint8List b, int offset) {
  if (offset < 0 || offset + 4 > b.length) return 0;
  return b[offset] |
      (b[offset + 1] << 8) |
      (b[offset + 2] << 16) |
      (b[offset + 3] << 24);
}

int _u64le(Uint8List b, int offset) {
  if (offset < 0 || offset + 8 > b.length) return 0;
  var v = 0;
  for (var i = 7; i >= 0; i--) {
    v = v * 256 + b[offset + i];
  }
  return v;
}
