// 缩略图 UI 层（`FileThumb` / `FileIconTile` / 类型判断）的离线测试。
//
// 这里不打真服务端，`thumbCacheProvider` 直接用内存版 `ThumbCache`
// （directory = null → 不碰磁盘，测试里也就不会去要 path_provider 插件）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/l10n/gen/app_localizations_zh.dart'
    show AppTextZh;
import 'package:synhub/src/core/media/thumb_cache.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/files/file_thumb.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/media/video_frame_thumb.dart'
    show VideoFrameLoader, videoFrameLoaderProvider;

/// 1x1 的真 PNG（能被 Flutter 解码）
final Uint8List pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

FileEntryDto entryFor(String name) => FileEntryDto(
  name: name,
  path: '/home/$name',
  isDir: false,
  size: 1024,
  mtime: 1758100000,
);

void main() {
  group('要不要请求缩略图', () {
    test('图片 / 视频 → 要', () {
      for (final n in ['a.png', 'b.JPG', 'c.webp', 'd.heic', 'e.mp4']) {
        expect(showsFileThumbnail(entryFor(n)), isTrue, reason: n);
      }
    });

    test('PDF → 不要服务端缩略图（真机：Thumb 对 PDF 回 404 + HTML）', () {
      // 服务端只对图片/视频出图：同一目录下 cover.jpg 200 带真 JPEG，
      // outline.pdf 404 带 11.9KB 错误页。所以 PDF 走客户端渲染第一页
      // （见 file_providers.dart 的 showsBookCover / bookCoverProvider）。
      expect(showsFileThumbnail(entryFor('f.pdf')), isFalse);
    });

    test('文本 / 压缩包 / 未知类型 / 文件夹 → 不要（别白占并发名额）', () {
      for (final n in ['a.txt', 'b.md', 'c.zip', 'd.bin', 'e.docx']) {
        expect(showsFileThumbnail(entryFor(n)), isFalse, reason: n);
      }
      final dir = FileEntryDto(
        name: 'Photos',
        path: '/home/Photos',
        isDir: true,
        size: 0,
        mtime: 1,
      );
      expect(showsFileThumbnail(dir), isFalse);
    });
  });

  group('看起来是不是一张图', () {
    test('PNG / JPEG / GIF / WEBP / BMP 认得出', () {
      expect(looksLikeImage(pngBytes), isTrue);
      expect(
        looksLikeImage(
          Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ),
        isTrue,
      );
      expect(
        looksLikeImage(Uint8List.fromList(utf8.encode('GIF89a______'))),
        isTrue,
      );
      expect(
        looksLikeImage(Uint8List.fromList(utf8.encode('BM____________'))),
        isTrue,
      );
      expect(
        looksLikeImage(Uint8List.fromList(utf8.encode('RIFF1234WEBPVP8 '))),
        isTrue,
      );
    });

    test('HTML 错误页 / 空 / 太短 → 不是图（否则 Image.memory 会抛解码异常）', () {
      // 实测 entry.cgi 有时用 200 回一整页 HTML
      expect(
        looksLikeImage(
          Uint8List.fromList(utf8.encode('<!DOCTYPE html><html>')),
        ),
        isFalse,
      );
      expect(looksLikeImage(Uint8List(0)), isFalse);
      expect(looksLikeImage(Uint8List.fromList([0x89, 0x50])), isFalse);
    });
  });

  group('FileThumb', () {
    Future<void> pump(
      WidgetTester tester,
      Widget child, {
      required ThumbCache cache,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [thumbCacheProvider.overrideWithValue(cache)],
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(body: Center(child: child)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('有真图 → 显示 Image，不再显示分类图标', (tester) async {
      var asked = 0;
      final cache = ThumbCache(
        loader: (path, size) async {
          asked++;
          expect(size, 'small');
          return pngBytes;
        },
        memoryBytes: 1 << 20,
      );

      await pump(tester, FileThumb(entry: entryFor('a.png')), cache: cache);
      expect(asked, 1, reason: '图片类型应该去取缩略图');
      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(Icons.image_outlined), findsNothing);
    });

    testWidgets('取不到（失败）→ 退回分类图标，不崩', (tester) async {
      final cache = ThumbCache(
        loader: (path, size) async => throw Exception('404'),
      );
      await pump(tester, FileThumb(entry: entryFor('b.png')), cache: cache);
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('服务端用 200 回了 HTML → 不当图用（退回图标）', (tester) async {
      final cache = ThumbCache(
        loader: (path, size) async =>
            Uint8List.fromList(utf8.encode('<!DOCTYPE html><html>…')),
      );
      await pump(tester, FileThumb(entry: entryFor('c.png')), cache: cache);
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    });

    testWidgets('文本文件根本不请求缩略图', (tester) async {
      var asked = 0;
      final cache = ThumbCache(
        loader: (path, size) async {
          asked++;
          return pngBytes;
        },
      );
      await pump(tester, FileThumb(entry: entryFor('notes.txt')), cache: cache);
      expect(asked, 0);
      expect(find.byIcon(Icons.article_outlined), findsOneWidget);
    });

    testWidgets('大格子（网格）用 medium 档', (tester) async {
      String? askedSize;
      final cache = ThumbCache(
        loader: (path, size) async {
          askedSize = size;
          return pngBytes;
        },
      );
      await pump(
        tester,
        FileThumb(
          entry: entryFor('d.png'),
          scale: ThumbScale.medium,
          size: 120,
        ),
        cache: cache,
      );
      expect(askedSize, 'medium');
    });
  });

  // 视频的缩略图**不走服务端**：真机实测 `SYNO.FileStation.Thumb` 对视频恒
  // `404 + 11939B HTML`（两个不同视频的 404 响应体 sha256 完全相同 ⇒ 是错误页
  // 不是缩略图）。所以 `FileThumb` 对视频必须在**服务端分支之前**就分岔，
  // 否则每行视频都会白发一个注定 404 的请求，还把并发名额占掉。
  group('视频：走本机抽帧，不发注定 404 的服务端请求', () {
    Future<void> pumpVideo(
      WidgetTester tester,
      FileEntryDto entry, {
      required ThumbCache cache,
      VideoFrameLoader? loader,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            thumbCacheProvider.overrideWithValue(cache),
            if (loader != null)
              videoFrameLoaderProvider.overrideWithValue(loader),
          ],
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(body: Center(child: FileThumb(entry: entry))),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('mp4：服务端缩略图**一次都没请求**，退回视频图标', (tester) async {
      var serverAsked = 0;
      var frameAsked = 0;
      final cache = ThumbCache(
        loader: (path, size) async {
          serverAsked++;
          return pngBytes;
        },
      );
      await pumpVideo(
        tester,
        entryFor('movie.mp4'),
        cache: cache,
        loader: (req) async {
          frameAsked++;
          return null; // "抽不出来"
        },
      );
      expect(
        serverAsked,
        0,
        reason: '视频绝不能去要服务端缩略图（真机恒 404 + HTML）',
      );
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
      // 拿不到 FileStation 直链时**连抽帧都不该发**（supported == false）
      expect(frameAsked, 0, reason: '没有直链就该直接占位，别发请求');
    });

    testWidgets('后缀大小写归一化：`.AVI` 同样走视频分支', (tester) async {
      var serverAsked = 0;
      final cache = ThumbCache(
        loader: (path, size) async {
          serverAsked++;
          return pngBytes;
        },
      );
      await pumpVideo(tester, entryFor('clip.AVI'), cache: cache);
      expect(serverAsked, 0);
      expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
    });

    testWidgets('对照：图片仍然照常请求服务端缩略图（别把图片也挡掉）', (tester) async {
      var serverAsked = 0;
      final cache = ThumbCache(
        loader: (path, size) async {
          serverAsked++;
          return pngBytes;
        },
      );
      await pumpVideo(tester, entryFor('photo.png'), cache: cache);
      expect(serverAsked, 1);
      expect(find.byType(Image), findsOneWidget);
    });
  });

  group('FileIconTile', () {
    testWidgets('文件夹用主色，文件用次要色（保持原列表观感）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: Column(
              children: [
                FileIconTile(
                  entry: FileEntryDto(
                    name: 'Photos',
                    path: '/home/Photos',
                    isDir: true,
                    size: 0,
                    mtime: 1,
                  ),
                ),
                FileIconTile(
                  entry: FileEntryDto(
                    name: 'a.zip',
                    path: '/home/a.zip',
                    isDir: false,
                    size: 1,
                    mtime: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.folder_rounded), findsOneWidget);
      expect(find.byIcon(Icons.folder_zip_outlined), findsOneWidget);
    });
  });

  // HEIC/HEIF 的收敛：`showsFileThumbnail` / `filePreviewKind` 都把它声明成图片，
  // 但 Flutter 的 `Image.memory` **不认** HEIC（`looksLikeImage` 故意不收）→ 只能
  // 走服务端 `SYNO.FileStation.Thumb`（回 JPEG）。服务端给不出时**必须**给带原因的
  // 明确占位，不能静默退回分类图标（那等于"声明支持、实际不可用"地骗用户）。
  group('HEIC/HEIF：声明支持就必须真能用（服务端缩略图）', () {
    // ISO-BMFF：`ftyp` @4 + major brand `heic` @8。
    final heicBytes = Uint8List.fromList([
      0x00, 0x00, 0x00, 0x18, //
      0x66, 0x74, 0x79, 0x70, // 'ftyp'
      0x68, 0x65, 0x69, 0x63, // 'heic'
      0x00, 0x00, 0x00, 0x00,
      0x6D, 0x69, 0x66, 0x31, // 'mif1'
    ]);

    Future<void> pump(
      WidgetTester tester,
      Widget child, {
      required ThumbCache cache,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [thumbCacheProvider.overrideWithValue(cache)],
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(body: Center(child: child)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    test('looksLikeHeic 认 HEIC/HEIF；looksLikeImage 故意不收（喂解码器会抛）', () {
      expect(looksLikeHeic(heicBytes), isTrue);
      expect(looksLikeImage(heicBytes), isFalse);
      expect(needsServerDecodedImage('heic'), isTrue);
      expect(needsServerDecodedImage('HEIF'), isTrue);
      expect(needsServerDecodedImage('jpg'), isFalse);
    });

    test('HEIC 魔数兜底：不是 ISO-BMFF / 太短 → false', () {
      expect(
        looksLikeHeic(Uint8List.fromList(utf8.encode('not-iso-bmff'))),
        isFalse,
      );
      expect(looksLikeHeic(heicBytes.sublist(0, 8)), isFalse);
      expect(looksLikeHeic(Uint8List(0)), isFalse);
    });

    testWidgets('heic + 服务端缩略图回 JPEG → 显示真图，不是占位', (tester) async {
      var asked = 0;
      final cache = ThumbCache(
        loader: (path, size) async {
          asked++;
          expect(path, '/home/a.heic');
          return pngBytes; // 服务端 Thumb 回的就是 JPEG/PNG 真图
        },
      );
      await pump(tester, FileThumb(entry: entryFor('a.heic')), cache: cache);
      expect(asked, 1, reason: 'HEIC 必须走服务端缩略图这条路');
      expect(find.byType(Image), findsOneWidget);
      expect(find.byKey(const Key('file-thumb-server-required')), findsNothing);
    });

    testWidgets('heic + 服务端缩略图失败 → 明确占位 + 原因（不静默变分类图标）', (tester) async {
      final cache = ThumbCache(
        loader: (path, size) async => throw Exception('404'),
      );
      await pump(tester, FileThumb(entry: entryFor('b.heic')), cache: cache);
      expect(
        find.byKey(const Key('file-thumb-server-required')),
        findsOneWidget,
      );
      expect(find.byTooltip(AppTextZh().fileImageDecodeFailed), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('heic + 服务端原样回 HEIC 字节 → 不喂 Image.memory，给明确占位', (
      tester,
    ) async {
      final cache = ThumbCache(loader: (path, size) async => heicBytes);
      await pump(tester, FileThumb(entry: entryFor('c.heic')), cache: cache);
      expect(
        find.byType(Image),
        findsNothing,
        reason: 'HEIC 字节进 Image.memory 只会抛解码异常',
      );
      expect(
        find.byKey(const Key('file-thumb-server-required')),
        findsOneWidget,
      );
    });

    testWidgets('heic 预览（showUnavailableReason）→ 失败时把原因画在占位下', (tester) async {
      final cache = ThumbCache(
        loader: (path, size) async => throw Exception('404'),
      );
      await pump(
        tester,
        FileThumb(
          entry: entryFor('d.heic'),
          size: 320,
          radius: 16,
          showUnavailableReason: true,
        ),
        cache: cache,
      );
      expect(
        find.byKey(const Key('file-thumb-server-required')),
        findsOneWidget,
      );
      expect(find.text(AppTextZh().fileImageDecodeFailed), findsOneWidget);
    });

    testWidgets('PNG 零回归：失败仍退回普通分类图标，不带 server-required 标记', (tester) async {
      final cache = ThumbCache(
        loader: (path, size) async => throw Exception('404'),
      );
      await pump(tester, FileThumb(entry: entryFor('e.png')), cache: cache);
      expect(find.byKey(const Key('file-thumb-server-required')), findsNothing);
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    });
  });
}
