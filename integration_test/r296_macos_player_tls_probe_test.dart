// 第 296 轮 macOS 自研播放器桥（`macos/Runner/MediaPlayerBridge.swift` +
// `macos/Runner/MediaPlayerTransport.swift`）的**可复现佐证** —— 只在 macOS 上有意义。
//
// 做法：起一个 **https + 自签证书**的小服务（证书 `CN=nas.example.com`、
// SAN 只有 `*.nas.example.com`；用 `127.0.0.1` 访问 ⇒ **主机名不匹配**，
// 正是真 NAS `https://nas.example.com:5001` 的形态），然后走 `synhub/player`：
//   AVPlayer → 自定义 scheme `synhub-https://` → `AVAssetResourceLoaderDelegate`
//   → 我们自己的 `URLSession`（`serverTrust` 挑战里按政策放行）→ 分段回数据
// 断言：
//   ① 指纹放行   ⇒ texture id / `ready` / `durationMs > 0` / **`firstFrame`**
//   ② 指纹不匹配 ⇒ 不出帧，且上报的是**证书**类错误（不是误导人的"解码失败"）
//
// 跑法：
//   flutter test integration_test/r296_macos_player_tls_probe_test.dart -d macos
//
// ⚠️ 服务跑在**独立 isolate**里（不是测试那个 isolate）：`flutter test` 的
// integration binding 会接管测试 isolate 的事件循环，进程内直接调
// `HttpServer.bindSecure` 时原生 `URLSession` 的请求**根本得不到应答**
// （实测：30s 超时 `NSURLErrorDomain(-1001)`）。独立 isolate 有自己的事件循环，
// 不受测试 binding 影响。
//
// ⚠️ 诚实边界（别把这条当"真 NAS 已验证"）：
//   * 这里证的是 **"自签 + 指纹钉住"** 那条 TLS 分支；
//   * **没有**证"证书链合法、只是主机名不匹配"那条分支（要一枚由**系统信任的 CA**
//     签出的证书，本机造不出来）—— 真 NAS 的流在桌面上仍是**未验**；
//   * 内嵌 PEM 是一枚**一次性探针证书**（自签、非秘密、不用于生产），
//     内嵌 MP4 是 ffmpeg 生成的 0.8s / 64x64 / H.264 小样本。
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 探针证书（自签，`CN=nas.example.com`；**不是**任何真实凭据）
const String _certPem = r'''
-----BEGIN CERTIFICATE-----
MIIDIzCCAgugAwIBAgIUfSPvKt7iW0RZHPHiEKHSOJHTcEAwDQYJKoZIhvcNAQEL
BQAwGjEYMBYGA1UEAwwPbmFzLmV4YW1wbGUuY29tMB4XDTI2MTEwNDE1MjIzMFoX
DTM2MTEwMTE1MjIzMFowGjEYMBYGA1UEAwwPbmFzLmV4YW1wbGUuY29tMIIBIjAN
BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAtKjSiyPT1dNSoQwfqTEpMzY2kyvM
/qLBRlgR9DXgRV0IvXBK/H7+p/d6OheQT3QcwK7VRU0ix3ZpPULJPsAnVntPLxzU
t5us/4v0ltoL5vXuKSjbTyNN/onXgB3GrjXdTOSt06AdapUXD0J9uzdADzT7dIHp
8Kx9L/fh04HtOm3CJ6g75tzgiND5isRryhWZlsMHey6Dbhg6VKSF0V4i3ZoG5TfD
caRLq5I85DmYQKnkd1y1ajnK/dVdF3Valq0Yr1Qpo2Pm56FprX0gTtOgS9Xnymyn
WHMey2OTYyI6W3ynvCMgE4bSAtC/zCzBOE2yp3p7jTfoLnsPcjSYU4mHXwIDAQAB
o2EwXzAdBgNVHQ4EFgQUc01q491VtbCJzrdrv9IJamPzW+owDwYDVR0TAQH/BAUw
AwEB/zAtBgNVHREEJjAkghEqLm5hcy5leGFtcGxlLmNvbYIPbmFzLmV4YW1wbGUu
Y29tMA0GCSqGSIb3DQEBCwUAA4IBAQA7SbvnDcfHt9crxSwu71HIHhsJX83zb8B1
MY0JoFPYdTbSKo8zuEZB3WzKRe2D/7CaUOS1nRporA2swh1vdy92Zhc0jogM1RsQ
jii8w2M+6d4SzAyX1pj5Ff+ZALNzPQ7fiSWP/KgF/jJ49KDN7WfGH27XPKuUu5a3
KIVxtkTUH+EwDnjP1dY/PpKQ01FRpOC9dl39d5rsLihkJEw8mlUK/vZUHiSU+/LM
YN7GnURRiUPhiALZhFuQONrnkdMyoeypAFMfTrzCtWv5t6PVVlKjFCjHAlbw+LwF
3/qNgIfDUoIokfYvdvzCUF9YMeVoOk/7IbVyIvqmpk6qlSNn0d3H
-----END CERTIFICATE-----
''';

/// 探针私钥（与上面那枚证书配对；一次性）
const String _keyPem = r'''
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC0qNKLI9PV01Kh
DB+pMSkzNjaTK8z+osFGWBH0NeBFXQi9cEr8fv6n93o6F5BPdBzArtVFTSLHdmk9
Qsk+wCdWe08vHNS3m6z/i/SW2gvm9e4pKNtPI03+ideAHcauNd1M5K3ToB1qlRcP
Qn27N0APNPt0genwrH0v9+HTge06bcInqDvm3OCI0PmKxGvKFZmWwwd7LoNuGDpU
pIXRXiLdmgblN8NxpEurkjzkOZhAqeR3XLVqOcr91V0XdVqWrRivVCmjY+bnoWmt
fSBO06BL1efKbKdYcx7LY5NjIjpbfKe8IyAThtIC0L/MLME4TbKnenuNN+guew9y
NJhTiYdfAgMBAAECggEAD2+/ccEmyBtYRkeIFbJhgAKOs5DnYWNHGtDKqUXIkH9h
uvdzM35RxHNlH71Es5f1yacGtSG2qjlyxkJvJKv8OyuqeURAOXdqrE6T9dHSzjIk
XqL4PkZY0zo0TjpScC9NEKrCNEDMUqpDlVEL95PB0arSyO09hTblNCnnmLrTf42d
iufqQBDLy3IFv4txouHMt661kmqF5BK0xosgh3RcIS0IhfxoLtrMvIR0kC4uXnNi
79HgG+R5X5Tmh4WQi4P6MZbfbc3dUqroc8Pqqzwgr/X5w6bh38N31X0nL/uaSbi+
QIdknSlYWx9l1eoin40xWgqxyW4kpoU5w2MmcmkF1QKBgQDiKXIZ1IsLGq95tooF
8zz4rrT58A1S2GOEkhVUHu3+hthRUAPqedN9DBGoSVwz1VxdSLqYTVXJbOBl2iRX
UzY31Orspp8OP75c2bxXAY6BTpBfPdrA97re2PcxJJlrC+4URYk1P0EGXtrLGRvv
vf5jaqFW+C5/cN+wZILnghWIJQKBgQDMfot6IN7P2XbdTJij1HrDHDZRFxlX168z
WD6UMf1iW6+/yrFpvsF1Ll7BPXTiUGMz0V/SWRBadyNNFuVRobitKyg43Wjp+RMw
2c0YL1Pzo6VxMLCkesrf3L1QtMPBYCKS8q6etcwjQYfveT6OF4yv7FVOix6h/AG/
A1ng5pFIMwKBgDXXTBSeJuPj3HaLYFx+RbumS+tcnK9mWHrNFErMejgn/gONmwEN
M64HW4TGwi6M0spacCGl95BWXS2iOxiW9Mdh5vOjzyXjQvxz0YSdGEHsZC5oWVWr
JE+9M0v9vJBhbLJiw4Frp51Oo6PKPH5cqt0cG4DK4LbyNi6WHxviOiIJAoGBAItQ
iuUhD6q6lGgfjr3OO/RAfCCyg+l8Xzeznq6HgABKRml7RXKtKk8S0CsGG2MzMOJU
edtsId//2mTifEgozQ/snvJepOMBdTmKqFcZpzANBOEgMrdbkGsCj1c0T0imnedO
vfgSEojSVDGpgBx9nrMbZuKjlLL2ZJolRk4ZxlBRAoGBAKoM/Wvi78EhafYjrmB7
DV4Y+fa+iYDBnf9DWetR6GJebBforOv1NLgEeRC+po9WvRMQPnjjhzD4/w6lK1QN
xz2GYz8vwfOKwESW387twr4SH2wY6EHCukmVnWJZuxTobWhi70/kMbNm+5jTd7Cu
p/bWSj4L40x2R63fa8wKrXSK
-----END PRIVATE KEY-----
''';

/// ffmpeg `-f lavfi -i testsrc=duration=0.8:size=64x64:rate=8 -c:v libx264` → mp4
const String _mp4Base64 =
    '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';

/// 这枚探针证书叶子 DER 的 SHA-256（大写十六进制，与 Dart `TrustStore` 同格式）
const String kProbeFingerprint = 'A962E378465A8B7086C3958D78642E7483C2BDE56D9819E33E300B81154DD8EF';

/// 故意错的指纹（负对照）
const String kWrongFingerprint = 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF';

const MethodChannel _player = MethodChannel('synhub/player');
const EventChannel _events = EventChannel('synhub/player_events');

/// **独立 isolate** 里的 https 服务（支持 Range：AVFoundation 全靠分段请求）
Future<void> _probeServer(List<Object?> args) async {
  final send = args[0] as SendPort;
  final media = args[1] as List<int>;
  final cert = args[2] as String;
  final key = args[3] as String;
  try {
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(cert))
      ..usePrivateKeyBytes(utf8.encode(key));
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    server.listen((request) async {
      final response = request.response;
      response.headers.set('Accept-Ranges', 'bytes');
      response.headers.set('Content-Type', 'video/mp4');
      final range = request.headers.value(HttpHeaders.rangeHeader);
      var start = 0;
      var end = media.length - 1;
      var partial = false;
      if (range != null && range.startsWith('bytes=')) {
        final spec = range.substring('bytes='.length).split('-');
        final a = int.tryParse(spec.first);
        if (a != null) {
          start = a;
          final b = spec.length > 1 ? int.tryParse(spec[1]) : null;
          if (b != null) end = b;
          partial = true;
        }
      }
      if (start >= media.length || start > end) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await response.close();
        return;
      }
      end = end < media.length ? end : media.length - 1;
      final slice = media.sublist(start, end + 1);
      response.statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok;
      if (partial) {
        response.headers.set(
          'Content-Range',
          'bytes $start-$end/${media.length}',
        );
      }
      response.headers.contentLength = slice.length;
      response.add(slice);
      await response.close();
    });
    send.send(server.port);
  } catch (error) {
    send.send('$error');
  }
}

Future<int> _startProbeServer(List<int> media) async {
  final port = ReceivePort();
  await Isolate.spawn(_probeServer, <Object?>[
    port.sendPort,
    media,
    _certPem,
    _keyPem,
  ]);
  final first = await port.first;
  port.close();
  if (first is int) return first;
  throw StateError('探针 https 服务起不来：$first');
}

Future<void> _setPolicy({required String? host, String? fingerprint}) =>
    _player.invokeMethod<bool>('setTlsPolicy', <String, Object?>{
      'host': host,
      'fingerprint': fingerprint,
    });

/// 等到 [predicate] 为真或超时
Future<bool> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return predicate();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // ★ 第 92 轮：iOS 与 macOS **共用同一份 Swift 桥**（`#if os(macOS)` 只收口
  // registrar 形态）⇒ 这条探针在 iOS 上同样成立，而且它是现有证据里**唯一**
  // 能在"零外网 + 不需要真 NAS"的前提下把整条链路走完的一条
  // （自签 https 服务 → 政策下发 → TLS 挑战 → 分段取流 → 解码出帧 → 纹理）。
  // 仍然**只**在 Apple 平台上跑（Kotlin 侧是另一套契约）。
  if (!Platform.isMacOS && !Platform.isIOS) {
    test('Apple 平台专有探针', () {}, skip: '只在 macOS / iOS 上有意义');
    return;
  }

  late int port;
  final bytes = base64Decode(_mp4Base64);

  setUpAll(() async {
    port = await _startProbeServer(bytes);
  });

  /// 跑一次完整链路，回收集到的事件
  Future<List<Map<Object?, Object?>>> playOnce({
    required String fingerprint,
  }) async {
    final events = <Map<Object?, Object?>>[];
    final sub = _events.receiveBroadcastStream().listen((event) {
      if (event is Map) events.add(Map<Object?, Object?>.from(event));
    });
    // 事件订阅先立起来，再 create/load（与 Dart 适配器的顺序一致）
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await _setPolicy(host: '127.0.0.1', fingerprint: fingerprint);
    final id = await _player.invokeMethod<int>('create');
    expect(id, isNotNull, reason: '原生没给 texture id');
    expect(id! >= 0, isTrue, reason: 'texture id 不能是负的（-1 = 没注册成功）');
    await _player.invokeMethod<void>('load', <String, Object?>{
      'urls': <String>['https://127.0.0.1:$port/probe.mp4'],
      'index': 0,
      'autoplay': true,
      'volume': 1.0,
      'muted': false,
      'speed': 1.0,
      'aspect': 'fit',
    });
    await _waitFor(
      () => events.any(
        (e) =>
            e['kind'] == 'state' &&
            (e['firstFrame'] == true ||
                (e['error'] is String && (e['error'] as String).isNotEmpty)),
      ),
    );
    await _player.invokeMethod<void>('dispose');
    await _setPolicy(host: null);
    await sub.cancel();
    return events;
  }

  testWidgets('① 自签 + 指纹放行 ⇒ ready / durationMs / firstFrame', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final states = [
        for (final e in await playOnce(fingerprint: kProbeFingerprint))
          if (e['kind'] == 'state') e,
      ];
      debugPrint('[r296-probe] ① state 事件数=${states.length}');
      expect(
        states.any((e) => e['ready'] == true),
        isTrue,
        reason: '没有 ready=true 的 state；原始事件=$states',
      );
      expect(
        states.any((e) => (e['durationMs'] as num? ?? 0) > 0),
        isTrue,
        reason: 'durationMs 一直是 0（根本没读到媒体）；原始事件=$states',
      );
      expect(
        states.any((e) => e['firstFrame'] == true),
        isTrue,
        reason: '没等到 firstFrame=true（视频轨没出帧）；原始事件=$states',
      );
    });
  });

  testWidgets('② 指纹不匹配 ⇒ 不出帧，且报的是证书类错误', (tester) async {
    await tester.runAsync(() async {
      final states = [
        for (final e in await playOnce(fingerprint: kWrongFingerprint))
          if (e['kind'] == 'state') e,
      ];
      debugPrint('[r296-probe] ② state 事件数=${states.length}');
      expect(
        states.any((e) => e['firstFrame'] == true),
        isFalse,
        reason: '错指纹居然出帧了 ⇒ 说明放宽是全局的，政策根本没生效',
      );
      final errors = [
        for (final e in states)
          if (e['error'] is String && (e['error'] as String).isNotEmpty)
            e['error'] as String,
      ];
      expect(errors, isNotEmpty, reason: '错指纹应当报错；原始事件=$states');
      expect(
        errors.any((e) => e.toLowerCase().contains('cert')),
        isTrue,
        reason: '证书被拒时上报的应当是证书类错误（不是通用的 -11800/解码失败）：$errors',
      );
    });
  });
}
