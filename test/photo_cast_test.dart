// P65：照片投送（Chromecast）协议层与会话状态的离线用例。
//
// 证据出处：`lib/src/features/photos/photo_cast.dart` 顶部注释
// （APK 2.4.0-644 smali：`ChromecastHelper` 的命名空间常量、
//  `CastMessageChannel` 的命令常量、`SenderItem` 的 `command/data/version`、
//  `GotoIndexItem.index`、错误消息的 `code`/`detail`）。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/photos/photo_cast.dart';

class _FakeBridge implements PhotoCastBridge {
  _FakeBridge({this.available = true, this.throwOnAvailability = false});

  bool available;
  bool throwOnAvailability;
  final List<Map<String, dynamic>> sent = [];
  final List<String> connects = [];
  int disconnects = 0;

  @override
  Future<Map<String, dynamic>> availability() async {
    if (throwOnAvailability) {
      throw MissingPluginException('no cast bridge');
    }
    return {'available': available, 'devices': <Object?>[]};
  }

  @override
  Future<void> connect(String deviceId) async => connects.add(deviceId);

  @override
  Future<void> send(Map<String, dynamic> message) async => sent.add(message);

  @override
  Future<void> disconnect() async => disconnects++;
}

void main() {
  group('P65 协议层：信封与载荷逐字对齐官方', () {
    test('命名空间就是官方那个', () {
      expect(kPhotoCastNamespace, 'urn:x-cast:com.synology.photos');
    });

    test('信封字段 = command / data / version（官方 SenderItem 三个字段）', () {
      final e = photoCastEnvelope(PhotoCastCommand.identify, const {});
      expect(e.keys.toSet(), {'command', 'data', 'version'});
      expect(e['command'], 'identify');
      expect(e['data'], isEmpty);
      // version 取值未取证 ⇒ 允许调用方指定，默认 1（不假装知道官方值）
      expect(e['version'], 1);
      expect(
        photoCastEnvelope('x', const {}, version: 2)['version'],
        2,
      );
    });

    test('goto_index 载荷字段就是 index（官方 GotoIndexItem.index）', () {
      expect(photoCastGotoIndex(7), {'index': 7});
    });

    test('接收端错误的 code/detail：有则拼、无则 null（不编造错误码）', () {
      expect(photoCastErrorDetail({'code': 5, 'detail': 'boom'}), 'code=5, detail=boom');
      expect(photoCastErrorDetail({'code': 5}), 'code=5');
      expect(photoCastErrorDetail({'detail': 'boom'}), 'boom');
      expect(photoCastErrorDetail(const {}), isNull);
    });
  });

  group('P65 会话状态机', () {
    test('能力不可用 ⇒ unsupported，且**一个字节都不发**', () async {
      final bridge = _FakeBridge(available: false);
      final s = PhotoCastSession(bridge);
      expect(await s.probe(), isFalse);
      expect(s.state, PhotoCastState.unsupported);
      expect(await s.start('tv-1'), isFalse);
      await s.project(1);
      await s.stop();
      expect(bridge.sent, isEmpty);
      expect(bridge.connects, isEmpty);
    });

    test('桥抛异常（原生侧未实现）⇒ 收敛成 unsupported，不假装成功', () async {
      final bridge = _FakeBridge(throwOnAvailability: true);
      final s = PhotoCastSession(bridge);
      expect(await s.probe(), isFalse);
      expect(s.state, PhotoCastState.unsupported);
      expect(bridge.sent, isEmpty);
    });

    test('正常投送：connect → identify；翻页 → goto_index；结束 → disconnect', () async {
      final bridge = _FakeBridge();
      final s = PhotoCastSession(bridge);
      expect(await s.probe(), isTrue);
      expect(s.state, PhotoCastState.idle);

      expect(await s.start('tv-1'), isTrue);
      expect(bridge.connects, ['tv-1']);
      expect(s.state, PhotoCastState.projecting);
      expect(bridge.sent.single['command'], 'identify');
      expect(bridge.sent.single['data'], isEmpty);

      await s.project(3);
      expect(bridge.sent.last['command'], 'goto_index');
      expect(bridge.sent.last['data'], {'index': 3});

      await s.stop();
      expect(bridge.sent.last['command'], 'disconnect');
      expect(s.state, PhotoCastState.idle);
      expect(bridge.disconnects, 1);
    });

    test('未连接时 project / stop ⇒ 零消息（不无意义地骚扰原生层）', () async {
      final bridge = _FakeBridge();
      final s = PhotoCastSession(bridge);
      await s.probe();
      await s.project(0);
      await s.stop();
      expect(bridge.sent, isEmpty);
      expect(bridge.disconnects, 0);
    });

    test('空 deviceId ⇒ 不连接、不握手', () async {
      final bridge = _FakeBridge();
      final s = PhotoCastSession(bridge);
      await s.probe();
      expect(await s.start(''), isFalse);
      expect(bridge.connects, isEmpty);
      expect(bridge.sent, isEmpty);
    });

    test('接收端 error ⇒ 记录 code/detail 并停止投送（不吞错）', () async {
      final bridge = _FakeBridge();
      final s = PhotoCastSession(bridge);
      await s.probe();
      await s.start('tv-1');
      s.onReceiverMessage({
        'command': 'error',
        'data': 'ignored',
        'code': 42,
        'detail': 'receiver busy',
      });
      expect(s.lastError, 'code=42, detail=receiver busy');
      expect(s.state, PhotoCastState.idle);
      // 已经停投 ⇒ 再 project 不发
      final before = bridge.sent.length;
      await s.project(9);
      expect(bridge.sent.length, before);
    });
  });
}
