// Drive wave1「可直接做」剩余项 + 相机备份落点修复的离线测试。
//
// 覆盖：
//   * D19 排序（`sort_by`/`sort_direction` 一路透传）
//   * D18 网格视图（`Files/list` 的 `field=thumbnail` + 切换）
//   * D51 搜索历史（本地持久化）
//   * D43 请求文件 identifier（`create_folder`/`add_prefix`）
//   * D60/D59 文本新建 / 编辑
//   * D81 首次运行范围说明（本地持久化，只弹一次）
//   * 相机备份 `Photos/upload` 的 `path` = 目录 + 文件名（真机 A/B 2026-09-22）
//
// 纪律：不跑真机、不联网；断言只钉"有原文/已取证"的参数名。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/media/thumb_cache.dart';
import 'package:synhub/src/design/design_palette.dart';
import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/drive/drive_gaps_stores.dart';
import 'package:synhub/src/features/drive/drive_search_page.dart';
import 'package:synhub/src/features/drive/drive_text_editor_page.dart';
import 'package:synhub/src/features/files/drive_browse_view.dart';
import 'package:synhub/src/features/files/drive_providers.dart';
import 'package:synhub/src/features/files/file_thumb.dart'
    show FileIconTile;

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

/// 1×1 透明 PNG：钉"既有 `get_thumbnail` 通道真的能出图"。
final Uint8List _png1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

/// **内存版**缩略图缓存：loader 与生产逻辑一致（`thumbnailUrl` → `getBytes`，
/// 因此 `get_thumbnail` 仍会被假传输记录），只是 `directory` 返回 null 关掉磁盘。
///
/// 为什么不用生产 `driveThumbCacheProvider`：它的磁盘目录来自
/// `CacheService.fileThumbsDirectory()`，在 widget test 的 fake-async 里会等
/// `path_provider` 的平台通道**永不返回**，loader 根本走不到——测试要么卡死要么
/// 误判"没走通道"。换成内存版就能稳定钉住回落分支本身。
ThumbCache _memoryThumbCache(DsmWebApi api) => ThumbCache(
  directory: () async => null,
  loader: (key, size) async {
    final parts = key.split('|');
    final bytes = await api.getBytes(
      DriveApi(api).thumbnailUrl(
        fileId: parts.first,
        size: size,
        versionId: parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null,
      ),
    );
    return Uint8List.fromList(bytes);
  },
);

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.SynologyDrive.Photos': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.SynologyDrive.FileRequest': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.SynologyDrive.Labels': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.SynologyDrive.TeamFolders': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.FileStation.Upload': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
};

Map<String, dynamic> _item({
  required String id,
  required String name,
  String type = 'file',
  String? thumbnail,
}) => {
  'file_id': id,
  'name': name,
  'type': type,
  'path': '/$name',
  'display_path': '/mydrive/$name',
  'parent_id': '900',
  'size': type == 'dir' ? 0 : 2048,
  'modified_time': 1789739500,
  'created_time': 1789739400,
  'content_type': type == 'dir' ? 'dir' : 'document',
  'starred': false,
  'shared': false,
  'owner': {'display_name': 'demo_user', 'name': 'demo_user'},
  'capabilities': {
    'can_download': true,
    'can_preview': true,
    'can_write': true,
  },
  'thumbnail': ?thumbnail,
};

const _allDriveApis = {
  'SYNO.SynologyDrive.Files',
  'SYNO.SynologyDrive.TeamFolders',
  'SYNO.SynologyDrive.Labels',
  'SYNO.SynologyDrive.FileRequest',
  'SYNO.SynologyDrive.Photos',
};

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);
  final ServiceAvailabilitySnapshot snapshot;
  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

ServiceAvailabilitySnapshot _snap(Set<String> apis) =>
    ServiceAvailabilitySnapshot(
      states: {
        for (final s in StationService.values)
          s: s == StationService.drive
              ? classifyApiTable(kServiceRegistry[StationService.drive]!, apis)
              : AvailabilityState.available,
      },
      apis: apis,
      checkedAt: DateTime(2026, 9, 22),
    );

/// 建一个已登录的 API + 假传输。
Future<({FakeTransport t, DsmWebApi api})> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (t: t, api: api);
}

FakeTransport _transport({
  Map<String, Map<String, dynamic>> responses = const {},
}) {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._table});
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    return {...?responses[key], 'success': true};
  };
  return t;
}

Map<String, dynamic> _listCall(FakeTransport t) =>
    t.calls.lastWhere((c) => c['method'] == 'list');

Future<void> _pumpWidget(
  WidgetTester tester,
  Widget page, {
  required DsmWebApi api,
  DriveScopeIntroStore? scopeIntroStore,
  DriveSearchHistoryStore? searchHistoryStore,
  ThumbCache? thumbCache,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: ProviderContainer(
        overrides: [
          driveApiProvider.overrideWithValue(DriveApi(api)),
          serviceAvailabilityProvider.overrideWith(
            () => _FixedAvailability(_snap(_allDriveApis)),
          ),
          if (thumbCache != null)
            driveThumbCacheProvider.overrideWithValue(thumbCache),
          if (scopeIntroStore != null)
            driveScopeIntroStoreProvider.overrideWithValue(scopeIntroStore),
          if (searchHistoryStore != null)
            driveSearchHistoryStoreProvider.overrideWithValue(
              searchHistoryStore,
            ),
        ],
      ),
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  // ============================================================ 界面层
  group('D19/D18 顶部工具条', () {
    testWidgets('排序菜单选"修改时间"→ list 带 sort_by', (tester) async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Files.list': {
            'items': [_item(id: '1', name: 'a.txt')],
            'total': 1,
          },
        },
      );
      final s = await _loggedIn(t);
      await _pumpWidget(
        tester,
        const Scaffold(body: DriveBrowseView()),
        api: s.api,
      );
      await tester.tap(find.byKey(const Key('drive-sort-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('drive-sort-modified_time')));
      await tester.pumpAndSettle();
      expect(_listCall(t)['sort_by'], 'modified_time');
    });

    testWidgets('切换视图 → 网格出现、再切回列表', (tester) async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Files.list': {
            'items': [
              _item(id: '1', name: 'a.jpg'),
              _item(id: '2', name: 'b.txt'),
            ],
            'total': 2,
          },
        },
      );
      final s = await _loggedIn(t);
      await _pumpWidget(
        tester,
        const Scaffold(body: DriveBrowseView()),
        api: s.api,
      );
      expect(find.byKey(const Key('drive-list')), findsOneWidget);
      await tester.tap(find.byKey(const Key('drive-view-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('drive-grid')), findsOneWidget);
      expect(find.byKey(const Key('drive-grid-tile-1')), findsOneWidget);
      await tester.tap(find.byKey(const Key('drive-view-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('drive-list')), findsOneWidget);
    });
  });

  group('D18 网格回落（真机已证 list 不下发条目级 thumbnail）', () {
    // 真机只读实测（2026-09-22，entry.cgi）：`Files/list` v11 带
    // `field=thumbnail` 回包**不含 thumbnail**；`get_thumbnail` 端点存在但
    // 必填参数未取证（只带 `path` 会 400）。所以网格必须**优雅回落**到既有
    // `get_thumbnail` 通道 / 分类图标，且**绝不**伪造 URL 或猜参数。
    //
    // 网格缩略图会触发真实图片解码，`pumpAndSettle` 在这种场景下可能等不到
    // 收敛；这里用有界 pump 把 provider future 推完即可（不需要解码完成，
    // `Image` widget 在 bytes 非空且是图片时就已经进树）。
    Future<void> pumpFrames(WidgetTester tester, {int times = 12}) async {
      for (var i = 0; i < times; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
    }

    testWidgets('thumbnail 缺失 → 走既有 get_thumbnail 通道出图（不空白、不露 id/路径）', (
      tester,
    ) async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Files.list': {
            'items': [_item(id: '1', name: 'a.jpg')], // 无 thumbnail 字段
            'total': 1,
          },
        },
      );
      // 既有通道（get_thumbnail）回一张真图，证明回落分支真能出图
      t.bytesByUrl['get_thumbnail'] = _png1x1;
      final s = await _loggedIn(t);
      await _pumpWidget(
        tester,
        const Scaffold(body: DriveBrowseView()),
        api: s.api,
        thumbCache: _memoryThumbCache(s.api),
      );
      await tester.tap(find.byKey(const Key('drive-view-toggle')));
      await pumpFrames(tester);

      final tile = find.byKey(const Key('drive-grid-tile-1'));
      expect(tile, findsOneWidget);
      // 走的是既有 `get_thumbnail`；没有凭空发明 `thumbnail` 方法
      expect(t.downloads.any((u) => u.contains('get_thumbnail')), isTrue);
      expect(t.calls.any((c) => (c['method'] ?? '') == 'thumbnail'), isFalse);
      // 出图（不是空白）
      expect(
        find.descendant(of: tile, matching: find.byType(Image)),
        findsWidgets,
      );
      // 不把内部 id / 路径渲染给用户
      expect(find.text('1'), findsNothing);
      expect(find.textContaining('/mydrive/'), findsNothing);
    });

    testWidgets('thumbnail 为空串且缩略图取不到 → 占位图标（不空白、不露 id/路径）', (tester) async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Files.list': {
            // 明确空串：不能被当成 URL 去 Image.network
            'items': [_item(id: '1', name: 'a.jpg', thumbnail: '')],
            'total': 1,
          },
        },
      );
      // 默认 downloadBytes 不是图片 → 走 FileIconTile 占位
      final s = await _loggedIn(t);
      await _pumpWidget(
        tester,
        const Scaffold(body: DriveBrowseView()),
        api: s.api,
        thumbCache: _memoryThumbCache(s.api),
      );
      await tester.tap(find.byKey(const Key('drive-view-toggle')));
      await pumpFrames(tester);

      final tile = find.byKey(const Key('drive-grid-tile-1'));
      expect(tile, findsOneWidget);
      expect(
        find.descendant(of: tile, matching: find.byType(FileIconTile)),
        findsOneWidget,
      );
      expect(find.text('1'), findsNothing);
      expect(find.textContaining('/mydrive/'), findsNothing);
    });
  });

  group('D81 首次运行范围说明', () {
    testWidgets('未看过 → 显示；点"知道了"→ 落盘且消失', (tester) async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Files.list': {
            'items': [_item(id: '1', name: 'a.txt')],
            'total': 1,
          },
        },
      );
      final s = await _loggedIn(t);
      final store = MemoryDriveScopeIntroStore();
      await _pumpWidget(
        tester,
        const Scaffold(body: DriveBrowseView()),
        api: s.api,
        scopeIntroStore: store,
      );
      await tester.pump();
      expect(find.byKey(const Key('drive-scope-intro')), findsOneWidget);
      await tester.tap(find.byKey(const Key('drive-scope-dismiss')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('drive-scope-intro')), findsNothing);
      expect(store.seen, isTrue);
    });

    testWidgets('已看过 → 不再显示', (tester) async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Files.list': {
            'items': [_item(id: '1', name: 'a.txt')],
            'total': 1,
          },
        },
      );
      final s = await _loggedIn(t);
      final store = MemoryDriveScopeIntroStore(seen: true);
      await _pumpWidget(
        tester,
        const Scaffold(body: DriveBrowseView()),
        api: s.api,
        scopeIntroStore: store,
      );
      await tester.pump();
      expect(find.byKey(const Key('drive-scope-intro')), findsNothing);
    });
  });

  group('D51 搜索历史', () {
    testWidgets('落盘的历史读回并展示；点一条即搜索', (tester) async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Files.search': {
            'items': [_item(id: '601', name: 'report.pdf')],
            'total': 1,
          },
        },
      );
      final s = await _loggedIn(t);
      final store = MemoryDriveSearchHistoryStore(['report']);
      await _pumpWidget(
        tester,
        const DriveSearchPage(),
        api: s.api,
        searchHistoryStore: store,
      );
      await tester.pump();
      expect(find.byKey(const Key('drive-search-history')), findsOneWidget);
      expect(find.text('report'), findsWidgets);
      await tester.tap(find.byKey(const Key('drive-search-history-report')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        t.calls.any((c) => c['method'] == 'search' && c['keyword'] == 'report'),
        isTrue,
      );
    });

    testWidgets('新搜索写入本地存储（falsification 目标）', (tester) async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Files.search': {'items': const [], 'total': 0},
        },
      );
      final s = await _loggedIn(t);
      final store = MemoryDriveSearchHistoryStore();
      await _pumpWidget(
        tester,
        const DriveSearchPage(),
        api: s.api,
        searchHistoryStore: store,
      );
      await tester.enterText(
        find.byKey(const Key('drive-search-field')),
        'alpha',
      );
      await tester.tap(find.byKey(const Key('drive-search-submit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(store.items, contains('alpha'));
    });
  });

  group('D59 文本编辑', () {
    testWidgets('可编辑后缀判定 + 编辑保存回调', (tester) async {
      expect(driveIsEditableText('a.txt'), isTrue);
      expect(driveIsEditableText('a.md'), isTrue);
      expect(driveIsEditableText('a.pdf'), isFalse);
      expect(driveIsEditableText('noext'), isFalse);

      String? saved;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: DriveTextEditorPage(
            title: 'a.txt',
            loadText: () async => 'hello',
            saveText: (s) async => saved = s,
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('drive-text-field')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('drive-text-field')),
        'hello world',
      );
      await tester.tap(find.byKey(const Key('drive-text-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(saved, 'hello world');
    });

    // ★ r379（DA16）：点 `.txt`/`.md` 行该进编辑器还是阅读器，是一个**纯函数**；
    //   判据来自官方 `OpenFileHelper.smali` `openFile$lambda$5` 的 1 MiB 分流。
    test('点行落点：≤1 MiB 的 .txt/.md 进编辑器，其余进阅读器', () {
      const mib = 1024 * 1024;
      // ≤1 MiB 的纯文本 ⇒ 编辑器
      expect(driveTapOpenMode(name: 'notes.txt', size: 12), DriveTapOpen.editor);
      expect(driveTapOpenMode(name: 'readme.md', size: mib), DriveTapOpen.editor);
      expect(driveTapOpenMode(name: 'A.TXT', size: 1), DriveTapOpen.editor);
      // 边界：多 1 字节就回落阅读器（官方是 `size <= 0x100000`）
      expect(
        driveTapOpenMode(name: 'notes.txt', size: mib + 1),
        DriveTapOpen.reader,
      );
      // 非纯文本 / 无后缀 ⇒ 阅读器
      expect(driveTapOpenMode(name: 'a.pdf', size: 10), DriveTapOpen.reader);
      expect(driveTapOpenMode(name: 'a.docx', size: 10), DriveTapOpen.reader);
      expect(driveTapOpenMode(name: 'noext', size: 10), DriveTapOpen.reader);
      // 写权限**不参与**判定（官方也不看权限）—— 函数签名里根本没有它
      expect(kDriveTextEditorMaxBytes, mib);
    });

    testWidgets('只读打开：没有保存按钮、有只读说明、正文不可编辑', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: DriveTextEditorPage(
            title: 'shared.txt',
            readOnly: true,
            loadText: () async => 'hello',
            saveText: (s) async => fail('只读打开不许保存'),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('drive-text-save')), findsNothing);
      expect(find.byKey(const Key('drive-text-readonly-note')), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const Key('drive-text-field')),
      );
      expect(field.readOnly, isTrue);
    });

    // ★★ DA209（r627 真机）：新建文本文件打开后是**一块与页面同色的空白**：
    // 真机实测边界 1.40:1、填色 1.00:1、hintText 是空串、也没有光标 ⇒ 用户看不出“从哪开始”。
    // 两半判据：① 空草稿要有提示；② 静态边界对页面底 **≥3:1**（WCAG 1.4.11）。
    testWidgets('DA209 空草稿必须有“开始输入…”且输入面边界≥3:1', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: DriveTextEditorPage(
            title: 'draft.txt',
            loadText: () async => '',
            saveText: (_) async {},
          ),
        ),
      );
      await tester.pump();
      final field = tester.widget<TextField>(
        find.byKey(const Key('drive-text-field')),
      );
      expect(field.decoration?.hintText, isNotEmpty);
      final border = field.decoration?.enabledBorder as OutlineInputBorder?;
      final line = border?.borderSide.color;
      expect(line, isNotNull);
      final palette = DesignPalette.of(
        tester.element(find.byKey(const Key('drive-text-field'))),
      );
      final c = _contrast(line!, palette.bg);
      expect(
        c,
        greaterThanOrEqualTo(3.0),
        reason: '输入面边界对页面底只有 ${c.toStringAsFixed(2)}:1',
      );
    });

    testWidgets('可写文本文件的菜单有"编辑文本"', (tester) async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Files.list': {
            'items': [_item(id: '1', name: 'notes.txt')],
            'total': 1,
          },
        },
      );
      final s = await _loggedIn(t);
      await _pumpWidget(
        tester,
        const Scaffold(body: DriveBrowseView()),
        api: s.api,
      );
      await tester.tap(find.byKey(const Key('drive-entry-menu-1')));
      await tester.pumpAndSettle();
      expect(find.text('编辑文本'), findsOneWidget);
    });
  });
}

/// WCAG 相对比度（与 /tmp/mbox.py 同一公式）
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}
