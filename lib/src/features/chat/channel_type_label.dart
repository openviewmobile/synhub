// 频道 `type`（服务端枚举）→ **用户词汇**。
//
// ★★ r344 D55：真机 `聊天` 列表逐字 `public · 3 人`，`频道管理` 弹层逐字
//   `public · 本地 28 条消息` —— `ChannelDto.type` 是内部枚举
//   （`public`/`private`/`anonymous`/`chatbot`/`synobot`），却被**原样印成用户文案**。
//   这是 D47「运行时值当文案」家族的第 **7** 处（D51/D52 是第 1–5 处、D54 是第 6 处）。
//
// 判据（§2.0.26「钉生产者」）：`type` 的渲染点**只有两处** ——
//   * `channel_row.dart` 的 `channelRowSubtitle()`（列表行副标题首段）
//   * `channel_manage_sheet.dart` 的弹层副标题
//   守卫 `test/channel_type_label_test.dart` 直接扫这两个文件（不许再出现裸 `.type` 插值），
//   并拿 `channel_dto.dart` 扫出 token 清单逐条断言"标签 ≠ token"。
//
// ★ 与 `connectSourceLabel`（D54）/`objectTypeLabel`（D47）同一套写法：查不到就回**通用名词**
//   「频道」（一句话，不宣称某具体类型），**永不**把 token 原样返回。
//
// ★ 官方依据：`Android-SynologyChat.2.11.1-607.ww.apk` 的资源里
//   `private_channel` = 「私人頻道」/「专用频道」，`channel` = 「频道」；
//   官方**没有**任何把 `public`/`private` 这种裸 token 当文案的字符串
//   （aapt2 + apktool `-s` 解出的 `res/values*/strings.xml` 全量核对过）。
import 'package:synhub/src/core/i18n/l10n.dart';

/// `type` → 用户文案。新增 token 必须同时登记进 [kChannelTypeTokens]（守卫会查）。
String channelTypeLabel(String type, AppText t) {
  switch (type.trim().toLowerCase()) {
    case 'public':
      return t.chatTypePublic;
    case 'private':
      return t.chatTypePrivate;
    case 'anonymous':
      return t.chatTypeAnonymous;
    case 'chatbot':
    case 'synobot':
      // 两个 token 都是"机器人会话"（官方 `isChatBot()` 只看 chatbot，synobot 是官方机器人）
      return t.chatTypeBot;
    default:
      // 兜底给**通用名词**而不是原样 token：`''`（服务端没给类型）与未知枚举都落这里。
      return t.chatChannel;
  }
}

/// 已知 token（守卫的非空判据；改这里必须同步 [channelTypeLabel]）。
const List<String> kChannelTypeTokens = <String>[
  'public',
  'private',
  'anonymous',
  'chatbot',
  'synobot',
];
