// 相册文件夹写操作（§11 第 ② 项）：离线测试。
//
// 形态来自**官方 Web 前端的真实调用**（SPK `SynologyPhotos-x86_64-1.9.1-10928.spk`
// 的 `ui/react_bundle.js`，CreateFolder / RenameFolder / DeleteFolder 三个 saga）：
//   * `Browse.Folder/create`  `{target_id: 父目录 id, name}` → `{folder:{…}}`
//   * `Browse.Folder/rename`  `{id: 裸, name}`               → `{folder:{…}}`
//   * `Browse.Folder/delete`  `{id: [数字…]}`                ← **必须是数组**
//
// 这一层测的是"参数形态是否与官方一致"——数组/裸值写错在真机上会 `120`
// 或静默无效，离线用例是唯一能钉死的地方（删相册那次就是静默无效）。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/photos/photo_browse_page.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Foto.Setting.User': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 7,
  },
  'SYNO.Foto.Browse.Folder': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Thumbnail': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

Map<String, dynamic> _folder(
  String id,
  String name, {
  bool shared = false,
  String parent = '0',
}) => {
  'id': id,
  'name': name,
  'parent': parent,
  'shared': shared,
  'owner_user_id': '4',
  'item_count': 0,
  'additional': {'thumbnail': <dynamic>[]},
};

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

/// 挂相册页：响应按 `api.method` 精确分发（`list` 被 Item/Folder 共用，
/// 不能像别的用例只按方法名分）
Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester, {
  Map<String, Map<String, dynamic>> byCall = const {},
  List<Map<String, dynamic>> folders = const [],
}) async {
  final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
  t.onCall = (params) {
    final api = '${params['api']}';
    final method = '${params['method']}';
    if (api.endsWith('Setting.User') && method == 'get') {
      return {
        'team_space_permission': 'none',
        'enable_person': false,
        'timeline_group_unit': 'day',
        'item_sort_by': 'takentime',
        'sort_direction': 'desc',
      };
    }
    final hit = byCall['$api.$method'];
    if (hit != null) return hit;
    if (api.endsWith('Browse.Folder') && method == 'get') {
      return {'folder': _folder('1', 'Photos')};
    }
    if (api.endsWith('Browse.Folder') && method == 'list') {
      return {'list': folders, 'total': folders.length};
    }
    if (api.endsWith('Browse.Item') && method == 'list') {
      return {'list': <dynamic>[], 'total': 0};
    }
    return const <String, dynamic>{};
  };
  final api = await _loggedIn(t);
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fotoApiProvider.overrideWithValue(FotoApi(api)),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: PhotoBrowsePage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return (t: t, c: c);
}

void main() {
  group('文件夹写操作 · 接口层', () {
    late FakeTransport t;
    late FotoApi foto;

    setUp(() async {
      t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) {
        final api = '${params['api']}';
        final method = '${params['method']}';
        if (api.endsWith('Browse.Folder') && method == 'create') {
          return {'folder': _folder('31', '${params['name']}', parent: '1')};
        }
        // `Browse.Folder/get` 不带 id → 当前空间的根文件夹（真机根 id 不是 0）
        if (api.endsWith('Browse.Folder') && method == 'get') {
          return {'folder': _folder('1', 'Photos')};
        }
        return const <String, dynamic>{};
      };
      foto = FotoApi(await _loggedIn(t));
    });

    Map<String, dynamic> lastCall(String method) => t.calls.lastWhere(
      (c) => '${c['method']}' == method,
      orElse: () => throw StateError('没有发起过 $method'),
    );

    test('创建文件夹：create v1，父目录走 target_id（官方 Web 形态）', () async {
      final folder = await foto.createFolder(parentId: '0', name: '旅行');
      final call = lastCall('create');
      expect(call['api'], 'SYNO.Foto.Browse.Folder');
      expect('${call['version']}', '1', reason: '官方 Web 前端钉死写操作 = v1');
      expect(call['name'], '旅行');
      expect(folder.id, '31');
      expect(folder.name, '旅行');
    });

    test('根目录创建：先 `Folder/get` 取真实根 id，再拿它当 target_id', () async {
      await foto.createFolder(parentId: '0', name: '旅行');
      // ⚠️ 真机教训：`target_id=0` 会被判 120 请求参数无效
      expect(
        t.calls.where((c) => '${c['method']}' == 'get').length,
        1,
        reason: '取根文件夹用 Browse.Folder/get（不带 id）',
      );
      expect(lastCall('create')['target_id'], '1', reason: '用真实根 id，不是 0');
    });

    test('在子目录里创建：target_id 就是那个目录的 id，不再问根', () async {
      await foto.createFolder(parentId: '12', name: '子目录');
      expect(lastCall('create')['target_id'], '12');
      expect(
        t.calls.any((c) => '${c['method']}' == 'get'),
        isFalse,
        reason: '有真实父 id 时不必多做一次 get',
      );
    });

    test('folderRoot：`Folder/get` 不带 id，回包取 folder', () async {
      final root = await foto.folderRoot();
      final call = lastCall('get');
      expect(call['api'], 'SYNO.Foto.Browse.Folder');
      expect(call.containsKey('id'), isFalse, reason: '不带 id 才是"当前空间的根"');
      expect(root.id, '1');
    });

    test('回包没有 folder 时不炸（返回占位 DTO）', () async {
      t.onCall = (_) => const <String, dynamic>{};
      final folder = await foto.createFolder(parentId: '7', name: 'x');
      expect(folder.id, '');
      expect(folder.parentId, '7');
    });

    test('重命名文件夹：rename v1，id 与 name 都是裸值', () async {
      await foto.renameFolder(folderId: '12', name: '新名字');
      final call = lastCall('rename');
      expect('${call['version']}', '1');
      expect(call['id'], '12', reason: 'id 不能被数组化');
      expect(call['name'], '新名字');
    });

    test('删除文件夹：delete v1，id 必须是数字数组串（裸 id 静默无效）', () async {
      await foto.deleteFolders(['12', '13']);
      final call = lastCall('delete');
      expect('${call['version']}', '1');
      expect(call['id'], '[12,13]');
    });

    test('非数字 id 被丢掉；全非数字/空列表不发请求', () async {
      await foto.deleteFolders(['12', 'folder-cover']);
      expect(lastCall('delete')['id'], '[12]');

      final before = t.calls.length;
      await foto.deleteFolders(const []);
      await foto.deleteFolders(const ['x']);
      expect(t.calls.length, before, reason: '空/非法 id 不该发请求');
    });
  });

  group('文件夹写操作 · 页面层', () {
    testWidgets('文件夹段有「创建文件夹」FAB，时间轴段没有', (tester) async {
      await _pump(tester);
      expect(find.byKey(const Key('photo-folder-create')), findsNothing);
      await tester.tap(find.text('文件夹'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('photo-folder-create')), findsOneWidget);
      expect(find.byKey(const Key('photo-album-create')), findsNothing);
    });

    testWidgets('创建文件夹：默认名「新文件夹」，确认后发 create(真实根 id)', (tester) async {
      final boot = await _pump(tester);
      await tester.tap(find.text('文件夹'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 时间轴段也有自己的 FAB → Scaffold 有 FAB 过渡动画；等它走完再点
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-folder-create')));
      await tester.pumpAndSettle();
      expect(find.text('创建文件夹'), findsWidgets);
      // 官方语言包 default_folder_name = 新文件夹
      expect(find.text('新文件夹'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('photo-folder-name')),
        '2026 旅行',
      );
      await tester.tap(find.byKey(const Key('photo-folder-create-ok')));
      await tester.pumpAndSettle();

      final call = boot.t.calls.firstWhere(
        (c) => '${c['method']}' == 'create',
        orElse: () => throw StateError('没有发 create'),
      );
      expect(call['api'], 'SYNO.Foto.Browse.Folder');
      expect(call['target_id'], '1', reason: '根目录要先解析成真实根 id');
      expect(call['name'], '2026 旅行');
      expect(find.textContaining('已创建'), findsOneWidget);
    });

    testWidgets('自己的文件夹有菜单，共享给我的没有', (tester) async {
      await _pump(
        tester,
        folders: [_folder('12', '我的相册'), _folder('13', '别人共享的', shared: true)],
      );
      await tester.tap(find.text('文件夹'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('photo-folder-menu-12')), findsOneWidget);
      expect(
        find.byKey(const Key('photo-folder-menu-13')),
        findsNothing,
        reason: '共享给我的目录不给改名/删除',
      );
    });

    testWidgets('重命名文件夹：菜单 → 对话框 → rename(id, name)', (tester) async {
      final boot = await _pump(tester, folders: [_folder('12', '旧名字')]);
      await tester.tap(find.text('文件夹'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byKey(const Key('photo-folder-menu-12')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      expect(find.text('重命名文件夹'), findsWidgets);

      await tester.enterText(
        find.byKey(const Key('photo-folder-rename')),
        '新名字',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final call = boot.t.calls.firstWhere(
        (c) => '${c['method']}' == 'rename',
        orElse: () => throw StateError('没有发 rename'),
      );
      expect(call['id'], '12');
      expect(call['name'], '新名字');
      expect(find.textContaining('已改名为'), findsOneWidget);
    });

    testWidgets('删除文件夹：菜单 → 二次确认 → delete(id 数组)', (tester) async {
      final boot = await _pump(tester, folders: [_folder('12', '待删')]);
      await tester.tap(find.text('文件夹'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byKey(const Key('photo-folder-menu-12')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除文件夹'));
      await tester.pumpAndSettle();
      expect(find.text('删除文件夹？'), findsOneWidget);
      expect(find.textContaining('回收站'), findsOneWidget, reason: '官方语义是移回收站');

      await tester.tap(find.byKey(const Key('photo-folder-delete-ok')));
      await tester.pumpAndSettle();

      final call = boot.t.calls.firstWhere(
        (c) => '${c['method']}' == 'delete',
        orElse: () => throw StateError('没有发 delete'),
      );
      expect(call['id'], '[12]');
      expect(find.textContaining('已删除'), findsOneWidget);
    });

    testWidgets('文件夹详情页：详情页菜单能改名、FAB 建子目录（target_id=当前目录）', (tester) async {
      final boot = await _pump(tester, folders: [_folder('12', '照片')]);
      await tester.tap(find.text('文件夹'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('照片'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-folder-page-menu')), findsOneWidget);

      await tester.tap(find.byKey(const Key('photo-subfolder-create')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('photo-folder-name')), '子目录');
      await tester.tap(find.byKey(const Key('photo-folder-create-ok')));
      await tester.pumpAndSettle();

      final call = boot.t.calls.firstWhere(
        (c) => '${c['method']}' == 'create',
        orElse: () => throw StateError('没有发 create'),
      );
      expect(call['target_id'], '12', reason: '在详情页建的就是当前目录的子目录');
      expect(call['name'], '子目录');
    });

    testWidgets('接口报错时说人话（不吞异常）', (tester) async {
      final boot = await _pump(
        tester,
        folders: [_folder('12', '只读')],
        byCall: const {'SYNO.Foto.Browse.Folder.create': <String, dynamic>{}},
      );
      boot.t.failures['SYNO.Foto.Browse.Folder.create'] = 120;
      await tester.tap(find.text('文件夹'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 时间轴段也有自己的 FAB → Scaffold 有 FAB 过渡动画；等它走完再点
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('photo-folder-create')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('photo-folder-name')), 'x');
      await tester.tap(find.byKey(const Key('photo-folder-create-ok')));
      await tester.pumpAndSettle();
      expect(find.textContaining('建文件夹失败'), findsOneWidget);
    });
  });
}
