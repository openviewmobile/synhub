// Office 批 D —— 服务端模板库 / 主题 / 版本历史：**接口层请求形状** + UI 行为。
//
// 证据（`docs/office-sample-corpus.md` §7/§9，全部真机/官方前端）：
//   * `Office.Template:list` v1 无参 → 53 条（回包字段见 §7.1）；
//   * `Office.Template:make v1 {parent_id, object_id[, title]}` → 实测成功；
//   * `Office.Theme:list v1 {ntype:"presentation"}` → 17 条（§7.2）；
//   * `Office.Theme:apply` 参数白名单逐字（`ui.drive.js` 的 `applyTheme`）；
//   * `Theme.Thumb:get {ntype,id,retina}`（`ui.presentation.js`）。
//
// 无网络、无设备、无构建。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/office_version_dto.dart';
import 'package:synhub/src/data/office_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/office/office_library.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Office.Template': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Office.Template.Thumb': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Office.Theme': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Office.Theme.Thumb': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

/// 真机 53 条中的代表条目（字段逐字，§7.1）。
Map<String, dynamic> templatesPayload() => {
  'items': [
    {
      'capabilities': {
        'can_download': true,
        'can_preview': true,
        'can_read': true,
      },
      'category': 'node',
      'ctime': 0,
      'encrypt': false,
      'is_template': true,
      'mtime': 0,
      'ntype': 'presentation',
      'object_id': '1_opinion.tpl.slide',
      'perm': 'ro',
      'system': true,
      'title': 'theme_presentation:opinion',
      'ver': 'f26e4bacf7a38332c3f078c399c2bacdc8a198f6',
    },
    {
      'capabilities': {'can_preview': true, 'can_read': true},
      'ntype': 'doc',
      'object_id': '1_invoice.tpl.doc',
      'perm': 'ro',
      'system': true,
      'title': 'template_doc:invoice',
    },
    {
      'capabilities': {'can_read': true},
      'ntype': 'sheet',
      'object_id': '1_expense_report.tpl.sheet',
      'title': 'template_sheet:expense_report',
    },
  ],
};

Map<String, dynamic> themesPayload() => {
  'total': 17,
  'tpl': [
    {
      'id': 'opinion',
      'order': 120,
      'title_key': 'opinion',
      'title_section': 'theme_presentation',
    },
    {
      'id': 'minimalist_white',
      'order': 10,
      'title_key': 'minimalist_white',
      'title_section': 'theme_presentation',
    },
    {
      'id': 'navy_blue',
      'order': 30,
      'title_key': 'navy_blue',
      'title_section': 'theme_presentation',
    },
  ],
};

Future<OfficeApi> _api(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return OfficeApi(api);
}

/// 走**新交互**：点卡片 → 全屏预览 → 「使用此模板」→ 标题对话框。
///
/// 旧交互是卡片上一个直接的「从模板新建」按钮；第 260 轮改成
/// "点卡片=预览、预览里显式新建"（避免误触在用户 Drive 里凭空造文件）。
Future<void> _tapCardThenUseTemplate(
  WidgetTester tester,
  String objectId,
) async {
  await tester.tap(find.byKey(Key('office-template-item-$objectId')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('office-template-preview-use-$objectId')));
  await tester.pumpAndSettle();
}

void main() {
  group('L1. 接口层请求形状（官方白名单逐字）', () {
    late FakeTransport t;
    late OfficeApi office;

    setUp(() async {
      t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) {
        switch ('${params['api']}.${params['method']}') {
          case 'SYNO.Office.Template.list':
            return templatesPayload();
          case 'SYNO.Office.Theme.list':
            return themesPayload();
          case 'SYNO.Office.Template.make':
            return {
              'capabilities': {'can_write': true},
              'display_path': '/mydrive/Untitled.odoc',
            };
          default:
            return {'success': true};
        }
      };
      office = await _api(t);
    });

    test('Template/list v1：无参（真机 53 条那条形态）', () async {
      final list = await office.templateList();
      final call = t.calls.lastWhere((c) => '${c['method']}' == 'list');
      expect(call['api'], 'SYNO.Office.Template');
      expect('${call['version']}', '1');
      expect(call.containsKey('ntype'), isFalse);
      expect(list, hasLength(3));
      // i18n key **不上屏**：DTO 的 title 是可读名。
      expect(list.first.titleKey, 'theme_presentation:opinion');
      expect(list.first.title, 'Opinion');
      expect(list.first.ntype, 'presentation');
      expect(list.first.canRead, isTrue);
      expect(list.first.canPreview, isTrue);
      expect(list.first.canDownload, isTrue);
      expect(list[2].canPreview, isFalse);
      // ★ 真机 `ver` 是 40 位哈希串（第 257 轮白屏就是它被当成 int）。
      expect(list.first.ver, 'f26e4bacf7a38332c3f078c399c2bacdc8a198f6');
      expect(list.first.system, isTrue);
      expect(list.first.perm, 'ro');
      expect(list.first.isTemplate, isTrue);
      expect(list.first.encrypt, isFalse);
      // ★ 第 263 轮：`ver` 是**内容哈希**，缩略图接口的 `ver` 不能拿它顶替
      // （系统模板官方发应用版本；我们拿不到 ⇒ 不发）。发哈希会被真机
      // `120 {"name":"ver","reason":"type"}` 拒 → 4/53 个模板无缩略图。
      expect(list.first.thumbVer, isNull);
    });

    test('Template/list + ntype：白名单参数 ntype 发对了', () async {
      await office.templateList(ntype: 'sheet');
      final call = t.calls.lastWhere((c) => '${c['method']}' == 'list');
      expect(call['ntype'], 'sheet');
    });

    test('Template/get v1：只发 object_id', () async {
      await office.templateGet(objectId: '1_invoice.tpl.doc');
      final call = t.calls.lastWhere((c) => '${c['method']}' == 'get');
      expect(call['api'], 'SYNO.Office.Template');
      expect('${call['version']}', '1');
      expect(call['object_id'], '1_invoice.tpl.doc');
      expect(call.containsKey('link_id'), isFalse);
    });

    test('Template/make v1：**从模板新建** = parent_id + object_id（真机形态）', () async {
      final node = await office.templateMake(
        parentId: '/mydrive',
        objectId: '1_invoice.tpl.doc',
      );
      final call = t.calls.lastWhere((c) => '${c['method']}' == 'make');
      expect(call['api'], 'SYNO.Office.Template');
      expect('${call['version']}', '1');
      expect(call['parent_id'], '/mydrive');
      expect(call['object_id'], '1_invoice.tpl.doc');
      expect(call.containsKey('title'), isFalse);
      expect(node['display_path'], '/mydrive/Untitled.odoc');
    });

    test(
      'Template/make + title：title 原样发（不塞 link_id/Node:create 参数）',
      () async {
        await office.templateMake(
          parentId: '/mydrive',
          objectId: '1_invoice.tpl.doc',
          title: '我的发票',
        );
        final call = t.calls.lastWhere((c) => '${c['method']}' == 'make');
        expect(call['title'], '我的发票');
        for (final forbidden in <String>[
          'link_id',
          'template_link_id',
          'tpl_link_id',
          'from_link_id',
        ]) {
          expect(call.containsKey(forbidden), isFalse);
        }
      },
    );

    test('Template/make 缺 id → ArgumentError（不瞎发）', () async {
      await expectLater(
        office.templateMake(parentId: '', objectId: 'x'),
        throwsArgumentError,
      );
    });

    test('Theme/list v1：只发 ntype，按 order 排序', () async {
      final themes = await office.themeList(ntype: 'presentation');
      final call = t.calls.lastWhere((c) => '${c['method']}' == 'list');
      expect(call['api'], 'SYNO.Office.Theme');
      expect('${call['version']}', '1');
      expect(call['ntype'], 'presentation');
      expect(themes.map((e) => e.id).toList(), [
        'minimalist_white',
        'navy_blue',
        'opinion',
      ]);
      expect(themes.last.title, 'Opinion');
      expect(themes.first.order, 10);
    });

    test('Theme/apply v1：参数白名单逐字发对', () async {
      await office.themeApply(
        objectId: '1028_ABC',
        ntype: 'presentation',
        themeId: 'opinion',
      );
      final call = t.calls.lastWhere((c) => '${c['method']}' == 'apply');
      expect(call['api'], 'SYNO.Office.Theme');
      expect(call['object_id'], '1028_ABC');
      expect(call['ntype'], 'presentation');
      expect(call['theme_id'], 'opinion');
    });

    test('缩略图直链：Template 用 object_id+ver+retina；Theme 用 ntype+id+retina', () {
      final tpl = office.templateThumbUrl(objectId: '1_opinion.tpl.slide');
      expect(tpl, contains('api=SYNO.Office.Template.Thumb'));
      expect(tpl, contains('method=get'));
      expect(tpl, contains('object_id=1_opinion.tpl.slide'));
      expect(tpl, contains('retina=false'), reason: '官方两个值都发（1x/2x）');
      final tpl2x = office.templateThumbUrl(
        objectId: '1_opinion.tpl.slide',
        ver: 'f26e4bac',
        retina: true,
      );
      expect(tpl2x, contains('ver=f26e4bac'));
      expect(tpl2x, contains('retina=true'));

      final theme = office.themeThumbUrl(
        ntype: 'presentation',
        id: 'opinion',
        retina: true,
      );
      expect(theme, contains('api=SYNO.Office.Theme.Thumb'));
      expect(theme, contains('ntype=presentation'));
      expect(theme, contains('id=opinion'));
      expect(theme, contains('retina=true'));
    });
  });

  group('L2. i18n key → 可读名（key 绝不上屏）', () {
    test('section:key → 去前缀 + 拆词首字母大写', () {
      expect(
        officeLibraryTitleFromKey('theme_presentation:opinion'),
        'Opinion',
      );
      expect(officeLibraryTitleFromKey('template_doc:todo_list'), 'Todo List');
      expect(
        officeLibraryTitleFromKey('template_sheet:expense_report'),
        'Expense Report',
      );
      expect(officeLibraryTitleFromKey('opinion'), 'Opinion');
      expect(officeLibraryTitleFromKey('minimalist_white'), 'Minimalist White');
      expect(officeLibraryTitleFromKey('todo_list_2'), 'Todo List 2');
      expect(officeLibraryTitleFromKey(''), '');
      expect(officeLibraryTitleFromKey(null), '');
    });
  });

  group('L3. UI：模板库 / 主题 / 版本', () {
    Widget host(Widget child) => MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: child));

    final templates = OfficeTemplateDto.listFromJson(templatesPayload());

    testWidgets('模板库显示官方双语标题（不是 i18n key），并按 ntype 过滤', (tester) async {
      await tester.pumpWidget(
        host(OfficeTemplateLibraryView(templates: templates)),
      );
      expect(find.byKey(const Key('office-template-library')), findsOneWidget);
      // 中文模式（无 delegate ⇒ AppTextZh）：官方本地化表的中文译文。
      // 默认 800x600 测试面里三个分组会超出一屏 ⇒ 按页签逐个把组置顶再看。
      expect(find.text('付款明细'), findsOneWidget);
      // i18n key **绝不上屏**。
      expect(find.textContaining('theme_presentation:'), findsNothing);
      expect(find.textContaining('template_doc:'), findsNothing);
      // 过滤到 sheet。
      await tester.tap(find.byKey(const Key('office-template-filter-sheet')));
      await tester.pumpAndSettle();
      expect(find.text('费用报告'), findsOneWidget);
      expect(find.text('付款明细'), findsNothing);
      // 过滤到 presentation。
      await tester.tap(
        find.byKey(const Key('office-template-filter-presentation')),
      );
      await tester.pumpAndSettle();
      expect(find.text('观点'), findsOneWidget);
      expect(find.textContaining('theme_presentation:'), findsNothing);
    });

    testWidgets('从模板新建：调 makeTemplate(template,title) 且回传新节点', (tester) async {
      OfficeTemplateDto? made;
      String? madeTitle;
      Map<String, dynamic>? node;
      await tester.pumpWidget(
        host(
          OfficeTemplateLibraryView(
            templates: templates,
            makeTemplate: (t, title) async {
              made = t;
              madeTitle = title;
              return <String, dynamic>{'display_path': '/mydrive/我的发票.odoc'};
            },
            onTemplateCreated: (t, n) => node = n,
          ),
        ),
      );
      await _tapCardThenUseTemplate(tester, '1_invoice.tpl.doc');
      expect(
        find.byKey(const Key('office-template-make-dialog')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('office-template-make-title-field')),
        '我的发票',
      );
      await tester.tap(find.byKey(const Key('office-template-make-confirm')));
      await tester.pumpAndSettle();
      expect(made?.objectId, '1_invoice.tpl.doc');
      expect(madeTitle, '我的发票');
      expect(node?['display_path'], '/mydrive/我的发票.odoc');
      expect(
        find.byKey(const Key('office-template-make-result')),
        findsOneWidget,
      );
    });

    testWidgets('从模板新建失败 → 如实报错，不假装成功', (tester) async {
      await tester.pumpWidget(
        host(
          OfficeTemplateLibraryView(
            templates: templates,
            makeTemplate: (t, title) async =>
                throw StateError('120 缺 object_id'),
          ),
        ),
      );
      await _tapCardThenUseTemplate(tester, '1_invoice.tpl.doc');
      await tester.tap(find.byKey(const Key('office-template-make-confirm')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('office-template-make-error')),
        findsOneWidget,
      );
      expect(find.textContaining('120 缺 object_id'), findsOneWidget);
      expect(
        find.byKey(const Key('office-template-make-result')),
        findsNothing,
      );
    });

    testWidgets('无 makeTemplate → 不显示"从模板新建"按钮（不假装能建）', (tester) async {
      await tester.pumpWidget(
        host(OfficeTemplateLibraryView(templates: templates)),
      );
      expect(find.byIcon(Icons.add_box_outlined), findsNothing);
    });

    testWidgets('主题：选择后 apply 回调；措辞保守但不夹开发用语（r378 订正）', (tester) async {
      OfficeThemeDto? applied;
      await tester.pumpWidget(
        host(
          OfficeThemePickerView(
            themes: OfficeThemeDto.listFromJson(themesPayload()),
            onApply: (t) async => applied = t,
          ),
        ),
      );
      expect(find.byKey(const Key('office-theme-picker')), findsOneWidget);
      expect(find.text('Minimalist White'), findsOneWidget);
      await tester.tap(find.byKey(const Key('office-theme-item-opinion')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('office-theme-apply')));
      await tester.pumpAndSettle();
      expect(applied?.id, 'opinion');
      expect(find.byKey(const Key('office-theme-applied')), findsOneWidget);
      // ★ r378 订正：原用例要求文案里**必须**有"未取证"——那是把开发口吻焊进用户文案
      //   （用户上线要求：临时/调试字样一个都不许出现在最终包里）。
      //   保守性靠**动词**体现：只说"已请求"，不声称服务端已成功。
      expect(find.textContaining('已请求'), findsOneWidget);
      for (final devPhrase in <String>['未取证', '未验证', '真机', '本轮']) {
        expect(
          find.textContaining(devPhrase),
          findsNothing,
          reason: '用户文案里不许出现开发用语「$devPhrase」',
        );
      }
    });

    testWidgets('版本历史：只读列表显示版本/时间/编辑者', (tester) async {
      final versions = [
        OfficeVersionDto(
          version: '7',
          author: 'demo_user',
          modifiedTime: DateTime(2026, 1, 2, 3, 4),
          editors: const ['demo_user', 'guest'],
          verName: '定稿',
          commitMsg: '',
          firstVersion: false,
          listable: true,
          title: '报告',
        ),
        OfficeVersionDto(
          version: '1',
          author: 'system',
          modifiedTime: null,
          editors: const [],
          verName: '',
          commitMsg: '',
          firstVersion: true,
          listable: true,
          title: '报告',
        ),
      ];
      await tester.pumpWidget(host(OfficeVersionListView(versions: versions)));
      expect(find.byKey(const Key('office-version-list')), findsOneWidget);
      expect(find.text('定稿'), findsOneWidget);
      expect(find.text('2026-01-02 03:04 · demo_user、guest'), findsOneWidget);
      expect(find.text('初始版本'), findsOneWidget);
    });
  });
}
