// r417 写动词闭环的**只读回读**探针（仪器㉒：写动词前后都要有服务端原文）。
//
// 只读：本文件只调 `me / get / list / peek_item_count`，**不含任何
// add/set/create/delete/update**。它负责在真机动作前后给出"服务端到底变没变"。
//
// 判据（r417 §S5/§S6）：
//   * 共享相册非空分支：`Browse.Album/list category=shared` 从 `[]` 变成有行，
//     且该行的 `shared` / `sharing_info.privacy_type` 与界面一致；
//   * 还原：关闭外链后 `privacy_type` 回 `private`、`shared` 回 `false`、
//     `category=shared` 回 `[]`；
//   * 条件相册保存闭环：`Browse.ConditionAlbum/list` 出现行，
//     且 `additional.condition_object` 里的相机 id 与界面选的候选一致。
//
// 运行：
//   set -a; . ~/.synhub-nas.env; set +a
//   R417_TAG=before dart run tool/probe_r417_readback.dart
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

final String _tag = Platform.environment['R417_TAG'] ?? 'untagged';

void say(String s) => print('[r417/$_tag] $s');

Future<Object?> call(
  DsmWebApi api,
  String name,
  String method, {
  Map<String, dynamic> params = const {},
  int version = 1,
}) async {
  try {
    return await api.call(
      name,
      method,
      preferredVersion: version,
      params: params,
    );
  } catch (e) {
    say('$name/$method v$version ERROR $e');
    if (e is DsmApiException) say('   raw=${jsonEncode(e.raw)}');
    return null;
  }
}

/// 敏感串（外链口令）只报长度，不落盘。
String redact(String s) => s.isEmpty ? '<空>' : '<len=${s.length}>';

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

  // ① 身份（每次回读都先钉"现在连的是谁"）
  final me = await call(api, 'SYNO.Foto.UserInfo', 'me', version: 1);
  say('me=${jsonEncode(me)}');

  // ② 全部普通相册（看临时相册在不在、共享状态）
  final all = await call(
    api,
    'SYNO.Foto.Browse.Album',
    'list',
    version: 4,
    params: {
      'offset': '0',
      'limit': '50',
      'sort_by': 'create_time',
      'sort_direction': 'desc',
      'category': 'all',
      'additional': '["sharing_info","thumbnail"]',
    },
  );
  final allList = (all is Map ? all['list'] : null) as List? ?? const [];
  say('相册(category=all) 共 ${allList.length} 个：');
  for (final a in allList) {
    final m = (a as Map).cast<String, dynamic>();
    final info =
        ((m['additional'] as Map?)?['sharing_info'] as Map?)
            ?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final perm = info['permission'] as List? ?? const [];
    say(
      '  id=${m['id']} name=${m['name']} item_count=${m['item_count']} '
      'type=${m['type']} shared=${m['shared']} '
      'privacy=${info['privacy_type']} link=${redact('${info['sharing_link']}')} '
      'passphrase=${redact('${info['passphrase']}')} members=${perm.length} '
      'owner_user_id=${m['owner_user_id']}',
    );
  }

  // ③ 共享相册：我共享出去的（非空分支的判据）
  final shared = await call(
    api,
    'SYNO.Foto.Browse.Album',
    'list',
    version: 4,
    params: {
      'offset': '0',
      'limit': '50',
      'category': 'shared',
      'sort_by': 'share_modify_time',
      'sort_direction': 'desc',
      'additional': '["sharing_info","thumbnail"]',
    },
  );
  final sharedList = (shared is Map ? shared['list'] : null) as List? ?? const [];
  say('共享相册(我共享的) 共 ${sharedList.length} 个：');
  for (final a in sharedList) {
    final m = (a as Map).cast<String, dynamic>();
    final info =
        ((m['additional'] as Map?)?['sharing_info'] as Map?)
            ?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    say(
      '  id=${m['id']} name=${m['name']} item_count=${m['item_count']} '
      'shared=${m['shared']} privacy=${info['privacy_type']} '
      'link=${redact('${info['sharing_link']}')} '
      'passphrase=${redact('${info['passphrase']}')}',
    );
  }

  // ④ 与我共享（别一个非空分支：需要别人分享给我们）
  final withMe = await call(
    api,
    'SYNO.Foto.Sharing.Misc',
    'list_shared_with_me_album',
    version: 2,
    params: {
      'offset': '0',
      'limit': '25',
      'sort_by': 'share_modify_time',
      'sort_direction': 'desc',
      'additional': '["sharing_info","thumbnail","access_permission"]',
    },
  );
  final withMeList = withMe is Map ? withMe['list'] : null;
  say('与我共享 共 ${withMeList is List ? withMeList.length : 'n/a'} 个');

  // ⑤ 条件相册（保存闭环的判据）
  final cond = await call(
    api,
    'SYNO.Foto.Browse.ConditionAlbum',
    'list',
    version: 4,
    params: {
      'offset': '0',
      'limit': '50',
      'additional': '["thumbnail","condition_object"]',
    },
  );
  final condList = (cond is Map ? cond['list'] : null) as List? ?? const [];
  say('条件相册 共 ${condList.length} 个：');
  for (final a in condList) {
    final m = (a as Map).cast<String, dynamic>();
    final obj = (m['additional'] as Map?)?['condition_object'];
    say(
      '  id=${m['id']} name=${m['name']} '
      'condition=${jsonEncode(m['condition'])} '
      'condition_object=${jsonEncode(obj)}',
    );
  }

  // ⑥ 条件预览条数（相机 LGE-AN10 = id 23，r402 实测 10 张）
  final peek = await call(
    api,
    'SYNO.Foto.Browse.ConditionAlbum',
    'peek_item_count',
    version: 4,
    params: {
      // 形状逐字取自 r402 探针（真机可用的那一条）：
      // camera id 是**裸数字**、item_type 空数组 —— 发撮串/字符串 id 会 `120 type`。
      'condition': '{"user_id":4,"item_type":[],"camera":[23]}',
    },
  );
  say('peek(camera=23) = ${jsonEncode(peek)}');

  await api.logout();
  say('完成（只读）');
}
