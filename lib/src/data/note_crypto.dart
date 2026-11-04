// 加密笔记的密码学实现 —— **逐字对照**官方客户端，不是自定义方案。
//
// 两处权威实现完全一致：
//   1. Web 客户端（NoteStation 2.6.10-3938，`ui/notestation.js`）：
//        content = CryptoJS.AES.encrypt(Define.MAGIC + html, password).toString()
//        Define.MAGIC = "NoTeStAtIoNMaGic"
//        decryptContent: CryptoJS.AES.decrypt(c, pwd).toString(Utf8)
//                        → startsWith(MAGIC) ? slice(MAGIC.length) : throw
//   2. Android（DS note 1.12.0-346，`com/synology/dsnote/utils/AES256Cipher.java`）
//        Cipher "AES/CBC/PKCS7Padding"
//        salt = 8 random bytes
//        derived = MD5(∅‖pwd‖salt) ‖ MD5(prev‖pwd‖salt) ‖ MD5(prev‖pwd‖salt)
//                  → key = 前 32 字节，iv = 后 16 字节（即 OpenSSL EVP_BytesToKey，1 轮）
//        输出 = Base64("Salted__" ‖ salt ‖ cipher)
//
// CryptoJS 传**字符串口令**时用的就是这套 EVP_BytesToKey(MD5, 1 轮) +
// `Salted__` 容器，所以两边互通：Web 端加密的笔记 Android 端能解开，反之亦然。
//
// 注意：口令最长为 32 字符（Web 表单 `maxlength:32`）。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/digests/md5.dart';
import 'package:pointycastle/paddings/pkcs7.dart';
import 'package:pointycastle/padded_block_cipher/padded_block_cipher_impl.dart';

import '../core/i18n/data_text.dart';

/// 解密失败（口令不对 / 内容不是加密笔记）时抛出。
class NoteDecryptException implements Exception {
  /// [message] 不传时按**当前应用语言**取默认文案（docs §4.6）。
  ///
  /// ⚠️ 这里不能再是 `const` 构造函数：默认文案要在**构造时**从 `dataText` 取。
  /// 异常对象里只存 `String` —— 异常可能跨语言切换存活。
  NoteDecryptException([String? message])
    : message = message ?? dataText('noteWrongPasscode', '口令不对，或这段内容不是加密笔记');

  final String message;

  @override
  String toString() => message;
}

/// 加密笔记的 AES256 口令加解密（CryptoJS / OpenSSL 兼容）。
abstract final class NoteCrypto {
  /// 官方 `SYNO.SDS.NoteStation.Define.MAGIC`（Web）/ `MAGIC_NOTE_STATION`（Android）
  static const String magic = 'NoTeStAtIoNMaGic';

  /// 官方 `MAGIC_OPENSSL`
  static const String opensslMagic = 'Salted__';

  /// 官方 `SALT_LENGTH`
  static const int saltLength = 8;

  /// 口令上限（官方表单 `maxlength:32`）
  static const int maxPasswordLength = 32;

  /// 明文 HTML → 密文（可以直接塞进 `Note/set` 的 `content`）。
  ///
  /// 每次调用都重新随机 salt（官方 Android 用 `new Random()`，Web 用 CryptoJS
  /// 的随机 salt）——所以同样的正文两次加密结果不同，这是**正常且必须**的。
  static String encryptContent(
    String plainHtml,
    String password, {
    Random? random,
    Uint8List? saltOverride,
  }) {
    final salt = saltOverride ?? Uint8List(saltLength);
    if (saltOverride == null) {
      final rnd = random ?? Random.secure();
      for (var i = 0; i < salt.length; i++) {
        salt[i] = rnd.nextInt(256);
      }
    }
    final keyIv = _deriveKeyIv(password, salt);

    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    );
    cipher.init(
      true,
      PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
        ParametersWithIV<KeyParameter>(KeyParameter(keyIv.key), keyIv.iv),
        null,
      ),
    );
    final plain = Uint8List.fromList(utf8.encode('$magic$plainHtml'));
    final encrypted = cipher.process(plain);

    final out = BytesBuilder(copy: false)
      ..add(ascii.encode(opensslMagic))
      ..add(salt)
      ..add(encrypted);
    return base64.encode(out.toBytes());
  }

  /// 密文 → 明文 HTML；口令不对 / 容器不对 → [NoteDecryptException]。
  static String decryptContent(String cipherText, String password) {
    final Uint8List raw;
    try {
      raw = base64.decode(cipherText.trim());
    } catch (_) {
      throw NoteDecryptException(
        dataText('noteNotBase64', '这段内容不是 Base64，不是加密笔记'),
      );
    }
    if (raw.length <= opensslMagic.length + saltLength ||
        ascii.decode(raw.sublist(0, opensslMagic.length), allowInvalid: true) !=
            opensslMagic) {
      throw NoteDecryptException(
        dataText('noteNoSaltedHeader', '没有 "Salted__" 容器头，不是本方案的密文'),
      );
    }
    final salt = Uint8List.sublistView(
      raw,
      opensslMagic.length,
      opensslMagic.length + saltLength,
    );
    final body = Uint8List.sublistView(raw, opensslMagic.length + saltLength);
    final keyIv = _deriveKeyIv(password, salt);

    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    );
    cipher.init(
      false,
      PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
        ParametersWithIV<KeyParameter>(KeyParameter(keyIv.key), keyIv.iv),
        null,
      ),
    );
    final Uint8List plain;
    try {
      plain = cipher.process(body);
    } catch (_) {
      throw NoteDecryptException();
    }
    String text;
    try {
      text = utf8.decode(plain);
    } catch (_) {
      throw NoteDecryptException();
    }
    if (!text.startsWith(magic)) throw NoteDecryptException();
    return text.substring(magic.length);
  }

  /// 判断一段内容「像不像」加密笔记（`Note/list` 里正文可能是密文时用）。
  static bool looksEncrypted(String content) {
    final t = content.trim();
    if (t.isEmpty) return false;
    if (!t.startsWith('U2FsdGVkX1')) return false; // base64("Salted__")
    try {
      final raw = base64.decode(t);
      return raw.length > saltLength + opensslMagic.length &&
          ascii.decode(
                raw.sublist(0, opensslMagic.length),
                allowInvalid: true,
              ) ==
              opensslMagic;
    } catch (_) {
      return false;
    }
  }

  /// OpenSSL `EVP_BytesToKey`（MD5，1 轮）＝ Android `md5(∅‖pwd‖salt)` 三连。
  static _KeyIv _deriveKeyIv(String password, Uint8List salt) {
    final pwd = Uint8List.fromList(utf8.encode(password));
    final md5 = MD5Digest();
    final blocks = <Uint8List>[];
    var prev = Uint8List(0);
    while (blocks.length * 16 < 48) {
      final input = BytesBuilder(copy: false)
        ..add(prev)
        ..add(pwd)
        ..add(salt);
      final digest = md5.process(input.toBytes());
      blocks.add(digest);
      prev = digest;
    }
    final all = BytesBuilder(copy: false);
    for (final b in blocks) {
      all.add(b);
    }
    final derived = all.toBytes();
    return _KeyIv(
      Uint8List.sublistView(derived, 0, 32),
      Uint8List.sublistView(derived, 32, 48),
    );
  }
}

class _KeyIv {
  const _KeyIv(this.key, this.iv);

  final Uint8List key;
  final Uint8List iv;
}
