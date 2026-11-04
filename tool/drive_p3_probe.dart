//  Drive P3 参数取证：`Labels` / `Revisions` / `Sharing` / `Share.Priv` / `list_labelled`
//  方法表来自 NAS 上 Drive Server 包（`/tmp/spk/export_SynologyDrive/webapi/drive/
//  SYNO.SynologyDrive.lib`，4.2.0-30058）：
//    Labels   v1..3: list list_shared create update update_shared delete delegate …
//    Revisions v1..2: list download restore
//    Sharing  v1..2: list update create_link use_link sync_to_device get_base_url
//    Files    v1..11: … list_labelled …
//  这里只做**读**探测，唯一的写是"建一个探针标签再删掉"（跑完清场）。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  await api.login(
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
    session: 'SynologyDrive',
  );

  Future<Object?> tryCall(
    String a,
    String m,
    int v, [
    Map<String, dynamic> p = const {},
  ]) async {
    try {
      final r = await api.call(a, m, preferredVersion: v, params: p);
      return r;
    } catch (e) {
      return e;
    }
  }

  void show(String label, Object? r) {
    final s = '$r';
    print('   $label → ${s.length > 400 ? '${s.substring(0, 400)}…' : s}');
  }

  // 0) 拿一个 file_id（Drive 里可能为空）
  final list = await tryCall('SYNO.SynologyDrive.Files', 'list', 3, {
    'path': '/mydrive',
    'offset': '0',
    'limit': '20',
    'sort_by': 'name',
    'sort_direction': 'asc',
  });
  String? fileId;
  if (list is Map) {
    final items = (list['items'] as List?) ?? const [];
    print('⓪ /mydrive 条目 ${items.length}');
    for (final it in items.take(3)) {
      print('   - ${(it as Map)['file_id']} ${it['name']} ${it['type']}');
    }
    if (items.isNotEmpty) fileId = '${(items.first as Map)['file_id']}';
  } else {
    print('⓪ 列表失败：$list');
  }

  print('① Labels/list');
  for (final v in [3, 1]) {
    show('v$v {}', await tryCall('SYNO.SynologyDrive.Labels', 'list', v));
  }
  for (final v in [3, 1]) {
    show(
      'v$v {type:label}',
      await tryCall('SYNO.SynologyDrive.Labels', 'list', v, {'type': 'label'}),
    );
  }
  show(
    'v3 {type:shared_label}',
    await tryCall('SYNO.SynologyDrive.Labels', 'list', 3, {
      'type': 'shared_label',
    }),
  );

  print('② Share.Priv/list（共享成员搜索）');
  final priv = {
    'query': 'a',
    'limit': '5',
    'additional': jsonEncode(['nickname']),
    'filter': jsonEncode({'login': false}),
  };
  show(
    'v1 {query,limit,additional,filter}',
    await tryCall('SYNO.SynologyDrive.Share.Priv', 'list', 1, priv),
  );
  show('v1 {}', await tryCall('SYNO.SynologyDrive.Share.Priv', 'list', 1));

  print('③ Sharing/list（共享链接）');
  if (fileId != null) {
    for (final v in [2, 1]) {
      show(
        'v$v {path:id:$fileId}',
        await tryCall('SYNO.SynologyDrive.Sharing', 'list', v, {
          'path': 'id:$fileId',
        }),
      );
    }
    show(
      'v2 {path:/mydrive}',
      await tryCall('SYNO.SynologyDrive.Sharing', 'list', 2, {
        'path': '/mydrive',
      }),
    );
  } else {
    print('   （Drive 里没有文件，跳过）');
  }

  print('④ Revisions/list（版本历史）');
  if (fileId != null) {
    for (final v in [2, 1]) {
      show(
        'v$v {path:id:$fileId}',
        await tryCall('SYNO.SynologyDrive.Revisions', 'list', v, {
          'path': 'id:$fileId',
        }),
      );
    }
    show(
      'v2 {files:[id]}',
      await tryCall('SYNO.SynologyDrive.Revisions', 'list', 2, {
        'files': jsonEncode(['id:$fileId']),
      }),
    );
    show(
      'v2 {path:id, offset,limit}',
      await tryCall('SYNO.SynologyDrive.Revisions', 'list', 2, {
        'path': 'id:$fileId',
        'offset': '0',
        'limit': '30',
      }),
    );
  } else {
    print('   （Drive 里没有文件，跳过）');
  }

  print('⑤ Files/list_labelled（按标签列文件）');
  show(
    'v11 {label_id:1}',
    await tryCall('SYNO.SynologyDrive.Files', 'list_labelled', 11, {
      'label_id': '1',
    }),
  );
  show(
    'v11 {label_id:"1"}',
    await tryCall('SYNO.SynologyDrive.Files', 'list_labelled', 11, {
      'label_id': '"1"',
    }),
  );
  show(
    'v11 {label_id:1,offset,limit}',
    await tryCall('SYNO.SynologyDrive.Files', 'list_labelled', 11, {
      'label_id': '1',
      'offset': '0',
      'limit': '20',
    }),
  );

  print('⑥ Labels/create + delete（探针标签，验完就删）');
  Object? created = await tryCall('SYNO.SynologyDrive.Labels', 'create', 1, {
    'name': '"probe-label"',
  });
  show('create {name}', created);
  if (created is Map && created['id'] != null) {
    show(
      'delete {id}',
      await tryCall('SYNO.SynologyDrive.Labels', 'delete', 1, {
        'id': '${created['id']}',
      }),
    );
  }

  await api.logout();
  exit(0);
}
