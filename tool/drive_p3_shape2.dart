// Drive P3 形状钉子 第二轮（2026-09-19）：把 `Revisions/restore`、`Revisions/download`
// 和 `Files/label`（打标签）的**参数编码**试出来。第一轮已知：
//   * `Revisions/list` v1 用 `{path:'id:<id>',offset,limit}` ✔
//   * `Revisions/restore` v1 用 `{path,version_id}` → **114 缺少必需参数**
//   * `Files/label` v2 用 `files:["id:…"] + labels:["2"]` → **1000**
// 官方 Web 客户端（`drive_bundle.js`）的现代调用点用的是**对象数组**：
//   restore: `{to_parent_folder, action:'restore', conflict_action:'version',
//             files:[{path:'id:<id>', version_id}]}`
//   download:`{files:[{path:'id:<id>', version_id}]}`
// 这里把变体都跑一遍，成功的那条写进 `drive_api.dart`。
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

const _name = 'p3-shape2.txt';

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
    print('   $label → ${s.length > 260 ? '${s.substring(0, 260)}…' : s}');
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
  String? labelId;
  try {
    final tmp = File('${Directory.systemTemp.path}/$_name');
    await tmp.writeAsString('v1\n');
    await fs.upload(
      folderPath: '/home/Drive',
      filePath: tmp.path,
      fileName: _name,
      conflict: UploadConflictPolicy.overwrite,
    );
    var f = await findFile(_name);
    if (f == null) {
      print('✗ 没索引到');
      return;
    }
    fileId = '${f['file_id']}';
    await tmp.writeAsString('v2\n');
    await fs.upload(
      folderPath: '/home/Drive',
      filePath: tmp.path,
      fileName: _name,
      conflict: UploadConflictPolicy.overwrite,
    );
    await Future<void>.delayed(const Duration(seconds: 4));
    print('⓪ file_id=$fileId');

    // ---- 1) 打标签的编码变体 ----
    final created = await tryCall('SYNO.SynologyDrive.Labels', 'create', 1, {
      'name': '"p3s2"',
    });
    show('Labels/create', created);
    labelId = created is Map ? '${created['label_id']}' : null;
    print('   label_id=$labelId');

    final variants = <String, Map<String, dynamic>>{
      'F files=[id:..] labels=[{action,label_id}]': {
        'files': '["id:$fileId"]',
        'labels': '[{"action":"add","label_id":$labelId}]',
      },
      'A files=[id:..] labels=["id"]': {
        'files': '["id:$fileId"]',
        'labels': '["$labelId"]',
      },
      'B files=[id:..] labels=["\\"id\\""]': {
        'files': '["id:$fileId"]',
        'labels': '["\\"$labelId\\""]',
      },
      'C files=[{path}] labels=["id"]': {
        'files': '[{"path":"id:$fileId"}]',
        'labels': '["$labelId"]',
      },
      'D files=[{path}] labels=[{"label_id":..}]': {
        'files': '[{"path":"id:$fileId"}]',
        'labels': '[{"label_id":$labelId}]',
      },
      'E files=[{file_id}] labels=["id"]': {
        'files': '[{"file_id":$fileId}]',
        'labels': '["$labelId"]',
      },
    };
    for (final e in variants.entries) {
      final r = await tryCall('SYNO.SynologyDrive.Files', 'label', 2, e.value);
      show('label ${e.key}', r);
      // 查这个标签下有没有文件（成功的变体会让 list_labelled 非空）
      final labelled = await tryCall(
        'SYNO.SynologyDrive.Files',
        'list_labelled',
        2,
        {'label_id': '"$labelId"', 'offset': '0', 'limit': '20'},
      );
      final n = labelled is Map
          ? ((labelled['items'] as List?) ?? const []).length
          : labelled;
      print('      list_labelled → $n');
      if (n is int && n > 0) {
        print('      ✅ 命中的编码：${e.key}');
        break;
      }
    }
    show(
      'Files/get（labels 字段）',
      await tryCall('SYNO.SynologyDrive.Files', 'get', 3, {
        'path': 'id:$fileId',
      }),
    );

    // ---- 2) Revisions/restore + download 的对象数组形态 ----
    final revs = await tryCall('SYNO.SynologyDrive.Revisions', 'list', 1, {
      'path': 'id:$fileId',
      'offset': '0',
      'limit': '20',
    });
    var items = <dynamic>[];
    if (revs is Map) items = (revs['items'] as List?) ?? const [];
    print('   版本数=${items.length}');
    if (items.length >= 2) {
      final oldest = '${(items.last as Map)['version_id']}';
      final newest = '${(items.first as Map)['version_id']}';
      show(
        'restore A files=[{path,version_id}]+conflict_action',
        await tryCall('SYNO.SynologyDrive.Revisions', 'restore', 1, {
          'files': '[{"path":"id:$fileId","version_id":$oldest}]',
          'conflict_action': 'version',
        }),
      );
      await Future<void>.delayed(const Duration(seconds: 3));
      final after = await tryCall('SYNO.SynologyDrive.Revisions', 'list', 1, {
        'path': 'id:$fileId',
        'offset': '0',
        'limit': '20',
      });
      print(
        '   恢复后版本数=${after is Map ? ((after['items'] as List?) ?? const []).length : after}',
      );
      // 直链下载某个版本
      final url = api
          .authenticatedUrl(api.apiPath('SYNO.SynologyDrive.Revisions'), {
            'api': 'SYNO.SynologyDrive.Revisions',
            'version': '1',
            'method': 'download',
            'files': '[{"path":"id:$fileId","version_id":$newest}]',
          });
      print(
        '   download url → ${url.replaceAll(api.session?.sid ?? '', '<sid>')}',
      );
    }
  } finally {
    if (labelId != null) {
      show(
        'Labels/delete（清场）',
        await tryCall('SYNO.SynologyDrive.Labels', 'delete', 1, {
          'label_id': '"$labelId"',
        }),
      );
    }
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
