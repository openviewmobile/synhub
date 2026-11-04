// 联系人（P3 · Synology Contacts）：API 参数 + 页面离线测试。
//
// 关注真机上真踩过的点（见 `docs/api-server-authoritative.md` §5.3）：
//   * 回包的键是**单数** `addressbook` / `contact`（写复数就解析出空列表）；
//   * `Contact/get` 的参数是 **`ids` + JSON 数组字符串**（`id`/`contact_id` → 120）；
//   * `Info/get` **只有 v1**（v2 → 103）；
//   * `addressbook_id` 能过滤；`Contact/list` 用 v2。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/contacts_api.dart';
import 'package:synhub/src/data/local/analytics_database.dart';
import 'package:synhub/src/features/analytics/analytics_track.dart';
import 'package:synhub/src/features/analytics/usage_event.dart';
import 'package:synhub/src/features/analytics/usage_log.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/contacts/contacts_page.dart';
import 'package:synhub/src/features/contacts/contacts_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/core/ui/text_fit.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _contactsTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Contacts.Addressbook': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Contacts.Contact': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Contacts.Info': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2},
  'SYNO.Contacts.Label': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

/// 真机 `Addressbook/list` 回包（键是单数）
Map<String, dynamic> _books() => {
  'addressbook': [
    {
      'id': 7,
      'name': 'Suggested',
      'member_count': 0,
      'mode': 3,
      'type': 2,
      'owned_shared': false,
    },
    {'id': 5, 'name': 'My Contacts', 'member_count': 12, 'mode': 1, 'type': 1},
  ],
  'total': 2,
};

/// 真机 `Contact/list` 回包
Map<String, dynamic> _contacts() => {
  // 元素类型要显式写成 Map<String,dynamic>：字面量默认会推成 Map<String,Object>，
  // 之后 `.cast<Map<String,dynamic>>()` 的视图一赋值就在运行时炸
  'contact': <Map<String, dynamic>>[
    {
      'id': 1,
      'addressbook_id': 5,
      'full_name': 'demo_admin',
      'company': '未来工作室',
      'department': '研发',
      'title': '工程师',
      'primary_mail': 'demo-user@example.com',
      'primary_tel': '13800000000',
      'is_editable': false,
      'photo': '',
      'additional': {
        'label': [
          {'name': '客户'},
        ],
      },
    },
    {
      'id': 2,
      'addressbook_id': 5,
      'full_name': '张三',
      'company': '',
      'primary_mail': 'zhangsan@example.com',
      'primary_tel': '',
      'additional': {'label': const []},
    },
  ],
  'total': 2,
};

/// 真机 `Contact/get` 回包（多了 `additional.contact_detail`）
Map<String, dynamic> _detail() => {
  'contact': [
    {
      'id': 1,
      'addressbook_id': 5,
      'full_name': 'demo_admin',
      'primary_mail': 'demo-user@example.com',
      'additional': {
        'label': const [],
        'contact_detail': {
          'full_name': 'demo_admin',
          'mail': [
            {'data': 'demo-user@example.com', 'is_readonly': true},
            {'data': 'me@future.dev', 'is_readonly': false},
          ],
          'tel': [
            {'data': '13800000000', 'is_readonly': false},
          ],
          'note': '老同事',
          'photo': '',
        },
      },
    },
  ],
  'total': 1,
};

/// 真机 `Label/list` 回包（type 1 = 系统 Starred）
Map<String, dynamic> _labels() => {
  'label': [
    {'color': '', 'id': 3, 'name': 'Starred', 'type': 1, 'member_count': 0},
    {'color': '#37B26C', 'id': 6, 'name': '客户', 'type': 0, 'member_count': 1},
  ],
  'total': 2,
};

/// 联系人列表：第一张卡已经在 Starred 里
Map<String, dynamic> _starredContacts() {
  final raw = _contacts();
  final list = (raw['contact'] as List).cast<Map<String, dynamic>>();
  // 必须显式 Map<String,dynamic>：spread 字面量的推断类型是 Map<String,Object>，
  // 塞回 cast 视图时会在运行时炸（这个坑让"已加星标"用例红过一次）
  final first = Map<String, dynamic>.from(list[0]);
  first['additional'] = <String, dynamic>{
    'label': [
      {'color': '', 'id': 3, 'name': 'Starred', 'type': 1},
    ],
  };
  list[0] = first;
  return raw;
}

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester, {
  Map<String, dynamic> Function(String method, Map<String, dynamic> params)?
  onCall,
  // ★★★ r349 修正：以前这里**没装 `AppText.delegate`**，于是
  // `context.t` 的 `AppText.of(context)` 恒为 null ⇒ 回落 `AppTextZh()`
  // ⇒ **语言根本切不动**（`setCurrentText` 只影响数据层）。
  // 后果：r349 组里那几条 `en` 用例是**假用例** —— 就算界面是中文也照样绿
  // （§2.0.29 同型：用例不可能红 = 没在验）。
  // ★ 为了**不动既有 19 条的 widget 树**，只有显式传 `locale` 时才多装那一层；
  //   默认 `null` ⇒ 树与修改前**逐字相同**。
  Locale? locale,
}) async {
  final t = FakeTransport(const {}, {
    ...FakeTransport.table,
    ..._contactsTable,
  });
  t.onCall = (params) =>
      onCall?.call('${params['method']}', params) ?? const <String, dynamic>{};
  final api = await _loggedIn(t);
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      contactsApiProvider.overrideWithValue(ContactsApi(api)),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: locale == null
          ? MaterialApp(theme: AppTheme.dark(), home: ContactsPage())
          : MaterialApp(
              locale: locale,
              // ★ 必须用**生产同一套** delegate（`AppText.localizationsDelegates`
              // 含 Material/Widgets/Cupertino 全局本地化）。只装 `AppText.delegate`
              // 时 `Localizations` 解不出来，整棵子树会被排成 **0 宽**
              // （实测 `maxWidth=0.0`），量出来的不是产品行为。
              localizationsDelegates: AppText.localizationsDelegates,
              supportedLocales: AppText.supportedLocales,
              theme: AppTheme.dark(),
              home: ContactsPage(),
            ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return (t: t, c: c);
}

/// 埋点断言用：装一个内存日志并挂成全局单例
Future<UsageLog> armUsageLog() async {
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

Future<List<UsageEvent>> drainUsageLog(
  WidgetTester tester,
  UsageLog log,
) async {
  await tester.runAsync(() => log.flush());
  final rows = await tester.runAsync(() => log.recent());
  return rows!;
}

void main() {
  group('通讯录与联系人（参数与官方逐字对齐）', () {
    test('Addressbook/list 用 v1 + offset/limit，回包的键是单数 addressbook', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._contactsTable,
      });
      t.onCall = (params) => _books();
      final api = await _loggedIn(t);
      final books = await ContactsApi(api).addressbooks();
      final call = t.calls.last;
      expect(call['api'], 'SYNO.Contacts.Addressbook');
      expect(call['method'], 'list');
      expect(call['version'], '1');
      expect(call['offset'], '0');
      expect(books, hasLength(2));
      expect(books.first.name, 'Suggested');
      expect(books[1].id, '5', reason: '数字 id 也要读成字符串');
      expect(books[1].memberCount, 12);
      expect(books.first.isShared, isTrue, reason: 'mode=3 是共享通讯录');
    });

    test('Contact/list 用 v2 + addressbook_id 过滤（真机 5 是有效 id）', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._contactsTable,
      });
      t.onCall = (params) => _contacts();
      final api = await _loggedIn(t);
      final list = await ContactsApi(api).contacts(addressbookId: '5');
      final call = t.calls.last;
      expect(call['api'], 'SYNO.Contacts.Contact');
      expect(call['method'], 'list');
      expect(call['version'], '2');
      expect(call['addressbook_id'], '5');
      expect(list, hasLength(2));
      expect(list.first.fullName, 'demo_admin');
      expect(list.first.bestTel, '13800000000');
      expect(list.first.labels, ['客户']);
      expect(list[1].initials, '张');
      expect(list.first.subtitle, '未来工作室 · 研发 · 工程师');
    });

    test('Contact/get 必须用 ids=JSON 数组字符串，且回包是数组', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._contactsTable,
      });
      t.onCall = (params) => _detail();
      final api = await _loggedIn(t);
      final c = await ContactsApi(api).contact('1');
      final call = t.calls.last;
      expect(call['api'], 'SYNO.Contacts.Contact');
      expect(call['method'], 'get');
      expect(call['version'], '2');
      // 真机：`id` / `contact_id` 都回 120，只有 `ids` 是 JSON 数组字符串才行；
      // `[1]` 和 `["1"]` 服务端都收（后者是 jsonEncode(List<String>) 的自然产出）
      expect(call['ids'], '["1"]');
      expect(call.containsKey('id'), isFalse);
      expect(c, isNotNull);
      expect(c!.mail, ['demo-user@example.com', 'me@future.dev']);
      expect(c.tel, ['13800000000']);
      expect(c.note, '老同事');
    });

    test('Info/get 只能发 v1（表里写着 maxVersion 2，但 v2 真机回 103）', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._contactsTable,
      });
      t.onCall = (params) => {
        'principal': {
          'account_name': 'demo_user',
          'display_name': 'demo_user',
          'id': 9,
          'type': 1,
        },
        'is_migrating': false,
      };
      final api = await _loggedIn(t);
      final info = await ContactsApi(api).info();
      expect(t.calls.last['version'], '1');
      expect(info.account, 'demo_user');
    });
  });

  group('联系人页（浏览 + 搜索 + 增删改查）', () {
    testWidgets('列出联系人、显示通讯录切换与姓名首字头像', (tester) async {
      final boot = await _pump(
        tester,
        onCall: (m, p) {
          if (p['api'] == 'SYNO.Contacts.Addressbook') return _books();
          if (p['api'] == 'SYNO.Contacts.Contact') return _contacts();
          return const {};
        },
      );
      expect(find.text('demo_admin'), findsOneWidget);
      expect(find.text('张三'), findsOneWidget);
      expect(find.text('全部'), findsOneWidget);
      expect(find.textContaining('My Contacts'), findsOneWidget);
      expect(boot.t.calls.any((c) => c['method'] == 'list'), isTrue);
    });

    testWidgets('本地搜索姓名/单位/邮箱都能命中共说人话的空态', (tester) async {
      await _pump(
        tester,
        onCall: (m, p) {
          if (p['api'] == 'SYNO.Contacts.Addressbook') return _books();
          return _contacts();
        },
      );
      await tester.enterText(find.byType(TextField), '未来');
      await tester.pump();
      expect(find.text('demo_admin'), findsOneWidget);
      expect(find.text('张三'), findsNothing);

      await tester.enterText(find.byType(TextField), 'example.com');
      await tester.pump();
      expect(find.text('张三'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '不存在的人');
      await tester.pump();
      expect(find.textContaining('没找到'), findsOneWidget);
    });

    testWidgets('点开联系人：详情走 Contact/get，展示多值邮箱与备注', (tester) async {
      final log = await armUsageLog();
      await _pump(
        tester,
        onCall: (m, p) {
          if (p['api'] == 'SYNO.Contacts.Addressbook') return _books();
          if (m == 'get' && p['api'] == 'SYNO.Contacts.Contact') {
            return _detail();
          }
          return _contacts();
        },
      );
      await tester.tap(find.text('demo_admin'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('me@future.dev'), findsOneWidget, reason: '详情里第二个邮箱');
      expect(find.text('老同事'), findsOneWidget);
      // ★★★ r332：弹层是 `DraggableScrollableSheet(initialChildSize: 0.62)`，真实主题下内容比
      // 初始可视区高 ⇒ 末尾动作需要往上拖。**可见线索来自主题**（`AppTheme` 里
      // `bottomSheetTheme.showDragHandle: true`）—— 这里把"这条线索必须在"钉住，
      // 免得哪天主题改掉它、「关闭」就变成没有任何提示地藏在下面（反向验证：把它从主题里删掉 ⇒ 本条红）。
      expect(
        tester.widgetList<BottomSheet>(find.byType(BottomSheet)).any(
          (b) => b.showDragHandle == true,
        ),
        isTrue,
        reason: '联系人详情弹层要有拖拽把手（内容超过初始高度时唯一的可见线索）',
      );

      // ★★★ r332：真实产品主题下内容更高，`DraggableScrollableSheet(initialChildSize: 0.62)`
      // 的初始可视区装不下末尾动作 ⇒ 「关闭」初始是 **offstage**。
      // 判据按**可达**写（§2.0.61④）：先往上滚/拖到它出现，再断言。
      await tester.scrollUntilVisible(
        find.text('关闭'),
        120,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      expect(find.text('关闭'), findsOneWidget);

      // 使用日志：打开联系人只记"联系人"这个类型，不记姓名
      final rows = await drainUsageLog(tester, log);
      expect(rows.single.module, UsageModule.contacts);
      expect(rows.single.action, UsageAction.open);
      expect(rows.single.objectType, 'contact');
    });

    testWidgets('没有联系人时给引导空态，不是白屏', (tester) async {
      await _pump(
        tester,
        onCall: (m, p) {
          if (p['api'] == 'SYNO.Contacts.Addressbook') {
            return {'addressbook': const [], 'total': 0};
          }
          return {'contact': const [], 'total': 0};
        },
      );
      expect(find.text('还没有联系人'), findsOneWidget);
      expect(find.textContaining('点右下角「新建」'), findsOneWidget);
      expect(find.text('新建'), findsOneWidget, reason: '空态也要给出口');
    });

    testWidgets('没装 Contacts（102）→ 说人话 + 可重试', (tester) async {
      await _pump(
        tester,
        onCall: (m, p) {
          throw DsmApiException(102, method: 'SYNO.Contacts.Contact.list');
        },
      );
      expect(find.textContaining('没有装 Synology Contacts'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('列表右侧的星点一下就加星标（= 给系统 Starred 标签加成员）', (tester) async {
      final boot = await _pump(
        tester,
        onCall: (m, p) {
          if (p['api'] == 'SYNO.Contacts.Addressbook') return _books();
          if (p['api'] == 'SYNO.Contacts.Label') return _labels();
          return _contacts();
        },
      );
      // 两张卡都没有 label → 都是空星
      expect(find.byIcon(Icons.star_border_rounded), findsNWidgets(2));

      await tester.tap(find.byIcon(Icons.star_border_rounded).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final add = boot.t.calls.lastWhere(
        (c) => c['method'] == 'add_member',
        orElse: () => const {},
      );
      expect(add['api'], 'SYNO.Contacts.Label');
      expect(add['version'], '2');
      expect(add['ids'], '["3"]', reason: '3 = 系统 Starred');
      expect(add['contact_ids'], '["1"]');
      expect(find.text('已加星标'), findsOneWidget);
    });

    testWidgets('已加星标的行显示实心星，再点一下取消', (tester) async {
      final boot = await _pump(
        tester,
        onCall: (m, p) {
          if (p['api'] == 'SYNO.Contacts.Addressbook') return _books();
          if (p['api'] == 'SYNO.Contacts.Label') return _labels();
          return _starredContacts();
        },
      );
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.star_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final rm = boot.t.calls.lastWhere(
        (c) => c['method'] == 'remove_member',
        orElse: () => const {},
      );
      expect(rm['ids'], '["3"]');
      expect(rm['contact_ids'], '["1"]');
      expect(find.text('已取消星标'), findsOneWidget);
    });

    testWidgets('新建联系人：选中通讯录 → 填姓名 → 保存走 Contact/create', (tester) async {
      final boot = await _pump(
        tester,
        onCall: (m, p) {
          if (p['api'] == 'SYNO.Contacts.Addressbook') return _books();
          if (p['api'] == 'SYNO.Contacts.Label') return _labels();
          if (m == 'create') return {'id': 99};
          return _contacts();
        },
      );
      // 选中「My Contacts」，这样新建不用再挑通讯录
      await tester.tap(find.textContaining('My Contacts'));
      await tester.pump();

      await tester.tap(find.text('新建'));
      await tester.pumpAndSettle();

      expect(find.text('新建联系人'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '李四');
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final create = boot.t.calls.lastWhere(
        (c) => c['method'] == 'create',
        orElse: () => const {},
      );
      expect(create['api'], 'SYNO.Contacts.Contact');
      expect(create['version'], '1');
      expect(create['addressbook_id'], '5');
      expect(create['full_name'], '李四');
      expect(
        jsonDecode(create['name'] as String),
        containsPair('given_name', ''),
      );
    });

    testWidgets('详情里能删联系人（二次确认后走 Contact/delete）', (tester) async {
      final boot = await _pump(
        tester,
        onCall: (m, p) {
          if (p['api'] == 'SYNO.Contacts.Addressbook') return _books();
          if (p['api'] == 'SYNO.Contacts.Label') return _labels();
          if (m == 'get' && p['api'] == 'SYNO.Contacts.Contact') {
            return _detail();
          }
          return _contacts();
        },
      );
      await tester.tap(find.text('demo_admin'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('删除联系人'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '删除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final del = boot.t.calls.lastWhere(
        (c) => c['method'] == 'delete' && c['api'] == 'SYNO.Contacts.Contact',
        orElse: () => const {},
      );
      expect(del['ids'], '["1"]');
      expect(find.text('已删除'), findsOneWidget);
    });
  });

  group('★ r349 头部副标题：宁可整行不画，也不许折行/截断', () {
    Future<void> pumpAt(
      WidgetTester tester,
      Size logical,
      double scale,
      String lang,
    ) async {
      setCurrentText(lookupAppText(Locale(lang)));
      addTearDown(() => setCurrentText(lookupAppText(const Locale('zh'))));
      tester.view.physicalSize = Size(
        logical.width * scale,
        logical.height * scale,
      );
      tester.view.devicePixelRatio = scale;
      addTearDown(tester.view.reset);
      // ★ 语言必须**同时**装进 widget 树（`AppText.delegate` + `locale`），
      // 否则 `context.t` 会回落成中文，"en" 这一档等于没测。
      await _pump(tester, locale: Locale(lang));
      await tester.pump(const Duration(milliseconds: 200));
    }

    for (final lang in const ['zh', 'en']) {
      testWidgets('手机 375×812 / $lang / x1.0：副标题不许被折行或截断', (
        tester,
      ) async {
        await pumpAt(tester, const Size(375, 812), 1.0, lang);
        final para = tester.renderObject<RenderParagraph>(
          find.byKey(const Key('contacts-subtitle')),
        );
        expect(para.didExceedMaxLines, isFalse, reason: '副标题被省略号截断了');
        expect(
          para.text.toPlainText().contains('\n'),
          isFalse,
          reason: '副标题折行了 —— CJK 会从词中间断开（真机缺陷原样）',
        );
      });

      testWidgets('窄屏 + 大字号 360×640 / $lang / x2.0：不许折行也不许截断', (
        tester,
      ) async {
        await pumpAt(tester, const Size(360, 640), 2.0, lang);
        final para = tester.renderObject<RenderParagraph>(
          find.byKey(const Key('contacts-subtitle')),
        );
        expect(para.didExceedMaxLines, isFalse);
        expect(para.text.toPlainText().contains('\n'), isFalse);
      });
    }

    testWidgets('宽屏 800×1280 / zh：副标题必须真的画出来（功能没被删掉）', (
      tester,
    ) async {
      await pumpAt(tester, const Size(800, 1280), 1.0, 'zh');
      final para = tester.renderObject<RenderParagraph>(
        find.byKey(const Key('contacts-subtitle')),
      );
      expect(para.didExceedMaxLines, isFalse);
      expect(
        para.text.toPlainText(),
        '通讯录 · 标签 · CardDAV',
        reason: '宽屏上副标题必须完整可见，文案也不许悄悄变长回去',
      );
    });

    // ★★★ 跨平台（§2.0.63①）：这条共享件会在 **macOS / iOS / Linux / Windows**
    // 上跑，而桌面窗口比手机宽得多 —— 必须钉住"**桌面上文案不许被误藏**"。
    // 之前只有 800×1280，是靠"判据对宽度单调"推出来的；这里把桌面尺寸**显式**钉下来。
    testWidgets('★★ 桌面窗口 1280×800 / zh：副标题必须真的画出来（不许在桌面上被误藏）', (
      tester,
    ) async {
      await pumpAt(tester, const Size(1280, 800), 1.0, 'zh');
      final para = tester.renderObject<RenderParagraph>(
        find.byKey(const Key('contacts-subtitle')),
      );
      expect(para.didExceedMaxLines, isFalse);
      expect(para.text.toPlainText(), '通讯录 · 标签 · CardDAV');
    });

    testWidgets('★★ 桌面窗口 1280×800 / en：更长的英文副标题同样要画出来', (tester) async {
      // 英文文案 `Synology Contacts · Address books / Labels / CardDAV` 比中文长得多，
      // 手机上是靠"放不下就整行不画"兜住的 —— 但**桌面上放得下就必须画**，
      // 否则这条兜底会变成"桌面永远看不到副标题"。
      await pumpAt(tester, const Size(1280, 800), 1.0, 'en');
      final para = tester.renderObject<RenderParagraph>(
        find.byKey(const Key('contacts-subtitle')),
      );
      expect(para.didExceedMaxLines, isFalse);
      expect(
        para.text.toPlainText(),
        'Synology Contacts · Address books / Labels / CardDAV',
        reason: '桌面上英文副标题必须完整可见（兜底不许把功能删掉）',
      );
    });

    testWidgets('★ 反向：把副标题换成超长串，判据必须能判出"放不下"', (tester) async {
      // 反向验证的意义：如果 `FittedSubtitle` 永远返回空串，
      // 上面那条"宽屏必须画出来"也会绿 —— 所以这里钉住"判据真的会判否"。
      await pumpAt(tester, const Size(375, 812), 1.0, 'zh');
      final fits = textFitsOnOneLine(
        tester.element(find.byType(ContactsPage)),
        '通讯录 · 标签 · CardDAV' * 6,
        Theme.of(
          tester.element(find.byType(ContactsPage)),
        ).textTheme.labelSmall,
        200,
      );
      expect(fits, isFalse, reason: '超长串在 200px 预算里必须判为放不下');
    });
  });
}
