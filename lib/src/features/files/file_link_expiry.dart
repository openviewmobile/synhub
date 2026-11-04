// 分享链接「到期时间」的上线格式（纯函数，便于单测）。
//
// ★ 第 306 轮取证（两处一级来源 + 一次真机实证）：
//
// 1. 官方 Web 客户端（FileStation 1.5.1-2410 的 `ui/file_browser/FileBrowser.js`，
//    分享对话框）提交前**逐字**是：
//    ```js
//    t.expire_at = this.expireDateTimeField.getValue().format("Y-m-d H:i:s");
//    ```
//    全文里 `Y-m-d H:i:s` 出现 10 次，`Y-m-d`（不带时刻）**一次都没有**。
// 2. 服务端 `webapi/SYNO.FileStation.Sharing.so` 里两种解析格式都在：
//    `%Y-%m-%d`、`%Y-%m-%d %H:%M:%S`，还有
//    `"%s:%d Failed to convert input time to tm struct"`。
// 3. 真机实证（DSM 7.4.1-90080，r306）：**只发日期**（`2026-10-15`）时，
//    建出来的链接在服务端是「永久」—— 连做两次（「1 天」「7 天」）都一样，
//    而同一批请求里的**密码**却真的生效了（详情里 `has_password` 由有→没有）。
//    ⇒ 日期字段被静默忽略/丢弃，密码字段正常。
//
// ★★★ 第 318 轮真机**推翻**了上面第 3 条的处置：
//
// 真机（LGE-AN10 / DSM，包 sha `871d8e6b…`）两条独立路径都复现同一现象：
//   ① 创建面板选「7 天」→ 详情仍 `Valid until: Permanent`；
//   ② 管理页 `Edit share link` 选「30 days」→ Save → 详情**仍是** `Permanent`。
// 而详情读的是服务端 `Sharing/getinfo`（列表行 `Sharing/list` 同样没有到期时间）
// ⇒ **服务端根本没存这个到期时间**，不是显示问题（`expiryKnown=true` + 值为空）。
//
// 再看服务端 `SYNO.FileStation.Sharing.so` 的字符串：`%04d-%02d-%02d`、
// `" 00:00:00"`、`" 23:59:59"` —— 服务端**自己**会按日期补时刻（起=00:00:00、
// 止=23:59:59）；而官方**安卓 APK**（我们对齐的对象）发的是
// `DateUtils.DATE_FORMAT_LOCALE` = **`yyyy-MM-dd`（只发日期）**。
// ⇒ 上线格式改成**只发日期**（`yyyy-MM-dd`），交给服务端补 23:59:59。
//
// ⚠️ 第 318 轮真机复验结论：**换成官方安卓格式后仍然不生效**。四种报文形状
// 全部试过（① 带时刻；② 只发日期；③ 补官方 Web 的 `start_at:''`+`expire_times:0`；
// ④ 再补 `.so` 内部名 `expire_at` 与起始日 `date_available`）——
// 创建与编辑两条路径服务端都回"没有到期时间"（`list`/`getinfo` 一致）。
// 同一条请求里的**密码**却真的生效 ⇒ 请求确实到达并被执行，是**日期这一项**
// 被服务端丢掉。本包保持"官方安卓 APK 逐字形状"（`yyyy-MM-dd`），
// 缺口与全部读数记在 `docs/evidence-r316/README.md` D15 与
// `docs/device-verification.md` §3.7；**没有**继续堆猜测性字段。
library;

/// `YYYY-MM-DD`（只发日期；服务端按 `" 23:59:59"` 自行补成当天结束）。
///
/// [days] ≤ 0 = 永久 ⇒ 返回 `null`（**不发这个字段**，官方同样只在勾选时发）。
///
/// ★ 格式依据：官方安卓 APK `DateUtils.DATE_FORMAT_LOCALE` = `yyyy-MM-dd`
/// （`WebApiConnectionManager.createShareLinkV3/editShareLinkV3` 直接发它）；
/// 服务端 `.so` 里 `%Y-%m-%d` 与 `%Y-%m-%d %H:%M:%S` **两种都在**，且自带
/// `" 23:59:59"` 后缀 ⇒ 只发日期是官方语义。
String? shareLinkExpiryWire(DateTime now, int days) {
  if (days <= 0) return null;
  return shareLinkDateWire(now.add(Duration(days: days)));
}

/// 同一个线上格式的"裸日期"版本（`YYYY-MM-DD`）—— 起始/结束共用同一格式。
String shareLinkDateWire(DateTime day) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${day.year.toString().padLeft(4, '0')}-${two(day.month)}-'
      '${two(day.day)}';
}
