// MOBI HUFF/CDIC（压缩类型 17480）解码的离线测试。
//
// fixture 是**自造、代码生成**的合法 HUFF+CDIC 记录（见 `support/huff_cdic_fixture.dart`）：
//   * 8 位终端码 + 9 位**非终端**码混合（覆盖 dict2 的 min/max 查表路径）；
//   * 64 位滑动窗口跨字节边界；
//   * 中文 UTF-8 字节；
//   * 一条**压缩短语**（递归解码路径）。
// 同一份 fixture 已用 KindleUnpack 的参考解码器验证过能还原，所以 Dart 结果与
// 期望一致即可认为算法实现正确。
//
// ⚠️ **没有真实 HUFF/CDIC 书做端到端验证**：这一批的结论是"已实现 + 离线验证"，
// 不是"真实样本已证明"。真实样本若拿到，往本文件追加一个 skip-if-missing 用例即可
// （PG 的 KF8 回归见最后一个 group）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/files/book_mobi.dart';
import 'package:synhub/src/features/files/file_book.dart';

import 'support/huff_cdic_fixture.dart';

Uint8List _b(String b64) => base64.decode(b64);

/// PalmDB 记录表里第 [i] 条记录的绝对起点（78 字节头 + i*8 的记录项）
int _recordOffset(Uint8List mobi, int i) {
  final p = 78 + i * 8;
  return (mobi[p] << 24) |
      (mobi[p + 1] << 16) |
      (mobi[p + 2] << 8) |
      mobi[p + 3];
}

void main() {
  group('HUFF/CDIC 解码（mobiHuffCdicDecode）', () {
    test('全 256 字节（8/9 位混合码 + 非终端 dict2 路径）逐一还原', () {
      final want = Uint8List.fromList(List.generate(256, (i) => i));
      final got = mobiHuffCdicDecode(_b(kHuffB64), [
        _b(kCdicB64),
      ], _b(kEncodedAllB64));
      expect(got, want);
    });

    test('中文 UTF-8 正文还原（含 <p> 标签）', () {
      final got = mobiHuffCdicDecode(_b(kHuffB64), [
        _b(kCdicB64),
      ], _b(kEncodedCnB64));
      expect(utf8.decode(got), kCnText);
    });

    test('压缩短语递归展开：符号 128 → 短语 255 → 短语 254（字节 129）', () {
      // 符号 128 的 9 位码（C=256）编码成两个字节 `80 00`；短语 255 存的是
      // 符号 129 的 9 位码 `80 80`（flag=0 → 递归解）→ 输出字节 129。
      final got = mobiHuffCdicDecode(
        _b(kHuffB64),
        [_b(kCdicRecB64)],
        [0x80, 0x00],
      );
      expect(got, [129]);
    });

    test('HUFF magic 不对 → FormatException（不猜、不吐乱码）', () {
      final bad = Uint8List.fromList(_b(kHuffB64))
        ..setRange(0, 4, ascii.encode('XXXX'));
      expect(
        () => mobiHuffCdicDecode(bad, [_b(kCdicB64)], [1]),
        throwsFormatException,
      );
    });

    test('HUFF 码长为 0（坏字典）→ FormatException', () {
      final huff = Uint8List.fromList(_b(kHuffB64));
      // off1 = 24，dict1[0] 就压在 24..28；清零即 codelen == 0
      huff.setRange(24, 28, [0, 0, 0, 0]);
      expect(
        () => mobiHuffCdicDecode(huff, [_b(kCdicB64)], [1]),
        throwsFormatException,
      );
    });

    test('CDIC 被截断 → FormatException', () {
      final cdic = _b(kCdicB64);
      final cut = Uint8List.sublistView(cdic, 0, 24);
      expect(
        () => mobiHuffCdicDecode(_b(kHuffB64), [cut], [1]),
        throwsFormatException,
      );
    });
  });

  group('HUFF/CDIC 端到端（MOBI 容器）', () {
    test('压缩类型 17480 的 MOBI 能解析出正文与章节标题', () {
      final bytes = _b(kMobiB64);
      final probe = mobiHeaderProbe(bytes);
      expect(probe['compression'], 17480);
      expect(probe['version'], 6);
      expect(mobiHuffProbe(bytes)['phrases'], 256);

      final r = parseBook(BookFormat.mobi, bytes);
      expect(r.ok, isTrue, reason: r.error);
      expect(r.content.chapters, isNotEmpty);
      expect(r.content.chapters.first.title, 'HUFF 之书');
      expect(r.content.chapters.first.html, contains('HUFF/CDIC 正文。'));
      expect(kMobiHtml, contains('HUFF/CDIC 正文。'));
    });

    test('huffRecordOffset 指向非 HUFF 记录 → unsupportedCompression', () {
      final mobi = Uint8List.fromList(_b(kMobiB64));
      final rec0 = _recordOffset(mobi, 0);
      // rec0 里 huffRecordOffset 在 MOBI 头偏移 112 → 绝对 110+112
      final at = rec0 + 112;
      mobi[at] = 0;
      mobi[at + 1] = 0;
      mobi[at + 2] = 0;
      mobi[at + 3] = 1; // → record 1（正文记录，不是 HUFF）
      final r = parseBook(BookFormat.mobi, mobi);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
    });

    test('声明 HUFF/CDIC 但一条 CDIC 都没有 → unsupportedCompression', () {
      final mobi = Uint8List.fromList(_b(kMobiB64));
      final rec3 = _recordOffset(mobi, 3);
      mobi.setRange(rec3, rec3 + 4, ascii.encode('XXXX'));
      final r = parseBook(BookFormat.mobi, mobi);
      expect(r.ok, isFalse);
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      expect(r.error, contains('CDIC'));
    });
  });

  // ---------------------------------------------------------------- 真实样本回归
  //
  // `/tmp/ebook-samples/*` 是**公开许可/无 DRM** 的测试夹具，只在存在时跑，
  // **不入库**。PG11 是 Project Gutenberg 的公有领域 KF8 样本。
  group('真实样本回归（存在才跑）', () {
    // 真实 HUFF/CDIC 样本：libmobi 的合成测试夹具（LGPL-3.0-or-later，
    // 非公有领域文学文本），compression=17480、无 DRM，28 条正文记录、
    // 2 条 CDIC（347 个短语），是这批改动**唯一的真实端到端证据**。
    test('sample-unicode-huffdic.mobi（真实 17480）解出正文', () {
      final f = File('/tmp/ebook-samples/sample-unicode-huffdic.mobi');
      if (!f.existsSync()) {
        markTestSkipped('样本不存在：${f.path}');
        return;
      }
      final bytes = f.readAsBytesSync();
      expect(mobiHeaderProbe(bytes)['compression'], 17480);
      expect(mobiHuffProbe(bytes)['phrases'], 347);
      final r = parseBook(BookFormat.mobi, bytes);
      expect(r.ok, isTrue, reason: r.error);
      expect(r.content.chapters, isNotEmpty);
      final text = r.content.chapters.map((c) => c.html).join('\n');
      expect(text, contains('libmobi'));
    });

    for (final name in const [
      'pg11-kf8.azw3',
      'pg11.mobi',
      'pg1342-kf8.azw3',
      'pg1342.mobi',
    ]) {
      final path = '/tmp/ebook-samples/$name';
      test('$name 解析不崩、结论明确', () {
        final f = File(path);
        if (!f.existsSync()) {
          markTestSkipped('样本不存在：$path');
          return;
        }
        final r = parseBook(BookFormat.mobi, f.readAsBytesSync());
        // 要么读出来，要么给明确的能力边界/解析失败 —— 不允许"成功但没有内容"
        if (r.ok) {
          expect(r.content.chapters, isNotEmpty);
          expect(r.content.chapters.first.html, isNotEmpty);
        } else {
          expect(r.errorKind, isNotNull);
          expect(r.content.isEmpty, isTrue);
        }
      });
    }
  });
}
