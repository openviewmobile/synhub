// 226（M74）WebDAV 批次新增文案：**key + 中文原文**，与
// `filestation_g4_text.dart` / `filestation_p0b_text.dart` 同构。
// key 已同步追加进 `lib/l10n/app_zh.arb` / `app_en.arb`。
import '../../core/i18n/data_text.dart';

/// 取 WebDAV 文案
String fsWebDav(String key, String zh) => dataText(key, zh);

/// 带 `{...}` 占位符的文案填充
String fsWebDavFill(String key, String zh, Map<String, String> values) {
  var out = fsWebDav(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// WebDAV 批次新增的 ARB key
abstract final class FsWebDavTextKeys {
  static const title = 'fsWebDavTitle';
  static const entry = 'fsWebDavEntry';
  static const entryDescription = 'fsWebDavEntryDescription';
  static const host = 'fsWebDavHost';
  static const hostHint = 'fsWebDavHostHint';
  static const port = 'fsWebDavPort';
  static const account = 'fsWebDavAccount';
  static const password = 'fsWebDavPassword';
  static const secure = 'fsWebDavSecure';
  static const secureHint = 'fsWebDavSecureHint';
  static const connect = 'fsWebDavConnect';
  static const connecting = 'fsWebDavConnecting';
  static const missingHost = 'fsWebDavMissingHost';
  static const deprecated = 'fsWebDavDeprecated';
  static const readOnly = 'fsWebDavReadOnly';
  static const empty = 'fsWebDavEmpty';
  static const emptyBody = 'fsWebDavEmptyBody';
  static const error = 'fsWebDavError';
  static const capability = 'fsWebDavCapability';
  static const path = 'fsWebDavPath';
  static const up = 'fsWebDavUp';
  static const notConnected = 'fsWebDavNotConnected';
  static const server = 'fsWebDavServer';
}
