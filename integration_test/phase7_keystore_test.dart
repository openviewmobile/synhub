// Phase 7 真机验收：E2EE 身份的静态加密（Android Keystore）。
//
//   flutter test integration_test/phase7_keystore_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=… --dart-define=SYNO_E2EE_PASSCODE=…
//
// 对齐原版 `PreferencesHelper.setBase64KeyPair`：整对 keypair（含 privateKeyEnc）
// 在本机落盘前要经 Android Keystore 加密。这条用例在**真机真 Keystore**上验：
//   ① `KeystoreSecretKeeper.isSupported` 为真（说明没被"测试环境"挡掉）；
//   ② 升级/写入后，Drift 里的 `e2ee_identity` 是 `{"v":2,"sealed":…}`，
//      **不含** privateKeyEnc / public_key 原文；
//   ③ 另起一个 E2eeService（同一 Keystore）能 load 回来、口令解开同一把私钥；
//   ④ 用回来的私钥还能解开真加密频道的 `channel_key_enc`（功能没被加密层破坏）；
//   ⑤ 收尾：自建靶子频道退出；万一解封失败，用服务端 key_pair 复原身份。
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/core/security/keystore_secret_keeper.dart';
import 'package:synhub/src/data/chat_api.dart';
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

  testWidgets('Phase 7 真机：E2EE 身份经 Android Keystore 落盘', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    // ① 真机上必须真的走 Keystore（不是被 FLUTTER_TEST 挡掉的 no-op）
    debugPrint('[p7ks] KeystoreSecretKeeper.isSupported='
        '${KeystoreSecretKeeper.isSupported}');
    expect(KeystoreSecretKeeper.isSupported, isTrue,
        reason: '真机 App 进程里应当支持 Keystore');

    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(
        account: _account, password: _password, session: 'Chat');

    final container = ProviderContainer();
    var healthy = false;
    ChatApi? api;
    addTearDown(() async {
      try {
        container.dispose();
      } catch (_) {}
      if (!healthy) {
        // 兜底：万一中途把本机身份搞坏了，用服务端 key_pair 复原
        try {
          final c2 = ProviderContainer();
          final svc2 = c2.read(e2eeServiceProvider);
          final fresh = await api?.myUser();
          if (fresh != null && fresh.publicKey.isNotEmpty) {
            await svc2.adoptServerIdentity(E2eeIdentity(
                publicKey: fresh.publicKey,
                privateKeyEnc: fresh.privateKeyEnc));
            await svc2.unlock(_passcode);
            debugPrint('[p7ks] 已用服务端 key_pair 复原本机身份');
          }
          c2.dispose();
        } catch (e) {
          debugPrint('[p7ks] 复原失败：$e');
        }
      }
    });

    final ctrl = container.read(chatSessionControllerProvider.notifier);
    await ctrl.start(conn);
    api = ctrl.chatApi;
    await ctrl.refresh();
    final store = container.read(chatStoreProvider);
    final svc = container.read(e2eeServiceProvider);

    // ---------- 身份就位（服务端那份 + 口令解锁） ----------
    if (svc.identity == null) {
      final mine = await ctrl.chatApi!.myUser();
      expect(mine?.publicKey.isNotEmpty, isTrue);
      await svc.adoptServerIdentity(E2eeIdentity(
          publicKey: mine!.publicKey, privateKeyEnc: mine.privateKeyEnc));
    }
    final publicKey = svc.publicKey!;
    final privateKey = await svc.unlock(_passcode);

    // ---------- 造一个本机持有密钥的真加密频道 ----------
    final create = container.read(channelCreateControllerProvider);
    final encName =
        'flt-p7ks-${DateTime.now().millisecondsSinceEpoch % 100000}';
    final created = await create.create(
      name: encName,
      purpose: 'Phase 7 Keystore 真机验收',
      type: 'private',
      encrypted: true,
      memberIds: const [],
    );
    final cid = created.channelId;
    debugPrint('[p7ks] 靶子加密频道=#$cid $encName');
    expect(cid, greaterThan(0));
    await ctrl.refresh();
    addTearDown(() async {
      try {
        await ctrl.chatApi!.disjoinNamedChannel(cid);
        debugPrint('[p7ks] 清场：#$cid 已退出');
      } catch (e) {
        debugPrint('[p7ks] 清场失败：$e');
      }
    });

    // 触发一次真正的落盘（adopt 已经写过一次；这里再写保证是 v2）
    await svc.adoptServerIdentity(E2eeIdentity(
        publicKey: publicKey, privateKeyEnc: svc.identity!.privateKeyEnc));

    // ---------- ② 落盘记录是封过的 ----------
    final raw = (await store.setting('e2ee_identity'))!;
    debugPrint('[p7ks] ② 落盘记录前 40 字符=${raw.substring(0, raw.length < 40 ? raw.length : 40)}…');
    expect(raw.contains('"v":2'), isTrue, reason: '应当是 v2 封装格式');
    expect(raw.contains(svc.identity!.privateKeyEnc), isFalse,
        reason: 'privateKeyEnc 不该明文落盘');
    expect(raw.contains(publicKey), isFalse, reason: 'public_key 也不该明文落盘');

    // ---------- ③ 新的 service 能解封 + 口令解开同一把私钥 ----------
    final svc2 = E2eeService(store, keeper: const KeystoreSecretKeeper());
    final loaded = await svc2.load();
    expect(loaded, isNotNull, reason: '真 Keystore 应当能解封自己封的');
    expect(loaded!.publicKey, publicKey);
    expect(await svc2.unlock(_passcode), privateKey,
        reason: '同一个口令必须解出同一把私钥');

    // ---------- ④ 用解封回来的私钥解真频道的密钥 ----------
    svc2.loadChannelKeys([for (final c in await store.allChannels()) c]);
    final target = (await store.allChannels()).firstWhere((c) => c.channelId == cid);
    debugPrint('[p7ks] ④ 靶子频道 keyState=${svc2.keyState(target).name}');
    expect(svc2.keyState(target).name, 'ready',
        reason: '解封回来的私钥必须还能解真频道的 channel_key_enc');

    healthy = true;
    debugPrint('[p7ks] 完成 ✓');
  });
}
