// File Station C5（远程挂载 / 虚拟卷）DTO。
//
// 字段与取值**逐条对照服务端自带官方前端**
// `ui/file_browser/FileBrowser.js`（FileStation 包内，DSM 7 同源）：
//
// ```js
// // —— 列表：SYNO.FileStation.Mount.List / get / v1 ——
// sendWebAPI({api:"SYNO.FileStation.Mount.List",version:1,method:"get",
//   callback:function(e,t){ this.loadData(t) }})
// loadData: e.mountConfig.enable_iso_mount / e.mountConfig.enable_remote_mount
//           e.isoList / e.remoteList
// createStore: fields ["type","source","mount_point","actor","date","auto_mount"]
// ```
// （`MountGrid.createStore`，见 `/tmp/spk/export_FileStation/ui/file_browser/FileBrowser.js`）
//
// 关键结论（审计 §7.5 C3 的复核）：官方 VFS 只有 **cifs + iso** 两种
// （`util/Common.java:124-125` 的 `VIRTUAL_CIFS_PATH` / `VIRTUAL_ISO_PATH`），
// **没有 NFS 以外的第三种远端口、也没有 WebDAV 挂载**。
// 所以枚举里只放这两个；NFS/WebDAV 不做（WebDAV 官方自己在 DSM≥7 标废弃）。
library;

/// 官方 `Mount.List` 里会出现的挂载类型（只有这两个是官方 VFS）。
enum FileMountType {
  /// `SYNO.FileStation.VirtualFolder` 的 `type` 也是 `iso`
  iso,

  /// 远端 SMB/CIFS 卷；`type` 字段原文就是小写 `cifs`
  cifs;

  /// 服务端 `Mount.mount_remote` 的 `mount_type` 要大写 `CIFS`
  /// （`FileBrowser.js` `onMountRemote`：`"CIFS"===a` 才补 `account`/`passwd`）。
  String get wireValue => switch (this) {
    FileMountType.iso => 'ISO',
    FileMountType.cifs => 'CIFS',
  };

  /// `Mount.unmount` / `Mount.List.remount` 的 `mount_type` —— **不是** `CIFS`。
  ///
  /// 原文：`MountGrid.onRemount` 发 `{mount_type: <活动页 itemId>}`，而两个页的
  /// `itemId` 就是 `"iso"` / `"remote"`
  /// （`new MountGrid({type:"iso", itemId:"iso"})` / `{type:"remote", itemId:"remote"}`）；
  /// 文件列表这条路的 `mount_type` 来自 `List` 的 `mount_point_type`
  /// （`parseRemoteTreeNode`: `e.mountType = r.mount_point_type`），代码里
  /// 比对的就是 `"iso"` / `"remote"`（`getSourceTypeByPath`）。
  String get volumeValue => switch (this) {
    FileMountType.iso => 'iso',
    FileMountType.cifs => 'remote',
  };

  /// `Mount.List.get` 回包 / `VirtualFolder.list` 的 `type` 值
  String get listValue => switch (this) {
    FileMountType.iso => 'iso',
    FileMountType.cifs => 'cifs',
  };

  static FileMountType? tryParse(String raw) {
    switch (raw.toLowerCase()) {
      case 'iso':
        return FileMountType.iso;
      case 'cifs':
      case 'smb':
        return FileMountType.cifs;
      default:
        return null;
    }
  }
}

/// `Mount.List.get` 的 `mountConfig` —— **能不能挂载由服务器说**
/// （`enable_iso_mount` / `enable_remote_mount`）。两个都 false 时官方直接
/// 弹 `error_privilege_not_enough` 并把入口藏掉。
class FileMountConfig {
  const FileMountConfig({
    this.enableIsoMount = false,
    this.enableRemoteMount = false,
  });

  final bool enableIsoMount;
  final bool enableRemoteMount;

  /// 服务器允不允许这个账号挂载任何类型的卷
  bool get anyEnabled => enableIsoMount || enableRemoteMount;

  factory FileMountConfig.fromJson(Map<String, dynamic> json) =>
      FileMountConfig(
        enableIsoMount: json['enable_iso_mount'] == true,
        enableRemoteMount: json['enable_remote_mount'] == true,
      );
}

/// 一个已挂载的虚拟卷（`Mount.List.get` 的 `isoList[]` / `remoteList[]`）。
///
/// 字段原文：`{type, source, mount_point, actor, date, auto_mount}`。
class FileMountDto {
  const FileMountDto({
    required this.type,
    required this.source,
    required this.mountPoint,
    this.actor = '',
    this.date = 0,
    this.autoMount = '',
  });

  /// `iso` / `cifs`（原样保留服务端字符串，无法识别时 [mountType] 为 null）
  final String type;

  /// ISO = 镜像文件路径；CIFS = `\\server\share`
  final String source;

  /// 挂载点（FileStation 虚拟路径，可直接拿去 `List.list` 浏览）
  final String mountPoint;

  /// 挂载发起者（`actor`）
  final String actor;

  /// `date` 是**秒**
  final int date;

  /// `yes` / `no` / `fail`（`MountGrid` 的 renderer 原文）
  final String autoMount;

  FileMountType? get mountType => FileMountType.tryParse(type);

  bool get isIso => mountType == FileMountType.iso;

  /// 开机自动挂载失败（`auto_mount == "fail"`，官方渲染成错误文案）
  bool get autoMountFailed => autoMount == 'fail';

  /// 挂载点是否处于"连不上"状态。官方树节点用 `mountType=="remotefail"` 标记；
  /// `Mount.List.get` 的条目本身不带这个字段，所以这里只认 `source` 为空的情况。
  bool get sourceMissing => source.isEmpty;

  factory FileMountDto.fromJson(Map<String, dynamic> json) => FileMountDto(
    type: '${json['type'] ?? ''}',
    source: '${json['source'] ?? ''}',
    mountPoint: '${json['mount_point'] ?? ''}',
    actor: '${json['actor'] ?? ''}',
    date: _int(json['date']),
    autoMount: '${json['auto_mount'] ?? ''}',
  );
}

/// `Mount.List.get` 的完整返回。
class FileMountList {
  const FileMountList({
    this.config = const FileMountConfig(),
    this.isoList = const [],
    this.remoteList = const [],
  });

  final FileMountConfig config;
  final List<FileMountDto> isoList;
  final List<FileMountDto> remoteList;

  List<FileMountDto> get all => [...isoList, ...remoteList];

  factory FileMountList.fromJson(Map<String, dynamic> json) {
    List<FileMountDto> parse(Object? raw) => raw is List
        ? raw
              .whereType<Map>()
              .map((e) => FileMountDto.fromJson(Map<String, dynamic>.from(e)))
              .where((m) => m.mountPoint.isNotEmpty)
              .toList()
        : <FileMountDto>[];
    final config = json['mountConfig'];
    return FileMountList(
      config: config is Map
          ? FileMountConfig.fromJson(Map<String, dynamic>.from(config))
          : const FileMountConfig(),
      isoList: parse(json['isoList']),
      remoteList: parse(json['remoteList']),
    );
  }
}

/// WORM（WriteOnce）状态 —— 逐条对照官方 APK
/// `com/synology/DSfile/vos/WormVo.java:45-115` 的 `State` 枚举。
///
/// **两个不同的数字，别混**（APK 原文）：
///   * 线上值是 `@SerializedName` 的**下标 0..9**（`state` 字段）；
///   * 枚举内部还有一个**位掩码 value**：`UNKNOWN=0`、`NOT_IN_WORM_SHARE=16`、
///     `CANNOT_BE_LOCKED=17`、`OPEN=18`、`IMMUTABLE_LOCKED=32`、
///     `APPENDABLE_LOCKED=33`、`WEAK_IMMUTABLE_LOCKED=34`、
///     `WEAK_APPENDABLE_LOCKED=35`、`IMMUTABLE_EXPIRED=64`、
///     `APPENDABLE_EXPIRED=65`。
///   * `isLocked() = value & 32`、`isOpen() = value & 16`、`isExpired() = value & 64`
///     —— 所以"锁定"的是 **32/33/34/35**（= 下标 4/5/8/9）。
abstract final class FileWormState {
  // 线上下标（0..9）
  static const int wireUnknown = 0;
  static const int wireNotInWormShare = 1;
  static const int wireCannotBeLocked = 2;
  static const int wireOpen = 3;
  static const int wireImmutableLocked = 4;
  static const int wireAppendableLocked = 5;
  static const int wireImmutableExpired = 6;
  static const int wireAppendableExpired = 7;
  static const int wireWeakImmutableLocked = 8;
  static const int wireWeakAppendableLocked = 9;

  // 内部位掩码（`WormVo.State.value`）
  static const int notInWormShare = 16;
  static const int cannotBeLocked = 17;
  static const int open = 18;
  static const int immutableLocked = 32;
  static const int appendableLocked = 33;
  static const int weakImmutableLocked = 34;
  static const int weakAppendableLocked = 35;
  static const int immutableExpired = 64;
  static const int appendableExpired = 65;

  /// 下标 0..9 → 内部位掩码；已经是位掩码（>=16）就原样返回。
  static int normalize(int raw) =>
      raw >= 0 && raw <= 9 ? _wireToValue[raw] : raw;

  static const List<int> _wireToValue = [
    0, // UNKNOWN
    16, // NOT_IN_WORM_SHARE
    17, // CANNOT_BE_LOCKED
    18, // OPEN
    32, // IMMUTABLE_LOCKED
    33, // APPENDABLE_LOCKED
    64, // IMMUTABLE_EXPIRED
    65, // APPENDABLE_EXPIRED
    34, // WEAK_IMMUTABLE_LOCKED
    35, // WEAK_APPENDABLE_LOCKED
  ];

  /// 官方 `WormVo.Worm.State.isLocked()` = `value & 32`（APK 原文）。
  /// 传**内部位掩码**（线上 0..9 先用 [normalize]）。
  static bool isLocked(int value) => (value & 32) > 0;

  /// 官方 `isOpen()` = `value & 16`
  static bool isOpen(int value) => (value & 16) > 0;

  /// 官方 `isExpired()` = `value & 64`
  static bool isExpired(int value) => (value & 64) > 0;
}

int _int(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}
