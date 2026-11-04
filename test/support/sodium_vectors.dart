// 由 tool/gen_sodium_vectors.py 生成 —— 别手改。
//
// 基准是**本机真 libsodium**（brew 的 libsodium.dylib）：
// 离线测试拿这些固定向量校验纯 Dart 实现（pinenacl + blake2b）是否与
// libsodium 完全一致——E2EE 只要差一个字节，跟服务端/其它客户端就对不上了。
// ignore_for_file: lines_longer_than_80_chars

class SodiumVectors {
  static const passcode = 'flt-passcode-2026';

  /// blake2b-256(passcode) —— `crypto_generichash`，私钥加密用的口令密钥
  static const passcodeKey = '5/fG3MyX+FHnaejEN9gg3dJGtZG9Ob6kXG5xfvZdxaE=';

  static const secretboxKey = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
  static const secretboxNonce = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYX';
  static const secretboxPlaintext = '中文消息 with emoji 🙂';
  static const secretboxCiphertext =
      'H834p5ZY83WkgWNgmY3CX7pHlalRTUSmM9oOkUj4I+M6hSOy409Wz+c9/hY=';

  static const sealRecipientPublicKey =
      'VzCACrNA/LGM5REe2p1wX5E4i0HkVEy9EDullC2yIz4=';
  static const sealRecipientPrivateKey =
      'iHr1ijYgLgXEwc/sW/bGH61mvKhRU2AEB0sx8bVuSsk=';
  static const sealPlaintext = 'QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8=';
  static const sealSealed =
      'ty/KO7O2N5BVTaI5wuCsCyvvGVYLkWv7l3LsLtg5xgRgYbr9ewRGrJPIOLDjPbQZUBzfonupU6jng0bofSwBKuVl4JjYgyU/qDXtaChN2e4=';

  static const kxClientPublicKey =
      'p+CdISlWjoqlz5bqf9ng+IGl14v1kiaVYpY/e29okFA=';
  static const kxClientPrivateKey =
      'Xt5BmZY4zcq+w3yNuXJMlRzun0sqqeUi730B85mr/U8=';
  static const kxServerPublicKey =
      'fd5OvH5rsyk6RkNCOyLKTfNUK5DBd5IwvXd6nubT2S8=';
  static const kxServerPrivateKey =
      'uw4kvv41zWEq0G2nekpUpMeNAbOPRgntyx1NAGKMwvo=';
  static const kxClientRx = 'aimGC22Ow4UROZN4/GlIOAMyN9gV3S6Vf97CVrMeaME=';
  static const kxClientTx = 'vUagoEzfTENxNTvNzw3mCTT8993+ptTi62o3EpbtBwI=';
  static const kxServerRx = 'vUagoEzfTENxNTvNzw3mCTT8993+ptTi62o3EpbtBwI=';
  static const kxServerTx = 'aimGC22Ow4UROZN4/GlIOAMyN9gV3S6Vf97CVrMeaME=';
}
