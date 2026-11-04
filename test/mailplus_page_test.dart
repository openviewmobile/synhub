// MailPlus 页面层离线验证（阶段二 A 最后一批）。
//
// 接口层用例在 `test/mailplus_test.dart`；这里只验：
//   * 列表页把请求发对了、把会话画出来了（未读粗体/星标/附件/时间）；
//   * 空态/错误态**区分**套件未安装 / 无权限 / 网络失败（图标+文案都不同，
//     未安装态**不给重试**，改引导去套件中心）；
//   * 写信页：空收件人不发请求；填了才走 `Draft.create` → `send`。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/mailplus.dart';
import 'package:synhub/src/features/mailplus/mail_compose_page.dart';
import 'package:synhub/src/features/mailplus/mail_page.dart';
import 'package:synhub/src/features/mailplus/mail_providers.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _mcTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.MailClient.Info': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.MailClient.Mailbox': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 7,
  },
  'SYNO.MailClient.Thread': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.MailClient.Message': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 10,
  },
  'SYNO.MailClient.Draft': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 7,
  },
};

const _mailboxes = {
  'total': 1,
  'mailbox': [
    {
      'id': '1',
      'path': 'INBOX',
      'is_own': true,
      'subscribed': true,
      'additional': {'unread_count': 2},
    },
  ],
};

Map<String, dynamic> _thread({
  String id = 't1',
  String subject = '周报',
  String from = '张三 <z@example.com>',
  bool unread = true,
  bool star = false,
  bool attach = false,
  int lastModified = 1700000000,
}) => {
  'id': id,
  'star': star,
  'unread': unread ? 1 : 0,
  'last_modified': lastModified,
  'message': [
    {
      'id': 'm-$id',
      'subject': subject,
      'from': from,
      'body_preview': '预览内容',
      if (attach)
        'attachment': [
          {'name': 'a.pdf', 'size': 1024},
        ],
    },
  ],
};

/// 挂一个页面：假传输 + 只覆盖邮件模块的 API provider。
Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester,
  Widget page, {
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, int> failures = const {},
  bool noMail = false,
  bool noSession = false,
  void Function(FakeTransport t)? setup,
}) async {
  final t = FakeTransport(responses, {
    ...FakeTransport.table,
    if (!noMail) ..._mcTable,
  });
  t.failures.addAll(failures);
  setup?.call(t);
  final api = DsmWebApi(t);
  await api.discover();
  final c = ProviderContainer(
    overrides: [
      mailApiProvider.overrideWithValue(noSession ? null : MailPlusApi(api)),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await tester.pump(); // postFrameCallback → load()
  await tester.pump(const Duration(milliseconds: 200));
  // 邮箱树回来 → ref.listen 选中 INBOX → 再拉一次列表
  await tester.pump(const Duration(milliseconds: 200));
  return (t: t, c: c);
}

void main() {
  group('空态 / 错误态（三态必须互相区分）', () {
    testWidgets('没连会话 → 未连接，不是"没安装"', (tester) async {
      await _pump(tester, const MailPage(), noSession: true);
      expect(find.byKey(const Key('mail-no-session')), findsOneWidget);
      expect(find.byKey(const Key('mail-not-installed')), findsNothing);
      expect(find.text('这台 NAS 没有安装 MailPlus'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('套件未安装 → 说"没有安装"+套件中心引导，不给重试', (tester) async {
      await _pump(tester, const MailPage(), noMail: true);
      expect(find.byKey(const Key('mail-not-installed')), findsOneWidget);
      expect(find.text('这台 NAS 没有安装 MailPlus'), findsOneWidget);
      expect(
        find.text('在 DSM「套件中心」安装 MailPlus（并先装好 MailPlus Server）后即可使用'),
        findsOneWidget,
      );
      expect(find.text('重试'), findsNothing);
      expect(find.text('邮件列表加载失败'), findsNothing);
      expect(find.byKey(const Key('mail-no-privilege')), findsNothing);
      expect(find.byIcon(Icons.extension_off_outlined), findsOneWidget);
      // 未安装 → 不出现"写邮件"入口
      expect(find.byKey(const Key('mail-compose')), findsNothing);
    });

    testWidgets('无权限（160）→ 说权限 + 找管理员，不是"加载失败"', (tester) async {
      await _pump(
        tester,
        const MailPage(),
        responses: {'SYNO.MailClient.Mailbox.list': _mailboxes},
        failures: {'SYNO.MailClient.Thread.list': 160},
      );
      expect(find.byKey(const Key('mail-no-privilege')), findsOneWidget);
      expect(find.text('这个账号没有使用 MailPlus 的权限'), findsOneWidget);
      expect(find.text('请联系管理员为这个账号授予 MailPlus 权限'), findsOneWidget);
      expect(find.text('邮件列表加载失败'), findsNothing);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });

    testWidgets('网络失败 → 网络文案 + 可重试；图标与上面两种不同', (tester) async {
      await _pump(
        tester,
        const MailPage(),
        responses: {'SYNO.MailClient.Mailbox.list': _mailboxes},
        setup: (t) => t.onCall = (p) {
          if (p['method'] == 'list' && p['api'] == 'SYNO.MailClient.Thread') {
            throw DsmTransportException('offline');
          }
          return null;
        },
      );
      expect(find.byKey(const Key('mail-error')), findsOneWidget);
      expect(find.text('邮件列表加载失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.byIcon(Icons.wifi_off), findsOneWidget);
      expect(find.byKey(const Key('mail-not-installed')), findsNothing);
      expect(find.byKey(const Key('mail-no-privilege')), findsNothing);
    });

    testWidgets('装了但没有邮件 → 空态（不是错误，也不是未安装）', (tester) async {
      await _pump(
        tester,
        const MailPage(),
        responses: {
          'SYNO.MailClient.Mailbox.list': _mailboxes,
          'SYNO.MailClient.Thread.list': {'total': 0, 'thread': []},
        },
      );
      expect(find.byKey(const Key('mail-empty')), findsOneWidget);
      expect(find.text('没有邮件'), findsOneWidget);
      expect(find.byKey(const Key('mail-not-installed')), findsNothing);
      expect(find.byKey(const Key('mail-error')), findsNothing);
      expect(find.text('重试'), findsNothing);
    });
  });

  group('列表页正常路径', () {
    testWidgets('两封会话 → 行/未读/星标/附件角标；请求带 mailbox condition', (tester) async {
      final r = await _pump(
        tester,
        const MailPage(),
        responses: {
          'SYNO.MailClient.Mailbox.list': _mailboxes,
          'SYNO.MailClient.Thread.list': {
            'total': 2,
            'has_more': false,
            'thread': [
              _thread(id: 't1', subject: '周报', unread: true, star: true),
              _thread(
                id: 't2',
                subject: '发票',
                from: '财务 <f@example.com>',
                unread: false,
                attach: true,
              ),
            ],
          },
        },
      );
      expect(find.byKey(const Key('mail-thread-t1')), findsOneWidget);
      expect(find.byKey(const Key('mail-thread-t2')), findsOneWidget);
      expect(find.text('周报'), findsOneWidget);
      expect(find.text('发票'), findsOneWidget);
      expect(find.byKey(const Key('mail-mailbox-1')), findsOneWidget);
      expect(find.text('共 2 封'), findsOneWidget);
      // 至少有一次 Thread.list 带了 mailbox=INBOX（默认选中 INBOX 后重拉）
      final withMailbox = r.t.calls.where((c) {
        if (c['method'] != 'list' || c['api'] != 'SYNO.MailClient.Thread') {
          return false;
        }
        return '${c['condition']}'.contains('INBOX');
      });
      expect(withMailbox, isNotEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('会话没有主题 → 显示"（无主题）"', (tester) async {
      await _pump(
        tester,
        const MailPage(),
        responses: {
          'SYNO.MailClient.Mailbox.list': _mailboxes,
          'SYNO.MailClient.Thread.list': {
            'total': 1,
            'thread': [_thread(id: 't1', subject: '')],
          },
        },
      );
      expect(find.text('（无主题）'), findsOneWidget);
    });
  });

  group('写信页', () {
    testWidgets('列表页 FAB → 进写信页；空收件人不发请求', (tester) async {
      final r = await _pump(
        tester,
        const MailPage(),
        responses: {
          'SYNO.MailClient.Mailbox.list': _mailboxes,
          'SYNO.MailClient.Thread.list': {'total': 0, 'thread': []},
        },
      );
      await tester.tap(find.byKey(const Key('mail-compose')));
      await tester.pumpAndSettle();
      expect(find.byType(MailComposePage), findsOneWidget);
      expect(find.text('写邮件'), findsWidgets);

      await tester.tap(find.byKey(const Key('mail-send')));
      await tester.pump();
      expect(find.text('请至少填写一个收件人'), findsOneWidget);
      expect(
        r.t.calls.where((c) => c['api'] == 'SYNO.MailClient.Draft'),
        isEmpty,
      );
    });

    testWidgets('填了收件人 → 先 Draft.create 再 send，然后退回列表', (tester) async {
      final r = await _pump(
        tester,
        const MailPage(),
        responses: {
          'SYNO.MailClient.Mailbox.list': _mailboxes,
          'SYNO.MailClient.Thread.list': {'total': 0, 'thread': []},
          'SYNO.MailClient.Draft.create': {'id': 'd-1'},
        },
      );
      await tester.tap(find.byKey(const Key('mail-compose')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('mail-compose-to')),
        'a@b.c, d@e.f',
      );
      await tester.enterText(
        find.byKey(const Key('mail-compose-subject')),
        '标题',
      );
      await tester.enterText(find.byKey(const Key('mail-compose-body')), '正文');
      await tester.tap(find.byKey(const Key('mail-send')));
      await tester.pumpAndSettle();

      final draftCalls = r.t.calls
          .where((c) => c['api'] == 'SYNO.MailClient.Draft')
          .toList();
      expect(draftCalls.map((c) => c['method']), ['create', 'send']);
      expect(draftCalls.first['version'], '7');
      expect(draftCalls.first['to'], '["a@b.c","d@e.f"]');
      expect(draftCalls.last['id'], 'd-1');
      // 发完退回列表
      expect(find.byType(MailComposePage), findsNothing);
    });

    testWidgets('列表页 FAB 在未安装时不出现（无入口可点）', (tester) async {
      await _pump(tester, const MailPage(), noMail: true);
      expect(find.byKey(const Key('mail-compose')), findsNothing);
    });
  });
}
