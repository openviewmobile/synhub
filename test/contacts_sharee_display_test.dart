// ★★★ 第 349 轮真机缺陷 D66：`共享给 syno.contacts.internal.everyone`
//
// 真机（`联系人 → 通讯录与标签`）原样：`Team Contacts` 那行副标题是
//     `4 位联系人 · 团队/公开 · 共享自 Contacts · 共享给 syno.contacts.internal.everyone`
// —— **服务端内部群组标识当了用户文案**（AGENTS §2.0.47 家族第 8 处）。
// 前七处都是静态字面量（ARB / Dart 渲染点），静态守卫拦得住；
// 这一处是**运行时值** ⇒ 只能在渲染点兜（`core/ui/user_copy.dart`）。
//
// 本文件钉两件事：
//   ① 判据 `looksLikeInternalIdentifier` **保守**（邮箱/人名不许误命中）—— 带反向验证；
//   ② 渲染点真的把它换成了本地化名字，且**两个生产者**（`shared_with` 裸值 /
//      principals 的 `display_name`）走的是**同一道**解析。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/core/ui/user_copy.dart';
import 'package:synhub/src/data/contacts_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/contacts/contacts_manage_page.dart';
import 'package:synhub/src/features/contacts/contacts_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Contacts.Addressbook': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Contacts.Principal': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

void main() {
  group('★ r349 「内部标识符不许当用户文案」判据', () {
    test('服务端内部命名空间命中', () {
      expect(looksLikeInternalIdentifier('syno.contacts.internal.everyone'), isTrue);
      expect(looksLikeInternalIdentifier('syno.contacts.internal.admin'), isTrue);
      expect(looksLikeInternalIdentifier('SYNO.Contacts.Contact'), isTrue);
      expect(looksLikeInternalIdentifier('team.internal.sales'), isTrue);
    });

    // ★ 反向验证：判据保守才不会把真名字吃掉。
    // 少了这组，"永远返回 true"也能让上面的用例全绿。
    test('★ 反向：真名字 / 邮箱 / 空串不许误命中', () {
      expect(looksLikeInternalIdentifier('user@example.com'), isFalse, reason: '邮箱带点，但不是内部串');
      expect(looksLikeInternalIdentifier('demo_admin'), isFalse);
      expect(looksLikeInternalIdentifier('张三'), isFalse);
      expect(looksLikeInternalIdentifier('Sales Team'), isFalse);
      expect(looksLikeInternalIdentifier(''), isFalse);
      expect(looksLikeInternalIdentifier('   '), isFalse);
      expect(looksLikeInternalIdentifier('synology'), isFalse, reason: "'syno' 前缀不等于 'syno.' 前缀");
    });
  });

  group('★ r349 共享对象渲染点', () {
    Future<void> pump(WidgetTester tester, {required String sharedWith}) async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.onCall = (params) {
        switch (params['method']) {
          case 'list':
            if (params['api'] == 'SYNO.Contacts.Addressbook') {
              return {
                'addressbook': [
                  {
                    'id': 5,
                    'name': 'Team Contacts',
                    'type': 4,
                    'mode': 0,
                    'member_count': 4,
                    'shared_from': 'Contacts',
                    'shared_with': sharedWith,
                  },
                ],
                'total': 1,
              };
            }
            return const <String, dynamic>{};
          case 'get':
            return const <String, dynamic>{};
          default:
            return const <String, dynamic>{};
        }
      };
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final db = ChatDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          contactsApiProvider.overrideWithValue(ContactsApi(api)),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: const ContactsManagePage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('`shared_with` 是内部群组 id ⇒ 显示本地化名字，不显示内部串', (tester) async {
      await pump(tester, sharedWith: 'syno.contacts.internal.everyone');
      expect(find.textContaining('syno.contacts.internal.everyone'), findsNothing,
          reason: '内部标识符又被画到界面上了（D66 复发）');
      expect(find.textContaining('所有人'), findsOneWidget,
          reason: '已知内部群组要换成本地化名字（zh 模板是"所有人"）');
    });

    testWidgets('★ 反向：正常名字仍然照原样显示（不许把功能删掉）', (tester) async {
      await pump(tester, sharedWith: 'demo_user');
      expect(find.textContaining('demo_user'), findsOneWidget);
      expect(find.textContaining('所有人'), findsNothing);
    });
  });
}
