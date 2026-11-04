// Drive P3 页面层验证：版本历史 / 共享 / 标签（`drive_revisions_page.dart`、
// `drive_share_page.dart`、`drive_labels_page.dart`）。
//
// 形状全部来自真机探针（`tool/drive_p3_impl_probe.dart` / `drive_p3_shape2.dart` /
// `drive_share_probe.dart`），接口层用例在 `test/drive_api_test.dart`；这里只验
// "页面把请求发对了、把回包显示对了、写操作后有反馈"。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_entry_dto.dart';
import 'package:synhub/src/data/dto/drive_label_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/drive_labels_page.dart';
import 'package:synhub/src/features/files/drive_more_page.dart';
import 'package:synhub/src/features/files/drive_providers.dart';
import 'package:synhub/src/features/files/drive_revisions_page.dart';
import 'package:synhub/src/features/files/drive_share_page.dart';
import 'package:synhub/src/data/local/analytics_database.dart';
import 'package:synhub/src/features/analytics/analytics_track.dart';
import 'package:synhub/src/features/analytics/usage_event.dart';
import 'package:synhub/src/features/analytics/usage_log.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _driveTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.SynologyDrive.Revisions': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.SynologyDrive.Sharing': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.SynologyDrive.AdvanceSharing': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.SynologyDrive.Share.Priv': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.SynologyDrive.Labels': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.SynologyDrive.Trash': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

DriveEntryDto _file({
  String name = '报告.docx',
  String fileId = '9',
  String versionId = '65',
  List<DriveLabelDto> labels = const [],
}) => DriveEntryDto(
  fileId: fileId,
  name: name,
  type: 'file',
  path: '/$name',
  displayPath: '/mydrive/$name',
  parentId: '1',
  size: 2048,
  modifiedTime: 1789775507,
  createdTime: 1789775501,
  contentType: 'document',
  starred: false,
  shared: false,
  owner: 'demo_user',
  canDownload: true,
  canPreview: true,
  canWrite: true,
  capabilities: const {'can_write': true},
  versionId: versionId,
  labels: labels,
);

/// 挂一个页面（Drive 的 api 覆盖 + 内存库）
Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
}) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._driveTable});
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    if (responses.containsKey(key)) return responses[key]!;
    return {'success': true};
  };
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      driveApiProvider.overrideWithValue(DriveApi(api)),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  return (t: t, c: c);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('版本历史页', () {
    testWidgets('列出各版本、标出当前版本、恢复要走确认', (tester) async {
      final boot = await _pump(
        tester,
        DriveRevisionsPage(entry: _file()),
        responses: {
          'SYNO.SynologyDrive.Revisions.list': {
            'items': [
              {
                'version_id': 65,
                'size': 2048,
                'modified_time': 1789775507,
                'editor_display_name': 'demo_user',
              },
              {
                'version_id': 64,
                'size': 1024,
                'modified_time': 1789775100,
                'editor_display_name': 'demo_user',
              },
            ],
            'total': 2,
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('版本历史'), findsOneWidget);
      expect(find.textContaining('当前版本'), findsOneWidget);
      expect(find.textContaining('2.0 KB'), findsWidgets);
      expect(find.textContaining('版本号 64'), findsOneWidget);

      // 恢复要二次确认（真机语义：恢复会再生成一个新版本）
      await tester.tap(find.byTooltip('恢复到这个版本'));
      await tester.pumpAndSettle();
      expect(find.text('恢复到这个版本？'), findsOneWidget);
      await tester.tap(find.text('恢复'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final restore = boot.t.calls.lastWhere(
        (c) => c['method'] == 'restore',
        orElse: () => const {},
      );
      expect(restore['files'], '[{"path":"id:9","version_id":64}]');
      expect(restore['conflict_action'], 'version');
    });
  });

  group('共享页', () {
    testWidgets('公开链接能拿到并复制；成员列表显示角色', (tester) async {
      final boot = await _pump(
        tester,
        DriveSharePage(entry: _file()),
        responses: {
          'SYNO.SynologyDrive.Sharing.create_link': {
            'url': 'https://nas/d/f/abc',
          },
          'SYNO.SynologyDrive.Sharing.list': {
            'items': [
              {
                'permission_id': 1,
                'name': 'demo_user',
                'type': 'user',
                'role': 'viewer',
                'inherited': false,
              },
            ],
            'total': 1,
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('https://nas/d/f/abc'), findsOneWidget);
      expect(find.text('demo_user'), findsOneWidget);
      expect(find.textContaining('仅查看'), findsOneWidget);

      // 复制链接 → 剪贴板 + 提示。
      // ⚠️ 测试环境里 `Clipboard.getData` 没有平台实现，await 会永远挂住；
      // 所以要自己挂 `SystemChannels.platform` 的 mock 来截获 `Clipboard.setData`。
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      await tester.tap(find.text('复制链接'));
      await tester.pump();
      expect(copied, 'https://nas/d/f/abc');
      expect(find.text('链接已复制'), findsOneWidget);
      expect(boot.t.calls.any((c) => c['method'] == 'create_link'), isTrue);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    // ★ DA19（r380 修法）：这条链接**服务端没有撤销方法**（r378 逐字查过
    // `SYNO.SynologyDrive.Sharing` 只有 `list/update/create_link/use_link/
    // sync_to_device`），所以本页必须①**不把它叫成可撤销的「公开链接」**、
    // ②把"关得掉"的那条通道（`AdvanceSharing` 的「关闭链接」）指出来。
    testWidgets('DA19：改叫「永久打开链接」+ 说清关不掉 + 指到公开分享管理', (tester) async {
      await _pump(
        tester,
        DriveSharePage(entry: _file()),
        responses: {
          'SYNO.SynologyDrive.Sharing.create_link': {
            'url': 'https://nas/d/f/abc',
          },
          'SYNO.SynologyDrive.Sharing.list': {'items': const [], 'total': 0},
        },
      );
      await tester.pump(const Duration(milliseconds: 300));

      // ① 措辞不再暗示"这里能撤销"
      expect(find.text('永久打开链接'), findsOneWidget);
      expect(
        find.text('公开链接'),
        findsNothing,
        reason: '★ DA19：本页那条通道服务端没有撤销方法，不许再叫「公开链接」',
      );
      // ② 把"关不掉"说清楚（诚实文案，不是诊断串）
      expect(
        find.byKey(const Key('drive-permanent-link-note')),
        findsOneWidget,
      );
      expect(find.textContaining('本页关不掉它'), findsOneWidget);
      expect(find.textContaining('关闭公开链接'), findsOneWidget);
      // ③ 撤销入口指向真的能关的那条通道
      expect(
        find.byKey(const Key('drive-manage-public-sharing')),
        findsOneWidget,
      );
      expect(find.text('公开分享管理'), findsOneWidget);
    });

    testWidgets('DA19：点「公开分享管理」进的是带「关闭链接」的 AdvanceSharing 页；且没有删除类调用', (
      tester,
    ) async {
      final boot = await _pump(
        tester,
        DriveSharePage(entry: _file()),
        responses: {
          'SYNO.SynologyDrive.Sharing.create_link': {
            'url': 'https://nas/d/f/abc',
          },
          'SYNO.SynologyDrive.Sharing.list': {'items': const [], 'total': 0},
          // 高级共享页的进页读数（纯读）
          'SYNO.SynologyDrive.AdvanceSharing.get': {
            'path': 'id:9',
            'sharing_link': 'https://nas/d/s/zzz',
            'url': 'https://nas/d/s/zzz',
            'role': 'viewer',
            'expire_date': 0,
            'protect_password': '',
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byKey(const Key('drive-manage-public-sharing')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 到了真的能关的那条通道：页面 + 「关闭链接」按钮都在场
      expect(
        find.byKey(const Key('drive-advance-sharing-page')),
        findsOneWidget,
        reason: '★ DA19：撤销入口必须落在 AdvanceSharing（它的 `delete` 才是契约里的关闭链接）',
      );
      expect(
        find.byKey(const Key('drive-advance-sharing-close')),
        findsOneWidget,
      );

      // ★ 反向：只是"进入"这条通道，**不许**有任何删除/撤销调用
      const mutating = {
        'SYNO.SynologyDrive.AdvanceSharing.delete',
        'SYNO.SynologyDrive.Sharing.delete_link',
        'SYNO.SynologyDrive.Sharing.remove_link',
        'SYNO.SynologyDrive.Sharing.delete',
      };
      for (final call in boot.t.calls) {
        final key = '${call['api']}.${call['method']}';
        expect(
          mutating.contains(key),
          isFalse,
          reason: '★ DA19 反向：打开管理页不得触发 $key',
        );
      }
    });

    // ★ 静态契约守卫（DA19）：本页**不许**出现任何"删链接"调用 ——
    // 服务端那条通道本来就没有撤销方法（r378 逐字：`Sharing` v1/v2 =
    // list/update/create_link/use_link/sync_to_device(+v2 get_base_url)），
    // 补一个 `delete_link` 只会造出**官方不存在的方法调用**。
    test('DA19：共享页源码不含删链接调用，且撤销入口指向 AdvanceSharing', () {
      final src = File('lib/src/features/files/drive_share_page.dart')
          .readAsStringSync();
      for (final banned in const [
        'delete_link',
        'remove_link',
        'deleteAdvanceSharing',
        'AdvanceSharing/delete',
      ]) {
        expect(
          src.contains(banned),
          isFalse,
          reason: '★ DA19：drive_share_page.dart 不许出现 $banned（服务端无此方法）',
        );
      }
      expect(src.contains('DriveAdvanceSharingPage('), isTrue);
      expect(src.contains('driveManagePublicSharing'), isTrue);
    });

    testWidgets('邀请：搜账号 → 选权限 → `Sharing/update` 带上 permissions', (
      tester,
    ) async {
      final boot = await _pump(
        tester,
        DriveSharePage(entry: _file()),
        responses: {
          'SYNO.SynologyDrive.Sharing.create_link': {
            'url': 'https://nas/d/f/abc',
          },
          'SYNO.SynologyDrive.Sharing.list': {'items': const [], 'total': 0},
          'SYNO.SynologyDrive.Share.Priv.list': {
            'list': [
              {
                'id': 1027,
                'name': 'demo_user',
                'nickname': 'demo',
                'type': 'user',
              },
            ],
            'offset': 0,
            'total': 1,
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byTooltip('邀请'));
      // ⚠️ 弹层里有 autofocus 输入框：光标闪烁动画让 `pumpAndSettle` 永不返回，
      // 所以这里（以及下面）一律用定长 pump
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('demo_user'), findsOneWidget);
      // ★ r491：结果行换 `DesignRowTile` 后行高变了 ⇒ 先滚到可见再点，
      //   否则点到的是弹层的空白处（后面 `可编辑` 根本不会出现）。
      await tester.ensureVisible(find.textContaining('demo_user'));
      await tester.pump();
      await tester.tap(find.textContaining('demo_user'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // 选「可编辑」
      // ★★★ r332：真实产品主题下这一页更长（字体/间距来自 `AppTheme`）⇒ 权限 chip 会
      // **落到 800x600 的可视区之外**（实测中心 y=607.5），直接 `tap` 会命中不到、
      // 于是 `Sharing/update` **根本没发**（修前这条用例就是这么红的）。
      // 判据按"可达"写：先滚到它，再点（AGENTS §2.0.49③ / §2.0.61④）。
      await tester.ensureVisible(find.text('可编辑'));
      await tester.pump();
      await tester.tap(find.text('可编辑'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final update = boot.t.calls.lastWhere(
        (c) => c['method'] == 'update',
        orElse: () => const {},
      );
      expect(update['path'], 'id:9');
      expect(
        update['permissions'],
        '[{"action":"update","member":{"type":"user","name":"demo_user"},'
        '"role":"editor"}]',
      );
    });
  });

  group('标签页', () {
    testWidgets('列出标签 + 新建 + 删除', (tester) async {
      final boot = await _pump(
        tester,
        const DriveLabelsPage(),
        responses: {
          'SYNO.SynologyDrive.Labels.list': {
            'items': [
              {
                'label_id': 3,
                'name': '重要',
                'color': '#ff8800',
                'type': 'personal_label',
              },
            ],
            'total': 1,
          },
          'SYNO.SynologyDrive.Labels.create': {
            'label_id': 4,
            'name': '项目',
            'color': '#000000',
            'type': 'personal_label',
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('重要'), findsOneWidget);

      // 新建
      await tester.tap(find.byTooltip('新建标签'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField), '项目');
      await tester.tap(find.text('确定'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final create = boot.t.calls.lastWhere(
        (c) => c['method'] == 'create',
        orElse: () => const {},
      );
      expect(create['name'], '"项目"');

      // 删除（从 ⋮ 菜单）
      await tester.tap(find.byTooltip('更多'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('删除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('删除').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final del = boot.t.calls.lastWhere(
        (c) => c['method'] == 'delete',
        orElse: () => const {},
      );
      expect(del['label_id'], '"3"');
    });

    testWidgets('标签下的文件（`Files/list_labelled`）', (tester) async {
      await _pump(
        tester,
        const DriveLabelledPage(
          label: DriveLabelDto(
            labelId: '3',
            name: '重要',
            color: '#ff8800',
            position: 0,
            type: 'personal_label',
          ),
        ),
        responses: {
          'SYNO.SynologyDrive.Files.list_labelled': {
            'items': [
              {'file_id': '9', 'name': 'a.txt', 'type': 'file', 'size': 10},
            ],
            'total': 1,
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('a.txt'), findsOneWidget);
    });

    testWidgets('给文件打标签：勾选已有 + 新建并勾选 → `Files/label` 动作数组', (tester) async {
      final boot = await _pump(
        tester,
        _PickerHost(entry: _file()),
        responses: {
          'SYNO.SynologyDrive.Labels.list': {
            'items': [
              {
                'label_id': 3,
                'name': '重要',
                'color': '#ff8800',
                'type': 'personal_label',
              },
              {
                'label_id': 5,
                'name': '待办',
                'color': '#007aff',
                'type': 'personal_label',
              },
            ],
            'total': 2,
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('打开标签选择'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 勾上「待办」（当前文件没有任何标签）
      await tester.tap(find.text('待办'));
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final label = boot.t.calls.lastWhere(
        (c) => c['method'] == 'label',
        orElse: () => const {},
      );
      expect(label['files'], '["id:9"]');
      expect(label['labels'], '[{"action":"add","label_id":5}]');
    });

    // 新建入口：真机上"弹层里内嵌 TextField"点不聚焦，改成对话框；
    // 这里钉住"点按钮 → 对话框 → 填名 → 确定 → createLabel 并把新标签勾上"。
    testWidgets('新建标签并勾选：对话框填名 → `Labels/create` → 保存带上新 id', (tester) async {
      final boot = await _pump(
        tester,
        _PickerHost(entry: _file()),
        responses: {
          'SYNO.SynologyDrive.Labels.list': {'items': const [], 'total': 0},
          'SYNO.SynologyDrive.Labels.create': {
            'label_id': 8,
            'name': '新标签',
            'color': '#ff8800',
            'type': 'personal_label',
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('打开标签选择'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('新建标签并勾选'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField), '新标签');
      await tester.tap(find.text('确定'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(boot.t.calls.where((c) => c['method'] == 'create').length, 1);

      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final label = boot.t.calls.lastWhere(
        (c) => c['method'] == 'label',
        orElse: () => const {},
      );
      expect(label['labels'], '[{"action":"add","label_id":8}]');
    });
  });

  group('Drive「更多」页的标签段', () {
    testWidgets('五段（多出「标签」）且能滑到标签段', (tester) async {
      await _pump(
        tester,
        const DriveMorePage(),
        responses: {
          'SYNO.SynologyDrive.Trash.list': {'items': const [], 'total': 0},
          'SYNO.SynologyDrive.Trash.get_size': {'size': 0, 'total': 0},
          'SYNO.SynologyDrive.Labels.list': {
            'items': [
              {
                'label_id': 3,
                'name': '重要',
                'color': '#ff8800',
                'type': 'personal_label',
              },
            ],
            'total': 1,
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('标签'), findsOneWidget);

      // 左滑四次到标签段（回收站→星标→共享给我→团队文件夹→标签）
      final pager = find.byKey(const Key('drive-more-pager'));
      for (var i = 0; i < 4; i++) {
        await tester.fling(pager, const Offset(-600, 0), 1200);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.text('1 个个人标签'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // 埋点回归：以前**只有左右滑**才记 `switch_section`，点 chip 是漏的
  // （真机验证时发现"点了标签段但日志里没有"）。这里把两种入口都钉住。
  group('板块切换埋点', () {
    Future<UsageLog> arm() async {
      final db = AnalyticsDatabase.memory();
      final log = UsageLog(db);
      await log.load();
      setGlobalUsageLog(log);
      addTearDown(() async {
        setGlobalUsageLog(null);
        log.dispose();
        await db.close();
      });
      return log;
    }

    Future<List<UsageEvent>> drain(WidgetTester tester, UsageLog log) async {
      await tester.runAsync(() => log.flush());
      final rows = await tester.runAsync(() => log.recent());
      return rows!;
    }

    testWidgets('Drive 更多：点 chip 记一条', (tester) async {
      final log = await arm();
      await _pump(
        tester,
        const DriveMorePage(),
        responses: {
          'SYNO.SynologyDrive.Trash.list': {'items': const [], 'total': 0},
          'SYNO.SynologyDrive.Trash.get_size': {'size': 0, 'total': 0},
          'SYNO.SynologyDrive.Labels.list': {
            'items': [
              {
                'label_id': 3,
                'name': '重要',
                'color': '#ff8800',
                'type': 'personal_label',
              },
            ],
            'total': 1,
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('标签'));
      await tester.pump(const Duration(milliseconds: 400));

      final rows = await drain(tester, log);
      expect(rows.single.module, UsageModule.drive);
      expect(rows.single.action, UsageAction.switchSection);
      expect(rows.single.objectType, 'labels');
    });

    testWidgets('Drive 更多：左右滑记的是目标段', (tester) async {
      final log = await arm();
      await _pump(
        tester,
        const DriveMorePage(),
        responses: {
          'SYNO.SynologyDrive.Trash.list': {'items': const [], 'total': 0},
          'SYNO.SynologyDrive.Trash.get_size': {'size': 0, 'total': 0},
          'SYNO.SynologyDrive.Starred.list': {'items': const [], 'total': 0},
          'SYNO.SynologyDrive.Share.list': {'items': const [], 'total': 0},
        },
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.fling(
        find.byKey(const Key('drive-more-pager')),
        const Offset(-600, 0),
        1200,
      );
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 400));
      }

      final rows = await drain(tester, log);
      expect(rows.single.action, UsageAction.switchSection);
      expect(rows.single.objectType, 'starred');
    });
  });
}

/// 测试壳：一个按钮触发 [showDriveLabelPicker]（真实入口在 Drive 行的 ⋮ 菜单）
class _PickerHost extends ConsumerWidget {
  const _PickerHost({required this.entry});

  final DriveEntryDto entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: Center(
      child: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => showDriveLabelPicker(ctx, ref, entry),
          child: const Text('打开标签选择'),
        ),
      ),
    ),
  );
}
