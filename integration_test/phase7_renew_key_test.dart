// Phase 7 真机验收：真正「更换密钥对」（`RenewKeyPresenter` / `renew_key`）。
//
//   flutter test integration_test/phase7_renew_key_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=… --dart-define=SYNO_E2EE_PASSCODE=…
//
// ⚠️ **这条用例故意不真的把线上账号的密钥对换掉**：`update_key` 一旦上报，
// 服务端上我的公钥就变了、所有频道密钥副本都会改封给新公钥，如果中途失败，
// 真实账号的 E2EE 会处于"服务端新 / 本地旧"的危险状态（要靠 `User/list` 的
// key_pair 才救得回来）。写路径用的 `SYNO.Chat.User / update_key` v2 本身已经
// 在 `phase7_broken_test` 里真机验证过（7 字段形状一致）。
//
// 这里验的是**换密钥对里最危险的那半**：拿真服务端给的 `channel_key_enc` 做
// 重封，确认
//   ① 生成的是新密钥对，且新私钥仍然由同一个口令保护（换台设备也能解回来）；
//   ② 真频道 + 真归档的密钥都能用**旧**对解开，并用**新**公钥重封；
//   ③ 重封后的密文能用新私钥解出**同一把 32 字节频道密钥**，且仍是官方格式
//      （seal 的是 base64 文本，官方客户端拿新私钥也能读）；
//   ④ 旧私钥解不开重封后的密文（旧对被作废）；
//   ⑤ 解不开的频道（历史遗留）被如实记成 broken，不会谎报"已重封"。
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/core/crypto/sodium_crypto.dart';
import 'package:synhub/src/data/dto/archive_dto.dart';
import 'package:synhub/src/data/e2ee/e2ee_service.dart';
import 'package:synhub/src/features/chat/channel_create_controller.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');
/// 验收用的 E2EE 口令。
///
/// 默认值与 `phase7_test.dart` / `phase8_test.dart` / `phase6_channel_create_test.dart`
/// **保持一致**：服务端那份 `key_pair` 就是用这个口令加密的。
/// 套件脚本（`tool/device_feature_suite.sh`）只传 QC/ACCOUNT/PASSWORD，**不传**
/// 这个 define ⇒ 原来 `String.fromEnvironment` 没给默认值时 `_passcode` 恒为空串，
/// `E2eeService.unlock('')` 必然抛 `SodiumException`。真机红灯的真因是
/// **少了一个 dart-define**，不是本机身份/Keystore 坏了。仍可用 `--dart-define` 覆盖。
const _passcode = String.fromEnvironment(
  'SYNO_E2EE_PASSCODE',
  defaultValue: 'flt-e2ee-pass',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 7 真机：renew_key 的重封链路', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(
        account: _account, password: _password, session: 'Chat');

    final container = ProviderContainer();
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });
    final ctrl = container.read(chatSessionControllerProvider.notifier);
    await ctrl.start(conn);
    await ctrl.refresh(); // 频道列表要显式拉一次，否则本地库还是空的
    final store = container.read(chatStoreProvider);
    final svc = container.read(e2eeServiceProvider);

    // ---------- 身份：服务端那份 + 口令解锁 ----------
    if (svc.identity == null) {
      final mine = await ctrl.chatApi!.myUser();
      expect(mine?.publicKey.isNotEmpty, isTrue,
          reason: '服务端应该有我的 key_pair');
      await svc.adoptServerIdentity(E2eeIdentity(
          publicKey: mine!.publicKey, privateKeyEnc: mine.privateKeyEnc));
    }
    final oldPublic = svc.publicKey!;
    final oldPrivate = await svc.unlock(_passcode);
    debugPrint('[p7rk] 旧公钥=${oldPublic.substring(0, 12)}…（已解锁）');

    // ---------- 造一个**本机一定持有密钥**的真加密频道当靶子 ----------
    //
    // 不拿 #49 那种历史遗留频道：它本地行的 `channel_key_enc` 是空的
    // （归档副本里才有），只能验"被记成 broken"那条分支。
    final create = container.read(channelCreateControllerProvider);
    final encName = 'flt-p7rk-enc-${DateTime.now().millisecondsSinceEpoch % 100000}';
    final created = await create.create(
      name: encName,
      purpose: 'Phase 7 renew_key 真机验收',
      type: 'private',
      encrypted: true,
      memberIds: const [],
    );
    final targetId = created.channelId;
    debugPrint('[p7rk] 靶子加密频道=#$targetId $encName');
    expect(targetId, greaterThan(0));
    await ctrl.refresh();
    addTearDown(() async {
      try {
        await ctrl.chatApi!.disjoinNamedChannel(targetId);
        debugPrint('[p7rk] 清场：#$targetId 已退出');
      } catch (e) {
        debugPrint('[p7rk] 清场失败：$e');
      }
    });

    // ---------- 拉真频道 / 真归档 ----------
    final channels = await store.allChannels();
    List<ArchiveDto> archives = const [];
    try {
      archives = await ctrl.chatApi!.listArchives();
    } catch (e) {
      debugPrint('[p7rk] 归档拿不到（不影响）：$e');
    }
    final encChannels =
        channels.where((c) => c.encrypted && c.channelKeyEnc.isNotEmpty);
    debugPrint('[p7rk] 本地频道 ${channels.length} 个，其中加密 '
        '${channels.where((c) => c.encrypted).length} 个；'
        '带 channel_key_enc 的 ${encChannels.length} 个 / 归档 ${archives.length} 个');
    for (final c in channels.where((c) => c.encrypted)) {
      debugPrint('[p7rk]   加密频道 #${c.channelId} ${c.name} '
          'keyEnc.isEmpty=${c.channelKeyEnc.isEmpty} '
          '状态=${svc.keyState(c).name} broken=${c.brokenUsers}');
    }

    // ---------- 换密钥对（只在内存里算，不上报！） ----------
    final renewed = await svc.renewKeyPair(
      passcode: _passcode,
      channels: channels,
      archives: archives,
    );
    debugPrint('[p7rk] ① 新公钥=${renewed.publicKey.substring(0, 12)}… '
        '（不同=${renewed.publicKey != oldPublic}）'
        ' 重封频道=${renewed.channelIds.length} 归档=${renewed.archiveIds.length} '
        'broken=${renewed.brokenChannelIds}');
    expect(renewed.publicKey, isNot(oldPublic));
    expect(renewed.publicKey, isNotEmpty);
    expect(renewed.privateKeyEnc, isNotEmpty);
    expect(renewed.channelIds, contains(targetId),
        reason: '刚建的靶子频道必须出现在重封列表里');
    expect(renewed.channelIds, isNot(contains(49)),
        reason: '#49 本地没有 channel_key_enc，只能记 broken');

    // 新私钥仍由同一个口令保护（换台设备也能解回来）
    final viaPasscode =
        SodiumCrypto.decryptPrivateKey(renewed.privateKeyEnc, _passcode);
    expect(viaPasscode, renewed.privateKey);
    // 错误口令解不开
    expect(() => SodiumCrypto.decryptPrivateKey(renewed.privateKeyEnc, 'nope'),
        throwsA(anything));

    // ---------- 逐频道验证重封 ----------
    var checked = 0;
    for (final c in encChannels) {
      if (!renewed.channelIds.contains(c.channelId)) {
        debugPrint('[p7rk] ③ 跳过 #${c.channelId}（本来就解不开，计入 broken）');
        expect(renewed.brokenChannelIds, contains(c.channelId));
        continue;
      }
      final idx = renewed.channelIds.indexOf(c.channelId);
      final newEnc = renewed.channelKeyEncs[idx];

      // 新私钥解开 → 官方格式（seal 的是 base64 文本）→ 32 字节
      final plain = SodiumCrypto.sealDecrypt(
        _b64(newEnc),
        publicKeyBase64: renewed.publicKey,
        privateKeyBase64: renewed.privateKey,
      );
      final key = _openOfficial(plain);
      expect(key, isNotNull,
          reason: '#${c.channelId} 重封后必须是官方格式（base64 文本再 seal）');
      expect(key, hasLength(32));

      // 用旧对解出原来的密钥，应当一模一样（密钥本身不换，只换封装）
      final oldPlain = SodiumCrypto.sealDecrypt(
        _b64(c.channelKeyEnc),
        publicKeyBase64: oldPublic,
        privateKeyBase64: oldPrivate,
      );
      expect(_openOfficial(oldPlain), key,
          reason: '#${c.channelId} 换密钥对不该改变频道密钥本身');
      checked++;

      // 旧私钥解不开新封的（旧对作废）
      expect(
        () => SodiumCrypto.sealDecrypt(
          _b64(newEnc),
          publicKeyBase64: renewed.publicKey,
          privateKeyBase64: oldPrivate,
        ),
        throwsA(anything),
        reason: '#${c.channelId} 旧私钥不该还能解新封装',
      );
    }
    debugPrint('[p7rk] ③ 逐个核对重封：$checked 个频道通过');

    // ---------- 归档同样一组 ----------
    var archived = 0;
    for (final a in archives) {
      if (!renewed.archiveIds.contains(a.archiveId)) continue;
      final idx = renewed.archiveIds.indexOf(a.archiveId);
      final plain = SodiumCrypto.sealDecrypt(
        _b64(renewed.archiveKeyEncs[idx]),
        publicKeyBase64: renewed.publicKey,
        privateKeyBase64: renewed.privateKey,
      );
      expect(_openOfficial(plain), hasLength(32));
      archived++;
    }
    debugPrint('[p7rk] ④ 归档重封：$archived 个通过');

    // ---------- ⑤ 线上账号没有被改动 ----------
    final mine = await ctrl.chatApi!.myUser();
    debugPrint('[p7rk] ⑤ 服务端上的公钥仍是旧对=${mine?.publicKey == oldPublic}'
        '（本用例刻意不上报 renew_key）');
    expect(mine?.publicKey, oldPublic, reason: '真机验收不能改线上账号的密钥对');
    expect(svc.publicKey, oldPublic, reason: '本地身份也应当没变');

    debugPrint('[p7rk] 完成 ✓（写路径 update_key v2 见 phase7_broken_test）');
  });
}

List<int> _b64(String s) => const Base64Decoder().convert(s);

/// 官方格式：seal 的明文是 base64 文本，解出来要再 base64 解码成 32 字节
List<int>? _openOfficial(List<int> plain) {
  if (plain.length == 32) return plain; // 我们自己早期的裸格式
  try {
    final decoded = base64Decode(String.fromCharCodes(plain));
    return decoded.length == 32 ? decoded : null;
  } catch (_) {
    return null;
  }
}
