// 交叉校验用：读 tool/sodium_vectors.json，用**纯 Dart 实现**产出密文/会话密钥，
// 再由 tool/gen_sodium_vectors.py --verify 交给真 libsodium 验证。
//
//   python3 tool/gen_sodium_vectors.py --verify
//
// 这样双向都通了：libsodium → Dart（离线测试的固定向量）、Dart → libsodium（这里）。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/crypto/sodium_crypto.dart';

Future<void> main() async {
  final vectors =
      jsonDecode(File('tool/sodium_vectors.json').readAsStringSync())
          as Map<String, dynamic>;

  final sb = vectors['secretbox'] as Map<String, dynamic>;
  final key = base64Decode(sb['key'] as String);
  const plaintext = 'Dart → libsodium 交叉校验 🙂';
  final nonce = SodiumCrypto.randomBytes(kNonceBytes);
  final ct = SodiumCrypto.secretboxRaw(
    utf8.encode(plaintext),
    key: key,
    nonce: nonce,
  );

  final seal = vectors['seal'] as Map<String, dynamic>;
  final channelKey = base64Decode(SodiumCrypto.generateChannelKey());
  final sealed = SodiumCrypto.sealEncrypt(
    channelKey,
    seal['recipientPublicKey'] as String,
  );

  final kx = vectors['kx'] as Map<String, dynamic>;
  final client = SodiumCrypto.kxClientSessionKeys(
    clientPublicKeyBase64: '${kx['clientPublicKey']}',
    clientPrivateKeyBase64: '${kx['clientPrivateKey']}',
    serverPublicKeyBase64: '${kx['serverPublicKey']}',
  );

  File('tool/_dart_sodium_out.json').writeAsStringSync(
    jsonEncode({
      'secretboxNonce': base64Encode(nonce),
      'secretboxCiphertext': base64Encode(ct),
      'secretboxPlaintext': plaintext,
      'sealed': sealed,
      'sealPlaintext': base64Encode(channelKey),
      'kxClientPublicKey': '${kx['clientPublicKey']}',
      'kxServerPublicKey': '${kx['serverPublicKey']}',
      'kxRx': client.rx,
      'kxTx': client.tx,
    }),
  );
  print('Dart 侧产物已写入 tool/_dart_sodium_out.json');
}
