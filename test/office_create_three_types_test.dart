// ★★ 第 257 轮：Drive「新建」要支持官方 Web 客户端的**全部创建形态**
// （用户要求：「创建三种文档以及从模版创建 创建三种加密文档和从模版创建」）。
//
// ## 官方契约（两处硬证据，全部逐字）
//
// ① **安卓 APK**（`Android-SynologyDrive.3.9.0-1113`）只有两个类型
//    ——`ApiSynoOfficeNode$Type` = `Doc`/`Sheet`，`setAsCreate(path,type,title)`
//    只发 `path`/`ntype`/`title`。所以**只照 APK 会漏掉演示文稿与加密**。
// ② **官方 Office Web 客户端**（SPK `Office-3.8.0-22711` 的 `ui/dist/`）才是全集：
//    * 「新建」菜单：`createNode({ntype:"doc"|"sheet"|"presentation"})`；
//    * 「从模板」：`openTplDialog({defaultType:"all"})`；
//    * 「加密新建」子菜单：`new SYNO.SDS.Office.Encrypt.Window({ntype: …})`，
//      四种（doc/sheet/presentation/template）；
//    * 请求白名单（`ui.doc.js`）：
//      `Node:create` v1 `path,title,ctime,mtime,password,encrypt,ntype,content`
//      （外加默认 `commit_msg:{device:"desktop"}`）；
//      `Template:make` v1 `object_id,title,default_title,password,encrypt,parent_id,ver`；
//    * 类型映射 `getNTypeByObjectId`：`.doc`→doc、`.sh`→sheet、`.slide`→presentation。
//
// 本文件钉死：三种类型的空白新建、三种类型的加密新建、模板接口的
// encrypt/password、以及 Drive 新建面板里这些入口**真的都在**。
//
// 全程假传输，不碰真机（规程 §5.1：真 NAS 写操作必须为零）。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/office_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/drive_browse_view.dart';
import 'package:synhub/src/features/files/drive_providers.dart';
import 'package:synhub/src/features/files/office_providers.dart';
import 'package:synhub/src/features/office/office_library_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

// ------------------------------------------------------------------ 夹具

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Office.Node': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2},
  'SYNO.Office.Template': {
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

Map<String, dynamic> _folder() => {
  'file_id': '100',
  'name': 'mydrive',
  'type': 'folder',
  'display_path': '/mydrive',
};

Map<String, dynamic> _created() => {
  'file_id': '900',
  'link_id': 'LINK-900',
  'display_path': '/mydrive/new.odoc',
  'perm': 'rw',
};

Map<String, dynamic> _templates() => {
  'total': 1,
  'items': [
    {
      'object_id': '1_invoice.tpl.doc',
      'ntype': 'doc',
      'title': 'file:invoice',
      'link_id': 'TPL-LINK',
    },
  ],
};

FakeTransport _transport() => FakeTransport({
  'SYNO.SynologyDrive.Files.get': _folder(),
  'SYNO.Office.Node.create': _created(),
  'SYNO.Office.Template.list': _templates(),
  'SYNO.Office.Template.make': _created(),
}, {...FakeTransport.table, ..._table});

Future<DsmWebApi> _api(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

/// 最后一次某 api/method 的请求（键值全转字符串，便于断言）。
Map<String, String> _lastCall(FakeTransport t, String api, String method) {
  final hits = [
    for (final c in t.calls)
      if (c['api'] == api && c['method'] == method)
        {for (final e in c.entries) e.key: '${e.value}'},
  ];
  expect(hits, isNotEmpty, reason: '必须发出 $api:$method');
  return hits.last;
}

// ------------------------------------------------------------------ UI 夹具

Future<ProviderContainer> _pumpSheet(
  WidgetTester tester,
  FakeTransport t, {
  String path = '/mydrive',
}) async {
  final api = await _api(t);
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      driveApiProvider.overrideWithValue(DriveApi(api)),
      officeApiProvider.overrideWithValue(OfficeApi(api)),
    ],
  );
  addTearDown(c.dispose);
  addTearDown(db.close);
  // 默认测试窗口 800x600 放不下 8 项的弹层 ⇒ 后面的项被裁到屏外，
  // 直接 tap 会打在遮罩上（把弹层关掉）。这里给一块手机比例的高屏。
  tester.view.physicalSize = const Size(1080, 4200);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), 
        home: Scaffold(
          body: Consumer(
            builder: (ctx, ref, _) => ElevatedButton(
              key: const Key('open-create'),
              onPressed: () => showDriveCreateSheet(ctx, ref, path),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return c;
}

/// 打开新建面板（避开 `pumpAndSettle`：HUD 有常驻动画，settle 会卡）。
Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('open-create')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _tapAndSettle(WidgetTester tester, Key key) async {
  final f = find.byKey(key);
  expect(f, findsOneWidget, reason: '找不到 $key');
  try {
    await tester.ensureVisible(f);
    await tester.pump();
  } on Object {
    // 弹层里的按钮没有 Scrollable 祖先，ensureVisible 会抛：那说明它已经可见
  }
  await tester.tap(f);
  // 一次 tap 可能连着"弹层关闭 + 新路由推入"两段动画：多推几帧，
  // 让 pending 的异步续体（弹出后的 switch / push）都跑到。
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// 标题对话框里的「创建」确认（口令框已关，此时只剩它一个 FilledButton）。
Future<void> _confirmTitle(WidgetTester tester, String title) async {
  expect(find.byType(TextField), findsOneWidget, reason: '应停在「文件名」对话框');
  await tester.enterText(find.byType(TextField), title);
  expect(find.byType(FilledButton), findsOneWidget);
  await tester.tap(find.byType(FilledButton));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 直接把模板库页面挂起来（真机形态回归用）。
Future<ProviderContainer> _pumpTemplatePage(
  WidgetTester tester,
  FakeTransport t,
) async {
  final api = await _api(t);
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      driveApiProvider.overrideWithValue(DriveApi(api)),
      officeApiProvider.overrideWithValue(OfficeApi(api)),
    ],
  );
  addTearDown(c.dispose);
  addTearDown(db.close);
  tester.view.physicalSize = const Size(1080, 4200);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), 
        home: OfficeTemplateLibraryPage(parentId: '/mydrive'),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return c;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('① 数据层：三种类型的空白新建', () {
    test('★ doc / sheet / presentation 都发得出（presentation 此前没有入口）',
        () async {
      for (final type in OfficeNodeType.values) {
        final t = _transport();
        final api = OfficeApi(await _api(t));
        await api.createNode(
          parentId: 'id:100',
          type: type,
          title: 'a.odoc',
        );
        final call = _lastCall(t, 'SYNO.Office.Node', 'create');
        expect(call['ntype'], type.value);
        expect(call['path'], 'id:100');
        expect(call['title'], 'a.odoc');
        expect(
          call['version'],
          '1',
          reason: '服务端 v2 没有 create（v2 = touch/copy）⇒ 必须 v1',
        );
        expect(
          call.containsKey('encrypt'),
          isFalse,
          reason: '非加密新建不该悄悄带上 encrypt',
        );
        expect(call.containsKey('password'), isFalse);
      }
    });

    test('官方默认 commit_msg 形态逐字带上（{device:"desktop"}）', () async {
      final t = _transport();
      final api = OfficeApi(await _api(t));
      await api.createNode(
        parentId: 'id:100',
        type: OfficeNodeType.doc,
        title: 'a.odoc',
      );
      final call = _lastCall(t, 'SYNO.Office.Node', 'create');
      expect(call['commit_msg'], contains('desktop'));
    });
  });

  group('② 数据层：三种类型的加密新建', () {
    test('★ encrypt=true + password 与 ntype 同请求（官方 Web 客户端形态）',
        () async {
      for (final type in OfficeNodeType.values) {
        final t = _transport();
        final api = OfficeApi(await _api(t));
        await api.createNode(
          parentId: 'id:100',
          type: type,
          title: 'secret',
          encrypt: true,
          password: 'pw-1234',
        );
        final call = _lastCall(t, 'SYNO.Office.Node', 'create');
        expect(call['ntype'], type.value);
        expect(call['encrypt'], 'true', reason: '加密新建靠 create 上的 encrypt 位');
        expect(call['password'], 'pw-1234');
        expect(call['version'], '1');
      }
    });
  });

  group('③ 数据层：模板（含加密模板）', () {
    test('★ Template:make 的 encrypt/password 与 object_id/parent_id 同级',
        () async {
      final t = _transport();
      final api = OfficeApi(await _api(t));
      await api.templateMake(
        parentId: '/mydrive/sub',
        objectId: '1_invoice.tpl.doc',
        title: 'inv',
        encrypt: true,
        password: 'pw-9',
      );
      final call = _lastCall(t, 'SYNO.Office.Template', 'make');
      expect(call['object_id'], '1_invoice.tpl.doc');
      expect(call['parent_id'], '/mydrive/sub');
      expect(call['encrypt'], 'true');
      expect(call['password'], 'pw-9');
      expect(call['version'], '1');
    });

    test('非加密模板不带 encrypt/password（回归保护）', () async {
      final t = _transport();
      final api = OfficeApi(await _api(t));
      await api.templateMake(
        parentId: '/mydrive',
        objectId: '1_invoice.tpl.doc',
      );
      final call = _lastCall(t, 'SYNO.Office.Template', 'make');
      expect(call.containsKey('encrypt'), isFalse);
      expect(call.containsKey('password'), isFalse);
    });

    test('★ object_id → 类型（官方 getNTypeByObjectId：.doc/.sh/.slide）',
        () async {
      expect(
        officeNodeTypeFromObjectId('1_invoice.tpl.doc'),
        OfficeNodeType.doc,
      );
      expect(
        officeNodeTypeFromObjectId('12_plan.tpl.sh'),
        OfficeNodeType.sheet,
      );
      expect(
        officeNodeTypeFromObjectId('7_deck.tpl.slide'),
        OfficeNodeType.presentation,
      );
      // 认不出来**不猜**（宁可让调用方按"全部类型"处理）
      expect(officeNodeTypeFromObjectId('1_blank.tpl.odoc'), isNull);
      expect(officeNodeTypeFromObjectId('nodot'), isNull);
      expect(officeNodeTypeFromObjectId('trailing.'), isNull);
    });

    test('★★ r314：`Permission:check` 的 ntype 必须走官方映射（真机的 `.sh` 缺陷）',
        () async {
      // 真机缺陷：三个页面以前直接发 `object_id` 的**原始后缀**。
      // 文档的后缀恰好是官方的 `doc` ⇒ 只有文档页正常；
      // 表格的后缀是 `sh`、演示文稿是 `slide` ⇒ 服务端 `Permission:check` 回
      // `{readable:false, writable:false, commentable:false}`（真机读数），
      // 界面据此说"没有写入权限"并锁死整条写通道。
      expect(officePermissionNtype('1028_OMV1234567890.sh'), 'sheet');
      expect(officePermissionNtype('1028_ABC.slide'), 'presentation');
      expect(officePermissionNtype('1028_9QE.doc'), 'doc');
      // 认不出来时如实返回原后缀（官方 `default: return n`），不猜成别的类型
      expect(officePermissionNtype('1028_XXX.odoc'), 'odoc');
      expect(officePermissionNtype('nodot'), '');
    });
  });

  group('⑦ 真机载荷形态：模板列表不能因为字段类型变了就整页失败', () {
    // ★★ 第 257 轮真机缺陷（在 LGE-AN10 上点「从模板新建」当场复现）：
    //   `Template library` 页面显示
    //   `Failed to load template library: type 'String' is not a subtype of
    //    type 'num'? in type cast`
    // 真机只读取证（真 NAS nas.example.com，`Template:list` v1，53 条）：
    //   `ver` 是**字符串哈希** `"f26e4bacf7a3…"`，而 `ctime`/`mtime` 是 int `0`；
    //   旧解析写 `(json['ver'] as num?)?.toInt()` ⇒ 抛类型错 ⇒ **整页失效**。
    // 这条用例用**逐字真机回包**钉死："服务端字段类型不保证，解析必须宽松"。
    final realItem = <String, dynamic>{
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
      'object_id': '1_country_road.tpl.slide',
      'perm': 'ro',
      'system': true,
      'title': 'theme_presentation:country_road',
      'ver': 'f26e4bacf7a38332c3f078c399c2bacdc8a198f6',
    };

    test('★ 逐字真机条目：不抛异常，且 ver 按字符串解出', () {
      final list = OfficeTemplateDto.listFromJson({
        'total': 1,
        'items': [realItem],
      });
      expect(list, hasLength(1));
      final t = list.single;
      expect(t.objectId, '1_country_road.tpl.slide');
      expect(t.ntype, 'presentation');
      expect(t.ver, 'f26e4bacf7a38332c3f078c399c2bacdc8a198f6');
      expect(t.ctime, 0);
      expect(officeNodeTypeFromObjectId(t.objectId), OfficeNodeType.presentation);
    });

    test('★ 宽松整数解析：int / 数字串 / 哈希串 / null 都不炸', () {
      expect(officeJsonInt(0), 0);
      expect(officeJsonInt(7), 7);
      expect(officeJsonInt('12'), 12);
      expect(officeJsonInt('0'), 0);
      expect(officeJsonInt('f26e4bac'), isNull, reason: '哈希串不是数字 ⇒ null，不是抛');
      expect(officeJsonInt(null), isNull);
      expect(officeJsonInt(<String, dynamic>{}), isNull);
    });

    testWidgets('★ 真机形态的模板库页面：渲染出模板条目（不再显示加载失败）',
        (tester) async {
      final t = _transport();
      t.responses['SYNO.Office.Template.list'] = {
        'total': 1,
        'items': [realItem],
      };
      await _pumpTemplatePage(tester, t);
      expect(
        find.byKey(const Key('office-template-item-1_country_road.tpl.slide')),
        findsOneWidget,
        reason: '★ 真机就是在这里全页失败的（ver 类型）',
      );
      expect(find.textContaining('Failed to load'), findsNothing);
      expect(find.textContaining('加载失败'), findsNothing);
    });
  });

  group('④ Drive 新建面板：入口必须齐全', () {
    testWidgets('★ 三种类型 + 从模板 + 加密新建都在（此前只有 doc/sheet）',
        (tester) async {
      await _pumpSheet(tester, _transport());
      await _openSheet(tester);
      for (final key in const [
        'drive-create-folder',
        'drive-create-text',
        'drive-create-doc',
        'drive-create-sheet',
        'drive-create-slides',
        'drive-create-template',
        'drive-create-encrypted',
      ]) {
        expect(
          find.byKey(Key(key)),
          findsOneWidget,
          reason: '新建面板缺少 $key',
        );
      }
    });

    testWidgets('★ 加密新建是二级面板，四种类型与官方 create_encrypt 子菜单一致',
        (tester) async {
      await _pumpSheet(tester, _transport());
      await _openSheet(tester);
      await _tapAndSettle(tester, const Key('drive-create-encrypted'));
      for (final key in const [
        'drive-create-encrypted-doc',
        'drive-create-encrypted-sheet',
        'drive-create-encrypted-slides',
        'drive-create-encrypted-template',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget, reason: '缺少 $key');
      }
    });
  });

  group('⑤ 口令对话框：对齐官方 Encrypt.Window', () {
    testWidgets('两个字段 + maxLength 32（官方 allowBlank:false / maxlength:32）',
        (tester) async {
      await _pumpSheet(tester, _transport());
      await _openSheet(tester);
      await _tapAndSettle(tester, const Key('drive-create-encrypted'));
      await _tapAndSettle(tester, const Key('drive-create-encrypted-doc'));

      expect(
        find.byKey(const Key('drive-encrypt-password-dialog')),
        findsOneWidget,
      );
      final pwd = tester.widget<TextField>(
        find.byKey(const Key('drive-encrypt-password')),
      );
      final confirm = tester.widget<TextField>(
        find.byKey(const Key('drive-encrypt-password-confirm')),
      );
      expect(pwd.maxLength, 32);
      expect(confirm.maxLength, 32);
      expect(pwd.obscureText, isTrue);
    });

    testWidgets('★ 空口令与两次不一致都在本地挡住（不让服务端报看不懂的码）',
        (tester) async {
      final t = _transport();
      await _pumpSheet(tester, t);
      await _openSheet(tester);
      await _tapAndSettle(tester, const Key('drive-create-encrypted'));
      await _tapAndSettle(tester, const Key('drive-create-encrypted-slides'));

      // 空口令
      await tester.tap(find.byKey(const Key('drive-encrypt-password-ok')));
      await tester.pump();
      expect(find.byKey(const Key('drive-encrypt-password-error')), findsOneWidget);
      expect(
        t.calls.where((c) => c['method'] == 'create'),
        isEmpty,
        reason: '口令没填就不该发出任何创建请求',
      );

      // 两次不一致
      await tester.enterText(
        find.byKey(const Key('drive-encrypt-password')),
        'abc',
      );
      await tester.enterText(
        find.byKey(const Key('drive-encrypt-password-confirm')),
        'abd',
      );
      await tester.tap(find.byKey(const Key('drive-encrypt-password-ok')));
      await tester.pump();
      expect(
        find.byKey(const Key('drive-encrypt-password-dialog')),
        findsOneWidget,
        reason: '不一致时对话框必须留着',
      );
      expect(t.calls.where((c) => c['method'] == 'create'), isEmpty);
    });
  });

  group('⑥ 端到端（假传输）：面板 → 请求', () {
    testWidgets('★ 加密演示文稿：口令 + 类型都进 create 请求', (tester) async {
      final t = _transport();
      await _pumpSheet(tester, t);
      await _openSheet(tester);
      await _tapAndSettle(tester, const Key('drive-create-encrypted'));
      await _tapAndSettle(tester, const Key('drive-create-encrypted-slides'));

      await tester.enterText(
        find.byKey(const Key('drive-encrypt-password')),
        'pw-1',
      );
      await tester.enterText(
        find.byKey(const Key('drive-encrypt-password-confirm')),
        'pw-1',
      );
      await tester.tap(find.byKey(const Key('drive-encrypt-password-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await _confirmTitle(tester, 'deck');

      final call = _lastCall(t, 'SYNO.Office.Node', 'create');
      expect(call['ntype'], 'presentation');
      expect(call['encrypt'], 'true');
      expect(call['password'], 'pw-1');
      expect(call['title'], 'deck');
      expect(call['path'], 'id:100', reason: '父目录解析成 id:<file_id>');
    });

    testWidgets('★ 空白演示文稿：presentation 且不带 encrypt', (tester) async {
      final t = _transport();
      await _pumpSheet(tester, t);
      await _openSheet(tester);
      await _tapAndSettle(tester, const Key('drive-create-slides'));
      await _confirmTitle(tester, 'plain');

      final call = _lastCall(t, 'SYNO.Office.Node', 'create');
      expect(call['ntype'], 'presentation');
      expect(call.containsKey('encrypt'), isFalse);
    });

    testWidgets('★ 从模板新建：进模板库（Template:list 被拉起）', (tester) async {
      final t = _transport();
      await _pumpSheet(tester, t);
      await _openSheet(tester);
      await _tapAndSettle(tester, const Key('drive-create-template'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byKey(const Key('office-template-library-page')),
        findsOneWidget,
      );
      _lastCall(t, 'SYNO.Office.Template', 'list');
    });

    testWidgets('★ 加密模板：先设口令，再 make 时带上 encrypt/password',
        (tester) async {
      final t = _transport();
      await _pumpSheet(tester, t);
      await _openSheet(tester);
      await _tapAndSettle(tester, const Key('drive-create-encrypted'));
      await _tapAndSettle(tester, const Key('drive-create-encrypted-template'));

      await tester.enterText(
        find.byKey(const Key('drive-encrypt-password')),
        'pw-tpl',
      );
      await tester.enterText(
        find.byKey(const Key('drive-encrypt-password-confirm')),
        'pw-tpl',
      );
      await tester.tap(find.byKey(const Key('drive-encrypt-password-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      // 模板库里点卡片 → 预览 → 「使用此模板」→ 标题对话框 → 确认
      await _tapAndSettle(
        tester,
        const Key('office-template-item-1_invoice.tpl.doc'),
      );
      await _tapAndSettle(
        tester,
        const Key('office-template-preview-use-1_invoice.tpl.doc'),
      );
      expect(
        find.byKey(const Key('office-template-make-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('office-template-make-confirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final call = _lastCall(t, 'SYNO.Office.Template', 'make');
      expect(call['object_id'], '1_invoice.tpl.doc');
      expect(call['encrypt'], 'true');
      expect(call['password'], 'pw-tpl');
      expect(call.containsKey('parent_id'), isTrue);
    });

    testWidgets('★ 从模板：parent_id 用官方 getPathId 形态（id:<file_id>，不是人类可读路径）',
        (tester) async {
      final t = _transport();
      await _pumpSheet(tester, t, path: '/mydrive');
      await _openSheet(tester);
      await _tapAndSettle(tester, const Key('drive-create-template'));
      await _tapAndSettle(
        tester,
        const Key('office-template-item-1_invoice.tpl.doc'),
      );
      await _tapAndSettle(
        tester,
        const Key('office-template-preview-use-1_invoice.tpl.doc'),
      );
      await tester.tap(find.byKey(const Key('office-template-make-confirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final call = _lastCall(t, 'SYNO.Office.Template', 'make');
      // 官方 `prepareMakeTemplate` 发的是 `getPathId(lastPathId)` = `id:<file_id>`；
      // 夹具里 `Files.get` 回 `file_id=100` ⇒ `id:100`。
      // 第 258 轮真 NAS 写探针实测**两种形态都能成**，这里钉官方那一种。
      expect(
        call['parent_id'],
        'id:100',
        reason: '官方形态是 id:<file_id>，不是 /mydrive 这种人类可读路径',
      );
    });

    testWidgets('★ 从模板：父目录解析不出来 ⇒ 不硬发 make、不推模板库，并当场提示',
        (tester) async {
      // 服务端只回空壳 ⇒ pathId = `'id:'`（解析失败）
      final t = FakeTransport({
        'SYNO.SynologyDrive.Files.get': <String, dynamic>{},
        'SYNO.Office.Template.list': _templates(),
      }, {...FakeTransport.table, ..._table});
      await _pumpSheet(tester, t, path: '/mydrive');
      await _openSheet(tester);
      await _tapAndSettle(tester, const Key('drive-create-template'));

      expect(
        find.byKey(const Key('office-template-library-page')),
        findsNothing,
        reason: '定位不了父目录就不该进模板库（进去也只能失败）',
      );
      expect(find.byType(SnackBar), findsOneWidget, reason: '必须当场给出原因');
      expect(
        t.calls.where(
          (c) => c['api'] == 'SYNO.Office.Template' && c['method'] == 'make',
        ),
        isEmpty,
        reason: '坏 parent_id 不许发出去',
      );
    });
  });
}
