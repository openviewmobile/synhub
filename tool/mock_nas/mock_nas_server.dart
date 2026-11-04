// 本地 Mock NAS 服务器 —— 在没有 NAS 口令、不动真机的前提下，验证两件事：
//
//   ① 「会话失效」路径（`sessionExpired`，DSM 错误码 **119**）；
//   ② 「服务端未提供该服务」时的**降级**（能力表 `SYNO.API.Info` 缺 API）。
//
// 设计目标（对齐 `docs/service-availability-design.md` §6 方案 B 与
// `docs/device-batch-r5-taskbook.md` §8）：
//   * **零三方依赖**：只用 `dart:io` / `dart:convert`，`dart run` 直接起；
//   * **能力表可编程**：`--apis=` 决定 `SYNO.API.Info` 声明哪些 API；
//   * **可编程故障注入**：`--download-error` / `--download-truncate-after` /
//     `--list-error` / `--api-info-empty` / `--range=off`；
//   * **Range 语义正确**：默认 `Range: bytes=a-b` → `206 + Content-Range`。
//
// 安全：
//   * 本文件里的 `sid` / `SynoToken` 一律是**明显的假值**（`MOCK-SID-n` /
//     `MOCK-TOKEN-n`），与任何真实 NAS 无关；
//   * 日志对 `passwd` / `account` / `cipherkey` / `_sid` / `SynoToken` 做脱敏；
//   * `encryption.cgi` 回的公钥是**随仓库自带的 mock 公钥**（私钥只用于 mock
//     自己的 HTTPS，见 README），不是任何真实 NAS 的密钥。
//
// 用法见同目录 `README.md`。自测脚本：`tool/mock_nas/selftest.sh`。
//
// ⚠️ 这是一个**面向判定点**的最小服务器，不是 DSM 的功能仿真：
//   只把能力表、登录、FileStation `List`/`Download`/`Thumb` 做扎实，其余被声明
//   的 API 一律回 `{"success":true,"data":{}}`（够让能力检测通过，不保证模块功能）。
//   未声明的 API 回 **102**（"API 不存在"），与真实 DSM 一致。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'mock_nas_store.dart';

// ============================================================ 常量 / 目录

const String _kInfoApi = 'SYNO.API.Info';

/// **核心 API**：真实 DSM 的能力表**恒含**这三条（与装了哪些套件无关）。
///
/// ⚠️ 必须恒在：客户端（`lib/src/dsm/webapi.dart` 的 `_prepare`）会先查能力表，
/// **表里没有的 API 直接本地抛 102**，根本不会发请求 —— 少了
/// `SYNO.API.Encryption`，`login()` 第一步 `getinfo` 就 102，"降级"也就无从谈起。
/// 所以 `--api-info-empty` 的含义是"**没有任何套件服务**"，而不是字面意义的
/// "只剩 SYNO.API.Info"（后者用 `--literal-api-info-empty` 显式指定）。
const List<String> kCoreApis = [
  'SYNO.API.Info',
  'SYNO.API.Encryption',
  'SYNO.API.Auth',
];

/// 服务 → API 向量。
///
/// **镜像** `lib/src/core/services/service_registry.dart` 的
/// `kServiceRegistry`（必需的在前），API 名逐个来自
/// `docs/api-server-authoritative.md` 与各模块调研文档，**不得臆造**。
/// 这里只取必需 + 部分可选，供 `--apis=` 组合能力表。
const Map<String, List<String>> kServiceApiGroups = {
  'file': [
    'SYNO.FileStation.List',
    'SYNO.FileStation.Download',
    'SYNO.FileStation.Search',
    'SYNO.FileStation.Sharing',
    'SYNO.FileStation.Compress',
    'SYNO.FileStation.Extract',
    'SYNO.FileStation.Favorite',
    'SYNO.FileStation.BackgroundTask',
    'SYNO.FileStation.VirtualFolder',
    'SYNO.FileStation.Thumb',
    'SYNO.FileStation.Info',
    'SYNO.FileStation.Upload',
    'SYNO.FileStation.Delete',
    'SYNO.FileStation.Rename',
    'SYNO.FileStation.CopyMove',
    'SYNO.FileStation.CreateFolder',
    'SYNO.Core.RecycleBin',
    'SYNO.FileStation.CheckExist',
  ],
  'photo': [
    'SYNO.Foto.Browse.Item',
    'SYNO.Foto.Browse.Album',
    'SYNO.Foto.Streaming',
    'SYNO.Foto.Thumbnail',
    'SYNO.Foto.Download',
    'SYNO.Foto.Setting.User',
    'SYNO.Foto.Browse.Timeline',
    'SYNO.Foto.Browse.Folder',
    'SYNO.Foto.Browse.GeneralTag',
    'SYNO.Foto.Browse.Person',
    'SYNO.Foto.Search.Search',
    'SYNO.Foto.Upload.Item',
    'SYNO.Foto.Favorite',
    // —— 本批补齐：`lib/src/data/foto_api.dart` 在用、旧 mock 缺失的家族
    'SYNO.Foto.Browse.NormalAlbum',
    'SYNO.Foto.Browse.Favorites',
    'SYNO.Foto.Browse.RecentlyAdded',
    'SYNO.Foto.RegeneratePreview',
  ],
  'chat': [
    'SYNO.Chat.Channel',
    'SYNO.Chat.Post',
    'SYNO.Chat.User',
    'SYNO.Chat.Admin.Setting',
    'SYNO.Chat.Post.Reaction',
    'SYNO.Chat.Post.Vote',
    'SYNO.Chat.Post.Schedule',
    'SYNO.Chat.Post.Reminder',
    'SYNO.Chat.Sticker',
    'SYNO.Chat.User.Avatar',
    'SYNO.Chat.Channel.Named',
    'SYNO.Chat.Channel.Member',
    'SYNO.Chat.Post.Subscribe',
    'SYNO.Chat.Post.Hashtag',
    'SYNO.Chat.Channel.Hashtag',
    'SYNO.Chat.Misc',
    'SYNO.Chat.Post.Attachment',
  ],
  'note': [
    'SYNO.NoteStation.Note',
    'SYNO.NoteStation.Notebook',
    'SYNO.NoteStation.Todo',
    'SYNO.NoteStation.Tag',
    'SYNO.NoteStation.Note.Encrypt',
    'SYNO.NoteStation.Permission',
    // —— 本批补齐：`lib/src/data/note_api.dart` 真的在调用、旧 mock 缺失的家族
    'SYNO.NoteStation.Note.Polling',
    'SYNO.NoteStation.Notebook.Polling',
    'SYNO.NoteStation.Note.Version',
    'SYNO.NoteStation.Shortcut',
    'SYNO.NoteStation.Smart',
    'SYNO.NoteStation.Info',
    'SYNO.NoteStation.FTS',
    'SYNO.NoteStation.Setting',
    'SYNO.NoteStation.Export.Note',
    'SYNO.NoteStation.Export.Notebook',
    'SYNO.NoteStation.Import.Notebook',
    'SYNO.NoteStation.Import.Enex',
    'SYNO.NoteStation.Import.Evernote',
  ],
  'calendar': ['SYNO.Cal.Event', 'SYNO.Cal.Todo', 'SYNO.Cal.Setting'],
  'contacts': [
    'SYNO.Contacts.Contact',
    'SYNO.Contacts.Addressbook',
    'SYNO.Contacts.Label',
    'SYNO.Contacts.ExternalSource',
    'SYNO.Contacts.Info',
  ],
  'drive': [
    'SYNO.SynologyDrive.Files',
    'SYNO.SynologyDrive.Sharing',
    'SYNO.SynologyDrive.Revisions',
    'SYNO.SynologyDrive.Trash',
    'SYNO.SynologyDrive.Tasks',
    'SYNO.SynologyDrive.Labels',
    'SYNO.SynologyDrive.TeamFolders',
  ],
  'office': [
    'SYNO.Office.Node',
    'SYNO.Office.Node.Version',
    'SYNO.Office.File',
    'SYNO.Office.Export',
    'SYNO.Office.Import',
  ],
  'audio': [
    'SYNO.AudioStation.Song',
    'SYNO.AudioStation.Info',
    'SYNO.AudioStation.Playlist',
    'SYNO.AudioStation.Stream',
    'SYNO.AudioStation.Cover',
    'SYNO.AudioStation.Pin',
    'SYNO.AudioStation.Search',
  ],
  'download': [
    'SYNO.DownloadStation2.Task',
    'SYNO.DownloadStation2.Task.List',
    'SYNO.DownloadStation2.Task.Statistic',
    'SYNO.DownloadStation2.Settings.Location',
    // —— 本批补齐：`lib/src/data/download_station.dart` 在用、旧 mock 缺失的家族
    'SYNO.DownloadStation2.Task.BT',
    'SYNO.DownloadStation2.Task.BT.Tracker',
    'SYNO.DownloadStation2.Task.BT.Peer',
    'SYNO.DownloadStation2.Task.BT.File',
    'SYNO.DownloadStation2.Task.List.Polling',
    'SYNO.DownloadStation2.Task.NZB.Log',
    'SYNO.DownloadStation2.Task.NZB.File',
    'SYNO.DownloadStation2.Task.Source',
    'SYNO.DownloadStation2.Captcha',
    'SYNO.DownloadStation2.BTSearch',
    'SYNO.DownloadStation.BTSearch',
    'SYNO.DownloadStation2.RSS.Feed',
    'SYNO.DownloadStation2.RSS.Item',
    'SYNO.DownloadStation2.RSS.Filter',
    'SYNO.DownloadStation2.Settings.AutoExtraction',
    'SYNO.DownloadStation2.Package.Info',
    'SYNO.DownloadStation2.Package.Module',
    'SYNO.DownloadStation2.Package.Service',
    'SYNO.DownloadStation2.Thumbnail',
  ],
  'surveillance': [
    'SYNO.SurveillanceStation.Camera',
    'SYNO.SurveillanceStation.Stream.VideoStreaming',
    'SYNO.SurveillanceStation.Recording',
    'SYNO.SurveillanceStation.PTZ',
  ],
  'mailplus': [
    'SYNO.MailClient.Info',
    'SYNO.MailClient.Mailbox',
    'SYNO.MailClient.Thread',
    'SYNO.MailClient.Message',
    'SYNO.MailClient.Label',
    'SYNO.MailClient.Attachment',
  ],
};

/// API → `[minVersion, maxVersion]`。
///
/// 值来自 `test/fixtures/api_table.json`（真实 NAS 的 `SYNO.API.Info` 落盘，
/// 由 `tool/probe_api_table.dart` 生成）与调研文档：
///   * FileStation / Foto / Chat / Note / Cal / Contacts / Drive / Office：
///     → `test/fixtures/api_table.json`（实测）；
///   * Audio / DownloadStation2：`docs/station-audio-download-research.md`
///     （AudioStation.Song v1–3、Stream v1–2、Info v1–6、Cover v1–3、Search v1；
///      DownloadStation2.Task maxVersion=2 等）；
///   * Surveillance / MailClient：
///     `docs/station-surveillance-mailplus-insight-research.md`
///     （Camera maxVersion=9、MailClient.Info=6 / Mailbox=7 / Thread=11 /
///      Message=10 / Label=3 / Attachment=8）。
const Map<String, List<int>> kApiVersions = {
  'SYNO.API.Info': [1, 1],
  'SYNO.API.Encryption': [1, 1],
  'SYNO.API.Auth': [1, 7],
  'SYNO.FileStation.List': [1, 2],
  'SYNO.FileStation.Search': [1, 2],
  'SYNO.FileStation.Sharing': [1, 3],
  'SYNO.FileStation.Compress': [1, 3],
  'SYNO.FileStation.Extract': [1, 2],
  'SYNO.FileStation.Favorite': [1, 2],
  'SYNO.FileStation.BackgroundTask': [1, 3],
  'SYNO.FileStation.VirtualFolder': [1, 2],
  'SYNO.FileStation.Thumb': [1, 3],
  'SYNO.FileStation.Download': [1, 2],
  'SYNO.FileStation.Info': [1, 2],
  'SYNO.FileStation.Upload': [2, 3],
  'SYNO.FileStation.Delete': [1, 2],
  'SYNO.FileStation.Rename': [1, 2],
  'SYNO.FileStation.CheckExist': [1, 2],
  'SYNO.FileStation.CopyMove': [1, 3],
  'SYNO.FileStation.CreateFolder': [1, 2],
  'SYNO.Foto.Browse.Item': [1, 7],
  'SYNO.Foto.Browse.Album': [1, 5],
  'SYNO.Foto.Streaming': [1, 2],
  'SYNO.Foto.Thumbnail': [1, 2],
  'SYNO.Foto.Download': [1, 2],
  'SYNO.Foto.Setting.User': [1, 1],
  'SYNO.Foto.Browse.Timeline': [1, 6],
  'SYNO.Foto.Browse.Folder': [1, 2],
  'SYNO.Foto.Browse.GeneralTag': [1, 2],
  'SYNO.Foto.Browse.Person': [1, 3],
  'SYNO.Foto.Search.Search': [1, 7],
  'SYNO.Foto.Upload.Item': [1, 8],
  'SYNO.Foto.Favorite': [1, 2],
  // —— 本批补齐
  'SYNO.Foto.Browse.NormalAlbum': [1, 4],
  'SYNO.Foto.Browse.Favorites': [1, 2],
  'SYNO.Foto.Browse.RecentlyAdded': [1, 6],
  'SYNO.Foto.RegeneratePreview': [1, 1],
  'SYNO.Chat.Channel': [1, 5],
  'SYNO.Chat.Post': [1, 8],
  'SYNO.Chat.User': [1, 3],
  'SYNO.Chat.Admin.Setting': [1, 5],
  'SYNO.Chat.Post.Reaction': [1, 1],
  'SYNO.Chat.Post.Vote': [1, 1],
  'SYNO.Chat.Post.Schedule': [1, 1],
  'SYNO.Chat.Post.Reminder': [1, 1],
  'SYNO.Chat.Sticker': [1, 2],
  'SYNO.Chat.User.Avatar': [1, 1],
  'SYNO.Chat.Channel.Named': [1, 1],
  'SYNO.Chat.Channel.Member': [1, 1],
  'SYNO.Chat.Post.Subscribe': [1, 2],
  'SYNO.Chat.Post.Hashtag': [1, 1],
  'SYNO.Chat.Channel.Hashtag': [1, 1],
  'SYNO.Chat.Misc': [1, 1],
  'SYNO.Chat.Post.Attachment': [1, 1],
  'SYNO.NoteStation.Note': [1, 4],
  'SYNO.NoteStation.Notebook': [1, 2],
  'SYNO.NoteStation.Todo': [1, 2],
  'SYNO.NoteStation.Tag': [1, 2],
  'SYNO.NoteStation.Note.Encrypt': [1, 1],
  'SYNO.NoteStation.Permission': [1, 1],
  // —— 本批补齐（值对齐 `docs/api-server-authoritative.md` / 重判文档）
  'SYNO.NoteStation.Note.Polling': [1, 3],
  'SYNO.NoteStation.Notebook.Polling': [1, 1],
  'SYNO.NoteStation.Note.Version': [1, 2],
  'SYNO.NoteStation.Shortcut': [1, 1],
  'SYNO.NoteStation.Smart': [1, 1],
  'SYNO.NoteStation.Info': [1, 3],
  'SYNO.NoteStation.FTS': [1, 1],
  'SYNO.NoteStation.Setting': [1, 2],
  'SYNO.NoteStation.Note.Ghost': [1, 2],
  'SYNO.NoteStation.Export.Note': [1, 1],
  'SYNO.NoteStation.Export.Notebook': [1, 1],
  'SYNO.NoteStation.Export.Word': [1, 1],
  'SYNO.NoteStation.Import.Notebook': [1, 1],
  'SYNO.NoteStation.Import.Enex': [1, 1],
  'SYNO.NoteStation.Import.Evernote': [1, 1],
  'SYNO.Cal.Event': [1, 6],
  'SYNO.Cal.Todo': [1, 6],
  'SYNO.Cal.Setting': [1, 5],
  'SYNO.Contacts.Contact': [1, 2],
  'SYNO.Contacts.Addressbook': [1, 1],
  'SYNO.Contacts.Label': [1, 2],
  'SYNO.Contacts.ExternalSource': [1, 1],
  'SYNO.Contacts.Info': [1, 2],
  'SYNO.SynologyDrive.Files': [1, 11],
  'SYNO.SynologyDrive.Sharing': [1, 2],
  'SYNO.SynologyDrive.Revisions': [1, 2],
  'SYNO.SynologyDrive.Trash': [1, 2],
  'SYNO.SynologyDrive.Tasks': [1, 1],
  'SYNO.SynologyDrive.Labels': [1, 3],
  'SYNO.SynologyDrive.TeamFolders': [1, 1],
  'SYNO.Office.Node': [1, 2],
  'SYNO.Office.Node.Version': [1, 1],
  'SYNO.Office.File': [1, 1],
  'SYNO.Office.Export': [1, 1],
  'SYNO.Office.Import': [1, 1],
  'SYNO.AudioStation.Song': [1, 3],
  'SYNO.AudioStation.Info': [1, 6],
  'SYNO.AudioStation.Playlist': [1, 3],
  'SYNO.AudioStation.Stream': [1, 2],
  'SYNO.AudioStation.Cover': [1, 3],
  'SYNO.AudioStation.Pin': [1, 1],
  'SYNO.AudioStation.Search': [1, 1],
  'SYNO.DownloadStation2.Task': [1, 2],
  'SYNO.DownloadStation2.Task.List': [1, 2],
  'SYNO.DownloadStation2.Task.Statistic': [1, 1],
  'SYNO.DownloadStation2.Settings.Location': [1, 1],
  // —— 本批补齐（值对齐 `docs/download-api-live.md` / `download-captcha-tasklist-wave5.md`）
  'SYNO.DownloadStation2.Task.BT': [1, 2],
  'SYNO.DownloadStation2.Task.BT.Tracker': [1, 2],
  'SYNO.DownloadStation2.Task.BT.Peer': [1, 2],
  'SYNO.DownloadStation2.Task.BT.File': [1, 2],
  'SYNO.DownloadStation2.Task.List.Polling': [2, 2],
  'SYNO.DownloadStation2.Task.NZB.Log': [1, 1],
  'SYNO.DownloadStation2.Task.NZB.File': [1, 1],
  'SYNO.DownloadStation2.Task.Source': [1, 1],
  'SYNO.DownloadStation2.Captcha': [1, 1],
  'SYNO.DownloadStation2.BTSearch': [1, 2],
  'SYNO.DownloadStation.BTSearch': [1, 1],
  'SYNO.DownloadStation2.RSS.Feed': [1, 1],
  'SYNO.DownloadStation2.RSS.Item': [1, 1],
  'SYNO.DownloadStation2.RSS.Filter': [1, 1],
  'SYNO.DownloadStation2.Settings.AutoExtraction': [1, 1],
  'SYNO.DownloadStation2.Package.Info': [1, 2],
  'SYNO.DownloadStation2.Package.Module': [1, 2],
  'SYNO.DownloadStation2.Package.Service': [1, 2],
  'SYNO.DownloadStation2.Thumbnail': [1, 2],
  'SYNO.SurveillanceStation.Camera': [1, 9],
  'SYNO.SurveillanceStation.Stream.VideoStreaming': [1, 1],
  'SYNO.SurveillanceStation.Recording': [1, 6],
  'SYNO.SurveillanceStation.PTZ': [1, 6],
  'SYNO.MailClient.Info': [1, 6],
  'SYNO.MailClient.Mailbox': [1, 7],
  'SYNO.MailClient.Thread': [1, 11],
  'SYNO.MailClient.Message': [1, 10],
  'SYNO.MailClient.Label': [1, 3],
  'SYNO.MailClient.Attachment': [1, 8],
};

/// mock 的 `SYNO.API.Encryption / getinfo` 公钥（X.509 SPKI，DER，base64）。
///
/// 这是**随仓库自带的 mock 公钥**（与同目录 `mock_nas_cert.pem` 同一密钥对，
/// 私钥仅用于 mock 自己的 HTTPS）。App 登录时会真做 `RSA/ECB/PKCS1`，
/// 我们只需要一份**结构合法**的公钥让它加密成功——密文我们不解读。
/// 2048 位 → PKCS1 最多 245 字节明文，够放 mock 的账号/口令。
const String _kMockPublicKeyB64 =
    'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvVBXZL4s+Q2DBkm9Z0oG'
    'XYmRofRvNA3sSOE3zBfmXYjqu4ec1LPMGl7tWWpC1IskP/p5RdYu21eqM1v185wbU'
    'GWgC544YXfD8Hc/mYWWb0cMB518J4gTWJo4HyVu1oQTQ1jDu68ClykXTqqppB8FGJ'
    'OJgFf8SU/YXBPSXf4xbzNyz4zL/ylFaWdzSKt6mwLXHogTvRURDLxJkUg8sdaj0pG'
    'ChmM+5cnccyDWfzHcpLC5y3Zm7tvbPe3049NCcL+sZJMKwHijMwBwkCPaLq6RWJ8f'
    'XVUnoM+DV4L3qk/a0JvZlR3QCgvEnSkAsASZY89WlGbFCBfDShuRnroV7vtjsQIDA'
    'QAB';

// ============================================================ 配置

class MockConfig {
  MockConfig({
    required this.host,
    required this.port,
    required this.declaredApis,
    required this.apiInfoEmpty,
    required this.literalApiInfoEmpty,
    required this.downloadError,
    required this.truncateAfter,
    required this.listError,
    required this.rangeEnabled,
    required this.downloadBytes,
    required this.mediaFile,
    required this.errorHttpStatus,
    required this.https,
    required this.certPath,
    required this.keyPath,
    required this.apiTablePath,
    required this.verbose,
  });

  final String host;
  final int port;

  /// 能力表里声明的 API 集合（不含 [SYNO.API.Info]，它恒在）。
  final Set<String> declaredApis;
  final bool apiInfoEmpty;

  /// 字面意义的"能力表只剩 SYNO.API.Info"（连核心 API 也不声明）。
  /// ⚠️ 客户端会因此在 `login()` 第一步本地抛 102 —— 仅供观察该极端行为。
  final bool literalApiInfoEmpty;

  final int? downloadError;
  final int? truncateAfter;
  final int? listError;
  final bool rangeEnabled;
  final int downloadBytes;
  final String? mediaFile;

  /// 注入错误时的 HTTP 状态码。默认 **200**（DSM 的真实形态：
  /// `200 + {"success":false,"error":{"code":119}}`）。
  /// 置 403 可命中 App 现有"HTTP 401/403 → sessionExpired"的分类。
  final int errorHttpStatus;

  final bool https;
  final String certPath;
  final String keyPath;
  final String? apiTablePath;
  final bool verbose;
}

const String _usage = '''
本地 Mock NAS（零依赖 Dart）——验证 sessionExpired(119) 与能力表降级。

用法：
  dart run tool/mock_nas/mock_nas_server.dart [选项]

选项：
  --port=<n>                      监听端口（默认 8788）
  --host=<addr>                   绑定地址（默认 0.0.0.0，便于真机从局域网访问）
  --apis=<spec>                   能力表声明哪些服务（默认 file）：
                                    file | all | none | api-info-only |
                                    file,photo,chat（逗号分隔，可混）
                                    可选服务名：file / photo / chat / note /
                                    calendar / contacts / drive / office /
                                    audio / download / surveillance / mailplus
  --api-info-empty                去掉**全部套件服务**的能力声明（保留核心 API：
                                  SYNO.API.Info / SYNO.API.Encryption / SYNO.API.Auth）
  --literal-api-info-empty        字面意义的"只剩 SYNO.API.Info"（连核心 API 也不声明；
                                  App 会因此在 login 第一步本地抛 102，仅供观察）
  --download-error=<code>         FileStation Download 一律回该错误码（如 119）
  --download-truncate-after=<n>   Download 先发 n 字节再断流，随后该 sid 全回 119
  --list-error=<code>             FileStation List 回该错误码（如 105 无权限）
  --range=off                     忽略 Range，一律 200（对照默认的 206）
  --download-bytes=<n>            内置合成媒体大小（默认 1048576）
  --media-file=<path>             改用真实文件做 Download 内容（如 clip-h264.mp4）
  --error-http-status=<n>         注入错误用的 HTTP 状态（默认 200；403 可命中 App 分类）
  --https                         开 HTTPS（用自带自签证书）
  --cert=<path>                   HTTPS 证书（默认同目录 mock_nas_cert.pem）
  --key=<path>                    HTTPS 私钥（默认同目录 mock_nas_key.pem）
  --api-table=<path>              追加/覆盖 API 版本表（JSON，形如
                                  {"SYNO.X.Y":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}）
  --verbose                       逐请求日志
  -h, --help                      显示本帮助
''';

MockConfig parseArgs(List<String> argv) {
  final flags = <String>{};
  final opts = <String, String>{};
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (!a.startsWith('--') && a != '-h') {
      throw FormatException('未知参数：$a（用 --help 看用法）');
    }
    final eq = a.indexOf('=');
    if (eq > 0) {
      opts[a.substring(0, eq)] = a.substring(eq + 1);
    } else if (a == '--https' ||
        a == '--verbose' ||
        a == '--api-info-empty' ||
        a == '--literal-api-info-empty' ||
        a == '-h' ||
        a == '--help') {
      flags.add(a);
    } else if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) {
      opts[a] = argv[++i];
    } else {
      flags.add(a);
    }
  }

  final selfDir = File.fromUri(Platform.script).parent.path;
  final defaultCert = '$selfDir/mock_nas_cert.pem';
  final defaultKey = '$selfDir/mock_nas_key.pem';

  final literalApiInfoEmpty = flags.contains('--literal-api-info-empty');
  final apiSpec = (opts['--apis'] ?? 'file').trim();
  final apiInfoEmpty =
      literalApiInfoEmpty ||
      flags.contains('--api-info-empty') ||
      apiSpec == 'none' ||
      apiSpec == 'api-info-only';

  final declared = <String>{};
  if (!apiInfoEmpty) {
    if (apiSpec == 'all') {
      for (final list in kServiceApiGroups.values) {
        declared.addAll(list);
      }
    } else {
      for (final raw in apiSpec.split(',')) {
        final name = raw.trim();
        if (name.isEmpty) continue;
        final group = kServiceApiGroups[name];
        if (group == null) {
          throw FormatException(
            '--apis 里的 "$name" 不是已知服务；可选：'
            '${kServiceApiGroups.keys.join(', ')}, all, none',
          );
        }
        declared.addAll(group);
      }
    }
  }

  int intOpt(String key, int fallback) {
    final v = opts[key];
    if (v == null) return fallback;
    final n = int.tryParse(v);
    if (n == null) throw FormatException('$key 需要整数，得到 "$v"');
    return n;
  }

  int? intOrNull(String key) {
    final v = opts[key];
    if (v == null) return null;
    final n = int.tryParse(v);
    if (n == null) throw FormatException('$key 需要整数，得到 "$v"');
    return n;
  }

  final rangeRaw = (opts['--range'] ?? 'on').toLowerCase();
  if (rangeRaw != 'on' && rangeRaw != 'off') {
    throw FormatException('--range 只能是 on / off，得到 "$rangeRaw"');
  }

  return MockConfig(
    host: opts['--host'] ?? '0.0.0.0',
    port: intOpt('--port', 8788),
    declaredApis: declared,
    apiInfoEmpty: apiInfoEmpty,
    literalApiInfoEmpty: literalApiInfoEmpty,
    downloadError: intOrNull('--download-error'),
    truncateAfter: intOrNull('--download-truncate-after'),
    listError: intOrNull('--list-error'),
    rangeEnabled: rangeRaw == 'on',
    downloadBytes: intOpt('--download-bytes', 1048576),
    mediaFile: opts['--media-file'],
    errorHttpStatus: intOpt('--error-http-status', 200),
    https: flags.contains('--https'),
    certPath: opts['--cert'] ?? defaultCert,
    keyPath: opts['--key'] ?? defaultKey,
    apiTablePath: opts['--api-table'],
    verbose: flags.contains('--verbose'),
  );
}

// ============================================================ 运行状态

class MockState {
  int loginSeq = 0;

  /// 被"截断故障"或显式注入过 119 的 sid —— 之后该 sid 的所有请求都回 119。
  final Set<String> expiredSids = <String>{};

  /// 已经做过一次"发 N 字节再断流"的 sid（避免每次都截断）。
  final Set<String> truncatedSids = <String>{};
}

// ============================================================ 入口

/// 一份**已启动**的 mock 实例（供测试/工具在进程内直接拿着用）。
///
/// [store] 是内存后端 —— 测试可以直接读它断言"写操作之后状态对不对"，
/// 也可以只用 HTTP 黑盒断言。**它只存在于本进程**，与任何真实 NAS 无关。
class MockNasInstance {
  MockNasInstance._(
    this.server,
    this.store,
    this.apis,
    this.mediaBytes,
    this.state,
  );

  final HttpServer server;
  final MockNasStore store;
  final Map<String, List<int>> apis;
  final Uint8List mediaBytes;
  final MockState state;

  int get port => server.port;

  /// 测试/探针填的 baseUrl（末尾无 `/`；`DirectTransport.url` 会自己补）。
  String get url => 'http://127.0.0.1:${server.port}';

  Future<void> close() => server.close(force: true);
}

/// 按 [cfg] 组装能力表（`apis` 是终态：已含核心 API 与 `--api-table` 覆盖）。
Map<String, List<int>> buildApiTable(MockConfig cfg) {
  final apis = <String, List<int>>{};
  void addApi(String name, int minV, int maxV) => apis[name] = [minV, maxV];

  if (cfg.literalApiInfoEmpty) {
    // 字面模式：真的只剩 SYNO.API.Info（用于观察客户端本地 102）。
    addApi(_kInfoApi, 1, 1);
  } else {
    // 核心 API 恒在（真实 DSM 也是这样），否则客户端 login 第一步就本地 102。
    for (final name in kCoreApis) {
      final v = kApiVersions[name] ?? const [1, 1];
      addApi(name, v[0], v[1]);
    }
    for (final name in cfg.declaredApis) {
      // 允许两种写法：**服务组名**（`file`/`note`，`startMockNas` 直传）
      // 或**已展开的 API 名**（CLI `parseArgs` 展开后的产物）。
      final group = kServiceApiGroups[name];
      if (group != null) {
        for (final api in group) {
          final v = kApiVersions[api] ?? const [1, 1];
          addApi(api, v[0], v[1]);
        }
      } else {
        final v = kApiVersions[name] ?? const [1, 1];
        addApi(name, v[0], v[1]);
      }
    }
  }
  if (cfg.apiTablePath != null) {
    final f = File(cfg.apiTablePath!);
    if (!f.existsSync()) {
      throw FormatException('--api-table 文件不存在：${cfg.apiTablePath}');
    }
    final raw = jsonDecode(f.readAsStringSync());
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v is Map) {
          apis['$k'] = [
            (v['minVersion'] as num?)?.toInt() ?? 1,
            (v['maxVersion'] as num?)?.toInt() ?? 1,
          ];
        }
      });
    }
  }
  return apis;
}

/// **在进程内起一个 mock NAS**（测试/工具用）。
///
/// 与 CLI 完全同一套 [MockConfig]/handler —— 只是不占固定端口、不打印启动横幅，
/// 并回一个 [MockNasInstance] 句柄。测试随后用
/// `DirectTransport.url(instance.url)` 让**真实客户端代码**走 loopback 打它。
Future<MockNasInstance> startMockNas({
  String host = '127.0.0.1',
  int port = 0,
  Set<String> declaredApis = const {},
  bool apiInfoEmpty = false,
  bool literalApiInfoEmpty = false,
  bool rangeEnabled = true,
  int downloadBytes = 1048576,
  String? mediaFile,
  int? downloadError,
  int? truncateAfter,
  int? listError,
  int errorHttpStatus = 200,
  String? apiTablePath,
  bool verbose = false,
}) async {
  final cfg = MockConfig(
    host: host,
    port: port,
    declaredApis: declaredApis,
    apiInfoEmpty: apiInfoEmpty,
    literalApiInfoEmpty: literalApiInfoEmpty,
    downloadError: downloadError,
    truncateAfter: truncateAfter,
    listError: listError,
    rangeEnabled: rangeEnabled,
    downloadBytes: downloadBytes,
    mediaFile: mediaFile,
    errorHttpStatus: errorHttpStatus,
    https: false,
    certPath: '',
    keyPath: '',
    apiTablePath: apiTablePath,
    verbose: verbose,
  );
  final apis = buildApiTable(cfg);
  final mediaBytes = _loadMediaBytes(cfg);
  final server = await HttpServer.bind(host, port);
  final state = MockState();
  final instance = MockNasInstance._(
    server,
    MockNasStore(mediaSize: mediaBytes.length),
    apis,
    mediaBytes,
    state,
  );
  server.listen(
    (req) => unawaited(
      _handle(req, cfg, state, apis, mediaBytes, instance.store),
    ),
    onError: (_) {},
  );
  return instance;
}

Future<void> main(List<String> argv) async {
  MockConfig cfg;
  try {
    cfg = parseArgs(argv);
  } on FormatException catch (e) {
    stderr.writeln('[mock] 参数错误：${e.message}');
    stdout.writeln(_usage);
    exitCode = 2;
    return;
  }
  if (argv.contains('-h') || argv.contains('--help')) {
    stdout.writeln(_usage);
    return;
  }

  final Map<String, List<int>> apis;
  try {
    apis = buildApiTable(cfg);
  } on FormatException catch (e) {
    stderr.writeln('[mock] ${e.message}');
    exitCode = 2;
    return;
  }

  final state = MockState();
  final mediaBytes = _loadMediaBytes(cfg);
  final store = MockNasStore(mediaSize: mediaBytes.length);

  HttpServer server;
  final bindAddr = cfg.host;
  try {
    if (cfg.https) {
      final ctx = SecurityContext()
        ..useCertificateChain(cfg.certPath)
        ..usePrivateKey(cfg.keyPath);
      server = await HttpServer.bindSecure(bindAddr, cfg.port, ctx);
    } else {
      server = await HttpServer.bind(bindAddr, cfg.port);
    }
  } on SocketException catch (e) {
    stderr.writeln(
      '[mock] 绑定 ${cfg.https ? 'https' : 'http'}://$bindAddr:${cfg.port} 失败：'
      '${e.osError?.message ?? e.message}',
    );
    exitCode = 1;
    return;
  }

  final scheme = cfg.https ? 'https' : 'http';
  stdout.writeln('[mock] 本地 Mock NAS 已启动');
  stdout.writeln('[mock]   监听        : $scheme://$bindAddr:${cfg.port}');
  stdout.writeln('[mock]   $_kInfoApi : 声明 ${apis.length} 个 API'
      '${cfg.literalApiInfoEmpty ? '（--literal-api-info-empty：只剩 SYNO.API.Info）' : cfg.apiInfoEmpty ? '（--api-info-empty：无套件服务，仅核心 API）' : ''}');
  stdout.writeln('[mock]   Range       : ${cfg.rangeEnabled ? '开（206 + Content-Range）' : '关（一律 200）'}');
  stdout.writeln('[mock]   Download 字节: ${mediaBytes.length}'
      '${cfg.mediaFile == null ? '（合成）' : '（来自 ${cfg.mediaFile}）'}');
  stdout.writeln('[mock]   download-error=${cfg.downloadError ?? '-'} '
      'truncate-after=${cfg.truncateAfter ?? '-'} '
      'list-error=${cfg.listError ?? '-'} '
      'error-http-status=${cfg.errorHttpStatus}');
  stdout.writeln('[mock] 有状态后端：笔记 ${store.notes.length} / 文件 ${store.fs.length} / '
      '下载任务 ${store.downloadTasks.length} / 照片 ${store.photos.length}');
  stdout.writeln('[mock] 真机填的服务器地址：$scheme://<宿主局域网IP>:${cfg.port}');
  stdout.writeln('[mock] 假凭据：account=mock  password=mock（随便填，登录不看口令）');
  stdout.writeln('[mock] Ctrl-C 结束');

  await for (final req in server) {
    unawaited(_handle(req, cfg, state, apis, mediaBytes, store));
  }
}

// ============================================================ 请求分发

Future<void> _handle(
  HttpRequest req,
  MockConfig cfg,
  MockState state,
  Map<String, List<int>> apis,
  Uint8List mediaBytes,
  MockNasStore store,
) async {
  HttpResponse res;
  try {
    res = req.response;
  } catch (_) {
    return;
  }
  final uri = req.uri;
  final path = uri.path;
  final params = <String, String>{};
  uri.queryParameters.forEach((k, v) => params[k] = v);

  try {
    if (req.method == 'POST' || req.method == 'PUT') {
      final body = await utf8.decoder.bind(req).join();
      if (body.isNotEmpty) {
        _parseForm(body).forEach((k, v) => params[k] = v);
      }
    }
  } catch (e) {
    await _json(res, cfg, {
      'success': false,
      'error': {'code': 100},
    });
    _log(cfg, req, params, note: '读取请求体失败：$e');
    return;
  }

  var api = params['api'] ?? '';
  final method = params['method'] ?? '';
  if (api.isEmpty) api = _apiFromPath(path);

  _log(cfg, req, params, note: 'api=$api method=$method');

  // ① 能力表：恒在，且**不受**会话失效影响（它是匿名接口）。
  if (api == _kInfoApi || path.endsWith('query.cgi')) {
    final data = <String, dynamic>{};
    final query = params['query'];
    final filter = (query == null || query.isEmpty || query == 'all')
        ? null
        : query.split(',').map((s) => s.trim()).toSet();
    apis.forEach((name, range) {
      if (filter != null && !filter.contains(name)) return;
      data[name] = {
        'path': _pathOf(name),
        'minVersion': range[0],
        'maxVersion': range[1],
      };
    });
    await _json(res, cfg, {'success': true, 'data': data});
    return;
  }

  // ② 登录用的公钥：也是匿名接口。
  if (api == 'SYNO.API.Encryption' || path.endsWith('encryption.cgi')) {
    await _json(res, cfg, {
      'success': true,
      'data': {
        'cipherkey': '__cIpHeRtExT',
        'ciphertoken': '__cIpHeRtOkEn',
        'public_key': _kMockPublicKeyB64,
        'server_time':
            DateTime.now().millisecondsSinceEpoch ~/ 1000,
      },
    });
    return;
  }

  // ③ 登录 / 登出：**不看真实口令**，回一个明显的假 sid。
  if (api == 'SYNO.API.Auth' || path.endsWith('auth.cgi')) {
    if (method == 'logout') {
      await _json(res, cfg, {'success': true, 'data': {}});
      return;
    }
    state.loginSeq += 1;
    // 绝不能把**已失效**的 sid 再发出去（否则"重新登录"会被立刻判成 119）。
    while (state.expiredSids.contains('MOCK-SID-${state.loginSeq}')) {
      state.loginSeq += 1;
    }
    final sid = 'MOCK-SID-${state.loginSeq}';
    final token = 'MOCK-TOKEN-${state.loginSeq}';
    res.headers.set(HttpHeaders.setCookieHeader, 'id=$sid');
    await _json(res, cfg, {
      'success': true,
      'data': {'sid': sid, 'synotoken': token, 'device_id': 'MOCK-DID'},
    });
    stdout.writeln('[mock] 登录成功 → sid=$sid（假值）');
    return;
  }

  // ④ 会话失效：被标记过的 sid，之后**所有**请求都回 119。
  final sid = params['_sid'];
  if (sid != null && state.expiredSids.contains(sid)) {
    stdout.writeln('[mock] sid=$sid 已失效 → 回 '
        '{"success":false,"error":{"code":119}}');
    await _error(res, cfg, 119);
    return;
  }

  // ⑤ 未在能力表声明 → 102（与真实 DSM 一致）。
  if (!apis.containsKey(api)) {
    await _error(res, cfg, 102);
    return;
  }

  // ⑥ FileStation：核心三件事做扎实。
  if (api == 'SYNO.FileStation.List' && cfg.listError != null) {
    await _error(res, cfg, cfg.listError!);
    return;
  }
  if (api == 'SYNO.FileStation.Download') {
    if (cfg.downloadError != null) {
      await _error(res, cfg, cfg.downloadError!);
      return;
    }
    await _fileStationDownload(
      req,
      res,
      cfg,
      state,
      params,
      mediaBytes,
      sid,
    );
    return;
  }
  if (api == 'SYNO.FileStation.Thumb') {
    await _thumb(res);
    return;
  }

  // ⑦ 有状态业务后端（笔记 / 文件写操作 / 下载 / 相册）：
  //    真的改内存状态，"操作后状态正确"可断言。未覆盖的 API 回落 ⑧。
  final stored = store.reply(api, method, params);
  if (stored != null) {
    await _json(res, cfg, stored);
    return;
  }

  // ⑧ 其余被声明的 API：空 data 成功（够过能力检测，不保证模块功能）。
  if (api == 'SYNO.Foto.Browse.Item' ||
      api == 'SYNO.Foto.Browse.Album' ||
      api == 'SYNO.Foto.Browse.Timeline' ||
      api == 'SYNO.Foto.Browse.Folder') {
    await _json(res, cfg, {
      'success': true,
      'data': {'list': <dynamic>[], 'total': 0, 'offset': 0},
    });
    return;
  }
  await _json(res, cfg, {
    'success': true,
    'data': <String, dynamic>{},
  });
}

// ============================================================ FileStation

Future<void> _fileStationDownload(
  HttpRequest req,
  HttpResponse res,
  MockConfig cfg,
  MockState state,
  Map<String, String> params,
  Uint8List body,
  String? sid,
) async {
  final total = body.length;
  final rangeHeader = cfg.rangeEnabled ? req.headers.value('range') : null;

  // 默认语义：解析 `Range: bytes=a-b` → 206 + Content-Range。
  var start = 0;
  var end = total - 1;
  var isPartial = false;
  if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
    final spec = rangeHeader.substring('bytes='.length).split(',').first.trim();
    final dash = spec.indexOf('-');
    if (dash >= 0) {
      final a = spec.substring(0, dash).trim();
      final b = spec.substring(dash + 1).trim();
      if (a.isEmpty && b.isNotEmpty) {
        // 后缀范围：bytes=-N → 最后 N 字节
        final n = int.tryParse(b) ?? 0;
        if (n <= 0) {
          await _rangeNotSatisfiable(res, total);
          return;
        }
        start = max(0, total - n);
        end = total - 1;
        isPartial = true;
      } else {
        final aN = int.tryParse(a);
        if (aN == null || aN < 0 || aN >= total) {
          await _rangeNotSatisfiable(res, total);
          return;
        }
        final bN = b.isEmpty ? total - 1 : int.tryParse(b);
        if (bN == null || bN < aN) {
          await _rangeNotSatisfiable(res, total);
          return;
        }
        start = aN;
        end = min(bN, total - 1);
        isPartial = true;
      }
    }
  }

  final wanted = end - start + 1;

  // 故障注入：先发 N 字节再断流，然后把该 sid 标成失效。
  final truncate = cfg.truncateAfter;
  final doTruncate = truncate != null &&
      truncate >= 0 &&
      (sid == null || !state.truncatedSids.contains(sid));

  if (doTruncate && req.method != 'HEAD') {
    if (sid != null) {
      state.truncatedSids.add(sid);
      state.expiredSids.add(sid);
    }
    final sent = min(truncate, wanted);
    res.statusCode = isPartial ? HttpStatus.partialContent : HttpStatus.ok;
    res.headers.contentType = ContentType.binary;
    res.headers.set('Accept-Ranges', 'bytes');
    // 故意声明**完整**长度，实际只发 sent 字节 → 播放器/客户端以为还有后续，
    // 读到提前 EOF（curl exit 18）→ 会重试 → 重试命中 119。
    res.headers.contentLength = wanted;
    if (isPartial) {
      res.headers.set(
        'Content-Range',
        'bytes $start-${start + wanted - 1}/$total',
      );
    }
    // ⚠️ 必须在 `res.add()` **之前** detach：一旦写了响应体，头就发出去了，
    //     `detachSocket()` 会抛 `Bad state: Headers already sent`，连接也关不掉。
    try {
      final socket = await res.detachSocket();
      if (sent > 0) socket.add(Uint8List.sublistView(body, start, start + sent));
      await socket.flush();
      socket.destroy();
    } catch (e) {
      // 客户端可能已断开；忽略。
      stdout.writeln('[mock] 截断时连接处理异常（可忽略）：$e');
    }
    stdout.writeln(
      '[mock] Download 截断：已发 $sent 字节（声明 $wanted）→ '
      'sid=${sid ?? '(无)'} 标记为已失效（后续请求回 119）',
    );
    return;
  }

  res.statusCode = isPartial ? HttpStatus.partialContent : HttpStatus.ok;
  res.headers.contentType = ContentType.binary;
  res.headers.set('Accept-Ranges', cfg.rangeEnabled ? 'bytes' : 'none');
  res.headers.contentLength = wanted;
  if (isPartial) {
    res.headers.set('Content-Range', 'bytes $start-$end/$total');
  }
  if (req.method == 'HEAD') {
    await res.close();
    return;
  }
  if (wanted > 0) res.add(Uint8List.sublistView(body, start, start + wanted));
  await res.close();
}

Future<void> _rangeNotSatisfiable(HttpResponse res, int total) async {
  res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
  res.headers.set('Content-Range', 'bytes */$total');
  await res.close();
}

Future<void> _thumb(HttpResponse res) async {
  // 1×1 透明 PNG（能力检测/占位用，不需要真实图片）
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk'
    'YAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
  );
  res.statusCode = HttpStatus.ok;
  res.headers.contentType = ContentType('image', 'png');
  res.headers.contentLength = png.length;
  res.add(png);
  await res.close();
}

// ============================================================ 响应工具

Future<void> _json(
  HttpResponse res,
  MockConfig cfg,
  Map<String, dynamic> body,
) async {
  res.statusCode = HttpStatus.ok;
  res.headers.contentType = ContentType.json;
  final bytes = utf8.encode(jsonEncode(body));
  res.headers.contentLength = bytes.length;
  res.add(bytes);
  await res.close();
}

Future<void> _error(HttpResponse res, MockConfig cfg, int code) async {
  res.statusCode = cfg.errorHttpStatus;
  res.headers.contentType = ContentType.json;
  final bytes = utf8.encode(
    jsonEncode({
      'success': false,
      'error': {'code': code},
    }),
  );
  res.headers.contentLength = bytes.length;
  res.add(bytes);
  await res.close();
}

// ============================================================ 杂项

Uint8List _loadMediaBytes(MockConfig cfg) {
  if (cfg.mediaFile != null) {
    final f = File(cfg.mediaFile!);
    if (!f.existsSync()) {
      stderr.writeln('[mock] --media-file 不存在：${cfg.mediaFile}');
      exit(2);
    }
    return f.readAsBytesSync();
  }
  // 合成内容：确定性伪随机，避免和"真实媒体"混淆；只用于 Range/截断验证。
  final n = max(1, cfg.downloadBytes);
  final out = Uint8List(n);
  var x = 0x9E3779B97F4A7C15;
  for (var i = 0; i < n; i++) {
    x = (x * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF;
    out[i] = (x >> 33) & 0xFF;
  }
  return out;
}

/// 按 `api` 精确路由（本 mock 不关心 cgi 路径，因为真实路径由能力表给出）。
String _pathOf(String api) {
  switch (api) {
    case _kInfoApi:
      return 'query.cgi';
    case 'SYNO.API.Auth':
      return 'auth.cgi';
    case 'SYNO.API.Encryption':
      return 'encryption.cgi';
    default:
      return 'entry.cgi';
  }
}

String _apiFromPath(String path) {
  final p = path.toLowerCase();
  if (p.endsWith('query.cgi')) return _kInfoApi;
  if (p.endsWith('auth.cgi')) return 'SYNO.API.Auth';
  if (p.endsWith('encryption.cgi')) return 'SYNO.API.Encryption';
  return '';
}

Map<String, String> _parseForm(String body) {
  final out = <String, String>{};
  for (final pair in body.split('&')) {
    if (pair.isEmpty) continue;
    final eq = pair.indexOf('=');
    if (eq < 0) {
      out[Uri.decodeQueryComponent(pair)] = '';
    } else {
      out[Uri.decodeQueryComponent(pair.substring(0, eq))] =
          Uri.decodeQueryComponent(pair.substring(eq + 1));
    }
  }
  return out;
}

/// 日志脱敏：口令 / 账号 / 密文 / 会话 id / CSRF 令牌一律不落日志。
const Set<String> _kSensitiveKeys = {
  'passwd',
  'password',
  'account',
  'cipherkey',
  '_sid',
  'sid',
  'synotoken',
  'otp_code',
  'device_id',
};

void _log(
  MockConfig cfg,
  HttpRequest req,
  Map<String, String> params, {
  String? note,
}) {
  if (!cfg.verbose) return;
  final safe = <String>[];
  params.forEach((k, v) {
    if (_kSensitiveKeys.contains(k.toLowerCase())) {
      safe.add('$k=***');
    } else {
      safe.add('$k=$v');
    }
  });
  stdout.writeln(
    '[mock] ${req.method} ${req.uri.path} ${safe.join(' ')}'
    '${note == null ? '' : '  # $note'}',
  );
}
