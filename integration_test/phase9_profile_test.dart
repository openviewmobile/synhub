// Phase 9 真机验收：个人资料编辑（`SYNO.Chat.User / set` v1 multipart）。
//
//   flutter test integration_test/phase9_profile_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=…
//
// 真机上做四件事：
//   ① 读回服务端设置：`readonly_profile` / `force_ad_fullname`（本机是否只读）
//   ② 改昵称 → `User/set`（multipart）→ 用 `User/get` 回读确认服务端真的变了
//   ③ 传头像（本地生成一张 64×64 PNG）→ 回读 `avatar_version` 是否增长
//   ④ 复原昵称（不留垃圾数据）；简介/邮箱同理
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/core/media/image_prepare.dart';
import 'package:synhub/src/core/settings/server_settings.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/user_dto.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';
import 'package:synhub/src/features/settings/profile_edit_page.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');

String _marker(String kind) =>
    'flt-p9pf-$kind-${DateTime.now().millisecondsSinceEpoch % 1000000}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 9 真机：个人资料编辑', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(
        account: _account, password: _password, session: 'Chat');
    final chat = ChatApi(conn.api);

    final container = ProviderContainer();
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });

    // ---------- ① 服务端设置 ----------
    final settings = await chat.fetchServerSettings();
    debugPrint('[p9pf] ① readonly_profile=${settings.readonlyProfile} '
        'force_ad_fullname=${settings.forceAdFullname} '
        'User v3=${chat.supports('SYNO.Chat.User', 3)}');
    expect(settings.readonlyProfile, isA<List<String>>());

    // 原始资料（结束时要还原）
    final before = await chat.myUser();
    expect(before, isNotNull);
    final me = before!;
    debugPrint('[p9pf] 原始资料：nickname="${me.nickname}" '
        'email="${me.email}" desc="${me.description}" '
        'avatar_version=${me.avatarVersion}');

    // ---------- ② 改昵称 + 简介 ----------
    final newNick = _marker('nick');
    final newDesc = _marker('desc');
    final saved = await chat.setUserProfile(
      nickname: newNick,
      description: newDesc,
      email: me.email,
    );
    final savedDto = UserDto.fromJson(saved);
    debugPrint('[p9pf] ② set 返回：nickname="${savedDto.nickname}" '
        'desc="${savedDto.description}"');
    expect(savedDto.nickname, newNick, reason: '服务端应当原样存下新昵称');

    // 回读确认（不是只看返回值）
    final afterNick = await chat.myUser();
    debugPrint('[p9pf] ② User/get 回读：nickname="${afterNick?.nickname}" '
        'desc="${afterNick?.description}"');
    expect(afterNick?.nickname, newNick);
    expect(afterNick?.description, newDesc);

    // ---------- ③ 传头像（只在原本没头像时做，免得覆盖已有头像） ----------
    // 头像版本号重新读一次：它可能刚被上一次测试改过（本地快照会不准）
    final baseline = await chat.myUser();
    final dir = Directory.systemTemp.createTempSync('flt_p9pf');
    var avatarDto = savedDto;
    if ((baseline?.avatarVersion ?? 0) == 0) {
      final png = File('${dir.path}/avatar.png');
      png.writeAsBytesSync(img.encodePng(img.Image(width: 64, height: 64)));
      final squared = await cropAvatarSquare(png.path);
      debugPrint('[p9pf] ③ 头像裁好：${squared.split('/').last} '
          '${File(squared).lengthSync()} 字节');
      avatarDto = UserDto.fromJson(await chat.setUserProfile(
        nickname: newNick,
        description: newDesc,
        email: me.email,
        avatarPath: squared,
      ));
      debugPrint('[p9pf] ③ 上传头像后 avatar_version=${avatarDto.avatarVersion} '
          '(上传前 ${me.avatarVersion})');
      expect(avatarDto.avatarVersion, greaterThan(me.avatarVersion),
          reason: '传了头像，版本号应该往前走');
      // 回读一次，确认服务端真的存了
      final reread = await chat.myUser();
      expect(reread?.avatarVersion, avatarDto.avatarVersion);
    } else {
      debugPrint('[p9pf] ③ 账号本来就有头像（v=${me.avatarVersion}），跳过上传');
    }

    // ---------- ④ 页面渲染（只读字段要按服务端设置禁用） ----------
    await container.read(chatStoreProvider).upsertUsers([avatarDto]);
    container.read(serverSettingsProvider.notifier).apply(settings);
    await container.read(chatSessionControllerProvider.notifier).start(conn);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ProfileEditPage()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('个人资料'), findsOneWidget);
    final nickField =
        tester.widget<TextField>(find.widgetWithText(TextField, '昵称'));
    expect(nickField.enabled, !settings.readonlyProfile.contains('nickname'),
        reason: 'readonly_profile 命中昵称时输入框要禁用');
    debugPrint('[p9pf] ④ 资料页渲染 ✓（昵称框 enabled=${nickField.enabled}）');

    // ---------- ⑤ 还原（有上传过头像就删回原样） ----------
    final uploaded =
        (baseline?.avatarVersion ?? 0) == 0 && avatarDto.avatarVersion != 0;
    if (uploaded) {
      await chat.deleteProfilePhoto();
      final user = await chat.setUserProfile(
        nickname: me.nickname,
        description: me.description,
        email: me.email,
        removeAvatar: true,
      );
      debugPrint('[p9pf] ⑤ 移除头像 → avatar_version='
          '${UserDto.fromJson(user).avatarVersion}');
    } else {
      await chat.setUserProfile(
        nickname: me.nickname,
        description: me.description,
        email: me.email,
      );
    }
    final restored = await chat.myUser();
    debugPrint('[p9pf] ⑤ 已还原：nickname="${restored?.nickname}" '
        'desc="${restored?.description}" '
        'avatar_version=${restored?.avatarVersion}');
    expect(restored?.nickname, me.nickname);
    expect(restored?.description, me.description);
    expect(restored?.avatarVersion, baseline?.avatarVersion,
        reason: '头像版本要回到上传前（新增的删掉，原有的不动）');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    debugPrint('[p9pf] 完成 ✓');
  });
}
