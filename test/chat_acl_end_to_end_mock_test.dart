// ★★ **ACL 门控的「服务端 → 解析 → UI」端到端 Mock 验证**
// —— ②聊天 审计行 **244/245/246/247**（规则 B2）。
//
// ## 为什么要有这个文件（现有测试缺哪一环）
//
// 既有 `test/chat_acl_gate_test.dart`（9 条）验的是**门控逻辑本身**：它用
// `_setAcl(h, {...})` 把 ACL **直接塞进 provider**，然后断言界面。
// 那一环确实覆盖了，但**跳过了两段**：
//
// ```
//   SYNO.Chat.Misc/acl  →  fetchAcl() 解析  →  myAclProvider.apply()  →  UI 门控
//   └──── ① 没测 ────┘   └── ② 没测 ──┘        └─── 既有测试从这里开始 ───┘
// ```
//
// 而审计行 244-247 记的缺口正是「离线只覆盖本地逻辑」「需一个该键为 `false`
// 的真实 ACL 账号」。用户 2026-09-23 新规 B2：
// **「真机/真 NAS 无法验证的也一律通过 Mock Server 验证」**。
//
// ⇒ 本文件把整条链**从 Mock 服务端开始**跑通：
//   服务端回**真机逐字的 14 键 ACL** → 真的 `fetchAcl()` → 真的 `apply()`
//   → 断言界面按权限渲染。
//
// ## 数据出处（**不是我编的形状**）
// * **14 个键名与取值**：真机只读探针逐字记录
//   `docs/device-verification.md:455-458`（LGE AN10 / API 31）：
//   ```
//   {channel_kick: true, channel_set: true, channel_invite: true,
//    channel_join: true, channel_create: true, channel_close: true,
//    channel_archive: true, channel_anonymous: true, channel_disjoin: true,
//    channel_public: true, channel_encryption: true, webhook_create: true,
//    webhook_read: true, guest_manage: false}
//   ```
// * **线上数组包装** `{acls:[{acl_name, allow}]}`：反编译 APK 的解析代码
//   （见 `chat_api.dart:702-719` 对 `AccountManager.fetchAcl` 的记录）。
// * 同一份数据也落成了夹具 `tool/mock_dsm/fixtures/SYNO.Chat.Misc.acl.json`。
//
// ## 不做什么
// 不碰真机、不碰真 NAS（§5.1）。只读动词 `acl`。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/settings/acl.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/channel_create_page.dart';
import 'package:synhub/src/features/chat/channel_list_page.dart';

import 'dart:io';

import '../tool/mock_dsm/mock_dsm_core.dart';
import '../tool/mock_dsm/mock_dsm_server.dart';
import 'support/chat_harness.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/mock_dsm_transport.dart';
import 'support/switch_rows.dart';

/// 真机 14 键 ACL —— **逐字**来自 `docs/device-verification.md:455-458`。
const Map<String, bool> kRealDeviceAcl = {
  'channel_kick': true,
  'channel_set': true,
  'channel_invite': true,
  'channel_join': true,
  'channel_create': true,
  'channel_close': true,
  'channel_archive': true,
  'channel_anonymous': true,
  'channel_disjoin': true,
  'channel_public': true,
  'channel_encryption': true,
  'webhook_create': true,
  'webhook_read': true,
  'guest_manage': false,
};

/// 真机解析后的 map ⇒ **线上数组形状**（APK `fetchAcl` 解析的那种）。
Map<String, dynamic> wireAcl(Map<String, bool> acl) => {
  'acls': [
    for (final e in acl.entries) {'acl_name': e.key, 'allow': e.value},
  ],
};

void main() {
  late DsmCatalog catalog;
  late MockDsmBackend backend;
  late MockDsmTransport transport;
  late DsmWebApi web;
  late ChatApi chat;

  /// [acl] 非空时用它当服务端 ACL 回包；为 null 时**回空表**（老服务器场景）。
  Future<void> boot({Map<String, bool>? acl}) async {
    catalog = DsmCatalog.load();
    backend = MockDsmBackend(catalog: catalog);
    backend.login(username: 'u', admin: false);
    if (acl != null) {
      backend.fixture('SYNO.Chat.Misc', 'acl', (_) {
        return {'success': true, 'data': wireAcl(acl)};
      });
    }
    transport = MockDsmTransport(backend);
    web = DsmWebApi(transport);
    await web.discover();
    await web.login(account: 'u', password: 'x');
    chat = ChatApi(web);
  }

  setUp(boot);

  group('AE-1. ★ 从 Mock 服务端拉 ACL（链路的第①②环，既有测试没覆盖）', () {
    test('★ 真机 14 键回包能解析成 14 条（一条不丢）', () async {
      await boot(acl: kRealDeviceAcl);
      final got = await chat.fetchAcl();
      expect(got, hasLength(14), reason: '14 键必须全解析出来');
      expect(got.keys.toSet(), kRealDeviceAcl.keys.toSet());
      // 逐个键值都对
      for (final e in kRealDeviceAcl.entries) {
        expect(got[e.key], e.value, reason: '${e.key} 的值解析错了');
      }
    });

    test('★ 真机上那个唯一的 false（`guest_manage`）**真的**解析成 false', () async {
      await boot(acl: kRealDeviceAcl);
      final got = await chat.fetchAcl();
      expect(got['guest_manage'], isFalse);
      // 对照组：其余 13 个都是 true —— 证明不是"全 false"
      expect(got.values.where((v) => v).length, 13);
    });

    test('★ 请求形状：`SYNO.Chat.Misc` / `acl` / v1，无业务参数', () async {
      await boot(acl: kRealDeviceAcl);
      await chat.fetchAcl();
      final r = backend.requests.last;
      expect(r.params['api'], 'SYNO.Chat.Misc');
      expect(r.params['method'], 'acl');
      expect('${r.params['version']}', '1');
    });

    test('★ 老服务器回空表 ⇒ 空 map（不报错，交给 fail-open 兜底）', () async {
      await boot();
      expect(await chat.fetchAcl(), isEmpty);
    });

    test('★ 夹具文件与代码里的真机常量**一致**（防止两处漂移）', () {
      // 把 `tool/mock_dsm/fixtures/` 装进一台**干净后端**，再按真实路径取一次 ——
      // 这比"直接读文件"更严：它同时验证了夹具**能被 installInto 正确解析**。
      final b = MockDsmBackend(catalog: catalog);
      b.login(username: 'u', admin: false);
      final loaded = MockDsmFixtureStore(
        Directory('tool/mock_dsm/fixtures'),
      ).installInto(b);
      expect(loaded, greaterThan(0), reason: '夹具目录里应当有可加载的夹具');
      final resp = b.handle('entry.cgi', {
        'api': 'SYNO.Chat.Misc',
        'method': 'acl',
        'version': 1,
        '_sid': b.sessions.first,
      });
      final data = (resp.json['data'] as Map).cast<String, dynamic>();
      final got = <String, bool>{
        for (final raw in (data['acls'] as List))
          '${(raw as Map)['acl_name']}': raw['allow'] == true,
      };
      expect(got, kRealDeviceAcl, reason: '夹具与真机常量必须逐键一致');
      // 且 `_source` / `_note` **没有**混进服务端返回数据
      expect(data.keys.any((k) => k.startsWith('_')), isFalse);
    });
  });

  group('AE-2. ★ 端到端：应用**启动路径**拉 ACL → provider → UI 真的按权限渲染', () {
    // ⚠️ 这一组**必须**用 `bootChat()`（`test/support/chat_harness.dart`）：
    // 它用**内存 Drift**覆盖了 `chatDatabaseProvider`。
    // 我一开始用裸 `ProviderContainer()`，结果挂到超时 —— 因为
    // `myAclProvider.apply()` 会写 `settingsServiceProvider`，
    // 而裸容器没有数据库覆盖 ⇒ 初始化永远不完成。
    // `bootChat()` 内部会 `await ctrl.start(conn)`，而 `_loadAcl()` 正是
    // `start()` 里调用的（`chat_session_controller.dart:427`）⇒
    // **ACL 是在真实启动路径上被拉取并 apply 的**，不是我手工塞的。
    Future<ChatHarness> bootWithAcl(Map<String, bool> acl) =>
        bootChat(extra: {'SYNO.Chat.Misc.acl': wireAcl(acl)});

    bool has(ProviderContainer c, String n) => c.read(myAclProvider)[n] ?? true;

    test('★ 真机那份 ACL（13 true + guest_manage false）经启动路径落地', () async {
      final h = await bootWithAcl(kRealDeviceAcl);
      final c = h.container;
      expect(c.read(myAclProvider), hasLength(14), reason: '14 键都该进 provider');
      expect(has(c, kAclGuestManage), isFalse, reason: '真机唯一的 false');
      expect(has(c, kAclChannelCreate), isTrue);
      expect(allowsPublicChannels((n) => has(c, n)), isTrue);
      expect(has(c, kAclChannelEncryption), isTrue);
      expect(has(c, kAclChannelAnonymous), isTrue);
    });

    test(
      '★ `channel_public=false` ⇒ 服务端说了算，`allowsPublicChannels` 变 false',
      () async {
        final h = await bootWithAcl({
          ...kRealDeviceAcl,
          'channel_public': false,
        });
        expect(allowsPublicChannels((n) => has(h.container, n)), isFalse);
      },
    );

    test(
      '★ `channel_join=false` 而 `channel_public=true` ⇒ 仍 false（AND 语义）',
      () async {
        final h = await bootWithAcl({...kRealDeviceAcl, 'channel_join': false});
        expect(
          allowsPublicChannels((n) => has(h.container, n)),
          isFalse,
          reason: 'join 与 public 是 AND',
        );
      },
    );

    test('★ 老服务器（无 ACL 回包）⇒ fail-open，功能**不被锁死**', () async {
      final h = await bootChat(); // 不给 SYNO.Chat.Misc.acl 夹具
      final c = h.container;
      expect(c.read(myAclProvider), isEmpty);
      expect(has(c, kAclChannelCreate), isTrue, reason: '查不到即允许');
      expect(allowsPublicChannels((n) => has(c, n)), isTrue);
      expect(has(c, kAclChannelEncryption), isTrue);
      expect(has(c, kAclChannelAnonymous), isTrue);
    });

    testWidgets('★ `channel_encryption=false` ⇒ 建频道页的加密开关**整块消失**', (
      tester,
    ) async {
      final h = await bootWithAcl({
        ...kRealDeviceAcl,
        'channel_encryption': false,
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: ChannelCreatePage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        switchRowFinder,
        findsNothing,
        reason: 'ACL 说没有 channel_encryption ⇒ 开关不该渲染',
      );
    });

    testWidgets('★ 对照组：真机那份（encryption=true）⇒ 开关在', (tester) async {
      final h = await bootWithAcl(kRealDeviceAcl);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: ChannelCreatePage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(switchRowFinder, findsOneWidget);
    });

    testWidgets('★ `channel_anonymous=false` ⇒ 频道列表页仍能渲染（门控读真值不炸）', (
      tester,
    ) async {
      final h = await bootWithAcl({
        ...kRealDeviceAcl,
        'channel_anonymous': false,
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: ChannelListPage()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(has(h.container, kAclChannelAnonymous), isFalse);
    });
  });

  group('AE-3. §5.1：全程只读', () {
    test('★ 本文件只发 `acl`（只读），没有任何变更动词', () async {
      await boot(acl: kRealDeviceAcl);
      await chat.fetchAcl();
      // `getinfo` = `SYNO.API.Encryption/getinfo`（取登录公钥），只读
      const readOnly = {'acl', 'getinfo', 'Query', 'Login', 'login'};
      for (final r in backend.requests) {
        expect(
          readOnly,
          contains('${r.params['method']}'),
          reason: '出现了非只读方法 ${r.params['method']}',
        );
      }
    });
  });
}
