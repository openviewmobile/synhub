// r417 相册残留**只读**探针：给 ④ 最后两条写动词闭环钉死"现在连的是谁"，
// 并把两条残留能不能做、为什么，用服务端原文说清楚（仪器㉒：写动词前先定身份；
// "读到什么"优先于推断）。
//
// 只读：本探针只调 `list*/get*/me`，**不含任何 add/set/create/delete/update**。
//
// 要回答的三个问题：
//   ① 会话身份是谁？（`Core.User/list` 能不能读 → 决定"另一个用户"可不可得）
//   ② 共享相册**非空分支**：`list_user_group`（可邀请成员）到底有没有人？
//      `Browse.Album/list category=shared`（我共享出去的）现在是什么？
//   ③ 条件相册**保存闭环**的前置：`Browse.ConditionAlbum/list` 现在是什么？
//
// 运行（口令只从环境来，不许落库）：
//   set -a; . ~/.synhub-nas.env; set +a
//   dart run tool/probe_r417_photo_share.dart
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

Future<void> dump(
  DsmWebApi api,
  String name,
  String method, {
  Map<String, dynamic> params = const {},
  int version = 1,
  String label = '',
}) async {
  final tag = '[$name/$method v$version${label.isEmpty ? '' : ' $label'}]';
  try {
    final data = await api.call(
      name,
      method,
      preferredVersion: version,
      params: params,
    );
    final s = jsonEncode(data);
    print(
      '[r417]$tag len=${s.length} '
      '${s.length > 1200 ? '${s.substring(0, 1200)}…' : s}',
    );
  } catch (e) {
    print('[r417]$tag ERROR $e');
    if (e is DsmApiException) {
      print('[r417]$tag   raw=${jsonEncode(e.raw)}');
    }
  }
}

Future<void> main() async {
  final api = DsmWebApi(
    DirectTransport.url(
      _env('SYNO_NAS_URL', 'SYNO_URL'),
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  // 会话名 = App 逐字用的那个（`session_controller.dart:317`）。
  await api.login(
    account: _env('SYNO_NAS_ACCOUNT', 'SYNO_ACCOUNT'),
    password: _env('SYNO_NAS_PASSWORD', 'SYNO_PASSWORD'),
    session: 'Chat',
  );
  print('[r417] 登录成功（账号=${_env('SYNO_NAS_ACCOUNT', 'SYNO_ACCOUNT')}，只读探针）');

  // ① 身份：相册侧"我是谁"。v1（App 逐字用的版本）。
  await dump(api, 'SYNO.Foto.UserInfo', 'me', version: 1, label: 'identity');
  // ①b 同接口 v1 的 `get`（带 user_id 才能看别人；先空参看回什么）。
  await dump(api, 'SYNO.Foto.UserInfo', 'get', version: 1, label: 'no-arg');

  // ② NAS 用户表（只读）。普通用户很可能 105/407 ⇒ 这本身就是身份证据。
  await dump(api, 'SYNO.Core.User', 'list', version: 1, label: 'users-v1');
  await dump(api, 'SYNO.Core.User', 'list', version: 2, label: 'users-v2');

  // ③ 可邀请成员（决定"共享相册非空分支"可不可得）。
  await dump(
    api,
    'SYNO.Foto.Sharing.Misc',
    'list_user_group',
    version: 1,
    label: 'sharable-members',
  );

  // ④ 共享相册：与我共享（v2）/ 我共享出去的（category=shared, v4）。
  await dump(
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
    label: 'shared-with-me',
  );
  await dump(
    api,
    'SYNO.Foto.Browse.Album',
    'list',
    version: 4,
    params: {
      'offset': '0',
      'limit': '50',
      'sort_by': 'share_modify_time',
      'sort_direction': 'desc',
      'category': 'shared',
      'additional': '["sharing_info","thumbnail"]',
    },
    label: 'shared-by-me',
  );
  // ④b 全部相册（看 share_status/sharing_info 的真实取值分布）。
  await dump(
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
      'additional': '["sharing_info","thumbnail","access_permission"]',
    },
    label: 'all',
  );

  // ⑤ 条件相册现状（保存闭环的"改前"基线）。
  await dump(
    api,
    'SYNO.Foto.Browse.ConditionAlbum',
    'list',
    version: 4,
    params: {
      'offset': '0',
      'limit': '50',
      'additional': '["thumbnail","condition_object"]',
    },
    label: 'condition-albums',
  );

  // ⑥ 相册共享设置页的数据源（成员/外链现状）。
  await dump(
    api,
    'SYNO.Foto.Browse.NormalAlbum',
    'list',
    version: 4,
    params: {
      'offset': '0',
      'limit': '50',
      'sort_by': 'album_name',
      'sort_direction': 'asc',
      'additional': '["sharing_info","thumbnail"]',
    },
    label: 'normal-albums',
  );

  print('[r417] 完成（只读；未调用任何变更动词）');
  await api.logout();
}
