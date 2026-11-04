// **真实 RAR 样本**的端到端回归（libarchive 官方测试数据，BSD 许可）。
//
// 为什么单独一个文件：这些样本**不提交进仓库**（用户明确要求）。它们放在
// `/tmp/rar-samples/`（`test_read_format_rar*.rar`）、`/tmp/ebook-samples/real.rar`
// （RAR 2.0 存储包）；**存在就跑，不存在就 skip**（skip 原因写在测试名里，不会
// 假装通过）。期望值来自三方独立证据：
//   * `test_read_format_rar3_lowdist_reset`：**libarchive master 的测试源码里
//     逐字节写死的 expected[]**（本地 bsdtar 3.7.4 反而是错的那一版，会给全 0）；
//   * 其余样本：libarchive 的 `bsdtar`（与样本同源）解出来的字节 + sha256；
//   * 加密 / 坏样本：libarchive 测试明确要求"必须失败、不许崩"。
//
// 手动跑真实样本的完整对照：`dart run tool/rar_real_verify.dart`。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/files/rar_archive.dart';

const _realDir = '/tmp/rar-samples';
const _ebookDir = '/tmp/ebook-samples';

File? _sample(String name, {String dir = _realDir}) {
  final f = File('$dir/$name');
  return f.existsSync() ? f : null;
}

Uint8List _bytes(File f) => f.readAsBytesSync();

/// 期望的 CRC32 来自 oracle（libarchive/unrar）解出的字节，用库自带的实现算即可
/// （**不引三方依赖**：这个值本身就是独立证据，不是自比自证）。
String _crc(Uint8List data) => rarCrc32(data).toRadixString(16).padLeft(8, '0');

int _len(Uint8List data) => data.length;

/// 样本存在就正常跑，不存在就 skip（把原因写清楚，绝不"静默通过"）
Object? _skipUnless(String name, {String dir = _realDir}) =>
    _sample(name, dir: dir) == null ? '真实样本 $dir/$name 不存在（不提交进仓库）' : null;

void main() {
  group('真实样本：libarchive 官方 RAR3/RAR5 测试数据', () {
    test('rar3_lowdist_reset：与 libarchive 测试源码里写死的 expected 逐字节一致', () {
      // 这条样本专门测 RAR3 的"低距离（lowdist）在换表后要重置"。
      // 期望值直接抄自 libarchive master：
      //   libarchive/test/test_read_format_rar.c → test_read_format_rar3_lowdist_reset
      final expected = Uint8List.fromList([
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, //
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
        0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
        0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0d, 0x0e,
        0x0f, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e,
        0x2f, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36,
      ]);
      final f = _sample('test_read_format_rar3_lowdist_reset.rar')!;
      final a = RarArchive.open(_bytes(f));
      final out = a.extract();
      expect(out.keys, ['lowdist-reset.bin']);
      expect(out['lowdist-reset.bin'], expected);
      expect(out['lowdist-reset.bin']!.length, 64);
    }, skip: _skipUnless('test_read_format_rar3_lowdist_reset.rar'));

    test('rar5_compressed：RAR5 压缩流解出的字节与 libarchive 一致', () {
      final f = _sample('test_read_format_rar5_compressed.rar')!;
      final out = RarArchive.open(_bytes(f)).extract();
      expect(out.keys, ['test.bin']);
      expect(_len(out['test.bin']!), 1200);
      // 头 16 字节（文件本身的固定模式）+ 整段 CRC32
      expect(out['test.bin']!.sublist(0, 16), [
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        5,
        0,
        0,
        0,
      ]);
      expect(_crc(out['test.bin']!), '7cca70cd');
    }, skip: _skipUnless('test_read_format_rar5_compressed.rar'));

    test('rar5_solid：7 个固实文件全部与 libarchive 一致（共享窗口）', () {
      final f = _sample('test_read_format_rar5_solid.rar')!;
      final a = RarArchive.open(_bytes(f));
      expect(a.isSolid, isTrue);
      final out = a.extract();
      const expectCrc = {
        'test.bin': (1200, '7cca70cd'),
        'test1.bin': (4096, '7e13b2c6'),
        'test2.bin': (4096, 'f166afcb'),
        'test3.bin': (4096, '9fb123d9'),
        'test4.bin': (4096, '10c43ed4'),
        'test5.bin': (4096, 'b9d155f2'),
        'test6.bin': (4096, '36a448ff'),
      };
      expect(out.keys, expectCrc.keys);
      for (final e in expectCrc.entries) {
        expect(_len(out[e.key]!), e.value.$1, reason: '${e.key} 长度');
        expect(_crc(out[e.key]!), e.value.$2, reason: '${e.key} CRC');
      }
    }, skip: _skipUnless('test_read_format_rar5_solid.rar'));

    test('rar5_arm：ARM 过滤器（x86/ARM 反变换）解出 90808 B 且哈希一致', () {
      final f = _sample('test_read_format_rar5_arm.rar')!;
      final out = RarArchive.open(_bytes(f)).extract();
      expect(out.keys, ['elf-Linux-ARMv7-ls']);
      expect(_len(out['elf-Linux-ARMv7-ls']!), 90808);
      // ELF 魔数：ARM 过滤器解出来的必须是能认的 ELF
      expect(out['elf-Linux-ARMv7-ls']!.sublist(0, 4), [
        0x7f,
        0x45,
        0x4c,
        0x46,
      ]);
      expect(_crc(out['elf-Linux-ARMv7-ls']!), '886f91eb');
    }, skip: _skipUnless('test_read_format_rar5_arm.rar'));

    test('rar5_blake2：只有 BLAKE2 校验、没有 CRC32 的包也能解', () {
      final f = _sample('test_read_format_rar5_blake2.rar')!;
      final out = RarArchive.open(_bytes(f)).extract();
      expect(out.keys, ['cebula.txt']);
      expect(_len(out['cebula.txt']!), 814);
      expect(String.fromCharCodes(out['cebula.txt']!.sublist(0, 6)), 'Cebula');
      expect(_crc(out['cebula.txt']!), '7e5ec49e');
    }, skip: _skipUnless('test_read_format_rar5_blake2.rar'));
  });

  group('真实样本：RAR 2.0（存储型）—— 版本号不该一刀切', () {
    test('real.rar：RAR 2.0 + 全存储，3 个文件全部解出且反斜杠路径归一化', () {
      final f = _sample('real.rar', dir: _ebookDir)!;
      final bytes = _bytes(f);
      expect(RarArchive.isRar(bytes), isTrue);
      final a = RarArchive.open(bytes);
      expect(a.version, 4);
      // `testdir\test.txt`（Windows 打包）必须归一化成 `testdir/test.txt`
      expect(
        [for (final e in a.entries) e.name],
        ['test.txt', 'testlink', 'testdir/test.txt', 'testdir', 'testemptydir'],
      );
      final out = a.extract();
      expect(out.keys, ['test.txt', 'testlink', 'testdir/test.txt']);
      expect(String.fromCharCodes(out['test.txt']!), 'test text document\r\n');
      expect(_crc(out['test.txt']!), 'bec8a242');
      expect(_crc(out['testlink']!), 'b6c9447b');
      // RAR 里存的软链接内容就是目标路径字符串
      expect(String.fromCharCodes(out['testlink']!), 'test.txt');
      expect(out['testdir/test.txt'], out['test.txt']);
    }, skip: _skipUnless('real.rar', dir: _ebookDir));
  });

  group('真实样本：加密包必须给明确错误（不许乱码/半截）', () {
    const encrypted = [
      'test_read_format_rar4_encrypted.rar',
      'test_read_format_rar4_encrypted_filenames.rar',
      'test_read_format_rar4_solid_encrypted.rar',
      'test_read_format_rar4_solid_encrypted_filenames.rar',
      'test_read_format_rar5_solid_encrypted.rar',
      'test_read_format_rar5_solid_encrypted_filenames.rar',
    ];
    for (final name in encrypted) {
      test('$name：RarUnsupportedException 且文案点明"密码（加密）"', () {
        final f = _sample(name)!;
        final bytes = _bytes(f);
        // 档头加密的包在 open 就报错；文件加密的在 extract 报错。两条都要明确。
        Object? err;
        try {
          RarArchive.open(bytes).extract();
        } catch (e) {
          err = e;
        }
        expect(err, isA<RarUnsupportedException>(), reason: name);
        expect((err! as RarUnsupportedException).message, contains('密码'));
        expect((err as RarUnsupportedException).message, contains('加密'));
      }, skip: _skipUnless(name));
    }
  });

  group('真实样本：坏包必须明确报错，不许崩', () {
    const bad = [
      'test_read_format_rar5_bad_tables.rar',
      'test_read_format_rar5_bad_window_sz_in_mltarc_file.rar',
      'test_read_format_rar5_arm_filter_on_window_boundary.rar',
    ];
    for (final name in bad) {
      test('$name：抛 RarFormatException / RarUnsupportedException，不抛别的', () {
        // libarchive 的原话：文件是坏的，函数"应该返回失败，且不许 SIGSEGV"。
        final f = _sample(name)!;
        final bytes = _bytes(f);
        Object? err;
        try {
          final a = RarArchive.open(bytes);
          // bad_tables 的档头是合法的、坏的是压缩块里的码表 → open 可能成功，
          // 但读数据必须失败。
          a.extract();
        } catch (e) {
          err = e;
        }
        expect(
          err,
          anyOf(isA<RarFormatException>(), isA<RarUnsupportedException>()),
          reason: name,
        );
      }, skip: _skipUnless(name));
    }
  });
}
