// M04 目录分页 / 懒加载（P0）—— 离线用例。
//
// 缺陷背景：`List/list` 支持 `offset`/`limit`，但浏览页以前写死
// `limit: 1000, offset: 0` 且不翻页 → **>1000 项的目录被服务端静默截断**，
// `FileListResult.hasMore` 没有任何 UI 消费。
//
// 这里用 FakeTransport 的 `onCall` 按请求里的 `offset`/`limit` **真的切片**
// （静态 responses 忽略参数，验不出翻页），断言三件事：
//   1. 1001 项目录能滚到底并拿全 1001 条（不许截断）；
//   2. 到底之后**不再发请求**（`hasMore=false` 收尾）；
//   3. 跨页重复 path 去重合并（DB 不出现重复行）。
// 另有 widget 用例验"触底自动续取 + 底部收尾态"。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/file_browse_page.dart';
import 'package:synhub/src/features/files/file_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _fsTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.FileStation.List': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.Sharing': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
};

Map<String, dynamic> _file(String name) => {
  'name': name,
  'path': '/home/$name',
  'isdir': false,
  'additional': {
    'size': 10,
    'time': {'mtime': 1758100000},
    'perm': {
      'acl': {'read': true, 'write': true, 'exec': false},
    },
  },
};

int _intOf(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

/// 造一个按 `offset`/`limit` 真切片的假服务端。
///
/// [overlap] > 0 时，第 2 页会**重复**上一页末尾的 [overlap] 条（模拟服务端
/// 排序不稳定），用来验去重合并。
FakeTransport _pagingTransport(int total, {int overlap = 0}) {
  final all = [for (var i = 0; i < total; i++) _file('f$i')];
  final t = FakeTransport({}, {...FakeTransport.table, ..._fsTable});
  t.onCall = (params) {
    if (params['api'] != 'SYNO.FileStation.List') return null;
    if (params['method'] == 'list_share') {
      return {
        'shares': [
          {'name': 'home', 'path': '/home', 'isdir': true, 'additional': {}},
        ],
        'total': 1,
        'offset': 0,
      };
    }
    if (params['method'] != 'list') return null;
    final offset = _intOf(params['offset']);
    final limit = _intOf(params['limit']);
    final start = offset == 0 ? 0 : (offset - overlap).clamp(0, all.length);
    final page = all.skip(start).take(limit).toList();
    return {'files': page, 'total': total, 'offset': offset};
  };
  return t;
}

Future<({FileStationApi fs, FakeTransport t, ChatDatabase db})> _boot(
  FakeTransport t,
) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  return (fs: FileStationApi(api), t: t, db: db);
}

ProviderContainer _container(
  FileStationApi fs,
  ChatDatabase db, {
  int? pageSize,
}) {
  final container = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fileApiProvider.overrideWithValue(fs),
      if (pageSize != null) filePageSizeProvider.overrideWithValue(pageSize),
    ].cast(),
  );
  addTearDown(container.dispose);
  return container;
}

int _listCalls(FakeTransport t) => t.calls
    .where((c) => c['api'] == 'SYNO.FileStation.List' && c['method'] == 'list')
    .length;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('1001 项目录：两页取全 1001 条，不许截断；到底后不再发请求', () async {
    final boot = await _boot(_pagingTransport(1001));
    final c = _container(boot.fs, boot.db);

    // 第一页
    await c.read(folderSyncProvider('/home').future);
    var paging = c.read(folderPagingProvider('/home'));
    expect(paging.total, 1001);
    expect(paging.loaded, 1000, reason: '首屏只取一页（1000）');
    expect(paging.hasMore, isTrue);

    var rows = await c.read(fileStoreProvider).folder('/home');
    expect(rows, hasLength(1000), reason: '第一页 1000 条');

    // 触底 → 第二页
    await c.read(folderPagingProvider('/home').notifier).loadMore();
    paging = c.read(folderPagingProvider('/home'));
    expect(paging.loaded, 1001, reason: '第二页 +1，必须拿全 1001（截断的话这里会是 1000）');
    expect(paging.reachedEnd, isTrue);
    expect(paging.hasMore, isFalse);

    rows = await c.read(fileStoreProvider).folder('/home');
    expect(rows.length, 1001, reason: '审计 P0：>1000 项被静默截断，这里必须 1001 而不许是 1000');

    // 到底之后 hasMore=false → 不再发请求
    final before = _listCalls(boot.t);
    await c.read(folderPagingProvider('/home').notifier).loadMore();
    expect(
      _listCalls(boot.t),
      before,
      reason: 'reachedEnd 后 loadMore 必须是 no-op，不得再发 List/list',
    );

    // 第二页请求真的带了 offset=1000
    final offsets = boot.t.calls
        .where(
          (c) => c['api'] == 'SYNO.FileStation.List' && c['method'] == 'list',
        )
        .map((c) => _intOf(c['offset']))
        .toList();
    expect(offsets, [0, 1000]);
  });

  test('跨页重复 path 去重合并：DB 不出现重复行', () async {
    final boot = await _boot(_pagingTransport(1001, overlap: 1));
    final c = _container(boot.fs, boot.db);

    await c.read(folderSyncProvider('/home').future);
    await c.read(folderPagingProvider('/home').notifier).loadMore();

    final rows = await c.read(fileStoreProvider).folder('/home');
    final paths = rows.map((e) => e.path).toSet();
    expect(rows, hasLength(paths.length), reason: 'upsert 必须按 path 去重');
    expect(rows, hasLength(1001));
  });

  test('服务端不给 total 时退化为单页：不凭空翻页', () async {
    final t = FakeTransport(
      {
        'SYNO.FileStation.List.list': {
          'files': [for (var i = 0; i < 3; i++) _file('f$i')],
          'offset': 0,
        },
      },
      {...FakeTransport.table, ..._fsTable},
    );
    final boot = await _boot(t);
    final c = _container(boot.fs, boot.db);

    await c.read(folderSyncProvider('/home').future);
    final paging = c.read(folderPagingProvider('/home'));
    expect(paging.total, 3);
    expect(paging.hasMore, isFalse);
    expect(paging.reachedEnd, isTrue);
  });

  testWidgets('触底自动续取到第二页，底部收尾成「没有更多了」', (tester) async {
    // ★ r293：窗口必须**真的**在 <700dp（单列）—— `setSurfaceSize` 不改
    //   `MediaQuery`（实测 `w=800`），只有 `tester.view` 才生效。
    //   取 420×420（原作者写的本来就是 420×420）：视口必须矮到"6 行放不下"，
    //   否则 `drag(-600)` 根本滚不动 ⇒ 触底续取不会触发。
    tester.view.physicalSize = const Size(420, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await _boot(_pagingTransport(8));
    final c = _container(boot.fs, boot.db, pageSize: 6);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(theme: AppTheme.dark(), home: FileBrowsePage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 进 /home（根只列共享）
    await tester.tap(find.text('home'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('f0'), findsOneWidget);
    // 首屏 6 条，还没到底 → 不该有收尾文案
    expect(find.byKey(const Key('file-no-more')), findsNothing);

    // 往上拖到底 → 触发 offset=6
    final list = find.byType(CustomScrollView);
    await tester.drag(list, const Offset(0, -600));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final offsets = boot.t.calls
        .where(
          (c) => c['api'] == 'SYNO.FileStation.List' && c['method'] == 'list',
        )
        .map((c) => _intOf(c['offset']))
        .toList();
    expect(offsets, contains(6), reason: '触底要发 offset=6 的第二页');

    // 到底 → 再拖到列表最底：收尾态出现且不再转圈。sliver 是懒构建，
    // footer 在视口外时 `find` 找不到，必须先把它滚进视口。
    boot.t.calls.clear();
    await tester.drag(list, const Offset(0, -600));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('file-no-more')), findsOneWidget);
    expect(find.byKey(const Key('file-page-loading')), findsNothing);

    // 到底后再拖也不该有新请求
    await tester.drag(list, const Offset(0, -400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_listCalls(boot.t), 0, reason: '到底后滚动不得再发请求');
    expect(tester.takeException(), isNull);
  });
}
