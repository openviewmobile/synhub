// 文件缓存（FileStore）的离线验证。
//
// 重点不是"能存"，而是**缓存一致性**：整桶替换后，服务端删掉的文件不能留在本地；
// 重命名后本地不能还显示旧名。这类 bug 在真机上表现为"删了还在"，很难查。
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/local/file_store.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/file_providers.dart';

void main() {
  late ChatDatabase db;
  late FileStore store;

  setUp(() {
    db = ChatDatabase(NativeDatabase.memory());
    store = FileStore(db);
  });

  tearDown(() => db.close());

  FileEntryDto entry(
    String name, {
    String? parent = '/home',
    bool isDir = false,
    int size = 0,
  }) =>
      FileEntryDto(name: name, path: '$parent/$name', isDir: isDir, size: size);

  test('replaceFolder：写入、按目录分桶、目录排前面', () async {
    await store.replaceFolder('/home', [
      entry('b.txt'),
      entry('Photos', isDir: true),
      entry('a.txt'),
    ]);
    await store.replaceFolder('/docker', [
      entry('compose.yml', parent: '/docker'),
    ]);

    final home = await store.folder('/home');
    expect(home.map((e) => e.name), [
      'Photos',
      'a.txt',
      'b.txt',
    ], reason: '目录在前，其余按名称');
    expect(await store.folder('/docker'), hasLength(1));
    expect(await store.folder('/home').then((r) => r.first.isDir), isTrue);
  });

  test('replaceFolder：服务端删掉的文件不会留在缓存里', () async {
    await store.replaceFolder('/home', [entry('a.txt'), entry('b.txt')]);
    expect(await store.folder('/home'), hasLength(2));

    // 下一次刷新只剩 a.txt
    await store.replaceFolder('/home', [entry('a.txt')]);
    expect((await store.folder('/home')).map((e) => e.name), ['a.txt']);
    expect(await store.entry('/home/b.txt'), isNull);
  });

  test('replaceFolder：空列表会清空该目录（不是"什么都不做"）', () async {
    await store.replaceFolder('/home', [entry('a.txt')]);
    await store.replaceFolder('/home', const []);
    expect(await store.folder('/home'), isEmpty);
  });

  test('additional 里的字段能往返（perm/owner/mtime/挂载点）', () async {
    await store.replaceFolder('/home', [
      FileEntryDto(
        name: 'Photos',
        path: '/home/Photos',
        isDir: true,
        mtime: 1758100000,
        crtime: 1758000000,
        owner: 'demo_user',
        group: 'users',
        realPath: '/volume1/homes/demo_user/Photos',
        mountPointType: 'shared_folder',
        canRead: true,
        canWrite: true,
        canExecute: true,
        disableDownload: true,
        isWormShare: true,
      ),
    ]);

    final e = (await store.folder('/home')).single;
    expect(e.owner, 'demo_user');
    expect(e.group, 'users');
    expect(e.mtime, 1758100000);
    expect(e.crtime, 1758000000);
    expect(e.realPath, '/volume1/homes/demo_user/Photos');
    expect(e.mountPointType, 'shared_folder');
    expect(e.isMountPoint, isTrue);
    expect(e.canWrite, isTrue);
    expect(e.disableDownload, isTrue);
    expect(e.isWormShare, isTrue);
    expect(e.modifiedAt, isNotNull);
  });

  test('worm_state 经缓存表往返：锁定态读回来仍是锁定（不是恒 false）', () async {
    await store.replaceFolder('/home', const [
      // 线上是 0..9 的下标：4=IMMUTABLE_LOCKED、5=APPENDABLE_LOCKED、
      // 8/9=WEAK_*_LOCKED 都该判成锁定；3=OPEN、6=EXPIRED 不算。
      FileEntryDto(name: 'lock.txt', path: '/home/lock.txt', wormState: '4'),
      FileEntryDto(
        name: 'append.txt',
        path: '/home/append.txt',
        wormState: '5',
      ),
      FileEntryDto(name: 'weak.txt', path: '/home/weak.txt', wormState: '8'),
      FileEntryDto(name: 'open.txt', path: '/home/open.txt', wormState: '3'),
      FileEntryDto(
        name: 'expired.txt',
        path: '/home/expired.txt',
        wormState: '6',
      ),
      FileEntryDto(name: 'plain.txt', path: '/home/plain.txt'),
    ]);

    final lock = await store.entry('/home/lock.txt');
    expect(lock!.wormState, '4', reason: '原文要落库，不能只存推导结果');
    expect(lock.wormLocked, isTrue, reason: '以前缓存表没这列 → 恒 false');
    expect((await store.entry('/home/append.txt'))!.wormLocked, isTrue);
    expect((await store.entry('/home/weak.txt'))!.wormLocked, isTrue);
    expect((await store.entry('/home/open.txt'))!.wormLocked, isFalse);
    expect((await store.entry('/home/expired.txt'))!.wormLocked, isFalse);

    // 服务端没给 / 老数据缺失 → 未知，不拦（fail-open）
    final plain = await store.entry('/home/plain.txt');
    expect(plain!.wormState, isNull);
    expect(plain.wormLocked, isFalse);
  });

  test('watchFolder 会推送更新（UI 依赖这个）', () async {
    final seen = <List<String>>[];
    final sub = store.watchFolder('/home').listen((rows) {
      seen.add(rows.map((e) => e.name).toList());
    });
    await Future<void>.delayed(Duration.zero);
    await store.replaceFolder('/home', [entry('a.txt')]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await store.replaceFolder('/home', [entry('a.txt'), entry('b.txt')]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sub.cancel();

    expect(seen.last, ['a.txt', 'b.txt']);
  });

  test('renameEntry：本地缓存跟着改名（不会还显示旧名）', () async {
    await store.replaceFolder('/home', [entry('old.txt')]);
    await store.renameEntry('/home/old.txt', 'new.txt');

    expect(await store.entry('/home/old.txt'), isNull);
    final renamed = await store.entry('/home/new.txt');
    expect(renamed, isNotNull);
    expect(renamed!.name, 'new.txt');
    expect((await store.folder('/home')).map((e) => e.name), ['new.txt']);
  });

  test('removeEntries / clear / count', () async {
    await store.replaceFolder('/home', [entry('a.txt'), entry('b.txt')]);
    await store.removeEntries(['/home/a.txt']);
    expect(await store.count(), 1);
    await store.clear();
    expect(await store.count(), 0);
  });

  group('本地排序（缓存里的行序是插入序，必须自己排）', () {
    final rows = [
      const FileEntryDto(name: 'b.txt', path: '/b.txt', size: 20, mtime: 100),
      const FileEntryDto(name: 'Photos', path: '/Photos', isDir: true),
      const FileEntryDto(name: 'a.txt', path: '/a.txt', size: 10, mtime: 200),
      const FileEntryDto(name: 'Empty', path: '/Empty', isDir: true),
    ];

    test('名称升序：目录恒在前', () {
      final sorted = sortFileEntries(rows, const FileSortState());
      expect(sorted.map((e) => e.name), ['Empty', 'Photos', 'a.txt', 'b.txt']);
    });

    test('大小降序：目录仍在前（目录之间同向倒序），文件按大小倒序', () {
      final sorted = sortFileEntries(
        rows,
        const FileSortState(
          sortBy: FileSortBy.size,
          sortDirection: FileSortDirection.desc,
        ),
      );
      // 两个目录 size 都是 0 → 按名称倒序；文件同理
      expect(sorted.map((e) => e.name), ['Photos', 'Empty', 'b.txt', 'a.txt']);
    });

    test('修改时间升序', () {
      final sorted = sortFileEntries(
        rows,
        const FileSortState(sortBy: FileSortBy.mtime),
      );
      expect(sorted.map((e) => e.name), ['Empty', 'Photos', 'b.txt', 'a.txt']);
    });

    test('再点同一个键 → 方向翻转（与 DSM 网页一致）', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final notifier = c.read(fileSortProvider.notifier);
      notifier.setSortBy(FileSortBy.size);
      expect(c.read(fileSortProvider).sortDirection, FileSortDirection.asc);
      notifier.setSortBy(FileSortBy.size);
      expect(c.read(fileSortProvider).sortDirection, FileSortDirection.desc);
      notifier.setSortBy(FileSortBy.name);
      expect(c.read(fileSortProvider).sortBy, FileSortBy.name);
      expect(c.read(fileSortProvider).sortDirection, FileSortDirection.asc);
    });
  });

  group('错误文案（FileStation 的 401 不是"账号已停用"）', () {
    test('401/105 → 没有权限', () {
      expect(
        describeFileError(
          DsmApiException(401, method: 'SYNO.FileStation.List.list'),
        ),
        '没有权限访问该位置',
      );
      expect(
        describeFileError(
          DsmApiException(105, method: 'SYNO.FileStation.List.list'),
        ),
        '没有权限访问该位置',
      );
    });

    test('408 在文件模块是"路径不存在"，不是聊天里的"密码过期"', () {
      expect(
        describeFileError(
          DsmApiException(408, method: 'SYNO.FileStation.List.list'),
        ),
        contains('不存在'),
      );
      expect(
        describeFileError(
          DsmApiException(408, method: 'SYNO.FileStation.List.list'),
        ),
        isNot(contains('密码')),
      );
    });

    // DA10（r355 真机取证）：Drive 的 1003 与 FileStation 的 408 同义；
    // 修前它走 `apiUnknownErrorCode`，用户看到的是裸 `Error code 1003`。
    test('★ DA10b：Drive 的 1003 → 也是"目标不存在"，不许把裸错误码丢给用户', () {
      final msg = describeFileError(
        DsmApiException(
          DsmErrorCode.drivePathNotFound,
          method: 'SYNO.SynologyDrive.Files.list',
        ),
      );
      expect(msg, contains('不存在'));
      expect(msg, isNot(contains('1003')));
      expect(msg, isNot(contains('错误码')));
    });

    test('105 + Compress/Extract → 分开说是"没有压缩权限"/"没有解压权限"', () {
      // 真机：这台 NAS 上普通用户**能解压、不能压缩**，所以文案不能混成一句
      expect(
        describeFileError(
          DsmApiException(105, method: 'SYNO.FileStation.Compress.start'),
        ),
        contains('没有压缩权限'),
      );
      expect(
        describeFileError(
          DsmApiException(105, method: 'SYNO.FileStation.Extract.start'),
        ),
        contains('没有解压权限'),
      );
      // 其它接口的 105 还是通用的"没权限"
      expect(
        describeFileError(
          DsmApiException(105, method: 'SYNO.FileStation.Delete.delete'),
        ),
        '没有权限访问该位置',
      );
    });

    // ★★ r395 **就地订正**（这条用例原来断言的是错的）：
    //   旧断言写 `407 → 限流`，依据是"真机连打会命中"——但那次"连打"从未读到
    //   **服务端原始码**（r348/r369 台账都标着"根因留白"）。r395 拿到原文：
    //     List/list v2 {folder_path:"/teamdrivetest/#recycle"} → {"error":{"code":407}}
    //   而官方 FileStation **1.5.1-2410** 前端 `FileBrowserUtil.js` 的
    //   `getWebAPIErrStr`：`case 407: case 409: return error_privilege_not_enough`。
    //   ⇒ FileStation 的 407 是**权限**（重试永远不会好）；只有别的模块
    //     （如 `SYNO.API.Auth`）才按它自己的语义说。
    test('r395 订正：FileStation 的 407 → 权限不足（**不是**限流）', () {
      expect(
        describeFileError(
          DsmApiException(407, method: 'SYNO.FileStation.List.list'),
        ),
        '没有权限访问该位置',
      );
      // 反向：Auth 那边的 407 仍是它自己的语义，别被一刀切改掉
      expect(
        describeFileError(DsmApiException(407, method: 'SYNO.API.Auth.login')),
        '请求过于频繁，请稍后再试',
      );
    });

    test('102/103/104 → 服务或版本不可用', () {
      expect(
        describeFileError(DsmApiException(102, method: 'x')),
        '这台 NAS 没有开启文件服务',
      );
      expect(
        describeFileError(DsmApiException(104, method: 'x')),
        '这台 NAS 的文件服务版本不兼容',
      );
    });

    test('非 API 异常原样转字符串（不吞）', () {
      expect(describeFileError(StateError('boom')), contains('boom'));
    });
  });
}
