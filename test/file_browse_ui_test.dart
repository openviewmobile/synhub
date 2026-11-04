// 「文件」Tab 的界面验证：根目录 → 子目录 → 行操作。
//
// 用 `FakeTransport` 直接给 FileStation 的响应（不依赖 session 装配），
// 因为它能断言**请求参数**（folder_path / version / additional）——
// 文件模块最容易错的就是这些（`preferredVersion` 默认 1 的坑）。
import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/toolbar_actions.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/local/file_store.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/drive_providers.dart';
import 'package:synhub/src/features/files/file_browse_page.dart';
import 'package:synhub/src/core/media/thumb_cache.dart';
import 'package:synhub/src/features/files/file_download_resume.dart';
import 'package:synhub/src/features/files/file_download_tasks.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/files/file_row.dart';
import 'package:synhub/src/features/files/file_shortcut.dart';
import 'package:synhub/src/features/files/file_sheets.dart';
import 'package:synhub/src/features/shell/app_shell_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport, bootChat;

/// FileStation 的能力表（真机 `SYNO.API.Info` 的快照子集）
const _fsTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.FileStation.List': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.Info': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.CreateFolder': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.Rename': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.Delete': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.Favorite': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.Search': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.Sharing': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.FileStation.BackgroundTask': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.FileStation.VirtualFolder': {
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
  'SYNO.FileStation.DirSize': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  // P0-b：还原前查重（CheckExist/check）
  'SYNO.FileStation.CheckExist': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.Extract': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.Download': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  // 清空回收站（P0-a）：admin-only v1
  'SYNO.Core.RecycleBin': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

Map<String, dynamic> _file(String name, {bool isDir = false, int size = 0}) => {
  'name': name,
  'path': '/home/$name',
  'isdir': isDir,
  'additional': {
    'size': size,
    'time': {'mtime': 1758100000},
    'perm': {
      'acl': {'read': true, 'write': true, 'exec': false},
    },
  },
};

/// M72 测试用假桥：记录调用，按预设返回（不碰真实通道）。
class _FakeShortcutBridge implements ShortcutBridge {
  _FakeShortcutBridge({required this.result});

  final bool result;
  final List<({String id, String label, String path})> calls = [];

  @override
  Future<bool> pinShortcut({
    required String id,
    required String label,
    required String path,
  }) async {
    calls.add((id: id, label: label, path: path));
    return result;
  }
}

/// 1x1 真 PNG（缩略图测试用）
final _png1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

/// 造一个已 discover + login 的 FileStationApi
Future<({FileStationApi fs, FakeTransport t, ChatDatabase db})> _boot(
  Map<String, Map<String, dynamic>> responses, {
  Map<String, int> failures = const {},
  Map<String, Map<String, dynamic>>? table,
}) async {
  // 能力表要带上 FakeTransport 的那一份（里头有 SYNO.API.Encryption/登录相关），
  // 否则 discover() 之后的 login 会因为表里没有 Encryption 直接 102。
  final t = FakeTransport(responses, {
    ...FakeTransport.table,
    ...(table ?? _fsTable),
  });
  t.failures.addAll(failures);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  return (fs: FileStationApi(api), t: t, db: db);
}

/// 挂页面。
///
/// 用自己造的 `ProviderContainer` + `UncontrolledProviderScope`，**不在测试体内
/// dispose**（与 test/support/chat_harness.dart 的用法一致）：Drift 的流在容器
/// 销毁时会排一个 0ms 定时器，落在 fake_async 区里就会撞上
/// "A Timer is still pending even after the widget tree was disposed"。
Future<void> _pumpPage(
  WidgetTester tester,
  FileStationApi fs,
  ChatDatabase db, {
  List<Object> moreOverrides = const [],
}) async {
  final container = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fileApiProvider.overrideWithValue(fs),
      ...moreOverrides,
    ].cast(),
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), home: FileBrowsePage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

/// 根目录的共享列表 + `/home` 里的文件（新加的动作测试都要先"进 /home"）
/// `/home` 的列表夹具。
///
/// [recycle] = true 时**追加一条 `#recycle` 条目** —— 第 327 轮起这是给「回收站」
/// 入口的**唯一依据**（D27：本 NAS 实测 `/home`、`/docker` 的列表里没有 `#recycle`，
/// 直接访问回 408 ⇒ 无条件入口只会得到 "Target location not found" 错误页）。
Map<String, Map<String, dynamic>> _homeResponses(
  List<dynamic> files, {
  bool recycle = false,
}) => {
  'SYNO.FileStation.List.list_share': {
    'shares': [
      {'name': 'home', 'path': '/home', 'isdir': true, 'additional': {}},
    ],
    'total': 1,
    'offset': 0,
  },
  'SYNO.FileStation.List.list': {
    'files': [
      ...files,
      if (recycle)
        {
          'name': '#recycle',
          'path': '/home/#recycle',
          'isdir': true,
          'additional': {'size': 0, 'time': {}},
        },
    ],
    'total': files.length + (recycle ? 1 : 0),
    'offset': 0,
  },
};

/// 真·手机窗口（逻辑 420×1000，compact ⇒ **单列**）。
///
/// ★ **r293 修正（必须读）**：旧版写的是
/// `await tester.binding.setSurfaceSize(const Size(420, 1000))`，但
/// `setSurfaceSize` **不改变 `MediaQuery`** —— Flutter 3.47.4 实测：
/// `AdaptiveScaffold` 的探针打印 `w=800.000 h=600.000`，
/// 即便用例已经调用过 `setSurfaceSize(420,1000)`。也就是说这些用例
/// **一直跑在默认的 800dp 宽窗口**上。
/// r293 把双栏断点从 840 降到 700 后，800 ≥ 700 ⇒ 本页变**双栏**
/// ⇒ "点文件夹 = 左栏进目录 / 点行 = push 路由" 这些**单列前提被打破**
/// （本文件 23 条红）。`setSurfaceSize` 只影响渲染画布高度（那张底部
/// 弹层的注释是对的），**要改窗口宽度只能用 `tester.view`**。
///
/// 现在真的把窗口钉成 420×1000 ⇒ 断点裁定 = compact ⇒ 单列，
/// 与用例书写意图（"手机上的文件页"）一致；断言一条没放宽。
Future<void> _phoneSurface(WidgetTester tester) async {
  tester.view.physicalSize = const Size(420, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// 进某个目录（窄屏单击即进入；**宽屏 r673 起单击只选中**，第二下才进入）。
///
/// ★ r673：宽屏右栏从"第二级目录列表"改成**信息卡**，所以"点一下目录就把它的
///   内容拉进缓存"这条老路径**不再存在**。用例要量"进目录"就必须真的进 ——
///   否则量到的是右栏的副作用，而不是导航。
Future<void> _enterFolder(WidgetTester tester, String name) async {
  final expanded = find
      .byKey(const Key('file-wide-region'))
      .evaluate()
      .isNotEmpty;
  Finder row() => expanded
      ? find.descendant(
          of: find.byKey(const Key('file-wide-master')),
          matching: find.text(name),
        )
      : find.text(name);
  await tester.tap(row());
  await tester.pump();
  if (expanded) {
    await tester.tap(row());
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 300));
}

/// 点进 `/home`（根目录只列共享，不 list）
Future<void> _enterHome(WidgetTester tester) => _enterFolder(tester, 'home');

/// 某一行的「更多操作」按钮（缓存按"目录优先 + 名称"排序，不能靠 `.first`）。
Finder _rowMenu(String name) => find.descendant(
  of: find.ancestor(of: find.text(name), matching: find.byType(FileRow)),
  matching: find.byTooltip('更多操作'),
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('预览带的同级文件包含文本/PDF，不只是图片（规则与预览页同一份）', (tester) async {
    await _phoneSurface(tester); // r293：窗口必须真在 <700dp（单列）
    final boot = await _boot(
      _homeResponses([
        _file('a.dart', size: 98),
        _file('b.png', size: 2048),
        _file('c.png', size: 2048),
      ]),
    );
    await _pumpPage(tester, boot.fs, boot.db);
    await _enterHome(tester);
    // 点文本文件 → 预览页；此时同级可滑集合应该是 3 个（txt + 2 png）
    await tester.tap(find.text('a.dart').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.textContaining('1/3'),
      findsOneWidget,
      reason: '文本文件也参与左右滑，同级集合不能只剩图片',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('来源支持左右滑动：左滑到「我的 Drive」、右滑回「NAS 文件」', (tester) async {
    final t = FakeTransport(_homeResponses(const []), {
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
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(theme: AppTheme.dark(), home: FileBrowsePage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(c.read(fileSourceProvider), FileSource.nas);

    final pager = find.byKey(const Key('file-source-pager'));
    // 左滑 → 我的 Drive
    await tester.fling(pager, const Offset(-600, 0), 1200);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      c.read(fileSourceProvider),
      FileSource.drive,
      reason: '左滑应该切到 Drive 来源',
    );

    // 右滑 → 回 NAS 文件
    await tester.fling(pager, const Offset(600, 0), 1200);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.read(fileSourceProvider), FileSource.nas);
    expect(tester.takeException(), isNull);
  });

  testWidgets('根目录走 list_share，普通用户看不到 / 的 401', (tester) async {
    final boot = await _boot({
      'SYNO.FileStation.List.list_share': {
        'shares': [
          {'name': 'home', 'path': '/home', 'isdir': true, 'additional': {}},
          {'name': 'photo', 'path': '/photo', 'isdir': true, 'additional': {}},
        ],
        'total': 2,
        'offset': 0,
      },
    });
    await _pumpPage(tester, boot.fs, boot.db);

    // 请求的是 list_share，而不是 list(folder_path=/)
    final api = boot.t.calls
        .map((c) => '${c['api']}.${c['method']}')
        .where((s) => s.startsWith('SYNO.FileStation.List'))
        .toSet();
    expect(api, contains('SYNO.FileStation.List.list_share'));

    expect(find.text('home'), findsOneWidget);
    expect(find.text('photo'), findsOneWidget);
    // 面包屑的根显示成"共享文件夹"，不显示裸 '/'
    expect(find.text('共享文件夹'), findsWidgets);
  });

  // 真机（360dp 宽的 LG 手机）在标题行溢出过 20px —— 这里把小屏尺寸钉住，
  // 让以后再挤爆时离线就能发现（widget test 里溢出会直接算失败）。
  testWidgets('360dp 窄屏：文件页顶部不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boot = await _boot({
      'SYNO.FileStation.List.list_share': {
        'shares': [
          {
            'name': '一个名字很长的共享文件夹',
            'path': '/long-share',
            'isdir': true,
            'additional': {},
          },
        ],
        'total': 1,
        'offset': 0,
      },
    });
    await _pumpPage(tester, boot.fs, boot.db);
    expect(tester.takeException(), isNull);
    expect(find.text('一个名字很长的共享文件夹'), findsOneWidget);
  });

  testWidgets('点文件夹进入子目录，面包屑加一层，缓存也按目录分桶', (tester) async {
    final boot = await _boot({
      'SYNO.FileStation.List.list_share': {
        'shares': [
          {'name': 'home', 'path': '/home', 'isdir': true, 'additional': {}},
        ],
        'total': 1,
      },
      'SYNO.FileStation.List.list': {
        'files': [_file('a.txt', size: 12), _file('子目录', isDir: true)],
        'total': 2,
        'offset': 0,
      },
    });
    await _pumpPage(tester, boot.fs, boot.db);

    await _enterFolder(tester, 'home');

    expect(find.text('a.txt'), findsOneWidget);
    expect(find.text('子目录'), findsOneWidget);

    // 请求参数：folder_path = /home，且版本必须是显式协商出来的 2。
    // 用 `firstWhere`：浏览这一步的列举是最早的那次；文件夹封面（`folder_cover.dart`）
    // 之后会为屏幕上的每个子目录再各列一次（只看前 60 条找图，见那里的说明）。
    final call = boot.t.calls.firstWhere(
      (c) => c['api'] == 'SYNO.FileStation.List' && c['method'] == 'list',
    );
    expect(call['folder_path'], '/home');
    expect(
      call['version'],
      '2',
      reason: 'preferredVersion 默认 1 会漏掉 v2 的方法（服务端权威表）',
    );

    // 缓存分桶：根目录与 /home 互不污染
    final store = FileStore(boot.db);
    expect((await store.folder('/')).map((e) => e.name), ['home']);
    expect((await store.folder('/home')).map((e) => e.name), ['子目录', 'a.txt']);
  });

  // ★ 第 259 轮真机缺陷回归：进了子目录**回不去**。
  //
  // 现场：NAS 源进到 `/home/ebooktest` 后，头部没有任何"上一级"入口
  // （`FileBrowseStackNotifier.up()` 写好了但没人调），面包屑那行只有 30dp 高，
  // 真机上点不中；再按系统返回键**直接退出整个 App**（这一层是 tab 内状态，
  // 不是路由）⇒ 用户被"关在"深层目录里。
  //
  // 这个用例钉两件事：① 根目录**不出现**「上一级」（避免没用的按钮）；
  // ② 进子目录后出现，点一下回到上一级，而且**系统返回键**也先逐级返回。
  testWidgets('★ 子目录必须有「上一级」：按钮回退 + 系统返回键不退出 App', (tester) async {
    await _phoneSurface(tester); // r293：窗口必须真在 <700dp（单列）
    final boot = await _boot({
      'SYNO.FileStation.List.list_share': {
        'shares': [
          {'name': 'home', 'path': '/home', 'isdir': true, 'additional': {}},
        ],
        'total': 1,
      },
      'SYNO.FileStation.List.list': {
        'files': [_file('a.txt', size: 12), _file('子目录', isDir: true)],
        'total': 2,
        'offset': 0,
      },
    });
    await _pumpPage(tester, boot.fs, boot.db);

    // ① 根目录：没有「上一级」
    expect(find.byKey(const Key('file-up')), findsNothing);

    // ② 进子目录 → 出现；点它回到上一级（列表变回共享文件夹）
    await tester.tap(find.text('home'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('file-up')), findsOneWidget);

    await tester.tap(find.byKey(const Key('file-up')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('file-up')), findsNothing);
    expect(find.text('a.txt'), findsNothing, reason: '应已退回上一级');

    // ③ 系统返回键：在子目录里**不许**把整个 App 弹掉
    await tester.tap(find.text('home'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('a.txt'), findsOneWidget);

    final popped = await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    // 语义：`handlePopRoute()` 返回 **true = 这次返回被 App 消费掉**
    //（PopScope 的 `doNotPop` 也算"已处理"）；**false = 冒泡给系统
    // ⇒ 整个 App 退出**。所以这里必须是 true。
    expect(
      popped,
      isTrue,
      reason: '子目录里系统返回必须被 PopScope 消费（false = 冒泡给系统、App 退出）',
    );
    expect(find.text('a.txt'), findsNothing, reason: '返回键应退回上一级');
    expect(find.byKey(const Key('file-up')), findsNothing);
  });

  // 已收藏的文件在**行尾显示实心星**，点星直接取消收藏（用户问过"怎么删收藏"）
  testWidgets('已收藏的行带实心星，点一下 = 取消收藏', (tester) async {
    await _phoneSurface(tester); // r293：窗口必须真在 <700dp（单列）
    final boot = await _boot({
      'SYNO.FileStation.List.list_share': {
        'shares': [
          {'name': 'home', 'path': '/home', 'isdir': true, 'additional': {}},
        ],
        'total': 1,
      },
      'SYNO.FileStation.List.list': {
        'files': [_file('a.txt', size: 12)],
        'total': 1,
        'offset': 0,
      },
      'SYNO.FileStation.Favorite.list': {
        'favorites': [
          {
            'name': 'a.txt',
            'path': '/home/a.txt',
            'isdir': false,
            'status': 'valid',
          },
        ],
        'total': 1,
        'offset': 0,
      },
      'SYNO.FileStation.Favorite.delete': <String, dynamic>{},
    });
    await _pumpPage(tester, boot.fs, boot.db);
    await tester.tap(find.text('home'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 收藏状态是**第二跳**请求（先列目录、再列收藏）→ 要多给一帧才会重绘星标
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.star_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final del = boot.t.calls.lastWhere(
      (c) => c['api'] == 'SYNO.FileStation.Favorite' && c['method'] == 'delete',
      orElse: () => const {},
    );
    expect(del['path'], '["/home/a.txt"]');
    expect(find.text('已取消收藏'), findsOneWidget);
  });

  testWidgets('空文件夹显示空态，而不是骨架屏或错误页', (tester) async {
    final boot = await _boot({
      'SYNO.FileStation.List.list_share': {
        'shares': [
          {'name': 'empty', 'path': '/empty', 'isdir': true, 'additional': {}},
        ],
        'total': 1,
      },
      'SYNO.FileStation.List.list': {'files': [], 'total': 0, 'offset': 0},
    });
    await _pumpPage(tester, boot.fs, boot.db);

    await _enterFolder(tester, 'empty');

    expect(find.text('这个文件夹是空的'), findsOneWidget);
  });

  testWidgets('401 显示"没有权限访问该位置"（不是"账号已停用"）', (tester) async {
    await _phoneSurface(tester); // r293：窗口必须真在 <700dp（单列）
    final boot = await _boot(
      {
        'SYNO.FileStation.List.list_share': {
          'shares': [
            {'name': 'x', 'path': '/x', 'isdir': true, 'additional': {}},
          ],
          'total': 1,
        },
      },
      failures: {'SYNO.FileStation.List.list': 401},
    );
    await _pumpPage(tester, boot.fs, boot.db);

    await tester.tap(find.text('x'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('打不开这个位置'), findsOneWidget);
    expect(find.textContaining('没有权限访问该位置'), findsOneWidget);
    expect(find.textContaining('账号已停用'), findsNothing);
  });

  testWidgets('行菜单 → 重命名：调用 Rename 并刷新本地缓存', (tester) async {
    await _phoneSurface(tester); // r293：窗口必须真在 <700dp（单列）
    final boot = await _boot({
      'SYNO.FileStation.List.list_share': {
        'shares': [
          {'name': 'home', 'path': '/home', 'isdir': true, 'additional': {}},
        ],
        'total': 1,
      },
      'SYNO.FileStation.List.list': {
        'files': [_file('old.txt', size: 1)],
        'total': 1,
      },
      'SYNO.FileStation.Rename.rename': {'name': 'new.txt'},
    });

    // 先手动把缓存灌上，省一次点击
    final store = FileStore(boot.db);
    await store.replaceFolder('/home', const [
      FileEntryDto(name: 'old.txt', path: '/home/old.txt'),
    ]);
    await _pumpPage(tester, boot.fs, boot.db);
    await tester.pump(const Duration(milliseconds: 100));

    // 根目录点进 /home
    await tester.tap(find.text('home'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('old.txt'), findsOneWidget);

    // ★ r293：窗口真的变窄（420dp）后，**顶栏也会折叠出 `⋮`**
    //   （`adaptiveActions`，§2.0.10）⇒ `find.byIcon(Icons.more_vert).first`
    //   会点中**顶栏**那个而不是行菜单。行菜单一律按 tooltip「更多操作」定位。
    await tester.tap(_rowMenu('old.txt'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('重命名'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byType(TextField).first, 'new.txt');
    await tester.tap(find.text('重命名').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final rename = boot.t.calls.firstWhere((c) => c['method'] == 'rename');
    // 服务端要的是 **JSON 数组**（`path` 是路径列表，rename 也支持批量）
    expect(rename['path'], '["/home/old.txt"]');
    // `name` 同样是 JSON 数组（DSM 的 Rename 支持批量，位置与 path 一一对应）
    expect(rename['name'], '["new.txt"]');
    expect(await store.entry('/home/old.txt'), isNull);
    expect((await store.entry('/home/new.txt'))?.name, 'new.txt');
  });

  testWidgets('排序面板：进入目录后选"大小"，请求带上 sort_by=size', (tester) async {
    final boot = await _boot({
      'SYNO.FileStation.List.list_share': {
        'shares': [
          {'name': 'home', 'path': '/home', 'isdir': true, 'additional': {}},
        ],
        'total': 1,
      },
      'SYNO.FileStation.List.list': {
        'files': [_file('a.txt', size: 1), _file('b.txt', size: 2)],
        'total': 2,
      },
    });
    await _pumpPage(tester, boot.fs, boot.db);

    await _enterFolder(tester, 'home');
    // 先进入 /home：根目录走 list_share（它自带一个默认 sort_by=name），
    // 排序参数只有在 list 上才看得出来
    await tester.tap(find.text('home'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byTooltip('排序'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('大小'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final call = boot.t.calls.lastWhere(
      (c) => c['api'] == 'SYNO.FileStation.List' && c['method'] == 'list',
    );
    expect(call['sort_by'], 'size');
    expect(call['sort_direction'], 'asc');
  });

  testWidgets('外壳底栏：五个 tab，点「文件」切过去', (tester) async {
    // bootChat 会造一套完整的容器（内存库 + FakeTransport + 已登录的 api）；
    // FileStation 的能力表与响应按需补进去。
    FileStationApi? fs;
    final h = await bootChat(
      apiTable: {...FakeTransport.table, ..._fsTable},
      extra: {
        'SYNO.FileStation.List.list_share': {
          'shares': [
            {'name': 'home', 'path': '/home', 'isdir': true, 'additional': {}},
          ],
          'total': 1,
        },
      },
      moreOverrides: [fileApiProvider.overrideWith((ref) => fs)],
    );
    fs = FileStationApi(h.api);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(theme: AppTheme.dark(), home: AppShellPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    for (final label in ['聊天', '文件', '相册', '工作台', '我的']) {
      expect(find.text(label), findsWidgets, reason: '底栏要有 $label');
    }

    // 未选中时是描边图标，选中后换成实心 —— 用它判断 tab 真的切了
    await tester.tap(find.byIcon(Icons.folder_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.folder), findsOneWidget);
    expect(find.text('home'), findsOneWidget, reason: '文件 tab 应该已经拉到目录');
  });

  // 下面几条盯的是"面板返回动作名 → _runAction 真的发出对的请求"这一段。
  // 参数形态是最容易错的地方（path/name 都是 JSON 数组串）。
  group('行操作派发', () {
    testWidgets('删除：确认框 → Delete.start(path=JSON 数组) + 缓存同步移除', (tester) async {
      await _phoneSurface(tester);
      final boot = await _boot({
        ..._homeResponses([_file('a.txt', size: 10), _file('b.txt', size: 20)]),
        'SYNO.FileStation.Delete.start': <String, dynamic>{'taskid': 'D-1'},
      });
      await _pumpPage(tester, boot.fs, boot.db);
      await _enterHome(tester);
      final store = FileStore(boot.db);
      await store.replaceFolder('/home', [
        FileEntryDto.fromJson(_file('a.txt', size: 10)),
        FileEntryDto.fromJson(_file('b.txt', size: 20)),
      ]);
      await tester.pump();

      await tester.tap(find.byTooltip('更多操作').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 操作面板是限高 86% 的滚动面板，「删除」在最底下的危险区，
      // 面板内容全部建出来了但可能在屏幕外 → 先滚进可视区再点。
      await tester.ensureVisible(find.text('删除'));
      await tester.pump();
      await tester.tap(find.text('删除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600)); // 让面板完全退场
      // 删除成功后 `_refresh` 会**真的**重拉目录（R6 缺陷 3 的修法：先
      // invalidate 再读）。假服务端要像真服务端一样反映删除结果，否则重拉的
      // 陈旧响应会把 a.txt 又写回缓存。
      boot.t.responses['SYNO.FileStation.List.list'] = {
        'files': [_file('b.txt', size: 20)],
        'total': 1,
        'offset': 0,
      };
      // 危险确认框（点按钮本体，别点到还在动画里的面板）
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final del = boot.t.calls.lastWhere(
        (c) => c['method'] == 'start',
        orElse: () => const {},
      );
      expect(del['api'], 'SYNO.FileStation.Delete');
      expect(del['path'], '["/home/a.txt"]');
      // 缓存里也不该再有它
      expect((await store.folder('/home')).map((e) => e.name), ['b.txt']);
    });

    testWidgets('M18 复制到…：浏览式目录 picker（当前路径/进入/选中）→ '
        'CopyMove.start(path=JSON + dest_folder_path + remove_src=false)', (
      tester,
    ) async {
      await _phoneSurface(tester);
      final boot = await _boot({
        ..._homeResponses([
          _file('a.txt', size: 10),
          _file('Drive', isDir: true),
        ]),
        'SYNO.FileStation.CopyMove.start': {'taskid': 'CM1'},
      });
      await _pumpPage(tester, boot.fs, boot.db);
      await _enterHome(tester);

      // 取 a.txt 那一行的菜单（目录优先排序，不能靠 `.first` 拿文件行）
      await tester.tap(_rowMenu('a.txt'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('复制到…'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 目标选择器：初始停在源目录的父级（`/home` 的父级 = 根），
      // 根目录只列共享文件夹（`List/list_share`），且**只有目录**可选
      expect(
        (tester.widget<Text>(find.byKey(const Key('file-dest-current')))).data,
        '根目录',
      );
      expect(
        find.byKey(const Key('file-dest-entry-/home/a.txt')),
        findsNothing,
        reason: '文件不是可选目标',
      );

      // 根目录 → home → Drive（当前路径逐级更新）
      await tester.tap(find.byKey(const Key('file-dest-entry-/home')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        (tester.widget<Text>(find.byKey(const Key('file-dest-current')))).data,
        '/home',
      );
      await tester.tap(find.byKey(const Key('file-dest-entry-/home/Drive')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        (tester.widget<Text>(find.byKey(const Key('file-dest-current')))).data,
        '/home/Drive',
      );

      // 选中当前目录
      await tester.tap(find.byKey(const Key('file-dest-choose')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final move = boot.t.calls.lastWhere(
        (c) =>
            c['method'] == 'start' && c['api'] == 'SYNO.FileStation.CopyMove',
        orElse: () => const {},
      );
      expect(move['path'], '["/home/a.txt"]');
      expect(move['dest_folder_path'], '/home/Drive');
      expect(move['remove_src'], false);
    });

    testWidgets('M18 目标选择器：「上一级」回父目录、选中当前目录', (tester) async {
      await _phoneSurface(tester);
      final boot = await _boot({
        ..._homeResponses([
          _file('a.txt', size: 10),
          _file('Drive', isDir: true),
        ]),
        'SYNO.FileStation.CopyMove.start': {'taskid': 'CM2'},
      });
      await _pumpPage(tester, boot.fs, boot.db);
      await _enterHome(tester);

      await tester.tap(_rowMenu('a.txt'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('移动到…'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byKey(const Key('file-dest-entry-/home')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('file-dest-entry-/home/Drive')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        (tester.widget<Text>(find.byKey(const Key('file-dest-current')))).data,
        '/home/Drive',
      );

      // 上一级 → 回 /home
      await tester.tap(find.byKey(const Key('file-dest-up')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        (tester.widget<Text>(find.byKey(const Key('file-dest-current')))).data,
        '/home',
      );

      await tester.tap(find.byKey(const Key('file-dest-choose')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final move = boot.t.calls.lastWhere(
        (c) =>
            c['method'] == 'start' && c['api'] == 'SYNO.FileStation.CopyMove',
        orElse: () => const {},
      );
      expect(move['dest_folder_path'], '/home');
      expect(move['remove_src'], true, reason: '移动到… = 移动');
    });

    testWidgets('压缩：Compress.start 三件套 level/mode/format 都发', (tester) async {
      await _phoneSurface(tester);
      final boot = await _boot({
        ..._homeResponses([_file('a.txt', size: 10)]),
        'SYNO.FileStation.Compress.start': {'taskid': 'Z1'},
      });
      await _pumpPage(tester, boot.fs, boot.db);
      await _enterHome(tester);

      await tester.tap(find.byTooltip('更多操作').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('压缩'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField).last, 'a.zip');
      await tester.tap(find.text('开始压缩'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final zip = boot.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.FileStation.Compress',
        orElse: () => const {},
      );
      expect(zip['path'], '["/home/a.txt"]');
      expect(zip['dest_file_path'], '/home/a.zip');
      // ⚠️ 这里原先钉的是 `moderate`/`add` —— 那是**反推的臆测**，
      // 不是观测到的线上值。第 29 轮以官方 APK `arrays.xml` 的
      // `archive_compress_level_key`/`archive_update_mode_key` 定案为
      // `normal`/`replace`。⇒ **修正错误假设，不是迁就代码。**
      expect(zip['level'], 'normal');
      expect(zip['mode'], 'replace');
      expect(zip['format'], 'zip');
    });

    testWidgets(
      'M21 压缩更新模式：下拉选 update → Compress.start 的 mode=update（不是硬编码 add）',
      (tester) async {
        await _phoneSurface(tester);
        final boot = await _boot({
          ..._homeResponses([_file('a.txt', size: 10)]),
          'SYNO.FileStation.Compress.start': {'taskid': 'Z2'},
        });
        await _pumpPage(tester, boot.fs, boot.db);
        await _enterHome(tester);

        await tester.tap(find.byTooltip('更多操作').first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('压缩'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.enterText(find.byType(TextField).last, 'a.zip');

        // 打开更新模式下拉，选官方四值里的 update
        await tester.tap(find.byKey(const Key('compress-mode')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('更新（添加并替换）').last);
        await tester.pumpAndSettle();

        await tester.tap(find.text('开始压缩'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final zip = boot.t.calls.lastWhere(
          (c) => c['api'] == 'SYNO.FileStation.Compress',
          orElse: () => const {},
        );
        expect(
          zip['mode'],
          'update',
          reason: '下拉选中的 mode 必须透传到 Compress.start',
        );
        expect(zip['dest_file_path'], '/home/a.zip');
      },
    );

    testWidgets('M72 目录可「创建桌面快捷方式」：桥返回 true → 提示已请求', (tester) async {
      await _phoneSurface(tester);
      final bridge = _FakeShortcutBridge(result: true);
      final boot = await _boot({
        ..._homeResponses([_file('Drive', isDir: true)]),
      });
      await _pumpPage(
        tester,
        boot.fs,
        boot.db,
        moreOverrides: [shortcutBridgeProvider.overrideWithValue(bridge)],
      );
      await _enterHome(tester);

      await tester.tap(find.byTooltip('更多操作').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('创建桌面快捷方式'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(bridge.calls.single.path, '/home/Drive');
      expect(bridge.calls.single.label, 'Drive');
      expect(find.text('已请求创建快捷方式'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('M72 通道不可用（桥返回 false）→ 明确提示，不崩', (tester) async {
      await _phoneSurface(tester);
      final bridge = _FakeShortcutBridge(result: false);
      final boot = await _boot({
        ..._homeResponses([_file('Drive', isDir: true)]),
      });
      await _pumpPage(
        tester,
        boot.fs,
        boot.db,
        moreOverrides: [shortcutBridgeProvider.overrideWithValue(bridge)],
      );
      await _enterHome(tester);

      await tester.tap(find.byTooltip('更多操作').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('创建桌面快捷方式'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('这台设备不支持创建快捷方式'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('新建文件夹：CreateFolder.create(folder_path + name)', (
      tester,
    ) async {
      await _phoneSurface(tester);
      final boot = await _boot({
        ..._homeResponses(<dynamic>[]),
        'SYNO.FileStation.CreateFolder.create': {
          'folders': [
            {'name': '新目录', 'path': '/home/新目录', 'isdir': true},
          ],
        },
      });
      await _pumpPage(tester, boot.fs, boot.db);
      await _enterHome(tester);

      await tester.tap(find.byTooltip('新建 / 上传'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('新建文件夹'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField).last, '新目录');
      await tester.tap(find.text('创建'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final create = boot.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.FileStation.CreateFolder',
        orElse: () => const {},
      );
      expect(create['method'], 'create');
      expect(create['folder_path'], '/home');
      expect(create['name'], '新目录');
    });

    testWidgets('压缩被拒（105）→ 提示"账号没有压缩/解压权限"，不崩', (tester) async {
      await _phoneSurface(tester);
      final boot = await _boot(
        _homeResponses([_file('a.txt', size: 10)]),
        failures: {'SYNO.FileStation.Compress.start': 105},
      );
      await _pumpPage(tester, boot.fs, boot.db);
      await _enterHome(tester);

      await tester.tap(find.byTooltip('更多操作').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('压缩'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField).last, 'a.zip');
      await tester.tap(find.text('开始压缩'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('没有压缩权限'), findsOneWidget);
    });
  });

  group('缩略图视图（P0.1）', () {
    testWidgets('点「缩略图视图」→ 网格显示；图片格要真缩略图，文本格不要', (tester) async {
      await _phoneSurface(tester);
      final boot = await _boot(
        _homeResponses([_file('a.png', size: 2048), _file('b.txt', size: 10)]),
      );
      final asked = <String>[];
      final cache = ThumbCache(
        loader: (path, size) async {
          asked.add('$path|$size');
          return _png1x1;
        },
      );
      await _pumpPage(
        tester,
        boot.fs,
        boot.db,
        moreOverrides: [thumbCacheProvider.overrideWithValue(cache)],
      );
      await _enterHome(tester);

      // 默认是列表
      expect(find.byType(FileRow), findsWidgets);
      expect(find.byType(FileGridTile), findsNothing);

      await tapHeaderAction(tester, '切换为缩略图视图');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(FileGridTile), findsWidgets);
      expect(find.byType(FileRow), findsNothing);
      // 只有图片才去要缩略图；列表用 small、网格用 medium
      expect(
        asked.where((a) => a.startsWith('/home/b.txt')),
        isEmpty,
        reason: '文本文件不该请求缩略图',
      );
      expect(asked, contains('/home/a.png|small'));
      expect(asked, contains('/home/a.png|medium'));
      expect(find.byType(Image), findsWidgets);

      // 再点一下切回列表
      await tapHeaderAction(tester, '切换为列表视图');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(FileRow), findsWidgets);
      expect(find.byType(FileGridTile), findsNothing);
    });

    testWidgets('网格里长按仍能进多选', (tester) async {
      await _phoneSurface(tester);
      final boot = await _boot(_homeResponses([_file('a.png', size: 2048)]));
      await _pumpPage(
        tester,
        boot.fs,
        boot.db,
        moreOverrides: [
          thumbCacheProvider.overrideWithValue(
            ThumbCache(loader: (p, s) async => _png1x1),
          ),
        ],
      );
      await _enterHome(tester);
      await tapHeaderAction(tester, '切换为缩略图视图');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.longPress(find.byType(FileGridTile).first);
      await tester.pump();
      expect(find.textContaining('已选 1 项'), findsOneWidget);
    });
  });

  // ==================================================================
  // P0-a：上传同名冲突 / 回收站 #recycle / 分享链接
  // ==================================================================
  group('P0-a 上传同名冲突', () {
    testWidgets('冲突面板给 覆盖 / 重命名 / 跳过 三个选择，选谁返回谁', (tester) async {
      UploadConflictPolicy? picked;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    picked = await showUploadConflictSheet(
                      context,
                      fileName: 'a.txt',
                    );
                  },
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(find.text('同名文件已存在'), findsOneWidget);
      expect(find.text('覆盖'), findsOneWidget);
      expect(find.text('重命名'), findsOneWidget);
      expect(find.text('跳过'), findsOneWidget);

      await tester.tap(find.text('跳过'));
      await tester.pumpAndSettle();
      expect(picked, UploadConflictPolicy.skip, reason: '取消/未选不得回落成覆盖');
    });

    testWidgets('服务端不支持 rename 时面板不出现「重命名」（不给必失败入口）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showUploadConflictSheet(
                    context,
                    fileName: 'a.txt',
                    allowRename: false,
                  ),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('覆盖'), findsOneWidget);
      expect(find.text('重命名'), findsNothing);
      await tester.tap(find.text('覆盖'));
      await tester.pumpAndSettle();
    });
  });

  group('P0-a 回收站视图', () {
    Map<String, dynamic> recycleFile(String name) => {
      'name': name,
      'path': '/home/#recycle/$name',
      'isdir': false,
      'additional': {
        'size': 10,
        'time': {'mtime': 1758100000},
        'perm': {
          'acl': {'read': true, 'write': true, 'exec': false},
        },
      },
    };

    Future<({FileStationApi fs, FakeTransport t, ChatDatabase db})>
    bootRecycle({bool isManager = true}) async {
      final boot = await _boot({
        ..._homeResponses([_file('a.txt', size: 10)], recycle: true),
        'SYNO.FileStation.Info.get': {'is_manager': isManager},
        'SYNO.FileStation.CopyMove.start': {'taskid': 'R1'},
        'SYNO.FileStation.Delete.delete': <String, dynamic>{},
        'SYNO.Core.RecycleBin.start': <String, dynamic>{},
      });
      boot.t.onCall = (params) {
        if (params['api'] == 'SYNO.FileStation.List' &&
            params['method'] == 'list' &&
            params['folder_path'] == '/home/#recycle') {
          return {
            'files': [recycleFile('old.txt')],
            'total': 1,
            'offset': 0,
          };
        }
        return null;
      };
      return boot;
    }

    Future<void> enterRecycle(WidgetTester tester) async {
      await _enterHome(tester);
      await tapHeaderAction(tester, '回收站');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('还原：CopyMove.start + restore_from_recycle_bin，目标去掉 #recycle', (
      tester,
    ) async {
      await _phoneSurface(tester);
      final boot = await bootRecycle();
      await _pumpPage(tester, boot.fs, boot.db);
      await enterRecycle(tester);

      expect(find.text('回收站'), findsWidgets);
      await tester.tap(find.byTooltip('更多操作').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('永久删除'), findsOneWidget, reason: '回收站条目只给永久删除');
      await tester.ensureVisible(find.text('还原'));
      await tester.pump();
      await tester.tap(find.text('还原'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      // 确认框
      await tester.tap(find.widgetWithText(FilledButton, '还原'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final call = boot.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.FileStation.CopyMove',
        orElse: () => const {},
      );
      expect(call['method'], 'start');
      expect(call['restore_from_recycle_bin'], true);
      expect(call['remove_src'], true);
      expect(call['dest_folder_path'], '/home');
      expect(call['path'], '["/home/#recycle/old.txt"]');
    });

    // ★ D27（第 327 轮真机）：这是**唯一的反向端** —— 上面"还原/永久删除/清空"
    //   三条用例都是"列表里有 `#recycle` ⇒ 入口在"（正向端）。
    //   本 NAS 实测 `/home`、`/docker` 的列表里**都没有** `#recycle`，
    //   无条件入口点进去只有 "Target location not found"（`List/list('/home/#recycle')`
    //   → 408，见 `docs/device-readonly-verification-evidence-r16.md` §10）。
    test('D27 配套：`#recycle` 条目的图标是回收站（不是文件夹）', () {
      final recycle = FileEntryDto.fromJson({
        'name': '#recycle',
        'path': '/home/#recycle',
        'isdir': true,
        'additional': {'size': 0},
      });
      expect(
        fileIconFor(recycle),
        Icons.delete_outline,
        reason: '官方 ResourceItemFactory.isRecycleBin() 给它回收站图标',
      );
      // 反向：普通目录仍然是文件夹图标（别把判据写成"目录都不是图标"）
      final normal = FileEntryDto.fromJson({
        'name': 'Photos',
        'path': '/home/Photos',
        'isdir': true,
        'additional': {'size': 0},
      });
      expect(fileIconFor(normal), Icons.folder_rounded);
    });

    testWidgets('D27：列表里没有 `#recycle` ⇒ 不给「回收站」入口（假入口）', (tester) async {
      await _phoneSurface(tester);
      final boot = await _boot({
        // 默认夹具（`recycle: false`）= 与真机一致的"没有回收站条目"
        ..._homeResponses([_file('a.txt', size: 10)]),
        'SYNO.FileStation.Info.get': {'is_manager': true},
      });
      await _pumpPage(tester, boot.fs, boot.db);
      await _enterHome(tester);

      expect(
        find.text('#recycle'),
        findsNothing,
        reason: '夹具本身就不该有 `#recycle` 行（否则下面的判据失去意义）',
      );
      expect(
        await hasHeaderAction(tester, '回收站'),
        isFalse,
        reason: '服务端没列出 `#recycle` 就不许给入口 —— 点了必然得到错误页',
      );
      expect(
        await hasHeaderAction(tester, '清空回收站'),
        isFalse,
        reason: '不在回收站里，更不该有清空',
      );
    });

    testWidgets('永久删除：二次确认文案说明不可恢复 → Delete.delete', (tester) async {
      await _phoneSurface(tester);
      final boot = await bootRecycle();
      await _pumpPage(tester, boot.fs, boot.db);
      await enterRecycle(tester);

      await tester.tap(find.byTooltip('更多操作').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(find.text('永久删除'));
      await tester.pump();
      await tester.tap(find.text('永久删除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.textContaining('无法恢复'), findsOneWidget);
      // 确认之前不得发请求
      expect(
        boot.t.calls.where((c) => c['api'] == 'SYNO.FileStation.Delete'),
        isEmpty,
        reason: '永久删除必须先二次确认',
      );
      await tester.tap(find.widgetWithText(FilledButton, '永久删除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final call = boot.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.FileStation.Delete',
        orElse: () => const {},
      );
      expect(call['method'], 'delete', reason: '回收站内才用 Delete.delete（永久）');
      expect(call['path'], '["/home/#recycle/old.txt"]');
    });

    testWidgets('清空回收站：管理员可见 → 二次确认（说不可恢复）→ Core.RecycleBin.start', (
      tester,
    ) async {
      await _phoneSurface(tester);
      final boot = await bootRecycle();
      await _pumpPage(tester, boot.fs, boot.db);
      await enterRecycle(tester);

      expect(await hasHeaderAction(tester, '清空回收站'), isTrue);
      await tapHeaderAction(tester, '清空回收站');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('不可恢复'), findsOneWidget);
      expect(
        boot.t.calls.where((c) => c['api'] == 'SYNO.Core.RecycleBin'),
        isEmpty,
        reason: '清空回收站必须先二次确认',
      );
      await tester.tap(find.widgetWithText(FilledButton, '清空回收站'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final call = boot.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Core.RecycleBin',
        orElse: () => const {},
      );
      expect(call['method'], 'start');
      expect(call['id'], 'home');
    });

    testWidgets('非管理员：不显示「清空回收站」入口（不给必失败入口）', (tester) async {
      await _phoneSurface(tester);
      final boot = await bootRecycle(isManager: false);
      await _pumpPage(tester, boot.fs, boot.db);
      await enterRecycle(tester);
      expect(await hasHeaderAction(tester, '清空回收站'), isFalse);
    });
  });

  group('P0-a 冲突检测与重命名建议', () {
    test('indexedFileName 按官方拼 name-1.ext（不是 name (1).ext）', () {
      expect(indexedFileName('a.txt', {'a.txt'}), 'a-1.txt');
      expect(indexedFileName('a.txt', {'a.txt', 'a-1.txt'}), 'a-2.txt');
      expect(indexedFileName('noext', {'noext'}), 'noext-1');
      expect(indexedFileName('a.txt', {'b.txt'}), 'a.txt');
    });

    test('uploadConflictExists / suggestUploadName 用目标目录列表判定', () async {
      final boot = await _boot(
        _homeResponses([_file('a.txt', size: 10), _file('a-1.txt', size: 11)]),
      );
      final container = ProviderContainer(
        overrides: [fileApiProvider.overrideWithValue(boot.fs)],
      );
      addTearDown(container.dispose);
      final actions = container.read(fileActionsProvider);

      expect(
        await actions.uploadConflictExists(
          folderPath: '/home',
          fileName: 'a.txt',
        ),
        isTrue,
      );
      expect(
        await actions.uploadConflictExists(
          folderPath: '/home',
          fileName: 'new.txt',
        ),
        isFalse,
      );
      expect(
        await actions.suggestUploadName(folderPath: '/home', fileName: 'a.txt'),
        'a-2.txt',
      );
    });
  });

  group('P0-b 还原冲突 / 加密压缩 / 加密解压', () {
    Map<String, dynamic> recycleFile(String name) => {
      'name': name,
      'path': '/home/#recycle/$name',
      'isdir': false,
      'additional': {
        'size': 10,
        'time': {'mtime': 1758100000},
        'perm': {
          'acl': {'read': true, 'write': true, 'exec': false},
        },
      },
    };

    Future<({FileStationApi fs, FakeTransport t, ChatDatabase db})>
    bootRecycleWithConflicts({required bool conflict}) async {
      final boot = await _boot({
        ..._homeResponses([_file('a.txt', size: 10)], recycle: true),
        'SYNO.FileStation.Info.get': {'is_manager': true},
        'SYNO.FileStation.CopyMove.start': {'taskid': 'R9'},
        'SYNO.FileStation.CheckExist.check': {'exist': conflict},
      });
      boot.t.onCall = (params) {
        if (params['api'] == 'SYNO.FileStation.List' &&
            params['method'] == 'list' &&
            params['folder_path'] == '/home/#recycle') {
          return {
            'files': [recycleFile('old.txt')],
            'total': 1,
            'offset': 0,
          };
        }
        return null;
      };
      return boot;
    }

    Future<void> openRestore(WidgetTester tester) async {
      await _enterHome(tester);
      await tapHeaderAction(tester, '回收站');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byTooltip('更多操作').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(find.text('还原'));
      await tester.pump();
      await tester.tap(find.text('还原'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('还原冲突探测：目标已有同名 → 出覆盖/跳过面板，选覆盖前不发请求', (tester) async {
      await _phoneSurface(tester);
      final boot = await bootRecycleWithConflicts(conflict: true);
      await _pumpPage(tester, boot.fs, boot.db);
      await openRestore(tester);

      final check = boot.t.calls.lastWhere(
        (c) =>
            c['api'] == 'SYNO.FileStation.CheckExist' && c['method'] == 'check',
        orElse: () => const {},
      );
      expect(check['path'], '/home/old.txt', reason: '探测的是还原目标位置');
      expect(find.text('目标位置已有同名项目'), findsOneWidget);
      expect(find.text('覆盖'), findsOneWidget);
      expect(find.text('跳过'), findsOneWidget);
      expect(
        boot.t.calls.where((c) => c['api'] == 'SYNO.FileStation.CopyMove'),
        isEmpty,
        reason: '用户还没选之前不得直接覆盖',
      );

      await tester.tap(find.text('覆盖'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final call = boot.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.FileStation.CopyMove',
        orElse: () => const {},
      );
      expect(call['restore_from_recycle_bin'], true);
      expect(call['overwrite'], true, reason: '选覆盖 → overwrite=true');
    });

    testWidgets('还原冲突探测：选「跳过」→ overwrite=false（不覆盖既有文件）', (tester) async {
      await _phoneSurface(tester);
      final boot = await bootRecycleWithConflicts(conflict: true);
      await _pumpPage(tester, boot.fs, boot.db);
      await openRestore(tester);

      await tester.tap(find.text('跳过'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final call = boot.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.FileStation.CopyMove',
        orElse: () => const {},
      );
      expect(call['overwrite'], false);
    });

    testWidgets('无冲突时不弹冲突面板，走普通确认 → overwrite=false', (tester) async {
      await _phoneSurface(tester);
      final boot = await bootRecycleWithConflicts(conflict: false);
      await _pumpPage(tester, boot.fs, boot.db);
      await openRestore(tester);

      expect(find.text('目标位置已有同名项目'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, '还原'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final call = boot.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.FileStation.CopyMove',
        orElse: () => const {},
      );
      expect(call['overwrite'], false);
    });

    testWidgets('加密压缩：启用密码并两次一致 → Compress.start 带 password', (tester) async {
      await _phoneSurface(tester);
      final boot = await _boot({
        ..._homeResponses([_file('a.txt', size: 10)]),
        'SYNO.FileStation.Compress.start': {'taskid': 'Z2'},
      });
      await _pumpPage(tester, boot.fs, boot.db);
      await _enterHome(tester);

      await tester.tap(find.byTooltip('更多操作').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('压缩'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(find.byType(TextField).at(0), 'a.zip');
      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(1), 's3cret');
      await tester.enterText(find.byType(TextField).at(2), 's3cret');
      await tester.tap(find.text('开始压缩'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final zip = boot.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.FileStation.Compress',
        orElse: () => const {},
      );
      expect(zip['password'], 's3cret');
      expect(zip['format'], 'zip');
    });

    testWidgets('加密压缩：两次密码不一致 → 不提交', (tester) async {
      await _phoneSurface(tester);
      final boot = await _boot({
        ..._homeResponses([_file('a.txt', size: 10)]),
        'SYNO.FileStation.Compress.start': {'taskid': 'Z3'},
      });
      await _pumpPage(tester, boot.fs, boot.db);
      await _enterHome(tester);

      await tester.tap(find.byTooltip('更多操作').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('压缩'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(find.byType(TextField).at(0), 'a.zip');
      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(1), 'one');
      await tester.enterText(find.byType(TextField).at(2), 'two');
      await tester.tap(find.text('开始压缩'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('两次输入的密码不一致'), findsOneWidget);
      expect(
        boot.t.calls.where((c) => c['api'] == 'SYNO.FileStation.Compress'),
        isEmpty,
      );
    });

    testWidgets('普通压缩（不启用密码）→ 请求里没有 password 字段', (tester) async {
      await _phoneSurface(tester);
      final boot = await _boot({
        ..._homeResponses([_file('a.txt', size: 10)]),
        'SYNO.FileStation.Compress.start': {'taskid': 'Z4'},
      });
      await _pumpPage(tester, boot.fs, boot.db);
      await _enterHome(tester);

      await tester.tap(find.byTooltip('更多操作').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('压缩'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField).at(0), 'a.zip');
      await tester.tap(find.text('开始压缩'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final zip = boot.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.FileStation.Compress',
        orElse: () => const {},
      );
      expect(zip.containsKey('password'), isFalse);
    });

    testWidgets('加密解压：填密码 → Extract.start 带 password', (tester) async {
      await _phoneSurface(tester);
      final boot = await _boot({
        ..._homeResponses([_file('a.zip', size: 10)]),
        'SYNO.FileStation.Extract.start': {'taskid': 'E1'},
      });
      await _pumpPage(tester, boot.fs, boot.db);
      await _enterHome(tester);

      await tester.tap(find.byTooltip('更多操作').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(find.text('解压到此处'));
      await tester.pump();
      await tester.tap(find.text('解压到此处'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(find.byType(TextField).last, 'p@ss');
      await tester.tap(find.widgetWithText(FilledButton, '解压'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final call = boot.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.FileStation.Extract',
        orElse: () => const {},
      );
      expect(call['method'], 'start');
      expect(call['file_path'], '/home/a.zip');
      expect(call['password'], 'p@ss');
    });

    testWidgets('加密解压：留空 → 不发 password 字段', (tester) async {
      await _phoneSurface(tester);
      final boot = await _boot({
        ..._homeResponses([_file('a.zip', size: 10)]),
        'SYNO.FileStation.Extract.start': {'taskid': 'E2'},
      });
      await _pumpPage(tester, boot.fs, boot.db);
      await _enterHome(tester);

      await tester.tap(find.byTooltip('更多操作').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(find.text('解压到此处'));
      await tester.pump();
      await tester.tap(find.text('解压到此处'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(FilledButton, '解压'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final call = boot.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.FileStation.Extract',
        orElse: () => const {},
      );
      expect(call.containsKey('password'), isFalse);
    });
  });

  // ==================================================================
  // W1-3 收尾：下载任务列表的**常驻入口**（此前只能靠"再发起一次下载"打开）
  // ==================================================================
  group('W1-3 收尾：下载任务常驻入口', () {
    testWidgets('能力位在 → 顶栏常驻入口；点开是无任务的空态（不是空白弹层）', (tester) async {
      final boot = await _boot(_homeResponses([_file('a.txt', size: 10)]));
      await _pumpPage(tester, boot.fs, boot.db);

      final entry = find.byKey(const Key('file-download-tasks-entry'));
      expect(entry, findsOneWidget, reason: '下载任务入口要常驻在文件页顶栏');
      expect(
        find.byKey(const Key('file-download-tasks-badge')),
        findsNothing,
        reason: '没有活跃任务时不该显示数量徽标',
      );

      await tester.tap(entry);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('download-tasks-dialog')), findsOneWidget);
      expect(
        find.byKey(const Key('download-tasks-empty')),
        findsOneWidget,
        reason: '常驻入口随时可开 → 无任务必须是空态，而不是空白弹层',
      );
      expect(find.text('还没有下载任务'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('有活跃任务 → 入口显示数量徽标 + 进度 tooltip；跑完徽标消失', (tester) async {
      final gate = Completer<FileDownloadOutcome>();
      final list = FileDownloadTaskList();
      addTearDown(list.dispose);
      list.start(
        sourcePath: '/home/a.bin',
        name: 'a.bin',
        runner: (path, {required session}) async {
          session.report(30, 100);
          return gate.future;
        },
      );
      final boot = await _boot(_homeResponses([_file('a.txt', size: 10)]));
      await _pumpPage(
        tester,
        boot.fs,
        boot.db,
        moreOverrides: [fileDownloadTaskListProvider.overrideWithValue(list)],
      );
      await tester.pump();

      expect(
        find.byKey(const Key('file-download-tasks-badge')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('file-download-tasks-badge')),
          matching: find.text('1'),
        ),
        findsOneWidget,
        reason: '有 1 条活跃任务 → 徽标显示 1',
      );
      // 进度放在 tooltip 里（徽标是覆盖层，不占额外宽度 → 窄屏不溢出）
      final button = tester.widget<IconButton>(
        find.byKey(const Key('file-download-tasks-entry')),
      );
      expect(button.tooltip, contains('30%'));

      gate.complete(
        const FileDownloadOutcome(localPath: '/tmp/a.bin', totalBytes: 100),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const Key('file-download-tasks-badge')),
        findsNothing,
        reason: '任务结束后徽标不该常亮（不是"入口恒有徽标"）',
      );
    });

    testWidgets('下载能力位缺失 → 隐藏入口并就地给出原因（既有门控不删）', (tester) async {
      final table = {..._fsTable}..remove('SYNO.FileStation.Download');
      final boot = await _boot(
        _homeResponses([_file('a.txt', size: 10)]),
        table: table,
      );
      await _pumpPage(tester, boot.fs, boot.db);

      expect(
        find.byKey(const Key('file-download-tasks-entry')),
        findsNothing,
        reason: '能力位缺失 → 不给必失败的入口',
      );
      expect(find.text('服务器未提供文件下载功能'), findsWidgets);
      expect(
        find.byKey(const Key('file-download-disabled-reason')),
        findsOneWidget,
        reason: '隐藏入口的同时要给出原因（独立一行，窄屏不溢出）',
      );
      // 既有门控没被这次改动删掉：分享能力位在 → 分享入口仍在
      expect(await hasHeaderAction(tester, '分享链接'), isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  // ==================================================================
  // r121：多选条上的「更多」曾经是**死按钮**
  //
  // 真机像素取证：`/tmp/r121_ui/files_16_more.png` → `files_17_more2.png`
  // 前后**无任何变化**（`_runAction` 的 switch 里没有 `case 'more'`）。
  // ==================================================================
  group('r121 多选「更多」', () {
    testWidgets('多选后点「更多」必须弹出批量动作面板（不是死按钮）', (tester) async {
      await _phoneSurface(tester);
      final boot = await _boot(
        _homeResponses([
          _file('a.png', size: 2048),
          _file('b.png', size: 2048),
        ]),
      );
      await _pumpPage(
        tester,
        boot.fs,
        boot.db,
        moreOverrides: [
          thumbCacheProvider.overrideWithValue(
            ThumbCache(loader: (p, s) async => _png1x1),
          ),
        ],
      );
      await _enterHome(tester);

      // 长按第一行进多选，再点第二行加入选择
      await tester.longPress(find.byType(FileRow).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('已选 1 项'), findsOneWidget);

      await tester.tap(find.byType(FileRow).at(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('已选 2 项'), findsOneWidget);

      // 多选条上的「更多」
      await tester.tap(find.text('更多'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 修复前：这三个 key **一个都不会出现**（switch 里没有 case 'more'）。
      expect(
        find.byKey(const Key('file-more-download')),
        findsOneWidget,
        reason: '多选「更多」必须弹出批量动作面板（死按钮回归）',
      );
      expect(find.byKey(const Key('file-more-copy')), findsOneWidget);
      expect(find.byKey(const Key('file-more-delete')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // r296（收口 D2b）：`SYNO.FileStation.DirSize` 的能力表 / API / 服务层 / 后台任务
  // / 文案全都在，**唯独没有任何入口发 `'dirsize'`** ⇒ 用户点不到这个功能。
  // 这一组钉住"入口存在且真的会发请求"，并反向钉住"文件上不出现"。
  group('r296 D2b：计算文件夹大小（DirSize）入口', () {
    testWidgets('文件夹面板里有它，点了真发 DirSize.start(path=JSON 数组)', (tester) async {
      await _phoneSurface(tester);
      final boot = await _boot({
        ..._homeResponses([_file('videos', isDir: true), _file('a.txt', size: 10)]),
        'SYNO.FileStation.DirSize.start': <String, dynamic>{'taskid': 'DS-1'},
      });
      await _pumpPage(tester, boot.fs, boot.db);
      await _enterHome(tester);

      await tester.tap(_rowMenu('videos'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 面板是限高的滚动面板，动作可能在屏外 → 先滚进可视区（同删除那条）
      await tester.ensureVisible(find.byKey(const Key('file-dirsize')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('file-dirsize')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      final call = boot.t.calls.lastWhere(
        (c) => c['api'] == 'SYNO.FileStation.DirSize' && c['method'] == 'start',
        orElse: () => const {},
      );
      expect(
        call['path'],
        '["/home/videos"]',
        reason: '「计算文件夹大小」必须真的提交统计任务（死按钮回归）',
      );
      expect(find.textContaining('统计任务已提交'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('反向：普通文件的面板里**不该**有它（大小列表列已经有了）', (tester) async {
      await _phoneSurface(tester);
      final boot = await _boot(_homeResponses([_file('a.txt', size: 10)]));
      await _pumpPage(tester, boot.fs, boot.db);
      await _enterHome(tester);

      await tester.tap(_rowMenu('a.txt'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('file-dirsize')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  // ---------------------------------------------------------------- DA87
  //
  // r430：r424 记下的"列表尺寸/时间有缓存、下拉刷新与重进目录都不刷新"在此定性。
  // 真机 A/B（`docs/evidence-r430/`）已把变量锁到**一屏装不装得下**：
  //   ① 20 行的大列表（可滚动）：同一下拉手势 ⇒ 行从 `1.0 KB` 变 `2.9 MB` ✅
  //   ② 1 行的短列表（装得下）：同一手势 ×2 ⇒ 行**恒为** `2.9 MB · 16:34`（服务端已是 6 MB）❌
  // 根因：`RefreshIndicator` 要靠 **overscroll** 才会回调，而列表没有
  // `AlwaysScrollableScrollPhysics` ⇒ 内容比视口矮时滚不动、下拉手势根本到不了回调。
  // 下面这条用例把"短列表也必须能刷"钉成判据（修前恒红）。
  group('DA87 短列表的下拉刷新', () {
    testWidgets('DA87：内容不足一屏时，下拉刷新也必须真的重新取一次', (tester) async {
      await _phoneSurface(tester);
      final boot = await _boot(_homeResponses([_file('only.txt', size: 10)]));
      await _pumpPage(tester, boot.fs, boot.db);
      await _enterHome(tester);

      int homeListCalls() => boot.t.calls
          .where(
            (c) =>
                c['api'] == 'SYNO.FileStation.List' &&
                c['method'] == 'list' &&
                c['folder_path'] == '/home',
          )
          .length;

      final before = homeListCalls();
      expect(before, greaterThan(0), reason: '进 /home 至少要取一次');
      expect(find.text('only.txt'), findsOneWidget);

      // 一行的列表装得下一屏（内容矮于视口）—— 修前这里滚不动、收不到刷新回调
      await tester.fling(find.text('only.txt'), const Offset(0, 300), 1000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(
        homeListCalls(),
        before + 1,
        reason: 'DA87：短列表下拉刷新必须重新拉一次 /home（始终可滚 = AlwaysScrollableScrollPhysics）',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('反向：长列表本来就能刷（同一个判据在可滚动时早就通过）', (tester) async {
      await _phoneSurface(tester);
      final boot = await _boot(
        _homeResponses([
          for (var i = 0; i < 20; i++) _file('f$i.txt', size: 10),
        ]),
      );
      await _pumpPage(tester, boot.fs, boot.db);
      await _enterHome(tester);

      int homeListCalls() => boot.t.calls
          .where(
            (c) =>
                c['api'] == 'SYNO.FileStation.List' &&
                c['method'] == 'list' &&
                c['folder_path'] == '/home',
          )
          .length;

      final before = homeListCalls();
      await tester.fling(find.text('f0.txt'), const Offset(0, 300), 1000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(
        homeListCalls(),
        before + 1,
        reason: '长列表可滚动 ⇒ 下拉刷新一直是通的',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
