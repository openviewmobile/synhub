// 三份**能力快照夹具**（用户 2026-09-21 要求："模拟数据测试下效果"）。
//
// "快照"是**只读真值**的离线复刻，不含任何网络请求：
//   * 信号 1 = `Core.Desktop.Initdata:get` 的 `AppPrivilege`；
//   * 信号 2 = `SYNO.API.Info?query=all` 的 API 注册表。
//
// ============================================================================
// ⚠️ 真值刷新（2026-09-21，本批只改夹具与注释，未改任何判定逻辑）
//
// 用户已在真机安装 **Audio Station (7.2.1-6006)** 与
// **Download Station (4.1.2-5012)**，因此"当前真机快照"从"未安装"更新为
// "已安装"。采集依据（均为真机只读证据，本批未重新探测）：
//   * `SYNO.API.Info?query=all` = **1047** 个 API（未装 AS/DS 时为 977）
//     —— `docs/audio-parity-audit.md:93`、`docs/download-parity-audit.md:44`；
//   * `SYNO.AudioStation.*` = **27** 个命名空间，装机版本 7.2.1-6006
//     —— `docs/audio-parity-audit.md:83,:95`；
//   * `SYNO.DownloadStation.*`(7) + `SYNO.DownloadStation2.*`(36) = **43** 个，
//     装机版本 4.1.2-5012 —— `docs/download-parity-audit.md:24-25,:45`；
//   * `Core.Desktop.Initdata` 的
//     `AppPrivilege["SYNO.SDS.AudioStation.Application"] = true`
//     —— `docs/audio-parity-audit.md:224`。
//   * 过期提醒原文见 `docs/audio-parity-audit.md:634-651`（§7）与
//     `docs/download-parity-audit.md:496-516`（§8）。
//   （任务书把依据写成两份审计的 §4；实际承载 API 数 / 版本 / AppPrivilege
//   证据的是 §1.1 / §1.5 与 §1，此处按真实行号引用。）
//
// 采集日期：**2026-09-21**（真机 `https://nas.example.com:5001`，普通用户会话，
// 只读 GET）。本批**未**重新联网 / 未登录 NAS / 未动设备。
//
// 三个"真机/形态"夹具：
//   * [realNasSnapshot] —— **当前这台真 NAS**：photos/note/office/drive/chat/
//     calendar/contacts/file(+webdav/finder) **与 audio/download** 存在；
//     surveillance 不存在；**MailPlus 两信号矛盾**。
//   * [nasWithoutStations] —— **合成降级快照（不是当前真机！）**：形态同真机
//     但**未安装** audio/download，专门覆盖"服务端没有该服务时客户端降级"。
//   * [minimalNasSnapshot] —— 只有 FileStation。
//   * [fullNasSnapshot] —— 全存在（回归上限，11 个工作台入口 / 5 个底栏 tab）。
// 另外两个用于降级/回退边界的派生夹具：
//   * [noCoreNasSnapshot] —— 只有 NoteStation（三个核心模块全缺 → 受限首页）；
//   * [legacyNasSnapshot] —— 服务器**不提供** Initdata（信号 1 不可用 →
//     退回信号 2 单独判，钉死"不让老服务器永远藏不掉未装套件"）。
// ============================================================================

import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/features/shell/app_tab.dart';

/// 真机装机版本（真机只读 `Info.getinfo` / `Package.Info.get` 回包）。
/// 仅供文档锚定与防漂移用例引用，**不参与任何判定**。
const String kLiveNasAudioStationVersion =
    '7.2.1-6006'; // audio-parity-audit.md:83
const String kLiveNasDownloadStationVersion =
    '4.1.2-5012'; // download-parity-audit.md:24

/// 真机注册的命名空间个数（`SYNO.API.Info?query=all` 普查口径）。
const int kLiveNasAudioStationNamespaces = 27; // audio-parity-audit.md:95
const int kLiveNasDownloadStationNamespaces = 43; // download-parity-audit.md:45

/// 真机 `AppPrivilege` 全量 20 项（普通用户视角，全部 `true`）。
///
/// 原文：`docs/live-nas-verification.md` §8.3（行 748–757）与
/// `docs/workspace-expansion-evaluation.md` 附 3.8（行 2329–2336）。
///
/// **装 AS/DS 后是否新增 Audio/Download 权限键（2026-09-21 复核）**：
///   * Audio 侧真机已见该键为 true
///     （`docs/audio-parity-audit.md:224`）；
///   * Download 侧 `SYNO.SDS.DownloadStation.Application` 是否下发
///     **未单独取证**（`docs/download-parity-audit.md:531`，未确认项 U9）。
/// 本清单按"不凭猜加"原则**保持首次采集的 20 项原文不变**；两个模块能否用
/// 由**信号 2**（`SYNO.API.Info`，27 / 43 个命名空间在场）判定，
/// **不依赖**这两个 AppPrivilege 键（见 [classifyMultiSignal] 规则 2）。
const List<String> kLiveNasAppPrivilegeKeys = [
  'SYNO.AFP',
  'SYNO.Cal.Application',
  'SYNO.Contacts.AppInstance',
  'SYNO.Desktop',
  'SYNO.FTP',
  'SYNO.Foto.AppInstance',
  'SYNO.Rsync',
  'SYNO.SDS.App.FileStation3.Instance',
  'SYNO.SDS.BackupService.Instance',
  'SYNO.SDS.Chat.Application',
  'SYNO.SDS.DocumentViewer.Application',
  'SYNO.SDS.Drive.Application',
  'SYNO.SDS.MailClient.Application',
  'SYNO.SDS.MailPlusServer.Instance',
  'SYNO.SDS.MailServer.Instance',
  'SYNO.SDS.NoteStation.Application',
  'SYNO.SDS.SMBService.AppPrivilege.Instance',
  'SYNO.SDS.SynologyFileManager.Privilege.Extension',
  'SYNO.SDS.WebDAVServer.Instance',
  'SYNO.SFTP',
];

/// 真机上存在、但**不属于任何 [StationService]** 的 API（证明夹具不是"凭空
/// 拼出来的"：这些键在真机 API 普查（装 AS/DS 后 1047 个）
/// 里，且不参与任何模块判定）。
const List<String> kNonModuleApis = [
  'SYNO.API.Info',
  'SYNO.API.Auth',
  'SYNO.API.Encryption',
  'SYNO.Core.Desktop.Initdata',
  'SYNO.Finder.File',
  'SYNO.Finder.FileIndexing.Search',
  'SYNO.WebDAV.Common',
  'SYNO.WebDAV.CalDAV.Calendar',
  'SYNO.Core.Package',
];

Set<String> _apisOf(Iterable<StationService> services) => {
  for (final s in services) ...kServiceRegistry[s]!.allApis,
};

/// 只要**主链路**（requiredApis）。
Set<String> _requiredApisOf(Iterable<StationService> services) => {
  for (final s in services) ...kServiceRegistry[s]!.requiredApis,
};

/// 一台 NAS 的"能力快照"。
class NasSnapshot {
  const NasSnapshot({
    required this.label,
    required this.apiNames,
    required this.privilege,
    this.initdataInApiTable = true,
    this.apiCensus,
  });

  /// 给测试输出用的名字（断言 reason 里带上它，红了知道是哪台机器）。
  final String label;

  /// **信号 2**：`SYNO.API.Info` 里存在的 API 名。
  final Set<String> apiNames;

  /// **信号 1**：`AppPrivilege`（`known == false` 表示该服务器没这个信号）。
  final AppPrivilegeSignal privilege;

  /// 服务器是否把 `Core.Desktop.Initdata` 注册进 API 表。
  final bool initdataInApiTable;

  /// 采集时 `SYNO.API.Info?query=all` 的**普查总数**（真机真值锚点）。
  ///
  /// 注意：这是那一轮只读采集的 key 总数，**不是** [apiNames] 的长度
  /// ——本夹具只离线复刻与模块判定相关的子集。合成快照不声明该数字
  /// （`null`），以免把"编的"当成"采到的"。
  final int? apiCensus;

  /// 本次能否真的用上信号 1。
  bool get signal1Available => initdataInApiTable && privilege.known;

  /// `FakeTransport` 的 `SYNO.API.Info` 表。
  Map<String, Map<String, dynamic>> apiTable() => {
    for (final a in apiNames)
      a: const {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 9},
    if (initdataInApiTable)
      kDesktopInitdataApi: const {
        'path': 'entry.cgi',
        'minVersion': 1,
        'maxVersion': 1,
      },
  };

  /// `bootChat(extra:)` 用的响应：只补 `Initdata:get`。
  Map<String, Map<String, dynamic>> responses() => {
    if (signal1Available)
      '$kDesktopInitdataApi.get': {
        'AppPrivilege': privilege.toJson(),
        // 真机同一次回包还有这两个（本设计暂未使用，保留形状）。
        'JSConfig': const <String, dynamic>{},
        'CSSFiles': const <String>[],
      },
  };

  /// 走**生产同一条**合并逻辑（[classifyMultiSignal]）算出的状态表。
  Map<StationService, AvailabilityState> states() => {
    for (final e in kServiceRegistry.entries)
      e.key: classifyMultiSignal(
        e.value,
        apiNames,
        privilege.known ? privilege : null,
      ),
  };

  /// 底栏可见 tab（生产纯函数）。
  List<AppTab> tabs({bool showHidden = false}) =>
      visibleTabs(states(), showHidden: showHidden);

  /// 未安装 / 无权限（会被隐藏）的模块。
  List<StationService> hiddenServices() => [
    for (final s in StationService.values)
      if (hidesModule(states()[s]!)) s,
  ];
}

AppPrivilegeSignal _allTrue(Iterable<String> keys) => AppPrivilegeSignal(
  entries: {for (final k in keys) k: true},
  allowAll: false,
);

/// 真机（2026-09-21 装 AS/DS 后）快照。
///
/// 真机存在：photos / note / office / drive / chat / calendar / contacts /
/// file / ai（AI Console）**+ audio / download** + 不属于任何模块的
/// Finder / WebDAV / Core。
///
/// 真值依据：`docs/audio-parity-audit.md:83,:93,:95,:224` 与
/// `docs/download-parity-audit.md:24,:25,:44,:45`（真机只读采集，采集日期
/// 2026-09-21，**本批未重新探测**）。
final NasSnapshot realNasSnapshot = NasSnapshot(
  label: '真机 NAS',
  // 采集时 `SYNO.API.Info?query=all` 普查 = 1047（装 AS/DS 前为 977）。
  apiCensus: 1047,
  apiNames: {
    ..._apisOf(const [
      StationService.chat,
      StationService.file,
      StationService.photo,
      StationService.note,
      StationService.calendar,
      StationService.contacts,
      StationService.drive,
      StationService.office,
      StationService.ai,
      // 2026-09-21 复核：真机已安装 Audio Station（27 个命名空间）与
      // Download Station（43 个命名空间）→ 两个模块应判 available。
      StationService.audio,
      StationService.download,
    ]),
    ...kNonModuleApis,
  },
  // 真机 **不存在**：surveillance / video / virtual / usb
  // → 不加入 apiNames。
  // （audio / download **曾经**不存在，现已安装；见上方真值依据。）
  //
  // AppPrivilege 用真机原文 20 项：注意里面**没有** Office 键，
  // 但**有** MailPlus 的三个键 → Office 靠信号 2 判，MailPlus 两信号矛盾。
  privilege: _allTrue(kLiveNasAppPrivilegeKeys),
);

/// **合成降级快照（不是当前真机！）**：形态与 [realNasSnapshot] 相同
/// （同样的 9 个模块 + 同样的真机 AppPrivilege 原文），但**未安装**
/// Audio Station / Download Station。
///
/// 用途：覆盖用户明确要求的**降级路径**——"服务端没有该服务时客户端要降级、
/// 主 tab 隐藏或替换"。用它与 [realNasSnapshot] 对照，就能同时钉死
/// "已装 → available"和"未装 → absent 且隐藏"两条相反的真值，
/// 且**不需要**放宽任何断言。
///
/// 这份数据是**为测试构造的合成快照**；真机当前真值见 [realNasSnapshot]。
final NasSnapshot nasWithoutStations = NasSnapshot(
  label: '合成降级 NAS（真机形态，但未装 audio/download）',
  apiNames: {
    ..._apisOf(const [
      StationService.chat,
      StationService.file,
      StationService.photo,
      StationService.note,
      StationService.calendar,
      StationService.contacts,
      StationService.drive,
      StationService.office,
      StationService.ai,
      // 刻意**不含** StationService.audio / StationService.download。
    ]),
    ...kNonModuleApis,
  },
  privilege: _allTrue(kLiveNasAppPrivilegeKeys),
);

/// 最小 NAS：只装了 FileStation，**且只注册了主链路 API**。
///
/// 刻意只给 requiredApis（`SYNO.FileStation.List`）→ FileStation 落在
/// `partial`："模块在、可选能力位缺" 的降级路径（工作台的 tasks / search
/// 入口应当消失）也被这份夹具覆盖。
final NasSnapshot minimalNasSnapshot = NasSnapshot(
  label: '最小 NAS（只有 FileStation）',
  apiNames: {
    ..._requiredApisOf(const [StationService.file]),
    ...kNonModuleApis,
  },
  privilege: _allTrue(const ['SYNO.SDS.App.FileStation3.Instance']),
);

/// 全功能 NAS：所有模块的必需 + 可选 API 都在，AppPrivilege 全 true。
final NasSnapshot fullNasSnapshot = NasSnapshot(
  label: '全功能 NAS',
  apiNames: {
    for (final spec in kServiceRegistry.values) ...spec.allApis,
    ...kNonModuleApis,
  },
  privilege: _allTrue([
    for (final spec in kServiceRegistry.values) ...spec.appPrivilegeKeys,
  ]),
);

/// 只有 NoteStation：三个核心模块（chat/file/photo）全缺 → 受限模式首页。
final NasSnapshot noCoreNasSnapshot = NasSnapshot(
  label: '无核心模块 NAS（只有 NoteStation）',
  apiNames: {
    ..._apisOf(const [StationService.note]),
    ...kNonModuleApis,
  },
  privilege: _allTrue(const ['SYNO.SDS.NoteStation.Application']),
);

/// 老服务器：**没有** `Core.Desktop.Initdata`（信号 1 不可用）。
///
/// 本快照同样**未装** audio/download/surveillance（合成，非当前真机——
/// 真机现已装 AS/DS，见 [realNasSnapshot]）。期望：退回信号 2 单独判，
/// 未装套件仍 `absent`，已装模块仍 `available` —— 即"缺少一个信号 ≠ 永远不隐藏"。
final NasSnapshot legacyNasSnapshot = NasSnapshot(
  label: '老 NAS（信号 1 不可用）',
  apiNames: {
    ..._apisOf(const [
      StationService.chat,
      StationService.file,
      StationService.photo,
      StationService.note,
      StationService.calendar,
      StationService.contacts,
      StationService.drive,
      StationService.office,
      StationService.ai,
    ]),
    ...kNonModuleApis,
  },
  privilege: AppPrivilegeSignal.unavailable,
  initdataInApiTable: false,
);
