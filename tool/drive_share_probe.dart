// Drive 共享（`Sharing/update`）形状钉子（2026-09-19）——参数从官方 Android 端
// `ApiSynoDriveSharing.setAsUpdate` 逐字抄：
//   path        = `id:<file_id>`
//   permissions = List<Map>，每项
//                 邀请/改权限：{action:'update', member:{type:'user'|'group', name}, role}
//                 移除：      {action:'delete', member:{type:'user'|'group', name}}
// 这里在真机上**双向验证**：邀请本 NAS 的另一个账号 → `Sharing/list` 应能看到 →
// 再移除 → 应该回到空。跑完清场（删文件）。
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

const _name = 'p3-share.txt';

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
  final fs = FileStationApi(api);

  Future<Object?> tryCall(
    String a,
    String m,
    int v, [
    Map<String, dynamic> p = const {},
  ]) async {
    try {
      return await api.call(a, m, preferredVersion: v, params: p);
    } catch (e) {
      return e;
    }
  }

  void show(String label, Object? r) {
    final s = '$r';
    print('   $label → ${s.length > 300 ? '${s.substring(0, 300)}…' : s}');
  }

  Future<Map<String, dynamic>?> findFile(String name, {int tries = 20}) async {
    for (var i = 0; i < tries; i++) {
      final r = await tryCall('SYNO.SynologyDrive.Files', 'list', 3, {
        'path': '/mydrive',
        'offset': '0',
        'limit': '50',
        'sort_by': 'name',
        'sort_direction': 'asc',
      });
      if (r is Map) {
        for (final it in (r['items'] as List?) ?? const []) {
          final m = (it as Map).cast<String, dynamic>();
          if ('${m['name']}' == name) return m;
        }
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return null;
  }

  String? fileId;
  try {
    final tmp = File('${Directory.systemTemp.path}/$_name');
    await tmp.writeAsString('share probe\n');
    await fs.upload(
      folderPath: '/home/Drive',
      filePath: tmp.path,
      fileName: _name,
      conflict: UploadConflictPolicy.overwrite,
    );
    final f = await findFile(_name);
    if (f == null) {
      print('✗ 没索引到');
      return;
    }
    fileId = '${f['file_id']}';
    print('⓪ file_id=$fileId');

    final path = 'id:$fileId';
    // 邀请 demo_user（本 NAS 的普通账号）为 viewer
    for (final v in [1, 2]) {
      show(
        'Sharing/update v$v（邀请 demo_user viewer）',
        await tryCall('SYNO.SynologyDrive.Sharing', 'update', v, {
          'path': path,
          'permissions': jsonEncode([
            {
              'action': 'update',
              'member': {'type': 'user', 'name': 'demo_user'},
              'role': 'viewer',
            },
          ]),
        }),
      );
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    for (final v in [1, 2]) {
      show(
        'Sharing/list v$v（邀请后）',
        await tryCall('SYNO.SynologyDrive.Sharing', 'list', v, {
          'path': path,
          'offset': '0',
          'limit': '20',
        }),
      );
    }
    show(
      'Files/get（shared 字段）',
      await tryCall('SYNO.SynologyDrive.Files', 'get', 3, {'path': path}),
    );

    // 移除
    show(
      'Sharing/update v1（移除 demo_user）',
      await tryCall('SYNO.SynologyDrive.Sharing', 'update', 1, {
        'path': path,
        'permissions': jsonEncode([
          {
            'action': 'delete',
            'member': {'type': 'user', 'name': 'demo_user'},
          },
        ]),
      }),
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    show(
      'Sharing/list v1（移除后）',
      await tryCall('SYNO.SynologyDrive.Sharing', 'list', 1, {
        'path': path,
        'offset': '0',
        'limit': '20',
      }),
    );

    // 顺带：公开链接 + Files/update 改共享？链接用 create_link
    show(
      'Sharing/create_link v1',
      await tryCall('SYNO.SynologyDrive.Sharing', 'create_link', 1, {
        'path': path,
      }),
    );
  } finally {
    if (fileId != null) {
      await tryCall('SYNO.SynologyDrive.Files', 'delete', 2, {
        'files': jsonEncode(['id:$fileId']),
      });
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    try {
      await fs.deleteItems(['/home/Drive/$_name']);
    } catch (_) {}
    final left = await tryCall('SYNO.SynologyDrive.Files', 'list', 3, {
      'path': '/mydrive',
      'offset': '0',
      'limit': '50',
    });
    print('   清场后 /mydrive: ${left is Map ? left['total'] : left}');
    await api.logout();
    exit(0);
  }
}
