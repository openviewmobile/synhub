// 统一服务能力注册表（能力层）。
//
// 目标（见 `docs/service-availability-design.md` §2.1）：
//   * 把"某个服务需要哪些服务端 API 才算可用"集中成**一份可离线测的数据**；
//   * 供状态层（`service_availability.dart`）算 available / partial / absent；
//   * 供呈现层（`visible_tabs` / 工作台入口）决定隐藏或降级。
//
// ⚠️ **纯 Dart 纪律**：本文件**不得** import `package:flutter/**`、
// `package:l10n/**` 或 material —— `tool/*.dart` 下的探针用纯 Dart VM 直接
// 加载数据层，碰了 Flutter 符号就编不过（见 `lib/src/core/i18n/data_text.dart`
// 顶部注释）。错误码常量也刻意**不** import `dsm/webapi.dart`（那会拖进 dio 与
// FFI），改为在这里镜像一份，并由 `test/service_registry_test.dart` 断言两处一致。
//
// API 名一律取自既有权威资料，**不得臆造**：
//   * DSM 套件（FileStation / SynologyPhotos / NoteStation / Calendar /
//     Contacts / SynologyDrive / Office）→ `docs/api-server-authoritative.md`
//     的实测方法表（该表由 `analyze_package.py apis` 从 `.lib` 读出）；
//   * 打包套件（Chat / AudioStation / DownloadStation / SurveillanceStation /
//     MailPlus）→ 各自的调研文档与 `lib/src/data/*.dart` 里已经在用的常量：
//       - Chat：`test/support/chat_harness.dart` 的实测能力表 +
//         `docs/client-station-plan.md`、Phase 3–9 协议文档；
//       - Audio/Download：`docs/station-audio-download-research.md`、
//         `docs/stage2-audio-download-api.md`；
//       - Surveillance/MailPlus：
//         `docs/station-surveillance-mailplus-insight-research.md`。
//   * ai：**端侧模型 + 自带 key 的云端 LLM** 是本机能力，**不需要** NAS
//     服务端 API → `requiredApis` 为空（永不 `absent` / 隐藏）；
//     NAS 侧 AI Console（`SYNO.AI.Completion` / `.Thread` / `.Config` /
//     `.Metrics`）登记为**可选能力位**（可选增强）。
//
// ⚠️ **更正（2026-09-21）**：本文件旧注释与 `docs/ebook-reader-plan.md:43`
// 曾写「`SYNO.API.Info` 里没有任何 `SYNO.AI.*`」——该结论已被**无凭据活体探针
// 推翻**：真机 `SYNO.API.Info` 共 977 个 API（该数字是 **AS/DS 安装前**的
// 普查数；用户装上 Audio Station / Download Station 后为 **1047**，
// 见 `docs/audio-parity-audit.md:93`），含 **34 个 `SYNO.AI.*`** 与
// **17 个 `SYNO.Finder.*`**。探针只证明「方法存在 + 需会话」，**证明不了
// `allowUser`**，因此可选购／`partial` 路径**不做任何权限判定**。
library;

// ---------------------------------------------------------------- 错误码镜像

/// 与 `DsmErrorCode.apiNotFound`（`lib/src/dsm/webapi.dart`）一致。
/// "服务端明确没有这个 API"——**唯一**允许把服务判成 `absent`（隐藏 tab）的
/// 调用级证据。
const int kApiNotFoundCode = 102;

/// 与 `DsmErrorCode.sidNotFound` 一致。会话无效 → `unauthorized`（**不隐藏**）。
const int kSidNotFoundCode = 119;

/// 与 `DsmErrorCode.noPermission` 一致。**已安装但该账号无权使用** →
/// `unauthorized`。用户 2026-09-21 决策：**也隐藏**（避免"看得见用不了"的矛盾）。
const int kNoPermissionCode = 105;

/// 与 `DsmErrorCode.noAppPrivilege` 一致（160）。DSM「应用程序权限」被拒
/// （`docs/p1-notestation-implementation.md:84`：160 = 没有 Note Station 应用权限）
/// → `unauthorized`，同样隐藏。
const int kNoAppPrivilegeCode = 160;

/// 与 `DsmErrorCode.sessionTimeout` 一致。**会话超时 ≠ 无权限**：
/// → `sessionExpired`，**绝不隐藏**（否则会话一过期整个 App 变空白）。
const int kSessionTimeoutCode = 106;

// ---------------------------------------------------------------- 服务

/// 所有需要统一检测的服务。
///
/// 顺序不影响呈现（呈现用 [kReplacementOrder]）；这里只是枚举清单。
enum StationService {
  chat,
  file,
  photo,
  note,
  calendar,
  contacts,
  drive,
  office,
  audio,
  download,
  surveillance,
  mailplus,

  /// 端侧 / 云端 AI：本机能力（端侧模型 + 自带 key 的云端 LLM），
  /// **不需要** NAS 服务端 API → 恒不隐藏；NAS 侧 AI Console 是可选增强
  /// （见文件头注释的 2026-09-21 更正）。
  ai,
}

/// 主 tab 槽位：只有 chat / file / photo 占底栏的三个"内容槽"。
enum PrimarySlot { chat, files, photos }

/// 一个服务的必需/可选 API 向量。
class ServiceSpec {
  const ServiceSpec({
    required this.id,
    required this.requiredApis,
    this.optionalApis = const [],
    this.appPrivilegeKeys = const [],
    this.primarySlot,
  });

  final StationService id;

  /// 全部存在 → `available`；任一缺失 → `absent`（隐藏主 tab）。
  final List<String> requiredApis;

  /// `required` 都在、部分缺失 → `partial`（模块可用，缺失功能降级）。
  final List<String> optionalApis;

  /// **信号 1**：该模块在 `SYNO.Core.Desktop.Initdata:get` 的 `AppPrivilege`
  /// 里的键（一个模块可有多个键，**任一命中**即算命中）。
  ///
  /// 取值语义**照抄官方前端**（`/tmp/spk/export_SynologyPhotos/ui/*.js` 的
  /// `FotoReactLibrary` 打包产物原文）：
  /// ```js
  /// !0===SYNO.SDS.AppPrivilege["SYNO.ALLOW.ALL.APPLICATIONS"] ||
  ///   void 0!==SYNO.SDS.AppPrivilege[e] && !1!==SYNO.SDS.AppPrivilege[e]
  /// ```
  /// 即：键**存在且不为 `false`** → 该用户可用此应用；键为 `false` →
  /// **无权限**（等价 105）；键**不存在** → 官方前端判"不允许"。
  ///
  /// 每个键的出处逐条写在 [kServiceRegistry] 的条目注释里。空列表 = 该模块
  /// 没有可用的 AppPrivilege 信号（目前只有 [StationService.ai]）。
  final List<String> appPrivilegeKeys;

  /// 非 null 才占底栏内容槽。
  final PrimarySlot? primarySlot;

  /// 这个 API 是否属于本服务（必需或可选）。
  ///
  /// 供 `file_providers.dart` 的能力位复用同一份 API 表，避免散落的 `hasApi`。
  bool contains(String api) =>
      requiredApis.contains(api) || optionalApis.contains(api);

  /// 必需 + 可选的并集（测试构造"服务齐全"的能力表用）。
  Set<String> get allApis => {...requiredApis, ...optionalApis};
}

/// 服务注册表。API 名的出处逐条写在下面的注释里。
const Map<StationService, ServiceSpec> kServiceRegistry = {
  // ---- Chat：打包套件，方法表来自实测（chat_harness.dart）与 Phase 文档。
  // 必需：频道 / 消息 / 用户三条主链路；可选：设置、贴纸、投票、定时等。
  StationService.chat: ServiceSpec(
    id: StationService.chat,
    // 信号 1 取证（等级 B）：`/tmp/spk` 下**没有** Chat 解包件，键取自真机
    // `AppPrivilege` 全量 20 项（`docs/live-nas-verification.md:751`）+ §8.2:726
    // （`SYNO.SDS.Chat.Application=true`、`JSConfig` 有 `Chat`）。
    appPrivilegeKeys: ['SYNO.SDS.Chat.Application'],
    primarySlot: PrimarySlot.chat,
    requiredApis: [
      'SYNO.Chat.Channel', // chat_harness.dart 能力表；phase3 频道链路
      'SYNO.Chat.Post', // chat_harness.dart；phase4 消息链路
      'SYNO.Chat.User', // chat_harness.dart；phase3 用户列表
    ],
    optionalApis: [
      'SYNO.Chat.Admin.Setting', // phase9 服务端能力/限制
      'SYNO.Chat.Post.Reaction', // phase6 表情回应
      'SYNO.Chat.Post.Vote', // phase6 投票
      'SYNO.Chat.Post.Schedule', // phase6 定时消息
      'SYNO.Chat.Post.Reminder', // phase6 提醒
      'SYNO.Chat.Sticker', // phase5 贴纸目录
      'SYNO.Chat.User.Avatar', // 头像取图
      'SYNO.Chat.Channel.Named', // 命名频道管理
    ],
  ),

  // ---- File Station：权威表 docs/api-server-authoritative.md §FileStation
  // （`SYNO.FileStation.List` v1–2，普通用户）。可选 8 项 = 既有
  // `FileCapabilities` 的 8 个能力位（file_providers.dart:342-349）。
  StationService.file: ServiceSpec(
    id: StationService.file,
    // 信号 1 取证（等级 A）：`/tmp/spk/export_FileStation/INFO` 的
    // `dsmappname="SYNO.SDS.App.FileStation3.Instance"`；真机 AppPrivilege 同键。
    appPrivilegeKeys: ['SYNO.SDS.App.FileStation3.Instance'],
    primarySlot: PrimarySlot.files,
    requiredApis: [
      'SYNO.FileStation.List', // authoritative §FileStation
    ],
    optionalApis: [
      'SYNO.FileStation.Search', // 既有能力位 canSearch
      'SYNO.FileStation.Sharing', // 既有能力位 canShare
      'SYNO.FileStation.Compress', // 既有能力位 canCompress
      'SYNO.FileStation.Extract', // 既有能力位 canExtract
      'SYNO.FileStation.Favorite', // 既有能力位 canFavorite
      'SYNO.FileStation.BackgroundTask', // 既有能力位 canBackgroundTask
      'SYNO.FileStation.VirtualFolder', // 既有能力位 canVirtualFolder
      'SYNO.FileStation.Thumb', // 缩略图（file_providers thumbnailUrl）
      'SYNO.FileStation.Download', // 下载直链
    ],
  ),

  // ---- Synology Photos：权威表 §SynologyPhotos（Browse.Item / Browse.Album
  // 均为普通用户）。Streaming 缺 → 视频不可播（partial，不隐藏相册）。
  StationService.photo: ServiceSpec(
    id: StationService.photo,
    // 信号 1 取证（等级 A）：`/tmp/spk/export_SynologyPhotos/INFO` 的
    // `dsmappname="SYNO.Foto.AppInstance"`；官方前端打包产物里正是
    // `WQ("SYNO.Foto.AppInstance")`（`SYNO.SDS.AppPrivilege[...]` 查表）；
    // 真机 AppPrivilege 同键 = true。
    appPrivilegeKeys: ['SYNO.Foto.AppInstance'],
    primarySlot: PrimarySlot.photos,
    requiredApis: [
      'SYNO.Foto.Browse.Item', // authoritative；foto_api.dart 时间轴/相册项
      'SYNO.Foto.Browse.Album', // authoritative；foto_api.dart 相册
    ],
    optionalApis: [
      'SYNO.Foto.Streaming', // 视频播放直链（photo_viewer_page.dart:356）
      'SYNO.Foto.Thumbnail', // 缩略图
      'SYNO.Foto.Download', // 原图下载
      // 批次②（图生图）补缺：`foto_api.dart` 已实现 `Upload.Item`（`uploadToTimeline`
      // / `uploadToFolder` / backup），但**从未列入能力表**。缺位只隐藏
      // "AI 美化 → 保存到相册"，"保存到本机"仍可用（fail-open：未检测不降级）。
      kFotoUploadApi,
      'SYNO.Foto.Setting.User', // 用户相册设置
      // ---- C2（Photos 补齐）：横切能力。每一条只降级**自己那个入口**
      // （`photo_c2_page.dart` 的 hub），**绝不隐藏 Photos 模块本身**。
      'SYNO.Foto.Sharing.Misc', // 共享相册（与我共享 / 可共享用户组）
      'SYNO.Foto.PhotoRequest', // 照片请求（收图链接）
      'SYNO.Foto.Browse.Geocoding', // 地点 / 地理编码
      'SYNO.Foto.Search.Search', // 搜索
      'SYNO.Foto.Search.Filter', // 筛选项（只被搜索页用；缺了不另设入口）
      'SYNO.Foto.Browse.ConditionAlbum', // 条件相册
      'SYNO.Foto.Browse.Similar', // 相似照片（还要看用户设置 enable_similar）
    ],
  ),

  // ---- Note Station：authoritative §NoteStation。
  StationService.note: ServiceSpec(
    id: StationService.note,
    // 信号 1 取证（等级 A）：`/tmp/spk/export_NoteStation/INFO` 的
    // `dsmappname="SYNO.SDS.NoteStation.Application"`；真机 AppPrivilege 同键。
    appPrivilegeKeys: ['SYNO.SDS.NoteStation.Application'],
    requiredApis: [
      'SYNO.NoteStation.Note', // authoritative（15 处）
      'SYNO.NoteStation.Notebook', // 笔记本列表
    ],
    optionalApis: [
      'SYNO.NoteStation.Todo', // 待办
      'SYNO.NoteStation.Tag', // 标签
      'SYNO.NoteStation.Note.Encrypt', // 加密笔记
      'SYNO.NoteStation.Permission', // 权限
      // ---- C3（NoteStation 补齐）：版本 / 导出 / 导入 ----
      // 缺位 → **只隐藏对应入口**（`partial`，**不隐藏笔记模块本身**）。
      'SYNO.NoteStation.Note.Version', // 版本历史（列出/预览/回滚）
      'SYNO.NoteStation.Export.Word', // 导出为 Word
      'SYNO.NoteStation.Export.Note', // 导出为 .nsx
      'SYNO.NoteStation.Export.Notebook', // 笔记本导出到 NAS 目录
      'SYNO.NoteStation.Import.Enex', // 导入 Evernote .enex
      'SYNO.NoteStation.Import.Notebook', // 导入 .nsx
      'SYNO.NoteStation.Import.Evernote', // Evernote 账号云导入
    ],
  ),

  // ---- Calendar：authoritative §Calendar。
  StationService.calendar: ServiceSpec(
    id: StationService.calendar,
    // 信号 1 取证（等级 A）：`/tmp/spk/export_Calendar/INFO` 的
    // `dsmappname="SYNO.Cal.Application"`（注意**不是** `SYNO.SDS.*` 前缀）；
    // 真机 AppPrivilege 同键。
    appPrivilegeKeys: ['SYNO.Cal.Application'],
    requiredApis: [
      'SYNO.Cal.Event', // authoritative；calendar_api.dart eventApi
    ],
    optionalApis: [
      'SYNO.Cal.Todo',
      'SYNO.Cal.Setting',
      // ---- C4（Calendar / Contacts 外部源补齐）：**只隐藏对应入口** ----
      // `AuthForeign` 存在但**真机不可用**（`list` 回 117）：缺位时把
      // 「外部日历（暂不支持）」那条说明入口一起藏掉（`partial`），
      // **不隐藏日历模块本身**。
      'SYNO.Cal.AuthForeign',
      // 远端日历只读列表（`Proxy/cal_list`）。缺位只影响"外部日历"这一块。
      'SYNO.Cal.Proxy',
    ],
  ),

  // ---- Contacts：authoritative §Contacts。
  StationService.contacts: ServiceSpec(
    id: StationService.contacts,
    // 信号 1 取证（等级 A）：`/tmp/spk/export_Contacts/INFO` 的
    // `dsmappname="SYNO.Contacts.AppInstance"`；真机 AppPrivilege 同键。
    appPrivilegeKeys: ['SYNO.Contacts.AppInstance'],
    requiredApis: [
      'SYNO.Contacts.Contact', // authoritative；contacts_api.dart
    ],
    optionalApis: [
      'SYNO.Contacts.Addressbook', // 通讯录
      'SYNO.Contacts.Label', // 标签
      'SYNO.Contacts.ExternalSource', // 外部源
      'SYNO.Contacts.Info', // 服务信息
      // ---- C4：组织单位（分组）只读树 ----
      // 缺位 → 只隐藏「分组（组织单位）」那一处入口（`partial`），
      // **不隐藏联系人模块**（见 `contacts_manage_page.dart` 的 tab 门控）。
      'SYNO.Contacts.OU',
    ],
  ),

  // ---- Synology Drive：authoritative §SynologyDrive（Files v1–11，普通用户）。
  StationService.drive: ServiceSpec(
    id: StationService.drive,
    // 信号 1 取证（等级 A）：`/tmp/spk/export_SynologyDrive/INFO` 的
    // `dsmappname=` 里含 `SYNO.SDS.Drive.Application`（用户可见入口那一个；
    // 同一行还有 CSTN / Office / Upload 等内部实例，不作为模块门控）；
    // 真机 AppPrivilege 同键。
    appPrivilegeKeys: ['SYNO.SDS.Drive.Application'],
    requiredApis: [
      'SYNO.SynologyDrive.Files', // authoritative；drive_api.dart
    ],
    optionalApis: [
      'SYNO.SynologyDrive.Sharing',
      'SYNO.SynologyDrive.Revisions',
      'SYNO.SynologyDrive.Trash',
      'SYNO.SynologyDrive.Tasks',
      'SYNO.SynologyDrive.Labels',
      'SYNO.SynologyDrive.TeamFolders',
      // C1（Drive 补齐）：以下四位的原文证据见
      // `/tmp/spk/out/SynologyDrive.apis.txt`（行号写在常量注释处）与
      // `docs/workspace-expansion-evaluation.md` 实施记录。缺任一位 →
      // `partial`，只隐藏对应入口，**不隐藏整个 Drive**。
      'SYNO.SynologyDrive.AdvanceSharing', // apis.txt:9
      'SYNO.SynologyDrive.FileRequest', // apis.txt:39
      'SYNO.SynologyDrive.NodeLocking', // apis.txt:106
      'SYNO.SynologyDrive.Notifications', // apis.txt:112
    ],
  ),

  // ---- Office：authoritative §Office（SYNO.Office.Node v1–2，普通用户）。
  StationService.office: ServiceSpec(
    id: StationService.office,
    // 信号 1 取证（等级 A，但**键在本机真值里缺席**）：
    // `/tmp/spk/export_Office/INFO` 的 `dsmappname="SYNO.SDS.Office.AppInstance
    // SYNO.SDS.Office.Sheet.Application …"`；然而真机 AppPrivilege 全量 20 项
    // 里**一个 Office 键都没有**（`docs/live-nas-verification.md:746-757`），
    // 而 Office 确实已装（API 49 + `Info:get`=3.7.2）。
    // ⇒ 在 Office 上"该键缺席"**不是**"未安装"的证据；Office 的存在性由
    // **信号 2**（`SYNO.Office.Node`）判。合并规则（signal2 全缺席才看信号 1）
    // 保证这里不会被误判成 absent。
    appPrivilegeKeys: ['SYNO.SDS.Office.AppInstance'],
    requiredApis: [
      'SYNO.Office.Node', // authoritative:854
    ],
    optionalApis: [
      'SYNO.Office.Node.Version', // 版本历史（authoritative:442）
      'SYNO.Office.File',
      'SYNO.Office.Export',
      'SYNO.Office.Import',
      // 只读原生内容树（真机 `get v4` = 200，见 live-nas-verification §⑦）。
      // **可选**：缺位只让本模块降级成 `partial`（该通道跳过并回落），
      // 绝不隐藏；119/106 也**绝不隐藏**（hidesModule 只管 absent/unauthorized）。
      'SYNO.Office.Snapshot',
    ],
  ),

  // ---- Audio Station：docs/station-audio-download-research.md:155。
  StationService.audio: ServiceSpec(
    id: StationService.audio,
    // 信号 1 取证（等级 A）：`/tmp/spk/export_AudioStation/INFO` 的
    // `dsmappname="SYNO.SDS.AudioStation.Application"`。
    // ⚠️ 2026-09-21 真值刷新：旧注释写「真机 AppPrivilege 无此键 = 未安装」，
    // **已过期**——用户装上 Audio Station 7.2.1-6006 后，
    // `Core.Desktop.Initdata` 的
    // `AppPrivilege["SYNO.SDS.AudioStation.Application"] = true`，且
    // `SYNO.API.Info` 有 27 个 `SYNO.AudioStation.*` 命名空间
    // （`docs/audio-parity-audit.md:224,:95`）→ 真机应判 `available`。
    // 本处**只订正注释**：键值 / 阈值 / 判定逻辑一字未改。
    appPrivilegeKeys: ['SYNO.SDS.AudioStation.Application'],
    requiredApis: [
      'SYNO.AudioStation.Song', // 曲库主链路（song.cgi）
    ],
    optionalApis: [
      'SYNO.AudioStation.Info', // audio_station.dart:73
      'SYNO.AudioStation.Playlist',
      'SYNO.AudioStation.Stream', // 播放直链
      'SYNO.AudioStation.Cover',
      'SYNO.AudioStation.Pin', // audio_station.dart:86
      'SYNO.AudioStation.Search',
    ],
  ),

  // ---- Download Station：新版 synoapid `SYNO.DownloadStation2.Task`
  // （docs/station-audio-download-research.md:461、download_station.dart:71）。
  // 注意**不是**老的 `SYNO.DownloadStation.Task`。
  StationService.download: ServiceSpec(
    id: StationService.download,
    // 信号 1 取证（等级 A）：`/tmp/spk/export_DownloadStation/INFO` 的
    // `dsmappname="SYNO.SDS.DownloadStation.Application"`。
    // ⚠️ 2026-09-21 真值刷新：旧注释「真机 AppPrivilege 无此键」**已过期**
    // ——用户装上 Download Station 4.1.2-5012 后，真机 `SYNO.API.Info` 注册了
    // 43 个 `SYNO.DownloadStation*.*` 命名空间（`docs/download-parity-audit.md:44-45`）
    // → 真机应判 `available`。该 AppPrivilege 键**是否下发未单独取证**
    // （`docs/download-parity-audit.md:531`，未确认项 U9）；因信号 2 命中，
    // 判定不依赖它。本处**只订正注释**：键值 / 判定逻辑一字未改。
    appPrivilegeKeys: ['SYNO.SDS.DownloadStation.Application'],
    requiredApis: [
      'SYNO.DownloadStation2.Task', // download_station.dart:71
    ],
    optionalApis: [
      'SYNO.DownloadStation2.Task.Statistic', // download_station.dart:72
      'SYNO.DownloadStation2.Settings.Location', // download_station.dart:74
      'SYNO.DownloadStation2.Task.List', // 任务列表轮询
    ],
  ),

  // ---- Surveillance Station：未装包时 Camera.List 回 102（实测）；
  // station-surveillance-mailplus-insight-research.md:130。
  StationService.surveillance: ServiceSpec(
    id: StationService.surveillance,
    // 信号 1 取证（等级 A）：`/tmp/spk/ex_SS/INFO` 的
    // `dsmappname="SYNO.SDS.SurveillanceStation"`——**没有** `.Application`
    // / `.Instance` 后缀，别照抄其它模块的形状；真机 AppPrivilege 无此键。
    appPrivilegeKeys: ['SYNO.SDS.SurveillanceStation'],
    requiredApis: [
      'SYNO.SurveillanceStation.Camera', // surveillance_station.dart:44
    ],
    optionalApis: [
      'SYNO.SurveillanceStation.Stream.VideoStreaming', // 实时流
      'SYNO.SurveillanceStation.Recording', // 录像
      'SYNO.SurveillanceStation.PTZ', // 云台
    ],
  ),

  // ---- MailPlus：未装包时回 102（实测）；mailplus.dart:54。
  StationService.mailplus: ServiceSpec(
    id: StationService.mailplus,
    // 信号 1 取证（等级 A，真机**三个键全部为 true**）：
    //   * `SYNO.SDS.MailClient.Application` ← `/tmp/spk/ex_MailPlus/INFO` 的
    //     `dsmappname`（package="MailClient"）；
    //   * `SYNO.SDS.MailPlusServer.Instance` ← `/tmp/spk/ex_MPS/INFO` 的
    //     `dsmappname`（package="MailPlus-Server"）；
    //   * `SYNO.SDS.MailServer.Instance` ← 真机 AppPrivilege 全量列表
    //     （`docs/live-nas-verification.md:751-756`）。
    // ⚠️ 真机 `SYNO.MailClient.*` 的 **API 注册数 = 0**，与这三个 true 矛盾
    // → 合并规则把这种"信号 2 缺席 + 信号 1 命中"判成 `uncertain`
    // （**绝不 absent**、fail-open 显示）。
    appPrivilegeKeys: [
      'SYNO.SDS.MailClient.Application',
      'SYNO.SDS.MailPlusServer.Instance',
      'SYNO.SDS.MailServer.Instance',
    ],
    requiredApis: [
      'SYNO.MailClient.Info', // mailplus.dart:54；未装包的强判据
      'SYNO.MailClient.Mailbox', // mailplus.dart:55
    ],
    optionalApis: [
      'SYNO.MailClient.Thread', // 会话
      'SYNO.MailClient.Message', // 正文
      'SYNO.MailClient.Label', // 标签
      'SYNO.MailClient.Attachment', // 附件
    ],
  ),

  // ---- AI：本机能力（端侧模型 + 自带 key 的云端 LLM）→ **没有必需项**，
  // 恒不 `absent` / 不隐藏；NAS 侧 AI Console 作为**可选增强**登记。
  //
  // 方法名出处：2026-09-21 真机活体探针（`entry.cgi` 方法名校验发生在鉴权
  // 之前：`103` = 方法不存在，`119` = 方法存在但需会话）。实测：
  //   `SYNO.AI.Completion` → `create`
  //   `SYNO.AI.Thread`     → `create, delete`
  //   `SYNO.AI.Config`     → `get`
  //   `SYNO.AI.Metrics`    → `get`
  // ⚠️ 陷阱：`SYNO.AI.Thread.Message` 的候选方法全部返回 `102`（API 不存在）
  // → **不按这个名字实现**。
  StationService.ai: ServiceSpec(
    id: StationService.ai,
    // 信号 1：**不登记**。AI 的端侧模型 / 自带 key 云端 LLM 是本机能力；
    // NAS 侧 AI Console 在真机只有 `JSConfig` 的 `AIConsole`（前端模块路径），
    // `AppPrivilege` 里**没有**对应键——若登记一个不存在的键，就会把"键缺席"
    // 误读成"未安装"。因此 ai 只走信号 2 的**可选位**（且 requiredApis 为空）。
    appPrivilegeKeys: [],
    requiredApis: [],
    optionalApis: [
      kAiCompletionApi, // NAS 端生成（服务端 AI 通道的必需位，模块内可选）
      kAiThreadApi, // 服务端会话
      kAiConfigApi, // 服务端模型 / provider 配置
      kAiMetricsApi, // 服务端用量指标
    ],
  ),
};

/// 主 tab 被隐藏时的**顶替顺序**（见设计 §2.3）：
/// note → calendar → contacts → drive → download → audio → surveillance → mailplus。
/// 顶替者**自身必须 available**（partial/unknown 不顶替）。
const List<StationService> kReplacementOrder = [
  StationService.note,
  StationService.calendar,
  StationService.contacts,
  StationService.drive,
  StationService.download,
  StationService.audio,
  StationService.surveillance,
  StationService.mailplus,
];

// ---------------------------------------------------------------- 可选能力位常量
//
// 模块内降级（S2 任务 2）要用到这些 API 名。集中成常量，避免各模块把字符串
// 写错；`test/service_capabilities_test.dart` 会断言每个常量都确实在
// [kServiceRegistry] 的对应服务里（防漂移）。

const String kNoteTodoApi = 'SYNO.NoteStation.Todo';
// ---- C3（NoteStation 补齐）：版本 / 导出 / 导入的可选能力位 ----
//
// 语义（与 C2 同）：缺位 → **只隐藏该入口**（`partial`，不隐藏笔记模块）；
// `105`/`160` → 入口隐藏 + 无权限提示；`119`/`106` → 会话提示、**绝不隐藏**；
// 未检测 → fail-open。入口映射见 `note_c3_providers.dart` 的 [NoteC3Feature]。
const String kNoteVersionApi = 'SYNO.NoteStation.Note.Version';
const String kNoteExportWordApi = 'SYNO.NoteStation.Export.Word';
const String kNoteExportNoteApi = 'SYNO.NoteStation.Export.Note';
const String kNoteExportNotebookApi = 'SYNO.NoteStation.Export.Notebook';
const String kNoteImportEnexApi = 'SYNO.NoteStation.Import.Enex';
const String kNoteImportNotebookApi = 'SYNO.NoteStation.Import.Notebook';
const String kNoteImportEvernoteApi = 'SYNO.NoteStation.Import.Evernote';
const String kCalTodoApi = 'SYNO.Cal.Todo';
const String kContactsAddressbookApi = 'SYNO.Contacts.Addressbook';
// ---- C4（Calendar / Contacts 外部源补齐）新增能力位 ----
//
// 语义沿用 C2/C3（**只做最小可选位追加**）：缺位 → **只隐藏对应入口**
// （`partial`，模块本身照常）；`105`/`160` → 该入口隐藏 + 无权限提示；
// `119`/`106` → 会话提示、入口**保留**、**绝不隐藏模块**；未检测 → fail-open。
//   * [kContactsExternalSourceApi]：外部通讯录/ CardDAV 账号那一整块（只读列表 +
//     手动同步 + 添加 CardDAV）——`carddav_sheet.dart`；
//   * [kContactsOUApi]：组织单位（分组）只读树 —— `contacts_manage_page.dart` 的
//     「分组」页签；
//   * [kCalAuthForeignApi] / [kCalProxyApi]：「外部日历（暂不支持）」说明入口
//     —— `calendar_page.dart` 的日历选择器。
const String kContactsExternalSourceApi = 'SYNO.Contacts.ExternalSource';
const String kContactsOUApi = 'SYNO.Contacts.OU';
const String kCalAuthForeignApi = 'SYNO.Cal.AuthForeign';
const String kCalProxyApi = 'SYNO.Cal.Proxy';
const String kDriveSharingApi = 'SYNO.SynologyDrive.Sharing';
// C1（Drive 补齐）新增能力位；缺失时只隐藏对应入口（`partial`）。
const String kDriveTrashApi = 'SYNO.SynologyDrive.Trash';
const String kDriveTeamFoldersApi = 'SYNO.SynologyDrive.TeamFolders';
const String kDriveAdvanceSharingApi = 'SYNO.SynologyDrive.AdvanceSharing';
const String kDriveFileRequestApi = 'SYNO.SynologyDrive.FileRequest';
const String kDriveNodeLockingApi = 'SYNO.SynologyDrive.NodeLocking';
const String kDriveNotificationsApi = 'SYNO.SynologyDrive.Notifications';
const String kOfficeVersionApi = 'SYNO.Office.Node.Version';
const String kDownloadTaskListApi = 'SYNO.DownloadStation2.Task.List';
const String kSurveillanceRecordingApi = 'SYNO.SurveillanceStation.Recording';
const String kMailAttachmentApi = 'SYNO.MailClient.Attachment';
const String kFotoStreamingApi = 'SYNO.Foto.Streaming';
const String kFotoThumbnailApi = 'SYNO.Foto.Thumbnail';
// 批次②（图生图）补缺：`foto_api.dart` 早已实现 `Upload.Item`（时间轴/相册回写、
// 备份），但它**从未进过能力表** → "照片回写"没被统一检测覆盖，缺位时无法降级。
// 追加为可选能力位后：缺位 → **只隐藏"保存到相册"**，"保存到本机"照常；
// 未检测 → fail-open（`ServiceAvailabilitySnapshot.hasApi`）。
const String kFotoUploadApi = 'SYNO.Foto.Upload.Item';

// ---- C2（Photos 补齐）：六个横切入口的可选能力位 ----
//
// 语义（用户决策，见 `photo_c2_providers.dart` 的 `PhotoC2Availability`）：
//   * 缺位 → **只隐藏该入口**（hub 上少一格），Photos 模块照常（`partial`）；
//   * `105`/`160` → 该入口隐藏 + "没有权限"提示；
//   * `119`/`106` → 会话提示，入口**保留**，模块**绝不隐藏**；
//   * 未检测 → fail-open（`ServiceAvailabilitySnapshot.hasApi`）。
const String kFotoSharingApi = 'SYNO.Foto.Sharing.Misc';
const String kFotoPhotoRequestApi = 'SYNO.Foto.PhotoRequest';
const String kFotoGeocodingApi = 'SYNO.Foto.Browse.Geocoding';
const String kFotoSearchApi = 'SYNO.Foto.Search.Search';
const String kFotoSearchFilterApi = 'SYNO.Foto.Search.Filter';
const String kFotoConditionAlbumApi = 'SYNO.Foto.Browse.ConditionAlbum';
const String kFotoSimilarApi = 'SYNO.Foto.Browse.Similar';

const String kAudioStreamApi = 'SYNO.AudioStation.Stream';
const String kAudioCoverApi = 'SYNO.AudioStation.Cover';

// ---- 服务端 AI（NAS AI Console）可选能力位 ----
//
// 与其余 optional 位不同：这几个位**不**门控 AI 模块本身（AI 的端侧/云端
// 引擎是本机能力），只门控「使用 NAS 的 AI」这一类**服务端选项**
// （`features/ai/server_ai_channel.dart` 的 `ServerAiChannel`）。
// 缺 `kAiCompletionApi` → 服务端 AI 选项隐藏，模块其余照常（`partial`，不隐藏）。
const String kAiCompletionApi = 'SYNO.AI.Completion';
const String kAiThreadApi = 'SYNO.AI.Thread';
const String kAiConfigApi = 'SYNO.AI.Config';
const String kAiMetricsApi = 'SYNO.AI.Metrics';

// ---- Synology Universal Search（`SYNO.Finder.*`）能力位 ----
//
// `SYNO.Finder.*` **不属于任何 StationService**（不是套件，是 DSM 横切能力），
// 所以判定走 `ServiceAvailabilitySnapshot.apiPresent(...)`（能力表存在性）。
// 真机实测 17 个 `SYNO.Finder.*` 全部存在；方法名表见
// `lib/src/data/finder_api.dart`（逐方法来自 2026-09-21 活体探针）。
const String kFinderFileIndexingSearchApi = 'SYNO.Finder.FileIndexing.Search';
const String kFinderFileApi = 'SYNO.Finder.File';
const String kFinderFileThumbnailApi = 'SYNO.Finder.File.Thumbnail';
const String kFinderBookmarkApi = 'SYNO.Finder.Bookmark';

// ---------------------------------------------------------------- 反向映射

/// API 名 → 它所属的服务（必需或可选）。
///
/// 供**统一错误出口**（`service_reporting_api.dart` 的 `ServiceReportingApi`）
/// 在一次调用失败时知道"该回填哪个服务"——这样模块侧零散点不需要各自写
/// `reportError`，一处映射即可覆盖全部 12 个 NAS 服务。
///
/// 不认识的名字（`SYNO.API.Info` / `SYNO.API.Auth` / `SYNO.Entry.Request` …）
/// 返回 null：**不参与降级**，避免把登录 / 探测本身的失败误当成模块不可用。
StationService? serviceForApiName(String api) {
  for (final entry in kServiceRegistry.entries) {
    if (entry.value.contains(api)) return entry.key;
  }
  return null;
}

/// 这个 API 是否是某服务的**必需** API（102 只有落在必需 API 上才算"未安装"）。
bool isRequiredApiOf(StationService service, String api) =>
    kServiceRegistry[service]?.requiredApis.contains(api) ?? false;

// ---------------------------------------------------------------- 状态

/// 每个服务的可用性状态机（见设计 §2.2）。
enum AvailabilityState {
  /// 还没拿到 `SYNO.API.Info`（未登录 / 未检测）——**不判死、不隐藏**。
  unknown,

  /// 必需 API 全在。
  available,

  /// 必需 API 全在，部分可选缺失——模块可用，缺的功能降级。
  partial,

  /// 任一必需 API 缺失（能力表明确缺失，或明确 [kApiNotFoundCode]）
  /// ——**未安装**；隐藏主 tab。
  absent,

  /// **两个信号相互矛盾**（见 [classifyMultiSignal]）：信号 2 说"没注册任何
  /// 必需 API"，信号 1 的 `AppPrivilege` 却说"该应用可用"。
  ///
  /// 真机实例 = **MailPlus**：`SYNO.MailClient.*` 的 API 注册数 = 0，但
  /// `AppPrivilege` 的 `SYNO.SDS.MailClient.Application` 等三项全 `true`
  /// （`docs/live-nas-verification.md:743`）。
  ///
  /// 用户决策：**矛盾时绝不判 `absent`**——fail-open 显示，如实标注"信号矛盾"。
  /// 因此 `hidesModule(uncertain) == false`（见 [hidesModule]），且
  /// `hasApi(...)` 对它一律 fail-open。
  uncertain,

  /// **权限不足**（[kNoPermissionCode] 105 / [kNoAppPrivilegeCode] 160 等
  /// "已安装但该账号无权使用"）——用户决策：**也隐藏**
  /// （避免"看得见但用不了"引发矛盾）；隐藏后可从「设置 → 服务检测」找回。
  ///
  /// 信号 1 里"键存在且为 `false`"也归这里（官方前端 `AppPrivilege` 语义）。
  ///
  /// ⚠️ **绝不能**把 [kSidNotFoundCode]（119）/ [kSessionTimeoutCode]（106）
  /// 归到这里——那是会话失效，见 [sessionExpired]。
  unauthorized,

  /// **会话失效 / 超时**（119 / 106）——**绝不隐藏**：此时所有接口都会失败，
  /// 一隐藏用户就无从恢复。统一走"会话已过期，请重新登录"，tab 可见性不变。
  sessionExpired,

  /// 网络 / 握手失败——**不隐藏**（不是服务端没提供）。
  unreachable,
}

/// 这个状态是否应当**隐藏**模块（主 tab / 工作台入口）。
///
/// 只有"未安装"（[AvailabilityState.absent]）与"无权限"
/// （[AvailabilityState.unauthorized]）会隐藏；
/// `sessionExpired` / `unreachable` / `unknown` / `partial` / `available` /
/// `uncertain`（两信号矛盾，fail-open）一律可见。
bool hidesModule(AvailabilityState state) =>
    state == AvailabilityState.absent ||
    state == AvailabilityState.unauthorized;

// ---------------------------------------------------------------- 信号 1（AppPrivilege）

/// `Core.Desktop.Initdata:get` 的 API 名（真机 `AppPrivilege` 权威来源）。
///
/// 真机验证（`docs/live-nas-verification.md` §8.1）：**普通用户可读**，
/// 返回 `AppPrivilege` + `JSConfig` + `CSSFiles`。`Core.Package:list` 对普通
/// 用户是 105（不可用），所以才要这个替代信号。
const String kDesktopInitdataApi = 'SYNO.Core.Desktop.Initdata';

/// 官方前端的"全应用放行"通配键。原文见 [ServiceSpec.appPrivilegeKeys] 注释。
///
/// 语义边界（**刻意**）：通配键只用来**抵消 `false`**（有通配键时，键值为
/// `false` 也算放行），**不**用来自动把"键不存在"当成"已安装"——安装与否由
/// 信号 2（API 注册）判，否则管理员账号下"没装的套件"也会被误判成 `uncertain`
/// 而永远藏不掉。
const String kAppPrivilegeAllowAllKey = 'SYNO.ALLOW.ALL.APPLICATIONS';

/// **信号 1** 的一次快照：`Core.Desktop.Initdata:get` 的 `AppPrivilege`。
///
/// 纯数据（无 Flutter / 无 dio），可离线单测，也可缓存。
class AppPrivilegeSignal {
  const AppPrivilegeSignal({
    required this.entries,
    required this.allowAll,
    this.known = true,
  });

  /// 探测失败 / 未探测：**信号 1 不可用**（合并规则退化为信号 2 单独判）。
  static const AppPrivilegeSignal unavailable = AppPrivilegeSignal(
    entries: {},
    allowAll: false,
    known: false,
  );

  /// `AppPrivilege` 里的键 → bool（只保留真正的布尔值）。
  final Map<String, bool> entries;

  /// `SYNO.ALLOW.ALL.APPLICATIONS === true`。
  final bool allowAll;

  /// 是否真的读到了 `AppPrivilege`。
  final bool known;

  /// 从 `Initdata:get` 的 `data` 里解析。
  ///
  /// * `data['AppPrivilege']` 不是 Map → [unavailable]（**不是**"全部缺席"）；
  /// * 非布尔的键值直接忽略（官方前端也只认 bool / undefined）。
  static AppPrivilegeSignal fromInitdata(Map<String, dynamic> data) {
    final raw = data['AppPrivilege'];
    if (raw is! Map) return unavailable;
    final entries = <String, bool>{};
    raw.forEach((k, v) {
      if (v is bool) entries['$k'] = v;
    });
    return AppPrivilegeSignal(
      entries: entries,
      allowAll: entries[kAppPrivilegeAllowAllKey] ?? false,
    );
  }

  bool get isEmpty => entries.isEmpty;

  /// 某个键是否"放行"（照抄官方前端的三元判断）。
  bool _allowed(String key) {
    final v = entries[key];
    if (v == null) return false; // 键不存在 → 官方前端判"不允许"
    if (v) return true;
    return allowAll; // 键为 false：只有通配键能抵消
  }

  /// 该模块的任一 AppPrivilege 键是否"放行"。
  bool isPresent(List<String> keys) => keys.any(_allowed);

  /// 该模块是否被**明确拒绝**（键存在且为 `false`，且没有任何键放行）。
  bool isDenied(List<String> keys) =>
      keys.isNotEmpty && !isPresent(keys) && keys.any((k) => entries[k] == false);

  Map<String, bool> toJson() => {...entries};
}

// ---------------------------------------------------------------- 纯判定

/// 由能力表算一个服务的状态。**纯函数**：只依赖 [spec] 与"表里有哪些 API"。
///
/// 这是**信号 2 单独判**的旧约定，保留给"信号 1 不可用"的回退路径与既有用例：
/// 只有"必需 API 明确不在表里"才回 `absent`；可选购成 `partial`。
/// `requiredApis` 为空的服务（只有 [StationService.ai]）**永不** `absent`
/// —— 模块本体不依赖 NAS；但可选能力位缺失时**如实报 `partial`**，
/// 让 UI 用能力位隐藏"服务端增强"那一类选项。
AvailabilityState classifyApiTable(ServiceSpec spec, Set<String> apiNames) {
  final missingRequired = spec.requiredApis.any((a) => !apiNames.contains(a));
  if (missingRequired) return AvailabilityState.absent;
  final missingOptional = spec.optionalApis.any((a) => !apiNames.contains(a));
  return missingOptional
      ? AvailabilityState.partial
      : AvailabilityState.available;
}

/// **统一多信号判定**（用户 2026-09-21 要求）——把三个信号合成一个状态。
///
/// 输入：
/// * 信号 1 = [privilege]（`Core.Desktop.Initdata:get` 的 `AppPrivilege`，
///   权威的"这个用户能不能用"信号）；
/// * 信号 2 = [apiNames]（`SYNO.API.Info?query=all` 的键集合，"这套件注册了
///   哪些 WebAPI"信号 —— 一个必需 API 存在即证明"服务器上装了"）；
/// * 信号 3 = 调用错误码回填（[classifyErrorCode] / `reportApiError`，
///   102 / 105 / 160 / 119 / 106 的语义**保持不变**）。
///
/// ## 合并规则（**写死在这里**，`test/service_multi_signal_test.dart` 逐条钉死）
///
/// ```text
/// 0. privilege == null / !known  → 回退 classifyApiTable(spec, apiNames)
///    （"信号 1 不可用"= Initdata 这个 API 没注册 / 返回里没有 AppPrivilege /
///      该调用失败。这不是"探测失败"，而是"这台服务器不提供该信号"，
///      所以退回已被真机验证过的信号 2 单独判：全缺席 → absent，
///      **保持既有隐藏能力**；真正的探测失败由 _runProbe 归 unreachable。）
/// 1. 信号 1 明确拒绝（键存在且为 false，且无键放行）→ unauthorized（隐藏）
///    —— 权限优先于 API 注册（官方前端就是这么拦的）。
/// 2. 否则按信号 2 判：必需全在 → available / partial；部分在 → partial；
///    全不在 → 看信号 1 复核。
/// 3. 信号 2 全缺席（= classifyApiTable 判 absent）时用信号 1 复核：
///    * 信号 1 命中（任一键放行）→ uncertain（**两信号矛盾，绝不 absent**，
///      fail-open 显示；真机实例 = MailPlus）；
///    * 该模块没有登记任何 AppPrivilege 键 → absent（没有可用信号 1 就信信号 2）；
///    * 信号 1 里键不存在 → absent（两信号一致说"没有"）。
/// 4. requiredApis 为空（ai）→ 永不 absent / unauthorized。
/// ```
///
/// ⚠️ **不许**出现的行为：信号 2 缺席 + 信号 1 命中 → absent（MailPlus 会被
/// 藏掉）；105 / 160 → absent；119 / 106 → 任何形式的隐藏。
AvailabilityState classifyMultiSignal(
  ServiceSpec spec,
  Set<String> apiNames,
  AppPrivilegeSignal? privilege,
) {
  // 规则 0：信号 1 不可用 → 回退信号 2 单独判（既有约定，一字不改）。
  if (privilege == null || !privilege.known) {
    return classifyApiTable(spec, apiNames);
  }
  // 规则 4：本机能力（ai）没有服务端必需项 → 永不 hidden。
  if (spec.requiredApis.isEmpty) {
    return classifyApiTable(spec, apiNames);
  }
  // 规则 1：权限优先。
  if (privilege.isDenied(spec.appPrivilegeKeys)) {
    return AvailabilityState.unauthorized;
  }
  // 规则 2：信号 2 说了算。
  final base = classifyApiTable(spec, apiNames);
  if (base != AvailabilityState.absent) return base;
  // 规则 3：两信号交叉复核。
  if (spec.appPrivilegeKeys.isEmpty) return AvailabilityState.absent;
  return privilege.isPresent(spec.appPrivilegeKeys)
      ? AvailabilityState.uncertain
      : AvailabilityState.absent;
}

/// 由**调用错误码**回填状态。**纯函数**。
///
/// 三分天下，**弄错后果严重**：
/// * [kApiNotFoundCode] (102) → `absent`（服务端明确没这个 API = 未安装），隐藏；
/// * [kNoPermissionCode] (105) / [kNoAppPrivilegeCode] (160) →
///   `unauthorized`（已安装但该账号无权），**也隐藏**（用户决策）；
/// * [kSidNotFoundCode] (119) / [kSessionTimeoutCode] (106) →
///   `sessionExpired`（会话失效），**绝不隐藏**——若误当 `unauthorized` 隐藏，
///   会话一过期整个 App 的所有 tab 都会消失且无从恢复；
/// * 其它码 → `unknown`（宁可不动，也不误判）。
AvailabilityState classifyErrorCode(int code) {
  switch (code) {
    case kApiNotFoundCode:
      return AvailabilityState.absent;
    case kNoPermissionCode:
    case kNoAppPrivilegeCode:
      return AvailabilityState.unauthorized;
    case kSidNotFoundCode:
    case kSessionTimeoutCode:
      return AvailabilityState.sessionExpired;
    default:
      return AvailabilityState.unknown;
  }
}

/// 所有服务都按 [AvailabilityState.unknown] 起步的映射。
Map<StationService, AvailabilityState> unknownAvailability() => {
  for (final s in StationService.values) s: AvailabilityState.unknown,
};
