// J7「发送到邮件」离线套件（接口层 + 页面层）。
//
// 官方证据（DSnote 1.12.0 反编译 `com/synology/dsnote/fragments/NoteFragment.java`）：
//   * 无附件/无行内图 → `sendMailHTML`：`Intent(ACTION_SENDTO, "mailto:")`
//     + `EXTRA_SUBJECT = mTitle` + `EXTRA_TEXT = Html.fromHtml(html)`；
//   * 有附件/行内图 → `sendMailText`：`ACTION_SEND_MULTIPLE` + `*/*` +
//     `EXTRA_STREAM`（本批未实现，见报告"残余缺口"）；
//   * 两条路都 `Intent.createChooser(..., getString(R.string.email_note))`，
//     `email_note` 实测（`aapt2 dump resources`）= **"Email note"**。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/notes/note_c3_providers.dart';
import 'package:synhub/src/features/notes/note_html.dart'
    show notePlainText;
import 'package:synhub/src/features/files/file_link_share.dart';
import 'package:synhub/src/features/notes/note_mail.dart';
import 'package:synhub/src/features/notes/note_providers.dart';
import 'package:synhub/src/features/notes/note_view_page.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _noteTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.NoteStation.Note': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.NoteStation.Notebook': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

Future<NoteStationApi> _api(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return NoteStationApi(api);
}

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
      checkedAt: DateTime(2026, 1, 1),
    );

NoteDto _stub(
  String id,
  String title, {
  String content = '<p>正文</p>',
  bool encrypt = false,
}) => NoteDto(
  objectId: id,
  title: title,
  content: content,
  hasContent: true,
  encrypt: encrypt,
);

/// 装配一个只够 NoteViewPage 跑起来的容器（不依赖真机、不连 NAS）。
Future<({ProviderContainer c, List<Map<String, String>> sent})> _boot({
  Set<String> apis = const {'SYNO.NoteStation.Note'},
}) async {
  final t = FakeTransport({}, {...FakeTransport.table, ..._noteTable});
  final api = await _api(t);
  final sent = <Map<String, String>>[];
  final container = ProviderContainer(
    overrides: [
      noteApiProvider.overrideWithValue(api),
      chatDatabaseProvider.overrideWith((ref) {
        final db = ChatDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return db;
      }),
      serviceAvailabilityProvider.overrideWith(
        () => _FixedAvailability(_snap(apis)),
      ),
      // 能力位整批缺失 → 导出/版本入口隐藏，页面只剩本行要测的邮件入口
      noteC3AvailabilityProvider.overrideWith(
        (ref) async => const NoteC3Availability(),
      ),
      noteMailProvider.overrideWithValue(({
        required String subject,
        required String body,
        List<String> attachments = const [],
      }) async {
        sent.add({'subject': subject, 'body': body});
        return true;
      }),
    ],
  );
  return (c: container, sent: sent);
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget child,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: child,
        localizationsDelegates: const [
          FlutterQuillLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: FlutterQuillLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  // ============================================================ 接口层

  group('mailto URI（官方 sendMailHTML 的等价物）', () {
    test('主题 + 正文都进 query，空格是 %20 不是 +', () {
      final uri = noteMailUri(subject: '周会 纪要', body: '第一行 第二行');
      expect(uri.scheme, 'mailto');
      // 官方 `MailTo.MAILTO_SCHEME` 就是空收件人的 mailto:
      expect(uri.path, '');
      expect(
        uri.query,
        contains('subject=%E5%91%A8%E4%BC%9A%20%E7%BA%AA%E8%A6%81'),
      );
      expect(
        uri.query,
        contains(
          'body=%E7%AC%AC%E4%B8%80%E8%A1%8C%20%E7%AC%AC%E4%BA%8C%E8%A1%8C',
        ),
      );
      expect(uri.query, isNot(contains('+')));
    });

    test('正文里的换行 / & / = / # 原样还原', () {
      const body = 'line1\nline2 & more = x#y';
      final uri = noteMailUri(subject: 's', body: body);
      expect(uri.queryParameters['body'], body);
    });

    test('展开后与 Uri.queryParameters 一致（不产生二次转义）', () {
      final uri = noteMailUri(subject: 'a b', body: 'c&d=e');
      expect(uri.queryParameters['subject'], 'a b');
      expect(uri.queryParameters['body'], 'c&d=e');
    });

    test('主题为空 → 不写 subject 参数；正文也在时仍然只有 body', () {
      final onlyBody = noteMailUri(subject: '', body: 'x');
      expect(onlyBody.query, 'body=x');
      final onlySubject = noteMailUri(subject: 't', body: '');
      expect(onlySubject.query, 'subject=t');
    });

    test('两者都空 → 裸 mailto:（仍拉起邮件应用，与官方 createChooser 同效）', () {
      final uri = noteMailUri(subject: '', body: '');
      expect(uri.toString(), 'mailto:');
      expect(uri.query, isEmpty);
    });
  });

  group('笔记 → 邮件正文（notePlainText 复用）', () {
    test('块级边界留一个空格（官方 GET_MAIL_TEXT 取的是纯文本）', () {
      expect(notePlainText('<p>a</p><p>b</p>'), 'a b');
      expect(notePlainText('<p>a<br>b</p>'), 'a b');
      expect(notePlainText(''), '');
    });

    test('脏标签被忽略，不把 HTML 当正文发出去', () {
      final text = notePlainText('<div style="x">A</div><div>B</div>');
      expect(text, 'A B');
      expect(text, isNot(contains('<div')));
    });
  });

  // ============================================================ 页面层

  group('NoteViewPage 的「发送到邮件」入口', () {
    testWidgets('入口在（key = note-email-entry）且带 tooltip', (tester) async {
      final b = await _boot();
      addTearDown(b.c.dispose);
      await _pump(tester, b.c, NoteViewPage(note: _stub('n1', '周会纪要')));

      expect(find.byKey(const Key('note-email-entry')), findsOneWidget);
      expect(find.byIcon(Icons.mail_outline), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点一下就用「标题 + 纯文本正文」调用发送器', (tester) async {
      final b = await _boot();
      addTearDown(b.c.dispose);
      await _pump(
        tester,
        b.c,
        NoteViewPage(note: _stub('n1', '周会纪要', content: '<p>甲</p><p>乙</p>')),
      );

      await tester.tap(find.byKey(const Key('note-email-entry')));
      await tester.pump();

      expect(b.sent, hasLength(1));
      expect(b.sent.single['subject'], '周会纪要');
      expect(b.sent.single['body'], '甲 乙');
      expect(tester.takeException(), isNull);
    });

    testWidgets('空正文也不崩（官方同样会发出去）', (tester) async {
      final b = await _boot();
      addTearDown(b.c.dispose);
      await _pump(
        tester,
        b.c,
        NoteViewPage(note: _stub('n1', '空', content: '')),
      );

      await tester.tap(find.byKey(const Key('note-email-entry')));
      await tester.pump();

      expect(b.sent, hasLength(1));
      expect(b.sent.single['body'], '');
      expect(tester.takeException(), isNull);
    });

    testWidgets('加密且未解锁 → 入口禁用（不把密文发出去）', (tester) async {
      final b = await _boot();
      addTearDown(b.c.dispose);
      await _pump(
        tester,
        b.c,
        NoteViewPage(note: _stub('n1', '密', content: 'CIPHER', encrypt: true)),
      );

      final button = tester.widget<IconButton>(
        find.byKey(const Key('note-email-entry')),
      );
      expect(button.onPressed, isNull);
      expect(b.sent, isEmpty);
    });

    testWidgets('发送失败（没有可用应用）→ 出提示条', (tester) async {
      final t = FakeTransport({}, {...FakeTransport.table, ..._noteTable});
      final api = await _api(t);
      final container = ProviderContainer(
        overrides: [
          noteApiProvider.overrideWithValue(api),
          chatDatabaseProvider.overrideWith((ref) {
            final db = ChatDatabase(NativeDatabase.memory());
            ref.onDispose(db.close);
            return db;
          }),
          serviceAvailabilityProvider.overrideWith(
            () => _FixedAvailability(_snap(const {})),
          ),
          noteC3AvailabilityProvider.overrideWith(
            (ref) async => const NoteC3Availability(),
          ),
          noteMailProvider.overrideWithValue(
            ({
              required String subject,
              required String body,
              List<String> attachments = const [],
            }) async => false,
          ),
        ],
      );
      addTearDown(container.dispose);
      await _pump(tester, container, NoteViewPage(note: _stub('n1', '周会纪要')));

      await tester.tap(find.byKey(const Key('note-email-entry')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.text(noteMailText(NoteMailTextKeys.mailUnavailable, '没有可用的邮件应用。')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  // ============================================================ 真实现守卫

  group('defaultNoteMail（真实现）', () {
    test('测试环境直接返回 true，不拉起任何外部应用', () async {
      expect(
        await defaultNoteMail(subject: 's', body: 'b'),
        isTrue,
        reason: 'isTestEnvironment 下不能真的调 url_launcher',
      );
    });

    test('ARB 文案 key 与默认中文对得上', () {
      expect(NoteMailTextKeys.sendToEmail, 'noteMailSendToEmail');
      expect(NoteMailTextKeys.mailUnavailable, 'noteMailUnavailable');
      expect(noteMailText(NoteMailTextKeys.sendToEmail, '发送到邮件'), '发送到邮件');
    });

    test('真实 ARB 里有这两条 key（append-only 契约）', () {
      for (final f in const ['lib/l10n/app_zh.arb', 'lib/l10n/app_en.arb']) {
        final body = File(f).readAsStringSync();
        expect(body, contains('"noteMailSendToEmail"'), reason: f);
        expect(body, contains('"noteMailUnavailable"'), reason: f);
      }
    });
  });
  _mailAttachmentTransportTests();
}

// ★★★ 第 111 轮：官方 `NoteFragment.prepareMailContent` 的**分流** ——
// 无附件 `sendMailHTML`（SENDTO + mailto:）、有附件 `sendMailText`
// （ACTION_SEND_MULTIPLE + FileProvider uri）。此前的实现只有 mailto 一支。
void _mailAttachmentTransportTests() {
  group('111. 邮件带附件（官方 sendMailText / SEND_MULTIPLE）', () {
    test('★ 分流规则：无附件 → mailto，有附件 → SEND_MULTIPLE', () {
      expect(noteMailTransportFor(const []), NoteMailTransport.mailto);
      expect(
        noteMailTransportFor(const ['/tmp/a.pdf']),
        NoteMailTransport.attachments,
      );
    });

    test('★ 默认实现：测试环境不碰平台（有附件也一样）', () async {
      expect(
        await defaultNoteMail(
          subject: 's',
          body: 'b',
          attachments: const ['/tmp/a.pdf'],
        ),
        isTrue,
      );
    });

    test('★ 有附件 → 调 shareFiles（多附件、带正文与标题），不调 mailto', () async {
      final bridge = _RecordingShareBridge();
      final sender = NoteMailSender(bridge: bridge, platformTouching: true);
      final ok = await sender(
        subject: '周会',
        body: '<p>正文</p>',
        attachments: const ['/tmp/a.pdf', '/tmp/b.png'],
      );
      expect(ok, isTrue);
      expect(bridge.fileCalls, hasLength(1));
      expect(bridge.fileCalls.single['paths'], ['/tmp/a.pdf', '/tmp/b.png']);
      expect(bridge.fileCalls.single['subject'], '周会');
      expect(bridge.fileCalls.single['text'], '<p>正文</p>');
      expect(bridge.textCalls, isEmpty, reason: '有附件时不该退化成纯文本分享');
    });

    test('★ 附件全失败 → 回落纯文本（不让笔记堵死；我方加固）', () async {
      final bridge = _RecordingShareBridge(filesOk: false, textOk: true);
      final sender = NoteMailSender(bridge: bridge, platformTouching: true);
      final ok = await sender(
        subject: 's',
        body: 'b',
        attachments: const ['/tmp/a.pdf'],
      );
      expect(ok, isTrue);
      expect(bridge.fileCalls, hasLength(1));
      // mailto 在测试环境拉不起来（Platform 分支），最终落到纯文本分享
      expect(bridge.textCalls, hasLength(1));
    });
  });
}

/// 记录调用的假分享桥（不碰任何平台通道）。
class _RecordingShareBridge extends TextShareBridge {
  _RecordingShareBridge({this.filesOk = true, this.textOk = true});

  final bool filesOk;
  final bool textOk;
  final List<Map<String, Object?>> fileCalls = [];
  final List<Map<String, Object?>> textCalls = [];

  @override
  Future<bool> shareFiles({
    required List<String> paths,
    String text = '',
    String subject = '',
    String mime = '*/*',
  }) async {
    fileCalls.add({
      'paths': paths,
      'text': text,
      'subject': subject,
      'mime': mime,
    });
    return filesOk;
  }

  @override
  Future<bool> shareText({
    required String text,
    required String subject,
  }) async {
    textCalls.add({'text': text, 'subject': subject});
    return textOk;
  }
}
