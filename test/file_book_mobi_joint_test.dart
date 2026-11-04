// **joint MOBI/KF8（kindlegen 组合包）** 与 **KF8 目录（NCX `0xF4` / guide `0x104`）**
// 的解析测试。
//
// 样本（都不进仓库，只在宿主 `/tmp` 存在时跑；不存在就带原因 skip）：
//   * `/tmp/ebook-samples/libmobi-joint-{ncx,multimedia,unicode}.mobi`
//     —— libmobi 仓库 `tests/samples/` 的三份**真实组合包**（record 0 是 MOBI6 头、
//     `BOUNDARY` 记录之后是 MOBI8 头、`0xC0` FDST 缺失）。libmobi 是
//     LGPL-3.0-or-later 的测试夹具，仅作**输入数据**，代码零拷贝。
//   * `/tmp/ebook-samples/pg11-kf8.azw3` —— 纯 KF8（Gutenberg #11，公有领域）。
//   * `/tmp/ebook-samples/pg11.mobi` —— 纯 MOBI6。
//
// **独立 oracle = KindleUnpack v0.83**（`/tmp/KindleUnpack`）：
//   * 组合包用 `tool/mobi_joint_probe.dart` 的等价驱动：扫描 8 字节 `BOUNDARY`
//     记录 → `MobiHeader(sect, boundary+1)` → `K8Processor.buildParts`；
//   * 三份 joint 样本 **逐段 sha256 全部一致**（下表 pin 死），见测试
//     「joint KF8 重组逐字节等于 KindleUnpack oracle」。
//
// 这一层是**承重**断言：把 `book_mobi.dart` 的"joint 优先 KF8"去掉（退回只读
// MOBI6），或把 `_kf8Ncx` 改坏（返回空），下面相应用例立刻红。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/digests/sha256.dart';

import 'package:synhub/src/features/files/book_mobi.dart';
import 'package:synhub/src/features/files/file_book.dart';

const _dir = '/tmp/ebook-samples';
const _jointNcx = '$_dir/libmobi-joint-ncx.mobi';
const _jointMultimedia = '$_dir/libmobi-joint-multimedia.mobi';
const _jointUnicode = '$_dir/libmobi-joint-unicode.mobi';
const _pureKf8 = '$_dir/pg11-kf8.azw3';
const _pureMobi6 = '$_dir/pg11.mobi';

String? _missing(String path) =>
    File(path).existsSync() ? null : '真实样本 $path 不存在（不进仓库）';

String _sha256(List<int> b) => SHA256Digest()
    .process(b is Uint8List ? b : Uint8List.fromList(b))
    .map((x) => x.toRadixString(16).padLeft(2, '0'))
    .join();

/// KindleUnpack v0.83 对三份 joint 样本的 `buildParts` 真值（`tool/mobi_joint_probe.dart`
/// 的 Python 驱动 `/tmp/kf8_joint_ref.py` 产出，os sha256sum 复核过）。
const _oracle =
    <String, ({int parts, List<String> sha, String concat, int bytes})>{
      _jointNcx: (
        parts: 3,
        sha: [
          '349754770f1701c073169855d4fd6d4a2bd1ed20a8adb08dbcf8f0cf42f04185',
          '1a58a89bc900bac27cb95f2e5eab442cf9c1bffada2c083fc1df505092cf89f1',
          '9373131b60e9c54b094487f2f8f91cc5aed202cbebc99a3f735114cc8028e115',
        ],
        concat:
            '263fb222d1c42ff2fdebff9ac89cf6ccba8428cb46a4a4fb4c8b6c582b1455d4',
        bytes: 1032,
      ),
      _jointMultimedia: (
        parts: 2,
        sha: [
          'e4b0abac2f1ad53bfdb0c337e5c08772e52f16ff9fd7141775a35424a20efbce',
          '327f4d9d948ae8500e71a53eb1da5f1e73a190d69f5e0c0502c4e32b45cf7460',
        ],
        concat:
            '6c0c0d6769a15897436ac4cb8017e5bdd8282ad19f7f5b744c373805a6cab885',
        bytes: 108896,
      ),
      _jointUnicode: (
        parts: 2,
        sha: [
          'cf8756295c0b98c502fc56d0ffcf9b8c3ae4a88577b3c7632bfc768bfd749c09',
          '327f4d9d948ae8500e71a53eb1da5f1e73a190d69f5e0c0502c4e32b45cf7460',
        ],
        concat:
            '7386a292441f784ef45b8c5a559e6e62efbee8d8a9e63191ab9f868803cdd606',
        bytes: 108333,
      ),
    };

// ------------------------------------------------------------- PalmDB 补丁工具

int _u32(List<int> b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

void _put32(Uint8List b, int o, int v) {
  b[o] = (v >> 24) & 0xFF;
  b[o + 1] = (v >> 16) & 0xFF;
  b[o + 2] = (v >> 8) & 0xFF;
  b[o + 3] = v & 0xFF;
}

/// 第 [i] 条 PalmDB 记录在文件里的字节偏移（最后一条到文件尾）。
int _recOffset(Uint8List b, int i) => _u32(b, 78 + i * 8);

/// KF8 半边 record 0 的**文件字节偏移**（joint 由 probe 的 `kf8Start` 得到）。
int _kf8Rec0(Uint8List b) {
  final p = mobiKf8Probe(b);
  final start = p['kf8Start'];
  if (p['ok'] != true || start is! int) {
    throw StateError('不是 KF8/ joint：$p');
  }
  return _recOffset(b, start);
}

Uint8List _birthBytes(String path) =>
    Uint8List.fromList(File(path).readAsBytesSync());

void main() {
  // ======================================================== joint 优先 KF8
  group('joint MOBI/KF8：优先解析 KF8 半边，KF8 坏了回落到 MOBI6', () {
    test('libmobi-joint-ncx：读到的是 KF8 半边（3 段骨架，不是 MOBI6 的 4 章）', () {
      final bytes = _birthBytes(_jointNcx);
      final p = mobiKf8Probe(bytes);
      expect(p['ok'], isTrue);
      expect(
        p['joint'],
        isTrue,
        reason: 'record 0 是 MOBI6 头 + EXTH 121 → joint',
      );
      expect(p['kf8Start'], 12, reason: 'KF8 record 0 在 joint 记录表的第 12 条');
      expect(p['parts'], 3);

      final r = parseBook(BookFormat.mobi, bytes);
      expect(r.ok, isTrue);
      // **承重**：KF8 半边是 3 段；同一文件的 MOBI6 半边是 4 章。
      // 若把"joint 优先 KF8"退回 MOBI6，这里立刻变 4 → 红。
      expect(r.content.chapters, hasLength(3));
      expect(r.content.chapters.map((c) => c.title).toList(), [
        'Test chapter 1',
        'Test chapter 2',
        'Test subchapter 2-1',
      ]);
      expect(r.content.chapters[2].html, contains('Test subchapter 2-2'));
      // MOBI6 半边没有 NCX（toc=0）；KF8 半边有 4 条 NCX 目录。
      expect(r.content.toc, hasLength(4));
    }, skip: _missing(_jointNcx));

    test('joint 的 KF8 半边损坏 → 回落 MOBI6，不崩、不吐半截', () {
      final bytes = _birthBytes(_jointNcx);
      final rec0 = _kf8Rec0(bytes);
      // skeleton 索引记录号（KF8 头 0xFC，相对 KF8 record 0）→ 绝对记录号
      final skel =
          _u32(bytes, rec0 + 0xFC) + (mobiKf8Probe(bytes)['kf8Start'] as int);
      final at = _recOffset(bytes, skel);
      expect(String.fromCharCodes(bytes.sublist(at, at + 4)), 'INDX');
      bytes[at] = 0x58; // 'INDX' → 'XXXX'
      bytes[at + 1] = 0x58;

      // KF8 半边现在明确报错……
      final p = mobiKf8Probe(bytes);
      expect(p['ok'], isFalse);
      expect('${p['error']}', contains('skeleton'));

      // ……但整本书照 MOBI6 半边读出，不崩。
      final r = parseBook(BookFormat.mobi, bytes);
      expect(r.ok, isTrue);
      expect(r.content.chapters, hasLength(4), reason: 'MOBI6 半边是 4 章');
      expect(r.content.chapters[0].title, 'Test chapter 1');
      expect(r.content.chapters[0].html, contains('Test page 1'));
      expect(r.content.toc, isEmpty, reason: 'MOBI6 半边没有 NCX');
    }, skip: _missing(_jointNcx));

    test(
      'joint KF8 重组逐字节等于 KindleUnpack v0.83 oracle',
      () {
        for (final path in _oracle.keys) {
          final want = _oracle[path]!;
          final parts = mobiKf8Parts(_birthBytes(path));
          expect(parts, hasLength(want.parts), reason: '$path 段数');
          for (var i = 0; i < parts.length; i++) {
            expect(
              _sha256(parts[i]),
              want.sha[i],
              reason: '$path 第 $i 段 sha256',
            );
          }
          expect(
            _sha256([for (final p in parts) ...p]),
            want.concat,
            reason: '$path 拼接 sha256',
          );
          final probe = mobiKf8Probe(_birthBytes(path));
          expect('${probe['assembledBytes']}', '${want.bytes}');
        }
      },
      skip:
          _missing(_jointNcx) ??
          _missing(_jointMultimedia) ??
          _missing(_jointUnicode),
    );

    test('纯 MOBI6（无 EXTH 121）行为零回归：不误判成 KF8', () {
      final bytes = _birthBytes(_pureMobi6);
      final h = mobiHeaderProbe(bytes);
      expect(h['version'], 6);
      expect(h['kf8Boundary'], 0);
      expect(mobiKf8Probe(bytes)['ok'], isFalse, reason: '纯 MOBI6 没有 KF8 半边');
      final r = parseBook(BookFormat.mobi, bytes);
      expect(r.ok, isTrue);
      expect(r.content.title, "Alice's Adventures in Wonderland");
    }, skip: _missing(_pureMobi6));
  });

  // ======================================================== NCX / guide → toc
  group('KF8 目录：NCX(0xF4) → BookContent.toc（层级保留）+ guide(0x104) 兜底', () {
    test('真实 joint 样本的 NCX：条目数 / 标题 / 层级 / 落点段号', () {
      final t = mobiTocProbe(_birthBytes(_jointNcx));
      expect(t['ok'], isTrue);
      expect(t['source'], 'ncx');
      expect(t['count'], 4);
      expect(t['entries'], [
        {'title': 'Test chapter 1', 'chapterIndex': 0, 'depth': 0},
        {'title': 'Test chapter 2', 'chapterIndex': 1, 'depth': 0},
        {'title': 'Test subchapter 2-1', 'chapterIndex': 2, 'depth': 1},
        {'title': 'Test subchapter 2-2', 'chapterIndex': 2, 'depth': 1},
      ]);

      // 同一条路径经 `parseBook` 落在 `BookContent.toc` 上，且**层级别拍平**。
      final r = parseBook(BookFormat.mobi, _birthBytes(_jointNcx));
      expect(r.content.toc.map((e) => e.depth).toList(), [0, 0, 1, 1]);
      expect(
        r.content.toc.where((e) => e.depth == 1).map((e) => e.title).toList(),
        ['Test subchapter 2-1', 'Test subchapter 2-2'],
      );
      expect(r.content.toc[3].chapterIndex, 2);
    }, skip: _missing(_jointNcx));

    test('真实纯 KF8 样本的 NCX：16 条、标题与 chapterIndex 精确', () {
      final r = parseBook(BookFormat.azw3, _birthBytes(_pureKf8));
      expect(r.content.chapters, hasLength(19));
      expect(r.content.toc, hasLength(16));
      expect(r.content.toc.first.title, 'Alice’s Adventures in Wonderland');
      final hop = r.content.toc.firstWhere(
        (e) => e.title == 'CHAPTER I. Down the Rabbit-Hole',
      );
      expect(hop.chapterIndex, 4);
      expect(hop.depth, 0);
      expect(r.content.toc.last.title, 'THE FULL PROJECT GUTENBERG™ LICENSE');
    }, skip: _missing(_pureKf8));

    test('NCX 缺失 → guide 兜底；NCX/guide 都没有 → 目录为空且不崩', () {
      // 用真实 joint 样本（multimedia）把 KF8 头的 NCX 指针清零，模拟"没有 NCX"。
      final bytes = _birthBytes(_jointMultimedia);
      final rec0 = _kf8Rec0(bytes);
      expect(_u32(bytes, rec0 + 0xF4) != 0xFFFFFFFF, isTrue);
      _put32(bytes, rec0 + 0xF4, 0xFFFFFFFF);
      final g = mobiTocProbe(bytes);
      expect(g['ok'], isTrue);
      expect(g['source'], 'guide', reason: 'NCX 没了就用 guide');
      expect(g['count'], 1);
      expect(g['entries'], [
        {'title': 'start', 'chapterIndex': 0, 'depth': 0},
      ]);
      final r = parseBook(BookFormat.mobi, bytes);
      expect(r.ok, isTrue);
      expect(r.content.toc, hasLength(1));
      expect(r.content.toc.single.chapterIndex, 0);

      // 再把 guide 指针也清零：两条路都没有 → 空目录，但正文照读。
      _put32(bytes, rec0 + 0x104, 0xFFFFFFFF);
      final none = mobiTocProbe(bytes);
      expect(none['ok'], isTrue);
      expect(none['source'], 'none');
      expect(none['count'], 0);
      final r2 = parseBook(BookFormat.mobi, bytes);
      expect(r2.ok, isTrue);
      expect(r2.content.toc, isEmpty);
      expect(r2.content.chapters, hasLength(2));
    }, skip: _missing(_jointMultimedia));

    test('NCX 记录损坏（magic 坏）→ 目录退化，正文照读不崩', () {
      final bytes = _birthBytes(_jointMultimedia);
      final rec0 = _kf8Rec0(bytes);
      final start = mobiKf8Probe(bytes)['kf8Start'] as int;
      final ncxRec = _u32(bytes, rec0 + 0xF4) + start;
      final at = _recOffset(bytes, ncxRec);
      expect(String.fromCharCodes(bytes.sublist(at, at + 4)), 'INDX');
      bytes[at] = 0x58; // 'INDX' → 'XXXX'
      bytes[at + 1] = 0x58;
      final t = mobiTocProbe(bytes);
      expect(t['ok'], isTrue, reason: '坏目录不能让整本书解析失败');
      expect(t['source'], 'guide', reason: 'NCX 坏了 → 退到 guide');
      final r = parseBook(BookFormat.mobi, bytes);
      expect(r.ok, isTrue);
      expect(r.content.chapters, hasLength(2));
    }, skip: _missing(_jointMultimedia));
  });
}
