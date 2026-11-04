// Phase 7：E2EE 身份的**静态加密**（对齐原版 `LegacyKeystoreHelper` +
// `PreferencesHelper.setBase64KeyPair`）。
//
// 原版：整对 `Base64ChatKeyPair`（含 privateKeyEnc）先 Gson 序列化，再用
// AndroidKeyStore（alias `SYNOAPP`）加密后才写 SharedPreferences；我们把它做成
// `E2eeService.keeper`（Android 走 AES-256-GCM，测试注入假实现）。
//
// 这里覆盖：封了能开、落盘里**不含**私钥密文原文、旧明文格式自动升级、
// 没有 Keystore 时退回明文（行为不变）、Keystore 密钥丢了 → 当成"本机没身份"
// 而不是拿半个身份跑、setup/changePasscode/renew 全都走新出口。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/e2ee/e2ee_service.dart';
import 'package:synhub/src/data/e2ee/secret_keeper.dart';
import 'package:synhub/src/data/local/chat_store.dart';
import 'package:synhub/src/data/local/database.dart';

ChatStore _store() => ChatStore(ChatDatabase(NativeDatabase.memory()));

void main() {
  group('Keystore 包裹身份', () {
    test('setup 后落盘的是封过的记录，明文私钥密文不在库里', () async {
      final store = _store();
      final keeper = InMemorySecretKeeper();
      final svc = E2eeService(store, keeper: keeper);

      final id = await svc.setup('pass');
      final raw = (await store.setting('e2ee_identity'))!;

      expect(keeper.seals, 1, reason: '落盘必须过一次 seal');
      final json = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      expect(json['v'], 2);
      expect(json['sealed'], isNotNull);
      expect(
        raw.contains(id.privateKeyEnc),
        isFalse,
        reason: 'privateKeyEnc 不该明文躺在库里',
      );
      expect(raw.contains(id.publicKey), isFalse);
      expect(raw.contains('pass'), isFalse);
    });

    test('封过的记录换新 service 能读回来（同一 Keystore）', () async {
      final store = _store();
      final keeper = InMemorySecretKeeper();
      final id = await E2eeService(store, keeper: keeper).setup('pass');

      final svc2 = E2eeService(store, keeper: keeper);
      final loaded = await svc2.load();
      expect(loaded?.publicKey, id.publicKey);
      expect(loaded?.privateKeyEnc, id.privateKeyEnc);
      expect(await svc2.unlock('pass'), isNotNull);
    });

    test('旧明文格式自动升级：读到后重写成 v2，内容不变', () async {
      final store = _store();
      // 先用"没有 Keystore"的模式写一份明文（= 改造前的行为）
      final plain = E2eeService(
        store,
        keeper: InMemorySecretKeeper(available: false),
      );
      final id = await plain.setup('pass');
      final legacy = (await store.setting('e2ee_identity'))!;
      expect(legacy.contains(id.privateKeyEnc), isTrue, reason: '前提：明文格式');

      final keeper = InMemorySecretKeeper();
      final svc = E2eeService(store, keeper: keeper);
      final loaded = await svc.load();
      expect(loaded?.publicKey, id.publicKey);
      expect(keeper.seals, 1, reason: '读到旧格式应当顺手封装一次');

      final now = (await store.setting('e2ee_identity'))!;
      expect(now.contains(id.privateKeyEnc), isFalse);
      expect(Map<String, dynamic>.from(jsonDecode(now) as Map)['v'], 2);
      // 再读一次还能读出来，且不会再封（已经是 v2）
      final svc2 = E2eeService(store, keeper: keeper);
      expect((await svc2.load())?.publicKey, id.publicKey);
      expect(keeper.seals, 1);
    });

    test('没有 Keystore（seal 返回 null）→ 退回明文，功能不受影响', () async {
      final store = _store();
      final svc = E2eeService(
        store,
        keeper: InMemorySecretKeeper(available: false),
      );
      final id = await svc.setup('pass');
      final raw = (await store.setting('e2ee_identity'))!;
      expect(raw.contains(id.privateKeyEnc), isTrue);

      final svc2 = E2eeService(
        store,
        keeper: InMemorySecretKeeper(available: false),
      );
      expect((await svc2.load())?.publicKey, id.publicKey);
      expect(await svc2.unlock('pass'), isNotNull);
    });

    test('Keystore 密钥丢了（open 为 null）→ load 返回 null，不崩、不拿半个身份', () async {
      final store = _store();
      final keeper = InMemorySecretKeeper();
      await E2eeService(store, keeper: keeper).setup('pass');

      keeper.failOpen = true;
      final svc = E2eeService(store, keeper: keeper);
      expect(await svc.load(), isNull);
      expect(svc.isConfigured, isFalse);
      expect(svc.publicKey, isNull);
      // 记录还在（不清库）：用户重新从服务端 adopt 时会被覆盖
      expect(await store.setting('e2ee_identity'), isNotNull);
    });

    test('记录被写坏（不是 JSON）→ load 返回 null 而不是抛', () async {
      final store = _store();
      await store.setSetting('e2ee_identity', 'not-json');
      final svc = E2eeService(store, keeper: InMemorySecretKeeper());
      expect(await svc.load(), isNull);
    });

    test(
      'adoptServerIdentity / changePasscode / adoptRenewedIdentity 都走封装出口',
      () async {
        final store = _store();
        final keeper = InMemorySecretKeeper();
        final svc = E2eeService(store, keeper: keeper);

        await svc.adoptServerIdentity(
          const E2eeIdentity(publicKey: 'PUB_A', privateKeyEnc: 'ENC_A'),
        );
        var raw = (await store.setting('e2ee_identity'))!;
        expect(raw.contains('ENC_A'), isFalse, reason: 'adopt 也要封');
        expect(rawJson(raw)['v'], 2);

        // changePasscode 需要真私钥，所以先 setup 一次
        await svc.setup('old');
        await svc.changePasscode(oldPasscode: 'old', newPasscode: 'new');
        raw = (await store.setting('e2ee_identity'))!;
        expect(raw.contains('"private_key_enc"'), isFalse);
        expect(await E2eeService(store, keeper: keeper).load(), isNotNull);

        // renew：换完密钥对也要封着落盘
        final renewed = await svc.renewKeyPair(
          passcode: 'new',
          channels: const <ChannelDto>[],
        );
        await svc.adoptRenewedIdentity(renewed);
        raw = (await store.setting('e2ee_identity'))!;
        expect(raw.contains(renewed.privateKeyEnc), isFalse);
        final back = await E2eeService(store, keeper: keeper).load();
        expect(back?.publicKey, renewed.publicKey);
      },
    );
  });
}

/// 小工具：把落盘串当 JSON 读
Map<String, dynamic> rawJson(String raw) =>
    Map<String, dynamic>.from(jsonDecode(raw) as Map);
