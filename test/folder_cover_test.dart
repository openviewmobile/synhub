// 文件夹封面（客户端九宫格）与"按真实比例"的缩略图规则。
//
// 服务端证据：2026-09-21 真机实测 `SYNO.FileStation.Thumb.get` 对**目录**一律
// 404 + 11939 B HTML（同目录图片 200 带真字节），所以文件夹封面只能客户端拼。
// 这里离线测三件事：
//   1. 拼图本身（1/2/3/4 张的布局、0 张退回图标）；
//   2. provider 的接线（列目录 → 挑图片 → 取缩略图）与缓存（同 mtime 只列一次）；
//   3. 图片缩略图按**真实比例**摆（不裁切）——16:9 的照片不该被砍成正方形。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/media/thumb_cache.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/files/file_thumb.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/files/folder_cover.dart';

/// 指定尺寸的真 PNG（能被 Flutter 解码；头部也能被我们解析）
Uint8List png(int w, int h) {
  final src = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
    'q842iQAAAABJRU5ErkJggg==',
  );
  // 只改 IHDR 里的宽高（对布局测试足够；解码仍按 1×1 的像素数据来）
  final out = Uint8List.fromList(src);
  void put(int at, int v) {
    out[at] = (v >> 24) & 0xFF;
    out[at + 1] = (v >> 16) & 0xFF;
    out[at + 2] = (v >> 8) & 0xFF;
    out[at + 3] = v & 0xFF;
  }

  put(16, w);
  put(20, h);
  return out;
}

FileEntryDto file(String name, {String dir = '/home'}) => FileEntryDto(
  name: name,
  path: '$dir/$name',
  isDir: false,
  size: 1024,
  mtime: 1758100000,
);

FileEntryDto dir(String name, {int mtime = 1758100000}) => FileEntryDto(
  name: name,
  path: '/home/$name',
  isDir: true,
  size: 0,
  mtime: mtime,
);

/// 内存缩略图缓存：按路径返回不同尺寸的图，便于验证"每格都画出来了"
ThumbCache cacheWith(Map<String, Uint8List> byPath, {void Function()? onLoad}) {
  return ThumbCache(
    loader: (path, size) async {
      onLoad?.call();
      final hit = byPath[path];
      if (hit == null) throw StateError('没有这张图：$path');
      return hit;
    },
    memoryBytes: 1 << 20,
  );
}

Future<void> pumpThumb(
  WidgetTester tester,
  FileEntryDto entry, {
  required ThumbCache cache,
  FolderImageLister? lister,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        thumbCacheProvider.overrideWithValue(cache),
        if (lister != null) folderImageListerProvider.overrideWithValue(lister),
      ],
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: Center(child: FileThumb(entry: entry)),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUp(FolderCoverCache.clear);

  group('拼图布局', () {
    testWidgets('1 张 → 只画一张，且按真实比例（不裁）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: Center(
              child: FolderCoverMosaic(images: [png(400, 200)], size: 40),
            ),
          ),
        ),
      );
      expect(find.byType(Image), findsOneWidget);
      final size = tester.getSize(find.byType(Image));
      expect(
        size.width / size.height,
        closeTo(2.0, 0.05),
        reason: '400×200 = 2:1',
      );
    });

    testWidgets('2/3/4 张 → 张张都画出来', (tester) async {
      for (final n in [2, 3, 4]) {
        await tester.pumpWidget(
          MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: Center(
                child: FolderCoverMosaic(
                  images: [for (var i = 0; i < n; i++) png(80, 80)],
                  size: 48,
                ),
              ),
            ),
          ),
        );
        expect(find.byType(Image), findsNWidgets(n), reason: '$n 张');
      }
    });

    testWidgets('0 张 → 什么都不画（调用方退回图标）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: Center(child: FolderCoverMosaic(images: [], size: 40)),
          ),
        ),
      );
      expect(find.byType(Image), findsNothing);
    });
  });

  group('FileThumb 接线', () {
    testWidgets('文件夹里有图 → 拼九宫格（不再是纯图标）', (tester) async {
      final images = {
        '/home/Photos/a.jpg': png(80, 80),
        '/home/Photos/b.jpg': png(80, 80),
      };
      var listed = 0;
      await pumpThumb(
        tester,
        dir('Photos'),
        cache: cacheWith(images),
        lister: (path) async {
          listed++;
          expect(path, '/home/Photos');
          return [
            file('a.jpg', dir: '/home/Photos'),
            file('b.jpg', dir: '/home/Photos'),
            file('note.txt', dir: '/home/Photos'), // 非图片，不算封面
            dir('sub', mtime: 1), // 子目录也不算
          ];
        },
      );
      expect(find.byType(Image), findsNWidgets(2));
      expect(find.byIcon(Icons.folder_rounded), findsNothing);
      expect(listed, 1);
    });

    testWidgets('文件夹里没有图 → 退回文件夹图标（不留空框）', (tester) async {
      await pumpThumb(
        tester,
        dir('Docs'),
        cache: cacheWith(const {}),
        lister: (path) async => [file('a.txt', dir: '/home/Docs')],
      );
      expect(find.byType(Image), findsNothing);
      expect(find.byType(FileIconTile), findsOneWidget);
    });

    testWidgets('列举失败（权限/离线）→ 也是图标，不崩不重试刷屏', (tester) async {
      await pumpThumb(
        tester,
        dir('Private'),
        cache: cacheWith(const {}),
        lister: (path) async => throw StateError('403'),
      );
      expect(find.byType(FileIconTile), findsOneWidget);
    });

    testWidgets('同一个文件夹（mtime 没变）只列一次目录', (tester) async {
      var listed = 0;
      Future<List<FileEntryDto>> lister(String path) async {
        listed++;
        return [file('a.jpg', dir: '/home/Album')];
      }

      final cache = cacheWith({'/home/Album/a.jpg': png(80, 80)});
      await pumpThumb(tester, dir('Album'), cache: cache, lister: lister);
      // 重建整棵树（模拟滚走再滚回来）
      await pumpThumb(tester, dir('Album'), cache: cache, lister: lister);
      expect(listed, 1, reason: '同 mtime 应命中 FolderCoverCache');
      expect(FolderCoverCache.size, 1);
    });
  });

  group('图片缩略图按真实比例', () {
    testWidgets('16:9 的图 → 40×22.5，不再被砍成正方形', (tester) async {
      await pumpThumb(
        tester,
        file('wide.jpg'),
        cache: cacheWith({'/home/wide.jpg': png(1600, 900)}),
      );
      final size = tester.getSize(find.byType(Image));
      expect(size.width, closeTo(40, 0.5));
      expect(size.width / size.height, closeTo(16 / 9, 0.05));
    });

    testWidgets('竖图（手机截图 0.46）→ 宽度按比例收窄', (tester) async {
      await pumpThumb(
        tester,
        file('shot.png'),
        cache: cacheWith({'/home/shot.png': png(1148, 2492)}),
      );
      final size = tester.getSize(find.byType(Image));
      expect(size.height, closeTo(40, 0.5));
      expect(size.width, closeTo(40 * 1148 / 2492, 1.0));
    });

    testWidgets('比例读不出来（不明格式）→ 退 contain，仍不裁', (tester) async {
      // 有效图片字节但头不是我们认得的格式：换一个 GIF 头 + 垃圾
      final weird = Uint8List.fromList([
        ...utf8.encode('GIF89a'),
        ...List.filled(20, 0),
        ...List.filled(40, 0x7F),
      ]);
      await pumpThumb(
        tester,
        file('x.gif'),
        cache: cacheWith({'/home/x.gif': weird}),
      );
      // 认不出来时不留 AspectRatio 约束：Image 直接铺满方框 + contain 留白
      expect(find.byType(Image), findsOneWidget);
    });
  });
}
