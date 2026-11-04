// 相册 wave3 DTO：照片 EXIF / 相册缓存状态与大小 / 相册列表显示偏好。
//
// ★ 事实来源（逐条对照，**不猜**）：
//   1. `docs/api-method-level-gaps.md` §「真机复核（2026-09-22，普通用户 demo_user）」：
//      `Foto.Browse.Item:get_exif` **v1 + 必需参数 `id`**（无参 → 120 点名缺 `id`）；
//      `Foto.Download:get_cache_status` **v2** → `{"status":"done"}`；
//      `Foto.Download:calculate_cache_size` **v2** ✅；
//      `Foto.Browse.Album:get_album_list_display` **v3**（v1/v2 = 103）✅。
//   2. 回包字段名——**官方 APK 2.4.0-644（jadx）**：
//      * EXIF：`datasource/network/vo/objects/ImageTableExif.java` 六个
//        `@SerializedName`：`aperture` / `camera` / `exposure_time` /
//        `focal_length` / `iso` / `lens`（**全部 String?**）。
//        同一组列在 SPK `etc/sql/1.sql:70-85` 的 `metadata` 表里
//        （`focal_length/iso/exposure_time/aperture/lens/camera text NOT NULL`）。
//      * 缓存大小：官方 Web `react_bundle.js` `function BD()` →
//        `bS(Foto.Download.calculateCacheSize)` 读 `r.sent().cache_size`。
//      * 缓存状态：官方 Web `function Bk(e)` → `bS(Foto.Download.getCacheStatus)`
//        读 `t = o.sent().status`，并把 `"processing"` 视为"还在处理"。
//      * 列表显示：官方 Web `function OP()` → 读
//        `getAlbumListDisplay` 的 `album_display_type`；服务端
//        `SYNO.Foto.Browse.so` rodata 白名单 `["all_album","my_album"]`。
//
// 宽松解析：真机 `get_exif` 的**逐字回包没有抓到**，所以这里只认上面这些
// 有出处的字段名；认不出的键一律**不显示**（但记进 [FotoExifDto.rawKeys]
// 供报告/测试核对），绝不臆造中文名，也绝不把内部 id 上屏。
library;

import 'foto_dto.dart';

/// 官方 APK `ImageTableExif.java` 的六个字段名（服务端 `metadata` 表同名列）。
const List<String> kFotoExifKeys = [
  'aperture',
  'camera',
  'exposure_time',
  'focal_length',
  'iso',
  'lens',
];

/// 认得出、且**可以上屏**的标量值（Map/List 这类复合值不渲染）。
String _scalarText(Object? v) {
  if (v == null) return '';
  if (v is String) return v.trim();
  if (v is num || v is bool) return '$v';
  return '';
}

/// `api.call` 已经把顶层 `data` 拆掉了；这里再容忍一层 `{data:…}`（防回归）。
Map<String, dynamic>? _asMap(Object? j) {
  if (j is Map) {
    final m = j.cast<String, dynamic>();
    final inner = m['data'];
    if (inner is Map) return inner.cast<String, dynamic>();
    return m;
  }
  return null;
}

/// 在回包里**递归**找第一个含任一 [kFotoExifKeys] 的 Map。
///
/// 容忍 `{…}` / `{exif:{…}}` / `{list:[{…}]}` / 裸数组等形态；
/// 找不到就回 null（→ 空态，不给"0 项"表格）。
Map<String, dynamic>? _locateExifMap(Object? j, {int depth = 0}) {
  if (depth > 4) return null;
  if (j is List) {
    for (final e in j) {
      final hit = _locateExifMap(e, depth: depth + 1);
      if (hit != null) return hit;
    }
    return null;
  }
  final map = _asMap(j);
  if (map == null) return null;
  if (kFotoExifKeys.any(map.containsKey)) return map;
  for (final v in map.values) {
    if (v is Map || v is List) {
      final hit = _locateExifMap(v, depth: depth + 1);
      if (hit != null) return hit;
    }
  }
  return null;
}

/// `Browse.Item/get_exif` **v1** 的回包。
///
/// 只承载**能识别**的六个字段；[rawKeys] 是回包里出现过的原始键（排序后），
/// **仅供报告与用例核对，界面不渲染**。
class FotoExifDto {
  const FotoExifDto({
    this.camera = '',
    this.aperture = '',
    this.exposureTime = '',
    this.focalLength = '',
    this.iso = '',
    this.lens = '',
    this.rawKeys = const <String>[],
  });

  final String camera;
  final String aperture;
  final String exposureTime;
  final String focalLength;
  final String iso;
  final String lens;

  /// 回包顶层出现过的键（只用于核对；可能包含认不出的键或内部 id 字段名）。
  final List<String> rawKeys;

  /// 六个识别字段**一个都没有** → 明确空态（不是"0 项表格"）。
  bool get isEmpty =>
      camera.isEmpty &&
      aperture.isEmpty &&
      exposureTime.isEmpty &&
      focalLength.isEmpty &&
      iso.isEmpty &&
      lens.isEmpty;

  /// 有值的字段对（顺序固定 = 官方信息面板的展示顺序：相机 → 曝光三件套 → 镜头）。
  List<({String key, String value})> get fields => [
    if (camera.isNotEmpty) (key: 'camera', value: camera),
    if (aperture.isNotEmpty) (key: 'aperture', value: aperture),
    if (exposureTime.isNotEmpty) (key: 'exposure_time', value: exposureTime),
    if (focalLength.isNotEmpty) (key: 'focal_length', value: focalLength),
    if (iso.isNotEmpty) (key: 'iso', value: iso),
    if (lens.isNotEmpty) (key: 'lens', value: lens),
  ];

  static FotoExifDto fromJson(Object? json) {
    final map = _locateExifMap(json);
    if (map == null) return const FotoExifDto();
    final keys = <String>[for (final k in map.keys) k]..sort();
    return FotoExifDto(
      camera: _scalarText(map['camera']),
      aperture: _scalarText(map['aperture']),
      exposureTime: _scalarText(map['exposure_time']),
      focalLength: _scalarText(map['focal_length']),
      iso: _scalarText(map['iso']),
      lens: _scalarText(map['lens']),
      rawKeys: keys,
    );
  }
}

/// `Download/get_cache_status` **v2** 的回包（真机 `{"status":"done"}`）。
///
/// ⚠️ 只有**逐字等于 `done`** 才算"已完成"；`processing` 是"正在处理"，
/// 空/其它值一律**不显示成已完成**（官方 Web 也只把 `processing` 单独判）。
class FotoCacheStatusDto {
  const FotoCacheStatusDto({this.status = ''});

  /// 服务端原始状态串（`done` / `processing` / …）。
  final String status;

  bool get isEmpty => status.isEmpty;
  bool get isDone => status == 'done';
  bool get isProcessing => status == 'processing';

  static FotoCacheStatusDto fromJson(Object? json) {
    final map = _asMap(json);
    if (map == null) return const FotoCacheStatusDto();
    return FotoCacheStatusDto(status: fText(map['status']).trim());
  }
}

/// `Download/calculate_cache_size` **v2** 的回包。
///
/// 官方 Web 读 `cache_size`（数字，单位字节）。取不到就是 [bytes] == null
/// —— 界面显示"暂时取不到"，**不显示 0**。
class FotoCacheSizeDto {
  const FotoCacheSizeDto({this.bytes});

  final int? bytes;

  bool get hasValue => bytes != null;

  static FotoCacheSizeDto fromJson(Object? json) {
    if (json is num) return FotoCacheSizeDto(bytes: json.toInt());
    final map = _asMap(json);
    if (map == null) return const FotoCacheSizeDto();
    final raw = map['cache_size'];
    if (raw is num) return FotoCacheSizeDto(bytes: raw.toInt());
    if (raw is String) {
      final parsed = int.tryParse(raw);
      if (parsed != null) return FotoCacheSizeDto(bytes: parsed);
    }
    return const FotoCacheSizeDto();
  }
}

/// `Browse.Album/get_album_list_display` **v3** 的回包。
///
/// 官方 Web 读 `album_display_type`；服务端白名单
/// `["all_album","my_album"]`（`SYNO.Foto.Browse.so` rodata）。
class FotoAlbumListDisplayDto {
  const FotoAlbumListDisplayDto({this.displayType = ''});

  /// `all_album` / `my_album`（只读展示，不做写入）。
  final String displayType;

  bool get isEmpty => displayType.isEmpty;
  bool get isAllAlbums => displayType == 'all_album';
  bool get isMyAlbums => displayType == 'my_album';

  /// 服务端回了值但不在已取证白名单里 → 界面显示"未能识别"（不原样上屏）。
  bool get isUnknown => displayType.isNotEmpty && !isAllAlbums && !isMyAlbums;

  static FotoAlbumListDisplayDto fromJson(Object? json) {
    final map = _asMap(json);
    if (map == null) return const FotoAlbumListDisplayDto();
    return FotoAlbumListDisplayDto(
      displayType: fText(map['album_display_type']).trim(),
    );
  }
}
