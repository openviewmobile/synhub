// Synology Drive（4.2.0-30058）真机探针：能力表 + 列举/缩略图/下载/写操作的形状。
//
// 运行：
//   SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… \
//     dart run tool/drive_probe.dart [probe|seed|clean]
//
// 权威来源分两层：
//   1. NAS 上装的 SynologyDrive SPK —— `webapi/drive/SYNO.SynologyDrive.lib`
//      给出方法/版本（v1–v11；`list_backup_tasks` 从 v3 起），见
//      `docs/api-server-authoritative.md` §5；
//   2. 本探针 —— 把**请求参数名**和**回包形状**在真机上钉死（Drive 与 FileStation
//      的风格不同：回包是 `{items, total}`，路径是 `/mydrive/...`）。
//
// `probe` 会在个人空间根建一个 `drive-probe` 目录（上传 1 图 1 文），跑完
// 把写操作产生的垃圾收掉；`seed` 只建/上传；`clean` 只删。个人空间的磁盘目录
// 就是 `/home/Drive`（可用 FileStation 直接看/放文件）。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

const probeDir = '/mydrive/drive-probe';

Future<DsmWebApi> _login() async {
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
    session: 'FileStation',
  );
  return api;
}

Future<Map<String, dynamic>> dump(
  DsmWebApi api,
  String name,
  String method, {
  Map<String, dynamic> params = const {},
  int? version,
  int cap = 700,
}) async {
  try {
    final data = await api.call(
      name,
      method,
      params: params,
      preferredVersion: version ?? 1,
    );
    final s = jsonEncode(data);
    print(
      '✔ $name/$method ${jsonEncode(params)} → '
      '${s.length > cap ? '${s.substring(0, cap)}…' : s}',
    );
    return data;
  } catch (e) {
    print('✘ $name/$method ${jsonEncode(params)} → $e');
    return const {};
  }
}

/// 只打印一条 item 的键和几个关键值，避免刷屏
void showItems(String label, Map<String, dynamic> data) {
  final items = (data['items'] as List?) ?? const [];
  print('$label：total=${data['total']} items=${items.length}');
  for (final it in items.take(4)) {
    final m = (it as Map).cast<String, dynamic>();
    print('   keys=${m.keys.toList()}');
    print(
      '   name=${m['name']} type=${m['type']} path=${m['path']} '
      'size=${m['filesize'] ?? m['size']} id=${m['file_id']} '
      'mtime=${m['modified_time'] ?? m['time']}',
    );
  }
}

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? 'probe' : args[0];
  final api = await _login();
  final fs = FileStationApi(api);

  if (mode == 'seed' || mode == 'probe') {
    // Drive 的 create 参数是 `type:"folder"`（官方 web 端 `create_files` 同款），
    // 传 `type:"dir"` 会被拒；磁盘目录用 FileStation 建更省事，等价于 /home/Drive。
    await dump(
      api,
      'SYNO.SynologyDrive.Files',
      'create',
      params: {'path': probeDir, 'type': 'folder'},
      version: 2,
    );
    try {
      await fs.createFolder(folderPath: '/home/Drive', name: 'drive-probe');
    } catch (e) {
      print('（FileStation 建目录：$e —— 已存在也算成功）');
    }
    final tmp = Directory.systemTemp.createTempSync('drive-probe');
    // ⚠️ 必须是**合法** PNG：手糊的 base64（CRC/zlib 坏掉）在 Android 的
    //    ImageDecoder 下会 "Could not decompress image"，会被误判成 App 的 bug
    final png = File('${tmp.path}/probe-pic.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAGElEQVR42mNgYGCwsbGpqKjYsmUL'
          'A3EcAIzTEOFhpUK9AAAAAElFTkSuQmCC',
        ),
      );
    final txt = File('${tmp.path}/probe-note.txt')
      ..writeAsStringSync('drive probe ${DateTime.now()}\n' * 20);
    for (final f in [png, txt]) {
      await fs.upload(
        folderPath: '/home/Drive/drive-probe',
        filePath: f.path,
        fileName: f.path.split('/').last,
      );
    }
    // Drive 的索引是守护进程扫的，给它一点时间
    await Future.delayed(const Duration(seconds: 4));
    print('== 已播种 $probeDir ==');
    if (mode == 'seed') {
      await dump(
        api,
        'SYNO.SynologyDrive.Files',
        'list',
        params: {'path': probeDir},
        version: 11,
      );
      api.transport.close();
      exit(0);
    }
  }

  if (mode == 'clean') {
    // 真机事实：delete 收的是 **`files` = JSON 数组字符串**（`["id:…"]`），
    // 传 `path:[…]`/重复字段一律 `114/120`。所以先列出目录拿 file_id。
    final listed = await dump(
      api,
      'SYNO.SynologyDrive.Files',
      'list',
      params: {'path': '/mydrive', 'offset': 0, 'limit': 100},
      version: 11,
    );
    final items = ((listed['items'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .where((e) => e['name'] == 'drive-probe')
        .toList();
    if (items.isEmpty) {
      print('== drive-probe 不存在，无需清理 ==');
    } else {
      final id = 'id:${items.single['file_id']}';
      // 真机实测（2026-09-18，三种参数各跑一遍）：
      //   `{files}`                       → 2 秒内从 /mydrive 消失（进回收站）✔
      //   `{files, permanent:true}`       → 回 async_task_id，但条目**还在**（静默无效）✘
      //   `{files, permanent_delete:true}`→ 2 秒内消失，且不进回收站 ✔✔
      final params = <String, dynamic>{
        'files': jsonEncode([id]),
        if (Platform.environment['SYNO_DELETE_MODE'] != 'trash')
          'permanent_delete': true,
      };
      print('   删除参数：$params');
      await dump(
        api,
        'SYNO.SynologyDrive.Files',
        'delete',
        version: 2,
        params: params,
      );
      // 异步任务：轮询 10 秒看目录什么时候真的消失
      for (var i = 1; i <= 5; i++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final after = await dump(
          api,
          'SYNO.SynologyDrive.Files',
          'list',
          params: {'path': '/mydrive', 'offset': 0, 'limit': 100},
          version: 11,
          cap: 80,
        );
        final still = ((after['items'] as List?) ?? const []).any(
          (e) => (e as Map)['name'] == 'drive-probe',
        );
        print('   → ${i * 2}s：还在？$still');
        if (!still) break;
      }
      await dump(
        api,
        'SYNO.SynologyDrive.Files',
        'list',
        version: 11,
        params: {'path': '/mydrive'},
        cap: 80,
      );
    }
    // 回收站：`Trash/list` 必须带 `path` + offset/limit，且只能用 v1
    // （缺 path 或发 v2 都是 `1000`，很容易误判成"接口坏了"）；
    // 清空用 `Trash/empty {path}` —— 已进回收站的条目**不能**再用
    // `Files/delete` 删（那是对文件树生效的）。
    final trash = await dump(
      api,
      'SYNO.SynologyDrive.Trash',
      'list',
      version: 1,
      params: {'path': '/mydrive', 'offset': 0, 'limit': 100},
      cap: 300,
    );
    final residues = ((trash['items'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .where(
          (e) =>
              '${e['name']}'.startsWith('drive-probe') ||
              '${e['name']}'.startsWith('probe-note'),
        )
        .toList();
    print('== 回收站残留 ${residues.length} 项 ==');
    if (residues.isNotEmpty) {
      await dump(
        api,
        'SYNO.SynologyDrive.Trash',
        'empty',
        version: 1,
        params: {'path': '/mydrive'},
      );
      await Future<void>.delayed(const Duration(seconds: 3));
      final after = await dump(
        api,
        'SYNO.SynologyDrive.Trash',
        'list',
        version: 1,
        params: {'path': '/mydrive', 'offset': 0, 'limit': 100},
        cap: 120,
      );
      print('== 清空后回收站 ${((after['items'] as List?) ?? const []).length} 项 ==');
    }
    await dump(
      api,
      'SYNO.SynologyDrive.Files',
      'list',
      params: {'path': '/mydrive'},
      version: 11,
    );
    api.transport.close();
    exit(0);
  }

  print('== Info / 配额 ==');
  await dump(api, 'SYNO.SynologyDrive.Info', 'get');
  await dump(api, 'SYNO.SynologyDrive.Info', 'quota', version: 2);

  print('== list 的形状 ==');
  final root = await api.call(
    'SYNO.SynologyDrive.Files',
    'list',
    params: {'path': '/mydrive', 'offset': 0, 'limit': 100},
    preferredVersion: 3,
  );
  showItems('根 /mydrive', root);
  final sub = await api.call(
    'SYNO.SynologyDrive.Files',
    'list',
    params: {'path': probeDir, 'offset': 0, 'limit': 100},
    preferredVersion: 3,
  );
  showItems(probeDir, sub);
  final items = ((sub['items'] as List?) ?? const [])
      .map((e) => (e as Map).cast<String, dynamic>())
      .toList();
  final file = items.firstWhere(
    (e) => e['type'] == 'file',
    orElse: () => <String, dynamic>{},
  );
  final dir = items.firstWhere(
    (e) => e['type'] == 'dir',
    orElse: () => <String, dynamic>{},
  );
  final fileId = 'id:${file['file_id']}';
  print('== 完整 item ==');
  print(const JsonEncoder.withIndent('  ').convert(file));

  print('== 排序/过滤参数 ==');
  for (final p in [
    {
      'path': probeDir,
      'offset': 0,
      'limit': 50,
      'sort_by': 'name',
      'sort_direction': 'asc',
    },
    {
      'path': probeDir,
      'offset': 0,
      'limit': 50,
      'sort_by': 'modified_time',
      'sort_direction': 'desc',
    },
    {'path': probeDir, 'offset': 0, 'limit': 50, 'filter': 'file'},
    {'path': probeDir, 'offset': 0, 'limit': 50, 'filter': 'dir'},
    {
      'path': probeDir,
      'offset': 0,
      'limit': 50,
      'field': 'name,size,modified_time',
    },
  ]) {
    try {
      final d = await api.call(
        'SYNO.SynologyDrive.Files',
        'list',
        params: p,
        preferredVersion: 3,
      );
      print(
        '✔ list $p → total=${d['total']} '
        'names=${((d['items'] as List?) ?? const []).map((e) => (e as Map)['name']).toList()}',
      );
    } catch (e) {
      print('✘ list $p → $e');
    }
  }

  print('== get / 缩略图 / 下载（按 file_id 与按路径）==');
  await dump(
    api,
    'SYNO.SynologyDrive.Files',
    'get',
    params: {'path': fileId},
    version: 3,
    cap: 300,
  );
  await dump(
    api,
    'SYNO.SynologyDrive.Files',
    'get',
    params: {'path': '$probeDir/probe-note.txt'},
    version: 3,
    cap: 300,
  );
  await dump(
    api,
    'SYNO.SynologyDrive.Files',
    'get',
    params: {'path': 'id:${dir['file_id']}'},
    version: 3,
    cap: 300,
  );

  for (final size in ['small', 'medium', 'large']) {
    try {
      final d = await api.call(
        'SYNO.SynologyDrive.Files',
        'get_thumbnail',
        params: {'path': 'id:${file['file_id']}', 'size': size},
        preferredVersion: 2,
      );
      print('✔ get_thumbnail $size 原始回包 → ${jsonEncode(d)}');
      for (final variant in [
        {...d.map((k, v) => MapEntry(k, '$v'))},
        {
          'api': 'SYNO.SynologyDrive.Files',
          'method': 'get_thumbnail',
          'version': '2',
          ...d.map((k, v) => MapEntry(k, '$v')),
        },
      ]) {
        try {
          final url = api.authenticatedUrl('entry.cgi', variant);
          final bytes = await api.getBytes(url);
          print(
            '   取字节 OK（${variant.keys.join(',')}）→ ${bytes.length} 字节 '
            'PNG=${bytes.length > 8 && bytes[0] == 0x89}',
          );
        } catch (e) {
          print('   取字节失败（${variant.keys.join(',')}）→ $e');
        }
      }
    } catch (e) {
      print('✘ get_thumbnail $size → $e');
    }
  }

  try {
    final d = await api.call(
      'SYNO.SynologyDrive.Files',
      'download',
      params: {
        'files': '["id:${file['file_id']}"]',
        'force_download': true,
        'is_preview': true,
      },
      preferredVersion: 2,
    );
    print('✔ download 原始回包 → ${jsonEncode(d)}');
    for (final variant in [
      {...d.map((k, v) => MapEntry(k, '$v'))},
      {
        'api': 'SYNO.SynologyDrive.Files',
        'method': 'download',
        'version': '2',
        ...d.map((k, v) => MapEntry(k, '$v')),
      },
    ]) {
      try {
        final url = api.authenticatedUrl('entry.cgi', variant);
        final bytes = await api.getBytes(url);
        print(
          '   取字节 OK（${variant.keys.join(',')}）→ ${bytes.length} 字节 '
          'PNG=${bytes.length > 8 && bytes[0] == 0x89}',
        );
      } catch (e) {
        print('   取字节失败（${variant.keys.join(',')}）→ $e');
      }
    }
  } catch (e) {
    print('✘ download → $e');
  }

  print('== delete / copy 参数矩阵（找出 Drive 要的形态）==');
  for (final p in [
    {
      'path': ['id:${file['file_id']}'],
    },
    {'path': '["id:${file['file_id']}"]'},
    {'files': '["id:${file['file_id']}"]'},
    {'files': 'id:${file['file_id']}'},
    {'path': 'id:${file['file_id']}'},
  ]) {
    await dump(
      api,
      'SYNO.SynologyDrive.Files',
      'delete',
      params: p,
      version: 2,
      cap: 120,
    );
  }

  print('== 搜索 / 星标 / 最近 / 标签 ==');
  await dump(
    api,
    'SYNO.SynologyDrive.Files',
    'search',
    params: {'keyword': 'probe'},
    version: 3,
    cap: 300,
  );
  await dump(
    api,
    'SYNO.SynologyDrive.Files',
    'star',
    params: {
      'files': [fileId],
      'starred': true,
    },
    version: 2,
    cap: 200,
  );
  await dump(
    api,
    'SYNO.SynologyDrive.Files',
    'list_starred',
    params: {'offset': 0, 'limit': 50},
    version: 3,
    cap: 200,
  );
  await dump(
    api,
    'SYNO.SynologyDrive.Files',
    'recent',
    params: {'offset': 0, 'limit': 50},
    version: 3,
    cap: 200,
  );
  await dump(
    api,
    'SYNO.SynologyDrive.Files',
    'list_labelled',
    params: {'offset': 0, 'limit': 50},
    version: 3,
    cap: 200,
  );
  await dump(api, 'SYNO.SynologyDrive.Labels', 'list', cap: 300);

  print('== 写：update(改名) / label / copy / move ==');
  await dump(
    api,
    'SYNO.SynologyDrive.Files',
    'update',
    params: {'path': fileId, 'name': 'probe-note-renamed.txt'},
    version: 2,
    cap: 200,
  );
  await dump(
    api,
    'SYNO.SynologyDrive.Files',
    'label',
    params: {
      'files': [fileId],
      'labels': ['red'],
    },
    version: 1,
    cap: 200,
  );
  await dump(
    api,
    'SYNO.SynologyDrive.Files',
    'copy',
    params: {
      'files': [fileId],
      'to_parent_folder': 'id:${dir['file_id']}',
      'conflict_action': 'autorename',
    },
    version: 2,
    cap: 200,
  );
  await dump(
    api,
    'SYNO.SynologyDrive.Files',
    'move',
    params: {
      'files': [fileId],
      'to_parent_folder': 'id:${dir['file_id']}',
      'conflict_action': 'autorename',
    },
    version: 2,
    cap: 200,
  );

  print('== 版本 / 回收站 / 共享 ==');
  await dump(
    api,
    'SYNO.SynologyDrive.Revisions',
    'list',
    params: {'path': fileId},
    version: 1,
    cap: 300,
  );
  await dump(
    api,
    'SYNO.SynologyDrive.Trash',
    'list',
    params: {'offset': 0, 'limit': 20},
    version: 3,
    cap: 300,
  );
  await dump(api, 'SYNO.SynologyDrive.Sharing', 'list', version: 2, cap: 300);

  if (mode == 'probe') {
    print('== 清理（delete：files + permanent）==');
    await dump(
      api,
      'SYNO.SynologyDrive.Files',
      'delete',
      params: {'files': '["$probeDir"]', 'permanent': true},
      version: 2,
      cap: 200,
    );
    await dump(
      api,
      'SYNO.SynologyDrive.Files',
      'list',
      params: {'path': '/mydrive'},
      version: 3,
      cap: 300,
    );
  }
  api.transport.close();
  exit(0);
}
