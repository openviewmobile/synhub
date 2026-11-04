// ignore_for_file: avoid_print
//
// NoteStation 真机探针：把每个方法的**请求形态**和**响应形状**都打出来。
//
//   SYNO_NAS_URL=… SYNO_NAS_ACCOUNT=… SYNO_NAS_PASSWORD=… dart run tool/note_probe.dart
//
// 参数形态来自反编译的 DS note（`com/synology/dsnote/net/ApiNS*.java` +
// `callables/operations/*` + `callables/SyncPullCallable.java`）：Synology 的
// 这些接口用 **Gson 二次编码** —— 字符串要带引号、对象/数组要整体当一个 JSON 串传。
// 真服务端会告诉我们猜错的地方（错误码原样打印）。
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

late DsmWebApi api;

Future<void> tryCall(
  String name,
  String method, {
  int? version,
  Map<String, dynamic> params = const {},
  bool dump = true,
}) async {
  final v = version ?? 1;
  stdout.write(
    '== $name/$method v$v ${params.isEmpty ? "" : jsonEncode(params)}',
  );
  try {
    final data = await api.call(
      name,
      method,
      preferredVersion: v,
      params: params,
    );
    print(' → OK');
    if (dump) {
      final text = const JsonEncoder.withIndent('  ').convert(data);
      print(text.length > 3000 ? '${text.substring(0, 3000)}\n…(截断)' : text);
    }
  } catch (e) {
    print(' → 失败：$e');
  }
}

void main() async {
  api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  await api.login(
    account: Platform.environment['SYNO_NAS_ACCOUNT']!,
    password: Platform.environment['SYNO_NAS_PASSWORD']!,
    session: 'Chat',
  );
  print('登录 OK；NoteStation 相关 API：');
  for (final e in (api.apiTable ?? {}).entries) {
    if (e.key.contains('NoteStation')) {
      print(
        '  ${e.key.padRight(40)} v${e.value.minVersion}-${e.value.maxVersion}',
      );
    }
  }

  // ① 信息 / 设置
  await tryCall('SYNO.NoteStation.Info', 'get', version: 3);
  await tryCall('SYNO.NoteStation.Setting', 'get', version: 2);

  // ② 笔记本列表：filter={"archive":false}（v2）
  await tryCall(
    'SYNO.NoteStation.Notebook',
    'list',
    version: 2,
    params: {
      'filter': jsonEncode({'archive': false}),
    },
  );

  // ③ 笔记列表：field 三个开关（版本 1）
  await tryCall(
    'SYNO.NoteStation.Note',
    'list',
    version: 1,
    params: {
      'field': jsonEncode({
        'old_parent_id': true,
        'individual_joined': true,
        'individual_shared': true,
      }),
    },
  );

  // ④ 带 offset/limit/sort 的列表（官方 App 的界面列表形态）
  await tryCall(
    'SYNO.NoteStation.Note',
    'list',
    version: 4,
    params: {
      'offset': 0,
      'limit': 20,
      'sort_by': 'mtime',
      'sort_direction': 'desc',
      'field': jsonEncode({
        'old_parent_id': true,
        'individual_joined': true,
        'individual_shared': true,
      }),
    },
    dump: false,
  );

  // ⑤ 标签 / 待办 / 共享
  await tryCall('SYNO.NoteStation.Tag', 'list', version: 2, dump: false);
  await tryCall('SYNO.NoteStation.Todo', 'list', version: 2, dump: false);
  await tryCall('SYNO.NoteStation.Share.Priv', 'list', version: 2, dump: false);
  await tryCall('SYNO.NoteStation.Smart', 'list', version: 1, dump: false);

  // ⑥ 取一条真实笔记：先列出 id 再 get
  try {
    final list = await api.call(
      'SYNO.NoteStation.Note',
      'list',
      preferredVersion: 1,
      params: {
        'field': jsonEncode({
          'old_parent_id': true,
          'individual_joined': true,
          'individual_shared': true,
        }),
      },
    );
    final notes = (list['notes'] as List?) ?? const [];
    print('\n笔记 ${notes.length} 条，取第一条看 get：');
    if (notes.isNotEmpty) {
      final first = Map<String, dynamic>.from(notes.first as Map);
      print('  列表条目字段：${first.keys.join(', ')}');
      final id = '${first['object_id']}';
      print('  title=${jsonEncode(first['title'])} object_id=$id');
      await tryCall(
        'SYNO.NoteStation.Note',
        'get',
        version: 1,
        params: {
          'object_id': jsonEncode(id),
          'field': jsonEncode({'individual_shared': true}),
        },
      );
      await tryCall(
        'SYNO.NoteStation.Note.AppLink',
        'list',
        version: 2,
        params: {'object_id': jsonEncode(id)},
        dump: false,
      );
      await tryCall(
        'SYNO.NoteStation.Note.Version',
        'list',
        version: 2,
        params: {'object_id': jsonEncode(id)},
        dump: false,
      );
    }
  } catch (e) {
    print('列表/取笔记失败：$e');
  }

  await api.logout();
  exit(0);
}
