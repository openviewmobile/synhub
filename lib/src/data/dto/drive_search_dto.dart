// Drive 搜索条件（P0-4）——**逐字段对齐官方 Android 的 `SearchCondition`**。
//
// 权威原文（APK `com.synology.dsdrive`）：
//   * 请求拼装 `api/ApiSynoDriveFiles.java:724-796` `setAsListSearch`：
//     `keyword` / `location` / `custom_location` / `file_type` /
//     `custom_file_type` / `owner` / `custom_owner` / `min_size` / `max_size` /
//     `labels` / `time` / `start_date` / `end_date` / `offset` / `limit` /
//     `content_snippet:true`；方法名 `search`，版本 `Math.min(4, maxVersion)`
//     （`:782-788`）。
//   * 枚举 apiValue `model/data/SearchCondition.java`：
//     LocationType `:659-667`、FileType `:748-758`、OwnerType `:912-915`、
//     SizeType `:991-994`（无 apiValue，走 min/max 字节）、
//     DateType `:1062-1064`。
//   * 大小换算：`long size = getSize() * 1048576`（MB→字节，`:756`）；
//     `EqualTo` 是一个 **±5% 带**（`:762-766`，`SIZE_RANGE = 0.05`，`:133`）。
//
// ⚠️ **有原文才做**：`current` / `custom_label` 两种 location 的上行需要
// "当前节点上下文" / "收藏夹 id"（`m_collection_id`），本批没有对应上下文
// 或功能面 → 不进枚举；`custom_owner` 的 `{type:'user', name}` 结构在 DTO
// 里保留（有原文），但 UI 只给"任意/我/不是我"三档（自定义属主需要成员搜索，
// 属分享域，本批不做）。
library;

/// 官方 `SearchCondition.LocationType` 的 apiValue
/// （`SearchCondition.java:659-667`；只保留我们真发得出去的几档）。
enum DriveSearchLocation {
  any('any'),
  myDrive('mydrive'),
  teamFolders('team_folders'),
  sharedWithMe('shared_with_me'),
  sharedWithOthers('shared_with_others'),
  starred('starred'),

  /// `location=custom` + `custom_location=id:<folder_id>`（`:736-737`）。
  ///
  /// 官方另有独立的 `current` 档（`:660`），但其上行语义依赖"当前节点上下文"，
  /// 本批不实现；"在当前文件夹里搜"由 UI 传 `custom` + 当前目录 id 达成。
  custom('custom');

  const DriveSearchLocation(this.apiValue);
  final String apiValue;
}

/// 官方 `SearchCondition.FileType` 的 apiValue（`SearchCondition.java:748-758`）
enum DriveSearchFileType {
  any('any'),
  folder('folder'),
  file('file'),
  odoc('odoc'),
  osheet('osheet'),
  oslide('oslides'),
  document('document'),
  image('image'),
  audio('audio'),
  video('video'),

  /// `file_type=custom` + `custom_file_type=<扩展名>`（`:745-747`）
  custom('custom');

  const DriveSearchFileType(this.apiValue);
  final String apiValue;
}

/// 官方 `SearchCondition.OwnerType` 的 apiValue（`SearchCondition.java:912-915`）
enum DriveSearchOwner {
  any('any'),
  me('me'),
  notMe('not_me'),

  /// `owner=custom` + `custom_owner={type:"user",name:<name>}`
  custom('custom');

  const DriveSearchOwner(this.apiValue);
  final String apiValue;
}

/// 官方 `SearchCondition.DateType` 的 apiValue（`SearchCondition.java:1062-1064`）
enum DriveSearchDate {
  any('any'),
  modified('modified_time'),
  created('created_time');

  const DriveSearchDate(this.apiValue);
  final String apiValue;
}

/// 官方 `SearchCondition.SizeType`（`SearchCondition.java:991-994`）。
///
/// **没有 apiValue**：官方把大小换算成字节后发 `min_size` / `max_size`
/// （`:756-766`），所以这里只描述"用户选的是哪种比较"。
enum DriveSearchSize {
  /// 不按大小过滤
  any,

  /// `min_size`（大于）
  greaterThan,

  /// `max_size`（小于）
  lessThan,

  /// 官方 `EqualTo` = `[0.95*size, 1.05*size]` 的带
  roughly,
}

/// 官方 `EqualTo` 的容差（`ApiSynoDriveFiles.java:133` `SIZE_RANGE = 0.05`）
const double kDriveSearchSizeTolerance = 0.05;

/// 把"约等于 N MB"换算成官方那只 ±5% 带（字节）
({int min, int max}) driveSearchSizeBand(int megabytes) {
  final bytes = megabytes * 1048576;
  return (
    min: (bytes * (1 - kDriveSearchSizeTolerance)).floor(),
    max: (bytes * (1 + kDriveSearchSizeTolerance)).floor(),
  );
}

/// 搜索条件（不可变）。`DriveApi.search` 只发**非默认**字段。
class DriveSearchQuery {
  const DriveSearchQuery({
    this.keyword = '',
    this.location = DriveSearchLocation.any,
    this.customLocationId = '',
    this.fileType = DriveSearchFileType.any,
    this.customFileType = '',
    this.owner = DriveSearchOwner.any,
    this.customOwnerName = '',
    this.size = DriveSearchSize.any,
    this.sizeMegabytes = 0,
    this.labelIds = const [],
    this.date = DriveSearchDate.any,
    this.startTime = 0,
    this.endTime = 0,
    this.contentSnippet = true,
  });

  /// 关键词；官方为空时不发（我们这侧服务端回 120，故 UI 会先拦）。
  final String keyword;

  final DriveSearchLocation location;

  /// `location=custom` 时的目标目录 id（不带 `id:` 前缀）
  final String customLocationId;

  final DriveSearchFileType fileType;

  /// `file_type=custom` 时的扩展名（官方 `custom_file_type`）
  final String customFileType;

  final DriveSearchOwner owner;

  /// `owner=custom` 时的账号名（官方发 `{type:'user',name:...}`）
  final String customOwnerName;

  final DriveSearchSize size;

  /// UI 输入的大小（MB）；官方上行前 `* 1048576`
  final int sizeMegabytes;

  final List<String> labelIds;

  final DriveSearchDate date;

  /// epoch 秒；官方发 `start_date` / `end_date`
  final int startTime;
  final int endTime;

  /// 官方**恒定发** `content_snippet:true`（`:791`）——默认 true
  final bool contentSnippet;

  bool get isEmpty =>
      keyword.trim().isEmpty &&
      location == DriveSearchLocation.any &&
      fileType == DriveSearchFileType.any &&
      owner == DriveSearchOwner.any &&
      size == DriveSearchSize.any &&
      labelIds.isEmpty &&
      date == DriveSearchDate.any;

  DriveSearchQuery copyWith({
    String? keyword,
    DriveSearchLocation? location,
    String? customLocationId,
    DriveSearchFileType? fileType,
    String? customFileType,
    DriveSearchOwner? owner,
    String? customOwnerName,
    DriveSearchSize? size,
    int? sizeMegabytes,
    List<String>? labelIds,
    DriveSearchDate? date,
    int? startTime,
    int? endTime,
    bool? contentSnippet,
  }) => DriveSearchQuery(
    keyword: keyword ?? this.keyword,
    location: location ?? this.location,
    customLocationId: customLocationId ?? this.customLocationId,
    fileType: fileType ?? this.fileType,
    customFileType: customFileType ?? this.customFileType,
    owner: owner ?? this.owner,
    customOwnerName: customOwnerName ?? this.customOwnerName,
    size: size ?? this.size,
    sizeMegabytes: sizeMegabytes ?? this.sizeMegabytes,
    labelIds: labelIds ?? this.labelIds,
    date: date ?? this.date,
    startTime: startTime ?? this.startTime,
    endTime: endTime ?? this.endTime,
    contentSnippet: contentSnippet ?? this.contentSnippet,
  );

  // 值相等：`FutureProvider.family` 的 arg 必须可比，否则每次 build 都当新参数
  // 重新请求。标签列表用 `join` 比（顺序敏感，和我们拼上行参数一致）。
  @override
  bool operator ==(Object other) =>
      other is DriveSearchQuery &&
      other.keyword == keyword &&
      other.location == location &&
      other.customLocationId == customLocationId &&
      other.fileType == fileType &&
      other.customFileType == customFileType &&
      other.owner == owner &&
      other.customOwnerName == customOwnerName &&
      other.size == size &&
      other.sizeMegabytes == sizeMegabytes &&
      other.labelIds.join(',') == labelIds.join(',') &&
      other.date == date &&
      other.startTime == startTime &&
      other.endTime == endTime &&
      other.contentSnippet == contentSnippet;

  @override
  int get hashCode => Object.hash(
    keyword,
    location,
    customLocationId,
    fileType,
    customFileType,
    owner,
    customOwnerName,
    size,
    sizeMegabytes,
    labelIds.join(','),
    date,
    startTime,
    endTime,
    contentSnippet,
  );
}
