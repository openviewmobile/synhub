// 视频投屏（DLNA / UPnP AVTransport）的宿主用例 —— r655 · DA264。
//
// 分三段：
//   A. **纯解析**（SSDP 应答 / 设备描述 / DIDL / SOAP 故障分类）—— 全是纯函数，
//      用真设备回包的**原文片段**当夹具，改一行就能看出坏了哪条；
//   B. **发现**：注入假 socket + 假描述取回，验证"去重 / 取 controlURL / 排序 /
//      抓不到就不编"；
//   C. **状态机**：假 VideoCast 驱动五个状态，验证"每种结局都有话说"
//      （没设备 / 连不上 / 被拒 / 拉不到流）＋"投上去停本地"这条页面级约定。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/media/media_source.dart';
import 'package:synhub/src/features/media/upnp_cast.dart';
import 'package:synhub/src/features/media/video_cast.dart';

MediaSource _source() => const MediaSource(
      uri: 'https://nas.test/webapi/entry.cgi?api=SYNO.FileStation.Download&_sid=abc&SynoToken=xyz',
      channel: MediaChannel.fileStation,
      kind: MediaKind.video,
      displayName: 'Inception.2010.mkv',
      size: 1234567,
      supportsRange: true,
    );

/// 真机（软件渲染器）SSDP 应答的原文形状
const _ssdpOk = 'HTTP/1.1 200 OK\r\n'
    'CACHE-CONTROL: max-age=1800\r\n'
    'LOCATION: http://192.168.1.20:49494/description.xml\r\n'
    'SERVER: Linux/5.15 UPnP/1.0 r445-renderer/1.0\r\n'
    'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
    'USN: uuid:9d4f1c2e-aaaa-bbbb-cccc-1234567890ab::urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
    '\r\n';

/// 设备描述：故意带命名空间前缀与嵌套 service 块（真设备就是这样）
const _description = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>Living Room TV</friendlyName>
    <manufacturer>Acme</manufacturer>
    <modelName>AC-55X</modelName>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <controlURL>/upnp/control/RenderingControl1</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>/upnp/control/AVTransport1</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';

void main() {
  group('A. 纯解析', () {
    test('A1 SSDP：取 LOCATION（头名大小写不敏感）+ USN', () {
      expect(
        parseSsdpLocation(_ssdpOk),
        'http://192.168.1.20:49494/description.xml',
      );
      expect(parseSsdpUsn(_ssdpOk), contains('uuid:9d4f1c2e'));

      final lower = _ssdpOk.replaceAll('LOCATION:', 'location:');
      expect(parseSsdpLocation(lower), isNotNull,
          reason: 'DA264：真机设备有的小写有的驼峰，解析不许只认一种');
    });

    test('A2 SSDP：没有 LOCATION / 非 http(s) / 空值 ⇒ null（不编地址）', () {
      expect(parseSsdpLocation('HTTP/1.1 200 OK\r\nST: x\r\n'), isNull);
      expect(
        parseSsdpLocation('HTTP/1.1 200 OK\r\nLOCATION: file:///etc/passwd\r\n'),
        isNull,
      );
      expect(parseSsdpLocation('HTTP/1.1 200 OK\r\nLOCATION: \r\n'), isNull);
    });

    test('A3 设备描述：取 friendlyName/modelName 与 AVTransport 的**绝对** controlURL', () {
      final r = parseDeviceDescription(
        _description,
        location: 'http://192.168.1.20:49494/description.xml',
      );
      expect(r, isNotNull);
      expect(r!.friendlyName, 'Living Room TV');
      expect(r.modelName, 'AC-55X');
      expect(
        r.controlUrl,
        'http://192.168.1.20:49494/upnp/control/AVTransport1',
        reason: '设备给的是相对路径，必须按 LOCATION 解析成绝对地址',
      );
    });

    test('A4 设备描述：没有 AVTransport 服务 ⇒ null（RenderingControl 不是投屏入口）', () {
      final onlyVolume = _description.replaceAll('AVTransport', 'RenderingControl');
      expect(
        parseDeviceDescription(
          onlyVolume,
          location: 'http://192.168.1.20:49494/description.xml',
        ),
        isNull,
      );
    });

    test('A5 DIDL：带 upnp:class 与转义过的地址（电视靠 class 判"这是视频"）', () {
      final didl = buildVideoDidlLite(
        uri: 'https://nas.test/a.mkv?x=1&y=2',
        title: 'A & B <sample>',
        sizeBytes: 42,
      );
      expect(didl, contains('object.item.videoItem'));
      expect(didl, contains('http-get:*:video/*:*'));
      expect(didl, contains('A &amp; B &lt;sample&gt;'));
      expect(didl, contains('?x=1&amp;y=2'), reason: 'DIDL 是 XML，& 必须转义');
      expect(didl, contains('size="42"'));
    });

    test('A6 SOAP：信封里每个参数都被转义，SOAPACTION 用服务类型拼在调用点', () {
      final env = buildSoapEnvelope(
        serviceType: kAvTransportServiceType,
        action: 'SetAVTransportURI',
        arguments: {'InstanceID': '0', 'CurrentURI': 'http://a/b?c=1&d=2'},
      );
      expect(env, contains('<u:SetAVTransportURI'));
      expect(env, contains('c=1&amp;d=2'));
      expect(env, contains('xmlns:u="$kAvTransportServiceType"'));
    });

    test('A7 故障分类：714/701 是"不接受"，7xx 其它是"放不出来"，连不上是"不可达"', () {
      expect(
        classifySoapFailure('<errorCode>714</errorCode>'),
        UpnpCastFailure.rejected,
      );
      expect(
        classifySoapFailure('<errorCode>701</errorCode>'),
        UpnpCastFailure.rejected,
      );
      expect(
        classifySoapFailure('<errorCode>716</errorCode>'),
        UpnpCastFailure.rejected,
      );
      expect(
        classifySoapFailure('<errorCode>704</errorCode>'),
        UpnpCastFailure.rejected,
      );
      expect(
        classifySoapFailure('<errorCode>999</errorCode>'),
        UpnpCastFailure.rejected,
      );
      expect(
        classifySoapFailure('<errorCode>501</errorCode>'),
        UpnpCastFailure.rejected,
      );
      expect(
        classifySoapFailure('', transportError: true),
        UpnpCastFailure.unreachable,
      );
    });

    test('A8 状态解析：取 CurrentTransportState', () {
      expect(
        parseTransportState(
          '<CurrentTransportState>PLAYING</CurrentTransportState>',
        ),
        'PLAYING',
      );
      expect(parseTransportState('<foo>1</foo>'), isNull);
    });
  });

  group('B. 发现（注入假 socket / 假描述取回）', () {
    test('B1 同一台设备多播多次 ⇒ 只留一个；按名字排序', () async {
      final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(socket.close);
      // 把三条应答塞进 socket 的接收队列：用一对 loopback 端口模拟
      final sender = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(sender.close);
      // 简化：直接让 UpnpDiscovery 用 loopback 的 socket，测试里手工 send 到自己
      final discovery = UpnpDiscovery(
        searchTimeout: const Duration(milliseconds: 120),
        socketFactory: () async => socket,
        fetchDescription: (uri) async => _description,
        // 宿主上没有组播环境：M-SEARCH 打到 loopback 的假设备上
        searchAddress: InternetAddress.loopbackIPv4.address,
        searchPort: sender.port,
      );
      // 自投三条：两条同 USN、一条不同
      final soon = Future<void>(() async {
        for (var i = 0; i < 3; i++) {
          sender.send(
            utf8.encode(_ssdpOk),
            InternetAddress.loopbackIPv4,
            socket.port,
          );
        }
      });
      final result = await Future.wait([
        discovery.discover(),
        soon.then((_) => const <UpnpRenderer>[]),
      ]);
      final list = result.first;
      expect(list, hasLength(1), reason: 'DA264：同一 USN 只留一台（否则列表里一片重影）');
      expect(list.single.friendlyName, 'Living Room TV');
    });

    test('B2 没有应答 ⇒ 空列表（"没找到"不是失败，更不是编一个出来）', () async {
      final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(socket.close);
      final discovery = UpnpDiscovery(
        searchTimeout: const Duration(milliseconds: 80),
        socketFactory: () async => socket,
        fetchDescription: (uri) async => _description,
        searchAddress: InternetAddress.loopbackIPv4.address,
        searchPort: 9,
      );
      expect(await discovery.discover(), isEmpty);
    });

    test('B3 设备描述取不回来 ⇒ 跳过它（不拿 location 当播放器）', () async {
      final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(socket.close);
      final sender = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(sender.close);
      final discovery = UpnpDiscovery(
        searchTimeout: const Duration(milliseconds: 120),
        socketFactory: () async => socket,
        fetchDescription: (uri) async => null,
        searchAddress: InternetAddress.loopbackIPv4.address,
        searchPort: sender.port,
      );
      final soon = Future<void>(() async {
        sender.send(
          utf8.encode(_ssdpOk),
          InternetAddress.loopbackIPv4,
          socket.port,
        );
      });
      final result = await Future.wait([
        discovery.discover(),
        soon.then((_) => const <UpnpRenderer>[]),
      ]);
      expect(result.first, isEmpty);
    });
  });

  group('D. 真 HTTP 回环（DA265：SOAP 请求体必须带 Content-Length）', () {
    test('D1 渲染器读到的 body 与我们发的**逐字节相同**（chunked 会让它读成 0 字节）',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      String? receivedBody;
      int? receivedLength;
      String? receivedSoapAction;
      final handled = Completer<void>();
      server.listen((request) async {
        receivedLength = request.contentLength;
        receivedSoapAction = request.headers.value('SOAPACTION');
        receivedBody = await utf8.decoder.bind(request).join();
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType('text', 'xml')
          ..write(
            '<?xml version="1.0"?><s:Envelope '
            'xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
            '<u:SetAVTransportURIResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"/>'
            '</s:Body></s:Envelope>',
          );
        await request.response.close();
        if (!handled.isCompleted) handled.complete();
      });

      final transport = UpnpAvTransport(
        controlUrl: 'http://127.0.0.1:${server.port}/upnp/control/AVTransport1',
      );
      final failure = await transport.setVideo(
        source: _source(),
        title: 'Inception.2010.mkv',
      );
      await handled.future;

      expect(failure, isNull);
      expect(receivedSoapAction, contains('SetAVTransportURI'));
      // ★ DA265 的判据：真机（且几乎所有电视）只认 Content-Length；
      //   这条断言就是"我们现在真的给了它"。
      expect(receivedLength, isNotNull, reason: 'DA265：不许 chunked（Content-Length 必须存在）');
      expect(receivedLength, greaterThan(0));
      expect(receivedBody, contains('CurrentURI'));
      expect(receivedBody, contains('SynoToken'));
      expect(receivedBody, contains('object.item.videoItem'));
    });

    test('D2 设备回 SOAP Fault(714) ⇒ 分类成 rejected（不是笼统失败）', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        await utf8.decoder.bind(request).join();
        request.response
          ..statusCode = 500
          ..headers.contentType = ContentType('text', 'xml')
          ..write(
            '<?xml version="1.0"?><s:Envelope '
            'xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
            '<s:Fault><faultcode>s:Client</faultcode><detail>'
            '<UPnPError xmlns="urn:schemas-upnp-org:control-1-0">'
            '<errorCode>714</errorCode><errorDescription>Illegal MIME-type</errorDescription>'
            '</UPnPError></detail></s:Fault></s:Body></s:Envelope>',
          );
        await request.response.close();
      });

      final transport = UpnpAvTransport(
        controlUrl: 'http://127.0.0.1:${server.port}/upnp/control/AVTransport1',
      );
      expect(
        await transport.setVideo(source: _source(), title: 'x'),
        UpnpCastFailure.rejected,
      );
    });

    test('D3 端口没人监听 ⇒ unreachable（不许把 socket 异常漏成崩溃）', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close(force: true);
      final transport = UpnpAvTransport(
        controlUrl: 'http://127.0.0.1:$port/upnp/control/AVTransport1',
      );
      expect(
        await transport.setVideo(source: _source(), title: 'x'),
        UpnpCastFailure.unreachable,
      );
    });
  });

  group('C. 状态机（假 VideoCast）', () {
    test('C1 搜不到 ⇒ failed + noRenderer（有话说，不是空白）', () async {
      final cast = _FakeCast(renderers: const []);
      final c = VideoCastController(cast: cast);
      await c.search();
      expect(c.snapshot.phase, VideoCastPhase.failed);
      expect(c.snapshot.failure, UpnpCastFailure.noRenderer);
    });

    test('C2 搜到 ⇒ ready + 列表', () async {
      final cast = _FakeCast(renderers: [_renderer('TV A'), _renderer('TV B')]);
      final c = VideoCastController(cast: cast);
      await c.search();
      expect(c.snapshot.phase, VideoCastPhase.ready);
      expect(c.snapshot.renderers.map((e) => e.friendlyName), ['TV A', 'TV B']);
    });

    test('C3 推送成功 ⇒ casting + 记住设备 + remotePlaying', () async {
      final cast = _FakeCast(renderers: [_renderer('TV A')]);
      final c = VideoCastController(cast: cast);
      await c.search();
      await c.start(cast.renderers.first, _source());
      expect(c.snapshot.phase, VideoCastPhase.casting);
      expect(c.snapshot.renderer?.friendlyName, 'TV A');
      expect(c.snapshot.remotePlaying, isTrue);
      expect(cast.castCalls, 1);
    });

    test('C4 推送被拒 ⇒ failed + rejected（原因要能落到界面上）', () async {
      final cast = _FakeCast(
        renderers: [_renderer('TV A')],
        failure: UpnpCastFailure.rejected,
      );
      final c = VideoCastController(cast: cast);
      await c.search();
      await c.start(cast.renderers.first, _source());
      expect(c.snapshot.phase, VideoCastPhase.failed);
      expect(c.snapshot.failure, UpnpCastFailure.rejected);
    });

    test('C5 停止投屏：界面**立刻**回 idle，且真的叫了 stop', () async {
      final cast = _FakeCast(renderers: [_renderer('TV A')]);
      final c = VideoCastController(cast: cast);
      await c.search();
      await c.start(cast.renderers.first, _source());
      final done = c.stop();
      expect(c.snapshot.phase, VideoCastPhase.idle,
          reason: 'DA264：设备拔电时不能把"停止"卡成一个转圈');
      await done;
      expect(cast.stopCalls, 1);
      expect(c.snapshot.renderer, isNull);
    });

    test('C6 远端暂停/继续：状态跟着走；失败时保留原因', () async {
      final cast = _FakeCast(renderers: [_renderer('TV A')]);
      final c = VideoCastController(cast: cast);
      await c.search();
      await c.start(cast.renderers.first, _source());

      await c.toggleRemotePlayback();
      expect(c.snapshot.remotePlaying, isFalse);
      expect(cast.pauseCalls, 1);

      await c.toggleRemotePlayback();
      expect(c.snapshot.remotePlaying, isTrue);
      expect(cast.resumeCalls, 1);

      cast.failure = UpnpCastFailure.unreachable;
      await c.toggleRemotePlayback();
      expect(c.snapshot.failure, UpnpCastFailure.unreachable,
          reason: 'DA264：暂停失败要留原因，不许悄悄回到"没变化"');
    });

    test('C7 正在投屏时再点搜索 ⇒ 不重搜（不把用户正在投的那台挤掉）', () async {
      final cast = _FakeCast(renderers: [_renderer('TV A')]);
      final c = VideoCastController(cast: cast);
      await c.search();
      await c.start(cast.renderers.first, _source());
      final searchesBefore = cast.searchCalls;
      await c.search();
      expect(cast.searchCalls, searchesBefore);
      expect(c.snapshot.phase, VideoCastPhase.casting);
    });

    test('C8 换一台设备投 ⇒ 新设备就是当前设备', () async {
      final cast = _FakeCast(renderers: [_renderer('TV A'), _renderer('TV B')]);
      final c = VideoCastController(cast: cast);
      await c.search();
      await c.start(cast.renderers.first, _source());
      await c.start(cast.renderers.last, _source());
      expect(c.snapshot.renderer?.friendlyName, 'TV B');
      expect(cast.castCalls, 2);
    });
  });
}

UpnpRenderer _renderer(String name) => UpnpRenderer(
      friendlyName: name,
      location: 'http://192.168.1.20:49494/description.xml',
      controlUrl: 'http://192.168.1.20:49494/upnp/control/AVTransport1',
      modelName: 'AC-55X',
      usn: 'uuid:$name',
    );

class _FakeCast implements VideoCast {
  _FakeCast({required this.renderers, this.failure});

  final List<UpnpRenderer> renderers;
  UpnpCastFailure? failure;
  int searchCalls = 0;
  int castCalls = 0;
  int stopCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;

  @override
  Future<List<UpnpRenderer>> search() async {
    searchCalls++;
    return renderers;
  }

  @override
  Future<UpnpCastFailure?> cast(
    UpnpRenderer renderer,
    MediaSource source, {
    Duration position = Duration.zero,
    bool playing = true,
  }) async {
    castCalls++;
    return failure;
  }

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<UpnpCastFailure?> pause() async {
    pauseCalls++;
    return failure;
  }

  @override
  Future<UpnpCastFailure?> resume() async {
    resumeCalls++;
    return failure;
  }

  @override
  Future<String?> remoteTransportState() async => 'PLAYING';
}
