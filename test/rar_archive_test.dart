// RAR（CBR 的容器）**自研纯 Dart 读取器**的离线测试。
//
// 素材来源（关键约束：不下载任何真实漫画）：
//   * **压缩/固实/加密/多卷**夹具由 rarlab 官方 `rar` 命令行**本地**生成
//     （自造 txt + 自造 8×8 PNG），以 base64 常量固化在
//     `test/support/rar_fixture_data.dart` —— 相当于拿**独立参考实现**
//     当"期望字节"，自研解码器解出来必须逐字节对上，不是自比自证；
//   * **store** 夹具由 `tool/make_rar_fixture.dart`（自研最小写入器）现场生成，
//     中文文件名走 RAR3 的 Unicode 文件名编码，还额外用官方 `unrar` 交叉验过
//     （输出名字/大小完全一致，见 `docs/device-verification.md`）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/files/rar_archive.dart';

import '../tool/make_rar_fixture.dart';
import 'support/rar_fixture_data.dart';

Uint8List _b(String b64) => rarFixtureBytes(b64);

/// 自研写入器的 store 夹具（多文件 + 中文名 + 嵌套目录）
Uint8List _mine4() => buildRar4Fixture([
  RarFixtureEntry('readme.txt', Uint8List.fromList(utf8.encode(rarReadmeText))),
  RarFixtureEntry('漫画/', Uint8List(0)),
  RarFixtureEntry(
    '漫画/第01话/p1.png',
    Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]),
  ),
  RarFixtureEntry('中文说明.txt', Uint8List.fromList(utf8.encode(rarChineseText))),
]);

Uint8List _mine5() => buildRar5Fixture([
  RarFixtureEntry('readme.txt', Uint8List.fromList(utf8.encode(rarReadmeText))),
  RarFixtureEntry('漫画/', Uint8List(0)),
  RarFixtureEntry(
    '漫画/第01话/p1.png',
    Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]),
  ),
  RarFixtureEntry('中文说明.txt', Uint8List.fromList(utf8.encode(rarChineseText))),
]);

/// 六个"官方 rar 夹具"的 (名字, base64)
const Map<String, String> _official = {
  'rar4_store': kRar4Store,
  'rar4_comp': kRar4Comp,
  'rar4_solid': kRar4Solid,
  'rar5_store': kRar5Store,
  'rar5_comp': kRar5Comp,
  'rar5_solid': kRar5Solid,
};

void main() {
  group('签名识别', () {
    test('RAR4 / RAR5 签名与版本', () {
      expect(RarArchive.isRar(_b(kRar4Store)), isTrue);
      expect(RarArchive.isRar(_b(kRar5Store)), isTrue);
      expect(RarArchive.open(_b(kRar4Store)).version, 4);
      expect(RarArchive.open(_b(kRar5Store)).version, 5);
    });

    test('非 RAR / 空文件', () {
      expect(RarArchive.isRar(const <int>[]), isFalse);
      expect(RarArchive.isRar(utf8.encode('普通文本')), isFalse);
      expect(RarArchive.isRar(utf8.encode('PK\x03\x04zip')), isFalse);
      expect(
        () => RarArchive.open(utf8.encode('nope')),
        throwsA(isA<RarFormatException>()),
      );
    });

    test('自解压 exe：签名前面有可执行体也能认出来', () {
      final sfx = <int>[...List<int>.filled(256, 0x4D), ..._b(kRar4Store)];
      expect(RarArchive.isRar(sfx), isTrue);
      expect(RarArchive.open(sfx).entries, isNotEmpty);
    });
  });

  group('CRC32 工具（独立已知向量）', () {
    test('标准 check 值 0xCBF43926', () {
      expect(rarCrc32(utf8.encode('123456789')), 0xCBF43926);
      expect(rarCrc32(const <int>[]), 0);
    });
  });

  group('自研写入器的 store 包（RAR4 / RAR5）', () {
    for (final (label, build) in <(String, Uint8List Function())>[
      ('RAR4', _mine4),
      ('RAR5', _mine5),
    ]) {
      test('$label：条目名（含中文）/ 目录 / 大小 / CRC', () {
        final a = RarArchive.open(build());
        expect(a.isSolid, isFalse);
        expect(
          [for (final e in a.entries) e.name],
          ['readme.txt', '漫画/', '漫画/第01话/p1.png', '中文说明.txt'],
        );
        final dir = a.entries[1];
        expect(dir.isDir, isTrue);
        final png = a.entries[2];
        expect(png.unpackedSize, 8);
        expect(png.crc32, rarCrc32(const [0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]));
      });

      test('$label：解出来的字节逐字节正确', () {
        final a = RarArchive.open(build());
        final out = a.extract();
        expect(out.keys, ['readme.txt', '漫画/第01话/p1.png', '中文说明.txt']);
        expect(utf8.decode(out['readme.txt']!), rarReadmeText);
        expect(utf8.decode(out['中文说明.txt']!), rarChineseText);
        expect(out['漫画/第01话/p1.png'], [0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);
      });

      test('$label：only 只保留要的条目（非固实可以跳过其它）', () {
        final a = RarArchive.open(build());
        final out = a.extract(only: {'readme.txt'});
        expect(out.keys, ['readme.txt']);
      });
    }
  });

  group('官方 rar 夹具：RAR4 / RAR5 × store / 压缩 / 固实', () {
    for (final entry in _official.entries) {
      test('${entry.key}：文件数与名字', () {
        final a = RarArchive.open(_b(entry.value));
        final files = [
          for (final e in a.entries)
            if (!e.isDir) e.name,
        ];
        expect(files, containsAll(['readme.txt', '中文说明.txt']));
        expect(files, contains('漫画/第01话/p10.png'));
        expect(a.isSolid, entry.key.contains('solid'));
      });

      test('${entry.key}：解压结果与**独立文本**逐字节一致', () {
        final a = RarArchive.open(_b(entry.value));
        final out = a.extract();
        expect(utf8.decode(out['readme.txt']!), rarReadmeText);
        expect(utf8.decode(out['中文说明.txt']!), rarChineseText);
        for (final p in ['漫画/第01话/p1.png', '漫画/第01话/p10.png']) {
          final bytes = out[p]!;
          expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
          expect(bytes.length, greaterThan(50));
        }
        // 三页颜色不同 → 字节必须不同（顺序/错位立刻暴露）
        expect(out['漫画/第01话/p1.png'], isNot(out['漫画/第01话/p2.png']));
        expect(out['漫画/第01话/p10.png'], isNot(out['漫画/第01话/p2.png']));
      });
    }

    test('六个包的文本与图片内容完全一致（压缩/固实只是编码不同）', () {
      final texts = <String>{};
      final pages = <String>{};
      for (final b64 in _official.values) {
        final out = RarArchive.open(_b(b64)).extract();
        texts.add(utf8.decode(out['readme.txt']!));
        pages.add(base64Encode(out['漫画/第01话/p1.png']!));
      }
      expect(texts, hasLength(1));
      expect(pages, hasLength(1));
    });
  });

  group('能力边界：明确报错', () {
    test('加密包（文件加密）', () {
      for (final b64 in [kRar4Enc, kRar5Enc]) {
        final a = RarArchive.open(_b(b64));
        expect(a.entries.single.encrypted, isTrue);
        expect(
          () => a.extract(),
          throwsA(
            isA<RarUnsupportedException>().having(
              (e) => e.message,
              'message',
              contains('密码'),
            ),
          ),
        );
      }
    });

    test('多卷包（任意一卷）', () {
      // 多卷的每一卷都应该给"多卷"的明确错误
      for (final b64 in [kRar4VolPart1]) {
        expect(
          () => RarArchive.open(_b(b64)),
          throwsA(
            isA<RarUnsupportedException>().having(
              (e) => e.message,
              'message',
              contains('多卷'),
            ),
          ),
        );
      }
    });

    test('RAR 1.5/2.0 压缩（unpackver 26）→ 明确报"压缩流未实现"', () {
      final bytes = buildRar4Fixture(
        [RarFixtureEntry('a.txt', Uint8List.fromList(utf8.encode('hello')))],
        method: 0x33,
        unpackVersion: 26,
      );
      expect(
        () => RarArchive.open(bytes),
        throwsA(
          isA<RarUnsupportedException>().having(
            (e) => e.message,
            'message',
            allOf(contains('1.5/2.0'), contains('压缩流'), contains('存储型')),
          ),
        ),
      );
    });

    test('未知解码器版本 → 明确报错', () {
      final bytes = buildRar4Fixture(
        [RarFixtureEntry('a.txt', Uint8List.fromList(utf8.encode('hello')))],
        method: 0x33,
        unpackVersion: 99,
      );
      expect(
        () => RarArchive.open(bytes),
        throwsA(isA<RarUnsupportedException>()),
      );
    });

    test('RAR5 的 algorithm 1（非 v5 兼容，RAR 7）→ 明确报错', () {
      final bytes = buildRar5Fixture([
        RarFixtureEntry('a.txt', Uint8List.fromList(utf8.encode('hello'))),
      ], compressionInfo: 0x01 | (1 << 7)); // algorithm=1, method=1
      expect(
        () => RarArchive.open(bytes),
        throwsA(
          isA<RarUnsupportedException>().having(
            (e) => e.message,
            'message',
            contains('RAR 7'),
          ),
        ),
      );
    });
  });

  group('坏文件：明确报错，不吐半截数据', () {
    test('截断：数据区不够', () {
      expect(
        () => RarArchive.open(_b(kRar4Trunc)).extract(),
        throwsA(
          isA<RarFormatException>().having(
            (e) => e.message,
            'message',
            anyOf(contains('截断'), contains('CRC')),
          ),
        ),
      );
    });

    test('数据被改坏：CRC 校验失败', () {
      expect(
        () => RarArchive.open(_b(kRar5Corrupt)).extract(),
        throwsA(
          isA<RarFormatException>().having(
            (e) => e.message,
            'message',
            contains('CRC 校验失败'),
          ),
        ),
      );
    });

    test('块头 CRC 被改坏：解析期就拒绝', () {
      final bytes = _b(kRar4Store);
      final bad = Uint8List.fromList(bytes);
      bad[20] ^= 0xFF; // 落在块头里
      expect(
        () => RarArchive.open(bad),
        throwsA(
          isA<RarFormatException>().having(
            (e) => e.message,
            'message',
            contains('CRC'),
          ),
        ),
      );
    });
  });

  group('固实包必须按顺序解压', () {
    test('只取图片也要解全部（后面的文件依赖前面字典）', () {
      // 固实包里如果跳过前面的文本文件，字典/码表状态就断了；
      // 解析器必须自己处理，且结果仍然正确。
      final a = RarArchive.open(_b(kRar4Solid));
      final out = a.extract(only: {'漫画/第01话/p10.png'});
      expect(out.keys, ['漫画/第01话/p10.png']);
      final full = RarArchive.open(_b(kRar4Solid)).extract();
      expect(out['漫画/第01话/p10.png'], full['漫画/第01话/p10.png']);
    });
  });

  group('存储型条目不受 UNP_VER 限制（RAR 1.5 / 2.0 的包也能读）', () {
    const text = 'stored bytes across versions\r\n';

    for (final ver in [15, 20, 26, 29]) {
      test('RAR4 store + unpackver $ver：照样按存储解出', () {
        // 关键回归：版本白名单只能管压缩条目。METHOD=0x30 的条目在 RAR 1.5/2.0
        // 的包里也会出现（`rar -ma2` 只存储打的包），以前会被整包误判"不支持"。
        final bytes = buildRar4Fixture([
          RarFixtureEntry('a.txt', Uint8List.fromList(utf8.encode(text))),
        ], unpackVersion: ver);
        final a = RarArchive.open(bytes);
        expect(a.entries.single.unpackedSize, text.length);
        expect(utf8.decode(a.extract()['a.txt']!), text);
      });
    }

    test('RAR4 store + UNP_SIZE=0xFFFFFFFF（老包写"大小未知"）：按 PACK_SIZE 解出', () {
      final bytes = buildRar4Fixture(
        [RarFixtureEntry('b.txt', Uint8List.fromList(utf8.encode(text)))],
        unpackVersion: 20,
        unknownUnpSize: true,
      );
      final a = RarArchive.open(bytes);
      expect(a.entries.single.unpackedSize, text.length);
      expect(utf8.decode(a.extract()['b.txt']!), text);
    });

    test('RAR5 store + FILE_SIZE_UNKNOWN：按 PACK_SIZE 解出', () {
      final bytes = buildRar5Fixture([
        RarFixtureEntry('c.txt', Uint8List.fromList(utf8.encode(text))),
      ], unknownUnpSize: true);
      expect(utf8.decode(RarArchive.open(bytes).extract()['c.txt']!), text);
    });

    test('RAR 1.5/2.0 **压缩**条目：明确说"压缩流未实现"，与坏文件分开', () {
      final bytes = buildRar4Fixture(
        [RarFixtureEntry('a.txt', Uint8List.fromList(utf8.encode(text)))],
        unpackVersion: 20,
        method: 0x35,
      );
      expect(
        () => RarArchive.open(bytes),
        throwsA(
          isA<RarUnsupportedException>().having(
            (e) => e.message,
            'message',
            allOf(contains('压缩流'), contains('存储型')),
          ),
        ),
      );
    });
  });

  group('归档内路径分隔符', () {
    for (final (label, build)
        in <(String, Uint8List Function(List<RarFixtureEntry>))>[
          ('RAR4', buildRar4Fixture),
          ('RAR5', buildRar5Fixture),
        ]) {
      test('$label：Windows 的 `\\` 归一化成 `/`', () {
        final bytes = build([
          RarFixtureEntry(
            r'dir\pic.png',
            Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47, 9]),
          ),
        ]);
        final a = RarArchive.open(bytes);
        expect(a.entries.single.name, 'dir/pic.png');
        expect(a.extract().keys, ['dir/pic.png']);
      });
    }
  });
}
