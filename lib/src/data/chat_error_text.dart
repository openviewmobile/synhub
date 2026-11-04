// 聊天 wave1（`SYNO.Chat.Post.Reaction` / `Vote` / `Reminder` / `Schedule` /
// `Subscribe` / `Hashtag`）的错误码 → 用户文案。
//
// ## 为什么要单独一份
//
// `SYNO.Chat.*` 的错误码体系与 DSM 的 `SYNO.API.Auth` **不是一套**：
//   * DSM 的 `401` 是 `WEBAPI_AUTH_ERR_ACCOUNT_DISABLED`（账号已停用）、
//     `402` 是权限被拒、`403` 是需要两步验证码、`407` 是尝试次数过多、
//     `102` 是"API 不存在"；
//   * 聊天侧同名码语义**未取证或明显不同**：
//       - 缺参探测（`docs/chat-api-wire.md` §4）：Reaction set/delete → `402`；
//         Vote create/set/delete → `401/402`；Reminder list → `401`、get → `402`；
//         Schedule list/create → `401`；Subscribe / Hashtag → `402`；
//       - 真机补测（`docs/chat-api-wire.md` **附录 A**）：
//         `Post/list` 缺 `channel_id` → **`403 {"errors":"no such channel"}`**
//         （不是 DSM 的 OTP），且 **`102` 在聊天里可能只是"对象找不到"、
//         不等于"API 不存在"**；缺/错 `_sid` → `119`（不是 401）。
//
// 反编译的 `ApiException.java` 里 `sChatMap` 只在**少数 API** 上生效
// （`SYNO.Chat.Post.Reaction` / `SYNO.Chat.Post.Hashtag` / `SYNO.Chat.Post`…），
// **不含** `Post.Vote` / `Post.Reminder` / `Post.Schedule` / `Post.Subscribe`——
// 这几个 API 的任意错误码在官方实现里都回落到 `sApiMap[100]`（通用未知错误）。
//
// 所以本文件的硬规则：**语义未取证的同名码一律不猜文案**，
// 也不套用 `DsmErrorCode` 的登录码/通用码说法，统一走「未知错误 + 原始码」。
// 其余错误码才交给 [DsmErrorCode.describe]（它自己分得清 `SYNO.Chat.*` 表）。
//
// ⚠️ `403` 回包里的 `errors` 文字只作**诊断**，**绝不上屏原文**。
library;

import '../core/i18n/data_text.dart';
import '../dsm/webapi.dart';

/// `SYNO.Chat.*` 里**语义未取证 / 与 DSM 同名不同义**的错误码。
///
///   * `102` —— 聊天里可能只是"对象找不到"，**不等于** DSM 的"API 不存在"
///     （真机附录 A；门控不能用它判 `apiNotFound`）；
///   * `401` —— 聊天侧不是 DSM 的"账号已停用"；
///   * `402` —— 聊天侧不是 DSM 的"权限被拒"；
///   * `403` —— 聊天侧是"no such channel"，不是 DSM 的"需要两步验证码"；
///   * `407` —— 聊天侧与 `SYNO.API.Auth` 的"尝试次数过多"同名不同义。
const Set<int> chatUnverifiedErrorCodes = {102, 401, 402, 403, 407};

/// 聊天 wave1 操作的异常 → 可读文案。
///
/// 未取证码走「未知错误（{code}）」通用提示，**绝不编造语义**。
String describeChatWave1Error(Object error) {
  if (error is! DsmApiException) return '$error';
  if (chatUnverifiedErrorCodes.contains(error.code)) {
    return dataText(
      'chatErrUnknownCode',
      '未知错误（{code}）',
    ).replaceAll('{code}', '${error.code}');
  }
  return DsmErrorCode.describe(error.code, method: error.method);
}
