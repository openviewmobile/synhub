// ★★ **②聊天 第 45 轮：让 Mock 真正校验 Chat 方法名**（B1/B2 的「方法轴」）
//
// ## 修的是什么（一个一直在骗自己的弱断言）
//
// `catalog.json` 里 **36 个 `SYNO.Chat.*` 原本全是 `methods:{}` +
// `methodsVerified:false`** —— 来源是实况 `SYNO.API.Info` 快照，而那个接口
// **只返回 path/minVersion/maxVersion，不返回方法表**。
//
// 后果很具体：mock 对 Chat **完全不校验方法名**。
// `test/chat_api_coverage_mock_test.dart` 里那句
// 「所有请求过的 API 都是**目录内 + 无 101/103/105**」
// 因此是**弱断言** —— Chat 的 103 **永远不会出现**，
// 换句话说"没报错"根本没证明"方法名对"。
//
// ## 怎么修的
// 本机**没有 Chat Server 的 SPK**（`/tmp/spk/export_*` 里没有 Chat），
// 拿不到权威 `.lib`。可用的权威替代是**反编译记录**：
// `docs/rewrite-plan.md` 里有结构化表（`| SYNO.Chat.X | 版本 | 方法… |`），
// `docs/phase*-protocol.md` / `phase9-server-settings.md` 逐条标了官方 Java 类。
// `tool/mock_dsm/build_chat_methods.py` 据此生成并写回 `methodsVerified:true`。
//
// ⚠️ **过程中我自己踩了两个坑，都如实记在这儿**（因为不记就会再犯）：
//   1. 抽取正则写成 `[a-z_]+` 单方法形，文档里的
//      `Channel/hide\|show\|hide_global`（**转义竖线**）与
//      `| … | get set |`（**空格分隔**）都被截断
//      ⇒ 严格表把我方**正确**的 `Channel/hide`、`User.Preference/get`
//      误报成 103。**是表不全，不是代码错** —— 差点据此去"修"没坏的代码。
//   2. 放宽成"方法名连读"后，又把散文里的版本号吞进来
//      （`Channel` 表里混进 `v2`，`User` 里混进 `v1/v2/v3`）
//      ⇒ 那比不校验**更糟**（mock 会接受 `Channel/v2` 这种伪方法）。
//      现在用 `_METHOD_RE` + `_JUNK` 双重过滤。
//
// ## 本文件钉住什么
// * 29 个 Chat API 的 `methodsVerified` 必须是 **true**（防止悄悄退回不校验）；
// * 剩 7 个**一条证据都没有**的必须仍是 **false**（**不假装能校验没有数据的东西**）；
// * ★ **反证**：拿一个**拼错的方法名**打 Mock，必须**真回 103**
//   —— 这条才是"校验确实生效"的证据，光断言 `methodsVerified==true` 不够；
// * 我方需要的关键方法（`Channel/hide|show`、`User.Preference/get`、
//   `Channel.Preference/get`、`Post/stick|unstick`、`Post/get_read_status`）都在表里。
//
// 全程打**内存 Mock Server**，不碰真机（规程 §5.1）。
import 'package:flutter_test/flutter_test.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';

/// 本轮建立起方法表的 Chat API（文档有据）。
const List<String> kChatMethodTableApis = [
  'SYNO.Chat.Admin.Setting',
  'SYNO.Chat.Archive',
  'SYNO.Chat.Bot',
  'SYNO.Chat.Channel',
  'SYNO.Chat.Channel.Anonymous',
  'SYNO.Chat.Channel.Chatbot',
  'SYNO.Chat.Channel.GuestUser',
  'SYNO.Chat.Channel.Hashtag',
  'SYNO.Chat.Channel.Member',
  'SYNO.Chat.Channel.Named',
  'SYNO.Chat.Channel.Preference',
  'SYNO.Chat.Chatbot',
  'SYNO.Chat.External',
  'SYNO.Chat.Misc',
  'SYNO.Chat.Post',
  'SYNO.Chat.Post.Attachment',
  'SYNO.Chat.Post.File',
  'SYNO.Chat.Post.Hashtag',
  'SYNO.Chat.Post.Reaction',
  'SYNO.Chat.Post.Reminder',
  'SYNO.Chat.Post.Schedule',
  'SYNO.Chat.Post.Subscribe',
  'SYNO.Chat.Post.Vote',
  'SYNO.Chat.Sticker',
  'SYNO.Chat.User',
  'SYNO.Chat.User.Avatar',
  'SYNO.Chat.User.Preference',
  'SYNO.Chat.User.Status',
  'SYNO.Chat.Webhook.Slash',
];

/// **刻意保持不校验**的 Chat API：文档里一条方法证据都没有。
/// 「没有数据就不假装能校验」——这条比"全部 true 好看"重要。
const List<String> kChatNoMethodEvidence = [
  'SYNO.Chat.App',
  'SYNO.Chat.Channel.Hidden',
  'SYNO.Chat.Post.Snippet',
  'SYNO.Chat.Webhook.Broadcast',
  'SYNO.Chat.Webhook.BuiltIn',
  'SYNO.Chat.Webhook.Incoming',
  'SYNO.Chat.Webhook.Outgoing',
];

MockDsmBackend _backend() {
  final b = MockDsmBackend(catalog: DsmCatalog.load());
  b.login(username: 'u', admin: false); // 需要 sid，否则 `_sid` 无效
  return b;
}

/// 直接问后端要一个 catalog 里的 spec（用来读 `methodsVerified`/`methods`）。
DsmApiSpec _spec(MockDsmBackend b, String api) {
  final s = b.catalog[api];
  expect(s, isNotNull, reason: '$api 必须在 catalog 里');
  return s!;
}

void main() {
  group('CM-1. 方法表本身：有据的必须校验，没据的不许假装', () {
    test('★ 29 个有文档依据的 Chat API 必须 methodsVerified=true', () {
      final b = _backend();
      final missing = <String>[];
      final notVerified = <String>[];
      for (final api in kChatMethodTableApis) {
        final s = _spec(b, api);
        if (s.methods.isEmpty) {
          missing.add(api);
        } else if (!s.methodsVerified) {
          notVerified.add(api);
        }
      }
      expect(missing, isEmpty, reason: '$missing 没有方法表了');
      expect(
        notVerified,
        isEmpty,
        reason: '★ $notVerified 退回了「不校验方法名」——那会让"无 103"变成弱断言',
      );
    });

    test('★ 7 个没有方法证据的必须仍是 false（不假装能校验没有数据的东西）', () {
      final b = _backend();
      for (final api in kChatNoMethodEvidence) {
        final s = _spec(b, api);
        expect(
          s.methodsVerified,
          isFalse,
          reason: '$api 文档里没有任何方法证据，不该被标成"已校验"',
        );
      }
    });

    test('★ 方法名必须是干净的小写标识符（防止把散文里的 v2 当成方法）', () {
      final b = _backend();
      final junk = <String>[];
      final re = RegExp(r'^[a-z][a-z0-9_]*$');
      for (final api in kChatMethodTableApis) {
        for (final entry in _spec(b, api).methods.entries) {
          for (final m in entry.value) {
            if (!re.hasMatch(m)) junk.add('$api v${entry.key}: $m');
          }
        }
      }
      expect(
        junk,
        isEmpty,
        reason:
            '★ 混进 ${junk.take(6)} 这类伪方法会让 mock 接受 `Channel/v2`，'
            '比不校验更糟',
      );
    });

    test('★ 我方依赖的关键方法都在表里（这三个当年被我的正则漏过）', () {
      final b = _backend();
      void has(String api, String method) => expect(
        _spec(b, api).versionsWith(method),
        isNotEmpty,
        reason: '$api/$method 不在方法表里',
      );
      // 抽 `hide`/`show`/`hide_global` 时踩过「转义竖线」的坑
      has('SYNO.Chat.Channel', 'hide');
      has('SYNO.Chat.Channel', 'show');
      has('SYNO.Chat.Channel', 'hide_global');
      // `get set` 是**空格**分隔的表格写法
      has('SYNO.Chat.User.Preference', 'get');
      has('SYNO.Chat.User.Preference', 'set');
      has('SYNO.Chat.Channel.Preference', 'get');
      has('SYNO.Chat.Channel.Preference', 'set');
      // 版本门控的（`KNOWN_VERSION_GATES`）
      has('SYNO.Chat.Post', 'stick');
      has('SYNO.Chat.Post', 'unstick');
      has('SYNO.Chat.Post', 'get_read_status');
    });

    test('★ 版本门控真的生效：stick 不该在 v1 出现', () {
      final b = _backend();
      final post = _spec(b, 'SYNO.Chat.Post');
      expect(
        post.versionsWith('stick'),
        isNot(contains(1)),
        reason:
            '`docs/phase4-protocol.md` §5.1：话题内置顶是 **v2**（v1 写 last_pin_at）',
      );
      expect(post.versionsWith('stick'), contains(2));
    });
  });

  group('CM-2. ★★ 反证：方法名确实被校验了（这条才是硬证据）', () {
    test('★★ 拼错的方法名 → **真的回 103**（以前 Chat 永远不会 103）', () {
      final b = _backend();
      final r = b.handle('entry.cgi', {
        'api': 'SYNO.Chat.Post',
        'method': 'createXYZ', // 拼错
        'version': 5,
        '_sid': b.sessions.first,
      });
      expect(r.errorCode, 103, reason: '★ 这正是本轮之前**做不到**的事；能回 103 才证明校验生效');
    });

    test('★ 反证的方法真的错了：正确的 `create` 必须成功（排除"什么都 103"）', () {
      final b = _backend();
      final r = b.handle('entry.cgi', {
        'api': 'SYNO.Chat.Post',
        'method': 'create',
        'version': 5,
        '_sid': b.sessions.first,
      });
      expect(
        r.errorCode,
        isNot(103),
        reason: '如果 `create` 也 103，那说明我的表根本没生效（恒真断言）',
      );
    });

    test('★ 版本门控也算数：`stick` 打到 v1 → 103', () {
      final b = _backend();
      final r = b.handle('entry.cgi', {
        'api': 'SYNO.Chat.Post',
        'method': 'stick',
        'version': 1,
        '_sid': b.sessions.first,
      });
      expect(r.errorCode, 103, reason: 'stick 从 v2 才有');
    });

    test('★ 没有方法表的 API 仍然不校验（诚实的边界）', () {
      final b = _backend();
      final r = b.handle('entry.cgi', {
        'api': 'SYNO.Chat.Post.Snippet', // 刻意无证据
        'method': 'thisIsNotAMethod',
        'version': 1,
        '_sid': b.sessions.first,
      });
      expect(
        r.errorCode,
        isNot(103),
        reason: '没数据就不假装能校验 —— 这条是**已知边界**，不是 bug',
      );
    });
  });
}
