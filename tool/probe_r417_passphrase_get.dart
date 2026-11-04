// r417 只读探针：`Sharing.Passphrase/get` 的**原始**回包 —— 用来判"关闭外链分享"
// 到底有没有落地。背景（真机 r417）：点「关闭外链分享」→ 确认 → 界面弹
// `Link sharing turned off`，但同刻界面**仍**显示外链 + `Turn off link sharing`，
// 且 NAS 侧 `Browse.Album/get` 的 `shared` 仍是 `true`、`category=shared` 仍有它
// ⇒ 必须读服务端自己的共享状态，不许推断。
//
// 只读：只调 `get`（官方方法表 `grantByDefault:false` / `grantable:false`）。
//
// 用法：set -a; . ~/.synhub-nas.env; set +a; dart run tool/probe_r417_passphrase_get.dart
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

String _env(String primary, String legacy) {
  final v = Platform.environment[primary];
  if (v != null && v.isNotEmpty) return v;
  final l = Platform.environment[legacy];
  if (l != null && l.isNotEmpty) return l;
  stderr.writeln('缺环境变量 $primary（或 $legacy）');
  exit(2);
}

Future<void> main() async {
  final api = DsmWebApi(
    DirectTransport.url(
      _env('SYNO_NAS_URL', 'SYNO_URL'),
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  await api.login(
    account: _env('SYNO_NAS_ACCOUNT', 'SYNO_ACCOUNT'),
    password: _env('SYNO_NAS_PASSWORD', 'SYNO_PASSWORD'),
    session: 'Chat',
  );

  var secret = '';

  Future<void> probe(String label, Map<String, dynamic> params) async {
    try {
      final data = await api.call(
        'SYNO.Foto.Sharing.Passphrase',
        'get',
        preferredVersion: 1,
        params: params,
      );
      final redacted = secret.isEmpty
          ? jsonEncode(data)
          : jsonEncode(data).replaceAll(secret, '<redacted>');
      print('[r417/passphrase] $label OK $redacted');
    } catch (e) {
      print('[r417/passphrase] $label ERROR $e');
      if (e is DsmApiException) print('   raw=${jsonEncode(e.raw)}');
    }
  }

  // 口令本身**不落盘**：先从相册读出来放进变量，回包里的口令一律打码。
  Future<String> passphraseOf(String albumId) async {
    final Map<String, dynamic> data;
    try {
      data = await api.call(
      'SYNO.Foto.Browse.Album',
      'get',
      preferredVersion: 4,
      params: {
        'id': '[$albumId]',
        'additional': '["sharing_info"]',
        },
      );
    } catch (e) {
      print('[r417/passphrase] 读相册失败 $e');
      if (e is DsmApiException) print('   raw=${jsonEncode(e.raw)}');
      return '';
    }
    final list = (data['list'] as List?) ?? const [];
    if (list.isEmpty) return '';
    final info =
        ((list.first as Map)['additional'] as Map?)?['sharing_info'] as Map?;
    return '${info?['passphrase'] ?? ''}';
  }

  secret = await passphraseOf('9');
  print('[r417/passphrase] album 9 口令长度=${secret.length}');
  await probe('album 9（带口令）', {'passphrase': secret});
  await probe('口令乱填', const {'passphrase': 'not-a-real-passphrase'});

  print('[r417/passphrase] 完成（只读）');
}
