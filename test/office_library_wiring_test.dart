// Office 批 D **接线**测试：入口出现/隐藏（能力门控）、从模板新建后落到新文档、
// 主题与只读版本页可达。
//
// 覆盖范围刻意**只**覆盖本任务新加的接线层（`office_library_page.dart` +
// `office_page.dart` 的 AppBar + `drive_browse_view.dart` 的两个菜单项）；
// 批 D 的 widget 内部逻辑由 `office_library_test.dart` 负责。
//
// 无网络 / 无设备 / 无构建。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/office_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/drive_browse_view.dart';
import 'package:synhub/src/features/files/drive_providers.dart';
import 'package:synhub/src/features/files/office_page.dart';
import 'package:synhub/src/features/files/office_providers.dart';
import 'package:synhub/src/features/office/office_doc_page.dart';
import 'package:synhub/src/features/office/office_library_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _officeTable = {
  'SYNO.Office.Template': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Office.Theme': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Office.Node': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Office.Node.Encrypt': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Office.Node.Version': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
};

const _allWiringApis = {
  kOfficeTemplateApi,
  kOfficeThemeApi,
  kOfficeNodeApi,
  kOfficeEncryptApi,
  kOfficeVersionApi,
  'SYNO.SynologyDrive.Files',
};

// 本文件用到的 Office API 名（本地常量，避免依赖禁止改动区的登记表）。
const String kOfficeNodeApi = 'SYNO.Office.Node';
const String kOfficeEncryptApi = 'SYNO.Office.Node.Encrypt';

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);

  final ServiceAvailabilitySnapshot snapshot;

  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

ServiceAvailabilitySnapshot _snap(Set<String> apis) =>
    ServiceAvailabilitySnapshot(
      states: {
        for (final s in StationService.values) s: AvailabilityState.available,
      },
      apis: apis,
      checkedAt: DateTime(2026, 9, 22),
    );

Map<String, dynamic> _templates() => {
  'items': [
    {
      'capabilities': {'can_read': true, 'can_preview': true},
      'ntype': 'doc',
      'object_id': '1_invoice.tpl.doc',
      'perm': 'ro',
      'system': true,
      'title': 'template_doc:invoice',
    },
  ],
};

/// `Template:make` 真机回**完整 Drive 节点**（批 D §3）；这里造一个 `.odoc`。
Map<String, dynamic> _madeNode() => {
  'file_id': '77',
  'name': 'Untitled.odoc',
  'type': 'file',
  'display_path': '/mydrive/Untitled.odoc',
  'dsm_path': '/home/Drive/Untitled.odoc',
  'parent_id': '1',
  'permanent_link': 'link-77',
  'capabilities': {
    'can_read': true,
    'can_write': true,
    'can_download': true,
    'can_preview': true,
  },
};

Map<String, dynamic> _driveItem({
  required String name,
  bool permanentLink = true,
}) => {
  'file_id': name.startsWith('deck') ? '5' : '6',
  'name': name,
  'type': 'file',
  'path': '/$name',
  'display_path': '/mydrive/$name',
  'parent_id': '1',
  'size': 1024,
  'modified_time': 1789775507,
  'content_type': 'file',
  if (permanentLink)
    'permanent_link': 'link-${name.startsWith('deck') ? '5' : '6'}',
  'capabilities': {
    'can_download': true,
    'can_preview': true,
    'can_write': true,
    'can_lock': true,
  },
  'node_locking': {'is_locked': false},
};

Map<String, dynamic> _versions() => {
  'versions': [
    {
      'author': 'demo_user',
      'version': '3',
      'mtime': 1789775507,
      'editors': <String>[],
      'ver_name': '',
      'first_version': false,
      'listable': true,
      'title': 'Untitled.odoc',
    },
  ],
};

typedef _Tab = ({FakeTransport t, ProviderContainer c});

Future<_Tab> _boot(
  WidgetTester tester,
  Widget page, {
  Set<String> apis = _allWiringApis,
  Map<String, dynamic>? Function(Map<String, dynamic> params)? onCall,
  Size size = const Size(900, 1400),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final t = FakeTransport(const {}, {...FakeTransport.table, ..._officeTable});
  t.onCall = onCall ?? (params) => const <String, dynamic>{};
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      driveApiProvider.overrideWithValue(DriveApi(api)),
      officeApiProvider.overrideWithValue(OfficeApi(api)),
      serviceAvailabilityProvider.overrideWith(
        () => _FixedAvailability(_snap(apis)),
      ),
    ],
  );
  addTearDown(c.dispose);
  addTearDown(db.close);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return (t: t, c: c);
}

/// 是否存在以某前缀开头的 key（用于判定"是否落在新 Office 页面"）。
///
/// ⚠️ 为什么不直接断言 `office-doc-loading`：**加载态会立刻流转**。
/// 在本测试的 FakeTransport 下，Office 接口不在表里 ⇒ 回 `102`
/// ⇒ 页面很快进入 `office-doc-failure`，断言 loading 会假红。
/// 实测（2026-09-22 诊断输出）点击后屏幕上是：
///   keys 含 `office-doc-failure`；文案 = 打开失败 / DSM 102 / 重试 / 改用只读预览
/// ⇒ **这正好证明路由走到了【新】的 OfficeDocPage**。
bool _hasKeyPrefix(String prefix) => find
    .byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith(prefix),
    )
    .evaluate()
    .isNotEmpty;

/// 关掉"这是你的「我的文件」…"引导横幅。
///
/// ⚠️ **这不是可选步骤**：横幅在列表**上方**，真机实测点击它会消失并**顶动列表**，
/// 导致随后的行点击**落到错误的位置**（本会话已记录该陷阱）。
/// 测试里同理——不先关掉，点行会打不中。
Future<void> _dismissScopeIntro(WidgetTester tester) async {
  final btn = find.byKey(const Key('drive-scope-dismiss'));
  if (btn.evaluate().isEmpty) return;
  await tester.tap(btn);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> _openRowMenu(WidgetTester tester, String fileId) async {
  await tester.tap(find.byKey(Key('drive-entry-menu-$fileId')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('能力门控（纯函数，复用统一可用性快照）', () {
    test('能力表缺 Template / Theme → 对应入口判定为不可用', () {
      final full = _snap(_allWiringApis);
      expect(officeTemplateLibraryAvailable(full), isTrue);
      expect(officeThemePickerAvailable(full), isTrue);

      final noTemplate = _snap({..._allWiringApis}..remove(kOfficeTemplateApi));
      expect(officeTemplateLibraryAvailable(noTemplate), isFalse);
      expect(
        officeThemePickerAvailable(noTemplate),
        isTrue,
        reason: '缺 Template 不该把 Theme 一起隐藏',
      );
    });

    test('未检测（能力表为空）→ fail-open，不因不确定隐藏', () {
      final unknown = ServiceAvailabilitySnapshot(
        states: {
          for (final s in StationService.values) s: AvailabilityState.unknown,
        },
      );
      expect(officeTemplateLibraryAvailable(unknown), isTrue);
      expect(officeThemePickerAvailable(unknown), isTrue);
      expect(officeReadOnlyVersionsAvailable(unknown), isTrue);
    });

    test('只读版本通道：能力表缺 Node.Version → 不可用；在 → 可用', () {
      expect(officeReadOnlyVersionsAvailable(_snap(_allWiringApis)), isTrue);
      expect(
        officeReadOnlyVersionsAvailable(
          _snap({..._allWiringApis}..remove(kOfficeVersionApi)),
        ),
        isFalse,
      );
    });
  });

  group('从模板新建的回包 → 可打开条目', () {
    test('完整 Drive 节点 → fileId/name 正确', () {
      final entry = officeEntryFromMadeNode(_madeNode());
      expect(entry, isNotNull);
      expect(entry!.fileId, '77');
      expect(entry.name, 'Untitled.odoc');
      expect(entry.extension, 'odoc');
    });

    test('缺 file_id → 返回 null（宁可不打开，也不落到错的文档）', () {
      expect(
        officeEntryFromMadeNode({..._madeNode()}..remove('file_id')),
        isNull,
      );
    });

    test('★ D13：真机回包只有 file_id/display_path（没有 name）→ 名字取路径末段', () {
      // 真机形态（`Template:make` v1）：`{file_id, link_id, display_path, perm}`。
      final entry = officeEntryFromMadeNode(const {
        'file_id': '900',
        'link_id': 'LINK-900',
        'display_path': '/mydrive/我的发票.odoc',
        'perm': 'rw',
      });
      expect(entry, isNotNull);
      expect(entry!.fileId, '900');
      expect(entry.name, '我的发票.odoc');
      expect(entry.extension, 'odoc');
      // 打开路径靠 display_path → File Station 真实路径（不依赖 Drive 索引）。
      expect(entry.displayPath, '/mydrive/我的发票.odoc');
    });

    test('★ D13：name 与 display_path 都缺 → 仍返回 null（不编名字）', () {
      expect(
        officeEntryFromMadeNode({..._madeNode()}..remove('name')..remove('display_path')),
        isNull,
      );
    });

    test('officePathBasename：末段 / 空 / 纯根', () {
      expect(officePathBasename('/mydrive/a.odoc'), 'a.odoc');
      expect(officePathBasename('/mydrive/'), 'mydrive');
      expect(officePathBasename('a.odoc'), 'a.odoc');
      expect(officePathBasename(''), '');
      expect(officePathBasename('/'), '');
    });
  });

  group('OfficePage：模板库入口（AppBar）', () {
    testWidgets('能力齐全 → 入口在；点击进入模板库页', (tester) async {
      await _boot(
        tester,
        const OfficePage(title: 'Office'),
        onCall: (params) =>
            '${params['api']}.${params['method']}' ==
                'SYNO.Office.Template.list'
            ? _templates()
            : const <String, dynamic>{},
      );
      expect(find.byKey(const Key('office-page-templates')), findsOneWidget);

      await tester.tap(find.byKey(const Key('office-page-templates')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const Key('office-template-library-page')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('office-template-list')), findsOneWidget);
    });

    testWidgets('能力表缺 SYNO.Office.Template → 入口隐藏（点了报错的按钮不存在）', (tester) async {
      await _boot(
        tester,
        const OfficePage(title: 'Office'),
        apis: {..._allWiringApis}..remove(kOfficeTemplateApi),
      );
      expect(find.byKey(const Key('office-page-templates')), findsNothing);
      // 页面本身照常（不因缺一个可选入口而隐藏）
      expect(find.byKey(const Key('office-page')), findsOneWidget);
    });
  });

  group('从模板新建成功后落到新建出来的文档（复用 driveOpenEntry）', () {
    testWidgets('make 的参数正确，且导航到新文档的只读页', (tester) async {
      final boot = await _boot(
        tester,
        const OfficeTemplateLibraryPage(),
        onCall: (params) {
          switch ('${params['api']}.${params['method']}') {
            case 'SYNO.Office.Template.list':
              return _templates();
            case 'SYNO.Office.Template.make':
              return _madeNode();
            default:
              return const <String, dynamic>{};
          }
        },
      );

      // 第 260 轮新交互：点卡片 → 全屏预览 → 「使用此模板」→ 标题对话框。
      await tester.tap(
        find.byKey(const Key('office-template-item-1_invoice.tpl.doc')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(
        find.byKey(
          const Key('office-template-preview-use-1_invoice.tpl.doc'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const Key('office-template-make-dialog')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('office-template-make-title-field')),
        '我的发票',
      );
      await tester.tap(find.byKey(const Key('office-template-make-confirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      final make = boot.t.calls
          .where((c) => c['method'] == 'make')
          .toList(growable: false);
      expect(make, hasLength(1));
      expect(make.single['api'], 'SYNO.Office.Template');
      expect(make.single['parent_id'], '/mydrive');
      expect(make.single['object_id'], '1_invoice.tpl.doc');
      expect(make.single['title'], '我的发票');

      // 落到新文档：driveOpenEntry 按扩展名分流到既有 `.odoc` 只读页
      expect(
        find.byType(OfficeDocPage),
        findsOneWidget,
        reason: '从模板新建后必须打开新建出来的文档，而不是停在列表页',
      );
    });
  });

  group('Drive 行菜单：主题 / 只读版本入口', () {
    testWidgets('.oslides + 能力齐全 → 「主题」出现；点进主题页', (tester) async {
      final boot = await _boot(
        tester,
        const Scaffold(body: DriveBrowseView()),
        onCall: (params) => {
          'items': [_driveItem(name: 'deck.oslides')],
          'total': 1,
        },
      );
      await _openRowMenu(tester, '5');
      expect(find.text('主题'), findsOneWidget);

      await tester.tap(find.text('主题'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('office-themes-page')), findsOneWidget);
      expect(boot.t.calls.any((c) => c['api'] == 'SYNO.Office.Theme'), isTrue);
    });

    testWidgets('能力表缺 SYNO.Office.Theme → 「主题」隐藏，其余菜单项照常', (tester) async {
      await _boot(
        tester,
        const Scaffold(body: DriveBrowseView()),
        apis: {..._allWiringApis}..remove(kOfficeThemeApi),
        onCall: (params) => {
          'items': [_driveItem(name: 'deck.oslides')],
          'total': 1,
        },
      );
      await _openRowMenu(tester, '5');
      expect(find.text('主题'), findsNothing);
      expect(find.text('删除'), findsOneWidget, reason: '缺一个可选入口不影响其它项');
    });

    // ---- 版本入口：完整 / 只读 **降级互补、绝不同时出现**（父 agent 裁决）
    testWidgets('① 完整可用（有 permanent_link + 能力位在）→ 只有完整版本历史', (tester) async {
      await _boot(
        tester,
        const Scaffold(body: DriveBrowseView()),
        onCall: (params) => {
          'items': [_driveItem(name: 'memo.odoc')],
          'total': 1,
        },
      );
      await _openRowMenu(tester, '6');
      expect(find.text('版本历史'), findsOneWidget);
      expect(find.text('版本记录（只读）'), findsNothing, reason: '完整可用时不能同时出现只读退化入口');
    });

    testWidgets('② 完整不可用（无 permanent_link）+ 只读通道可用 → 只有只读入口，且可达', (
      tester,
    ) async {
      await _boot(
        tester,
        const Scaffold(body: DriveBrowseView()),
        onCall: (params) {
          switch ('${params['api']}.${params['method']}') {
            case 'SYNO.SynologyDrive.Files.list':
              return {
                'items': [_driveItem(name: 'memo.odoc', permanentLink: false)],
                'total': 1,
              };
            case 'SYNO.Office.Node.Version.list':
              return _versions();
            default:
              return const <String, dynamic>{};
          }
        },
      );
      await _openRowMenu(tester, '6');
      expect(
        find.text('版本历史'),
        findsNothing,
        reason: '完整页进不去（没有 permanent_link）→ 不当"看得见点不动"的入口',
      );
      expect(find.text('版本记录（只读）'), findsOneWidget);

      await tester.tap(find.text('版本记录（只读）'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const Key('office-versions-readonly-page')),
        findsOneWidget,
      );
      // 批 D 的只读列表 widget（有数据 → `office-version-list`）
      expect(find.byKey(const Key('office-version-list')), findsOneWidget);
      expect(find.byKey(const Key('office-version-item-3')), findsOneWidget);
    });

    testWidgets('③ 都不可用（能力表缺 Node.Version）→ 两个版本入口都不显示', (tester) async {
      for (final link in [true, false]) {
        await _boot(
          tester,
          const Scaffold(body: DriveBrowseView()),
          apis: {..._allWiringApis}..remove(kOfficeVersionApi),
          onCall: (params) => {
            'items': [_driveItem(name: 'memo.odoc', permanentLink: link)],
            'total': 1,
          },
        );
        await _openRowMenu(tester, '6');
        expect(find.text('版本历史'), findsNothing, reason: 'permanent_link=$link');
        expect(
          find.text('版本记录（只读）'),
          findsNothing,
          reason: 'permanent_link=$link',
        );
        // 结束这次的树，避免影响下一轮 pumpWidget
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  });

  // ⚠️ 真机回归（2026-09-22）：**同一份 Office 文件曾有两套渲染器**。
  //
  // `drive_browse_view.dart` 的 `_open()` 此前直接调 `openFilePreview`，
  // 于是从「文件」tab 打开 Office 文件会落到 `office_viewer_page.dart` 里的
  // **旧** `ODocView`（粗排版 + "只读预览"/"本批不支持编辑"/"版式从简" 横幅），
  // 而从 `DriveFolderPage`/`DriveMorePage`/`DriveSearchPage` 打开却走
  // **新**的 `OfficeDocPage`。真机截图 `/tmp/o8.png` 就是旧的那一套。
  //
  // 修法：Office 原生文件统一委托 `driveOpenEntry`（新渲染器）。
  // 这一组用例把该规则钉住 —— **回退即红**。
  group('Office 打开路由统一：Drive 浏览页也必须走新渲染器', () {
    testWidgets('.odoc 点击行 → 落到 OfficeDocPage，不再是旧只读预览', (tester) async {
      await _boot(
        tester,
        const Scaffold(body: DriveBrowseView()),
        onCall: (params) =>
            '${params['api']}.${params['method']}' ==
                'SYNO.SynologyDrive.Files.list'
            ? {
                'items': [_driveItem(name: 'plan.odoc')],
                'total': 1,
              }
            : const <String, dynamic>{},
      );

      await _dismissScopeIntro(tester);
      expect(find.text('plan.odoc'), findsOneWidget);
      await tester.tap(find.text('plan.odoc'));
      // 等页面进入**任一**状态：只要出现 office-doc-* 的 key，
      // 就证明进的是**新**的 OfficeDocPage（旧路径根本不会有这个前缀）。
      for (var i = 0; i < 12 && !_hasKeyPrefix('office-doc-'); i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        _hasKeyPrefix('office-doc-'),
        isTrue,
        reason: '点击 .odoc 行必须进入新的 OfficeDocPage，而不是旧只读预览',
      );
      // 旧渲染器的**开发者文案**一个都不许出现。
      expect(find.textContaining('版式从简'), findsNothing);
      expect(find.textContaining('本批不支持编辑'), findsNothing);
      expect(find.textContaining('只读渲染'), findsNothing);
    });

    testWidgets('.oslides 点击行 → 落到 OfficeSlidesPage（不得回落旧 OSlidesView）', (
      tester,
    ) async {
      await _boot(
        tester,
        const Scaffold(body: DriveBrowseView()),
        onCall: (params) =>
            '${params['api']}.${params['method']}' ==
                'SYNO.SynologyDrive.Files.list'
            ? {
                'items': [_driveItem(name: 'deck.oslides')],
                'total': 1,
              }
            : const <String, dynamic>{},
      );

      await _dismissScopeIntro(tester);
      await tester.tap(find.text('deck.oslides'));
      for (var i = 0; i < 12 && !_hasKeyPrefix('office-slides-'); i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        _hasKeyPrefix('office-slides-'),
        isTrue,
        reason: '点击 .oslides 行必须进入新的 OfficeSlidesPage',
      );
      expect(find.textContaining('版式从简'), findsNothing);
      expect(find.textContaining('不做母版继承'), findsNothing);
    });
  });
}
