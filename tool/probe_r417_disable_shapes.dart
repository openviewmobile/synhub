// r417 **写**探针（只在轮次内建的临时相册 `r417share` 上做，轮末整套删除）：
// 「关闭外链分享」为什么没落地 —— 逐个形状打同一个方法，看**原始回包**。
//
// 背景（真机 r417）：点「关闭外链分享」→ 确认 → 界面弹 `Link sharing turned off`
// （说明**没抛错**，即服务端回了 success），但同刻：
//   * 界面仍显示外链 + `Turn off link sharing`；
//   * NAS 侧 `Browse.Album/get` 的 `shared` 仍是 `true`，`category=shared` 仍有它。
// ⇒ 不是"请求失败"，是"请求被接受但什么都没改"（仪器73 那一族的形态）。
//
// 本探针把 App 现在发的形状与几个候选形状**逐个打完各读一次状态**，定性"读到什么"。
//
// 用法：set -a; . ~/.synhub-nas.env; set +a; dart run tool/probe_r417_disable_shapes.dart
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

const String _albumId = '9';

String _env(String primary, String legacy) {
  final v = Platform.environment[primary];
  if (v != null && v.isNotEmpty) return v;
  final l = Platform.environment[legacy];
  if (l != null && l.isNotEmpty) return l;
  stderr.writeln('缺环境变量 $primary（或 $legacy）');
  exit(2);
}

late DsmWebApi _api;

Future<Object?> _call(
  String name,
  String method,
  int version,
  Map<String, dynamic> params,
) async {
  try {
    final data = await _api.call(
      name,
      method,
      preferredVersion: version,
      params: params,
    );
    print('    OK   ${jsonEncode(data)}');
    return data;
  } catch (e) {
    print('    ERR  $e');
    if (e is DsmApiException) print('         raw=${jsonEncode(e.raw)}');
    return null;
  }
}

/// 服务端此刻怎么记账：`shared` / 外链长度 / 口令长度 / `category=shared` 条数。
Future<void> _state(String label) async {
  final get = await _call('SYNO.Foto.Browse.Album', 'get', 4, {
    'id': '[$_albumId]',
    'additional': '["sharing_info","thumbnail"]',
  });
  var passphrase = '';
  if (get is Map) {
    final list = (get['list'] as List?) ?? const [];
    if (list.isNotEmpty) {
      final m = (list.first as Map).cast<String, dynamic>();
      final info =
          ((m['additional'] as Map?)?['sharing_info'] as Map?)
              ?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      passphrase = '${info['passphrase']}';
      print(
        '  [$label] shared=${m['shared']} '
        'link=<len=${'${info['sharing_link']}'.length}> '
        'passphrase=<len=${passphrase.length}> '
        'privacy=${info['privacy_type']}',
      );
    }
  }
  final shared = await _call('SYNO.Foto.Browse.Album', 'list', 4, {
    'offset': '0',
    'limit': '50',
    'sort_by': 'share_modify_time',
    'sort_direction': 'desc',
    'category': 'shared',
  });
  final sharedList = (shared is Map ? shared['list'] : null) as List? ?? const [];
  print('  [$label] category=shared 共 ${sharedList.length} 个');

  // 把口令带回给下面几个形状用（只在内存里，不打印）
  _passphrase = passphrase;
}

String _passphrase = '';

Future<void> main() async {
  _api = DsmWebApi(
    DirectTransport.url(
      _env('SYNO_NAS_URL', 'SYNO_URL'),
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await _api.discover();
  await _api.login(
    account: _env('SYNO_NAS_ACCOUNT', 'SYNO_ACCOUNT'),
    password: _env('SYNO_NAS_PASSWORD', 'SYNO_PASSWORD'),
    session: 'Chat',
  );
  final me = await _call('SYNO.Foto.UserInfo', 'me', 1, const {});
  print('身份=${jsonEncode(me)}');

  await _state('起点');
  final appShape = jsonEncode([
    {
      'action': 'delete',
      'member': {'type': 'public'},
    },
  ]);

  print('① App 现在发的形状：permission(JSON 串) = delete public');
  await _call('SYNO.Foto.Sharing.Passphrase', 'update', 1, {
    'passphrase': _passphrase,
    'permission': appShape,
  });
  await _state('① 之后');

  print('② privacy_type=private');
  await _call('SYNO.Foto.Sharing.Passphrase', 'update', 1, {
    'passphrase': _passphrase,
    'privacy_type': 'private',
  });
  await _state('② 之后');

  print('③ permission(JSON 串) + privacy_type');
  await _call('SYNO.Foto.Sharing.Passphrase', 'update', 1, {
    'passphrase': _passphrase,
    'permission': appShape,
    'privacy_type': 'private',
  });
  await _state('③ 之后');

  print('④ set_shared enabled=false（已知"只生成链接不改可见性"）');
  await _call('SYNO.Foto.Sharing.Passphrase', 'set_shared', 1, {
    'policy': 'album',
    'album_id': _albumId,
    'enabled': 'false',
  });
  await _state('④ 之后');

  print('[r417/disable] 完成（写探针：只碰临时相册 $_albumId）');
}
