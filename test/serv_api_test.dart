// ServApi（QuickConnect 发现层）验证 —— 用本地 HttpServer 充当 Serv.php
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/quickconnect/address_selector.dart';
import 'package:synhub/src/quickconnect/serv_api.dart';

/// 按路径/命令分发的假 Serv.php
class FakeServ {
  FakeServ();

  late HttpServer _server;
  final List<Map<String, dynamic>> requests = [];

  /// command -> 响应体
  final Map<String, Object Function(Map<String, dynamic> req)> handlers = {};

  /// relayServer 主机名 -> 响应体
  final Map<String, Object Function(Map<String, dynamic> req)> relayHandlers =
      {};

  String get baseUrl => 'http://127.0.0.1:${_server.port}/Serv.php';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final raw = await utf8.decoder.bind(req).join();
      final body = jsonDecode(raw) as Map<String, dynamic>;
      requests.add({'host': req.headers.host, 'body': body});

      final fn = handlers[body['command'] as String? ?? ''];
      req.response.headers.contentType = ContentType.text;
      if (fn == null) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      req.response.write(jsonEncode(fn(body)));
      await req.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

ServApi apiFor(FakeServ fake) => ServApi(
  controlUrl: fake.baseUrl,
  dio: Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 2),
      receiveTimeout: const Duration(seconds: 2),
    ),
  ),
);

/// ★ D4 用的**假 Dio**：按 host 分发，**不建任何 socket**（AGENTS §5.1 只允许离线单测）。
///
/// [respond] 返回 `null` = 模拟该 host **不可达** —— 抛 `connectionError`，
/// 等价于台账里 `curl https://global.quickconnect.to/Serv.php → 000`。
/// 每次请求把 `options.uri.host` 记进 [hits]，用来断言"到底碰了哪个端点"。
Dio endpointDio(
  List<String> hits,
  Object? Function(String host) respond, {
  /// 记下每个 host 上真正 reject 的那个异常对象 —— 用来断言
  /// "抛回的是**最先尝试**那次的**原始异常**"（`identical`，不是只比文案）。
  Map<String, DioException>? rejected,
}) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 2),
      receiveTimeout: const Duration(seconds: 2),
    ),
  );
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final host = options.uri.host;
        hits.add(host);
        final body = respond(host);
        if (body == null) {
          final error = DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            message: '假 Dio：$host 不可达（模拟 000）',
          );
          rejected?[host] = error;
          handler.reject(error);
          return;
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: jsonEncode(body),
          ),
        );
      },
    ),
  );
  return dio;
}

void main() {
  _realResponseShape();
  _smartdnsLan();
  _errnoSemantics();
  group('fetchEchoList', () {
    late FakeServ fake;
    late ServApi api;

    setUp(() async {
      fake = FakeServ();
      await fake.start();
      api = apiFor(fake);
    });
    tearDown(() => fake.stop());

    test('正常响应：sites 共用 port，带 udt_tx_mss', () async {
      fake.handlers['get_echo_list'] = (_) => {
        'errno': 0,
        'sites': ['1.2.3.4', '5.6.7.8'],
        'port': 1234,
        'udt_tx_mss': 1400,
      };

      final r = await api.fetchEchoList();
      expect(r.errno, 0);
      expect(r.udtTxMss, 1400);
      expect(r.sites, [
        const EchoSite('1.2.3.4', 1234),
        const EchoSite('5.6.7.8', 1234),
      ]);
      expect(r.isEmpty, isFalse);
    });

    test('请求体与原库一致：version 为字符串 "1"', () async {
      fake.handlers['get_echo_list'] = (_) => {
        'errno': 0,
        'sites': <String>[],
        'port': 80,
      };
      await api.fetchEchoList();

      final body = fake.requests.single['body'] as Map<String, dynamic>;
      expect(body['version'], '1'); // 字符串，不是数字
      expect(body['command'], 'get_echo_list');
      expect(body.length, 2);
    });

    test('sites 里的非字符串元素被跳过（对齐原库 isString 判断）', () async {
      fake.handlers['get_echo_list'] = (_) => {
        'errno': 0,
        'sites': [
          '1.2.3.4',
          123,
          null,
          '5.6.7.8',
          {'ip': 'x'},
        ],
        'port': 1234,
      };
      final r = await api.fetchEchoList();
      expect(r.sites, [
        const EchoSite('1.2.3.4', 1234),
        const EchoSite('5.6.7.8', 1234),
      ]);
    });

    test('udt_tx_mss 缺失或 <= 0 时归 0（表示未提供）', () async {
      fake.handlers['get_echo_list'] = (_) => {
        'errno': 0,
        'sites': ['1.1.1.1'],
        'port': 1,
      };
      expect((await api.fetchEchoList()).udtTxMss, 0);

      fake.handlers['get_echo_list'] = (_) => {
        'errno': 0,
        'sites': ['1.1.1.1'],
        'port': 1,
        'udt_tx_mss': 0,
      };
      expect((await api.fetchEchoList()).udtTxMss, 0);

      fake.handlers['get_echo_list'] = (_) => {
        'errno': 0,
        'sites': ['1.1.1.1'],
        'port': 1,
        'udt_tx_mss': -5,
      };
      expect((await api.fetchEchoList()).udtTxMss, 0);
    });

    test('errno != 0 抛异常并带上 errno', () async {
      fake.handlers['get_echo_list'] = (_) => {'errno': 7, 'sites': <String>[]};
      await expectLater(
        api.fetchEchoList(),
        throwsA(isA<ServApiException>().having((e) => e.errno, 'errno', 7)),
      );
    });

    test('sites 不是数组 → 抛异常', () async {
      fake.handlers['get_echo_list'] = (_) => {
        'errno': 0,
        'sites': 'x',
        'port': 1,
      };
      await expectLater(api.fetchEchoList(), throwsA(isA<ServApiException>()));
    });

    test('port 缺失 → 抛异常', () async {
      fake.handlers['get_echo_list'] = (_) => {'errno': 0, 'sites': <String>[]};
      await expectLater(api.fetchEchoList(), throwsA(isA<ServApiException>()));
    });

    test('空响应 body → 抛异常', () async {
      fake.handlers['get_echo_list'] = (_) => <String, dynamic>{};
      // jsonEncode({}) = "{}" → errno 缺失按 0 处理，但 sites 不是数组
      await expectLater(api.fetchEchoList(), throwsA(isA<ServApiException>()));
    });
  });

  group('fetchServerInfo', () {
    late FakeServ fake;
    late ServApi api;

    setUp(() async {
      fake = FakeServ();
      await fake.start();
      api = apiFor(fake);
    });
    tearDown(() => fake.stop());

    Map<String, dynamic> serverInfoResponse() => {
      'errno': 0,
      'env': {'controlHost': 'global.quickconnect.to', 'relayRegion': 'tw'},
      'server': {
        'serverID': 'my-qcid',
        'external': '203.0.113.5',
        'ddns': 'my-qcid.direct.quickconnect.to',
        'fqdn': 'my-qcid.example.com',
        'udp_punch_port': 51342,
        'tcp_punch_port': 51343,
        'behind_nat': true,
        'interface': [
          {'name': 'eth0', 'ip': '192.168.1.10', 'mask': '255.255.255.0'},
        ],
      },
      'smartdns': {
        'host': 'my-qcid.direct.quickconnect.to',
        'external': '203.0.113.5',
        'lans': ['192.168.1.10'],
      },
      'service': {'id': 'dsm_https', 'port': 5001, 'extPort': 5001},
      'relay_servers': ['relay1.example.com', 'relay2.example.com'],
    };

    test('请求体与原库一致（version 为数字 1，字段 id）', () async {
      fake.handlers['get_server_info'] = (_) => serverInfoResponse();
      await api
          .fetchServerInfo(
            serverId: 'my-qcid',
            serviceId: 'dsm_https',
            relayServer: null,
          )
          .catchError((_) => throw 'should not fail');

      final body = fake.requests.last['body'] as Map<String, dynamic>;
      expect(body['version'], 1); // 数字
      expect(body['command'], 'get_server_info');
      expect(body['serverID'], 'my-qcid');
      expect(body['id'], 'dsm_https'); // 两阶段都用 "id"
      expect(body['get_ca_fingerprints'], true);
      expect(body.length, 5);
    });

    test('解析 env / server / smartdns / service / relay_servers', () async {
      fake.handlers['get_server_info'] = (_) => serverInfoResponse();
      final info = await api.fetchServerInfo(
        serverId: 'my-qcid',
        serviceId: 'dsm_https',
      );

      expect(info.env?.relayRegion, 'tw');
      expect(info.env?.controlHost, 'global.quickconnect.to');
      expect(info.server?.external, '203.0.113.5');
      expect(info.server?.udpPunchPort, 51342);
      expect(info.server?.tcpPunchPort, 51343);
      expect(info.server?.behindNat, isTrue);
      expect(info.server?.interfaceIps, ['192.168.1.10']);
      expect(info.smartdns?.host, 'my-qcid.direct.quickconnect.to');
      expect(info.smartdns?.lans, ['192.168.1.10']);
      expect(info.servicePort, 5001);
      expect(info.relayServers, ['relay1.example.com', 'relay2.example.com']);
    });

    test('缺少 server 字段 → 抛异常', () async {
      fake.handlers['get_server_info'] = (_) => {
        'errno': 0,
        'env': <String, dynamic>{},
      };
      await expectLater(
        api.fetchServerInfo(serverId: 'q', serviceId: 'dsm_https'),
        throwsA(isA<ServApiException>()),
      );
    });

    test('errno != 0 → 抛异常', () async {
      fake.handlers['get_server_info'] = (_) => {
        'errno': 3,
        'server': <String, dynamic>{},
      };
      await expectLater(
        api.fetchServerInfo(serverId: 'q', serviceId: 'dsm_https'),
        throwsA(isA<ServApiException>().having((e) => e.errno, 'errno', 3)),
      );
    });
  });

  group('resolve 早退分支', () {
    late FakeServ fake;
    late ServApi api;

    setUp(() async {
      fake = FakeServ();
      await fake.start();
      api = apiFor(fake);
    });
    tearDown(() => fake.stop());

    test('全球服务器未给 relay_servers 时直接返回', () async {
      fake.handlers['get_server_info'] = (_) => {
        'errno': 0,
        'server': {'external': '1.2.3.4', 'udp_punch_port': 100},
      };
      final info = await api.resolve(serverId: 'q', serviceId: 'dsm_https');
      expect(info.server?.external, '1.2.3.4');
      expect(info.relayServers, isEmpty);
    });

    test('无 server 且无 relay_servers → 抛异常', () async {
      fake.handlers['get_server_info'] = (_) => {
        'errno': 0,
        'relay_servers': <String>[],
      };
      await expectLater(
        api.resolve(serverId: 'q', serviceId: 'dsm_https'),
        throwsA(isA<ServApiException>()),
      );
    });
  });

  group('punchCandidates 优先级', () {
    test('smartdns.host 优先，其次 external，端口取 udp_punch_port', () {
      final info = DsmInfo.fromJson({
        'server': {
          'external': '203.0.113.5',
          'ddns': 'qc.direct.quickconnect.to',
          'udp_punch_port': 51342,
          'interface': [
            {'ip': '192.168.1.10'},
          ],
        },
        'smartdns': {'host': 'qc.direct.quickconnect.to'},
      });

      final c = info.punchCandidates();
      expect(c.first.host, 'qc.direct.quickconnect.to');
      expect(c.first.source, 'smartdns');
      expect(c.every((e) => e.port == 51342), isTrue);
      // smartdns.host 与 ddns 相同 → 只出现一次
      expect(c.where((e) => e.host == 'qc.direct.quickconnect.to').length, 1);
      expect(
        c.map((e) => e.host),
        containsAll(['203.0.113.5', '192.168.1.10']),
      );
    });

    test('udp_punch_port 缺失 → 无候选', () {
      final info = DsmInfo.fromJson({
        'server': {'external': '1.2.3.4'},
      });
      expect(info.punchCandidates(), isEmpty);
    });

    test('external 与 host 相同 → 去重', () {
      final info = DsmInfo.fromJson({
        'server': {'external': '1.2.3.4', 'udp_punch_port': 100},
        'smartdns': {'host': '1.2.3.4'},
      });
      expect(info.punchCandidates().length, 1);
      expect(info.punchCandidates().single.source, 'smartdns');
    });
  });

  group('链接常量', () {
    test('全球/中国站点 URL 与 .so 字符串表一致', () {
      expect(ServEndpoint.worldwide, 'https://global.quickconnect.to/Serv.php');
      expect(ServEndpoint.china, 'https://global.quickconnect.cn/Serv.php');
    });

    test('useChinaSite 影响控制服务器 URL', () {
      expect(
        ServApi(useChinaSite: false).controlServerUrl,
        ServEndpoint.worldwide,
      );
      expect(ServApi(useChinaSite: true).controlServerUrl, ServEndpoint.china);
      // 覆盖优先
      expect(
        ServApi(useChinaSite: true, controlUrl: 'http://x/').controlServerUrl,
        'http://x/',
      );
    });
  });

  // ─────────── D4：**非中国区**顺序 = WW 主、失败后回落 CN（离线）
  //
  // 落到这一组的**顺序**依据（`[取证]` SPK 服务端）：
  // `QuickConnect-x86_64-1.0.6-0134.spk` 的 `webapi/SYNO.Core.QuickConnect.so` 里
  //   SYNO::Relay::SendControlServRequestWithFailover(...)
  //   "%s:%d failover to global.quickconnect.cn request"
  //   "%s:%d serv request failed after trying global.quickconnect.to & global.quickconnect.cn"
  // 与 `etc/synosupauthd.conf` 的
  //   "control_server_host": "global.quickconnect.to" /
  //   "control_server_host_fallback": "global.quickconnect.cn"。
  // ★ 官方**客户端**对中国区设备是 **CN 优先**（见下面 D4b 组），
  //   所以本组用例一律**显式注入 `deviceInChina: false`** —— 不许让结果
  //   跟着跑测机器的 locale 变（§2.0.28 的假红来源）。
  group('D4 非中国区：WW 主 + 失败后回落 CN（假 Dio，零联网）', () {
    final wwHost = Uri.parse(ServEndpoint.worldwide).host;
    final cnHost = Uri.parse(ServEndpoint.china).host;

    /// entry 形态：给了 server 且不带 relay ⇒ `resolve` 早退，恰好一次请求
    Map<String, dynamic> entry(String external) => {
      'errno': 0,
      'env': {'control_host': 'global.quickconnect.to', 'relay_region': 'tw'},
      'server': {'external': external, 'udp_punch_port': 100},
      'relay_servers': <String>[],
    };

    test('① worldwide 失败 ⇒ 必须尝试 CN，并采用 CN 的结果', () async {
      final hits = <String>[];
      final api = ServApi(
        dio: endpointDio(
          hits,
          (host) => host == cnHost ? entry('198.51.100.7') : null,
        ),
        deviceInChina: false,
      );

      final info = await api.resolve(serverId: 'q', serviceId: 'dsm_https');

      expect(hits, [wwHost, cnHost], reason: '先 worldwide、失败后才 CN');
      expect(info.server?.external, '198.51.100.7');
    });

    test('② worldwide 成功 ⇒ 绝不碰 CN（反向验证：不是无条件乱试）', () async {
      final hits = <String>[];
      final api = ServApi(
        dio: endpointDio(hits, (host) => entry('203.0.113.9')),
        deviceInChina: false,
      );

      final info = await api.resolve(serverId: 'q', serviceId: 'dsm_https');

      expect(hits, [wwHost]);
      expect(hits, isNot(contains(cnHost)), reason: '成功就不许回落');
      expect(info.server?.external, '203.0.113.9');
    });

    test('③ 两个都失败 ⇒ 抛回 worldwide 原始错误（与不回落时逐字节一致）', () async {
      Future<String> errorText({required bool fallback}) async {
        final hits = <String>[];
        final api = ServApi(
          dio: endpointDio(hits, (_) => null),
          fallbackToChinaSite: fallback,
          deviceInChina: false,
        );
        try {
          await api.resolve(serverId: 'q', serviceId: 'dsm_https');
          fail('两个端点都不可达时必须抛出');
        } catch (e) {
          expect(hits.first, wwHost);
          // 关掉回落时只能碰 worldwide；开着时碰两个
          expect(hits, fallback ? [wwHost, cnHost] : [wwHost]);
          return '$e';
        }
      }

      final withFallback = await errorText(fallback: true);
      final withoutFallback = await errorText(fallback: false);

      expect(
        withFallback,
        withoutFallback,
        reason: '错误路径不许因回落而改变（不吞错、不换文案）',
      );
      expect(withFallback, contains(wwHost), reason: '抛的是 worldwide 的错误');
      expect(withFallback, isNot(contains(cnHost)), reason: '不许换成 CN 的文案');
    });

    test('④ useChinaSite 是"显式选站点"：与区域判定/回落语义互不影响', () async {
      for (final inChina in [true, false]) {
        final hits = <String>[];
        final api = ServApi(
          dio: endpointDio(hits, (_) => null),
          useChinaSite: true,
          deviceInChina: inChina,
        );
        expect(api.controlServerUrl, ServEndpoint.china);
        expect(
          await api.controlServerCandidates(),
          [ServEndpoint.china],
          reason: '显式选站点 ⇒ 候选唯一，不受 deviceInChina=$inChina 影响',
        );

        await expectLater(
          api.resolve(serverId: 'q', serviceId: 'dsm_https'),
          throwsA(isA<DioException>()),
        );
        expect(hits, [cnHost], reason: '显式 CN 时一次都不碰 worldwide');
      }
    });

    test('⑤ controlUrl 覆盖 ⇒ 候选唯一（离线单测绝不联网）', () async {
      final api = ServApi(
        controlUrl: 'http://127.0.0.1:9/Serv.php',
        deviceInChina: true,
        dio: Dio(),
      );
      expect(await api.controlServerCandidates(), [
        'http://127.0.0.1:9/Serv.php',
      ]);
    });

    test('⑥ 关掉回落 ⇒ 非中国区只剩 WW（"想只 WW 就关它"）', () async {
      final api = ServApi(fallbackToChinaSite: false, deviceInChina: false);
      expect(await api.controlServerCandidates(), [ServEndpoint.worldwide]);
    });
  });

  // ─────────── D4b：**官方客户端顺序** —— 中国区 CN 优先（离线，零联网）
  //
  // `[取证]` 官方 APK `Android-DSfinder.2.5.7-484.ww.apk` 的
  // `com/synology/sylibx/syhttp3/relay/RelayManager.smali` → `fetchRelayOrEnv`：
  //   · 先 `new ApiRelayServers(serverId, serviceId, false)` 造 **WW** 任务（行 501-505）；
  //   · `QuickConnectUtil.isDeviceInChina(context)` 为真时再造
  //     `ApiRelayServers(serverId, serviceId, true)` = **CN** 任务并**先 add**
  //     （行 527-532），随后 `:cond_0` 才 add WW（行 536）⇒ list = `[CN, WW]`；
  //     **非中国区 list 只有 `[WW]`**（CN 任务根本不造）；
  //   · 迭代体：`submit` 一个 → 立刻 `take` 一个；**失败才 `goto :goto_0`** 取下一个
  //     ⇒ **严格顺序、非并发**。
  // 结论：中国区设备官方是 **CN 优先、失败才试 WW** —— 我们照这个。
  // ★ 本组一律**显式注入 `deviceInChina`**，否则结果会跟着跑测机器的 locale 变。
  group('D4b 官方客户端顺序：中国区 CN 优先（假 Dio，零联网）', () {
    final wwHost = Uri.parse(ServEndpoint.worldwide).host;
    final cnHost = Uri.parse(ServEndpoint.china).host;

    Map<String, dynamic> entry(String external) => {
      'errno': 0,
      'env': {'control_host': 'global.quickconnect.cn', 'relay_region': 'cn'},
      'server': {'external': external, 'udp_punch_port': 100},
      'relay_servers': <String>[],
    };

    test('① 中国区 + CN 成功 ⇒ 只碰 CN，绝不碰 WW', () async {
      final hits = <String>[];
      final api = ServApi(
        dio: endpointDio(
          hits,
          (host) => host == cnHost ? entry('198.51.100.11') : null,
        ),
        deviceInChina: true,
      );
      expect(await api.controlServerCandidates(), [
        ServEndpoint.china,
        ServEndpoint.worldwide,
      ], reason: '中国区 = [CN, WW]（官方 list 顺序）');

      final info = await api.resolve(serverId: 'q', serviceId: 'dsm_https');

      expect(hits, [cnHost], reason: 'CN 第一个且成功了');
      expect(hits, isNot(contains(wwHost)), reason: 'CN 成功就不许碰 WW');
      expect(info.server?.external, '198.51.100.11');
    });

    test('② 中国区 + CN 失败 ⇒ 才试 WW，并采用 WW 的结果', () async {
      final hits = <String>[];
      final api = ServApi(
        dio: endpointDio(
          hits,
          (host) => host == wwHost ? entry('203.0.113.21') : null,
        ),
        deviceInChina: true,
      );

      final info = await api.resolve(serverId: 'q', serviceId: 'dsm_https');

      expect(hits, [cnHost, wwHost], reason: 'CN 先、WW 后（顺序，非并发）');
      expect(info.server?.external, '203.0.113.21');
    });

    test('③ 非中国区 ⇒ 先 WW（断言第一个碰的不是 CN）', () async {
      final hits = <String>[];
      final api = ServApi(
        dio: endpointDio(hits, (_) => entry('203.0.113.31')),
        deviceInChina: false,
      );
      expect(await api.controlServerCandidates(), [
        ServEndpoint.worldwide,
        ServEndpoint.china,
      ]);

      await api.resolve(serverId: 'q', serviceId: 'dsm_https');

      expect(hits.first, wwHost, reason: '非中国区第一个必须是 WW');
      expect(hits, isNot(equals([cnHost, wwHost])), reason: '顺序反过来就是错的');
    });

    test('④ 两端都失败 ⇒ 抛回**最先尝试**那次的原始异常（含原始栈）', () async {
      Future<void> check({
        required bool inChina,
        required String firstHost,
      }) async {
        final hits = <String>[];
        final rejected = <String, DioException>{};
        final api = ServApi(
          dio: endpointDio(hits, (_) => null, rejected: rejected),
          deviceInChina: inChina,
        );

        Object? thrown;
        try {
          await api.resolve(serverId: 'q', serviceId: 'dsm_https');
          fail('两个端点都不可达时必须抛出');
        } catch (e) {
          thrown = e;
        }

        expect(hits, hasLength(2), reason: '两个候选都要试过');
        expect(hits.first, firstHost, reason: '中国区先 CN、非中国区先 WW');
        expect(
          identical(thrown, rejected[firstHost]),
          isTrue,
          reason: '必须是**最先尝试**那次的**原始异常对象**，不是后一个端点的',
        );
        final otherHost = hits[1];
        expect('$thrown', contains(firstHost));
        expect('$thrown', isNot(contains(otherHost)), reason: '不许换成后一个端点的文案');
      }

      await check(inChina: true, firstHost: cnHost);
      await check(inChina: false, firstHost: wwHost);
    });

    test('⑤ 未注入区域 ⇒ 走官方判定链：MCC 拿不到（null）才回落 locale', () async {
      var mccCalls = 0;
      final api = ServApi(
        networkCountryIsoProbe: () async {
          mccCalls++;
          return null; // 模拟"桥拿不到"（非 Android / 无电话服务）
        },
      );
      final candidates = await api.controlServerCandidates();

      expect(mccCalls, greaterThanOrEqualTo(1), reason: '接线不是摆设：MCC 探针必须被问过');
      expect(candidates, hasLength(2));
      expect(candidates.toSet(), hasLength(2), reason: '同一条 URL 不许重复出现');
      expect(candidates, contains(ServEndpoint.worldwide));
      expect(candidates, contains(ServEndpoint.china));
      // MCC 为 null ⇒ 回落"本机平台 locale"（与纯函数同源，故结果自洽）
      final byLocale = ServApi.deviceInChinaFrom(
        localeCountryCode: platformLocale()?.countryCode,
      );
      expect(
        candidates.first,
        byLocale ? ServEndpoint.china : ServEndpoint.worldwide,
        reason: 'MCC 拿不到 ⇒ 回落 locale，两条路径用的是同一个判定函数',
      );
    });

    // ★ 本轮要修的那类用户：**网络在中国、但系统 locale 不是中文**
    // （例如手机语言设成 en-US、人在中国）。官方靠 `getNetworkCountryIso()` 兜住，
    // 我们此前只看 locale ⇒ 误判非中国区 ⇒ 先试 `.to` ⇒ 首次登录更慢。
    //
    // ⑧ 是它的反向：**MCC 说了算，locale 不许翻盘**（哪怕本机 locale 恰好是中文）。
    // 这两条都**与跑测机器的 locale 无关**，所以不会随环境漂。
    test('⑦ MCC=cn ⇒ 判中国区，即使 locale 看不出中国', () async {
      final hits = <String>[];
      final api = ServApi(
        dio: endpointDio(
          hits,
          (host) => host == cnHost ? entry('198.51.100.41') : null,
        ),
        networkCountryIsoProbe: () async => 'cn',
      );
      expect(await api.controlServerCandidates(), [
        ServEndpoint.china,
        ServEndpoint.worldwide,
      ], reason: 'MCC=cn ⇒ CN 优先（官方第一顺位）');

      final info = await api.resolve(serverId: 'q', serviceId: 'dsm_https');
      expect(hits, [cnHost], reason: 'CN 成功 ⇒ 一次都不碰 worldwide');
      expect(info.server?.external, '198.51.100.41');
    });

    test('⑧ MCC=us ⇒ 非中国区（MCC 优先，locale 不许翻盘）', () async {
      final api = ServApi(networkCountryIsoProbe: () async => 'us');
      expect(await api.controlServerCandidates(), [
        ServEndpoint.worldwide,
        ServEndpoint.china,
      ], reason: 'MCC 非空 ⇒ 只看 MCC，与 locale 无关');
    });

    test('⑨ 注入的 deviceInChina 压过 MCC 探针（概念②只有一个结论来源）', () async {
      var mccCalls = 0;
      final api = ServApi(
        deviceInChina: true,
        networkCountryIsoProbe: () async {
          mccCalls++;
          return 'us'; // 即使 MCC 说美国
        },
      );
      expect(await api.controlServerCandidates(), [
        ServEndpoint.china,
        ServEndpoint.worldwide,
      ]);
      expect(mccCalls, 0, reason: '已注入结论就不该再去问平台（也不该被 MCC 翻盘）');
    });
  });

  // ─────────── D4c：`isDeviceInChina` 的官方分支（纯函数，零网络）
  //
  // `[取证]` 官方 `QuickConnectUtil.isDeviceInChina(Context)`
  // （APK `Android-DSfinder.2.5.7-484.ww.apk`）：
  //   ① `getApplicationContext()==null` ⇒ false；② 拿不到 `TelephonyManager` ⇒ false；
  //   ③ `getNetworkCountryIso()` **非空** ⇒ `"cn".equals(iso, ignoreCase)` **到此为止**；
  //   ④ ③ 为空 ⇒ `locales[0].getISO3Country() == "CHN"`；
  //   ⑤ 取不到 ⇒ false。
  group('D4c isDeviceInChina 官方分支（纯函数，零网络）', () {
    test('③ MCC 非空 ⇒ 只看 MCC，locale 不参与', () {
      expect(
        ServApi.deviceInChinaFrom(
          networkCountryIso: 'cn',
          localeCountryCode: 'US',
        ),
        isTrue,
      );
      expect(
        ServApi.deviceInChinaFrom(
          networkCountryIso: 'CN',
          localeCountryCode: 'US',
        ),
        isTrue,
        reason: 'ignoreCase',
      );
      expect(
        ServApi.deviceInChinaFrom(
          networkCountryIso: 'us',
          localeCountryCode: 'CN',
        ),
        isFalse,
        reason: 'MCC 说是美国 ⇒ 不看 locale',
      );
    });

    test('④ MCC 为空 ⇒ 回落 locale（CHN 与 CN 两种书写都收）', () {
      expect(
        ServApi.deviceInChinaFrom(
          networkCountryIso: '',
          localeCountryCode: 'CHN',
        ),
        isTrue,
        reason: 'Android 的 getISO3Country()',
      );
      expect(
        ServApi.deviceInChinaFrom(
          networkCountryIso: '   ',
          localeCountryCode: 'CN',
        ),
        isTrue,
        reason: 'Dart 的 Locale.countryCode 是 alpha-2',
      );
      expect(
        ServApi.deviceInChinaFrom(
          networkCountryIso: null,
          localeCountryCode: 'chn',
        ),
        isTrue,
      );
      expect(
        ServApi.deviceInChinaFrom(
          networkCountryIso: null,
          localeCountryCode: 'US',
        ),
        isFalse,
      );
    });

    test('⑤ 都取不到 ⇒ 非中国区（fail-safe，不是"猜中国"）', () {
      expect(ServApi.deviceInChinaFrom(), isFalse);
      expect(
        ServApi.deviceInChinaFrom(networkCountryIso: '', localeCountryCode: null),
        isFalse,
      );
      expect(
        ServApi.deviceInChinaFrom(
          networkCountryIso: '  ',
          localeCountryCode: '  ',
        ),
        isFalse,
      );
    });
  });
}

// ─────────────────────────── errno != 0 的语义（原库实证）
//
// 原库 DSMInfo.parseServerInfo：
//   errno != 0 且 sites[] 非空 → sites 就是**中继服务器列表**，不是错误
//   errno != 0 且 sites 为空   → 才是真失败
void _errnoSemantics() {
  group('get_server_info 的 errno != 0 语义', () {
    test('errno=4 + sites → 当作中继服务器列表，不抛异常', () {
      final info = DsmInfo.fromJson({
        'errno': 4,
        'sites': ['relay-a.example.com', 'relay-b.example.com'],
      });
      expect(info.relayServers, ['relay-a.example.com', 'relay-b.example.com']);
      expect(info.server, isNull);
    });

    test('errno=0 时从 relay_servers 取', () {
      final info = DsmInfo.fromJson({
        'errno': 0,
        'relay_servers': ['r1.example.com'],
      });
      expect(info.relayServers, ['r1.example.com']);
    });

    test('两个来源都有时合并去重', () {
      final info = DsmInfo.fromJson({
        'errno': 0,
        'relay_servers': ['a', 'b'],
        'sites': ['b', 'c'],
      });
      expect(info.relayServers, ['a', 'b', 'c']);
    });

    test('sites 里的空串会被丢掉', () {
      final info = DsmInfo.fromJson({
        'errno': 4,
        'sites': ['a', '', 'b'],
      });
      expect(info.relayServers, ['a', 'b']);
    });
  });
}

// ─────────────────────────── 真实响应结构回归
//
// 夹具是真实 NAS 的 get_server_info 响应。之前 `server.external` 被按
// `as String?` 解析，真机上抛 type cast 异常；这个测试钉住它。
void _realResponseShape() {
  group('真实 get_server_info 响应解析', () {
    late Map<String, dynamic> body;

    setUpAll(() {
      body =
          jsonDecode(
                File('test/fixtures_serv_server_info.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
    });

    test('server.external 是对象，要取 .ip', () {
      final ext = body['server']['external'];
      expect(ext, isA<Map>(), reason: '真实响应里 external 是 {ip, ipv6}');
      final info = DsmInfo.fromJson(body);
      expect(info.server!.external, '115.204.122.167');
    });

    test('解析整体不抛异常', () {
      final info = DsmInfo.fromJson(body);
      expect(info.server, isNotNull);
      expect(info.server!.udpPunchPort, 48743);
      expect(info.server!.tcpPunchPort, 0);
      expect(info.env!.controlHost, 'cnc.quickconnect.cn');
      expect(info.env!.relayRegion, 'cn');
      expect(info.servicePort, 5001);
      expect(info.server!.interfaceIps, contains('nas.example.com'));
    });

    test('fqdn 字面量 "NULL" 视为无值', () {
      expect(body['server']['fqdn'], 'NULL');
      final info = DsmInfo.fromJson(body);
      expect(info.server!.fqdn, 'NULL');
      // punchCandidates 里应把它过滤掉
      final cands = info.punchCandidates();
      expect(cands.any((c) => c.host.startsWith('NULL')), isFalse);
    });

    test('external 是纯字符串时也认（兼容旧格式）', () {
      final alt = Map<String, dynamic>.from(body);
      alt['server'] = Map<String, dynamic>.from(body['server'] as Map)
        ..['external'] = '1.2.3.4';
      expect(DsmInfo.fromJson(alt).server!.external, '1.2.3.4');
    });

    test('external 缺失 / 空串 / "NULL" 都归为 null', () {
      for (final v in [null, '', 'NULL', <String, dynamic>{}]) {
        final alt = Map<String, dynamic>.from(body);
        alt['server'] = Map<String, dynamic>.from(body['server'] as Map)
          ..['external'] = v;
        expect(
          DsmInfo.fromJson(alt).server!.external,
          isNull,
          reason: 'input=$v',
        );
      }
    });
  });
}

// ─────────────────────────── smartdns.lan 回归
//
// 真实响应里是 `smartdns.lan`（单数）。早期按 `lans` 解析 → 永远空列表，
// 而官方 App 恰恰是先解析 `direct.quickconnect.cn` 失败、再用 LAN 形式连上的。
void _smartdnsLan() {
  group('smartdns 局域网名', () {
    late Map<String, dynamic> body;

    setUpAll(() {
      body =
          jsonDecode(
                File('test/fixtures_serv_server_info.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
    });

    test('真实响应字段是 lan（单数）', () {
      expect((body['smartdns'] as Map).containsKey('lan'), isTrue);
      expect((body['smartdns'] as Map).containsKey('lans'), isFalse);
    });

    test('解析出 SmartDNS 的 LAN 名', () {
      final info = DsmInfo.fromJson(body);
      expect(info.smartdns!.lans, isNotEmpty);
      expect(info.smartdns!.lans.first, contains('direct.quickconnect.cn'));
    });

    test('LAN 候选排在地址列表最前（官方 App 就是这么选的）', () {
      final cands = infoWithPort(body, 5001).httpCandidates();
      expect(cands, isNotEmpty);
      expect(cands.first.source, 'lan');
      expect(cands.first.baseUrl, startsWith('https://192-168-0-181.'));
    });

    test('lans 复数形态也认（兼容）', () {
      final alt = Map<String, dynamic>.from(body);
      alt['smartdns'] = {
        'host': 'h.example',
        'lans': ['a.example', 'b.example'],
      };
      expect(DsmInfo.fromJson(alt).smartdns!.lans, ['a.example', 'b.example']);
    });

    test('字符串形态的 lan 也能吃下', () {
      final alt = Map<String, dynamic>.from(body);
      alt['smartdns'] = {'lan': 'only.example'};
      expect(DsmInfo.fromJson(alt).smartdns!.lans, ['only.example']);
    });
  });
}

/// 夹具里的 service.port 是有的，这里只是显式注入端口以便断言候选 URL。
DsmInfo infoWithPort(Map<String, dynamic> body, int port) {
  final info = DsmInfo.fromJson(body);
  return DsmInfo(
    env: info.env,
    server: info.server,
    smartdns: info.smartdns,
    relayServers: info.relayServers,
    servicePort: port,
    serviceExtPort: info.serviceExtPort,
  );
}
