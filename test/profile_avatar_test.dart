// 个人资料 / 头像链路（`SYNO.Chat.User / set` + `SYNO.Chat.User.Avatar / get`）。
//
// 触发这条测试的真机 bug：「改了头像，App 里没生效，重启还是旧头像」。
//
// 官方事实来源（两处交叉验证，反编译在 `/tmp/syno_apk/jadx_out`，
// 服务端包在 `/tmp/chattar` 即 `Chat-x86_64-2.4.7-22203`）：
//   * `AccountManager#setUser(String,String,String,File)` multipart 字段是**裸值**；
//   * `AccountManager#removeAvatar` 的 form 字段是 `gson.toJson`（**带引号**）；
//   * `StreamService.getAvatar(path, api, method, version, user_id, type, v)`
//     = form POST `SYNO.Chat.User.Avatar / get` v1，`v` = `avatar_version`；
//   * `AvatarLoader` 缓存键 = `userId:appId:avatarVersion:type`；
//   * `DatabaseHelper.setUser` 是直接 UPDATE（**不合并字段**）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:synhub/src/core/ui/hud_widgets.dart';
import 'package:synhub/src/data/dto/user_dto.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/chat/user_avatar.dart';
import 'package:synhub/src/features/settings/profile_edit_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

/// 1×1 PNG（能通过 magic bytes + 真解码）
Uint8List tinyPng([int r = 255, int g = 0, int b = 0]) {
  final im = img.Image(width: 1, height: 1);
  im.setPixelRgba(0, 0, r, g, b, 255);
  return Uint8List.fromList(img.encodePng(im));
}

void main() {
  setUp(clearUserAvatarCache);
  tearDown(clearUserAvatarCache);

  group('官方形态对照：User/set 两条路', () {
    test('multipart 分支字段是裸值（不是 gson.toJson 的带引号串）', () async {
      final h = await bootChat();
      await h.apiForTest.setUserProfile(
        nickname: '新昵称',
        description: '新简介',
        email: 'me@example.com',
      );
      final call = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.User' && c['method'] == 'set',
      );
      expect(call['nickname'], '新昵称');
      expect(call['description'], '新简介');
      expect(call['email'], 'me@example.com');
      // 官方 `AccountManager#setUser` 没有 `gson.toJson`
      expect(call['nickname'], isNot(equals(jsonEncode('新昵称'))));
      expect('${call['nickname']}', isNot(contains('"')));
      expect('${call['email']}', isNot(contains('"')));
    });

    test('移除头像分支字段带引号 + remove_avatar=true', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.User.set': {
            'data': {'user_id': 14, 'username': 'me', 'type': 'human'},
          },
        },
      );
      await h.apiForTest.setUserProfile(
        nickname: 'n',
        description: 'd',
        email: 'e@x.com',
        removeAvatar: true,
      );
      final set = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.User' && c['method'] == 'set',
      );
      expect(set['nickname'], jsonEncode('n'));
      expect(set['email'], jsonEncode('e@x.com'));
      expect('${set['remove_avatar']}', 'true');
    });
  });

  group('官方形态对照：User.Avatar / get 取图', () {
    test('请求形状：POST form，user_id/type/v，version=1', () async {
      final h = await bootChat();
      h.transport.bytesByUrl['SYNO.Chat.User.Avatar'] = tinyPng();
      await h.apiForTest.fetchUserAvatar(
        userId: 14,
        version: 987654,
        type: 'L',
      );
      final sent = h.transport.postDownloads.single;
      expect(sent, contains('api=SYNO.Chat.User.Avatar'));
      expect(sent, contains('method=get'));
      expect(sent, contains('version=1'));
      expect(sent, contains('user_id=14'));
      expect(sent, contains('type=L'));
      expect(sent, contains('v=987654'));
    });

    test('looksLikeImage：PNG/JPEG/GIF/WebP 通过，HTML/JSON 拒绝', () {
      expect(looksLikeImage(tinyPng()), isTrue);
      expect(looksLikeImage([0xFF, 0xD8, 0xFF, 0x00]), isTrue);
      expect(looksLikeImage([0x47, 0x49, 0x46, 0x38, 0x39]), isTrue);
      expect(looksLikeImage(utf8.encode('<html>105</html>')), isFalse);
      expect(looksLikeImage(utf8.encode('{"success":false}')), isFalse);
      expect(looksLikeImage(const []), isFalse);
    });

    test('尺寸 → 官方 type 串 S/M/L', () {
      expect(userAvatarTypeForSize(32), 'S');
      expect(userAvatarTypeForSize(36), 'S');
      expect(userAvatarTypeForSize(44), 'M');
      expect(userAvatarTypeForSize(52), 'M');
      expect(userAvatarTypeForSize(80), 'L');
    });
  });

  group('缓存键：换头像必须让 URL/缓存键变', () {
    test('cacheKey 带 avatar_version：版本变了键就变', () {
      const before = UserAvatarKey(userId: 14, version: 111111, type: 'M');
      const after = UserAvatarKey(userId: 14, version: 222222, type: 'M');
      expect(before.cacheKey, '14:0:111111:M');
      expect(after.cacheKey, '14:0:222222:M');
      expect(before.cacheKey, isNot(after.cacheKey));
      // 同版本 → 同键（缓存命中）；type 不同 → 不同键
      expect(
        before,
        const UserAvatarKey(userId: 14, version: 111111, type: 'M'),
      );
      expect(
        before.cacheKey,
        isNot(
          const UserAvatarKey(userId: 14, version: 111111, type: 'L').cacheKey,
        ),
      );
      // appId 也进键（机器人头像按 app 区分）
      expect(
        before.cacheKey,
        isNot(
          const UserAvatarKey(
            userId: 14,
            appId: 7,
            version: 111111,
            type: 'M',
          ).cacheKey,
        ),
      );
    });

    test('0 版本是"没有头像"：不请求、直接回退', () async {
      final h = await bootChat();
      h.transport.bytesByUrl['SYNO.Chat.User.Avatar'] = tinyPng();
      final image = await h.container.read(
        userAvatarImageProvider(
          const UserAvatarKey(userId: 14, version: 0, type: 'S'),
        ).future,
      );
      expect(image, isNull);
      expect(h.transport.postDownloads, isEmpty, reason: '不该白发请求');
    });

    test('服务端回非图片（错误页）→ 回退，不抛异常', () async {
      final h = await bootChat();
      h.transport.bytesByUrl['SYNO.Chat.User.Avatar'] = utf8.encode(
        '<html>error</html>',
      );
      final image = await h.container.read(
        userAvatarImageProvider(
          const UserAvatarKey(userId: 14, version: 5, type: 'S'),
        ).future,
      );
      expect(image, isNull);
      expect(h.transport.postDownloads, hasLength(1));
    });

    test('同版本命中缓存（只请求一次）；换版本 → 回源且键变', () async {
      final h = await bootChat();
      h.transport.bytesByUrl['SYNO.Chat.User.Avatar'] = tinyPng();
      final k1 = const UserAvatarKey(userId: 14, version: 111, type: 'S');
      final a = await h.container.read(userAvatarImageProvider(k1).future);
      final b = await h.container.read(userAvatarImageProvider(k1).future);
      expect(a, isA<MemoryImage>());
      expect(b, isA<MemoryImage>());
      expect(h.transport.postDownloads, hasLength(1), reason: '同键走缓存');

      // 换头像：服务端换了一张蓝图 + 新 avatar_version
      h.transport.bytesByUrl['SYNO.Chat.User.Avatar'] = tinyPng(0, 0, 255);
      final k2 = const UserAvatarKey(userId: 14, version: 222, type: 'S');
      final c = await h.container.read(userAvatarImageProvider(k2).future);
      expect(c, isA<MemoryImage>());
      expect(h.transport.postDownloads, hasLength(2), reason: '换版本要回源');
      expect(
        (a! as MemoryImage).bytes,
        isNot((c! as MemoryImage).bytes),
        reason: '新版本必须拿到新图',
      );
    });

    test('evictUserAvatars 只清该用户，重取会再发请求', () async {
      final h = await bootChat();
      h.transport.bytesByUrl['SYNO.Chat.User.Avatar'] = tinyPng();
      await h.container.read(
        userAvatarImageProvider(
          const UserAvatarKey(userId: 14, version: 1, type: 'S'),
        ).future,
      );
      await h.container.read(
        userAvatarImageProvider(
          const UserAvatarKey(userId: 99, version: 1, type: 'S'),
        ).future,
      );
      expect(debugUserAvatarCacheKeys(), contains('14:0:1:S'));
      expect(debugUserAvatarCacheKeys(), contains('99:0:1:S'));

      final removed = evictUserAvatars(14);
      expect(removed, contains('14:0:1:S'));
      expect(debugUserAvatarCacheKeys(), isNot(contains('14:0:1:S')));
      expect(debugUserAvatarCacheKeys(), contains('99:0:1:S'));
    });
  });

  group('本地写回：User/set 响应是权威覆盖（对齐 DatabaseHelper.setUser）', () {
    test('默认合并会吃掉 avatar_version=0；权威写回把它落成 0', () async {
      final h = await bootChat();
      final store = h.container.read(chatStoreProvider);

      // 先有一张头像
      await store.upsertUsers([
        UserDto.fromJson(const {
          'user_id': 14,
          'username': 'me',
          'type': 'human',
          'avatar_version': 1789619312,
        }),
      ]);
      var me = (await store.allUsers()).firstWhere((u) => u.userId == 14);
      expect(me.avatarVersion, 1789619312);

      // 增量广播（合并语义）：0 被当成"没带"，保留旧值 —— 这是广播需要的
      await store.upsertUsers([
        UserDto.fromJson(const {
          'user_id': 14,
          'username': 'me',
          'type': 'human',
          'avatar_version': 0,
        }),
      ]);
      me = (await store.allUsers()).firstWhere((u) => u.userId == 14);
      expect(me.avatarVersion, 1789619312, reason: '广播合并语义不能变');

      // `User/set` 响应（权威）：移除头像必须真的落成 0
      await store.upsertUsers([
        UserDto.fromJson(const {
          'user_id': 14,
          'username': 'me',
          'type': 'human',
          'avatar_version': 0,
        }),
      ], authoritative: true);
      me = (await store.allUsers()).firstWhere((u) => u.userId == 14);
      expect(me.avatarVersion, 0, reason: '否则本地永远显示旧头像');
    });
  });

  group('资料页：显示服务端头像 + 保存后本地/缓存同步', () {
    Widget wrap(ProviderContainer c) => UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: ProfileEditPage()),
    );

    testWidgets('进入页面就按 avatar_version 取服务端头像（type=L）', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.User.list': {
            'users': [
              {
                'user_id': 14,
                'username': 'me',
                'nickname': '我',
                'type': 'human',
                'avatar_version': 555,
                'user_props': {'avatar_color': '#94bf13'},
              },
            ],
          },
        },
      );
      h.transport.bytesByUrl['SYNO.Chat.User.Avatar'] = tinyPng();

      await tester.pumpWidget(wrap(h.container));
      await tester.pumpAndSettle();

      expect(h.transport.postDownloads, isNotEmpty);
      final sent = h.transport.postDownloads.last;
      expect(sent, contains('user_id=14'));
      expect(sent, contains('v=555'));
      expect(sent, contains('type=L'));

      final ring = tester.widget<RingAvatar>(find.byType(RingAvatar));
      expect(ring.image, isA<MemoryImage>(), reason: '页面要显示真头像');
    });

    testWidgets('avatar_version=0 时退回首字母，不发取图请求', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.User.list': {
            'users': [
              {
                'user_id': 14,
                'username': 'me',
                'nickname': '我',
                'type': 'human',
                'avatar_version': 0,
              },
            ],
          },
        },
      );
      final before = h.transport.postDownloads.length;
      await tester.pumpWidget(wrap(h.container));
      await tester.pumpAndSettle();

      expect(h.transport.postDownloads.length, before);
      final ring = tester.widget<RingAvatar>(find.byType(RingAvatar));
      expect(ring.image, isNull);
      expect(ring.label, '我');
    });

    testWidgets('移除头像保存后：本地 avatar_version 归 0 + 清头像缓存', (tester) async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.User.list': {
            'users': [
              {
                'user_id': 14,
                'username': 'me',
                'nickname': '我',
                'type': 'human',
                'avatar_version': 424242,
              },
            ],
          },
          'SYNO.Personal.Profile.Photo.delete': const {},
          'SYNO.Chat.User.set': {
            'data': {
              'user_id': 14,
              'username': 'me',
              'nickname': '我',
              'type': 'human',
              'avatar_version': 0,
            },
          },
        },
      );
      h.transport.bytesByUrl['SYNO.Chat.User.Avatar'] = tinyPng();

      await tester.pumpWidget(wrap(h.container));
      await tester.pumpAndSettle();
      // 预热缓存（模拟之前已经显示过旧头像）
      final warm = await h.container.read(
        userAvatarImageProvider(
          const UserAvatarKey(userId: 14, version: 424242, type: 'L'),
        ).future,
      );
      expect(warm, isA<MemoryImage>());

      await tester.tap(find.text('移除头像'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '保存'));
      await tester.pumpAndSettle();

      final me = (await h.container.read(chatStoreProvider).allUsers())
          .firstWhere((u) => u.userId == 14);
      expect(me.avatarVersion, 0);
      expect(debugUserAvatarCacheKeys(), isNot(contains('14:0:424242:L')));
    });
  });
}
