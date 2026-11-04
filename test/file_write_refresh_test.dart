// 第 299 轮真机缺陷（HUAWEI TET-AN00 + 真 NAS，2026-10-07）：
//
//   **压缩成功后，压缩包不出现在文件列表里。**
//
// 现场证据：任务中心显示「压缩 | 完成」，`SYNO.Finder` 全局搜索 `r298` 也能搜到
// `r298_end.zip`（2.0 MB，时间戳与源文件一致），可**文件列表里一直没有它** ——
// 离开目录再进来也没有（`folderSyncProvider` 是非 autoDispose 的
// `FutureProvider.family`，重进拿到的是缓存）、下拉手势也不刷，
// **只有 FAB →「刷新」才出现**（刷新后同一屏立刻列出 `r298_end.zip`）。
//
// 根因（一处遗漏）：`FileActionsController._refresh` 的注释里写着
// "同一个坑对 createFolder / delete / copyMove / extract 一样成立"——
// **`compress` 不在这个清单里，它根本没调 `_refresh`**。
//
// 顺带钉住的第二个同型问题：`copyMove` **只刷 `destFolderPath`**，移动时
// **源目录**会一直留着已经被搬走的行（第 298 轮真机实测：移动完成后
// `_r298_dst` 仍列着 `r298_renamed.png`，而任务中心已「移动 | 完成」）。
//
// 用例覆盖：
//   ① 压缩成功 → `destFilePath` 的父目录**立即**刷新（缓存出现 .zip、List 恰好 +1）；
//   ② 压缩失败 → **不刷新**（不制造假成功）；
//   ③ 移动成功 → 源目录与目标目录**都**刷新（钉"两边各发一次"这个机制量）；
//   ④ 反向验证：复制成功 → 源目录**不**刷新（copy 没动源目录，别多打一次请求）。
//
// 第 300 轮真机又实测到**同一族的第二例**（解压，`/home/r300wt.zip` → `/home/r300wt`）：
//   **解压完成后，点进那个"同名子目录"看到的是解压前的旧列表。**
// 现场证据：先删掉 `r300wt/inner` 再对该 zip 执行「解压到此处」，父目录 `/home`
// 的 mtime 变成解压时刻、`r300wt` 的 mtime 也变成解压时刻，可**点进 `r300wt` 仍显示
// 「这个文件夹是空的」**；按一次「刷新」后 `inner` 才出现（mtime 是包内原时间）。
// 根因：UI 传的 `destFolderPath` 是**当前目录**（`file_browse_page.dart` 的
// `destFolderPath: dir`），而 `createSubfolder: true` 下服务端**真正写入的是
// `<当前目录>/<压缩包同名目录>`**；`extract()` 只 `_refresh(destFolderPath)`
// ⇒ 那个子目录的 `folderSyncProvider` 缓存没作废。
//
//   ⑤ 解压成功 → 目标目录刷新**且**同名子目录的缓存被作废（作废后重拉恰好一次）。
//
// 用**普通 `test()`**（不是 `testWidgets`）：Drift 的 `NativeDatabase` 有真实
// 异步 I/O，在 widget 的 fake_async 区里会挂住。本文件只测控制器，不需要 pump。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/local/file_store.dart' show FileStore;
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/file_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// FileStation 能力表（压缩 / 复制移动都需要）
const _fsTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.FileStation.List': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.Compress': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.FileStation.CopyMove': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.FileStation.Extract': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

Map<String, dynamic> _file(String name, {String dir = '/home', int size = 0}) => {
  'name': name,
  'path': '$dir/$name',
  'isdir': false,
  'additional': {
    'size': size,
    'time': {'mtime': 1758100000},
    'perm': {
      'acl': {'read': true, 'write': true, 'exec': false},
    },
  },
};

/// 每个目录各自的列表内容；`null` 表示该目录还没被列过。
final Map<String, List<dynamic>> _listing = {};

/// `SYNO.FileStation.List.list` 按 `folder_path` 给不同内容
Map<String, dynamic>? _byFolder(Map<String, dynamic> params) {
  if (params['api'] != 'SYNO.FileStation.List') return null;
  if (params['method'] != 'list') return null;
  final files = _listing['${params['folder_path']}'] ?? const <dynamic>[];
  return {'files': files, 'total': files.length, 'offset': 0};
}

/// 对某个目录发出的 `List/list` 次数
int _listCountFor(FakeTransport t, String folder) => t.calls
    .where(
      (c) =>
          c['api'] == 'SYNO.FileStation.List' &&
          c['method'] == 'list' &&
          c['folder_path'] == folder,
    )
    .length;

Future<({ProviderContainer c, FakeTransport t, ChatDatabase db})> _boot() async {
  final t = FakeTransport({
    'SYNO.FileStation.List.list_share': {
      'shares': [
        {'name': 'home', 'path': '/home', 'isdir': true, 'additional': {}},
      ],
      'total': 1,
      'offset': 0,
    },
    'SYNO.FileStation.Compress.start': {'taskid': 'T-compress'},
    'SYNO.FileStation.CopyMove.start': {'taskid': 'T-copymove'},
    'SYNO.FileStation.Extract.start': {'taskid': 'T-extract'},
  }, {...FakeTransport.table, ..._fsTable});
  t.onCall = _byFolder;
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fileApiProvider.overrideWithValue(FileStationApi(api)),
    ],
  );
  return (c: c, t: t, db: db);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(_listing.clear);

  test('压缩成功 → destFilePath 的父目录立即刷新（缓存出现 .zip、List 恰好 +1）', () async {
    _listing['/home'] = [_file('a.txt', size: 3)];
    final b = await _boot();
    await b.c.read(folderSyncProvider('/home').future);
    expect(
      (await FileStore(b.db).watchFolder('/home').first).map((e) => e.name),
      ['a.txt'],
    );

    // 服务端那边压缩包已经生成（列表接口从此会回它）
    _listing['/home'] = [_file('a.txt', size: 3), _file('a.zip', size: 900)];
    final before = _listCountFor(b.t, '/home');

    await b.c
        .read(fileActionsProvider)
        .compress(paths: ['/home/a.txt'], destFilePath: '/home/a.zip');

    // **核心断言**：不重新 read provider、不手动刷新，缓存里就要有压缩包
    expect(
      (await FileStore(b.db).watchFolder('/home').first).map((e) => e.name),
      contains('a.zip'),
      reason: '压缩成功后必须主动失效并重拉 **destFilePath 的父目录**（第 299 轮真机缺陷）',
    );
    expect(
      _listCountFor(b.t, '/home') - before,
      1,
      reason: '一次压缩只该触发一次列表刷新（不引入请求风暴）',
    );
  });

  test('压缩失败 → 不刷新（不制造假成功）', () async {
    _listing['/home'] = [_file('a.txt', size: 3)];
    final b = await _boot();
    await b.c.read(folderSyncProvider('/home').future);
    final before = _listCountFor(b.t, '/home');
    b.t.failures['SYNO.FileStation.Compress.start'] = DsmErrorCode.noPermission;

    await expectLater(
      b.c
          .read(fileActionsProvider)
          .compress(paths: ['/home/a.txt'], destFilePath: '/home/a.zip'),
      throwsA(isA<DsmApiException>()),
    );

    expect(_listCountFor(b.t, '/home'), before, reason: '压缩失败**不得**刷新（否则会掩盖失败）');
    expect(
      (await FileStore(b.db).watchFolder('/home').first).map((e) => e.name),
      ['a.txt'],
    );
  });

  test('移动成功 → 源目录与目标目录**都**刷新', () async {
    _listing['/home/src'] = [_file('m.txt', dir: '/home/src', size: 7)];
    _listing['/home/dst'] = <dynamic>[];
    final b = await _boot();
    await b.c.read(folderSyncProvider('/home/src').future);
    await b.c.read(folderSyncProvider('/home/dst').future);
    final srcBefore = _listCountFor(b.t, '/home/src');
    final dstBefore = _listCountFor(b.t, '/home/dst');

    // 服务端：文件已经搬到 dst
    _listing['/home/src'] = <dynamic>[];
    _listing['/home/dst'] = [_file('m.txt', dir: '/home/dst', size: 7)];

    await b.c.read(fileActionsProvider).copyMove(
      paths: ['/home/src/m.txt'],
      destFolderPath: '/home/dst',
      move: true,
    );

    expect(
      _listCountFor(b.t, '/home/dst') - dstBefore,
      1,
      reason: '目标目录必须刷新',
    );
    expect(
      _listCountFor(b.t, '/home/src') - srcBefore,
      1,
      reason: '**移动**时源目录也必须刷新 —— 只刷目标会让源目录留着已经搬走的行'
          '（第 298 轮真机：`_r298_dst` 仍列着已 move 走的文件）',
    );
    expect(
      (await FileStore(b.db).watchFolder('/home/src').first).map((e) => e.name),
      isEmpty,
      reason: '源目录缓存里不该再留着已搬走的行',
    );
    expect(
      (await FileStore(b.db).watchFolder('/home/dst').first).map((e) => e.name),
      contains('m.txt'),
    );
  });

  // ★ 第 303 轮：`fileArchiveSubfolderName` 逐字对齐官方
  // `SYNO.webfm.utils.getZipName`（FileBrowserUtil.js）—— 它是「解压到同名
  // 文件夹」时 `dest_folder_path` 末段的唯一来源，错一个字符目标目录就错。
  group('第 303 轮 fileArchiveSubfolderName（官方 getZipName 语义）', () {
    test('普通单扩展名：去掉最后一层', () {
      expect(fileArchiveSubfolderName('/home/r303wt/r303secret.zip'), 'r303secret');
      expect(fileArchiveSubfolderName('/a/b/photo.7z'), 'photo');
      expect(fileArchiveSubfolderName('/a/b/c.txt.bz2'), 'c.txt',
          reason: '只有紧跟 tar 的压缩后缀才再去一层（官方判据是 tar）');
    });

    test('双扩展名 .tar.gz / .tar.bz2 / .tar.xz：再去一层', () {
      expect(fileArchiveSubfolderName('/a/b/pkg.tar.gz'), 'pkg');
      expect(fileArchiveSubfolderName('/a/b/pkg.tar.bz2'), 'pkg');
      expect(fileArchiveSubfolderName('/a/b/pkg.TAR.GZ'), 'pkg',
          reason: '官方用 toLowerCase() 比较 tar');
    });

    test('反向验证：无扩展名 / 隐藏文件 → null（不许编出一个目录名）', () {
      expect(fileArchiveSubfolderName('/a/b/README'), isNull);
      expect(fileArchiveSubfolderName('/a/b/.zip'), isNull);
      expect(fileArchiveSubfolderName('.zip'), isNull);
    });
  });

  test('反向验证：复制成功 → 源目录**不**刷新（copy 没动源目录，别多发请求）', () async {
    _listing['/home/src'] = [_file('c.txt', dir: '/home/src', size: 5)];
    _listing['/home/dst'] = <dynamic>[];
    final b = await _boot();
    await b.c.read(folderSyncProvider('/home/src').future);
    await b.c.read(folderSyncProvider('/home/dst').future);
    final srcBefore = _listCountFor(b.t, '/home/src');
    final dstBefore = _listCountFor(b.t, '/home/dst');

    _listing['/home/dst'] = [_file('c.txt', dir: '/home/dst', size: 5)];

    await b.c.read(fileActionsProvider).copyMove(
      paths: ['/home/src/c.txt'],
      destFolderPath: '/home/dst',
      move: false,
    );

    expect(
      _listCountFor(b.t, '/home/dst') - dstBefore,
      1,
      reason: '目标目录必须刷新',
    );
    expect(
      _listCountFor(b.t, '/home/src') - srcBefore,
      0,
      reason: '**复制**不动源目录，不该为它多发一次 List（反向验证 `if (move)` 这个判据）',
    );
  });

  test('解压成功 → 请求目标是「同名子目录」本身，父目录刷新、目标缓存作废（第 303 轮修复）', () async {
    _listing['/home'] = [_file('r300wt.zip', size: 324)];
    _listing['/home/r300wt'] = <dynamic>[];
    final b = await _boot();
    // 先把这个同名子目录读**热**（模拟用户之前已经进过它，缓存里是空列表）
    await b.c.read(folderSyncProvider('/home/r300wt').future);
    final homeBefore = _listCountFor(b.t, '/home');
    final subBefore = _listCountFor(b.t, '/home/r300wt');

    // 服务端解压完成：同名子目录里出现了包内的 `inner/`
    _listing['/home/r300wt'] = [
      {
        'name': 'inner',
        'path': '/home/r300wt/inner',
        'isdir': true,
        'additional': {},
      },
    ];

    await b.c.read(fileActionsProvider).extract(
          filePath: '/home/r300wt.zip',
          destFolderPath: '/home',
        );

    // ★★ **核心机制量**（第 303 轮真机根因）：官方 `ExtractNoDialog` 在
    // "解压到同名文件夹"时**客户端自己**把 `dest_folder_path` 算成那个子目录，
    // `create_subfolder: true` 只是让服务端把它建出来。此前我们发的是父目录
    // ⇒ 服务端"目标已存在"、什么都不建，产物落回当前目录并在重名时静默跳过
    // （真机：任务「完成/没有错误」，但目录里始终没有那个同名文件夹）。
    final extractReq = b.t.calls.lastWhere(
      (c) => c['api'] == 'SYNO.FileStation.Extract' && c['method'] == 'start',
    );
    expect(
      extractReq['dest_folder_path'],
      '/home/r300wt',
      reason: '必须是 `<当前目录>/<包名去扩展名>`（官方 getZipName 语义），'
          '不是当前目录本身',
    );
    expect(extractReq['create_subfolder'], true);

    expect(
      _listCountFor(b.t, '/home') - homeBefore,
      1,
      reason: '父目录（当前目录 /home）必须刷新 —— 那个新建出来的同名子目录要出现在这里',
    );
    // 用户点进那个同名子目录 ⇒ 页面在这里 watch/read 一次（这一步是**用户动作**，
    // 不是"手动刷新"）。修复前 provider 没被作废 ⇒ 这里拿到**缓存里的空列表**、
    // 一次 List 都不会发；修复后才会重新拉取并把解压产物写进缓存。
    await b.c.read(folderSyncProvider('/home/r300wt').future);

    // **核心断言**：同名子目录的缓存里要有解压产物
    expect(
      (await FileStore(b.db).watchFolder('/home/r300wt').first)
          .map((e) => e.name),
      contains('inner'),
      reason: '解压产物落在**同名子目录**里；不 invalidate 这个目标目录，'
          '用户点进去只会看到解压前的旧列表（第 300 轮真机现象的**正确**归因是'
          '"目标路径发错了"，不是"缓存没作废"）',
    );
    expect(
      _listCountFor(b.t, '/home/r300wt') - subBefore,
      1,
      reason: '作废之后重拉恰好一次（别把 invalidate 写成循环刷新）',
    );
  });
}
