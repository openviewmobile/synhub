// CGI 加密单测
//
// 最有力的验证是**回环**：用测试密钥对加密 → 用私钥解密 → 断言明文
// 与 APK 的构造完全一致。这能证明 RSA 参数、padding、前缀格式都对。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:synhub/src/dsm/cgi_encryption.dart';

/// 用私钥解开 PKCS#1 v1.5 密文
String rsaDecrypt(
  AsymmetricKeyPair<PublicKey, PrivateKey> kp,
  List<int> cipher,
) {
  final engine = PKCS1Encoding(RSAEngine())
    ..init(
      false,
      PrivateKeyParameter<RSAPrivateKey>(kp.privateKey as RSAPrivateKey),
    );
  return utf8.decode(engine.process(Uint8List.fromList(cipher)));
}

void main() {
  group('javaUrlEncode 与 Java URLEncoder 一致', () {
    test('保留 . - * _', () {
      expect(javaUrlEncode('a.b-c*_d'), 'a.b-c*_d');
    });

    test('空格转 +', () {
      expect(javaUrlEncode('a b'), 'a+b');
    });

    test('密码 q*7B:vT3D1 的编码', () {
      // Java 不编码 *，但编码 :
      expect(javaUrlEncode('q*7B:vT3D1'), 'q*7B%3AvT3D1');
    });

    test('非 ASCII 走 UTF-8 且十六进制大写', () {
      expect(javaUrlEncode('中'), '%E4%B8%AD');
    });

    test('Dart 的 encodeQueryComponent 会编 * 号 —— 所以不能混用', () {
      expect(Uri.encodeQueryComponent('*'), '%2A');
      expect(javaUrlEncode('*'), '*');
    });
  });

  group('X.509 RSA 公钥解析', () {
    test('自造 DER 能解析回 n / e', () {
      final kp = generateTestRsaKeyPair(1024);
      final pub = kp.publicKey as RSAPublicKey;
      final der = encodeX509RsaPublicKey(pub.modulus!, pub.exponent!);
      final parsed = parseX509RsaPublicKey(der);
      expect(parsed.n, pub.modulus);
      expect(parsed.e, pub.exponent);
    });
  });

  group('CGI 加密回环', () {
    late AsymmetricKeyPair<PublicKey, PrivateKey> kp;
    late DsmCipherData cipher;

    setUpAll(() {
      kp = generateTestRsaKeyPair(2048);
      final pub = kp.publicKey as RSAPublicKey;
      cipher = fakeCipherData(
        publicKeyB64: base64Encode(
          encodeX509RsaPublicKey(pub.modulus!, pub.exponent!),
        ),
        serverTime: 1000,
        localTime: 990, // bias = +10
      );
    });

    test('只加密凭据时，明文格式与原库一致', () {
      final enc = DsmCgiEncryption(
        cipher,
        clock: () => DateTime.fromMillisecondsSinceEpoch(2000 * 1000),
      );
      final out = enc.encryptFromParamList({
        'account': 'demo_user',
        'passwd': 'q*7B:vT3D1',
      });

      // 原库 encryptFromParamList 只返回一个条目
      expect(out.keys.single, '__cIpHeRtExT');

      final plain = rsaDecrypt(kp, base64Decode(out.values.single));
      // 时间戳 = 本地 2000 + bias 10 = 2010
      expect(plain, '__cIpHeRtOkEn=2010&account=demo_user&passwd=q*7B%3AvT3D1');
    });

    test('timeBias 生效：时间戳贴近服务器时间', () {
      final c2 = fakeCipherData(
        publicKeyB64: cipher.publicKeyB64,
        serverTime: 5000,
        localTime: 4000, // bias = +1000
      );
      final enc = DsmCgiEncryption(
        c2,
        clock: () => DateTime.fromMillisecondsSinceEpoch(4100 * 1000),
      );
      final plain = rsaDecrypt(
        kp,
        base64Decode(
          enc
              .encryptFromParamList({'account': 'a', 'passwd': 'b'})
              .values
              .single,
        ),
      );
      expect(
        plain.startsWith('__cIpHeRtOkEn=5100&'),
        isTrue,
        reason: '4100 + 1000 = 5100',
      );
    });

    test('每次加密结果不同（PKCS#1 随机填充）', () {
      final enc = DsmCgiEncryption(cipher);
      final a = enc.encryptFromParamList({'account': 'a', 'passwd': 'b'});
      final b = enc.encryptFromParamList({'account': 'a', 'passwd': 'b'});
      expect(a.values.single, isNot(b.values.single));
      // 但解出来应当一样 —— **除时间戳那一位**。
      //
      // ★ r695：这里原来直接比两段明文，两次 `encryptFromParamList` 各自读真实时钟，
      //   跨秒时就红（现场：`__cIpHeRtOkEn=…092` vs `…091`，全量 -1 的唯一一条）。
      //   时间戳本来就是"现在"，不该被当成"必须相等"的东西：
      //   把 `__cIpHeRtOkEn=<秒>` 挖掉再比，剩下的参数必须逐字相同。
      String stripNonce(String s) =>
          s.replaceFirst(RegExp(r'__cIpHeRtOkEn=\d+&'), '');
      final pa = rsaDecrypt(kp, base64Decode(a.values.single));
      final pb = rsaDecrypt(kp, base64Decode(b.values.single));
      expect(pa, startsWith('__cIpHeRtOkEn='));
      expect(stripNonce(pa), stripNonce(pb));
    });

    test('密文长度 = 密钥字节数（2048 位 → 256 字节 → base64 344）', () {
      final enc = DsmCgiEncryption(cipher);
      final out = enc.encryptFromParamList({'account': 'a', 'passwd': 'b'});
      expect(base64Decode(out.values.single).length, 256);
    });
  });

  group('DsmCipherData', () {
    test('从真实 getinfo 响应构造', () {
      final c = DsmCipherData.fromJson({
        'cipherkey': '__cIpHeRtExT',
        'ciphertoken': '__cIpHeRtOkEn',
        'public_key': 'AAAA',
        'server_time': 1789569633,
      }, localTime: 1789569630);
      expect(c.cipherKey, '__cIpHeRtExT');
      expect(c.cipherToken, '__cIpHeRtOkEn');
      expect(c.timeBias, 3);
    });

    test('缺 server_time 时 bias 为 0', () {
      final c = DsmCipherData.fromJson({'public_key': 'x'}, localTime: 42);
      expect(c.timeBias, 0);
      expect(c.serverTime, 42);
    });
  });
}
