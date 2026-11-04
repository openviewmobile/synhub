// DSM WebAPI 客户端 + 可切换传输
//
// 传输抽象是关键：同一套请求既能走**直连**（LAN/WAN），也能走**隧道**
// （127.0.0.1:<port>）。这让我们能对两条路径做等价性验证 —— 目标里
// 「与 relay 兜底等价可用」需要的就是这个能力。
//
// 协议逆向自 APK：
//   syno/api/Auth.java, syno/api/Info.java
//   com.synology.sylib.syapi.webapi.request.ApiAuth / ApiInfo
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:http_parser/http_parser.dart';

import 'cgi_encryption.dart';

import '../core/i18n/data_text.dart';
import '../core/net/traffic_meter.dart';
import '../native/punch_ffi.dart';

/// 把流量模块标签塞进 `RequestOptions.extra`（计量适配器读它）。
///
/// null / 空 → 不塞，请求落 `unattributed`（绝不静默丢失，见
/// `core/net/traffic_meter.dart`）。这是数据层唯一的"打标签"出口。
Map<String, dynamic>? trafficExtra(String? module) =>
    (module == null || module.isEmpty)
        ? null
        : {kTrafficModuleKey: module};

// ---------------------------------------------------------------- 错误
/// DSM 的 `error.code`。取值来自 APK 的 `WebApiError`。
class DsmErrorCode {
  // ---- 通用 WebAPI 码（`WEBAPI_ERR_*`，逐条抄自 2.11.1 的
  // `com/synology/dschat/data/exception/ApiException.java:43-72`）。
  // ⚠️ 之前这张表是错的：105 曾被当成"未认证"（实际是 noPermission）、
  // 106/107 也错位，导致会话失效判断和错误文案都会错。
  static const int unknown = 100;
  static const int badRequest = 101;
  static const int apiNotFound = 102;
  static const int methodNotFound = 103;
  static const int notSupportedVersion = 104;
  static const int noPermission = 105;
  static const int sessionTimeout = 106;
  static const int sessionInterrupt = 107;
  static const int handleUpload = 108;
  static const int processRelay = 109;
  static const int processEntry = 110;
  static const int processLib = 111;
  static const int compoundStop = 112;
  static const int compoundReject = 113;
  static const int noRequiredParam = 114;
  static const int notAllowUpload = 115;
  static const int notAllowDemo = 116;
  static const int internalError = 117;
  static const int processNameError = 118;
  static const int sidNotFound = 119;
  static const int requestParameterInvalid = 120;
  static const int noMatchLibEntry = 121;
  static const int noAppPrivilege = 160;

  /// 会话失效（该重新登录）。
  static const Set<int> sessionExpiredCodes = {sessionTimeout, sidNotFound};

  /// 会触发"重登 + 重放"的码 —— **只有 119**。
  ///
  /// ⚠️ 这里**刻意不复刻**原版 `RetryInterceptor.java:66` 的 `{105, 119}`（见
  /// docs/device-verification.md R6-6 / §9.5 真机实测）：
  ///   * R6 用 `--list-error=105` 单跑，mock 日志记到 **712 次 `List`**。根因是
  ///     105 触发重登 → 每次重登换一个新 sid → `fileApiProvider` 重建 →
  ///     `folderSyncProvider` 再发 `List` → 又 105 …… 正反馈。
  ///   * `105 = noPermission` 是**确定性**失败（账号没被授权，重登不会改变），
  ///     按瞬时故障反复重试既没意义又烧流量/日志，必须**直接熔断**：
  ///     一条 105 现在只发**一次**请求，不再重登、不再重放（上限见
  ///     `test/session_relogin_test.dart` 的「105 → 有界」用例）。
  ///   * `119 = sidNotFound`（以及 `106 = sessionTimeout` 的文案语义）才是
  ///     "换个 sid 就好"的**瞬时**态，保留既有的"重登一次 + 重放一次"策略。
  static const Set<int> retryLoginCodes = {sidNotFound};

  /// 重登时若拿到这些码，说明**再登也没用**（密码错/账号停用/要改密/LDAP），
  /// 原版 `ApiException.shouldSkipRetryLogin()` 就是这个集合，会置
  /// `skip_retry_login` 永久跳过重试，直到下一次登录成功。
  static const Set<int> skipRetryLoginCodes = {
    authInvalidPassword, // 400
    authAccountDisabled, // 401
    authPasswordExpiredCantChange, // 408
    authPasswordExpired, // 409
    authPasswordMustChange, // 410
  };

  // ---- `SYNO.API.Auth` 的登录码（`WEBAPI_AUTH_ERR_*`）
  static const int authInvalidPassword = 400;
  static const int authAccountDisabled = 401;
  static const int authPermissionDenied = 402;
  static const int authOtpRequired = 403;
  static const int authOtpInvalid = 404;
  static const int authPortalPortInvalid = 405;
  static const int authOtpEnforced = 406;
  static const int authMaxTries = 407;
  static const int authPasswordExpiredCantChange = 408;

  /// 同一个 408 在两个模块里意思不同：
  ///   * 聊天（`SYNO.Chat.*`）：密码已过期且不允许自行修改；
  ///   * FileStation：**路径/文件不存在**（真机实测：列不存在的目录、
  ///     解压到一个不存在的目标目录，都是 408）。
  /// 文案按模块分开取（见 `describeFileError`）。
  static const int fileNotFound = 408;

  /// **Drive** 的"这个对象不存在 / 访问失败"（真机只读实测两处）：
  ///   * `Files:list` + `path=id:<已删除目录的回收站条目 id>` → `1003`
  ///     （r355 像素：回收站里点目录行 → `Cannot open this folder`）；
  ///   * `Files:get` v11 `{path:"/mydrive/__no_such__"}` → `1003`
  ///     `{"line":46,"message":"request access failed"}`（`drive_api.dart` 注释）。
  /// ⇒ 与 FileStation 的 [fileNotFound]（408）**同义**：文案复用同一条，
  /// 不许把裸 `Error code 1003` 丢给用户（见 `describeFileError`，DA10）。
  static const int drivePathNotFound = 1003;

  static const int authPasswordExpired = 409;
  static const int authPasswordMustChange = 410;
  static const int authAccountLocked = 411;

  /// **FileStation 的 407/409 = 权限不足**（不是限流！）。
  ///
  /// 权威出处：官方 FileStation **1.5.1-2410** 前端
  /// `ui/file_browser/FileBrowserUtil.js` 的 `getWebAPIErrStr`：
  /// `case 407: case 409: return _WFT("error","error_privilege_not_enough")`。
  ///
  /// r395 真机/宿主**原始读数**（未经仓里任何映射层）：
  /// `SYNO.FileStation.List/list v2 {folder_path:"/teamdrivetest/#recycle"}` →
  /// `{"error":{"code":407},"success":false}`（同一分钟列该共享本体是成功的）；
  /// 对照：不存在的路径 `/teamdrivetest/__nope__` → **408**；没有回收站的共享
  /// `/docker/#recycle` → **408**（见 `docs/evidence-r395/`）。
  static const int privilegeNotEnough = 407;

  /// **FileStation 的 600 = 搜索结果暂时不可用**（"缓存还没准备好"）。
  ///
  /// 权威出处：官方 FileStation **1.5.1-2410** 前端 `FileBrowserUtil.js` 的
  /// `case 600: return _WFT("search","no_search_cache")`，文案在同一个包的
  /// `ui/file_browser/texts/enu/strings`：
  /// `no_search_cache = "The search results are temporarily unavailable. Please try again."`
  /// （chs：「暂时无法访问搜索结果。请再试一次。」）
  ///
  /// r395 读数：对根 `/` 的搜索任务，`Search/list` 会在任务刚建好时回 600、
  /// 稍后同一报文回成功 ⇒ 是**瞬时态**，可重试（见
  /// `FileStationApi.searchResultsRetrying`）。
  static const int searchCacheUnavailable = 600;

  /// ★★★ **Audio Station 的业务码**（官方 `getErrCodeMapping` 逐字）。
  ///
  /// 与通用/其它模块**同号不同义**，必须按 method 分表（[audioStationMessages]）：
  ///   * `101` = `AUDIO_ERR_INVALID_PLAYLIST_NAME` / `AUDIO_ERR_COMMON_ERR`；
  ///   * `406` = `AUDIO_ERR_FILE_EXISTS`、`409` = `AUDIO_ERR_TOO_MANY_SONGS`；
  ///   * `407`/`412`/`1202` = `AUDIO_ERR_PLAYLIST_NOT_EXISTS`；
  ///   * **`411`/`1201` = `AUDIO_ERR_DUPLICATE_SONGS`** —— ★ 与 [authAccountLocked]
  ///     （同为 411）**完全相反**：音频侧是"列表里已有这首歌"。
  ///     真机读数见 [audioStationMessages] 的注释（r442 · `DA96`）。
  ///   * `410` = `AUDIO_ERR_SHARED_PLAYLIST_CONTAINS_SONG_RATING`；
  ///   * `501` = `AUDIO_ERR_INVALID_PASSWORD`（AirPlay 投送）；
  ///   * `1006`/`1007` = `AUDIO_ERR_PIN_EXIST` / `_NOT_EXIST`；`1010`/`1011` = `_TARGET_NOT_EXIST`。
  static const int audioInvalidPlaylistName = 101;
  static const int audioFileExists = 406;
  static const int audioTooManySongs = 409;
  static const int audioPlaylistNotExists = 407;
  static const int audioDuplicateSongs = 411;
  static const int audioSharedPlaylistRating = 410;
  static const int audioPinExists = 1006;
  static const int audioPinNotExists = 1007;
  static const int audioPinTargetNotExists = 1010;
  static const int audioInvalidPassword = 501;

  /// 通用 WebAPI 错误码 → **中文**文案。
  ///
  /// ⚠️ 这张表必须是纯 Dart 的 `const`（不含 `AppText`）：本文件要能被
  /// `dart run tool/*.dart` 加载，`l10n.dart` 会拖进 `dart:ui`。
  /// 要按当前应用语言取文案用 [messagesText]（走 `data_text.dart` 的 `dataText`）。
  /// 测试与老代码照旧可以 `messages[code]`。
  static const Map<int, String> messages = {
    unknown: '未知错误',
    badRequest: '请求无效',
    apiNotFound: 'API 不存在',
    methodNotFound: '方法不存在',
    notSupportedVersion: 'API 版本不支持',
    noPermission: '无权限',
    sessionTimeout: '会话超时，请重新登录',
    sessionInterrupt: '会话被中断',
    handleUpload: '上传处理失败',
    processRelay: '中继处理失败',
    processEntry: '入口处理失败',
    processLib: '模块处理失败',
    compoundStop: '复合请求中止',
    compoundReject: '复合请求被拒',
    noRequiredParam: '缺少必需参数',
    notAllowUpload: '不允许上传',
    notAllowDemo: '演示模式不允许该操作',
    internalError: '服务端内部错误',
    processNameError: '进程名错误',
    sidNotFound: '会话不存在，请重新登录',
    requestParameterInvalid: '请求参数无效',
    noMatchLibEntry: '找不到对应的模块入口',
    noAppPrivilege: '没有该应用的权限',
    authInvalidPassword: '账号或密码错误',
    authAccountDisabled: '账号已停用',
    authPermissionDenied: '权限被拒',
    authOtpRequired: '需要两步验证码',
    authOtpInvalid: '验证码错误',
    authPortalPortInvalid: '门户端口无效',
    authOtpEnforced: '该账号被强制要求两步验证',
    authMaxTries: '尝试次数过多，请稍后再试',
    authPasswordExpiredCantChange: '密码已过期且不允许自行修改',
    authPasswordExpired: '密码已过期，需修改',
    authPasswordMustChange: '必须先修改密码',
    authAccountLocked: '账号已锁定',
  };

  /// [messages] 的**当前应用语言**版本（key 沿用 ARB 的 `err*`）。
  ///
  /// 没装翻译器（纯 Dart 探针/单测）时逐条回落 [messages] 的中文原文。
  static Map<int, String> messagesText() => {
    unknown: dataText('errUnknown', messages[unknown]!),
    badRequest: dataText('errBadRequest', messages[badRequest]!),
    apiNotFound: dataText('errApiNotFound', messages[apiNotFound]!),
    methodNotFound: dataText('errMethodNotFound', messages[methodNotFound]!),
    notSupportedVersion: dataText(
      'errApiVersionUnsupported',
      messages[notSupportedVersion]!,
    ),
    noPermission: dataText('errNoPermission', messages[noPermission]!),
    sessionTimeout: dataText('errSessionTimeout', messages[sessionTimeout]!),
    sessionInterrupt: dataText(
      'errSessionInterrupted',
      messages[sessionInterrupt]!,
    ),
    handleUpload: dataText('errHandleUpload', messages[handleUpload]!),
    processRelay: dataText('errProcessRelay', messages[processRelay]!),
    processEntry: dataText('errProcessEntry', messages[processEntry]!),
    processLib: dataText('errProcessLib', messages[processLib]!),
    compoundStop: dataText('errCompoundStop', messages[compoundStop]!),
    compoundReject: dataText('errCompoundReject', messages[compoundReject]!),
    noRequiredParam: dataText('errNoRequiredParam', messages[noRequiredParam]!),
    notAllowUpload: dataText('errNotAllowUpload', messages[notAllowUpload]!),
    notAllowDemo: dataText('errNotAllowDemo', messages[notAllowDemo]!),
    internalError: dataText('errInternal', messages[internalError]!),
    processNameError: dataText('errProcessName', messages[processNameError]!),
    sidNotFound: dataText('errSidNotFound', messages[sidNotFound]!),
    requestParameterInvalid: dataText(
      'errRequestParameterInvalid',
      messages[requestParameterInvalid]!,
    ),
    noMatchLibEntry: dataText('errNoMatchLibEntry', messages[noMatchLibEntry]!),
    noAppPrivilege: dataText('errNoAppPrivilege', messages[noAppPrivilege]!),
    authInvalidPassword: dataText(
      'errAuthInvalidPassword',
      messages[authInvalidPassword]!,
    ),
    authAccountDisabled: dataText(
      'errAuthAccountDisabled',
      messages[authAccountDisabled]!,
    ),
    authPermissionDenied: dataText(
      'errAuthPermissionDenied',
      messages[authPermissionDenied]!,
    ),
    authOtpRequired: dataText('errAuthOtpRequired', messages[authOtpRequired]!),
    authOtpInvalid: dataText('errAuthOtpInvalid', messages[authOtpInvalid]!),
    authPortalPortInvalid: dataText(
      'errAuthPortalPortInvalid',
      messages[authPortalPortInvalid]!,
    ),
    authOtpEnforced: dataText('errAuthOtpEnforced', messages[authOtpEnforced]!),
    authMaxTries: dataText('errAuthMaxTries', messages[authMaxTries]!),
    authPasswordExpiredCantChange: dataText(
      'errAuthPasswordExpiredCantChange',
      messages[authPasswordExpiredCantChange]!,
    ),
    authPasswordExpired: dataText(
      'errAuthPasswordExpired',
      messages[authPasswordExpired]!,
    ),
    authPasswordMustChange: dataText(
      'errAuthPasswordMustChange',
      messages[authPasswordMustChange]!,
    ),
    authAccountLocked: dataText(
      'errAuthAccountLocked',
      messages[authAccountLocked]!,
    ),
  };

  /// `SYNO.Chat.*` 专用的错误码 → **中文**文案（纯 Dart `const`，理由同 [messages]）。
  ///
  /// ⚠️ 与 WebAPI 的通用码**有冲突**：比如 407 在 `SYNO.API.Auth` 是
  /// "IP 已被封禁"（`WEBAPI_AUTH_ERR_MAX_TRIES`），在 Chat 里却是
  /// `CHAT_ERR_INVALID_RECORD`（记录无效）。反编译出处：
  /// `com/synology/dschat/data/exception/ApiException.java`。
  /// 所以 [DsmErrorCode.describe] 要看是谁在报错，别一概而论。
  static const Map<int, String> chatMessages = {
    400: '没有这个用户（CHAT_ERR_NO_SUCH_USER）',
    401: '不在该频道（CHAT_ERR_NOT_IN_CHANNEL）',
    402: '消息不存在（CHAT_ERR_POST_NOT_FOUND）',
    403: '频道不存在（CHAT_ERR_CHANNEL_NOT_FOUND）',
    404: '无权限（CHAT_ERR_NO_PERMISSION）',
    405: '标签重复（CHAT_ERR_DUPLICATED_TAG）',
    406: '头像无效（CHAT_ERR_INVALID_AVATAR）',
    407: '记录无效（CHAT_ERR_INVALID_RECORD）',
    408: '密钥对不存在（CHAT_ERR_KEY_PAIR_NOT_EXIST）',
    409: '文件超过大小上限（CHAT_ERR_EXCEED_MAX_FILE_SIZE）',
    411: '发送过于频繁（CHAT_ERR_SEND_TOO_FREQUENTLY）',
    413: '频道被全局隐藏（CHAT_ERR_CHANNEL_GLOBAL_HIDE）',
    414: '服务端数据库迁移中（CHAT_ERR_SERVER_DB_MIGRATE）',
    420: '频道名重复（CHAT_ERR_DUPLICATED_CHANNEL_NAME）',
    421: '频道密钥不存在（CHAT_ERR_CHANNEL_KEY_NOT_EXIST）',
    422: '不允许加密（CHAT_ERR_NOT_ALLOW_ENCRYPTION）',
    423: '频道已加密（CHAT_ERR_CHANNEL_ENCRYPTED）',
    500: '用户重复（CHAT_ERR_USER_DUPLICATED）',
    501: '用户无效（CHAT_ERR_USER_INVALID）',
    502: '账号类型无效（CHAT_ERR_ACCOUNT_TYPE_INVALID）',
    503: '不允许 HTTP（CHAT_ERR_NOT_ALLOW_HTTP）',
    504: '不允许访客登录（CHAT_ERR_NOT_ALLOW_GUEST_LOGIN）',
  };

  /// [chatMessages] 的**当前应用语言**版本（key 沿用 ARB 的 `chatErr*`）
  static Map<int, String> chatMessagesText() => {
    400: dataText('chatErrNoSuchUser', chatMessages[400]!),
    401: dataText('chatErrNotInChannel', chatMessages[401]!),
    402: dataText('chatErrPostNotFound', chatMessages[402]!),
    403: dataText('chatErrChannelNotFound', chatMessages[403]!),
    404: dataText('chatErrNoPermission', chatMessages[404]!),
    405: dataText('chatErrDuplicatedTag', chatMessages[405]!),
    406: dataText('chatErrInvalidAvatar', chatMessages[406]!),
    407: dataText('chatErrInvalidRecord', chatMessages[407]!),
    408: dataText('chatErrKeyPairNotExist', chatMessages[408]!),
    409: dataText('chatErrExceedMaxFileSize', chatMessages[409]!),
    411: dataText('chatErrSendTooFrequently', chatMessages[411]!),
    413: dataText('chatErrChannelGlobalHide', chatMessages[413]!),
    414: dataText('chatErrServerDbMigrate', chatMessages[414]!),
    420: dataText('chatErrDuplicatedChannelName', chatMessages[420]!),
    421: dataText('chatErrChannelKeyNotExist', chatMessages[421]!),
    422: dataText('chatErrNotAllowEncryption', chatMessages[422]!),
    423: dataText('chatErrChannelEncrypted', chatMessages[423]!),
    500: dataText('chatErrUserDuplicated', chatMessages[500]!),
    501: dataText('chatErrUserInvalid', chatMessages[501]!),
    502: dataText('chatErrAccountTypeInvalid', chatMessages[502]!),
    503: dataText('chatErrNotAllowHttp', chatMessages[503]!),
    504: dataText('chatErrNotAllowGuestLogin', chatMessages[504]!),
  };

  /// **FileStation 家族**专用码 → 中文文案（其余模块的码见 [messages]）。
  ///
  /// 为什么必须分模块：同一个 407/408/409 在 `SYNO.API.Auth`、Chat 与 FileStation
  /// 里含义**互不相同**（r395：真机 `List/list` 对 `#recycle` 回 407，而旧代码把它
  /// 当成 Auth 的"限流"，于是用户看到"请求过于频繁，请稍后再试"——重试永远不会好）。
  ///
  /// 出处：官方 FileStation **1.5.1-2410** 前端
  /// `ui/file_browser/FileBrowserUtil.js` 的 `getWebAPIErrStr`：
  /// `407/409 → error_privilege_not_enough`、`408/1811 → error_no_path`、
  /// `600 → search/no_search_cache`（文案见同包 `texts/enu/strings`）。
  static const Map<int, String> fileStationMessages = {
    // 407 / 409 = 权限不足（**不是**限流）
    privilegeNotEnough: '没有权限访问该位置',
    409: '没有权限访问该位置',
    // 408 = 路径不存在（真机：列不存在的目录 / 没有回收站的共享都是 408）
    fileNotFound: '目标位置不存在（可能已被移动或删除）',
    // 600 = 搜索结果暂时不可用（瞬时态，可重试）
    searchCacheUnavailable: '搜索结果暂时不可用，请稍后再试',
  };

  /// [fileStationMessages] 的**当前应用语言**版本（key 沿用 ARB 的 `err*`）
  /// Audio Station 的业务码 → **中文**文案（官方 `getErrCodeMapping` 逐字）。
  ///
  /// ★★★ **r442（`DA96`）**：音频的业务码**与通用表冲突**，必须按 method 分表。
  ///   真机只读/有界写探针实测（`tool/r442_playlist_songs_probe_test.dart`）：
  ///   `Playlist/updatesongs` **重复加同一首歌** ⇒ 服务端拒绝并回 **411**，
  ///   而 411 在通用表里是 `authAccountLocked`（「账号已锁定」）—— 音频侧的真意是
  ///   `AUDIO_ERR_DUPLICATE_SONGS`（「有重复的歌曲」）。修前播放列表写动作走
  ///   `userFacingError` ⇒ 用户看到的是「DSM 411：账号已锁定」这种**与事实相反的假话**
  ///   （同一轮的控制实验：紧接 411 之后的另一次 `updatesongs` 与 `delete` **都成功**
  ///   ⇒ 账号从未被锁，错的只是文案）。
  ///   ★ 这套文案与音频层的 `describeAudioError` **一字不差**（守卫：
  ///   `test/audio_error_text_r442_test.dart` 逐码比对，防两张表漂移）。
  static const Map<int, String> audioStationMessages = {
    audioInvalidPlaylistName: '播放列表名称不被接受',
    audioFileExists: '同名文件已存在',
    audioTooManySongs: '歌曲数量已达上限',
    audioPlaylistNotExists: '播放列表不存在（DSM 可能正在重建索引）',
    audioDuplicateSongs: '有重复的歌曲',
    audioSharedPlaylistRating: '共享列表里不能复制带评分规则的歌曲',
    audioPinExists: '这个项目已经收藏过了',
    audioPinNotExists: '这个收藏不存在',
    audioPinTargetNotExists: '要收藏的内容不存在',
    audioInvalidPassword: '密码不正确',
  };

  /// [audioStationMessages] 的**当前应用语言**版本（key 与音频层 `asErr*` 同源）。
  static Map<int, String> audioStationMessagesText() => {
    101: dataText(
      'asErrPlaylistNameInvalid',
      audioStationMessages[audioInvalidPlaylistName]!,
    ),
    406: dataText('asErrFileExists', audioStationMessages[audioFileExists]!),
    407: dataText(
      'asErrPlaylistNotExists',
      audioStationMessages[audioPlaylistNotExists]!,
    ),
    409: dataText(
      'asErrTooManySongs',
      audioStationMessages[audioTooManySongs]!,
    ),
    410: dataText(
      'asErrSharedPlaylistRating',
      audioStationMessages[audioSharedPlaylistRating]!,
    ),
    411: dataText(
      'asErrDuplicateSongs',
      audioStationMessages[audioDuplicateSongs]!,
    ),
    412: dataText(
      'asErrPlaylistNotExists',
      audioStationMessages[audioPlaylistNotExists]!,
    ),
    501: dataText(
      'asErrInvalidPassword',
      audioStationMessages[audioInvalidPassword]!,
    ),
    1006: dataText('asErrPinExists', audioStationMessages[audioPinExists]!),
    1007: dataText(
      'asErrPinNotExists',
      audioStationMessages[audioPinNotExists]!,
    ),
    1010: dataText(
      'asErrPinTargetNotExists',
      audioStationMessages[audioPinTargetNotExists]!,
    ),
    1011: dataText(
      'asErrPinTargetNotExists',
      audioStationMessages[audioPinTargetNotExists]!,
    ),
    1201: dataText(
      'asErrDuplicateSongs',
      audioStationMessages[audioDuplicateSongs]!,
    ),
    1202: dataText(
      'asErrPlaylistNotExists',
      audioStationMessages[audioPlaylistNotExists]!,
    ),
  };

  static Map<int, String> fileStationMessagesText() => {
    privilegeNotEnough: dataText(
      'errNoPathPermission',
      fileStationMessages[privilegeNotEnough]!,
    ),
    409: dataText('errNoPathPermission', fileStationMessages[409]!),
    fileNotFound: dataText(
      'errTargetNotFound',
      fileStationMessages[fileNotFound]!,
    ),
    searchCacheUnavailable: dataText(
      'errSearchUnavailable',
      fileStationMessages[searchCacheUnavailable]!,
    ),
  };

  /// [method] 形如 `SYNO.Chat.Post.stick`：Chat 的 API 用 Chat 的错误表
  static String describe(int code, {String? method}) {
    if (method != null && method.startsWith('SYNO.Chat')) {
      final chat = chatMessagesText()[code];
      if (chat != null) return chat;
    }
    if (method != null && method.startsWith('SYNO.FileStation')) {
      final fs = fileStationMessagesText()[code];
      if (fs != null) return fs;
    }
    // ★★★ r443（`DA98`）：**电台**写动词上的 101 不是"播放列表名称"。
    //
    // 真机读数（`tool/r443_radio_batch_delete_probe_test.dart` D 段）：
    // `Radio/updateradios {offset, limit:0, radios_json:'[]'}` ⇒ `101`，
    // 而音频表里 101 的官方文案是「播放列表名称不被接受」—— 一个**电台**的
    // 参数错误却说"播放列表"。101 在官方表里本来就是**双义码**
    // （`AUDIO_ERR_INVALID_PLAYLIST_NAME` / `AUDIO_ERR_COMMON_ERR`），
    // 电台这一侧走的是后者 ⇒ 只说"服务端不接受这次电台请求"，不编具体原因。
    if (method != null &&
        method.startsWith('SYNO.AudioStation.Radio') &&
        code == audioInvalidPlaylistName) {
      return dataText('asErrRadioBadRequest', '电台请求未被服务端接受');
    }
    // ★★★ r442（`DA96`）：音频业务码必须走音频表 —— 否则 411（重复歌曲）
    // 会被通用表解释成「账号已锁定」（`authAccountLocked`）。
    if (method != null && method.startsWith('SYNO.AudioStation')) {
      final audio = audioStationMessagesText()[code];
      if (audio != null) return audio;
    }
    return messagesText()[code] ??
        dataText(
          'apiUnknownErrorCode',
          '错误码 {code}',
        ).replaceAll('{code}', '$code');
  }
}

/// DSM 返回 `success: false` 时抛出
class DsmApiException implements Exception {
  DsmApiException(this.code, {this.method, this.raw});

  final int code;
  final String? method;
  final Map<String, dynamic>? raw;

  bool get needsOtp => code == DsmErrorCode.authOtpRequired;
  bool get badCredentials => code == DsmErrorCode.authInvalidPassword;

  @override
  String toString() =>
      'DsmApiException(${DsmErrorCode.describe(code, method: method)}'
      '${method == null ? '' : ' @ $method'}, code=$code)';
}

/// API 不可达 / 非 JSON 响应
class DsmTransportException implements Exception {
  DsmTransportException(this.message, {this.statusCode, this.uri});
  final String message;
  final int? statusCode;
  final String? uri;

  @override
  String toString() =>
      'DsmTransportException($message${statusCode == null ? '' : ', HTTP $statusCode'})';
}

/// 下载取消句柄。API 层不暴露 dio 类型，内部再转成 `CancelToken`。
class DownloadCancelToken {
  DownloadCancelToken();

  final CancelToken _inner = CancelToken();

  bool get isCancelled => _inner.isCancelled;

  /// 用户点了「取消」
  void cancel([String reason = 'user']) {
    if (!_inner.isCancelled) _inner.cancel(reason);
  }
}

/// 用户点了下载框的「取消」（原版 `DownloadFragment` → `presenter.cancel`）。
/// 这不是错误：界面直接关框、不弹提示、不落盘。
class DownloadCancelledException implements Exception {
  const DownloadCancelledException();

  // 白名单：这是异常的 `toString()`（只进日志/调试输出），按
  // docs/app-identity-and-i18n.md §4.3.1 的「调试串」白名单**不翻**。
  @override
  String toString() => 'DownloadCancelledException(用户取消下载)';
}

// ---------------------------------------------------------------- 传输
/// WebAPI 请求的传输方式
/// multipart 里的**一个文件部分**。
///
/// [field] 是表单字段名 —— 注意 NoteStation 笔记附件用的是
/// "文件名 hashCode 的字符串"（不是 `file`），见 `NoteStationApi`。
/// [fileName] 是 `Content-Disposition` 里的 `filename`（服务端按它取真名）。
class MultipartUploadFile {
  const MultipartUploadFile({
    required this.field,
    required this.path,
    required this.fileName,
    this.mimeType,
  });

  final String field;
  final String path;
  final String fileName;
  final String? mimeType;
}

abstract class WebApiTransport {
  /// DSM 7.4 的 **CSRF 令牌**（= `SYNO.API.Auth login` 里的 `synotoken`）。
  ///
  /// ⚠️ 真机实测（DSM 7.4.1-90080，`tool/flt_home_compress_probe.dart`）：
  /// `SYNO.FileStation.Compress.start` 在 DSM 7.4 上**强制**要这个令牌，
  /// 不带就回 **105**（看起来像"没权限"，其实是缺 CSRF）；而且只要登录时
  /// 带了 `enable_syno_token=yes`，这条会话的**几乎所有**接口都会开始要它
  /// （不带就 119）。官方 DS file 4.17.2 / Drive 3.9.0 的代码里根本没有
  /// 这个字段 —— 它们是 DSM 7.4 之前的产物，所以照抄它们必踩这个坑。
  ///
  /// DSM 认两种放法：`X-SYNO-TOKEN` 头，或 URL 上的 `SynoToken=`；
  /// **放表单体里不认**（实测回 119）。这里用头，URL 型加载器见
  /// [authenticatedUrl]。
  String? synoToken;

  /// POST `{base}webapi/{path}`，form-urlencoded。返回原始响应体。
  /// form-urlencoded 表单。值可以是 String，也可以是 `List<String>`
  /// —— 后者会编码成**重复字段**（`has=thread&has=image`），
  /// 原库 Retrofit 的 `@Field List<String>` 就是这个语义（见 Post/list 的 `has`）。
  Future<String> postForm(
    String path,
    Map<String, dynamic> params, {
    String? module,
  });

  /// POST `{base}webapi/{path}?<query>`，**multipart/form-data**。
  ///
  /// 上传走这条路：元数据（`api`/`method`/`version`/`channel_id`…）拼在
  /// **查询串**上，body 里才是 `conn_id`/`type`/`message`/`file` 这些字段。
  /// 照抄反编译的 `AccountManager.createPost()` 上传分支。
  ///
  /// 默认实现直接抛 [UnsupportedError]：只有真正走网络的传输才需要实现，
  /// 测试里的假传输按需覆盖（不覆盖就说明这个用例不碰上传）。
  ///
  /// [headers] 是**额外的 HTTP 头** —— 不是表单字段。Synology Drive 的
  /// 分片续传要把 `X-TMP-FILE` / `X-TYPE-NAME` / `X-FILE-CHUNK-END`
  /// 放在**真 HTTP 头**上（`ApiSynoDriveFiles.java:52-54,459-467`），
  /// 放表单体里服务端不认，所以必须有这条通道。
  /// 实现里要与 CSRF 头**合并**（后者不能丢）。
  ///
  /// ⚠️ 下面 4 处 `UnsupportedError` 的文案是**开发者诊断**（真机两条传输都
  /// 实现了这些能力，只有假传输漏实现时才会冒出来），按
  /// docs/app-identity-and-i18n.md §4.3.1 的「调试串」白名单**不翻**。
  Future<String> postMultipart(
    String path, {
    required Map<String, dynamic> query,
    required Map<String, String> fields,
    String? fileField,
    String? filePath,
    String? fileName,
    String? mimeType,
    List<MultipartUploadFile>? files,
    void Function(int sent, int total)? onProgress,
    Map<String, String>? headers,
    String? module,
  }) => throw UnsupportedError('$describeKind 不支持 multipart 上传');

  /// 带鉴权的二进制下载（附件/缩略图）。
  ///
  /// URL 由 [DsmWebApi.authenticatedUrl] 生成（`_sid` 挂在查询串上，
  /// 这样 `Image.network` 这类不共享 cookie 的加载器也能用）。
  ///
  /// [maxBytes] 非空时带 `Range: bytes=0-<maxBytes-1>`，只取**开头一段**
  /// —— 文本预览靠它避免为看 20 行把 2GB 日志整份拉下来。
  /// 服务端实测支持（HTTP 206 + `content-range`）。
  ///
  /// [tailBytes] 非空时带 `Range: bytes=-<tailBytes>`，只取**末尾一段**
  /// —— 内嵌封面（MP4 的 `moov` 在文件尾 / MKV 的 Attachments 追加在末尾）
  /// 靠它避免为了封面下载整个大文件。两者互斥，[tailBytes] 优先。
  ///
  /// 默认实现抛 [UnsupportedError]，理由同上。
  Future<List<int>> getBytes(
    String url, {
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
    int? maxBytes,
    int? tailBytes,
    String? module,
  }) => throw UnsupportedError('$describeKind 不支持二进制下载');

  /// POST `{base}webapi/{path}`（form-urlencoded）→ **原始字节**。
  ///
  /// 为什么需要它：`SYNO.Office.Export/download` 这类"导出/下载"接口是
  /// **POST 表单**语义 —— 官方前端 `SYNO.API.Utils.download` 把参数放在
  /// **表单体**里（iOS 分支甚至是造一个隐藏 form 直接 submit）。
  /// 真机实测（2026-09-20）：同样的 `format=pdf` 放查询串上被服务端忽略，
  /// 回的是默认导出（docx，`PK` 头）；改走 POST 表单才拿到真 PDF。
  ///
  /// 默认实现抛 [UnsupportedError]（假传输按需覆盖）。
  Future<List<int>> postBytes(
    String path,
    Map<String, dynamic> params, {
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
    String? module,
  }) => throw UnsupportedError('$describeKind 不支持 POST 二进制下载');

  /// 生成带 `_sid` 的完整 URL（同 `AccountManager.getStreamingUrlOfPostId`）。
  String authenticatedUrl(
    String path,
    Map<String, String> params, {
    String? sid,
  }) => throw UnsupportedError('$describeKind 不支持直接拼 URL');

  /// GET `{base}webapi/query.cgi`（`SYNO.API.Info` 也接受 POST，这里统一用 POST）
  Future<String> describe({String? module});

  /// 用于日志与调试
  String get describeKind;

  /// 服务器根地址（末尾带 `/`）。贴纸图片这类静态资源不走 `webapi/`，
  /// 需要自己拼完整 URL（见 `ChatApi.stickerImageUrl`）。
  String get baseUrl;

  Future<void> close();
}

/// 直连（LAN / DDNS / 外网 IP）
class DirectTransport extends WebApiTransport {
  DirectTransport({
    required String host,
    required int port,
    bool https = true,
    Dio? dio,
    Duration? timeout,
  }) : baseUrl = '${https ? 'https' : 'http'}://$host:$port/',
       _dio = attachTrafficMeter(
         dio ??
             Dio(
               BaseOptions(
                 connectTimeout: timeout ?? const Duration(seconds: 15),
                 receiveTimeout: timeout ?? const Duration(seconds: 30),
                 validateStatus: (s) => s != null,
               ),
             ),
       );

  DirectTransport.url(String url, {Dio? dio, Duration? timeout})
    : baseUrl = url.endsWith('/') ? url : '$url/',
      _dio = attachTrafficMeter(
        dio ??
            Dio(
              BaseOptions(
                connectTimeout: timeout ?? const Duration(seconds: 15),
                receiveTimeout: timeout ?? const Duration(seconds: 30),
                validateStatus: (s) => s != null,
              ),
            ),
      );

  @override
  final String baseUrl;
  final Dio _dio;

  @override
  String get describeKind => 'direct($baseUrl)';

  @override
  Future<String> postForm(
    String path,
    Map<String, dynamic> params, {
    String? module,
  }) async {
    final uri = '$baseUrl${_normalize(path)}';
    try {
      final resp = await _dio.post<dynamic>(
        uri,
        data: params,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
          headers: _csrfHeaders(synoToken),
          extra: trafficExtra(module),
        ),
      );
      return _bodyOf(resp, uri);
    } on DioException catch (e) {
      throw DsmTransportException(
        e.message ?? dataText('apiRequestFailed', '请求失败'),
        statusCode: e.response?.statusCode,
        uri: uri,
      );
    }
  }

  @override
  Future<String> postMultipart(
    String path, {
    required Map<String, dynamic> query,
    required Map<String, String> fields,
    String? fileField,
    String? filePath,
    String? fileName,
    String? mimeType,
    List<MultipartUploadFile>? files,
    void Function(int sent, int total)? onProgress,
    Map<String, String>? headers,
    String? module,
  }) async {
    final form = FormData.fromMap({
      ...fields,
      if (fileField != null && filePath != null)
        fileField: await MultipartFile.fromFile(
          filePath,
          filename: fileName,
          contentType: mimeType == null ? null : MediaType.parse(mimeType),
        ),
      // 多文件（笔记附件：一次 set 可以带多个文件，字段名各不相同）
      if (files != null)
        for (final f in files)
          f.field: await MultipartFile.fromFile(
            f.path,
            filename: f.fileName,
            contentType: f.mimeType == null
                ? null
                : MediaType.parse(f.mimeType!),
          ),
    });
    final uri = _urlWith('$baseUrl${_normalize(path)}', query);
    try {
      final resp = await _dio.post<dynamic>(
        uri,
        data: form,
        options: Options(
          responseType: ResponseType.plain,
          headers: {...?_csrfHeaders(synoToken), ...?headers},
          extra: trafficExtra(module),
        ),
        onSendProgress: onProgress,
      );
      return _bodyOf(resp, uri);
    } on DioException catch (e) {
      throw DsmTransportException(
        // 与 E2EE 页共用 e2eeUploadFailed：同一句中文共用一个 key（§4.4）
        e.message ?? dataText('e2eeUploadFailed', '上传失败'),
        statusCode: e.response?.statusCode,
        uri: uri,
      );
    }
  }

  @override
  Future<List<int>> getBytes(
    String url, {
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
    int? maxBytes,
    int? tailBytes,
    String? module,
  }) async {
    try {
      final resp = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            ...?_csrfHeaders(synoToken),
            if (tailBytes != null && tailBytes > 0)
              'Range': 'bytes=-$tailBytes'
            else if (maxBytes != null && maxBytes > 0)
              'Range': 'bytes=0-${maxBytes - 1}',
          },
          extra: trafficExtra(module),
        ),
        onReceiveProgress: onProgress,
        cancelToken: cancelToken?._inner,
      );
      return _bytesOf(
        resp.data,
        resp.statusCode,
        url,
        contentType: resp.headers.value('content-type'),
      );
    } on DioException catch (e) {
      // 用户取消（原版 `DownloadFragment` 的取消按钮）不是错误
      if (CancelToken.isCancel(e)) throw const DownloadCancelledException();
      throw DsmTransportException(
        e.message ?? dataText('apiDownloadFailed', '下载失败'),
        statusCode: e.response?.statusCode,
        uri: url,
      );
    }
  }

  @override
  Future<List<int>> postBytes(
    String path,
    Map<String, dynamic> params, {
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
    String? module,
  }) async {
    final uri = '$baseUrl${_normalize(path)}';
    try {
      final resp = await _dio.post<List<int>>(
        uri,
        data: params,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.bytes,
          headers: _csrfHeaders(synoToken),
          extra: trafficExtra(module),
        ),
        onReceiveProgress: onProgress,
        cancelToken: cancelToken?._inner,
      );
      return _bytesOf(
        resp.data,
        resp.statusCode,
        uri,
        contentType: resp.headers.value('content-type'),
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) throw const DownloadCancelledException();
      throw DsmTransportException(
        e.message ?? dataText('apiDownloadFailed', '下载失败'),
        statusCode: e.response?.statusCode,
        uri: uri,
      );
    }
  }

  @override
  String authenticatedUrl(
    String path,
    Map<String, String> params, {
    String? sid,
  }) => authenticatedQueryUrl(
    '$baseUrl${_normalize(path)}',
    params,
    sid: sid,
    synoToken: synoToken,
  );

  /// **权威的"带鉴权 URL"拼装**：`_sid` 与 `SynoToken` **都进查询串**。
  ///
  /// 为什么必须是查询串：原生播放器（Media3 / ExoPlayer）**发不了自定义头**，
  /// 它拿到的 URL 必须自带给养。只把 `SynoToken` 放 `X-SYNO-TOKEN` 头是**不够**的
  /// —— DSM 7.4 的 CSRF 对"下载/图片 URL"只认查询串里的 `SynoToken=`（见
  /// `api-server-authoritative.md` §15）。缺了它服务端回 **HTTP 200 +
  /// `{"error":{"code":119}}`**，Media3 把这段 JSON 当"没有 extractor 能读的流"
  /// （`UnrecognizedInputFormatException` / `None of the available extractors…`），
  /// 真机上就表现为"系统解码器不支持这个文件的编码"；而**同一个文件**交给系统
  /// 应用打开完全正常 —— 这正是"误报编码不支持"的根。
  ///
  /// 直连与隧道**共用这一个函数**：两条传输以前各写一遍，隧道那条漏了
  /// `SynoToken`（隧道下所有内嵌音视频都挂，而走 `getBytes` 的文本/PDF 因为有
  /// `X-SYNO-TOKEN` 头而正常 —— 这就是"文本能看、媒体不能播"的由来）。
  static String authenticatedQueryUrl(
    String base,
    Map<String, String> params, {
    String? sid,
    String? synoToken,
  }) {
    final withCsrf = <String, String>{
      ...params,
      if (synoToken != null && synoToken.isNotEmpty) 'SynoToken': synoToken,
    };
    return _urlWith(base, withCsrf, sid: sid);
  }

  @override
  Future<String> describe({String? module}) => postForm('query.cgi', {
    'api': 'SYNO.API.Info',
    'version': '1',
    'method': 'query',
    'query': 'all',
  }, module: module);

  @override
  Future<void> close() async {}

  /// 拼 `?a=b&c=d`；`List` 值展开成重复字段
  static String _urlWith(
    String base,
    Map<String, dynamic> query, {
    String? sid,
  }) {
    final qp = <String, dynamic>{...query};
    if (sid != null && sid.isNotEmpty) qp['_sid'] = sid;
    final buf = StringBuffer(base);
    var first = !base.contains('?');
    qp.forEach((k, v) {
      final values = v is List ? v : [v];
      for (final item in values) {
        buf.write(first ? '?' : '&');
        first = false;
        buf.write('$k=${Uri.encodeQueryComponent('$item')}');
      }
    });
    return buf.toString();
  }

  /// CSRF 头（没有令牌就啥也不加 —— 老 DSM 没有这回事）
  static Map<String, String>? _csrfHeaders(String? token) =>
      (token == null || token.isEmpty) ? null : {'X-SYNO-TOKEN': token};

  static String _normalize(String path) {
    var p = path;
    if (p.startsWith('/')) p = p.substring(1);
    return p.startsWith('webapi/') ? p : 'webapi/$p';
  }

  /// 二进制响应的校验：**非 2xx 一律当失败**，且 **2xx 里的 JSON 错误信封
  /// 也不当内容**。
  ///
  /// 踩过的坑（两个，第二个是 R6 真机暴露的真实缺口）：
  ///   1. `DioFactory` 把 `validateStatus` 放宽成"任何状态码都算成功"，
  ///      于是文件不存在时（Thumb → 404、Download → 502）Dio 不抛异常，
  ///      我们高高兴兴把一张 DSM 的 **HTML 错误页**当成图片/文件返回：
  ///      下载会写出一个 `.html` 冒充的 `.png`，缩略图会渲染成空白。
  ///   2. **`HTTP 200 + {"success":false,"error":{"code":…}}`** —— DSM 用 200
  ///      承载错误是常态（`--error-http-status` 默认 200）。以前这里只看状态码，
  ///      于是把这段 JSON **原文当文件内容**：预览页直接把
  ///      `{"success":false,"error":{"code":119}}` 显示出来，下载也当成功写盘
  ///      → 119（会话失效）被漏判（R6-4a，截图 `r6-4a-119-200.png`）。
  ///      现在识别成 [DsmApiException]（带 `error.code`）→ 上层走既有错误分类
  ///      （`describeFileError` / `classifyErrorCode`）：119/106 会话失效、
  ///      105/160 无权限、102 未安装、其它明确错误。
  static List<int> _bytesOf(
    List<int>? data,
    int? status,
    String uri, {
    String? contentType,
  }) {
    final code = status ?? 0;
    if (code < 200 || code >= 300) {
      throw _errorFromBody(data, code, uri);
    }
    final envelope = _errorEnvelopeMap(data, contentType);
    if (envelope != null) {
      // r387/DA36：`{"code":120,"name":"list_id"}` 里的 `name` 必须留到
      // `raw` 里 —— 它是"哪个参数无效"的唯一线索。
      throw DsmApiException(
        envelope['code'] as int,
        raw: {...envelope, 'http': code, 'uri': uri},
      );
    }
    if (data == null || data.isEmpty) {
      throw DsmTransportException(
        dataText('apiEmptyDownload', '空下载'),
        statusCode: status,
        uri: uri,
      );
    }
    return data;
  }

  /// DSM 错误信封的**体积上限**：`{"success":false,"error":{"code":…}}` 只有
  /// 几十字节。超过这个大小的一律不当信封 —— 避免把"以 `{` 开头、以 `}`
  /// 结尾的真实文本/JSON 文件"整份当成错误吞掉。
  static const int kMaxErrorEnvelopeBytes = 512;

  /// `content-type` 明确是**二进制/媒体**类型 → 内容不可能是 DSM 的 JSON 信封。
  ///
  /// 这是"真实二进制零回归"的第一道闸：PDF/图片/音视频/压缩包即使恰好能被
  /// 当成 JSON 解析，也不进信封判定。
  static bool _isBinaryContentType(String? contentType) {
    if (contentType == null) return false;
    final ct = contentType.toLowerCase().trim();
    return ct.startsWith('image/') ||
        ct.startsWith('audio/') ||
        ct.startsWith('video/') ||
        ct.startsWith('font/') ||
        ct.startsWith('application/octet-stream') ||
        ct.startsWith('application/pdf') ||
        ct.startsWith('application/zip') ||
        ct.startsWith('application/x-') ||
        ct.startsWith('application/vnd.');
  }

  /// 从二进制响应体里识别 **DSM 的 JSON 错误信封**，返回 `error.code`。
  ///
  /// 判定刻意保守（宁可漏判也不误伤真实内容）：
  ///   * 只认**整个响应体**（去空白后）就是一个 JSON 对象且以 `{`/`}` 收尾；
  ///   * `success` 必须**显式**为 `false`（`{"success":true}` / 真文件都不认）；
  ///   * `error.code` 必须是 `int`；
  ///   * 体积 ≤ [kMaxErrorEnvelopeBytes]；
  ///   * [contentType] 不是明确的二进制/媒体类型。
  /// 从二进制响应体里识别 **DSM 的 JSON 错误信封**，返回整个 `error` 对象。
  ///
  /// ★★ r387（DA36）：DSM 对"参数无效"的回包是
  /// `{"success":false,"error":{"code":120,"name":"list_id","reason":"required"}}`
  /// —— **`name` 才是根因所在**。以前这里只把 `code` 带出去，
  /// `name`/`reason` 被丢掉 ⇒ 真机上只能看到"请求参数无效"，
  /// 永远读不出是**哪个**参数不对（下载选文件页卡在这里，
  /// 见 `docs/android-ui-audit-r387.md` DA36）。
  /// 现在把服务端给的原字段整份留下（`DsmApiException.raw`），
  /// 供排障读取；**涉及隐私的字段不在这个信封里**（只有 code/name/reason）。
  static Map<String, dynamic>? _errorEnvelopeMap(
    List<int>? data,
    String? contentType,
  ) {
    if (data == null || data.isEmpty || data.length > kMaxErrorEnvelopeBytes) {
      return null;
    }
    if (_isBinaryContentType(contentType)) return null;
    try {
      final text = utf8.decode(data, allowMalformed: true).trim();
      if (text.length < 8 || !text.startsWith('{') || !text.endsWith('}')) {
        return null;
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      if (decoded['success'] != false) return null;
      final err = decoded['error'];
      if (err is! Map) return null;
      if (err['code'] is! int) return null;
      return Map<String, dynamic>.from(err);
    } catch (_) {
      return null;
    }
  }

  /// 错误正文可能是 JSON（`{"error":{"code":119},"success":false}`）
  /// 也可能是一整页 HTML。前者还原成 [DsmApiException]（带错误码，UI 才能
  /// 说人话），后者退化成 [DsmTransportException]。
  static Exception _errorFromBody(List<int>? data, int status, String uri) {
    if (data != null && data.isNotEmpty) {
      try {
        final text = utf8.decode(data, allowMalformed: true).trim();
        final decoded = jsonDecode(text);
        if (decoded is Map && decoded['error'] is Map) {
          final err = decoded['error'] as Map;
          final c = err['code'];
          if (c is int) {
            // r387/DA36：服务端给的 `name`/`reason` 一并留下（以前只留 code）。
            return DsmApiException(c, raw: {
              ...Map<String, dynamic>.from(err),
              'http': status,
              'uri': uri,
            });
          }
        }
      } catch (_) {
        // 不是 JSON：大概率是 DSM 的 HTML 错误页，按传输层错误处理
      }
    }
    return DsmTransportException('HTTP $status', statusCode: status, uri: uri);
  }

  static String _bodyOf(Response<dynamic> resp, String uri) {
    final data = resp.data;
    if (data is String) {
      if (data.isEmpty) {
        throw DsmTransportException(
          dataText('apiEmptyResponse', '空响应'),
          statusCode: resp.statusCode,
          uri: uri,
        );
      }
      return data;
    }
    throw DsmTransportException(
      dataText('apiNonTextResponse', '非文本响应'),
      statusCode: resp.statusCode,
      uri: uri,
    );
  }
}

/// 走空洞穿透隧道（`https://127.0.0.1:<port>/`）
///
/// 原生事件循环没有自己的线程，必须由调用方驱动，所以这里在请求期间
/// 挂一个周期性 `punch.pump()`。
class TunnelTransport extends WebApiTransport {
  TunnelTransport(
    this.punch, {
    Dio? dio,
    Duration? timeout,
    this.pumpInterval = const Duration(milliseconds: 5),
  }) : _dio = attachTrafficMeter(
         dio ??
             Dio(
               BaseOptions(
                 connectTimeout: timeout ?? const Duration(seconds: 20),
                 receiveTimeout: timeout ?? const Duration(seconds: 60),
                 validateStatus: (s) => s != null,
               ),
             ),
       );

  final SynoPunch punch;
  final Dio _dio;
  final Duration pumpInterval;

  Timer? _pumpTimer;

  @override
  String get describeKind => 'tunnel(127.0.0.1:${punch.tcpPort})';

  @override
  String get baseUrl => 'https://127.0.0.1:${punch.tcpPort}/';

  int get port => punch.tcpPort;

  /// 启动周期性 pump。请求期间必须开着，否则隧道不动。
  void startPump() {
    _pumpTimer ??= Timer.periodic(pumpInterval, (_) {
      if (punch.isRunning) punch.pump(timeoutMs: 0);
    });
  }

  void stopPump() {
    _pumpTimer?.cancel();
    _pumpTimer = null;
  }

  @override
  Future<String> postForm(
    String path,
    Map<String, dynamic> params, {
    String? module,
  }) async {
    final port = punch.tcpPort;
    if (port == 0) {
      throw DsmTransportException(
        dataText('apiTunnelNotStarted', '隧道未启动（tcpPort == 0）'),
      );
    }
    final uri = 'https://127.0.0.1:$port/${DirectTransport._normalize(path)}';

    startPump();
    try {
      final resp = await _dio.post<dynamic>(
        uri,
        data: params,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
          headers: DirectTransport._csrfHeaders(synoToken),
          extra: trafficExtra(module),
        ),
      );
      return DirectTransport._bodyOf(resp, uri);
    } on DioException catch (e) {
      throw DsmTransportException(
        e.message ?? dataText('apiTunnelRequestFailed', '隧道请求失败'),
        statusCode: e.response?.statusCode,
        uri: uri,
      );
    } finally {
      stopPump();
    }
  }

  @override
  Future<String> postMultipart(
    String path, {
    required Map<String, dynamic> query,
    required Map<String, String> fields,
    String? fileField,
    String? filePath,
    String? fileName,
    String? mimeType,
    List<MultipartUploadFile>? files,
    void Function(int sent, int total)? onProgress,
    Map<String, String>? headers,
    String? module,
  }) async {
    final port = punch.tcpPort;
    if (port == 0) {
      throw DsmTransportException(
        dataText('apiTunnelNotStarted', '隧道未启动（tcpPort == 0）'),
      );
    }
    final form = FormData.fromMap({
      ...fields,
      if (fileField != null && filePath != null)
        fileField: await MultipartFile.fromFile(
          filePath,
          filename: fileName,
          contentType: mimeType == null ? null : MediaType.parse(mimeType),
        ),
      if (files != null)
        for (final f in files)
          f.field: await MultipartFile.fromFile(
            f.path,
            filename: f.fileName,
            contentType: f.mimeType == null
                ? null
                : MediaType.parse(f.mimeType!),
          ),
    });
    final uri = DirectTransport._urlWith(
      'https://127.0.0.1:$port/${DirectTransport._normalize(path)}',
      query,
    );
    startPump();
    try {
      final resp = await _dio.post<dynamic>(
        uri,
        data: form,
        options: Options(
          responseType: ResponseType.plain,
          headers: {...?DirectTransport._csrfHeaders(synoToken), ...?headers},
          extra: trafficExtra(module),
        ),
        onSendProgress: onProgress,
      );
      return DirectTransport._bodyOf(resp, uri);
    } on DioException catch (e) {
      throw DsmTransportException(
        e.message ?? dataText('apiTunnelUploadFailed', '隧道上传失败'),
        statusCode: e.response?.statusCode,
        uri: uri,
      );
    } finally {
      stopPump();
    }
  }

  @override
  Future<List<int>> getBytes(
    String url, {
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
    int? maxBytes,
    int? tailBytes,
    String? module,
  }) async {
    // 隧道场景下下载要一直 pump，否则隧道不动
    if (url.contains('127.0.0.1:$port')) startPump();
    try {
      final resp = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            ...?DirectTransport._csrfHeaders(synoToken),
            if (tailBytes != null && tailBytes > 0)
              'Range': 'bytes=-$tailBytes'
            else if (maxBytes != null && maxBytes > 0)
              'Range': 'bytes=0-${maxBytes - 1}',
          },
          extra: trafficExtra(module),
        ),
        onReceiveProgress: onProgress,
        cancelToken: cancelToken?._inner,
      );
      return DirectTransport._bytesOf(
        resp.data,
        resp.statusCode,
        url,
        contentType: resp.headers.value('content-type'),
      );
    } on DioException catch (e) {
      // 用户取消（原版 `DownloadFragment` 的取消按钮）不是错误
      if (CancelToken.isCancel(e)) throw const DownloadCancelledException();
      throw DsmTransportException(
        e.message ?? dataText('apiDownloadFailed', '下载失败'),
        statusCode: e.response?.statusCode,
        uri: url,
      );
    } finally {
      stopPump();
    }
  }

  @override
  Future<List<int>> postBytes(
    String path,
    Map<String, dynamic> params, {
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
    String? module,
  }) async {
    final port = punch.tcpPort;
    if (port == 0) {
      throw DsmTransportException(
        dataText('apiTunnelNotStarted', '隧道未启动（tcpPort == 0）'),
      );
    }
    final uri = 'https://127.0.0.1:$port/${DirectTransport._normalize(path)}';
    startPump();
    try {
      final resp = await _dio.post<List<int>>(
        uri,
        data: params,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.bytes,
          headers: DirectTransport._csrfHeaders(synoToken),
          extra: trafficExtra(module),
        ),
        onReceiveProgress: onProgress,
        cancelToken: cancelToken?._inner,
      );
      return DirectTransport._bytesOf(
        resp.data,
        resp.statusCode,
        uri,
        contentType: resp.headers.value('content-type'),
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) throw const DownloadCancelledException();
      throw DsmTransportException(
        e.message ?? dataText('apiTunnelDownloadFailed', '隧道下载失败'),
        statusCode: e.response?.statusCode,
        uri: uri,
      );
    } finally {
      stopPump();
    }
  }

  @override
  String authenticatedUrl(
    String path,
    Map<String, String> params, {
    String? sid,
  }) {
    final port = punch.tcpPort;
    if (port == 0) return '';
    return DirectTransport.authenticatedQueryUrl(
      'https://127.0.0.1:$port/${DirectTransport._normalize(path)}',
      params,
      sid: sid,
      synoToken: synoToken,
    );
  }

  @override
  Future<String> describe({String? module}) => postForm('query.cgi', {
    'api': 'SYNO.API.Info',
    'version': '1',
    'method': 'query',
    'query': 'all',
  }, module: module);

  @override
  Future<void> close() async {
    stopPump();
  }
}

// ---------------------------------------------------------------- API 描述
class DsmApiEntry {
  const DsmApiEntry({
    required this.name,
    required this.path,
    required this.minVersion,
    required this.maxVersion,
    this.requestFormat,
  });

  final String name;
  final String path;
  final int minVersion;
  final int maxVersion;

  /// `SYNO.API.Info` 里的 `requestFormat`（活服务器：`"JSON"` / 缺省＝表单）。
  ///
  /// ★ 这不是装饰字段：官方《DS file》4.17.2 的
  /// `WebApiConnectionManager.createNameValuePairs` 按
  /// `Api.isRequestFormatJson()`（= `requestFormat == "JSON"`）**二选一**
  /// 决定参数值怎么编码 —— JSON 格式的 API 一律 `jsonEncode`，
  /// 其余才走 v1 逗号 / v2 JSON 数组，**与版本无关**。
  final String? requestFormat;

  /// 该 API 是否声明 `requestFormat: "JSON"`（缺字段 = 按表单处理）
  bool get isJsonFormat => requestFormat == 'JSON';

  factory DsmApiEntry.fromJson(String name, Map<String, dynamic> j) =>
      DsmApiEntry(
        name: name,
        path: (j['path'] as String?) ?? '',
        minVersion: _int(j['minVersion']),
        maxVersion: _int(j['maxVersion']),
        requestFormat: _str(j['requestFormat']),
      );

  /// 在 [min,max] 里挑一个不超过 [preferred] 的版本
  int negotiate(int preferred) {
    if (preferred > maxVersion) return maxVersion;
    if (preferred < minVersion) return minVersion;
    return preferred;
  }

  @override
  String toString() =>
      '$name → ${path.isEmpty ? '(unknown)' : path} '
      'v$minVersion..$maxVersion';
}

// ---------------------------------------------------------------- 会话
/// `DsmWebApi` 的**共享**会话/能力表状态。
///
/// 本体与 [DsmWebApi.withModule] 生成的视图必须看到同一份，
/// 否则登录后的 `sid` / API 表到不了视图。
class _DsmApiState {
  Map<String, DsmApiEntry>? apis;
  DsmSession? session;
  bool retryLoginDisabled = false;
  Future<void>? reloginFuture;
}

class DsmSession {
  const DsmSession({
    required this.sid,
    this.did,
    this.synotoken,
    this.account,
    this.isPortal = false,
  });

  final String sid;
  final String? did;
  final String? synotoken;
  final String? account;
  final bool isPortal;

  @override
  String toString() =>
      'DsmSession(sid=${sid.length > 6 ? '${sid.substring(0, 6)}…' : sid}'
      '${did == null ? '' : ', did=$did'})';
}

// ---------------------------------------------------------------- 客户端
/// DSM WebAPI 客户端。传输可换 —— 直连或隧道，上层代码不变。
///
/// ## 流量归属（第 276 轮）
///
/// [withModule] 生成一个**共享同一会话状态**的"视图"，给所有经过它的请求
/// 打上流量模块标签（`core/net/traffic_meter.dart`）。业务 API 类在构造器里
/// 绑定自己的模块（如 `FileStationApi` → `files`），于是**调用点显式声明的
/// 归属**一路传到 Dio 适配器，不需要从 URL / API 名去猜。
/// 没有绑定的句柄 → 请求落 `unattributed`（宁可显示"未归属"，不静默丢）。
class DsmWebApi {
  DsmWebApi(this.transport)
    : trafficModule = null,
      _st = _DsmApiState();

  /// 内部：与 [base] 共享会话/能力表，只多一个流量模块标签
  DsmWebApi._scoped(this.transport, this._st, this.trafficModule);

  final WebApiTransport transport;

  /// 会话 / API 表的**共享状态**：视图与本体必须看到同一份，
  /// 否则登录后的 `sid` 到不了视图（这是"视图"能否成立的关键）。
  final _DsmApiState _st;

  /// 这个句柄给请求打的流量模块标签（null / 空 = 未归属）
  final String? trafficModule;

  /// 生成一个带模块标签的视图（共享会话）
  ///
  /// ★★ 第 287 轮**关键修复**：视图**必须继承会话过期钩子**。
  /// `_st` 共享的是会话/方法表/重登 Future，而 `onSessionExpired`/
  /// `onSessionLost` 是**实例字段** ⇒ 原来 `ChatApi(api.withModule(...))`
  /// 这些模块句柄拿到的是 `null` 钩子 ⇒ `_shouldRetryLogin` 在
  /// `onSessionExpired == null` 处直接返回 false ⇒ **119 永不重登、原样抛给用户**。
  /// 实证：`session_relogin_test` 的 `lastReloginError=null`（钩子路径压根没进），
  /// 以及 `media_session_renew_test` 的 3 条（同一形态）。
  DsmWebApi withModule(String module) {
    final view = DsmWebApi._scoped(transport, _st, module);
    view.onSessionExpired = onSessionExpired;
    view.onSessionLost = onSessionLost;
    return view;
  }

  Map<String, DsmApiEntry>? get _apis => _st.apis;
  DsmSession? get _session => _st.session;

  DsmSession? get session => _session;
  Map<String, DsmApiEntry>? get apiTable => _apis;

  // ------------------------------------------------ 会话过期自动重登
  //
  // 对齐原版 `RetryInterceptor`：请求拿到 **119（sidNotFound）** 时，**重新登录**
  // （内部会
  // 重新 `SYNO.API.Encryption getinfo` + `SYNO.API.Auth login`）再**把原请求
  // 重放一次**，用户完全无感。105 不再触发（确定性失败，见
  // `DsmErrorCode.retryLoginCodes` 的说明）。
  //
  // 分工：`DsmWebApi` 只负责"发现过期 → 叫上层重登 → 重放"，
  // 账号口令由上层持有并注入 [onSessionExpired]（见 `SessionController`）。

  /// 重新登录。由持有账号口令的层注入；返回即视为已拿到新 sid。
  ///
  /// 抛 [DsmApiException] 表示重登失败；抛的码若在
  /// [DsmErrorCode.skipRetryLoginCodes] 里，则**永久**关掉自动重登
  /// （原版的 `skip_retry_login` 偏好）。
  Future<void> Function()? onSessionExpired;

  /// ★ 第 287 轮：**上一次重登失败的原因**（只读诊断位，纯 Dart，不 import Flutter）。
  ///
  /// 为什么需要它：`_tryRelogin` 原来只 `return false`，把重登时抛的异常**整个丢掉**，
  /// 于是调用方只会看到最开始的 `119` —— `test/session_relogin_test.dart` 与
  /// `test/media_session_renew_test.dart`（4 条红）查了四轮都像"不明异常"。
  /// 这是 §2.0.17「静默降级必须能说出原因」的同类问题。
  Object? lastReloginError;

  /// 重登失败且不可恢复时通知上层（原版 `AuthManager.setException`）。
  void Function(int code)? onSessionLost;

  /// 重登彻底失败后置位；成功 `login()` 会复位
  bool get _retryLoginDisabled => _st.retryLoginDisabled;
  Future<void>? get _reloginFuture => _st.reloginFuture;

  /// 自动重登是否已被关掉（测试/UI 可以看）
  bool get retryLoginDisabled => _retryLoginDisabled;

  /// `SYNO.API.Info / query` —— 发现所有 API 的路径与版本区间
  Future<Map<String, DsmApiEntry>> discover() async {
    final json = _decode(
      await transport.describe(module: trafficModule),
      'SYNO.API.Info',
    );
    final data = _okData(json, 'SYNO.API.Info');
    final out = <String, DsmApiEntry>{};
    data.forEach((k, v) {
      if (v is Map) {
        out[k] = DsmApiEntry.fromJson(k, Map<String, dynamic>.from(v));
      }
    });
    _st.apis = out;
    return out;
  }

  /// `SYNO.Core.Desktop.Timeout / check` v1 —— **会话存活探针**。
  ///
  /// ## 为什么有这个方法（APK 证据，不是猜的）
  ///
  /// DSfile 4.17.2-609 `WebApiConnectionManager.smali`：
  /// ```text
  /// :3458  const-string v2, "SYNO.Core.Desktop.Timeout"
  ///        const-string v3, "check"
  ///        invoke-direct {p0, v2, v3, v0(=1), emptyList()}
  ///          ->doWebApiQuery(String,String,int,List)   // 方法名是 **check**
  /// :7764  iget-object p1, …->mKnownAPIs
  ///        const-string v0, "SYNO.Core.Desktop.Timeout"
  ///        invoke-interface {p1, v0}->containsKey(...)   // ★ 还是**登录时的能力表闸门**
  ///        … 不在表里 ⇒ new WebApiLoginException(-100)
  /// ```
  ///
  /// ## 真机契约（本会话只读探针，普通用户）
  /// ```text
  /// 带 _sid  : {"success":true}          ← 只有 success，**没有 data**
  /// 不带 _sid: {"error":{"code":119}}    ← 119 就是"会话已失效"
  /// ```
  ///
  /// ## 语义
  /// 它是**心跳**：只回 `success`，不返回值。用来在回前台/长时间空闲后
  /// **主动**判掉 119，而不是等用户点下去才炸。
  ///
  /// ⚠️ 能力表里没有这个 API（老 DSM）时**返回 true**（"无法判定"），
  /// 不能当成"会话失效" —— 否则会在旧机器上把好会话误杀。
  ///
  /// ⚠️ 它**不在**会话失效码集合的触发路径上：本方法自己吃掉 119 并返回 false，
  /// 由调用方决定要不要重登，**不会**触发 `call()` 的重登+重放。
  Future<bool> checkSessionAlive() async {
    final table = _apis;
    if (table != null && !table.containsKey('SYNO.Core.Desktop.Timeout')) {
      return true; // 这台机器没有这个 API ⇒ 无法判定，不妄下结论
    }
    try {
      // ⚠️ **刻意不走 `call()`**：`call()` 对 119 会触发"重登 + 重放"，
      // 而这条方法要的是**纯观测** —— 探针自己去重登，就把"会话已经没了"
      // 这个事实抹掉了（重登失败还会抛别的码，反而更看不出真相）。
      // 所以直接用 `_prepare` + `_send` 发一次，不重试。
      final req = _prepare(
        'SYNO.Core.Desktop.Timeout',
        'check',
        1,
        const {},
        true,
      );
      await _send(req, 'SYNO.Core.Desktop.Timeout', 'check');
      return true;
    } on DsmApiException catch (e) {
      // 119 = sidNotFound（会话没了）。其他错误（103/104/网络）都不能
      // 断言"会话失效" ⇒ 返回 true，交给常规错误处理。
      if (e.code == DsmErrorCode.sidNotFound) return false;
      return true;
    } catch (_) {
      return true;
    }
  }

  /// 通用调用。[preferredVersion] 会按服务器声明的区间收敛。
  Future<Map<String, dynamic>> call(
    String api,
    String method, {
    int preferredVersion = 1,
    Map<String, dynamic> params = const {},
    bool requiresAuth = true,
  }) async {
    final req = _prepare(api, method, preferredVersion, params, requiresAuth);
    try {
      return await _send(req, api, method);
    } on DsmApiException catch (e, st) {
      if (!_shouldRetryLogin(e, api, requiresAuth)) rethrow;
      if (!await _tryRelogin(e, st)) {
        // 重登没成功：保留**原始**错误（119），调用方关心的是这个
        Error.throwWithStackTrace(e, st);
      }
      // 用**新**的 sid 重放一次（`_prepare` 会重新取 `_session`）
      final retry = _prepare(
        api,
        method,
        preferredVersion,
        params,
        requiresAuth,
      );
      return await _send(retry, api, method);
    }
  }

  /// 重登一次。成功返回 true；失败返回 false（原始错误由调用方保留）；
  /// 若重登拿到"再登也没用"的码，直接把它抛出去（并已置 [retryLoginDisabled]）。
  Future<bool> _tryRelogin(DsmApiException original, StackTrace st) async {
    try {
      await _relogin();
      return true;
    } on DsmApiException catch (loginErr) {
      lastReloginError = loginErr;
      if (DsmErrorCode.skipRetryLoginCodes.contains(loginErr.code)) rethrow;
      return false;
    } catch (e) {
      lastReloginError = e;
      return false;
    }
  }

  /// 组装一次请求（api/version/method/参数/`_sid`）
  ({String path, Map<String, dynamic> all}) _prepare(
    String api,
    String method,
    int preferredVersion,
    Map<String, dynamic> params,
    bool requiresAuth,
  ) {
    var version = preferredVersion;
    var path = _pathHint(api);

    final table = _apis;
    if (table != null && table.containsKey(api)) {
      final entry = table[api]!;
      version = entry.negotiate(preferredVersion);
      if (entry.path.isNotEmpty) path = entry.path;
    } else if (table != null && !table.containsKey(api)) {
      throw DsmApiException(DsmErrorCode.apiNotFound, method: '$api.$method');
    }

    final all = <String, dynamic>{
      'api': api,
      'version': '$version',
      'method': method,
      ...params,
    };
    if (requiresAuth && _session != null) {
      all['_sid'] = _session!.sid;
    }
    return (path: path, all: all);
  }

  Future<Map<String, dynamic>> _send(
    ({String path, Map<String, dynamic> all}) req,
    String api,
    String method,
  ) async {
    final json = _decode(
      await transport.postForm(req.path, req.all, module: trafficModule),
      '$api.$method',
    );
    return _okData(json, '$api.$method');
  }

  /// 这次错误该不该触发"重登 + 重放"？（对齐原版拦截器的取舍）
  bool _shouldRetryLogin(DsmApiException e, String api, bool requiresAuth) {
    if (!requiresAuth) return false;
    // 登录/取公钥自身重试没有意义，会自己套自己
    if (api == 'SYNO.API.Auth' || api == 'SYNO.API.Encryption') return false;
    if (_retryLoginDisabled) return false;
    if (onSessionExpired == null) return false;
    return DsmErrorCode.retryLoginCodes.contains(e.code);
  }

  /// 并发请求一起过期时，只登一次，大家都等同一个 Future
  Future<void> _relogin() {
    final running = _reloginFuture;
    if (running != null) return running;
    final f = _runRelogin();
    _st.reloginFuture = f;
    return f.whenComplete(() => _st.reloginFuture = null);
  }

  Future<void> _runRelogin() async {
    try {
      await onSessionExpired!();
    } on DsmApiException catch (e) {
      if (DsmErrorCode.skipRetryLoginCodes.contains(e.code)) {
        _st.retryLoginDisabled = true;
        onSessionLost?.call(e.code);
      }
      rethrow;
    } catch (e) {
      onSessionLost?.call(DsmErrorCode.unknown);
      rethrow;
    }
  }

  /// `SYNO.API.Auth / login`
  ///
  /// [version] 默认 **7**。APK 里的取值：1 基础、4 portal、5 OTP、
  /// 6 OTP+设备记忆、7 = DSM 7.4 的"带 CSRF 令牌"登录。
  ///
  /// ⚠️ **为什么必须是 7**（真机实测，DSM 7.4.1-90080）：
  /// v6 与 v7 都会在 `enable_syno_token=yes` 时回一个 `synotoken`，但
  /// **只有 v7 发的令牌能通过 `SYNO.FileStation.Compress.start` 的 CSRF 校验**：
  /// 用 v6 的令牌（形如 `oMPgXz4IuCCgA`）→ 接口回 **105**；用 v7 的令牌
  /// （形如 `SAN.4Rjh7fbD2`）→ 正常返回 taskid。105 极易被误判成"没权限"，
  /// 实际是缺 CSRF —— DSM 网页端能压缩、我们的客户端不能，就是这个原因。
  /// 隔离探针：`tool/flt_cookie_probe.dart`（同一份代码只换 Auth 版本）。
  Future<DsmSession> login({
    required String account,
    required String password,
    String session = 'Chat',
    String? otpCode,
    String? deviceId,
    String? deviceName,
    bool enableDeviceToken = false,
    bool isPortal = false,
    int version = 7,
  }) async {
    // 上一会话的令牌先清掉：login 本身是匿名接口，不该带旧令牌
    transport.synoToken = null;
    if (_apis == null) {
      try {
        await discover();
      } catch (_) {
        // 服务器不支持 query 时降级：用未知路径，靠 pathHint
      }
    }

    // ① getinfo —— 拿 RSA 公钥与 cipherkey / ciphertoken
    final info = await call(
      'SYNO.API.Encryption',
      'getinfo',
      preferredVersion: 1,
      requiresAuth: false,
    );
    final cipher = DsmCipherData.fromJson(info);

    // ② 按 APK 的做法：**只加密 account / passwd**
    //
    // ⚠️ `otp_code` / `enable_device_token` / `device_id` 一律**明文**，别塞进密文。
    // DS file 4.17.2 的 `WebApiConnectionManager.loginDsm()` 原文：
    //   `encryptFromParamList([(account,…), (passwd,…)])` 之后
    //   `if (otpCode非空) { otp_code; if (信任设备) enable_device_token=yes }`
    //   `if (authMaxVersion>=6 && 本地存过 deviceId) { device_id; device_name }`
    // 之前我们把 otp/信任开关放进密文，服务端读不到 → **永远拿不到 `did`**，
    // 于是"记住此设备"名存实亡（用户实测反馈）。
    final toEncrypt = <String, String>{'account': account, 'passwd': password};

    final params = <String, String>{
      ...DsmCgiEncryption(cipher).encryptFromParamList(toEncrypt),
      // ↓ 以下全部是**明文**字段，与原库一致
      'client_time': '${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      'session': session,
      // ⚠️ DSM 7.4 必须显式要令牌：不带这个参数服务端不回 synotoken，
      // 于是 `SYNO.FileStation.Compress.start` 会以一个非常误导的 105 失败。
      'enable_syno_token': 'yes',
    };
    if (otpCode != null && otpCode.isNotEmpty) {
      params['otp_code'] = otpCode;
      // 只在这里发：它表示"这次验证码通过后，把这台设备记下来"
      if (enableDeviceToken) params['enable_device_token'] = 'yes';
    }
    if (deviceId != null && deviceId.isNotEmpty) {
      // 上次服务端给的 `did`：带回去就不必再验证码（原库 `TrustDeviceManager`）
      params['device_id'] = deviceId;
      params['device_name'] = deviceName ?? 'Flutter - Chat';
    } else {
      params['device_name'] = deviceName ?? 'Flutter - Chat';
    }

    Map<String, dynamic> data;
    try {
      data = await call(
        'SYNO.API.Auth',
        'login',
        preferredVersion: version,
        params: params,
        requiresAuth: false,
      );
    } on DsmApiException catch (e) {
      // v7 不被支持（老 DSM / 老包）→ 退回 v6 再试一次。
      // 注意**只在"版本不支持"这类协议错上退**：OTP/密码错必须原样抛出去，
      // 否则会把"要验证码"吞掉再拿密码去撞一次。
      final fallbackable = {
        DsmErrorCode.apiNotFound,
        DsmErrorCode.notSupportedVersion,
        DsmErrorCode.badRequest,
      };
      if (version < 7 || !fallbackable.contains(e.code)) rethrow;
      data = await call(
        'SYNO.API.Auth',
        'login',
        preferredVersion: 6,
        params: params,
        requiresAuth: false,
      );
    }

    final sid = data['sid'] as String?;
    if (sid == null || sid.isEmpty) {
      throw DsmApiException(
        DsmErrorCode.unknown,
        method: 'SYNO.API.Auth.login',
      );
    }

    _st.session = DsmSession(
      sid: sid,
      // v7 回的是 `device_id`（不再是 `did`），两个都认
      did: data['did'] as String? ?? data['device_id'] as String?,
      synotoken: data['synotoken'] as String?,
      account: account,
      isPortal: isPortal,
    );
    // 登录后就把它挂到传输层：DSM 7.4 的会话一旦带令牌，后续请求都要带
    transport.synoToken = _session!.synotoken;
    _st.retryLoginDisabled = false; // 登录成功 → 重新允许自动重登
    return _session!;
  }

  /// `SYNO.API.Auth / logout`
  ///
  /// `session` 必须是 `Chat`、版本用 6 —— 原版 `AccountManager.logout`
  /// 传的就是 `LoggerUtil.TAG`("Chat") 与 `getMaxAvailableVersion(6,1)`；
  /// 传错 session 服务端不会真正注销这条会话（2.11.1 源码 AccountManager.java:342）。
  ///
  /// ⚠️ **必须带 `_sid`**（`requiresAuth: true`）：服务端是靠 `_sid` 认"要注销
  /// 哪条会话"的。真机探针实测（`tool/flt_relogin_probe.dart`）：
  ///   * 带 sid 调 logout → 紧接着用同一个 sid 调 `Channel/list` 拿到 **119**；
  ///   * 不带 sid（原实现）→ 会话在服务端**根本没被注销**（登出等于没登出，
  ///     NAS 上一直挂着一条活会话）。
  /// 原版是靠 OkHttp 的 cookie jar（`SynoSharedPrefsCookiePersistor`）自动带上
  /// sid 的，所以它的 logout 也是"认证请求"。
  Future<void> logout({String session = 'Chat'}) async {
    if (_session == null) return;
    try {
      await call(
        'SYNO.API.Auth',
        'logout',
        preferredVersion: 6,
        params: {'session': session},
      );
    } catch (_) {
      // 登出失败不阻断本地清理
    }
    _st.session = null;
    transport.synoToken = null;
  }

  /// 只做认证探测，不建立会话 —— 用于比较直连与隧道的可达性
  Future<bool> ping() async {
    try {
      await discover();
      return true;
    } catch (_) {
      return false;
    }
  }

  void close() {
    _st.session = null;
    transport.close();
  }

  // ------------------------------------------------------------ 内部
  /// query 不可用时的路径回退（APK 里这些是固定的）
  static String _pathHint(String api) {
    const hints = {
      'SYNO.API.Info': 'query.cgi',
      'SYNO.API.Auth': 'auth.cgi',
      'SYNO.API.Encryption': 'encryption.cgi',
      'SYNO.Entry.Request': 'entry.cgi',
      'SYNO.Chat.Channel': 'entry.cgi',
      'SYNO.Chat.Message': 'entry.cgi',
      'SYNO.Chat.User': 'entry.cgi',
    };
    return hints[api] ?? 'entry.cgi';
  }

  static Map<String, dynamic> _decode(String body, String what) {
    Object? parsed;
    try {
      parsed = jsonDecode(body);
    } catch (_) {
      throw DsmTransportException(
        dataText(
              'apiResponseNotJson',
              '{what}: 响应不是合法 JSON（前 120 字节: {preview}）',
            )
            .replaceAll('{what}', what)
            .replaceAll(
              '{preview}',
              body.length > 120 ? body.substring(0, 120) : body,
            ),
      );
    }
    if (parsed is! Map) {
      throw DsmTransportException(
        dataText(
          'apiResponseNotJsonObject',
          '{what}: 响应不是 JSON 对象',
        ).replaceAll('{what}', what),
      );
    }
    return Map<String, dynamic>.from(parsed);
  }

  /// 某个 API 的 cgi 路径（`query.cgi` / `entry.cgi`）。
  ///
  /// 上传/下载这类不能走普通 `call` 的请求要自己拼 URL，就需要这个。
  String apiPath(String api) {
    final entry = _apis?[api];
    if (entry != null && entry.path.isNotEmpty) return entry.path;
    return 'entry.cgi';
  }

  /// 把原始响应体解成 `data`（上传接口复用同一套 success/error 解析）
  Map<String, dynamic> decodeData(String raw, String what) =>
      _okData(_decode(raw, what), what);

  /// 带 `_sid` 的完整 URL（附件下载/缩略图用；`null` 表示还没登录）
  String authenticatedUrl(String path, Map<String, String> params) =>
      transport.authenticatedUrl(path, params, sid: _session?.sid);

  /// 这条会话有没有 CSRF 令牌（登录时 `enable_syno_token=yes` 服务端才会回）。
  ///
  /// 媒体层用它决定"URL 必须带 `SynoToken` 吗"：有令牌就**必须**出现在查询串
  /// （原生播放器发不了 `X-SYNO-TOKEN` 头，缺了服务端回 119，Media3 会误报成
  /// "编码不支持"）；老 DSM 不回令牌 → false，此时不强求 URL 带它。
  bool get hasSynoToken => transport.synoToken?.isNotEmpty ?? false;

  /// 服务器根地址（贴纸等静态资源用）
  String get baseUrl => transport.baseUrl;

  /// 二进制下载（[maxBytes] / [tailBytes] 见 `WebApiTransport.getBytes`：
  /// 分别只取开头一段 / 末尾一段）
  Future<List<int>> getBytes(
    String url, {
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
    int? maxBytes,
    int? tailBytes,
  }) => transport.getBytes(
    url,
    onProgress: onProgress,
    cancelToken: cancelToken,
    maxBytes: maxBytes,
    tailBytes: tailBytes,
    module: trafficModule,
  );

  /// POST 表单 → 原始字节（导出类接口；参数进 **form body**，不是查询串）。
  ///
  /// `_sid` 由传输层在 body 里带上（DSM 两种都认，官方 Web 就是放 body），
  /// CSRF 令牌走 `X-SYNO-TOKEN` 头（与其它 POST 一致）。
  Future<List<int>> postBytesForm(
    String path,
    Map<String, dynamic> params, {
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
  }) {
    final sid = _session?.sid;
    return transport.postBytes(
      path,
      {...params, if (sid != null) '_sid': sid},
      onProgress: onProgress,
      cancelToken: cancelToken,
      module: trafficModule,
    );
  }

  /// multipart 上传（元数据在查询串，字段在 body）
  Future<String> postMultipart(
    String path, {
    required Map<String, dynamic> query,
    required Map<String, String> fields,
    String? fileField,
    String? filePath,
    String? fileName,
    String? mimeType,
    List<MultipartUploadFile>? files,
    void Function(int sent, int total)? onProgress,
    Map<String, String>? headers,
  }) => transport.postMultipart(
    path,
    query: query,
    fields: fields,
    fileField: fileField,
    filePath: filePath,
    fileName: fileName,
    mimeType: mimeType,
    files: files,
    onProgress: onProgress,
    headers: headers,
    module: trafficModule,
  );

  static Map<String, dynamic> _okData(Map<String, dynamic> json, String what) {
    final ok = json['success'] == true;
    if (!ok) {
      final err = json['error'];
      var code = DsmErrorCode.unknown;
      if (err is Map && err['code'] is num) {
        code = (err['code'] as num).toInt();
      }
      throw DsmApiException(code, method: what, raw: json);
    }
    final data = json['data'];
    if (data is Map) return Map<String, dynamic>.from(data);
    return const <String, dynamic>{};
  }
}

int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

/// `SYNO.API.Info` 里的字符串字段（缺字段 / 类型不对 ⇒ `null`，不抛）
String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;
