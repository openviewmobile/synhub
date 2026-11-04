// Download Station 业务 API（**只做普通用户功能**）—— 在 [DsmWebApi] 之上把
// `SYNO.DownloadStation2.*`（新代，synoapid）收敛成强类型方法。
//
// ★ 权威事实来源：`docs/stage2-audio-download-api.md`（本项目对
//   DownloadStation-x86_64-4.1.2-5012.spk 的离线取证）。本文件里的
//   **api 名 / method / 版本 / 参数名**逐字对齐该文档 §3.3–§3.5 与包内官方
//   Web 前端 `ui/download.js`；不要凭记忆改。
//
// 已实现（文档 A-2 切片 D1/D2/D4/D6，普通用户）：
//   * `Task.list` v2        —— root `task` + `total`；`offset/limit/sort_by/order`、
//                              `additional=["detail","transfer"]`、`status` 过滤、
//                              `type=["emule"] & type_inverse=true`（默认排除 eMule）
//   * `Task.get` v2         —— 任务详情（`additional=["detail"]`）
//   * `Task.Statistic.get` v1 —— 顶部总速率（`download_rate`/`upload_rate`）
//   * `Task.create` v2      —— `type=url`（HTTP/FTP/磁力/迅雷）；种子上传走
//                              **`webapi/entry.cgi/SYNO.DownloadStation2.Task`** 的
//                              multipart（字段 `type` / `file` / `torrent` 文件块）
//   * `Task.pause` / `resume` / `delete` v2 —— 单任务与批量
//   * `Task.BT.get` / `set` v2 —— **单任务**限速（§3.3 A-2d 结论：普通用户可改）
//   * `Settings.Location.get` v1 —— 默认下载目录（normal，用于新建表单预填）
//   * `Task.BT.File.list` v1–v2 —— 任务内文件清单（A6，只读；root `items`）
//   * `Thumbnail.get` v2 + `Thumbnail.download` v2 —— BT 预览缩略图（F8，参数 `id`）
//   * `Task.Source.download` v2 —— 取回原始 `.torrent` 字节（F7）
//   * `Settings.AutoExtraction.get` / `set` v1 —— 自动解压设置（F9，普通用户可读写）
//
// 明确**不做**（文档 §3.1 的 admin-only 与 §6.2 后置项，代码里也不留半成品）：
//   * `Settings.Global/BT/FtpHttp/Nzb/Rss/Scheduler/Emule/BTSearch/FileHosting.*`
//     （全局限速、下载计划、RSS/文件托管服务端配置……`allowUser=['admin.local']`）
//   * 老 `SYNO.DownloadStation.Info.getconfig/setserverconfig`、`Schedule.*`（推断 admin-only）
//   * BTSearch / RSS / eMule / Captcha / Package（后置，未做）
//
// ⚠️ 数据层：**不许** import flutter / package:flutter（要能被 `dart run tool/*.dart`
// 加载）；文案走 `dataText(key, 中文原文)`（见 docs/app-identity-and-i18n.md §4.6）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../core/i18n/data_text.dart';
import '../core/net/traffic_meter.dart';
import '../dsm/webapi.dart';
import 'dto/download_task_dto.dart';
import 'remote/compound.dart';

/// §5 U2：DS2 `Task.create` 的 `type` 值在官方前端里有**两种并存形态**。
///
/// 取证（`ui/download.js`，逐字）：
///   * 程序化/快捷路径 `addQuickURL`：`{type:"url", url:[a], …}` → 线上是 `url`；
///   * 表单路径（`DLM.QueueAddFile` / aMule 单选切换）：
///     `Ext.encode("file")` / `Ext.encode("url")` → 线上是**带引号**的 `"file"`/`"url"`。
///
/// 两种都在官方代码里，无法从静态证据判断服务端接受哪一种 → 这里做成**可切换**：
/// 默认按各自官方路径的形态（URL 用 [plain]，上传用 [jsonQuoted]），
/// 真机确认后（§5 U2）可整体切到另一种。发错形态的典型症状是 `502 JSON_PARSE_FAILED`。
enum DsCreateValueShape {
  /// `type=url`（不带引号）
  plain,

  /// `type="url"`（`Ext.encode` 的线上值，带双引号）
  jsonQuoted,
}

/// `Task.create` 的返回：`create_list=true` 时服务端回 `list_id`（异步选文件流程）。
class DsCreateResult {
  const DsCreateResult({this.listId});

  /// 种子/文件上传后「选择文件」流程的 id（`Task.List.get` / `Polling.*` 用）。
  ///
  /// ★★ r387/DA37（**真机读到**）：服务端的 `list_id` 是**数组**
  /// （官方 `updateCreateInfo` 是 `listIds.concat(d.list_id)`），
  /// 每个元素一个清单 id。以前这里用 `'$v'` 直接字符串化：
  ///   * `[]`（URL 建任务、服务端没生成清单）→ 得到字符串 `"[]"`（2 字符），
  ///     于是页面被推出来、却必然 `Task.List:get` 失败
  ///     （真机：`code=120 errors{name:list_id,reason:type}`，见 `w3_45.xml` +
  ///     logcat 的 `[ds] Task.List.get failed …`）；
  ///   * `["abc"]` → 得到 `"[abc]"`，同样不是服务端要的标量。
  /// 现在：数组取**第一个非空元素**；空数组（或 `[]`/`{}` 这种空壳字符串）
  /// 一律当**没有清单**（null）⇒ 上层不再推一个注定失败的页面。
  final String? listId;
}

/// `SYNO.DownloadStation2.*` 的高层封装。**不持有传输** —— 传输由 [DsmWebApi] 管。
class DownloadStationApi {
  DownloadStationApi(DsmWebApi api)
    : api = api.withModule(TrafficModules.downloads);

  final DsmWebApi api;

  // ------------------------------------------------------------ 常量（逐字）
  static const String apiTask = 'SYNO.DownloadStation2.Task';
  static const String apiStatistic = 'SYNO.DownloadStation2.Task.Statistic';
  static const String apiBt = 'SYNO.DownloadStation2.Task.BT';
  static const String apiLocation = 'SYNO.DownloadStation2.Settings.Location';

  /// `Task.List` / `Task.List.Polling` —— 种子上传后"选择要下载的文件"流程
  /// （官方 `QueueAddFilePanel`，v2）。normal 可用（SPK `.lib` `normal.local`）。
  static const String apiTaskList = 'SYNO.DownloadStation2.Task.List';
  static const String apiTaskListPolling =
      'SYNO.DownloadStation2.Task.List.Polling';

  /// BT Tracker / Peer 只读列表（官方 `InfoTracker` / `InfoPeer`，v2）。
  static const String apiTracker = 'SYNO.DownloadStation2.Task.BT.Tracker';
  static const String apiPeer = 'SYNO.DownloadStation2.Task.BT.Peer';

  /// 任务内**文件清单**（官方 `InfoFile`，v1–v2）。
  ///
  /// 官方前端逐字：`{api:"SYNO.DownloadStation2.Task.BT.File", method:"list",
  /// version:2, root:"items", totalProperty:"total"}`；`task_id` 必填。
  /// ⚠️ 名称是 **`DownloadStation2`** 家族（`docs/download-api-live.md:35`）；
  /// `SYNO.DownloadStation.Task.BT.File` 在本机 `API.Info` 里**不存在**。
  static const String apiFile = 'SYNO.DownloadStation2.Task.BT.File';

  /// 缩略图（`docs/download-api-live.md:32`：`get` v2，参数 `id` 已实测）。
  static const String apiThumbnail = 'SYNO.DownloadStation2.Thumbnail';

  /// 任务源文件（`.torrent`/`.nzb`）导出（`docs/download-api-live.md:36`，v2）。
  static const String apiSource = 'SYNO.DownloadStation2.Task.Source';

  /// 自动解压设置（`docs/download-api-live.md:31`：`get` v1 普通用户可读）。
  static const String apiAutoExtraction =
      'SYNO.DownloadStation2.Settings.AutoExtraction';

  /// eMule **上传**列表（F1 的管理员部分）：
  /// `SYNO.DownloadStation2.Task.eMule / list_upload` v1。
  ///
  /// 事实来源：包内 `webapi/SYNO.DownloadStation2.Task.eMule.lib`
  /// （v1，方法 `list_upload`，`authLevel:1`，**`allowUser` 不含普通用户**
  /// ⇒ adminOnly）+ 官方前端 `ui/download.js` 的 aMule UpperPanel store
  /// （root `task`、`paramNames:{offset,limit,sort:"sort_by",dir:"order"}`）。
  static const String apiEmuleUpload = 'SYNO.DownloadStation2.Task.eMule';

  /// eMule **服务器 / Kad 管理**（F2，**管理员**）：
  /// `SYNO.DownloadStation2.eMule.Server` v1。
  ///
  /// 事实来源：包内 `webapi/SYNO.DownloadStation2.eMule.Server.lib`
  /// （v1，方法 `get_status/connect/connect_kad/disconnect/delete/add/list`，
  /// **`allowUser` 不含普通用户** ⇒ adminOnly）+ 官方前端 aMule ServerGridPanel
  /// （list root `results`、`paramNames:{offset,limit,sort:"sort_by",dir:"order"}`；
  /// `connect` = `{id}`、`disconnect` = `{type:"all"}`、`delete` = `{id:[…]}`；
  /// `connect_kad` 无参，且官方把它与 `connect` 放进同一次复合请求）。
  static const String apiEmuleServer = 'SYNO.DownloadStation2.eMule.Server';

  /// eMule **搜索**（F3）：`SYNO.DownloadStation2.eMule.Search` v1。
  ///
  /// 事实来源：包内 `webapi/SYNO.DownloadStation2.eMule.Search.lib`
  /// （v1，方法 `start/list/stop/download`，`allowUser` 含普通用户）
  /// + 官方前端 `ui/download.js` 的 aMule AdvancedSearchPanel / SearchGridPanel。
  static const String apiEmuleSearch = 'SYNO.DownloadStation2.eMule.Search';

  /// NZB 日志（F5）：`Task.NZB.Log / get` v1，参数 `task_id`，回包 `nzblog`。
  ///
  /// 事实来源：包内 `webapi/SYNO.DownloadStation2.Task.NZB.lib`（v1，两个方法，
  /// `allowUser` 含 `normal.local`）+ 官方前端 `ui/download.js` 逐字调用点
  /// （`params:{task_id}`）；真机只读实调确认 `task_id` 为必填（120 oracle）。
  static const String apiNzbLog = 'SYNO.DownloadStation2.Task.NZB.Log';

  /// NZB 文件清单（F6）：`Task.NZB.File / list` v1，参数 `task_id`，root `items`。
  ///
  /// 官方 store：`fields:["name","size"]`、`totalProperty:"total"`、
  /// `paramNames:{start:"offset",limit:"limit"}`。
  static const String apiNzbFile = 'SYNO.DownloadStation2.Task.NZB.File';

  /// 套件版本（F14）：`Package.Info / get` v2，普通用户可读。
  ///
  /// 真机实调：`{major:4,minor:1,build_number:5012,is_manager:false}`。
  static const String apiPkgInfo = 'SYNO.DownloadStation2.Package.Info';

  /// 已安装模块（F14）：`Package.Module / list` v2，root `listItems`。
  static const String apiPkgModule = 'SYNO.DownloadStation2.Package.Module';

  /// 服务/能力位（F14）：`Package.Service / get` v2。
  ///
  /// 真机实调：`{enable_bt_preview,enable_emule,enable_unzip,is_unzip_service_enable}`。
  static const String apiPkgService = 'SYNO.DownloadStation2.Package.Service';

  /// NZB 日志在任务不存在/本任务无 NZB 日志时的**中性**业务码 `404`。
  ///
  /// 真机只读实调（2026-09-22，NAS 0 任务）：`task_id=bogus` → `404`。
  /// 对 NZB 页签这是"没有日志/不是 NZB 任务"的**正常回落**，不是加载失败。
  static const int errNzbNotAvailable = 404;

  /// BT 搜索（新代）：`SYNO.DownloadStation2.BTSearch` v1，**只有 5 个方法**
  /// `start`/`list`/`stop`/`list_category`/`list_plugin_status`
  /// （包内 `.lib` 逐字，`docs/download-api-live.md:204-218`）；`path=entry.cgi`。
  /// **普通用户可用**（`.lib` 的 `allowUser=["admin.local","normal.local"]`）。
  /// ⚠️ `Settings.BTSearch:*` 是 admin-only（105），**本模块绝不调用**
  /// （`start` 报 1408 时给降级空态，而不是去调管理接口）。
  static const String apiBtSearch = 'SYNO.DownloadStation2.BTSearch';

  /// BT 搜索（**老一代**）：`SYNO.DownloadStation.BTSearch` v1，
  /// **path 逐字是 `DownloadStation/btsearch.cgi`**（不是 `entry.cgi`！）。
  ///
  /// 方法表（包内 `DownloadStation.api` 逐字）：
  /// `v1: ["start", "list", "getCategory", "clean", "getModule"]`。
  ///
  /// ⚠️ **wave4 重大更正**：真机（普通用户）`getModule` / `start {keyword}` /
  /// `list {taskid,offset,limit}` **全部可用**，`list` 回真实结果
  /// （`docs/download-api-live.md` §12 更正了早先"`start` HTTP 502"的误判 ——
  /// 那次是用 `entry.cgi` 测的）。`getCategory`（403）/ `clean`（401）不取证、不做。
  ///
  /// ⚠️ 方法名大小写以包内 `DownloadStation.api` 为准 = **`getModule`**
  /// （文档正文写的 `getmodule` 是转述；见 `docs/download-gaps-wave2.md`）。
  static const String apiBtSearchLegacy = 'SYNO.DownloadStation.BTSearch';

  // ------------------------------------------------------------ RSS 订阅（wave3）
  //
  // 事实来源（**三层都对上了才写**）：
  //   * 包内 `webapi/SYNO.DownloadStation2.RSS.lib` 逐字：三个 API
  //     `RSS.Feed` / `RSS.Filter` / `RSS.Item`，**都只有 v1**，
  //     `allowUser=["admin.local","normal.local"]`（普通用户可用），
  //     `authLevel=1`，path 由 `SYNO.API.Info` 给（真机 = `entry.cgi`）；
  //   * 包内官方前端 `ui/download.js` 的 `DLM.RSS*` 调用点（逐字，见下）；
  //   * 真机实测（`docs/download-api-live.md` §11）：`Feed:list` / `Feed:updateall`
  //     可用，其余方法"缺参报 120"钉死参数名。
  //
  // ⚠️ **不要**再写老代兜底：`SYNO.DownloadStation.RSS.*` 真机 **102 不存在**
  //   （`docs/download-api-live.md:331`）。

  /// RSS 订阅源：`add` / `delete` / `list` / `set` / `update` / `updateall`（v1）。
  static const String apiRssFeed = 'SYNO.DownloadStation2.RSS.Feed';

  /// RSS 自动下载过滤器：`add` / `delete` / `list` / `set` / `test`（v1）。
  static const String apiRssFilter = 'SYNO.DownloadStation2.RSS.Filter';

  /// RSS 订阅条目：`clear` / `list`（v1）。
  static const String apiRssItem = 'SYNO.DownloadStation2.RSS.Item';

  /// 官方 RSS 列表每页条数：`DLM.RSSGridPanel` / `RSSItemList` / `RSSFilterList`
  /// 三处都是 `this.itemsPerPage=50`（`ui/download.js` 逐字）。
  static const int rssPageSize = 50;

  /// 官方 RSS 轮询间隔：`RSS.createPollingTask` 的 `interval:5000`
  /// （`ui/download.js` 逐字）——`is_updating` 为真时每 5 秒拉一次 `Feed:list`。
  static const Duration rssPollInterval = Duration(seconds: 5);

  /// `Feed:list` 轮询上限。官方 RSS 轮询**没有**次数上限（只有 BTSearch 有
  /// 120）——这里给一个保守上限，避免"服务端永远 `is_updating:true`"时无限转。
  static const int rssMaxPolls = 120;

  /// DS2 RSS 的**语义未定**业务码集合。
  ///
  /// 真机 `Feed:add` 用 4 个真实/伪造 feed URL 实测：`2404`（3 个可达 URL）、
  /// `2405`（非 RSS 页面）——**成功路径未取证，语义未定**
  /// （`docs/download-api-live.md:328-330`）。
  /// **绝不给它们编文案**：界面一律走 [DsmErrorCode.describe] 的
  /// "未知错误 + 原始码"通用提示（任务书硬要求）。
  static const Set<int> rssUndeterminedErrorCodes = {2404, 2405};

  /// `Task.BT.File/list` 的**中性**业务码：任务未激活（暂停**或**已完成）→
  /// 当前没有可读文件清单。真机实测（`docs/download-api-live.md:98/135/137`）：
  /// 开关是 `is_active_torrent`，**与"是不是 BT 任务"无关**；
  /// 界面应给中性提示，不是"加载失败"。
  static const int errFileListInactive = 1913;

  /// `Thumbnail/get` 的**中性**业务码：暂无缩略图。
  ///
  /// 真机实测（`docs/download-api-live.md:115/139-141`）：**成功回包未取证**
  /// （整片下完、5 种参数形态仍全部 1911）。一律按"暂无缩略图"回落既有图标。
  static const int errNoThumbnail = 1911;

  /// `Task.List/get` 的**中性**业务码：`1910` = 清单不存在/已过期。
  ///
  /// 真机只读实测（2026-09-22，普通用户）：
  /// `Task.List:get v2 {list_id:"bogus-xyz"}` → `{"error":{"code":1910}}`
  /// ⇒ 参数名 `list_id` **被接受**（不再是 120），1910 是"这个清单没了"。
  /// 界面按"清单已过期，请重新添加任务"提示，**不是**加载失败。
  static const int errTaskListNotFound = 1910;

  /// `BTSearch` 的**中性**业务码：`SYNODL_ERR_BTSERACH_ID_NOT_FOUND = 1408`
  /// （官方 `ui/download.js` 错误表逐字，`docs/download-api-live.md:263`）。
  ///
  /// 真机语义：**"这台 NAS 未启用 BT 搜索 / 搜索会话无可用数据源 / id 失效"**
  /// → **不是加载失败**，界面给明确空态（`docs/download-api-live.md:180-184`）。
  static const int errBtSearchIdNotFound = 1408;

  /// 官方 `DLM.SearchGridPanel.maxRequestTimes = 120`（`ui/download.js`）：
  /// 轮询到这个次数就停，**绝不无限转**。
  static const int btSearchMaxPolls = 120;

  /// 官方轮询间隔：`interval:5000`（`ui/download.js` 的 `startSearch`）。
  static const Duration btSearchPollInterval = Duration(seconds: 5);

  /// 官方搜索结果每页条数（`itemsPerPage`，`ui/download.js`）。
  static const int btSearchPageSize = 25;

  /// 官方分页大小（`NUM_REC_PER_PAGE = 25`）。
  static const int pageSize = 25;

  /// 一次最多 50 个 URL / 50 个文件（官方 `ADDTASK_MAXLIMIT: 50`）。
  static const int maxAddLimit = 50;

  /// 单文件上限 100 MiB（官方 `ADDTASK_MAXSIZE: 104857600`）。
  static const int maxAddBytes = 104857600;

  /// 上传时 multipart 文件块的**字段名**：官方 `FILEFILEDNAME:"torrent"`
  /// （`.torrent`/`.nzb`/`.txt` 都走这一个字段名）。
  static const String uploadFileField = 'torrent';

  /// 列表排序键 = 官方 store 的**字段名**（`ui/download.js` 的 `createStore`）。
  ///
  /// ⚠️ `sort_by` 的**合法取值域**没有穷举证据（§5 U7）：这张表是从官方
  /// store 字段名整理出来的候选；界面默认**不传** sort_by（用服务端默认序）。
  static const Map<String, String> sortFields = {
    'filename': 'title', // 名称
    'total_size': 'size', // 大小
    'current_size': 'downloaded', // 已下载
    'status': 'status', // 状态
    'current_rate': 'speed_download', // 下载速度
    'upload_rate': 'speed_upload', // 上传速度
    'started_time': 'started_time', // 添加时间
  };

  static const List<int> _taskVersions = [2, 1];
  static const List<int> _btVersions = [2, 1];
  static const List<int> _fileVersions = [2, 1];
  static const List<int> _thumbnailVersions = [2];
  static const List<int> _v1 = [1];
  static const List<int> _v2 = [2];
  static const List<int> _captchaVersions = [2, 1];

  // ------------------------------------------------------------ 能力 / 版本

  /// 候选版本里挑一个服务器真正支持的（与 `FileStationApi.negotiate` 同规则）。
  int negotiate(String apiName, List<int> candidates) {
    final entry = api.apiTable?[apiName];
    if (entry == null || candidates.isEmpty) {
      return candidates.isEmpty ? 1 : candidates.first;
    }
    final within = candidates.where(
      (c) => c >= entry.minVersion && c <= entry.maxVersion,
    );
    if (within.isNotEmpty) return within.reduce((a, b) => a > b ? a : b);
    return entry.maxVersion < candidates.last
        ? entry.maxVersion
        : entry.minVersion;
  }

  /// 服务器是否声明了某 API（`SYNO.API.Info` 实测表）。
  ///
  /// 表为空（未 discover）时按"未知"处理，返回 true —— 交给调用时的错误兜底。
  bool hasApi(String apiName) {
    final table = api.apiTable;
    if (table == null) return true;
    return table.containsKey(apiName);
  }

  /// **套件未安装**的强判据：能力表里没有 `SYNO.DownloadStation2.Task`。
  ///
  /// 与"有 API 但没权限（160/105）"和"网络不通"区分开，界面才能给对的空态
  /// （任务书硬要求：不要一律"加载失败"）。
  bool get installed => hasApi(apiTask);

  // ------------------------------------------------------------ 列表 / 详情

  /// `SYNO.DownloadStation2.Task / list`（v2）。
  ///
  /// 参数逐字对齐官方 `getLoadParams()`：
  /// ```
  /// {offset, limit, sort_by, order, additional:["detail","transfer"],
  ///  type:["emule"], type_inverse:true, status, keyword}
  /// ```
  /// 返回 root 是 **`task`**、total 是 **`total`**（不是 items/total！）。
  ///
  /// eMule 任务恒被服务端 `type:["emule"] & type_inverse:true` 排除（官方默认；
  /// 真机 `Task.eMule.list_upload` 对普通用户 `105`，所以本客户端不做 eMule
  /// 分支 —— 原 `includeEmule` 形参无调用方，P0 批次删除）。
  Future<DownloadTaskPage> listTasks({
    int offset = 0,
    int limit = pageSize,
    DownloadTaskCategory category = DownloadTaskCategory.all,

    /// 关键字过滤（服务端 `keyword`）。
    String? keyword,

    /// 排序：键取 [sortFields] 的 key；**默认不传**（服务端默认序，§5 U7）。
    String? sortBy,
    bool descending = false,

    /// **只看 eMule 任务**（F1）。
    ///
    /// 官方 aMule 面板逐字：`type:["emule"]`（**不带** `type_inverse`）；
    /// 而默认队列是 `type:["emule"], type_inverse:true`（排除 eMule）。
    bool emuleOnly = false,
  }) async {
    final statusFilter = statusesFor(category);
    final trimmedKeyword = (keyword ?? '').trim();
    final params = <String, dynamic>{
      'offset': offset,
      'limit': limit,
      // 复杂参数一律 JSON 串：官方前端走 SYNO.API.Request，数组在线上就是
      // `["detail","transfer"]` 这种 JSON 文本；FileStation 也是同一形态
      // （真机实测 `additional` 不能当重复字段发）。
      'additional': jsonEncode(const ['detail', 'transfer']),
      'type': jsonEncode(const ['emule']),
      // emuleOnly：官方 aMule 面板**不下发** `type_inverse`（= 只要 eMule）
      if (!emuleOnly) 'type_inverse': true,
      if (statusFilter != null && statusFilter.isNotEmpty)
        'status': jsonEncode(statusFilter),
      if (trimmedKeyword.isNotEmpty) 'keyword': trimmedKeyword,
      if (sortBy != null && sortBy.isNotEmpty) ...{
        'sort_by': sortBy,
        'order': descending ? 'desc' : 'asc',
      },
    };
    final data = await api.call(
      apiTask,
      'list',
      preferredVersion: negotiate(apiTask, _taskVersions),
      params: params,
    );
    final raw = data['task'] ?? data['tasks'];
    final items = <DownloadTaskDto>[
      if (raw is List)
        for (final e in raw)
          if (e is Map) DownloadTaskDto.fromJson(Map<String, dynamic>.from(e)),
    ];
    return DownloadTaskPage(
      items: items,
      total: _intOf(data['total'], items.length),
      offset: offset,
      limit: limit,
    );
  }

  /// eMule **上传**列表（F1，管理员）：`Task.eMule / list_upload` v1。
  ///
  /// 官方 aMule 面板逐字：`paramNames:{offset,limit,sort:"sort_by",dir:"order"}`，
  /// root `task`、totalProperty `total`；对应 `Task.Statistic/get`
  /// `{type:["emule"], type_inverse:false}` 拿上传速率。
  Future<DsEmuleUploadPage> emuleUploads({
    int offset = 0,
    int limit = pageSize,
    String? sortBy,
    String? order,
  }) async {
    final data = await api.call(
      apiEmuleUpload,
      'list_upload',
      preferredVersion: negotiate(apiEmuleUpload, _v1),
      params: {
        'offset': offset,
        'limit': limit,
        if (sortBy != null && sortBy.isNotEmpty) 'sort_by': sortBy,
        if (order != null && order.isNotEmpty) 'order': order,
      },
    );
    return DsEmuleUploadPage.fromJson(data, offset: offset, limit: limit);
  }

  /// 分类 → 服务端 `status` 过滤值。
  ///
  /// 「下载中」「已完成」「已暂停」直接照官方 `QueueDownloading`/`QueueFinished`/
  /// `QueueStopped` 的常量表；「错误」用 §3.5 的错误态全表（`status >= 101`）。
  static List<int>? statusesFor(DownloadTaskCategory category) =>
      switch (category) {
        DownloadTaskCategory.all => null,
        DownloadTaskCategory.active => DsTaskStatus.activeGroup,
        DownloadTaskCategory.downloading => DsTaskStatus.downloadingGroup,
        DownloadTaskCategory.waiting => DsTaskStatus.waitingGroup,
        DownloadTaskCategory.seeding => DsTaskStatus.seedingGroup,
        DownloadTaskCategory.hashChecking => DsTaskStatus.hashCheckingGroup,
        DownloadTaskCategory.extracting => DsTaskStatus.extractingGroup,
        DownloadTaskCategory.paused => DsTaskStatus.pausedGroup,
        DownloadTaskCategory.finished => DsTaskStatus.finishedGroup,
        DownloadTaskCategory.error => DsTaskStatus.errorGroup,
      };

  /// `SYNO.DownloadStation2.Task / get`（v2）—— 单个/多个任务详情。
  Future<List<DownloadTaskDto>> getTasks(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final data = await api.call(
      apiTask,
      'get',
      preferredVersion: negotiate(apiTask, _taskVersions),
      params: {
        'id': jsonEncode(ids),
        'additional': jsonEncode(const ['detail']),
      },
    );
    final raw = data['task'] ?? data['tasks'];
    return [
      if (raw is List)
        for (final e in raw)
          if (e is Map) DownloadTaskDto.fromJson(Map<String, dynamic>.from(e)),
    ];
  }

  /// 单个任务详情（找不到就是 null）。
  Future<DownloadTaskDto?> getTask(String id) async {
    final list = await getTasks([id]);
    return list.isEmpty ? null : list.first;
  }

  /// `SYNO.DownloadStation2.Task.Statistic / get`（v1）—— 顶部总速率。
  ///
  /// 官方前端也是默认排除 eMule（`type:["emule"], type_inverse:true`）。
  Future<DownloadTaskStatistic> statistic() async {
    final data = await api.call(
      apiStatistic,
      'get',
      preferredVersion: negotiate(apiStatistic, _v1),
      params: {
        'type': jsonEncode(const ['emule']),
        'type_inverse': true,
      },
    );
    return DownloadTaskStatistic.fromJson(data);
  }

  /// `SYNO.DownloadStation2.Settings.Location / get`（v1，normal）——
  /// 默认下载目录（官方 `webapiLocationGet`；字段 `default_destination`）。
  Future<String> defaultDestination() async {
    final data = await api.call(
      apiLocation,
      'get',
      preferredVersion: negotiate(apiLocation, _v1),
    );
    return '${data['default_destination'] ?? ''}';
  }

  // ------------------------------------------------------------ 建任务

  /// `Task / create`（v2）—— URL / 磁力 / 迅雷 / flashget / qqdl。
  ///
  /// 官方 `addQuickURL` 的参数：`{type:"url", url:[a], destination, create_list:false}`；
  /// URL 前缀只做**规范化**（不解码），整串交给服务端（§3.3）。
  ///
  /// [shape] 见 [DsCreateValueShape]（§5 U2，默认按官方快捷路径 = 不带引号）。
  Future<DsCreateResult> createUrlTask({
    required List<String> urls,
    String? destination,
    String? username,
    String? password,
    String? extractPassword,
    bool createList = false,
    DsCreateValueShape shape = DsCreateValueShape.plain,
  }) async {
    final links = [
      for (final u in urls)
        if (canonizeUrl(u) case final c when c.isNotEmpty) c,
    ];
    if (links.isEmpty) {
      throw DsmApiException(
        DsmErrorCode.noRequiredParam,
        method: '$apiTask.create',
      );
    }
    if (links.length > maxAddLimit) {
      throw DsmApiException(501, method: '$apiTask.create'); // REACH_LIMIT
    }
    // ★★ DA60（r408 真机 + 服务端**原始 error.code**）：
    //   `destination` 是 `Task/create` 的**必填项**。缺它时服务端回
    //     `{"error":{"code":120,"errors":{"name":"destination","reason":"required"}}}`
    //   —— 而"链接浏览器 → 添加到下载"这条路径**从来没传过 destination**
    //   ⇒ 磁力 / `ed2k://` / `.torrent` URL **一律** 120（r408 真机两种链接都复现：
    //   界面只显示 `Invalid request parameter`，任务一条都没建出来）。
    //   修法：按服务端契约补默认目录（`Settings.Location/get` 的
    //   `default_destination`，与"新建任务"页预填的是同一个值）；
    //   调用方显式给了就用调用方的。
    var dest = destination;
    if (dest == null || dest.isEmpty) {
      try {
        dest = await defaultDestination();
      } catch (_) {
        // 取不到默认目录**不是**本函数要报的错：照旧不传，
        // 让服务端按它自己的规则回答（120 会点名 `destination`，见 DA61）。
        dest = null;
      }
    }
    final data = await api.call(
      apiTask,
      'create',
      preferredVersion: negotiate(apiTask, _taskVersions),
      params: {
        'type': _typeValue('url', shape),
        // 数组参数在线上是 JSON 文本（官方 `url:[...]`）。
        'url': jsonEncode(links),
        if (dest != null && dest.isNotEmpty) 'destination': jsonEncode(dest),
        if (username != null && username.isNotEmpty)
          'username': Uri.encodeComponent(username),
        if (password != null && password.isNotEmpty)
          'password': Uri.encodeComponent(password),
        if (extractPassword != null && extractPassword.isNotEmpty)
          'extract_password': extractPassword,
        'create_list': createList,
      },
    );
    return DsCreateResult(listId: firstCreateListId(data['list_id']));
  }

  /// `Task / create`（v2）—— 上传 `.torrent` / `.nzb` / `.txt`。
  ///
  /// 端点**逐字**是 `webapi/entry.cgi/SYNO.DownloadStation2.Task`（官方
  /// `formWebAPIUrl("SYNO.DownloadStation2.Task")` + `filefiledname:"torrent"`）。
  ///
  /// multipart 形态（官方 `QueueAddFile` 表单，逐字）：
  ///   * 文件块字段名 = **`torrent`**（`FILEFILEDNAME`）；
  ///   * 表单字段 `file` = `Ext.encode(["torrent"])` → JSON 文本 `["torrent"]`
  ///     （**注意**：`file` 是"告诉服务端文件在哪个字段里"，不是文件块本身）；
  ///   * 表单字段 `type` = `Ext.encode("file")` → 线上 **`"file"`（带引号）**；
  ///   * `destination` = `Ext.encode(dest)` → JSON 文本；`create_list`；`extract_password`。
  Future<DsCreateResult> createFileTask({
    required String filePath,
    required String fileName,
    String? destination,
    String? extractPassword,
    bool createList = false,
    DsCreateValueShape shape = DsCreateValueShape.jsonQuoted,
  }) async {
    final version = negotiate(apiTask, _taskVersions);
    final body = await api.postMultipart(
      uploadPath(apiTask),
      query: {'api': apiTask, 'method': 'create', 'version': '$version'},
      fields: {
        'type': _typeValue('file', shape),
        'file': jsonEncode(const [uploadFileField]),
        if (destination != null && destination.isNotEmpty)
          'destination': jsonEncode(destination),
        if (extractPassword != null && extractPassword.isNotEmpty)
          'extract_password': extractPassword,
        'create_list': '$createList',
      },
      fileField: uploadFileField,
      filePath: filePath,
      fileName: fileName,
      mimeType: 'application/octet-stream',
    );
    final data = api.decodeData(body, '$apiTask.create');
    return DsCreateResult(listId: firstCreateListId(data['list_id']));
  }

  /// 上传端点的完整 path：`<cgi path>/SYNO.DownloadStation2.Task`。
  ///
  /// 能力表里注册的 path 是 `entry.cgi`（§5 U4 未在真机核对），官方前端也
  /// 就是 `webapi/entry.cgi/SYNO.DownloadStation2.Task`。
  String uploadPath(String apiName) {
    final base = api.apiPath(apiName);
    if (base.endsWith('/$apiName')) return base;
    return '$base/$apiName';
  }

  /// URL 前缀规范化（只做 scheme 大小写规范化，不解码）。
  ///
  /// **判定逻辑逐字对齐官方**（`com/synology/DSdownload/utils/Utils.java`）：
  ///   * 通用任务 `isValidUrls(TASKS_TYPE_GENERAL)`（`:212-228`）认
  ///     `http://` / `https://` / `ftp://` / `ftps://` / `sftp://` / `magnet:?` /
  ///     `thunder://` / `flashget://` / `file:///` / `qqdl://`；
  ///   * eMule 任务 `isValidUrls(TASKS_TYPE_EMULE)`（`:222-227`）与
  ///     `isValidDownloadUrls`（`:337-344`）认 **`ed2k://`**。
  ///
  /// 官方建任务时 ed2k 走的是 `{type:"url", url:[ed2k://…]}` 同一个字段
  /// （Web UI `addTaskByURL`：`{type:"url",url:[c],…}`），所以这里把 `ed2k://`
  /// 与 `file:///` 一并纳入规范化，不再自己发明规则。
  ///
  /// 都认不出就返回空串（调用方当"无效链接"）。
  static String canonizeUrl(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '';
    final lower = s.toLowerCase();
    const schemes = [
      'http://',
      'https://',
      'ftp://',
      'ftps://',
      'sftp://',
      'thunder://',
      'flashget://',
      'qqdl://',
      'ed2k://',
      'file:///',
    ];
    for (final p in schemes) {
      if (lower.startsWith(p)) return '$p${s.substring(p.length)}';
    }
    if (lower.startsWith('magnet:')) return 'magnet:${s.substring(7)}';
    return '';
  }

  /// 是否为磁力链接（官方 `isMagnetLink`：判 `magnet:?` 前缀）。
  static bool isMagnet(String raw) =>
      raw.trim().toLowerCase().startsWith('magnet:?');

  String _typeValue(String base, DsCreateValueShape shape) =>
      shape == DsCreateValueShape.jsonQuoted ? jsonEncode(base) : base;

  // ------------------------------------------------------------ 暂停/继续/删除

  /// `Task / pause`（v2）。
  Future<void> pauseTasks(List<String> ids) => _idAction('pause', ids);

  /// `Task / resume`（v2）。
  Future<void> resumeTasks(List<String> ids) => _idAction('resume', ids);

  /// **全部暂停** —— `Task / pause_condition`（v2）。
  ///
  /// 官方 Web UI 一键停全部（`ui/download.js` 的 `pause_all`）：
  /// `{api:"SYNO.DownloadStation2.Task", method:"pause_condition", version:2,
  ///   params:{type:["emule"], type_inverse:true}}`。
  /// 即"除 eMule 外的全部任务"，与我们的列表过滤口径一致。
  /// 老 App 走客户端拼 id 再发老 `Task.pause`；两条都是官方路径，这里按用户
  /// 指定的 DS2 `*_condition` v2 实现。
  Future<void> pauseAll() => _conditionAction('pause_condition');

  /// **全部恢复** —— `Task / resume_condition`（v2），参数同 [pauseAll]。
  Future<void> resumeAll() => _conditionAction('resume_condition');

  /// **按状态批量删除** —— `Task / delete_condition`（v2）。
  ///
  /// 官方 Web UI（`ui/download.js`）：
  ///   * 清除已完成 `clear`：`{type:["emule"], type_inverse:true,
  ///     status:[TASK_FINISHED]}`（`TASK_FINISHED = 5`）；
  ///   * 删除全部 `delete_all`：`{type:["emule"], type_inverse:true}`。
  ///
  /// [statuses] 为空即"删除全部任务"（官方 `delete_all`）。
  ///
  /// ⚠️ **会一并删除已下载文件**：`delete_condition` 是服务端 `Task.delete` 的
  /// 批量形态，`unlink` 语义与单任务删除相同（见 [deleteTasks] 注释）。
  Future<void> deleteCondition({List<int> statuses = const []}) async {
    await api.call(
      apiTask,
      'delete_condition',
      preferredVersion: negotiate(apiTask, _v2),
      params: {
        'type': jsonEncode(const ['emule']),
        'type_inverse': true,
        if (statuses.isNotEmpty) 'status': jsonEncode(statuses),
      },
    );
  }

  Future<void> _conditionAction(String method) async {
    await api.call(
      apiTask,
      method,
      preferredVersion: negotiate(apiTask, _v2),
      params: {
        'type': jsonEncode(const ['emule']),
        'type_inverse': true,
      },
    );
  }

  /// `Task / delete`（v2）。
  ///
  /// ⚠️ **与任务书的差异（不许含糊）**：DS2 的 `Task.delete` **没有**"是否连带
  /// 删除文件"的开关。取遍包内 `SYNO.DownloadStation2.Task.so` 与老 `task.cgi`
  /// 的参数 token，只找到 `force_complete`；官方前端删除时也只发
  /// `{id, force_complete:false}`（r382 从 SPK 现解 `ui/download.js` 逐字复核过）。
  ///
  /// ★★★ **r382 订正（DA29）**：这段注释原来写着"`.so` 里有 `unlink` token ⇒
  /// **服务端删除任务时会一并 unlink 下载文件**" —— **那是推断，不是读数，
  /// 而且真机把它证伪了**：r382 用宿主只读 HTTP 探针做对照实验，**3 个任务
  /// （1 个带文件清单 + 2 个普通 URL 任务）删完后，`home/Download` 下的
  /// `probe_r381/382/383.zip` 全都还在**（点空态里的显式 `Refresh` 才读到真值；
  /// 服务端访问日志证明三次下载都真发生）。官方前端的确认文案
  /// `download_cfrm_remove` = "Are you sure you want to remove the download task?"
  /// **根本不提删文件** ⇒ 界面文案**不许**再承诺"连带删文件"（已改 `dsDeleteBody`）。
  /// **服务端在什么状态下才会 unlink 仍是留白**（要 NAS 侧原始回包/日志），
  /// 所以文案只写"任务从列表移除"，**不对文件做任何承诺**（写多了就是新的撒谎）。
  /// 证据：`docs/evidence-r382/`（`t5_21`/`t5_27`/`t5_28` + 两份 `http_access_r382*.log`）。
  ///
  /// **[forceComplete] = 官方 App 的「结束下载任务」（`str_force_complete`）**：
  /// `TaskDetailFragment.java:306-316` / `TaskListFragment.java:390-400` 都是
  /// `DELETE` 方法 + `{id, force_complete:"true"}`。官方确认文案
  /// `str_force_complete_confirm` = "You cannot resume a download task after its
  /// files are moved to another folder." —— 即**结束后任务无法再续传**，
  /// 已下载的文件留在目标文件夹（不是"再删一次文件"）。界面文案必须按这个语义写。
  Future<void> deleteTasks(
    List<String> ids, {
    bool forceComplete = false,
  }) async {
    if (ids.isEmpty) return;
    await api.call(
      apiTask,
      'delete',
      preferredVersion: negotiate(apiTask, _taskVersions),
      params: {'id': jsonEncode(ids), 'force_complete': forceComplete},
    );
  }

  Future<void> _idAction(String method, List<String> ids) async {
    if (ids.isEmpty) return;
    await api.call(
      apiTask,
      method,
      preferredVersion: negotiate(apiTask, _taskVersions),
      params: {'id': jsonEncode(ids)},
    );
  }

  // ------------------------------------------------------------ 任务目的地修改（B8）

  /// `Task / edit`（v1–2，normal）—— 改任务目的地（以及 BT 优先级/解压密码）。
  ///
  /// 参数形态**逐字**取自 NAS 包内官方前端 `ui/download.js`
  /// （`DLM.EditTaskWindow.saveDestination` / `saveTorrentSetting`）：
  /// ```
  /// {api:"SYNO.DownloadStation2.Task", method:"edit", version:2,
  ///  params:{id:[task_id,…], destination:<路径>,
  ///           priority:<high|normal|low>?, extract_password:<密码>?}}
  /// ```
  /// ⇒ `id` 是**任务 id 数组**（官方 `this.taskIds` 由选中的每一行 `task_id` 组成），
  /// 不是单个字符串；这一点与 [getTasks] / [deleteTasks] 一致。
  ///
  /// ⚠️ **写操作**：本批按纪律未在真机调用（`docs/download-parity-audit.md` §9 U1）。
  /// 离线用例只钉"请求拼对了 + 失败如实上抛"。
  Future<void> editTask(
    List<String> ids, {
    String? destination,
    String? priority,
    String? extractPassword,
  }) async {
    if (ids.isEmpty) return;
    final dest = destination?.trim() ?? '';
    final prio = priority?.trim() ?? '';
    final pw = extractPassword ?? '';
    if (dest.isEmpty && prio.isEmpty) {
      // 官方只在 dirty 时才发；两个可改字段都空 = 没东西可发。
      throw DsmApiException(
        DsmErrorCode.noRequiredParam,
        method: '$apiTask.edit',
      );
    }
    // ★ 写动词的诊断串（第 328 轮加）：参数问题在跨进程用例里很难定位，
    //   而这一条正好是"界面填了 A、线上发的是不是 A"的唯一直接读数。
    //   ⚠️ 解压口令**只报有无**，绝不回显（§2.0.35）。
    debugPrint(
      '[ds] Task.edit ids=$ids '
      'destination="${dest.isEmpty ? '—' : dest}" '
      'priority="${prio.isEmpty ? '—' : prio}" '
      'extract_password=${pw.isEmpty ? '无' : '有（已打码）'}',
    );
    await api.call(
      apiTask,
      'edit',
      preferredVersion: negotiate(apiTask, _taskVersions),
      params: {
        'id': jsonEncode(ids),
        if (dest.isNotEmpty) 'destination': dest,
        if (prio.isNotEmpty) 'priority': prio,
        if (pw.isNotEmpty) 'extract_password': pw,
      },
    );
  }

  // ------------------------------------------------- 新建任务后置选项（C12）

  /// **新建任务后的"立即开始 / 排队"与限速**（C12）。
  ///
  /// 官方 `Task.create` 本身**没有**"是否立即开始"或限速参数
  /// （`ui/download.js` 的 `getWebAPICreateParams` 只有
  /// `url/destination/username/password/create_list/extract_password`）；
  /// 但 `Task/pause`（v1–2，normal）与 `Task.BT.set`（v1–2，normal）可对**刚建好
  /// 的任务**补做。这正是重判 §5.3 给 C12 的落点。
  ///
  /// [knownIds] 是**创建前**的任务 id 快照：创建后列表里多出来的那个就是新任务。
  /// 找不到（列表尚未刷新/并发创建）返回 `null`，调用方**不得**据此判定创建失败。
  Future<String?> newestTaskId(Set<String> knownIds) async {
    final page = await listTasks(offset: 0, limit: pageSize);
    DownloadTaskDto? best;
    for (final task in page.items) {
      if (knownIds.contains(task.id)) continue;
      final bestTime = best?.detail.createdTime ?? -1;
      if (best == null || task.detail.createdTime >= bestTime) best = task;
    }
    return best?.id;
  }

  /// 对**刚创建的任务**应用 C12 选项：
  ///   * `startImmediately == false` → `Task/pause`（加入队列/暂停）；
  ///   * 给了限速 → 先读 `Task.BT.get` 再 `Task.BT.set`（**单任务**限速，
  ///     normal 可改；全局限速是 admin-only，本客户端不做）。
  ///
  /// 返回是否真的下发过写请求（用于界面给"任务已创建，但选项未生效"的提示）。
  /// **限速只对 BT 任务有效**：非 BT 任务调 `Task.BT.get` 会失败，此处如实上抛，
  /// 由调用方提示（任务本身已经创建成功）。
  Future<bool> applyCreateOptions({
    required String taskId,
    bool startImmediately = true,
    int? maxDownloadRate,
    int? maxUploadRate,
  }) async {
    var applied = false;
    if (!startImmediately) {
      await pauseTasks([taskId]);
      applied = true;
    }
    final wantDown = maxDownloadRate != null && maxDownloadRate > 0;
    final wantUp = maxUploadRate != null && maxUploadRate > 0;
    if (wantDown || wantUp) {
      final current = await getBtSettings(taskId);
      await setBtSettings(
        taskId,
        current.copyWith(
          maxDownloadRate: wantDown ? maxDownloadRate : null,
          maxUploadRate: wantUp ? maxUploadRate : null,
        ),
      );
      applied = true;
    }
    return applied;
  }

  // ------------------------------------------------------------ 单任务 BT 限速

  /// `Task.BT / get`（v2）—— 单个 BT 任务的设置（普通用户可读）。
  Future<DownloadBtSettings> getBtSettings(String taskId) async {
    final data = await api.call(
      apiBt,
      'get',
      preferredVersion: negotiate(apiBt, _btVersions),
      params: {'task_id': taskId},
    );
    return DownloadBtSettings.fromJson(data);
  }

  /// `Task.BT / set`（v2）—— **单任务** BT 限速/做种/优先级（§3.3 A-2d：normal，可改）。
  ///
  /// 字段逐字对齐官方 `_getBTSetFieldValues`（`settingform.getFieldValues(true)`
  /// 的所有脏字段）：`seeding_ratio` / `max_upload_rate` / `max_download_rate` /
  /// `max_peers` / `seeding_interval` / `destination` / **`priority`**；
  /// `task_id` 官方传的是**任务 id 数组**。
  ///
  /// `priority` 取值 `high` / `normal` / `low`（官方 BT 属性表单的 combobox
  /// store，`ui/download.js`）；[DownloadBtSettings.priority] 为空时**不下发**
  /// （官方 `allowBlank:true`，不脏就不带）。
  ///
  /// 限速单位 **KB/s**，`0 = 不限`。全局限速是 admin-only（`Settings.BT.set`），
  /// 本客户端**不做**。
  Future<void> setBtSettings(String taskId, DownloadBtSettings s) async {
    await api.call(
      apiBt,
      'set',
      preferredVersion: negotiate(apiBt, _btVersions),
      params: {
        'task_id': jsonEncode([taskId]),
        'max_upload_rate': s.maxUploadRate,
        'max_download_rate': s.maxDownloadRate,
        'seeding_ratio': s.seedingRatio,
        'seeding_interval': s.seedingInterval,
        'max_peers': s.maxPeers,
        if (s.destination.isNotEmpty) 'destination': jsonEncode(s.destination),
        if (s.priority.isNotEmpty) 'priority': s.priority,
      },
    );
  }

  // ------------------------------------------------------------ Tracker / Peer（只读）

  /// `Task.BT.Tracker / list`（v2，normal 只读）—— 官方 `InfoTracker`：
  /// params `{task_id, offset, limit}`，root `items`、total `total`。
  Future<DownloadTrackerPage> listTrackers(
    String taskId, {
    int offset = 0,
    int limit = 50,
  }) async {
    final data = await api.call(
      apiTracker,
      'list',
      preferredVersion: negotiate(apiTracker, _v2),
      params: {'task_id': taskId, 'offset': offset, 'limit': limit},
    );
    final raw = data['items'];
    final items = <DownloadTrackerDto>[
      if (raw is List)
        for (final e in raw)
          if (e is Map)
            DownloadTrackerDto.fromJson(Map<String, dynamic>.from(e)),
    ];
    return DownloadTrackerPage(
      items: items,
      total: _intOf(data['total'], items.length),
    );
  }

  /// `Task.BT.Peer / list`（v2，normal 只读）—— 官方 `InfoPeer`：
  /// params `{task_id, offset, limit}`，root `items`、total `total`。
  Future<DownloadPeerPage> listPeers(
    String taskId, {
    int offset = 0,
    int limit = 50,
  }) async {
    final data = await api.call(
      apiPeer,
      'list',
      preferredVersion: negotiate(apiPeer, _v2),
      params: {'task_id': taskId, 'offset': offset, 'limit': limit},
    );
    final raw = data['items'];
    final items = <DownloadPeerDto>[
      if (raw is List)
        for (final e in raw)
          if (e is Map) DownloadPeerDto.fromJson(Map<String, dynamic>.from(e)),
    ];
    return DownloadPeerPage(
      items: items,
      total: _intOf(data['total'], items.length),
    );
  }

  // ------------------------------------------------------------ 任务内文件清单（A6）

  /// `Task.BT.File / list`（v1–v2，normal 只读）—— 任务详情的文件清单。
  ///
  /// 官方 `ui/download.js` 的 file store（逐字）：
  /// `{task_id, offset, limit}`（`paramNames:{start:"offset", limit:"limit",
  /// sort:"sort_by", dir:"order"}`），root **`items`**、total **`total`**。
  ///
  /// 回包字段见 [DownloadFileDto]（`index`/`name`/`size`/`size_downloaded`/
  /// `priority`/`wanted`）。**只读**：本方法不下发 `set`/`copy`（勾选/优先级
  /// 写操作另行取证，见 `docs/download-gaps-wave1.md` 的未取证清单）。
  Future<DownloadFilePage> listFiles(
    String taskId, {
    int offset = 0,
    int limit = pageSize,
  }) async {
    final data = await api.call(
      apiFile,
      'list',
      preferredVersion: negotiate(apiFile, _fileVersions),
      params: {'task_id': taskId, 'offset': offset, 'limit': limit},
    );
    final raw = data['items'] ?? data['files'];
    final items = <DownloadFileDto>[
      if (raw is List)
        for (final e in raw)
          if (e is Map) DownloadFileDto.fromJson(Map<String, dynamic>.from(e)),
    ];
    return DownloadFilePage(
      items: items,
      total: _intOf(data['total'], items.length),
    );
  }

  /// `Task.BT.File / copy`（v2，normal）—— 把任务内选中文件**复制到**别的目录（B10）。
  ///
  /// 参数形态**逐字**取自包内官方前端 `ui/download.js`
  /// （`DLQFileList.applyCopyTo`）：
  /// ```
  /// {api:"SYNO.DownloadStation2.Task.BT.File", method:"copy", version:2,
  ///  params:{task_id:<单个>, index:[<文件下标>…], destination:<路径>}}
  /// ```
  /// ⚠️ 注意与 [listFiles] 的 `task_id`（单个）一致，但 `index` 是**数组**。
  ///
  /// ⚠️ **写操作**：本批按纪律未在真机调用（`docs/download-parity-audit.md` §9 U1）。
  Future<void> copyTaskFile({
    required String taskId,
    required List<int> indexes,
    required String destination,
  }) async {
    final dest = destination.trim();
    if (taskId.isEmpty || indexes.isEmpty || dest.isEmpty) {
      throw DsmApiException(
        DsmErrorCode.noRequiredParam,
        method: '$apiFile.copy',
      );
    }
    await api.call(
      apiFile,
      'copy',
      preferredVersion: negotiate(apiFile, _fileVersions),
      params: {
        'task_id': taskId,
        'index': jsonEncode(indexes),
        'destination': dest,
      },
    );
  }

  /// `Task.BT.File / set`（v2）—— 任务内文件的**优先级**与**跳过/恢复**（A6）。
  ///
  /// 参数形态**逐字**取自包内官方前端 `ui/download.js`
  /// （`DLQFileList`）：优先级菜单 `{itemId:"high"|"normal"|"low"}` →
  /// `setFiles({index, priority})`；跳过 → `skipHandler` =
  /// `{task_id, index, wanted:false}`。两者都是同一个 `set`：
  /// ```
  /// {api:"SYNO.DownloadStation2.Task.BT.File", method:"set", version:2,
  ///  params:{task_id:…, index:[…], priority:<high|normal|low> | wanted:<bool>}}
  /// ```
  /// 官方 `list` 的字段表里同时有 `priority` 与 `wanted`
  /// （`fields:["index","name","size","size_downloaded","progress","priority","wanted"]`）。
  Future<void> setTaskFiles({
    required String taskId,
    required List<int> indexes,
    String? priority,
    bool? wanted,
  }) async {
    if (indexes.isEmpty) return;
    await api.call(
      apiFile,
      'set',
      preferredVersion: negotiate(apiFile, _fileVersions),
      params: {
        'task_id': taskId,
        'index': jsonEncode(indexes),
        if (priority != null) 'priority': priority,
        if (wanted != null) 'wanted': wanted,
      },
    );
  }

  // ------------------------------------------------------------ NZB 日志 / 文件（F5/F6）

  /// `Task.NZB.Log / get`（v1，normal）—— NZB 任务的服务端日志（F5）。
  ///
  /// 官方前端 `ui/download.js` 的 NZB 日志面板：`params:{task_id}`，
  /// 回包读 `data.nzblog`。真机只读实调（2026-09-22）：缺参 → `120`（`task_id`），
  /// `task_id=bogus` → `404`；非 NZB 任务同样回 `404`（= 没有 NZB 日志）。
  Future<DsNzbLog> nzbLog(String taskId) async {
    final data = await api.call(
      apiNzbLog,
      'get',
      preferredVersion: negotiate(apiNzbLog, _v1),
      params: {'task_id': taskId},
    );
    return DsNzbLog.fromJson(data);
  }

  // ------------------------------------------------------------ eMule 搜索（F3）

  /// Kad 关键字校验（官方 `IsKadSearchKeywordValid` 逐字）：
  /// 按 `[ ()\[\]{}<>,._!?:;\\/-]+` 切分，**任一段长度 ≥ 3** 才合法。
  static bool isKadKeywordValid(String keyword) => keyword
      .split(RegExp(r'[ ()\[\]{}<>,._!?:;\/-]+'))
      .any((seg) => seg.length >= 3);

  /// ★ **DA33（r387）**：eMule **搜索/服务器**的业务码（`SYNODL_ERR_EMULE_*`）。
  ///
  /// **权威来源逐条实读**（不是推断）：官方 Download Station 包
  /// `DownloadStation-armada38x-4.1.2-5012.spk` 内 `ui/download.js` 的
  /// `SYNODL_ERR_*:code` 枚举 —— 原文见 `docs/evidence-r387/ds412_error_enum.txt`：
  ///
  /// ```
  /// 2700 SYNODL_ERR_EMULE_SEARCH_PERFORM_FAILED
  /// 2701 SYNODL_ERR_EMULE_SEARCH_STOP_FAILED
  /// 2702 SYNODL_ERR_EMULE_SEARCH_RESULT_GET_FAILED
  /// 2703 SYNODL_ERR_EMULE_SEARCH_BUSY
  /// 2704 SYNODL_ERR_EMULE_ED2K_NOT_CONNECTED
  /// 2705 SYNODL_ERR_EMULE_KAD_NOT_CONNECTED   （2705 之后直接跳 2800）
  /// ```
  ///
  /// ★★ 官方前端 `getErrorString()` **只**给 `2704`/`2705` 配了文案：
  /// `error_server_not_connected{,_normaluser}` /
  /// `error_kad_not_connected{,_normaluser}`（原文见同一证据文件）。
  /// ⇒ 我们**只**映射这两个；`2700–2703`/`2800–2807` 保持"未知码 + 原始码"
  /// （**与官方行为一致**），**不编**文案。
  ///
  /// ★ 先前记录里的 `2706` 在 4.1.2-5012 的枚举里**根本不存在**
  /// （`2705` 之后直接跳 `2800`）⇒ 那条读数与**本版本**对不上，
  /// 不再与 `2704` 并列当"两个读数"。
  static const int errEmuleEd2kNotConnected = 2704;
  static const int errEmuleKadNotConnected = 2705;

  /// `eMule.Search / start`（v1）—— 开一次搜索，回 `id`。
  ///
  /// 官方 `onSearch()` 逐字：
  /// `{keyword, search_type, file_type}` 恒发；
  /// `file_size_min`/`file_size_max`/`source_num_min`/`file_extension`
  /// **只在用户填了才发**（官方用 `isDirty()` 判）。
  /// `search_type` ∈ `local|global|kad`（默认 `local`），
  /// `file_type` ∈ `any|audio|video|image|doc|prog|archive|iso`（默认 `any`）。
  Future<int> emuleSearchStart({
    required String keyword,
    String searchType = 'local',
    String fileType = 'any',
    int? fileSizeMin,
    int? fileSizeMax,
    int? sourceNumMin,
    String? fileExtension,
  }) async {
    final kw = keyword.trim();
    if (kw.isEmpty) {
      throw DsmApiException(
        DsmErrorCode.noRequiredParam,
        method: '$apiEmuleSearch.start',
      );
    }
    // 客户端前置校验（官方 validator 同款）：kad 关键字太短直接挡下，
    // 不发无效请求（服务端也会拒，这里省一次往返）。
    if (searchType == 'kad' && !isKadKeywordValid(kw)) {
      throw DsmApiException(
        DsmErrorCode.noRequiredParam,
        method: '$apiEmuleSearch.start',
      );
    }
    final ext = (fileExtension ?? '').trim();
    final data = await api.call(
      apiEmuleSearch,
      'start',
      preferredVersion: negotiate(apiEmuleSearch, _v1),
      params: {
        'keyword': kw,
        'search_type': searchType,
        'file_type': fileType,
        if (fileSizeMin != null) 'file_size_min': fileSizeMin,
        if (fileSizeMax != null) 'file_size_max': fileSizeMax,
        if (sourceNumMin != null) 'source_num_min': sourceNumMin,
        if (ext.isNotEmpty) 'file_extension': ext,
      },
    );
    return _intOf(data['id'], 0);
  }

  /// `eMule.Search / list`（v1）—— 结果分页。
  ///
  /// 官方 store 逐字：root `results`、total `total`、
  /// `paramNames:{start:"offset",limit:"limit",sort:"sort_by",dir:"order"}`、
  /// `sortInfo:{field:"source",direction:"DESC"}`；回包 `search_done` 表示抓完。
  Future<DsEmuleSearchPage> emuleSearchList({
    required int id,
    int offset = 0,
    int limit = pageSize,
    String? sortBy,
    String? order,
  }) async {
    final data = await api.call(
      apiEmuleSearch,
      'list',
      preferredVersion: negotiate(apiEmuleSearch, _v1),
      params: {
        'id': id,
        'offset': offset,
        'limit': limit,
        if (sortBy != null && sortBy.isNotEmpty) 'sort_by': sortBy,
        if (order != null && order.isNotEmpty) 'order': order,
      },
    );
    return DsEmuleSearchPage.fromJson(data, offset: offset, limit: limit);
  }

  /// `eMule.Search / stop`（v1）—— `id:0` = 停全部（官方 `stopSearch()`）。
  Future<void> emuleSearchStop({int id = 0}) async {
    await api.call(
      apiEmuleSearch,
      'stop',
      preferredVersion: negotiate(apiEmuleSearch, _v1),
      params: {'id': id},
    );
  }

  /// `eMule.Search / download`（v1）—— 把搜索结果**建成下载任务**。
  ///
  /// 官方 `actionDownload()` 逐字：`{file_id: [选中项的 file_id]}`（数组）。
  /// 表单通道里数组的既有形态是 **JSON 文本**（同族约定）。
  /// 官方错误码 `1917` = 还没设 eMule 下载目录（界面据此引导去设置）。
  Future<void> emuleSearchDownload(List<String> fileIds) async {
    if (fileIds.isEmpty) {
      throw DsmApiException(
        DsmErrorCode.noRequiredParam,
        method: '$apiEmuleSearch.download',
      );
    }
    await api.call(
      apiEmuleSearch,
      'download',
      preferredVersion: negotiate(apiEmuleSearch, _v1),
      params: {'file_id': jsonEncode(fileIds)},
    );
  }

  /// `Task.NZB.File / list`（v1，normal）—— NZB 任务内文件清单（F6）。
  ///
  /// 官方 store：root `items`、total `total`、`paramNames:{offset,limit}`、
  /// `fields:["name","size"]`。
  Future<DsNzbFilePage> nzbFiles(
    String taskId, {
    int offset = 0,
    int limit = pageSize,
  }) async {
    final data = await api.call(
      apiNzbFile,
      'list',
      preferredVersion: negotiate(apiNzbFile, _v1),
      params: {'task_id': taskId, 'offset': offset, 'limit': limit},
    );
    return DsNzbFilePage.fromJson(data);
  }

  // ------------------------------------------------------------ Package 能力探测（F14）

  /// `Package.Info / get`（v2，normal）—— 套件版本（F14）。
  Future<DsPackageInfo> packageInfo() async {
    final data = await api.call(
      apiPkgInfo,
      'get',
      preferredVersion: negotiate(apiPkgInfo, _v2),
    );
    return DsPackageInfo.fromJson(data);
  }

  /// `Package.Module / list`（v2，normal）—— 已安装模块（F14），root `listItems`。
  Future<List<DsPackageModule>> packageModules() async {
    final data = await api.call(
      apiPkgModule,
      'list',
      preferredVersion: negotiate(apiPkgModule, _v2),
    );
    final raw = data['listItems'];
    return [
      if (raw is List)
        for (final e in raw)
          if (e is Map) DsPackageModule.fromJson(Map<String, dynamic>.from(e)),
    ];
  }

  /// `Package.Service / get`（v2，normal）—— 服务/能力位（F14）。
  Future<DsPackageService> packageService() async {
    final data = await api.call(
      apiPkgService,
      'get',
      preferredVersion: negotiate(apiPkgService, _v2),
    );
    return DsPackageService.fromJson(data);
  }

  // ------------------------------------------------------------ eMule 服务器（F2，管理员）

  /// `eMule.Server / list`（v1，**管理员**）—— 服务器列表。
  Future<DsEmuleServerPage> emuleServers({
    int offset = 0,
    int limit = pageSize,
    String? sortBy,
    String? order,
  }) async {
    final data = await api.call(
      apiEmuleServer,
      'list',
      preferredVersion: negotiate(apiEmuleServer, _v1),
      params: {
        'offset': offset,
        'limit': limit,
        if (sortBy != null && sortBy.isNotEmpty) 'sort_by': sortBy,
        if (order != null && order.isNotEmpty) 'order': order,
      },
    );
    return DsEmuleServerPage.fromJson(data, offset: offset, limit: limit);
  }

  /// `eMule.Server / get_status`（v1，**管理员**）—— ED2K/Kad 连接状态。
  Future<DsEmuleServerStatus> emuleServerStatus() async {
    final data = await api.call(
      apiEmuleServer,
      'get_status',
      preferredVersion: negotiate(apiEmuleServer, _v1),
    );
    return DsEmuleServerStatus.fromJson(data);
  }

  /// `eMule.Server / connect`（v1，**管理员**）—— `{id}`（官方逐字）。
  Future<void> emuleConnect(String id) async {
    await api.call(
      apiEmuleServer,
      'connect',
      preferredVersion: negotiate(apiEmuleServer, _v1),
      params: {'id': id},
    );
  }

  /// `eMule.Server / connect_kad`（v1，**管理员**）—— 无参（官方逐字）。
  Future<void> emuleConnectKad() async {
    await api.call(
      apiEmuleServer,
      'connect_kad',
      preferredVersion: negotiate(apiEmuleServer, _v1),
    );
  }

  /// `eMule.Server / disconnect`（v1，**管理员**）—— `{type:"all"}`（官方逐字）。
  Future<void> emuleDisconnect({String type = 'all'}) async {
    await api.call(
      apiEmuleServer,
      'disconnect',
      preferredVersion: negotiate(apiEmuleServer, _v1),
      params: {'type': type},
    );
  }

  /// `eMule.Server / delete`（v1，**管理员**）—— `{id:[…]}`（数组 → JSON 文本）。
  Future<void> emuleDeleteServers(List<String> ids) async {
    if (ids.isEmpty) {
      throw DsmApiException(
        DsmErrorCode.noRequiredParam,
        method: '$apiEmuleServer.delete',
      );
    }
    await api.call(
      apiEmuleServer,
      'delete',
      preferredVersion: negotiate(apiEmuleServer, _v1),
      params: {'id': jsonEncode(ids)},
    );
  }

  /// `eMule.Server / add`（v1，**管理员**）—— 官方表单字段是 `ip`/`port`
  /// （`vtype:"ip"` / `vtype:"port"`），`name` 可选。
  Future<void> emuleAddServer({
    required String ip,
    required int port,
    String? name,
  }) async {
    final host = ip.trim();
    if (host.isEmpty) {
      throw DsmApiException(
        DsmErrorCode.noRequiredParam,
        method: '$apiEmuleServer.add',
      );
    }
    final n = (name ?? '').trim();
    await api.call(
      apiEmuleServer,
      'add',
      preferredVersion: negotiate(apiEmuleServer, _v1),
      params: {'ip': host, 'port': port, if (n.isNotEmpty) 'name': n},
    );
  }

  // ------------------------------------------------------------ 缩略图（F8）

  /// `Thumbnail / get`（v2）—— 任务的可用缩略图列表（`id` = **任务 id**）。
  ///
  /// 官方 `InfoPreview.getAvailbleThumbnail`：`{api:"…Thumbnail", method:"get",
  /// version:2, params:{id: taskId}}` 且回包 `data` 是**裸数组**
  /// （`setThumbnail(a)` 先判 `Ext.isArray(a)`）。
  ///
  /// `DsmWebApi.call` 的 `_okData` 对非 Map 的 `data` 一律回 `{}`，所以这里
  /// **不走 `call`**，改用二进制通道 `postBytesForm` 拿原始 JSON 自己解
  /// —— 与 `CalendarApi.remoteCalendars` 处理裸数组回包是同一套做法
  /// （官方 `SYNO.API.Request` 本来就是 POST 表单语义）。
  ///
  /// 任何失败都不在这里吞：调用方把"无缩略图"当正常回落，不阻塞详情页。
  Future<List<DownloadThumbnailDto>> thumbnails(String taskId) async {
    const what = '$apiThumbnail.get';
    final bytes = await api.postBytesForm(api.apiPath(apiThumbnail), {
      'api': apiThumbnail,
      'method': 'get',
      'version': '${negotiate(apiThumbnail, _thumbnailVersions)}',
      'id': taskId,
    });
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map || decoded['success'] != true) {
      final err = decoded is Map ? decoded['error'] : null;
      final code = (err is Map && err['code'] is num)
          ? (err['code'] as num).toInt()
          : DsmErrorCode.unknown;
      throw DsmApiException(code, method: what);
    }
    return DownloadThumbnailDto.listFromJson(decoded['data']);
  }

  /// 缩略图图片 URL（`Thumbnail / download` v2 + `thumbnail_id`，官方
  /// `getThumbnailURL`）。字节走 [DsmWebApi.getBytes]（自签证书 + `_sid`）。
  String thumbnailUrl(String thumbnailId) =>
      api.authenticatedUrl(api.apiPath(apiThumbnail), {
        'api': apiThumbnail,
        'method': 'download',
        'version': '${negotiate(apiThumbnail, _thumbnailVersions)}',
        'thumbnail_id': thumbnailId,
      });

  /// 取缩略图字节（取不到由调用方回落既有图标，**不留空白**）。
  Future<List<int>> thumbnailBytes(String thumbnailId) =>
      api.getBytes(thumbnailUrl(thumbnailId));

  // ------------------------------------------------------------ 种子导出（F7）

  /// `Task.Source / download`（v2，`allowDownload`）的直链。
  ///
  /// 官方 `InfoGeneral`：`getBaseURL({api:"…Task.Source", method:"download",
  /// version:2, params:{id, t:Date.now()}}, true, title+".torrent")`
  /// —— 即**带鉴权的 GET 直链**，`t` 只是防缓存（这里默认不带，保持可测）。
  String sourceUrl(String taskId, {String? cacheBuster}) =>
      api.authenticatedUrl(api.apiPath(apiSource), {
        'api': apiSource,
        'method': 'download',
        'version': '${negotiate(apiSource, _v2)}',
        'id': taskId,
        if (cacheBuster != null && cacheBuster.isNotEmpty) 't': cacheBuster,
      });

  /// `Task.Source / download`（v2）—— 取回原始 `.torrent`/`.nzb` 字节。
  ///
  /// 只读（不是 `create`/`delete` 类写操作）；真机 NAS 上当前 0 任务，
  /// 响应形态未取证（`docs/download-api-live.md:56`）。
  Future<List<int>> downloadSource(String taskId, {String? cacheBuster}) =>
      api.getBytes(sourceUrl(taskId, cacheBuster: cacheBuster));

  // ------------------------------------------------------------ 自动解压设置（F9）

  /// `Settings.AutoExtraction / get`（v1）—— 普通用户**可读**
  /// （`docs/download-api-live.md:31` 真机实测 OK；审计里 `.lib` 标 admin 与
  /// 真机不一致，见 `download-parity-audit.md:119/130`，以真机为准）。
  Future<DownloadAutoExtractionSettings> autoExtraction() async {
    final data = await api.call(
      apiAutoExtraction,
      'get',
      preferredVersion: negotiate(apiAutoExtraction, _v1),
    );
    return DownloadAutoExtractionSettings.fromJson(data);
  }

  /// `Settings.AutoExtraction / set`（v1）—— **写操作**。
  ///
  /// 官方表单只发**脏字段**（`getDirtyFieldValues`）；这里同理：null 的字段
  /// 一律不下发。`enable_unzip` 是设置页开关绑定的那个字段。
  /// `enable_unzip_service` 只在 `is_admin` 时出现（**本轮不下发**）。
  ///
  /// ⚠️ 写操作**离线只验请求体形状**，真机由用户开受控写窗口取证。
  /// ★★ DA65（r410 真机 + 受控探针**实测**）：
  /// `unzip_location` **是布尔，不是字符串** ——
  ///   * `set {unzip_location: "select_folder"}` ⇒ `120 {"name":"unzip_location","reason":"type"}`
  ///     （`"specified_folder"` / 连服务端自己回读的 `"current_folder"` **也一律被拒**，
  ///     三个值都回 `reason:"type"` ⇒ **是类型错，不是枚举错**）；
  ///   * `set {unzip_location: true}`  ⇒ 回读 `"current_folder"`；
  ///   * `set {unzip_location: false}` ⇒ 回读 `"select_folder"`。
  ///
  /// ⇒ 读回来的 `unzip_location` 是**字符串**，写进去的却是**布尔**（语义相反：
  /// `true` = 用下载文件夹）。r407 按字符串发，**这一档写动词从来没成功过**；
  /// 页面又只暴露 1 个字段，所以一直没撞到。
  ///
  /// ★ 另一个实测：`unzip_to_path` 的**裸空串会被服务端当"参数缺失"**
  /// （`set {unzip_to_path: ""}` 返回 `success:true` 却**不回写**，回读仍是旧值）；
  /// 要真的清空必须发 **JSON 空串 `""`**（回读 `""`）。非空值裸发与 JSON 发**等价**。
  Future<void> setAutoExtraction({
    bool? enableUnzip,
    bool? unzipLocationToCurrentFolder,
    String? unzipToPath,
    bool? createSubfolder,
    bool? deleteArchive,
    bool? unzipOverwrite,
  }) async {
    await api.call(
      apiAutoExtraction,
      'set',
      preferredVersion: negotiate(apiAutoExtraction, _v1),
      params: {
        if (enableUnzip != null) 'enable_unzip': enableUnzip,
        if (unzipLocationToCurrentFolder != null)
          'unzip_location': unzipLocationToCurrentFolder,
        if (unzipToPath != null)
          // 空串 = 用户要清空 ⇒ 必须 JSON 编码，否则服务端静默丢弃。
          'unzip_to_path': unzipToPath.isEmpty ? jsonEncode('') : unzipToPath,
        if (createSubfolder != null) 'create_subfolder': createSubfolder,
        if (deleteArchive != null) 'delete_archive': deleteArchive,
        if (unzipOverwrite != null) 'unzip_overwrite': unzipOverwrite,
      },
    );
  }

  // ------------------------------------------------------------ 选文件流程（create_list）

  /// `Task.List / get`（v2）—— 读取 `create_list=true` 建任务后待选的文件清单。
  ///
  /// 官方 `QueueAddFilePanel`：`Task.create {create_list:true}` 返回 `list_id`，
  /// 再用 `Task.List.get {list_id}` 拿 root = **`files`** 的清单。
  /// 这就是消费 [DsCreateResult.listId] 的第一步（P0：原来是死代码）。
  Future<DownloadCreateList> getCreateList(String listId) async {
    final Map<String, dynamic> data;
    try {
      data = await api.call(
        apiTaskList,
        'get',
        preferredVersion: negotiate(apiTaskList, _v2),
        params: {'list_id': listId},
      );
    } on DsmApiException catch (e) {
      // ★ r387/DA36 仪器：DSM 对"参数无效"的回包带着 **`name`**（哪个参数），
      //   而界面上只该显示"请求参数无效"（§2.0.47：诊断串不当用户文案）
      //   ⇒ 根因只能从 logcat 读。这一行就是"读到什么"的通道。
      //   信封只有 `code`/`name`/`reason`，不含隐私字段。
      debugPrint(
        '[ds] Task.List.get failed list_id=${listId.length} chars '
        'code=${e.code} raw=${e.raw}',
      );
      rethrow;
    }
    final raw = data['files'];
    final files = <DownloadCreateListFile>[
      if (raw is List)
        for (final e in raw)
          if (e is Map)
            DownloadCreateListFile.fromJson(Map<String, dynamic>.from(e)),
    ];
    return DownloadCreateList(
      files: files,
      total: _intOf(data['total'], files.length),
    );
  }

  /// `Task.List.Polling / download`（v2）—— 用选中的文件下标**真正开始下载**。
  ///
  /// 官方 `sendWebAPIForSpecificList`：
  /// `{list_id, destination, create_subfolder, selected:[index…], extract_password}`，
  /// 回包给 `task_id`。`selected` 缺省 = 全部文件。
  Future<String> downloadCreateList({
    required String listId,
    String? destination,
    List<int>? selected,
    bool createSubfolder = true,
    String? extractPassword,
  }) async {
    final data = await api.call(
      apiTaskListPolling,
      'download',
      preferredVersion: negotiate(apiTaskListPolling, _v2),
      params: {
        'list_id': listId,
        if (destination != null && destination.isNotEmpty)
          'destination': jsonEncode(destination),
        'create_subfolder': createSubfolder,
        if (selected != null) 'selected': jsonEncode(selected),
        if (extractPassword != null && extractPassword.isNotEmpty)
          'extract_password': extractPassword,
      },
    );
    return '${data['task_id'] ?? ''}';
  }

  /// `Task.List / delete`（v2）—— 用户放弃选择时清掉服务端临时清单。
  ///
  /// 官方 `QueueAddFilePanel.onCloseHandler`：关闭选文件窗口时对每个
  /// `list_id` 发一次 `Task.List.delete`。
  Future<void> deleteCreateList(String listId) async {
    await api.call(
      apiTaskList,
      'delete',
      preferredVersion: negotiate(apiTaskList, _v2),
      params: {'list_id': listId},
    );
  }

  /// `Task.List / download`（v1–v2）—— **非轮询版**的"开始下载清单里的文件"。
  ///
  /// ⚠️ **语义纠正（不许含糊）**：它**不是**"取清单文件"，也**不走二进制通道**
  /// —— 真机只读探针逐字：
  /// ```
  /// Task.List:download v2 {}                    → 120 {"name":"list_id"}
  /// Task.List:download v2 {list_id:"bogus-xyz"} → 120 {"name":"destination"}
  /// ```
  /// `destination` 是**必填** ⇒ 它是把清单里的文件按目标目录**开成任务**的动作；
  /// 包内 `.so` 的符号也叫 **`SYNODLTaskListDownload`**。官方 Web UI 用的是它的
  /// 轮询兄弟 `Task.List.Polling.download`（同名参数、回 `task_id` 再轮询进度），
  /// 而 `Task.List.Polling` 的 `.lib` **`minVersion=2`**，[apiTaskList] 是 v1–v2。
  ///
  /// ⇒ 本方法**只作为"没有 `Polling` 能力位"时的降级路径**存在（见
  /// `DownloadFileSelectPage`），不是死代码，也不假装是文件下载。
  /// `selected` / `create_subfolder` / `extract_password` 与
  /// [downloadCreateList] 同族（官方 `generateAPIParamsSelected` /
  /// `QueueAddFilePanel.onSubmitDone` 逐字）。
  ///
  /// **真机未取证**：本方法会真的开下载任务，本批次**不调用**（规程 §5.1）。
  /// 回包形状**未取证** → 这里只返回空串，调用方不依赖返回值。
  Future<String> taskListDownload({
    required String listId,
    required String destination,
    List<int>? selected,
    bool createSubfolder = true,
    String? extractPassword,
  }) async {
    final data = await api.call(
      apiTaskList,
      'download',
      preferredVersion: negotiate(apiTaskList, _v2),
      params: {
        'list_id': listId,
        'destination': jsonEncode(destination),
        'create_subfolder': createSubfolder,
        if (selected != null) 'selected': jsonEncode(selected),
        if (extractPassword != null && extractPassword.isNotEmpty)
          'extract_password': extractPassword,
      },
    );
    return '${data['task_id'] ?? ''}';
  }

  // ------------------------------------------------------------ BT 搜索
  //
  // 事实来源（**三层都对上了才写**）：
  //   * 包内 `webapi/SYNO.DownloadStation2.BTSearch.lib`（5 个方法 / v1 / normal）；
  //   * 包内官方前端 `ui/download.js` 的 `DLM.SearchGridPanel`（真实调用流程）；
  //   * 真机实测回包形状与错误码（`docs/download-api-live.md` §10）。
  //
  // ⚠️ **分页参数的口径冲突（如实记在波次报告里）**：
  //   * 本实现按**任务书钉死的真机契约**用 **`start`**（§10.1/§10.4 明文，
  //     真机 `list {id,start:0,limit:5}` 实测可用）；
  //   * 但官方 `beforeSearchPolling`（`ui/download.js`）与包内
  //     `SYNO.DownloadStation2.BTSearch.so` 的参数串表里都是 **`offset`**。
  //   真机因 `results:[]` **无法区分二者**（`start` 被忽略时 offset 默认 0，
  //   同样 200）。这里把参数名收敛到 [btSearchPageParam] 一个常量，日后可一处切换。

  /// 搜索分页参数名（见上方口径冲突说明；任务书钉 = `start`）。
  static const String btSearchPageParam = 'start';

  /// `BTSearch / start` v1 —— 开一次检索会话，回 **`{id}`** 作为
  /// `searchTaskID`（官方逐字：`this.searchTaskID = c.id`）。
  ///
  /// 参数：`keyword` 必填；`id` = 数据源（老一代 `getModule` 的 `module_id`）。
  ///
  /// ⚠️ 官方 DLM 实际发的是 `{action:"search", keyword}`、**没带 `id`**；
  /// 任务书钉的契约是 `{id, keyword}`（真机用 `id` 也受理）。这里按任务书带
  /// `id`，并把 `action` 列为未取证项（见波次报告），**不擅自加**。
  ///
  /// 失败语义：**1408** = 本机 BT 搜索不可用/会话无数据源（中性，非"加载失败"）。
  Future<String> btSearchStart({
    required String keyword,
    String? sourceId,
  }) async {
    final kw = keyword.trim();
    if (kw.isEmpty) {
      throw DsmApiException(
        DsmErrorCode.noRequiredParam,
        method: '$apiBtSearch.start',
      );
    }
    final data = await api.call(
      apiBtSearch,
      'start',
      preferredVersion: negotiate(apiBtSearch, _v1),
      params: {
        if (sourceId != null && sourceId.isNotEmpty) 'id': sourceId,
        'keyword': kw,
      },
    );
    return '${data['id'] ?? ''}';
  }

  /// `BTSearch / list` v1 —— 结果分页。
  ///
  /// 参数：`id`（会话）+ [start]/[limit] + `sort_by`/`order` + 可选
  /// `categories`（官方 `beforeSearchPolling` 用**数组**下发）+
  /// 可选 `keyword`（官方做结果内二次过滤）。
  /// 回包：`{is_running, results:[], total}` → [DsBtSearchPage]。
  Future<DsBtSearchPage> btSearchList({
    required String searchTaskId,
    int start = 0,
    int? limit,
    String? sortBy,
    String? order,
    String? category,
    String? keyword,
  }) async {
    final data = await api.call(
      apiBtSearch,
      'list',
      preferredVersion: negotiate(apiBtSearch, _v1),
      params: _btSearchListParams(
        searchTaskId: searchTaskId,
        start: start,
        limit: limit,
        sortBy: sortBy,
        order: order,
        category: category,
        keyword: keyword,
      ),
    );
    return DsBtSearchPage.fromJson(data);
  }

  /// `list` 的参数表。[compound] = true 时走 `SYNO.Entry.Request` 复合请求，
  /// 参数是**会进 JSON 数组**的真实类型；非复合走表单，数组要 JSON 文本
  /// （官方 `Ext.apply` 的数组在复合请求里就是 JSON 数组）。
  Map<String, Object?> _btSearchListParams({
    required String searchTaskId,
    required int start,
    int? limit,
    String? sortBy,
    String? order,
    String? category,
    String? keyword,
    bool compound = false,
  }) => {
    'id': searchTaskId,
    // 分页参数名见 [btSearchPageParam] 的口径冲突说明。
    btSearchPageParam: start,
    'limit': limit ?? btSearchPageSize,
    if (sortBy != null && sortBy.isNotEmpty) 'sort_by': sortBy,
    if (order != null && order.isNotEmpty) 'order': order,
    if (category != null && category.isNotEmpty)
      'categories': compound ? [category] : jsonEncode([category]),
    if (keyword != null && keyword.isNotEmpty) 'keyword': keyword,
  };

  /// `list_category` v1 —— 结果分类（真机回 `{categories:[]}`，官方是字符串数组）。
  Future<List<String>> btSearchCategories(String searchTaskId) async {
    final data = await api.call(
      apiBtSearch,
      'list_category',
      preferredVersion: negotiate(apiBtSearch, _v1),
      params: {'id': searchTaskId},
    );
    final raw = data['categories'];
    if (raw is! List) return const [];
    return [
      for (final c in raw)
        if ('$c'.isNotEmpty) '$c',
    ];
  }

  /// `list_plugin_status` v1 —— 搜索插件连通性（回 `{plugins:[], can_connect}`）。
  ///
  /// 官方只在**离开/停止时**调它，`plugins[].can_connect` 不全 true 就提示
  /// "结果可能不完整"（`ui/download.js` 的 `checkPluginStatus`）。
  Future<DsBtSearchPluginStatus> btSearchPluginStatus(
    String searchTaskId,
  ) async {
    final data = await api.call(
      apiBtSearch,
      'list_plugin_status',
      preferredVersion: negotiate(apiBtSearch, _v1),
      params: {'id': searchTaskId},
    );
    return DsBtSearchPluginStatus.fromJson(data);
  }

  /// `BTSearch / stop` v1 —— 停检索会话（**离开/取消/轮询结束必须调**，否则泄漏）。
  ///
  /// 失败**不抛**：收尾动作，窗口正在关闭，把错误吞掉（官方 `stopSearch` 里
  /// 失败也只 `SYNO.Debug` 一句）。返回是否受理。
  Future<bool> btSearchStop(String searchTaskId) async {
    if (searchTaskId.isEmpty) return false;
    try {
      await api.call(
        apiBtSearch,
        'stop',
        preferredVersion: negotiate(apiBtSearch, _v1),
        params: {'id': searchTaskId},
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 一次复合轮询：`SYNO.Entry.Request` 里并发 `list` + `list_category`
  /// （官方 `startSearch` 逐字用复合，`stopwhenerror:false`）。
  ///
  /// 返回 `(page, categories)`；**单段失败**（含 1408）通过 [CompoundResult]
  /// 的 `success/errorCode` 返回，由调用方决定降级 —— 复合整体成功不代表
  /// 每段成功（`compound.dart` 的既有结论）。
  Future<({DsBtSearchPage page, List<String> categories, int? errorCode})>
  btSearchPoll({
    required String searchTaskId,
    int start = 0,
    int? limit,
    String? sortBy,
    String? order,
    String? category,
    String? keyword,
  }) async {
    final params = _btSearchListParams(
      searchTaskId: searchTaskId,
      start: start,
      limit: limit,
      sortBy: sortBy,
      order: order,
      category: category,
      keyword: keyword,
      compound: true,
    );
    final results = await api.compound([
      ApiRequest(
        apiBtSearch,
        'list',
        version: negotiate(apiBtSearch, _v1),
        params: params,
      ),
      ApiRequest(
        apiBtSearch,
        'list_category',
        version: negotiate(apiBtSearch, _v1),
        params: {'id': searchTaskId},
      ),
    ]);

    DsBtSearchPage page = const DsBtSearchPage();
    var categories = const <String>[];
    int? errorCode;
    for (final r in results) {
      if (!r.success) {
        errorCode ??= r.errorCode;
        continue;
      }
      if (r.method == 'list') {
        page = DsBtSearchPage.fromJson(r.data ?? const {});
      } else if (r.method == 'list_category') {
        final raw = r.data?['categories'];
        if (raw is List) {
          categories = [
            for (final c in raw)
              if ('$c'.isNotEmpty) '$c',
          ];
        }
      }
    }
    return (page: page, categories: categories, errorCode: errorCode);
  }

  /// 老一代 `SYNO.DownloadStation.BTSearch / getModule` v1 —— **数据源列表**。
  ///
  /// **path 逐字 `DownloadStation/btsearch.cgi`**（由 `SYNO.API.Info` 的能力表
  /// 提供，`api.call` 会自动用它 —— 我们**不**把它拼成 entry.cgi）。
  /// 真机普通用户可用，回 13 个 enabled 模块；条目字段宽容解析
  /// （`module_id|id`、`module_title|title|displayname`、`enabled`）。
  Future<List<DsBtSearchModule>> btSearchModules() async {
    final data = await api.call(
      apiBtSearchLegacy,
      'getModule',
      preferredVersion: negotiate(apiBtSearchLegacy, _v1),
    );
    final raw = data['modules'];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) DsBtSearchModule.fromJson(Map<String, dynamic>.from(e)),
    ];
  }

  // ------------------------------------------------- 老一代 BT 搜索（wave4）
  //
  // 事实来源（**真机取证 + 包内权威方法表**，`docs/download-api-live.md` §12）：
  //   * 方法表（`export_DownloadStation/webapi/DownloadStation.api` 逐字）：
  //     `SYNO.DownloadStation.BTSearch` → `path: "DownloadStation/btsearch.cgi"`，
  //     v1 = `["start","list","getCategory","clean","getModule"]`；
  //   * 真机（普通用户，2026-09-22）：
  //     `start {keyword}` → `{"data":{"taskid":"179004081364F3458F"}}`；
  //     `list {taskid,offset,limit}` → `{"data":{"finished":false,"items":[…],
  //     "offset":0,"total":130}}`；
  //   * `getCategory`（403）/ `clean`（401）**未取证 → 不做**。
  //
  // ⚠️ path **必须**由 `SYNO.API.Info` 的能力表给（`api.call` 自动用
  // `DownloadStation/btsearch.cgi`）—— **绝不**写死 `entry.cgi`。

  /// 老一代 `BTSearch / start` v1 —— 开检索会话，回 **`{taskid}`**。
  ///
  /// 参数：**`keyword`**（必填；真机**无参 → 400**）。会话 id 取 `taskid`
  /// （真机逐字），兼容 `id`。
  ///
  /// ⚠️ 服务端 cgi 字符串表里还有 `module` 参数，但**真机未取证其线参形态**
  /// → 本实现**不发**（`docs/download-api-live.md` §12 只钉了 `{keyword}`）。
  /// 模块选择在**客户端**按 `module_id` 过滤（见 provider）。
  Future<String> btSearchLegacyStart({required String keyword}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) {
      throw DsmApiException(
        DsmErrorCode.noRequiredParam,
        method: '$apiBtSearchLegacy.start',
      );
    }
    final data = await api.call(
      apiBtSearchLegacy,
      'start',
      preferredVersion: negotiate(apiBtSearchLegacy, _v1),
      params: {'keyword': kw},
    );
    return '${data['taskid'] ?? data['id'] ?? ''}';
  }

  /// 老一代 `BTSearch / list` v1 —— 结果分页 / `finished` 轮询。
  ///
  /// 参数（真机钉死）：**`taskid`** + `offset` + `limit`
  /// （真机 `taskid` / `id` 都能出结果，本实现用 `taskid`）。
  /// 回包顶层 `{finished, items, offset, total}` → [DsBtSearchLegacyPage]。
  Future<DsBtSearchLegacyPage> btSearchLegacyList({
    required String taskid,
    int offset = 0,
    int? limit,
  }) async {
    final data = await api.call(
      apiBtSearchLegacy,
      'list',
      preferredVersion: negotiate(apiBtSearchLegacy, _v1),
      params: {
        'taskid': taskid,
        'offset': offset,
        'limit': limit ?? btSearchPageSize,
      },
    );
    return DsBtSearchLegacyPage.fromJson(data);
  }

  // ------------------------------------------------- 下载任务验证码（wave5）
  //
  // 事实来源（**三层都对上了才写**）：
  //   * 包内 `webapi/SYNO.DownloadStation2.Captcha.lib` 逐字：只有 3 个方法
  //     `list` / `set` / `download`，**v1–v2**，`allowUser=["admin.local",
  //     "normal.local"]`（普通用户可用），`authLevel=1`；
  //   * 包内 `SYNO.DownloadStation2.Captcha.so` 字符串：`task_ids` / `task_id` /
  //     `code` / `captcha.json` / `PrintDownloadFileNotFound`；
  //   * 包内官方前端 `ui/download.js` 的 `DLM.CaptchaEnterDialog`（逐字）：
  //       `webapiList   = {Captcha, list, v2}`     → `data.task_ids`
  //       `webapiSet    = {Captcha, set, v2}`      → `params:{task_id, code}`
  //       `webapiDownload={Captcha, download, v2}` → `params:{task_id, t}`（直链）
  //       `webapiGet    = {Task, get, v2}`         → `params:{id:[task_id],
  //                                                   additional:["detail"]}`
  //     错误表：`2301` = `download_error_wrong_captcha`（"验证码不正确"）；
  //   * 真机（普通用户，2026-09-22，只读）：
  //       `Captcha:list v2 {}`     → ✅ `{"data":{"task_ids":[]}}`
  //       `Captcha:list v1 {}`     → ✅ `{"data":[]}`（**裸数组**）
  //       `Captcha:download v2 {}` → `120 {"name":"task_id","reason":"required"}`
  //       `Captcha:set v2 {}`      → `120 {"name":"code","reason":"required"}`
  //     且 `SYNO.API.Info`：`path=entry.cgi`、`requestFormat:"JSON"`、v1–2。
  //
  // ⚠️ **语义纠正（不许含糊）**：验证码**不是 BT 搜索的**。官方 JS 把它绑在
  //   **下载任务**上（任务状态 `15 = TASK_CAPTCHA_NEEDED`，工具栏 `captcha`
  //   按钮显示待输入数量；对话框逐个任务 `Captcha:list` → 取图 → `set`）。
  //   BT 搜索（老代 `start/list`、DS2 `start/list`）回包里**没有任何验证码字段**
  //   ⇒ 把本 API 接进 BT 搜索就是死代码（规程 §4.6）。
  //   `Captcha:download` 也**不是**"下载清单文件"，而是**取验证码图片**。

  /// 验证码 API：`list` / `set` / `download`（v1–v2）。
  static const String apiCaptcha = 'SYNO.DownloadStation2.Captcha';

  /// `Captcha:set` 的错误码：`2301 = download_error_wrong_captcha`
  /// （官方 JS 的 `getErrorMessage` 逐字只认这一个业务码）。
  static const int errWrongCaptcha = 2301;

  /// `Captcha / list`（v2 优先，兼容 v1）—— **需要输入验证码的下载任务** id。
  ///
  /// 走二进制通道自己解包：真机 **v1 的 `data` 是裸数组** `[]`，
  /// 而 [`DsmWebApi.call`] 对非 Map 的 `data` 一律回 `{}` ⇒ 若用 `call`，
  /// 在"只提供 v1 的 NAS"上会**把"有验证码任务"读成空**（静默失败）。
  /// 这里兼容两种形状：Map 取 `task_ids`、List 直接当 id 列表。
  ///
  /// 返回的 id 是**内部值**（绝不进 UI 文本）。
  Future<List<String>> captchaTaskIds() async {
    const what = '$apiCaptcha.list';
    final bytes = await api.postBytesForm(api.apiPath(apiCaptcha), {
      'api': apiCaptcha,
      'method': 'list',
      'version': '${negotiate(apiCaptcha, _captchaVersions)}',
    });
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map || decoded['success'] != true) {
      throw DsmApiException(_errorCodeOf(decoded), method: what);
    }
    final data = decoded['data'];
    final raw = data is Map ? (data['task_ids'] ?? data['items']) : data;
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if ('$e'.isNotEmpty) '$e',
    ];
  }

  /// `Captcha / set`（v2）—— 提交某个任务的验证码。
  ///
  /// 线参**逐字**是 `{task_id, code}`（官方 `setCaptchaResult` 的
  /// `params:{task_id:a, code:b}`）；真机 `Captcha:set {}` 先报
  /// `120 {"name":"code"}`。成功后官方**立刻**读下一个验证码任务
  /// （`setCaptchaResultCallback` → `onSubmit()`）——调用方照此刷新即可。
  ///
  /// 失败码 `2301` = 验证码不正确（[errWrongCaptcha]），**必须**上屏提示，
  /// 不许吞掉。
  Future<void> setCaptcha({
    required String taskId,
    required String code,
  }) async {
    final c = code.trim();
    if (taskId.isEmpty || c.isEmpty) {
      throw DsmApiException(
        DsmErrorCode.noRequiredParam,
        method: '$apiCaptcha.set',
      );
    }
    await api.call(
      apiCaptcha,
      'set',
      preferredVersion: negotiate(apiCaptcha, _captchaVersions),
      params: {'task_id': taskId, 'code': c},
    );
  }

  /// `Captcha / download`（v2）的**带鉴权直链**（验证码图片）。
  ///
  /// 官方 `getCaptchaImageURL`：`getBaseURL(Ext.apply(webapiDownload,
  /// {params:{task_id:a, t:Date.now()}}))` ⇒ GET 直链，`t` 只是防缓存。
  /// 服务端在本机上是 `task_id` 必填（真机 `120 {"name":"task_id"}`）。
  String captchaImageUrl(String taskId, {String? cacheBuster}) =>
      api.authenticatedUrl(api.apiPath(apiCaptcha), {
        'api': apiCaptcha,
        'method': 'download',
        'version': '${negotiate(apiCaptcha, _captchaVersions)}',
        'task_id': taskId,
        if (cacheBuster != null && cacheBuster.isNotEmpty) 't': cacheBuster,
      });

  /// `Captcha / download`（v2）—— 取验证码图片字节。
  ///
  /// ⚠️ 真机实测：`task_id` 不存在时**不是** JSON 错误码，而是
  /// **HTTP 404 + DSM HTML 错误页**（`.so` 里的 `PrintDownloadFileNotFound`）
  /// ——由调用方按"验证码图片取不到"回落，不要当网络故障。
  Future<List<int>> captchaImageBytes(String taskId, {String? cacheBuster}) =>
      api.getBytes(captchaImageUrl(taskId, cacheBuster: cacheBuster));

  // ------------------------------------------------------------ RSS 订阅（wave3）
  //
  // 调用点**逐字**来自包内官方前端 `ui/download.js` 的 `DLM.RSS*`
  // （`/tmp/spk/export_DownloadStation/ui/download.js`，单行压缩文件第 3 行）。
  // 每个方法的线参形态都在方法注释里给出官方原文，**不猜**。

  /// `RSS.Feed / list` v1 —— 订阅源分页。
  ///
  /// 官方 `DLM.RSSGridPanel.createStore`（逐字）：
  /// `{api:"SYNO.DownloadStation2.RSS.Feed", method:"list", version:1,
  ///   baseParams:{limit:this.itemsPerPage},
  ///   root:"items", fields:["id","title","url","last_update","is_updating",
  ///   "username"], paramNames:{start:"offset", limit:"limit"}}`
  /// ⇒ 线上分页参数是 **`offset` / `limit`**（不是 `start`）。
  /// 真机无参回 `{"data":{"is_updating":false,"items":[],"total":0}}`（§11）。
  Future<DsRssFeedPage> rssFeedList({int offset = 0, int? limit}) async {
    final data = await api.call(
      apiRssFeed,
      'list',
      preferredVersion: negotiate(apiRssFeed, _v1),
      params: {'offset': offset, 'limit': limit ?? rssPageSize},
    );
    return DsRssFeedPage.fromJson(data);
  }

  /// `RSS.Feed / add` v1 —— 添加订阅。
  ///
  /// 官方 `DLM.RSSAddDialog.addRss`（逐字）：
  /// ```
  /// var c = {};
  /// … if (b.findField("dl_all").getValue()) {
  ///     c.enable_auto_download = true;
  ///     c.destination = b.findField("desttext").getValue();
  ///   }
  /// c.url = b.findField("url").getValue();
  /// sendWebAPI({api:"SYNO.DownloadStation2.RSS.Feed", method:"add",
  ///             params:c, version:1})
  /// ```
  /// ⇒ 线参 = **`url`**（必填，已 trim），可选 `enable_auto_download=true` +
  /// `destination`（目标文件夹**路径字符串**）。官方**没有** `name` / `path`
  /// 参数 —— 别加。真机 `Feed:add` **120 缺 `url`**（参数名钉死，§11）。
  Future<void> rssFeedAdd({
    required String url,
    bool enableAutoDownload = false,
    String? destination,
  }) async {
    final u = url.trim();
    if (u.isEmpty) {
      throw DsmApiException(
        DsmErrorCode.noRequiredParam,
        method: '$apiRssFeed.add',
      );
    }
    await api.call(
      apiRssFeed,
      'add',
      preferredVersion: negotiate(apiRssFeed, _v1),
      params: {
        'url': u,
        if (enableAutoDownload) 'enable_auto_download': true,
        if (enableAutoDownload && destination != null && destination.isNotEmpty)
          'destination': destination,
      },
    );
  }

  /// `RSS.Feed / set` v1 —— 改订阅名 / 地址。
  ///
  /// 官方 `DLM.RSSEditDialog.applyHandler`（逐字）：
  /// `var b={id:this.record.get("id")}; Ext.apply(b, a.getValues());`
  /// 表单字段是 `title` + `url`（`RSSEditDialog.createForm` 逐字）
  /// ⇒ 线参 = `{id, title, url}`。真机 `Feed:set` **120 缺 `id`**。
  Future<void> rssFeedSet({
    required String id,
    String? title,
    String? url,
  }) async {
    await api.call(
      apiRssFeed,
      'set',
      preferredVersion: negotiate(apiRssFeed, _v1),
      params: {
        'id': id,
        if (title != null) 'title': title,
        if (url != null) 'url': url,
      },
    );
  }

  /// `RSS.Feed / delete` v1 —— 删订阅（官方支持多选）。
  ///
  /// 官方 `DLM.RSS.actionRemove`（逐字）：
  /// `var b={}; b.id = this.getSelectedTaskIDArray(); sendRequest("delete", b)`
  /// ⇒ `id` 是**数组**。表单通道里数组的既有线上形态是 **JSON 文本**
  /// （本仓库同族约定的 `Task.delete`，见上文 `'id': jsonEncode(ids)`）。
  Future<void> rssFeedDelete(List<String> ids) async {
    if (ids.isEmpty) return;
    await api.call(
      apiRssFeed,
      'delete',
      preferredVersion: negotiate(apiRssFeed, _v1),
      params: {'id': jsonEncode(ids)},
    );
  }

  /// `RSS.Feed / update` v1 —— 更新选中的订阅（官方 `actionUpdate`：
  /// `b.id = getSelectedTaskIDArray()`，同样是数组）。
  Future<void> rssFeedUpdate(List<String> ids) async {
    if (ids.isEmpty) return;
    await api.call(
      apiRssFeed,
      'update',
      preferredVersion: negotiate(apiRssFeed, _v1),
      params: {'id': jsonEncode(ids)},
    );
  }

  /// `RSS.Feed / updateall` v1 —— 全部更新。官方 `actionUpdateAll` 逐字：
  /// `this.sendRequest("updateall")` ⇒ **无参**。真机回 `{"success":true}`（§11）。
  Future<void> rssFeedUpdateAll() async {
    await api.call(
      apiRssFeed,
      'updateall',
      preferredVersion: negotiate(apiRssFeed, _v1),
    );
  }

  /// `RSS.Item / list` v1 —— 某个订阅源的条目分页。
  ///
  /// 官方 `DLM.RSSItemList.createStore` + `onBeforeStoreLoad`（逐字）：
  /// `{api:"SYNO.DownloadStation2.RSS.Item", method:"list", version:1,
  ///   baseParams:{limit:itemsPerPage}, root:"items", totalProperty:"total",
  ///   fields:["id","feed_id","title","url","link","date","size","is_new"],
  ///   paramNames:{start:"offset", limit:"limit"}}`
  /// 且 `b.params.feed_id = c[0].id`（选中的 feed）。
  /// ⇒ 线上参数 = **`feed_id` + `offset` + `limit`**。
  /// 真机 `Item:list` **120 缺 `feed_id`**（§11）。
  Future<DsRssItemPage> rssItemList({
    required String feedId,
    int offset = 0,
    int? limit,
  }) async {
    final data = await api.call(
      apiRssItem,
      'list',
      preferredVersion: negotiate(apiRssItem, _v1),
      params: {
        'feed_id': feedId,
        'offset': offset,
        'limit': limit ?? rssPageSize,
      },
    );
    return DsRssItemPage.fromJson(data);
  }

  /// `RSS.Item / clear` v1 —— 清空某个订阅源的条目。
  ///
  /// 官方 `DLM.RSSItemList.actionClear`（逐字）：`params:{feed_id:a[0].id}`，
  /// 成功后 `this.store.load()`。真机 **120 缺 `feed_id`**（§11）。
  Future<void> rssItemClear(String feedId) async {
    await api.call(
      apiRssItem,
      'clear',
      preferredVersion: negotiate(apiRssItem, _v1),
      params: {'feed_id': feedId},
    );
  }

  /// `RSS.Filter / list` v1 —— 某个订阅源的自动下载过滤器。
  ///
  /// 官方 `DLM.RSSFilterList.createStore` + `onBeforeStoreLoad`（逐字）：
  /// `baseParams:{limit:itemsPerPage, sort_by:"name"}`、`root:"items"`、
  /// `totalProperty:"total"`、`fields:["id","feed_id","name","match",
  /// "not_match","destination","enable","is_regex"]`、`paramNames:{start:"offset",
  /// limit:"limit"}`，且 `b.params.feed_id = c[0].id`。
  /// 真机 `Filter:list` **120 缺 `feed_id`**（§11）。
  Future<DsRssFilterPage> rssFilterList({
    required String feedId,
    int offset = 0,
    int? limit,
    String? sortBy,
  }) async {
    final data = await api.call(
      apiRssFilter,
      'list',
      preferredVersion: negotiate(apiRssFilter, _v1),
      params: {
        'feed_id': feedId,
        'offset': offset,
        'limit': limit ?? rssPageSize,
        'sort_by': sortBy ?? 'name',
      },
    );
    return DsRssFilterPage.fromJson(data);
  }

  /// `RSS.Filter / add` v1 —— 新建过滤器（**线参形态已从官方 JS 取到**）。
  ///
  /// 官方 `DLM.RSSAddFilterDialog.applyHandler`（逐字）：
  /// ```
  /// var b = {};
  /// b.feed_id = this.feedId;
  /// if (this.record) { a = "set"; b.id = this.record.get("id"); }
  /// else { a = "add"; b.feed_id = this.feedId; }
  /// Ext.apply(b, this.formPanel.form.getValues());
  /// b.is_regex = this.formPanel.form.findField("is_regex").getValue();
  /// sendWebAPI({api:"SYNO.DownloadStation2.RSS.Filter", method:a,
  ///             params:b, version:1})
  /// ```
  /// 表单字段（`RSSAddFilterDialog.createForm` 逐字）：
  /// `name` / `match` / `not_match` / `destination` / `is_regex`。
  ///
  /// ★ **`destination` 是普通字符串**：表单里是 `syno_textfield`（readOnly），
  /// 值由文件夹选择器 `chooseDestHandler` 写回
  /// `destinationField.setValue(e.path.substr(1))` —— **既不是数组，也不是
  /// JSON 串**。文档里"裸数字仍报缺 ⇒ 线参大概率是 JSON 串"的推断被官方 JS
  /// **否证**（服务端只是对 `destination` 做字符串校验；类型不对同样报 120）。
  Future<void> rssFilterAdd({
    required String feedId,
    required String name,
    required String destination,
    String? match,
    String? notMatch,
    bool isRegex = false,
  }) async {
    await api.call(
      apiRssFilter,
      'add',
      preferredVersion: negotiate(apiRssFilter, _v1),
      params: {
        'feed_id': feedId,
        'name': name,
        'match': match ?? '',
        'not_match': notMatch ?? '',
        'destination': destination,
        'is_regex': isRegex,
      },
    );
  }

  /// `RSS.Filter / set` v1 —— 改过滤器（同 [rssFilterAdd]，另带 `id`）。
  /// 官方同一段 `applyHandler`：`record` 非空时 `a="set"` 且
  /// `b.id = record.get("id")`。
  Future<void> rssFilterSet({
    required String id,
    required String feedId,
    required String name,
    required String destination,
    String? match,
    String? notMatch,
    bool isRegex = false,
  }) async {
    await api.call(
      apiRssFilter,
      'set',
      preferredVersion: negotiate(apiRssFilter, _v1),
      params: {
        'id': id,
        'feed_id': feedId,
        'name': name,
        'match': match ?? '',
        'not_match': notMatch ?? '',
        'destination': destination,
        'is_regex': isRegex,
      },
    );
  }

  /// `RSS.Filter / delete` v1 —— 官方 `actionDelete` 逐字：
  /// `var a=[]; Ext.each(selections, function(e){a.push(e.get("id"))});
  ///  params:{id:a}` ⇒ `id` 是**数组**（多选），表单通道用 JSON 文本。
  Future<void> rssFilterDelete(List<String> ids) async {
    if (ids.isEmpty) return;
    await api.call(
      apiRssFilter,
      'delete',
      preferredVersion: negotiate(apiRssFilter, _v1),
      params: {'id': jsonEncode(ids)},
    );
  }

  /// `RSS.Filter / test` v1 —— 试跑过滤器（**线参形态已从官方 JS 取到**）。
  ///
  /// 官方 `DLM.RSSAddFilterTestingTool.onTest`（逐字）：
  /// ```
  /// var a = {};
  /// Ext.apply(a, this.formPanel.form.getValues());
  /// a.is_regex = this.formPanel.form.findField("is_regex").getValue();
  /// sendWebAPI({api:"SYNO.DownloadStation2.RSS.Filter", method:"test",
  ///             params:a, version:1})
  /// ```
  /// 表单字段（`createForm` 逐字）：`test_string` / `match` / `not_match` /
  /// `is_regex` ⇒ **`test_string` 是普通字符串**（`syno_textfield`）。
  ///
  /// 回包判据（官方 `onTestDone` 逐字）：`if (b.matched) …matched… else
  /// …not match…` ⇒ 顶层布尔 **`matched`**。本方法返回它。
  Future<bool> rssFilterTest({
    required String testString,
    String? match,
    String? notMatch,
    bool isRegex = false,
  }) async {
    final data = await api.call(
      apiRssFilter,
      'test',
      preferredVersion: negotiate(apiRssFilter, _v1),
      params: {
        'test_string': testString,
        'match': match ?? '',
        'not_match': notMatch ?? '',
        'is_regex': isRegex,
      },
    );
    return data['matched'] == true;
  }
}

// ---------------------------------------------------------------- 错误文案

/// 失败的**大类**：界面据此给出不同的空态/图标/标题。
///
/// 任务书硬要求："区分套件未安装 / 无权限 / 网络失败，不要一律加载失败"。
enum DsFailureKind {
  /// 这台 NAS 没装（或没启用）Download Station（能力表里没有该 API）。
  notInstalled,

  /// 装了，但这账号没有该应用权限（`downloadstation.auth` 的 `allow_user`
  /// 只有 `admin/local`，LDAP/域用户天然没有）。
  noPrivilege,

  /// 会话过期，需要重新登录。
  sessionExpired,

  /// 连不上（断网/隧道未起/证书问题）。
  network,

  /// 其它（业务错误、参数错误……）。
  other,
}

/// 把异常归到 [DsFailureKind]（判据与 [describeDownloadError] 一致）。
DsFailureKind downloadFailureKind(Object error) {
  if (error is DsmTransportException) return DsFailureKind.network;
  if (error is! DsmApiException) return DsFailureKind.other;
  switch (error.code) {
    case DsmErrorCode.apiNotFound:
    case DsmErrorCode.methodNotFound:
    case DsmErrorCode.notSupportedVersion:
    case DsmErrorCode.noMatchLibEntry:
      return DsFailureKind.notInstalled;
    case DsmErrorCode.noPermission:
    case DsmErrorCode.noAppPrivilege:
    case 524: // SYNODL_ERR_NO_PRIVILEGE
      return DsFailureKind.noPrivilege;
    case DsmErrorCode.sessionTimeout:
    case DsmErrorCode.sidNotFound:
      return DsFailureKind.sessionExpired;
    case 519: // SYNODL_ERR_NETWORK
      return DsFailureKind.network;
    default:
      return DsFailureKind.other;
  }
}

/// Download Station 错误 → 可读文案。
///
/// 与 `describeFileError` 同一套路，但**按 DS 的语义**解释：
///   * `102` = 这台 NAS 没装/没启用 Download Station（能力表里没这个 API）；
///   * `160` / `105` = 账号没有该应用权限（`downloadstation.auth` 的
///     `allow_user` 只有 `admin/local`，LDAP/域用户天然没有）；
///   * `DsmTransportException` = 网络失败；
///   * 业务码 4xx/5xx 用 §3.5 的 `SYNODL_ERR_*` 表逐条解释。
///
/// 数据层只认 key + 中文原文；英文由 Flutter 层注入（§4.6）。
/// 服务端 120（`requestParameterInvalid`）回包里点名的**参数名**。
///
/// 原始形状（r408 真机逐字，见 `docs/evidence-r408/nas/r408d_create_shape.log`）：
///   `{"code":120,"errors":{"name":"destination","reason":"required"}}`
/// 两种存放位置都认（`DsmApiException.raw` 有的路径是**整包**
/// `{success,error:{code,errors}}`，有的是**摊平的** `{code,errors,…}`）；
/// `errors` 是数组的写法也接受。取不到就回 `null`（**不猜**）。
String? errorFieldName(Map<String, dynamic>? raw) {
  final errors = raw?['errors'] ?? (raw?['error'] as Map?)?['errors'];
  if (errors is Map) {
    final n = errors['name'];
    if (n is String && n.isNotEmpty) return n;
  }
  if (errors is List && errors.isNotEmpty) {
    final first = errors.first;
    if (first is Map) {
      final n = first['name'];
      if (n is String && n.isNotEmpty) return n;
    }
  }
  return null;
}

String describeDownloadError(Object error) {
  if (error is DsmTransportException) {
    // `Task.Source/download` 对非 BT 任务回 **HTTP 404 + DSM HTML 错误页**
    // （真机实测 `docs/download-api-live.md:65`）→ 不是网络问题，别说"检查网络"。
    if (error.statusCode == 404) {
      return dataText('dsErrSourceNotAvailable', '这个任务没有可导出的源文件');
    }
    return dataText('dsErrNetwork', '网络连接失败，请检查网络后重试');
  }
  if (error is! DsmApiException) return '$error';
  switch (error.code) {
    // 通用 WebAPI 码
    case DsmErrorCode.apiNotFound: // 102
    case DsmErrorCode.methodNotFound: // 103
    case DsmErrorCode.notSupportedVersion: // 104
    case DsmErrorCode.noMatchLibEntry: // 121
      return dataText('dsErrNotInstalled', '这台 NAS 没有安装 Download Station');
    case DsmErrorCode.noPermission: // 105
    case DsmErrorCode.noAppPrivilege: // 160
      return dataText('dsErrNoPrivilege', '这个账号没有使用 Download Station 的权限');
    case DsmErrorCode.sessionTimeout: // 106
    case DsmErrorCode.sidNotFound: // 119
      return dataText('errLoginExpired', '登录已过期，请重新登录');
    // 业务码（SYNODL_ERR_*，§3.5）
    case 400: // FILE_UPLOAD_FAILED
      return dataText('dsErrUploadFailed', '种子文件上传失败');
    case 401: // REACH_LIMIT
    case 526: // TASK_REACH_LIMIT_ALL
    case 527: // TASK_REACH_LIMIT_USER
      return dataText('dsErrReachLimit', '任务数量已达上限');
    case 402: // TASK_DEST_DENY
      return dataText('dsStatusErrDestDeny', '下载目录无权限');
    case 403: // TASK_DEST_NOT_EXISTS
    case 531: // PATH_NOT_EXISTS
      return dataText('dsStatusErrDestNotExist', '下载目录不存在');
    case 404: // TASK_NOT_FOUND
    case 544: // TASK_NOT_EXISTS
      return dataText('dsErrTaskNotFound', '任务不存在（可能已被删除）');
    case 405: // ACTION_INVALID
      return dataText('dsErrActionFailed', '操作失败');
    case 406: // NO_DEFAULT_DEST
      return dataText('dsErrNoDefaultDest', '还没有设置默认下载目录，请先填写下载目录');
    case 408: // FILE_NOT_EXISTS
      return dataText('dsStatusErrFileNotExist', '文件不存在');
    case 500: // DEMO_NOT_ALLOW
      return dataText('dsErrDemo', '演示模式下不允许这个操作');
    case 501: // REQUEST_PARAMETER_INVALID
      return dataText('dsErrRequestInvalid', '请求参数不被接受');
    case 502: // JSON_PARSE_FAILED
      return dataText('dsErrJsonParse', '服务端无法解析请求数据');
    case 519: // NETWORK
      return dataText('dsErrNetwork', '网络连接失败，请检查网络后重试');
    case 520: // SYSTEM
    case 521: // ACTION_FAILED
      return dataText('dsErrSystem', 'Download Station 服务异常');
    case 523: // QUOTA_REACH
      return dataText('dsStatusErrQuota', '超出存储配额');
    case 524: // NO_PRIVILEGE
      return dataText('dsErrNoPrivilege', '这个账号没有使用 Download Station 的权限');
    case 537: // UNLINK_FAILED
      return dataText('dsErrUnlinkFailed', '删除文件失败（任务可能仍已移除）');
    // 中性业务码（真机实测；界面一般已分别兜住，这里是兜底的兜底）
    case 1408: // SYNODL_ERR_BTSERACH_ID_NOT_FOUND（BT 搜索不可用/会话无数据源）
      return dataText('dsErrBtSearchUnavailable', '这台 NAS 未启用 BT 搜索或没有可用数据源');
    case DownloadStationApi.errTaskListNotFound: // 1910（清单不存在/已过期）
      return dataText('dsErrListNotFound', '文件清单已过期，请重新添加这个任务');
    case DownloadStationApi.errWrongCaptcha: // 2301（验证码不正确）
      return dataText('dsErrWrongCaptcha', '验证码不正确，请重新输入');
    // ★ DA33（r387）：eMule 搜索的两个"没连上"码 —— 官方前端逐字只给这两个配了
    //   文案（`SYNODL_ERR_EMULE_ED2K_NOT_CONNECTED/KAD_NOT_CONNECTED`，
    //   见 `docs/evidence-r387/ds412_error_enum.txt`）。修前它们落进 default，
    //   界面显示"未知错误 (2704)"——**语义明明是已知的**。
    //   文案只陈述**事实**（谁没连上），不替用户下"去找管理员"的结论：
    //   本客户端的管理员与普通用户都会看到同一句。
    case DownloadStationApi.errEmuleEd2kNotConnected: // 2704
      return dataText('dsErrEmuleEd2kNotConnected', 'eMule 未连接到 ED2K 服务器');
    case DownloadStationApi.errEmuleKadNotConnected: // 2705
      return dataText('dsErrEmuleKadNotConnected', 'eMule 未连接到 Kad 网络');
    case 1911: // NO_THUMBNAIL（暂无缩略图）
      return dataText('dsErrNoThumbnail', '这个任务暂无缩略图');
    case 1913: // FILE_LIST_INACTIVE（任务未激活/已完成）
      return dataText('dsErrFileListInactive', '任务未激活或已完成，暂无文件列表');
    default:
      // ★★ r371（DA18，r361 真机）：`120` 是**业务码** `requestParameterInvalid`，
      //   但它落在 `101..134` 这个"任务状态码"区间里，被下面的状态表解释成
      //   `dsStatusErrExtractInvalid`（**"压缩包已损坏"**）—— 同一文件的注释
      //   （见 `describeDownloadRssError` 头注）自己写着这个映射"完全错"，
      //   RSS 那条通道就是为它打的补丁，但**选文件页走的是这一个函数**。
      //   ⇒ 先走通用参数通道（"请求参数无效"），不再落进状态表。
      //   ★ 根因（服务端为什么对 `.txt`/`.zip` 都回 120）仍**留白**，见缺陷表。
      if (error.code == DsmErrorCode.requestParameterInvalid) {
        // ★★ DA61（r408 真机）：服务端的 120 回包里**点名了是哪个参数** ——
        //   `{"code":120,"errors":{"name":"destination","reason":"required"}}`。
        //   以前这条细节整个被丢掉，界面上只剩"请求参数不被接受"，用户无从下手
        //   （r408 实测：链接浏览器加磁力/ed2k 全失败，却看不出缺的是什么）。
        //   参数名是**机器标识**，按 §2.0.47/D55 一律**原样透传**，不许编人话。
        final base = DsmErrorCode.describe(error.code, method: error.method);
        final field = errorFieldName(error.raw);
        return field == null ? base : '$base ($field)';
      }
      if (error.code >= 101 && error.code <= 134) {
        // 任务状态错误码与业务码在数值上重叠，按状态表给更具体的解释。
        final status = _statusErrorText(error.code);
        if (status != null) return status;
      }
      return dataText(
        'dsErrUnknown',
        '未知错误（{code}）',
      ).replaceAll('{code}', '${error.code}');
  }
}

/// **RSS 专用**错误 → 可读文案（wave3）。
///
/// 为什么要单独一份：RSS 的两个业务码在**通用** [`describeDownloadError`] 里
/// 会被解释错 ——
///   * `120`（`requestParameterInvalid`）落进 `101..134` 的**任务状态表**，
///     被当成 `dsStatusErrExtractInvalid`（"压缩包已损坏"）——**完全错**。
///     RSS 真机的 `120` 是"缺参"（§11 逐条实测）→ 走**既有的通用参数提示通道**
///     [`DsmErrorCode.describe`]（`errRequestParameterInvalid`）。
///   * `2404` / `2405`（[DownloadStationApi.rssUndeterminedErrorCodes]）
///     **语义未定**（§11：成功路径未取证）→ **绝不写死文案**，同样走
///     [`DsmErrorCode.describe`] 的"未知错误 + 原始码"通用提示。
/// 其余码（105/160/519/1913…）继续用下载模块的既有解释。
String describeDownloadRssError(Object error) {
  if (error is! DsmApiException) return describeDownloadError(error);
  if (error.code == DsmErrorCode.requestParameterInvalid ||
      DownloadStationApi.rssUndeterminedErrorCodes.contains(error.code)) {
    // 通用通道：120 → "请求参数无效"；2404/2405 → "错误码 2404/2405"
    // （`messagesText()` 里没有 2404/2405，`describe` 自然回落到原始码）。
    return DsmErrorCode.describe(error.code, method: error.method);
  }
  return describeDownloadError(error);
}

String? _statusErrorText(int status) => switch (status) {
  102 => dataText('dsStatusErrBrokenLink', '链接已失效'),
  103 => dataText('dsStatusErrDestNotExist', '下载目录不存在'),
  104 => dataText('dsStatusErrDestDeny', '下载目录无权限'),
  105 => dataText('dsStatusErrDiskFull', '磁盘空间不足'),
  106 => dataText('dsStatusErrQuota', '超出存储配额'),
  107 => dataText('dsStatusErrTimeout', '下载超时'),
  108 || 109 || 110 => dataText('dsStatusErrFileSize', '超出文件系统大小上限'),
  111 || 112 => dataText('dsStatusErrNameTooLong', '文件名过长'),
  113 => dataText('dsStatusErrTorrentDuplicate', '这个种子已在任务列表里'),
  114 => dataText('dsStatusErrFileNotExist', '文件不存在'),
  118 => dataText('dsStatusErrExtractFailed', '解压失败'),
  119 => dataText('dsStatusErrExtractPassword', '解压密码错误'),
  // ★ 120 原来在这里映射成 `dsStatusErrExtractInvalid`（"压缩包已损坏"）——
  //   见 `describeDownloadError` 的 default 分支：`120` 是**业务码**，
  //   r371（DA18）起在进状态表**之前**就被通用参数通道接走，故本条已删。
  //   （`dsStatusErrExtractInvalid` 仍留在表里给别的生产者用。）
  123 => dataText('dsStatusErrTorrentInvalid', '种子文件无效'),
  124 => dataText('dsStatusErrRequiredAccount', '需要账号信息'),
  125 => dataText('dsStatusErrTryLater', '服务端繁忙，请稍后再试'),
  _ => null,
};

int _intOf(Object? v, int fallback) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

/// 从**已解码的响应信封**里取错误码（取不到 = [DsmErrorCode.unknown]）。
///
/// 二进制通道（[DsmWebApi.postBytesForm]）拿到的原始 JSON 要自己解，
/// 这套判读与 [DownloadStationApi.thumbnails] 内联的那段一致。
int _errorCodeOf(Object? decoded) {
  final err = decoded is Map ? decoded['error'] : null;
  if (err is Map && err['code'] is num) return (err['code'] as num).toInt();
  return DsmErrorCode.unknown;
}

/// `Task.create` 回包的 `list_id` → **一个**清单 id（见 [DsCreateResult.listId]）。
///
/// ★ r387/DA37：服务端给的是**数组**；空数组 / `[]` / `{}` 这类空壳 = 没有清单。
String? firstCreateListId(Object? v) {
  if (v is List) {
    for (final e in v) {
      final s = '$e'.trim();
      if (s.isNotEmpty && s != '[]' && s != '{}') return s;
    }
    return null;
  }
  final s = _strOrNull(v)?.trim();
  if (s == null || s == '[]' || s == '{}') return null;
  return s;
}

String? _strOrNull(Object? v) {
  if (v == null) return null;
  final s = '$v';
  return s.isEmpty ? null : s;
}
