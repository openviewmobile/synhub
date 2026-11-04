// P52：分享桥的离线用例（不碰真机、不碰原生通道）。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/photos/photo_share.dart';

/// 假桥：可控 `canShare` / `share`，并记录调用参数。
class _FakeBridge implements PhotoShareBridge {
  _FakeBridge({this.can = true, this.shareReturns = true});

  bool can;
  bool shareReturns;
  final List<Map<String, String>> shared = [];
  final List<Map<String, String>> asked = [];

  @override
  Future<bool> canShare({required String path, required String mime}) async {
    asked.add({'path': path, 'mime': mime});
    return can;
  }

  @override
  Future<bool> share({
    required String path,
    required String name,
    required String mime,
  }) async {
    shared.add({'path': path, 'name': name, 'mime': mime});
    return shareReturns;
  }
}

void main() {
  const a = PhotoShareTarget(path: '/tmp/a.jpg', name: 'a.jpg', mime: 'image/jpeg');
  const b = PhotoShareTarget(path: '/tmp/b.mp4', name: 'b.mp4', mime: 'video/mp4');

  group('P52 分享（复用 MediaOpenBridge 的 share/canShare）', () {
    test('空列表 ⇒ 一个调用都不发', () async {
      final bridge = _FakeBridge();
      final out = await sharePhotoTargets(bridge: bridge, targets: const []);
      expect(out.isEmpty, isTrue);
      expect(bridge.asked, isEmpty);
      expect(bridge.shared, isEmpty);
    });

    test('正常：先 canShare 再 share，参数逐字带 path/name/mime', () async {
      final bridge = _FakeBridge();
      final out = await sharePhotoTargets(bridge: bridge, targets: const [a]);
      expect(out.shared, 1);
      expect(out.unsupported, 0);
      expect(bridge.asked, [
        {'path': '/tmp/a.jpg', 'mime': 'image/jpeg'},
      ]);
      expect(bridge.shared, [
        {'path': '/tmp/a.jpg', 'name': 'a.jpg', 'mime': 'image/jpeg'},
      ]);
    });

    test('canShare=false ⇒ 不调 share，计入 unsupported（不谎报成功）', () async {
      final bridge = _FakeBridge(can: false);
      final out = await sharePhotoTargets(bridge: bridge, targets: const [a, b]);
      expect(out.shared, 0);
      expect(out.unsupported, 2);
      expect(bridge.shared, isEmpty);
    });

    test('share 回 false（桥不可用/没得选）⇒ 计入 unsupported', () async {
      final bridge = _FakeBridge(shareReturns: false);
      final out = await sharePhotoTargets(bridge: bridge, targets: const [a, b]);
      expect(out.shared, 0);
      expect(out.unsupported, 2);
      expect(bridge.shared.length, 2, reason: 'canShare 过了就该真的去拉面板');
    });

    test('空 path ⇒ 直接 unsupported，连 canShare 都不问', () async {
      final bridge = _FakeBridge();
      final out = await sharePhotoTargets(
        bridge: bridge,
        targets: const [
          PhotoShareTarget(path: '', name: 'x.jpg', mime: 'image/jpeg'),
        ],
      );
      expect(out.unsupported, 1);
      expect(bridge.asked, isEmpty);
    });

    test('混合：一个能分享、一个不能 ⇒ 计数分别正确', () async {
      final bridge = _FakeBridge();
      final out = await sharePhotoTargets(
        bridge: bridge,
        targets: const [a, PhotoShareTarget(path: '', name: '', mime: '')],
      );
      expect(out.shared, 1);
      expect(out.unsupported, 1);
    });

    test('真实实现：没有原生通道时 canShare/share 都回 false（明确失败，不抛）', () async {
      final bridge = MediaOpenPhotoShareBridge(
        channel: const MethodChannel('synhub/__no_such_channel__'),
      );
      expect(await bridge.canShare(path: '/tmp/a.jpg', mime: 'image/jpeg'), isFalse);
      expect(
        await bridge.share(path: '/tmp/a.jpg', name: 'a.jpg', mime: 'image/jpeg'),
        isFalse,
      );
      final out = await sharePhotoTargets(
        bridge: bridge,
        targets: const [a],
      );
      expect(out.shared, 0);
      expect(out.unsupported, 1);
    });
  });
}
