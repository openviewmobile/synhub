// 加密笔记的算法兼容性测试。
//
// ★ 判定标准不是"我自己加能自己解"，而是**与官方实现逐字节一致**：
//   下面的 Base64 是 `openssl enc -aes-256-cbc -md md5 -S <salt>` 的密文
//   拼上 `"Salted__" + salt` 头得到的（即 OpenSSL 的 EVP_BytesToKey/MD5 1 轮
//   + "Salted__" 容器），明文是 `"NoTeStAtIoNMaGic" + 正文`。
//   CryptoJS 传字符串口令、官方 Android `AES256Cipher` 用的都是同一套 KDF，
//   所以这三方互为已知答案向量：
//     v1 = base64("Salted__" ‖ 0001020304050607 ‖ cipher)
//     v2 = base64("Salted__" ‖ ffeeddccbbaa9988 ‖ cipher)
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/note_crypto.dart';

void main() {
  group('NoteCrypto 与官方 CryptoJS / Android AES256Cipher 互通', () {
    test('解密 OpenSSL(CryptoJS 同格式) 生成的密文', () {
      const cipher =
          'U2FsdGVkX18AAQIDBAUGByqqrkWWkzo/BI0U1Mm/hhTBXfeplwaRKt'
          'NyjXfvxHRElwTMFzagSR6BFCf5MqUvhg==';
      final plain = NoteCrypto.decryptContent(cipher, 'secret');
      expect(plain, '<p>hello 加密笔记</p>');
    });

    test('用固定 salt 加密，结果与 OpenSSL 逐字节相同', () {
      final salt = Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]);
      final out = NoteCrypto.encryptContent(
        '<p>hello 加密笔记</p>',
        'secret',
        saltOverride: salt,
      );
      expect(
        out,
        'U2FsdGVkX18AAQIDBAUGByqqrkWWkzo/BI0U1Mm/hhTBXfeplwaRKt'
        'NyjXfvxHRElwTMFzagSR6BFCf5MqUvhg==',
      );
      // 容器头 = "Salted__" + salt
      final raw = base64.decode(out);
      expect(ascii.decode(raw.sublist(0, 8)), 'Salted__');
      expect(raw.sublist(8, 16), salt);
    });

    test('内含特殊字符的口令（口令带 : 和 *）', () {
      const cipher =
          'U2FsdGVkX1+eHE9t8D0h9hUOGzHuLIbJWGoCiexMgicg8QtXheHUTw47mBx91qdp';
      expect(NoteCrypto.decryptContent(cipher, 'q*7B:vT3D1'), '<p>a</p>');
    });

    test('口令不对 → NoteDecryptException，而不是乱码', () {
      const cipher =
          'U2FsdGVkX18AAQIDBAUGByqqrkWWkzo/BI0U1Mm/hhTBXfeplwaRKt'
          'NyjXfvxHRElwTMFzagSR6BFCf5MqUvhg==';
      expect(
        () => NoteCrypto.decryptContent(cipher, 'wrong'),
        throwsA(isA<NoteDecryptException>()),
      );
    });

    test('不是密文的内容 → 明确的异常', () {
      expect(
        () => NoteCrypto.decryptContent('<p>plain</p>', 'x'),
        throwsA(isA<NoteDecryptException>()),
      );
      // 合法 Base64 但没有 Salted__ 头
      expect(
        () =>
            NoteCrypto.decryptContent(base64.encode(utf8.encode('nope')), 'x'),
        throwsA(isA<NoteDecryptException>()),
      );
    });

    test('looksEncrypted：只认本方案的容器', () {
      expect(
        NoteCrypto.looksEncrypted(
          'U2FsdGVkX18AAQIDBAUGByqqrkWWkzo/BI0U1Mm/hhTBXfeplwaRKt'
          'NyjXfvxHRElwTMFzagSR6BFCf5MqUvhg==',
        ),
        isTrue,
      );
      expect(NoteCrypto.looksEncrypted('<p>普通正文</p>'), isFalse);
      expect(NoteCrypto.looksEncrypted(''), isFalse);
      // 长的普通 base64（比如图片 data URI）不能被误判
      expect(
        NoteCrypto.looksEncrypted(base64.encode(List.filled(200, 7))),
        isFalse,
      );
    });

    test('往返：每次 salt 随机 → 同一正文两次密文不同，但都能解回', () {
      final a = NoteCrypto.encryptContent('<p>same</p>', 'pwd');
      final b = NoteCrypto.encryptContent('<p>same</p>', 'pwd');
      expect(a, isNot(b), reason: 'salt 必须随机');
      expect(NoteCrypto.decryptContent(a, 'pwd'), '<p>same</p>');
      expect(NoteCrypto.decryptContent(b, 'pwd'), '<p>same</p>');
    });

    test('MAGIC 与官方常量一致', () {
      expect(NoteCrypto.magic, 'NoTeStAtIoNMaGic');
      expect(NoteCrypto.opensslMagic, 'Salted__');
      expect(NoteCrypto.maxPasswordLength, 32);
    });
  });
}
