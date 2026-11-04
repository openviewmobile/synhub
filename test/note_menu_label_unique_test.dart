// r349（D72）守卫：**同一行里两个不同出口不许共用同一个文案 key**。
//
// 真机现象（Android，2026-10-11）：笔记详情页右上角 `⋮` 菜单里出现
// **两条同名项「发送到邮件」**（y=237 与 y=384 两行，图标一个 ✉️ 一个 ⤴️）。
//
// 根因：`note_view_page.dart` 里两个**语义不同**的入口
//   * `note-share-out-entry`（`Icons.ios_share`，把正文交给**系统分享面板** `ACTION_SEND`）
//   * `note-email-entry`     （`Icons.mail_outline`，走 **`mailto:`** 邮件 intent）
// 都写了 `noteMailText(NoteMailTextKeys.sendToEmail, …)` —— **同一个 key**。
// 第二个参数是**没装翻译器时的中文兜底**，一旦 ARB 装上（生产如此），
// 两条 tooltip **都**解析成 ARB 里 `noteMailSendToEmail` 的值 ⇒ 同名。
//
// ★★ 为什么必须**另开一个文件**（而不是加进 `test/note_mail_test.dart`）：
//    那个文件里的 `_pump` 用的是**裸 `MaterialApp`**（没装 `AppText` 的 delegate）
//    ⇒ `dataText(key, zh)` 恒回落第二个参数 ⇒ 两条兜底串（`分享笔记` / `发送到邮件`）
//    **本来就是不同的** ⇒ **在那个装置里这个缺陷永远测不出来**。
//    这是 AGENTS §2.0.65 仪器⑯「测试装置不诚实 ⇒ 用例不可能红」的现场复现：
//    要验"装了翻译之后长什么样"，就必须装**生产同一套** delegate。
//
// ★ 反向断言（两条）：① 两个 tooltip **必须不同**；② 它们**都不得**等于
//   `noteMailUnavailable`（防"两个都回落成同一句别的文案"这种换汤不换药）。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/l10n/gen/app_localizations.dart';
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
import 'package:synhub/src/features/notes/note_mail.dart';
import 'package:synhub/src/features/notes/note_providers.dart';
import 'package:synhub/src/core/i18n/l10n.dart' show lookupAppText, setCurrentText;
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

NoteDto _stub(String id, String title) => NoteDto(
  objectId: id,
  title: title,
  content: '<p>正文</p>',
  hasContent: true,
  encrypt: false,
);

Future<ProviderContainer> _boot() async {
  final t = FakeTransport({}, {...FakeTransport.table, ..._noteTable});
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final container = ProviderContainer(
    overrides: [
      noteApiProvider.overrideWithValue(NoteStationApi(api)),
      chatDatabaseProvider.overrideWith((ref) {
        final db = ChatDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return db;
      }),
      serviceAvailabilityProvider.overrideWith(
        () => _FixedAvailability(_snap(const {'SYNO.NoteStation.Note'})),
      ),
      noteC3AvailabilityProvider.overrideWith(
        (ref) async => const NoteC3Availability(),
      ),
      noteMailProvider.overrideWithValue(({
        required String subject,
        required String body,
        List<String> attachments = const [],
      }) async => true),
    ],
  );
  return container;
}

/// ★★★ 关键（本轮踩到并靠"装置自证"抓出来的）：`noteMailText` 走的是
/// **`dataText(key, zh)`**（`data_text.dart`），它的翻译器**不是**由
/// `LocalizationsDelegate` 装的，而是由 **`SynologyChatApp.build` 调
/// `setCurrentText(lookupAppText(locale))`** 装的（`l10n.dart:44`）。
/// ⇒ 只装 delegate **不够**：`dataText` 会静默回落第二个参数。
/// 本函数把**生产的那一步**也照做一遍，两条腿都装上。
Future<void> _pump(WidgetTester tester, ProviderContainer c, Locale locale) async {
  // ① 生产里由 SynologyChatApp.build 做的那一步
  setCurrentText(lookupAppText(locale));
  addTearDown(() => setCurrentText(lookupAppText(const Locale('zh'))));
  // ② 正常挂树（`context.t` 那一半走 delegate）
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        locale: locale,
        home: NoteViewPage(note: _stub('n1', '周会纪要')),
        localizationsDelegates: [
          ...AppText.localizationsDelegates,
          FlutterQuillLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppText.supportedLocales,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// 取某个 key 对应按钮的 tooltip 文案（`IconButton(tooltip:)` 会包一层 `Tooltip`）。
String? _tooltipOf(WidgetTester tester, String key) {
  final finder = find.descendant(
    of: find.byKey(Key(key)),
    matching: find.byType(Tooltip),
  );
  if (finder.evaluate().isEmpty) return null;
  return tester.widget<Tooltip>(finder.first).message;
}

void main() {
  // 两个**语义不同**的出口：系统分享面板 vs `mailto:`。
  const shareOutKey = 'note-share-out-entry';
  const emailKey = 'note-email-entry';

  for (final locale in const [Locale('zh'), Locale('en')]) {
    testWidgets('${locale.languageCode}：分享出口与邮件出口**不同名**（D72）', (
      tester,
    ) async {
      final c = await _boot();
      addTearDown(c.dispose);
      await _pump(tester, c, locale);

      // 两个入口都在
      expect(find.byKey(const Key(shareOutKey)), findsOneWidget);
      expect(find.byKey(const Key(emailKey)), findsOneWidget);

      final share = _tooltipOf(tester, shareOutKey);
      final mail = _tooltipOf(tester, emailKey);

      // ① 都取到了（装的是生产 delegate ⇒ 走的是 ARB，不是兜底）
      expect(share, isNotNull, reason: '分享出口应有 tooltip');
      expect(mail, isNotNull, reason: '邮件出口应有 tooltip');

      // ② ★ 正向：两者**必须不同**（修复前两条都是 ARB 里的「发送到邮件/Email note」）
      expect(
        share,
        isNot(equals(mail)),
        reason: '同一个 ⋮ 菜单里两个不同出口不许同名（D72）',
      );

      // ③ 反向：都不许是"没有可用邮件应用"那句（防换成另一种同名）
      final unavailable = noteMailText(
        NoteMailTextKeys.mailUnavailable,
        '没有可用的邮件应用。',
      );
      expect(share, isNot(equals(unavailable)));
      expect(mail, isNot(equals(unavailable)));

      // ④ 反向：分享出口**不许**再等于邮件那句（把 D72 钉死）
      final emailLabel = noteMailText(
        NoteMailTextKeys.sendToEmail,
        '发送到邮件',
      );
      expect(share, isNot(equals(emailLabel)));

      // ⑤ 正向：邮件出口**就是**邮件那句（这条同时证明"装上了翻译"）
      expect(mail, equals(emailLabel));

      expect(tester.takeException(), isNull);
    });
  }

  // ★★ 装置自证：**在同一次 pump 之后**再解析一次 —— `dataText` 的 resolver 是
  //    由挂在树上的 `AppText` delegate 装的，**没有树就没有 ARB**。
  //    故意传一个**错的**兜底串：若解析真走 ARB，结果就**不会**是它。
  //    （这条就是防"本文件其余断言其实全在测兜底串、等于没测"。）
  testWidgets('★ 装置自证：装了生产 delegate ⇒ 文案确实来自 ARB（不是兜底）', (
    tester,
  ) async {
    final c = await _boot();
    addTearDown(c.dispose);
    await _pump(tester, c, const Locale('zh'));

    final fromArb = noteMailText(
      NoteMailTextKeys.sendToEmail,
      'THIS-FALLBACK-MUST-NOT-WIN',
    );
    expect(
      fromArb,
      isNot(equals('THIS-FALLBACK-MUST-NOT-WIN')),
      reason: '装了 AppText delegate 后，dataText 必须走 ARB 而不是第二个参数'
          '（否则本文件的其余断言全是在测兜底串，等于没测）',
    );
  });
}
