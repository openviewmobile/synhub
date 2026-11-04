// 新建频道（含加密频道的密钥分发）离线验证。
//
// 关键点：
//   * 加密频道的调用**次序**：create → join（带自己的 channel_key_enc）→ invite
//     （带每个成员的 channel_key_encs）—— 顺序错了服务端会 421/401；
//   * 成员那把封好的密钥**真的能被该成员的私钥解开**，且等于本地留存的频道密钥；
//   * 没有加密密钥的成员要在**建频道之前**被挑出来（原版 `dialog_no_passphrase`：
//     移出名单 + 可选「通知他们」`User / notify_encrypt`）；
//   * 普通命名频道不发密钥、也不调 join。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/dto/user_dto.dart';
import 'package:synhub/src/data/e2ee/e2ee_service.dart';
import 'package:synhub/src/features/chat/channel_create_controller.dart';
import 'package:synhub/src/features/chat/channel_create_page.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';
import 'support/switch_rows.dart';
import 'package:synhub/src/design/kit/design_kit.dart';

Map<String, dynamic> _userJson({
  required int id,
  required String name,
  String type = 'human',
  String publicKey = '',
  bool deleted = false,
}) => {
  'user_id': id,
  'username': name,
  'nickname': name,
  'type': type,
  'status': 'online',
  if (publicKey.isNotEmpty)
    'user_props': {
      'key_pair': {'public_key': publicKey},
    },
  if (deleted) 'deleted': true,
};

/// 造一个"有人在用"的聊天环境：我 = 14，另有 demo(4)/openclaw(27, bot)/已删(9)
Future<ChatHarness> _boot({
  String otherPublicKey = '',
  bool withUsers = true,
}) => bootChat(
  extra: {
    'SYNO.Chat.Channel.Named.create': {'channel_id': 77},
    if (withUsers)
      'SYNO.Chat.User.list': {
        'users': [
          _userJson(id: 14, name: '我'),
          _userJson(id: 4, name: 'demo', publicKey: otherPublicKey),
          _userJson(id: 27, name: 'openclaw', type: 'bot'),
          _userJson(id: 9, name: '走的', deleted: true),
        ],
      },
  },
);

List<Map<String, dynamic>> _callsTo(
  FakeTransport t,
  String api,
  String method,
) => t.calls.where((c) => c['api'] == api && c['method'] == method).toList();

/// 点「创建」后页面进入 busy（转圈是无限动画，`pumpAndSettle` 会超时）→ 用固定 pump
Future<void> _pumpBusy(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('可邀请的人', () {
    test('排除我自己 / 机器人 / 已删除用户', () async {
      final h = await _boot();
      final list = await h.container
          .read(channelCreateControllerProvider)
          .invitableUsers();
      expect(list.map((u) => u.userId), [4]);
    });
  });

  group('普通命名频道', () {
    test('create → join → invite（普通频道也要先 join，不发密钥）', () async {
      final h = await _boot();
      final created = await h.container
          .read(channelCreateControllerProvider)
          .create(
            name: '  项目讨论  ',
            purpose: '干活的地方',
            type: 'public',
            memberIds: [4],
          );
      expect(created.channelId, 77);
      expect(created.encrypted, isFalse);

      final create = _callsTo(
        h.transport,
        'SYNO.Chat.Channel.Named',
        'create',
      ).single;
      expect('${create['version']}', '1');
      expect(create['name'], '项目讨论', reason: '要去掉首尾空格');
      expect(create['purpose'], '干活的地方');
      expect(create['type'], 'public');
      expect(create['encrypted'], 'false');
      expect(create.containsKey('channel_key_enc'), isFalse);

      final invite = _callsTo(
        h.transport,
        'SYNO.Chat.Channel.Named',
        'invite',
      ).single;
      expect(jsonDecode(invite['user_ids'] as String), [4]);
      expect(invite.containsKey('channel_key_encs'), isFalse);

      // 真机实测：create 后创建者不是成员，必须 join，否则 invite 401
      final join = _callsTo(
        h.transport,
        'SYNO.Chat.Channel.Named',
        'join',
      ).single;
      expect(join['channel_id'], 77);
      expect(join.containsKey('channel_key_enc'), isFalse, reason: '普通频道没有密钥');

      final order = h.transport.calls
          .where((c) => c['api'] == 'SYNO.Chat.Channel.Named')
          .map((c) => c['method'])
          .toList();
      expect(order, ['create', 'join', 'invite']);
    });

    test('名字为空 → 直接拒绝，且一个请求都不发', () async {
      final h = await _boot();
      await expectLater(
        h.container.read(channelCreateControllerProvider).create(name: '   '),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        _callsTo(h.transport, 'SYNO.Chat.Channel.Named', 'create'),
        isEmpty,
      );
    });
  });

  group('加密命名频道', () {
    test('次序 = create → join(自己的 key) → invite(每个成员各一份)', () async {
      late E2eeService e2ee;
      late String otherPublicKey;
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.Named.create': {'channel_id': 88},
        },
      );
      e2ee = h.container.read(e2eeServiceProvider);
      final me = await e2ee.setup('flt-pass');
      final other = E2eeService(_MemStore());
      final otherId = await other.setup('other-pass');
      otherPublicKey = otherId.publicKey;
      expect(otherPublicKey, isNotEmpty);

      // 成员写进库（nickname/username 都叫 demo）
      await h.container.read(chatStoreProvider).upsertUsers([
        UserDto.fromJson(
          _userJson(id: 4, name: 'demo', publicKey: otherPublicKey),
        ),
      ]);

      // 预置一行 #88（模拟 `Channel/list` 已经把它列出来、但**不带**
      // channel_key_enc —— 真机实测就是这样），这样"本地补写密文"才有行可写
      await h.container.read(chatStoreProvider).upsertChannels([
        ChannelDto.fromJson({
          'channel_id': 88,
          'type': 'private',
          'encrypted': true,
          'name': '加密频道',
          'is_joined': true,
        }),
      ]);

      final created = await h.container
          .read(channelCreateControllerProvider)
          .create(name: '加密频道', encrypted: true, memberIds: [4]);
      expect(created.channelId, 88);
      expect(created.encrypted, isTrue);
      expect(me.publicKey, isNotEmpty);

      // 调用次序
      final order = h.transport.calls
          .where((c) => c['api'] == 'SYNO.Chat.Channel.Named')
          .map((c) => c['method'])
          .toList();
      expect(order, ['create', 'join', 'invite']);

      final join = _callsTo(
        h.transport,
        'SYNO.Chat.Channel.Named',
        'join',
      ).single;
      expect(join['channel_id'], 88);
      final mySealed = join['channel_key_enc'] as String;
      expect(
        mySealed,
        isNotEmpty,
        reason: 'join 必须带自己的 channel_key_enc（否则 421）',
      );

      final invite = _callsTo(
        h.transport,
        'SYNO.Chat.Channel.Named',
        'invite',
      ).single;
      expect(jsonDecode(invite['user_ids'] as String), [4]);
      final encs = (jsonDecode(invite['channel_key_encs'] as String) as List)
          .cast<String>();
      expect(encs, hasLength(1));

      // 本地留存的频道密钥 = 成员私钥能解开的那把
      final localKey = e2ee.channelKey(88)!;
      final openedForOther = E2eeService(_MemStore());
      await openedForOther.adoptServerIdentity(otherId);
      await openedForOther.unlock('other-pass');
      expect(openedForOther.loadChannelKey(88, encs.single), isTrue);
      expect(
        openedForOther.channelKey(88),
        localKey,
        reason: '发给成员的必须是同一把频道密钥',
      );

      // 我自己那份也要能解开（重启后靠本地存下来的 channel_key_enc 恢复）
      final mine = E2eeService(_MemStore());
      await mine.adoptServerIdentity(me);
      await mine.unlock('flt-pass');
      expect(mine.loadChannelKey(88, mySealed), isTrue);
      expect(mine.channelKey(88), localKey);

      // ⚠️ 这份"封给我自己"的密文必须落到本地频道行：服务端 `Channel/list`
      // 对自己建的频道**不返回** channel_key_enc（真机实测 #49/#63 都是空），
      // 只靠服务端的话重启后 keyState 会变 missing、界面显示 ⚠。
      final stored = (await h.container.read(chatStoreProvider).allChannels())
          .firstWhere((c) => c.channelId == 88);
      expect(
        stored.channelKeyEnc,
        mySealed,
        reason: '本地必须存下封给自己的 channel_key_enc',
      );
      // 而且拿这份本地密文 + 口令就能把密钥恢复出来（= 重启场景）
      final reboot = E2eeService(h.container.read(chatStoreProvider));
      await reboot.load();
      await reboot.unlock('flt-pass');
      expect(reboot.loadChannelKey(88, stored.channelKeyEnc), isTrue);
    });

    test('成员没有加密密钥 → 建之前就拦住（不发 create）', () async {
      late E2eeService e2ee;
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.Named.create': {'channel_id': 99},
        },
      );
      e2ee = h.container.read(e2eeServiceProvider);
      await e2ee.setup('flt-pass');
      await h.container.read(chatStoreProvider).upsertUsers([
        UserDto.fromJson(_userJson(id: 4, name: 'demo')), // 没有 public_key
      ]);

      await expectLater(
        h.container
            .read(channelCreateControllerProvider)
            .create(name: '加密频道', encrypted: true, memberIds: [4]),
        throwsA(predicate((e) => '$e'.contains('还没有端到端加密密钥'))),
      );
      expect(
        _callsTo(h.transport, 'SYNO.Chat.Channel.Named', 'create'),
        isEmpty,
        reason: '不能先建出一个谁也解不开的频道',
      );
    });

    test('没有本机 E2EE 身份 → 明确报错', () async {
      final h = await _boot();
      await expectLater(
        h.container
            .read(channelCreateControllerProvider)
            .create(name: '加密频道', encrypted: true, memberIds: const []),
        throwsA(predicate((e) => '$e'.contains('还没有端到端加密身份'))),
      );
    });
  });

  group('新建频道页', () {
    Future<void> pump(WidgetTester tester, ChatHarness h) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: ChannelCreatePage()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('名称为空时创建按钮不可用；填了就可用', (tester) async {
      final h = await _boot();
      await pump(tester, h);

      final button = tester.widget<TextButton>(
        find.ancestor(of: find.text('创建'), matching: find.byType(TextButton)),
      );
      expect(button.onPressed, isNull);

      await tester.enterText(find.byType(TextField).first, '新频道');
      await tester.pump();
      final enabled = tester.widget<TextButton>(
        find.ancestor(of: find.text('创建'), matching: find.byType(TextButton)),
      );
      expect(enabled.onPressed, isNotNull);
    });

    testWidgets('加密开关给出「创建后无法关闭」的提示', (tester) async {
      final h = await _boot();
      await pump(tester, h);
      expect(find.textContaining('创建后无法切换'), findsOneWidget);

      await tester.tap(switchRowFinder);
      await tester.pumpAndSettle();
      expect(find.textContaining('创建后无法关闭'), findsOneWidget);
    });

    testWidgets('列成员时勾选状态可切换（机器人/已删不在列表里）', (tester) async {
      final h = await _boot();
      await pump(tester, h);
      expect(find.text('demo'), findsOneWidget, reason: '昵称=账号名时只显示一行');
      expect(find.text('openclaw'), findsNothing);
      expect(find.text('走的'), findsNothing);

      await tester.tap(checkboxRowFinder.first);
      await tester.pumpAndSettle();
      expect(
        tester.widget<DesignCheckRow>(find.byType(DesignCheckRow)).value,
        isTrue,
      );
    });

    // 原版行为（`showNoPublicKeyUsers` → `dialog_no_passphrase`）：**不是**报错终止，
    // 而是弹窗告诉你有几个人没设口令，确认后把他们移出、继续建加密频道。
    testWidgets('加密成员没口令 → 弹窗；取消则不建频道', (tester) async {
      late E2eeService e2ee;
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.Named.create': {'channel_id': 66},
        },
      );
      e2ee = h.container.read(e2eeServiceProvider);
      await e2ee.setup('flt-pass');
      await h.container.read(chatStoreProvider).upsertUsers([
        UserDto.fromJson(_userJson(id: 4, name: 'demo')),
      ]);
      await pump(tester, h);

      await tester.enterText(find.byType(TextField).first, '加密频道');
      await tester.tap(switchRowFinder);
      await tester.pumpAndSettle();
      await tester.tap(find.text('demo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建'));
      await _pumpBusy(tester);

      expect(find.textContaining('还没有设置端到端加密口令'), findsOneWidget);
      expect(find.text('通知他们去设置口令'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await _pumpBusy(tester);

      expect(
        _callsTo(h.transport, 'SYNO.Chat.Channel.Named', 'create'),
        isEmpty,
      );
      expect(
        _callsTo(h.transport, 'SYNO.Chat.User', 'notify_encrypt'),
        isEmpty,
      );
    });

    testWidgets('加密成员没口令 → 确定后把该成员移出并继续建频道', (tester) async {
      late E2eeService e2ee;
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.Named.create': {'channel_id': 66},
        },
      );
      e2ee = h.container.read(e2eeServiceProvider);
      await e2ee.setup('flt-pass');
      final other = E2eeService(_MemStore());
      final otherId = await other.setup('other-pass');
      await h.container.read(chatStoreProvider).upsertUsers([
        UserDto.fromJson(_userJson(id: 4, name: 'demo')),
        UserDto.fromJson(
          _userJson(id: 3, name: '有钥匙', publicKey: otherId.publicKey),
        ),
      ]);
      // 预置频道行，好让"把封给自己的 channel_key_enc 写回本地"有行可写
      await h.container.read(chatStoreProvider).upsertChannels([
        ChannelDto.fromJson({
          'channel_id': 66,
          'name': '加密频道',
          'type': 'private',
          'encrypted': true,
        }),
      ]);
      await pump(tester, h);

      await tester.enterText(find.byType(TextField).first, '加密频道');
      await tester.tap(switchRowFinder);
      await tester.pumpAndSettle();
      await tester.tap(find.text('demo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('有钥匙'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建'));
      await _pumpBusy(tester);

      expect(find.textContaining('1 位'), findsOneWidget, reason: '只有 demo 没口令');
      // 勾上「通知他们」再确定
      await tester.tap(find.text('通知他们去设置口令'));
      await _pumpBusy(tester);
      await tester.tap(find.text('确定'));
      await _pumpBusy(tester);

      final create = _callsTo(
        h.transport,
        'SYNO.Chat.Channel.Named',
        'create',
      ).single;
      expect(create['encrypted'], 'true');
      final invite = _callsTo(
        h.transport,
        'SYNO.Chat.Channel.Named',
        'invite',
      ).single;
      expect(jsonDecode(invite['user_ids'] as String), [
        3,
      ], reason: '没口令的 demo(4) 被移出，只有 3 留下来');
      final notify = _callsTo(
        h.transport,
        'SYNO.Chat.User',
        'notify_encrypt',
      ).single;
      expect(notify['version'], '1');
      expect(jsonDecode(notify['user_ids'] as String), [4]);
    });

    testWidgets('没勾「通知他们」→ 只把人移出，不调 notify_encrypt', (tester) async {
      late E2eeService e2ee;
      final h = await bootChat(
        extra: {
          'SYNO.Chat.Channel.Named.create': {'channel_id': 66},
        },
      );
      e2ee = h.container.read(e2eeServiceProvider);
      await e2ee.setup('flt-pass');
      final other = E2eeService(_MemStore());
      final otherId = await other.setup('other-pass');
      await h.container.read(chatStoreProvider).upsertUsers([
        UserDto.fromJson(_userJson(id: 4, name: 'demo')),
        UserDto.fromJson(
          _userJson(id: 3, name: '有钥匙', publicKey: otherId.publicKey),
        ),
      ]);
      // 预置频道行，好让"把封给自己的 channel_key_enc 写回本地"有行可写
      await h.container.read(chatStoreProvider).upsertChannels([
        ChannelDto.fromJson({
          'channel_id': 66,
          'name': '加密频道',
          'type': 'private',
          'encrypted': true,
        }),
      ]);
      await pump(tester, h);

      await tester.enterText(find.byType(TextField).first, '加密频道');
      await tester.tap(switchRowFinder);
      await tester.pumpAndSettle();
      await tester.tap(find.text('demo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('有钥匙'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建'));
      await _pumpBusy(tester);
      await tester.tap(find.text('确定'));
      await _pumpBusy(tester);

      final invite = _callsTo(
        h.transport,
        'SYNO.Chat.Channel.Named',
        'invite',
      ).single;
      expect(jsonDecode(invite['user_ids'] as String), [3]);
      expect(
        _callsTo(h.transport, 'SYNO.Chat.User', 'notify_encrypt'),
        isEmpty,
      );
    });
  });
}

/// 给"对方设备"用的内存键值存储
class _MemStore implements E2eeStore {
  final _map = <String, String>{};
  @override
  Future<String?> setting(String key) async => _map[key];
  @override
  Future<void> setSetting(String key, String value) async => _map[key] = value;
  @override
  Future<void> deleteSetting(String key) async => _map.remove(key);
}
