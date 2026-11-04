// 个人资料（`SYNO.Personal.Profile / get`）的离线验证。
//
// 两类断言：
//   1. **协议形状**：api / method / version / 参数 / path 来源
//      —— 真机原文：`SYNO.Personal.Profile/get`，path=`entry.cgi`，v1..3，无参
//      （docs/device-readonly-verification-evidence-r16.md §12）；
//   2. **界面**：空值如实显示"未设置"、`emails` 空数组走空态、
//      有值时正常显示（**不编造**任何昵称/邮箱）。
//
// ⚠️ 本文件是**离线**用例：全部走 `FakeTransport`，不碰真实 NAS。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/personal_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/settings/personal_profile_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

/// 能力表：真机 `SYNO.Personal.Profile` 是 path=entry.cgi、min=1、max=3。
const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Personal.Profile': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
};

/// 真机回包原文（小号/空资料；`emails` 是空数组）。
const _realEmptyReply = {
  'id': 'a83c54f9-4b31-424e-b82b-9653697f921f',
  'email': '',
  'emails': [],
  'nickName': '',
  'isGuest': false,
};

/// 记录 `path` 的假传输：`_prepare` 是不是**从能力表取 path**（规程 §1.4）
/// 只有把 `postForm` 的 path 抓下来才验得了。
class _PathRecordingTransport extends FakeTransport {
  _PathRecordingTransport(super.responses, super.apiTable);

  final List<String> paths = [];

  @override
  Future<String> postForm(
    String path,
    Map<String, dynamic> params, {
    String? module,
  }) {
    paths.add(path);
    return super.postForm(path, params);
  }
}

Future<(PersonalApi, _PathRecordingTransport)> _api({
  Map<String, Map<String, dynamic>> table = _table,
}) async {
  final t = _PathRecordingTransport(const {}, table);
  final api = DsmWebApi(t);
  await api.discover();
  return (PersonalApi(api), t);
}

Map<String, dynamic>? _lastCall(_PathRecordingTransport t, String key) {
  for (final call in t.calls.reversed) {
    if ('${call['api']}.${call['method']}' == key) return call;
  }
  return null;
}

void main() {
  group('PersonalProfileDto 解析（不补默认值）', () {
    test('真机空资料：空串保持空串、空数组保持空数组', () {
      final p = PersonalProfileDto.fromJson(
        Map<String, dynamic>.from(_realEmptyReply),
      );
      expect(p.id, 'a83c54f9-4b31-424e-b82b-9653697f921f');
      expect(p.email, '');
      expect(p.emails, isEmpty);
      expect(p.nickName, '');
      expect(p.isGuest, isFalse);
      expect(p.hasNickName, isFalse);
      expect(p.hasEmail, isFalse);
      expect(p.hasAnyEmail, isFalse);
      expect(p.validEmails, isEmpty);
    });

    test('有值时逐字段读出（含 emails 数组）', () {
      final p = PersonalProfileDto.fromJson({
        'id': 'u-1',
        'email': 'main@example.com',
        'emails': ['main@example.com', 'alt@example.com', ''],
        'nickName': 'Demo_user',
        'isGuest': true,
      });
      expect(p.nickName, 'Demo_user');
      expect(p.email, 'main@example.com');
      // 空串项被过滤，但不影响原始 emails 长度
      expect(p.validEmails, ['main@example.com', 'alt@example.com']);
      expect(p.hasAnyEmail, isTrue);
      expect(p.isGuest, isTrue);
    });

    test('缺字段 / 类型不对：不崩、如实空着', () {
      final p = PersonalProfileDto.fromJson(const {});
      expect(p.id, '');
      expect(p.nickName, '');
      expect(p.emails, isEmpty);
      expect(p.isGuest, isFalse);
      // `emails` 给成字符串（服务端异常形态）→ 当作没有，不抛
      final q = PersonalProfileDto.fromJson(const {'emails': 'oops'});
      expect(q.emails, isEmpty);
      // 全空白昵称视同没设置
      final w = PersonalProfileDto.fromJson(const {'nickName': '   '});
      expect(w.hasNickName, isFalse);
    });
  });

  group('请求形状（真机原文对齐）', () {
    test('api/method/version=3，且 path 来自能力表（不是写死的）', () async {
      final (api, t) = await _api();
      final p = await api.profile();
      expect(p.nickName, '');
      final call = _lastCall(t, 'SYNO.Personal.Profile.get');
      expect(call, isNotNull);
      expect(call!['version'], '3', reason: '能力表 max=3 ⇒ 候选 [3,2,1] 收敛到 3');
      // 无业务参数（真机就是不传参）
      expect(call.keys.toSet(), {'api', 'method', 'version'});
      // path 由 `SYNO.API.Info` 决定：能力表写 entry.cgi 就必须发 entry.cgi
      expect(t.paths, isNotEmpty);
      expect(t.paths.last, 'entry.cgi');
    });

    test('老服务器只有 v1 ⇒ 协商到 v1（不硬发 v3）', () async {
      final (api, t) = await _api(
        table: const {
          'SYNO.API.Info': {
            'path': 'query.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
          'SYNO.Personal.Profile': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
        },
      );
      await api.profile();
      expect(_lastCall(t, 'SYNO.Personal.Profile.get')!['version'], '1');
    });

    test('能力表把 path 写成 query.cgi ⇒ 跟着发 query.cgi（规程 §1.4）', () async {
      final (api, t) = await _api(
        table: const {
          'SYNO.API.Info': {
            'path': 'query.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
          'SYNO.Personal.Profile': {
            'path': 'query.cgi',
            'minVersion': 1,
            'maxVersion': 3,
          },
        },
      );
      await api.profile();
      expect(t.paths.last, 'query.cgi');
    });

    test('出错照常抛（不吞成"空资料"）', () async {
      final t = _PathRecordingTransport(const {}, _table);
      t.failures['SYNO.Personal.Profile.get'] = DsmErrorCode.noPermission;
      final api = DsmWebApi(t);
      await api.discover();
      await expectLater(
        PersonalApi(api).profile(),
        throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 105)),
      );
    });
  });

  group('个人资料页（离线）', () {
    Future<_PathRecordingTransport> pump(
      WidgetTester tester,
      Map<String, dynamic> reply, {
      Map<String, Map<String, dynamic>> table = _table,
    }) async {
      final t = _PathRecordingTransport(const {}, table);
      t.onCall = (params) =>
          params['api'] == 'SYNO.Personal.Profile' ? reply : null;
      final api = DsmWebApi(t);
      await api.discover();
      final c = ProviderContainer(
        overrides: [personalApiProvider.overrideWithValue(PersonalApi(api))],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), home: PersonalProfilePage()),
        ),
      );
      await tester.pumpAndSettle();
      return t;
    }

    testWidgets('真机空资料：昵称/邮箱如实显示"未设置"，emails 空数组明说"未绑定邮箱"', (tester) async {
      await pump(tester, Map<String, dynamic>.from(_realEmptyReply));
      // 昵称 + 邮箱两行都是"未设置"
      expect(
        find.byKey(const Key('personal-profile-nickname')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('personal-profile-email')), findsOneWidget);
      expect(find.text('未设置'), findsNWidgets(2));
      // emails 空数组 ⇒ 明确的空态文案（不是静默省略）
      expect(
        find.byKey(const Key('personal-profile-emails-empty')),
        findsOneWidget,
      );
      expect(find.text('未绑定邮箱'), findsOneWidget);
      // isGuest=false ⇒ 普通账号；访客提示不出现
      expect(find.text('普通账号'), findsOneWidget);
      expect(
        find.byKey(const Key('personal-profile-guest-hint')),
        findsNothing,
      );
      // 不许编造任何昵称
      expect(find.textContaining('a83c54f9'), findsNothing);
    });

    testWidgets('有资料：昵称/主邮箱/其他邮箱/访客账号都如实显示', (tester) async {
      await pump(tester, {
        'id': 'u-1',
        'email': 'main@example.com',
        'emails': ['alt@example.com'],
        'nickName': 'Demo_user',
        'isGuest': true,
      });
      expect(find.text('Demo_user'), findsOneWidget);
      expect(find.text('main@example.com'), findsOneWidget);
      expect(find.text('alt@example.com'), findsOneWidget);
      expect(find.text('访客账号'), findsOneWidget);
      expect(
        find.byKey(const Key('personal-profile-guest-hint')),
        findsOneWidget,
      );
      // 有值时不再出现占位
      expect(find.text('未设置'), findsNothing);
      expect(find.text('未绑定邮箱'), findsNothing);
    });

    testWidgets('API 缺失（不在能力表）⇒ 错误态 + 重试，不崩', (tester) async {
      await pump(
        tester,
        Map<String, dynamic>.from(_realEmptyReply),
        table: const {
          'SYNO.API.Info': {
            'path': 'query.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
        },
      );
      expect(find.byKey(const Key('personal-profile-error')), findsOneWidget);
      expect(find.text('资料加载失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });
  });
}
