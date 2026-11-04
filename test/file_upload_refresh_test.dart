// R6 缺陷 3：**上传成功后列表不刷新**（真机观察到 snackbar「已上传 …」后看不到
// 新文件，必须冷启动才进 `FileStation.List` 结果，期间 sqlite mtime 也不更新）。
//
// 根因：`FileActionsController._refresh` 只 `ref.read(folderSyncProvider(path).future)`
// —— `folderSyncProvider` 是非 autoDispose 的 `FutureProvider.family`，一旦解析过，
// 读 `.future` 只拿**缓存结果**、不会再发请求。修法：先 `ref.invalidate` 再读。
//
// 覆盖：
//   * 上传成功 → **不冷启动**即可在缓存里看到新文件（List 恰好重发一次）；
//   * 上传失败 → **不刷新**、缓存不变、不显示假成功；
//   * 零回归：零新增请求风暴（一次上传最多一次 List 刷新）。
//
// 注意用**普通 `test()`**（不是 `testWidgets`）：Drift 的 `NativeDatabase` 有真实
// 异步 I/O，在 widget 的 fake_async 区里会挂住。本文件只测控制器，不需要 pump。
import 'dart:io';

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

/// FileStation 的能力表（含 Upload —— 上传用例必需）
const _fsTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
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
};

Map<String, dynamic> _file(String name, {int size = 0}) => {
  'name': name,
  'path': '/home/$name',
  'isdir': false,
  'additional': {
    'size': size,
    'time': {'mtime': 1758100000},
    'perm': {
      'acl': {'read': true, 'write': true, 'exec': false},
    },
  },
};

/// 根目录共享 + `/home` 列表
Map<String, Map<String, dynamic>> _homeResponses(List<dynamic> files) => {
  'SYNO.FileStation.List.list_share': {
    'shares': [
      {'name': 'home', 'path': '/home', 'isdir': true, 'additional': {}},
    ],
    'total': 1,
    'offset': 0,
  },
  'SYNO.FileStation.List.list': {
    'files': files,
    'total': files.length,
    'offset': 0,
  },
};

int _listCallCount(FakeTransport t) =>
    t.calls.where((c) => c['api'] == 'SYNO.FileStation.List').length;

/// 造一个已 discover + login 的容器（真实异步：Drift 内存库 + 假传输）
Future<({ProviderContainer c, FakeTransport t, ChatDatabase db})> _boot(
  List<dynamic> files,
) async {
  final t = FakeTransport(_homeResponses(files), {
    ...FakeTransport.table,
    ..._fsTable,
  });
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

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('flt_upload'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('上传成功 → 列表**不冷启动**即可看到新文件（List 恰好刷新一次）', () async {
    final b = await _boot([_file('a.txt')]);

    // 首次网络刷新：缓存里先只有 a.txt
    await b.c.read(folderSyncProvider('/home').future);
    final before = await FileStore(b.db).watchFolder('/home').first;
    expect(before.map((e) => e.name), ['a.txt']);

    // 模拟"上传完成后服务端列表里多出 new.txt"，并记录 List 调用数
    b.t.responses['SYNO.FileStation.List.list'] = {
      'files': [_file('a.txt'), _file('new.txt', size: 5)],
      'total': 2,
      'offset': 0,
    };
    final local = File('${tmp.path}/new.txt')..writeAsStringSync('hello');
    final listsBefore = _listCallCount(b.t);

    await b.c
        .read(fileActionsProvider)
        .upload(
          folderPath: '/home',
          localPath: local.path,
          fileName: 'new.txt',
        );

    // **核心断言**：不冷启动、不重新 read provider，缓存里就要有新文件
    final after = await FileStore(b.db).watchFolder('/home').first;
    expect(
      after.map((e) => e.name),
      contains('new.txt'),
      reason: '上传成功后必须主动失效并重拉目录缓存（R6 缺陷 3）',
    );
    expect(
      _listCallCount(b.t) - listsBefore,
      1,
      reason: '一次上传只该触发一次列表刷新（不引入重复请求风暴）',
    );
  });

  test('上传失败 → 不刷新列表、缓存不变（不显示假成功）', () async {
    final b = await _boot([_file('a.txt')]);

    await b.c.read(folderSyncProvider('/home').future);
    final local = File('${tmp.path}/bad.bin')..writeAsStringSync('x');
    final listsBefore = _listCallCount(b.t);
    // 上传接口回 105（无权限）→ 确定性失败
    b.t.failures['SYNO.FileStation.Upload.upload'] = DsmErrorCode.noPermission;

    await expectLater(
      b.c
          .read(fileActionsProvider)
          .upload(
            folderPath: '/home',
            localPath: local.path,
            fileName: 'bad.bin',
          ),
      throwsA(isA<DsmApiException>()),
    );

    expect(_listCallCount(b.t), listsBefore, reason: '上传失败**不得**刷新（否则会掩盖失败）');
    final rows = await FileStore(b.db).watchFolder('/home').first;
    expect(rows.map((e) => e.name), ['a.txt'], reason: '缓存不该被污染');
  });
}
