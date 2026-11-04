// Phase 7：真正「更换密钥对」（原版 `RenewKeyPresenter` / `AccountManager.renewKey`）。
//
// 原版流程：生成新 X25519 对 → 旧口令解旧私钥（仅校验）→ 用**旧**对解出所有
// 加密频道 + 归档的频道密钥 → 用**新**公钥重封 → 7 字段 `update_key` v2 上报 →
// 本地换身份 + `updateChannelEncryptKeys`。
//
// 这里覆盖：service 的重封正确性（新私钥能解、旧私钥解不开）、口令错不产生任何
// 副作用、broken 频道被跳过、controller 的上报顺序与本地落地、失败时不换身份。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/crypto/sodium_crypto.dart';
import 'package:synhub/src/data/dto/archive_dto.dart';
import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/e2ee/e2ee_service.dart';
import 'package:synhub/src/data/local/chat_store.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/settings/e2ee_controller.dart';

import 'support/chat_harness.dart';

ChatStore _store() => ChatStore(ChatDatabase(NativeDatabase.memory()));

void main() {
  group('E2eeService.renewKeyPair', () {
    test('频道密钥重封给新公钥：新私钥能解、旧身份解不开', () async {
      final store = _store();
      final svc = E2eeService(store);
      final id = await svc.setup('pass-1');

      // 造一个真实频道密钥，并按老格式（base64 文本再 seal）封给我自己
      final channelKey = SodiumCrypto.randomBytes(32);
      final enc = SodiumCrypto.sealEncrypt(
        _utf8(base64Encode(channelKey)),
        id.publicKey,
      );
      final channel = ChannelDto.fromJson({
        'channel_id': 45,
        'type': 'private',
        'encrypted': true,
        'channel_key_enc': enc,
        'name': '加密频道',
      });

      final renewed = await svc.renewKeyPair(
        passcode: 'pass-1',
        channels: [channel],
      );

      expect(renewed.publicKey, isNot(id.publicKey), reason: '应当是新密钥对');
      expect(renewed.channelIds, [45]);
      expect(renewed.channelKeyEncs, hasLength(1));
      expect(renewed.brokenChannelIds, isEmpty);

      // 新公钥+新私钥能解开重封后的密钥，且等于原密钥
      final opened = SodiumCrypto.sealDecrypt(
        _b64(renewed.channelKeyEncs.single),
        publicKeyBase64: renewed.publicKey,
        privateKeyBase64: renewed.privateKey,
      );
      expect(base64Decode(_utf8Decode(opened)), channelKey);

      // 旧私钥解不开新封的（前向安全：旧对不再能读新副本）
      expect(
        () => SodiumCrypto.sealDecrypt(
          _b64(renewed.channelKeyEncs.single),
          publicKeyBase64: renewed.publicKey,
          privateKeyBase64: svc.privateKey!,
        ),
        throwsA(anything),
      );
    });

    test('换完之后 adoptRenewedIdentity：本地身份换成新对且保持解锁', () async {
      final store = _store();
      final svc = E2eeService(store);
      final id = await svc.setup('pass-1');
      final renewed = await svc.renewKeyPair(passcode: 'pass-1', channels: []);

      await svc.adoptRenewedIdentity(renewed);
      expect(svc.publicKey, renewed.publicKey);
      expect(svc.isUnlocked, isTrue);
      expect(svc.privateKey, renewed.privateKey);

      // 落库了：另一个 service 用同一口令能解出新私钥
      final svc2 = E2eeService(store);
      await svc2.load();
      expect(svc2.publicKey, renewed.publicKey);
      expect(await svc2.unlock('pass-1'), renewed.privateKey);
      expect(svc2.publicKey, isNot(id.publicKey));
    });

    test('口令错 → 抛异常，且不改任何东西（旧身份仍可用）', () async {
      final store = _store();
      final svc = E2eeService(store);
      final id = await svc.setup('right');
      final channelKey = SodiumCrypto.randomBytes(32);
      final channel = ChannelDto.fromJson({
        'channel_id': 46,
        'type': 'private',
        'encrypted': true,
        'channel_key_enc': SodiumCrypto.sealEncrypt(
          _utf8(base64Encode(channelKey)),
          id.publicKey,
        ),
        'name': 'x',
      });

      await expectLater(
        svc.renewKeyPair(passcode: 'wrong', channels: [channel]),
        throwsA(isA<SodiumException>()),
      );
      expect(svc.publicKey, id.publicKey, reason: '旧身份必须原样');
      expect(svc.privateKey, isNotNull, reason: '还是解锁态');
    });

    test('解不开的频道被跳过并记进 brokenChannelIds（不谎报已重封）', () async {
      final store = _store();
      final svc = E2eeService(store);
      await svc.setup('p');
      final other = SodiumCrypto.generateKeyPair();
      final broken = ChannelDto.fromJson({
        'channel_id': 47,
        'type': 'private',
        'encrypted': true,
        // 封给了别人的公钥 → 我解不开
        'channel_key_enc': SodiumCrypto.sealEncrypt(
          _utf8(base64Encode(SodiumCrypto.randomBytes(32))),
          other.publicKey,
        ),
        'name': 'broken',
      });
      final renewed = await svc.renewKeyPair(passcode: 'p', channels: [broken]);
      expect(renewed.channelIds, isEmpty);
      expect(renewed.channelKeyEncs, isEmpty);
      expect(renewed.brokenChannelIds, [47]);
    });

    test('归档走 archive_ids/archive_key_encs 一组，与频道分开', () async {
      final store = _store();
      final svc = E2eeService(store);
      final id = await svc.setup('p');
      final channelKey = SodiumCrypto.randomBytes(32);
      final enc = SodiumCrypto.sealEncrypt(
        _utf8(base64Encode(channelKey)),
        id.publicKey,
      );
      final channel = ChannelDto.fromJson({
        'channel_id': 48,
        'type': 'private',
        'encrypted': true,
        'channel_key_enc': enc,
        'name': 'c',
      });
      final archive = ArchiveDto.tryParse({
        'archive_id': 900,
        'props': {
          'channel': {
            'channel_id': 48,
            'type': 'private',
            'encrypted': true,
            'channel_key_enc': enc,
            'name': 'c',
          },
        },
      })!;

      final renewed = await svc.renewKeyPair(
        passcode: 'p',
        channels: [channel],
        archives: [archive],
      );
      expect(renewed.channelIds, [48]);
      expect(renewed.archiveIds, [900]);
      expect(renewed.archiveKeyEncs, hasLength(1));
      expect(
        renewed.channelKeyEncs.single,
        isNot(renewed.archiveKeyEncs.single),
        reason: '每次 seal 都是新密文（crypto_box_seal 带随机）',
      );
    });
  });

  group('E2eeController.renewKeyPair（上报 + 本地落地）', () {
    test('update_key 带 7 个字段；成功后换身份、换本地 channel_key_enc、摘自己的 ⚠', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Archive.list': {'archives': []},
        },
      );
      final store = h.container.read(chatStoreProvider);
      final svc = h.container.read(e2eeServiceProvider);

      // 先建身份 + 一个加密频道
      final id = await svc.setup('pass');
      final channelKey = SodiumCrypto.randomBytes(32);
      final enc = SodiumCrypto.sealEncrypt(
        _utf8(base64Encode(channelKey)),
        id.publicKey,
      );
      await store.upsertChannels([
        ChannelDto.fromJson({
          'channel_id': 45,
          'type': 'private',
          'encrypted': true,
          'channel_key_enc': enc,
          'name': '加密频道',
          'is_joined': true,
        }),
      ]);
      // 先把自己标成 broken，验证换完会摘掉
      await store.addChannelBrokenUsers(45, [14]);

      final ok = await h.container
          .read(e2eeControllerProvider.notifier)
          .renewKeyPair(passcode: 'pass');
      expect(ok, isTrue);
      expect(h.container.read(e2eeControllerProvider).error, isNull);

      // 上报的 7 个字段
      final call = h.transport.calls.lastWhere(
        (c) => c['api'] == 'SYNO.Chat.User' && c['method'] == 'update_key',
      );
      for (final key in [
        'conn_id',
        'public_key',
        'private_key_enc',
        'channel_ids',
        'channel_key_encs',
        'archive_ids',
        'archive_key_encs',
      ]) {
        expect(call.containsKey(key), isTrue, reason: '缺字段 $key');
      }
      expect(call['channel_ids'], '[45]');
      // 新公钥 ≠ 旧公钥
      expect(call['public_key'], isNot(id.publicKey));

      // 本地身份换了
      final after = h.container.read(e2eeServiceProvider);
      expect(after.publicKey, '${call['public_key']}'.replaceAll('"', ''));
      // 本地 channel_key_enc 换成新封的
      final stored = (await store.allChannels()).firstWhere(
        (c) => c.channelId == 45,
      );
      expect(
        stored.channelKeyEnc,
        '${call['channel_key_encs']}'.replaceAll(RegExp(r'[\[\]"]'), ''),
      );
      // 自己的 ⚠ 摘掉了
      expect(stored.brokenUsers, isNot(contains(14)));
    });

    test('服务端拒绝 → 本地身份保持旧对（不能出现半截状态）', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Archive.list': {'archives': []},
        },
      );
      final svc = h.container.read(e2eeServiceProvider);
      final id = await svc.setup('pass');
      h.transport.failures['SYNO.Chat.User.update_key'] = 407;

      final ok = await h.container
          .read(e2eeControllerProvider.notifier)
          .renewKeyPair(passcode: 'pass');
      expect(ok, isFalse);
      expect(svc.publicKey, id.publicKey, reason: '失败必须保留旧身份');
      expect(h.container.read(e2eeControllerProvider).error, isNotNull);
    });

    test('口令错 → false 且不发 update_key', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Archive.list': {'archives': []},
        },
      );
      await h.container.read(e2eeServiceProvider).setup('right');
      final before = h.transport.calls.length;
      final ok = await h.container
          .read(e2eeControllerProvider.notifier)
          .renewKeyPair(passcode: 'wrong');
      expect(ok, isFalse);
      expect(
        h.transport.calls
            .skip(before)
            .where((c) => c['method'] == 'update_key'),
        isEmpty,
      );
    });
  });
}

List<int> _utf8(String s) => s.codeUnits.isEmpty ? <int>[] : _encode(s);
List<int> _encode(String s) => const Utf8Encoder().convert(s);
String _utf8Decode(List<int> bytes) => const Utf8Decoder().convert(bytes);
List<int> _b64(String s) => const Base64Decoder().convert(s);
