// Phase 7 E2EE 原语测试。
//
// 基准是 `test/support/sodium_vectors.dart`：由 `tool/gen_sodium_vectors.py`
// 用**本机真 libsodium** 生成的固定向量。纯 Dart 实现（pinenacl + blake2b）
// 必须逐字节对上——E2EE 差一个字节，跟服务端和其它客户端就完全对不上了。
//
// 反向（Dart → libsodium）由 `python3 tool/gen_sodium_vectors.py --verify` 校验。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/crypto/sodium_crypto.dart';

import 'support/sodium_vectors.dart';

void main() {
  group('generichash（blake2b-256）', () {
    test('passcode 派生密钥与 libsodium 一致', () {
      expect(
        base64Encode(SodiumCrypto.passcodeKey(SodiumVectors.passcode)),
        SodiumVectors.passcodeKey,
      );
    });

    test('空输入 32 字节（libsodium 的 crypto_generichash 语义）', () {
      // blake2b-256("") = 0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8
      expect(
        SodiumCrypto.generichash256(
          const [],
        ).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        '0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8',
      );
    });
  });

  group('secretbox（消息 / 文件名 / 文件 / 私钥）', () {
    test('用 libsodium 的 key+nonce 加密，密文逐字节相同', () {
      final out = SodiumCrypto.secretboxRaw(
        utf8.encode(SodiumVectors.secretboxPlaintext),
        key: base64Decode(SodiumVectors.secretboxKey),
        nonce: base64Decode(SodiumVectors.secretboxNonce),
      );
      expect(base64Encode(out), SodiumVectors.secretboxCiphertext);
    });

    test('解开 libsodium 的密文', () {
      final plain = SodiumCrypto.secretboxOpenRaw(
        base64Decode(SodiumVectors.secretboxCiphertext),
        key: base64Decode(SodiumVectors.secretboxKey),
        nonce: base64Decode(SodiumVectors.secretboxNonce),
      );
      expect(utf8.decode(plain), SodiumVectors.secretboxPlaintext);
    });

    test('encryptMessage/decryptMessage（消息体：nonce||MAC||密文，base64）', () {
      final key = SodiumVectors.secretboxKey;
      final enc = SodiumCrypto.encryptMessage('你好 E2EE 🙂', key);
      expect(SodiumCrypto.decryptMessage(enc, key), '你好 E2EE 🙂');
      // 每次 nonce 不同 → 密文不同
      expect(SodiumCrypto.encryptMessage('你好 E2EE 🙂', key), isNot(enc));
    });

    test('文件名走 hex（跟消息的 base64 不一样）', () {
      final key = base64Decode(SodiumVectors.secretboxKey);
      final hex = SodiumCrypto.encryptFileNameHex('报告 2026.pdf', key);
      // 原 App `LazySodium.hexArray` 是大写字母，发出去的文件名必须一致，
      // 否则官方客户端按它自己的表解不出名字（读取时大小写都收）。
      expect(hex, matches(RegExp(r'^[0-9A-F]+$')));
      expect(SodiumCrypto.decryptFileNameHex(hex, key), '报告 2026.pdf');
      expect(
        SodiumCrypto.decryptFileNameHex(hex.toLowerCase(), key),
        '报告 2026.pdf',
      );
    });

    test('文件体是原始字节（nonce||MAC||密文）', () {
      final key = base64Decode(SodiumVectors.secretboxKey);
      final body = List<int>.generate(5000, (i) => i % 251);
      final enc = SodiumCrypto.encryptFileBytes(body, key);
      expect(enc.length, body.length + kNonceBytes + kMacBytes);
      expect(SodiumCrypto.decryptFileBytes(enc, key), body);
    });

    test('密钥/密文被改过 → 解密失败', () {
      final key = base64Decode(SodiumVectors.secretboxKey);
      final enc = SodiumCrypto.encryptMessage(
        'secret',
        SodiumVectors.secretboxKey,
      );
      final tampered = base64Decode(enc)
        ..[base64Decode(enc).length - 1] ^= 0xff;
      expect(
        () => SodiumCrypto.decryptMessage(
          base64Encode(tampered),
          SodiumVectors.secretboxKey,
        ),
        throwsA(isA<SodiumException>()),
      );
      expect(
        () =>
            SodiumCrypto.decryptMessage(enc, base64Encode(List.filled(32, 7))),
        throwsA(isA<SodiumException>()),
      );
      expect(key, hasLength(32));
    });

    test('私钥口令加解密（SodiumHelper.encryptPrivateKey/decryptPrivateKey）', () {
      const passcode = 'flt-passcode-2026';
      final priv = SodiumCrypto.generateKeyPair().privateKey;
      final enc = SodiumCrypto.encryptPrivateKey(priv, passcode);
      expect(SodiumCrypto.decryptPrivateKey(enc, passcode), priv);
      expect(
        () => SodiumCrypto.decryptPrivateKey(enc, '错误的密码'),
        throwsA(isA<SodiumException>()),
      );
    });
  });

  group('box seal（频道密钥分发）', () {
    test('解开 libsodium 封的盒子', () {
      final plain = SodiumCrypto.sealDecrypt(
        base64Decode(SodiumVectors.sealSealed),
        publicKeyBase64: SodiumVectors.sealRecipientPublicKey,
        privateKeyBase64: SodiumVectors.sealRecipientPrivateKey,
      );
      expect(base64Encode(plain), SodiumVectors.sealPlaintext);
    });

    test('自己封的盒子自己能开，别人开不了', () {
      final pair = SodiumCrypto.generateKeyPair();
      final other = SodiumCrypto.generateKeyPair();
      final channelKey = SodiumCrypto.generateChannelKey();
      final sealed = SodiumCrypto.sealEncrypt(
        base64Decode(channelKey),
        pair.publicKey,
      );
      expect(
        base64Encode(
          SodiumCrypto.sealDecrypt(
            base64Decode(sealed),
            publicKeyBase64: pair.publicKey,
            privateKeyBase64: pair.privateKey,
          ),
        ),
        channelKey,
      );
      expect(
        () => SodiumCrypto.sealDecrypt(
          base64Decode(sealed),
          publicKeyBase64: other.publicKey,
          privateKeyBase64: other.privateKey,
        ),
        throwsA(anything),
      );
    });

    test('密封盒比明文长 48 字节（32 临时公钥 + 16 MAC）', () {
      final pair = SodiumCrypto.generateKeyPair();
      final sealed = base64Decode(
        SodiumCrypto.sealEncrypt(List.filled(32, 1), pair.publicKey),
      );
      expect(sealed.length, 32 + 48);
    });
  });

  group('crypto_kx（SAS 设备校验）', () {
    test('客户端会话密钥与 libsodium 一致', () {
      final out = SodiumCrypto.kxClientSessionKeys(
        clientPublicKeyBase64: SodiumVectors.kxClientPublicKey,
        clientPrivateKeyBase64: SodiumVectors.kxClientPrivateKey,
        serverPublicKeyBase64: SodiumVectors.kxServerPublicKey,
      );
      expect(out.rx, SodiumVectors.kxClientRx);
      expect(out.tx, SodiumVectors.kxClientTx);
    });

    test('服务端视角 rx/tx 与客户端对调（双向一致）', () {
      final client = SodiumCrypto.kxClientSessionKeys(
        clientPublicKeyBase64: SodiumVectors.kxClientPublicKey,
        clientPrivateKeyBase64: SodiumVectors.kxClientPrivateKey,
        serverPublicKeyBase64: SodiumVectors.kxServerPublicKey,
      );
      final server = SodiumCrypto.kxServerSessionKeys(
        serverPublicKeyBase64: SodiumVectors.kxServerPublicKey,
        serverPrivateKeyBase64: SodiumVectors.kxServerPrivateKey,
        clientPublicKeyBase64: SodiumVectors.kxClientPublicKey,
      );
      expect(server.rx, client.tx);
      expect(server.tx, client.rx);
    });
  });

  group('密钥生成', () {
    test('X25519 密钥对长度 32/32，公钥能由私钥推出（scalarmult 一致性）', () {
      final a = SodiumCrypto.generateKeyPair();
      final b = SodiumCrypto.generateKeyPair();
      expect(base64Decode(a.publicKey), hasLength(32));
      expect(base64Decode(a.privateKey), hasLength(32));
      expect(a.publicKey, isNot(b.publicKey));
      // 走一遍 kx：a 当客户端、b 当服务端，两边算出来的会话密钥必须配对
      // （libsodium 的规则：client.rx == server.tx、client.tx == server.rx）
      final client = SodiumCrypto.kxClientSessionKeys(
        clientPublicKeyBase64: a.publicKey,
        clientPrivateKeyBase64: a.privateKey,
        serverPublicKeyBase64: b.publicKey,
      );
      final server = SodiumCrypto.kxServerSessionKeys(
        serverPublicKeyBase64: b.publicKey,
        serverPrivateKeyBase64: b.privateKey,
        clientPublicKeyBase64: a.publicKey,
      );
      expect(client.rx, server.tx);
      expect(client.tx, server.rx);
    });

    test('频道密钥是 32 字节 base64 随机值', () {
      final k1 = SodiumCrypto.generateChannelKey();
      final k2 = SodiumCrypto.generateChannelKey();
      expect(base64Decode(k1), hasLength(32));
      expect(k1, isNot(k2));
    });

    test('randomBytes 长度对、会变', () {
      expect(SodiumCrypto.randomBytes(24), hasLength(24));
      expect(SodiumCrypto.randomBytes(32), isNot(SodiumCrypto.randomBytes(32)));
    });
  });
}
