// File Station 业务 API —— 在 [DsmWebApi] 之上把 `SYNO.FileStation.*` /
// `SYNO.FolderSharing.*` 收敛成强类型方法。
//
// ★ 方法与版本**逐一对照服务端权威表**：
//   docs/api-server-authoritative.md §2（FileStation 1.5.1-2410 的 webapi/*.lib）
//
//   权威表里 FileStation 的方法**分散在互不包含的版本里**（例如
//   `Sharing.list_share_me` 只在 v2+），所以每个方法都单独给候选版本，
//   交给 [negotiate] 收敛到服务器真正支持的最大版本 —— 与聊天模块同一套做法。
//
// 参数名出处（双向交叉验证）：
//   * 服务端：`SYNO.FileStation.List.so --preset params`
//     （`additional real_path owner time perm mount_point_type volume_status
//       indexed hybrid_share worm_share size description files count path`）
//   * 客户端：DSfile 4.17.2-609 `WebApiConnectionManager.java` 的调用点
//     （`folder_path` / `additional` / `offset` / `limit` / `sort_by` /
//      `sort_direction` / `filetype` / `onlywrite` / `force_clean` …）
library;

import 'dart:convert';
import 'dart:io';

import '../dsm/cgi_encryption.dart';
import '../core/net/traffic_meter.dart';
import '../dsm/webapi.dart';
import 'dto/file_entry_dto.dart';
import 'dto/file_mount_dto.dart';
import 'dto/file_photo_upload_dto.dart';
import 'dto/file_worm_dto.dart';

/// 宽松解析：数值或**数值字符串**都要认（DSM 在不同接口上两种都给过）。
int? parseIntOrNull(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

/// 上传同名冲突策略 —— **取值逐字来自官方 DS file 的 `OverWriteMode`**
/// （`com/synology/DSfile/util/data/OverWriteMode.java`）：
///
/// ```
/// RENAME    paramName = "rename"     isNeedOverwrite = null
/// OVERWRITE paramName = "overwrite"  isNeedOverwrite = true
/// SKIP      paramName = "skip"       isNeedOverwrite = false
/// NONE      paramName = ""           isNeedOverwrite = null
/// ```
///
/// 官方 `WebApiConnectionManager.getUploadOverwriteState()`：
/// * 服务端 `Upload` **maxVersion >= 3**（`isSupportUploadRename()`）→ 发
///   `overwrite=rename|skip|overwrite` 枚举串；
/// * 老服务端（v2）→ 发布尔串 `overwrite=true|false`（`isNeedOverwrite`）；
/// * `NONE`（没冲突）→ **整个字段都不发**。
///
/// 这是本批修「同名文件静默覆盖」的取值依据：默认（无冲突）与官方一致地
/// **不发** `overwrite`；一旦检测到冲突，必须显式选一个策略。
enum UploadConflictPolicy {
  overwrite,
  skip,
  rename;

  /// v3 起服务端认的枚举串
  String get v3Value => switch (this) {
    UploadConflictPolicy.overwrite => 'overwrite',
    UploadConflictPolicy.skip => 'skip',
    UploadConflictPolicy.rename => 'rename',
  };

  /// v2 服务端只认的布尔串（`OverWriteMode.isNeedOverwrite.toString()`）。
  ///
  /// `rename` 在 v2 上没有对应值（官方 `getOverwriteMsg()` 回空串 = 不发），
  /// 这里退化成 `false`（跳过）而不是不发 —— 宁可不上传也不能静默覆盖。
  String get legacyValue => switch (this) {
    UploadConflictPolicy.overwrite => 'true',
    UploadConflictPolicy.skip => 'false',
    UploadConflictPolicy.rename => 'false',
  };

  String valueFor(int version) => version >= 3 ? v3Value : legacyValue;
}

/// 搜索历史的两类（`SYNO.FileStation.Search.History` 的 `search_type`）。
///
/// 取值逐字来自官方 Web 端 `FileBrowser.js`：
/// `SYNO.FileStation.SearchHistoryPanel.search_type = "simple"`、
/// `SYNO.FileStation.AdvSearchHistoryPanel.search_type = "advance"`。
enum FileSearchHistoryType {
  /// 简单搜索面板的历史
  simple('simple'),

  /// 高级搜索面板的历史
  advance('advance');

  const FileSearchHistoryType(this.value);
  final String value;
}

/// `SYNO.FileStation.*` 的高层封装。**不持有传输** —— 传输由 [DsmWebApi] 管。
class FileStationApi {
  FileStationApi(DsmWebApi api) : api = api.withModule(TrafficModules.files);

  final DsmWebApi api;

  // ------------------------------------------------------------ 版本候选
  //
  // 权威表（FileStation 1.5.1-2410）：
  //   List               maxV2  v1/v2: list list_share getinfo
  //   Upload             maxV3  v2/v3: upload
  //   PhotoUpload        maxV3  v2/v3: upload
  //   Delete             maxV2  v1/v2: delete start status stop
  //   Rename             maxV2  v1/v2: rename
  //   CreateFolder       maxV2  v1/v2: create
  //   CopyMove/Compress  maxV3  v1..v3: start status stop
  //   Extract            maxV2  v1/v2: list start status stop
  //   DirSize/MD5        maxV2  v1/v2: start status stop
  //   CheckPermission    maxV3  v1..v3: write
  //   CheckExist         maxV2  v1/v2: check
  //   BackgroundTask     maxV3  v1..v3: list clear_finished
  //   Search             maxV2  v1/v2: start list stop clean
  //   Favorite           maxV2  v1/v2: add delete edit list replace_all clear_broken
  //   VirtualFolder      maxV2  v1/v2: list
  //   Sharing            maxV3  v1: … ｜ v2+: + list_share_me
  //   Thumb              maxV3  v1..v3: get
  //   Download           maxV2  v1/v2: download
  //   DirSize/Property   maxV1  v1
  //   FolderSharing.*    maxV2  v1/v2
  //
  //   Worm               maxV2（**但方法只在 v1**）v1: get get_share_info
  //     ⚠️ `SYNO.FileStation.lib` 里 `Worm` 的 methods **只在 "1" 段**，
  //     v2 段是空的 ⇒ 真机 v2 恒 `103` ⇒ 一律钉 v1（[_v1]）。
  //   Worm.Lock          maxV2（admin-only，allowUser 只有 admin.*）—— 本批不做。
  //   PhotoUpload        minV2（没有 v1）v2/v3: upload（见 [photoUpload]）。

  static const List<int> _v1 = [1];
  static const List<int> _v2 = [2, 1];
  static const List<int> _v3 = [3, 2, 1];

  /// `Sharing.list_share_me` 专用候选：**优先 v3，回落 v2，绝不发 v1**。
  ///
  /// 真机逐版本扫描（DSM 7.x / DS923+）：v1 = **103**（方法不存在）、
  /// v2 = OK、v3 = OK。所以候选里放 `1` 会让 v1-only 的服务端拿到
  /// `negotiate` 的"退到 minVersion"回落 → 发 v1 → 必 103。
  ///
  /// **为什么优先 v3**：官方 Web 前端 `FileBrowser.js`
  /// （`SharingManager.Common.createStore`）里写的正是
  /// `{api:"SYNO.FileStation.Sharing", method:…, version:3}` ——
  /// 按"与官方形态逐字对齐"的要求，先 v3 再 v2（两者真机都验过）。
  /// 只有 v1 的服务器由能力位 [FileCapabilities.canShareWithMe] 在上层
  /// **隐藏入口**，不会走到这里。
  static const List<int> _shareWithMeVersions = [3, 2];

  /// 候选版本里挑一个服务器真正支持的（与 `ChatApi.negotiate` 同规则）。
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

  /// `additional` 的**编码随接口版本而变** —— 真机逐版本实测（本会话，
  /// DSM 7.x / DS923+，同一接口同一路径，只改编码；逐字回包见
  /// `docs/filestation-worm-photoupload-wave.md` §3）：
  ///
  /// | 发法 | `List:list` **v1** | `List:list` **v2** |
  /// |---|---|---|
  /// | `["size","time"]`（JSON 数组） | ❌ **502 + 11939 字节 HTML 错误页** | ✅ `additional` 齐全 |
  /// | `size,time`（逗号分隔） | ✅ `additional` 齐全 | ⚠️ **200 但整块 `additional` 缺失**（静默忽略） |
  /// | `size`（单值裸串） | ✅ | ✅ |
  /// | `additional=size&additional=time`（重复字段） | ⚠️ 只认最后一个 | ⚠️ 只认最后一个 |
  ///
  /// ⇒ **v1 拒 JSON 数组**（回的不是错误码，是一张 HTML 页面，排查极痛苦）；
  /// ⇒ **v2 收逗号但"收而不认"**：不报错，却把 `additional` 整个丢掉
  ///   —— `size`/`time`/`owner`/`perm` 全缺，表现成"大小 0、时间空白"
  ///   （与"什么都不发"逐字同形）。**这不是失败装空态，而是空态装成功**，
  ///   所以**不能**"统一发逗号分隔"：那会在 v2 上静默丢字段。
  /// ⇒ 六个调用点（`list` / `list_share` / `getinfo` / `VirtualFolder:list` /
  ///   `Favorite:list` / `Search:list`）**逐个真机验过**，全是同一个规律；
  ///   所以这里按**协商到的版本**分别编码，而不是一刀切。
  ///
  /// 另一个已订正的事实（`docs/live-write-verification.md` §4#1/#2，写入批次真机）：
  /// `additional` **不是"必须"是某个特定形态**才能成功 —— 单值裸值两版都收
  /// （服务端宽容）。但**多值**只有上表这两种各自可用的形态。
  /// `additional` 参数的编码（★ 规则来自官方客户端，不是我们编的）。
  ///
  /// 官方《DS file》4.17.2 smali `WebApiConnectionManager.createNameValuePairs`：
  /// 按 `Api.isRequestFormatJson()`（= `requestFormat == "JSON"`）**二选一** ——
  /// JSON 格式的 API 一律 `getJsonEncodeValue()`（如 `["partitions"]`），
  /// 其余才走 `getValue()` 逗号分隔（如 `partitions`），**与版本无关**。
  ///
  /// 所以判据是「**这条 API 在 `SYNO.API.Info` 里声明的 `requestFormat`**」，
  /// 版本号只在**非** JSON 的 API 上继续区分 v1 逗号 / v2 JSON 数组。
  /// 表里查不到（未登录 / 老服务器没这个字段）⇒ 按表单处理，与改前一致。
  String _additional(String apiName, int version, List<String> values) {
    final list = values.isEmpty ? FileAdditional.light : values;
    final jsonFormat = api.apiTable?[apiName]?.isJsonFormat ?? false;
    return (jsonFormat || version > 1) ? jsonEncode(list) : list.join(',');
  }

  /// 服务器是否支持某 API 的某版本（`minVersion <= v <= maxVersion`）
  bool supports(String apiName, int version) {
    final entry = api.apiTable?[apiName];
    if (entry == null) return false;
    return version >= entry.minVersion && version <= entry.maxVersion;
  }

  /// 普通用户能用的能力探测：服务器**根本没有**这个 API 时返回 false。
  ///
  /// `apiTable` 是 `SYNO.API.Info` 实测结果，未登录时可能为空
  /// —— 这种情况按"未知"处理（返回 true，交给调用时的错误兜底）。
  bool hasApi(String apiName) {
    final table = api.apiTable;
    if (table == null) return true;
    return table.containsKey(apiName);
  }

  // ------------------------------------------------------------ 浏览

  /// `SYNO.FileStation.List / list` —— 列目录。
  ///
  /// 官方 `getFiles(folderPath, offset, limit, sortBy, sortDirection)` 的
  /// `additional` 是 `{size, time, mount_point_type, worm_share}`；
  /// 我们额外要 `owner`/`perm`（用于属性页与"能不能下载"），
  /// 服务端 `List.so` 里这些键都在白名单内。
  ///
  /// ⚠️ 普通用户对**根目录 `/`** 会拿到 `105/401`（权限不足）；
  /// 上层要做权限降级（见 docs 里的实测记录），别当成致命错误。
  Future<FileListResult> listFolder({
    required String folderPath,
    int offset = 0,
    int limit = 0,
    FileSortBy sortBy = FileSortBy.name,
    FileSortDirection sortDirection = FileSortDirection.asc,
    String filetype = 'all',
    List<String> additional = FileAdditional.browse,
  }) async {
    final version = negotiate('SYNO.FileStation.List', _v2);
    final data = await api.call(
      'SYNO.FileStation.List',
      'list',
      preferredVersion: version,
      params: {
        'folder_path': folderPath,
        'additional': _additional(
          'SYNO.FileStation.List',
          version,
          additional,
        ),
        'offset': offset,
        'limit': limit,
        'sort_by': sortBy.value,
        'sort_direction': sortDirection.value,
        'filetype': filetype,
      },
    );
    return FileListResult.fromJson(data);
  }

  /// `SYNO.FileStation.List / list_share` —— 列共享文件夹（普通用户看到的"根"）。
  ///
  /// 官方 `getShares` 的 `additional` 是 `{perm, worm_share}`，带 `onlywrite`。
  Future<FileListResult> listShares({
    int offset = 0,
    int limit = 0,
    FileSortBy sortBy = FileSortBy.name,
    FileSortDirection sortDirection = FileSortDirection.asc,
    bool onlyWrite = false,
  }) async {
    final version = negotiate('SYNO.FileStation.List', _v2);
    final data = await api.call(
      'SYNO.FileStation.List',
      'list_share',
      preferredVersion: version,
      params: {
        'onlywrite': onlyWrite,
        'offset': offset,
        'limit': limit,
        'sort_by': sortBy.value,
        'sort_direction': sortDirection.value,
        'additional': _additional('SYNO.FileStation.List', version, const [
          FileAdditional.perm,
          FileAdditional.wormShare,
        ]),
      },
    );
    return FileListResult.fromJson(data);
  }

  /// `SYNO.FileStation.List / getinfo` —— 取单个路径的详情（官方 `getInfo`）。
  Future<FileEntryDto> getInfo(String path) async {
    final version = negotiate('SYNO.FileStation.List', _v2);
    final data = await api.call(
      'SYNO.FileStation.List',
      'getinfo',
      preferredVersion: version,
      params: {
        'path': path,
        // getinfo 的 additional 也要显式点单：真机只认 JSON 串里的这些键，
        // 漏了 `size` 就会拿到 0（P0 上传后校验大小时踩过）。
        'additional': _additional('SYNO.FileStation.List', version, const [
          ...FileAdditional.browse,
          FileAdditional.realPath,
        ]),
      },
    );
    // 返回 `{files: [...]}`，正常只有一项
    final result = FileListResult.fromJson(data);
    if (result.entries.isEmpty) {
      return FileEntryDto(name: path.split('/').last, path: path);
    }
    return result.entries.first;
  }

  /// `SYNO.FileStation.VirtualFolder / list` —— 虚拟目录（挂载的远程/ISO）。
  ///
  /// `type`：`cifs` / `iso` / …；**留空表示"全部"**。
  ///
  /// ⚠️ 真机实测（DSM 7.4 / DS923+）：`type=all` 会被判 **101 参数无效**；
  /// 它要的是 JSON 数组（`type=["cifs"]`）。所以这里：空列表 → 干脆不发这个参数。
  ///
  /// [bareType] = true 时发**裸字符串**（不是 JSON 数组）。这是官方前端对
  /// `fm_vd_root`（虚拟设备/ISO 根）的原文形态：
  /// `FileBrowserUtil.js` 里 `baseParams.type="iso"`，而对 `fm_rf_root`
  /// （远端卷根）才是 `baseParams.type=["cifs","nfs"]`（数组）。
  /// 缺省 false 保持既有形状不变。
  Future<FileListResult> listVirtualFolders({
    List<String> type = const [],
    bool bareType = false,
    int offset = 0,
    int limit = 0,
    FileSortBy sortBy = FileSortBy.name,
    FileSortDirection sortDirection = FileSortDirection.asc,
  }) async {
    final version = negotiate('SYNO.FileStation.VirtualFolder', _v2);
    final data = await api.call(
      'SYNO.FileStation.VirtualFolder',
      'list',
      preferredVersion: version,
      params: {
        if (type.isNotEmpty)
          'type': bareType && type.length == 1 ? type.single : jsonEncode(type),
        'offset': offset,
        'limit': limit,
        'sort_by': sortBy.value,
        'sort_direction': sortDirection.value,
        'additional': _additional(
          'SYNO.FileStation.VirtualFolder',
          version,
          FileAdditional.light,
        ),
      },
    );
    return FileListResult.fromJson(data);
  }

  // ------------------------------------------------ C5 远程挂载 / 虚拟卷
  //
  // 权威注册表（`/tmp/spk/export_FileStation/webapi/SYNO.FileStation.lib`，# 编号即行：
  // `SYNO.FileStation.Mount` v1 {mount_iso, mount_remote, unmount}，
  // `SYNO.FileStation.Mount.List` v1 {get, unmount, reconnect, remount}；
  // 两者 allowUser **均含 normal.***）。
  //
  // 参数逐字来自**服务端自带官方前端** `ui/file_browser/FileBrowser.js`
  // （该文件随 FileStation 包发布，就是 DSM 网页端本身）：
  //
  // ```js
  // // 新增 CIFS（FileAction.onMountRemote）
  // i = {mount_type:e.getMountType(), server_ip:e.getServerIP(), mount_point:o,
  //      user_set:l, auto_mount:e.getAutoMnt()}
  // "CIFS"===a && Ext.apply(i, {account:e.getAccount(), passwd:e.getPasswd()})
  // // 新增 ISO（FileAction.onMountISO）
  // {api:"SYNO.FileStation.Mount", method:"mount_iso",
  //  params:{source:s, mount_point:r, auto_mount:a, user_set:h}}
  // // 单个卸载（FileAction.Umount）
  // {api:"SYNO.FileStation.Mount", method:"unmount",
  //  params:{mount_type:o, is_mount_point:n||!0, mount_point:i}}
  // // 列表 / 批量卸载 / 重连 / 重挂（MountListDialog / MountGrid）
  // {api:"SYNO.FileStation.Mount.List", version:1, method:"get"}
  // {method:"unmount",   params:{mount_point:[...]}}
  // {method:"reconnect", params:{mount_point:[...]}}
  // {method:"remount",   params:{mount_type:<"iso"|"remote">}}
  // ```
  //
  // ⚠️ **只有 cifs + iso**（审计 §7.5 C3 复核）：官方 DS file 4.17.2-609 的
  // dex 里 `mount_remote`/`mount_iso`/`FileStation.Mount` **0 命中**，只有
  // `VIRTUAL_CIFS_PATH` / `VIRTUAL_ISO_PATH` 两个哨兵；NFS 主客户端不暴露、
  // WebDAV 官方自己标了废弃（`WebDavConnectionManager.java:39,86`）→ 本批不做。
  //
  // ⚠️ **凭据是明文 `account` / `passwd`**：官方前端把表单值直接放进 params，
  // 没有 `cipherkey`/`ciphertoken`；服务端记录类是
  // `IdentRecord::setPlainPasswd`（`SYNO.FileStation.Mount.so` 字符串）。
  // 所以默认按原文发明文；需要 CGI 加密的部署可以传 [credentialCipher]
  // （复用 `cgi_encryption.dart` 的 `DsmCgiEncryption`，**不改它**）。

  /// `SYNO.FileStation.Mount.List / get` —— 已挂载的 ISO / CIFS 卷 + 服务器
  /// 允不允许挂载（`mountConfig.enable_iso_mount` / `enable_remote_mount`）。
  Future<FileMountList> listMounts() async {
    final data = await api.call(
      'SYNO.FileStation.Mount.List',
      'get',
      preferredVersion: negotiate('SYNO.FileStation.Mount.List', _v1),
    );
    return FileMountList.fromJson(data);
  }

  /// `SYNO.FileStation.Mount / mount_remote` —— 新增一个 CIFS 挂载。
  ///
  /// [serverIp] 官方形态是 `\\192.168.1.1\Share`（`MountCIFS` 的 tip 原文），
  /// 验签正则 `^(//|\\\\)([^/\\]*)[/\\]?(.*)`；[mountPoint] 是挂载点目录。
  /// [userSet] = 用户在目标选择器里**显式点过**目录（`mntPointUserSet`）。
  ///
  /// [credentialCipher] 非空时只把 `account`/`passwd` 换成 `cipherkey`
  /// （与登录同一条 CGI 加密链）；为空则按官方原文发明文两字段。
  Future<void> mountCifs({
    required String serverIp,
    required String mountPoint,
    required bool userSet,
    String account = '',
    String password = '',
    bool autoMount = false,
    DsmCgiEncryption? credentialCipher,
  }) async {
    final credentials = credentialCipher == null
        ? <String, dynamic>{'account': account, 'passwd': password}
        : credentialCipher.encryptFromParamList({
            'account': account,
            'passwd': password,
          });
    await api.call(
      'SYNO.FileStation.Mount',
      'mount_remote',
      preferredVersion: negotiate('SYNO.FileStation.Mount', _v1),
      params: {
        'mount_type': FileMountType.cifs.wireValue, // 原文 "CIFS"
        'server_ip': serverIp,
        'mount_point': mountPoint,
        'user_set': userSet,
        'auto_mount': autoMount,
        ...credentials,
      },
    );
  }

  /// `SYNO.FileStation.Mount / mount_iso` —— 把一个 `.iso` 镜像挂成只读卷。
  ///
  /// [source] = ISO 文件的**路径**（`getSource()` = 表单隐藏字段 `source`，
  /// 由 `setSource(real_path)` 填）；`auto_mount` 是复选值（布尔）。
  Future<void> mountIso({
    required String source,
    required String mountPoint,
    required bool userSet,
    bool autoMount = false,
  }) async {
    await api.call(
      'SYNO.FileStation.Mount',
      'mount_iso',
      preferredVersion: negotiate('SYNO.FileStation.Mount', _v1),
      params: {
        'source': source,
        'mount_point': mountPoint,
        'auto_mount': autoMount,
        'user_set': userSet,
      },
    );
  }

  /// `SYNO.FileStation.Mount / unmount` —— 从文件列表卸载**单个**挂载点。
  ///
  /// [mountType] 用 `List` 的 `mount_point_type`（`iso` / `remote`），
  /// 不是 `mount_remote` 那个大写 `CIFS`（见 [FileMountType.volumeValue]）。
  /// [isMountPoint] 原文是 `e.get("isMountPoint")`，缺省按 `true`。
  Future<void> unmountVolume({
    required String mountType,
    required String mountPoint,
    bool isMountPoint = true,
  }) async {
    await api.call(
      'SYNO.FileStation.Mount',
      'unmount',
      preferredVersion: negotiate('SYNO.FileStation.Mount', _v1),
      params: {
        'mount_type': mountType,
        'is_mount_point': isMountPoint,
        'mount_point': mountPoint,
      },
    );
  }

  /// `SYNO.FileStation.Mount.List / unmount` —— 挂载管理页的批量卸载。
  /// `mount_point` 是**JSON 数组串**（官方 `params:{mount_point:e}`，e 是数组）。
  Future<void> unmountMounts(List<String> mountPoints) async {
    await api.call(
      'SYNO.FileStation.Mount.List',
      'unmount',
      preferredVersion: negotiate('SYNO.FileStation.Mount.List', _v1),
      params: {'mount_point': jsonEncode(mountPoints)},
    );
  }

  /// `SYNO.FileStation.Mount.List / reconnect` —— 重连远端卷（CIFS）。
  Future<void> reconnectMounts(List<String> mountPoints) async {
    await api.call(
      'SYNO.FileStation.Mount.List',
      'reconnect',
      preferredVersion: negotiate('SYNO.FileStation.Mount.List', _v1),
      params: {'mount_point': jsonEncode(mountPoints)},
    );
  }

  /// `SYNO.FileStation.Mount.List / remount` —— 重挂某类型的所有卷。
  /// [mountType] 是 `iso` / `remote`（原文为活动页 `itemId`）。
  Future<void> remountAll(String mountType) async {
    await api.call(
      'SYNO.FileStation.Mount.List',
      'remount',
      preferredVersion: negotiate('SYNO.FileStation.Mount.List', _v1),
      params: {'mount_type': mountType},
    );
  }

  /// `SYNO.FileStation.Favorite / list` —— 收藏夹。
  ///
  /// 官方 `getFavoriteList`：`status_filter='all'` + `additional={real_path,time}`。
  Future<FileListResult> listFavorites({
    int offset = 0,
    int limit = 0,
    String statusFilter = 'all',
  }) async {
    final version = negotiate('SYNO.FileStation.Favorite', _v2);
    final data = await api.call(
      'SYNO.FileStation.Favorite',
      'list',
      preferredVersion: version,
      params: {
        'offset': offset,
        'limit': limit,
        'status_filter': statusFilter,
        'additional': _additional(
          'SYNO.FileStation.Favorite',
          version,
          FileAdditional.light,
        ),
      },
    );
    return FileListResult.fromJson(data);
  }

  /// `SYNO.FileStation.Favorite / add`
  ///
  /// ⚠️ `name` 得**发**（真机漏传直接 400）：不指定就用路径最后一段当名字。
  Future<void> addFavorite(String path, {String? name}) async {
    final label = (name == null || name.isEmpty)
        ? (path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path)
        : name;
    await api.call(
      'SYNO.FileStation.Favorite',
      'add',
      preferredVersion: negotiate('SYNO.FileStation.Favorite', _v2),
      params: {'path': path, 'name': label},
    );
  }

  /// `SYNO.FileStation.Favorite / delete`
  Future<void> deleteFavorite(String path) async {
    await api.call(
      'SYNO.FileStation.Favorite',
      'delete',
      preferredVersion: negotiate('SYNO.FileStation.Favorite', _v2),
      params: {
        'path': FileEntryDto.encodePaths([path]),
      },
    );
  }

  /// `SYNO.FileStation.Favorite / edit` —— 改收藏的显示名（P1-7）。
  ///
  /// 原文来自官方 Web 端 `ui/file_browser/FileBrowser.js` 的收藏重命名对话框
  /// `onAction`：`params = Ext.apply({name:<新名>, path:<收藏路径>, index:-1},
  /// this.getParams())`，且 `blRename ? "edit" : "add"`、`version: 2`。
  /// `index` 是同一父节点内的排序位（对话框固定发 -1 = 不变）。
  Future<void> editFavorite(
    String path, {
    required String name,
    int index = -1,
  }) async {
    await api.call(
      'SYNO.FileStation.Favorite',
      'edit',
      preferredVersion: negotiate('SYNO.FileStation.Favorite', _v2),
      params: {'name': name, 'path': path, 'index': index},
    );
  }

  /// `SYNO.FileStation.Favorite / clear_broken` —— 清掉已失效的收藏（P1-7）。
  ///
  /// 原文：`ui/file_browser/FileBrowser.js` 的 `CleanFav`
  /// `{api:"SYNO.FileStation.Favorite", method:"clear_broken", version:2}`，
  /// **没有任何参数**。
  Future<void> clearBrokenFavorites() async {
    await api.call(
      'SYNO.FileStation.Favorite',
      'clear_broken',
      preferredVersion: negotiate('SYNO.FileStation.Favorite', _v2),
    );
  }

  // ------------------------------------------------------------ 写操作

  /// `SYNO.FileStation.CreateFolder / create`（官方 `createFolder`）。
  Future<FileListResult> createFolder({
    required String folderPath,
    required String name,
    bool forceParent = true,
  }) async {
    final data = await api.call(
      'SYNO.FileStation.CreateFolder',
      'create',
      preferredVersion: negotiate('SYNO.FileStation.CreateFolder', _v2),
      params: {
        'folder_path': folderPath,
        'name': name,
        'force_parent': forceParent,
      },
    );
    return FileListResult.fromJson(data);
  }

  /// `SYNO.FileStation.Rename / rename`（官方 `rename`）。
  Future<void> rename({required String path, required String name}) async {
    await api.call(
      'SYNO.FileStation.Rename',
      'rename',
      preferredVersion: negotiate('SYNO.FileStation.Rename', _v2),
      params: {
        'path': FileEntryDto.encodePaths([path]),
        'name': FileEntryDto.encodePaths([name]),
      },
    );
  }

  /// `SYNO.FileStation.Delete / start` —— **删除到回收站**（官方 `deleteFiles`
  /// 唯一用法）。
  ///
  /// 证据（官方 DS file 4.17.2-609）：
  /// `WebApiConnectionManager.delete(path, search_taskid)` →
  /// `doWebApiQuery(SYNO_FILESTATION_DELETE, "start", …)`，参数
  /// `path`（JSON 数组）+ `accurate_progress=true` + `recursive=true`；
  /// 返回 `taskid`。`SYNO.FileStation.Delete.so` 里链接了
  /// `libsynorecycle.so.7`（`SYNORecycleUnlinkFileWithSharePath` /
  /// `SYNORecycleRmDirWithSharePath`），即删除走回收站语义。
  ///
  /// ⚠️ 本批把它从原来的 `delete`（同步）改成 `start`：`delete` 是**不进任务、
  /// 直接落盘**的那一支，用它删除会让回收站永远为空、回收站浏览形同虚设。
  /// 回收站内条目的「永久删除」才走 [deletePermanently]。
  Future<FileTaskStart> deleteItems(
    List<String> paths, {
    bool recursive = true,
  }) async {
    final data = await api.call(
      'SYNO.FileStation.Delete',
      'start',
      preferredVersion: negotiate('SYNO.FileStation.Delete', _v2),
      params: {
        'path': FileEntryDto.encodePaths(paths),
        'accurate_progress': true,
        'recursive': recursive,
      },
    );
    return FileTaskStart.fromJson(data);
  }

  /// `SYNO.FileStation.Delete / delete` —— **永久删除**（同步，不入回收站）。
  ///
  /// 只给回收站内的条目用（`#recycle` 下的路径本来就已经在回收站里，再删就是
  /// 永久移除）。见 `[K]` 注册表：`Delete` 的 v1/v2 方法组里 `delete` 与
  /// `start` 并列存在（`start` 是官方 APK 用的那一支）。
  ///
  /// ⚠️ 需要真机验证「`delete` 是否真的绕过回收站」—— 目前证据是
  /// 注册表存在该方法 + 审计判定；但即便它仍走回收站逻辑，对已经在
  /// `#recycle` 里的路径也是移除，用户可见语义仍是"永久删除"。
  Future<void> deletePermanently(
    List<String> paths, {
    bool recursive = true,
  }) async {
    await api.call(
      'SYNO.FileStation.Delete',
      'delete',
      preferredVersion: negotiate('SYNO.FileStation.Delete', _v2),
      params: {'path': FileEntryDto.encodePaths(paths), 'recursive': recursive},
    );
  }

  /// `SYNO.FileStation.CopyMove / start` + `restore_from_recycle_bin` ——
  /// **从回收站还原**。
  ///
  /// 证据（服务端官方前端 `ui/file_browser/RecycleBin.js` 的
  /// `SYNO.SDS.RecycleBin.Restore.FBExt.doRestore`）：
  ///
  /// ```js
  /// requestAPI({api:"SYNO.FileStation.CopyMove", method:"start", version:3,
  ///   params:{remove_src:true, overwrite:r, restore_from_recycle_bin:true,
  ///           dest_folder_path:a, accurate_progress:true, path:t}})
  /// ```
  ///
  /// `restore_from_recycle_bin` 在 `SYNO.FileStation.CopyMove.so` 字符串里可证。
  /// 目标位置 `a` = 源路径**去掉 `#recycle` 这一段**（`RecycleBin.js` 先 pop 掉
  /// 文件名、再 splice 掉 `#recycle`、join）。
  Future<FileTaskStart> restoreFromRecycleBin({
    required List<String> paths,
    required String destFolderPath,
    bool overwrite = false,
    bool accurateProgress = true,
  }) async {
    final data = await api.call(
      'SYNO.FileStation.CopyMove',
      'start',
      preferredVersion: negotiate('SYNO.FileStation.CopyMove', _v3),
      params: {
        'path': FileEntryDto.encodePaths(paths),
        'dest_folder_path': destFolderPath,
        'remove_src': true,
        'overwrite': overwrite,
        'restore_from_recycle_bin': true,
        'accurate_progress': accurateProgress,
      },
    );
    return FileTaskStart.fromJson(data);
  }

  /// `SYNO.Core.RecycleBin / start` —— **清空共享文件夹的回收站**（不可恢复）。
  ///
  /// 证据（`ui/file_browser/RecycleBin.js` 的
  /// `SYNO.SDS.RecycleBin.Cleaner.FBExt.doCleanRecycleBin`）：
  /// `SYNO.API.Request({api:"SYNO.Core.RecycleBin", method:"start", version:1,
  /// params:{id:<共享文件夹名>}})`；`checkFn` 里 `_S("is_admin")` 才放行
  /// —— 与 `[K]` 注册表一致（`allowUser` 仅 `admin.*`）。
  ///
  /// 因此调用方必须先用 [isManager] 门控；普通用户调用会被服务端拒绝。
  Future<void> purgeRecycleBin(String shareName) async {
    await api.call(
      'SYNO.Core.RecycleBin',
      'start',
      preferredVersion: negotiate('SYNO.Core.RecycleBin', const [1]),
      params: {'id': shareName},
    );
  }

  /// `SYNO.FileStation.CopyMove / start` —— 复制 / 移动，返回任务号。
  ///
  /// [removeSrc] = true 即"移动"（官方 `copyMoveFile` 的 `remove_src`）。
  Future<FileTaskStart> startCopyMove({
    required List<String> paths,
    required String destFolderPath,
    bool removeSrc = false,
    String? destFileName,
    bool overwrite = false,
    bool accurateProgress = true,
  }) async {
    final data = await api.call(
      'SYNO.FileStation.CopyMove',
      'start',
      preferredVersion: negotiate('SYNO.FileStation.CopyMove', _v3),
      params: {
        'path': FileEntryDto.encodePaths(paths),
        'dest_folder_path': destFolderPath,
        'dest_file_path': ?destFileName,
        'remove_src': removeSrc,
        'overwrite': overwrite,
        'accurate_progress': accurateProgress,
      },
    );
    return FileTaskStart.fromJson(data);
  }

  /// `SYNO.FileStation.Compress / start` —— 压缩，返回任务号。
  Future<FileTaskStart> startCompress({
    required List<String> paths,
    required String destFilePath,
    String format = 'zip',
    String level = 'normal',
    // ⚠️ `mode` 官方是**每次都发**的（`.so` 里认 `update`/`freshen`/
    // `synchronize`，默认档 = 添加/替换，服务端**没有名字**）。早先默认给空串
    // 等于不发 → 服务端 101。
    //
    // 默认档的线上值取官方 APK 的 `replace`（`archive_update_mode_key[0]`）。
    // 见 `CompressMode` 的裁决表 —— 注意官方 APK 的同步档是拼写错误的
    // `synchroize`，本仓**不照抄那个错**。
    String mode = 'replace',
    String? password,
  }) async {
    final data = await api.call(
      'SYNO.FileStation.Compress',
      'start',
      preferredVersion: negotiate('SYNO.FileStation.Compress', _v3),
      params: {
        'path': FileEntryDto.encodePaths(paths),
        'dest_file_path': destFilePath,
        'format': format,
        'level': level,
        'mode': mode,
        if (password != null && password.isNotEmpty) 'password': password,
      },
    );
    return FileTaskStart.fromJson(data);
  }

  /// `SYNO.FileStation.Extract / start` —— 解压，返回任务号。
  ///
  /// ⚠️ **目标目录必须已存在**：传一个不存在的 `dest_folder_path` 服务端回
  /// **408**（= 路径不存在，真机实测）。408 不属于"参数错"，很容易被误判成
  /// 权限问题 —— 客户端调用前请确保目录已在（浏览页传的就是当前目录）。
  /// `codepage` 可发可不发（`utf8`/`chs`/`enu` 实测都能解），不发就用服务端默认。
  Future<FileTaskStart> startExtract({
    required String filePath,
    required String destFolderPath,
    String? codepage,
    String? password,
    bool keepDir = true,
    bool overwrite = false,
    bool createSubfolder = false,
  }) async {
    final data = await api.call(
      'SYNO.FileStation.Extract',
      'start',
      preferredVersion: negotiate('SYNO.FileStation.Extract', _v2),
      params: {
        'file_path': filePath,
        'dest_folder_path': destFolderPath,
        if (password != null && password.isNotEmpty) 'password': password,
        if (codepage != null && codepage.isNotEmpty) 'codepage': codepage,
        'keep_dir': keepDir,
        'overwrite': overwrite,
        'create_subfolder': createSubfolder,
      },
    );
    return FileTaskStart.fromJson(data);
  }

  /// `SYNO.FileStation.Extract / list` —— 不解压先看压缩包里有什么。
  Future<FileListResult> listArchive({
    required String filePath,
    String? password,
    String? codepage,
  }) async {
    final data = await api.call(
      'SYNO.FileStation.Extract',
      'list',
      preferredVersion: negotiate('SYNO.FileStation.Extract', _v2),
      params: {
        'file_path': filePath,
        if (password != null && password.isNotEmpty) 'password': password,
        if (codepage != null && codepage.isNotEmpty) 'codepage': codepage,
      },
    );
    return FileListResult.fromJson(data);
  }

  /// `SYNO.FileStation.DirSize / start` —— 统计目录大小（异步任务）。
  Future<FileDirSizeStart> startDirSize(List<String> paths) async {
    final data = await api.call(
      'SYNO.FileStation.DirSize',
      'start',
      preferredVersion: negotiate('SYNO.FileStation.DirSize', _v2),
      params: {'path': FileEntryDto.encodePaths(paths)},
    );
    return FileDirSizeStart.fromJson(data);
  }

  /// `SYNO.FileStation.CheckPermission / write` —— 能不能写（用于提前禁用按钮）。
  /// `SYNO.FileStation.CheckPermission / write` —— 往 [folderPath] 里写
  /// [filename] **允不允许**。
  ///
  /// 真机实测（DSM 7.4 / DS923+，普通用户）：
  ///   * 可写目录 + `filename` → `{blSkip:false}`（**没有** `is_writable` 字段）；
  ///   * 只读共享（`/docker`）→ `401`；
  ///   * **漏传 `filename` → 401，哪怕目录明显可写**（刚在里面建过目录也一样）。
  ///     所以 `filename` 是必填，缺了会给出假阴性。
  /// 结论：判据是**调用成功**；`blSkip` 只是"是否需要弹确认框"。
  /// 401 原样抛出（`describeFileError` 翻成"没有权限访问该位置"）。
  Future<FileWritePermission> checkWritePermission(
    String folderPath, {
    required String filename,
  }) async {
    final data = await api.call(
      'SYNO.FileStation.CheckPermission',
      'write',
      preferredVersion: negotiate('SYNO.FileStation.CheckPermission', _v3),
      params: {'path': folderPath, 'filename': filename},
    );
    return FileWritePermission.fromJson(data, callSucceeded: true);
  }

  /// `SYNO.FileStation.CheckExist / check` —— 目标是否已存在（重命名/新建前查重）。
  Future<bool> exists(String path) async {
    final data = await api.call(
      'SYNO.FileStation.CheckExist',
      'check',
      preferredVersion: negotiate('SYNO.FileStation.CheckExist', _v2),
      params: {'path': path},
    );
    return data['exist'] == true;
  }

  // ------------------------------------------------------------ 任务中心

  /// `SYNO.FileStation.BackgroundTask / list`
  ///
  /// ⚠️ 服务端**只有** `list` / `clear_finished` 两个方法（权威表实测）；
  /// APK 里出现的 `clear_broken` 属于 `Favorite`，不属于这里。
  Future<FileTaskListResult> listBackgroundTasks({
    int offset = 0,
    int limit = 1000,
    String sortBy = 'crtime',
    FileSortDirection sortDirection = FileSortDirection.desc,
  }) async {
    final data = await api.call(
      'SYNO.FileStation.BackgroundTask',
      'list',
      preferredVersion: negotiate('SYNO.FileStation.BackgroundTask', _v3),
      params: {
        'offset': offset,
        'limit': limit,
        'sort_by': sortBy,
        'sort_direction': sortDirection.value,
      },
    );
    return FileTaskListResult.fromJson(data);
  }

  /// `SYNO.FileStation.Timeout / avoid` v1 —— **长任务期间给会话保活**。
  ///
  /// ## 为什么需要它
  /// NAS 的空闲超时是真机实测的 **15 分钟**（`SYNO.Core.Desktop.Timeout.get`
  /// → `{"timeout":15}`）。而压缩 / 解压 / MD5 / 目录大小这类**后台任务**可以
  /// 跑十几分钟 —— 用户把 App 放一边等，回来就发现会话没了、任务进度也读不到。
  /// 官方 File Station 的**Web 前端**在长任务期间就是靠这个方法续命的
  /// （DSM 里这个方法存在且真的生效，真机只读探针 `{"success":true}`）。
  ///
  /// ## 权威性
  /// * `.lib`：`SYNO.FileStation.Timeout` v1，方法只有 `avoid`
  ///   （权威表：`v1: avoid`）；
  /// * 真机只读探针（普通用户）：`avoid v1` → `200 {"success":true}`。
  ///
  /// ⚠️ 官方 **DSfile 安卓端不用它**（本会话用 smali 全量 grep 核实：
  /// `SYNO.FileStation.Timeout` 在 DSfile 里**零命中**）—— 所以这条不是
  /// "对齐 DSfile"，而是**补移动端特有的缺口**：手机上"放着让它跑完"
  /// 比网页端更常见。理由与证据记在 `docs/dsfile-apk-parity.md`。
  Future<void> avoidTimeout() async {
    await api.call('SYNO.FileStation.Timeout', 'avoid', preferredVersion: 1);
  }

  /// `SYNO.FileStation.BackgroundTask / clear_finished`
  Future<void> clearFinishedTasks() async {
    await api.call(
      'SYNO.FileStation.BackgroundTask',
      'clear_finished',
      preferredVersion: negotiate('SYNO.FileStation.BackgroundTask', _v3),
    );
  }

  /// 压缩 / 复制移动 / 解压 / 目录大小 的任务状态（共用几个 API 的 `status`）。
  ///
  /// ⚠️ `taskid` 是**裸字符串**，不是 JSON 数组串 —— 官方 DS file 就是这么发的
  /// （`new SingleApiParameter("taskid", transferItem.getId())`），真机实测：
  /// 发数组串服务端直接回一个 HTML 错误页（`tool/flt_task_probe.dart`）。
  /// 要给多个任务发，就一个个调。
  Future<FileTaskListResult> taskStatus({
    required String apiName,
    required String taskId,
  }) async {
    final data = await api.call(
      apiName,
      'status',
      preferredVersion: negotiate(apiName, _v3),
      params: {'taskid': taskId},
    );
    return FileTaskListResult.fromJson(data);
  }

  // ------------------------------------------------- MD5 校验 / 文件属性
  //
  // 这两个 Property 接口真机回的是**字符串数字**，所以统一走这个宽松解析。
  //
  // 形态出处：**官方 FileStation Web 客户端** `export/ui/file_browser/FileProperty.js`
  //   * MD5:    `start {file_path}` → `{taskid}` → `status {taskid}` 每 1s 轮询
  //             → `{finished, md5}`；失败 → `{errors:[…]}`；取消 → `stop {taskid}`
  //   * 压缩后大小: `Property.CompressSize/get {file}` → `{diskSize}`
  //   * 修改时间:   `Property.Mtime/get {file}`        → `{mtime}`（秒）
  //   * 所有者:     `Property.ACLOwner/get {file}`     → `{name,type,value,hasPrivilege}`
  //                （普通用户看别人/系统目录会直接 403）
  //
  // ⚠️ 参数名三套不一样：MD5 用 `file_path`（与 DirSize 一致），
  // Property.* 用 `file` —— 官方 JS 里就是这么分的，别"顺手统一"。

  /// `SYNO.FileStation.MD5 / start` —— 开始算 MD5（异步任务），返回 `taskid`。
  Future<String> startMd5(List<String> paths) async {
    final data = await api.call(
      'SYNO.FileStation.MD5',
      'start',
      preferredVersion: negotiate('SYNO.FileStation.MD5', _v2),
      params: {'file_path': FileEntryDto.encodePaths(paths)},
    );
    return '${data['taskid'] ?? ''}';
  }

  /// `SYNO.FileStation.MD5 / status` —— 算完了才有 `md5`。
  Future<FileMd5Status> md5Status(String taskId) async {
    final data = await api.call(
      'SYNO.FileStation.MD5',
      'status',
      preferredVersion: negotiate('SYNO.FileStation.MD5', _v2),
      params: {'taskid': taskId},
    );
    return FileMd5Status.fromJson(data);
  }

  /// `SYNO.FileStation.MD5 / stop`（关面板/离开页面时别把 NAS 的 CPU 白烧）
  Future<void> stopMd5(String taskId) async {
    await api.call(
      'SYNO.FileStation.MD5',
      'stop',
      preferredVersion: negotiate('SYNO.FileStation.MD5', _v2),
      params: {'taskid': taskId},
    );
  }

  /// `SYNO.FileStation.Property.CompressSize / get` —— 实际占盘字节数
  /// （稀疏文件 / Btrfs 压缩后会小于 `size`）。失败（无权限等）返回 null。
  Future<int?> compressSize(String path) async {
    final data = await api.call(
      'SYNO.FileStation.Property.CompressSize',
      'get',
      preferredVersion: negotiate(
        'SYNO.FileStation.Property.CompressSize',
        _v1,
      ),
      params: {'file': path},
    );
    // ⚠️ 真机上 `diskSize` 是**字符串**（"1916928"，实测 DS923+ / DSM 7.4），
    // 所以不能只认 num —— 只认 num 会静默变成 null（0 行，页面少一行还不报错）。
    return parseIntOrNull(data['diskSize']);
  }

  /// `SYNO.FileStation.Property.Mtime / get` —— 真实修改时间（秒）。失败返回 null。
  Future<int?> mtimeOf(String path) async {
    final data = await api.call(
      'SYNO.FileStation.Property.Mtime',
      'get',
      preferredVersion: negotiate('SYNO.FileStation.Property.Mtime', _v1),
      params: {'file': path},
    );
    return parseIntOrNull(data['mtime']);
  }

  /// `SYNO.FileStation.Property.ACLOwner / get` —— 所有者 + 我有没有权限改。
  /// 普通用户对没权限的位置会拿到 `403`（原样抛出，调用方降级显示）。
  Future<FileAclOwnerDto> aclOwner(String path) async {
    final data = await api.call(
      'SYNO.FileStation.Property.ACLOwner',
      'get',
      preferredVersion: negotiate('SYNO.FileStation.Property.ACLOwner', _v1),
      params: {'file': path},
    );
    return FileAclOwnerDto.fromJson(data);
  }

  /// 停止任务（压缩 / 复制移动 / 解压 / 目录大小共用 `stop`，`taskid` 同上：裸字符串）
  Future<void> stopTask({
    required String apiName,
    required String taskId,
  }) async {
    await api.call(
      apiName,
      'stop',
      preferredVersion: negotiate(apiName, _v3),
      params: {'taskid': taskId},
    );
  }

  /// M58：**重试**一个失败的后台任务 —— 用原 api / method / 参数快照重发一次。
  ///
  /// 服务端 `BackgroundTask` 没有重试方法（注册表只有 `list` /
  /// `clear_finished`），官方 `BackgroundTaskFragment.retry` 就是**客户端重发**。
  /// 参数快照由 [FileTaskDto.params] 承载；这里只做一次透传调用，不碰任何
  /// 参数名（api / method / params 全部由调用方 `fileTaskRetryPlan` 决定）。
  Future<void> retryTask({
    required String apiName,
    required String method,
    required Map<String, dynamic> params,
  }) async {
    await api.call(
      apiName,
      method,
      preferredVersion: negotiate(apiName, _v3),
      params: params,
    );
  }

  /// `SYNO.FileStation.Favorite / replace_all`（M50）—— 整表覆盖收藏顺序。
  ///
  /// **参数形态已真机取证**（2026-09-22，父 agent 实机跑通）：
  /// `path` 与 `name` 是两个**平行**数组，都按 JSON 数组串发；数组顺序 =
  /// 期望的显示顺序，第 i 个 `name` 对应第 i 个 `path`：
  ///
  /// ```
  /// path = '["/home/Books","/home/Download"]'
  /// name = '["ZZ测试收藏A","ZZ测试收藏B"]'
  /// → {"success":true}
  /// ```
  ///
  /// 双证：① 官方 `ui/file_browser/FileBrowser.js` 的 `SaveFav`
  /// （逐字 `params:{path:e,name:t}`，`e` 取各节点 `o.path`、`t` 取 `o.name`，
  /// **按显示顺序**）；② 真机把两个收藏（原顺序 B、A）用 `replace_all` 传 A 先，
  /// `Favorite/list` 随即变成 **A、B**。
  ///
  /// 错误形态（真机逐个试过）：只传 `path` → **400**；传
  /// `favorites=[{path,name}]` 对象数组/JSON 串 → **400**；参数过期/缺失也可能回
  /// **400** —— 所以**不能**把 400 当成"参数名错"，UI 一律按"保存失败"处理。
  ///
  /// `success:false` 由 [DsmWebApi.call] 抛 `DsmApiException`，调用方负责
  /// **保留原顺序**并提示。
  Future<void> replaceAllFavorites({
    required List<String> paths,
    required List<String> names,
  }) async {
    await api.call(
      'SYNO.FileStation.Favorite',
      'replace_all',
      preferredVersion: negotiate('SYNO.FileStation.Favorite', _v2),
      params: {
        // 两个数组必须**平行且同序**（第 i 个 name 对应第 i 个 path）
        'path': FileEntryDto.encodePaths(paths),
        'name': FileEntryDto.encodePaths(names),
      },
    );
  }

  // ------------------------------------------------------------ 搜索

  /// `SYNO.FileStation.Search / start` —— 开一个搜索任务。
  Future<FileSearchStart> startSearch({
    required String folderPath,
    String? pattern,
    String? extension,
    String? filetype,
    int sizeFrom = 0,
    int sizeTo = 0,
    int? mtimeFrom,
    int? mtimeTo,
    int? crtimeFrom,
    int? crtimeTo,
    String? owner,
    String? group,
    bool recursive = true,
  }) async {
    final data = await api.call(
      'SYNO.FileStation.Search',
      'start',
      preferredVersion: negotiate('SYNO.FileStation.Search', _v2),
      params: {
        'folder_path': folderPath,
        if (pattern != null && pattern.isNotEmpty) 'pattern': pattern,
        if (extension != null && extension.isNotEmpty) 'extension': extension,
        if (filetype != null && filetype.isNotEmpty) 'filetype': filetype,
        if (sizeFrom > 0) 'size_from': sizeFrom,
        if (sizeTo > 0) 'size_to': sizeTo,
        'mtime_from': ?mtimeFrom,
        'mtime_to': ?mtimeTo,
        'crtime_from': ?crtimeFrom,
        'crtime_to': ?crtimeTo,
        if (owner != null && owner.isNotEmpty) 'owner': owner,
        if (group != null && group.isNotEmpty) 'group': group,
        'recursive': recursive,
      },
    );
    return FileSearchStart.fromJson(data);
  }

  /// `SYNO.FileStation.Search / list` —— 取搜索结果（分页 + `additional`）。
  ///
  /// **不做任何重试**：600 会原样抛出。要"容忍瞬时 600"请用
  /// [searchResultsRetrying]（界面走那条）。
  Future<FileListResult> searchResults({
    required String taskId,
    int offset = 0,
    int limit = 0,
    FileSortBy sortBy = FileSortBy.name,
    FileSortDirection sortDirection = FileSortDirection.asc,
    List<String> additional = FileAdditional.browse,
  }) async {
    final version = negotiate('SYNO.FileStation.Search', _v2);
    final data = await api.call(
      'SYNO.FileStation.Search',
      'list',
      preferredVersion: version,
      params: {
        'taskid': taskId,
        'offset': offset,
        'limit': limit,
        'sort_by': sortBy.value,
        'sort_direction': sortDirection.value,
        'additional': _additional('SYNO.FileStation.Search', version, additional),
      },
    );
    return FileListResult.fromJson(data);
  }

  /// [`searchResults`] 的**瞬时态容忍**版本（界面用这条）。
  ///
  /// ★ r395（DA42 根因）：真机 `Search/list` 会回 **600**，而官方 FileStation
  /// 1.5.1-2410 的文案就是 `search/no_search_cache`
  /// 「暂时无法访问搜索结果。请再试一次。」——**字面就是"暂时"**。
  ///
  /// r395 逐字读数（`docs/evidence-r395/r395_da42_limit_matrix.txt`，同一台 NAS、
  /// 同一个账号、每个变体都**新开任务**）：对根 `/` 的任务刚建好时
  /// `list` 回 `{"error":{"code":600}}`，稍后**同一报文**回 `success:true`；
  /// 而根 `/home` 上的同一关键字直接成功并命中 1 条。
  ///
  /// ⇒ 这里**只对 600** 重试（默认 4 次 × 300 ms），其它码（105/119/400/408…）
  /// **原样抛出**——不许把"参数错"当"稍后再试"。
  Future<FileListResult> searchResultsRetrying({
    required String taskId,
    int offset = 0,
    int limit = 0,
    FileSortBy sortBy = FileSortBy.name,
    FileSortDirection sortDirection = FileSortDirection.asc,
    List<String> additional = FileAdditional.browse,
    int maxAttempts = 4,
    Duration retryDelay = const Duration(milliseconds: 300),
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await searchResults(
          taskId: taskId,
          offset: offset,
          limit: limit,
          sortBy: sortBy,
          sortDirection: sortDirection,
          additional: additional,
        );
      } on DsmApiException catch (e) {
        final transient = e.code == DsmErrorCode.searchCacheUnavailable;
        if (!transient || attempt >= maxAttempts - 1) rethrow;
        await Future<void>.delayed(retryDelay);
      }
    }
  }

  /// `SYNO.FileStation.Search / stop`
  Future<void> stopSearch(String taskId) async {
    await api.call(
      'SYNO.FileStation.Search',
      'stop',
      preferredVersion: negotiate('SYNO.FileStation.Search', _v2),
      params: {'taskid': taskId},
    );
  }

  /// `SYNO.FileStation.Search / clean` —— 清掉搜索结果缓存
  Future<void> cleanSearch(String taskId) async {
    await api.call(
      'SYNO.FileStation.Search',
      'clean',
      preferredVersion: negotiate('SYNO.FileStation.Search', _v2),
      params: {'taskid': taskId},
    );
  }

  /// `SYNO.FileStation.Search.History` —— 搜索历史（v1：`get` / `set` / `delete`）。
  ///
  /// ## 真机复核（本会话，只读）
  ///
  /// `get` v1 **无参**在普通用户下就回真实数据（本机 9 条）：
  /// ```json
  /// {"data":{"history":[{"folder_path":"/","pattern":"pdf","recursive":true,
  ///                      "timestamp":1789838418}, …],"total":9},"success":true}
  /// ```
  /// 补 `offset`/`limit`/`search_type` 后**回包逐字不变**（这台 NAS 上它们不影响
  /// 结果）⇒ 既有"不发任何参数"的形态**已被真机验证**，保持不变。
  ///
  /// ⚠️ 同族的 `set` 在普通用户下回 **401**（不是 `103` ⇒ 方法**存在**但不可用）。
  /// 与规程 §1.1「`allowUser` ≠ 实际可调」同族：**没有实现 `set`** ——
  /// 不给自己造一个"点了就 401"的入口。
  ///
  /// ⚠️ 已知缺陷（本批**未修**，登记在案）：服务端每项是**对象**
  /// （`{folder_path, pattern, recursive, timestamp}`；官方 `JsonReader` 也是按
  /// 这四个字段读的），而这里 `'$e'` 会把 Map 打成 `"{folder_path: /, …}"` 这种串。
  /// 该方法目前**没有生产调用点**，改动会牵动返回类型与既有离线用例，
  /// 故留待专门批次，不在本批"只补缺的方法"范围内顺手动。
  Future<List<String>> searchHistory() async {
    final data = await api.call(
      'SYNO.FileStation.Search.History',
      'get',
      preferredVersion: negotiate('SYNO.FileStation.Search.History', const [1]),
    );
    final raw = data['history'] ?? data['list'];
    if (raw is List) return raw.map((e) => '$e').toList();
    return const [];
  }

  /// `SYNO.FileStation.Search.History / delete` v1 —— 清空**某一类**搜索历史。
  ///
  /// 线参 `search_type` 与取值逐字来自官方 Web 端 `FileBrowser.js`：
  /// ```js
  /// // SYNO.FileStation.SearchHistoryPanel.search_type = "simple"
  /// // SYNO.FileStation.AdvSearchHistoryPanel.search_type = "advance"
  /// onClearHistory: sendWebAPI({api:"SYNO.FileStation.Search.History",
  ///                            method:"delete", version:1,
  ///                            params:{search_type: this.search_type}})
  /// ```
  ///
  /// ⚠️ **本批只做 API 层 + 离线用例**：`delete` 是**写操作**，本批禁止对 NAS
  /// 写入，所以**没有真机正向样本**（这不是"取不到参数"，而是"按规矩不去调"）。
  Future<void> clearSearchHistory({
    FileSearchHistoryType type = FileSearchHistoryType.simple,
  }) async {
    await api.call(
      'SYNO.FileStation.Search.History',
      'delete',
      preferredVersion: negotiate('SYNO.FileStation.Search.History', const [1]),
      params: {'search_type': type.value},
    );
  }

  // ------------------------------------------------------------ 分享链接
  //
  // 用户的决定：**分享链接默认关闭**（不提供"新建链接"的入口）。
  // 这里只实现"只读管理"：列出现有链接 + 删除 + 清理失效项。

  /// `SYNO.FileStation.Sharing / list`
  ///
  /// 官方 `getShareLinks`：`offset/limit(1000)/force_clean`。
  Future<List<ShareLinkDto>> listShareLinks({
    int offset = 0,
    int limit = 1000,
    bool forceClean = true,
  }) async {
    final data = await api.call(
      'SYNO.FileStation.Sharing',
      'list',
      preferredVersion: negotiate('SYNO.FileStation.Sharing', _v3),
      params: {'offset': offset, 'limit': limit, 'force_clean': forceClean},
    );
    return ShareLinkDto.parseList(data);
  }

  /// `SYNO.FileStation.Sharing / list_share_me` —— **共享给我的**（wave3）。
  ///
  /// ## 版本：**v2**（本方法独有的硬契约）
  ///
  /// 真机逐版本扫描：`v1 = 103`（方法不存在）、`v2 = OK`、`v3 = OK`；
  /// 本机真机回包（空态）：
  /// `{"data":{"links":[],"offset":0,"total":0},"success":true}`。
  ///
  /// ⚠️ 官方 Web 前端的同一 store 写的是 `version:3`
  /// （`/tmp/spk/export_FileStation/ui/file_browser/FileBrowser.js`，
  /// `SharingManager.Common.createStore`），v3 在真机上同样 OK；但本批次按
  /// 已取证契约钉 **v2**（既能用又与官方 v1→103 的坑拉开距离）。所以候选
  /// 版本是 [_shareWithMeVersions]（**优先 v3、回落 v2，不含 1**，见其文档）。
  ///
  /// ## 参数：`offset` / `limit` / `filter_type`（+ 排序）
  ///
  /// 官方 store 的 `baseParams`（同一 createStore）：
  /// ```js
  /// baseParams:{offset:0,limit:t.pageSize,filter_type:...},
  /// paramNames:{start:"offset",limit:"limit",sort:"sort_by",dir:"sort_direction"}
  /// ```
  /// 即**分页起点字段名就是 `offset`**（Ext 的 `paramNames.start` 只是把本地
  /// 的 `start` 映射成线上的 `offset`，我们直接发 `offset`）。
  /// `filter_type` 是分享来源应用的逗号串（`getFilterTypeStr`）。
  ///
  /// ## 回包：`data.links`（root 与 `list` 同族）
  ///
  /// `{links, total, offset}` —— 空 `links` 是**空态**不是错误。
  Future<SharedWithMeListResult> listSharedWithMe({
    int offset = 0,
    int limit = 1000,
    String? filterType,
    FileSortBy? sortBy,
    FileSortDirection? sortDirection,
  }) async {
    final data = await api.call(
      'SYNO.FileStation.Sharing',
      'list_share_me',
      preferredVersion: negotiate(
        'SYNO.FileStation.Sharing',
        _shareWithMeVersions,
      ),
      params: {
        'offset': offset,
        'limit': limit,
        // 官方只在选了具体来源时才发（`all` 也展开成应用列表串）
        if (filterType != null && filterType.isNotEmpty)
          'filter_type': filterType,
        // 排序参数成对出现（官方 paramNames.sort/dir）
        if (sortBy != null && sortDirection != null) ...{
          'sort_by': sortBy.value,
          'sort_direction': sortDirection.value,
        },
      },
    );
    return SharedWithMeListResult.fromJson(data);
  }

  /// `SYNO.FileStation.Sharing / getinfo` —— 查单个分享链接的详情。
  ///
  /// ⚠️ **`id` 是裸字符串，不是 JSON 数组** —— 反编译官方 DS file 4.17.2-609：
  ///
  /// ```
  /// .method public getShareLink(Ljava/lang/String;)…          // ← 只收一个 String
  ///   const-string v3, "id"
  ///   SingleApiParameter("id", p1)                            // ← 裸值，不是 List
  ///   const-string v2, "getinfo"
  /// ```
  ///
  /// **对照**：同一个 APK 里 `deleteShareLinks(List)` 用的是
  /// `CompositeApiParameter("id", p1)`（列表 ⇒ JSON 数组串）。
  /// 所以 `delete` 发数组、`getinfo`/`edit` 发裸串 —— **两者不一样**，
  /// 不能照抄。本方法原先照抄 `delete` 发数组，是**错的**，已修。
  ///
  /// ⚠️ 本方法目前**全仓无调用方**（死代码）。留着是因为它是 `Sharing` 家族的
  /// 一员、且形状已由 APK 钉死；接管理页"点开看详情"时可直接用。
  Future<List<ShareLinkDto>> shareLinkInfo(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final data = await api.call(
      'SYNO.FileStation.Sharing',
      'getinfo',
      preferredVersion: negotiate('SYNO.FileStation.Sharing', _v3),
      // 官方只发一个裸 id。多 id 的语义**未取证** ⇒ 这里不猜：
      // 只取首个（调用方要批量详情应改用 `list`）。
      params: {'id': ids.first},
    );
    return parseShareLinkInfo(data);
  }

  /// `SYNO.FileStation.Sharing / delete` —— 删除分享链接
  Future<void> deleteShareLinks(List<String> ids) async {
    await api.call(
      'SYNO.FileStation.Sharing',
      'delete',
      preferredVersion: negotiate('SYNO.FileStation.Sharing', _v3),
      params: {'id': FileEntryDto.encodePaths(ids)},
    );
  }

  /// `SYNO.FileStation.Sharing / clear_invalid` —— 清理失效链接
  Future<void> clearInvalidShareLinks() async {
    await api.call(
      'SYNO.FileStation.Sharing',
      'clear_invalid',
      preferredVersion: negotiate('SYNO.FileStation.Sharing', _v3),
    );
  }

  /// `SYNO.FileStation.Sharing / create` —— **创建分享链接**（P0-1）。
  ///
  /// 证据（官方 DS file 4.17.2-609 `WebApiConnectionManager.createShareLinkV3`）：
  ///
  /// ```java
  /// arrayList.add(new CompositeApiParameter(PATH, list));        // path = JSON 数组
  /// if (str != null)  arrayList.add(new SingleApiParameter("password", str));
  /// if (!empty(avail)) arrayList.add(new SingleApiParameter("date_available", avail));
  /// if (!empty(exp))   arrayList.add(new SingleApiParameter("date_expired", exp));
  /// doWebApiQuery(SYNO_FILESTATION_SHARING, "create", 3, arrayList);
  /// ```
  ///
  /// 日期格式 `yyyy-MM-dd`（`DateUtils.DATE_FORMAT_LOCALE`，"0" = 立即生效 /
  /// 永久有效；官方永久时**不发**该字段）。
  ///
  /// 密码**原样发送**（官方 APK 的 CREATE 分支就是 `passwd` 原文，没有走
  /// `CgiEncryption`；`WebApiConnectionManager` 里 `CgiEncryption` 只服务于
  /// 登录的 `SYNO.API.Encryption`）。因此本方法不调用 `cgi_encryption.dart`。
  Future<List<ShareLinkDto>> createShareLink({
    required List<String> paths,
    String? password,
    String? dateAvailable,
    String? dateExpired,
  }) async {
    final data = await api.call(
      'SYNO.FileStation.Sharing',
      'create',
      preferredVersion: negotiate('SYNO.FileStation.Sharing', _v3),
      params: {
        'path': FileEntryDto.encodePaths(paths),
        if (password != null && password.isNotEmpty) 'password': password,
        if (dateAvailable != null && dateAvailable.isNotEmpty)
          'date_available': dateAvailable,
        if (dateExpired != null && dateExpired.isNotEmpty)
          'date_expired': dateExpired,
      },
    );
    return ShareLinkDto.parseList(data);
  }

  /// `SYNO.FileStation.Sharing / edit` —— **修改**已有分享链接的密码 / 有效期（M36）。
  ///
  /// 证据：`docs/api-server-authoritative.md:120`（v1–3 都有 `edit`，普通用户）。
  /// 参数形状沿用同一 API 的 `create`（`password` / `date_available` /
  /// `date_expired`）+ 目标链接的 `id`；`id` 按 `delete` / `getinfo` 的既有
  /// 形状编码（`FileEntryDto.encodePaths` = JSON 数组串）。
  ///
  /// ## `id` 形状：**已取证**（第 28 轮，改掉了原先的错误实现）
  /// 反编译官方 DS file 4.17.2-609 `WebApiConnectionManager`：
  /// ```
  /// .method public editShareLink(Ljava/lang/String;Ljava/lang/String;
  ///                              Ljava/lang/String;Ljava/lang/String;)V
  ///   SingleApiParameter("id", p1)            // ★ 裸值
  ///   SingleApiParameter("password", p2)
  ///   SingleApiParameter("date_available", p3)
  ///   SingleApiParameter("date_expired", p4)
  ///   doWebApiQuery("SYNO.FileStation.Sharing", "edit", v, …)
  /// ```
  /// ⇒ 四个位置参数就是 `id / password / date_available / date_expired`。
  /// **`id` 是裸字符串**。同 APK 的 `deleteShareLinks(List)` 才用
  /// `CompositeApiParameter`（数组）—— 本方法原先照抄 `delete` 发
  /// `encodePaths([id])`，**是错的**，已修。
  ///
  /// ## ★★★ 第 251 轮取证：**清空密码 = `protect_type:"none"` + `password:""`**
  ///
  /// 证据（一级来源，反编译官方 DS file 4.17.2-609）：
  ///
  /// ```text
  /// WebApiConnectionManager.editShareLinkV3(String id, String pwd,
  ///                                         String avail, String expired)
  ///   add(SingleApiParameter("id", id))                       // 裸字符串
  ///   if (pwd != null) {
  ///       if (TextUtils.isEmpty(pwd))
  ///           add(SingleApiParameter("protect_type", "none"));   // ★ 清空密码
  ///       add(SingleApiParameter("password", pwd));              // ★ 空串也照发
  ///   }
  ///   if (!isEmpty(avail))   add(("date_available", avail));
  ///   if (!isEmpty(expired)) add(("date_expired", expired));
  ///   doWebApiQuery("SYNO.FileStation.Sharing", "edit", 3, …)
  /// ```
  ///
  /// 调用方 `ShareFragmentDSM6$12`：编辑模式下
  /// * 关掉"密码保护"开关 ⇒ 传 **空串**（不是 null）⇒ 上面 `isEmpty` 分支命中
  ///   ⇒ **两个字段一起发**；这就是官方"移除密码"的完整报文；
  /// * 密码框仍是占位符 `"0000000000"`（未改）⇒ 传 **null** ⇒ 两个字段**都不发**；
  /// * 起止日期未勾选 ⇒ 传空串 ⇒ `date_expired` **不发**（不是发空串！）。
  ///
  /// 服务端侧佐证（同版本 FileStation 1.5.1-2410 SPK 的 `webapi/SYNO.FileStation.Sharing.so`）：
  /// 时间字段的解析格式是 `%Y-%m-%d` / `%Y-%m-%d %H:%M:%S`，且库里有
  /// `"%s:%d Failed to convert input time to tm struct"` —— 发一个空的时间串
  /// **不是**官方的"清空"表达（很可能直接报错），所以本方法**不再自创**
  /// `date_expired:""`。
  ///
  /// ⚠️ **诚实边界**：官方 edit 路径**没有**"取消既有有效期"的报文
  /// （APK 在日期为空时直接省略；DSM 网页端发的 `expire_at` 服务端不认），
  /// 所以本方法**没有** `clearExpiry` 参数：不传 `dateExpired` = **不动**原有效期。
  /// 界面已如实说明（见 `file_sheets.dart` 的编辑面板提示），**不假装能清**。
  Future<List<ShareLinkDto>> editShareLink({
    required String id,
    String? password,
    bool clearPassword = false,
    String? dateAvailable,
    String? dateExpired,
  }) async {
    final data = await api.call(
      'SYNO.FileStation.Sharing',
      'edit',
      preferredVersion: negotiate('SYNO.FileStation.Sharing', _v3),
      params: {
        // ★ **裸字符串**，不是 JSON 数组 —— 见 `shareLinkInfo` 的 APK 证据：
        // `editShareLink(String,String,String,String)` 里
        // `SingleApiParameter("id", p1)`。原先照抄 `delete` 发数组是错的。
        'id': id,
        // 清空密码：**两个字段一起发**（官方 `editShareLinkV3` 逐字）。
        if (clearPassword) ...{
          'protect_type': 'none',
          'password': '',
        } else if (password != null && password.isNotEmpty)
          'password': password,
        if (dateAvailable != null && dateAvailable.isNotEmpty)
          'date_available': dateAvailable,
        // 日期为空 ⇒ **省略**（与官方同形，不是发空串）。见上方诚实边界。
        if (dateExpired != null && dateExpired.isNotEmpty)
          'date_expired': dateExpired,
      },
    );
    return ShareLinkDto.parseList(data);
  }

  /// 服务端 `Upload` 是否支持 `rename` 冲突策略（官方 `isSupportUploadRename()`：
  /// `maxVersion >= 3`）。
  bool get supportsUploadRename {
    final entry = api.apiTable?['SYNO.FileStation.Upload'];
    if (entry == null) return true; // 未知 → fail-open，与服务端实际能力不符时由调用兜底
    return entry.maxVersion >= 3;
  }

  // ------------------------------------------------------------ 上传 / 下载

  /// `SYNO.FileStation.Upload / upload` —— multipart 上传（权威表 v2/v3 都只有
  /// `upload`）。
  ///
  /// ⚠️ **元数据全部走 multipart 的 form 字段，不是查询串**。这是反编译官方
  /// DS file（`WebApiConnectionManager.upload` + `uploadInternal`）后照抄的：
  ///
  /// ```
  /// POST entry.cgi?_sid=…              ← 只有 _sid 在 URL 上
  ///   api=SYNO.FileStation.Upload
  ///   method=upload
  ///   version=<2|3>
  ///   path=<目标目录>
  ///   create_parents=false
  ///   size=<字节数>                     ← 必发
  ///   mtime=<毫秒时间戳>
  ///   overwrite=overwrite|skip|rename
  ///   file=<文件字节>（filename=…）
  /// ```
  ///
  /// 真机踩过：把 `api`/`path` 之类放查询串、**漏掉 `size`** → 文件字节能传完，
  /// 但服务端一直在等剩余的字节，`receiveTimeout` 到点报 "request took longer
  /// than …"。`overwrite` 的取值来自官方枚举 `OverWriteMode`
  /// （`rename`/`overwrite`/`skip`；`none` 表示不发这个字段）。
  Future<String> upload({
    required String folderPath,
    required String filePath,
    required String fileName,
    String? mimeType,
    UploadConflictPolicy? conflict,
    bool createParents = false,
    void Function(int sent, int total)? onProgress,
  }) async {
    final version = negotiate('SYNO.FileStation.Upload', _v3);
    // `size` 必发（服务端按它等字节，少了会一直挂着到超时）；
    // 读不到本地文件时给一条说人话的错误，而不是把 PathNotFoundException 抛给 UI。
    final int size;
    try {
      size = await File(filePath).length();
    } on FileSystemException {
      throw DsmApiException(
        DsmErrorCode.requestParameterInvalid,
        method: 'SYNO.FileStation.Upload.upload',
        raw: {'reason': 'read_local_file_failed', 'path': filePath},
      );
    }
    final raw = await api.postMultipart(
      api.apiPath('SYNO.FileStation.Upload'),
      query: {'_sid': api.session?.sid ?? ''},
      fields: {
        'api': 'SYNO.FileStation.Upload',
        'method': 'upload',
        'version': '$version',
        'path': folderPath,
        'create_parents': '$createParents',
        'size': '$size',
        'mtime': '${DateTime.now().millisecondsSinceEpoch}',
        // 官方 `getUploadOverwriteState()`：无冲突（NONE）时**整个字段都不发**；
        // 有冲突才带上策略串。修掉"硬编码 overwrite → 静默覆盖"。
        if (conflict != null) 'overwrite': conflict.valueFor(version),
      },
      fileField: 'file',
      filePath: filePath,
      fileName: fileName,
      mimeType: mimeType ?? 'application/octet-stream',
      onProgress: onProgress,
    );
    // 上传接口同样返回 `{success, data:{…}}`（data 可能为空对象）
    final data = api.decodeData(raw, 'SYNO.FileStation.Upload.upload');
    return '${data['id'] ?? data['fileid'] ?? ''}';
  }

  // ------------------------------------------------ PhotoUpload（照片上传）

  /// `SYNO.FileStation.PhotoUpload / upload` v2/v3 —— **带缩略图的图片上传**。
  ///
  /// 与服务端 `SYNO.FileStation.Upload` **共用同一个 `.so` 与同一个 `upload`
  /// 方法**（`SYNO.FileStation.lib`：两者 `lib` 都是 `SYNO.FileStation.Upload.so`，
  /// 且 `PhotoUpload` 没有 `deferUpload`）。区别只在**客户端要不要附带缩略图部分**。
  ///
  /// ## 线参（**权威来源 = DSfile 4.17.2-609 APK 反编译**，不是猜的）
  ///
  /// `WebApiConnectionManager.smali`：
  /// ```java
  /// // upload(...) 选 API：
  /// usePhotoUpload(name) = supportUploadThumbnail() && isPicture(name)
  ///   ? "SYNO.FileStation.PhotoUpload" : "SYNO.FileStation.Upload"
  /// // uploadInternal(...) 逐字 addFormDataPart：
  /// api / method="upload" / version=<max> /
  /// path=<去掉尾斜杠的目标目录> / create_parents="false" / size=<字节数>
  /// // upload(...) 之后补：
  /// mtime=<毫秒> / overwrite=<OverWriteMode> / file=<文件字节>
  /// // 再 appendThumbnailBody(...)：把缩略图文件按各自的 field 名追加成额外部分
  /// ```
  /// 注意 **`dest_folder_path` 只在 `version==1` 时**发（`PhotoUpload` 的
  /// `minVersion=2`，所以我们对它**永不**发这个字段）。
  ///
  /// ## 真机复核（本会话，只读探针）
  ///
  /// `API.Info` 确认 `minVersion=2/maxVersion=3`、`path=entry.cgi`、
  /// `allowUser` 含 `normal.*`；**`method:upload` 必须带 `file` 部分**：
  /// ```text
  /// multipart 但无 file 部分            → 502 + 11939 字节 HTML「页面不存在」
  /// （对比）Upload:upload 无 file 部分   → 200 {"error":{"code":401}}
  /// 空文件 + 不存在的 path              → 200 {"error":{"code":408}}  （路径不存在）
  /// 空文件 + 已存在的 path + size=0     → 200 {"data":{"blSkip":false,"file":"…",
  ///                                             "pid":31101,"progress":1},"success":true}
  /// ```
  /// ⚠️ **不要用 urlencoded / GET 调它**：非 multipart 一律拿到那张 11939 字节
  /// 的 HTML 页（`502`），看起来像"接口不存在"，其实是"没按 multipart 发"。
  ///
  /// ## 取舍（本批决定）
  ///
  /// 我方**已有两条相机备份路径**（Drive `PhotoBackup` / Photos `Backup`），
  /// `PhotoUpload` 是**第三条**；因此本批**只做 API 层封装 + 离线用例**，
  /// **不新建第三条上传 UI**，避免同一功能三个入口互相打架。
  ///
  /// [thumbnailFiles] 是官方的"缩略图部分"（`ThumbnailUtil.createThumbnailMap`
  /// 产生的 `field → 本地文件`）；不传就退化成普通 `Upload` 的形状。
  Future<FilePhotoUploadResult> photoUpload({
    required String folderPath,
    required String filePath,
    required String fileName,
    String? mimeType,
    UploadConflictPolicy? conflict,
    int? mtimeMs,
    List<MultipartUploadFile> thumbnailFiles = const [],
    void Function(int sent, int total)? onProgress,
  }) async {
    final version = negotiate('SYNO.FileStation.PhotoUpload', _v3);
    final int size;
    try {
      size = await File(filePath).length();
    } on FileSystemException {
      throw DsmApiException(
        DsmErrorCode.requestParameterInvalid,
        method: 'SYNO.FileStation.PhotoUpload.upload',
        raw: {'reason': 'read_local_file_failed', 'path': filePath},
      );
    }
    final raw = await api.postMultipart(
      api.apiPath('SYNO.FileStation.PhotoUpload'),
      // `_sid` 挂查询串：DSM 7.4 起 multipart 的表单体里放 `_sid` **不认**（回 119）。
      query: {'_sid': api.session?.sid ?? ''},
      fields: {
        'api': 'SYNO.FileStation.PhotoUpload',
        'method': 'upload',
        'version': '$version',
        'path': folderPath,
        // 官方 uploadInternal 逐字发字符串 `"false"`（不是布尔）。
        'create_parents': 'false',
        'size': '$size',
        'mtime': '${mtimeMs ?? DateTime.now().millisecondsSinceEpoch}',
        if (conflict != null) 'overwrite': conflict.valueFor(version),
      },
      fileField: 'file',
      filePath: filePath,
      fileName: fileName,
      mimeType: mimeType ?? 'application/octet-stream',
      files: thumbnailFiles.isEmpty ? null : thumbnailFiles,
      onProgress: onProgress,
    );
    final data = api.decodeData(raw, 'SYNO.FileStation.PhotoUpload.upload');
    return FilePhotoUploadResult.fromJson(data);
  }

  // ------------------------------------------------------------ WORM / WriteOnce

  /// `SYNO.FileStation.Worm / get_share_info` v1 —— **共享级** WriteOnce 配置。
  ///
  /// ⚠️ **必须钉 v1**：`SYNO.FileStation.lib` 里 `Worm` 的 `methods` **只在 `"1"`
  /// 段**有 `get` / `get_share_info`（v2 段是空的），所以真机 v2 恒回 `103`。
  /// `negotiate(..., _v1)` 正好收敛到 1，不会误发 v2。
  ///
  /// 真机（普通用户）：
  /// ```text
  /// {path:"/docker"} → {"data":{"def_lock_duration":-1,"def_lock_mode":2,
  ///                             "lock_wait_time":-1,"subvol_mode":1},"success":true}
  /// {path:"/mydrive"}→ {"error":{"code":1500,"errors":[{"code":408,"path":"/mydrive"}]}}
  /// 无参 / {path:""} → {"error":{"code":1500,"errors":[{"code":400,"path":""}]}}
  /// ```
  ///
  /// 返回值可为 null（服务端没给 `def_lock_mode`）—— 调用方按"未启用"处理，
  /// **不要**把它当错误。
  Future<FileWormShareInfo?> wormShareInfo(String path) async {
    final data = await api.call(
      'SYNO.FileStation.Worm',
      'get_share_info',
      preferredVersion: negotiate('SYNO.FileStation.Worm', _v1),
      params: {'path': path},
    );
    return FileWormShareInfo.fromJson(data);
  }

  /// `SYNO.FileStation.Worm / get` v1 —— **逐路径** WriteOnce 状态。
  ///
  /// ## ⚠️ 外层码恒为 `1500`，判别力全在**内层 `errors[].code`**
  ///
  /// 真机逐字回包（普通用户，只读）：
  /// ```text
  /// {path:"/home"}   → {"error":{"code":1500,"errors":[{"code":0,"path":"/home"}]},"success":false}
  /// {path:"/docker"} → {"error":{"code":1500,"errors":[{"code":0,"path":"/docker"}]},"success":false}
  /// 无参             → {"error":{"code":1500,"errors":[{"code":400,"path":""}]},"success":false}
  /// {path:"/mydrive"}→ {"error":{"code":1500,"errors":[{"code":408,"path":"/mydrive"}]},"success":false}
  /// {path:["/home","/home/Books"]}（JSON 数组）→ 502 + HTML（**只认单值 `path`**）
  /// {paths:"/home"}（键名写错）→ 内层 400（⇒ 必需参数名确实是 `path`）
  /// ```
  ///
  /// 所以：
  ///   * **内层 `code=0` = 该路径没有 WORM 状态，是正常结果**，返回
  ///     [FileWormPathStatus.notInWorm]`== true` 的对象，**不抛异常**；
  ///   * 内层 `400/408` 是真失败（缺参 / 路径不存在）⇒ **照常抛**，不静默；
  ///   * 其它外层码（`103`/`105`/`119`…）根本不该进 [FileWormPathStatus.parseInner]
  ///     ⇒ 原样抛出。
  ///
  /// 字段名 `worm_state` / `lock_time` / `unlock_time` / `lock_duration` /
  /// `last_update_time` / `ds_current_time` 来自官方前端
  /// `FileProperty.js` 的 `WormFieldset.setLockRetention`（本机无 WORM 共享，
  /// 拿不到正向样本，故按官方字段名宽松解析：缺字段只是 null，不崩）。
  Future<FileWormPathStatus> wormGet(String path) async {
    try {
      final data = await api.call(
        'SYNO.FileStation.Worm',
        'get',
        preferredVersion: negotiate('SYNO.FileStation.Worm', _v1),
        params: {'path': path},
      );
      return FileWormPathStatus.fromData(data);
    } on DsmApiException catch (err) {
      // 1500 + 内层 code=0 ⇒ "没有 WORM"，是正常结果而非失败。
      final inner = FileWormPathStatus.parseInner(err.raw, outerCode: err.code);
      if (inner != null && inner.code == FileWormPathCode.noWorm) return inner;
      rethrow;
    }
  }

  /// `SYNO.FileStation.Download / download` 的直链（带 `_sid`）。
  ///
  /// `path` 是 **JSON 数组字符串**（官方 `getItemUrl` 用的是同一个语义），
  /// `mode` 常用 `download` / `open`。
  String downloadUrl(
    List<String> paths, {
    String mode = 'download',
    int? preferredVersion,
  }) {
    final version = negotiate(
      'SYNO.FileStation.Download',
      preferredVersion == null ? _v2 : [preferredVersion, 1],
    );
    return api.authenticatedUrl(api.apiPath('SYNO.FileStation.Download'), {
      'api': 'SYNO.FileStation.Download',
      'version': '$version',
      'method': 'download',
      'path': FileEntryDto.encodePaths(paths),
      'mode': mode,
    });
  }

  /// `SYNO.FileStation.Thumb / get` 的缩略图直链（给 `Image.network` 用）。
  String thumbnailUrl(String path, {String size = 'small'}) {
    final version = negotiate('SYNO.FileStation.Thumb', _v3);
    return api.authenticatedUrl(api.apiPath('SYNO.FileStation.Thumb'), {
      'api': 'SYNO.FileStation.Thumb',
      'version': '$version',
      'method': 'get',
      'path': path,
      'size': size,
    });
  }

  /// `SYNO.FileStation.ThumbInfo / get` v1 —— 文件的 **EXIF / IPTC / XMP** 元数据
  /// （**只读**）。
  ///
  /// ## 事实来源（真机只读实测，原文见
  /// `docs/device-readonly-verification-evidence-r16.md` §12）
  ///
  /// ```console
  /// SYNO.FileStation.ThumbInfo/get  path=entry.cgi  v1..1  params={path:/home}
  ///   → {"exif":null,"iptc":null,"xmp":null}
  /// ```
  ///
  /// ⇒ 已取证：**API 名、path、版本区间 v1..1、参数名 `path`（单值裸串）**，
  /// 以及"没有元数据时三个键**都在**、值都是 `null`"这个**空态形状**。
  ///
  /// ⚠️ **未取证**：`exif` / `iptc` / `xmp` **非 null 时的内部结构**
  /// —— 本机样本（`/home` 下的图）恰好都没有元数据，所以拿不到正向回包。
  /// 因此 [FileThumbInfoDto] **不假设**字段名：Map 就逐键展示、字符串就整段展示、
  /// 未知形状原样降级（见该类注释）；界面**只**对认得的标准键给中文标签，
  /// **不编造**任何值。
  ///
  /// ## 边界
  /// * 版本走 [negotiate]（候选 [_v1]，真机只有 v1）；path 由 `SYNO.API.Info`
  ///   决定（真机 `entry.cgi`），本方法**不写死路径**（规程 §1.4）。
  /// * 调用前请用 [hasApi] 门控：API 不存在的服务器上**不发探测**，
  ///   整块元数据区直接不出现（规程 §4.5「缺失→隐藏」）。
  /// * 对目录调用是合法参数形状（真机就是这么验的），服务端回三个 `null`；
  ///   调用方一般在图片/视频文件上用它。
  Future<FileThumbInfoDto> thumbInfo(String path) async {
    final data = await api.call(
      'SYNO.FileStation.ThumbInfo',
      'get',
      preferredVersion: negotiate('SYNO.FileStation.ThumbInfo', _v1),
      params: {'path': path},
    );
    return FileThumbInfoDto.fromJson(data);
  }

  /// 服务器有没有 `SYNO.FileStation.ThumbInfo`（能力表为空 = 未知，按"有"处理）。
  bool get canThumbInfo => hasApi('SYNO.FileStation.ThumbInfo');

  /// `SYNO.FileStation.Sharing.Download / download` 的公开链接直链
  String shareLinkDownloadUrl(String linkId, {String? path}) {
    final version = negotiate('SYNO.FileStation.Sharing.Download', const [1]);
    return api
        .authenticatedUrl(api.apiPath('SYNO.FileStation.Sharing.Download'), {
          'api': 'SYNO.FileStation.Sharing.Download',
          'version': '$version',
          'method': 'download',
          'id': linkId,
          'path': ?path,
        });
  }

  /// `SYNO.Core.ExternalDevice.Storage.USB / list`（**v1**）—— 外接 USB 存储
  /// 设备列表（D223）。
  ///
  /// ## 原文证据（DS file 反编译 `smali_classes2/.../WebApiConnectionManager.smali`）
  ///
  /// ```text
  /// getUSBList()  : api="SYNO.Core.ExternalDevice.Storage.USB"
  ///                 method="list"  version=1
  ///                 additional = ["partitions"]      （CompositeApiParameter）
  /// USBDevicesResponseVo$Device    : dev_id / dev_title / partitions[]
  /// USBDevicesResponseVo$Partition : filesystem / name_id / partition_title /
  ///                                  share_name / status / total_size_mb /
  ///                                  used_size_mb
  /// doEjectUSBList(devId) : method="eject" version=1  param **dev_id**
  /// ```
  ///
  /// 并且 FileStation 自己声明的 `allow_other_apis`
  /// （`/tmp/spk/export_FileStation/conf/resource`）逐字含：
  /// `{api:"SYNO.Core.ExternalDevice.Storage.USB", method:"list", version:1}` 与
  /// `{…, method:"eject", version:1}` ⇒ **普通 FileStation 用户可用**。
  ///
  /// ## 真机取证（本会话，只读；普通用户 `demo_user`，DSM 7.2）
  ///
  /// ```text
  /// API.Info : SYNO.Core.ExternalDevice.Storage.USB {path:entry.cgi, min:1, max:1}
  /// USB/list v1 （entry.cgi 与 query.cgi 都试，无参）        → 404
  /// USB/__bogus__ v1 （同 API 的假方法）                    → 103 method not found
  /// USB/list v2                                             → 104 version not supported
  /// Storage.EUnit/list v1 （兄弟 API 对照）                 → 105 permission denied
  /// ```
  ///
  /// ## r395 订正（**DA25 的"404 = 没插盘"这个推断被推翻了**）
  ///
  /// 第一轮探针（r370）时本机"没插盘"，所以把 404 **推断**成"没有找到设备"，
  /// 并在注释里明确标了"⚠️ 未取证"。r395 拿到 NAS 侧原始回包后，对照证据是：
  ///
  /// ```text
  /// ① 同一分钟 list_share：share=usbshare1 → real_path=/volumeUSB1/usbshare
  ///    （8.05 GB 的卷真的挂载着，Files 里也能列出内容）      ⇒ 盘**在**
  /// ② USB/list v1（additional=["partitions"]）               → 404
  /// ③ USB/list v1（官方前端那 4 个 additional）              → 404
  /// ④ USB/list 走官方形态 SYNO.Entry.Request/compound        → 404（同码）
  /// ⑤ 同一个 compound 里的兄弟 eSATA/list v1                 → 105（权限）
  /// ⑥ USB/list v2                                            → 104（版本不支持）
  /// ```
  ///
  /// ⇒ 三条硬结论：**(a) 404 与"有没有插盘"无关**（盘就在那儿）；
  /// **(b) 404 不是权限码**（同请求内的兄弟 API 回的是 105，DSM 不是用 404 掩饰权限）；
  /// **(c) 调用形态无关**（直呼 / compound 都是 404）。
  /// ⇒ **404 的确切语义仍未取到**（`.lib` 契约里本 API 允许 `normal.*`，
  /// 而官方前端只对管理员调它），所以 UI **不许**把 404 说成"NAS 上没有 U 盘"，
  /// 只能说"服务端没有给出设备列表"并保留去 Files 看盘的路径。
  Future<UsbDeviceList> listUsbDevices() async {
    // ★ r370 订正（**原来这里写的是"编码口径未取证"**）：官方规则已取证 ——
    //   《DS file》4.17.2 smali `WebApiConnectionManager.createNameValuePairs`
    //   按 `Api.isRequestFormatJson()`（= `requestFormat == "JSON"`）二选一，
    //   **与版本无关**：JSON 格式的 API 一律 `jsonEncode`（→ `["partitions"]`）。
    //   活服务器（`SYNO.API.Info`，未鉴权可读）对本 API 明确回
    //   `{path:entry.cgi, minVersion:1, maxVersion:1, requestFormat:"JSON"}`。
    //   而改前走的是"v1 ⇒ 逗号"（→ `partitions`）—— 与官方客户端不一致，
    //   见 DA24（r370 台账）。现在交由 `_additional` 按**服务端声明**决定。
    final version = negotiate('SYNO.Core.ExternalDevice.Storage.USB', _v1);
    try {
      final data = await api.call(
        'SYNO.Core.ExternalDevice.Storage.USB',
        'list',
        preferredVersion: version,
        params: {
          'additional': _additional(
            'SYNO.Core.ExternalDevice.Storage.USB',
            version,
            const ['partitions'],
          ),
        },
      );
      return UsbDeviceList(
        devices: UsbDeviceDto.listFromJson(data),
        notFound: false,
      );
    } on DsmApiException catch (e) {
      // 404 = 服务端**没有给出设备列表**。★ r395：这**不代表**"本机没插盘"
      // （真机读数：盘挂载着、Files 能列出内容，本调用照样 404），也**不是**权限码
      // （同请求里的 eSATA 回 105）。只认这一个码，其它一律照原样抛。
      if (e.code == 404) {
        return const UsbDeviceList(devices: [], notFound: true);
      }
      rethrow;
    }
  }

  /// `SYNO.Core.ExternalDevice.Storage.USB / eject`（**v1**）—— 弹出（安全卸载）
  /// 一个 USB 设备。参数 **`dev_id`**（原文见 [listUsbDevices]）。
  ///
  /// ⚠️ **这是写操作**（会真的卸载/弹出设备）。UI 必须二次确认后才调；
  /// 本批**没有在真机上调用过它**（纪律：不做任何变更型探测）。
  Future<void> ejectUsbDevice(String devId) async {
    await api.call(
      'SYNO.Core.ExternalDevice.Storage.USB',
      'eject',
      preferredVersion: negotiate('SYNO.Core.ExternalDevice.Storage.USB', _v1),
      params: {'dev_id': devId},
    );
  }

  /// `SYNO.FileStation.Info / get` —— 服务端 File Station 能力与设置。
  Future<Map<String, dynamic>> info() async {
    return api.call(
      'SYNO.FileStation.Info',
      'get',
      preferredVersion: negotiate('SYNO.FileStation.Info', _v2),
    );
  }

  /// `SYNO.FileStation.Info / get` 的 `is_manager` —— 当前用户是不是管理员。
  ///
  /// 证据：`FileStation.Info.so` 字符串含 `is_manager`；官方 APK
  /// `FileStationInfoVo.Data.is_manager` 在 `WebApiConnectionManager:476`
  /// 被读进 `isManager`。清空回收站（`SYNO.Core.RecycleBin` 仅 admin）要靠它门控。
  Future<bool> isManager() async {
    final data = await info();
    return data['is_manager'] == true;
  }
}

// --------------------------------------------------------------- 223 USB DTO

/// [FileStationApi.listUsbDevices] 的结果。
///
/// [notFound] = 服务端回了 **404**。★ r395 订正：它**不等于**"本机没有 USB 设备"
/// —— 真机实测（U 盘挂着、`usbshare1` = `/volumeUSB1/usbshare`、Files 能列内容）
/// 时这个调用仍回 404，且直呼/`compound` 两种形态、官方与我们的 `additional`
/// 都一样；同请求里的兄弟 `eSATA/list` 回的是 **105**（权限）⇒ 404 既不是
/// "盘不在"也不是"没权限"。所以单独留标志位，让 UI 说"服务端没有给出列表"，
/// **不许**说"没插盘"。
class UsbDeviceList {
  const UsbDeviceList({required this.devices, required this.notFound});

  final List<UsbDeviceDto> devices;
  final bool notFound;

  bool get isEmpty => devices.isEmpty;
}

/// 一个外接 USB 存储设备（DS file `USBDevicesResponseVo$Device`）。
class UsbDeviceDto {
  const UsbDeviceDto({
    required this.devId,
    required this.title,
    required this.partitions,
  });

  /// `dev_id`（eject 要原样回传）
  final String devId;

  /// `dev_title`（设备显示名）
  final String title;

  /// `partitions[]`
  final List<UsbPartitionDto> partitions;

  static List<UsbDeviceDto> listFromJson(Map<String, dynamic> json) {
    final raw = json['devices'] ?? json['items'] ?? json['list'];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) UsbDeviceDto._from(e.cast<String, dynamic>()),
    ];
  }

  static UsbDeviceDto _from(Map<String, dynamic> json) => UsbDeviceDto(
    devId: '${json['dev_id'] ?? ''}',
    title: '${json['dev_title'] ?? json['title'] ?? ''}',
    partitions: UsbPartitionDto.listFromJson(json['partitions']),
  );
}

/// USB 设备上的一个分区（DS file `USBDevicesResponseVo$Partition`）。
class UsbPartitionDto {
  const UsbPartitionDto({
    required this.nameId,
    required this.title,
    required this.shareName,
    required this.filesystem,
    required this.status,
    required this.totalSizeMb,
    required this.usedSizeMb,
  });

  final String nameId;
  final String title;
  final String shareName;
  final String filesystem;
  final String status;
  final int totalSizeMb;
  final int usedSizeMb;

  static List<UsbPartitionDto> listFromJson(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) UsbPartitionDto._from(e.cast<String, dynamic>()),
    ];
  }

  static UsbPartitionDto _from(Map<String, dynamic> json) => UsbPartitionDto(
    nameId: '${json['name_id'] ?? ''}',
    title: '${json['partition_title'] ?? ''}',
    shareName: '${json['share_name'] ?? ''}',
    filesystem: '${json['filesystem'] ?? ''}',
    status: '${json['status'] ?? ''}',
    totalSizeMb: _intOrZero(json['total_size_mb']),
    usedSizeMb: _intOrZero(json['used_size_mb']),
  );

  static int _intOrZero(Object? v) {
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }
}

// ============================================================ ThumbInfo（元数据）

/// 元数据块的种类（`SYNO.FileStation.ThumbInfo / get` 的三个顶层键）。
enum ThumbInfoKind { exif, iptc, xmp }

/// 元数据里的一行：**原始键 + 已格式化的值**。
///
/// [key] 是服务端给的原始键名，**原样保留**；界面只对认得的标准键给中文标签，
/// 认不出就把原始键名显示出来 —— 这样"服务端给了什么"永远看得见，
/// 不会因为标签表没覆盖就丢掉一行。
///
/// [key] 为空串表示这一行没有键名（例如整个块就是一个字符串 / 数组元素）。
class ThumbInfoRow {
  const ThumbInfoRow(this.key, this.value);

  final String key;
  final String value;
}

/// 一个元数据块（EXIF / IPTC / XMP）解析后的一组行。
///
/// [rows] 为空 = **这个块没有可用数据**（服务端回 `null`、空串或空容器）
/// —— 这是**正常结果**，不是错误，界面按空态如实呈现。
class ThumbInfoBlock {
  const ThumbInfoBlock(this.kind, this.rows);

  final ThumbInfoKind kind;
  final List<ThumbInfoRow> rows;

  bool get isEmpty => rows.isEmpty;
}

/// `SYNO.FileStation.ThumbInfo / get` 的回包（**只读**）。
///
/// ## 真机取到的**两种**形状（都有原文）
///
/// **① 空态**（`/home` 等无元数据的文件）：
/// ```json
/// {"exif":null,"iptc":null,"xmp":null}
/// ```
///
/// **② 有数据**（真机 `/home/Photos/手机备份/IMG_20260920_171030.jpg`，
/// 2026-09-22 真机实测，截图 `docs/evidence-r17/06-file-thumbinfo-data-exif.png`）：
/// 块的值是一个**数组**，每个元素是 `{"name": <英文可读名>, "value": <字符串>}`，
/// `value` **带尾随 `\n`**：
/// ```json
/// "exif": [
///   {"name":"Image Width","value":"3072\n"},
///   {"name":"Model","value":"LGE-AN10\n"},
///   {"name":"Exposure Time","value":"0.06 s\n"},
///   {"name":"FNumber","value":"F1.8\n"},
///   {"name":"ISO Speed Ratings","value":"6400\n"},
///   {"name":"Date and Time (original)","value":"2026:09:20 17:10:30\n"},
///   {"name":"Focal Length","value":"5.5 mm\n"},
///   {"name":"GPS Latitude","value":"0deg 0' 0\"\n"}
/// ]
/// ```
/// ⇒ `name` 就是**标签**（已经是人话英文），`value` 就是**值**
/// ⇒ 界面**直接显示 `name`/`value` 两列**，不再把整个对象 `jsonEncode` 出来。
///
/// ## 但解析仍然"松"
/// 上面这条只是**这一台机器上这一张图**的形状，不是接口契约。所以按 JSON 类型
/// 逐层降级，**先认 `{name,value}`，认不出再退回通用平铺**：
///
/// | 服务端给的值 | 解析成 |
/// |---|---|
/// | `null` | 空块（0 行） |
/// | `[{name,value}, …]` | 每元素 1 行：**`name` 当标签、`value` 当值**（去掉尾随空白） |
/// | `{name, value}`（单对象） | 同上，1 行 |
/// | 字符串 | 1 行（无键名），整段原文 |
/// | 对象 | 逐键 1 行（键名原样） |
/// | 数组（元素不是 `{name,value}`） | 每个元素 1 行（无键名）；对象元素用 `jsonEncode` 平铺 |
/// | 数字 / 布尔 | 1 行（无键名） |
///
/// 这样"有数据"就一定显示得出来（而且是**人话**），"没有"就一定落空态，
/// **两种都不会崩**。
class FileThumbInfoDto {
  const FileThumbInfoDto({this.exif, this.iptc, this.xmp});

  factory FileThumbInfoDto.fromJson(Map<String, dynamic> json) =>
      FileThumbInfoDto(
        exif: json['exif'],
        iptc: json['iptc'],
        xmp: json['xmp'],
      );

  /// 服务端原样的三块内容（可能是 null / String / Map / List / num / bool）
  final Object? exif;
  final Object? iptc;
  final Object? xmp;

  static const List<ThumbInfoKind> kinds = ThumbInfoKind.values;

  /// 三个块按 EXIF → IPTC → XMP 的顺序（键名与官方回包一致）
  List<ThumbInfoBlock> get blocks => [
    ThumbInfoBlock(ThumbInfoKind.exif, _rows(exif)),
    ThumbInfoBlock(ThumbInfoKind.iptc, _rows(iptc)),
    ThumbInfoBlock(ThumbInfoKind.xmp, _rows(xmp)),
  ];

  /// 三块里**一行都没有** —— 服务端明确回了"没有元数据"。
  ///
  /// ⚠️ 这只描述"回包里有内容"，**不**描述"接口失败"：失败在调用层就抛异常了，
  /// 不会走到这里。界面绝不可以把失败渲染成"没有元数据"。
  bool get isEmpty => blocks.every((b) => b.rows.isEmpty);

  /// 所有块里的行数合计（给用例/调试用）
  int get rowCount => blocks.fold(0, (n, b) => n + b.rows.length);

  static List<ThumbInfoRow> _rows(Object? v) {
    if (v == null) return const [];
    if (v is String) {
      final s = v.trim();
      return s.isEmpty ? const [] : [ThumbInfoRow('', v)];
    }
    if (v is Map) {
      // ② 有数据：单个 `{name, value}` 对象
      if (_isNameValueMap(v)) {
        final single = _nameValueRow(v);
        return single == null ? const [] : [single];
      }
      final out = <ThumbInfoRow>[];
      v.forEach((k, value) {
        final text = _format(value);
        if (text == null) return; // null 值不占一行（"没有这个键"和"键为空"同义）
        out.add(ThumbInfoRow('$k', text));
      });
      return out;
    }
    if (v is List) {
      final out = <ThumbInfoRow>[];
      for (var i = 0; i < v.length; i++) {
        final e = v[i];
        // ② 有数据：`[{name, value}, …]` —— 真机 IMG_*.jpg 就是这个形状
        if (e is Map && _isNameValueMap(e)) {
          // 认出来了就**绝不**再退回 jsonEncode：value 为空白的项（真机有
          // `{"name":"Image Description","value":"\n"}`）直接不占行，
          // 而不是把 `{"name":…}` 糊到界面上。
          final nv = _nameValueRow(e);
          if (nv != null) out.add(nv);
          continue;
        }
        final text = _format(e);
        if (text == null) continue;
        out.add(ThumbInfoRow('', text));
      }
      return out;
    }
    final text = _format(v);
    return text == null ? const [] : [ThumbInfoRow('', text)];
  }

  /// 是不是 `{"name": <非空字符串>, …}` 这个形状（值部分不参与判断）。
  static bool _isNameValueMap(Map<Object?, Object?> m) {
    final name = m['name'];
    return name is String && name.trim().isNotEmpty;
  }

  /// 认 `{"name": …, "value": …}` 并转成一行；不是这个形状就返回 `null`。
  ///
  /// * `name` 必须是字符串且非空（空白 `name` 认不出来，退回通用平铺，信息不丢）；
  /// * `value` 去掉**尾随**空白（真机每个 `value` 都以 `\n` 结尾，直接显示会多一个
  ///   看不见的空行）；去掉后为空的（真机有 `{"name":"Image Description",
  ///   "value":"\n"}` 这种）**不占行**，与 `null` 值同规则。
  static ThumbInfoRow? _nameValueRow(Map<Object?, Object?> m) {
    final name = m['name'];
    if (name is! String) return null;
    final label = name.trim();
    if (label.isEmpty) return null;
    final value = _format(m['value']);
    final text = value?.replaceFirst(RegExp(r'\s+$'), '') ?? '';
    if (text.isEmpty) return null;
    return ThumbInfoRow(label, text);
  }

  /// 值的显示形态；`null` 表示"这个值不值得占一行"。
  static String? _format(Object? v) {
    if (v == null) return null;
    if (v is String) return v.isEmpty ? null : v;
    if (v is Map || v is List) {
      // 嵌套结构不猜字段，整段平铺（保证信息不丢）
      try {
        return jsonEncode(v);
      } catch (_) {
        return '$v';
      }
    }
    return '$v';
  }
}

/// `Sharing / getinfo` 回包的形状容错（**只做类型容错，不做业务兜底**）。
///
/// ★ 为什么不能照抄 `list` 的解析：真机（r306，DSM 7.4.1-90080）实测
/// `getinfo` 回 `success:true` 但按 `list` 的根键 `links` 解出来是 **0 条**
/// —— 同一个 API 的 `list` 与 `getinfo` **回包形状不一样**。
/// 官方本方 `.lib`（FileStation 1.5.1-2410）只声明方法存在性、不给 response schema，
/// 所以这里三种形状都收：
/// `{links:[…]}`（与 `list` 同形） / `{link:{…}}`、`{info:{…}}` / **扁平单体**
/// （带 `id` 或 `url`）。三种都不匹配 ⇒ 空列表（= "服务端没说"，**不是**"没密码"）。
List<ShareLinkDto> parseShareLinkInfo(Map<String, dynamic> data) {
  if (data['links'] is List) return ShareLinkDto.parseList(data);
  for (final key in const ['link', 'info', 'data']) {
    final v = data[key];
    if (v is Map) return [ShareLinkDto.fromJson(Map<String, dynamic>.from(v))];
  }
  if (data.containsKey('id') || data.containsKey('url')) {
    return [ShareLinkDto.fromJson(data)];
  }
  return const [];
}
