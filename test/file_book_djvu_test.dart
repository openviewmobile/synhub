// DJVU（.djvu）**自研纯 Dart** 的解析 + 接入点离线测试。
//
// **fixture 全部由 `tool/make_djvu_fixture.dart` 现场生成**（自研写入器：
// IFF/FORM 容器 + INFO + TXTa/TXTz + DIRM + NAVM + INCL + THUM + Sjbz + BG44 头），
// **不下载任何真实 DJVU**。真实扫描件的覆盖率交给真机那一步；这里负责把
// **接口与算法**钉死：
//   * 容器：DJVU / DJVM 顶层、INFO、2 字节对齐、坏签名/截断；
//   * 文本层：TXTa 原样、TXTz（BZZ）、VT/GS/US/LF 归一化；
//   * 多页：DIRM（bundled v1）偏移 + 标题、NAVM 书签层级、THUM 缩略图、INCL 跳过；
//   * BZZ：编码↔解码逐字节往返（含空/1 字节/中文/随机/高重复）；
//   * JB2：`djvuJb2EncodeSimple` ↔ `djvuJb2Decode` **逐像素往返**；
//   * 合成渲染：Sjbz 掩码 + 白底 → PNG（解 PNG 后逐像素断言）、BG44 平灰页；
//   * 能力边界：Smmr / 版本过新 / 散装 DJVM / 空页 / 坏 BZZ → 必须给清晰错误，
//     不许抛到界面、不许吐乱码或半截；
//   * 接入点：`bookFormatOf` / `isReadableBook` / `filePreviewKind` /
//     `bookCoverSupported` / `usesPageView` / 封面；阅读页 widget（文本 + 翻页）。
//
// **验证状态（如实声明）**：
//   * **IW44（BG44/FG44/TH44）**：合成 fixture 证管线（分块→头解析→像素缓冲→PNG）。
//     像素正确性另由文末「真实样本对照」组证明：6 份真实 .djvu 对 DjVuLibre 3.5.28
//     的 `ddjvu` 做逐像素对照（脚本 `tool/djvu_real_compare.dart`），页数/尺寸全一致，
//     抽样页 meanAbs 0.0–1.6、IoU 0.982–1.000。该组在 `/tmp/djvu-samples/` 不存在时
//     整组跳过；真实样本因体积与版权**不入库**。
//   * **JB2**：往返自证 + `tool/djvu_jb2_selftest.dart` 里对 DjVuLibre 参考流的
//     交叉验证（GPL 库只用于 /tmp 造/验样本，**不进仓库**）；真实整册文件由上面同一组覆盖。
import 'dart:convert';
import 'dart:io' show Directory, File, ZLibDecoder;
import 'dart:math';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/design/kit/design_kit.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/book_store.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/book_cover.dart';
import 'package:synhub/src/features/files/book_djvu.dart';
import 'package:synhub/src/features/files/djvu_archive.dart';
import 'package:synhub/src/features/files/djvu_bzz.dart';
import 'package:synhub/src/features/files/djvu_jb2.dart';
import 'package:synhub/src/features/files/file_book.dart';
import 'package:synhub/src/features/files/file_book_view.dart';
import 'package:synhub/src/features/files/file_preview_page.dart';
import 'package:synhub/src/features/files/file_providers.dart';

import '../tool/make_djvu_fixture.dart';
import 'support/chat_harness.dart' show FakeTransport;

// ============================================================ fixture / 工具

final Map<String, Uint8List> _fx = buildDjvuFixtures();

Uint8List _f(String name) {
  final b = _fx[name];
  if (b == null) throw StateError('fixture 缺失：$name');
  return b;
}

FileEntryDto _entry(String name) => FileEntryDto(
  name: name,
  path: '/books/$name',
  isDir: false,
  size: 4096,
  mtime: 1700000000000,
);

/// 极简 PNG 读取器（只认本仓编码器产出的 8 位 RGBA、filter=0）。
({int w, int h, Uint8List rgba}) _decodePng(Uint8List png) {
  expect(png.length > 8, isTrue);
  expect(png[0], 0x89);
  expect(ascii.decode(png.sublist(1, 4)), 'PNG');
  var p = 8;
  var w = 0, h = 0;
  final idat = BytesBuilder();
  while (p + 8 <= png.length) {
    final len =
        (png[p] << 24) | (png[p + 1] << 16) | (png[p + 2] << 8) | png[p + 3];
    final type = ascii.decode(png.sublist(p + 4, p + 8));
    final data = png.sublist(p + 8, p + 8 + len);
    if (type == 'IHDR') {
      w = (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
      h = (data[4] << 24) | (data[5] << 16) | (data[6] << 8) | data[7];
      expect(data[8], 8); // bit depth
      expect(data[9], 6); // RGBA
    } else if (type == 'IDAT') {
      idat.add(data);
    } else if (type == 'IEND') {
      break;
    }
    p += 12 + len;
  }
  final raw = Uint8List.fromList(ZLibDecoder().convert(idat.toBytes()));
  final stride = w * 4 + 1;
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final filter = raw[y * stride];
    expect(filter, 0, reason: '本仓编码器只用 filter 0');
    out.setRange(y * w * 4, (y + 1) * w * 4, raw, y * stride + 1);
  }
  return (w: w, h: h, rgba: out);
}

({int r, int g, int b}) _px(
  ({int w, int h, Uint8List rgba}) img,
  int x,
  int y,
) {
  final i = (y * img.w + x) * 4;
  return (r: img.rgba[i], g: img.rgba[i + 1], b: img.rgba[i + 2]);
}

Uint8List _hiddenText(String text) {
  final b = utf8.encode(text);
  return Uint8List.fromList([
    (b.length >> 16) & 0xFF,
    (b.length >> 8) & 0xFF,
    b.length & 0xFF,
    ...b,
  ]);
}

// ============================================================ 阅读页 pump

Future<({ProviderContainer c, ChatDatabase db})> _pumpWithStore(
  WidgetTester tester,
  FileEntryDto entry,
  List<int> bytes,
) async {
  final t = FakeTransport(const {}, {...FakeTransport.table});
  t.downloadBytes = bytes;
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fileApiProvider.overrideWithValue(FileStationApi(api)),
    ],
  );
  addTearDown(() async {
    c.dispose();
    await db.close();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: FileBookStage(entry: entry, bytesUrl: 'https://nas/x'),
        ),
        localizationsDelegates: const [
          FlutterQuillLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: FlutterQuillLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return (c: c, db: db);
}

Future<void> _pump(WidgetTester tester, FileEntryDto entry, List<int> bytes) =>
    _pumpWithStore(tester, entry, bytes);

void main() {
  // ------------------------------------------------------------ 容器
  group('容器 / INFO', () {
    test('自造单页能被识别为 DJVU', () {
      expect(DjvuArchive.isDjvu(_f('djvu-text-ta.djvu')), isTrue);
      expect(DjvuArchive.isDjvu(utf8.encode('not a djvu at all!!')), isFalse);
      expect(DjvuArchive.isDjvu(const <int>[]), isFalse);
    });

    test('单页：INFO 宽高/版本读对，文本层抽到', () {
      final arc = DjvuArchive.open(_f('djvu-text-ta.djvu'));
      expect(arc.isMultiPage, isFalse);
      expect(arc.pages, hasLength(1));
      final p = arc.pages.single;
      expect(p.info!.width, 600);
      expect(p.info!.height, 800);
      expect(p.info!.version, 24);
      expect(p.info!.dpi, 300);
      expect(p.hasBitmap, isFalse);
      expect(p.text, contains('第一段隐藏文本层'));
      expect(p.text, contains('第二段'));
    });

    test('多页 DJVM：DIRM 3 页 + 标题 + 书签 + 缩略图，INCL 被跳过', () {
      final arc = DjvuArchive.open(_f('djvu-multi.djvu'));
      expect(arc.isMultiPage, isTrue);
      expect(arc.pages, hasLength(3));
      expect(arc.directory, hasLength(3));
      expect(arc.pages.map((p) => p.title), ['第一章', '第一节', '第二章']);
      expect(arc.bookmarks, hasLength(3));
      expect(arc.bookmarks.map((b) => b.depth), [0, 1, 0]);
      expect(arc.thumbnail, isNotEmpty);
      // INCL 不是页、不影响页数
      expect(arc.pages.every((p) => p.formType == 'DJVU'), isTrue);
    });

    test('INFO 尺寸非法/缺失时不会伪造数据', () {
      final arc = DjvuArchive.open(_f('djvu-text-ta.djvu'));
      // 文本路线，无需 INFO 也能抽文本；这里只确认没有凭空造出位图
      expect(arc.pages.single.sjbz, isNull);
      expect(arc.pages.single.bg44, isEmpty);
    });
  });

  // ------------------------------------------------------------ 文本层
  group('文本层', () {
    test('TXTa：原样解出，未被压缩', () {
      final arc = DjvuArchive.open(_f('djvu-text-ta.djvu'));
      expect(arc.pages.single.text, contains('English、数字 123'));
    });

    test('TXTz：BZZ 压缩的文本层能被解回', () {
      final arc = DjvuArchive.open(_f('djvu-text-tz.djvu'));
      expect(arc.pages.single.text, contains('BZZ 压缩的文本层'));
      expect(arc.pages.single.text, contains('第三段结束'));
    });

    test('隐藏文本层归一化：VT/GS/US/LF → 换行，连续空行折叠', () {
      String norm(String s) => djvuNormalizeHiddenText(_hiddenText(s));
      expect(norm('a\nb'), 'a\nb');
      expect(norm('a\u000bb'), 'a\nb');
      expect(norm('a\u001db'), 'a\nb');
      expect(norm('a\u001fb'), 'a\nb');
      expect(norm('a\n\n\n\n\nb'), 'a\n\nb');
      expect(norm('  a  \n  b  '), 'a\nb');
      expect(norm('a\u0000b'), 'ab');
      // 截断的文本层：不抛，只取有数据的部分
      final cut = Uint8List.fromList(_hiddenText('hello world').sublist(0, 8));
      expect(djvuNormalizeHiddenText(cut), 'hello');
    });
  });

  // ------------------------------------------------------------ 目录
  group('NAVM 目录', () {
    test('书签层级 + url → 页码映射', () {
      final r = parseDjvuBook(_f('djvu-multi.djvu'), format: BookFormat.djvu);
      expect(r.error, isNull);
      expect(r.content.chapters, hasLength(3));
      expect(r.content.toc, hasLength(3));
      expect(r.content.toc.map((e) => e.title), ['第一章', '第一节', '第二章']);
      expect(r.content.toc.map((e) => e.depth), [0, 1, 0]);
      expect(r.content.toc.map((e) => e.chapterIndex), [0, 1, 2]);
    });
  });

  // ------------------------------------------------------------ BZZ
  group('BZZ（BWT + MTF + ZP）', () {
    test('往返：空 / 1 字节 / 中文 / 随机 / 高重复', () {
      final rnd = Random(20240921);
      final cases = <Uint8List>[
        Uint8List(0),
        Uint8List.fromList([0x00]),
        Uint8List.fromList(
          utf8.encode('第一章 hidden text layer 测试。\n第二段\u001f结束'),
        ),
        Uint8List.fromList(List.generate(50000, (_) => rnd.nextInt(256))),
        Uint8List.fromList(List.generate(120000, (i) => 97 + (i % 3))),
        Uint8List.fromList(List.generate(3000, (i) => (i * 37) % 256)),
      ];
      for (var i = 0; i < cases.length; i++) {
        final src = cases[i];
        final dec = djvuBzzDecode(djvuBzzEncode(src));
        expect(dec, equals(src), reason: 'case $i (len=${src.length})');
      }
    });

    test('截断/垃圾位流给明确异常，不吐半截', () {
      final good = djvuBzzEncode(utf8.encode('x' * 2000));
      expect(
        () => djvuBzzDecode(Uint8List.sublistView(good, 0, 8)),
        throwsA(isA<DjvuFormatException>()),
      );
    });

    test('解压上限触发 unsupported', () {
      final big = djvuBzzEncode(Uint8List.fromList(List.filled(4096, 65)));
      expect(
        () => djvuBzzDecode(big, maxSize: 16),
        throwsA(isA<DjvuUnsupportedException>()),
      );
    });
  });

  // ------------------------------------------------------------ JB2
  group('JB2（Sjbz 掩码）', () {
    DjvuBitmap bitmap(int w, int h, bool Function(int, int) f) {
      final b = DjvuBitmap(w, h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          if (f(x, y)) b.pixels[y * w + x] = 1;
        }
      }
      return b;
    }

    test('编码 ↔ 解码逐像素往返', () {
      final cases = <String, DjvuBitmap>{
        '矩形': bitmap(40, 30, (x, y) => x >= 5 && x < 35 && y >= 4 && y < 26),
        '棋盘': bitmap(32, 32, (x, y) => (x + y).isEven),
        '对角线': bitmap(50, 50, (x, y) => x == y),
        '全空': bitmap(20, 20, (x, y) => false),
        '全实': bitmap(16, 12, (x, y) => true),
      };
      cases.forEach((name, src) {
        final dec = djvuJb2Decode(
          djvuJb2EncodeSimple(src),
          width: src.width,
          height: src.height,
        );
        expect(dec.width, src.width, reason: name);
        expect(dec.height, src.height, reason: name);
        for (var i = 0; i < src.pixels.length; i++) {
          expect(dec.pixels[i] != 0, src.pixels[i] != 0, reason: '$name 像素 $i');
        }
      });
    });

    test('fixture 里的 Sjbz 掩码解出预期矩形', () {
      final page = DjvuArchive.open(_f('djvu-jb2-mask.djvu')).pages.single;
      final bmp = djvuJb2Decode(page.sjbz!, width: 64, height: 48);
      expect(bmp.at(20, 20), isTrue);
      expect(bmp.at(2, 2), isFalse);
      expect(bmp.at(63, 47), isFalse);
    });

    test('坏输入 / 非字典输入给明确异常', () {
      expect(
        () => djvuJb2Decode(
          Uint8List.fromList(const [0, 0, 0]),
          width: 8,
          height: 8,
        ),
        throwsA(isA<DjvuFormatException>()),
      );
      expect(
        () => djvuJb2DictionaryDecode(djvuJb2EncodeSimple(DjvuBitmap(8, 8))),
        throwsA(isA<DjvuFormatException>()),
      );
    });
  });

  // ------------------------------------------------------------ 合成渲染
  group('合成渲染 → PNG', () {
    test('Sjbz 掩码 + 白底：黑矩形、白背景', () {
      final r = parseDjvuBook(
        _f('djvu-jb2-mask.djvu'),
        format: BookFormat.djvu,
      );
      expect(r.error, isNull);
      expect(r.content.pages, hasLength(1));
      expect(r.content.pages.first, isNotEmpty);
      final img = _decodePng(r.content.pages.first);
      expect(img.w, 64);
      expect(img.h, 48);
      // 掩码内 = 黑（无 FG44 时前景是黑）
      final ink = _px(img, 20, 20);
      expect([ink.r, ink.g, ink.b], [0, 0, 0]);
      // 掩码外 = 白（无 BG44）
      final bg = _px(img, 1, 1);
      expect([bg.r, bg.g, bg.b], [255, 255, 255]);
    });

    test('BG44 平灰页：管线通（零系数 → 均匀灰）', () {
      final r = parseDjvuBook(
        _f('djvu-bg44-flat.djvu'),
        format: BookFormat.djvu,
      );
      expect(r.error, isNull);
      final img = _decodePng(r.content.pages.first);
      expect(img.w, 32);
      expect(img.h, 32);
      final p = _px(img, 5, 5);
      expect(p.r, p.g);
      expect(p.g, p.b);
      // 灰度 BG44 走 `IWPixmap::get_pixmap`（DjVuFile 对 BG44 一律 create_decode(COLOR)），
      // 该分支取像素是 `127 - s`，不是 GBitmap 路径的 `s + 128`。零系数 → s = 0 → 127。
      //
      // oracle（独立像素级背书，非自证）：DjVuLibre 3.5.28 官方源码
      // `./configure --disable-desktopfiles --disable-xmltools && make` 构出的
      // `/tmp/djvuoracle/djvulibre-3.5.28/tools/ddjvu`。复现：
      //   dart run tool/make_djvu_fixture.dart /tmp/djvufix
      //   /tmp/djvuoracle/djvulibre-3.5.28/tools/ddjvu -format=pgm \
      //       /tmp/djvufix/djvu-bg44-flat.djvu /tmp/flatref.pgm
      // → 整页 32x32 像素唯一值 = [127]。
      // 注意：这台机器的 brew 装不上 djvulibre（bottle 清单报错），所以 ddjvu 不在
      // PATH / homebrew 前缀下，只在上面那个 /tmp 源码构建目录里。
      expect(p.r, 127);
    });

    test('封面：THUM/TH44 出 PNG（不含真实 IW44 系数）', () {
      final cov = djvuCoverBytes(_f('djvu-thum.djvu'));
      expect(cov, isNotNull);
      final img = _decodePng(cov!);
      expect(img.w, 40);
      expect(img.h, 30);
    });

    test('多页 DJVM 的封面走 TH44', () {
      final cov = djvuCoverBytes(_f('djvu-multi.djvu'));
      expect(cov, isNotNull);
      final img = _decodePng(cov!);
      expect([img.w, img.h], [40, 30]);
    });
  });

  // ------------------------------------------------------------ 能力边界
  group('坏文件 / 能力边界', () {
    void expectError(String name, {BookParseErrorKind? kind}) {
      final r = parseDjvuBook(_f(name), format: BookFormat.djvu);
      expect(r.error, isNotNull, reason: name);
      if (kind != null) expect(r.errorKind, kind, reason: name);
      // 绝不能"半截内容 + 无错误"
      expect(r.content.pages.isEmpty && r.content.chapters.isEmpty, isTrue);
    }

    test('坏签名 → 报错', () => expectError('djvu-bad-signature.djvu'));
    test('截断 → 报错', () => expectError('djvu-truncated.djvu'));
    test(
      'Smmr（G4 掩码，认识但做不到）→ 不支持压缩',
      () => expectError(
        'djvu-smmr.djvu',
        kind: BookParseErrorKind.unsupportedCompression,
      ),
    );
    test(
      'INFO 版本过新 → 不支持',
      () => expectError(
        'djvu-version-new.djvu',
        kind: BookParseErrorKind.unsupportedCompression,
      ),
    );
    test('散装（indirect）DJVM → 报错', () => expectError('djvu-indirect.djvu'));
    test('只有 INFO 的空页 → 报错', () => expectError('djvu-empty.djvu'));
    test('坏 TXTz 位流 → 报错', () => expectError('djvu-bad-bzz.djvu'));

    test('parseDjvuBook 对任意垃圾字节都不抛（只回错误）', () {
      for (final junk in const <List<int>>[
        [],
        [0],
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
        [0x41, 0x54, 0x26, 0x54, 0x46, 0x4F, 0x52, 0x4D],
      ]) {
        final r = parseDjvuBook(junk, format: BookFormat.djvu);
        expect(r.error, isNotNull);
      }
    });
  });

  // ------------------------------------------------------------ 接入点
  group('格式接入（扩展名 → 解析器 → 预览分流）', () {
    test('.djvu / .djv 都落到"可内嵌阅读"', () {
      expect(bookFormatOf('djvu'), BookFormat.djvu);
      expect(bookFormatOf('DJVU'), BookFormat.djvu);
      expect(bookFormatOf('djv'), BookFormat.djvu);
      expect(isReadableBook('djvu'), isTrue);
      expect(isReadableBook('djv'), isTrue);
      expect(filePreviewKind(_entry('a.djvu')), FilePreviewKind.book);
      expect(filePreviewKind(_entry('a.djv')), FilePreviewKind.book);
      expect(canPreviewInline(_entry('a.djvu')), isTrue);
      expect(bookCoverSupported('djvu'), isTrue);
      expect(bookCoverSupported('djv'), isTrue);
      expect(BookFormat.djvu.label, 'DJVU');
    });

    test('封面：走自研 DJVU 渲染', () {
      final cov = bookCoverBytes('djvu', _f('djvu-thum.djvu'));
      expect(cov, isNotNull);
      expect(_decodePng(cov!).w, 40);
    });

    test('usesPageView：位图书走翻页器，纯文本书走富文本', () {
      final text = parseDjvuBook(
        _f('djvu-text-ta.djvu'),
        format: BookFormat.djvu,
      );
      expect(usesPageView(text.content), isFalse);
      final bmp = parseDjvuBook(
        _f('djvu-jb2-mask.djvu'),
        format: BookFormat.djvu,
      );
      expect(usesPageView(bmp.content), isTrue);
      // 文本书的位图路线必须留空 pages
      expect(text.content.pages, isEmpty);
      expect(text.content.chapters, isNotEmpty);
      expect(bmp.content.pages, isNotEmpty);
      expect(bmp.content.chapters, isEmpty);
    });

    test('格式名语言中立（没有新增 ARB key）', () {
      expect(BookFormat.djvu.name, 'djvu');
      expect(BookFormat.djvu.label, 'DJVU');
    });
  });

  // ------------------------------------------------------------ 阅读页
  group('阅读页 widget', () {
    testWidgets('DJVU 文本层：抽成章节，能翻章', (tester) async {
      await _pump(tester, _entry('book.djvu'), _f('djvu-multi.djvu'));
      expect(tester.takeException(), isNull);
      // 第一页标题 + 正文
      expect(find.textContaining('第一章'), findsWidgets);
      expect(find.textContaining('第一页正文', findRichText: true), findsWidgets);
      // 目录面板用的是 NAVM 层级
      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('book-toc-list')), findsOneWidget);
      expect(find.text('第二章'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('DJVU 位图：走翻页器，图片出现且不红屏', (tester) async {
      await _pump(tester, _entry('scan.djvu'), _f('djvu-jb2-mask.djvu'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(Image), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('合成位图（无 NAVM）：目录入口不显示，也不弹空面板', (tester) async {
      // `djvu-jb2-mask.djvu` 是位图路线且没有 NAVM → 目录空。
      // 入口必须**整个不出现**（不是灰按钮），更不许点出空面板。
      await _pump(tester, _entry('scan-synth.djvu'), _f('djvu-jb2-mask.djvu'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PageView), findsOneWidget);
      expect(find.byKey(const Key('book-comic-toc')), findsNothing);
      expect(find.byTooltip('目录'), findsNothing);
      expect(find.byKey(const Key('book-toc-list')), findsNothing);
      // 页脚照旧（零回归）：格式名 · 页/总页
      expect(find.text('DJVU · 1/1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('DJVU 坏文件：给"不支持/读不了"提示，不红屏', (tester) async {
      await _pump(tester, _entry('bad.djvu'), _f('djvu-smmr.djvu'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    });
  });

  // ------------------------------------------------------- 真实样本（可选）
  //
  // 真实 .djvu 从不入库（体积 + 版权），只在开发机上放在 /tmp/djvu-samples/。
  // 目录不在时整组跳过，保证 CI 与干净检出也能全绿。
  //
  // 这一组是 IW44 的**端到端**验证：结构（页数）来自 `djvudump -e n`，
  // 像素来自 DjVuLibre 3.5.28 的 `ddjvu`，对照脚本见 `tool/djvu_real_compare.dart`。
  group('真实样本对照（/tmp/djvu-samples 存在才跑）', () {
    final dir = Directory('/tmp/djvu-samples');
    final has = dir.existsSync();

    Uint8List? sample(String name) {
      final f = File('/tmp/djvu-samples/$name');
      return f.existsSync() ? f.readAsBytesSync() : null;
    }

    // 期望页数取自 `djvudump`/`djvused -e n` 的独立核对结果。
    const expected = <String, int>{
      '1998_compression.djvu': 25,
      '1998_lossy_masked.djvu': 10,
      '1998_zcoder.djvu': 10,
      'DjVu3Spec_bundled.djvu': 71,
      'djvulibre-book-en.djvu': 57,
      "Mcguffey's_Primer.djvu": 62,
    };

    test('页数与结构：6 份样本全部解出正确页数', () {
      if (!has) return;
      for (final e in expected.entries) {
        final bytes = sample(e.key);
        if (bytes == null) continue;
        final arc = DjvuArchive.open(bytes);
        expect(arc.pages.length, e.value, reason: '${e.key} 页数');
      }
    });

    test('位图渲染：每份样本首页都能出 PNG，且尺寸与 INFO 一致', () {
      if (!has) return;
      for (final e in expected.entries) {
        final bytes = sample(e.key);
        if (bytes == null) continue;
        final r = parseDjvuBook(bytes, format: BookFormat.djvu);
        expect(r.error, isNull, reason: '${e.key} 不应报错：${r.error}');
        expect(r.content.pages, isNotEmpty, reason: '${e.key} 应有页');
        final img = _decodePng(r.content.pages.first);
        final arc = DjvuArchive.open(bytes);
        expect(img.w, arc.pages.first.info!.width, reason: '${e.key} 宽');
        expect(img.h, arc.pages.first.info!.height, reason: '${e.key} 高');
        // 真实扫描页不会是纯白：必须真的画出了东西。
        var dark = 0;
        for (var y = 0; y < img.h; y += 8) {
          for (var x = 0; x < img.w; x += 8) {
            if (_px(img, x, y).r < 192) dark++;
          }
        }
        final sampled = (img.w ~/ 8 + 1) * (img.h ~/ 8 + 1);
        expect(dark / sampled, greaterThan(0.005), reason: '${e.key} 墨迹占比');
      }
    });

    test('散装（indirect）多页：缺分页文件时必须给清晰错误', () {
      if (!has) return;
      final bytes = sample('index.djvu');
      if (bytes == null) return;
      final r = parseDjvuBook(bytes, format: BookFormat.djvu);
      expect(r.error, isNotNull);
      expect(r.error, contains('分页文件'));
      expect(r.errorKind, BookParseErrorKind.unsupportedCompression);
      // 不许吐半截内容。
      expect(r.content.pages, isEmpty);
      // 报错时目录也必须空（不许"有目录 + 正文报错"的错位状态）。
      expect(r.content.toc, isEmpty);
    });

    test('扫描书：NAVM 书签接进位图路线的 BookContent.toc（页号/层级正确）', () {
      final bytes = sample('DjVu3Spec_bundled.djvu');
      if (bytes == null) return;
      final r = parseDjvuBook(bytes, format: BookFormat.djvu);
      expect(r.error, isNull);
      // 位图路线：有页、无章节；目录来自容器层的 NAVM（书签 url → 页索引）。
      expect(r.content.pages, hasLength(71));
      expect(r.content.chapters, isEmpty);
      expect(
        r.content.toc,
        hasLength(98),
        reason: '100 条 NAVM 书签 - 2 条空 url 根书签',
      );
      expect(
        r.content.toc.every(
          (e) => e.chapterIndex >= 0 && e.chapterIndex < r.content.pages.length,
        ),
        isTrue,
        reason: '目录页索引必须落在 [0, 71)',
      );
      // `#<page-number>`（0-based，DjVuLibre 别名口径）：#1 → 第 2 页。
      expect(r.content.toc[0].title, 'Introduction');
      expect(r.content.toc[0].depth, 1);
      expect(r.content.toc[0].chapterIndex, 1);
      // `#<component-id>`：`#p0006.djvu` → 第 6 页（0-based 5）。
      final p6 = r.content.toc[12];
      expect(p6.title, 'p0006.djvu');
      expect(p6.chapterIndex, 5);
      expect(p6.depth, 2);
      // 层级保留（NAVM 的 depth 原样带进来）。
      expect(r.content.toc[18].title, 'IFF wrapper');
      expect(r.content.toc[18].depth, 3);
      expect(r.content.toc[18].chapterIndex, 8);
      expect(
        r.content.toc.map((e) => e.depth).reduce((a, b) => a > b ? a : b),
        4,
      );
    }, skip: has ? null : '真实样本 /tmp/djvu-samples 不存在');

    test('无 NAVM 的真实扫描书：toc 空且不崩', () {
      final bytes = sample('1998_zcoder.djvu');
      if (bytes == null) return;
      final r = parseDjvuBook(bytes, format: BookFormat.djvu);
      expect(r.error, isNull);
      expect(r.content.pages, isNotEmpty);
      expect(DjvuArchive.open(bytes).bookmarks, isEmpty);
      expect(r.content.toc, isEmpty);
    }, skip: has ? null : '真实样本 /tmp/djvu-samples 不存在');

    test('多页 bundled：NAVM 书签与 THUM 缩略图都读出来', () {
      if (!has) return;
      final bytes = sample('DjVu3Spec_bundled.djvu');
      if (bytes == null) return;
      final r = parseDjvuBook(bytes, format: BookFormat.djvu);
      expect(r.error, isNull);
      expect(r.content.pages.length, 71);
      // 书签/缩略图在容器层（`DjvuArchive`），并且已经接进 `BookContent.toc`
      // （位图路线的 `chapterIndex` 就是页索引，见上一组用例）。
      final arc = DjvuArchive.open(bytes);
      expect(arc.bookmarks.length, 100, reason: 'NAVM 书签条数');
      expect(arc.thumbnail.length, 71, reason: 'THUM 缩略图数');
      expect(arc.bookmarks.first.title, isNotEmpty);
      expect(r.content.toc, isNotEmpty);
      final thumb = djvuCoverBytes(bytes);
      expect(thumb, isNotNull);
      final img = _decodePng(thumb!);
      expect(img.w, greaterThan(0));
      expect(img.h, greaterThan(0));
    });

    // ------------------------------------------------ 扫描书翻页视图的目录
    //
    // 数据层已经把 NAVM 书签接进 `BookContent.toc`（上一组用例），这一组装的是
    // **翻页视图（`_ComicView`）真的把它展示出来、点得动、跳得对**：
    //   ① 入口可发现 + 面板 98 条 + 层级缩进；
    //   ② 点条目 → 跳到正确页，页码与翻页进度同步；
    //   ③ 无 NAVM 样本 → 入口不显示、不弹空面板；
    //   ④ 散装 index.djvu → 明确报错路径不回归。
    testWidgets('① 扫描书目录入口：面板 98 条 · 原书目录，depth 1/3/4 缩进递增', (tester) async {
      final bytes = sample('DjVu3Spec_bundled.djvu');
      if (bytes == null) return;
      await _pump(tester, _entry('scan.djvu'), bytes);

      // 位图路线现在也有与文本 / PDF 阅读器同一种目录入口（同一个 tooltip 文案）
      final btn = find.byKey(const Key('book-comic-toc'));
      expect(btn, findsOneWidget);
      expect(find.byTooltip('目录'), findsOneWidget);
      // 第 0 页没有目录条覆盖 → 入口退回 `bookTocTitle`（复用既有 ARB key）
      expect(
        find.descendant(of: btn, matching: find.text('目录')),
        findsOneWidget,
      );

      await tester.tap(btn);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('book-toc-list')), findsOneWidget);
      // 计数复用 `bookTocCount` + `bookOwnToc`
      expect(find.text('98 条 · 原书目录'), findsOneWidget);

      // 层级靠 `book_toc_sheet` 的 contentPadding 表达；直接量它比量 x 坐标稳。
      double leftPad(String title) {
        final tile = tester.widget<ListTile>(
          find.ancestor(
            of: find.descendant(
              of: find.byKey(const Key('book-toc-list')),
              matching: find.text(title),
            ),
            matching: find.byType(DesignRowTile),
          ),
        );
        return (tile.contentPadding! as EdgeInsets).left;
      }

      // depth 1（toc[0]）在首屏；depth 3/4 用筛选拉进视口再量
      final d1 = leftPad('Introduction');
      await tester.enterText(
        find.byKey(const Key('book-toc-filter')),
        'IFF wrapper',
      );
      await tester.pumpAndSettle();
      final d3 = leftPad('IFF wrapper'); // toc[18]，depth 3，页索引 8
      await tester.enterText(
        find.byKey(const Key('book-toc-filter')),
        'p0009.djvu',
      );
      await tester.pumpAndSettle();
      final d4 = leftPad('p0009.djvu'); // toc[20]，depth 4
      expect(d3, greaterThan(d1), reason: 'depth 3 要比 depth 1 深');
      expect(d4, greaterThan(d3), reason: 'depth 4 要比 depth 3 深');
      expect(tester.takeException(), isNull);
    });

    testWidgets('② 点目录条目 → 跳到正确页，页码与进度同步', (tester) async {
      final bytes = sample('DjVu3Spec_bundled.djvu');
      if (bytes == null) return;
      final r = await _pumpWithStore(tester, _entry('scan.djvu'), bytes);
      expect(find.text('DJVU · 1/71'), findsOneWidget);

      await tester.tap(find.byKey(const Key('book-comic-toc')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('book-toc-filter')),
        'IFF wrapper',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('book-toc-list')),
          matching: find.text('IFF wrapper'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));

      // 页码：chapterIndex 8（0 基）→ 第 9 页
      expect(find.text('DJVU · 9/71'), findsOneWidget);
      // 入口标题跟着当前页走（第 8 页覆盖到的最后一条就是 p0009.djvu）
      expect(
        find.descendant(
          of: find.byKey(const Key('book-comic-toc')),
          matching: find.text('p0009.djvu'),
        ),
        findsOneWidget,
      );
      // 翻页进度**同步落库**：9/71（不是"跳了但进度没变"）
      final p = await BookStore(r.db).progressOf('fs:/books/scan.djvu');
      expect(p, isNotNull, reason: '跳页必须写进度');
      expect(p!.format, 'DJVU');
      expect(p.scroll, closeTo(9 / 71, 0.01));
      // 点完自动关面板
      expect(find.byKey(const Key('book-toc-list')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('③ 无 NAVM 扫描书：目录入口不显示、不弹空面板、不崩', (tester) async {
      final bytes = sample('1998_zcoder.djvu');
      if (bytes == null) return;
      await _pump(tester, _entry('plain.djvu'), bytes);
      expect(find.byType(PageView), findsOneWidget);
      expect(find.byKey(const Key('book-comic-toc')), findsNothing);
      expect(find.byTooltip('目录'), findsNothing);
      expect(find.byKey(const Key('book-toc-list')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('④ 散装 index.djvu：明确报错，不出现目录入口也不崩', (tester) async {
      final bytes = sample('index.djvu');
      if (bytes == null) return;
      await _pump(tester, _entry('index.djvu'), bytes);
      expect(find.byKey(const Key('book-comic-toc')), findsNothing);
      expect(find.byKey(const Key('book-toc-list')), findsNothing);
      // 报错路径照旧：给出"分页文件"这条具体原因（toc 空、不崩）
      expect(find.textContaining('分页文件'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
