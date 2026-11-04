// ignore_for_file: avoid_print
//
// FileStation 真机探针：把 P0 用到的接口在真 NAS 上跑一遍，打印**原始响应**。
//
// 用法（凭据只从环境变量读，不写进仓库）：
//   SYNO_NAS_URL=https://nas.example.com:5001 \
//   SYNO_ACCOUNT=demo_user SYNO_PASSWORD=... \
//   dart run tool/flt_file_probe.dart
//
// 关注三件事：
//   1. 这台服务器**实际**有哪些 SYNO.FileStation.* 及其版本区间（权威表来源）；
//   2. `list_share` / `list` 的原始 JSON（校验 DTO 的字段路径，尤其是 additional）；
//   3. 普通用户（非管理员）对每个接口的真实返回码（401/403/无权限）。
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final url = Platform.environment['SYNO_NAS_URL'];
  final account = Platform.environment['SYNO_ACCOUNT'];
  final password = Platform.environment['SYNO_PASSWORD'];
  if (url == null || account == null || password == null) {
    print('需要 SYNO_NAS_URL / SYNO_ACCOUNT / SYNO_PASSWORD');
    exit(2);
  }

  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );

  final table = await api.discover();
  print('=== SYNO.FileStation.* 能力表（这台服务器的真实版本）');
  for (final k in table.keys.where((k) => k.startsWith('SYNO.FileStation'))) {
    final e = table[k]!;
    print('  $k  v${e.minVersion}..${e.maxVersion}  ${e.path}');
  }
  for (final k in table.keys.where(
    (k) =>
        k.startsWith('SYNO.Office') ||
        k.startsWith('SYNO.SynologyDrive') ||
        k.startsWith('SYNO.NoteStation') ||
        k.startsWith('SYNO.Foto'),
  )) {
    final e = table[k]!;
    print('  [跨模块] $k  v${e.minVersion}..${e.maxVersion}  ${e.path}');
  }

  final session = await api.login(
    account: account,
    password: password,
    session: 'FileStation',
    deviceName: 'flt-file-probe',
  );
  print('=== 登录成功 sid=${session.sid.substring(0, 4)}…');

  final fs = FileStationApi(api);
  await _section('Info.get', () async {
    print(
      jsonEncode(
        await api.call(
          'SYNO.FileStation.Info',
          'get',
          preferredVersion: fs.negotiate('SYNO.FileStation.Info', const [2, 1]),
        ),
      ),
    );
  });

  await _section('List.list_share（根目录）', () async {
    final result = await fs.listShares(limit: 100);
    print(
      'total=${result.total} offset=${result.offset} '
      'hasMore=${result.hasMore} entries=${result.entries.length}',
    );
    for (final e in result.entries.take(10)) {
      print(
        '  ${e.isDir ? "D" : "F"} ${e.path}  name=${e.name} '
        'mount=${e.mountPointType} owner=${e.owner} canWrite=${e.canWrite}',
      );
    }
    return result.entries.firstOrNull?.path;
  }).then((first) async {
    if (first == null) return;
    await _section('List.list($first) 带 additional', () async {
      final result = await fs.listFolder(
        folderPath: first,
        limit: 20,
        additional: FileAdditional.browse,
      );
      print('total=${result.total} entries=${result.entries.length}');
      for (final e in result.entries.take(8)) {
        print(
          '  ${e.isDir ? "D" : "F"} ${e.name} size=${e.size} '
          'mtime=${e.mtime} (${e.modifiedAt}) owner=${e.owner} '
          'rwx=${e.canRead}${e.canWrite}${e.canExecute} '
          'real=${e.realPath} worm=${e.isWormShare}',
        );
      }
    });
    await _section('CheckPermission.write', () async {
      print(await fs.checkWritePermission(first, filename: 'flt-probe.tmp'));
    });
    await _section('VirtualFolder.list', () async {
      final r = await fs.listVirtualFolders();
      print('${r.entries.length} 个虚拟目录');
    });
    await _section('Favorite.list', () async {
      final r = await fs.listFavorites();
      print('${r.entries.length} 个收藏');
    });
    await _section('BackgroundTask.list', () async {
      final r = await fs.listBackgroundTasks();
      print(
        '${r.tasks.length} 个任务 '
        '${r.tasks.map((t) => "${t.label}/${t.finished}").take(5).toList()}',
      );
    });
    await _section('List.list_share 带 JSON additional', () async {
      final r = await fs.listShares(limit: 5);
      for (final e in r.entries.take(3)) {
        print(
          '  ${e.name} size=${e.size} mtime=${e.mtime} owner=${e.owner} '
          'rwx=${e.canRead}${e.canWrite}${e.canExecute} real=${e.realPath}',
        );
      }
    });
    await _section('Sharing.list', () async {
      final r = await api.call(
        'SYNO.FileStation.Sharing',
        'list',
        preferredVersion: fs.negotiate('SYNO.FileStation.Sharing', const [
          3,
          2,
          1,
        ]),
        params: {'offset': 0, 'limit': 50},
      );
      final text = jsonEncode(r);
      print(text.length > 600 ? '${text.substring(0, 600)}…' : text);
    });
    await _section('List.getinfo', () async {
      final r = await fs.getInfo(first);
      print(
        'getinfo：name=${r.name} size=${r.size} owner=${r.owner} '
        'mtime=${r.mtime} real=${r.realPath}',
      );
    });
    await _section('Search.start/stop', () async {
      final start = await fs.startSearch(folderPath: first, pattern: 'a');
      print('task=${start.taskId}');
      await Future<void>.delayed(const Duration(seconds: 1));
      final res = await fs.searchResults(taskId: start.taskId, limit: 20);
      print('结果 ${res.entries.length} / total=${res.total}');
      await fs.stopSearch(start.taskId);
      await fs.cleanSearch(start.taskId);
    });
  });

  // 普通用户碰管理接口会怎样？（只为看错误码，不做任何修改）
  await _section('管理员接口（预期失败）', () async {
    for (final name in const [
      'SYNO.FileStation.SharingCustom',
      'SYNO.FileStation.VFS.User',
    ]) {
      if (!table.containsKey(name)) {
        print('  $name 不在这台服务器的能力表里');
        continue;
      }
      try {
        await api.call(name, 'list', preferredVersion: 1);
        print('  $name 竟然成功了（说明 demo_user 有管理员权限）');
      } catch (e) {
        print('  $name → $e');
      }
    }
  });

  api.transport.close();
  exit(0);
}

Future<T?> _section<T>(String title, Future<T> Function() body) async {
  print('--- $title');
  try {
    final v = await body();
    return v;
  } catch (e) {
    print('    !! $e');
    return null;
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
