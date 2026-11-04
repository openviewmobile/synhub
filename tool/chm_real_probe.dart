// 用**真实 CHM** 对我们自研的 ITSF/ITSP/PMGL + LZX 解析器做端到端对照。
//
// 只调 `lib/src/features/files/chm_archive.dart` 的**公开 API**
// （`ChmArchive.open` / `.entries` / `.find` / `.read` / `chmLzxDecodeBlock`），
// 不 import flutter / l10n，`dart run` 即可。
//
// 用法：
//   dart run tool/chm_real_probe.dart <file.chm> <oracle-dir>
//
// oracle-dir 是用独立实现（本机只有 `7z`）导出的同内容目录树：
//   7z x file.chm -o<oracle-dir>
// 逐文件比对我们解出的字节与 oracle 的字节（sha256），并输出
// 成功 / 不一致 / 抛错 三类统计与前若干个不一致例子。
//
// 样本只放 /tmp，不提交进仓库。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';

import 'package:synhub/src/features/files/book_chm.dart';
import 'package:synhub/src/features/files/book_encoding.dart';
import 'package:synhub/src/features/files/chm_archive.dart';

String sha256Hex(List<int> b) => SHA256Digest()
    .process(b is Uint8List ? b : Uint8List.fromList(b))
    .map((x) => x.toRadixString(16).padLeft(2, '0'))
    .join();

String normalize(String p) {
  var s = p.replaceAll('\\', '/');
  while (s.startsWith('/')) {
    s = s.substring(1);
  }
  while (s.startsWith('./')) {
    s = s.substring(2);
  }
  return s;
}

/// 从公开的 space-0 条目里读 LZXC 控制数据，报出真实文件的参数实况。
Map<String, Object?> lzxParams(ChmArchive a) {
  const controlUnit = '::dataspace/storage/mscompressed/controldata';
  const resetUnit =
      '::dataspace/storage/mscompressed/transform/'
      '{7fc28940-9d31-11d0-9b27-00a0c91e9c7c}/instancedata/resettable';
  try {
    final c = a.find(controlUnit);
    if (c == null) return {'error': '找不到 ControlData'};
    final cd = a.read(c);
    if (cd.length < 0x14) return {'error': 'ControlData 太短 ${cd.length}'};
    final sig = String.fromCharCodes(cd.sublist(0x04, 0x08));
    final ver =
        cd[0x08] | (cd[0x09] << 8) | (cd[0x0A] << 16) | (cd[0x0B] << 24);
    final resetRaw =
        cd[0x0C] | (cd[0x0D] << 8) | (cd[0x0E] << 16) | (cd[0x0F] << 24);
    final winRaw =
        cd[0x10] | (cd[0x11] << 8) | (cd[0x12] << 16) | (cd[0x13] << 24);
    final rt = a.find(resetUnit);
    final out = <String, Object?>{
      'controlSig': sig,
      'lzxcVersion': ver,
      'resetRaw': resetRaw,
      'windowRaw': winRaw,
      'resetInterval': ver == 2 ? resetRaw * 0x8000 : resetRaw,
      'windowSize': ver == 2 ? winRaw * 0x8000 : winRaw,
      'resetTableFound': rt != null,
      'resetTableLen': rt?.length,
    };
    if (rt != null) {
      final rb = a.read(rt);
      if (rb.length >= 0x28) {
        int u32(int o) =>
            rb[o] | (rb[o + 1] << 8) | (rb[o + 2] << 16) | (rb[o + 3] << 24);
        int u64(int o) {
          var v = 0;
          for (var i = 7; i >= 0; i--) {
            v = (v << 8) | rb[o + i];
          }
          return v;
        }

        out['resetTableVersion'] = u32(0x00);
        out['resetBlockCount'] = u32(0x04);
        out['resetTableOffset'] = u32(0x0C);
        out['compressedLen'] = u64(0x18);
        out['blockLen'] = u64(0x20);
      }
    }
    return out;
  } catch (e) {
    return {'error': '$e'};
  }
}

/// 统计真实内容流里**实际用到的 LZX 块类型**（1=verbatim / 2=aligned / 3=uncompressed）。
///
/// 自造 fixture 只覆盖 uncompressed 块；只有真实 CHM 才能证明 verbatim/aligned
/// 这条"从未被证明的路径"。这里用公开 API 自己驱动 [ChmLzxDecoder]，把块头回调
/// 出来分类 —— 解码器与 `ChmArchive.read` 用的是同一个类、同一份输入。
Map<String, Object?> lzxBlockTypeCensus(ChmArchive a) {
  const contentUnit = '::dataspace/storage/mscompressed/content';
  const controlUnit = '::dataspace/storage/mscompressed/controldata';
  const resetUnit =
      '::dataspace/storage/mscompressed/transform/'
      '{7fc28940-9d31-11d0-9b27-00a0c91e9c7c}/instancedata/resettable';
  int u32le(List<int> b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
  int u64le(List<int> b, int o) {
    var v = 0;
    for (var i = 7; i >= 0; i--) {
      v = (v << 8) | b[o + i];
    }
    return v;
  }

  try {
    final control = a.find(controlUnit);
    final rtEntry = a.find(resetUnit);
    final content = a.find(contentUnit);
    if (control == null || rtEntry == null || content == null) {
      return {'error': '缺少 ControlData/ResetTable/Content'};
    }
    final cd = a.read(control);
    final ver = u32le(cd, 0x08);
    final resetRaw = u32le(cd, 0x0C);
    final winRaw = u32le(cd, 0x10);
    final windowSize = ver == 2 ? winRaw * 0x8000 : winRaw;
    final resetInterval = ver == 2 ? resetRaw * 0x8000 : resetRaw;
    var windowBits = 0;
    while ((1 << windowBits) < windowSize) {
      windowBits++;
    }

    final rb = a.read(rtEntry);
    final blockCount = u32le(rb, 0x04);
    final tableOffset = u32le(rb, 0x0C);
    final compressedLen = u64le(rb, 0x18);
    final blockLen = u64le(rb, 0x20);
    final tableBase = a.dataOffset + rtEntry.start + tableOffset;
    int blockStart(int i) => u64le(a.bytes, tableBase + i * 8);
    final contentStart = a.dataOffset + content.start;
    var perReset = resetInterval ~/ blockLen;
    if (perReset < 1) perReset = 1;

    final counts = <int, int>{};
    var chunks = 0;
    var errors = 0;
    for (var base = 0; base < blockCount; base += perReset) {
      final dec = ChmLzxDecoder(
        windowBits: windowBits,
        onBlockType: (t) => counts[t] = (counts[t] ?? 0) + 1,
      );
      for (var b = base; b < base + perReset && b < blockCount; b++) {
        final start = blockStart(b);
        final end = b < blockCount - 1 ? blockStart(b + 1) : compressedLen;
        if (end <= start || contentStart + end > a.bytes.length) {
          errors++;
          continue;
        }
        final input = Uint8List.sublistView(
          a.bytes,
          contentStart + start,
          contentStart + end,
        );
        try {
          dec.decodeChunk(input, blockLen);
          chunks++;
        } catch (_) {
          errors++;
        }
      }
    }
    // LZX 流头（只在每个重置区间第一块前读）：1 bit 的 E8/Intel 标志 +
    // 可选的 32 位"文件长度"。这里按 LZX 的位序（16 位小端字、从最高位起）
    // 直接从内容流首块读，报告 E8 是否启用。
    var intelFlag = -1;
    var intelFileSize = 0;
    if (blockCount > 0) {
      final s = blockStart(0);
      if (contentStart + s + 10 <= a.bytes.length) {
        int bitAt(int i) {
          final at = contentStart + s + (i ~/ 16) * 2;
          final w = a.bytes[at] | (a.bytes[at + 1] << 8);
          return (w >> (15 - (i % 16))) & 1;
        }

        intelFlag = bitAt(0);
        if (intelFlag == 1) {
          for (var i = 1; i <= 32; i++) {
            intelFileSize = (intelFileSize << 1) | bitAt(i);
          }
        }
      }
    }
    return {
      'windowBits': windowBits,
      'resetIntervalBlocks': perReset,
      'e8IntelFlag': intelFlag,
      'e8FileSize': intelFileSize,
      'chunksDecoded': chunks,
      'chunksErrored': errors,
      'verbatim(1)': counts[1] ?? 0,
      'aligned(2)': counts[2] ?? 0,
      'uncompressed(3)': counts[3] ?? 0,
      'unknownTypes': {
        for (final e in counts.entries)
          if (e.key < 1 || e.key > 3) e.key: e.value,
      },
    };
  } catch (e) {
    return {'error': '$e'};
  }
}

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln(
      '用法: dart run tool/chm_real_probe.dart <file.chm> <oracle-dir>',
    );
    exit(2);
  }
  final chmPath = args[0];
  final oracleDir = args[1];
  final reportPath = args.length > 2 ? args[2] : '/tmp/chm-probe-report.txt';

  final bytes = File(chmPath).readAsBytesSync();
  final buf = StringBuffer();
  void log(Object s) {
    print(s);
    buf.writeln(s);
  }

  log('===== CHM 真实样本端到端探针 =====');
  log('样本: $chmPath (${bytes.length} 字节)');
  log('oracle: $oracleDir');

  final ChmArchive a;
  try {
    a = ChmArchive.open(bytes);
  } catch (e) {
    log('打开失败: $e');
    File(reportPath).writeAsStringSync(buf.toString());
    exit(1);
  }
  log(
    'ITSF 版本=${a.version} langId=0x${a.langId.toRadixString(16)} '
    'dirOffset=${a.dirOffset} dirLen=${a.dirLen} dataOffset=${a.dataOffset} '
    'blockLen=${a.blockLen}',
  );
  final sp0 = a.entries.where((e) => e.space == 0 && !e.isDir).length;
  final sp1 = a.entries.where((e) => e.space == 1 && !e.isDir).length;
  final dirs = a.entries.where((e) => e.isDir).length;
  log('目录条目: 共 ${a.entries.length}（文件 space0=$sp0 space1=$sp1, 目录=$dirs 个）');
  log('LZX 参数实况: ${jsonEncode(lzxParams(a))}');
  log('LZX 块类型统计: ${jsonEncode(lzxBlockTypeCensus(a))}');

  // oracle 文件清单
  final dir = Directory(oracleDir);
  if (!dir.existsSync()) {
    log('oracle 目录不存在: $oracleDir');
    File(reportPath).writeAsStringSync(buf.toString());
    exit(2);
  }
  final files =
      dir
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => normalize(f.path.substring(oracleDir.length)))
          .toList()
        ..sort();
  log('oracle 文件数: ${files.length}');

  var ok = 0;
  var mismatch = 0;
  var error = 0;
  var missing = 0;
  final problems = <String>[];
  var checkedBytes = 0;

  for (final rel in files) {
    final entry = a.find(rel);
    if (entry == null) {
      missing++;
      if (problems.length < 40) problems.add('MISSING   $rel');
      continue;
    }
    final Uint8List mine;
    try {
      mine = a.read(entry);
    } catch (e) {
      error++;
      if (problems.length < 40) problems.add('ERROR     $rel :: $e');
      continue;
    }
    final theirs = File('$oracleDir/$rel').readAsBytesSync();
    checkedBytes += theirs.length;
    if (mine.length == theirs.length && sha256Hex(mine) == sha256Hex(theirs)) {
      ok++;
    } else {
      mismatch++;
      if (problems.length < 40) {
        problems.add(
          'MISMATCH  $rel :: len ${mine.length} vs ${theirs.length} :: '
          'mine=${sha256Hex(mine)} oracle=${sha256Hex(theirs)}',
        );
      }
    }
  }

  log('');
  log('===== 对照统计 =====');
  log('成功一致 : $ok');
  log('不一致   : $mismatch');
  log('抛错     : $error');
  log('找不到条目: $missing');
  log('比对字节总数: $checkedBytes');
  log('');
  log('--- 前若干个问题（最多 40）---');
  for (final p in problems) {
    log(p);
  }
  if (problems.isEmpty) log('（无）');

  // ---- 内容抽取层（book_chm.dart）：目录/正文/图片
  log('');
  log('===== book_chm 内容抽取 =====');
  log('chmBookProbe: ${jsonEncode(chmBookProbe(bytes))}');
  log('chmDebugProbe: ${jsonEncode(chmDebugProbe(bytes))}');

  // 编码探测实况：真实 Python CHM 的 hhc/正文是 Windows-1252（ANSI）
  try {
    final hhc = a.entries.firstWhere(
      (e) => !e.isDir && e.normalized.toLowerCase().endsWith('.hhc'),
    );
    final hb = a.read(hhc);
    final d = detectAndDecodeBookText(hb);
    log(
      'hhc 编码探测: ${d.encoding.label}, U+FFFD=${'\uFFFD'.allMatches(d.text).length}, '
      '0x92 计数=${hb.where((x) => x == 0x92).length}',
    );
    final page = a.entries.firstWhere(
      (e) => !e.isDir && e.normalized.toLowerCase().endsWith('.html'),
    );
    final pb = a.read(page);
    final dp = detectAndDecodeBookText(pb);
    log(
      '正文页 ${page.normalized} 编码探测: ${dp.encoding.label}, '
      'U+FFFD=${'\uFFFD'.allMatches(dp.text).length}, '
      '0x92 计数=${pb.where((x) => x == 0x92).length}',
    );
  } catch (e) {
    log('编码探测失败: $e');
  }

  File(reportPath).writeAsStringSync(buf.toString());
  print('\n报告写入: $reportPath');

  // 用于脚本判断
  exit(
    ok == files.length && mismatch == 0 && error == 0 && missing == 0 ? 0 : 1,
  );
}
