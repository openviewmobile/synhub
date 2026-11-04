// DsmWebApi 验证 —— 假 DSM 服务器 + 传输等价性
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:synhub/src/dsm/cgi_encryption.dart';
import 'package:synhub/src/dsm/webapi.dart';

/// 最小可用的假 DSM：query.cgi / auth.cgi / encryption.cgi / entry.cgi
///
/// **真的实现了 CGI 加密协议** —— 用私钥解开客户端发来的 cipherkey，
/// 所以这组测试验证的是"客户端是否正确实现了协议"，而不是"参数长得像不像"。
class FakeDsm {
  FakeDsm({
    this.password = 'secret',
    this.requireOtp = false,
    // 服务端声明的 Auth 最高版本（测 v7 / 退回 v6 用）
    this.authMaxVersion = 6,
    // 声明支持 v7，但真的用 v7 请求时回 104（老包的行为）
    this.rejectV7 = false,
  }) {
    _kp = generateTestRsaKeyPair(2048);
    _pubB64 = base64Encode(
      encodeX509RsaPublicKey(
        (_kp.publicKey as RSAPublicKey).modulus!,
        (_kp.publicKey as RSAPublicKey).exponent!,
      ),
    );
  }

  final String password;
  final bool requireOtp;
  final int authMaxVersion;
  final bool rejectV7;

  static const cipherKey = '__cIpHeRtExT';
  static const cipherToken = '__cIpHeRtOkEn';

  late final AsymmetricKeyPair<PublicKey, PrivateKey> _kp;
  late final String _pubB64;

  /// 测试用：解开最后一次请求里的凭据
  Map<String, String>? decryptLastCredentials() =>
      calls.isEmpty ? null : _decryptCredentials(calls.last);

  /// 解开客户端发来的凭据，返回明文键值对；失败返回 null
  Map<String, String>? _decryptCredentials(Map<String, String> p) {
    final enc = p[cipherKey];
    if (enc == null) return null;
    try {
      final engine = PKCS1Encoding(RSAEngine())
        ..init(
          false,
          PrivateKeyParameter<RSAPrivateKey>(_kp.privateKey as RSAPrivateKey),
        );
      final plain = utf8.decode(engine.process(base64Decode(enc)));
      // 明文形状：<cipherToken>=<ts>&account=..&passwd=..
      final qs = plain.split('&').skip(1).join('&');
      return Uri.splitQueryString(qs);
    } catch (_) {
      return null;
    }
  }

  late HttpServer _server;
  final List<Map<String, String>> calls = [];
  int _sidCounter = 0;
  final Set<String> _validSids = {};

  /// 原始 request body（`Uri.splitQueryString` 会把重复字段压掉，
  /// 验证 `has=thread&has=image` 这类重复字段必须看原文）
  final List<String> rawBodies = [];

  /// 每次请求收到的 `x-syno-token`（DSM 7.4 的 CSRF 头），没带就是 null
  final List<String?> synoTokenHeaders = [];

  int get port => _server.port;
  String get host => '127.0.0.1';

  /// 已成功登录次数（用于验证两条路径各自独立登录）
  int get loginCount => _validSids.length;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    final params = Uri.splitQueryString(body);
    calls.add(params);
    rawBodies.add(body);
    synoTokenHeaders.add(req.headers.value('x-syno-token'));

    final path = req.uri.path;
    if (path.endsWith('download.cgi')) {
      await _handleBinary(req, body);
      return;
    }
    req.response.headers.contentType = ContentType.json;

    Map<String, dynamic> out;
    if (path.endsWith('query.cgi')) {
      out = _query(params);
    } else if (path.endsWith('encryption.cgi')) {
      out = _encryption(params);
    } else if (path.endsWith('auth.cgi')) {
      out = _auth(params);
    } else {
      out = {
        'success': false,
        'error': {'code': DsmErrorCode.apiNotFound},
      };
    }
    req.response.write(jsonEncode(out));
    await req.response.close();
  }

  // ------------------------------------------------ 二进制下载 / 错误页（P0.1）

  /// 正常情况的正文（默认 1000 字节的伪随机序列）
  List<int> downloadBody = List<int>.generate(1000, (i) => (i * 7) % 256);

  /// 非空时：按 [downloadStatus] 返回一段 **HTML 错误页**（DSM 真实行为：
  /// Thumb 文件不存在 → 404、Download → 502，正文都是一整页 HTML）
  bool htmlError = false;
  int downloadStatus = 200;

  /// 非空时：正文是 JSON 错误（`{"error":{"code":…}}`），用于验错误码还原
  int? jsonErrorCode;

  /// 非空时：错误信封里再带一个 `name`（DSM 120 就是用它说"哪个参数不对"）。
  /// r387/DA36：这个字段**必须**活到 `DsmApiException.raw`。
  String? jsonErrorName;

  /// 正常二进制响应的 `content-type`（默认 `application/octet-stream`）。
  /// 用于验"真实二进制零回归"里不同内容类型（`image/png`、`text/plain`…）
  ContentType? downloadContentType;

  /// 每次请求收到的 `Range` 头
  final List<String?> rangeHeaders = [];

  Future<void> _handleBinary(HttpRequest req, String body) async {
    rangeHeaders.add(req.headers.value('range'));
    req.response.statusCode = downloadStatus;
    if (htmlError) {
      req.response.headers.contentType = ContentType.html;
      req.response.write(
        '<!DOCTYPE html><html><head><meta charset="utf-8"></head>'
        '<body>© Synology Inc. 404 Not Found</body></html>',
      );
      await req.response.close();
      return;
    }
    if (jsonErrorCode != null) {
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'success': false,
          'error': {
            'code': jsonErrorCode,
            if (jsonErrorName != null) 'name': jsonErrorName,
            if (jsonErrorName != null) 'reason': 'required',
          },
        }),
      );
      await req.response.close();
      return;
    }
    final range = req.headers.value('range');
    var data = downloadBody;
    if (range != null && range.startsWith('bytes=0-')) {
      final end = int.tryParse(range.substring('bytes=0-'.length)) ?? -1;
      if (end >= 0 && end + 1 < data.length) {
        req.response.statusCode = 206;
        req.response.headers.set(
          'content-range',
          'bytes 0-$end/${data.length}',
        );
        data = data.sublist(0, end + 1);
      }
    }
    req.response.headers.contentType =
        downloadContentType ?? ContentType.binary;
    req.response.add(data);
    await req.response.close();
  }

  Map<String, dynamic> _query(Map<String, String> p) {
    if (p['api'] != 'SYNO.API.Info') {
      return {
        'success': false,
        'error': {'code': DsmErrorCode.apiNotFound},
      };
    }
    return {
      'success': true,
      'data': {
        'SYNO.API.Info': {
          'path': 'query.cgi',
          'minVersion': 1,
          'maxVersion': 1,
        },
        'SYNO.API.Auth': {
          'path': 'auth.cgi',
          'minVersion': 1,
          'maxVersion': authMaxVersion,
        },
        'SYNO.API.Encryption': {
          'path': 'encryption.cgi',
          'minVersion': 1,
          'maxVersion': 1,
        },
        'SYNO.Entry.Request': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 2,
        },
        'SYNO.Chat.Channel': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 2,
        },
        // 故意声明一个较窄的区间，用来测版本收敛
        'SYNO.Legacy.Thing': {
          'path': 'legacy.cgi',
          'minVersion': 2,
          'maxVersion': 3,
        },
      },
    };
  }

  Map<String, dynamic> _encryption(Map<String, String> p) {
    if (p['api'] != 'SYNO.API.Encryption' || p['method'] != 'getinfo') {
      return {
        'success': false,
        'error': {'code': DsmErrorCode.apiNotFound},
      };
    }
    return {
      'success': true,
      'data': {
        'cipherkey': cipherKey,
        'ciphertoken': cipherToken,
        'public_key': _pubB64,
        'server_time': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      },
    };
  }

  Map<String, dynamic> _auth(Map<String, String> p) {
    if (p['method'] == 'logout') {
      _validSids.remove(p['_sid']);
      return {'success': true, 'data': {}};
    }
    if (p['method'] != 'login') {
      return {
        'success': false,
        'error': {'code': DsmErrorCode.methodNotFound},
      };
    }
    // 声明支持 v7 却不认 v7：走"自动退回 v6"那条分支
    if (rejectV7 && p['version'] == '7') {
      return {
        'success': false,
        'error': {'code': DsmErrorCode.notSupportedVersion},
      };
    }

    final creds = _decryptCredentials(p);
    if (creds == null) {
      return {
        'success': false,
        'error': {'code': DsmErrorCode.apiNotFound},
      };
    }
    if (creds['account'] != 'tester' || creds['passwd'] != password) {
      return {
        'success': false,
        'error': {'code': DsmErrorCode.authInvalidPassword},
      };
    }
    if (requireOtp) {
      // ⚠️ 真服务端（DS file 4.17.2 的 loginDsm）把 otp_code 当**明文参数**发，
      // 不放进密文里 —— 假服务端也必须照这个来，否则会掩盖"参数放错地方"的 bug
      if (p['otp_code'] == null || p['otp_code']!.isEmpty) {
        return {
          'success': false,
          'error': {'code': DsmErrorCode.authOtpRequired},
        };
      }
      if (p['otp_code'] != '123456') {
        return {
          'success': false,
          'error': {'code': DsmErrorCode.authOtpInvalid},
        };
      }
    }

    final sid = 'sid-${++_sidCounter}';
    _validSids.add(sid);
    final data = <String, dynamic>{'sid': sid};
    // 真服务端：登录成功后会把设备令牌 `did` 下发（有 OTP+信任、或已带 device_id）
    if (p['device_id'] != null || p['enable_device_token'] == 'yes') {
      data['did'] = 'did-abc';
    }
    // v5/v6/v7 都会在 enable_syno_token=yes 时回令牌（真机实测），
    // 但**只有 v7 的令牌能过 CSRF** —— 这里回一个可断言的假令牌
    if (p['enable_syno_token'] == 'yes') {
      data['synotoken'] = 'SAN.fake-token';
    }
    return {'success': true, 'data': data};
  }
}

/// 把请求转发到另一个地址的传输 —— 模拟「换一条网络路径」
class ForwardingTransport extends WebApiTransport {
  ForwardingTransport(this._inner, this._label);
  final WebApiTransport _inner;
  final String _label;
  int forwarded = 0;

  @override
  String get describeKind => 'forward(${_inner.describeKind} via $_label)';

  @override
  String get baseUrl => _inner.baseUrl;

  @override
  Future<String> postForm(
    String path,
    Map<String, dynamic> params, {
    String? module,
  }) {
    forwarded++;
    return _inner.postForm(path, params, module: module);
  }

  @override
  Future<String> describe({String? module}) {
    forwarded++;
    return _inner.describe(module: module);
  }

  @override
  Future<void> close() async {}
}

DirectTransport directTo(FakeDsm dsm) =>
    DirectTransport(host: dsm.host, port: dsm.port, https: false);

void main() {
  late FakeDsm dsm;
  late DsmWebApi api;

  setUp(() async {
    dsm = FakeDsm();
    await dsm.start();
    api = DsmWebApi(directTo(dsm));
  });
  tearDown(() async {
    await dsm.stop();
  });

  group('discover（SYNO.API.Info/query）', () {
    test('拿到 API 表并解析 path / 版本区间', () async {
      final table = await api.discover();
      expect(table.keys, contains('SYNO.API.Auth'));
      expect(table['SYNO.API.Auth']!.path, 'auth.cgi');
      expect(table['SYNO.API.Auth']!.minVersion, 1);
      expect(table['SYNO.API.Auth']!.maxVersion, 6);
    });

    test('请求参数与 APK 一致：version=1, method=query, query=all', () async {
      await api.discover();
      final c = dsm.calls.last;
      expect(c['api'], 'SYNO.API.Info');
      expect(c['version'], '1');
      expect(c['method'], 'query');
      expect(c['query'], 'all');
    });

    test('ping() 在可达时返回 true', () async {
      expect(await api.ping(), isTrue);
    });
  });

  group('版本收敛 negotiate', () {
    test('preferred 高出上界 → 取 maxVersion', () {
      const e = DsmApiEntry(name: 'x', path: 'p', minVersion: 2, maxVersion: 3);
      expect(e.negotiate(9), 3);
    });

    test('preferred 低于下界 → 取 minVersion', () {
      const e = DsmApiEntry(name: 'x', path: 'p', minVersion: 2, maxVersion: 3);
      expect(e.negotiate(1), 2);
    });

    test('区间内 → 保持 preferred', () {
      const e = DsmApiEntry(name: 'x', path: 'p', minVersion: 1, maxVersion: 6);
      expect(e.negotiate(4), 4);
    });

    test('call() 实际发出的 version 被收敛（min 2 / max 3，请求 9）', () async {
      await api.discover();
      // 假服务器未实现 legacy.cgi，会返回 apiNotFound；这里只关心发出的参数
      await expectLater(
        api.call('SYNO.Legacy.Thing', 'get', preferredVersion: 9),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.apiNotFound,
          ),
        ),
      );
      expect(dsm.calls.last['version'], '3'); // 9 被收敛到 maxVersion
      expect(dsm.calls.last['api'], 'SYNO.Legacy.Thing');
    });

    test('call() 使用 API 表里的 path（entry.cgi）', () async {
      await api.discover();
      await expectLater(
        api.call('SYNO.Chat.Channel', 'list', preferredVersion: 2),
        throwsA(isA<DsmApiException>()),
      );
      expect(dsm.calls.last['api'], 'SYNO.Chat.Channel');
      expect(dsm.calls.last['version'], '2');
      // 未在表里的 API 会直接判 apiNotFound，不会发出请求
      final before = dsm.calls.length;
      await expectLater(
        api.call('SYNO.Nonexistent.Api', 'x'),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.apiNotFound,
          ),
        ),
      );
      expect(dsm.calls.length, before, reason: '表里没有的 API 不应发出请求');
    });
  });

  group('login（SYNO.API.Auth）', () {
    test('成功登录拿到 sid', () async {
      final s = await api.login(account: 'tester', password: 'secret');
      expect(s.sid, isNotEmpty);
      expect(s.account, 'tester');
      expect(api.session?.sid, s.sid);
    });

    test('请求参数与原库一致：只加密凭据，其余明文', () async {
      await api.login(account: 'tester', password: 'secret');
      final c = dsm.calls.last;

      // 固定三件套
      expect(c['api'], 'SYNO.API.Auth');
      expect(c['method'], 'login');
      expect(c['version'], '6'); // 收敛到服务器 maxVersion

      // 凭据走密文字段，**不以明文出现**
      expect(
        c.containsKey(FakeDsm.cipherKey),
        isTrue,
        reason: '应有 cipherkey 字段',
      );
      expect(c.containsKey('account'), isFalse, reason: 'account 不该明文');
      expect(c.containsKey('passwd'), isFalse, reason: 'passwd 不该明文');

      // 其余作为明文并排发送
      expect(c['session'], 'Chat'); // LoggerUtil.TAG
      expect(c['client_time'], isNotNull);
      expect(c['device_name'], isNotNull);

      // 且服务器能用私钥解开，得到原始凭据
      final creds = dsm.decryptLastCredentials();
      expect(creds!['account'], 'tester');
      expect(creds['passwd'], 'secret');
    });

    test('DSM 7.4 的 CSRF：登录要令牌，之后每个请求都带 X-SYNO-TOKEN', () async {
      // 服务端支持 Auth v7 时，必须用 v7 登录：**只有 v7 发的 synotoken
      // 能过 `SYNO.FileStation.Compress.start` 的 CSRF 校验**（v6 的令牌
      // 会被回一个非常误导的 105，真机实测 DSM 7.4.1-90080）。
      await dsm.stop();
      dsm = FakeDsm(authMaxVersion: 7);
      await dsm.start();
      api = DsmWebApi(
        DirectTransport(host: dsm.host, port: dsm.port, https: false),
      );

      final s = await api.login(account: 'tester', password: 'secret');
      expect(s.synotoken, 'SAN.fake-token');
      final c = dsm.calls.last;
      expect(c['version'], '7', reason: '要令牌就得用 Auth v7');
      expect(c['enable_syno_token'], 'yes');
      // 传输层已经挂上令牌
      expect(api.transport.synoToken, 'SAN.fake-token');
      // 登录请求本身还没令牌（令牌是这次响应才拿到的）
      expect(dsm.synoTokenHeaders.first, isNull);

      // URL 型加载器（Image.network 那种带不了头的）走查询串
      final url = api.transport.authenticatedUrl('entry.cgi', {
        'api': 'SYNO.FileStation.Download',
        'method': 'download',
      }, sid: s.sid);
      expect(url, contains('SynoToken=SAN.fake-token'));
      expect(url, contains('_sid='));

      // 后续带鉴权的请求自动带头（logout 走 auth.cgi，假服务端认）
      await api.logout();
      expect(dsm.synoTokenHeaders.last, 'SAN.fake-token');
    });

    test('服务端不认 v7（104）→ 自动退回 v6 再试一次', () async {
      await dsm.stop();
      dsm = FakeDsm(authMaxVersion: 7, rejectV7: true);
      await dsm.start();
      api = DsmWebApi(
        DirectTransport(host: dsm.host, port: dsm.port, https: false),
      );

      final s = await api.login(account: 'tester', password: 'secret');
      expect(s.sid, isNotEmpty);
      final versions = dsm.calls
          .where((c) => c['api'] == 'SYNO.API.Auth' && c['method'] == 'login')
          .map((c) => c['version'])
          .toList();
      expect(versions, ['7', '6'], reason: '先试 7，被拒后退回 6');
    });

    test('OTP 缺失（403）不会被"退回 v6"吞掉', () async {
      await dsm.stop();
      dsm = FakeDsm(authMaxVersion: 7, requireOtp: true);
      await dsm.start();
      api = DsmWebApi(
        DirectTransport(host: dsm.host, port: dsm.port, https: false),
      );

      await expectLater(
        api.login(account: 'tester', password: 'secret'),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.authOtpRequired,
          ),
        ),
      );
      final logins = dsm.calls
          .where((c) => c['api'] == 'SYNO.API.Auth' && c['method'] == 'login')
          .length;
      expect(logins, 1, reason: '要验证码就是结果，别再拿密码撞一次');
    });

    test('logout 会摘掉传输层上的令牌', () async {
      await dsm.stop();
      dsm = FakeDsm(authMaxVersion: 7);
      await dsm.start();
      api = DsmWebApi(
        DirectTransport(host: dsm.host, port: dsm.port, https: false),
      );

      await api.login(account: 'tester', password: 'secret');
      expect(api.transport.synoToken, isNotNull);
      await api.logout();
      expect(api.transport.synoToken, isNull);
    });

    test('带 device_id（上次的 did）时回传 did', () async {
      final s = await api.login(
        account: 'tester',
        password: 'secret',
        deviceId: 'dev-1',
        deviceName: 'Pixel',
        enableDeviceToken: true,
      );
      expect(s.did, 'did-abc');
      final c = dsm.calls.last;
      // 原库 `loginDsm`：带 device_id 时同时给 device_name，
      // 而 enable_device_token 只在"这次有验证码"时才发
      expect(c['device_id'], 'dev-1');
      expect(c['device_name'], 'Pixel');
      expect(c['enable_device_token'], isNull);
    });

    test('OTP + 信任设备：otp_code / enable_device_token 必须是**明文**参数', () async {
      // 这条是"记住此设备"的根：塞进密文里服务端读不到 → 永远拿不到 did
      await dsm.stop();
      dsm = FakeDsm(requireOtp: true);
      await dsm.start();
      api = DsmWebApi(
        DirectTransport(host: dsm.host, port: dsm.port, https: false),
      );

      final s = await api.login(
        account: 'tester',
        password: 'secret',
        otpCode: '123456',
        deviceName: 'Pixel',
        enableDeviceToken: true,
      );
      final c = dsm.calls.last;
      expect(c['otp_code'], '123456', reason: '明文参数（原库如此）');
      expect(c['enable_device_token'], 'yes');
      expect(s.did, 'did-abc', reason: '服务端下发的设备令牌');
      // 密文里**不该**再出现这两个键
      final creds = dsm.decryptLastCredentials()!;
      expect(creds.containsKey('otp_code'), isFalse);
      expect(creds.containsKey('enable_device_token'), isFalse);
    });

    test('密码错误 → code 400', () async {
      await expectLater(
        api.login(account: 'tester', password: 'wrong'),
        throwsA(
          isA<DsmApiException>()
              .having((e) => e.code, 'code', DsmErrorCode.authInvalidPassword)
              .having((e) => e.badCredentials, 'badCredentials', isTrue),
        ),
      );
      expect(api.session, isNull);
    });

    test('需要 OTP → code 403，nextOtp 标志可用', () async {
      final otpDsm = FakeDsm(requireOtp: true);
      await otpDsm.start();
      final otpApi = DsmWebApi(directTo(otpDsm));
      addTearDown(otpDsm.stop);

      await expectLater(
        otpApi.login(account: 'tester', password: 'secret'),
        throwsA(
          isA<DsmApiException>()
              .having((e) => e.code, 'code', DsmErrorCode.authOtpRequired)
              .having((e) => e.needsOtp, 'needsOtp', isTrue),
        ),
      );

      // 带正确 OTP 再试
      final s = await otpApi.login(
        account: 'tester',
        password: 'secret',
        otpCode: '123456',
      );
      expect(s.sid, isNotEmpty);
    });

    test('OTP 错误 → code 404', () async {
      final otpDsm = FakeDsm(requireOtp: true);
      await otpDsm.start();
      final otpApi = DsmWebApi(directTo(otpDsm));
      addTearDown(otpDsm.stop);

      await expectLater(
        otpApi.login(account: 'tester', password: 'secret', otpCode: '000000'),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.authOtpInvalid,
          ),
        ),
      );
    });

    test('登录后带 _sid，登出后清空', () async {
      await api.login(account: 'tester', password: 'secret');
      await api.logout();
      expect(api.session, isNull);
      expect(dsm.calls.last['method'], 'logout');
    });

    test('错误码有中文描述', () {
      expect(
        DsmErrorCode.describe(DsmErrorCode.authInvalidPassword),
        '账号或密码错误',
      );
      expect(DsmErrorCode.describe(DsmErrorCode.authOtpRequired), '需要两步验证码');
      expect(DsmErrorCode.describe(9999), contains('9999'));
    });
  });

  group('传输等价性（直连 vs 隧道/转发两条路径）', () {
    test('同一套请求在两条路径上产生相同结果', () async {
      // 路径 A：直连
      final apiA = DsmWebApi(directTo(dsm));
      final tableA = await apiA.discover();
      final sessA = await apiA.login(account: 'tester', password: 'secret');

      // 路径 B：经由「转发」传输（等价于换一条网络路径）
      final forwarder = ForwardingTransport(directTo(dsm), 'alt-path');
      final apiB = DsmWebApi(forwarder);
      final tableB = await apiB.discover();
      final sessB = await apiB.login(account: 'tester', password: 'secret');

      // API 表完全一致
      expect(tableB.keys.toSet(), tableA.keys.toSet());
      for (final k in tableA.keys) {
        expect(tableB[k]!.path, tableA[k]!.path, reason: 'path 不一致: $k');
        expect(tableB[k]!.minVersion, tableA[k]!.minVersion, reason: 'min: $k');
        expect(tableB[k]!.maxVersion, tableA[k]!.maxVersion, reason: 'max: $k');
      }

      // 两个会话各自有效且不同（服务器独立签发）
      expect(sessA.sid, isNotEmpty);
      expect(sessB.sid, isNotEmpty);
      expect(sessA.sid, isNot(sessB.sid));
      expect(dsm.loginCount, 2);
      expect(forwarder.forwarded, greaterThan(0));
    });

    test('两条路径的失败语义一致（密码错误都是 400）', () async {
      final apiA = DsmWebApi(directTo(dsm));
      final apiB = DsmWebApi(ForwardingTransport(directTo(dsm), 'alt'));

      int codeOf(Object e) => (e as DsmApiException).code;

      var a = 0, b = 0;
      try {
        await apiA.login(account: 'tester', password: 'nope');
      } catch (e) {
        a = codeOf(e);
      }
      try {
        await apiB.login(account: 'tester', password: 'nope');
      } catch (e) {
        b = codeOf(e);
      }
      expect(a, DsmErrorCode.authInvalidPassword);
      expect(b, a);
    });
  });

  group('重复字段（Retrofit 的 @Field List<String>）', () {
    test('List 值编码成重复字段，而不是 JSON 数组', () async {
      final transport = directTo(dsm);
      await transport.postForm('entry.cgi', {
        'api': 'SYNO.Chat.Post',
        'method': 'list',
        'has': ['thread', 'image'],
        'channel_id': '1',
      });

      final body = dsm.rawBodies.last;
      // 必须是 has=thread&has=image 这种重复字段
      expect(body, contains('has=thread'));
      expect(body, contains('has=image'));
      // 不能退化成 JSON 数组字符串
      expect(body, isNot(contains('%5B')));
      expect(RegExp(r'has=').allMatches(body).length, 2);
    });

    test('字符串值照旧单字段', () async {
      final transport = directTo(dsm);
      await transport.postForm('entry.cgi', {'api': 'SYNO.API.Info', 'x': '1'});
      expect(dsm.rawBodies.last, contains('x=1'));
    });
  });

  group('传输失败语义', () {
    test('连不上的地址 → DsmTransportException 且 ping() 为 false', () async {
      // 端口 1 基本不可能有服务
      final dead = DsmWebApi(
        DirectTransport(
          host: '127.0.0.1',
          port: 1,
          https: false,
          timeout: const Duration(milliseconds: 500),
          dio: Dio(
            BaseOptions(
              connectTimeout: const Duration(milliseconds: 500),
              receiveTimeout: const Duration(milliseconds: 500),
            ),
          ),
        ),
      );
      expect(await dead.ping(), isFalse);
      await expectLater(dead.discover(), throwsA(isA<DsmTransportException>()));
    });

    test('getBytes 正常 200 → 全量字节', () async {
      final bytes = await api.getBytes('${api.baseUrl}download.cgi');
      expect(bytes, dsm.downloadBody);
      expect(dsm.rangeHeaders.single, isNull, reason: '不传 maxBytes 就不该带 Range');
    });

    test('getBytes 带 maxBytes → 发 Range 且只拿前 N 字节', () async {
      final bytes = await api.getBytes(
        '${api.baseUrl}download.cgi',
        maxBytes: 64,
      );
      expect(dsm.rangeHeaders.single, 'bytes=0-63');
      expect(bytes.length, 64);
      expect(bytes, dsm.downloadBody.sublist(0, 64));
    });

    test('getBytes 文件不存在（404 + HTML）→ 抛错，绝不把错误页当文件', () async {
      // 踩过的坑：validateStatus 放宽后，404 的 HTML 错误页会被当成图片/文件返回
      dsm
        ..htmlError = true
        ..downloadStatus = 404;
      await expectLater(
        api.getBytes('${api.baseUrl}download.cgi'),
        throwsA(
          isA<DsmTransportException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });

    test('getBytes 502（Download 对不存在的路径就这么答）→ 抛错', () async {
      dsm
        ..htmlError = true
        ..downloadStatus = 502;
      await expectLater(
        api.getBytes('${api.baseUrl}download.cgi'),
        throwsA(
          isA<DsmTransportException>().having(
            (e) => e.statusCode,
            'statusCode',
            502,
          ),
        ),
      );
    });

    test('getBytes 的 JSON 错误正文 → 还原成带错误码的 DsmApiException', () async {
      dsm
        ..downloadStatus = 403
        ..jsonErrorCode = DsmErrorCode.noPermission;
      await expectLater(
        api.getBytes('${api.baseUrl}download.cgi'),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.noPermission,
          ),
        ),
      );
    });

    // ------------------------------------------------------------------
    // R6-4a：`HTTP 200 + JSON 错误信封`（DSM 默认就是这么承载错误的）。
    // 以前只按状态码判 → 这段 JSON 被当"文件内容"返回：预览页显示 JSON 原文、
    // 下载写盘、119（会话失效）漏判（真机截图 `r6-4a-119-200.png`）。
    // 下面这组锁死"信封绝不当内容"，并覆盖真实二进制零回归。
    // ------------------------------------------------------------------

    test('200 + JSON 信封 119（默认承载）→ 抛带码异常，绝不吐 JSON 当字节', () async {
      // `downloadStatus` 默认就是 200 —— 正是 R6 的失败形态
      dsm.jsonErrorCode = DsmErrorCode.sidNotFound;
      await expectLater(
        api.getBytes('${api.baseUrl}download.cgi'),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.sidNotFound,
          ),
        ),
      );
    });

    // ★ r387/DA36：DSM 的「参数无效」信封会带 `name`（哪个参数）。
    //   以前只把 `code` 带出来，`name` 被丢掉 ⇒ 真机上永远查不出根因
    //   （下载选文件页 `Task.List:get` 一直只显示"请求参数无效"）。
    test('200 + JSON 信封 120 带 name → raw 里必须留住 name（DA36）', () async {
      dsm
        ..jsonErrorCode = DsmErrorCode.requestParameterInvalid
        ..jsonErrorName = 'list_id';
      await expectLater(
        api.getBytes('${api.baseUrl}download.cgi'),
        throwsA(
          isA<DsmApiException>()
              .having((e) => e.code, 'code', 120)
              .having((e) => e.raw?['name'], 'raw.name', 'list_id')
              .having((e) => e.raw?['reason'], 'raw.reason', 'required'),
        ),
      );
    });

    test('200 + JSON 信封 105 → DsmApiException(105)（无权限）', () async {
      dsm.jsonErrorCode = DsmErrorCode.noPermission;
      await expectLater(
        api.getBytes('${api.baseUrl}download.cgi'),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.noPermission,
          ),
        ),
      );
    });

    test('200 + JSON 信封 102 → DsmApiException(102)（未安装）', () async {
      dsm.jsonErrorCode = DsmErrorCode.apiNotFound;
      await expectLater(
        api.getBytes('${api.baseUrl}download.cgi'),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.apiNotFound,
          ),
        ),
      );
    });

    test('200 + JSON 信封 其它码（500）→ DsmApiException(500)（明确错误）', () async {
      dsm.jsonErrorCode = 500;
      await expectLater(
        api.getBytes('${api.baseUrl}download.cgi'),
        throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 500)),
      );
    });

    test('postBytesForm 的 200 + JSON 信封 119 → 同样抛带码异常', () async {
      dsm.jsonErrorCode = DsmErrorCode.sidNotFound;
      await expectLater(
        api.postBytesForm('download.cgi', {'api': 'SYNO.FileStation.Download'}),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.sidNotFound,
          ),
        ),
      );
    });

    test('200 + JSON 信封 + Range 请求 → 仍按错误抛，不返回片段', () async {
      dsm.jsonErrorCode = DsmErrorCode.sidNotFound;
      await expectLater(
        api.getBytes('${api.baseUrl}download.cgi', maxBytes: 64),
        throwsA(isA<DsmApiException>()),
      );
      expect(dsm.rangeHeaders.single, 'bytes=0-63', reason: 'Range 头照发');
    });

    test('真实二进制零回归：PDF / PNG / 文本原样返回，不被当信封', () async {
      final pdf = utf8.encode('%PDF-1.4\n%âãÏÓ\n1 0 obj\n');
      dsm
        ..downloadBody = pdf
        ..downloadContentType = ContentType('application', 'pdf');
      expect(await api.getBytes('${api.baseUrl}download.cgi'), pdf);

      final png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3];
      dsm
        ..downloadBody = png
        ..downloadContentType = ContentType('image', 'png');
      expect(await api.getBytes('${api.baseUrl}download.cgi'), png);

      final text = utf8.encode('hello world\n{"not":"an envelope"}\n');
      dsm
        ..downloadBody = text
        ..downloadContentType = ContentType.text;
      expect(await api.getBytes('${api.baseUrl}download.cgi'), text);
    });

    test('`success:true` 的正常 JSON 响应 → 原样返回（不当错误）', () async {
      final body = utf8.encode('{"success":true,"data":{"x":1}}');
      dsm
        ..downloadBody = body
        ..downloadContentType = ContentType.json;
      expect(await api.getBytes('${api.baseUrl}download.cgi'), body);
    });

    test('binary 内容类型下"恰好长得像信封"的字节 → 不当错误（内容类型闸门）', () async {
      final fake = utf8.encode('{"success":false,"error":{"code":119}}');
      dsm
        ..downloadBody = fake
        ..downloadContentType = ContentType.binary;
      expect(
        await api.getBytes('${api.baseUrl}download.cgi'),
        fake,
        reason: '明确二进制类型 → 不进入信封判定，避免误伤真实内容',
      );
    });

    test('响应不是 JSON → DsmTransportException', () async {
      final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      srv.listen((req) async {
        await req.drain<void>();
        req.response.write('<html>not json</html>');
        await req.response.close();
      });
      addTearDown(() => srv.close(force: true));

      final api2 = DsmWebApi(
        DirectTransport(host: '127.0.0.1', port: srv.port, https: false),
      );
      await expectLater(api2.discover(), throwsA(isA<DsmTransportException>()));
    });
  });
}
