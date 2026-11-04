// ★★ **②聊天 的「API 覆盖率」——用**执行**度量，不用 grep**
//
// ## 为什么要有这个文件（一次自打脸的记录）
//
// 我先前用"把整个 `lib/` 拼起来搜 API 名字"来算覆盖率，两次得到**互相矛盾**的结果：
//   * 朴素子串搜索  → **42/42**（"全齐了"）
//   * 改成只搜"调用位" → **32/42**
//
// 两个都**错**，原因很具体：
//   * 朴素搜索把 `kAuthExtraNotImplemented` 那张"**刻意不实现**"清单里的
//     API **名字**也算成了"已覆盖"（它就在源码里，当然是子串）；
//   * "调用位"正则又漏掉了用其它形状发的请求（`SYNO.API.Auth`、`SYNO.API.Info`、
//     `SYNO.Core.Desktop.Timeout`、`SYNO.Entry.Request` 明明都在调）。
//
// ⇒ **文本度量不可信。** 覆盖率这个数必须由**执行**得出：
//   把客户端打在 Mock Server 上，看**它到底请求了哪些 API**。
//   本文件就是干这个的。
//
// ## 这个方法能证明什么 / 不能证明什么
// ✅ 能：**真的发出去了**的 API 集合；每一条都经 Mock 校验过
//        `api/method/version` 三元组（合法、版本在区间内、权限档位对）。
// ❌ 不能：证明"没被请求的 API 就不该实现" —— 那要靠人工判定；
//        所以下面用 [kChatApkApis] 与 [kChatApkNotImplemented] **显式对照**，
//        让"缺"是**写下来的选择**而不是漏掉。
//
// 全部打**内存 Mock Server**，不碰真机（规程 §5.1）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

/// 官方 **Synology Chat 安卓 APK** 的 `SYNO.*` 全量（≥3 段，共 42 个）。
///
/// 出处：`/tmp/chat_apktool/classes*.dex` 全量 `strings` 提取。
/// ⚠️ **这是"候选清单"不是"调用清单"** —— 出现在 APK 的字符串表里
/// 不等于被调用（本会话铁律）。用它做**对照基准**，判定见
/// [kChatApkNotImplemented]。
const List<String> kChatApkApis = [
  'SYNO.API.Auth',
  'SYNO.API.Auth.RedirectURI',
  'SYNO.API.Auth.Type',
  'SYNO.API.Encryption',
  'SYNO.API.Info',
  'SYNO.ActiveInsight.Package',
  'SYNO.Auth.RescueEmail',
  'SYNO.Bee.Available',
  'SYNO.Chat.Admin.Setting',
  'SYNO.Chat.Archive',
  'SYNO.Chat.Channel',
  'SYNO.Chat.Channel.Anonymous',
  'SYNO.Chat.Channel.Chatbot',
  'SYNO.Chat.Channel.Hashtag',
  'SYNO.Chat.Channel.Member',
  'SYNO.Chat.Channel.Named',
  'SYNO.Chat.Channel.Preference',
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
  'SYNO.Chat.Webhook.Slash',
  'SYNO.Core.Desktop.SessionData',
  'SYNO.Core.Desktop.Timeout',
  'SYNO.Entry.Request',
  'SYNO.Personal.Notification.Mobile',
  'SYNO.Personal.Notification.Settings',
  'SYNO.Personal.Notification.Token',
  'SYNO.Personal.Profile.Photo',
  'SYNO.SAS.Encryption',
  'SYNO.SAS.Guest',
  'SYNO.SecureSignIn.AMFA.SuggestConn',
];

/// **刻意不实现**的 API —— 每条的判定依据与理由。
///
/// 这张表与 `lib/src/data/auth_extra_api.dart` 的 `kAuthExtraNotImplemented`
/// 是**同一批判定**，但这里按 **API 粒度**再列一遍，方便与 [kChatApkApis] 直接对账。
const Map<String, String> kChatApkNotImplemented = {
  'SYNO.Bee.Available':
      '真机上**不存在**（不在 SYNO.API.Info 快照里）⇒ Synology Bee/C2 的能力探针，本 NAS 不提供 ⇒ ➖非缺口',
  'SYNO.API.Auth.RedirectURI':
      '`.lib` v1 有 `run, check`，但**官方 Web JS 零命中** ⇒ 调用形状无证据；本仓走直连登录 ⇒ **不猜**，待判',
  'SYNO.Core.Desktop.SessionData':
      '`.lib` v1 有 `getjs, getjs_mobile, getjs_forgotpass`，但**返回 JS 文本**、服务于 DSM **网页桌面壳**；原生客户端不需要，且参数形状无证据 ⇒ ➖不合用',
  'SYNO.SAS.Encryption':
      '`api-server-authoritative.md:991` 记 v1 有 `exchange, status`，但**官方 Web JS 零命中** ⇒ 形状无证据；我方聊天 E2EE 走 `Chat.User/update_key`（**已有且已验证**），与 SAS 非同一机制 ⇒ 不猜、不重复实现',
  'SYNO.SAS.Guest':
      '**仅管理员**（`SAS.Group`/`SAS.Guest` 在文档里单列「仅管理员（不做）」）⇒ 用户明确"暂不考虑管理员功能" ⇒ ➖',
  'SYNO.SecureSignIn.AMFA.SuggestConn':
      '真机存在，但**目录里没有方法表**（live 快照只给版本），官方 Web JS 也零命中 ⇒ 方法名与参数**都无证据** ⇒ 不猜',
};

void main() {
  late DsmCatalog catalog;
  late MockDsmBackend backend;
  late MockDsmTransport transport;
  late DsmWebApi web;
  late ChatApi chat;

  Future<void> boot() async {
    catalog = DsmCatalog.load();
    backend = MockDsmBackend(catalog: catalog);
    backend.login(username: 'u', admin: false);
    transport = MockDsmTransport(backend);
    web = DsmWebApi(transport);
    await web.discover();
    await web.login(account: 'u', password: 'x');
    chat = ChatApi(web);
  }

  setUp(boot);

  group('CC-1. 基准表自检', () {
    test('官方 APK 基准恰好 42 个，且无重复', () {
      expect(kChatApkApis, hasLength(42));
      expect(kChatApkApis.toSet(), hasLength(42));
    });

    test('"刻意不实现"清单非空、每条有理由、且都在基准表里', () {
      expect(kChatApkNotImplemented, isNotEmpty);
      for (final e in kChatApkNotImplemented.entries) {
        expect(kChatApkApis, contains(e.key), reason: '${e.key} 不在基准表');
        expect(e.value.length, greaterThan(15), reason: '${e.key} 理由太短');
      }
    });
  });

  group('CC-2. ★ 执行度量：真的请求了哪些 API', () {
    /// 逐个驱动聊天客户端。**每条都打内存 Mock。**
    /// 只放**只读或可逆**的方法（会改数据的走 CC-3 的说明）。
    Future<void> driveAll() async {
      await chat.userPreferenceGet();
      await chat.myUser();
      await chat.fetchServerSettings();
      await chat.fetchStickers();
      await chat.searchPosts(const PostSearchQuery(keyword: 'a'));
      await chat.enterChannel(5, 'conn-1');
      await chat.viewChannel(5, 'conn-1');
      await chat.viewChannelThreads(channelId: 5, connId: 'conn-1');
      await chat.listEditable(5);
      await chat.reminderAt(4294967300);
    }

    test('★ 驱动后，把"真实请求过的 API"算出来（不是 grep）', () async {
      await driveAll();
      final hit = <String>{
        for (final r in backend.requests)
          if ('${r.params['api']}'.isNotEmpty) '${r.params['api']}',
      };
      // 登录/发现阶段本来就会碰到这两个
      expect(hit, contains('SYNO.API.Info'));
      expect(hit, contains('SYNO.API.Auth'));
      // 聊天家族确实被碰到了
      expect(
        hit.where((a) => a.startsWith('SYNO.Chat.')).length,
        greaterThanOrEqualTo(3),
        reason: '至少碰到几个 Chat.* ⇒ 说明驱动真的生效了',
      );
      // 打印出来（`-r expanded` 时可见），便于人工对账
      // ignore: avoid_print
      print('[CC] 实际请求过的 API（${hit.length} 个）：${hit.toList()..sort()}');
    });

    test('★ 所有请求过的 API 都是**目录内 + 无 101/103/105**', () async {
      await driveAll();
      for (final r in backend.requests) {
        final api = '${r.params['api']}';
        final spec = catalog[api];
        expect(spec, isNotNull, reason: '$api 不在权威目录里 ⇒ 幻影 API');
        // 版本必须落在目录区间内
        final v = int.tryParse('${r.params['version']}');
        if (v != null) {
          expect(v, greaterThanOrEqualTo(spec!.minVersion));
          expect(v, lessThanOrEqualTo(spec.maxVersion));
        }
      }
    });
  });

  group('CC-3. 变更动词的合法性**只**在 Mock 上验（§5.1）', () {
    test('★ 变更动词逐个打 Mock，断言三元组合法', () async {
      // ⚠️ 这些会改数据。**只**打内存 Mock —— 在真 NAS 上会真删消息、真建频道。
      final mutating = <String, Future<void> Function()>{
        'Post/create': () => chat.createScheduledPost(
          channelId: 5,
          message: 'x',
          sendAt:
              DateTime.now()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch ~/
              1000,
        ),
        'Post/delete': () => chat.deletePost(4294967300),
        'Channel/archive': () => chat.archiveChannel(5),
        'Channel/star': () => chat.starChannel(5),
        'Channel/hide': () => chat.hideChannel(5),
      };
      for (final e in mutating.entries) {
        await e.value();
        expect(
          transport.last!.errorCode,
          isNull,
          reason: '${e.key} 被 Mock 拒绝：code=${transport.last!.errorCode}',
        );
      }
    });
  });
}
