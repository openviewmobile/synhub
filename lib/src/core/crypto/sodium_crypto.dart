// E2EE 用的 libsodium 原语（Phase 7）。
//
// 对应反编译的 `com/synology/dschat/data/local/SodiumHelper.java` +
// `SodiumHash.generic`，逐个函数对齐：
//
// | 原 App（libsodium）                          | 这里                                |
// | -------------------------------------------- | ----------------------------------- |
// | `crypto_secretbox_easy` / `open_easy`         | [secretboxEncrypt]/[secretboxDecrypt] |
// | `crypto_box_seal` / `seal_open`               | [sealEncrypt]/[sealDecrypt]         |
// | `crypto_kx_keypair`                           | [generateKeyPair]                   |
// | `crypto_kx_client_session_keys`               | [kxClientSessionKeys]               |
// | `crypto_generichash`（blake2b-256）           | [generichash256] / [passcodeKey]    |
//
// **纯 Dart 实现**（`pinenacl` 的 TweetNaCl 移植 + `blake2b`），不依赖 native
// 库——Android 上少一个要交叉编译的 .so，也不用管拆包/ABI。
// 正确性由 `test/support/sodium_vectors.dart`（本机真 libsodium 生成）+
// `tool/gen_sodium_vectors.py --verify`（Dart↔libsodium 双向互通）保证。
import 'dart:convert';
import 'dart:math';

import 'package:blake2b/blake2b.dart';
import 'package:pinenacl/tweetnacl.dart';
import 'package:pinenacl/x25519.dart';

/// 24 字节 nonce + 16 字节 Poly1305 MAC（libsodium 常量）
const int kNonceBytes = 24;
const int kMacBytes = 16;
const int kSecretboxKeyBytes = 32;
const int kPublicKeyBytes = 32;
const int kPrivateKeyBytes = 32;

class SodiumException implements Exception {
  const SodiumException(this.message);
  final String message;
  @override
  String toString() => 'SodiumException: $message';
}

class SodiumCrypto {
  /// `randombytes_buf`（libsodium 用 ChaCha20 的 CSPRNG，这里用
  /// `Random.secure()`——Android/iOS 上都接的是系统熵源）
  static final _rng = Random.secure();

  static Uint8List randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _rng.nextInt(256);
    }
    return out;
  }

  // ------------------------------------------------------------ generichash

  /// `crypto_generichash(out, outlen, in, inlen, NULL, 0)` —— BLAKE2b
  static Uint8List generichash256(List<int> data) {
    final hasher = Blake2b(256);
    hasher.update(Uint8List.fromList(data), 0, data.length);
    return hasher.digest(Uint8List(32), 0);
  }

  /// 口令密钥：`SodiumHash().generic(passcode)` —— 私钥就是用这个当 secretbox 密钥
  static Uint8List passcodeKey(String passcode) =>
      generichash256(utf8.encode(passcode));

  // ------------------------------------------------------------ secretbox

  /// `crypto_secretbox_easy`：返回 `MAC(16) || 密文`
  static Uint8List secretboxRaw(
    List<int> plain, {
    required List<int> key,
    required List<int> nonce,
  }) {
    if (key.length != kSecretboxKeyBytes) {
      throw const SodiumException('secretbox 密钥必须是 32 字节');
    }
    if (nonce.length != kNonceBytes) {
      throw const SodiumException('nonce 必须是 24 字节');
    }
    final box = SecretBox(Uint8List.fromList(key));
    final out = box.encrypt(
      Uint8List.fromList(plain),
      nonce: Uint8List.fromList(nonce),
    );
    return Uint8List.fromList(out.cipherText.asTypedList);
  }

  /// `crypto_secretbox_open_easy`（`sealed` = MAC || 密文）
  static Uint8List secretboxOpenRaw(
    List<int> sealed, {
    required List<int> key,
    required List<int> nonce,
  }) {
    final box = SecretBox(Uint8List.fromList(key));
    try {
      final out = box.decrypt(
        ByteList(sealed),
        nonce: Uint8List.fromList(nonce),
      );
      return Uint8List.fromList(out.toList());
    } catch (e) {
      throw SodiumException('解密失败（密钥/密文不对）：$e');
    }
  }

  /// 跟原 App 一样：`nonce(24) || MAC(16) || 密文`，整体 base64
  static String secretboxEncrypt(
    List<int> plain,
    List<int> key, {
    List<int>? nonce,
  }) {
    final n = nonce ?? randomBytes(kNonceBytes);
    final body = secretboxRaw(plain, key: key, nonce: n);
    return base64Encode(Uint8List.fromList([...n, ...body]));
  }

  /// [sealed] = base64(nonce || MAC || 密文)
  static Uint8List secretboxDecryptRaw(String sealed, List<int> key) {
    final raw = base64Decode(sealed);
    if (raw.length < kNonceBytes + kMacBytes) {
      throw const SodiumException('密文太短');
    }
    return secretboxOpenRaw(
      raw.sublist(kNonceBytes),
      key: key,
      nonce: raw.sublist(0, kNonceBytes),
    );
  }

  // ------------------------------------------------------------ 消息 / 文件名 / 文件

  /// `SodiumHelper.encryptMessage`：key 是 base64 的频道密钥
  static String encryptMessage(String text, String channelKeyBase64) =>
      secretboxEncrypt(utf8.encode(text), base64Decode(channelKeyBase64));

  static String decryptMessage(
    String encryptedBase64,
    String channelKeyBase64,
  ) => utf8.decode(
    secretboxDecryptRaw(encryptedBase64, base64Decode(channelKeyBase64)),
  );

  /// `encryptFileName`：与消息同构造（`nonce || MAC || 密文`），
  /// 但整体是 **hex** 而不是 base64
  static String encryptFileNameHex(String name, List<int> channelKey) {
    final n = randomBytes(kNonceBytes);
    final body = secretboxRaw(utf8.encode(name), key: channelKey, nonce: n);
    return _hexEncode(Uint8List.fromList([...n, ...body]));
  }

  static String decryptFileNameHex(String hex, List<int> channelKey) {
    final raw = _hexDecode(hex);
    return utf8.decode(
      secretboxOpenRaw(
        raw.sublist(kNonceBytes),
        key: channelKey,
        nonce: raw.sublist(0, kNonceBytes),
      ),
    );
  }

  /// `encryptFile`：`nonce || MAC || 密文` 的原始字节（不是 base64）
  static Uint8List encryptFileBytes(List<int> body, List<int> channelKey) {
    final n = randomBytes(kNonceBytes);
    return Uint8List.fromList([
      ...n,
      ...secretboxRaw(body, key: channelKey, nonce: n),
    ]);
  }

  static Uint8List decryptFileBytes(List<int> raw, List<int> channelKey) {
    if (raw.length < kNonceBytes + kMacBytes) {
      throw const SodiumException('文件密文太短');
    }
    return secretboxOpenRaw(
      raw.sublist(kNonceBytes),
      key: channelKey,
      nonce: raw.sublist(0, kNonceBytes),
    );
  }

  // ------------------------------------------------------------ 匿名投递（频道密钥分发）

  /// `crypto_box_seal`：用收件人公钥封一个只有他能开的盒子（发件人匿名）
  static String sealEncrypt(List<int> plain, String recipientPublicKeyBase64) {
    final box = SealedBox(PublicKey(base64Decode(recipientPublicKeyBase64)));
    final sealed = box.encrypt(Uint8List.fromList(plain));
    return base64Encode(sealed);
  }

  /// `crypto_box_seal_open`
  static Uint8List sealDecrypt(
    List<int> sealed, {
    required String publicKeyBase64,
    required String privateKeyBase64,
  }) {
    final sk = PrivateKey(base64Decode(privateKeyBase64));
    final box = SealedBox(sk);
    final out = box.decrypt(Uint8List.fromList(sealed));
    return Uint8List.fromList(out.toList());
  }

  // ------------------------------------------------------------ 密钥对 / 口令

  /// `crypto_kx_keypair`（== X25519 密钥对；`crypto_box_keypair` 同构）
  static ({String publicKey, String privateKey}) generateKeyPair() {
    final pk = Uint8List(kPublicKeyBytes);
    final sk = Uint8List(kPrivateKeyBytes);
    TweetNaCl.crypto_box_keypair(pk, sk);
    return (publicKey: base64Encode(pk), privateKey: base64Encode(sk));
  }

  /// `crypto_kx_client_session_keys`（SAS 设备校验）。
  ///
  /// libsodium 的构造：q = X25519(client_sk, server_pk)，
  /// 然后 `blake2b(q || client_pk || server_pk, 64)` 切两半（rx / tx）。
  static ({String rx, String tx}) kxClientSessionKeys({
    required String clientPublicKeyBase64,
    required String clientPrivateKeyBase64,
    required String serverPublicKeyBase64,
  }) {
    final q = _scalarmult(clientPrivateKeyBase64, serverPublicKeyBase64);
    final keys = _kxKeys(q, clientPublicKeyBase64, serverPublicKeyBase64);
    return (
      rx: base64Encode(keys.sublist(0, 32)),
      tx: base64Encode(keys.sublist(32, 64)),
    );
  }

  /// `crypto_kx_server_session_keys`（收到的 rx/tx 跟客户端正好对调）
  static ({String rx, String tx}) kxServerSessionKeys({
    required String serverPublicKeyBase64,
    required String serverPrivateKeyBase64,
    required String clientPublicKeyBase64,
  }) {
    final q = _scalarmult(serverPrivateKeyBase64, clientPublicKeyBase64);
    final keys = _kxKeys(q, clientPublicKeyBase64, serverPublicKeyBase64);
    return (
      rx: base64Encode(keys.sublist(32, 64)),
      tx: base64Encode(keys.sublist(0, 32)),
    );
  }

  static Uint8List _kxKeys(
    Uint8List q,
    String clientPkB64,
    String serverPkB64,
  ) {
    final hasher = Blake2b.blake2b(null, 64, null, null);
    hasher.update(q, 0, q.length);
    final c = base64Decode(clientPkB64);
    hasher.update(Uint8List.fromList(c), 0, c.length);
    final s = base64Decode(serverPkB64);
    hasher.update(Uint8List.fromList(s), 0, s.length);
    return hasher.digest(Uint8List(64), 0);
  }

  static Uint8List _scalarmult(String skB64, String pkB64) {
    final q = Uint8List(kPublicKeyBytes);
    TweetNaCl.crypto_scalarmult(q, base64Decode(skB64), base64Decode(pkB64));
    // 全零 = 低阶点，libsodium 会报错
    if (q.every((b) => b == 0)) {
      throw const SodiumException('X25519 共享密钥全零（低阶点）');
    }
    return q;
  }

  /// `encryptPrivateKey`：secretbox(私钥, key=blake2b256(passcode)) → base64
  static String encryptPrivateKey(String privateKey, String passcode) =>
      secretboxEncrypt(utf8.encode(privateKey), passcodeKey(passcode));

  /// `decryptPrivateKey`
  static String decryptPrivateKey(String encryptedBase64, String passcode) =>
      utf8.decode(secretboxDecryptRaw(encryptedBase64, passcodeKey(passcode)));

  /// `genChannelKey`：32 字节随机 → base64
  static String generateChannelKey() =>
      base64Encode(randomBytes(kSecretboxKeyBytes));

  // ------------------------------------------------------------ 小工具

  /// 大写入（`LazySodium.hexArray = "0123456789ABCDEF"`，原 App 的 `toHexStr`
  /// 输出的就是大写；加密附件的文件名按这个大小写发出去，官方客户端才认）。
  /// 读取 [decodeHex] 两种大小写都收。
  static String _hexEncode(List<int> bytes) => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();

  static Uint8List _hexDecode(String hex) {
    if (hex.length.isOdd) throw const SodiumException('hex 长度必须是偶数');
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
