// Synology Drive 客户端（P0.1「文件」第二来源）。
//
// **与官方逐字对齐**（见 `docs/api-server-authoritative.md` §5.1）：
//   * 版本：`Files/list|get|search|recent|list_starred` 用 **v3**（官方
//     `SYNO.SDS.Drive.WebAPIDesc` 里 `get_file` 就是 v3），`create|update|copy|move|
//     delete|get_thumbnail|download` 用 **v2**（官方同款），标签用 `Labels` v1；
//   * `path` 参数是 **`id:<file_id>`**（官方 `SYNO.SDS.Drive.Utils.getPathId`），
//     也接受 `/mydrive/...`；`files` 参数是 **JSON 数组字符串**（真机实测：
//     传重复字段或裸 id 一律 `114 缺少必需参数`）；
//   * 回包是 `{items, total}`（FileStation 是 `{files, total}`，别混）；
//   * **缩略图与下载不是 JSON 接口**：官方用 `SYNO.API.GetBaseURL` 拼出 URL 直接
//     给 `<img src>` / 下载用，服务端直接回字节。所以这里是 `thumbnailUrl` /
//     `downloadUrl`（带 `_sid`），不是 `call`。
import 'dart:convert';

import '../core/net/traffic_meter.dart';
import '../dsm/webapi.dart';
import 'dto/drive_collection_dto.dart';
import 'dto/drive_connection_dto.dart';
import 'dto/drive_entry_dto.dart';
import 'dto/drive_file_request_dto.dart';
import 'dto/drive_label_dto.dart';
import 'dto/drive_move_conflict_dto.dart';
import 'dto/drive_notification_dto.dart';
import 'dto/drive_quota_dto.dart';
import 'dto/drive_search_dto.dart';
import 'dto/drive_revision_dto.dart';
import 'dto/drive_share_dto.dart';
import 'dto/drive_task_dto.dart';
import 'dto/drive_team_member_dto.dart';

/// 个人空间根（官方 `Utils` 里个人空间就是 `/mydrive`）
const String kDriveRoot = '/mydrive';

/// 加密 Office 文档的"需要密码"服务端错误码。
///
/// 原文证据：APK `model/exception/SynologyDriveExceptionInterpreter.java:248-250`
/// ```java
/// public boolean isNeedPasswordException(Exception exception) {
///     return (exception instanceof WebApiErrorException) &&
///         ((WebApiErrorException) exception).getWebApiError().getErrorCode() == 57373;
/// }
/// ```
/// （`ShowSynoDocumentFragment.java:1756-1789` 用它决定弹"输入密码"框。）
const int kDriveNeedPasswordCode = 57373;

/// `FileRequest` 被**服务端开关**关掉时的错误码。
///
/// 真机只读实测（普通账号，DSM 7.2，`docs/g6-api-probe-facts.md:44-50`）：
///
/// ```
/// SYNO.SynologyDrive.FileRequest:list v1
/// → {"success": false, "error": {"code": 1076, "errors": {"line": 63,
///    "message": "protocol error, reason = 'file request is disabled'"}}}
/// ```
///
/// **⇒ 不是实现缺口，是 DSM 侧的 `file request` 功能没开。**
/// `error.errors.message` 是**原始协议报文**，**绝不允许进界面**
/// —— 界面文案见 `features/drive/drive_g6_text.dart` 的
/// `describeDriveG6Error`。
const int kDriveFileRequestDisabledCode = 1076;

/// 相机备份的**目录分层**（官方 `BackupStructure`，D72）。
///
/// 原文（反编译 `BackupStructureKt.java` 的字符串常量 +
/// `BackupStructure.java:getStructure`）：
///   * `none` → 不进任何日期层（`return ""`）；
///   * `year` → `"yyyy"`；
///   * `yearAndMonth` → `"yyyy/MM"`（官方默认，`pref_photo_backup_setting.xml`
///     `android:defaultValue="year_and_month"`）。
enum DriveBackupStructure {
  none('none'),
  year('year'),
  yearAndMonth('year_and_month');

  const DriveBackupStructure(this.value);

  /// 官方存进 SharedPreferences 的原值
  final String value;

  /// 官方 `BackupStructure.fromValue(String)`：认不出时**回落 `year_and_month`**
  /// （`BackupStructure$Companion.java`）。
  static DriveBackupStructure fromValue(String? value) => switch (value) {
    'none' => DriveBackupStructure.none,
    'year' => DriveBackupStructure.year,
    _ => DriveBackupStructure.yearAndMonth,
  };
}

/// `SYNO.SynologyDrive.Files` 上我们已实测过的版本（v1–v11 的方法集一致，
/// 差异只有 v3 起多一个 `list_backup_tasks`）
const List<int> _v4 = [4, 3, 2, 1];
const List<int> _v3 = [3, 2, 1];

/// `Files/upload` 整文件分支的候选版本（官方 `Math.min(8, maxVersion)`）。
const List<int> _v8 = [8, 7, 6, 5, 4, 3, 2, 1];
const List<int> _v2 = [2, 1];
const List<int> _v1 = [1];

/// `Files/list` **按排序键**选版本的候选表（真机实测，2026-09-25 第 256 轮）。
///
/// 真机缺陷根因：`sort_by=created_time` 在 **v3 上被拒**，v2/v1 正常。
///
/// 实测（真 NAS nas.example.com，`SYNO.SynologyDrive.Files:list`，只读）：
/// ```
/// v3 sort_by=created_time  -> {"error":{"code":120,"errors":{"name":"sort_by","reason":"condition"}}}
/// v2 sort_by=created_time  -> 成功（total=14，与 v3 同样的 41 个字段）
/// v1 sort_by=created_time  -> 成功
/// v3 sort_by=name|size|modified_time|type|owner -> 成功
/// ```
/// ⇒ 「创建时间」这个排序只能用 **v2**；其余排序键继续用 v3。
/// 这是**参数级**的版本差异，`SYNO.API.Info` 的能力表看不出来，
/// 只能靠这条实测钉住。**别把 v2 当"降级"删掉**：删了就等于把创建时间排序关掉。
const List<int> _vListSortCreatedTime = [2, 1];

/// `download` / `list_backup_tasks` 的候选版本。
///
/// 官方这两个方法的 `VersionComputer` 都是 **`Math.min(7, api.getMaxVersion())`**
/// （反编译原文：`ApiSynoDriveFiles.java` 的 `setAsDownload` /
/// `setAsArchiveFiles` / `setAsDownloadArchive` 三处 lambda；`setAsComputers`
/// 是 `Math.min(3, …)`）。本机 `Files` 的 `maxVersion` 真机注册是 **11**
/// （`SYNO.API.Info` 只读探针），所以官方发 **7**。
///
/// ⚠️ 不要用 `apiTable.maxVersion` 直发：老的 `_negotiate(Files, _v2)` 会给
/// **2**，而 `archive_name` / `decrypt` 这些打包参数是更高版本才认的。
const List<int> _v7 = [7, 6, 5, 4, 3, 2, 1];

/// `count_files` 的**最低可用版本**（官方 APK 常量
/// `VERSION_SUPPORT_FILE_COUNT_QUERY = 0xb`，即 **11**）。
///
/// 见 [DriveApi.countFiles]：低于该版本时官方 App **根本不会调**这个接口，
/// 所以我们也不发（返回空映射），不拿"未知行为的老版本"去凑数。
const List<int> _v11 = [11];

/// `Connection:list` 的候选版本：**优先 v2，回退 v1**。
///
/// ⚠️ 这是**候选列表**，不是"写死的版本"：`DriveApi._negotiate` 会拿它跟
/// 服务端 `SYNO.API.Info` 里 `SYNO.SynologyDrive.Connection` 的
/// `[minVersion, maxVersion]` 取交集再挑（§5.3 硬规则：不得直接发 `maxVersion`）。
///
/// 两端的证据：
///   * `.lib` 逐字 `methods: {1:[list, delete], 2:[list, delete, summary]}`；
///   * 真机只读实测（`docs/g6-api-probe-facts.md:37`）：**v1 与 v2 都 `success`**
///     （`{"items": [], "total": 0}`）⇒ 老包只到 v1 时我们也要能工作。
const List<int> _vConnection = [2, 1];

/// 收藏集（`Labels` 上的 `type=*_album|*_folder|*_playlist`）的候选版本。
///
/// 原文：官方 `ApiSynoDriveLabels.VERSION_SUPPORT_COLLECTION = 2`，且
/// `setAsListCollection` / `setAsCreateCollection` 的 `VersionComputer`
/// 都是 **`Math.min(2, api.getMaxVersion())`**（`ApiSynoDriveLabels.java`）。
/// ⇒ 收藏集**从 v2 起才有**；老包只到 v1 时不能当作支持收藏集
/// （[DriveApi.listCollections] 仍会按候选挑到 v1，调用方需用能力表判断）。
const List<int> _vCollection = [2, 1];

/// `Trash` 的候选版本：官方 `setAsList` 是
/// **`Math.min(3, api.getMaxVersion())`**（`ApiSynoDriveTrash$$ExternalSyntheticLambda0`），
/// `VERSION_SUPPORT_COLLECTION = 2`、`VERSION_SUPPORT_RECYCLED_TIME = 3`。
///
/// ⚠️ 本机 `SYNO.API.Info` 只到 **maxVersion 2**（真机只读探针），
/// ⇒ `_negotiate` 会挑到 **2**（不是 3），这正是"按服务端协商"而非写死。
const List<int> _vTrash = [3, 2, 1];

/// 团队文件夹的空间根（官方 `Constants.TEAMFOLDER_PATH = "/team-folders"`）。
///
/// 只用于把"这是团队文件夹空间"这件事讲清楚；**回收站列表本身不用它拼
/// path**（见 [DriveApi.listFolderTrash] 的原文说明）。
const String kDriveTeamFolderRoot = '/team-folders';

class DriveApi {
  DriveApi(DsmWebApi api) : api = api.withModule(TrafficModules.drive);

  final DsmWebApi api;

  /// ★ 官方 `DriveServerInfo.isRecoverableTransferSupported()` —— **可续传上传**能力位。
  ///
  /// ## ⚠️ 它不是服务端返回的字段（这点很容易搞反）
  ///
  /// 官方 DTO 上确实写着 `@SerializedName("is_support_recoverable_transfer")`
  /// （`DriveServerInfo.java:83`），看着像服务端给的 —— 但那是**本地算完之后
  /// 缓存/序列化用的名字**。真正把它置位的是
  /// `DriveServerInfoGetWork.onPrepareRequestWork` 的 **case 6**：
  ///
  /// ```java
  /// if (apiManager.fetchAPI(ApiSynoDriveFiles.API_NAME).getMaxVersion() >= 9) {
  ///     this.mSupportRecoverableTransfer = true;
  ///     this.mSupportAppendText = true;      // ★ 同一个阈值还管"追加文本"
  /// }
  /// ```
  ///
  /// 同批还有别的阈值（都在同一个 case 里，一并记下来备查）：
  /// `>=2` 分类视图、`>=3` allow_download、`>=4` file_api_v4、
  /// `>=5`（与 `Profiles>=2` 一起）`is_sync_supported`、
  /// `>=8` OCR + PDF 缩略图、**`>=9` 可续传 + 追加文本**、`>=11` 文件计数查询。
  ///
  /// ⇒ 所以判据是**目录里的 maxVersion**，不是某个接口的回包。
  /// [api] 的 `apiTable` 为空（还没 discover）时按 `false` 处理 —— 与官方
  /// 默认值 `mIsSupportRecoverableTransfer = false` 一致。
  bool get isSupportRecoverableTransfer =>
      (api.apiTable?['SYNO.SynologyDrive.Files']?.maxVersion ?? 0) >= 9;

  /// `Files` maxVersion >= 9 时官方同时置位的**另一个**能力：追加文本。
  ///
  /// 见 [isSupportRecoverableTransfer] 的引用；两者在官方代码里是**同一行**
  /// 里一起赋值的，所以阈值必须一致，不能各写各的。
  bool get isSupportAppendText => isSupportRecoverableTransfer;

  /// 候选版本里挑一个服务器真正支持的（与 `FileStationApi.negotiate` 同规则）
  int _negotiate(String apiName, List<int> candidates) {
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

  /// `Files/list` —— 目录列举。
  ///
  /// [path] 用 `id:<file_id>` 或 `/mydrive/...`（真机两种都通）。
  Future<({List<DriveEntryDto> items, int total})> list({
    String path = kDriveRoot,
    int offset = 0,
    int limit = 200,
    DriveSortBy? sortBy,
    String sortDirection = 'asc',
    String? field,
  }) async {
    // ★ 第 256 轮真机缺陷修复：`sort_by=created_time` **在 v3 上被服务端拒**
    // （`120 / sort_by / condition`），v2/v1 正常 ⇒ 按排序键挑候选版本。
    // 依据与实测输出见 [_vListSortCreatedTime] 的文档注释。
    final candidates = sortBy == DriveSortBy.createdTime
        ? _vListSortCreatedTime
        : _v3;
    final data = await api.call(
      'SYNO.SynologyDrive.Files',
      'list',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', candidates),
      params: {
        'path': path,
        'offset': offset,
        'limit': limit,
        if (sortBy != null) 'sort_by': sortBy.value,
        if (sortBy != null) 'sort_direction': sortDirection,
        'field': ?field,
      },
    );
    return DriveEntryDto.listFromJson(data);
  }

  /// `Files/get` —— 单个条目（列表字段不全时用它补）
  Future<DriveEntryDto> get({required String path}) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Files',
      'get',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v3),
      params: {'path': path},
    );
    return DriveEntryDto.fromJson(data);
  }

  /// `Files/get`（**v2**）→ 条目的 `permanent_link`，即 Office 的 `link_id`。
  ///
  /// 真机取证（`docs/live-nas-verification.md` §⑦.2）：
  /// `SYNO.SynologyDrive.Files:get v2 {path:'/mydrive/<name>'}` 回真实数据，
  /// 响应里的 `permanent_link` 就是 `Office.Snapshot:get` 要的 `link_id`
  /// （例：`5-day trip planner.odoc` → `19yWDUyKQgqT7TGZ0wml6hMaNWMD2PaC`）。
  ///
  /// ⚠️ 路径语义：**Drive API 只认 `/mydrive`**（`/home/Drive` 真机回 `1000`）。
  /// `/home/Drive` 是 File Station 视角的真实目录，两者**不可互换**。
  /// 版本按取证发 **v2**（`Files/get` 的官方形态就是 v2，v3 是 `list` 用的）。
  Future<String> permanentLinkForPath({required String path}) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Files',
      'get',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v2),
      params: {'path': path},
    );
    return DriveEntryDto.fromJson(data).permanentLink;
  }

  /// `Files/search`（官方搜索页同款）。
  ///
  /// 原文证据（P0-4）：
  ///   * APK `ApiSynoDriveFiles.java:724-796` `setAsListSearch`：方法名
  ///     `search`、版本 `Math.min(4, maxVersion)`（`:786`）、**恒定**
  ///     `content_snippet:true`（`:791`）；筛选键 `keyword / location /
  ///     custom_location / file_type / custom_file_type / owner /
  ///     custom_owner / min_size / max_size / labels / time /
  ///     start_date / end_date`（`:119-132`、`:730-781`）。
  ///   * 官方 Web 同款（`synodrive_common.js:18` `ViewStore.Search` +
  ///     `fillSearch*`），搜索描述符 = `{api, version:2, method:"search"}`。
  ///   * 大小：官方把 MB 乘 1048576 再发 `min_size`/`max_size`；`EqualTo` 是
  ///     ±5% 带（`ApiSynoDriveFiles.java:756-766,133`）。
  ///
  /// `keyword` 为空且无任何筛选时服务端回 `120`，UI 会先拦（见搜索页）。
  Future<({List<DriveEntryDto> items, int total})> search(
    String keyword, {
    int offset = 0,
    int limit = 200,
    DriveSearchLocation location = DriveSearchLocation.any,
    String customLocationId = '',
    DriveSearchFileType fileType = DriveSearchFileType.any,
    String customFileType = '',
    DriveSearchOwner owner = DriveSearchOwner.any,
    String customOwnerName = '',
    DriveSearchSize size = DriveSearchSize.any,
    int sizeMegabytes = 0,
    List<String> labelIds = const [],
    DriveSearchDate date = DriveSearchDate.any,
    int startTime = 0,
    int endTime = 0,
    bool contentSnippet = true,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Files',
      'search',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v4),
      params: {
        if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
        'offset': offset,
        'limit': limit,
        // ---- location（`:734-742`）
        if (location != DriveSearchLocation.any) 'location': location.apiValue,
        if (location == DriveSearchLocation.custom &&
            customLocationId.isNotEmpty)
          'custom_location': 'id:$customLocationId',
        // ---- file_type（`:743-748`）
        if (fileType != DriveSearchFileType.any) 'file_type': fileType.apiValue,
        if (fileType == DriveSearchFileType.custom &&
            customFileType.trim().isNotEmpty)
          'custom_file_type': customFileType.trim(),
        // ---- owner（`:749-754`）；custom_owner 官方是 {type:'user',name}
        if (owner != DriveSearchOwner.any) 'owner': owner.apiValue,
        if (owner == DriveSearchOwner.custom &&
            customOwnerName.trim().isNotEmpty)
          'custom_owner': {'type': 'user', 'name': customOwnerName.trim()},
        // ---- 大小（`:755-767`）：MB × 1048576
        if (size == DriveSearchSize.greaterThan && sizeMegabytes > 0)
          'min_size': sizeMegabytes * 1048576,
        if (size == DriveSearchSize.lessThan && sizeMegabytes > 0)
          'max_size': sizeMegabytes * 1048576,
        if (size == DriveSearchSize.roughly && sizeMegabytes > 0) ...{
          'min_size': driveSearchSizeBand(sizeMegabytes).min,
          'max_size': driveSearchSizeBand(sizeMegabytes).max,
        },
        // ---- 标签 / 时间（`:768-780`）
        if (labelIds.isNotEmpty) 'labels': labelIds,
        if (date != DriveSearchDate.any) 'time': date.apiValue,
        if (date != DriveSearchDate.any && startTime > 0)
          'start_date': startTime,
        if (date != DriveSearchDate.any && endTime > 0) 'end_date': endTime,
        'content_snippet': contentSnippet,
      },
    );
    return DriveEntryDto.listFromJson(data);
  }

  /// `DriveSearchQuery` → 上面 [search] 的命名参数（页面层用它拼条件）
  Future<({List<DriveEntryDto> items, int total})> searchQuery(
    DriveSearchQuery query, {
    int offset = 0,
    int limit = 200,
  }) => search(
    query.keyword,
    offset: offset,
    limit: limit,
    location: query.location,
    customLocationId: query.customLocationId,
    fileType: query.fileType,
    customFileType: query.customFileType,
    owner: query.owner,
    customOwnerName: query.customOwnerName,
    size: query.size,
    sizeMegabytes: query.sizeMegabytes,
    labelIds: query.labelIds,
    date: query.date,
    startTime: query.startTime,
    endTime: query.endTime,
    contentSnippet: query.contentSnippet,
  );

  /// `Files/recent`（"最近"）
  Future<({List<DriveEntryDto> items, int total})> recent({
    int offset = 0,
    int limit = 200,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Files',
      'recent',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v3),
      params: {'offset': offset, 'limit': limit},
    );
    return DriveEntryDto.listFromJson(data);
  }

  /// `Files/list_starred`（"星标"）
  Future<({List<DriveEntryDto> items, int total})> listStarred({
    int offset = 0,
    int limit = 200,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Files',
      'list_starred',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v3),
      params: {'offset': offset, 'limit': limit},
    );
    return DriveEntryDto.listFromJson(data);
  }

  /// `Files/shared_with_me`（"共享给我"）。
  Future<({List<DriveEntryDto> items, int total})> sharedWithMe({
    int offset = 0,
    int limit = 200,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Files',
      'shared_with_me',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v3),
      params: {'offset': offset, 'limit': limit},
    );
    return DriveEntryDto.listFromJson(data);
  }

  /// `Files/shared_with_others`（"我共享的"，P0-6）。
  ///
  /// 原文证据：APK `ApiSynoDriveFiles.java:689-691` `setAsListSharedWithOthers`
  /// → `setAsListWithMethod(Method.SHARED_WITH_OTHERS, …)`（`:80-81` 方法名
  /// `shared_with_others`）；官方 Web 描述符
  /// `list_shared_with_others:{api:"SYNO.SynologyDrive.Files",
  /// method:"shared_with_others",version:2}`（`synodrive_common.js:18`）。
  /// 与 [sharedWithMe] 是**同族的另一个方法**（不是 `Sharing` 那套具名共享）。
  ///
  /// 版本沿用同族 `list_starred` / `shared_with_me` 已真机验证的 v3
  /// （官方 APK 用 `Math.min(5, max)`、Web 描述符写 v2；三者差异记在文档
  /// "未验证边界"，v5 未在真机复核）。
  Future<({List<DriveEntryDto> items, int total})> sharedWithOthers({
    int offset = 0,
    int limit = 200,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Files',
      'shared_with_others',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v3),
      params: {'offset': offset, 'limit': limit},
    );
    return DriveEntryDto.listFromJson(data);
  }

  /// `TeamFolders/list`（团队文件夹；普通用户的个人空间之外的空间）。
  ///
  /// 真机（2026-09-18）：`{offset,limit}` + **v1** → `{items:[],total:0}`。
  ///
  /// ★ **r369（真机首次拿到非空回包）**：条目**不带 `type`**，若按
  /// `DriveEntryDto` 的兜底（空 ⇒ `'file'`）就会被当成文件 —— 真机像素：
  /// 「更多 → Team folders」里 `teamdrivetest` 的大小列显示 **`0 B`**（而不是
  /// `Folder`），点进去进的是**文件预览页**（`This kind of file opens in a
  /// system app`）。团队文件夹按定义就是目录（官方 APK 本地表
  /// `team_folder(name, team_id, file_id, …)` 的 `file_id` 与 `file` 表同键），
  /// 所以这里在**边界上声明 `forceType: 'dir'`**，不靠回包字段猜。
  Future<({List<DriveEntryDto> items, int total})> teamFolders({
    int offset = 0,
    int limit = 200,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.TeamFolders',
      'list',
      preferredVersion: _negotiate('SYNO.SynologyDrive.TeamFolders', _v1),
      params: {'offset': offset, 'limit': limit},
    );
    // ★ 团队文件夹一律声明为目录（见上：该回包没有 `type` 字段）
    return DriveEntryDto.listFromJson(data, forceType: 'dir');
  }

  /// `Trash/get_size`（回收站占用；真机 v2 回 `{items:null}` = 空）。
  Future<int> trashSize({String path = kDriveRoot}) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Trash',
      'get_size',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Trash', const [2, 1]),
      params: {'path': path},
    );
    // 真机空回收站回 `{items:null}`；有内容时官方回的是按空间分组的尺寸信息，
    // 这里只取"总字节"这一个我们真用得上的数字，取不到就 0。
    final items = data['items'];
    if (items is int) return items;
    if (items is List) {
      var sum = 0;
      for (final e in items) {
        if (e is Map) {
          final v = e['size'] ?? e['total_size'];
          if (v is int) sum += v;
        }
      }
      return sum;
    }
    return 0;
  }

  /// `Files/list_ancestor`（面包屑；真机回 `items` 从根到当前）
  Future<List<DriveEntryDto>> listAncestor({required String path}) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Files',
      'list_ancestor',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v2),
      params: {'path': path},
    );
    return DriveEntryDto.listFromJson(data).items;
  }

  /// 缩略图直链（**服务端直接回图片字节**，给 `Image.network` / `getBytes` 用）
  ///
  /// 官方参数：`path=id:<file_id>` + `size=small|medium|large`（还有可选的
  /// `version_id` / `is_preview` / `online_convert`，这里按需给）。
  String thumbnailUrl({
    required String fileId,
    String size = 'medium',
    String? versionId,
    bool isPreview = true,
  }) {
    final version = _negotiate('SYNO.SynologyDrive.Files', _v2);
    return api.authenticatedUrl(api.apiPath('SYNO.SynologyDrive.Files'), {
      'api': 'SYNO.SynologyDrive.Files',
      'version': '$version',
      'method': 'get_thumbnail',
      'path': 'id:$fileId',
      'size': size,
      'version_id': ?versionId,
      'is_preview': isPreview ? 'true' : 'false',
    });
  }

  /// 下载直链（**服务端直接回文件字节**；多文件时官方走分块任务，这里按单文件用）
  ///
  /// 官方参数：`files=["id:<file_id>"]` + `force_download` + `is_preview`
  /// （真机实测 `is_preview=false` 时也是原文件字节）。
  String downloadUrl({
    required String fileId,
    bool forceDownload = true,
    bool isPreview = false,
  }) {
    final version = _negotiate('SYNO.SynologyDrive.Files', _v2);
    return api.authenticatedUrl(api.apiPath('SYNO.SynologyDrive.Files'), {
      'api': 'SYNO.SynologyDrive.Files',
      'version': '$version',
      'method': 'download',
      'files': '["id:$fileId"]',
      'force_download': forceDownload ? 'true' : 'false',
      'is_preview': isPreview ? 'true' : 'false',
    });
  }

  /// **多选打包下载直链**（D25）。
  ///
  /// ## 官方规格（`ApiSynoDriveFiles.setAsDownload`，`ApiSynoDriveFiles.java:388-408`）
  ///
  /// ```java
  /// setAsDownload(List<String> fileIdList, String archiveName,
  ///               String targetPath, String sharingToken, DownloadType downloadType)
  ///   version       = Math.min(7, api.getMaxVersion())
  ///   files         = UtilsForApi.computeManyPathesById(fileIdList)
  ///   force_download       = true
  ///   update_access_time   = !downloadType.forSync()
  ///   convert_office_file  = true ^ downloadType.forSync()   // 即 !forSync()
  ///   download_type        = downloadType.getValue()
  ///   archive_name         = archiveName      // 仅当非空
  ///   sharing_token        = sharingToken     // 仅当非空
  /// ```
  ///
  /// **`DownloadType` 枚举**（`FileRepositoryNet.java:782`）：
  /// `DOWNLOAD("download")` / `PREVIEW("preview")` / `SYNC("sync")`，
  /// `forSync()` **仅** `SYNC` 为 true。
  /// ⇒ **普通下载**（`download`）的 `update_access_time` 与
  /// `convert_office_file` **都是 `true`**（`true ^ false == true`）。
  ///
  /// ## 路径拼法（`UtilsForApi.computePathById:19-21`）
  /// ```java
  /// return id.startsWith("/") ? id : "id:" + id;
  /// ```
  /// ⇒ 已经是路径的（如 `/home/...`）**保持原样**，否则加 `id:` 前缀。
  /// 我方的 [_pathById] 就是这个语义。
  ///
  /// ## ★ 为什么**不改**既有的单文件 [downloadUrl]
  /// 它走 `_v2` 且**已真机验证**。把它改成 `min(7,max)` 会让那份证据作废
  /// （第 53 轮的教训，见附录 AP.3）。所以这里**新增**一个方法，
  /// 两者并存：单个文件继续用已验证的那条，**多选打包**用这条。
  String downloadArchiveUrl({
    required List<String> fileIds,
    String? archiveName,
    String? sharingToken,
    bool isPreview = false,
  }) {
    // 官方 Math.min(7, maxVersion)
    final version = _negotiate('SYNO.SynologyDrive.Files', _v7);
    final paths = fileIds.map(_pathById).toList(growable: false);
    return api.authenticatedUrl(api.apiPath('SYNO.SynologyDrive.Files'), {
      'api': 'SYNO.SynologyDrive.Files',
      'version': '$version',
      'method': 'download',
      // 官方是 JSON 数组字面量（`computeManyPathesById` 的结果被序列化成数组）
      'files': jsonEncode(paths),
      'force_download': 'true',
      'update_access_time': 'true',
      'convert_office_file': 'true',
      'download_type': 'download',
      if (archiveName != null && archiveName.isNotEmpty)
        'archive_name': archiveName,
      if (sharingToken != null && sharingToken.isNotEmpty)
        'sharing_token': sharingToken,
      if (isPreview) 'is_preview': 'true',
    });
  }

  /// `Files/create`（v2）：建文件夹。官方参数 `path` + `type:"folder"`。
  /// 服务端回**新建出来的那个条目**。
  Future<DriveEntryDto> createFolder({required String path}) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Files',
      'create',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v2),
      params: {'path': path, 'type': 'folder'},
    );
    return DriveEntryDto.fromJson(data);
  }

  /// `Files/create`（v2）：新建 / 覆盖写文本文件（D60）。
  ///
  /// ## ★★ r371（DA12/DA14 修复）：参数名是 `file_content`，不是 `text_content`
  ///
  /// 真机（r359，DA12）报 **`Missing required parameter`**、文件从不落盘；
  /// 同屏「New folder」走同一个 `Files/create` **成功** ⇒ 缺参数只在文本分支。
  /// 过去这里发的是 `text_content` —— 那是官方 APK `AppendTextWork`
  /// （`ApiSynoDriveFiles.java:904-914`，"**追加**文本"那条 Work）的参数名。
  ///
  /// 本轮在**服务端自己的二进制**里核对到 `create` 分支真正认的参数名与形态
  /// （`synodrive.spk` → `webapi/drive/file/SYNO.SynologyDrive.File.so`，
  /// `create.cpp` 的字符串块，逐字）：
  ///
  /// ```
  /// create
  /// file_content            <- ★ 参数名（不是 text_content）
  /// refer / is_delta / real_size / created_time / access_time / modified_time
  /// encrypted / permanent_link / mute / sync_id / max_id / is_dir / file_data_path
  /// create file failed
  /// file content is required          <- 缺它时的服务端报错
  /// [ERROR] create.cpp(%d): the length of file content is not multiple of 4
  /// [ERROR] create.cpp(%d): failed to decode base64 string.
  /// ```
  ///
  /// ⇒ 两条硬事实：① 名字是 **`file_content`**；② 内容是 **base64**
  /// （"length … not multiple of 4"、"failed to decode base64"）。
  /// 这也解释了 `Missing required parameter`：服务端要的 `file_content`
  /// 根本没收到，而它给的 `text_content` 被忽略。
  ///
  /// `conflict_action` 也在官方列里：Web 端 `create_files` 描述符
  /// （`synodrive.js`：`{api:"SYNO.SynologyDrive.Files",method:"create",version:1}`）
  /// 的调用点是 `copyTo({},e.params,"path,type,conflict_action")`，
  /// 建目录那条传 `conflict_action:"autorename"`；官方语义见
  /// `uploadFile` 的注释（新建文本→`autorename`、其余→`version`）。
  /// 本方法默认 `autorename`（新建），覆盖保存传 `version`（新建版本）。
  Future<DriveEntryDto> createTextFile({
    required String path,
    String textContent = '',
    String conflictAction = 'autorename',
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Files',
      'create',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v2),
      params: {
        'path': path,
        'type': 'file',
        // ★ 服务端认的是 base64 文本（`create.cpp` 的两条报错即判据）
        'file_content': base64Encode(utf8.encode(textContent)),
        'conflict_action': conflictAction,
      },
    );
    return DriveEntryDto.fromJson(data);
  }

  /// `Files/update`（v2）：改名 / 改时间 / 改星标 / 改标签（只发改动的字段）。
  Future<DriveEntryDto> update({
    required String fileId,
    String? name,
    int? modifiedTime,
    int? createdTime,
    bool? starred,
    List<String>? labels,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Files',
      'update',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v2),
      params: {
        'path': 'id:$fileId',
        'name': ?name,
        'modified_time': ?modifiedTime,
        'created_time': ?createdTime,
        'starred': ?starred,
        'labels': ?labels,
      },
    );
    return DriveEntryDto.fromJson(data);
  }

  /// `Files/star`（v2）：星标开/关（`files` 是 JSON 数组字符串）
  Future<void> star({
    required List<String> fileIds,
    required bool starred,
  }) async {
    await api.call(
      'SYNO.SynologyDrive.Files',
      'star',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v2),
      params: {'files': _jsonIds(fileIds), 'starred': starred},
    );
  }

  /// `Files/label`（**v2**）：给文件打/去标签。
  ///
  /// ⚠️ 真机踩过的坑（2026-09-19 三轮探针）：`labels` 不是 id 列表，而是
  /// **动作数组** `[{"action":"add"|"delete","label_id":<int>}]`；传
  /// `["1"]` / `["\"1\""]` / 对象形式的 `files` 全都失败（1000 或 114）。
  /// 官方 Web 端的调用点（`synodrive.js` 的 `changeTagByRec`）就是这么拼的。
  Future<void> setLabels({
    required List<String> fileIds,
    required List<DriveLabelChange> changes,
  }) async {
    await api.call(
      'SYNO.SynologyDrive.Files',
      'label',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v2),
      params: {
        'files': _jsonIds(fileIds),
        'labels': jsonEncode([for (final c in changes) c.toJson()]),
      },
    );
  }

  /// `Files/list_labelled`（v2）：按标签列文件。
  ///
  /// `label_id` 必须是 **Gson 引号串**（`'"1"'`）：裸串回 `120 参数无效`。
  Future<({List<DriveEntryDto> items, int total})> listLabelled({
    required String labelId,
    int offset = 0,
    int limit = 200,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Files',
      'list_labelled',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v2),
      params: {'label_id': '"$labelId"', 'offset': offset, 'limit': limit},
    );
    return DriveEntryDto.listFromJson(data);
  }

  // ------------------------------------------------------------ 版本历史

  /// `Revisions/list`（v1）：某个文件的版本列表。
  ///
  /// 真机：`{path:'id:<file_id>', offset, limit}` → `{items, total}`；
  /// `version_id` 是服务端全局变更号（不是 1/2/3）。回 `1003` 表示**文件不存在**。
  Future<List<DriveRevisionDto>> listRevisions({
    required String fileId,
    int offset = 0,
    int limit = 200,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Revisions',
      'list',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Revisions', _v1),
      params: {'path': 'id:$fileId', 'offset': offset, 'limit': limit},
    );
    return DriveRevisionDto.listFromJson(data);
  }

  /// `Revisions/restore`（v1）：把文件恢复到某个版本。
  ///
  /// 真机（2026-09-19）：参数**不是** `{path, version_id}`（那样回 114），
  /// 而是官方 Web 端的对象数组形态：
  /// `{files:'[{"path":"id:<id>","version_id":<vid>}]', conflict_action:'version'}`
  /// → `{async_task_id}`；恢复本身会**再生成一个新版本**（版本数 +1，符合官方行为）。
  Future<String> restoreRevision({
    required String fileId,
    required String versionId,
    String conflictAction = 'version',
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Revisions',
      'restore',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Revisions', _v1),
      params: {
        'files':
            '[{"path":"id:$fileId","version_id":${_numOrQuoted(versionId)}}]',
        'conflict_action': conflictAction,
      },
    );
    return '${data['async_task_id'] ?? ''}';
  }

  /// `Revisions/download`（v1）直链（服务端直接回该版本的字节）
  String revisionDownloadUrl({
    required String fileId,
    required String versionId,
  }) {
    final version = _negotiate('SYNO.SynologyDrive.Revisions', _v1);
    return api.authenticatedUrl(api.apiPath('SYNO.SynologyDrive.Revisions'), {
      'api': 'SYNO.SynologyDrive.Revisions',
      'version': '$version',
      'method': 'download',
      'files':
          '[{"path":"id:$fileId","version_id":${_numOrQuoted(versionId)}}]',
    });
  }

  // -------------------------------------------------------------- 共享

  /// `Sharing/list`（v1）：这个文件共享给了谁（用户/群组；公开链接**不在这里**）。
  ///
  /// 真机：`{path:'id:<file_id>', offset, limit}` 必带 `path`（少了回 1000）。
  Future<List<DriveShareDto>> listShares({
    required String fileId,
    int offset = 0,
    int limit = 200,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Sharing',
      'list',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Sharing', _v1),
      params: {'path': 'id:$fileId', 'offset': offset, 'limit': limit},
    );
    return DriveShareDto.listFromJson(data);
  }

  /// `Sharing/update`（v1）：邀请成员 / 改权限 / 移除成员。
  ///
  /// 真机双向验证过（`tool/drive_share_probe.dart`）：邀请后 `Sharing/list` 立刻
  /// 出现该成员，移除后回到空。
  Future<void> updateShares({
    required String fileId,
    required List<DriveShareChange> changes,
  }) async {
    await api.call(
      'SYNO.SynologyDrive.Sharing',
      'update',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Sharing', _v1),
      params: {
        'path': 'id:$fileId',
        'permissions': jsonEncode([for (final c in changes) c.toJson()]),
      },
    );
  }

  /// `Sharing/create_link`（v1）：拿到（没有就创建）这个文件的公开链接。
  ///
  /// 真机：`{path:'id:<file_id>'}` → `{url:"https://<host>/d/f/<permanent_link>"}`。
  Future<String> createShareLink({required String fileId}) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Sharing',
      'create_link',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Sharing', _v1),
      params: {'path': 'id:$fileId'},
    );
    return '${data['url'] ?? ''}';
  }

  /// `Share.Priv/list`（v1）：共享成员候选（搜索用户/群组）。
  ///
  /// 真机：`{query, limit, additional:'["nickname"]'}` →
  /// `{list:[{id, name, nickname, type:'user'|'group'}], offset, total}`。
  /// `filter:'{"login":false}'` 可以过滤掉没登录过的账号（官方 Web 同款）。
  Future<List<({String name, String nickname, String type})>> searchPrincipals({
    String query = '',
    int limit = 50,
    bool onlyLoggedIn = true,
  }) async {
    final params = <String, dynamic>{
      'query': query,
      'limit': '$limit',
      'additional': '["nickname"]',
      if (onlyLoggedIn) 'filter': '{"login":false}',
    };
    final data = await api.call(
      'SYNO.SynologyDrive.Share.Priv',
      'list',
      preferredVersion: 1,
      params: params,
    );
    final raw = (data['list'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map(
          (e) => (
            name: '${e['name'] ?? ''}',
            nickname: '${e['nickname'] ?? ''}',
            type: '${e['type'] ?? 'user'}',
          ),
        )
        .where((e) => e.name.isNotEmpty)
        .toList(growable: false);
  }

  // -------------------------------------------------- 高级共享（AdvanceSharing）

  /// `AdvanceSharing/get`（v1）：这个条目的**公开链接**（"高级共享"链接）。
  ///
  /// 原文证据：官方 `SYNO.SDS.Drive.WebAPIDesc.get_adv_sharing` =
  /// `{api:"SYNO.SynologyDrive.AdvanceSharing", method:"get", version:1}`
  /// （`/tmp/spk/export_SynologyDrive/drive/synodrive_common.js:514992` 起）；
  /// 调用参数 `{path:this.path}`（同文件 `:294847`）；回包字段 `url` /
  /// `role` / `protect_password` / `due_date` / `sharing_link`
  /// （`_onSetLinkInfo`，同文件 `:294700` 附近）。
  ///
  /// 文件不存在/未开启过高级共享时官方前端吃 `1036`（同文件 `:294847` 的
  /// `.catch`），调用方自行处理即可。
  Future<DriveAdvanceSharingDto> getAdvanceSharing({
    required String path,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.AdvanceSharing',
      'get',
      preferredVersion: _negotiate('SYNO.SynologyDrive.AdvanceSharing', _v1),
      params: {'path': path},
    );
    return DriveAdvanceSharingDto.fromJson(data);
  }

  /// `AdvanceSharing/create`（v1）：给这个条目开一个公开链接。
  ///
  /// 原文证据：描述符 `create_adv_sharing`（`synodrive_common.js:514992` 起）；
  /// 调用参数 `{path:this.path}`（`_onCreateLink`，同文件 `:295184`）；
  /// 官方拿回包里的 `url`（并配合 `get_adv_sharing` 取 role/密码/有效期）。
  Future<DriveAdvanceSharingDto> createAdvanceSharing({
    required String path,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.AdvanceSharing',
      'create',
      preferredVersion: _negotiate('SYNO.SynologyDrive.AdvanceSharing', _v1),
      params: {'path': path},
    );
    return DriveAdvanceSharingDto.fromJson(data);
  }

  /// `AdvanceSharing/update`（v1）：改公开链接的角色 / 有效期。
  ///
  /// 原文证据：描述符 `update_adv_sharing` 的 `copyTo` 参数表
  /// 是 **`path, sharing_link, role, protect_password, due_date`**
  /// （[dart] `WebAPI.updateAdvSharingLink`，`synodrive_common.js:576450`）；
  /// 调用参数 `{path, sharing_link, role, protect_password, due_date}`
  /// （`_onSaveLink`，同文件 `:296719`）。
  ///
  /// ## ★ 第 59 轮**订正**：`protect_password` 是**明文字段**，不需要加密
  ///
  /// 这里原先写着"官方对 `protect_password` 挂了
  /// `encryption:["protect_password"]`，本仓库不支持，故只发 role/due_date"。
  /// **那句话是错的**，是我早期未经验证的假设。三条独立证据都否掉它：
  ///
  /// 1. **APK**：`ApiSynoDriveAdvanceSharing.java:92` 就是裸的
  ///    `putParam(PARAM_KEY__PROTECT_PASSWORD, …)`，
  ///    而 `putParam` 的属性表里**没有任何加密标记**
  ///    （对比登录的 `passwd` 才走 `DsmCgiEncryption`）；
  /// 2. **服务端 `.lib`（权威 JSON）**：整份
  ///    `webapi/drive/SYNO.SynologyDrive.lib` 里 **`encryption` 出现 0 次**；
  ///    `AdvanceSharing` 的方法表只有 `grantByUser`/`grantable`/`allowDemo`；
  /// 3. **服务端二进制**：`libsynosyncservercore.so` 直接把
  ///    `protect_password` 当成 **DB 列**读写
  ///    （`SELECT id, sharing_link, permanent_id, role, uid, protect_password, due_date …`），
  ///    并未出现 `cipherkey`/`ciphertoken` 解密路径。
  ///
  /// ⇒ 密码与 `due_date` / `role` 同级，都是**普通表单字段**
  /// （靠 HTTPS 保护）。所以[updateAdvanceSharing]一直**能**发密码 ——
  /// 真正缺的只是**UI 上没有让人填密码/点"新建公开链接"的入口**（D39 的 UI 半边）。
  ///
  /// ## 官方流程：先 `create` 再 `update`
  /// `setAsCreate(fileId)` **只传 `path`**（`ApiSynoDriveAdvanceSharing.java:60-67`），
  /// 保护设置全在 `setAsUpdate` 里 ⇒ 与[createAdvanceSharing]的现状一致。
  ///
  /// ## `role` 的官方取值全集（`ApiSynoDriveAdvanceSharing.java:23-29`）
  /// `viewer` / `previewer` / `preview_commenter` / `commenter` /
  /// `editor` / `organizer`（`convertPermissionTypeToRole`）。
  /// ## ★ 第 59 轮：补上 `protect_password`（此前**完全没发**）
  ///
  /// 官方 `setAsUpdate` 的参数是**五个**：
  /// `path` / `sharing_link` / `due_date` / `role` / `protect_password`
  /// （`ApiSynoDriveAdvanceSharing.java:81-93`）。我方此前只发了前四个，
  /// 所以"给公开链接设密码"在协议层就做不到。
  ///
  /// ⚠️ **官方语义是"总是发"**：`dueDate == null` 发 `0L`、
  /// `password == null` 发 **空串**（同文件 `:90-92`）。
  /// 也就是说 `update` 是一个**全量覆盖**操作 —— 传空串等于**清掉密码**。
  /// 这里**照官方实现**（保持"与 APP 一致"），调用方必须传**当前完整状态**，
  /// 不能只传要改的那一项。这一点已在用例里钉住。
  Future<void> updateAdvanceSharing({
    required String path,
    required String sharingLink,
    DriveShareRole? role,
    int? dueDate,
    String? protectPassword,
  }) async {
    await api.call(
      'SYNO.SynologyDrive.AdvanceSharing',
      'update',
      preferredVersion: _negotiate('SYNO.SynologyDrive.AdvanceSharing', _v1),
      params: {
        'path': path,
        'sharing_link': sharingLink,
        // 官方：null ⇒ 0（"无有效期"）
        'due_date': dueDate ?? 0,
        if (role != null) 'role': role.value,
        // 官方：null ⇒ 空串（**会清掉已有密码**，见上面 ⚠️）
        'protect_password': protectPassword ?? '',
      },
    );
  }

  /// `AdvanceSharing/delete`（v1）：关掉公开链接。
  ///
  /// 原文证据：描述符 `remove_adv_sharing`（`synodrive_common.js:514992` 起）；
  /// 调用参数 `{path, sharing_link}`（`_onRemoveLink`，同文件 `:295900`）。
  Future<void> deleteAdvanceSharing({
    required String path,
    required String sharingLink,
  }) async {
    await api.call(
      'SYNO.SynologyDrive.AdvanceSharing',
      'delete',
      preferredVersion: _negotiate('SYNO.SynologyDrive.AdvanceSharing', _v1),
      params: {'path': path, 'sharing_link': sharingLink},
    );
  }

  /// `AdvanceSharing.Public / auth`（**v1**）：校验"公开链接"的访问密码（D40）。
  ///
  /// ## 原文证据
  ///
  ///   * 官方公开分享页描述符 `auth_adv_sharing`
  ///     （`synodrive_common.js:19`）带 `encryption:["password"]`；
  ///     密码路由 `case c.VA.ADV_SHARING_PASSWORD: return "/password"`
  ///     （`drive/mobile-sharing/js/app.2e77ae12.js`，`drive-parity-audit.md:375`）；
  ///   * `SYNO.API.Info` **真机注册**（本会话只读探针，2026-09-22）：
  ///     `SYNO.SynologyDrive.AdvanceSharing.Public`
  ///     `{path:"entry.cgi", minVersion:1, maxVersion:1}`。
  ///
  /// ## 真机取证（普通用户 `demo_user`，DSM 7.2，**只读**）
  ///
  /// ```text
  /// AdvanceSharing.Public/auth v1 （无参）                → 1036 Invalid sharing_link
  /// AdvanceSharing.Public/auth v1 {sharing_link=bogus}    → 1036 Invalid sharing_link
  /// AdvanceSharing.Public/auth v1 {sharing_link=bogus,password=x} → 1036 Invalid sharing_link
  /// AdvanceSharing/verify       v1 {path=…}               → 105 permission denied (admin only)
  /// AdvanceSharing/verify       v1 {path=…,password=x}    → 105 permission denied (admin only)
  /// AdvanceSharing/get          v1 {path=/mydrive/PhotoBackup} → 1036 sharing link not created
  /// ```
  ///
  /// ⇒ 两条硬结论：
  ///   1. `AdvanceSharing.Public/auth` **普通用户可达**（回 1036 而不是 105）——
  ///      它就是匿名访客校验公开链接密码的那条路；
  ///   2. `AdvanceSharing/verify` 在本机是 **管理员专属**（105 `admin only`，
  ///      line 592），`api-server-authoritative.md:754` 把它记成普通用户是**错的**。
  ///      **我们绝不发 `verify`**——发了对普通用户必 105。
  ///
  /// ## 未取证（如实登记）
  ///
  /// 本机 `/mydrive` 14 个条目**没有一个开过公开链接**（`adv_shared` 全 false），
  /// 且"建链接"是写操作（本批纪律禁止），所以**没有**"带正确密码的成功回包"原文。
  /// 参数名 `password` 来自官方描述符的 `encryption:["password"]`（原文级证据），
  /// 但服务端是否强制要求该字段**先经过 `SYNO.API.Encryption` 公钥加密**
  /// **未取证**（本仓库 `DsmWebApi.call` 不支持 `encryption`，见
  /// [updateAdvanceSharing] 的同类说明）。这里按**明文**发送，成功/失败都由
  /// 服务端裁判；页面把"被拒"如实体现在 UI 上，绝不伪装成成功。
  ///
  /// 返回 `true` = 服务端接受该密码；`false` = 被拒（密码错 / 链接失效，
  /// 服务端都以 `success:false` 表达）。**传输层错误照常抛出**
  /// （`DsmTransportException`），不会把"断网"伪装成"密码错"。
  Future<bool> authAdvanceSharingPassword({
    required String sharingLink,
    required String password,
  }) async {
    try {
      await api.call(
        'SYNO.SynologyDrive.AdvanceSharing.Public',
        'auth',
        preferredVersion: _negotiate(
          'SYNO.SynologyDrive.AdvanceSharing.Public',
          _v1,
        ),
        params: {'sharing_link': sharingLink, 'password': password},
      );
      return true;
    } on DsmApiException {
      // 服务端拒绝（官方公开页此时停在 /password 让访客重试）
      return false;
    }
  }

  // -------------------------------------------------------------- 标签

  /// `Labels/list`（v1）：个人标签表（`type` = `personal_label`）
  Future<List<DriveLabelDto>> listLabels({bool shared = false}) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Labels',
      'list',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Labels', _v1),
      params: {if (shared) 'type': 'shared_label'},
    );
    return DriveLabelDto.listFromJson(data);
  }

  /// `Labels/create`（v1）：新建标签（名字必须 Gson 引号串）
  Future<DriveLabelDto> createLabel(String name) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Labels',
      'create',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Labels', _v1),
      params: {'name': '"$name"'},
    );
    return DriveLabelDto.fromJson(data);
  }

  /// `Labels/update`（v1）：改名 / 改色
  Future<DriveLabelDto> updateLabel({
    required String labelId,
    String? name,
    String? color,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Labels',
      'update',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Labels', _v1),
      params: {
        'label_id': '"$labelId"',
        if (name != null) 'name': '"$name"',
        if (color != null) 'color': '"$color"',
      },
    );
    return DriveLabelDto.fromJson(data);
  }

  /// `Labels/delete`（v1）：删标签（`label_id` 要引号串，裸串回 1006）
  Future<void> deleteLabel(String labelId) async {
    await api.call(
      'SYNO.SynologyDrive.Labels',
      'delete',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Labels', _v1),
      params: {'label_id': '"$labelId"'},
    );
  }

  // ------------------------------------------------------------ 收藏集（D8）

  /// `Labels/list`（**v2 起**）—— 列出收藏集（官方 `DriveCategory.Collection`）。
  ///
  /// ## 原文证据（反编译 `Android-SynologyDrive.3.9.0-1113.ww.apk`）
  ///
  /// `ApiSynoDriveLabels.setAsListCollection(FileGroup)`（`:117-135`）就是
  /// `Labels/list` + `putParam("type", group.getLabelTypeValue())`，
  /// 版本 `Math.min(2, api.getMaxVersion())`；四个类型串见
  /// [DriveCollectionType] 的注释（`LabelImpl.java:39-42`）。
  ///
  /// ## 真机只读实测（本批；普通用户，DSM 7.2）
  ///
  /// ```text
  /// Labels:list v3 {"type":"photo_album"}     → {"items":[],"total":0} success
  /// Labels:list v3 {"type":"document_folder"} → {"items":[],"total":0} success
  /// Labels:list v3 {"type":"audio_playlist"}  → {"items":[],"total":0} success
  /// Labels:list v3 {"type":"video_playlist"}  → {"items":[],"total":0} success
  /// Labels:list v2 {"type":"photo_album"}     → {"items":[],"total":0} success
  /// ```
  ///
  /// ⇒ 四个类型都认；本机**没有收藏集**，空 `items` 是真实业务结果。
  /// [type] 为 `null` 时不带 `type`（服务端按个人标签语义回，仅作兜底）。
  Future<List<DriveCollectionDto>> listCollections({
    DriveCollectionType? type,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Labels',
      'list',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Labels', _vCollection),
      params: {if (type != null) 'type': type.apiValue},
    );
    return DriveCollectionDto.listFromJson(data);
  }

  /// `Labels/create`（v2 起）+ `type` —— 新建收藏集。
  ///
  /// 官文 `setAsCreateCollection(group, name, color)`：`type`（必给）、
  /// `name`、可选 `color`（`#rrggbb`，官方做了 `& 0xffffff` 掩码）。
  ///
  /// ⚠️ **这是写方法：按 §5.1 本批一次都没调**。参数形状按官方逐字实现；
  /// `name` 沿用**同 API 同参数**已真机验证过的约定——`Labels/create` 的
  /// `name` 必须是 **Gson 引号串**（见 [createLabel] 与 `drive_label_dto.dart`
  /// 的注释，真机 2026-09-19）。⇒ **未真机验证**，见报告"未完成清单"。
  Future<DriveCollectionDto> createCollection({
    required String name,
    required DriveCollectionType type,
    String? color,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Labels',
      'create',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Labels', _vCollection),
      params: {
        'type': type.apiValue,
        'name': '"$name"',
        if (color != null) 'color': '"$color"',
      },
    );
    return DriveCollectionDto.fromJson(data);
  }

  /// `Labels/update` + `label_id` —— 收藏集改名 / 改色（官方与标签**共用**
  /// `setAsUpdate`，见 `ApiSynoDriveLabels.java` 的 `setAsUpdate`）。
  ///
  /// 写方法：**本批不调**，按官方参数形状实现，未真机验证。
  Future<DriveCollectionDto> updateCollection({
    required String collectionId,
    String? name,
    String? color,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Labels',
      'update',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Labels', _vCollection),
      params: {
        'label_id': '"$collectionId"',
        if (name != null) 'name': '"$name"',
        if (color != null) 'color': '"$color"',
      },
    );
    return DriveCollectionDto.fromJson(data);
  }

  /// `Labels/delete` + `label_id` —— 删除收藏集（官方与标签**共用**
  /// `setAsDelete`）。**只删收藏集容器，不动里面的文件**。
  ///
  /// 写方法：**本批不调**，按官方参数形状实现，未真机验证。
  Future<void> deleteCollection(String collectionId) async {
    await api.call(
      'SYNO.SynologyDrive.Labels',
      'delete',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Labels', _vCollection),
      params: {'label_id': '"$collectionId"'},
    );
  }

  /// 把文件**加入收藏集**：`Files/label` 的动作数组（不是 Collections 方法）。
  ///
  /// 原文：`FileRepositoryNet.labelFiles(fileIds, toBeAddedLabels, toBeRemoved)`
  /// → `FileLabelWork` → `ApiSynoDriveFiles.setAsLabelFiles(...)`
  /// （`ApiSynoDriveFiles.java:614-632`），动作 `{"action":"add","label_id":<int>}`。
  /// 因此这里**直接复用 [setLabels]**（同一套真机验证过的形状）。
  Future<void> addFilesToCollection({
    required List<String> fileIds,
    required String collectionId,
  }) => setLabels(
    fileIds: fileIds,
    changes: [DriveLabelChange.add(collectionId)],
  );

  /// 把文件**移出收藏集**：`Files/label` 动作 `{"action":"delete",...}` 逐字
  /// （`setAsLabelFiles` 里 `map2.put("action", "delete")`）。
  Future<void> removeFilesFromCollection({
    required List<String> fileIds,
    required String collectionId,
  }) => setLabels(
    fileIds: fileIds,
    changes: [DriveLabelChange.remove(collectionId)],
  );

  /// 收藏集里的文件：收藏集与标签同存储，官方 Web 端用
  /// `Files/list_labelled`（真机已验证，见 [listLabelled]）。
  Future<({List<DriveEntryDto> items, int total})> listCollectionFiles({
    required String collectionId,
    int offset = 0,
    int limit = 200,
  }) => listLabelled(labelId: collectionId, offset: offset, limit: limit);

  /// `Files/delete`（v2）：**普通删除 = 进回收站**。
  ///
  /// 真机取证（`docs/live-write-verification.md` §7 与
  /// `docs/live-nas-verification.md` 附录 A.1，2026-09-21，A/B 两个同内容临时文件）：
  ///   * `files` 必须是 **JSON 数组字符串**（`'["id:…"]'`），回包 `{async_task_id}`；
  ///   * **不传额外参数** → 进回收站（这是唯一对**活动文件**有效的删除形态）；
  ///   * `permanent_delete: true` → **服务端不识别**（等同不传，照样进回收站；
  ///     整个 Drive 包里**没有** `permanent_delete` 这个串）；
  ///   * `permanent: true` → 对**活动文件**是**静默 no-op**：照样回
  ///     `async_task_id`，但文件既没删、也没进回收站。
  ///
  /// ⇒ 本方法**只发 `files`**：既不会给用户"已彻底删除"的假承诺，也不会误伤。
  /// 要把条目从回收站**彻底清掉**，用 [deleteFromTrash]（`permanent:true`
  /// 只对**回收站条目 id** 有效）。
  Future<String> delete({required List<String> fileIds}) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Files',
      'delete',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v2),
      params: <String, dynamic>{'files': _jsonIds(fileIds)},
    );
    return '${data['async_task_id'] ?? ''}';
  }

  /// `Files/delete`（v2）+ **`permanent: true`**：从回收站**彻底清除**。
  ///
  /// [trashFileIds] 必须是**回收站条目的 id**（`Trash/list` 回的 `file_id`），
  /// **不是**活动文件的 id：
  ///   * 对回收站条目发 `permanent:true` → 真机 ✅ **从回收站永久消失**；
  ///   * 对活动文件发 `permanent:true` → 真机 ❌ 静默 no-op（文件一动没动）；
  ///   * 参数名**不是** `permanent_delete`（服务端不认识的串，见 [delete]）。
  ///
  /// 「彻底删除」在真机上是**两步**：① 普通删除进回收站（[delete]）→
  /// ② 用回收站里的条目 id 调本方法。调用方不要用"名字"去回收站里猜 id。
  Future<String> deleteFromTrash({required List<String> trashFileIds}) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Files',
      'delete',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v2),
      params: <String, dynamic>{
        'files': _jsonIds(trashFileIds),
        'permanent': true,
      },
    );
    return '${data['async_task_id'] ?? ''}';
  }

  /// `Trash/list`（v1）：回收站列表。
  ///
  /// ⚠️ 真机实测的坑：**必须带 `path`**（空间路径，如 `/mydrive`）和
  /// `offset`/`limit`；少了 `path` 会回 `1000`（看着像"未知错误"，其实是缺参数），
  /// 而且要 **v1**（表里写着 maxVersion 2，但发 v2 也是 `1000`）。
  Future<({List<DriveEntryDto> items, int total})> listTrash({
    String path = kDriveRoot,
    int offset = 0,
    int limit = 200,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Trash',
      'list',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Trash', const [1]),
      params: {'path': path, 'offset': offset, 'limit': limit},
    );
    return DriveEntryDto.listFromJson(data);
  }

  /// `Trash/list`（**v1..3**）—— **指定文件夹**的回收站（团队文件夹误删项）。
  ///
  /// ## 为什么不是"给 [listTrash] 换个 path"就完事：官方原文
  ///
  /// 反编译 `ApiSynoDriveTrash.setAsList`（`ApiSynoDriveTrash.java`）逐字：
  /// ```java
  /// putParam("version", Math.min(3, api.getMaxVersion()));   // VersionComputer
  /// if (dataSource.isForMyDrive())      path = Constants.MYDRIVE_PATH;      // "/mydrive"
  /// else if (dataSource.isForFolder())  path = UtilsForApi.computePathById(dataSource.getFolderId());
  /// else                                path = "";
  /// putParam("path", path);
  /// ```
  /// ⇒ **团队文件夹回收站**在官方有两条构造：
  ///   1. `generateInstanceForFolder(folderId, isRemoved=true)`
  ///      （`DataSource.java` 的 `generateInstanceForFolder$default(..., isRemoved=true)`，
  ///      也被 `generateInstanceForEmptyRecycleBin` 用于团队文件夹：命中
  ///      `rootDataSource.isForTeamFolders()` 时走 `generateInstanceForFolder`）
  ///      ⇒ path = **`id:<folder_id>`**；
  ///   2. `generateInstanceForTeamFolder(isRemoved=true)`（`DataSource.java:319-325`）
  ///      ⇒ **不设 folderId**，命中上面 `else` 分支 ⇒ path = **空串**。
  ///
  /// ## 真机只读实测（本批；普通用户，DSM 7.2）——两条都试了
  ///
  /// ```text
  /// Trash:list v1 {"path":"/mydrive",          ...} → success（26 条）
  /// Trash:list v2 {"path":"/mydrive",          ...} → success（同上）
  /// Trash:list v1 {"path":"",                  ...} → 1000 "list node failed"
  /// Trash:list v2 {"path":"",                  ...} → 1000 "list node failed"
  /// Trash:list v2 {"path":"id:974457808523148038",...} → success（该目录的误删项）
  /// Trash:list v1 {"path":"id:974457808523148038",...} → success（同上）
  /// ```
  ///
  /// ⇒ **本机 `path=""` 不可用（1000）**，而 `path="id:<folder_id>"` 可用
  /// （本机团队文件夹为 0 个，所以拿个人空间的目录 id 做了等价验证）。
  /// 本方法因此实现 `isForFolder` 那条（**有 id、可验证**），
  /// `path=""` 那条**如实登记为待确认**，不硬猜。
  ///
  /// ## 版本
  /// 走 [_vTrash]（`[3,2,1]`）按服务端协商：本机 maxVersion 2 ⇒ 发 **v2**
  /// （与官方 `Math.min(3, maxVersion)` 一致，且真机过）。
  ///
  /// ## 只读
  /// `list` 是读动词；本条**不产生任何服务端副作用**。
  Future<({List<DriveEntryDto> items, int total})> listFolderTrash({
    required String folderId,
    int offset = 0,
    int limit = 200,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Trash',
      'list',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Trash', _vTrash),
      params: {'path': _pathId(folderId), 'offset': offset, 'limit': limit},
    );
    return DriveEntryDto.listFromJson(data);
  }

  /// `Trash/empty`（v1）：清空回收站。`path` 是空间路径（`/mydrive`）。
  Future<String> emptyTrash({String path = kDriveRoot}) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Trash',
      'empty',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Trash', const [1]),
      params: {'path': path},
    );
    return '${data['async_task_id'] ?? ''}';
  }

  /// `Revisions/restore`（v1）：**从回收站恢复**。
  ///
  /// 原文证据（官方 Web 端把"回收站 → 恢复"接到 `Revisions/restore`）：
  ///   * 描述符 `restore_revisions` = `{api:"SYNO.SynologyDrive.Revisions",
  ///     method:"restore", version:1}`（`synodrive_common.js:511981`）；
  ///   * **回收站自己的**恢复动作构造参数是
  ///     `t.push({path:getPathId(file_id)})` → `restoreFileVersion({files:t,
  ///     dry_run:true, action:"restore"})`（`drive/synodrive.js:108914`）；
  ///   * `WebAPI.restoreNode` 的 `copyTo` 白名单是
  ///     **`files, conflict_action, to_parent_folder`**（`synodrive_common.js:571465`）
  ///     —— `dry_run` / `action` 在上行前被丢掉。
  ///
  /// 所以本方法发 `files = [{"path":"id:<id>"}]` + `conflict_action`（默认
  /// `autorename`）；`version_id` **不带**（回收站恢复的是节点本身，不是版本）。
  ///
  /// ⚠️ 与官方 UI 的两点差异（有意为之，见文档"未验证边界"）：
  ///   1. 官方先发一次 `dry_run:true` 探测冲突、必要时弹冲突框再发正式请求；
  ///      本方法**不探测**，直接带 `conflict_action:autorename`；
  ///   2. 整条调用**未在真机验证**（本批未动设备）。
  Future<String> restoreTrash({
    required List<String> fileIds,
    String conflictAction = 'autorename',
    String? toParentFolder,
  }) async {
    final files =
        '[${fileIds.map((id) {
          final p = id.startsWith('id:') ? id : 'id:$id';
          return '{"path":"${p.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"}';
        }).join(',')}]';
    final data = await api.call(
      'SYNO.SynologyDrive.Revisions',
      'restore',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Revisions', _v1),
      params: {
        'files': files,
        'conflict_action': conflictAction,
        'to_parent_folder': ?toParentFolder,
      },
    );
    return '${data['async_task_id'] ?? ''}';
  }

  /// `Files/copy` / `Files/move`（**v2**）—— `to_parent_folder` 是 path id。
  ///
  /// 原文证据（P0-7）：
  ///   * APK `ApiSynoDriveFiles.java:557-565`（move）/ `:579-587`（copy）：
  ///     `putParam("files", paths, "to_parent_folder", path,
  ///     "conflict_action", "autorename")`；`METHOD_NAME__COPY="copy"` /
  ///     `__MOVE="move"`（`:47-48`）、`CONFLICT_ACTION__{AUTORENAME,OVERWRITE,
  ///     STOP}="autorename"/"overwrite"/"stop"`（`:44-46`）。
  ///   * 官方 Web 描述符 `copy_files` / `move_files` 都是 **v2**
  ///     （`synodrive_common.js:18`）；上行白名单
  ///     `copy` = `files,to_parent_folder,conflict_action,dry_run`、
  ///     `move` 另加 `change_name`（`:20`）。
  ///
  /// ⚠️ 任务简报里的 `dest_folder` / `accurate_progress` 在 APK 与 SPK/Web
  /// 全量检索里**都不存在**（`grep` 零命中）→ **不实现**（见文档"证不到"清单）。
  /// [conflictAction] 只接受官方三个取值（见 `DriveConflictAction`）。
  Future<String> copyOrMove({
    required List<String> fileIds,
    required String toParentFolderId,
    required bool move,
    String conflictAction = DriveConflictAction.autorename,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Files',
      move ? 'move' : 'copy',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v2),
      params: {
        'files': _jsonIds(fileIds),
        'to_parent_folder': 'id:$toParentFolderId',
        'conflict_action': conflictAction,
      },
    );
    return '${data['async_task_id'] ?? ''}';
  }

  /// `Files/copy|move` 的 **同名冲突探测**（`dry_run:true`）。
  ///
  /// 原文证据（官方 Web `mvcpNode`，`synodrive_common.js:20`）：
  /// ```js
  /// var s=Ext.applyIf(t||{},{dry_run:!0});
  /// if(s.conflict_action||!1===s.dry_run)return delete s.dry_run,void this.doMvcpNode(...);
  /// sendPromise(o,s).then(function(t){ delete s.dry_run,
  ///   t.result&&this.needToShowConflictDialog(t.result)?...
  ///     showConflictDialog(...):this.doMvcpNode(...)})
  /// ```
  /// —— 即：**先只发 `dry_run:true`（不带 `conflict_action`）**，服务端回
  /// `result[]`（每项 `src_info`/`dst_info`/`dst_locked_by_others`/`renamed`）。
  /// 这是官方"同名冲突"的探测路径；Android 端不探测、恒 autorename
  /// （`ApiSynoDriveFiles.java:563/585`），两处原文都在本文件与文档里记着。
  ///
  /// 返回可处理的冲突列表（等价官方 `needToShowConflictDialog`：全被他人锁住的
  /// 项不算），空列表 = 无冲突、可直接发正式请求。
  Future<List<DriveMoveConflict>> probeCopyMove({
    required List<String> fileIds,
    required String toParentFolderId,
    required bool move,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Files',
      move ? 'move' : 'copy',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v2),
      params: {
        'files': _jsonIds(fileIds),
        'to_parent_folder': 'id:$toParentFolderId',
        'dry_run': true,
      },
    );
    return DriveMoveConflict.listFromResult(data['result']);
  }

  /// `SYNO.Office.Node.Encrypt:check`（**v1**）—— 加密 Office 文档探测（P0-11）。
  ///
  /// 原文证据：
  ///   * APK `ApiSynoOfficeNodeEncrypt.java:11-45`：API
  ///     `"SYNO.Office.Node.Encrypt"`、方法 `"check"`、参数
  ///     `path`（`UtilsForApi.computePathById(fileId)` = `id:<file_id>`）、
  ///     `password`、可选 `sharing_token`。
  ///   * SPK `/tmp/spk/out/Office.apis.txt:56-57` `v1: check`；服务端 lib
  ///     `methods.1[0].check`（`/tmp/spk/export_Office/webapi/SYNO.Office.lib`）。
  ///   * 官方 Web 调用点（`drive/mobile-sharing/js/app.2e77ae12.js:1`）：
  ///     `{api:"SYNO.Office.Node.Encrypt",method:"check",version:1,
  ///      params:{path,password,sharing_token}}`。
  ///
  /// 语义（APK `SynologyDriveExceptionInterpreter.java:248-250`）：密码不对 /
  /// 文件加密时服务端回 **`57373`**（`isNeedPasswordException`）；成功 = `true`。
  /// 我们用空密码探一次即可判定"是否加密"。
  ///
  /// 返回 `true` = 校验通过（未加密，或密码正确）；`false` = 服务端明确回
  /// `57373`（需要密码）。其它错误（API 不存在 102 等）**原样抛出**，由调用方
  /// fail-open 跳过提示（见 `DriveEncryptGate`）。
  Future<bool> officeEncryptCheck({
    required String fileId,
    String password = '',
    String? sharingToken,
  }) async {
    try {
      await api.call(
        'SYNO.Office.Node.Encrypt',
        'check',
        preferredVersion: _negotiate('SYNO.Office.Node.Encrypt', _v1),
        params: {
          'path': 'id:$fileId',
          'password': password,
          if (sharingToken != null && sharingToken.isNotEmpty)
            'sharing_token': sharingToken,
        },
      );
      return true;
    } on DsmApiException catch (e) {
      // 57373 = 需要密码（官方 `isNeedPasswordException` 的码）
      if (e.code == kDriveNeedPasswordCode) return false;
      rethrow;
    }
  }

  /// 旧接口（原始 Map 形态）：标签表。新代码请用 [listLabels]。
  Future<List<Map<String, dynamic>>> labels() async {
    final data = await api.call(
      'SYNO.SynologyDrive.Labels',
      'list',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Labels', _v1),
    );
    return ((data['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList(growable: false);
  }

  /// `Info/get` —— 账号昵称/是否管理员/版本（工作台卡片与设置页用）
  Future<Map<String, dynamic>> info() =>
      api.call('SYNO.SynologyDrive.Info', 'get', preferredVersion: _v1.first);

  // 注意：`Info/quota` 的唯一实现在下方「配额 / 用量」小节（返回 DriveQuotaDto）。
  // 这里曾有一个返回 Map<String, dynamic> 的同名旧实现，与 wave2 新增的实现
  // 构成 duplicate_definition 并使整包无法编译，已删除（旧实现无任何调用方）。

  // ------------------------------------------------------ 已连接的客户端（Connection）
  //
  // 方法表（权威，SPK 自带）：
  // `/tmp/spk/export_SynologyDrive/webapi/drive/SYNO.SynologyDrive.lib` 逐字
  // `"SYNO.SynologyDrive.Connection"` → `minVersion:1, maxVersion:2`，
  // `methods:{1:[list,delete], 2:[list,delete,summary]}`，
  // `allowUser` 含 `normal.local/domain/ldap` ⇒ **普通用户可调**。
  //
  // ⚠️ **只做 `list`**；`delete` 命中 §5.1 变更动词黑名单，**永不调用**。

  /// `Connection/list`（**v2 优先，回退 v1**）：已连接 Drive 的客户端 / 设备。
  ///
  /// 真机只读实测（普通账号，`docs/g6-api-probe-facts.md:37`）：
  /// **v1 与 v2 都 `success`**、**无必填参数**，
  /// 回 `{"items": [], "total": 0}`（本账号没有任何已连接设备）。
  ///
  /// 条目字段白名单见 [DriveConnectionDto]（九项，来自 `.so` 字符串常量）。
  Future<DriveConnectionListDto> listConnections() async {
    final data = await api.call(
      'SYNO.SynologyDrive.Connection',
      'list',
      preferredVersion: _negotiate(
        'SYNO.SynologyDrive.Connection',
        _vConnection,
      ),
    );
    return DriveConnectionListDto.fromJson(data);
  }

  // ------------------------------------------------------ 请求文件（FileRequest）
  //
  // 方法表原文：`SYNO.SynologyDrive.FileRequest` v1 =
  // `get delete update create list verify`（`/tmp/spk/out/SynologyDrive.apis.txt:39`）。
  // ⚠️ 未取证：`verify`（无任何客户端调用点/参数原文）→ **不实现**。

  /// `FileRequest/list`（v1）：我发出的"请求文件"链接。
  ///
  /// 原文证据：描述符 `list_file_request`（`synodrive_common.js:515851` 起）；
  /// 分页 `offset`/`limit` + 过滤 `status`（`ViewStore.FileRequest.getBaseParams`
  /// / `getLoadParam`，同文件 `:496067`），默认排序 `created_time DESC`。
  Future<({List<DriveFileRequestDto> items, int total})> listFileRequests({
    String? status,
    int offset = 0,
    int limit = 200,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.FileRequest',
      'list',
      preferredVersion: _negotiate('SYNO.SynologyDrive.FileRequest', _v1),
      params: {
        'offset': offset,
        'limit': limit,
        if (status != null && status.isNotEmpty) 'status': status,
      },
    );
    return DriveFileRequestDto.listFromJson(data);
  }

  /// `FileRequest/create`（v1）：新建一个"请求文件"链接。
  ///
  /// 原文证据：官方 Vue `createFileRequest()`（`drive/drive_bundle.js:1639894`）
  /// 组装的参数表，与 `getParams()`（同文件 `:1640420`）逐字一致：
  /// `title` / `identifier` / `description` / `protect_password` / `due_date` /
  /// `has_due_date_hour`，外加 `path:"id:<folder_id>"`（目标文件夹）。
  ///
  /// ★ `protect_password` 同 [updateAdvanceSharing]：**就是明文字段**，
  /// 不需要 `encryption`（第 59 轮订正，三条证据见 [updateAdvanceSharing] 的文档）。
  /// 允许传空串（不加密码）。
  Future<DriveFileRequestDto> createFileRequest({
    required String folderId,
    required String title,
    String description = '',
    String identifier = '',
    String protectPassword = '',
    int dueDate = 0,
    bool hasDueDateHour = false,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.FileRequest',
      'create',
      preferredVersion: _negotiate('SYNO.SynologyDrive.FileRequest', _v1),
      params: {
        'title': title,
        'identifier': identifier,
        'description': description,
        'protect_password': protectPassword,
        'due_date': dueDate,
        'has_due_date_hour': hasDueDateHour,
        'path': 'id:$folderId',
      },
    );
    return DriveFileRequestDto.fromJson(data);
  }

  /// `FileRequest/update`（v1）：改标题/说明/有效期，或关闭/重开请求。
  ///
  /// 原文证据：官方 Vue `editFileRequest()`（`drive/drive_bundle.js:1640082`）：
  /// 在 `getParams()` 之上加 `sharing_link`，`path` 是
  /// `id:<folder_id>` 或 **`link:<permanent_link>`**；关闭时补
  /// `file_request_status:"inactive"`（官方 `closeFileRequest` →
  /// `file_request_status:"inactive"` + `sharing_links`/`paths`，
  /// `drive/synodrive.js:114380`）。
  Future<DriveFileRequestDto> updateFileRequest({
    required String sharingLink,
    required String path,
    required String title,
    String description = '',
    String identifier = '',
    String protectPassword = '',
    int dueDate = 0,
    bool hasDueDateHour = false,
    String? fileRequestStatus,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.FileRequest',
      'update',
      preferredVersion: _negotiate('SYNO.SynologyDrive.FileRequest', _v1),
      params: {
        'title': title,
        'identifier': identifier,
        'description': description,
        'protect_password': protectPassword,
        'due_date': dueDate,
        'has_due_date_hour': hasDueDateHour,
        'sharing_link': sharingLink,
        'path': path,
        'file_request_status': ?fileRequestStatus,
      },
    );
    return DriveFileRequestDto.fromJson(data);
  }

  /// `FileRequest/delete`（v1）：删掉一个"请求文件"链接。
  ///
  /// 原文证据：官方 `WebAPI.deleteFileRequest` 逐个链接发
  /// `{sharing_link:<id>}`（`synodrive_common.js:578415` 附近），
  /// 这里的多链接版本由调用方循环（每条各发一次，语义与官方一致）。
  Future<void> deleteFileRequest({required String sharingLink}) async {
    await api.call(
      'SYNO.SynologyDrive.FileRequest',
      'delete',
      preferredVersion: _negotiate('SYNO.SynologyDrive.FileRequest', _v1),
      params: {'sharing_link': sharingLink},
    );
  }

  // ------------------------------------------------------ 通知中心（Notifications）
  //
  // 方法表原文：`SYNO.SynologyDrive.Notifications` v1-2 = `create list delete`
  // （`/tmp/spk/out/SynologyDrive.apis.txt:112`）。

  /// `Notifications/list`（v1）：通知列表。
  ///
  /// 原文证据：官方轮询任务 `params:{limit:100}`（`synodrive_common.js:331025`），
  /// 回包 `result.items[]`，字段见 [DriveNotificationDto]。
  Future<List<DriveNotificationDto>> listNotifications({
    int limit = 100,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Notifications',
      'list',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Notifications', _v1),
      params: {'limit': limit},
    );
    return DriveNotificationDto.listFromJson(data);
  }

  /// `Notifications/create`（v1）：写一条通知。
  ///
  /// 原文证据：官方上传任务结束时
  /// `send("create_notification", {content:t, type:"drive#upload_task"})`
  /// （`synodrive_common.js:635884`）。
  Future<void> createNotification({
    required Object content,
    required String type,
  }) async {
    await api.call(
      'SYNO.SynologyDrive.Notifications',
      'create',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Notifications', _v1),
      params: {'content': jsonEncode(content), 'type': type},
    );
  }

  /// `Notifications/delete`（v1）：**清空全部通知**。
  ///
  /// 原文证据：官方"全部清除"调用 `clearNotifications({params:{}, …})`
  /// （`synodrive_common.js:329203`）——**空参数**。单项删除没有原文，
  /// 因此这里只提供"清空"语义。
  Future<void> clearNotifications() async {
    await api.call(
      'SYNO.SynologyDrive.Notifications',
      'delete',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Notifications', _v1),
      params: const {},
    );
  }

  // ------------------------------------------------------ 文件锁（NodeLocking / Files.lock）
  //
  // ⚠️ `SYNO.SynologyDrive.NodeLocking` **模块本身**（v1 = `list`，
  //    `/tmp/spk/out/SynologyDrive.apis.txt:106`）在官方 Web 端**没有任何调用点**，
  //    参数无原文 → **不实现**（登记为待取证）。
  //    官方 UI 的加锁/解锁走的是 `Files` 模块，参数原文如下。

  /// `Files/lock`（v2）：给文件加锁 / 解锁。
  ///
  /// 原文证据：`WebAPI.lockNode` 的 `copyTo` 参数表
  /// **`files, perform_lock`**（`synodrive_common.js:566000` 附近），
  /// 描述符 `lock_node` = `{api:"SYNO.SynologyDrive.Files", method:"lock",
  /// version:2}`（同文件 `:516019`）。
  /// `perform_lock=false` 即解锁（官方同一个接口两用）。
  Future<void> setNodeLock({
    required List<String> fileIds,
    required bool lock,
  }) async {
    await api.call(
      'SYNO.SynologyDrive.Files',
      'lock',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v2),
      params: {'files': _jsonIds(fileIds), 'perform_lock': lock},
    );
  }

  /// `Files/request_unlock`（v2）：请求锁的持有者解锁（不是强解）。
  ///
  /// 原文证据：`WebAPI.requestUnlock` 的 `copyTo` 参数表 **`path`**
  /// （`synodrive_common.js:567000` 附近），描述符 `request_unlock` =
  /// `{api:"SYNO.SynologyDrive.Files", method:"request_unlock", version:2}`
  /// （同文件 `:516104`）。
  Future<void> requestNodeUnlock({required String path}) async {
    await api.call(
      'SYNO.SynologyDrive.Files',
      'request_unlock',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v2),
      params: {'path': path},
    );
  }

  // ------------------------------------------------------ 团队文件夹成员

  /// `TeamFolders/list_members`（v1）：某个团队文件夹的成员。
  ///
  /// 原文证据：成员 grid store 的
  /// `baseParams:{team_id:<id>, offset:0, limit:100}`
  /// （`synodrive_common.js:225431`）；描述符 `list_team_folders_members` =
  /// `{api:"SYNO.SynologyDrive.TeamFolders", version:1, method:"list_members"}`
  /// （同文件 `:511427`）；读字段 `display_name/name/uid/role`。
  Future<List<DriveTeamMemberDto>> listTeamFolderMembers({
    required String teamId,
    int offset = 0,
    int limit = 100,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.TeamFolders',
      'list_members',
      preferredVersion: _negotiate('SYNO.SynologyDrive.TeamFolders', _v1),
      params: {'team_id': teamId, 'offset': offset, 'limit': limit},
    );
    return DriveTeamMemberDto.listFromJson(data);
  }

  // ------------------------------------------------------ 后台任务（Drive 侧）

  /// `Tasks/list`（v1）：Drive 自己的异步任务（上传/下载/跨空间转存）。
  ///
  /// 官方 Drive 前端 `drive/synodrive_common.js`：
  /// `list_tasks:{api:"SYNO.SynologyDrive.Tasks",method:"list",version:1}`，
  /// 遍历时读 `items[].status` / `result.action` / `result.names` /
  /// `result.total_size` / `progress` / `task_id`。
  ///
  /// ⚠️ 与 File Station 的 `BackgroundTask/list` 是**两套**：那个是文件模块的
  /// 复制/压缩任务，这个是 Drive 的上传/备份任务，UI 上分开列。
  Future<List<DriveTaskDto>> listTasks({
    int offset = 0,
    int limit = 200,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Tasks',
      'list',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Tasks', _v1),
      params: {'offset': '$offset', 'limit': '$limit'},
    );
    return DriveTaskDto.listFromJson(data);
  }

  /// `Tasks/delete`（v1）：删掉一条任务记录（官方传 `{task_id}`，清已完成任务用）
  Future<void> deleteTask(String taskId) async {
    await api.call(
      'SYNO.SynologyDrive.Tasks',
      'delete',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Tasks', _v1),
      params: {'task_id': taskId},
    );
  }

  // ------------------------------------------------------------ 计算机（D21）

  /// `Files/list_backup_tasks`（**v3**）—— 列出正在用 Drive 客户端同步的
  /// **计算机 / 设备**（官方 `DriveCategory.Computers`）。
  ///
  /// ## 原文证据（反编译 `Android-SynologyDrive.3.9.0-1113.ww.apk`）
  ///
  ///   * API/Method 常量：`ApiSynoDriveFiles.METHOD_NAME__LIST_BACKUP_TASKS =
  ///     "list_backup_tasks"`（`:73`），枚举 `Method.LIST_BACKUP_TASKS`（`:167`）；
  ///   * 版本：`setAsComputers(...)` 的 `VersionComputer` =
  ///     **`Math.min(3, api.getMaxVersion())`**（`ApiSynoDriveFiles.java:665` 区）；
  ///   * 分页：`ComputerListWork` 默认 **`offset=0` / `limit=100`**
  ///     （`ComputerListWork.java` 的 `DEFAULT__OFFSET=0`、`DEFAULT__LIMIT=100`）；
  ///   * 条目形状 = **普通 `FileInfoVo`**（`ComputerListWork` 只把它包成
  ///     `ComputerFileInfo extends FileInfo`，`ComputerFileInfo.java` 里**没有
  ///     任何新字段**，只是 `isComputer()` 恒真）⇒ 可以直接复用
  ///     [DriveEntryDto] 解析，**不需要新 DTO**。
  ///
  /// ## 真机取证（本会话，只读；普通用户 `demo_user`，DSM 7.2）
  ///
  /// ```text
  /// Files/list_backup_tasks v3 {offset:0,limit:200} → {"items":[],"total":0} success
  /// Files/list_backup_tasks v2                     → 103 method not found
  /// Files/list_backup_tasks v1                     → 103 method not found
  /// ```
  ///
  /// ⇒ **v3 是硬门槛**（v1/v2 一律 103，与官方 `Math.min(3, …)` 一致）。
  /// 本机当前**没有任何计算机在同步**，所以 `items` 为空是**真实业务结果**，
  /// 不是接口失败；"有设备时的字段"没有真机样本，因此 UI 只展示
  /// [DriveEntryDto] 已经解析过的通用字段，**不新造任何字段**。
  Future<({List<DriveEntryDto> items, int total})> listBackupTasks({
    int offset = 0,
    int limit = 100,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Files',
      'list_backup_tasks',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v3),
      params: {'offset': offset, 'limit': limit},
    );
    return DriveEntryDto.listFromJson(data);
  }

  // ------------------------------------------------- 压缩 / 打包下载（D31/D35）

  /// `Files/download`（**v≤7**）的**打包**直链：多选/整目录 → 服务端现打一个
  /// 压缩包再回字节（官方 `setAsDownload(...)` 的 `archive_name` 变体）。
  ///
  /// ## 原文证据（反编译 `ApiSynoDriveFiles.java:388-412` `setAsDownload`）
  ///
  /// ```java
  /// putParam("files", UtilsForApi.computeManyPathesById(fileIdList));
  /// putParam("force_download", true);
  /// boolean forSync = downloadType.forSync();
  /// putParam("update_access_time", !forSync);
  /// putParam("convert_office_file", !forSync);
  /// putParam("download_type", downloadType.getValue());   // download|preview|sync
  /// if (!TextUtils.isEmpty(archiveName)) putParam("archive_name", archiveName);
  /// ```
  /// `DownloadType` 三值原文（`FileRepositoryNet$DownloadType`）：
  /// `DOWNLOAD="download"` / `PREVIEW="preview"` / `SYNC="sync"`。
  /// 版本是 `Math.min(7, api.getMaxVersion())`（同一个方法的三处 lambda）。
  ///
  /// ## 取证边界（如实登记）
  ///
  /// 单文件 `Files/download` 我方早已真机验证过（既有 [downloadUrl]）；
  /// **带 `archive_name` 的"服务端现打包"没有真机成功回包**——本批纪律禁止
  /// 产生任何服务端副作用（`Files/download` 带打包参数会**建打包任务**），
  /// 所以只按官方源码逐字组参，不拿猜测的字段凑数。
  String archiveDownloadUrl({
    required List<String> fileIds,
    String? archiveName,
  }) {
    final version = _negotiate('SYNO.SynologyDrive.Files', _v7);
    return api.authenticatedUrl(api.apiPath('SYNO.SynologyDrive.Files'), {
      'api': 'SYNO.SynologyDrive.Files',
      'version': '$version',
      'method': 'download',
      'files': _jsonIds(fileIds),
      'force_download': 'true',
      'update_access_time': 'true',
      'convert_office_file': 'true',
      'download_type': 'download',
      if (archiveName != null && archiveName.isNotEmpty)
        'archive_name': archiveName,
    });
  }

  /// `Files/download`（v≤7）：把**已经打好的**打包任务取回来（官方
  /// `setAsDownloadArchive(taskId, targetPath)` → `putParam("task_id", taskId)`）。
  ///
  /// 这是两段式打包下载的第二段：先 [createArchiveTask] 拿 `task_id`，
  /// 再从这里取字节。**本仓库默认走一段式的 [archiveDownloadUrl]**，
  /// 这个方法保留给"服务端要求两段式"的情形（例如需要在任务列表里显示进度）。
  String archiveTaskDownloadUrl({required String taskId}) {
    final version = _negotiate('SYNO.SynologyDrive.Files', _v7);
    return api.authenticatedUrl(api.apiPath('SYNO.SynologyDrive.Files'), {
      'api': 'SYNO.SynologyDrive.Files',
      'version': '$version',
      'method': 'download',
      'task_id': taskId,
    });
  }

  /// `Files/download`（v≤7）：**发起**一次打包任务（官方
  /// `setAsArchiveFiles(fileIdList, passwordMap, archiveName)`）。
  ///
  /// 原文（`ApiSynoDriveFiles.java:406-427`）：
  /// ```java
  /// putParam("files", …); putParam("force_download", true);
  /// if (!archiveName.isEmpty()) putParam("archive_name", archiveName);
  /// if (!passwordMap.isEmpty()) putParam("decrypt", passwordMap);
  /// ```
  /// 回包是 `AsyncTaskResponseVo`（取 `task_id`）。
  ///
  /// ⚠️ **这是写路径**（会在服务端建打包任务）。本批**不实调**，只做协议层 +
  /// 离线用例；UI 默认不走它（走一段式 [archiveDownloadUrl]）。
  Future<String> createArchiveTask({
    required List<String> fileIds,
    String? archiveName,
    Map<String, String> passwordMap = const {},
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Files',
      'download',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v7),
      params: {
        'files': _jsonIds(fileIds),
        'force_download': true,
        if (archiveName != null && archiveName.isNotEmpty)
          'archive_name': archiveName,
        if (passwordMap.isNotEmpty) 'decrypt': jsonEncode(passwordMap),
      },
    );
    return '${data['task_id'] ?? data['id'] ?? ''}';
  }

  // ------------------------------------------------------------ 配额 / 用量

  /// `Info/quota`（**v2**）→ 存储空间 / 配额。
  ///
  /// 权威事实（官方 Web 前端 `drive/synodrive_common.js`）：
  /// `get_quota:{api:"SYNO.SynologyDrive.Info",version:2,method:"quota"}`，**无参**。
  /// **v2 是硬要求**：`Info` v1 只有 `get/noop`
  /// （`docs/api-server-authoritative.md:768`），真机 v1 回 `103`。
  /// 回包形状与"`quota:0` = 不限额"的语义见 [DriveQuotaDto]。
  Future<DriveQuotaDto> quota() async {
    final data = await api.call(
      'SYNO.SynologyDrive.Info',
      'quota',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Info', _v2),
    );
    return DriveQuotaDto.fromJson(data);
  }

  // --------------------------------------------------------- 访问事件上报

  /// `Files/access`（**v1**）→ 上报一次文件访问事件。
  ///
  /// **真机契约（用户取证）**：参数是 **`event_type` + `path`**
  /// （只传 `path` → `120 缺少必需参数`）；回 `{"success":true}`。
  ///
  /// 官方语义：`event_type` 的合法值从前端源码核到 **`preview`** ——
  /// 通用查看器切换条目时
  /// `accessFile({params:{path:"id:"+e.get("file_id"),event_type:"preview"}})`
  /// （`/tmp/spk/export_SynologyDrive/drive/synodrive.js`，sha256 `dc88a861…`；
  /// 描述符 `access_file:{api:"SYNO.SynologyDrive.Files",method:"access",version:10}`
  /// 在 `synodrive_common.js`，sha256 `9b5bd0ce…`）。这里按真机契约发 **v1**。
  ///
  /// `path` 用 [DriveEntryDto.pathId]（`id:<file_id>`），与官方一致。
  Future<void> reportAccess({
    required String eventType,
    required String path,
  }) async {
    await api.call(
      'SYNO.SynologyDrive.Files',
      'access',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v1),
      params: {'event_type': eventType, 'path': path},
    );
  }

  /// 官方唯一核到的 `event_type` 值（查看器预览）。
  static const String kAccessEventPreview = 'preview';

  // ------------------------------------------------------------- 文件计数

  /// 服务器是否支持 `Files` 的 **v11** 契约（`count_files` / `request_access`
  /// 在这一代才被官方 App 启用；APK 常量 `VERSION_SUPPORT_FILE_COUNT_QUERY = 0xb`）。
  ///
  /// 能力表没读到（未检测）→ **fail-open**（返回 true），由调用侧的正常错误路径处理。
  bool get supportsFilesV11 {
    final entry = api.apiTable?['SYNO.SynologyDrive.Files'];
    return entry == null || entry.maxVersion >= 11;
  }

  /// `Files/count_files`（**v11**）→ `path → 条目数` 映射。
  ///
  /// **参数名来自服务端报错原文**（本会话真机，`docs/live-verification-sweep-2026-09-22.md`
  /// 第六扫）：空参回
  /// ```json
  /// {"error":{"code":114,"errors":{"line":39,
  ///   "message":"Require paths (array of path) to count files."}},"success":false}
  /// ```
  /// ⇒ 参数名 `paths`，类型是**数组**。
  ///
  /// **线参形态**：`paths` 是 **JSON 数组字符串**（不是重复字段、不是裸值）——
  /// 与本文件既有的 `files`（`convert_office`）同形。真机逐字回包：
  /// ```
  /// count_files v11 {paths:'["/mydrive"]'}             → {"data":{"/mydrive":14},"success":true}
  /// count_files v11 {paths:'["/mydrive","/mydrive/PhotoBackup"]'}
  ///                                                    → {"data":{"/mydrive":14,"/mydrive/PhotoBackup":4}}
  /// ```
  /// ⇒ 回包 `data` 就是 **`path → 数量` 的映射**（key 是传进去的 path 原样）。
  /// **内部 map 由调用方按需取值，绝不把原始 JSON 丢上屏。**
  ///
  /// **版本**：官方 APK 的 `VERSION_SUPPORT_FILE_COUNT_QUERY = 0xb`（=11），
  /// 低于 11 的服务器上官方不调 → 这里返回空映射（不猜老版本行为）。
  Future<Map<String, int>> countFiles(List<String> paths) async {
    if (paths.isEmpty) return const {};
    final version = _negotiate('SYNO.SynologyDrive.Files', _v11);
    if (version < _v11.first) return const {};
    final data = await api.call(
      'SYNO.SynologyDrive.Files',
      'count_files',
      preferredVersion: version,
      params: {
        // 逐字形态：JSON 数组字符串
        'paths': jsonEncode(paths),
      },
    );
    final out = <String, int>{};
    for (final entry in data.entries) {
      final parsed = int.tryParse('${entry.value}');
      if (parsed != null) out[entry.key] = parsed;
    }
    return out;
  }

  // ----------------------------------------------------------- 请求访问权

  /// `Files/request_access`（**v11**）→ 向条目拥有者申请访问权。
  ///
  /// ⚠️ **这是写操作**：一次成功调用会在服务端**产生一条真实的访问权申请**。
  /// 本批按纪律**只做只读取证**（`docs/agent-batch-protocol.md` §5「写操作一律不实调」），
  /// **从未用真实目标调过成功路径**；参数只由**只读 120 oracle** 探明：
  /// ```
  /// v11 空参                 → 120 {"name":"path","reason":"required"}
  /// v11 {path:"/mydrive/__no_such__"} → 1003 {"line":46,"message":"request access failed"}
  /// v11 {path:["/mydrive/__no_such__"]} → 120 {"name":"path","reason":"type"}
  /// v10 {path:"/mydrive/__no_such__"}  → 1003（v10 同形）
  /// v1  空参                 → 1000 {"line":46,"message":"request access failed"}（v1 不点名参数）
  /// ```
  /// ⇒ **参数 `path` 是标量字符串**（数组回 `reason:"type"`）；错误码从"缺参
  /// `120{path}`"跃迁到"`1003` 申请失败"证明**名字与形态都对**（[§1.9] 的
  /// 错误码跃迁手法）；探测目标全部**不存在**，服务端在写之前就失败，**无副作用**。
  ///
  /// `path` 用 `/mydrive/...`（[DriveEntryDto.displayPath]）或 `id:<file_id>`；
  /// **真实调用走展示路径**（与 [countFiles] 真机取证的 path 形态一致），
  /// 展示路径为空才回落到 `id:<file_id>`。
  ///
  /// **调用方必须先取得用户明确确认**（写操作），失败必须明确提示、不许静默。
  Future<void> requestAccess({required String path}) async {
    await api.call(
      'SYNO.SynologyDrive.Files',
      'request_access',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v11),
      params: {'path': path},
    );
  }

  // ------------------------------------------------------- 转成 Office 格式

  /// `Files/convert_office`（**v1**）→ 起一个转换任务。
  ///
  /// **真机契约（用户取证）**：
  ///   * `files` = `'["id:<file_id>"]'` —— **必须带 `id:` 前缀**，且是
  ///     **JSON 数组字符串**；裸 id 或少了前缀会 `114`；
  ///   * `format` = 目标格式（真机验证值 `"docx"`）；
  ///   * 回包 `{"data":{"async_task_id":"task-140"}}`。
  ///
  /// 官方前端同款描述符为 `convert_office:{api:"SYNO.SynologyDrive.Files",
  /// version:6,method:"convert_office"}`（`synodrive_common.js`），参数白名单
  /// `files, conflict_action, to_parent_folder, dry_run`；**真机契约的 v1 + `format`
  /// 优先**（本方法按契约发 v1）。
  ///
  /// 返回 `async_task_id`（**只在 Key / 测试断言 / 内部轮询里出现，绝不上界面**）。
  Future<String> convertOffice({
    required String fileId,
    String format = 'docx',
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Files',
      'convert_office',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Files', _v1),
      params: {
        // 逐字形态：JSON 数组字符串，元素必须 `id:<file_id>`
        'files': jsonEncode(['id:$fileId']),
        'format': format,
      },
    );
    return '${data['async_task_id'] ?? ''}';
  }

  /// `Tasks/get`（v1）→ 查一个异步任务的状态（转换任务轮询用）。
  ///
  /// 证据（**官方前端源码级，非真机**）：
  ///   * 描述符 `get_task:{api:"SYNO.SynologyDrive.Tasks",method:"get",version:1}`
  ///     （`synodrive_common.js`）；
  ///   * 调用点 `getTaskStatus(e){… params:{task_id:e} …}` 后读 `t.status`
  ///     （`mobile-sharing` 的官方 JS；同样被 `Tasks/list` 的任务管理复用）。
  ///
  /// ★ **`SYNO.SynologyDrive.Tasks` 官方只有三个方法**
  /// （`ApiSynoDriveTasks.java:13-15`）：`list` / `get` / `delete`；
  /// 服务端 `.lib` 交叉确认（`catalog.json`，`source:"spk"`）：
  /// `maxVersion=1`、`methods["1"]=[delete,get,list]`、
  /// `allowUser` 含 `normal.*` ⇒ **普通用户可用、非 admin**。
  /// **没有 retry / pause / resume / cancel** —— 所以「暂停/取消任务」
  /// 在服务端就没有这个操作，不是客户端漏做（见差距表附录 AU）。
  ///
  /// ⚠️ 这是**新增的、未经真机验证**的读取通道。轮询拿不到确定状态时**不得
  /// 谎报成功**（见 `DriveConvertOfficeRunner`：只有 `status == "finished"`
  /// 才报完成，否则一律"已提交"）。
  /// 返回 null = 回包里没有可判读的任务对象。
  Future<DriveTaskDto?> getTask(String taskId) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Tasks',
      'get',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Tasks', _v1),
      params: {'task_id': taskId},
    );
    // 官方 `getTaskStatus` 直接读顶层 `status`；也兼容被包在 `items[0]` 的形态。
    final single = data['status'] != null
        ? data
        : (data['items'] is List && (data['items'] as List).isNotEmpty
              ? ((data['items'] as List).first as Map).cast<String, dynamic>()
              : null);
    if (single == null) return null;
    return DriveTaskDto.fromJson(single);
  }

  // ------------------------------------------------------- 相机备份（Drive 落点）
  //
  // 官方 Synology Drive 安卓端的相机备份落点就是 Drive 的我的文件：
  // `/mydrive/PhotoBackup/<设备名>/`（逐字证据：`backup/BackupTarget.java:177-190`
  // `new File(Constants.MYDRIVE_PATH, getString(R.string.photo_backup_folder_name))`
  // + `Constants.java:33 MYDRIVE_PATH="/mydrive"` + `strings.xml:1844
  // photo_backup_folder_name="PhotoBackup"`；设备子目录见 `BackupTarget.java:130-138`。
  // 见 `docs/drive-parity-audit.md:264` 与 `:277`）。
  //
  // 上传走 `SYNO.SynologyDrive.Photos` 的 `upload`（服务端 `.lib` 注册表：
  // `SYNO.SynologyDrive.Photos | 3 | v1: get_metadata | v2–3: get_metadata, list, upload`
  // —— `docs/api-server-authoritative.md:785`），官方客户端参数逐字来自
  // `ApiSynoDrivePhotos.java:162-187`：`path` / `type=file` /
  // `conflict_action`（备份时 `autorename`）/ `modified_time` / `file`；
  // 整文件 multipart，**照片备份不分片**（`ApiRequest.java:66-68` 是 `Type.Upload`，
  // 不是可续传的 `RecoverableUpload`）。

  /// Drive 相机备份的根目录（官方 `photo_backup_folder_name="PhotoBackup"`）。
  static const String kDrivePhotoBackupRoot = '$kDriveRoot/PhotoBackup';

  /// 设备名 → 目录名。官方直接用设备型号当子目录名，这里只做**文件名安全**
  /// 清洗（保留 `[A-Za-z0-9._-]`，其余换 `_`，压掉连续/首尾下划线）——与服务端
  /// 无关，是为了不因 `/` 这类字符把路径拼坏。空则回 `Android`。
  static String sanitizeDeviceName(String device) {
    final cleaned = device
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .replaceAll(RegExp('_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return cleaned.isEmpty ? 'Android' : cleaned;
  }

  /// `/mydrive/PhotoBackup/<设备名>`（官方同构的落点路径）。
  static String photoBackupFolderPath(String device) =>
      '$kDrivePhotoBackupRoot/${sanitizeDeviceName(device)}';

  /// 官方 `BackupStructure.None` / `Year` / `YearAndMonth` 的**原值字符串**
  /// （反编译 `BackupStructureKt.java`）：
  /// `"none"` / `"year"` / `"year_and_month"`。
  static String backupStructureValue(DriveBackupStructure s) => s.value;

  /// 把拍摄时间按官方 [DriveBackupStructure] 编成**子目录后缀**（D72）。
  ///
  /// ## 原文证据（反编译 `Android-SynologyDrive.3.9.0-1113.ww.apk`，逐字）
  ///
  /// ```java
  /// // backup/BackupStructure.java:getStructure(long timestamp)
  /// if (this == None) return "";
  /// if (this == Year) return DateUtilities.getYearString(timestamp);       // "yyyy"
  /// return DateUtilities.getYearMonthString(timestamp);                    // "yyyy/MM"
  /// // util/DateUtilities.java:190-196
  /// getYearMonthString(ts) = getStringByTime(ts, "yyyy/MM");
  /// getYearString(ts)      = getStringByTime(ts, "yyyy");
  /// // :205-211：Calendar.getInstance()（**本地时区**）+ SimpleDateFormat(pattern, Locale.ENGLISH)
  /// ```
  ///
  /// 时基是 **MediaStore 拍摄时间**（`PhotoBackupManager.java:287-288`
  /// `getStructure(…getTakenTime())`），**不是**上传那一刻的时间。
  ///
  /// 返回**不带首尾 `/`** 的相对子路径：`""`（none）/ `"2024"`（year）/
  /// `"2024/09"`（year_and_month，月份**补两位**）。
  static String backupStructureSuffix(
    DriveBackupStructure structure,
    DateTime taken,
  ) {
    switch (structure) {
      case DriveBackupStructure.none:
        return '';
      case DriveBackupStructure.year:
        return taken.year.toString().padLeft(4, '0');
      case DriveBackupStructure.yearAndMonth:
        return '${taken.year.toString().padLeft(4, '0')}/'
            '${taken.month.toString().padLeft(2, '0')}';
    }
  }

  /// 相机备份的**最终目录**（D72）：`/mydrive/PhotoBackup/<设备名>[/<YYYY>[/<MM>]]`。
  ///
  /// [structure] 是官方默认 `year_and_month`；[taken] 是这张/这批照片的
  /// **拍摄时间**（同官方 `getStructure(...getTakenTime())`）。
  static String photoBackupFolderPathFor({
    required String device,
    DriveBackupStructure structure = DriveBackupStructure.yearAndMonth,
    DateTime? taken,
  }) {
    final base = photoBackupFolderPath(device);
    if (structure == DriveBackupStructure.none || taken == null) return base;
    final suffix = backupStructureSuffix(structure, taken);
    return suffix.isEmpty ? base : '$base/$suffix';
  }

  /// 确保 `/mydrive/PhotoBackup/<设备名>` 两级目录存在，返回该路径。
  ///
  /// 官方 `BackupTarget.java` 也是"缺就建"（`BackupFolderManager.ensureBackupFolder`）。
  /// 已存在时不抛：`Files/get` 复核一次确实是个目录就算成功（服务端对重复建目录
  /// 回的错误码没有原文证据，所以用**复核**而不是猜错误码）。
  Future<String> ensurePhotoBackupFolder({required String device}) async {
    final path = photoBackupFolderPath(device);
    await _ensureFolder(kDrivePhotoBackupRoot);
    await _ensureFolder(path);
    return path;
  }

  /// D72：确保**按日期分层的**备份目录存在（逐级建），返回最终目录。
  ///
  /// 与 [ensurePhotoBackupFolder] 同款"缺就建 + get 复核"，只是把
  /// [photoBackupFolderPathFor] 的每一段都建出来。
  /// [structure] = `none` 时退化成 [ensurePhotoBackupFolder]（不建日期层）。
  Future<String> ensurePhotoBackupFolderFor({
    required String device,
    DriveBackupStructure structure = DriveBackupStructure.yearAndMonth,
    DateTime? taken,
  }) async {
    if (structure == DriveBackupStructure.none || taken == null) {
      return ensurePhotoBackupFolder(device: device);
    }
    final path = photoBackupFolderPathFor(
      device: device,
      structure: structure,
      taken: taken,
    );
    await _ensureFolder(kDrivePhotoBackupRoot);
    // 逐级建：`base` → `base/YYYY` → `base/YYYY/MM`
    final base = photoBackupFolderPath(device);
    var current = base;
    await _ensureFolder(current);
    for (final seg in backupStructureSuffix(structure, taken).split('/')) {
      if (seg.isEmpty) continue;
      current = '$current/$seg';
      await _ensureFolder(current);
    }
    return path;
  }

  Future<void> _ensureFolder(String path) async {
    try {
      await createFolder(path: path);
    } catch (err) {
      // 复核：已经是目录就当作成功（重复创建）；否则原样抛出。
      try {
        final existing = await get(path: path);
        if (existing.isDir) return;
      } catch (_) {
        // 复核也失败 → 抛最初的错误（更有信息量）
      }
      rethrow;
    }
  }

  /// 目标设备目录里**已有的文件**（去重用：文件名 + 大小）。
  ///
  /// 目录还不存在时回空表（第一次备份什么都没建）。
  Future<List<({String name, int size})>> photoBackupRemoteEntries({
    required String folderPath,
  }) async {
    try {
      final page = await list(path: folderPath, limit: 1000);
      return [
        for (final item in page.items)
          if (!item.isDir) (name: item.name, size: item.size),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 上传一张到相机备份目录（`SYNO.SynologyDrive.Photos/upload` v2–3）。
  ///
  /// 返回 `(id, hash)`：`hash` 是服务端回的哈希（官方拿 `FileInfo.hash` 做**全文件
  /// MD4** 比对，见 `PhotoBackupManager.java:298-306` + `FileInfoVo.java:28`）；
  /// 服务端没回这个字段时为空串 —— 调用方只做"认得就比"的 best-effort。
  ///
  /// ⚠️ `path` 语义（真机 A/B 2026-09-22）：它是**目标文件的完整路径**
  /// （目录 + `'/'` + 文件名），**不是目录**。旧实现只发目录导致照片落到父目录、
  /// 且被服务端取名成设备名（同名自动改名 `LGE-AN10 (1)`/`(2)`）。用
  /// [_driveUploadFilePath] 把 [folderPath] 与 [fileName] 拼成完整路径。
  /// [folderPath] 的**目录语义不变**（调用方照旧传目录）。
  Future<({String id, String hash})> uploadPhotoForBackup({
    required String folderPath,
    required String filePath,
    required String fileName,
    required int modifiedTimeMs,
    String? mimeType,
    void Function(int sent, int total)? onProgress,
  }) async {
    const apiId = 'SYNO.SynologyDrive.Photos';
    // 服务端注册表里 upload 在 v2–3（`api-server-authoritative.md:785`），发 v2。
    final version = _negotiate(apiId, _v2);
    final fields = <String, String>{
      'api': apiId,
      'method': 'upload',
      'version': '$version',
      // 目录 + 文件名；与 multipart 的 filename 是同一个 [fileName]，
      // 不看 `filePath` 的 basename（有些临时文件会被改名）。
      'path': _driveUploadFilePath(folderPath, fileName),
      'type': 'file',
      // 备份场合官方传 autorename（`conflict_action, forBackup?autorename:…`）
      'conflict_action': 'autorename',
      // 官方 `putParam("modified_time", …)`；Drive 的 modified_time 全程是**秒**
      if (modifiedTimeMs > 0) 'modified_time': '${modifiedTimeMs ~/ 1000}',
    };
    final raw = await api.postMultipart(
      api.apiPath(apiId),
      query: {'_sid': api.session?.sid ?? ''},
      fields: fields,
      fileField: 'file',
      filePath: filePath,
      fileName: fileName,
      mimeType: mimeType ?? 'application/octet-stream',
      onProgress: onProgress,
    );
    final data = api.decodeData(raw, '$apiId.upload');
    return (
      id: '${data['file_id'] ?? data['id'] ?? ''}',
      hash: '${data['hash'] ?? data['file_hash'] ?? ''}',
    );
  }

  // ------------------------------------------- D24：Drive 原生上传（含分片续传）

  /// `SYNO.SynologyDrive.Files/upload`（**普通整文件**，`offset <= -1`）。
  ///
  /// 官方 `ApiSynoDriveFiles.setAsUpload` 的 offset<=-1 分支
  /// （`ApiSynoDriveFiles.java:471-527`）：
  /// * 版本 **`Math.min(8, maxVersion)`**（★ 与分片那条的 `min(2,·)` **不同**）；
  /// * `path` = `id:<folderId>/<fileName>`、`type=file`；
  /// * `conflict_action` 官方默认 **`version`**（普通文件）；
  /// * 可选 `mute` / `modified_time`（**秒**）/ `sharing_token`；
  /// * 文件参数名 = **文件名**（官方 `putParam(name, file)`），
  ///   不是固定的 `file` —— 这点与相机备份那条（`file`）不同。
  ///
  /// ⚠️ 这是 Drive **自己的**上传，与 `uploadPhotoForBackup`
  /// （`SYNO.SynologyDrive.Photos/upload`）是两条不同的 API，别混。
  Future<({String id, String hash})> uploadFile({
    required String folderId,
    required String filePath,
    required String fileName,
    int? modifiedTimeSeconds,
    String conflictAction = 'version',
    bool mute = false,
    String? sharingToken,
    String? mimeType,
    void Function(int sent, int total)? onProgress,
  }) async {
    const apiId = 'SYNO.SynologyDrive.Files';
    // 官方 setAsUpload 的 offset<=-1 分支：Math.min(8, maxVersion)。
    final version = _negotiate(apiId, _v8);
    final fields = <String, String>{
      'api': apiId,
      'method': 'upload',
      'version': '$version',
      'path': '${_pathById(folderId)}/$fileName',
      'type': 'file',
      'conflict_action': conflictAction,
      if (mute) 'mute': 'true',
      if (modifiedTimeSeconds != null && modifiedTimeSeconds != 0)
        'modified_time': '$modifiedTimeSeconds',
      'sharing_token': ?sharingToken,
    };
    final raw = await api.postMultipart(
      api.apiPath(apiId),
      query: {'_sid': api.session?.sid ?? ''},
      fields: fields,
      // ★ 官方的文件字段名就是**文件名**（`putParam(name, file)`）
      fileField: fileName,
      filePath: filePath,
      fileName: fileName,
      mimeType: mimeType ?? 'application/octet-stream',
      onProgress: onProgress,
    );
    final data = api.decodeData(raw, '$apiId.upload');
    return (
      id: '${data['file_id'] ?? data['id'] ?? ''}',
      hash: '${data['hash'] ?? data['file_hash'] ?? ''}',
    );
  }

  // ── 普通整文件那条（`offset <= -1`）：
  //
  // `SYNO.SynologyDrive.Files/upload`（**普通整文件**，`offset <= -1`）。
  //
  // ## 为什么 Drive 有它自己的上传而不是借 FileStation
  // 官方 `ApiSynoDriveFiles.java:43,84`：`API_NAME="SYNO.SynologyDrive.Files"`、
  // `METHOD_NAME__UPLOAD="upload"` —— Drive 客户端**走自己的 upload**，
  // 这样才能写进**团队文件夹**（`path=id:<folderId>/<name>`）并复用
  // Drive 的冲突策略/`mute`/`modified_time` 语义。
  //
  // ## 版本与冲突策略（逐字对齐官方）
  // * 版本：`Math.min(8, maxVersion)`（`setAsUpload` 的 offset<=-1 分支）；
  // * `path` = `id:<folderId>` + `/` + 文件名（`computePathById` + 文件名）；
  // * `type=file`；
  // * `conflict_action` 官方默认 **`version`**（`ApiSynoDriveFiles.java:492-499`）：
  //   文件夹→`stop`、新建文本→`autorename`、**其余→`version`**。
  //   ⚠️ 相机备份那条路官方另传 `autorename`，别混用。
  //
  // 无 `id:` 前缀时 [_pathById] 会补上。

  /// `SYNO.SynologyDrive.Files/upload`（**分片续传**，`offset > -1`）。
  ///
  /// 官方 `setAsUpload` 的 offset>-1 分支（`ApiSynoDriveFiles.java:471-527`）：
  /// * 版本：`Math.min(2, maxVersion)`（**比整文件那条低**）；
  /// * 三个**真 HTTP 头**：
  ///   `X-TMP-FILE: <taskId>`、`X-TYPE-NAME: SLICEUPLOAD`、
  ///   `X-FILE-CHUNK-END: "true"`；
  /// * 文件参数带 `offset`（官方 `putParam(name, file, offset)`）。
  ///
  /// ⇒ 断点续传 = 先 [getUploadedSize] 问"已收到多少字节"，再从这里带
  /// `offset` 续。**两个方法必须是同一个 `taskId`**。
  Future<({String id, String hash})> uploadChunk({
    required String folderId,
    required String filePath,
    required String fileName,
    required String taskId,
    required int offset,
    int? modifiedTimeSeconds,
    String conflictAction = 'version',
    bool mute = false,
    String? sharingToken,
    String? mimeType,
    void Function(int sent, int total)? onProgress,
  }) async {
    const apiId = 'SYNO.SynologyDrive.Files';
    final version = _negotiate(apiId, _v2);
    final fields = <String, String>{
      'api': apiId,
      'method': 'upload',
      'version': '$version',
      'path': '${_pathById(folderId)}/$fileName',
      'type': 'file',
      'conflict_action': conflictAction,
      if (mute) 'mute': 'true',
      if (modifiedTimeSeconds != null && modifiedTimeSeconds != 0)
        'modified_time': '$modifiedTimeSeconds',
      'sharing_token': ?sharingToken,
    };
    final raw = await api.postMultipart(
      api.apiPath(apiId),
      query: {'_sid': api.session?.sid ?? ''},
      fields: fields,
      fileField: fileName,
      filePath: filePath,
      fileName: fileName,
      mimeType: mimeType ?? 'application/octet-stream',
      onProgress: onProgress,
      headers: {
        'X-TMP-FILE': taskId,
        'X-TYPE-NAME': 'SLICEUPLOAD',
        'X-FILE-CHUNK-END': 'true',
      },
    );
    final data = api.decodeData(raw, '$apiId.upload');
    return (
      id: '${data['file_id'] ?? data['id'] ?? ''}',
      hash: '${data['hash'] ?? data['file_hash'] ?? ''}',
    );
  }

  /// ★ **续传探针**：问服务端"这个上传任务已经收到多少字节"。
  ///
  /// 官方 `setAsGetUploadedSize(taskId, dummyFile)`（`ApiSynoDriveFiles.java:454-466`）：
  /// * 方法仍是 `upload`，版本 `Math.min(2, maxVersion)`；
  /// * 头：`X-TMP-FILE: <taskId>`、`X-TYPE-NAME: SLICEUPLOAD`、
  ///   **`X-FILE-CHUNK-END: "false"`**（与续传那次的 `true` 相反）；
  /// * 参：**`dummy` = 一个假文件** —— 只为让请求成为合法 multipart；
  /// * 回包：`UploadedSizeResponseVo` → **`uploaded_size`**。
  ///
  /// ⇒ 这条请求**此前完全没有记录**，Mech 上它是断点续传能成立的关键：
  /// 没有它就无法知道该从哪个 offset 续，只能**整份重传**。
  ///
  /// 服务端没回 `uploaded_size` 时返回 `0`（保守：从头传）。
  Future<int> getUploadedSize({
    required String taskId,
    required String dummyFilePath,
    required String dummyFileName,
  }) async {
    const apiId = 'SYNO.SynologyDrive.Files';
    final version = _negotiate(apiId, _v2);
    final fields = <String, String>{
      'api': apiId,
      'method': 'upload',
      'version': '$version',
    };
    final raw = await api.postMultipart(
      api.apiPath(apiId),
      query: {'_sid': api.session?.sid ?? ''},
      fields: fields,
      fileField: 'dummy',
      filePath: dummyFilePath,
      fileName: dummyFileName,
      mimeType: 'application/octet-stream',
      headers: {
        'X-TMP-FILE': taskId,
        'X-TYPE-NAME': 'SLICEUPLOAD',
        'X-FILE-CHUNK-END': 'false',
      },
    );
    final data = api.decodeData(raw, '$apiId.upload');
    final v = data['uploaded_size'] ?? data['uploadedSize'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}') ?? 0;
  }

  /// 官方 `UtilsForApi.computePathById`（`UtilsForApi.java:19-21`）：
  ///
  /// ```java
  /// return id.startsWith("/") ? id : "id:" + id;
  /// ```
  ///
  /// ⇒ **已是路径**（以 `/` 开头）的**原样保留**；否则加 `id:` 前缀。
  /// 已带 `id:` 的同样不再重复加（幂等）。
  ///
  /// ⚠️ 我第一版**只判了 `id:` 前缀、漏了 `/` 分支**，被
  /// `drive_download_archive_test.dart` 的 DA-1 抓到：`/home/team/a.txt`
  /// 被拼成 `id:/home/team/a.txt` —— 服务端找不到该对象。
  /// 上传那条路径传进来的是纯 file_id，所以这个 bug 当时**没有暴露**。
  static String _pathById(String folderId) {
    if (folderId.startsWith('/')) return folderId;
    return folderId.startsWith('id:') ? folderId : 'id:$folderId';
  }

  /// JSON 里的数字字段：能当 int 就裸写，否则加引号（`version_id` 官方两种都收）
  static String _numOrQuoted(String v) {
    final n = int.tryParse(v);
    return n == null ? '"$v"' : '$n';
  }

  static String _jsonIds(List<String> fileIds) => _jsonStrings(
    fileIds.map((e) => e.startsWith('id:') ? e : 'id:$e').toList(),
  );

  static String _jsonStrings(List<String> values) =>
      '[${values.map((e) => '"${e.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"').join(',')}]';

  /// 官方 `UtilsForApi.computePathById`（`UtilsForApi.java:20`）逐字：
  /// 已经以 `/` 开头的当**绝对路径**原样用，否则拼成 `id:<id>`。
  ///
  /// 回收站列表/清空的 `path` 就是这个形状：个人空间是 `/mydrive`，
  /// "某个文件夹"是 `id:<folder_id>`。
  static String _pathId(String id) => id.startsWith('/') ? id : 'id:$id';

  // ══════════════════════════════════════════════════════════════════════
  // ★★★ 第 98 轮：官方 `SynologyDrive 3.9.0-1113` APK 取证补齐的 5 族 API
  //（见 docs/drive-apk391113-evidence.md §1.1；目录里 5 族**均已 methodsVerified**，
  //   方法名与 APK smali 交叉印证一致 ⇒ 这里只调目录里已存在的方法）。
  // ══════════════════════════════════════════════════════════════════════

  /// `SYNO.SynologyDrive.Users:get` —— 用户显示名映射。
  ///
  /// 官方证据：`ApiSynoDriveUsers.smali:17` `METHOD_NAME__GET="get"`；
  /// 调用方 `UserGetWork`/`UserMapGetWork`（拿 `UserGetResponseVo.getUser()`）。
  /// 响应按官方 VO 的 `users` 列表原样透传（**不臆造字段**）。
  Future<List<dynamic>> usersGet() async {
    final data = await api.call(
      'SYNO.SynologyDrive.Users',
      'get',
      preferredVersion: _negotiate('SYNO.SynologyDrive.Users', const [1]),
    );
    final users = data['users'];
    return users is List ? users : const [];
  }

  /// `SYNO.SynologyDrive.Profiles:get_sync_profiles`（**必须 v2**）。
  ///
  /// 官方证据：`ApiSynoDriveProfiles.smali:47`
  /// `METHOD_NAME__GET_SYNC="get_sync_profiles"`、
  /// `VERSION_SUPPORT_SYNC = 0x2` ⇒ 官方只在 v2 上调它
  /// （目录：v1/v2 都有该方法，但按官方写法只走 v2）。
  Future<List<dynamic>> syncProfiles() async {
    final data = await api.call(
      'SYNO.SynologyDrive.Profiles',
      'get_sync_profiles',
      preferredVersion: 2,
    );
    final items = data['profiles'];
    return items is List ? items : const [];
  }

  /// `SYNO.SynologyDrive.SCIM.User:get` —— param `user`（用户名列表）。
  ///
  /// 官方证据：`ApiSynoDriveScimUser.smali` `setAsGet(Collection userNames)`
  /// 里 `putParam("user", list)` + `Method.GET`。
  /// ⚠️ 目录 `authLevel=2`（admin）⇒ 非管理员会被 `105` 拒。
  Future<List<dynamic>> scimUsers(List<String> userNames) async {
    final data = await api.call(
      'SYNO.SynologyDrive.SCIM.User',
      'get',
      preferredVersion: _negotiate('SYNO.SynologyDrive.SCIM.User', const [1]),
      params: {'user': userNames},
    );
    final users = data['users'];
    return users is List ? users : const [];
  }

  /// `SYNO.SynologyDrive.SCIM.Photo:get` —— 按名或按 `_uid`。
  ///
  /// 官方证据：`ApiSynoDriveScimPhoto.smali:50` `METHOD_NAME__GET="get"`
  /// + `setAsGet(String)` / `setAsGetByUID(J)`。
  Future<List<dynamic>> scimPhotos({String? name, int? uid}) async {
    assert(name != null || uid != null, '官方二选一：按名或按 uid');
    final data = await api.call(
      'SYNO.SynologyDrive.SCIM.Photo',
      'get',
      preferredVersion: _negotiate('SYNO.SynologyDrive.SCIM.Photo', const [1]),
      params: name != null ? {'name': name} : {'uid': uid},
    );
    final photos = data['photos'];
    return photos is List ? photos : const [];
  }

  /// `SYNO.SynologyDrive.Authentication:authenticate_by_dsm`（v2，带设备参数）。
  ///
  /// 官方证据：`ApiSynoDriveAuthenticate.smali` 常量
  /// `client_version` / `device_name` / `device_uuid` / `platform` / `access_token`
  /// + `VERSION_SUPPORT_REMOTE_WIPE = 0x2`。
  /// ⚠️ 响应字段官方 VO 未逐字段取证 ⇒ 只透传整包 `data`。
  Future<Map<String, dynamic>> authenticateByDsm({
    required String accessToken,
    required String deviceName,
    required String deviceUuid,
    String platform = 'Android',
    int clientVersion = 2,
  }) async {
    final data = await api.call(
      'SYNO.SynologyDrive.Authentication',
      'authenticate_by_dsm',
      preferredVersion: 2,
      params: {
        'access_token': accessToken,
        'device_name': deviceName,
        'device_uuid': deviceUuid,
        'platform': platform,
        'client_version': clientVersion,
      },
    );
    return data;
  }
}

/// `SYNO.SynologyDrive.Photos/upload` 的 `path`：**目标文件完整路径**。
///
/// 原文/真机证据（2026-09-22 服务端 A/B，同 session 只改 `path`）：
///   * `path=/mydrive/PhotoBackup/LGE-AN10`（目录）→ http 200，但文件落到
///     **父目录**、被取名成 `LGE-AN10 (3)`；
///   * `path=/mydrive/PhotoBackup/LGE-AN10/PROBE_V2.png` → http 200，文件正确
///     落在设备目录内、名为 `PROBE_V2.png`。
///
/// 目录以 `/` 结尾时避免双斜杠；根目录 `"/"` 保持原样。
String _driveUploadFilePath(String folderPath, String fileName) {
  var dir = folderPath;
  while (dir.length > 1 && dir.endsWith('/')) {
    dir = dir.substring(0, dir.length - 1);
  }
  if (dir.isEmpty) dir = '/';
  return dir == '/' ? '/$fileName' : '$dir/$fileName';
}
