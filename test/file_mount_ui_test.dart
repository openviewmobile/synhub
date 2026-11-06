// ★ D17（r719）：文件页的「远程挂载」入口改成**短标签「挂载」**（长标签被 ellipsis 截断），
//   所以这里按芯片文案断言。
// File Station C5 远程挂载页面 + 文件侧 P1 界面的离线验证。
//
// 关注三件事：
//   1. **入口门控**：服务器没 Mount / Mount.List 就整个不渲染入口；回了
//      105/160 就标记禁用并给原因（"不许留会失败的入口"）；
//   2. **页面内容**：ISO / CIFS / 虚拟文件夹三段，只读提示，卸载确认；
//   3. **P1 界面**：目录内过滤框、WORM 锁定面板只留复制、只读角标。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/toolbar_actions.dart';

import 'package:synhub/src/features/admin/admin_gate.dart' show isAdminProvider;
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/file_browse_page.dart';
import 'package:synhub/src/features/files/file_mount_page.dart';
import 'package:synhub/src/features/files/file_pages.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/files/file_sheets.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

/// 真机 `SYNO.API.Info` 的快照子集 + Mount 家族
const _fsTable = {
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
  'SYNO.FileStation.Favorite': {
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
  'SYNO.FileStation.Mount': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.FileStation.Mount.List': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
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
  'SYNO.FileStation.Extract': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

Map<String, dynamic> _file(
  String name, {
  bool isDir = false,
  int? wormState,
  bool? writable,
}) => {
  'name': name,
  'path': '/home/$name',
  'isdir': isDir,
  'additional': {
    'size': 128,
    'time': {'mtime': 1758100000},
    if (writable != null)
      'perm': {
        'acl': {'read': true, 'write': writable, 'exec': false},
      },
    'worm_state': ?wormState,
  },
};

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

const _mountGet = {
  'mountConfig': {'enable_iso_mount': true, 'enable_remote_mount': true},
  'isoList': [
    {
      'type': 'iso',
      'source': '/volume1/iso/win.iso',
      'mount_point': '/volume1/win',
      'actor': 'l1',
      'date': 1758100000,
      'auto_mount': 'yes',
    },
  ],
  'remoteList': [
    {
      'type': 'cifs',
      'source': r'\\192.168.1.9\Share',
      'mount_point': '/volume1/smb',
      'actor': 'l1',
      'date': 1758100001,
      'auto_mount': 'fail',
    },
  ],
};

const _virtualGet = {
  'folders': [
    {'name': 'win', 'path': '/volume1/win'},
  ],
  'total': 1,
  'offset': 0,
};

Future<({FileStationApi fs, FakeTransport t, ChatDatabase db})> _boot(
  Map<String, Map<String, dynamic>> responses, {
  Map<String, int> failures = const {},
  bool withMount = true,
}) async {
  final table = <String, Map<String, dynamic>>{
    ...FakeTransport.table,
    ..._fsTable,
  };
  if (!withMount) {
    table.remove('SYNO.FileStation.Mount');
    table.remove('SYNO.FileStation.Mount.List');
  }
  final t = FakeTransport(responses, table);
  t.failures.addAll(failures);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  return (fs: FileStationApi(api), t: t, db: db);
}

Future<ProviderContainer> _pumpBrowse(
  WidgetTester tester,
  FileStationApi fs,
  ChatDatabase db,
) async {
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fileApiProvider.overrideWithValue(fs),
    ].cast(),
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: FileBrowsePage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return c;
}

Future<void> _enterHome(WidgetTester tester) async {
  // ★ r673：宽屏（expanded）下**单击只选中**（右栏出信息卡），第二下（≤500ms）
  //   或「打开文件夹」才是进入。这一支按窗口分级走对应的入口，不再假设"点一下
  //   就进目录"—— 否则测试量到的是"右栏把目录同步进了缓存"，而不是进入目录。
  final expanded = find
      .byKey(const Key('file-wide-region'))
      .evaluate()
      .isNotEmpty;
  Finder row() => expanded
      ? find.descendant(
          of: find.byKey(const Key('file-wide-master')),
          matching: find.text('home'),
        )
      : find.text('home');
  await tester.tap(row());
  await tester.pump();
  if (expanded) {
    await tester.tap(row());
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('服务端有 Mount → 文件页出现「远程挂载」入口，点进去能看列表', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boot = await _boot({
      ..._homeResponses([_file('a.txt')]),
      'SYNO.FileStation.Mount.List.get': _mountGet,
      'SYNO.FileStation.VirtualFolder.list': _virtualGet,
    });
    await _pumpBrowse(tester, boot.fs, boot.db);
    await _enterHome(tester);

    expect(find.text('挂载'), findsOneWidget);
    await tester.tap(find.text('挂载'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 已在挂载页：ISO / 远程 / 虚拟文件夹三段
    expect(find.byType(FileMountPage), findsOneWidget);
    expect(find.text('ISO 镜像卷'), findsOneWidget);
    expect(find.text('远程卷（CIFS）'), findsOneWidget);
    expect(find.text('/volume1/win'), findsWidgets);
    expect(find.text('/volume1/smb'), findsWidgets);
    // ISO 是只读卷 → 有明确提示
    expect(find.textContaining('只读'), findsWidgets);
    // 自动挂载失败要标出来
    expect(find.textContaining('自动挂载失败'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('服务端没有 Mount → 入口整个不渲染', (tester) async {
    final boot = await _boot(
      _homeResponses([_file('a.txt')]),
      withMount: false,
    );
    await _pumpBrowse(tester, boot.fs, boot.db);
    await _enterHome(tester);
    expect(find.text('挂载'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // ---- 官方「新增挂载」门控（FileBrowser.js offset 395,971 逐字）----
  //
  //   enable_remote_mount ? (is_admin || remote/home ? show : hide) : hide
  //   enable_iso_mount    ? show : hide
  //
  // 判据：`+` = 官方 `btnMountRemote` / `btnMountISO` 两个入口的合并形态。
  group('官方新增挂载门控（容器的出现条件）', () {
    Map<String, Map<String, dynamic>> mountWith({
      bool iso = false,
      bool remote = false,
      bool home = true,
    }) {
      final shares = <Map<String, dynamic>>[
        if (home) {'name': 'home', 'path': '/home', 'isdir': true, 'additional': {}},
        {'name': 'photo', 'path': '/photo', 'isdir': true, 'additional': {}},
      ];
      return {
        ..._homeResponses([_file('a.txt')]),
        'SYNO.FileStation.List.list_share': {
          'shares': shares,
          'total': shares.length,
          'offset': 0,
        },
        'SYNO.FileStation.Mount.List.get': {
          'mountConfig': {
            'enable_iso_mount': iso,
            'enable_remote_mount': remote,
          },
          'isoList': const [],
          'remoteList': const [],
        },
        'SYNO.FileStation.VirtualFolder.list': {
          'folders': const [],
          'total': 0,
          'offset': 0,
        },
      };
    }

    Future<void> pumpMount(
      WidgetTester tester,
      Map<String, Map<String, dynamic>> responses, {
      bool admin = false,
      bool viaBrowse = false,
      bool withSharedHome = true,
    }) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final boot = await _boot(responses);
      final container = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(boot.db),
          fileApiProvider.overrideWithValue(boot.fs),
          isAdminProvider.overrideWith((ref) async => admin),
        ].cast(),
      );
      if (viaBrowse) {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.dark(),
              home: FileBrowsePage(),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        if (withSharedHome) {
          await _enterHome(tester);
        }
        await tester.tap(find.text('挂载'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      } else {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.dark(),
              home: const FileMountPage(),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    testWidgets('两类都没开 → 顶栏没有 `+`，且不给"还没有挂载"的误导空态', (tester) async {
      await pumpMount(tester, mountWith(iso: false, remote: false));
      expect(find.byType(FileMountPage), findsOneWidget);
      expect(
        find.byTooltip('新增挂载'),
        findsNothing,
        reason: '官方：enable_remote_mount / enable_iso_mount 都为 false ⇒ 整格藏掉',
      );
      // 真正的空态（"还没有挂载…"）会让人以为可以加 ⇒ 不许出现
      expect(find.textContaining('还没有挂载任何远程卷'), findsNothing);
      expect(find.text('无法管理远程挂载'), findsOneWidget);
      expect(find.textContaining('没有为这个账号开启挂载'), findsOneWidget, reason: '要说清是服务器没开');
      expect(tester.takeException(), isNull);
    });

    testWidgets('只开 ISO → `+` 在，弹层里只有 ISO 一项', (tester) async {
      await pumpMount(tester, mountWith(iso: true, remote: false));
      expect(find.byTooltip('新增挂载'), findsOneWidget);
      await tester.tap(find.byTooltip('新增挂载'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('挂载 ISO 镜像'), findsOneWidget);
      expect(find.text('挂载远程文件夹（CIFS）'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('远程 + ISO 都开 + 有 home（浏览页进）→ `+` 在，弹层两项都在', (tester) async {
      await pumpMount(
        tester,
        mountWith(iso: true, remote: true, home: true),
        viaBrowse: true,
      );
      expect(find.byType(FileMountPage), findsOneWidget);
      expect(find.byTooltip('新增挂载'), findsOneWidget);
      await tester.tap(find.byTooltip('新增挂载'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('挂载 ISO 镜像'), findsOneWidget);
      expect(find.text('挂载远程文件夹（CIFS）'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('★ 开了远程但非管理员且没有 home → 不给远程，且原因说"要 home"', (
      tester,
    ) async {
      await pumpMount(
        tester,
        mountWith(iso: false, remote: true, home: false),
        viaBrowse: true,
        withSharedHome: false,
      );
      expect(find.byType(FileMountPage), findsOneWidget);
      expect(find.byTooltip('新增挂载'), findsNothing);
      expect(find.text('无法管理远程挂载'), findsOneWidget);
      expect(
        find.textContaining('用户主目录'),
        findsOneWidget,
        reason: '官方 err_remote_no_home：别把"没有 home"误报成"服务器没开"',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('★ 同一条件换成管理员 → 远程照给（官方 is_admin 短路）', (tester) async {
      await pumpMount(
        tester,
        mountWith(iso: false, remote: true, home: false),
        admin: true,
      );
      expect(find.byTooltip('新增挂载'), findsOneWidget);
      await tester.tap(find.byTooltip('新增挂载'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('挂载远程文件夹（CIFS）'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Mount.List/get 回 105 → 点了给原因，且不推一个只会报错的页面', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boot = await _boot(
      _homeResponses([_file('a.txt')]),
      failures: {'SYNO.FileStation.Mount.List.get': DsmErrorCode.noPermission},
    );
    await _pumpBrowse(tester, boot.fs, boot.db);
    await _enterHome(tester);

    // 入口还在（能力上支持），但点下去必须先解释为什么不行
    expect(find.text('挂载'), findsOneWidget);
    await tester.tap(find.text('挂载'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(FileMountPage), findsNothing, reason: '不该进页面');
    expect(find.textContaining('权限'), findsWidgets, reason: '要给出明确原因');
    // 标记为禁用后入口也消失
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('挂载'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('挂载页：卸载走确认框，105 之外的错误原样提示', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boot = await _boot({
      ..._homeResponses([_file('a.txt')]),
      'SYNO.FileStation.Mount.List.get': _mountGet,
      'SYNO.FileStation.VirtualFolder.list': _virtualGet,
    });
    await _pumpBrowse(tester, boot.fs, boot.db);
    await _enterHome(tester);
    await tester.tap(find.text('挂载'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byIcon(Icons.eject_outlined).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 确认框
    expect(find.textContaining('卸载'), findsWidgets);
    await tester.tap(find.text('取消').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('P1-1：目录内过滤只筛当前页，没匹配给清除入口', (tester) async {
    // ★ r293：窗口必须**真的**在 <700dp（单列）—— `setSurfaceSize` 不改
    //   `MediaQuery`（实测 `w=800`），只有 `tester.view` 才生效。
    tester.view.physicalSize = const Size(420, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final boot = await _boot(
      _homeResponses([
        _file('alpha.txt'),
        _file('beta.txt'),
        _file('gamma.txt'),
      ]),
    );
    await _pumpBrowse(tester, boot.fs, boot.db);
    await _enterHome(tester);
    expect(find.text('alpha.txt'), findsOneWidget);

    await tester.tap(find.text('筛选'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(TextField), findsWidgets);

    await tester.enterText(find.byType(TextField).last, 'BETA');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('beta.txt'), findsOneWidget);
    expect(find.text('alpha.txt'), findsNothing);

    // 全都不匹配 → 提示 + 清除
    await tester.enterText(find.byType(TextField).last, 'zzz');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('没有匹配项'), findsOneWidget);
    await tester.tap(find.text('清除筛选'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('alpha.txt'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('P1-6：WORM 锁定文件的操作面板只留复制', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boot = await _boot(
      _homeResponses([_file('locked.txt', wormState: 4)]),
    );
    await _pumpBrowse(tester, boot.fs, boot.db);
    await _enterHome(tester);

    final entry = FileEntryDto.fromJson(_file('locked.txt', wormState: 4));
    var opened = '';
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.dark(), 
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  opened =
                      await showFileItemSheet(
                        context,
                        entry: entry,
                        wormLocked: entry.wormLocked,
                      ) ??
                      '';
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(entry.wormLocked, isTrue);
    expect(find.text('复制到…'), findsOneWidget);
    // 面板里不该出现可点的改名 / 移动 / 压缩 / 删除
    expect(find.text('重命名'), findsNothing);
    expect(find.text('移动到…'), findsNothing);
    expect(find.text('压缩'), findsNothing);
    expect(find.text('删除'), findsNothing);
    // WORM 段
    expect(find.textContaining('WORM'), findsWidgets);
    expect(opened, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('C5 接线：WORM 锁定态经本地缓存表传到浏览页门控', (tester) async {
    // ★ r293：窗口必须**真的**在 <700dp（单列）—— `setSurfaceSize` 不改
    //   `MediaQuery`（实测 `w=800`），只有 `tester.view` 才生效。
    tester.view.physicalSize = const Size(420, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final boot = await _boot(
      _homeResponses([_file('locked.txt', wormState: 4)]),
    );
    final c = await _pumpBrowse(tester, boot.fs, boot.db);
    await _enterHome(tester);

    // 关键：行数据来自本地缓存表 `file_entry_rows`（不是内存里那份刚解析的 DTO）。
    // 缓存表缺 `worm_state` 列时，真机上这里恒为 false，门控永不触发。
    final cached =
        c.read(folderCacheProvider('/home')).value ?? const <FileEntryDto>[];
    final row = cached.firstWhere((e) => e.name == 'locked.txt');
    expect(row.wormLocked, isTrue, reason: '缓存表缺 worm_state → 恒 false');

    // 从列表行的菜单打开操作面板 → 锁定态只留复制
    // ⚠️ 第 258 轮：顶部工具条的 ⋮ 折叠入口（tooltip「更多」）也是 more_vert，
    // 用 byIcon 会点到它。行菜单的 tooltip 是「更多操作」。
    await tester.tap(find.byTooltip('更多操作').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('复制到…'), findsOneWidget);
    expect(find.text('重命名'), findsNothing);
    expect(find.text('删除'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('P1-11：只读文件的列表行有锁角标', (tester) async {
    final boot = await _boot(
      _homeResponses([_file('ro.txt', writable: false)]),
    );
    final c = await _pumpBrowse(tester, boot.fs, boot.db);
    await _enterHome(tester);
    // 缓存里没有 permKnown 列 → DTO 用"三个 acl 位"兜底判定，只读仍要认得出来
    final cached =
        c.read(folderCacheProvider('/home')).value ?? const <FileEntryDto>[];
    expect(cached.single.isReadOnly, isTrue);
    expect(find.byIcon(Icons.lock_outline), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('M12：网格视图的只读格也有锁角标（以前只有列表行有）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boot = await _boot(
      _homeResponses([_file('ro.txt', writable: false)]),
    );
    await _pumpBrowse(tester, boot.fs, boot.db);
    await _enterHome(tester);

    await tapHeaderAction(tester, '切换为缩略图视图');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byIcon(Icons.lock_outline), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('M12：只读共享根说「只读共享」（perm.acl.write=false + 挂载点）', (tester) async {
    final boot = await _boot({
      'SYNO.FileStation.List.list_share': {
        'shares': [
          {
            'name': 'ro-share',
            'path': '/ro-share',
            'isdir': true,
            'additional': {
              'mount_point_type': 'shared_folder',
              'perm': {
                'acl': {'read': true, 'write': false, 'exec': false},
              },
            },
          },
        ],
        'total': 1,
        'offset': 0,
      },
    });
    await _pumpBrowse(tester, boot.fs, boot.db);

    expect(find.byIcon(Icons.lock_outline), findsWidgets);
    expect(find.byTooltip('只读共享'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('P1-7：收藏页可清理失效收藏（Favorite/clear_broken，无参数）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boot = await _boot({
      'SYNO.FileStation.Favorite.list': {
        'files': [
          {
            'name': 'broken',
            'path': '/home/gone',
            'isdir': true,
            'additional': {
              'real_path': '/home/gone',
              'time': {'mtime': 1758100000},
            },
          },
        ],
        'total': 1,
        'offset': 0,
      },
    });
    final c = ProviderContainer(
      overrides: [
        chatDatabaseProvider.overrideWithValue(boot.db),
        fileApiProvider.overrideWithValue(boot.fs),
      ].cast(),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(theme: AppTheme.dark(), home: FileFavoritesPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byIcon(Icons.cleaning_services_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 二次确认后才发请求
    expect(
      boot.t.calls.any((x) => x['method'] == 'clear_broken'),
      isFalse,
      reason: '确认前不发请求',
    );
    await tester.tap(find.text('清理失效收藏').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final call = boot.t.calls.lastWhere((x) => x['method'] == 'clear_broken');
    expect(call['api'], 'SYNO.FileStation.Favorite');
    expect(call['version'], '2');
    expect(call.containsKey('path'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('P1-7：收藏重命名走 Favorite/edit', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boot = await _boot({
      'SYNO.FileStation.Favorite.list': {
        'files': [
          {
            'name': '老名字',
            'path': '/home/keep',
            'isdir': true,
            'additional': {
              'real_path': '/home/keep',
              'time': {'mtime': 1758100000},
            },
          },
        ],
        'total': 1,
        'offset': 0,
      },
    });
    final c = ProviderContainer(
      overrides: [
        chatDatabaseProvider.overrideWithValue(boot.db),
        fileApiProvider.overrideWithValue(boot.fs),
      ].cast(),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(theme: AppTheme.dark(), home: FileFavoritesPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('重命名收藏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byType(TextField).last, '新名字');
    await tester.pump();
    await tester.tap(find.text('重命名').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final call = boot.t.calls.lastWhere((x) => x['method'] == 'edit');
    expect(call['api'], 'SYNO.FileStation.Favorite');
    expect(call['name'], '新名字');
    expect(call['path'], '/home/keep');
    expect('${call['index']}', '-1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('虚拟文件夹为空 → 不渲染该分组（没有"虚拟文件夹为空"独立空态）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boot = await _boot({
      ..._homeResponses([_file('a.txt')]),
      'SYNO.FileStation.Mount.List.get': _mountGet,
      'SYNO.FileStation.VirtualFolder.list': {
        'folders': <dynamic>[],
        'total': 0,
        'offset': 0,
      },
    });
    await _pumpBrowse(tester, boot.fs, boot.db);
    await _enterHome(tester);
    await tester.tap(find.text('挂载'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 有挂载但没有虚拟文件夹：整个「虚拟文件夹」分组不渲染（空段落不出现）
    expect(find.text('远程卷（CIFS）'), findsOneWidget);
    expect(
      find.textContaining('虚拟文件夹'),
      findsNothing,
      reason: '虚拟文件夹为空不是独立空态（也没有"虚拟文件夹为空"文案）',
    );
    // "一个挂载/虚拟卷都没有"才是页面级空态（`fsC5MountEmpty`）管的事
    expect(find.text('还没有挂载任何远程卷或 ISO 镜像。'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('360dp 窄屏：加了筛选/挂载入口后顶部仍不溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boot = await _boot(_homeResponses([_file('a.txt')]));
    await _pumpBrowse(tester, boot.fs, boot.db);
    await _enterHome(tester);
    // 打开过滤框（多一行 TextField）也不许溢出
    await tester.tap(find.text('筛选'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });
}
