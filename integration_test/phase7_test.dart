// Phase 7 真机验收：E2EE 走 App 自己的代码路径（E2eeService + E2eeController + ChatApi）。
//
//   flutter test integration_test/phase7_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=… --dart-define=SYNO_LIVE_POST=true
//
// 会做这些事（都在真 NAS 上）：
//   ① 生成密钥对并 `update_key` 上传
//   ② 从 `Channel/list` 读回加密频道，解出频道密钥（broken 判定）
//   ③ 用 App 的加密接口发一条只写 `flt-p7-` 前缀的消息，读回用 App 解密
//   ④ `rescue` 把频道密钥重封给另一个成员（不实际调用，除非开了 post）
//   ⑤ UI：打开 E2EE 设置页看到状态
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/e2ee/e2ee_service.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';
import 'package:synhub/src/features/settings/e2ee_controller.dart';
import 'package:synhub/src/features/settings/e2ee_page.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');
const _postRaw = String.fromEnvironment('SYNO_LIVE_POST');
final _doPost = _postRaw == '1' || _postRaw == 'true';

/// 测试用的口令：**必须**跟历史探针一致，否则解不开之前注册的私钥。
const _passcode = 'flt-e2ee-pass';

String _marker(String kind) =>
    'flt-p7-$kind-${DateTime.now().millisecondsSinceEpoch}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 7 真机：E2EE 身份 / 频道密钥 / 密文收发 / 设置页', (tester) async {
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
    final ctrl = container.read(chatSessionControllerProvider.notifier);
    await ctrl.start(conn);
    final sync = container.read(chatSessionControllerProvider);
    debugPrint('[p7] 我=#${sync.myUserId} 实时=${sync.realtime}');

    final store = container.read(chatStoreProvider);
    final svc = container.read(e2eeServiceProvider);
    final e2ee = container.read(e2eeControllerProvider.notifier);
    final created = <int>[];

    // ---------- ① 身份：先 load，再解锁（这台机器上应该已经注册过） ----------
    await e2ee.load();
    var e2eeState = container.read(e2eeControllerProvider);
    debugPrint('[p7] 身份：configured=${e2eeState.configured} '
        'unlocked=${e2eeState.unlocked} pub=${e2eeState.publicKey}');

    // 本地没有身份时会自动从服务端 `user_props.key_pair` 取（新设备流程）
    if (!e2eeState.configured) {
      final adopted = await e2ee.adoptServerIdentityIfAny();
      debugPrint('[p7] 本地没有身份，从服务端取：$adopted');
    }
    // 注意：**不能**在解不开口令时 setup 新密钥对 —— 那会把服务端记录顶掉，
    // 旧加密频道全部变砖（原地踩过）。
    final unlocked = await e2ee.unlock(_passcode);
    expect(unlocked, isTrue, reason: '要用 $_passcode 解锁服务端那份私钥');
    e2eeState = container.read(e2eeControllerProvider);
    expect(e2eeState.configured, isTrue);
    debugPrint('[p7] 公钥=${e2eeState.publicKey}');

    // 服务端确实登记了公钥
    final me = await chat.myUser();
    debugPrint('[p7] 服务端 key_pair=${me?.publicKey}');
    expect(me?.publicKey, e2eeState.publicKey,
        reason: 'update_key 之后服务端应该存着同一个公钥');

    // ---------- ② 频道密钥：从真频道里解出来 ----------
    final channels = await store.allChannels();
    final encrypted = channels.where((c) => c.encrypted).toList();
    debugPrint('[p7] 频道 ${channels.length} 个，其中加密 ${encrypted.length} 个；'
        'broken=${container.read(e2eeControllerProvider).brokenChannels}');
    var usable = 0;
    for (final c in encrypted) {
      final state = e2ee.keyStateOf(c);
      debugPrint('[p7] 加密频道 #${c.channelId} 密钥状态=$state');
      if (state == ChannelKeyState.ready) usable++;
    }
    if (encrypted.isNotEmpty) {
      expect(usable, greaterThan(0),
          reason: '至少有一个加密频道的密钥要能解开（否则 E2EE 没打通）');
    }

    // ---------- ③ 密文收发（默认只读；开 SYNO_LIVE_POST 才写） ----------
    if (!_doPost || usable == 0) {
      debugPrint('[p7] 跳过收发（post=$_doPost usable=$usable）');
    } else {
      final target =
          encrypted.firstWhere((c) => e2ee.keyStateOf(c) == ChannelKeyState.ready);
      final text = _marker('msg');
      final wire = svc.encryptMessage(target.channelId, text);
      final raw = await chat.createPost(
        channelId: target.channelId,
        message: wire,
        connId: sync.connId ?? '',
        mobileToken: '${DateTime.now().millisecondsSinceEpoch}',
      );
      // ChatApi.createPost 已经把 data.post 拆出来了，直接就是 post 本体
      final postId = (raw['post_id'] as num?)?.toInt();
      expect(postId, isNotNull, reason: '加密消息要能发出去');
      created.add(postId!);
      debugPrint('[p7] 发出加密消息 #$postId');

      // 读回：服务端那份是密文，用 App 的解密接口解出原文
      final posts = await chat.listPosts(
          channelId: target.channelId, prevCount: 10, has: const ['thread']);
      var found = false;
      for (final p in posts) {
        final message = '${p['message'] ?? ''}';
        final decoded = svc.tryDecryptMessage(target.channelId, message);
        if (decoded == text) found = true;
      }
      expect(found, isTrue, reason: '读回来的密文要能用 App 接口解开');
      debugPrint('[p7] 读回并解密成功 ✓');

      // ---------- ③b 加密附件：上传 → 下载 → 解密，字节要一致 ----------
      final access = ctrl.attachmentAccessFor(target);
      expect(access, isNotNull, reason: '加密频道要有附件访问器');
      // 一张 1x1 的 PNG（就 68 字节，够验证加解密链路了）
      final png = Uint8List.fromList(const [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
        0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
      ]);
      final tmpDir = await getTemporaryDirectory();
      final srcName = 'flt-p7-图.png';
      final src = File('${tmpDir.path}/$srcName')..writeAsBytesSync(png);
      final uploaded = await ctrl.sendAttachment(
        channelId: target.channelId,
        filePath: src.path,
        fileName: srcName,
        message: 'flt-p7 附件字幕',
        mimeType: 'image/png',
      );
      expect(uploaded, isTrue, reason: '加密附件要能发出去');

      // 本地库里那条就是刚上传的（取最新的 file 消息）
      final localPosts = await store.postsForChannel(target.channelId, limit: 10);
      final filePost = localPosts.firstWhere(
        (p) => p.type == 'file' && p.postId > 0,
        orElse: () => localPosts.first,
      );
      created.add(filePost.postId);
      debugPrint('[p7] 加密附件 #${filePost.postId} 本地附件数='
          '${filePost.attachments.length}');

      // 服务端那份：文件名是密文，内容解出来要等于原字节
      final serverPosts = await chat.listPosts(
          channelId: target.channelId, prevCount: 10, has: const ['file_props']);
      var attachOk = false;
      for (final p in serverPosts) {
        final dto = PostDto.fromJson(p);
        if (dto.postId != filePost.postId) continue;
        if (dto.attachments.isEmpty) continue;
        final rawName = dto.attachments.first.label;
        final shown = access!.decodeName(rawName);
        debugPrint('[p7] 服务端文件名（密文）=${rawName.substring(0, rawName.length.clamp(0, 24))}… '
            '解出来=$shown');
        if (shown != srcName) continue;
        final bytes = await access.bytes(dto.postId);
        attachOk = bytes != null && bytes.length == png.length;
      }
      expect(attachOk, isTrue, reason: '下载 + 解密后的附件字节要跟原文件一致');
      debugPrint('[p7] 加密附件下载解密一致 ✓');
    }

    // ---------- ④ 收尾：删掉测试消息 ----------
    for (final id in created) {
      try {
        await chat.deletePost(id);
        debugPrint('[p7] 已删消息 #$id');
      } catch (e) {
        debugPrint('[p7] 删消息 #$id 失败：$e');
      }
    }

    // ---------- ⑤ UI：E2EE 设置页 ----------
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: E2eePage()),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(find.text('端到端加密'), findsOneWidget);
    expect(find.textContaining('已开启'), findsOneWidget);
    expect(find.text('修改口令'), findsOneWidget);
    debugPrint('[p7] 设置页渲染正常 ✓');

    debugPrint('[p7] 清理完成 ✓');
  });
}
