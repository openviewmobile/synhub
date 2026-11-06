// r653（`DA254`）：**通知栏/锁屏封面**的字节来源 —— 内嵌优先，退服务器封面。
//
// 真机缺口（`docs/evidence-r653/`）：Audio Station 的歌 `path` 常为空 ⇒
// 内嵌封面链给 null ⇒ 通知栏从来没有 `largeIcon`；而页面上那张
// `Cover.getsongcover` 的图是拿得到的。同一个东西两处显示、只有一处有图。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/audio/audio_cover.dart';

/// 最小合法 JPEG 头（`looksLikeImage` 只认魔数）。
Uint8List _jpeg([int seed = 1]) =>
    Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, seed, 0, 0, 0, 0, 0, 0, 0]);

void main() {
  group('DA254 通知栏封面：内嵌优先、服务器兜底', () {
    test('有内嵌封面 ⇒ 直接用，一次网络都不发', () async {
      var fetched = 0;
      final bytes = await resolveNotificationCoverBytes(
        embedded: () async => _jpeg(1),
        fetchServerCover: () async {
          fetched++;
          return _jpeg(2);
        },
      );
      expect(bytes, isNotNull);
      expect(bytes!.length, _jpeg(1).length);
      expect(fetched, 0, reason: '内嵌已经拿到了，不该再去 NAS 取一遍');
    });

    test('内嵌拿不到（AS 歌 path 为空）⇒ 退服务器封面', () async {
      final bytes = await resolveNotificationCoverBytes(
        embedded: () async => null,
        fetchServerCover: () async => _jpeg(7),
      );
      expect(bytes, isNotNull);
      expect(bytes, _jpeg(7));
    });

    test('内嵌解析抛异常 ⇒ 仍然退服务器封面（不许因此打断播放）', () async {
      final bytes = await resolveNotificationCoverBytes(
        embedded: () async => throw StateError('range failed'),
        fetchServerCover: () async => _jpeg(9),
      );
      expect(bytes, _jpeg(9));
    });

    test('服务器回的是 HTML（entry.cgi 200 一整页）⇒ 当没有封面', () async {
      final bytes = await resolveNotificationCoverBytes(
        embedded: () async => null,
        fetchServerCover: () async =>
            Uint8List.fromList('<html><body>404</body></html>'.codeUnits),
      );
      expect(bytes, isNull, reason: '非图片字节不许进 artUri（否则通知栏一片空白）');
    });

    test('服务器 404/网络错 ⇒ 当没有封面，不抛', () async {
      final bytes = await resolveNotificationCoverBytes(
        embedded: () async => null,
        fetchServerCover: () async => throw StateError('404'),
      );
      expect(bytes, isNull);
    });

    test('内嵌是空字节 ⇒ 等同没有，退服务器封面', () async {
      final bytes = await resolveNotificationCoverBytes(
        embedded: () async => Uint8List(0),
        fetchServerCover: () async => _jpeg(5),
      );
      expect(bytes, _jpeg(5));
    });
  });

  _mainDelivery();
}

// ══════════════════════════════════════════════════════════════════════════
// DA254 ②：**取到了就必须交出去**（不许被"页面已经重建"否决）
//
// 真机缺陷原形（logcat）：`attach idx=1 … bytes=55253 mounted=false` ——
// 55 KB 封面已经拿到手，却因为"发起取图的 State 已经不在了"被丢掉，
// 通知栏于是"第一首有图、下一首没图"。
// ══════════════════════════════════════════════════════════════════════════
void _mainDelivery() {
  group('DA254 ② 封面字节的交付契约', () {
    test('取到字节 ⇒ 一定交给 handler（哪怕"发起方已经不在"）', () async {
      var ownerAlive = true; // 模拟页面的生命周期
      final attached = <String, int>{};
      await deliverCoverBytesToHandler(
        mediaId: 'music_2',
        load: () async {
          // 取图是异步的：回来之前"页面"已经被重建掉了
          await Future<void>.delayed(Duration.zero);
          ownerAlive = false;
          return _jpeg(3);
        },
        attach: (id, bytes) async => attached[id] = bytes.length,
      );
      expect(ownerAlive, isFalse);
      expect(
        attached.keys,
        ['music_2'],
        reason: '已经拿到手的封面不许因为"发起取图的页面没了"被丢掉',
      );
      expect(attached['music_2'], _jpeg(3).length);
    });

    test('没取到（null）/ 空字节 ⇒ 不调用 attach（不假装有封面）', () async {
      var calls = 0;
      Future<void> attach(String _, Uint8List _) async => calls++;
      await deliverCoverBytesToHandler(
        mediaId: 'm',
        load: () async => null,
        attach: attach,
      );
      await deliverCoverBytesToHandler(
        mediaId: 'm',
        load: () async => Uint8List(0),
        attach: attach,
      );
      expect(calls, 0);
    });

    test('取图抛异常 ⇒ 吞掉，不把异常抛进播放链路', () async {
      var calls = 0;
      await deliverCoverBytesToHandler(
        mediaId: 'm',
        load: () async => throw StateError('network down'),
        attach: (_, _) async => calls++,
      );
      expect(calls, 0);
    });
  });
}
