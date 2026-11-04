// r652（**DA252**）· 封面**在途请求去重**（single-flight）。
//
// 人视角的缺口：一屏 17 行歌曲 + 专辑网格 + 迷你条同时挂上来时，同一张封面
// 会在**第一张图回来之前**各发一次 `getBytes` —— 用户看到的是"一进页面 NAS
// 就猛响一阵"，实测就是同一张图打好几次。
//
// 判据钉的是**加载器被调用了几次**（机制量），不是"界面上有没有图"：
//   ① 3 个同 `identity|url` 的 `AuthedImage` 同时挂载、加载器故意挂起
//      ⇒ 加载器只被调用 **1** 次（`joins` ≥ 2）；
//   ② 三个都拿到同一份字节并画出 `Image.memory`；
//   ③ 取完之后再挂第 4 个 ⇒ 走缓存（`hits` 增、加载器调用数不变）；
//   ④ 反向：不同 `identity` ⇒ 各算一次（合并不能把两张不同的图合成一张）；
//   ⑤ 反向：加载失败也不许把 future 永久卡在在途表里（`inflight` 归 0）。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/media/authed_image.dart';

/// 1×1 PNG（够 `_looksLikeImage` 认出来）
final _png = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

void main() {
  setUp(AuthedImageCache.reset);

  group('DA252 封面在途请求去重', () {
    testWidgets('3 个同身份同时挂载：加载器只跑 1 次，三处都出图', (tester) async {
      final gate = Completer<void>();
      var calls = 0;
      Future<List<int>> load(String url) async {
        calls++;
        await gate.future; // 故意挂起：模拟"第一张图还没回来"
        return _png;
      }

      Widget img(String identity) => AuthedImage(
        url: 'https://nas/cover.cgi?id=1',
        identity: identity,
        load: load,
        fallback: const Text('占位'),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              SizedBox(width: 40, height: 40, child: img('album:A')),
              SizedBox(width: 40, height: 40, child: img('album:A')),
              SizedBox(width: 40, height: 40, child: img('album:A')),
            ],
          ),
        ),
      );
      await tester.pump();

      expect(calls, 1, reason: '同一个 identity|url 在途时只许发一次');
      expect(AuthedImageCache.joins, greaterThanOrEqualTo(2));

      gate.complete();
      await tester.pumpAndSettle();

      expect(
        find.byType(Image),
        findsNWidgets(3),
        reason: '搭车的两个也必须拿到同一份字节并画出来',
      );
      expect(calls, 1);

      // ④ 反向：不同身份各算一次
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              SizedBox(width: 40, height: 40, child: img('album:B')),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(calls, 2, reason: '不同 identity 不许被合并成一张图');
    });

    testWidgets('取完之后再挂：走缓存，不再打 NAS', (tester) async {
      var calls = 0;
      Future<List<int>> load(String url) async {
        calls++;
        return _png;
      }

      // 每一轮换一个 key ⇒ 真的**重新挂载**（不换 key 会复用 State、
      // 走 `didUpdateWidget` 而不是 `initState`，测不到缓存命中）
      Future<void> mountOnce(int round) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 40,
              height: 40,
              child: AuthedImage(
                key: ValueKey('round-$round'),
                url: 'https://nas/cover.cgi?id=2',
                identity: 'album:C',
                load: load,
                fallback: const Text('占位'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await mountOnce(1);
      expect(calls, 1);
      expect(AuthedImageCache.hits, 0);

      await mountOnce(2);
      expect(calls, 1, reason: '第二轮必须命中缓存');
      expect(AuthedImageCache.hits, greaterThan(0));
    });

    testWidgets('反向：失败也要把在途表清干净（不许永久卡住后来的请求）', (tester) async {
      Future<List<int>> boom(String url) async => <int>[];

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 40,
            height: 40,
            child: AuthedImage(
              url: 'https://nas/cover.cgi?id=3',
              identity: 'album:D',
              load: boom,
              fallback: const Text('占位'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('占位'), findsOneWidget);
      expect(AuthedImageCache.inflight, 0, reason: '在途表不许泄漏');
      expect(AuthedImageCache.length, 0, reason: '空字节不许进缓存');
    });
  });
}
