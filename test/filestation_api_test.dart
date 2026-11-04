// FileStationApi 的离线验证。
//
// 断言分两类：
//   1. **协议形状**：请求里的 `api`/`method`/`version`/参数名必须与服务端权威表
//      （docs/api-server-authoritative.md §2，FileStation 1.5.1-2410）以及官方
//      DSfile 4.17.2-609 的调用点一致；
//   2. **解析**：`additional` 是"按需下发"的，缺字段时不能崩。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

/// 记录请求并回放预设响应的假传输（与 test/chat_api_test.dart 同一套写法）。
class FakeFsTransport extends WebApiTransport {
  FakeFsTransport({Map<String, Map<String, dynamic>>? table})
    : apiTable = table ?? defaultTable;

  final Map<String, Map<String, dynamic>> apiTable;

  /// 每次请求的完整参数
  final List<Map<String, dynamic>> calls = [];

  /// (api.method) → 响应 data
  final Map<String, Map<String, dynamic>> responses = {};

  /// (api.method) → 让这次调用返回 `success:false` 的错误码
  final Map<String, int> failures = {};

  /// 记录 multipart 上传
  final List<Map<String, dynamic>> uploads = [];

  static const defaultTable = {
    'SYNO.FileStation.List': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 2,
    },
    'SYNO.FileStation.Upload': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 3,
    },
    'SYNO.FileStation.Download': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 2,
    },
    'SYNO.FileStation.Thumb': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 3,
    },
    'SYNO.FileStation.Delete': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 2,
    },
    'SYNO.FileStation.Rename': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 2,
    },
    'SYNO.FileStation.CreateFolder': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 2,
    },
    'SYNO.FileStation.CopyMove': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 3,
    },
    'SYNO.FileStation.Compress': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 3,
    },
    'SYNO.FileStation.Extract': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 2,
    },
    'SYNO.FileStation.DirSize': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 2,
    },
    'SYNO.FileStation.CheckPermission': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 3,
    },
    'SYNO.FileStation.CheckExist': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 2,
    },
    'SYNO.FileStation.BackgroundTask': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 3,
    },
    'SYNO.FileStation.MD5': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 2,
    },
    'SYNO.FileStation.Property.CompressSize': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
    'SYNO.FileStation.Property.Mtime': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
    'SYNO.FileStation.Property.ACLOwner': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
    'SYNO.FileStation.Search': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 2,
    },
    'SYNO.FileStation.Search.History': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
    'SYNO.FileStation.Favorite': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 2,
    },
    'SYNO.FileStation.VirtualFolder': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 2,
    },
    'SYNO.FileStation.Sharing': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 3,
    },
    'SYNO.FileStation.Sharing.Download': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
    'SYNO.FileStation.Info': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 2,
    },
    // 清空回收站（P0-a）：admin-only，注册表里是 v1 start
    'SYNO.Core.RecycleBin': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
  };

  Map<String, dynamic> get lastCall => calls.last;

  @override
  String get describeKind => 'fake-fs';

  @override
  String get baseUrl => 'https://nas.example.com:5001/';

  @override
  Future<String> describe({String? module}) async =>
      jsonEncode({'success': true, 'data': apiTable});

  @override
  Future<String> postForm(
    String path,
    Map<String, dynamic> params, {
    String? module,
  }) async {
    calls.add({...params});
    final key = '${params['api']}.${params['method']}';
    final code = failures[key];
    if (code != null) {
      return jsonEncode({
        'success': false,
        'error': {'code': code},
      });
    }
    return jsonEncode({'success': true, 'data': responses[key] ?? const {}});
  }

  @override
  Future<String> postMultipart(
    String path, {
    required Map<String, dynamic> query,
    required Map<String, String> fields,
    String? fileField,
    String? filePath,
    String? fileName,
    String? mimeType,
    String? module,
    List<MultipartUploadFile>? files,
    void Function(int sent, int total)? onProgress,
    Map<String, String>? headers,
  }) async {
    uploads.add({
      'path': path,
      'query': {...query},
      'fields': {...fields},
      'fileField': fileField,
      'filePath': filePath,
      'fileName': fileName,
      'mimeType': mimeType,
    });
    return jsonEncode({
      'success': true,
      'data': {'id': 'fs-file-1'},
    });
  }

  @override
  Future<void> close() async {}

  @override
  String authenticatedUrl(
    String path,
    Map<String, String> params, {
    String? sid,
  }) =>
      'https://nas.example.com:5001/webapi/$path?'
      '${params.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&')}'
      '${sid == null ? '' : '&_sid=$sid'}';
}

/// 造一个已 `discover()` 的 [FileStationApi]（不登录：测试只关心协议形状）
Future<({FileStationApi fs, FakeFsTransport t})> makeApi({
  Map<String, Map<String, dynamic>>? table,
}) async {
  final t = FakeFsTransport(table: table);
  final web = DsmWebApi(t);
  await web.discover();
  return (fs: FileStationApi(web), t: t);
}

/// 造一个有内容的临时文件（`upload` 会读它的字节数填 `size`）
File _tmpFile(String name, int bytes) {
  final dir = Directory.systemTemp.createTempSync('flt-upload');
  final f = File('${dir.path}/$name')
    ..writeAsBytesSync(List<int>.filled(bytes, 7));
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  return f;
}

void main() {
  group('版本协商（按方法，不按 maxVersion）', () {
    test('List 在 maxVersion=2 的服务器上用 v2', () async {
      final (:fs, :t) = await makeApi();
      await fs.listFolder(folderPath: '/home');
      expect(t.lastCall['version'], '2');
    });

    test('List 在只有 v1 的老服务器上退到 v1', () async {
      final table = Map<String, Map<String, dynamic>>.from(
        FakeFsTransport.defaultTable,
      );
      table['SYNO.FileStation.List'] = {
        'path': 'entry.cgi',
        'minVersion': 1,
        'maxVersion': 1,
      };
      final (:fs, :t) = await makeApi(table: table);
      await fs.listFolder(folderPath: '/home');
      expect(t.lastCall['version'], '1');
    });

    test('Sharing 在 v3 服务器上用 v3；v1 服务器上退到 v1（list_share_me 不可用）', () async {
      final (:fs, :t) = await makeApi();
      await fs.listShareLinks();
      expect(t.lastCall['version'], '3');

      final table = Map<String, Map<String, dynamic>>.from(
        FakeFsTransport.defaultTable,
      );
      table['SYNO.FileStation.Sharing'] = {
        'path': 'entry.cgi',
        'minVersion': 1,
        'maxVersion': 1,
      };
      final second = await makeApi(table: table);
      await second.fs.listShareLinks();
      expect(second.t.lastCall['version'], '1');
    });

    test('Upload 走 v3（权威表 v2/v3 都只有 upload）', () async {
      final (:fs, :t) = await makeApi();
      await fs.upload(
        folderPath: '/home',
        filePath: _tmpFile('a.txt', 16).path,
        fileName: 'a.txt',
      );
      expect((t.uploads.single['fields'] as Map)['version'], '3');
    });

    test('supports/hasApi 直接读 API 表', () async {
      final (:fs, :t) = await makeApi();
      expect(fs.supports('SYNO.FileStation.List', 2), isTrue);
      expect(fs.supports('SYNO.FileStation.List', 3), isFalse);
      expect(fs.hasApi('SYNO.FileStation.SharingCustom'), isFalse);
      // 表为空（还没 discover）时按"未知"处理
      final blank = FileStationApi(DsmWebApi(FakeFsTransport(table: const {})));
      expect(blank.hasApi('SYNO.FileStation.List'), isTrue);
      expect(t.apiTable, isNotEmpty);
    });
  });

  group('List / list_share', () {
    test('listFolder 的参数与 official 调用点一致', () async {
      final (:fs, :t) = await makeApi();
      await fs.listFolder(
        folderPath: '/home/Drive',
        offset: 20,
        limit: 50,
        sortBy: FileSortBy.mtime,
        sortDirection: FileSortDirection.desc,
      );
      final c = t.lastCall;
      expect(c['api'], 'SYNO.FileStation.List');
      expect(c['method'], 'list');
      expect(c['folder_path'], '/home/Drive');
      expect(c['offset'], 20);
      expect(c['limit'], 50);
      expect(c['sort_by'], 'mtime');
      expect(c['sort_direction'], 'desc');
      expect(c['filetype'], 'all');
      // 这里钉的是**我们的发送形态**：`additional` 发 JSON 字符串（官方 JS 也这么发）。
      // ⚠️ 不是"服务端只接受 JSON 串"：写入批次真机在同一接口上发**裸值也回 0**
      //（`docs/live-write-verification.md` §4#1/#2，服务端宽容）。
      expect(c['additional'], isA<String>());
      final additional = jsonDecode(c['additional'] as String) as List;
      expect(additional, contains(FileAdditional.size));
      expect(additional, contains(FileAdditional.perm));
      expect(additional, contains(FileAdditional.wormShare));
    });

    test('listFolder 能解析 additional 里的嵌套字段', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.List.list'] = {
        'total': 2,
        'offset': 0,
        'files': [
          {
            'name': 'Photos',
            'path': '/home/Photos',
            'isdir': true,
            'additional': {
              'size': 0,
              'real_path': '/volume1/homes/demo_user/Photos',
              'mount_point_type': 'shared_folder',
              'worm_share': false,
              'is_worm_share': false,
              'owner': {
                'user': 'demo_user',
                'group': 'users',
                'uid': 1024,
                'gid': 100,
              },
              'time': {'mtime': 1758100000, 'crtime': 1758000000},
              'perm': {
                'posix': 755,
                'acl': {
                  'read': true,
                  'write': true,
                  'exec': true,
                  'append': true,
                },
                'adv_right': {'disable_download': false},
              },
            },
          },
          {
            'name': 'report.pdf',
            'path': '/home/report.pdf',
            'isdir': false,
            'additional': {
              'size': 2048,
              'owner': {'user': 'demo_user'},
              'time': {'mtime': 1758200000},
              'perm': {
                'acl': {'read': true, 'write': false},
                'adv_right': {'disable_download': true},
              },
            },
          },
        ],
      };

      final result = await fs.listFolder(folderPath: '/home');
      expect(result.total, 2);
      expect(result.entries, hasLength(2));
      expect(result.hasMore, isFalse);

      final dir = result.entries.first;
      expect(dir.name, 'Photos');
      expect(dir.isDir, isTrue);
      expect(dir.owner, 'demo_user');
      expect(dir.group, 'users');
      expect(dir.uid, 1024);
      expect(dir.mtime, 1758100000);
      expect(dir.realPath, '/volume1/homes/demo_user/Photos');
      expect(dir.mountPointType, 'shared_folder');
      expect(dir.isMountPoint, isTrue);
      expect(dir.canWrite, isTrue);
      expect(dir.disableDownload, isFalse);
      expect(dir.modifiedAt, isNotNull);

      final file = result.entries.last;
      expect(file.isDir, isFalse);
      expect(file.extension, 'pdf');
      expect(file.showsThumbnail, isFalse);
      expect(file.humanSize, '2.0 KB');
      expect(file.canWrite, isFalse);
      expect(file.disableDownload, isTrue);
    });

    test('additional 缺失时不崩（服务端按需下发）', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.List.list'] = {
        'total': 1,
        'offset': 0,
        'files': [
          {'name': 'a', 'path': '/a', 'isdir': false},
        ],
      };
      final r = await fs.listFolder(folderPath: '/');
      expect(r.entries.single.name, 'a');
      expect(r.entries.single.size, 0);
      expect(r.entries.single.owner, isNull);
      expect(r.entries.single.canWrite, isFalse);
    });

    test('listShares 用 onlywrite + perm/worm_share，并解析 shares', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.List.list_share'] = {
        'total': 2,
        'offset': 0,
        'shares': [
          {'name': 'docker', 'path': '/docker', 'isdir': true},
          {'name': 'home', 'path': '/home', 'isdir': true},
        ],
      };
      final r = await fs.listShares(onlyWrite: true, limit: 0);
      final c = t.lastCall;
      expect(c['method'], 'list_share');
      expect(c['onlywrite'], true);
      expect(jsonDecode(c['additional'] as String), [
        FileAdditional.perm,
        FileAdditional.wormShare,
      ]);
      expect(r.entries.map((e) => e.name), ['docker', 'home']);
    });

    test('getInfo 取 files[0]，空时用路径兜底', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.List.getinfo'] = {
        'files': [
          {'name': 'x.txt', 'path': '/home/x.txt', 'isdir': false},
        ],
      };
      final one = await fs.getInfo('/home/x.txt');
      expect(one.name, 'x.txt');
      expect(t.lastCall['method'], 'getinfo');
      final additional = jsonDecode(t.lastCall['additional'] as String) as List;
      expect(additional, contains(FileAdditional.size));
      expect(additional, contains(FileAdditional.realPath));
      expect(additional, contains(FileAdditional.owner));

      t.responses['SYNO.FileStation.List.getinfo'] = {'files': []};
      final none = await fs.getInfo('/home/gone.txt');
      expect(none.name, 'gone.txt');
    });

    test('listFavorites / listVirtualFolders 用 real_path+time', () async {
      final (:fs, :t) = await makeApi();
      await fs.listFavorites();
      expect(t.lastCall['method'], 'list');
      expect(t.lastCall['status_filter'], 'all');
      expect(jsonDecode(t.lastCall['additional'] as String), [
        FileAdditional.realPath,
        FileAdditional.time,
      ]);

      // type 要 JSON 数组；留空则完全不发这个参数（真机 type=all 会 101）
      await fs.listVirtualFolders(type: const ['cifs']);
      expect(jsonDecode(t.lastCall['type'] as String), ['cifs']);
      await fs.listVirtualFolders();
      expect(t.lastCall.containsKey('type'), isFalse);
    });
  });

  group('写操作', () {
    test('createFolder / rename / deleteItems 的参数形状', () async {
      final (:fs, :t) = await makeApi();

      await fs.createFolder(folderPath: '/home', name: '新目录');
      expect(t.lastCall['api'], 'SYNO.FileStation.CreateFolder');
      expect(t.lastCall['method'], 'create');
      expect(t.lastCall['folder_path'], '/home');
      expect(t.lastCall['name'], '新目录');
      expect(t.lastCall['force_parent'], true);

      await fs.rename(path: '/home/a.txt', name: 'b.txt');
      expect(t.lastCall['method'], 'rename');
      // path/name 都是 JSON 数组字符串
      expect(jsonDecode(t.lastCall['path'] as String), ['/home/a.txt']);
      expect(jsonDecode(t.lastCall['name'] as String), ['b.txt']);

      await fs.deleteItems(['/home/a.txt', '/home/b/c.txt']);
      expect(t.lastCall['api'], 'SYNO.FileStation.Delete');
      // P0-a：普通删除改走官方 DS file 唯一用的 `Delete.start`（进回收站），
      // 不再是同步的 `Delete.delete`
      expect(t.lastCall['method'], 'start');
      expect(jsonDecode(t.lastCall['path'] as String), [
        '/home/a.txt',
        '/home/b/c.txt',
      ]);
      expect(t.lastCall['recursive'], true);
      expect(t.lastCall['accurate_progress'], true);
    });

    test('deletePermanently 走 Delete.delete（回收站条目专用）', () async {
      final (:fs, :t) = await makeApi();
      await fs.deletePermanently(['/home/#recycle/a.txt']);
      expect(t.lastCall['api'], 'SYNO.FileStation.Delete');
      expect(t.lastCall['method'], 'delete');
      expect(jsonDecode(t.lastCall['path'] as String), [
        '/home/#recycle/a.txt',
      ]);
    });

    test('startCopyMove：remove_src 区分复制/移动，解析 taskid', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.CopyMove.start'] = {'taskid': 'T-1'};
      final r = await fs.startCopyMove(
        paths: ['/home/a'],
        destFolderPath: '/home/b',
        removeSrc: true,
      );
      expect(r.taskIds, ['T-1']);
      expect(t.lastCall['remove_src'], true);
      expect(t.lastCall['dest_folder_path'], '/home/b');
      expect(t.lastCall['accurate_progress'], true);
    });

    test('startCompress / startExtract / startDirSize', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.Compress.start'] = {'taskid': 'C-1'};
      await fs.startCompress(paths: ['/home/a'], destFilePath: '/home/a.zip');
      expect(t.lastCall['format'], 'zip');
      expect(t.lastCall['dest_file_path'], '/home/a.zip');

      t.responses['SYNO.FileStation.Extract.start'] = {'taskid': 'E-1'};
      await fs.startExtract(
        filePath: '/home/a.zip',
        destFolderPath: '/home/out',
      );
      expect(t.lastCall['file_path'], '/home/a.zip');
      expect(t.lastCall['keep_dir'], true);

      t.responses['SYNO.FileStation.DirSize.start'] = {'taskid': 'D-1'};
      final d = await fs.startDirSize(['/home']);
      expect(d.taskId, 'D-1');
    });

    test('listArchive 先看压缩包内容（items 键，形状未经实证）', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.Extract.list'] = {
        'items': [
          {
            'name': 'inside.txt',
            'path': '/home/a.zip/inside.txt',
            'isdir': false,
            'size': 12,
          },
        ],
        'total': 1,
      };
      final r = await fs.listArchive(filePath: '/home/a.zip');
      expect(t.lastCall['method'], 'list');
      expect(t.lastCall['file_path'], '/home/a.zip');
      // ⚠️ dsfile APK 没调过 Extract.list，这个键是容错处理；
      // 真机验证后再回来收紧（见 docs §11「还没挖的」）
      expect(r.entries.single.name, 'inside.txt');
    });

    test('checkWritePermission / exists', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.CheckPermission.write'] = {
        'is_writable': true,
      };
      // ⚠️ filename 必填：真机漏传会 401（哪怕目录可写）
      expect(
        (await fs.checkWritePermission('/home', filename: 'x.txt')).isWritable,
        isTrue,
      );
      expect(t.lastCall['filename'], 'x.txt');
      expect(t.lastCall['method'], 'write');

      t.responses['SYNO.FileStation.CheckExist.check'] = {'exist': true};
      expect(await fs.exists('/home/a.txt'), isTrue);
    });

    test('错误码原样抛出（普通用户列根目录会拿到 105/401）', () async {
      final (:fs, :t) = await makeApi();
      t.failures['SYNO.FileStation.List.list'] = 401;
      await expectLater(
        fs.listFolder(folderPath: '/'),
        throwsA(
          isA<DsmApiException>()
              .having((e) => e.code, 'code', 401)
              .having((e) => e.method, 'method', 'SYNO.FileStation.List.list'),
        ),
      );
    });
  });

  group('任务中心', () {
    test('listBackgroundTasks 解析任务（含 params 与 errors）', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.BackgroundTask.list'] = {
        'total': 1,
        'offset': 0,
        'tasks': [
          {
            'taskid': 'T-9',
            'api': 'SYNO.FileStation.CopyMove',
            'method': 'start',
            'version': 3,
            'finished': false,
            'progress': 0.42,
            'processed_num': 3,
            'processing_path': '/home/b',
            'crtime': '2026-09-18 10:50:00',
            'path': '/home/a',
            'params': {'remove_src': true, 'dest_folder_path': '/home/b'},
            'errors': [
              {'code': 408, 'path': '/home/a/locked'},
            ],
          },
        ],
      };
      final r = await fs.listBackgroundTasks();
      final task = r.tasks.single;
      expect(task.taskId, 'T-9');
      expect(task.progress, 0.42);
      expect(task.finished, isFalse);
      expect(task.processedNum, 3);
      expect(task.label, '移动');
      expect(task.errors.single.code, 408);
      expect(task.errors.single.path, '/home/a/locked');
      expect(t.lastCall['sort_by'], 'crtime');
      expect(t.lastCall['sort_direction'], 'desc');
      // ⚠️ 分页形状：`offset` 必须真的发出去（漏了服务端只会回第一页，
      // 分页就静默失效）；版本必须协商到 **v3**（SPK `.lib` maxV=3）。
      expect(t.lastCall['offset'], 0);
      expect(r.offset, 0);
      expect(t.lastCall['version'], '3', reason: 'BackgroundTask maxV=3');
    });

    test('任务类型中文标签', () {
      FileTaskDto t(
        String api, {
        String method = 'start',
        Map<String, dynamic> params = const {},
      }) => FileTaskDto(taskId: 'x', api: api, method: method, params: params);
      expect(t('SYNO.FileStation.Compress').label, '压缩');
      expect(t('SYNO.FileStation.Extract').label, '解压');
      expect(t('SYNO.FileStation.CopyMove').label, '复制');
      expect(
        t('SYNO.FileStation.CopyMove', params: {'remove_src': true}).label,
        '移动',
      );
      expect(t('SYNO.FileStation.Delete', method: 'delete').label, '删除');
      expect(t('SYNO.FileStation.DirSize').label, '统计大小');
      expect(t('SYNO.FileStation.MD5').label, '计算校验值');
    });

    test('clearFinishedTasks 用 clear_finished（服务端只有它和 list）', () async {
      final (:fs, :t) = await makeApi();
      await fs.clearFinishedTasks();
      expect(t.lastCall['api'], 'SYNO.FileStation.BackgroundTask');
      expect(t.lastCall['method'], 'clear_finished');
    });

    test('taskStatus / stopTask 复用几个 API 的 status/stop，taskid 是裸字符串', () async {
      final (:fs, :t) = await makeApi();
      await fs.taskStatus(apiName: 'SYNO.FileStation.Compress', taskId: 'T-1');
      expect(t.lastCall['method'], 'status');
      // ⚠️ 裸字符串！发 JSON 数组串时真机回的是 HTML 错误页
      expect(t.lastCall['taskid'], 'T-1');

      await fs.stopTask(apiName: 'SYNO.FileStation.Extract', taskId: 'T-2');
      expect(t.lastCall['method'], 'stop');
      expect(t.lastCall['taskid'], 'T-2');
    });
  });

  group('搜索', () {
    test('startSearch 只下发非空筛选条件', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.Search.start'] = {
        'taskid': 'S-1',
        'finished': false,
        'offset': 0,
      };
      final r = await fs.startSearch(
        folderPath: '/home',
        pattern: 'report',
        extension: 'pdf',
        sizeFrom: 1024,
      );
      expect(r.taskId, 'S-1');
      final c = t.lastCall;
      expect(c['folder_path'], '/home');
      expect(c['pattern'], 'report');
      expect(c['extension'], 'pdf');
      expect(c['size_from'], 1024);
      expect(c.containsKey('size_to'), isFalse);
      expect(c['recursive'], true);
    });

    test('searchResults / stopSearch / cleanSearch', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.Search.list'] = {
        'total': 1,
        'offset': 0,
        'files': [
          {'name': 'r.pdf', 'path': '/home/r.pdf', 'isdir': false},
        ],
      };
      final r = await fs.searchResults(taskId: 'S-1', limit: 100);
      expect(r.entries.single.name, 'r.pdf');
      expect(t.lastCall['taskid'], 'S-1');

      await fs.stopSearch('S-1');
      expect(t.lastCall['method'], 'stop');
      await fs.cleanSearch('S-1');
      expect(t.lastCall['method'], 'clean');
    });

    test('searchHistory 兼容 history/list 两种键', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.Search.History.get'] = {
        'history': ['report', 'photo'],
      };
      expect(await fs.searchHistory(), ['report', 'photo']);
    });
  });

  group('分享链接（只读管理）', () {
    test('listShareLinks 解析 links', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.Sharing.list'] = {
        'total': 1,
        'offset': 0,
        'links': [
          {
            'id': 'L-1',
            'path': '/home/report.pdf',
            'name': 'report.pdf',
            'url': 'https://nas.example.com:5001/sharing/abc',
            'isFolder': false,
            'status': 'valid',
            'has_password': true,
            'date_available': '2026-09-01',
            'date_expired': '2026-10-01',
            'link_owner': 'demo_user',
            'uid': 1024,
            'qrcode': '',
            'error': 0,
          },
        ],
      };
      final links = await fs.listShareLinks();
      final link = links.single;
      expect(link.id, 'L-1');
      expect(link.name, 'report.pdf');
      expect(link.url, 'https://nas.example.com:5001/sharing/abc');
      expect(link.hasPassword, isTrue);
      expect(link.isValid, isTrue);
      expect(t.lastCall['force_clean'], true);
    });

    test('deleteShareLinks / clearInvalidShareLinks', () async {
      final (:fs, :t) = await makeApi();
      await fs.deleteShareLinks(['L-1', 'L-2']);
      expect(t.lastCall['method'], 'delete');
      expect(jsonDecode(t.lastCall['id'] as String), ['L-1', 'L-2']);

      await fs.clearInvalidShareLinks();
      expect(t.lastCall['method'], 'clear_invalid');
    });

    test('无效链接的 status 判定', () {
      expect(const ShareLinkDto(id: 'x', status: 'broken').isValid, isFalse);
      // 空 status 视为有效（老服务器不给这个字段）
      expect(const ShareLinkDto(id: 'x').isValid, isTrue);
    });

    // ⚠️ 这条用例**原先断言的是错的**：它按 `delete` 的形状把 `id` 钉成
    // JSON 数组 `["L-1"]`。那是我方当初"未取证"时的**猜测**，不是真机/APK 事实。
    // 第 28 轮反编译官方 DS file 4.17.2-609 后确认 `edit` 发的是**裸 id**
    // （`SingleApiParameter("id", p1)`），只有 `delete` 发数组
    // （`CompositeApiParameter`）。⇒ **这里是修正一个错误假设，不是"改代码迁就测试"。**
    test(
      'editShareLink：Sharing.edit v3 + id(**裸字符串**) + password/date_expired',
      () async {
        final (:fs, :t) = await makeApi();
        t.responses['SYNO.FileStation.Sharing.edit'] = {
          'links': [
            {'id': 'L-1', 'name': 'a.txt', 'status': 'valid'},
          ],
        };
        final links = await fs.editShareLink(
          id: 'L-1',
          password: 'pw2',
          dateExpired: '2026-12-31',
        );
        expect(links.single.id, 'L-1');
        expect(t.lastCall['api'], 'SYNO.FileStation.Sharing');
        expect(t.lastCall['method'], 'edit');
        expect(t.lastCall['version'], '3');
        // ★ 裸 id —— 不是 `jsonDecode(...) == ['L-1']`（那是旧错误假设）
        expect(t.lastCall['id'], 'L-1');
        expect(t.lastCall['password'], 'pw2');
        expect(t.lastCall['date_expired'], '2026-12-31');
      },
    );

    test('editShareLink：保持原样不发可选字段；清空密码发 `protect_type:none` + 空串', () async {
      final (:fs, :t) = await makeApi();
      await fs.editShareLink(id: 'L-1');
      expect(t.lastCall.containsKey('password'), isFalse);
      expect(t.lastCall.containsKey('date_expired'), isFalse);

      // ★ 第 251 轮按官方 smali（`WebApiConnectionManager.editShareLinkV3`）订正：
      //   清空密码是**两个字段一起发**；`date_expired` 空值一律**不发**。
      await fs.editShareLink(id: 'L-1', clearPassword: true);
      expect(t.lastCall['protect_type'], 'none');
      expect(t.lastCall['password'], '');
      expect(t.lastCall.containsKey('date_expired'), isFalse);
    });
  });

  group('上传 / 下载 / 缩略图', () {
    test('upload 的元数据在 multipart form 字段上（只 _sid 在查询串）', () async {
      final (:fs, :t) = await makeApi();
      final tmp = _tmpFile('report.pdf', 1234);
      final id = await fs.upload(
        folderPath: '/home/Drive',
        filePath: tmp.path,
        fileName: 'report.pdf',
        mimeType: 'application/pdf',
      );
      expect(id, 'fs-file-1');
      final up = t.uploads.single;
      expect(up['path'], 'entry.cgi');

      // ⚠️ 反编译官方 DS file（WebApiConnectionManager.uploadInternal）得到的形态：
      //    元数据是 **form 字段**，URL 上只有 _sid。放查询串 + 漏 size 会让服务端
      //    一直等剩余字节（真机 receiveTimeout）。
      expect(up['query'].keys, ['_sid']);
      final fields = up['fields'] as Map;
      expect(fields['api'], 'SYNO.FileStation.Upload');
      expect(fields['method'], 'upload');
      expect(fields['path'], '/home/Drive');
      expect(fields['create_parents'], 'false');
      // P0-a：没有冲突时不发 overwrite（官方 OverWriteMode.NONE）。
      // 旧实现硬编码 `overwrite=overwrite` → 同名文件静默覆盖。
      expect(
        fields.containsKey('overwrite'),
        isFalse,
        reason: '无冲突不得发 overwrite（更不得硬编码 overwrite）',
      );
      expect(fields['size'], isA<String>(), reason: 'size 必发（字节数）');
      expect(int.parse(fields['size'] as String), greaterThan(0));
      expect(
        int.tryParse('${fields['mtime']}'),
        isNotNull,
        reason: 'mtime 是毫秒',
      );
      expect(up['fileField'], 'file');
      expect(up['fileName'], 'report.pdf');
      expect(up['mimeType'], 'application/pdf');
    });

    test('Extract.list 的形状：items + is_dir/pack_size/字符串 mtime', () {
      // 真机原样（tool/flt_extract_probe.dart）：
      //   {items:[{is_dir:false,item_id:0,mtime:"2026-09-18 13:16:20",
      //            name:"a.txt",pack_size:6,path:"a.txt",size:6}],total:1}
      final r = FileListResult.fromJson({
        'items': [
          {
            'is_dir': false,
            'item_id': 0,
            'mtime': '2026-09-18 13:16:20',
            'name': 'a.txt',
            'pack_size': 6,
            'path': 'a.txt',
            'size': 6,
          },
          {
            'is_dir': true,
            'item_id': 1,
            'mtime': '2026-09-18 13:16:21',
            'name': 'sub',
            'pack_size': 0,
            'path': 'sub',
          },
        ],
        'total': 2,
      });
      expect(r.entries.length, 2);
      expect(r.entries.first.name, 'a.txt');
      expect(r.entries.first.size, 6, reason: '归档条目 size 在顶层');
      expect(r.entries.first.isDir, isFalse);
      expect(r.entries.first.mtime, greaterThan(0), reason: '字符串时间要能解析');
      expect(r.entries[1].isDir, isTrue, reason: '归档里的目录是 is_dir');
    });

    test('Favorite.list 的 entries 在 favorites 键上（漏了会永远显示空）', () {
      final r = FileListResult.fromJson({
        'favorites': [
          {'path': '/home/a', 'name': 'a', 'isdir': true, 'status': 'valid'},
        ],
        'offset': 0,
        'total': 1,
      });
      expect(r.entries.single.path, '/home/a');
      expect(r.total, 1);
    });

    test('Compress.start 一定发 mode（官方每次都发，默认 add）', () async {
      final (:fs, :t) = await makeApi();
      await fs.startCompress(
        paths: ['/home/a.txt'],
        destFilePath: '/home/a.zip',
      );
      // ⚠️ 这里原先钉的是 `moderate`/`add` —— 那是**反推的臆测**，
      // 不是观测到的线上值。第 29 轮以官方 APK `arrays.xml` 的
      // `archive_compress_level_key`/`archive_update_mode_key` 定案为
      // `normal`/`replace`。⇒ **修正错误假设，不是迁就代码。**
      expect(t.lastCall['mode'], 'replace');
      expect(t.lastCall['level'], 'normal');
      expect(t.lastCall['format'], 'zip');
    });

    test('addFavorite 一定会发 name（漏了真机 400）', () async {
      final (:fs, :t) = await makeApi();
      await fs.addFavorite('/home/Drive/报告');
      expect(t.lastCall['name'], '报告');
      await fs.addFavorite('/home/Drive', name: '我的 Drive');
      expect(t.lastCall['name'], '我的 Drive');
    });

    test('本地文件读不到 → 说人话的 400，不抛 PathNotFoundException', () async {
      final (:fs, :t) = await makeApi();
      await expectLater(
        fs.upload(
          folderPath: '/home',
          filePath: '/definitely/not/here.bin',
          fileName: 'here.bin',
        ),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.requestParameterInvalid,
          ),
        ),
      );
      expect(t.uploads, isEmpty, reason: '读不到文件就不该发请求');
    });

    test('upload 冲突策略取官方枚举（v3：rename/skip/overwrite）', () async {
      final (:fs, :t) = await makeApi();
      await fs.upload(
        folderPath: '/home',
        filePath: _tmpFile('a.bin', 8).path,
        fileName: 'a.bin',
        conflict: UploadConflictPolicy.skip,
      );
      expect((t.uploads.single['fields'] as Map)['overwrite'], 'skip');

      await fs.upload(
        folderPath: '/home',
        filePath: _tmpFile('b.bin', 8).path,
        fileName: 'b.bin',
        conflict: UploadConflictPolicy.rename,
      );
      expect((t.uploads.last['fields'] as Map)['overwrite'], 'rename');

      await fs.upload(
        folderPath: '/home',
        filePath: _tmpFile('c.bin', 8).path,
        fileName: 'c.bin',
        conflict: UploadConflictPolicy.overwrite,
      );
      expect((t.uploads.last['fields'] as Map)['overwrite'], 'overwrite');
    });

    test('老服务端（Upload maxVersion<3）：rename 退化成布尔 false 而非静默覆盖', () async {
      final table = Map<String, Map<String, dynamic>>.from(
        FakeFsTransport.defaultTable,
      );
      table['SYNO.FileStation.Upload'] = {
        'path': 'entry.cgi',
        'minVersion': 2,
        'maxVersion': 2,
      };
      final (:fs, :t) = await makeApi(table: table);
      expect(fs.supportsUploadRename, isFalse);
      await fs.upload(
        folderPath: '/home',
        filePath: _tmpFile('d.bin', 8).path,
        fileName: 'd.bin',
        conflict: UploadConflictPolicy.rename,
      );
      // 官方 v2 只认布尔串；rename 没有对应值 → 这里退化成 false（跳过）
      expect((t.uploads.single['fields'] as Map)['overwrite'], 'false');
      expect((t.uploads.single['fields'] as Map)['version'], '2');
    });

    test('restoreFromRecycleBin：CopyMove.start v3 + 官方还原参数', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.CopyMove.start'] = {'taskid': 'R-1'};
      final r = await fs.restoreFromRecycleBin(
        paths: ['/home/#recycle/a.txt'],
        destFolderPath: '/home',
      );
      expect(r.taskIds, ['R-1']);
      expect(t.lastCall['api'], 'SYNO.FileStation.CopyMove');
      expect(t.lastCall['method'], 'start');
      expect(t.lastCall['version'], '3');
      expect(t.lastCall['remove_src'], true);
      expect(t.lastCall['restore_from_recycle_bin'], true);
      expect(t.lastCall['dest_folder_path'], '/home');
      expect(t.lastCall['accurate_progress'], true);
      expect(jsonDecode(t.lastCall['path'] as String), [
        '/home/#recycle/a.txt',
      ]);
    });

    test('purgeRecycleBin：Core.RecycleBin.start v1 + id=共享名', () async {
      final (:fs, :t) = await makeApi();
      await fs.purgeRecycleBin('home');
      expect(t.lastCall['api'], 'SYNO.Core.RecycleBin');
      expect(t.lastCall['method'], 'start');
      expect(t.lastCall['version'], '1');
      expect(t.lastCall['id'], 'home');
    });

    test('isManager 读 Info.get 的 is_manager', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.Info.get'] = {'is_manager': true};
      expect(await fs.isManager(), isTrue);
      t.responses['SYNO.FileStation.Info.get'] = {'is_manager': false};
      expect(await fs.isManager(), isFalse);
    });

    test(
      'createShareLink：Sharing.create v3 + path/password/date_expired',
      () async {
        final (:fs, :t) = await makeApi();
        t.responses['SYNO.FileStation.Sharing.create'] = {
          'links': [
            {
              'id': 'L1',
              'url': 'https://nas.example.com:5001/sharing/abc',
              'path': '/home/a.txt',
              'name': 'a.txt',
            },
          ],
        };
        final links = await fs.createShareLink(
          paths: ['/home/a.txt'],
          password: 'pw123',
          dateExpired: '2026-10-01',
        );
        expect(links.single.url, 'https://nas.example.com:5001/sharing/abc');
        expect(t.lastCall['api'], 'SYNO.FileStation.Sharing');
        expect(t.lastCall['method'], 'create');
        expect(t.lastCall['version'], '3');
        expect(jsonDecode(t.lastCall['path'] as String), ['/home/a.txt']);
        expect(t.lastCall['password'], 'pw123');
        expect(t.lastCall['date_expired'], '2026-10-01');
        // 没有"生效时间"时不发 date_available（官方 createShareLinkV3）
        expect(t.lastCall.containsKey('date_available'), isFalse);
      },
    );

    test('createShareLink：无密码/永久有效时不发可选字段', () async {
      final (:fs, :t) = await makeApi();
      await fs.createShareLink(paths: ['/home/a.txt']);
      expect(t.lastCall.containsKey('password'), isFalse);
      expect(t.lastCall.containsKey('date_expired'), isFalse);
      expect(t.lastCall.containsKey('date_available'), isFalse);
      expect(t.lastCall.containsKey('path'), isTrue, reason: 'path 是必填');
    });

    test('downloadUrl 带 api/method/path(JSON)/mode', () {
      final t = FakeFsTransport();
      final fs = FileStationApi(DsmWebApi(t));
      final url = fs.downloadUrl(['/home/a.txt', '/home/b c.txt']);
      expect(url, contains('api=SYNO.FileStation.Download'));
      expect(url, contains('method=download'));
      expect(url, contains('version=2'));
      expect(url, contains('mode=download'));
      // path 是 JSON 数组串，且被 URL 编码过
      expect(
        Uri.decodeQueryComponent(url),
        contains('["/home/a.txt","/home/b c.txt"]'),
      );
    });

    test('thumbnailUrl 带 size', () {
      final t = FakeFsTransport();
      final fs = FileStationApi(DsmWebApi(t));
      final url = fs.thumbnailUrl('/home/a.jpg', size: 'large');
      expect(url, contains('api=SYNO.FileStation.Thumb'));
      expect(url, contains('size=large'));
      expect(url, contains('path=%2Fhome%2Fa.jpg'));
    });

    test('路径里的引号/反斜杠会被转义（JSON 数组串不能坏）', () {
      expect(FileEntryDto.encodePaths(['/a"b']), '["/a\\"b"]');
      expect(FileEntryDto.encodePaths(['/a\\b']), '["/a\\\\b"]');
    });
  });

  group('MD5 校验（服务端算）', () {
    test('start：v2 + file_path 是路径数组串', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.MD5.start'] = {'taskid': 'M-1'};
      final id = await fs.startMd5(['/home/a.bin']);
      expect(id, 'M-1');
      expect(t.lastCall['api'], 'SYNO.FileStation.MD5');
      expect(t.lastCall['method'], 'start');
      expect('${t.lastCall['version']}', '2');
      // 官方 Web 端（FileProperty.js）用的就是 `file_path`，不是 `path`/`file`
      expect(t.lastCall['file_path'], '["/home/a.bin"]');
      expect(t.lastCall.containsKey('path'), isFalse);
    });

    test('status：taskid 是裸串；finished 才有 md5', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.MD5.status'] = {
        'finished': true,
        'md5': 'd41d8cd98f00b204e9800998ecf8427e',
      };
      final st = await fs.md5Status('M-1');
      expect(st.finished, isTrue);
      expect(st.md5, 'd41d8cd98f00b204e9800998ecf8427e');
      expect(t.lastCall['taskid'], 'M-1');
      expect('${t.lastCall['version']}', '2');
    });

    test('status：还在算 → finished=false 且没有 md5', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.MD5.status'] = {'finished': false};
      final st = await fs.md5Status('M-1');
      expect(st.finished, isFalse);
      expect(st.md5, isEmpty);
      expect(st.failed, isFalse);
    });

    test('status：errors 非空 → failed（算不了/没权限）', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.MD5.status'] = {
        'finished': false,
        'errors': [
          {'code': 408, 'path': '/home/a.bin'},
        ],
      };
      final st = await fs.md5Status('M-1');
      expect(st.failed, isTrue);
    });

    test('stop：taskid 裸串', () async {
      final (:fs, :t) = await makeApi();
      await fs.stopMd5('M-1');
      expect(t.lastCall['method'], 'stop');
      expect(t.lastCall['taskid'], 'M-1');
    });

    test('服务器只到 v1 时就发 v1（不硬写 v2）', () async {
      final (:fs, :t) = await makeApi(
        table: {
          ...FakeFsTransport.defaultTable,
          'SYNO.FileStation.MD5': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
        },
      );
      t.responses['SYNO.FileStation.MD5.start'] = {'taskid': 'M-1'};
      await fs.startMd5(['/home/a.bin']);
      expect('${t.lastCall['version']}', '1');
    });
  });

  group('文件属性扩展（Property.*）', () {
    test('CompressSize：v1 + 参数名是 file（不是 file_path）', () async {
      final (:fs, :t) = await makeApi();
      // 真机回的是字符串 "4096"，不是数字 —— 这就是当年静默变 null 的坑
      t.responses['SYNO.FileStation.Property.CompressSize.get'] = {
        'diskSize': '4096',
      };
      expect(await fs.compressSize('/home/a.bin'), 4096);
      expect(t.lastCall['api'], 'SYNO.FileStation.Property.CompressSize');
      expect(t.lastCall['method'], 'get');
      expect('${t.lastCall['version']}', '1');
      expect(t.lastCall['file'], '/home/a.bin');
    });

    test('数值为数字时照样认（两种形态都兼容）', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.Property.CompressSize.get'] = {
        'diskSize': 4096,
      };
      expect(await fs.compressSize('/volume1/a.bin'), 4096);
    });

    test('Mtime：拿秒级时间戳（真机是字符串）', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.Property.Mtime.get'] = {
        'mtime': '1789000000',
      };
      expect(await fs.mtimeOf('/home/a.bin'), 1789000000);
      expect(t.lastCall['api'], 'SYNO.FileStation.Property.Mtime');
      expect(t.lastCall['file'], '/home/a.bin');
    });

    test('ACLOwner：解析 name/type/value/hasPrivilege', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.Property.ACLOwner.get'] = {
        'name': 'demo_user',
        'type': 'user',
        'value': 'user:demo_user',
        'hasPrivilege': true,
      };
      final owner = await fs.aclOwner('/home/a.bin');
      expect(owner.name, 'demo_user');
      expect(owner.type, 'user');
      expect(owner.label, 'user:demo_user');
      expect(owner.hasPrivilege, isTrue);
      expect(t.lastCall['api'], 'SYNO.FileStation.Property.ACLOwner');
      expect(t.lastCall['file'], '/home/a.bin');
    });

    test('ACLOwner：没权限时原样抛（页面降级显示，不当成致命错误）', () async {
      final (:fs, :t) = await makeApi();
      t.failures['SYNO.FileStation.Property.ACLOwner.get'] = 403;
      await expectLater(fs.aclOwner('/other/x'), throwsA(anything));
    });

    test('CompressSize 缺字段 → null（老版本不下发 diskSize）', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.Property.CompressSize.get'] = {};
      expect(await fs.compressSize('/home/a.bin'), isNull);
    });
  });

  group('FileStation 能力探测', () {
    test('info() 走 Info.get', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.Info.get'] = {'support': 1};
      final info = await fs.info();
      expect(info['support'], 1);
      expect(t.lastCall['method'], 'get');
    });
  });

  group('回收站路径判定（RecyclePath，对照官方 RecycleBin.js）', () {
    test('isInRecycleBin / isRecycleRoot', () {
      expect(RecyclePath.isInRecycleBin('/home/#recycle'), isTrue);
      expect(RecyclePath.isInRecycleBin('/home/#recycle/a.txt'), isTrue);
      expect(RecyclePath.isInRecycleBin('/home/a.txt'), isFalse);
      expect(RecyclePath.isInRecycleBin(''), isFalse);
      expect(RecyclePath.isRecycleRoot('/home/#recycle'), isTrue);
      expect(RecyclePath.isRecycleRoot('/home/#recycle/dir'), isFalse);
    });

    test('shareOf / rootOf', () {
      expect(RecyclePath.shareOf('/home/#recycle/a.txt'), 'home');
      expect(RecyclePath.shareOf('/photo/#recycle'), 'photo');
      expect(RecyclePath.shareOf('/home/a.txt'), isNull);
      expect(RecyclePath.rootOf('/home/#recycle/dir/a.txt'), '/home/#recycle');
    });

    test('restoreDest：去掉 #recycle 这一段（官方 doRestore 的算法）', () {
      expect(RecyclePath.restoreDest('/home/#recycle/a.txt'), '/home');
      expect(RecyclePath.restoreDest('/home/#recycle/dir/a.txt'), '/home/dir');
      expect(RecyclePath.restoreDest('/photo/#recycle/img.png'), '/photo');
      // 不在回收站里：原样返回
      expect(RecyclePath.restoreDest('/home/a.txt'), '/home/a.txt');
    });
  });

  group('wave2：M58 retryTask / M50 replace_all（真机已取证）', () {
    test('retryTask 按传入的 api/method/params 重发（不碰参数名）', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.Compress.start'] = {'taskid': 'R-1'};
      await fs.retryTask(
        apiName: 'SYNO.FileStation.Compress',
        method: 'start',
        params: {
          'path': '["/home/a"]',
          'dest_file_path': '/home/a.zip',
          'format': 'zip',
          'level': 'normal',
          'mode': 'replace',
        },
      );
      expect(t.lastCall['api'], 'SYNO.FileStation.Compress');
      expect(t.lastCall['method'], 'start');
      expect(t.lastCall['version'], '3');
      // 参数原样透传
      expect(t.lastCall['dest_file_path'], '/home/a.zip');
      expect(t.lastCall['mode'], 'replace');
    });

    test('retryTask 用 api 自己的 maxVersion 协商（Extract 退到 v2）', () async {
      final (:fs, :t) = await makeApi();
      await fs.retryTask(
        apiName: 'SYNO.FileStation.Extract',
        method: 'start',
        params: {'file_path': '/home/a.zip', 'dest_folder_path': '/home'},
      );
      expect(t.lastCall['version'], '2');
    });

    test('replace_all：v2 + path/name 两个平行 JSON 数组串（顺序即显示顺序）', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.Favorite.replace_all'] =
          <String, dynamic>{};
      await fs.replaceAllFavorites(
        paths: ['/home/Books', '/home/Download'],
        names: ['ZZ测试收藏A', 'ZZ测试收藏B'],
      );
      expect(t.lastCall['api'], 'SYNO.FileStation.Favorite');
      expect(t.lastCall['method'], 'replace_all');
      expect(t.lastCall['version'], '2');
      // 真机取证：两个数组都按 JSON 数组串发，且第 i 个 name 对应第 i 个 path
      expect(t.lastCall['path'], '["/home/Books","/home/Download"]');
      expect(t.lastCall['name'], '["ZZ测试收藏A","ZZ测试收藏B"]');
    });

    test('replace_all：顺序真的按传入顺序（反序传入 → 反序发出）', () async {
      final (:fs, :t) = await makeApi();
      t.responses['SYNO.FileStation.Favorite.replace_all'] =
          <String, dynamic>{};
      // 真机场景：原来 B、A，用户重排成 A、B
      await fs.replaceAllFavorites(
        paths: ['/home/Download', '/home/Books'],
        names: ['ZZ测试收藏B', 'ZZ测试收藏A'],
      );
      expect(t.lastCall['path'], '["/home/Download","/home/Books"]');
      expect(t.lastCall['name'], '["ZZ测试收藏B","ZZ测试收藏A"]');
    });

    test('replace_all：success:false → 抛异常（400 也算失败，不当成功）', () async {
      final (:fs, :t) = await makeApi();
      // 真机实测：只传 path、或参数过期/缺失 → 400
      t.failures['SYNO.FileStation.Favorite.replace_all'] = 400;
      await expectLater(
        fs.replaceAllFavorites(paths: ['/home/a'], names: ['A']),
        throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 400)),
      );
    });
  });
}
