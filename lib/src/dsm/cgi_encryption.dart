// DSM 登录用的 CGI 加密 —— 逐语句对应 APK 的
// com.synology.dschat.util.CgiEncryption + RetryInterceptor。
//
// 关键点（反编译 + 真实 NAS 验证得出）：
//   · **只加密 account / passwd**，其余参数明文并排发送
//   · 明文 = "<ciphertoken>=<时间戳>&account=..&passwd=.."
//   · RSA/ECB/PKCS1Padding，4096 位
//   · 结果 base64 后作为名为 cipherkey 的**单个**表单字段发出
//
// 时间戳必须贴近服务器时间：timeBias = server_time - 本地收到的时间。
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

// 注意：pointycastle 4.x 的 `SecureRandom()` 工厂依赖注册表，在测试里注册不生效；
// 直接用具体类 FortunaRandom 更稳。
import 'package:pointycastle/export.dart';

import '../core/i18n/data_text.dart';

/// Java `URLEncoder.encode(s, "UTF-8")` 的精确复刻。
///
/// 与 Dart 的 `Uri.encodeQueryComponent` 有实质差异，不能混用：
///   · 保留 `a-zA-Z0-9` 以及 `.` `-` `*` `_`（Dart 会把 `*` 编成 `%2A`）
///   · 空格 → `+`（Dart 用 `%20`）
///   · 其余 → `%XX`，**大写**十六进制
String javaUrlEncode(String s) {
  const keep =
      'abcdefghijklmnopqrstuvwxyz'
      'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
      '0123456789.-*_';
  final out = StringBuffer();
  for (final b in utf8.encode(s)) {
    final c = String.fromCharCode(b);
    if (keep.contains(c)) {
      out.write(c);
    } else if (c == ' ') {
      out.write('+');
    } else {
      out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

/// `SYNO.API.Encryption / getinfo` 的响应
class DsmCipherData {
  DsmCipherData({
    required this.cipherKey,
    required this.cipherToken,
    required this.publicKeyB64,
    required this.serverTime,
    required this.localTimeAtFetch,
  });

  /// 实测为字面量 `__cIpHeRtExT` —— 用作**参数名**
  final String cipherKey;

  /// 实测为字面量 `__cIpHeRtOkEn` —— 用作**明文前缀**
  final String cipherToken;

  /// base64 的 X.509 SubjectPublicKeyInfo（DER）
  final String publicKeyB64;

  final int serverTime;

  /// 本地收到响应时的秒级时间戳，用于算 timeBias
  final int localTimeAtFetch;

  int get timeBias => serverTime - localTimeAtFetch;

  factory DsmCipherData.fromJson(Map<String, dynamic> j, {int? localTime}) {
    final now = localTime ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return DsmCipherData(
      cipherKey: j['cipherkey'] as String? ?? '',
      cipherToken: j['ciphertoken'] as String? ?? '',
      publicKeyB64: j['public_key'] as String? ?? '',
      serverTime: (j['server_time'] as num?)?.toInt() ?? now,
      localTimeAtFetch: now,
    );
  }
}

/// 最小 DER 读取器 —— 只为从 X.509 SPKI 里取出 RSA 的 n / e。
///
/// 结构：
///   SEQUENCE { SEQUENCE { OID, NULL }, BIT STRING { SEQUENCE { INTEGER n, INTEGER e } } }
class _Der {
  _Der(this.b);
  final Uint8List b;
  int p = 0;

  int _len() {
    var l = b[p++];
    if (l & 0x80 != 0) {
      final n = l & 0x7f;
      l = 0;
      for (var i = 0; i < n; i++) {
        l = (l << 8) | b[p++];
      }
    }
    return l;
  }

  /// 返回 [tag, contentStart, contentLength]，并把游标移到内容之后
  List<int> read() {
    final tag = b[p++];
    final len = _len();
    final start = p;
    p += len;
    return [tag, start, len];
  }

  Uint8List bytes(int start, int len) =>
      Uint8List.sublistView(b, start, start + len);

  void skip() => read();
}

/// RSA 公钥的两个整数（n, e）
class RsaPublicNumbers {
  RsaPublicNumbers(this.n, this.e);
  final BigInt n;
  final BigInt e;
}

BigInt _toBigInt(Uint8List v) {
  var r = BigInt.zero;
  for (final byte in v) {
    r = (r << 8) | BigInt.from(byte);
  }
  return r;
}

RsaPublicNumbers parseX509RsaPublicKey(Uint8List der) {
  final d = _Der(der);
  // 外层 SEQUENCE：read() 会把游标推到末尾，所以必须在它的**内容切片**里继续解析
  final outer = d.read();
  if (outer[0] != 0x30) {
    throw FormatException(
      dataText(
        'apiX509ExpectedSequence',
        '期望 SEQUENCE，得到 0x{got}',
      ).replaceAll('{got}', outer[0].toRadixString(16)),
    );
  }
  final mid = _Der(d.bytes(outer[1], outer[2]));

  mid.skip(); // AlgorithmIdentifier（rsaEncryption OID + NULL）
  final bs = mid.read(); // BIT STRING
  if (bs[0] != 0x03) {
    throw FormatException(
      dataText(
        'apiX509ExpectedBitString',
        '期望 BIT STRING，得到 0x{got}',
      ).replaceAll('{got}', bs[0].toRadixString(16)),
    );
  }
  var content = mid.bytes(bs[1], bs[2]);
  // BIT STRING 首字节是 unused bit 数
  if (content.isNotEmpty && content[0] == 0) {
    content = Uint8List.sublistView(content, 1);
  }

  final inner = _Der(content);
  final seq = inner.read(); // SEQUENCE { INTEGER n, INTEGER e }
  if (seq[0] != 0x30) {
    throw FormatException(
      dataText('apiX509NotSequence', 'RSA 公钥内容不是 SEQUENCE'),
    );
  }
  final kv = _Der(inner.bytes(seq[1], seq[2]));
  final n = kv.read();
  final e = kv.read();
  if (n[0] != 0x02 || e[0] != 0x02) {
    throw FormatException(
      dataText('apiX509NoNOrE', 'RSA 公钥里没找到 n / e 两个 INTEGER'),
    );
  }
  return RsaPublicNumbers(
    _toBigInt(kv.bytes(n[1], n[2])),
    _toBigInt(kv.bytes(e[1], e[2])),
  );
}

/// 按 APK 的方式加密一组参数。
class DsmCgiEncryption {
  DsmCgiEncryption(this.data, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DsmCipherData data;
  final DateTime Function() _clock;
  late final RsaPublicNumbers _pub = parseX509RsaPublicKey(
    base64Decode(data.publicKeyB64),
  );

  int _nowSeconds() => _clock().millisecondsSinceEpoch ~/ 1000 + data.timeBias;

  /// 加密 [params]（**只应传 account / passwd**），返回可直接并入表单的
  /// `{cipherkey: <base64>}`。
  ///
  /// 对应原库的 `encryptFromParamList`：它也只返回这一个条目。
  Map<String, String> encryptFromParamList(Map<String, String> params) {
    final ts = _nowSeconds();
    final qs = params.entries
        .map((e) => '${javaUrlEncode(e.key)}=${javaUrlEncode(e.value)}')
        .join('&');
    // ↓ 与原库一字不差：cipherToken + "=" + 时间戳 + "&" + 参数串
    final plain = '${data.cipherToken}=$ts&$qs';
    return {data.cipherKey: base64Encode(_rsaPkcs1(utf8.encode(plain)))};
  }

  Uint8List _rsaPkcs1(Uint8List plain) {
    final engine = PKCS1Encoding(RSAEngine())
      ..init(
        true,
        PublicKeyParameter<RSAPublicKey>(RSAPublicKey(_pub.n, _pub.e)),
      );
    return engine.process(plain);
  }

  /// 调试用：暴露被加密的明文，便于与抓包对照
  String debugPlaintext(Map<String, String> params) {
    final qs = params.entries
        .map((e) => '${javaUrlEncode(e.key)}=${javaUrlEncode(e.value)}')
        .join('&');
    return '${data.cipherToken}=${_nowSeconds()}&$qs';
  }
}

/// 便于测试：伪造一份 cipher data（公钥由调用方给）
DsmCipherData fakeCipherData({
  String cipherKey = '__cIpHeRtExT',
  String cipherToken = '__cIpHeRtOkEn',
  required String publicKeyB64,
  int serverTime = 0,
  int localTime = 0,
}) => DsmCipherData(
  cipherKey: cipherKey,
  cipherToken: cipherToken,
  publicKeyB64: publicKeyB64,
  serverTime: serverTime,
  localTimeAtFetch: localTime,
);

/// 供测试构造一个最小 RSA 公钥的 DER 编码
Uint8List encodeX509RsaPublicKey(BigInt n, BigInt e) {
  Uint8List derInt(BigInt v) {
    var bytes = <int>[];
    var x = v;
    while (x > BigInt.zero) {
      bytes.insert(0, (x & BigInt.from(0xff)).toInt());
      x >>= 8;
    }
    if (bytes.isEmpty) bytes = [0];
    if (bytes[0] & 0x80 != 0) bytes.insert(0, 0);
    return Uint8List.fromList([0x02, ..._derLen(bytes.length), ...bytes]);
  }

  final rsa = <int>[...derInt(n), ...derInt(e)];
  final inner = Uint8List.fromList([0x30, ..._derLen(rsa.length), ...rsa]);
  // AlgorithmIdentifier: rsaEncryption OID + NULL
  final alg = <int>[
    0x30,
    0x0d,
    0x06,
    0x09,
    0x2a,
    0x86,
    0x48,
    0x86,
    0xf7,
    0x0d,
    0x01,
    0x01,
    0x01,
    0x05,
    0x00,
  ];
  final bitStringContent = <int>[0x00, ...inner];
  final body = <int>[
    ...alg,
    0x03,
    ..._derLen(bitStringContent.length),
    ...bitStringContent,
  ];
  return Uint8List.fromList([0x30, ..._derLen(body.length), ...body]);
}

List<int> _derLen(int n) {
  if (n < 0x80) return [n];
  final bytes = <int>[];
  var x = n;
  while (x > 0) {
    bytes.insert(0, x & 0xff);
    x >>= 8;
  }
  return [0x80 | bytes.length, ...bytes];
}

Uint8List _seedBytes() {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(32, (_) => r.nextInt(256)));
}

/// 生成一对用于测试的 RSA 密钥（2048 位够快）
AsymmetricKeyPair<PublicKey, PrivateKey> generateTestRsaKeyPair([
  int bits = 2048,
]) {
  final keyGen = RSAKeyGenerator()
    ..init(
      ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.from(65537), bits, 64),
        FortunaRandom()..seed(KeyParameter(_seedBytes())),
      ),
    );
  return keyGen.generateKeyPair();
}
