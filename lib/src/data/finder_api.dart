// `SYNO.Finder.*` 协议层 —— Synology Universal Search（全局搜索）。
//
// **纯 Dart 纪律**：本文件**不得** import `package:flutter/**` / `l10n` /
// material（与 `service_registry.dart` 同款约定）：探针与协议测试用纯 Dart VM
// 直接加载它。
//
// ---------------------------------------------------------------- 证据来源
//
// 方法名全部来自 **2026-09-21 无凭据活体探针**（真机
// `https://nas.example.com:5001/webapi/entry.cgi?api=SYNO.API.Info&version=1
// &method=query&query=all` → **977 API，含 34 个 `SYNO.AI.*`、17 个
// `SYNO.Finder.*`**）。探针原理：DSM 的**方法名校验发生在鉴权之前** ——
// `entry.cgi?api=<API>&version=1&method=<M>` 不带会话时
// `103` = 方法不存在，`119` = 方法存在但需会话
// （对照：`SYNO.FileStation.List` + `__bogus__` → 103，+ `list` → 119）。
//
// ⚠️ **边界（必须遵守）**：
//   1. 探针只证明「**方法存在 + 需会话**」，**证明不了 `allowUser`**
//      —— 普通用户是否有权用 `SYNO.Finder.*` **未验证**；
//   2. `SYNO.Finder.FileIndexing.Search` 的**请求参数形态未取证**
//      —— 官方 JS（`export_NoteStation/ui/notestation_finder.js`、
//      `export_FileStation/ui/file_browser/FileBrowser.js`、
//      `export_SynologyDrive/ui/cloudstation.js`、
//      `ex_AI_pat/.../AdminCenter/admin_center.js`）里唯一带参数的
//      `SYNO.Finder` 调用是 `SYNO.Finder.AppIndexing.Search`（**应用**索引，
//      不是文件索引）：
//        admin_center.js：`{api:"SYNO.Finder.AppIndexing.Search",
//          method:"search",version:1,params:{keyword:e,
//          search_weight_list:[{field:"SYNOMDWildcard",weight:1},
//          {field:"keywords",weight:5},{field:"search_title",weight:10}],
//          from:0,size:10,lang:_S("lang")}}`
//      `FileIndexing.Search` 的请求体**没有**可引用原文 → **绝不发送猜测参数
//      的请求**（详见 `docs/finder-global-search.md`）。
//   3. 因此本 App 的"全局搜索"**不复用 Finder 的搜索请求**，而是复用
//      **已知参数形态**的各模块搜索 API（File Station.Search / NoteStation.FTS），
//      Finder 只用于**存在性探测 + 入口显隐**（设计 §4.3(b) 的降级）。
library;

/// `SYNO.Finder.*` 的 API 名与方法名表。
abstract final class FinderApi {
  // ---------------------------------------------------------------- API 名
  static const String file = 'SYNO.Finder.File';
  static const String fileIndexingSearch = 'SYNO.Finder.FileIndexing.Search';
  static const String fileIndexingFolder = 'SYNO.Finder.FileIndexing.Folder';
  static const String fileIndexingStatus = 'SYNO.Finder.FileIndexing.Status';
  static const String fileIndexingTerm = 'SYNO.Finder.FileIndexing.Term';
  static const String elasticSearchHistory =
      'SYNO.Finder.Elastic.SearchHistory';
  static const String elasticTerm = 'SYNO.Finder.Elastic.Term';
  static const String bookmark = 'SYNO.Finder.Bookmark';
  static const String appIndexingSearch = 'SYNO.Finder.AppIndexing.Search';
  static const String fileCover = 'SYNO.Finder.File.Cover';
  static const String fileThumbnail = 'SYNO.Finder.File.Thumbnail';
  static const String preference = 'SYNO.Finder.Preference';
  static const String settings = 'SYNO.Finder.Settings';

  /// 全局搜索入口的**能力位**（存在性探测用）。
  ///
  /// 刻意**不用** `FileIndexing.Folder`：索引未建时它可能为空，而搜索本身
  /// 仍可覆盖笔记 / 相册等来源（父 agent 2026-09-21 决定）。
  static const String gateApi = fileIndexingSearch;

  // ---------------------------------------------------------------- 版本
  /// 探针只给出「API 存在」，`maxVersion` 统一按 `1` 处理
  /// （`SYNO.API.Info` 的 `maxVersion` 本项目未逐个取回 → 用最小可用版本）。
  static const int version = 1;

  // ---------------------------------------------------------------- 方法表
  //
  // 键 = API 名，值 = 探针实测**存在**（返回 119）的方法名。
  // 出处：2026-09-21 无凭据活体探针（父 agent 已执行，本层直接引用）。
  //
  // ⚠️ 陷阱：`SYNO.AI.Thread.Message` 的所有候选方法都返回 **102（API 不
  // 存在）**——顺带记录在 `service_registry.dart` 的 ai 注释里。
  static const Map<String, List<String>> methods = {
    'SYNO.Finder.File': ['get'],
    'SYNO.Finder.FileIndexing.Search': ['search'],
    'SYNO.Finder.FileIndexing.Folder': [
      'list',
      'get',
      'set',
      'add',
      'delete',
      'check',
      'reindex',
    ],
    'SYNO.Finder.FileIndexing.Status': ['get'],
    'SYNO.Finder.FileIndexing.Term': ['update'],
    'SYNO.Finder.Elastic.SearchHistory': ['get', 'delete'],
    'SYNO.Finder.Elastic.Term': ['suggest'],
    'SYNO.Finder.Bookmark': ['get', 'add'],
    'SYNO.Finder.AppIndexing.Search': ['search'],
    'SYNO.Finder.File.Cover': ['get'],
    'SYNO.Finder.File.Thumbnail': ['get'],
    'SYNO.Finder.Preference': ['get', 'set'],
    'SYNO.Finder.Settings': ['get', 'set'],
  };
}

/// 全局搜索入口的状态机。
///
/// 与 `AvailabilityState` 分开：`SYNO.Finder.*` **不属于任何 StationService**
/// （不是套件，是 DSM 横切能力），所以走"能力表存在性 + 调用错误码"两段判定，
/// 而不是 `classifyApiTable`。
enum FinderGateState {
  /// 还没拿到能力表（未连接 / 未检测）→ **不判死**（入口按可见渲染，
  /// 与 `hidesModule` 的 `unknown` 语义一致）。
  unknown,

  /// 能力表里有 `SYNO.Finder.FileIndexing.Search` → 入口出现。
  available,

  /// 能力表里明确没有 → 入口**隐藏**（`absent` 语义）。
  absent,

  /// 调用返回 `105`（已安装但该账号无权用）→ 提示 + **隐藏入口**
  /// （自我保护：`allowUser` 未验证时，功能自禁用而不是报错）。
  noPermission,

  /// 调用返回 `119`（会话失效）→ 提示，**绝不隐藏**。
  sessionExpired,
}

/// **纯函数**：由"能力表存在性 + 最近一次调用错误码"算入口状态。
///
/// * [probed] = 是否真的拿到过能力表（`apis` 非空才算）；
/// * [apiNames] = 能力表里的 API 名；
/// * [errorCode] = 最近一次搜索调用返回的 DSM 错误码（null = 没出错）。
///
/// 优先级：**错误码 > 能力表**（119 必须压过"表里有"；105 必须压过"表里有"），
/// 且 `unknown` / 会话失效都**不隐藏**。
FinderGateState classifyFinderGate({
  required bool probed,
  required Set<String> apiNames,
  int? errorCode,
}) {
  switch (errorCode) {
    case 105:
    case 160:
      return FinderGateState.noPermission;
    case 119:
    case 106:
      return FinderGateState.sessionExpired;
    default:
      break;
  }
  if (!probed) return FinderGateState.unknown;
  return apiNames.contains(FinderApi.gateApi)
      ? FinderGateState.available
      : FinderGateState.absent;
}

/// 入口是否应当**隐藏**（只有 `absent` 与 `noPermission` 隐藏）。
bool hidesFinderEntry(FinderGateState state) =>
    state == FinderGateState.absent || state == FinderGateState.noPermission;
