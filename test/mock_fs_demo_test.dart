// `tool/mock_dsm/mock_fs_demo.dart` 的守卫：**Mock 的写动词必须真的改状态**。
//
// 为什么值得单独立测：这个内存树是 macOS/Linux/iOS 写侧验收的**判据来源**——
// 如果它自己就"create 了但 list 里没有"，那么上层所有"写成功"的结论都会变成
// §2.0.29 的反面教材（用一个坏仪器去证明"改对了"）。
//
// 判据一律取**服务端状态**（`List.list` 的回包），不取 create 的回包。
import 'package:flutter_test/flutter_test.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import '../tool/mock_dsm/mock_fs_demo.dart';

void main() {
  late MockDsmBackend backend;
  late String sid;

  setUp(() {
    backend = MockDsmBackend(catalog: DsmCatalog.load());
    sid = backend.login(username: 'mockuser', admin: false);
    backend.installFileSystemDemo();
  });

  /// 从 `List.list` 的回包里按名字取一条（**服务端状态**判据的统一入口）。
  Map<String, dynamic>? fileIn(String folder, String name) {
    final r = backend.handle('entry.cgi', {
      'api': 'SYNO.FileStation.List',
      'method': 'list',
      'version': 2,
      '_sid': sid,
      'folder_path': folder,
    });
    final files = ((r.json['data'] as Map?)?['files'] as List?) ?? const [];
    for (final f in files) {
      final m = Map<String, dynamic>.from(f as Map);
      if (m['name'] == name) {
        // 大小在 `additional.size` 里（与真 DSM 同形）—— 判据也走这个层级
        return Map<String, dynamic>.from(m);
      }
    }
    return null;
  }

  MockDsmResponse call(String api, String method, Map<String, dynamic> p) =>
      backend.handle('entry.cgi', {
        'api': api,
        'method': method,
        'version': 2,
        '_sid': sid,
        ...p,
      });

  List<String> namesOf(MockDsmResponse r, String key) {
    expect(r.ok, isTrue, reason: '服务端应成功：${r.json}');
    final data = r.json['data'] as Map;
    return (data[key] as List)
        .map((e) => '${(e as Map)['name']}')
        .toList(growable: false);
  }

  test('list_share 回顶层共享文件夹（判据 = 服务端状态）', () {
    final shares = namesOf(
      call('SYNO.FileStation.List', 'list_share', const {}),
      'shares',
    );
    expect(shares, containsAll(<String>['home', 'photo']));
  });

  test('list 只回该目录的直接子节点，且目录在前', () {
    final names = namesOf(
      call('SYNO.FileStation.List', 'list', const {
        'folder_path': '/home',
      }),
      'files',
    );
    expect(names, contains('mockfs_sandbox'));
    // 目录（mockfs_sandbox / Documents）必须排在文件前面
    final firstFile = names.indexOf('mockfs_home.txt');
    expect(firstFile, greaterThanOrEqualTo(0), reason: '种子里有这个文件');
    expect(names.indexOf('mockfs_sandbox'), lessThan(firstFile));
    // 孙节点不许混进来（`/home/mockfs_sandbox/readme.txt`）
    expect(names, isNot(contains('sample.jpg')));
  });

  test('★ create → list 里真的多出这一条（这就是"写动词真的改了状态"）', () {
    final r = call('SYNO.FileStation.CreateFolder', 'create', const {
      'folder_path': '/home',
      'name': 'r319_new',
      'force_parent': true,
    });
    expect(r.ok, isTrue, reason: '创建应成功：${r.json}');

    final names = namesOf(
      call('SYNO.FileStation.List', 'list', const {
        'folder_path': '/home',
      }),
      'files',
    );
    expect(names, contains('r319_new'));
  });

  test('create 允许 name 是 JSON 数组（官方前端两种都发过）', () {
    final r = call('SYNO.FileStation.CreateFolder', 'create', const {
      'folder_path': '/home',
      'name': '["r319_arr"]',
    });
    expect(r.ok, isTrue);
    final names = namesOf(
      call('SYNO.FileStation.List', 'list', const {
        'folder_path': '/home',
      }),
      'files',
    );
    expect(names, contains('r319_arr'));
  });

  test('重名 create ⇒ 服务端报错（不许静默成功）', () {
    final r = call('SYNO.FileStation.CreateFolder', 'create', const {
      'folder_path': '/home',
      'name': 'Documents',
    });
    expect(r.ok, isFalse);
    expect(r.errorCode, 414);
  });

  test('★ rename → 新名字出现在列表、旧名字消失（目录整棵子树跟着走）', () {
    expect(
      call('SYNO.FileStation.Rename', 'rename', const {
        'path': '["/home/Documents"]',
        'name': '["r319_renamed"]',
      }).ok,
      isTrue,
    );
    final names = namesOf(
      call('SYNO.FileStation.List', 'list', const {
        'folder_path': '/home',
      }),
      'files',
    );
    expect(names, contains('r319_renamed'));
    expect(names, isNot(contains('Documents')));

    // 子树跟着改名（否则新目录会是空的 —— 真机上是"文件丢了"）
    final kids = namesOf(
      call('SYNO.FileStation.List', 'list', const {
        'folder_path': '/home/r319_renamed',
      }),
      'files',
    );
    expect(kids, contains('plan.txt'));
  });

  test('★ delete → 列表里真的没了；删子项不影响父项', () {
    expect(
      call('SYNO.FileStation.Delete', 'delete', const {
        'path': '["/home/mockfs_sandbox/readme.txt"]',
      }).ok,
      isTrue,
    );
    final kids = namesOf(
      call('SYNO.FileStation.List', 'list', const {
        'folder_path': '/home/mockfs_sandbox',
      }),
      'files',
    );
    expect(kids, isNot(contains('readme.txt')));

    // 父目录还在（删子项不该连父项一起删）
    final home = namesOf(
      call('SYNO.FileStation.List', 'list', const {
        'folder_path': '/home',
      }),
      'files',
    );
    expect(home, contains('mockfs_sandbox'));
  });

  test('删不存在的路径 ⇒ 报错（避免"删成功"的假绿）', () {
    final r = call('SYNO.FileStation.Delete', 'delete', const {
      'path': '["/home/never_existed"]',
    });
    expect(r.ok, isFalse);
  });

  test('夹具没装的接口仍然走"空 data"契约（没有被我这次改动波及）', () {
    // `getinfo` 在 `SYNO.FileStation.List` v2 里**存在**（权威表 v1/v2 都有），
    // 但本 demo 没给它注册夹具 ⇒ 必须还是「空 data」，不是被我顺手改了契约。
    final r = call('SYNO.FileStation.List', 'getinfo', const {});
    expect(r.ok, isTrue, reason: '存在的方法不该变成 103：${r.json}');
    expect(r.json['data'], isEmpty);
  });

  test('反向验证：方法在版本里不存在 ⇒ 103（不是我这次把校验放松了）', () {
    final r = call('SYNO.FileStation.List', 'list_recent', const {});
    expect(r.ok, isFalse);
    expect(r.errorCode, 103);
  });

  // ---------------------------------------------------------------- 上传（r319）
  //
  // 服务端把 multipart 解析成 `params['__files']`（见 `mock_dsm_server.dart`），
  // 夹具据此**真的**把文件写进内存树。判据仍是 `List.list` 的回包。

  test('上传：文件真的进树，`List.list` 能列出来且大小 = 字节数', () {
    final r = call('SYNO.FileStation.Upload', 'upload', {
      'path': '/home/mockfs_sandbox',
      '__files': [
        {
          'name': 'r319_upload.bin',
          'bytes': List<int>.filled(37, 7),
        },
      ],
    });
    expect(r.ok, isTrue, reason: '${r.json}');
    expect(r.json['data'], containsPair('blSkip', false));

    final hit = fileIn('/home/mockfs_sandbox', 'r319_upload.bin');
    expect(hit, isNotNull, reason: '上传后列表里必须有它（判据 = List.list 回包）');
    expect(
      (hit!['additional'] as Map)['size'],
      37,
      reason: '大小必须是真实字节数，不是占位',
    );
  });

  test('上传：同名且未允许覆盖 ⇒ 414（冲突面板的语义，不许静默覆盖）', () {
    final first = call('SYNO.FileStation.Upload', 'upload', {
      'path': '/home',
      '__files': [
        {
          'name': 'mockfs_home.txt',
          'bytes': List<int>.filled(5, 1),
        },
      ],
    });
    expect(first.ok, isFalse);
    expect(first.errorCode, 414);

    // 原文件**一个字节都没变**（覆盖失败不许留半截）
    final after = fileIn('/home', 'mockfs_home.txt');
    expect(after, isNotNull);
    expect((after!['additional'] as Map)['size'], 64);
  });

  test('上传：允许覆盖 ⇒ 大小被替换', () {
    final r = call('SYNO.FileStation.Upload', 'upload', {
      'path': '/home',
      'overwrite': 'true',
      '__files': [
        {
          'name': 'mockfs_home.txt',
          'bytes': List<int>.filled(9, 2),
        },
      ],
    });
    expect(r.ok, isTrue, reason: '${r.json}');
    final after = fileIn('/home', 'mockfs_home.txt');
    expect(after, isNotNull);
    expect((after!['additional'] as Map)['size'], 9);
  });

  test('反向验证：没带文件的上传不许回"成功"', () {
    final r = call('SYNO.FileStation.Upload', 'upload', const {'path': '/home'});
    expect(r.ok, isFalse);
    expect(r.errorCode, 114);
  });

  test('反向验证：multipart 解析失败的上传同样不许当成功', () {
    final r = call('SYNO.FileStation.Upload', 'upload', const {
      'path': '/home',
      '__multipartBroken': true,
    });
    expect(r.ok, isFalse);
    expect(r.errorCode, 114);
  });

  // ── ★★ 第 329 轮：二进制下载夹具（补 §2.0.57 的"宿主存本机不可达"缺口）──
  group('二进制下载 `FileStation.Download`（内存树的真字节）', () {
    /// ★ 入参形状必须与**客户端**一致：`path` 是 JSON 数组
    /// （`FileEntryDto.encodePaths()`），不是裸字符串 —— 第一版单测用裸串，
    /// 于是它绿、集成红（夹具踩的正是同一个坑）。
    MockRawResponse raw(String path) => backend.handleRaw('entry.cgi', {
      'api': 'SYNO.FileStation.Download',
      'method': 'download',
      'version': 2,
      '_sid': sid,
      'path': '["$path"]',
    });

    test('回真字节：长度 == 树里登记的 size，且逐字节等于公式', () {
      final r = raw('/photo/mockfs_album/sample.jpg');
      expect(r.ok, isTrue, reason: r.note);
      expect(r.contentType, 'image/jpeg');
      expect(r.bytes.length, 4096, reason: '夹具声明的 size = 4096');
      // 判据独立重算一遍（不依赖夹具自己的生成器）
      for (final i in [0, 1, 30, 4095]) {
        expect(r.bytes[i], (i * 31 + 7) % 256, reason: '第 $i 字节');
      }
    });

    test('文本文件走 text/plain（客户端会先嗅 JSON 错误信封那条分支）', () {
      final r = raw('/home/Documents/plan.txt');
      expect(r.ok, isTrue, reason: r.note);
      expect(r.contentType, 'text/plain');
      expect(r.bytes.length, 2048);
    });

    test('反向：目录 / 不存在的路径都不许回字节（408，不是空成功）', () {
      final dir = raw('/home');
      expect(dir.ok, isFalse);
      expect(dir.errorCode, 408);
      final missing = raw('/home/nope.bin');
      expect(missing.ok, isFalse);
      expect(missing.errorCode, 408);
    });

    test('反向：空 path / 多个 path 都不许静默取第一个（114 / 408）', () {
      final empty = backend.handleRaw('entry.cgi', {
        'api': 'SYNO.FileStation.Download',
        'method': 'download',
        'version': 2,
        '_sid': sid,
        'path': '[]',
      });
      expect(empty.ok, isFalse);
      expect(empty.errorCode, 114);
      final multi = backend.handleRaw('entry.cgi', {
        'api': 'SYNO.FileStation.Download',
        'method': 'download',
        'version': 2,
        '_sid': sid,
        'path': '["/home/mockfs_home.txt","/home/Documents/plan.txt"]',
      });
      expect(multi.ok, isFalse);
      expect(multi.errorCode, 408, reason: '不许"悄悄只下第一个"');
    });

    test('反向：没带 sid 就不许下（119）—— 与 JSON 侧同一套鉴权判据', () {
      final r = backend.handleRaw('entry.cgi', {
        'api': 'SYNO.FileStation.Download',
        'method': 'download',
        'version': 2,
        'path': '["/home/mockfs_home.txt"]',
      });
      expect(r.ok, isFalse);
      expect(r.errorCode, 119);
    });

    test('两条分支的 MIME 都不在 JSON 名单里（不会把字节当错误信封吞掉）', () {
      // 与客户端 `_isBinaryContentType` 的口径对齐：image/* 与 text/plain
      // 一个直通、一个先缓冲再判；两者都**不许**是 application/json。
      for (final p in const ['/photo/mockfs_album/sample.jpg', '/home/mockfs_home.txt']) {
        final r = raw(p);
        expect(r.contentType.startsWith('application/json'), isFalse);
      }
    });
  });
}
