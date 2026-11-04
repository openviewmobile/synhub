// Drive P3 落地前的**形状钉子**（2026-09-19）：版本历史 / 共享链接 / 标签
// ——把"请求参数怎么写、回包长什么样"在真机上跑通一遍，UI 与测试照抄这组形状。
//
// 权威来源两层：
//   1. NAS 上 Drive 包的 WebAPI 表（`SYNO.SynologyDrive.lib`，4.2.0-30058）：
//      Revisions v1 = `list download restore`；Sharing v1 = `list update create_link
//      use_link sync_to_device`；Labels v1..3 = `list list_shared create update delete …`；
//      Files/label 走 v2、Files/list_labelled 走 v2。
//   2. 本探针：钉参数编码（`id:<file_id>`、Gson 引号串 `"<id>"`）。
//
// 运行：SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… \
//         dart run tool/drive_p3_impl_probe.dart
// 跑完自动清场（删文件 + 删标签 + 删链接随文件一起走）。
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

const _probeName = 'p3-impl-probe.txt';
const _probeDsmPath = '/home/Drive/$_probeName';

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
    print('   $label → ${s.length > 420 ? '${s.substring(0, 420)}…' : s}');
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
    // 0) 用 FileStation 往 Drive 个人空间的磁盘目录放一个文件（索引 1–5 秒）
    final tmp = File('${Directory.systemTemp.path}/$_probeName');
    await tmp.writeAsString('v1 ${DateTime.now()}\n');
    await fs.upload(
      folderPath: '/home/Drive',
      filePath: tmp.path,
      fileName: _probeName,
      conflict: UploadConflictPolicy.overwrite,
    );
    final first = await findFile(_probeName);
    if (first == null) {
      print('✗ Drive 没索引到 $_probeName（放在 $_probeDsmPath）');
      return;
    }
    fileId = '${first['file_id']}';
    print(
      '⓪ 文件就位 file_id=$fileId dsm_path=${first['dsm_path']} '
      'display_path=${first['display_path']} revisions=${first['revisions']}',
    );

    // 1) 第二个版本：同样的路径再传一次（内容不同）
    await tmp.writeAsString('v2 ${DateTime.now()}\n');
    await fs.upload(
      folderPath: '/home/Drive',
      filePath: tmp.path,
      fileName: _probeName,
      conflict: UploadConflictPolicy.overwrite,
    );
    await Future<void>.delayed(const Duration(seconds: 4));

    // 2) Revisions/list
    for (final v in [1, 2]) {
      final r = await tryCall('SYNO.SynologyDrive.Revisions', 'list', v, {
        'path': 'id:$fileId',
        'offset': '0',
        'limit': '20',
      });
      show('Revisions/list v$v', r);
    }

    final revs = await tryCall('SYNO.SynologyDrive.Revisions', 'list', 1, {
      'path': 'id:$fileId',
      'offset': '0',
      'limit': '20',
    });
    List<dynamic> revItems = const [];
    if (revs is Map) revItems = (revs['items'] as List?) ?? const [];
    print('   版本数 = ${revItems.length}');
    if (revItems.length >= 2) {
      final old = (revItems.last as Map)['version_id'];
      // 3) Revisions/restore：回到最老的版本
      show(
        'Revisions/restore v1',
        await tryCall('SYNO.SynologyDrive.Revisions', 'restore', 1, {
          'path': 'id:$fileId',
          'version_id': '$old',
        }),
      );
      await Future<void>.delayed(const Duration(seconds: 3));
      final revs2 = await tryCall('SYNO.SynologyDrive.Revisions', 'list', 1, {
        'path': 'id:$fileId',
        'offset': '0',
        'limit': '20',
      });
      print(
        '   恢复后版本数 = '
        '${revs2 is Map ? ((revs2['items'] as List?) ?? const []).length : revs2}',
      );
    }

    // 4) Revisions/download 的直链形状（GetBaseURL）
    try {
      final url = api
          .authenticatedUrl(api.apiPath('SYNO.SynologyDrive.Revisions'), {
            'api': 'SYNO.SynologyDrive.Revisions',
            'version': '1',
            'method': 'download',
            'path': 'id:$fileId',
          });
      print(
        '   Revisions/download url → ${url.replaceAll(api.session?.sid ?? '', '<sid>')}',
      );
    } catch (e) {
      print('   Revisions/download url ✗ $e');
    }

    // 5) 共享链接
    show(
      'Sharing/create_link v1',
      await tryCall('SYNO.SynologyDrive.Sharing', 'create_link', 1, {
        'path': 'id:$fileId',
      }),
    );
    for (final v in [1, 2]) {
      show(
        'Sharing/list v$v',
        await tryCall('SYNO.SynologyDrive.Sharing', 'list', v, {
          'path': 'id:$fileId',
          'offset': '0',
          'limit': '20',
        }),
      );
    }

    // 6) 标签：建 → 打 → 按标签列文件 → 改名 → 删除
    final created = await tryCall('SYNO.SynologyDrive.Labels', 'create', 1, {
      'name': '"p3-probe-label"',
    });
    show('Labels/create v1', created);
    if (created is Map && created['label_id'] != null) {
      labelId = '${created['label_id']}';
      show(
        'Files/label v2（打标签）',
        await tryCall('SYNO.SynologyDrive.Files', 'label', 2, {
          'files': jsonEncode(['id:$fileId']),
          'labels': jsonEncode(['$labelId']),
        }),
      );
      show(
        'Files/list_labelled v2',
        await tryCall('SYNO.SynologyDrive.Files', 'list_labelled', 2, {
          'label_id': '"$labelId"',
          'offset': '0',
          'limit': '20',
        }),
      );
      show(
        'Labels/update v1（改名+改色）',
        await tryCall('SYNO.SynologyDrive.Labels', 'update', 1, {
          'label_id': '"$labelId"',
          'name': '"p3-probe-renamed"',
          'color': '"#ff8800"',
        }),
      );
      show(
        'Files/get v3（看 labels 字段）',
        await tryCall('SYNO.SynologyDrive.Files', 'get', 3, {
          'path': 'id:$fileId',
        }),
      );
    }

    // 7) 共享成员候选（Share.Priv/list）
    show(
      'Share.Priv/list v1',
      await tryCall('SYNO.SynologyDrive.Share.Priv', 'list', 1, {
        'query': '',
        'limit': '5',
        'additional': '["nickname"]',
      }),
    );
  } finally {
    // 清场：删标签 → 删文件（链接跟着文件走）
    if (labelId != null) {
      show(
        'Labels/delete v1（清场）',
        await tryCall('SYNO.SynologyDrive.Labels', 'delete', 1, {
          'label_id': '"$labelId"',
        }),
      );
    }
    if (fileId != null) {
      show(
        'Files/delete v2（清场）',
        await tryCall('SYNO.SynologyDrive.Files', 'delete', 2, {
          'files': jsonEncode(['id:$fileId']),
        }),
      );
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    try {
      await fs.deleteItems([_probeDsmPath]);
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
