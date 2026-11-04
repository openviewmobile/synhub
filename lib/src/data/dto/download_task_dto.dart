// Download Station 任务记录 DTO —— `SYNO.DownloadStation2.Task.list` / `get`
// 的返回形状，**逐字**对齐 NAS 上 DownloadStation 4.1.2-5012 包内的官方前端
// `ui/download.js`（本轮取证命令见 docs/stage2-audio-download-api.md §1.2）。
//
// 事实来源（都可在解包目录里 grep 到原文）：
//   * 列表 root = **`task`**、total = **`total`**：
//     `{name:"task_id",mapping:"id"}` 一族字段映射；
//   * `additional.detail.*` / `additional.transfer.*` 的取值路径；
//   * 状态码表 `SYNO.SDS.DownloadStation.Utils.TASK_STATUS_INT`（§3.5 全表）。
//
// ⚠️ 本文件属**数据层**：不许 import flutter / package:flutter —— 它要能被
// `dart run tool/*.dart`（纯 Dart VM）加载（见 docs/app-identity-and-i18n.md §4.6）。
// 因此状态/错误的**文案**由界面层给（`download_labels.dart`），这里只给
// 「状态码 + key + 中文原文」；只有 `describeDownloadError` 走 `dataText`。
library;

/// `SYNO.DownloadStation2.Task` 列表里的任务记录。
class DownloadTaskDto {
  const DownloadTaskDto({
    required this.id,
    required this.title,
    required this.type,
    required this.status,
    this.statusExtra = '',
    this.size = 0,
    this.username = '',
    this.detail = const DownloadTaskDetail(),
    this.transfer = const DownloadTaskTransfer(),
  });

  /// 任务 id。官方字段名是 `id`（`task_id` 只是前端 store 的别名），
  /// 一律按**字符串**收，避免 int 溢出。
  final String id;

  /// 顶层 `title`（文件名/标题）。
  final String title;

  /// 顶层 `type`：`bt` / `nzb` / `http` / `ftp` / `emule` …
  final String type;

  /// 顶层 `status`（§3.5 的 `TASK_STATUS_INT`）。
  final int status;

  /// 顶层 `status_extra`（例如解压时的 `extract_progress`）。
  final String statusExtra;

  /// 顶层 `size`（总字节）。
  final int size;

  /// 顶层 `username`（创建者；普通用户列自己的任务时也有）。
  final String username;

  final DownloadTaskDetail detail;
  final DownloadTaskTransfer transfer;

  factory DownloadTaskDto.fromJson(Map<String, dynamic> json) {
    final additional = json['additional'];
    Map<String, dynamic> sub(Object? v) =>
        v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};
    final add = additional is Map
        ? Map<String, dynamic>.from(additional)
        : const <String, dynamic>{};
    return DownloadTaskDto(
      id: _str(json['id'] ?? json['task_id']),
      title: _str(json['title'] ?? json['filename']),
      type: _str(json['type']),
      status: _int(json['status']),
      statusExtra: _str(json['status_extra']),
      size: _int(json['size']),
      username: _str(json['username']),
      detail: DownloadTaskDetail.fromJson(sub(add['detail'])),
      transfer: DownloadTaskTransfer.fromJson(sub(add['transfer'])),
    );
  }

  /// 前端判据 `status >= 101`（`isTaskErrorStatus`）。
  bool get isError => DsTaskStatus.isError(status);

  /// 「已完成」= 官方 `isFinishedStatus`（`FINISHED`/`FINISHING`/`EXTRACTING`）
  /// 再并上做种两态（官方 `QueueFinished` 分类：`PRE_SEEDING`/`SEEDING`/`FINISHED`）。
  bool get isFinished => DsTaskStatus.finishedGroup.contains(status);

  bool get isPaused => status == DsTaskStatus.paused;

  bool get isBt => type == 'bt';

  /// eMule(ED2K) 任务。官方把 eMule 做成**独立模块**
  /// （`SYNO.SDS.DownloadStation.aMule.*`），只有它的编辑窗口才给「优先级」。
  /// 第 328 轮起用于 `_editTask` 的优先级字段门控（`Task/edit` 的 `priority`）。
  bool get isEmule => type == 'emule';

  /// 进度 0–1。官方算法：`size == 0 ? 0 : size_downloaded / size`。
  double get progress {
    if (size <= 0) return 0;
    final done = transfer.sizeDownloaded;
    if (done <= 0) return 0;
    return (done / size).clamp(0.0, 1.0);
  }

  /// 剩余秒数（官方 `timeleftCalc`）；速度未知/已下载完成为 null。
  int? get etaSeconds {
    final speed = transfer.speedDownload;
    if (speed <= 0 || size <= 0) return null;
    final left = size - transfer.sizeDownloaded;
    if (left <= 0) return null;
    return (left / speed).ceil();
  }
}

/// `additional.detail.*`（`Task.list` 传 `additional=["detail"]` 时才有）。
class DownloadTaskDetail {
  const DownloadTaskDetail({
    this.destination = '',
    this.priority = '',
    this.hash = '',
    this.uri = '',
    this.connectedPeers = 0,
    this.totalPeers = 0,
    this.connectedSeeders = 0,
    this.connectedLeechers = 0,
    this.startedTime = 0,
    this.completedTime = 0,
    this.waitingSeconds = 0,
    this.createdTime = 0,
    this.lastSeenComplete = 0,
  });

  final String destination;
  final String priority;
  final String hash;
  final String uri;
  final int connectedPeers;
  final int totalPeers;
  final int connectedSeeders;
  final int connectedLeechers;
  final int startedTime;
  final int completedTime;
  final int waitingSeconds;
  final int createdTime;
  final int lastSeenComplete;

  factory DownloadTaskDetail.fromJson(Map<String, dynamic> json) =>
      DownloadTaskDetail(
        destination: _str(json['destination']),
        priority: _str(json['priority']),
        hash: _str(json['hash']),
        uri: _str(json['uri']),
        connectedPeers: _int(json['connected_peers']),
        totalPeers: _int(json['total_peers']),
        connectedSeeders: _int(json['connected_seeders']),
        connectedLeechers: _int(json['connected_leechers']),
        startedTime: _int(json['started_time']),
        completedTime: _int(json['completed_time']),
        waitingSeconds: _int(json['waiting_seconds']),
        createdTime: _int(json['created_time']),
        lastSeenComplete: _int(json['last_seen_complete']),
      );
}

/// `additional.transfer.*`（`Task.list` 传 `additional=["transfer"]` 时才有）。
class DownloadTaskTransfer {
  const DownloadTaskTransfer({
    this.sizeDownloaded = 0,
    this.sizeUploaded = 0,
    this.speedDownload = 0,
    this.speedUpload = 0,
    this.totalPieces = 0,
    this.downloadedPieces = 0,
    this.seedElapsed = 0,
  });

  final int sizeDownloaded;
  final int sizeUploaded;

  /// 速度单位 **B/s**（官方 `updateTextByRate` 直接拼 `/s`）。
  final int speedDownload;
  final int speedUpload;
  final int totalPieces;
  final int downloadedPieces;
  final int seedElapsed;

  factory DownloadTaskTransfer.fromJson(Map<String, dynamic> json) =>
      DownloadTaskTransfer(
        sizeDownloaded: _int(json['size_downloaded']),
        sizeUploaded: _int(json['size_uploaded']),
        speedDownload: _int(json['speed_download']),
        speedUpload: _int(json['speed_upload']),
        totalPieces: _int(json['total_pieces']),
        downloadedPieces: _int(json['downloaded_pieces']),
        seedElapsed: _int(json['seed_elapsed']),
      );
}

/// `SYNO.DownloadStation2.Task.list` 的一页（root `task` + `total`）。
class DownloadTaskPage {
  const DownloadTaskPage({
    required this.items,
    required this.total,
    this.offset = 0,
    this.limit = 0,
  });

  final List<DownloadTaskDto> items;
  final int total;
  final int offset;
  final int limit;

  bool get hasMore => items.length < total;
}

/// `SYNO.DownloadStation2.Task.Statistic.get`（官方前端读 `download_rate`/`upload_rate`）。
class DownloadTaskStatistic {
  const DownloadTaskStatistic({this.downloadRate = 0, this.uploadRate = 0});

  /// 单位 **B/s**。
  final int downloadRate;
  final int uploadRate;

  factory DownloadTaskStatistic.fromJson(Map<String, dynamic> json) =>
      DownloadTaskStatistic(
        downloadRate: _int(json['download_rate']),
        uploadRate: _int(json['upload_rate']),
      );
}

/// `SYNO.DownloadStation2.Task.BT.get` 的返回（单任务 BT 设置）。
class DownloadBtSettings {
  const DownloadBtSettings({
    this.isActiveTorrent = true,
    this.maxUploadRate = 0,
    this.maxDownloadRate = 0,
    this.seedingRatio = 0,
    this.seedingInterval = 0,
    this.maxPeers = 0,
    this.destination = '',
    this.priority = '',
  });

  /// 官方前端的 `is_active_torrent`：false 表示任务不在活动态（UI 隐藏做种项）。
  final bool isActiveTorrent;

  /// 限速单位 **KB/s**；**0 = 不限**（官方表单的语义，见 `dsBtRateHint`）。
  final int maxUploadRate;
  final int maxDownloadRate;
  final int seedingRatio;
  final int seedingInterval;
  final int maxPeers;
  final String destination;

  /// 单任务下载优先级：`high` / `normal` / `low`（官方 BT 属性表单的
  /// `priority` combobox store，经 `Task.BT.set` 下发）。
  ///
  /// 空串表示"服务端没给/不改"——`setBtSettings` 此时**不下发**该字段
  /// （官方表单 `allowBlank:true`，只有脏字段才会被 `getFieldValues(true)` 带上）。
  final String priority;

  factory DownloadBtSettings.fromJson(Map<String, dynamic> json) =>
      DownloadBtSettings(
        isActiveTorrent: json['is_active_torrent'] != false,
        maxUploadRate: _int(json['max_upload_rate']),
        maxDownloadRate: _int(json['max_download_rate']),
        seedingRatio: _int(json['seeding_ratio']),
        seedingInterval: _int(json['seeding_interval']),
        maxPeers: _int(json['max_peers']),
        destination: _str(json['destination']),
        priority: _str(json['priority']),
      );

  DownloadBtSettings copyWith({
    int? maxUploadRate,
    int? maxDownloadRate,
    int? seedingRatio,
    int? seedingInterval,
    int? maxPeers,
    String? priority,
  }) => DownloadBtSettings(
    isActiveTorrent: isActiveTorrent,
    maxUploadRate: maxUploadRate ?? this.maxUploadRate,
    maxDownloadRate: maxDownloadRate ?? this.maxDownloadRate,
    seedingRatio: seedingRatio ?? this.seedingRatio,
    seedingInterval: seedingInterval ?? this.seedingInterval,
    maxPeers: maxPeers ?? this.maxPeers,
    destination: destination,
    priority: priority ?? this.priority,
  );
}

/// `SYNO.DownloadStation2.Task.BT.Tracker / list`（v2）的一行。
///
/// 字段逐字对齐官方 `InfoTracker` 的 store：`url` / `status` / `update` /
/// `seeds` / `peers`；root = `items`、total = `total`。
class DownloadTrackerDto {
  const DownloadTrackerDto({
    this.url = '',
    this.status = 0,
    this.update = '',
    this.seeds = 0,
    this.peers = 0,
  });

  final String url;
  final int status;

  /// 更新时间（官方 store 里是字符串，原样保留）。
  final String update;
  final int seeds;
  final int peers;

  factory DownloadTrackerDto.fromJson(Map<String, dynamic> json) =>
      DownloadTrackerDto(
        url: _str(json['url']),
        status: _int(json['status']),
        update: _str(json['update']),
        seeds: _int(json['seeds']),
        peers: _int(json['peers']),
      );
}

/// `Task.BT.Tracker.list` 的一页（root `items` + `total`）。
class DownloadTrackerPage {
  const DownloadTrackerPage({required this.items, this.total = 0});

  final List<DownloadTrackerDto> items;
  final int total;
}

/// `SYNO.DownloadStation2.Task.BT.Peer / list`（v2）的一行。
///
/// 字段逐字对齐官方 `InfoPeer` 的 store：`ip` / `client` / `progress` /
/// `speed_upload` / `speed_download`；root = `items`、total = `total`。
class DownloadPeerDto {
  const DownloadPeerDto({
    this.ip = '',
    this.client = '',
    this.progress = 0,
    this.speedUpload = 0,
    this.speedDownload = 0,
  });

  final String ip;
  final String client;

  /// 该 peer 的完成度 0–1（官方 renderer 乘 100 显示百分比）。
  final double progress;
  final int speedUpload;
  final int speedDownload;

  factory DownloadPeerDto.fromJson(Map<String, dynamic> json) =>
      DownloadPeerDto(
        ip: _str(json['ip']),
        client: _str(json['client']),
        progress: _double(json['progress']),
        speedUpload: _int(json['speed_upload']),
        speedDownload: _int(json['speed_download']),
      );
}

/// `Task.BT.Peer.list` 的一页（root `items` + `total`）。
class DownloadPeerPage {
  const DownloadPeerPage({required this.items, this.total = 0});

  final List<DownloadPeerDto> items;
  final int total;
}

/// `SYNO.DownloadStation2.Task.BT.File / list`（v1–v2）返回的**任务内文件**一行。
///
/// 字段逐字对齐 NAS 上 DownloadStation 4.1.2-5012 包内官方前端
/// `ui/download.js` 的 file store（**这一处是本轮新取证**，文档 §3.3 A-2a #7
/// 只写了"名称/大小/优先级"）：
/// ```
/// api:"SYNO.DownloadStation2.Task.BT.File", method:"list", version:2, root:"items",
/// fields:["index","name","size","size_downloaded","progress","priority","wanted"],
/// baseParams:{limit:NUM_REC_PER_PAGE}, totalProperty:"total",
/// paramNames:{start:"offset", limit:"limit", sort:"sort_by", dir:"order"}
/// ```
/// * `priority` 取值 `high` / `normal` / `low`（也可能回 `auto`）；
/// * `wanted=false` 表示这一条被"跳过"（官方 renderer 直接显示 `common.skip`）；
/// * 官方进度列**不是**读 `progress` 而是算 `size_downloaded / size`
///   （`calculateProgressRenderer`），所以这里也只算不算读。
class DownloadFileDto {
  const DownloadFileDto({
    this.index = 0,
    this.name = '',
    this.size = 0,
    this.sizeDownloaded = 0,
    this.progress = 0,
    this.priority = '',
    this.wanted = true,
  });

  final int index;
  final String name;
  final int size;
  final int sizeDownloaded;

  /// 服务端`progress`字段（官方 renderer 未用；保留以便真机核对）。
  final double progress;
  final String priority;
  final bool wanted;

  factory DownloadFileDto.fromJson(Map<String, dynamic> json) =>
      DownloadFileDto(
        index: _int(json['index']),
        name: _str(json['name']),
        size: _int(json['size']),
        sizeDownloaded: _int(json['size_downloaded']),
        progress: _double(json['progress']),
        priority: _str(json['priority']),
        // 官方 store 的 `wanted` 缺省为 true（`enable` 同义）。
        wanted: json['wanted'] != false && json['enable'] != false,
      );

  /// 被跳过（官方 `priorityRenderer`：`wanted=false` → "跳过"）。
  bool get isSkipped => !wanted;

  /// 进度 0–1（官方 `calculateProgressRenderer`：`size==0 → 1`）。
  double get progressRatio {
    if (size <= 0) return 1;
    return (sizeDownloaded / size).clamp(0.0, 1.0);
  }
}

/// `Task.BT.File.list` 的一页（root `items` + `total`）。
class DownloadFilePage {
  const DownloadFilePage({required this.items, this.total = 0});

  final List<DownloadFileDto> items;
  final int total;
}

/// `SYNO.DownloadStation2.Thumbnail / get`（v2）返回的一项缩略图。
///
/// 官方 `ui/download.js` 的 `setThumbnail`（逐字）：
/// 回包 `data` 是**裸数组**，每项 `{file_name, thumbnail_list:[{thumbnail_id}]}`；
/// 图片本体走 `Thumbnail/download` + `thumbnail_id`（见 `DownloadStationApi.thumbnailUrl`）。
class DownloadThumbnailDto {
  const DownloadThumbnailDto({this.fileName = '', this.thumbnailId = ''});

  /// 文件路径（官方 `getFileName` 只取 basename 显示）。
  final String fileName;
  final String thumbnailId;

  /// 从**裸数组**（或少了数组包裹的 Map）里摊平出所有 `thumbnail_id`。
  static List<DownloadThumbnailDto> listFromJson(Object? raw) {
    final out = <DownloadThumbnailDto>[];
    void addItem(Object? e) {
      if (e is! Map) return;
      final m = Map<String, dynamic>.from(e);
      final name = _str(m['file_name']);
      final list = m['thumbnail_list'] ?? m['thumbnails'];
      if (list is List) {
        for (final t in list) {
          if (t is! Map) continue;
          final tm = Map<String, dynamic>.from(t);
          final id = _str(tm['thumbnail_id'] ?? tm['id']);
          if (id.isEmpty) continue;
          out.add(DownloadThumbnailDto(fileName: name, thumbnailId: id));
        }
      } else {
        // 兼容退化形态：直接给 `thumbnail_id`。
        final id = _str(m['thumbnail_id'] ?? m['id']);
        if (id.isNotEmpty) {
          out.add(DownloadThumbnailDto(fileName: name, thumbnailId: id));
        }
      }
    }

    if (raw is List) {
      for (final e in raw) {
        addItem(e);
      }
    } else {
      addItem(raw);
    }
    return out;
  }
}

/// `SYNO.DownloadStation2.Settings.AutoExtraction / get`（v1，普通用户可读）的返回。
///
/// 官方 `Settings.AutoExtraction` 面板的 `getFields()`（`ui/download.js`，逐字）：
/// `create_subfolder` / `delete_archive` / `enable_unzip` / `unzip_location` /
/// `passwords` / `unzip_overwrite` / `unzip_to_path`；
/// `_S("is_admin")` 时另加 `enable_unzip_service`（admin 专属，本客户端不下发）。
/// `getKeyName()` = `unzip`（面板分组名，不进请求）。
class DownloadAutoExtractionSettings {
  const DownloadAutoExtractionSettings({
    this.enableUnzip = false,
    this.unzipLocation = '',
    this.unzipToPath = '',
    this.createSubfolder = false,
    this.deleteArchive = false,
    this.unzipOverwrite = false,
    this.passwords = const [],
  });

  /// 「自动解压下载的压缩文件」总开关（设置页的开关就绑这个字段）。
  final bool enableUnzip;

  /// 官方 radio 的**两个真值**：`current_folder` / `select_folder`
  /// （4.1.2 `ui/download.js` 逐字；★ r410 DA64：`specified_folder` 是
  /// 我们写错的值，服务端从来没发过）。**未知值原样保留**。
  final String unzipLocation;

  /// `unzip_location == select_folder` 时的目标路径。
  final String unzipToPath;
  final bool createSubfolder;
  final bool deleteArchive;
  final bool unzipOverwrite;
  final List<String> passwords;

  factory DownloadAutoExtractionSettings.fromJson(Map<String, dynamic> json) =>
      DownloadAutoExtractionSettings(
        enableUnzip: json['enable_unzip'] == true,
        unzipLocation: _str(json['unzip_location']),
        unzipToPath: _str(json['unzip_to_path']),
        createSubfolder: json['create_subfolder'] == true,
        deleteArchive: json['delete_archive'] == true,
        unzipOverwrite: json['unzip_overwrite'] == true,
        passwords: [
          if (json['passwords'] is List)
            for (final p in json['passwords'] as List) _str(p),
        ],
      );
}

/// `SYNO.DownloadStation2.Task.List / get`（v2）返回的**待选文件**。
///
/// 官方 `QueueAddFilePanel` 的 store（`ui/download.js`，逐字）：
/// `api:"SYNO.DownloadStation2.Task.List", method:"get", version:2`,
/// root = **`files`**，字段 `index` / `name` / `size` / `download_url` /
/// `enable`（默认 true）。`enable=false` 的文件不会被下载。
class DownloadCreateListFile {
  const DownloadCreateListFile({
    this.index = 0,
    this.name = '',
    this.size = 0,
    this.downloadUrl = '',
    this.enable = true,
  });

  final int index;
  final String name;
  final int size;
  final String downloadUrl;
  final bool enable;

  factory DownloadCreateListFile.fromJson(Map<String, dynamic> json) =>
      DownloadCreateListFile(
        index: _int(json['index']),
        name: _str(json['name']),
        size: _int(json['size']),
        downloadUrl: _str(json['download_url']),
        enable: json['enable'] != false,
      );
}

/// `Task.List.get` 的结果：待选文件 + 总数（root `files`）。
class DownloadCreateList {
  const DownloadCreateList({required this.files, this.total = 0});

  final List<DownloadCreateListFile> files;
  final int total;
}

double _double(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}

// ---------------------------------------------------------------- BT 搜索

/// `SYNO.DownloadStation2.BTSearch / list` 的**一行结果**。
///
/// **字段名的权威来源**：SPK 包内官方前端 `ui/download.js` 的
/// `SYNO.SDS.DownloadStation.DLM.SearchGridPanel.createStore()`（逐字）：
/// ```
/// fields = [title, size, date, seeds, peers, provider, dlurl, page]
/// root = "results", idProperty = "result_id", totalProperty = "total"
/// ```
/// 即：`title`（名称）/ `size`（字节）/ `date`（`new Date(g)` → epoch 毫秒）/
/// `seeds`·`peers`（**<0 = 未知**，官方渲染器如是说）/ `provider`（数据源名）/
/// `dlurl`（**建任务用的 URL**，官方 `downloadSelected` 只认它）/
/// `page`（详情页外链，官方只用于"在外部打开"）。
///
/// ⚠️ **真机 `results:[]`**：以上是**客户端字段名**取证（官方前端 store），
/// **成功回包的实际 JSON 条目仍未在真机取证**（见 `docs/download-gaps-wave2.md`
/// 的"未取证清单"）。因此这里**只放宽类型、不臆造键名**：键缺失/类型不对一律
/// 回落中性值，并**保留 [raw] 原始 map** 供日后核对；绝不因此崩页面。
class DsBtSearchResult {
  const DsBtSearchResult({
    required this.raw,
    this.resultId = '',
    this.title = '',
    this.size = 0,
    this.date = 0,
    this.seeds = -1,
    this.peers = -1,
    this.provider = '',
    this.dlurl = '',
    this.page = '',
  });

  /// 服务端原始条目（字段名可能随版本变化，保留原文以便核对）。
  final Map<String, dynamic> raw;

  /// `result_id`（官方 `idProperty`）。**内部标识，界面绝不显示**。
  final String resultId;

  final String title;
  final int size;

  /// epoch **毫秒**（官方列渲染 `new Date(g)` 按毫秒解释）。
  final int date;

  /// `-1` = 服务端未给出（官方：`seeds < 0` → 显示"未知"）。
  final int seeds;
  final int peers;

  /// 数据源（插件 displayname）。
  final String provider;

  /// 建任务用的下载 URL（官方 `downloadSelected` 读的就是 `dlurl`）。
  final String dlurl;

  /// 详情页外链（官方 `openTorrentLink` 读 `page`）。
  final String page;

  /// `seeds`/`peers` 是否是有效数字（`>=0`）。
  bool get hasSeedInfo => seeds >= 0;
  bool get hasPeerInfo => peers >= 0;

  factory DsBtSearchResult.fromJson(Map<String, dynamic> json) {
    int unknownAware(Object? v) {
      if (v == null) return -1;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? -1;
      return -1;
    }

    return DsBtSearchResult(
      raw: json,
      resultId: _str(json['result_id']),
      title: _str(json['title']),
      size: _int(json['size']),
      date: _int(json['date']),
      seeds: unknownAware(json['seeds']),
      peers: unknownAware(json['peers']),
      provider: _str(json['provider']),
      dlurl: _str(json['dlurl']),
      page: _str(json['page']),
    );
  }
}

/// `SYNO.DownloadStation2.BTSearch / list` 的一页（root `results` + `total`）。
///
/// 真机回包（§10.2）：`{is_running:bool, results:[], total:int}`。
class DsBtSearchPage {
  const DsBtSearchPage({
    this.results = const [],
    this.total = 0,
    this.isRunning = false,
    this.searchDone = false,
  });

  final List<DsBtSearchResult> results;
  final int total;
  final bool isRunning;

  /// 官方 aMule 搜索用 `search_done`；DS2 BTSearch 用 `is_running`（§10.1）。
  /// 这里两个都收，停止条件"任一为真"（宽容，避免死轮询）。
  final bool searchDone;

  factory DsBtSearchPage.fromJson(Map<String, dynamic> json) {
    final rawList = json['results'];
    return DsBtSearchPage(
      results: rawList is List
          ? [
              for (final e in rawList)
                if (e is Map)
                  DsBtSearchResult.fromJson(Map<String, dynamic>.from(e)),
            ]
          : const [],
      total: _int(json['total']),
      isRunning: json['is_running'] == true,
      searchDone: json['search_done'] == true,
    );
  }
}

/// `SYNO.DownloadStation2.BTSearch / list_plugin_status` 的单个插件状态。
///
/// 字段 `can_connect` 逐字取自官方前端（`checkPluginStatus`：
/// `a.plugins.some(function(c){return !c.can_connect})`）。
/// ⚠️ 真机回 `{plugins:[]}`（**空**），成功时插件条目的**完整字段仍未取证**
/// → 缺 `can_connect` 时按 `true`（"没明确说连不上，就不吓用户"）。
class DsBtSearchPluginStatus {
  const DsBtSearchPluginStatus({
    this.plugins = const [],
    this.canConnect = true,
  });

  final List<DsBtSearchPlugin> plugins;

  /// 顶层 `can_connect`（真机回包里没有；有就一起收）。
  final bool canConnect;

  /// 是否**全部可连**。任一插件 `can_connect != true`（或顶层为 false）→ false。
  bool get allConnected => canConnect && !plugins.any((p) => !p.canConnect);

  factory DsBtSearchPluginStatus.fromJson(Map<String, dynamic> json) {
    final raw = json['plugins'];
    return DsBtSearchPluginStatus(
      plugins: raw is List
          ? [
              for (final e in raw)
                if (e is Map)
                  DsBtSearchPlugin.fromJson(Map<String, dynamic>.from(e)),
            ]
          : const [],
      canConnect: json['can_connect'] != false,
    );
  }
}

/// `list_plugin_status` 里的一个插件（成功字段未取证，宽容解析）。
class DsBtSearchPlugin {
  const DsBtSearchPlugin({
    this.id = '',
    this.title = '',
    this.canConnect = true,
  });

  final String id;
  final String title;
  final bool canConnect;

  factory DsBtSearchPlugin.fromJson(Map<String, dynamic> json) =>
      DsBtSearchPlugin(
        id: _str(json['id'] ?? json['plugin_id']),
        title: _str(json['title'] ?? json['name'] ?? json['plugin_name']),
        // 没明确说 false 就按可连（避免把"字段缺失"渲染成"结果不完整"）。
        canConnect: json['can_connect'] != false,
      );
}

/// 老一代 `SYNO.DownloadStation.BTSearch / getModule` 的一个**数据源**。
///
/// 字段名来源：包内 `webapi/btsearch.cgi` 的字符串表（`enabled` / `module_id` /
/// `module_title` / `displayname` / `modules`）。真机实测回 **13 个 enabled 模块**
/// （§10.2），但**成功条目的确切 JSON 键未逐字取证** → 宽容取 `module_id|id`、
/// `module_title|title|displayname`。
class DsBtSearchModule {
  const DsBtSearchModule({this.id = '', this.title = '', this.enabled = true});

  /// 数据源 id（`start` 的 `id` 参数用它）。
  final String id;
  final String title;
  final bool enabled;

  factory DsBtSearchModule.fromJson(Map<String, dynamic> json) =>
      DsBtSearchModule(
        id: _str(json['module_id'] ?? json['id']),
        title: _str(
          json['module_title'] ?? json['title'] ?? json['displayname'],
        ),
        enabled: json['enabled'] != false,
      );
}

/// 老一代 `SYNO.DownloadStation.BTSearch / list` 的**一行结果**。
///
/// **字段名逐字来自真机回包**（`docs/download-api-live.md` §12.2）：
/// `date` / `download_uri` / `external_link` / `id` / `leechs` / `module_id` /
/// `module_title` / `peers` / `seeds` / `size` / `title`（共 11 个）。
///
/// ⚠️ 两条必须记住的类型事实：
///   * **`size` 是字符串字节数**（真机逐字 `"204385784"`）→ 用 [_int] 解析成
///     字节后再由界面走 [dsHumanBytes] 格式化，**不许当数字直接上屏**；
///   * `date` 真机是**日期字符串**（逐字 `"2012-04-20"`），不是 epoch 毫秒
///     → 原样保留为 [date]，界面直接显示。
///
/// 内部标识 [id] / [moduleId] **只用于去重与筛选**，界面绝不把它们当可见文本。
class DsBtSearchLegacyResult {
  const DsBtSearchLegacyResult({
    required this.raw,
    this.id = '',
    this.title = '',
    this.size = 0,
    this.date = '',
    this.seeds = -1,
    this.leechs = -1,
    this.peers = -1,
    this.moduleId = '',
    this.moduleTitle = '',
    this.downloadUri = '',
    this.externalLink = '',
  });

  /// 服务端原始条目（保留原文以便日后核对）。
  final Map<String, dynamic> raw;

  /// `id`（内部标识，界面绝不显示）。
  final String id;

  final String title;

  /// 字节数（`size` 字符串解析而来）。
  final int size;

  /// 真机是日期字符串（`"2012-04-20"`）；若服务端回数字则存数字文本。
  final String date;

  /// `-1` = 服务端未给出（未知）。
  final int seeds;
  final int leechs;
  final int peers;

  /// `module_id`（内部标识，界面绝不显示；用于模块筛选）。
  final String moduleId;

  /// `module_title`（**显示名**，界面用这个）。
  final String moduleTitle;

  /// `download_uri`（magnet）。★ r388/DA35 起**真的用来建任务**（结果行的
  /// 「下载」按钮 → `Task.create type=url`），不再是"仅解析留档"。
  final String downloadUri;

  /// `external_link`（详情外链）。本波次不上屏。
  final String externalLink;

  bool get hasSeedInfo => seeds >= 0;
  bool get hasPeerInfo => peers >= 0;

  factory DsBtSearchLegacyResult.fromJson(Map<String, dynamic> json) {
    int unknownAware(Object? v) {
      if (v == null) return -1;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? -1;
      return -1;
    }

    return DsBtSearchLegacyResult(
      raw: json,
      id: _str(json['id']),
      title: _str(json['title']),
      size: _int(json['size']),
      date: _str(json['date']),
      seeds: unknownAware(json['seeds']),
      leechs: unknownAware(json['leechs']),
      peers: unknownAware(json['peers']),
      moduleId: _str(json['module_id']),
      moduleTitle: _str(json['module_title']),
      downloadUri: _str(json['download_uri']),
      externalLink: _str(json['external_link']),
    );
  }
}

/// 老一代 `SYNO.DownloadStation.BTSearch / list` 的**一页**。
///
/// 真机顶层（逐字，`docs/download-api-live.md` §12.2）：
/// `{finished, items, offset, total}`。
/// ❗ [finished] 是**轮询标志**：`false` = 服务端还在抓，继续轮询；
/// `true` = 抓完。
class DsBtSearchLegacyPage {
  const DsBtSearchLegacyPage({
    this.items = const [],
    this.total = 0,
    this.offset = 0,
    this.finished = false,
  });

  final List<DsBtSearchLegacyResult> items;
  final int total;
  final int offset;
  final bool finished;

  factory DsBtSearchLegacyPage.fromJson(Map<String, dynamic> json) {
    final rawList = json['items'];
    return DsBtSearchLegacyPage(
      items: rawList is List
          ? [
              for (final e in rawList)
                if (e is Map)
                  DsBtSearchLegacyResult.fromJson(Map<String, dynamic>.from(e)),
            ]
          : const [],
      total: _int(json['total']),
      offset: _int(json['offset']),
      finished: json['finished'] == true,
    );
  }
}

/// 任务状态码（`TASK_STATUS_INT`，逐字抄自官方前端；§3.5）。
class DsTaskStatus {
  const DsTaskStatus._();

  static const int waiting = 1;
  static const int downloading = 2;
  static const int paused = 3;
  static const int finishing = 4;
  static const int finished = 5;
  static const int hashChecking = 6;
  static const int preSeeding = 7;
  static const int seeding = 8;
  static const int filehostingWaiting = 9;
  static const int extracting = 10;
  static const int preprocessing = 11;
  static const int preprocessPass = 12;
  static const int downloaded = 13;
  static const int postprocessing = 14;
  static const int captchaNeeded = 15;

  // 101 起为错误态（前端判据 `status >= 101`）。
  static const int error = 101;
  static const int brokenLink = 102;
  static const int destNotExist = 103;
  static const int destDeny = 104;
  static const int diskFull = 105;
  static const int quotaReached = 106;
  static const int timeout = 107;
  static const int exceedMaxFsSize = 108;
  static const int exceedMaxTempFsSize = 109;
  static const int exceedMaxDestFsSize = 110;
  static const int nameTooLongEncryption = 111;
  static const int nameTooLong = 112;
  static const int torrentDuplicate = 113;
  static const int fileNoExist = 114;
  static const int requiredPremium = 115;
  static const int notSupportType = 116;
  static const int ftpEncryptionNotSupport = 117;
  static const int extractFail = 118;
  static const int extractWrongPassword = 119;
  static const int extractInvalidArchive = 120;
  static const int extractQuotaReached = 121;
  static const int extractDiskFull = 122;
  static const int torrentInvalid = 123;
  static const int requiredAccount = 124;
  static const int tryItLater = 125;
  static const int encryption = 126;
  static const int missingPython = 127;
  static const int privateVideo = 128;
  static const int extractFolderNotExist = 129;
  static const int nzbMissingArticle = 130;
  static const int ed2kLinkDuplicate = 131;
  static const int destFileDuplicate = 132;
  static const int par2RepairFailed = 133;
  static const int invalidAccountPassword = 134;

  /// `status >= 101`（前端 `isTaskErrorStatus`）。
  static bool isError(int status) => status >= error;

  /// 官方 `isActiveTorrentStatus`：下载/准备做种/做种/校验 —— 这些是"真的在跑"。
  static const Set<int> active = {
    downloading,
    preSeeding,
    seeding,
    hashChecking,
  };

  /// 「下载中」分类（官方 `QueueDownloading`）+ 官方没归类但语义也在进行的
  /// 等待/预处理两态（`WAITING`/`PREPROCESSING`/`PREPROCESSPASS`）。
  static const List<int> downloadingGroup = [
    waiting,
    downloading,
    hashChecking,
    finishing,
    preprocessing,
    preprocessPass,
    downloaded,
    postprocessing,
  ];

  /// 「已完成」分类 = 官方 `QueueFinished`（做种两态 + 已完成）。
  static const List<int> finishedGroup = [preSeeding, seeding, finished];

  /// 「等待中」分类 = 官方过滤类 `waiting`/`filehosting_waiting`
  /// （两个字符串都在官方 DSdownload dex 里逐个搜到）。
  static const List<int> waitingGroup = [waiting, filehostingWaiting];

  /// 「做种」分类 = 官方过滤类 `seeding`。
  static const List<int> seedingGroup = [preSeeding, seeding];

  /// 「校验/解压」分类 = 官方过滤类 `hash_checking`/`extracting`。
  static const List<int> hashCheckingGroup = [hashChecking, finishing];
  static const List<int> extractingGroup = [
    extracting,
    preprocessing,
    preprocessPass,
    postprocessing,
  ];

  /// 「已暂停」分类 = 官方 `QueueStopped`。
  static const List<int> pausedGroup = [paused];

  /// 「进行中（active）」= 官方过滤类 `active`：下载中 ∨ 做种中 ∨ 校验/解压中。
  static const List<int> activeGroup = [
    waiting,
    downloading,
    hashChecking,
    finishing,
    preprocessing,
    preprocessPass,
    downloaded,
    postprocessing,
    preSeeding,
    seeding,
  ];

  /// 错误态全表（101–134），用来做服务端 `status` 过滤。
  ///
  /// ⚠️ `status` 的**合法取值域**在官方前端里没有穷举证据（§5 U7）：这里用
  /// 官方状态常量全表，属于"按已证事实拼出来的候选"，真机传一次即知。
  static const List<int> errorGroup = [
    error,
    brokenLink,
    destNotExist,
    destDeny,
    diskFull,
    quotaReached,
    timeout,
    exceedMaxFsSize,
    exceedMaxTempFsSize,
    exceedMaxDestFsSize,
    nameTooLongEncryption,
    nameTooLong,
    torrentDuplicate,
    fileNoExist,
    requiredPremium,
    notSupportType,
    ftpEncryptionNotSupport,
    extractFail,
    extractWrongPassword,
    extractInvalidArchive,
    extractQuotaReached,
    extractDiskFull,
    torrentInvalid,
    requiredAccount,
    tryItLater,
    encryption,
    missingPython,
    privateVideo,
    extractFolderNotExist,
    nzbMissingArticle,
    ed2kLinkDuplicate,
    destFileDuplicate,
    par2RepairFailed,
    invalidAccountPassword,
  ];

  /// 「进度条要转」的中间态（不含暂停/错误/已完成）。
  static bool isRunning(int status) =>
      downloadingGroup.contains(status) || active.contains(status);
}

/// 任务列表的分类（界面的三个 tab）。`status` 服务端过滤用的就是这三组。
enum DownloadTaskCategory {
  all,
  active,
  downloading,
  waiting,
  seeding,
  hashChecking,
  extracting,
  paused,
  finished,
  error,
}

/// 字节格式化（数据层纯 Dart，避免引 `core/media` 里带 flutter 的那份）。
String dsHumanBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1023.95 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}

/// 速率格式化：入参是 **B/s**（服务端单位），显示成 `KB/s`/`MB/s`。
String dsHumanRate(int bytesPerSecond) {
  if (bytesPerSecond <= 0) return '0 KB/s';
  if (bytesPerSecond < 1024 * 1024) {
    return '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
  }
  return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
}

/// 剩余时间格式化：`1 天 2 小时` / `3 分 20 秒`（数字 + 单位由界面层再拼，见
/// `download_labels.dart` 的 `dsEtaText`）。这里只给**段**，因为单位要翻译。
List<({int value, String unit})> dsEtaParts(int? seconds) {
  if (seconds == null || seconds <= 0) return const [];
  final d = seconds ~/ 86400;
  final h = (seconds % 86400) ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  return [
    if (d > 0) (value: d, unit: 'd'),
    if (h > 0) (value: h, unit: 'h'),
    if (m > 0) (value: m, unit: 'm'),
    if (s > 0 && d == 0) (value: s, unit: 's'),
  ];
}

// ------------------------------------------------------------------ RSS 订阅
//
// 字段名**逐字**取自官方前端 `ui/download.js`（`DLM.RSSGridPanel` /
// `DLM.RSSItemList` / `DLM.RSSFilterList` 的 `createStore().fields`）：
//   * Feed   store：`["id","title","url","last_update","is_updating","username"]`
//   * Item   store：`["id","feed_id","title","url","link","date","size","is_new"]`
//   * Filter store：`["id","feed_id","name","match","not_match","destination",
//                     "enable","is_regex"]`
// 回包 root 一律是 `items` + `total`（Feed:list 另含顶层 `is_updating`，真机实测
// `docs/download-api-live.md:316`）。
//
// ⚠️ **真机只取证到"空列表 + is_updating:false"**（§11）：成功条目的**实际 JSON
// 形状**仍属未取证。这里**只放宽类型、不臆造键名**：缺字段/类型不对回落中性值，
// 并保留 [DsRssFeed.raw] 等原始 map 供日后核对；绝不因此崩页面。
// ⚠️ `id` / `feed_id` 是**内部标识**，界面**绝不显示**（任务书硬要求）。

/// `SYNO.DownloadStation2.RSS.Feed / list` 里的一条订阅源。
class DsRssFeed {
  const DsRssFeed({
    required this.raw,
    this.id = '',
    this.title = '',
    this.url = '',
    this.lastUpdate = 0,
    this.isUpdating = false,
    this.username = '',
  });

  /// 服务端原始条目（字段名可能随版本变化，保留原文以便核对）。
  final Map<String, dynamic> raw;

  /// `id`（`set`/`delete`/`update` 与 `feed_id` 用它）。**内部标识，界面绝不显示**。
  final String id;

  /// 订阅名（可为空 —— 真机新建时官方只传 `url`，名字由服务端抓取后回填）。
  final String title;

  /// 订阅地址（`url`）。
  final String url;

  /// `last_update`：epoch **秒**（官方列渲染 `new Date(f*1000)`）。
  final int lastUpdate;

  /// `is_updating`：这一条正在更新 → 界面给"更新中"并轮询。
  final bool isUpdating;

  /// `username`（官方列在非管理员时隐藏）。
  final String username;

  factory DsRssFeed.fromJson(Map<String, dynamic> json) => DsRssFeed(
    raw: json,
    id: _str(json['id']),
    title: _str(json['title'] ?? json['name']),
    url: _str(json['url']),
    lastUpdate: _int(json['last_update']),
    isUpdating: json['is_updating'] == true,
    username: _str(json['username']),
  );
}

/// `RSS.Feed / list` 的一页（root `items` + `total` + **顶层 `is_updating`**）。
class DsRssFeedPage {
  const DsRssFeedPage({
    this.items = const [],
    this.total = 0,
    this.isUpdating = false,
  });

  final List<DsRssFeed> items;
  final int total;

  /// 顶层 `is_updating`：**全库**是否有正在进行的更新（真机回包逐字，§11）。
  /// 官方轮询判据是**逐条的** `is_updating`（`RSSGridPanel.onStoreLoad`），
  /// 顶层位只作"还有没有在忙"的兜底提示。
  final bool isUpdating;

  /// 是否任一订阅源在更新（顶层位 **或** 逐条位）。
  bool get anyUpdating => isUpdating || items.any((f) => f.isUpdating);

  factory DsRssFeedPage.fromJson(Map<String, dynamic> json) {
    final raw = json['items'];
    return DsRssFeedPage(
      items: raw is List
          ? [
              for (final e in raw)
                if (e is Map) DsRssFeed.fromJson(Map<String, dynamic>.from(e)),
            ]
          : const [],
      total: _int(json['total']),
      isUpdating: json['is_updating'] == true,
    );
  }
}

/// `SYNO.DownloadStation2.RSS.Item / list` 里的一条订阅条目。
class DsRssItem {
  const DsRssItem({
    required this.raw,
    this.id = '',
    this.feedId = '',
    this.title = '',
    this.url = '',
    this.link = '',
    this.date = 0,
    this.size = 0,
    this.isNew = false,
  });

  final Map<String, dynamic> raw;

  /// `id`（**内部标识，界面绝不显示**）。
  final String id;

  /// `feed_id`（**内部标识，界面绝不显示**）。
  final String feedId;

  final String title;

  /// `url`：官方"下载"动作读的字段（`getSelectionUrls()` 取 `url`）。
  final String url;

  /// `link`：官方"打开原链接"读的字段（`actionExternalHandler` 取 `link`）。
  final String link;

  /// `date`：epoch **秒**（官方列渲染 `new Date(b*1000)`）。
  final int date;

  /// `size`：官方列渲染成人类可读（`parseInt` 后 `sizeRenderer`）。
  final int size;

  /// `is_new`：新条目标记（官方 store 字段；用途未在 UI 里展开）。
  final bool isNew;

  factory DsRssItem.fromJson(Map<String, dynamic> json) => DsRssItem(
    raw: json,
    id: _str(json['id']),
    feedId: _str(json['feed_id']),
    title: _str(json['title']),
    url: _str(json['url']),
    link: _str(json['link']),
    date: _int(json['date']),
    size: _int(json['size']),
    isNew: json['is_new'] == true,
  );
}

/// `RSS.Item / list` 的一页（root `items` + `total`）。
class DsRssItemPage {
  const DsRssItemPage({this.items = const [], this.total = 0});

  final List<DsRssItem> items;
  final int total;

  factory DsRssItemPage.fromJson(Map<String, dynamic> json) {
    final raw = json['items'];
    return DsRssItemPage(
      items: raw is List
          ? [
              for (final e in raw)
                if (e is Map) DsRssItem.fromJson(Map<String, dynamic>.from(e)),
            ]
          : const [],
      total: _int(json['total']),
    );
  }
}

/// `SYNO.DownloadStation2.RSS.Filter / list` 里的一条自动下载过滤器。
class DsRssFilter {
  const DsRssFilter({
    required this.raw,
    this.id = '',
    this.feedId = '',
    this.name = '',
    this.match = '',
    this.notMatch = '',
    this.destination = '',
    this.enable = false,
    this.isRegex = false,
  });

  final Map<String, dynamic> raw;

  /// `id`（`set`/`delete` 用它）。**内部标识，界面绝不显示**。
  final String id;

  /// `feed_id`（**内部标识，界面绝不显示**）。
  final String feedId;

  final String name;
  final String match;
  final String notMatch;

  /// `destination`：**下载目标文件夹路径字符串**（官方表单是 readOnly 文本框，
  /// 由文件夹选择器写入 `path.substr(1)`；`ui/download.js` 逐字）。
  final String destination;

  final bool enable;
  final bool isRegex;

  factory DsRssFilter.fromJson(Map<String, dynamic> json) => DsRssFilter(
    raw: json,
    id: _str(json['id']),
    feedId: _str(json['feed_id']),
    name: _str(json['name']),
    match: _str(json['match']),
    notMatch: _str(json['not_match']),
    destination: _str(json['destination']),
    enable: json['enable'] != false,
    isRegex: json['is_regex'] == true,
  );
}

/// `RSS.Filter / list` 的一页（root `items` + `total`）。
class DsRssFilterPage {
  const DsRssFilterPage({this.items = const [], this.total = 0});

  final List<DsRssFilter> items;
  final int total;

  factory DsRssFilterPage.fromJson(Map<String, dynamic> json) {
    final raw = json['items'];
    return DsRssFilterPage(
      items: raw is List
          ? [
              for (final e in raw)
                if (e is Map)
                  DsRssFilter.fromJson(Map<String, dynamic>.from(e)),
            ]
          : const [],
      total: _int(json['total']),
    );
  }
}

// ------------------------------------------------ F14：Package 能力探测
//
// 事实来源（**真机只读实调，2026-09-22**）：
//   * `SYNO.DownloadStation2.Package.Info / get` v2 →
//     `{major:4, minor:1, build_number:5012, is_manager:false}`；
//   * `SYNO.DownloadStation2.Package.Module / list` v2 →
//     `{listItems:[{fn,folder,iconCls,text}]}`（真机回 BT + eMule 两项）；
//   * `SYNO.DownloadStation2.Package.Service / get` v2 →
//     `{enable_bt_preview,enable_emule,enable_unzip,is_unzip_service_enable}`。
// 官方前端 `ui/download.js` 的 `MainWindow` 也逐字用这三个（`webapiModuleList` /
// `webapiServiceGet`），并用 `is_unzip_service_enable` / `enable_unzip` /
// `enable_emule` 决定 tab 与解压入口是否出现。

/// `SYNO.DownloadStation2.Package.Info / get`（v2，normal）。
class DsPackageInfo {
  const DsPackageInfo({
    this.major = 0,
    this.minor = 0,
    this.buildNumber = 0,
    this.isManager = false,
  });

  final int major;
  final int minor;
  final int buildNumber;

  /// 当前账号是不是管理员（官方 `is_manager`；本客户端只做普通用户功能）。
  final bool isManager;

  /// 可读版本串（`4.1-5012` 形态，对齐 `SYNO.DownloadStation.Info.getinfo`
  /// 的 `version_string`）。
  String get versionString => major <= 0 ? '' : '$major.$minor-$buildNumber';

  factory DsPackageInfo.fromJson(Map<String, dynamic> json) => DsPackageInfo(
    major: _int(json['major']),
    minor: _int(json['minor']),
    buildNumber: _int(json['build_number']),
    isManager: json['is_manager'] == true,
  );
}

/// `SYNO.DownloadStation2.Package.Module / list`（v2，normal）里的一项。
///
/// 字段逐字来自真机回包：`fn`（模块构造名）/`folder`/`iconCls`/`text`（i18n key）。
class DsPackageModule {
  const DsPackageModule({
    this.fn = '',
    this.folder = '',
    this.iconCls = '',
    this.text = '',
  });

  final String fn;
  final String folder;
  final String iconCls;

  /// 官方 i18n key（例如 `helptoc:dl_bt`）。**内部值，界面不直接显示**。
  final String text;

  factory DsPackageModule.fromJson(Map<String, dynamic> json) =>
      DsPackageModule(
        fn: _str(json['fn']),
        folder: _str(json['folder']),
        iconCls: _str(json['iconCls']),
        text: _str(json['text']),
      );
}

/// `SYNO.DownloadStation2.Package.Service / get`（v2，normal）—— 能力位。
///
/// 官方前端拿它做 UI 门控（`SYNO.SDS.DownloadStation.isUnzipServiceEnable` /
/// `isPersonalUnzipEnable` / `gData.amule_enabled`）。
class DsPackageService {
  const DsPackageService({
    this.enableBtPreview = false,
    this.enableEmule = false,
    this.enableUnzip = false,
    this.isUnzipServiceEnable = false,
  });

  /// BT 预览（缩略图，F8）是否开启。
  final bool enableBtPreview;

  /// eMule 是否开启（对本客户端无意义：eMule 任务对普通用户是 admin-only）。
  final bool enableEmule;

  /// 「个人」自动解压是否开启（F9）。
  final bool enableUnzip;

  /// 解压服务是否可用（官方用它决定要不要显示解压相关字段）。
  final bool isUnzipServiceEnable;

  factory DsPackageService.fromJson(Map<String, dynamic> json) =>
      DsPackageService(
        enableBtPreview: json['enable_bt_preview'] == true,
        enableEmule: json['enable_emule'] == true,
        enableUnzip: json['enable_unzip'] == true,
        isUnzipServiceEnable: json['is_unzip_service_enable'] == true,
      );
}

// ------------------------------------------------ F5 / F6：NZB 日志与文件清单

/// `SYNO.DownloadStation2.Task.NZB.Log / get`（v1，normal）。
///
/// 官方前端 `ui/download.js` 的 NZB 日志面板逐字：
/// `{api:"SYNO.DownloadStation2.Task.NZB.Log", method:"get", version:1,
///   params:{task_id}}`，回包读 **`data.nzblog`**。
/// 真机只读实调（2026-09-22，NAS 0 任务）：缺参 → `120`（`task_id` required）；
/// `task_id=bogus` → `404`（任务不存在）。
class DsNzbLog {
  const DsNzbLog({this.log = ''});

  /// 服务端返回的日志正文（官方字段名 **`nzblog`**）。
  final String log;

  factory DsNzbLog.fromJson(Map<String, dynamic> json) => DsNzbLog(
    // 官方字段是 `nzblog`；`log`/`logs` 只是防御性别名（真机成功回包未取证）。
    log: _str(json['nzblog'] ?? json['log'] ?? json['logs']),
  );
}

/// `SYNO.DownloadStation2.Task.NZB.File / list`（v1，normal）里的一行。
///
/// 官方前端 store 逐字：`root:"items"`、`totalProperty:"total"`、
/// `fields:["name","size"]`、`paramNames:{start:"offset",limit:"limit"}`。
class DsNzbFile {
  const DsNzbFile({this.name = '', this.size = 0});

  final String name;
  final int size;

  factory DsNzbFile.fromJson(Map<String, dynamic> json) =>
      DsNzbFile(name: _str(json['name']), size: _int(json['size']));
}

/// `Task.NZB.File / list` 的一页（root `items` + `total`）。
class DsNzbFilePage {
  const DsNzbFilePage({this.items = const [], this.total = 0});

  final List<DsNzbFile> items;
  final int total;

  factory DsNzbFilePage.fromJson(Map<String, dynamic> json) {
    final raw = json['items'] ?? json['files'];
    return DsNzbFilePage(
      items: raw is List
          ? [
              for (final e in raw)
                if (e is Map) DsNzbFile.fromJson(Map<String, dynamic>.from(e)),
            ]
          : const [],
      total: _int(json['total']),
    );
  }
}

/// eMule **上传**条目（F1，`SYNO.DownloadStation2.Task.eMule / list_upload` v1）。
///
/// 官方 store 字段（`ui/download.js` 的 aMule UpperPanel 逐字）：
/// `id / client_name / file_name / upload_speed / size_uploaded / wait_time /
/// upload_time`，root `task`、totalProperty `total`、`paramNames:{offset,limit}`。
class DsEmuleUpload {
  const DsEmuleUpload({
    this.id = '',
    this.clientName = '',
    this.fileName = '',
    this.uploadSpeed = 0,
    this.sizeUploaded = 0,
    this.waitTime = 0,
    this.uploadTime = 0,
  });

  final String id;
  final String clientName;
  final String fileName;
  final int uploadSpeed;
  final int sizeUploaded;
  final int waitTime;
  final int uploadTime;

  factory DsEmuleUpload.fromJson(Map<String, dynamic> json) => DsEmuleUpload(
    id: _str(json['id']),
    clientName: _str(json['client_name']),
    fileName: _str(json['file_name']),
    uploadSpeed: _int(json['upload_speed']),
    sizeUploaded: _int(json['size_uploaded']),
    waitTime: _int(json['wait_time']),
    uploadTime: _int(json['upload_time']),
  );
}

/// `list_upload` 的一页（root `task`）。
class DsEmuleUploadPage {
  const DsEmuleUploadPage({
    this.items = const [],
    this.total = 0,
    this.offset = 0,
    this.limit = 0,
  });

  final List<DsEmuleUpload> items;
  final int total;
  final int offset;
  final int limit;

  factory DsEmuleUploadPage.fromJson(
    Map<String, dynamic> json, {
    int offset = 0,
    int limit = 0,
  }) {
    final raw = json['task'] ?? json['items'];
    return DsEmuleUploadPage(
      items: raw is List
          ? [
              for (final e in raw)
                if (e is Map)
                  DsEmuleUpload.fromJson(Map<String, dynamic>.from(e)),
            ]
          : const [],
      total: _int(json['total']),
      offset: offset,
      limit: limit,
    );
  }
}

/// eMule **搜索结果**（F3，`SYNO.DownloadStation2.eMule.Search / list` v1）。
///
/// 官方 store 字段逐字（`ui/download.js` 的 aMule `createStore`）：
/// `file_id / filename / file_size / source / completed_source / file_type /
/// file_has_downloaded`，root `results`、total `total`。
class DsEmuleSearchResult {
  const DsEmuleSearchResult({
    this.fileId = '',
    this.filename = '',
    this.fileSize = 0,
    this.source = 0,
    this.completedSource = 0,
    this.fileType = '',
    this.hasDownloaded = false,
  });

  final String fileId;
  final String filename;
  final int fileSize;
  final int source;
  final int completedSource;
  final String fileType;

  /// 官方用红色标出"已经下载过"的条目（`file_has_downloaded`）。
  final bool hasDownloaded;

  factory DsEmuleSearchResult.fromJson(Map<String, dynamic> json) {
    final raw = json['file_has_downloaded'];
    return DsEmuleSearchResult(
      fileId: _str(json['file_id']),
      filename: _str(json['filename']),
      fileSize: _int(json['file_size']),
      source: _int(json['source']),
      completedSource: _int(json['completed_source']),
      fileType: _str(json['file_type']),
      hasDownloaded: raw == true || raw == 1 || raw == '1' || raw == 'true',
    );
  }
}

/// `eMule.Search / list` 的一页；`searchDone` = 服务端 `search_done`。
class DsEmuleSearchPage {
  const DsEmuleSearchPage({
    this.results = const [],
    this.total = 0,
    this.searchDone = false,
    this.offset = 0,
    this.limit = 0,
  });

  final List<DsEmuleSearchResult> results;
  final int total;
  final bool searchDone;
  final int offset;
  final int limit;

  factory DsEmuleSearchPage.fromJson(
    Map<String, dynamic> json, {
    int offset = 0,
    int limit = 0,
  }) {
    final raw = json['results'] ?? json['items'];
    final done = json['search_done'];
    return DsEmuleSearchPage(
      results: raw is List
          ? [
              for (final e in raw)
                if (e is Map)
                  DsEmuleSearchResult.fromJson(Map<String, dynamic>.from(e)),
            ]
          : const [],
      total: _int(json['total']),
      searchDone: done == true || done == 1 || done == '1' || done == 'true',
      offset: offset,
      limit: limit,
    );
  }
}

/// eMule **服务器**条目（F2 管理员，`eMule.Server / list` v1）。
///
/// 官方 store 字段逐字：`id/ip/port/name/description/ping/user_count/
/// user_max/file_count`；root `results`、total `total`。
class DsEmuleServer {
  const DsEmuleServer({
    this.id = '',
    this.ip = '',
    this.port = 0,
    this.name = '',
    this.description = '',
    this.ping = 0,
    this.userCount = 0,
    this.userMax = 0,
    this.fileCount = 0,
  });

  final String id;
  final String ip;
  final int port;
  final String name;
  final String description;
  final int ping;
  final int userCount;
  final int userMax;
  final int fileCount;

  factory DsEmuleServer.fromJson(Map<String, dynamic> json) => DsEmuleServer(
    id: _str(json['id']),
    ip: _str(json['ip']),
    port: _int(json['port']),
    name: _str(json['name']),
    description: _str(json['description']),
    ping: _int(json['ping']),
    userCount: _int(json['user_count']),
    userMax: _int(json['user_max']),
    fileCount: _int(json['file_count']),
  );
}

class DsEmuleServerPage {
  const DsEmuleServerPage({
    this.items = const [],
    this.total = 0,
    this.offset = 0,
    this.limit = 0,
  });

  final List<DsEmuleServer> items;
  final int total;
  final int offset;
  final int limit;

  factory DsEmuleServerPage.fromJson(
    Map<String, dynamic> json, {
    int offset = 0,
    int limit = 0,
  }) {
    final raw = json['results'] ?? json['servers'];
    return DsEmuleServerPage(
      items: raw is List
          ? [
              for (final e in raw)
                if (e is Map)
                  DsEmuleServer.fromJson(Map<String, dynamic>.from(e)),
            ]
          : const [],
      total: _int(json['total']),
      offset: offset,
      limit: limit,
    );
  }
}

/// eMule/Kad 连接状态（`eMule.Server / get_status` v1）。
///
/// 官方把它们分别喂给 ED2K/Kad 两个控件（`gDataED2K.status`、`gDataKad.status`）。
/// 回包**形状没有穷举证据** ⇒ 宽容解析：既接受 `ed2k`/`kad` 子对象，
/// 也接受顶层 `ed2k_status`/`kad_status`；取不到就是空串（未知，不是"已断开"）。
class DsEmuleServerStatus {
  const DsEmuleServerStatus({
    this.ed2kStatus = '',
    this.kadStatus = '',
    this.ed2kIp = '',
    this.ed2kPort = 0,
  });

  final String ed2kStatus;
  final String kadStatus;
  final String ed2kIp;
  final int ed2kPort;

  factory DsEmuleServerStatus.fromJson(Map<String, dynamic> json) {
    final ed2k = json['ed2k'];
    final kad = json['kad'];
    final ed2kMap = ed2k is Map ? Map<String, dynamic>.from(ed2k) : null;
    final kadMap = kad is Map ? Map<String, dynamic>.from(kad) : null;
    return DsEmuleServerStatus(
      ed2kStatus: ed2kMap != null
          ? _str(ed2kMap['status'])
          : _str(json['ed2k_status']),
      kadStatus: kadMap != null
          ? _str(kadMap['status'])
          : _str(json['kad_status']),
      ed2kIp: ed2kMap != null ? _str(ed2kMap['ip']) : _str(json['ed2k_ip']),
      ed2kPort: ed2kMap != null
          ? _int(ed2kMap['port'])
          : _int(json['ed2k_port']),
    );
  }
}

int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

String _str(Object? v) {
  if (v == null) return '';
  if (v is String) return v;
  return '$v';
}
