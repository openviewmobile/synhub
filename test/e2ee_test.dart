// Phase 7 E2EE 离线测试：身份/口令、频道密钥分发、消息与文件加解密，
// 以及三个新 API（`update_key` / `Anonymous.initiate` / `Channel.rescue`）
// 的参数形状——参数形状全部照真机实测（见 docs/phase7-protocol.md）。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/crypto/sodium_crypto.dart';
import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/dto/archive_dto.dart';
import 'package:synhub/src/data/e2ee/e2ee_service.dart';
import 'package:synhub/src/data/local/chat_store.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/data/local/database.dart';

import 'support/chat_harness.dart';

ChatStore _store() => ChatStore(ChatDatabase(NativeDatabase.memory()));

ChannelDto _encryptedChannel(int id, String keyEnc) => ChannelDto.fromJson({
  'channel_id': id,
  'type': 'private',
  'encrypted': true,
  'channel_key_enc': keyEnc,
  'name': '加密频道',
});

void main() {
  group('身份与口令', () {
    test('setup 生成密钥对并落库，私钥可直接用', () async {
      final store = _store();
      final svc = E2eeService(store);
      expect(svc.isConfigured, isFalse);
      expect(svc.isUnlocked, isFalse);

      final id = await svc.setup('my-pass');
      expect(id.publicKey, isNotEmpty);
      expect(base64Decode(id.publicKey), hasLength(32));
      expect(id.privateKeyEnc, isNotEmpty);
      expect(svc.isConfigured, isTrue);
      expect(svc.isUnlocked, isTrue, reason: '刚设置完应当是解锁态');
      expect(svc.privateKey, isNotNull);

      // 落库：新开一个 service 读回来
      final svc2 = E2eeService(store);
      final loaded = await svc2.load();
      expect(loaded?.publicKey, id.publicKey);
      expect(loaded?.privateKeyEnc, id.privateKeyEnc);
      expect(svc2.isUnlocked, isFalse, reason: '重启后必须重新输口令');
    });

    test('口令错了解不开，对了能解出同一把私钥', () async {
      final store = _store();
      final svc = E2eeService(store);
      final id = await svc.setup('right-pass');
      final privateKey = svc.privateKey!;

      final svc2 = E2eeService(store);
      await svc2.load();
      expect(() => svc2.unlock('wrong-pass'), throwsA(isA<SodiumException>()));
      expect(svc2.isUnlocked, isFalse);
      expect(await svc2.unlock('right-pass'), privateKey);
      expect(svc2.isUnlocked, isTrue);
      expect(svc2.publicKey, id.publicKey);
    });

    test('换口令（changePasscode）：旧口令失效、新口令可用、私钥不变', () async {
      final store = _store();
      final svc = E2eeService(store);
      await svc.setup('old-pass');
      final privateKey = svc.privateKey!;
      final oldEnc = svc.identity!.privateKeyEnc;

      final updated = await svc.changePasscode(
        oldPasscode: 'old-pass',
        newPasscode: 'new-pass',
      );
      expect(updated.privateKeyEnc, isNot(oldEnc));

      final svc2 = E2eeService(store);
      await svc2.load();
      expect(() => svc2.unlock('old-pass'), throwsA(isA<SodiumException>()));
      expect(await svc2.unlock('new-pass'), privateKey);
    });

    test('lock 抹掉内存里的私钥与频道密钥，reset 连身份一起清', () async {
      final store = _store();
      final svc = E2eeService(store);
      await svc.setup('pass');
      final ch = _encryptedChannel(1, 'x');
      svc.putChannelKey(1, List.filled(32, 9));
      expect(svc.channelKey(1), isNotNull);

      svc.lock();
      expect(svc.isUnlocked, isFalse);
      expect(svc.channelKey(1), isNull);
      expect(svc.isConfigured, isTrue, reason: 'lock 不该丢身份');

      await svc.reset();
      expect(svc.isConfigured, isFalse);
      expect(await E2eeService(store).load(), isNull);
      expect(ch.encrypted, isTrue);
    });

    test('晚到的 load() 不能把刚 setup 的身份冲掉（真踩过的竞态）', () async {
      final store = _store();
      final svc = E2eeService(store);
      // 先把一个"慢"的 load 挂起来（读的就是当时还是空的库）
      final slow = svc.load();
      final fresh = await svc.setup('pass');
      await slow;
      expect(
        svc.identity?.publicKey,
        fresh.publicKey,
        reason: 'load 在 setup 之后返回时，必须丢弃自己的过期结果',
      );
      expect(svc.isConfigured, isTrue);
      expect(svc.publicKey, fresh.publicKey);
    });

    test('归档：解密钥 + 上报 archive_ids/archive_key_encs', () async {
      final store = _store();
      final svc = E2eeService(store);
      final id = await svc.setup('p');
      final key = List<int>.generate(32, (i) => i + 1);
      svc.putChannelKey(45, key);

      // 归档的形状：{archive_id, props:{channel:{... channel_key_enc}}}
      final archives = ArchiveDto.parseList([
        {
          'archive_id': 7,
          'props': {
            'channel': {
              'channel_id': 45,
              'type': 'private',
              'encrypted': true,
              // 原 App 的在途格式：seal 的是密钥的 base64 文本
              'channel_key_enc': SodiumCrypto.sealEncrypt(
                utf8.encode(base64Encode(key)),
                id.publicKey,
              ),
            },
          },
        },
      ]);
      expect(archives.single.archiveId, 7);
      expect(archives.single.channel.channelId, 45);
      expect(svc.loadArchiveKeys(archives), isEmpty);

      final encs = svc.archiveKeyEncs(archives);
      expect(encs.archiveIds, [7]);
      final plain = SodiumCrypto.sealDecrypt(
        base64Decode(encs.archiveKeyEncs.single),
        publicKeyBase64: id.publicKey,
        privateKeyBase64: svc.privateKey!,
      );
      expect(plain, hasLength(44)); // base64 文本，跟官方客户端一致
      expect(base64Decode(utf8.decode(plain)), orderedEquals(key));
    });

    test('归档：锁着时算 broken', () async {
      final svc = E2eeService(_store());
      final id = await svc.setup('p');
      final archives = ArchiveDto.parseList([
        {
          'archive_id': 9,
          'props': {
            'channel': {
              'channel_id': 45,
              'encrypted': true,
              'channel_key_enc': SodiumCrypto.sealEncrypt(
                List<int>.filled(32, 3),
                id.publicKey,
              ),
            },
          },
        },
      ]);
      svc.lock();
      expect(svc.loadArchiveKeys(archives), [9]);
    });

    test('adoptServerIdentity：换设备时用服务端那份 key_pair', () async {
      final store = _store();
      final svc = E2eeService(store);
      final other = E2eeService(_store());
      final otherId = await other.setup('pass');
      await svc.adoptServerIdentity(otherId);
      expect(svc.publicKey, otherId.publicKey);
      expect(svc.isUnlocked, isFalse);
      expect(await svc.unlock('pass'), other.privateKey);
    });
  });

  group('频道密钥分发', () {
    test('newChannelKey：给每个人封一份，各自都能解出同一把钥匙', () async {
      final alice = E2eeService(_store());
      final bob = E2eeService(_store());
      final aliceId = await alice.setup('a');
      final bobId = await bob.setup('b');

      final made = alice.newChannelKey([bobId.publicKey, aliceId.publicKey]);
      expect(made.key, hasLength(32));
      expect(made.sealedKeys, hasLength(2));

      // Bob 的那一份
      final bobSvc = E2eeService(_store());
      await bobSvc.adoptServerIdentity(bobId);
      await bobSvc.unlock('b');
      expect(bobSvc.loadChannelKey(7, made.sealedKeys[0]), isTrue);
      expect(bobSvc.channelKey(7), made.key);

      // Alice 自己的那一份
      expect(alice.loadChannelKey(7, made.sealedKeys[1]), isTrue);
      expect(alice.channelKey(7), made.key);
    });

    test('在途格式 = seal(base64 文本)：跟原 App 双向互通，且兼容老的裸 32B', () async {
      final alice = E2eeService(_store());
      final bob = E2eeService(_store());
      final aliceId = await alice.setup('a');
      final bobId = await bob.setup('b');

      final made = alice.newChannelKey([bobId.publicKey]);
      final sealed = made.sealedKeys.single;

      // 官方客户端的解法定法是：seal 打开 → 得到 44 字符 base64 文本 → decode 回 32B。
      // 我们发出去的那份必须满足这个形状（只 seal 32B 裸字节时官方客户端会 broken）。
      final bobPriv = bob.privateKey!; // unlock 后才拿得到明文私钥
      final plain = SodiumCrypto.sealDecrypt(
        base64Decode(sealed),
        publicKeyBase64: bobId.publicKey,
        privateKeyBase64: bobPriv,
      );
      expect(plain, hasLength(44));
      expect(base64Decode(utf8.decode(plain)), made.key);

      // 反向：官方客户端封给我们的，我们要能解开
      final fromOfficial = SodiumCrypto.sealEncrypt(
        utf8.encode(base64Encode(List.filled(32, 6))),
        aliceId.publicKey,
      );
      expect(alice.loadChannelKey(21, fromOfficial), isTrue);
      expect(alice.channelKey(21), List.filled(32, 6));

      // 兼容早期纯 Dart 版本已经分发出去的裸 32B 格式
      final legacy = SodiumCrypto.sealEncrypt(
        List.filled(32, 8),
        aliceId.publicKey,
      );
      expect(alice.loadChannelKey(22, legacy), isTrue);
      expect(alice.channelKey(22), List.filled(32, 8));
    });

    test('loadChannelKeys：解不开的算 broken（原 App 的 broken channel）', () async {
      final alice = E2eeService(_store());
      final bob = E2eeService(_store());
      final aliceId = await alice.setup('a');
      final bobId = await bob.setup('b');

      final made = alice.newChannelKey([bobId.publicKey]);
      final sealedForBob = made.sealedKeys.single;

      // Alice 收到的是"封给 Bob"的那一份（历史 bug 现场）：解不开
      final broken = alice.loadChannelKeys([
        _encryptedChannel(1, sealedForBob),
      ]);
      expect(broken, [1]);
      expect(
        alice.keyState(_encryptedChannel(1, sealedForBob)),
        ChannelKeyState.missing,
      );

      // 没解锁时是 locked，不是 missing
      final locked = E2eeService(_store());
      await locked.adoptServerIdentity(aliceId);
      expect(
        locked.keyState(_encryptedChannel(2, sealedForBob)),
        ChannelKeyState.locked,
      );
      expect(locked.loadChannelKey(2, sealedForBob), isFalse);

      // 非加密频道不影响
      final plain = ChannelDto.fromJson({'channel_id': 3, 'type': 'public'});
      expect(alice.keyState(plain), ChannelKeyState.notEncrypted);
    });

    test('sealChannelKey：把已有钥匙封给别人（邀请/rescue）', () async {
      final alice = E2eeService(_store());
      final bob = E2eeService(_store());
      final bobId = await bob.setup('b');
      final aliceId = await alice.setup('a');
      alice.putChannelKey(5, List.generate(32, (i) => i));

      final sealed = alice.sealChannelKey(5, bobId.publicKey);
      await bob.unlock('b');
      expect(bob.loadChannelKey(5, sealed), isTrue);
      expect(bob.channelKey(5), alice.channelKey(5));
      expect(
        () => alice.sealChannelKey(99, aliceId.publicKey),
        throwsA(isA<SodiumException>()),
      );
    });

    test('myKeyEncs：产出 update_key 要的两条平行数组', () async {
      final svc = E2eeService(_store());
      await svc.setup('p');
      svc.putChannelKey(11, List.filled(32, 1));
      svc.putChannelKey(12, List.filled(32, 2));
      final out = svc.myKeyEncs([
        _encryptedChannel(11, ''),
        _encryptedChannel(12, ''),
        ChannelDto.fromJson({'channel_id': 13, 'type': 'public'}),
      ]);
      expect(out.channelIds, [11, 12]);
      expect(out.channelKeyEncs, hasLength(2));
      for (var i = 0; i < 2; i++) {
        final plain = SodiumCrypto.sealDecrypt(
          base64Decode(out.channelKeyEncs[i]),
          publicKeyBase64: svc.publicKey!,
          privateKeyBase64: svc.privateKey!,
        );
        expect(plain, hasLength(44));
        expect(
          base64Decode(utf8.decode(plain)),
          svc.channelKey(out.channelIds[i]),
        );
      }
    });
  });

  group('消息 / 文件加解密', () {
    test('加密频道里消息来回一致，非加密频道不该有钥匙', () async {
      final svc = E2eeService(_store());
      await svc.setup('p');
      svc.putChannelKey(1, List.filled(32, 7));

      final enc = svc.encryptMessage(1, '机密：明天见 🙂');
      expect(enc, isNot(contains('明天见')));
      expect(svc.tryDecryptMessage(1, enc), '机密：明天见 🙂');
      // 别人的密文（换一把钥匙）解不开 → null
      expect(
        svc.tryDecryptMessage(1, base64Encode(List.filled(60, 1))),
        isNull,
      );
      expect(svc.tryDecryptMessage(2, enc), isNull);
      expect(() => svc.encryptMessage(2, 'x'), throwsA(isA<SodiumException>()));
    });

    test('文件名走 hex、文件体走原始字节', () async {
      final svc = E2eeService(_store());
      await svc.setup('p');
      svc.putChannelKey(1, List.filled(32, 3));

      final name = svc.encryptFileName(1, '季度报告 2026.pdf');
      expect(name, matches(RegExp(r'^[0-9A-F]+$')));
      expect(svc.tryDecryptFileName(1, name), '季度报告 2026.pdf');
      expect(svc.tryDecryptFileName(1, 'zzz'), isNull);

      final body = List.generate(3000, (i) => i % 256);
      final enc = svc.encryptFileBytes(1, body);
      expect(enc.length, body.length + 24 + 16);
      expect(svc.tryDecryptFileBytes(1, enc), body);
      expect(svc.tryDecryptFileBytes(1, [1, 2, 3]), isNull);
    });
  });

  group('E2EE API 参数形状（对齐真机实测）', () {
    test('update_key：全部 Gson 再编码，channel_ids/key_encs 顺序一致', () async {
      final h = await bootChat();
      final svc = E2eeService(h.container.read(chatStoreProvider));
      final id = await svc.setup('p');
      svc.putChannelKey(45, List.filled(32, 5));
      final mine = svc.myKeyEncs([_encryptedChannel(45, '')]);

      await h.apiForTest.updateKey(
        connId: 'SID-1',
        publicKey: id.publicKey,
        privateKeyEnc: id.privateKeyEnc,
        channelIds: mine.channelIds,
        channelKeyEncs: mine.channelKeyEncs,
      );

      final call = h.transport.calls.lastWhere(
        (c) => c['method'] == 'update_key',
      );
      expect(call['api'], 'SYNO.Chat.User');
      expect('${call['version']}', '2');
      expect(jsonDecode(call['conn_id'] as String), 'SID-1');
      expect(jsonDecode(call['public_key'] as String), id.publicKey);
      expect(jsonDecode(call['private_key_enc'] as String), id.privateKeyEnc);
      expect(jsonDecode(call['channel_ids'] as String), [45]);
      expect(
        (jsonDecode(call['channel_key_encs'] as String) as List).length,
        1,
      );
      expect(jsonDecode(call['archive_ids'] as String), isEmpty);
      expect(jsonDecode(call['archive_key_encs'] as String), isEmpty);
    });

    test('Anonymous.initiate：[对方, 我] 的顺序、encrypted=true、返回频道对象', () async {
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.Anonymous.initiate': {
            'channel_id': 45,
            'type': 'private',
            'encrypted': true,
            'members': [4, 14],
            'channel_key_enc': 'SEALED-1',
          },
        },
      );
      final svc = E2eeService(h.container.read(chatStoreProvider));
      final me = await svc.setup('p');
      final other = E2eeService(_store());
      final otherId = await other.setup('o');
      final made = svc.newChannelKey([otherId.publicKey, me.publicKey]);

      final channel = await h.apiForTest.initiateAnonymous(
        userIds: [4, 14],
        channelKeyEncs: made.sealedKeys,
      );
      final call = h.transport.calls.lastWhere(
        (c) =>
            c['method'] == 'initiate' &&
            c['api'] == 'SYNO.Chat.Channel.Anonymous',
      );
      expect('${call['version']}', '1');
      expect(jsonDecode(call['user_ids'] as String), [4, 14]);
      expect(
        (jsonDecode(call['channel_key_encs'] as String) as List),
        made.sealedKeys,
      );
      expect(call['encrypted'], 'true');
      expect(channel.channelId, 45);
      expect(channel.encrypted, isTrue);
      expect(channel.members, [4, 14]);
      expect(channel.channelKeyEnc, 'SEALED-1');
    });

    test('Channel.rescue：只重封对方那一份', () async {
      final h = await bootChat();
      final svc = E2eeService(h.container.read(chatStoreProvider));
      final me = await svc.setup('p');
      svc.putChannelKey(45, List.filled(32, 6));

      final sealed = svc.sealChannelKey(45, me.publicKey);
      await h.apiForTest.rescueChannel(
        userId: 4,
        channelId: 45,
        channelKeyEnc: sealed,
      );

      final call = h.transport.calls.lastWhere((c) => c['method'] == 'rescue');
      expect(call['api'], 'SYNO.Chat.Channel');
      expect('${call['version']}', '1');
      expect(call['user_id'], '4');
      expect(call['channel_id'], '45');
      expect(jsonDecode(call['channel_key_enc'] as String), sealed);
    });
  });
}
