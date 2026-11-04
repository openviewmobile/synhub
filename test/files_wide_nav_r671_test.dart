// r671（`DA297` / `DA298`）：宽屏文件站的**两条用户手测反馈**。
//
// 用户 2026-10-28 原话："打开文件不能直接打开会出现一个中间页面，
// 这个页面无返回到上级父目录"。拆成两条机制量：
//
// | # | 缺陷 | 机制量 | 判据 |
// |---|---|---|---|
// | `DA298` | 打开文件要两跳（单击只填右栏 ⇒ 再点「打开预览」） | 宽屏左列表行挂 `onDoubleTap` ⇒ 直接走窄屏同一条打开路径 | 双击 ⇒ `Navigator` 计数 **+1** 且栈顶 `FilePreviewPage`；**单击 ⇒ 计数不变**（仍是选中） |
// | `DA297` | 那个中间页面（右栏文件详情卡）**没有回父目录入口** | 详情卡与目录列表吃**同一套** `_PaneHeader` | 详情里有 `file-wide-header` ＋ `file-wide-up`；点上去 ⇒ 右栏换成父目录列表；根下文件（路径只有一段）**不摆** up（不摆假控件） |
//
// ★ 判据钉**行为**（路由计数 / 右栏换成了哪个目录），不钉"某个图标像素在不在"。
// ★ 反向验证（本轮已做，记录在此）：把 `_FileWideDetail` 的 `_PaneHeader` 段删掉
//   ⇒ §2 第一条红；把 `onDoubleTap` 从 `FileRow` 透传里去掉 ⇒ §1 第一条红。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_entry_dto.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/drive_providers.dart';
import 'package:synhub/src/features/files/file_browse_page.dart';
import 'package:synhub/src/features/files/file_preview_page.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/files/file_wide_pane.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.FileStation.List': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
};

Map<String, dynamic> _entry(String name, {bool dir = false}) => {
  'name': name,
  'path': '/home/$name',
  'isdir': dir,
  'additional': {
    'size': dir ? 0 : 12,
    'time': {'mtime': 1758100000},
    'perm': {
      'acl': {'read': true, 'write': true, 'exec': false},
    },
  },
};

class _RouteCounter extends NavigatorObserver {
  final List<Route<dynamic>> pushes = <Route<dynamic>>[];

  int get count => pushes.length;

  Route<dynamic>? get top => pushes.isEmpty ? null : pushes.last;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes.add(route);
    super.didPush(route, previousRoute);
  }
}

/// 起一个真的 `FileBrowsePage`（NAS 源，起始目录 `/home`：一个目录 + 一个文件）。
Future<_RouteCounter> _pumpPage(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    if (key == 'SYNO.FileStation.List.list') {
      final path = '${params['folder_path'] ?? ''}';
      final files = path == '/home/docs'
          ? [_entry('inner.txt')]
          : [_entry('docs', dir: true), _entry('a.txt')];
      return {
        'success': true,
        'files': files,
        'total': files.length,
        'offset': 0,
      };
    }
    return {'success': true};
  };
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fileApiProvider.overrideWithValue(FileStationApi(api)),
      driveApiProvider.overrideWithValue(DriveApi(api)),
    ],
  );
  addTearDown(() async => db.close());
  addTearDown(c.dispose);

  final nav = _RouteCounter();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        navigatorObservers: [nav],
        home: const FileBrowsePage(initialPath: '/home'),
      ),
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  var n = 0;
  while (n < 60 && tester.takeException() != null) {
    n++;
  }
  return nav;
}

/// 直接起**右栏本身**（详情卡 / 目录列表都在这里），只用来量"回父目录"。
Future<void> _pumpPane(
  WidgetTester tester,
  WideSelection selection, {
  void Function(WideSelection)? onSelect,
  VoidCallback? onUp,
}) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final c = ProviderContainer();
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Scaffold(
          body: FileWidePane(
            selection: selection,
            onSelect: onSelect,
            onUp: onUp,
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 200));
  var n = 0;
  while (n < 60 && tester.takeException() != null) {
    n++;
  }
}

FileEntryDto _file(String path) => FileEntryDto(
  name: path.split('/').last,
  path: path,
  isDir: false,
  permKnown: true,
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('§1 DA298 宽屏双击 = 直接打开（不再要「选中→详情→打开」两跳）', () {
    testWidgets('双击文件行 ⇒ 直接进预览页（路由 +1，栈顶 FilePreviewPage）', (tester) async {
      final nav = await _pumpPage(tester, const Size(800, 600));
      final before = nav.count;
      // ★ 必须限定在**左栏**里找那一行：第一次点之后右栏详情卡上也有同一个
      //   文件名（那是 `Text`，不是行）⇒ 裸 `find.text` 会变成两个目标。
      Finder row() => find.descendant(
        of: find.byKey(const Key('file-wide-master')),
        matching: find.text('a.txt'),
      );
      expect(row(), findsOneWidget, reason: '前提：左栏应该列出 a.txt');

      await tester.tap(row());
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(row());
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 400));

      expect(nav.count, before + 1, reason: '双击必须直接打开预览（中间页面不再是唯一路径）');
      expect(nav.top, isA<MaterialPageRoute<void>>());
      expect(
        find.byType(FilePreviewPage),
        findsOneWidget,
        reason: '打开的必须是既有预览页（不是第二套打开实现）',
      );
    });

    testWidgets('同一行**慢慢再点一次**也直接打开（不靠时间窗：真机每下点击 ≈1.5 s）', (tester) async {
      // ★ 为什么必须有这条：真机走查的 `tester.tap` 两下之间实测 ≈2975 ms
      //   （每一下自带一帧往返）⇒ 500ms 时间窗在仪器里**永远量不到**。
      //   所以"右栏正在显示的那一条再点一次 = 打开"必须是**独立判据**。
      final nav = await _pumpPage(tester, const Size(800, 600));
      Finder row() => find.descendant(
        of: find.byKey(const Key('file-wide-master')),
        matching: find.text('a.txt'),
      );
      final before = nav.count;
      await tester.tap(row());
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump(const Duration(seconds: 2));
      expect(nav.count, before, reason: '前提：第一下只是选中');
      await tester.tap(row());
      await tester.pump(const Duration(milliseconds: 400));
      expect(nav.count, before + 1, reason: '再点一次已选中的文件必须打开');
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.byType(FilePreviewPage), findsOneWidget);
    });

    testWidgets('单击文件行 ⇒ 仍然只是选中（路由计数不变）', (tester) async {
      final nav = await _pumpPage(tester, const Size(800, 600));
      final before = nav.count;
      await tester.tap(find.text('a.txt'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(nav.count, before, reason: '单击选中不许偷偷推路由（r284 口径）');
      expect(find.byType(FilePreviewPage), findsNothing);
    });
  });

  group('§2 DA297 详情卡必须有回父目录的入口', () {
    testWidgets('文件详情有头部与「上一级」，点上去 ⇒ 右栏换成父目录（r673 起是父目录的信息卡）', (tester) async {
      WideSelection? picked;
      await _pumpPane(
        tester,
        WideSelection(entry: _file('/home/a.txt')),
        onSelect: (s) => picked = s,
      );

      expect(
        find.byKey(const Key('file-wide-detail')),
        findsOneWidget,
        reason: '前提：文件选中 ⇒ 右栏是详情卡',
      );
      expect(
        find.byKey(const Key('file-wide-header')),
        findsOneWidget,
        reason: 'DA297：详情卡必须有头部（原来根本没有这一行）',
      );
      final up = find.byKey(const Key('file-wide-up'));
      expect(up, findsOneWidget, reason: 'DA297：必须能回上一级');

      await tester.tap(up);
      await tester.pump(const Duration(milliseconds: 200));

      expect(picked, isNotNull, reason: '点「上一级」要把父目录填回右栏');
      expect(picked!.entry.path, '/home');
      expect(picked!.entry.isDir, isTrue);
    });

    testWidgets('面包屑可点：点祖先段 ⇒ 填回那个祖先目录', (tester) async {
      WideSelection? picked;
      await _pumpPane(
        tester,
        WideSelection(entry: _file('/home/docs/a.txt')),
        onSelect: (s) => picked = s,
      );
      // `/home/docs/a.txt` 的父级是 `/home/docs` ⇒ 面包屑两段 home / docs
      final crumb = find.byKey(const Key('file-wide-crumb-0'));
      expect(crumb, findsOneWidget, reason: '父级路径要能逐段点回去');
      await tester.tap(crumb);
      await tester.pump(const Duration(milliseconds: 200));
      expect(picked?.entry.path, '/home');
    });

    testWidgets('根下的文件（路径只有一段）不摆「上一级」——不摆假控件', (tester) async {
      await _pumpPane(tester, WideSelection(entry: _file('/x.txt')));
      expect(find.byKey(const Key('file-wide-detail')), findsOneWidget);
      expect(
        find.byKey(const Key('file-wide-up')),
        findsNothing,
        reason: '已经在根：没有父目录可回，就不许摆一个点了没用的按钮',
      );
    });

    testWidgets('Drive 源文件详情：上一级走调用方 Drive 栈（onUp 回调）', (tester) async {
      var upCalls = 0;
      WideSelection? picked;
      await _pumpPane(
        tester,
        WideSelection(
          entry: _file('/mydrive/a.txt'),
          drive: const DriveEntryDto(
            fileId: 'd2',
            name: 'a.txt',
            type: 'file',
            path: '/mydrive/a.txt',
            displayPath: '/mydrive/a.txt',
            parentId: 'p1',
            size: 12,
            modifiedTime: 1700000000,
            createdTime: 1700000000,
            contentType: 'text/plain',
            starred: false,
            shared: false,
            owner: 'me',
            canDownload: true,
            canPreview: true,
            canWrite: true,
            capabilities: <String, dynamic>{},
          ),
        ),
        onSelect: (s) => picked = s,
        onUp: () => upCalls++,
      );
      final up = find.byKey(const Key('file-wide-up'));
      expect(up, findsOneWidget, reason: 'Drive 源也要能回上一级');
      await tester.tap(up);
      await tester.pump(const Duration(milliseconds: 200));
      expect(upCalls, 1, reason: 'Drive 的父目录要服务端 parentId ⇒ 必须交回调用方栈');
      expect(picked, isNull, reason: '不许自己瞎造 Drive 父目录 selection');
    });
  });
}
