// 电子书封面在文件列表里的接线（NAS 源 + Drive 源）。
//
// 服务端证据：`SYNO.FileStation.Thumb.get` 对 `.epub`/`.pdf` 回 404 + 一页 HTML
// （同目录 `cover.jpg` 200 带真 JPEG），所以封面必须客户端出。这里只测**接线**：
//   1. [showsBookCover] 的类型/体积闸门（哪些书才去要封面）；
//   2. PDF 不再走服务端缩略图（[showsFileThumbnail] 里必须没有 pdf）；
//   3. `FileThumb` 拿到封面字节 → 画图；拿不到 → 退回分类图标。
// 真正的"从 epub 里抠封面"由 `test/book_cover_test.dart` 覆盖（纯解析）。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/media/thumb_cache.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/files/file_thumb.dart';

/// 一张最小的合法 PNG（1×1），够 `looksLikeImage` 认出来
final Uint8List kPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // magic
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, //
  0xDE, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, //
  0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// 一张 200×300（2:3，典型书封比例）的 PNG 头 —— 尺寸解析要能读出来
Uint8List pngOf(int w, int h) => Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  (w >> 24) & 0xFF, (w >> 16) & 0xFF, (w >> 8) & 0xFF, w & 0xFF,
  (h >> 24) & 0xFF, (h >> 16) & 0xFF, (h >> 8) & 0xFF, h & 0xFF,
  0x08, 0x02, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

FileEntryDto book(
  String name, {
  int size = 1024,
  bool isDir = false,
  int mtime = 1700000000,
}) => FileEntryDto(
  name: name,
  path: '/home/books/$name',
  isDir: isDir,
  size: size,
  mtime: mtime,
);

/// 用假 loader 造一个只走内存的封面缓存（不碰网络/磁盘）
ThumbCache fakeCoverCache(Uint8List? bytes) => ThumbCache(
  loader: (path, size) async {
    if (bytes == null) throw StateError('这本书里没有封面');
    return bytes;
  },
);

Future<void> pumpThumb(
  WidgetTester tester,
  FileEntryDto entry, {
  Uint8List? cover,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        bookCoverCacheProvider.overrideWithValue(fakeCoverCache(cover)),
      ],
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: Center(child: FileThumb(entry: entry)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('哪些条目会去要客户端封面', () {
    test('电子书 + PDF 要，普通文件/文件夹不要', () {
      for (final name in ['a.epub', 'b.EPUB', 'c.cbz', 'd.fb2', 'e.pdf']) {
        expect(showsBookCover(book(name)), isTrue, reason: name);
      }
      for (final name in ['a.jpg', 'a.mp4', 'a.txt', 'a.docx', 'a.zip']) {
        expect(showsBookCover(book(name)), isFalse, reason: name);
      }
      expect(showsBookCover(book('dir.epub', isDir: true)), isFalse);
    });

    test('超过体积闸门的大书不去取（一本画集不值得为一张小图下全本）', () {
      expect(
        showsBookCover(book('big.epub', size: kBookCoverMaxBytes)),
        isTrue,
      );
      expect(
        showsBookCover(book('big.epub', size: kBookCoverMaxBytes + 1)),
        isFalse,
      );
      // size=0（列表没带 additional）不设闸门，先试一次
      expect(showsBookCover(book('unknown.epub', size: 0)), isTrue);
    });

    test('PDF 不再走服务端缩略图（真机：Thumb 对 PDF 回 404）', () {
      expect(showsFileThumbnail(book('a.pdf')), isFalse);
      // 图片/视频仍然走服务端
      expect(showsFileThumbnail(book('a.jpg')), isTrue);
      expect(showsFileThumbnail(book('a.mp4')), isTrue);
    });
  });

  group('FileThumb 接线', () {
    testWidgets('epub：拿到封面字节就画出来（不再是分类图标）', (tester) async {
      await pumpThumb(tester, book('a.epub'), cover: kPng);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(Icons.menu_book_outlined), findsNothing);
    });

    testWidgets('epub：拿不到封面 → 退回分类图标（不崩、不空白）', (tester) async {
      await pumpThumb(tester, book('a.epub'));
      expect(find.byType(Image), findsNothing);
      // 分类图标是 Fallback，标题不空
      expect(find.byType(FileIconTile), findsOneWidget);
    });

    testWidgets('普通图片走服务端缩略图这条路（封面缓存不参与）', (tester) async {
      // 假封面缓存里塞了图，但 jpg 不该去读它 —— 只验证不发请求、
      // 且没有服务端数据时退回图标
      await pumpThumb(tester, book('a.jpg'), cover: kPng);
      expect(find.byType(FileIconTile), findsOneWidget);
    });
  });

  group('缩略图按真实比例摆（书封与图片，都不裁切）', () {
    testWidgets('2:3 的封面 → 竖着摆，宽度按比例缩到方框内', (tester) async {
      await pumpThumb(tester, book('a.epub'), cover: pngOf(200, 300));
      final image = find.byType(Image);
      expect(image, findsOneWidget);
      final size = tester.getSize(image);
      // 高度用满（父级给的 40），宽度 = 40 × 2/3 ≈ 26.7
      expect(size.height, closeTo(40, 0.5));
      expect(size.width, closeTo(40 * 2 / 3, 1.0));
      // 关键：**没有被裁成正方形**
      expect(size.width, lessThan(40));
    });

    testWidgets('宽封面（比例超出区间）会被夹住，不至于把行撑变形', (tester) async {
      // 300×100（3:1）明显不是封面 → 夹到 kBookCoverMaxAspect
      await pumpThumb(tester, book('b.pdf'), cover: pngOf(300, 100));
      final size = tester.getSize(find.byType(Image));
      expect(size.height, closeTo(40, 0.5));
      expect(size.width / size.height, closeTo(kBookCoverMaxAspect, 0.01));
    });

    testWidgets('头部读不出比例（例如 HEIC）→ 用 0.70 兜底，仍然不是正方形', (tester) async {
      // 合法 PNG 魔数但 IHDR 被截断 → imageSizeFromBytes 返回 null
      final weird = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
        ...List.filled(20, 0),
      ]);
      await pumpThumb(tester, book('c.epub'), cover: weird);
      final size = tester.getSize(find.byType(Image));
      expect(size.width / size.height, closeTo(kBookCoverAspect, 0.01));
      expect(size.width, lessThan(size.height));
    });

    testWidgets('图片同样按真实比例（4:3 的照片不再裁成方形）', (tester) async {
      final cache = ThumbCache(
        loader: (path, size) async => pngOf(400, 300),
        memoryBytes: 1 << 20,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [thumbCacheProvider.overrideWithValue(cache)],
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: Center(child: FileThumb(entry: book('a.jpg'))),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final size = tester.getSize(find.byType(Image));
      expect(size.width, closeTo(40, 0.5));
      expect(size.height, closeTo(30, 0.5), reason: '400×300 → 4:3，高度按比例收');
    });
  });
}
