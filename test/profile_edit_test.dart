// 个人资料编辑（Phase 9）：`SYNO.Chat.User / set` v1 multipart + 校验 + 只读字段。
//
// 反编译依据：
//   * `AccountManager#setUser` → multipart，查询串 `api/method/version=1`，
//     body `nickname` / `description` / `email`（+ 可选 `avatar`，文件名 `blob`）
//   * `ProfileEditFragment` → 昵称/邮箱/简介三个输入框，`readonly_profile`
//     命中的字段要 setEnabled(false)；保存按钮"有改动才可点"
//   * `ChatUtil.validateNickname` / `validateEmail` / `isSupportExemptSpecialCharacter`
//     （`User` API 支持 v3 → 免特殊字符 + 上限 255，否则 32）
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:synhub/src/core/media/image_prepare.dart';
import 'package:synhub/src/core/settings/server_settings.dart';
import 'package:synhub/src/data/dto/server_settings_dto.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/settings/profile_edit_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

void main() {
  group('校验规则（ChatUtil）', () {
    test('昵称：非豁免模式下不许特殊字符', () {
      expect(isValidNickname('正常名字', exemptSpecialChars: false), isTrue);
      for (final bad in ['a!b', 'a@b', 'a<b', 'a#b', 'a/b', 'a:b', '名字,逗号']) {
        expect(
          isValidNickname(bad, exemptSpecialChars: false),
          isFalse,
          reason: '$bad 里有非法字符',
        );
      }
      // 以下字符原版是**允许**的：- _ . 空格 中文 emoji
      expect(
        isValidNickname('a-b_c.d 名字 🎉', exemptSpecialChars: false),
        isTrue,
      );
    });

    test('昵称：豁免模式（User API ≥ v3）随便写', () {
      expect(isValidNickname('a!b@c', exemptSpecialChars: true), isTrue);
    });

    test('昵称长度上限 32 / 255', () {
      expect(nicknameMaxLength(exemptSpecialChars: false), 32);
      expect(nicknameMaxLength(exemptSpecialChars: true), 255);
    });

    test('邮箱：空串放行，非空要匹配原版正则', () {
      expect(isValidEmail(''), isTrue);
      expect(isValidEmail('a@b.com'), isTrue);
      expect(isValidEmail('first.last+tag@sub.domain.co'), isTrue);
      expect(isValidEmail('a@b'), isFalse);
      expect(isValidEmail('a b@c.com'), isFalse);
      expect(isValidEmail('a@@b.com'), isFalse);
    });

    test('readonly_profile 命中即只读', () {
      const s = ServerSettings(readonlyProfile: ['nickname', 'desc']);
      expect(isProfileFieldReadonly('nickname', s), isTrue);
      expect(isProfileFieldReadonly('desc', s), isTrue);
      expect(isProfileFieldReadonly('email', s), isFalse);
    });

    test('readonly_profile 从服务端载荷解析', () {
      final s = ServerSettings.fromJson(const {
        'readonly_profile': ['nickname', 'email'],
        'force_ad_fullname': true,
      });
      expect(s.readonlyProfile, ['nickname', 'email']);
      expect(s.forceAdFullname, isTrue);
    });
  });

  group('User/set 请求形状', () {
    test('不带头像：multipart 但只有三个文本字段', () async {
      final h = await bootChat();
      await h.apiForTest.setUserProfile(
        nickname: '新昵称',
        description: '新简介',
        email: 'me@example.com',
      );
      final call = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.User' && c['method'] == 'set',
      );
      expect('${call['version']}', '1');
      expect(call['nickname'], '新昵称');
      expect(call['description'], '新简介');
      expect(call['email'], 'me@example.com');
      expect(call['file_field'], isNull, reason: '没换头像就不该带文件字段');
    });

    test('带头像：字段名 avatar、文件名 blob、字节原样', () async {
      final h = await bootChat();
      final tmp = File('${Directory.systemTemp.path}/flt_avatar_upload.bin');
      tmp.writeAsBytesSync(List<int>.generate(64, (i) => i));
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync();
      });
      await apiCall(h, tmp.path);
      final call = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.User' && c['method'] == 'set',
      );
      expect(call['file_field'], 'avatar');
      expect(call['file_name'], 'blob');
      expect(call['file_bytes'], isA<List<int>>());
      expect((call['file_bytes'] as List).length, 64);
    });

    test('移除头像：先删头像，再走 form 的 remove_avatar=true', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Personal.Profile.Photo.delete': const {},
          'SYNO.Chat.User.set': {
            'data': {'user_id': 14, 'username': 'me', 'type': 'human'},
          },
        },
      );
      await h.apiForTest.deleteProfilePhoto();
      await h.apiForTest.setUserProfile(
        nickname: 'n',
        description: 'd',
        email: 'e@x.com',
        removeAvatar: true,
      );
      final del = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Personal.Profile.Photo',
      );
      expect(del['method'], 'delete');
      final set = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.User' && c['method'] == 'set',
      );
      expect('${set['remove_avatar']}', 'true');
      // form 这条路原版用 gson.toJson → 值是带引号的 JSON 串
      expect(set['nickname'], '"n"');
      expect(set['email'], '"e@x.com"');
      expect(set['file_field'], isNull);
    });

    test('保存成功后把服务端返回的 user 写回本地库', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.User.set': {
            'data': {
              'user_id': 14,
              'username': 'me',
              'nickname': '服务端新昵称',
              'type': 'human',
              'user_props': {'email': 'new@example.com', 'description': '改了'},
            },
          },
        },
      );
      final user = await h.apiForTest.setUserProfile(nickname: '服务端新昵称');
      expect(user['nickname'], '服务端新昵称');
      expect(user['user_props']['email'], 'new@example.com');
    });

    test('服务端报错 → 抛异常，不静默', () async {
      final h = await bootChat();
      h.transport.failures['SYNO.Chat.User.set'] = 105;
      await expectLater(
        h.apiForTest.setUserProfile(nickname: 'x'),
        throwsA(isA<Object>()),
      );
    });
  });

  group('资料编辑页', () {
    Widget wrap(ProviderContainer c) => UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: ProfileEditPage()),
    );

    testWidgets('预填当前资料；没改动时保存不可点', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.User.list': {
            'users': [
              {
                'user_id': 14,
                'username': 'demo_user',
                'nickname': '老昵称',
                'type': 'human',
                'user_props': {
                  'email': 'old@example.com',
                  'description': '老简介',
                },
              },
            ],
          },
        },
      );
      await tester.pumpWidget(wrap(h.container));
      await tester.pumpAndSettle();

      expect(find.text('个人资料'), findsOneWidget);
      expect(find.widgetWithText(TextField, '老昵称'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'old@example.com'), findsOneWidget);
      final save = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '保存'),
      );
      expect(save.onPressed, isNull, reason: '没有改动不该能保存');
    });

    testWidgets('改了昵称 → 能保存 → 发请求并更新本地', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.User.list': {
            'users': [
              {
                'user_id': 14,
                'username': 'me',
                'nickname': '老昵称',
                'type': 'human',
              },
            ],
          },
          'SYNO.Chat.User.set': {
            'data': {
              'user_id': 14,
              'username': 'me',
              'nickname': '新昵称',
              'type': 'human',
            },
          },
        },
      );
      await tester.pumpWidget(wrap(h.container));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, '老昵称'), '新昵称');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '保存'));
      await tester.pumpAndSettle();

      final call = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.User' && c['method'] == 'set',
      );
      expect(call['nickname'], '新昵称');
      expect(find.text('已保存'), findsOneWidget);
      final users = await h.container.read(chatStoreProvider).allUsers();
      expect(users.firstWhere((u) => u.userId == 14).nickname, '新昵称');
    });

    testWidgets('邮箱非法 → 不发请求，提示格式不对', (tester) async {
      final h = await bootChat();
      await tester.pumpWidget(wrap(h.container));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '邮箱'),
        'not-an-email',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '保存'));
      await tester.pumpAndSettle();

      expect(find.text('邮箱格式不对'), findsOneWidget);
      expect(
        h.transport.calls.where(
          (c) => c['method'] == 'set' && c['api'] == 'SYNO.Chat.User',
        ),
        isEmpty,
      );
      // 也不该有任何别的 User/set 发出去
      expect(
        h.transport.calls.where(
          (c) => c['api'] == 'SYNO.Chat.User' && c['method'] == 'set',
        ),
        isEmpty,
      );
    });

    testWidgets('readonly_profile 命中 → 输入框禁用 + 提示', (tester) async {
      final h = await bootChat();
      // 让页面能看到服务端设置
      await h.container
          .read(serverSettingsProvider.notifier)
          .apply(
            ServerSettings.fromJson(const {
              'readonly_profile': ['nickname', 'email'],
            }),
          );
      await tester.pumpWidget(wrap(h.container));
      await tester.pumpAndSettle();

      final nickname = tester.widget<TextField>(
        find.widgetWithText(TextField, '昵称'),
      );
      final email = tester.widget<TextField>(
        find.widgetWithText(TextField, '邮箱'),
      );
      final desc = tester.widget<TextField>(
        find.widgetWithText(TextField, '简介'),
      );
      expect(nickname.enabled, isFalse, reason: '昵称被管理员设为只读');
      expect(email.enabled, isFalse);
      expect(desc.enabled, isTrue);
      expect(find.text('管理员已设为只读'), findsNWidgets(2));
    });

    testWidgets('点「移除头像」再保存 → 走 delete + remove_avatar', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.User.list': {
            'users': [
              {
                'user_id': 14,
                'username': 'me',
                'nickname': '老昵称',
                'type': 'human',
              },
            ],
          },
          'SYNO.Personal.Profile.Photo.delete': const {},
          'SYNO.Chat.User.set': {
            'data': {'user_id': 14, 'username': 'me', 'type': 'human'},
          },
        },
      );
      await tester.pumpWidget(wrap(h.container));
      await tester.pumpAndSettle();

      await tester.tap(find.text('移除头像'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '保存'));
      await tester.pumpAndSettle();

      expect(
        h.transport.calls.where(
          (c) =>
              c['api'] == 'SYNO.Personal.Profile.Photo' &&
              c['method'] == 'delete',
        ),
        isNotEmpty,
        reason: '要先删服务端头像',
      );
      final set = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.User' && c['method'] == 'set',
      );
      expect('${set['remove_avatar']}', 'true');
    });

    testWidgets('昵称非法字符 → 提示并不发请求（非豁免模式）', (tester) async {
      // 老服务器：`SYNO.Chat.User` 只到 v2 → 非豁免模式（特殊字符受限、上限 32）
      final h = await bootChat(
        apiTable: {
          ...FakeTransport.table,
          'SYNO.Chat.User': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 2,
          },
        },
      );
      // `_loadServerSettings()` 是 fire-and-forget：用真异步时间等它落地
      // （widget 测试里 `Future.delayed` 走的是假时钟，必须用 runAsync）
      await tester.runAsync(() async {
        for (var i = 0; i < 50; i++) {
          if (!h.container.read(chatSessionControllerProvider).supportsUserV3) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      expect(
        h.container.read(chatSessionControllerProvider).supportsUserV3,
        isFalse,
        reason: 'User v2 → 非豁免模式',
      );
      await tester.pumpWidget(wrap(h.container));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, '昵称'), '非法!昵称');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '保存'));
      await tester.pumpAndSettle();

      expect(find.text('昵称里有不允许的字符'), findsOneWidget);
      expect(
        h.transport.calls.where(
          (c) => c['method'] == 'set' && c['api'] == 'SYNO.Chat.User',
        ),
        isEmpty,
      );
    });
  });

  group('头像裁方形', () {
    test('100×50 的图 → 50×50 的 jpg', () async {
      final dir = Directory.systemTemp.createTempSync('flt_avatar');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final src = File('${dir.path}/wide.png');
      src.writeAsBytesSync(img.encodePng(img.Image(width: 100, height: 50)));
      final out = await cropAvatarSquare(src.path);
      expect(out, isNot(src.path));
      final decoded = img.decodeImage(File(out).readAsBytesSync())!;
      expect(decoded.width, 50);
      expect(decoded.height, 50);
    });

    test('超大图缩到 512', () async {
      final dir = Directory.systemTemp.createTempSync('flt_avatar_big');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final src = File('${dir.path}/big.png');
      src.writeAsBytesSync(img.encodePng(img.Image(width: 900, height: 700)));
      final out = await cropAvatarSquare(src.path);
      final decoded = img.decodeImage(File(out).readAsBytesSync())!;
      expect(decoded.width, 512);
      expect(decoded.height, 512);
    });
  });
}

/// 传头像的调用（单独抽出来方便读）
Future<void> apiCall(ChatHarness h, String avatarPath) =>
    h.apiForTest.setUserProfile(
      nickname: 'n',
      description: 'd',
      email: 'e@x.com',
      avatarPath: avatarPath,
    );
