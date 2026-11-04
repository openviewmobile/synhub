// **最小 RAR 写入器**（只用来生成测试夹具，不进 App）—— 纯 Dart，零依赖。
//
// 为什么需要它：CBR 的离线测试不能依赖外部二进制、也不许下载真实漫画，
// 所以 store（不压缩）模式的 RAR4/RAR5 由我们自己**写出来**，包含：
//   * 中文文件名（RAR4 走 RAR3 的 Unicode 文件名编码；RAR5 走 UTF-8）；
//   * 嵌套目录、多文件；
//   * 正确的文件 CRC32 与块头 CRC（RAR4 是 CRC32 低 16 位，RAR5 是完整 CRC32）。
//
// **压缩模式不在这里写**：LZSS+Huffman 的编码器不在本批范围；压缩夹具用 rarlab
// 官方 `rar` 本地生成后以 base64 常量固化（见 `test/support/rar_fixture_data.dart`），
// 由自研纯 Dart 解码器解出来再对 CRC —— 相当于拿独立参考实现当"期望字节"。
//
// 用法：
//   dart run tool/make_rar_fixture.dart out/rar4.rar rar4 姓名.txt=你好
//   dart run tool/make_rar_fixture.dart out/rar5.rar rar5 漫画/p1.png@p1.png
//   （`名字=文本` 写文本；`名字@本地文件` 写文件字节；`名字/` 写目录）
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:synhub/src/features/files/rar_archive.dart'
    show rarCrc32;

/// 一个夹具条目
class RarFixtureEntry {
  RarFixtureEntry(this.name, this.data);

  /// 归档内路径（`/` 分隔；目录以 `/` 结尾）
  final String name;
  final Uint8List data;

  bool get isDir => name.endsWith('/');
}

/// 生成 RAR4（RAR3 主体）的 store 归档
Uint8List buildRar4Fixture(
  List<RarFixtureEntry> entries, {
  int mtime = 0,
  int method = 0x30,
  int unpackVersion = 20,
  bool unknownUnpSize = false,
}) {
  final out = BytesBuilder();
  out.add(const [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]);

  // 归档头：type=0x73, flags=0, size=13, 数据 6 字节保留
  out.add(_rar4Header(0x73, 0, List<int>.filled(6, 0)));

  for (final e in entries) {
    final nameBytes = _rar4Name(e.isDir ? e.name : e.name);
    final body = BytesBuilder();
    body.add(_u32(e.data.length)); // PACK_SIZE
    // UNP_SIZE：老包（RAR 2.0）常写 0xFFFFFFFF = "大小未知"，存储型要能兜住
    body.add(_u32(unknownUnpSize ? 0xFFFFFFFF : e.data.length));
    body.addByte(3); // HOST_OS = Windows
    body.add(_u32(e.isDir ? 0 : rarCrc32(e.data))); // FILE_CRC
    body.add(_u32(mtime)); // FTIME（DOS）
    body.addByte(unpackVersion); // UNP_VER
    body.addByte(method); // METHOD（0x30 = store）
    body.add(_u16(nameBytes.length)); // NAME_SIZE
    body.add(_u32(0x20)); // ATTR
    body.add(nameBytes);
    var flags = 0x8000; // blockHasData
    flags |= 0x0200; // LHD_UNICODE（中文名走 RAR3 的 Unicode 编码）
    if (e.isDir) flags |= 0x00E0; // 目录：window bits 全 1
    out.add(_rar4Header(0x74, flags, body.takeBytes()));
    if (!e.isDir) out.add(e.data);
  }

  out.add(_rar4Header(0x7B, 0, const [])); // 结束块
  return out.takeBytes();
}

/// 生成 RAR5 的 store 归档
Uint8List buildRar5Fixture(
  List<RarFixtureEntry> entries, {
  int? mtime,
  int compressionInfo = 0,
  bool unknownUnpSize = false,
}) {
  final out = BytesBuilder();
  out.add(const [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]);

  // 归档块：type=1, flags=0, arcFlags=0
  out.add(_rar5Header(1, 0, _vint(0)));

  for (final e in entries) {
    final nameBytes = Uint8List.fromList(utf8.encode(e.name));
    final hasCrc = !e.isDir && e.data.isNotEmpty;
    var fileFlags = 0;
    if (e.isDir) fileFlags |= 0x0001;
    if (mtime != null) fileFlags |= 0x0002;
    if (hasCrc) fileFlags |= 0x0004;
    if (unknownUnpSize && !e.isDir) fileFlags |= 0x0008; // FILE_SIZE_UNKNOWN
    final body = BytesBuilder();
    body.add(_vint(fileFlags));
    body.add(_vint(e.data.length)); // unpacked size（未知时按规范写 0）
    body.add(_vint(0x20)); // attributes
    if (mtime != null) body.add(_u32(mtime));
    if (hasCrc) body.add(_u32(rarCrc32(e.data)));
    body.add(_vint(compressionInfo)); // 0 = store；非 0 用来测"未实现的压缩"分支
    body.add(_vint(0)); // host os = Windows
    body.add(_vint(nameBytes.length));
    body.add(nameBytes);
    final flags = e.data.isEmpty ? 0 : 0x0002; // blockHasData
    out.add(_rar5Header(2, flags, body.takeBytes(), dataSize: e.data.length));
    if (e.data.isNotEmpty) out.add(e.data);
  }

  out.add(_rar5Header(5, 0, _vint(0))); // 结束块
  return out.takeBytes();
}

// ------------------------------------------------------------------ 内部

/// RAR4 块：`crc16(2) type(1) flags(2) size(2) data`
Uint8List _rar4Header(int type, int flags, List<int> data) {
  final size = 7 + data.length;
  final buf = Uint8List(size);
  buf[2] = type;
  buf[3] = flags & 0xFF;
  buf[4] = (flags >> 8) & 0xFF;
  buf[5] = size & 0xFF;
  buf[6] = (size >> 8) & 0xFF;
  buf.setRange(7, 7 + data.length, data);
  // 块头 CRC = CRC32 的低 16 位（覆盖 type 起、到块尾）
  final crc = rarCrc32(Uint8List.sublistView(buf, 2)) & 0xFFFF;
  buf[0] = crc & 0xFF;
  buf[1] = (crc >> 8) & 0xFF;
  return buf;
}

/// RAR5 块：`crc32(4) size(vint) body`；CRC 覆盖 `size` 字段 + body
Uint8List _rar5Header(int type, int flags, List<int> body, {int dataSize = 0}) {
  final content = BytesBuilder();
  content.add(_vint(type));
  content.add(_vint(flags));
  if (dataSize > 0) content.add(_vint(dataSize));
  content.add(body);
  final contentBytes = content.takeBytes();
  final sizeBytes = _vint(contentBytes.length);
  final covered = Uint8List(sizeBytes.length + contentBytes.length)
    ..setRange(0, sizeBytes.length, sizeBytes)
    ..setRange(
      sizeBytes.length,
      sizeBytes.length + contentBytes.length,
      contentBytes,
    );
  final out = BytesBuilder();
  out.add(_u32(rarCrc32(covered)));
  out.add(covered);
  return out.takeBytes();
}

/// RAR3 的 Unicode 文件名编码：`ansiName \0 highByte flags 字符数据`
///
/// 这里对所有字符统一用 2 bit 码 `10`（16 位小端），够用且简单。
Uint8List _rar4Name(String name) {
  final units = name.codeUnits;
  final out = BytesBuilder();
  out.add(utf8.encode(name)); // 前置 ANSI 字段（我们的解析器优先严格 UTF-8）
  out.addByte(0);
  out.addByte(0); // highByte
  // 每 4 个字符前放一个 flags 字节（每 2 bit 一个字符，`10` = 16 位小端），
  // 解码器是**边读边取** flags 的，所以必须交错，不能把 flags 全堆在前面。
  for (var i = 0; i < units.length; i += 4) {
    out.addByte(0xAA);
    for (var j = i; j < i + 4 && j < units.length; j++) {
      out.addByte(units[j] & 0xFF);
      out.addByte((units[j] >> 8) & 0xFF);
    }
  }
  return out.takeBytes();
}

List<int> _vint(int v) {
  final out = <int>[];
  var n = v;
  while (true) {
    final b = n & 0x7F;
    n >>= 7;
    if (n == 0) {
      out.add(b);
      return out;
    }
    out.add(b | 0x80);
  }
}

List<int> _u16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
List<int> _u32(int v) => [
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
];

// ------------------------------------------------------------------ CLI

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln(
      '用法: dart run tool/make_rar_fixture.dart <out.rar> <rar4|rar5> '
      '(名字=文本 | 名字@文件 | 名字/ ...)',
    );
    exit(2);
  }
  final outPath = args[0];
  final version = args[1];
  final entries = <RarFixtureEntry>[];
  for (final spec in args.skip(2)) {
    if (spec.endsWith('/')) {
      entries.add(RarFixtureEntry(spec, Uint8List(0)));
      continue;
    }
    final eq = spec.indexOf('=');
    final at = spec.indexOf('@');
    if (eq > 0 && (at < 0 || eq < at)) {
      entries.add(
        RarFixtureEntry(
          spec.substring(0, eq),
          Uint8List.fromList(utf8.encode(spec.substring(eq + 1))),
        ),
      );
    } else if (at > 0) {
      entries.add(
        RarFixtureEntry(
          spec.substring(0, at),
          File(spec.substring(at + 1)).readAsBytesSync(),
        ),
      );
    } else {
      stderr.writeln('无法解析条目：$spec');
      exit(2);
    }
  }
  final bytes = version == 'rar5'
      ? buildRar5Fixture(entries)
      : buildRar4Fixture(entries);
  File(outPath).writeAsBytesSync(bytes);
  stdout.writeln(
    '$outPath: RAR$version store, ${entries.length} 条目, ${bytes.length} 字节',
  );
}
