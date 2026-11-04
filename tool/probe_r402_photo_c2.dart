// r402 相册 C2 子页**只读**探针：把「共享相册 / 搜索照片 / 条件相册 / 相似照片 /
// 相册设置」这几页的**数据来源**逐条打一遍，拿到服务端原文当独立通道判据。
//
// 只读：本探针**只调 `list* / get* / count* / suggest / get_status`**，
// 不含任何 add/set/create/delete/update（仪器㉒：写动词前先钉死"现在连的是谁"）。
//
// ⚠️ 仪器76（本文件第一版踩的坑，务必别重犯）：
// 第一版 `dump()` **声明了 `version` 参数却忘了往 `api.call` 传** ⇒ 全部请求按
// `preferredVersion: 1` 发出 ⇒ 读到一堆**假 `120`（参数无效）/假 `103`（方法不存在）**，
// 差点把"探针自己没发版本"写成产品缺陷。**探针声明的参数必须真的发出去**，
// 且"方法不存在(103)"的读数一律要回看探针有没有把版本带上。
//
// 运行（口令只从环境来，不许落库）：
//   set -a; . ~/.synhub-nas.env; set +a
//   dart run tool/probe_r402_photo_c2.dart
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

/// 每条读数都带上**实际发出的版本**，免得再看不出探针发了什么。
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
      '[r402]$tag len=${s.length} '
      '${s.length > 900 ? '${s.substring(0, 900)}…' : s}',
    );
  } catch (e) {
    print('[r402]$tag ERROR $e');
  }
}

/// **120 oracle**：空参 / 半参调用时，服务端会把"缺哪个参数"点名出来
/// （`raw.error.errors = {name, reason}`）。判"某参数是不是必填"用它，
/// 别靠猜（仪器77：必填参数的"空值"照样可能被判 required）。
Future<void> oracle(
  DsmWebApi api,
  String name,
  String method, {
  int version = 1,
  Map<String, dynamic> params = const {},
}) async {
  try {
    final data = await api.call(
      name,
      method,
      preferredVersion: version,
      params: params,
    );
    print('[r402][oracle $name/$method v$version] ✔ ${jsonEncode(data)}');
  } catch (e) {
    print('[r402][oracle $name/$method v$version] ✘ $e');
    if (e is DsmApiException) {
      print('[r402][oracle $name/$method v$version]   raw=${jsonEncode(e.raw)}');
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
  // 会话名 = App 逐字用的那个（`session_controller.dart:317`）；用别的会 `402 权限被拒`。
  await api.login(
    account: _env('SYNO_NAS_ACCOUNT', 'SYNO_ACCOUNT'),
    password: _env('SYNO_NAS_PASSWORD', 'SYNO_PASSWORD'),
    session: 'Chat',
  );
  print('[r402] 登录成功（会话仅用于本次只读探针）');

  // ① 相册设置页 / 相似照片门控：`Setting.User/get`（App 用 v1）
  await dump(api, 'SYNO.Foto.Setting.User', 'get', version: 1);

  // ② 共享相册（与我共享）：`Sharing.Misc/list_shared_with_me_album`（App 用 v2/v1）
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
  );
  // ②b 我共享出去的：`Browse.Album/list` + `category=shared`（App 用 v4）。
  //     真机读数：**缺 `sort_by`/`sort_direction` 会被判 `120`** ⇒ 三个参数要一起给。
  await dump(
    api,
    'SYNO.Foto.Browse.Album',
    'list',
    version: 4,
    params: {
      'offset': '0',
      'limit': '25',
      'category': 'shared',
      'sort_by': 'share_modify_time',
      'sort_direction': 'desc',
      'additional': '["sharing_info","thumbnail"]',
    },
  );
  // ②c 可共享的用户/群组（邀请成员表，App 用 v1）
  await dump(
    api,
    'SYNO.Foto.Sharing.Misc',
    'list_user_group',
    version: 1,
    params: {'team_space_sharable_list': 'false'},
  );

  // ③ 搜索照片：筛选项 + 计数 + 结果（App 用 v4 / v7）
  await dump(api, 'SYNO.Foto.Search.Filter', 'list', version: 4);
  await dump(
    api,
    'SYNO.Foto.Search.Search',
    'count_item',
    version: 7,
    params: {'keyword': 'IMG'},
  );
  await dump(
    api,
    'SYNO.Foto.Search.Search',
    'list_item',
    version: 7,
    params: {
      'offset': '0',
      'limit': '100',
      'keyword': 'IMG',
      'additional':
          '["thumbnail","resolution","orientation","video_convert",'
              '"video_meta","address","favorite"]',
    },
  );

  // ④ 条件相册：列表（App 用 v4）
  await dump(
    api,
    'SYNO.Foto.Browse.ConditionAlbum',
    'list',
    version: 4,
    params: {'offset': '0', 'limit': '100'},
  );

  // ④b 条件相册选值（`suggest`）——**DA49/DA50 的原始读数**
  //
  // 120 oracle：空参调用会把"缺哪个参数"点名出来（`raw.errors.name`）。
  await oracle(api, 'SYNO.Foto.Browse.ConditionAlbum', 'suggest', version: 4);
  await oracle(
    api,
    'SYNO.Foto.Browse.ConditionAlbum',
    'suggest',
    version: 4,
    params: {'user_id': '4'},
  );
  // 空串同样被判 required；`%` 是服务端 LIKE 通配（返回全部值）
  for (final kw in ['', '%', 'LGE']) {
    await dump(
      api,
      'SYNO.Foto.Browse.ConditionAlbum',
      'suggest',
      version: 4,
      params: {
        'user_id': '4',
        'keyword': kw,
        'condition': '["camera"]',
        'additional': '["thumbnail"]',
      },
      label: 'keyword="${kw.isEmpty ? '<空串>' : kw}"',
    );
  }
  // 条件预览条数（`peek_item_count`，只读）——App 真机点"预览"时的同一条条件
  await dump(
    api,
    'SYNO.Foto.Browse.ConditionAlbum',
    'peek_item_count',
    version: 4,
    params: {
      'condition': '{"user_id":4,"item_type":[],"camera":[23]}',
    },
  );

  // ⑤ 相似照片：状态（App 用 v1）
  await dump(api, 'SYNO.Foto.Browse.Similar', 'get_status', version: 1);

  // ⑥ 相册设置页的数据源（App 用 v2 / v2 / v3）
  await dump(api, 'SYNO.Foto.Download', 'get_cache_status', version: 2);
  await dump(api, 'SYNO.Foto.Download', 'calculate_cache_size', version: 2);
  await dump(
    api,
    'SYNO.Foto.Browse.Album',
    'get_album_list_display',
    version: 3,
  );
  print('[r402] 完成（只读）');
}
