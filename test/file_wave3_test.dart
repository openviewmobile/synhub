// 文件模块 **wave3「共享给我的」** 的离线验证（`Sharing/list_share_me`）。
//
// 契约（真机取证 + 官方前端，照抄不猜）：
//   * **优先 v3、回落 v2，绝不发 v1**：v1 = 103（方法不存在）、v2 = OK、v3 = OK；
//     官方 Web 前端 `FileBrowser.js`（`SharingManager.Common.createStore`）
//     写的是 `version:3` → 按"与官方形态逐字对齐"先发 v3；只有 v2 的服务器回落 v2；
//   * 分页参名 **`offset`**（官方 `paramNames:{start:"offset"}` 的线上名）；
//   * 回包 root = **`data.links`**（另有 `total` / `offset`）；
//     真机空态：`{"data":{"links":[],"offset":0,"total":0},"success":true}`；
//   * 字段名来自官方前端 reader（`FileBrowser.js`
//     `SharingManager.Common.createStore`），线上原名 `date_expired` /
//     `date_available`、`isFolder`、`project_name`、`link_owner`。
//
// 这些用例同时是**falsification 的绿侧**：改了版本/参数名/空态/门控就必红。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/file_browse_page.dart';
import 'package:synhub/src/features/files/file_pages.dart';
import 'package:synhub/src/features/files/file_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

/// 一个够用的能力表：Sharing 默认 **v3**（真机同款区间），按需在用例里改小。
Map<String, Map<String, dynamic>> _table({
  int sharingMax = 3,
  bool sharing = true,
}) => {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  if (sharing)
    'SYNO.FileStation.Sharing': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': sharingMax,
    },
  'SYNO.FileStation.List': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

Future<({FileStationApi fs, FakeTransport t})> _api({
  int sharingMax = 3,
  bool sharing = true,
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, int> failures = const {},
}) async {
  final t = FakeTransport(
    Map<String, Map<String, dynamic>>.from(responses),
    _table(sharingMax: sharingMax, sharing: sharing),
  );
  t.failures.addAll(failures);
  final web = DsmWebApi(t);
  await web.discover();
  return (fs: FileStationApi(web), t: t);
}

Map<String, dynamic> get _emptyShareMe => {
  'links': <dynamic>[],
  'offset': 0,
  'total': 0,
};

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('list_share_me 协议形状', () {
    test('v3（官方前端版本；绝不发 v1）+ 分页参数名是 offset（不是 start）', () async {
      final (:fs, :t) = await _api();
      t.responses['SYNO.FileStation.Sharing.list_share_me'] = _emptyShareMe;

      await fs.listSharedWithMe();

      expect(t.calls.last['api'], 'SYNO.FileStation.Sharing');
      expect(t.calls.last['method'], 'list_share_me');
      // ⚠️ v1 在真机回 103（方法不存在）；官方前端发 version:3 → 先 v3
      expect(
        t.calls.last['version'],
        '3',
        reason: 'list_share_me 先发官方前端的 v3（v2 是回落；v1=103 绝不发）',
      );
      // ⚠️ 官方 paramNames 把 start 映射成线上 offset；我们直接发 offset
      expect(t.calls.last.containsKey('offset'), isTrue);
      expect(t.calls.last['offset'], 0);
      expect(
        t.calls.last.containsKey('start'),
        isFalse,
        reason: '分页起点字段名是 offset，不是 Ext 的本地名 start',
      );
      expect(t.calls.last['limit'], 1000);
    });

    test('只有 v2 的服务器 → 回落 v2（仍不发 v1）', () async {
      final (:fs, :t) = await _api(sharingMax: 2);
      t.responses['SYNO.FileStation.Sharing.list_share_me'] = _emptyShareMe;

      await fs.listSharedWithMe();

      expect(
        t.calls.last['version'],
        '2',
        reason: 'maxVersion 只有 2 时必须回落 v2，而不是退到 v1（v1=103）',
      );
      expect(t.calls.last.containsKey('offset'), isTrue);
    });

    test('offset/limit 原样下发；排序成对出现；filter_type 可选', () async {
      final (:fs, :t) = await _api();
      t.responses['SYNO.FileStation.Sharing.list_share_me'] = _emptyShareMe;

      await fs.listSharedWithMe(
        offset: 50,
        limit: 25,
        filterType: 'SYNO.SDS.App.FileStation3.Instance',
        sortBy: FileSortBy.name,
        sortDirection: FileSortDirection.desc,
      );

      expect(t.calls.last['offset'], 50);
      expect(t.calls.last['limit'], 25);
      expect(t.calls.last['filter_type'], 'SYNO.SDS.App.FileStation3.Instance');
      expect(t.calls.last['sort_by'], 'name');
      expect(t.calls.last['sort_direction'], 'desc');
    });

    test('回包 root 是 data.links；字段按官方 reader 的线上原名解析', () async {
      final (:fs, :t) = await _api();
      t.responses['SYNO.FileStation.Sharing.list_share_me'] = {
        'links': [
          {
            'id': 'LINK-ID-1',
            'url': 'https://nas.example.com:5001/sharing/abc',
            'link_owner': 'demo_user',
            'path': '/home/report.pdf',
            'name': 'report.pdf',
            'date_expired': '2026-12-31 23:59:59',
            'date_available': '2026-01-01 00:00:00',
            'expire_times': 3,
            'protect_users': ['alice'],
            'protect_groups': ['staff'],
            'status': 'ok',
            'protect_type': 'password',
            'qrcode': 'QR',
            'isFolder': false,
            'enable_upload': true,
            'request_name': 'req',
            'request_info': 'info',
            'limit_size': 1024,
            'project_name': 'SYNO.SDS.App.FileStation3.Instance',
          },
        ],
        'total': 1,
        'offset': 0,
      };

      final res = await fs.listSharedWithMe();

      expect(res.total, 1);
      expect(res.offset, 0);
      final link = res.links.single;
      expect(link.id, 'LINK-ID-1');
      expect(link.name, 'report.pdf');
      expect(link.path, '/home/report.pdf');
      expect(link.linkOwner, 'demo_user');
      expect(link.dateExpired, '2026-12-31 23:59:59');
      expect(link.dateAvailable, '2026-01-01 00:00:00');
      expect(link.isFolder, isFalse);
      expect(link.hasPassword, isTrue);
      expect(link.isOk, isTrue);
      expect(link.projectName, 'SYNO.SDS.App.FileStation3.Instance');
      expect(link.protectUsers, ['alice']);
      expect(link.expireTimes, 3);
    });

    test('真机空态 {links:[],offset:0,total:0} 解析成空表（不是错误）', () async {
      final (:fs, :t) = await _api();
      t.responses['SYNO.FileStation.Sharing.list_share_me'] = _emptyShareMe;

      final res = await fs.listSharedWithMe();

      expect(res.isEmpty, isTrue);
      expect(res.total, 0);
      expect(res.links, isEmpty);
    });

    test('status 分支照官方列模型：broken/expired/inactive 之外都是 ok', () {
      expect(
        const SharedWithMeLinkDto(id: 'x', status: 'broken').isOk,
        isFalse,
      );
      expect(
        const SharedWithMeLinkDto(id: 'x', status: 'expired').isOk,
        isFalse,
      );
      expect(
        const SharedWithMeLinkDto(id: 'x', status: 'inactive').isOk,
        isFalse,
      );
      expect(const SharedWithMeLinkDto(id: 'x', status: 'ok').isOk, isTrue);
      expect(const SharedWithMeLinkDto(id: 'x').isOk, isTrue);
    });
  });

  group('能力门控 canShareWithMe（统一 FileCapabilities 机制）', () {
    test('Sharing v2/v3 → 有「共享给我的」', () async {
      final v3 = await _api(sharingMax: 3);
      expect(FileCapabilities.probe(v3.fs).canShareWithMe, isTrue);
      final v2 = await _api(sharingMax: 2);
      expect(FileCapabilities.probe(v2.fs).canShareWithMe, isTrue);
    });

    test('Sharing 只有 v1（list_share_me 不存在）→ 无', () async {
      final (:fs, :t) = await _api(sharingMax: 1);
      expect(FileCapabilities.probe(fs).canShareWithMe, isFalse);
    });

    test('根本没有 Sharing → 无', () async {
      final (:fs, :t) = await _api(sharing: false);
      expect(FileCapabilities.probe(fs).canShareWithMe, isFalse);
    });

    test('API 表没拉到（未登录）→ fail-open（与其余能力位一致）', () {
      const blank = FileCapabilities();
      expect(blank.canShareWithMe, isTrue);
      expect(FileCapabilities.probe(null).canShareWithMe, isTrue);
    });
  });

  group('「共享给我的」UI', () {
    Future<({FileStationApi fs, FakeTransport t, ChatDatabase db})> boot({
      int sharingMax = 3,
      bool sharing = true,
      Map<String, Map<String, dynamic>> responses = const {},
      Map<String, int> failures = const {},
    }) async {
      final api = await _api(
        sharingMax: sharingMax,
        sharing: sharing,
        responses: responses,
        failures: failures,
      );
      final db = ChatDatabase(NativeDatabase.memory());
      return (fs: api.fs, t: api.t, db: db);
    }

    Future<void> pump(
      WidgetTester tester,
      FileStationApi fs,
      ChatDatabase db,
    ) async {
      final container = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          fileApiProvider.overrideWithValue(fs),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.dark(), home: FileShareLinksPage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }

    Future<void> openWithMeTab(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('shared-with-me-tab')));
      await tester.pumpAndSettle();
    }

    testWidgets('空 links → 明确空态"还没有人分享给你"（不是加载失败）', (tester) async {
      final b = await boot(
        responses: {'SYNO.FileStation.Sharing.list_share_me': _emptyShareMe},
      );
      await pump(tester, b.fs, b.db);
      await openWithMeTab(tester);

      expect(find.text('还没有人分享给你'), findsOneWidget);
      expect(find.textContaining('别人分享给你的文件'), findsOneWidget);
      // 空态不是错误：不得出现错误页/重试
      expect(find.textContaining('加载失败'), findsNothing);
      expect(find.text('重试'), findsNothing);
    });

    testWidgets('有 links → 渲染 name/path/来自/状态；id 绝不上屏', (tester) async {
      final b = await boot(
        responses: {
          'SYNO.FileStation.Sharing.list_share_me': {
            'links': [
              {
                'id': 'LINK-ID-42',
                'name': '季度报告',
                'path': '/home/report.pdf',
                'link_owner': 'demo_user',
                'status': 'ok',
                'isFolder': false,
                'project_name': 'SYNO.SDS.App.FileStation3.Instance',
              },
            ],
            'total': 1,
            'offset': 0,
          },
        },
      );
      await pump(tester, b.fs, b.db);
      await openWithMeTab(tester);

      expect(find.text('季度报告'), findsOneWidget);
      expect(find.textContaining('/home/report.pdf'), findsOneWidget);
      expect(find.textContaining('来自 demo_user'), findsOneWidget);
      // 类型标签（project_name → 官方 getTypeArray 的文案）与状态同行
      expect(find.textContaining('分享链接 · 来自'), findsOneWidget);
      // ⚠️ 内部 id 只能出现在 Key / 断言里
      expect(find.textContaining('LINK-ID-42'), findsNothing);
      expect(
        find.byKey(const Key('shared-with-me-LINK-ID-42')),
        findsOneWidget,
      );
    });

    testWidgets('点条目 → 复用既有浏览路径（FileBrowsePage）', (tester) async {
      final b = await boot(
        responses: {
          'SYNO.FileStation.Sharing.list_share_me': {
            'links': [
              {
                'id': 'L1',
                'name': '共享目录',
                'path': '/share/team',
                'link_owner': 'demo_user',
                'status': 'ok',
                'isFolder': true,
              },
            ],
            'total': 1,
            'offset': 0,
          },
          'SYNO.FileStation.List.list_share': {
            'shares': <dynamic>[],
            'total': 0,
          },
          'SYNO.FileStation.List.list': {'files': <dynamic>[], 'total': 0},
        },
      );
      await pump(tester, b.fs, b.db);
      await openWithMeTab(tester);
      await tester.tap(find.byKey(const Key('shared-with-me-L1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(FileBrowsePage), findsOneWidget);
    });

    testWidgets('门控：Sharing 只到 v1 → 「共享给我的」入口/Tab 不渲染', (tester) async {
      final b = await boot(
        sharingMax: 1,
        responses: {
          'SYNO.FileStation.Sharing.list': {
            'links': <dynamic>[],
            'total': 0,
            'offset': 0,
          },
        },
      );
      await pump(tester, b.fs, b.db);

      expect(find.byKey(const Key('shared-with-me-tab')), findsNothing);
      // 也没有任何"还没有人分享给你"之类残留
      expect(find.textContaining('共享给我的'), findsNothing);
    });

    testWidgets('没有 Sharing API → 入口不渲染', (tester) async {
      final b = await boot(sharing: false);
      await pump(tester, b.fs, b.db);
      expect(find.byKey(const Key('shared-with-me-tab')), findsNothing);
    });

    testWidgets('门控开启 → Tab 出现', (tester) async {
      final b = await boot(
        responses: {'SYNO.FileStation.Sharing.list_share_me': _emptyShareMe},
      );
      await pump(tester, b.fs, b.db);
      expect(find.byKey(const Key('shared-with-me-tab')), findsOneWidget);
    });
  });
}
