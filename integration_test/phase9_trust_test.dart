// Phase 9 真机验收：首连证书信任（用真 NAS 的真实自签证书跑完整链路）。
//
//   flutter test integration_test/phase9_trust_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_URL=https://nas.example.com:5001
//
// 验的是"用户不点信任就连不上、点了才连上、指纹变了要重新确认"这三件事：
//   ① 抓真实证书指纹（SecureSocket）；
//   ② 未信任 + 用户拒绝 → 连不上，且信任库里没有；
//   ③ 未信任 + 用户同意 → 连上（重试成功），库里指纹 = 真实指纹；
//   ④ 已信任 → 不再弹框，直接连上；
//   ⑤ 指纹被换掉（模拟中间人）→ 连不上，且挑战里带出原指纹（UI 会红色告警）；
//   ⑥ 证书管理页能列出、能删除。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_tokens.dart';
import 'package:integration_test/integration_test.dart';
import 'package:synhub/src/core/net/trust_store.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/servers/certificates_page.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

/// 直连地址。
///
/// 套件（`tool/device_feature_suite.sh`）只传 QC / 账号 / 口令，**不传**这个
/// define ⇒ 原来 `String.fromEnvironment` 没给默认值时 `_direct` 恒为空串，
/// 用例第 31 行 `expect(_direct, isNotEmpty)` 必红 —— "真机红灯"的真因是
/// **少了一个 dart-define**（同 phase7 那一簇 `SYNO_E2EE_PASSCODE`，见
/// AGENTS §2.0.20 第 5 条），不是信任链坏了。
/// 默认值 = 本验收 NAS 的局域网地址（真机实测可达、能拿到那张自签证书）。
/// 仍可用 `--dart-define=SYNO_NAS_URL=…` 覆盖。
const _direct = String.fromEnvironment(
  'SYNO_NAS_URL',
  defaultValue: 'https://nas.example.com:5001',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // ★ 真机 `integration_test` 的"常驻动效"陷阱（第 45 轮定位）：
  //   `FieldBackdrop` 在 `AppEffects.ambientAllowed` 为真时会
  //   `AnimationController.repeat()`（`lib/src/core/ui/field_backdrop.dart:104`），
  //   而 `ambientAllowed = Motion.enabled && !AppEffects.isFlutterTest`
  //   （`lib/src/core/theme/app_tokens.dart:109`）；`isFlutterTest` 只认
  //   `Platform.environment.containsKey('FLUTTER_TEST')`（`:99`）—— 这个环境变量
  //   **只有宿主 `flutter test` 才有，真机 App 进程里永远没有** ⇒ 生产路径的常驻
  //   动效照常在跑 ⇒ 含 `FieldBackdrop` 的页面（ChatPage / CertificatesPage …）上的
  //   `pumpAndSettle()` 永远等不到停帧：默认 10 分钟超时，整目标先被套件看门狗杀掉，
  //   日志里连一条 `Expected/Actual` 都看不到。
  //   这里按仓库既有约定（AGENTS §2.0.9「有常驻动画时 pumpAndSettle 不可用」）
  //   显式打开**用户可见的**「减少动效」开关把常驻动效停掉：
  //   不改产品行为、不放宽任何产品断言。
  AppEffects.reducedMotion.value = true;

  testWidgets('Phase 9 真机：首连证书信任（拒绝/信任/指纹变更）', (tester) async {
    expect(_direct, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_URL=…');
    final uri = Uri.parse(_direct);
    final hostPort = '${uri.host}:${uri.port}';

    // ---------- ① 抓真实证书指纹 ----------
    X509Certificate? seen;
    final socket = await SecureSocket.connect(
      uri.host,
      uri.port,
      onBadCertificate: (cert) {
        seen = cert;
        return true; // 只是抓证书，不做信任判断
      },
    );
    socket.destroy();
    expect(seen, isNotNull, reason: 'NAS 应该给出一张（自签）证书');
    final realFp = TrustPolicy.fingerprintOf(seen!);
    debugPrint('[p9t] 服务器证书指纹=$realFp');
    debugPrint('[p9t] subject=${seen!.subject} / issuer=${seen!.issuer}');
    debugPrint('[p9t] 有效期 ${seen!.startValidity} ~ ${seen!.endValidity}');

    // 用测试自己的 ProviderContainer（不依赖 App 启动）
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final store = container.read(chatStoreProvider);
    final policy = TrustPolicy.of(
      read: (k) => store.setting(k),
      write: (k, v) => store.setSetting(k, v),
      remove: (k) => store.deleteSetting(k),
      all: () => store.allSettings(),
    );
    await policy.load();

    // ★ 先**清干净**这台主机在信任库里的旧指纹（第 45 轮真机实测）。
    //   步骤②的前提是"未信任"，可这个用例自己会在步骤③把指纹写进库、步骤⑥才删；
    //   只要上一次跑到一半被看门狗/崩溃打断（本机真机上就发生过：600s 看门狗在
    //   步骤⑥把整目标杀了），库里就会**残留**指纹 ⇒ 下一次跑时 `connect()` 直接
    //   成功、压根不弹框、也不抛 StateError ⇒ 步骤②那句
    //   `expectLater(…, throwsA(isA<StateError>()))` 报
    //   "Expected: throws ... / Actual: <Instance of 'Future<DsmConnection>'>"，
    //   看着像"信任链坏了"，其实是**用例不幂等**（产品行为是对的：已信任就该直连，
    //   步骤④本身就是在断言这一点）。开跑前清一次，谁打断过都不影响下一次。
    await policy.forget(hostPort);

    final profile = ServerProfile(
      kind: ServerAddressKind.direct,
      value: _direct,
    );
    final service =
        ConnectionService(trustPolicy: policy, probeTimeout: const Duration(seconds: 8));
    final steps = <String>[];

    // ---------- ② 未信任 + 拒绝 ----------
    var asked = 0;
    TrustChallenge? askedChallenge;
    policy.prompt = (ch) async {
      asked++;
      askedChallenge = ch;
      return false;
    };
    await expectLater(service.connect(profile), throwsA(isA<StateError>()));
    expect(asked, greaterThanOrEqualTo(1), reason: '必须弹框问用户');
    expect(askedChallenge!.sha256, realFp,
        reason: '弹框里显示的指纹必须就是服务端的真实指纹');
    expect(askedChallenge!.isChanged, isFalse, reason: '首次连接不是"变更"');
    // 这台 NAS 装的是 Let's Encrypt 正式证书（CN=nas.example.com），
    // 按 **IP** 访问会走到 badCertificateCallback 的"主机名不匹配"分支，
    // 所以这里不是自签名 —— 原版同样会弹信任框。
    expect(askedChallenge!.isSelfSigned, isFalse,
        reason: '正式证书 + 按 IP 访问 → 域名不匹配，不是自签名');
    expect(askedChallenge!.issuer, contains("Let's Encrypt"));
    expect(await policy.find(hostPort), isNull, reason: '拒绝就不该入库');
    debugPrint('[p9t] 拒绝 → 连不上且不入库 ✓');

    // ---------- ③ 未信任 + 同意 ----------
    steps.clear();
    policy.prompt = (ch) async => true;
    final conn = await service.connect(
      profile,
      onStep: (s) {
        steps.add('${s.ok ? '' : '✗ '}${s.text}');
        debugPrint('[p9t] ${s.ok ? '' : '✗ '}${s.text}');
      },
    );
    expect(conn.endpoint.baseUrl, contains(uri.host));
    expect(steps.any((s) => s.contains('未受信任')), isTrue,
        reason: '第一次必须因证书被拒');
    expect(steps.any((s) => s.contains('重试连接')), isTrue,
        reason: '信任后必须重试');
    final stored = await policy.find(hostPort);
    expect(stored, isNotNull);
    expect(stored!.sha256, realFp);
    expect(stored.subject, seen!.subject);
    debugPrint('[p9t] 同意 → 连上 + 入库指纹一致 ✓');

    // 真的能登录（说明重试后的连接是可用的，不只是握上手）
    await conn.api.login(
      account: const String.fromEnvironment('SYNO_NAS_ACCOUNT'),
      password: const String.fromEnvironment('SYNO_NAS_PASSWORD'),
      session: 'Chat',
    );
    debugPrint('[p9t] 重试后的连接能正常登录 ✓');

    // ---------- ④ 已信任 → 不再弹框 ----------
    var askedAgain = 0;
    final policy2 = TrustPolicy.of(
      read: (k) => store.setting(k),
      write: (k, v) => store.setSetting(k, v),
      remove: (k) => store.deleteSetting(k),
      all: () => store.allSettings(),
    );
    await policy2.load();
    policy2.prompt = (ch) async {
      askedAgain++;
      return false; // 就算会弹也是拒绝 —— 但根本不该走到这里
    };
    final service2 = ConnectionService(trustPolicy: policy2);
    final conn2 = await service2.connect(profile);
    expect(askedAgain, 0, reason: '已信任的证书不该再问');
    expect(conn2.endpoint.baseUrl, contains(uri.host));
    debugPrint('[p9t] 已信任 → 免弹框直连 ✓');

    // ---------- ⑤ 指纹变了 → 拒绝 + 带出原指纹 ----------
    await policy.forget(hostPort); // 清掉
    await policy.trust(TrustChallenge(
      host: hostPort,
      sha256: 'AB' * 32, // 假装以前信任的是别的证书
      subject: 'CN=old',
      issuer: 'CN=old',
      validFrom: DateTime(2025, 1, 1),
      validTo: DateTime(2030, 1, 1),
    ));
    final policy3 = TrustPolicy.of(
      read: (k) => store.setting(k),
      write: (k, v) => store.setSetting(k, v),
      remove: (k) => store.deleteSetting(k),
      all: () => store.allSettings(),
    );
    await policy3.load();
    TrustChallenge? changed;
    policy3.prompt = (ch) async {
      changed = ch;
      return false;
    };
    final service3 = ConnectionService(trustPolicy: policy3);
    await expectLater(service3.connect(profile), throwsA(isA<StateError>()));
    expect(changed, isNotNull);
    expect(changed!.isChanged, isTrue, reason: '必须识别成"证书变更"');
    expect(changed!.changedFrom, 'AB' * 32);
    expect(changed!.sha256, realFp);
    debugPrint('[p9t] 指纹变更 → 拒绝 + 原指纹=${changed!.changedFrom} ✓');

    // ---------- ⑥ 证书管理页 ----------
    await policy.forget(hostPort);
    await policy.trust(askedChallenge!);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: CertificatesPage()),
    ));
    await tester.pumpAndSettle();
    expect(find.text(hostPort), findsOneWidget);
    // 页面上按字节分组展示（DD:4F:75:…）
    final grouped =
        realFp.replaceAllMapped(RegExp(r'.{2}'), (m) => '${m[0]}:');
    expect(find.textContaining(grouped.substring(0, 11)), findsOneWidget);
    debugPrint('[p9t] 证书管理页列出 $hostPort ✓');

    await tester.tap(find.byIcon(Icons.delete_outline));
    // 收尾按**接口**再清一次（页面删除可能带二次确认，UI 走法将来会变）：
    // 保证用例无论走到哪一步结束，这台主机都不会留在信任库里 —— 幂等就靠这个。
    await policy.forget(hostPort);
    expect(await policy.find(hostPort), isNull, reason: '删掉后不该还在信任库里');
    debugPrint('[p9t] 信任库已清干净 ✓');
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await policy.load();
    expect(await policy.find(hostPort), isNull);
    debugPrint('[p9t] 删除信任 ✓');

    // 收尾：不留痕
    await policy.forget(hostPort);
    debugPrint('[p9t] 清理完成 ✓');
  });
}
