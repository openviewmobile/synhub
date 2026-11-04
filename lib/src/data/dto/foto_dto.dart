// 相册（Synology Photos）DTO —— 字段名逐一对照官方 Photos 2.4.0-644 的
// `datasource/network/vo/ImageVo.kt` / `FolderVo.kt` / `AlbumVo.kt`，
// 以及真机返回的 JSON（tool/foto_probe.dart）。
library;

import '../foto_media_kinds.dart';

/// 宽松取值（服务端有时给 int 有时给 string）。
///
/// 名字带 `foto` 前缀：`note_dto.dart` 里已有一组同义 helper，避免同名冲突。
String fText(Object? v) => v == null ? '' : '$v';

String? fTextOrNull(Object? v) {
  if (v == null) return null;
  final s = '$v';
  return s.isEmpty ? null : s;
}

int fInt(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

double fDouble(Object? v, [double fallback = 0]) {
  if (v is double) return v;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? fallback;
  return fallback;
}

bool fBool(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v == 'true' || v == '1';
  return false;
}

/// 缩略图状态（`additional.thumbnail`）。
///
/// `m`/`xl`/`preview` 的值是 `ready` / `broken` / `not_ready`；真机上
/// PNG 这两张的 `preview` 就是 `broken`（无 preview 规格），所以取图时
/// **按 sm → m → xl 顺序降级**，不能死等 preview。
class FotoThumbDto {
  const FotoThumbDto({
    this.sm = '',
    this.m = '',
    this.xl = '',
    this.preview = '',
    this.cacheKey = '',
    this.unitId = '',
  });

  final String sm;
  final String m;
  final String xl;
  final String preview;
  final String cacheKey;
  final String unitId;

  bool get hasAny => sm == 'ready' || m == 'ready' || xl == 'ready';

  /// 界面实际要请求的档位（官方 `ThumbnailSize.small`）。
  String get bestSize {
    if (sm == 'ready') return 'sm';
    if (m == 'ready') return 'm';
    if (xl == 'ready') return 'xl';
    return 'sm';
  }

  static FotoThumbDto fromJson(Map<String, dynamic> j) => FotoThumbDto(
    sm: fText(j['sm']),
    m: fText(j['m']),
    xl: fText(j['xl']),
    preview: fText(j['preview']),
    cacheKey: fText(j['cache_key']),
    unitId: fText(j['unit_id']),
  );
}

/// `additional.gps` —— NAS 索引器从照片 EXIF 解出的 **WGS-84** 经纬度。
///
/// 证据（`docs/photo-map-queries-and-coords.md` §5）：
///   * SPK `etc/sql/1.sql:81-82` `metadata(latitude float8, longitude float8)`；
///   * 官方 APK `ImageTableGps.java:12/15` `@SerializedName("latitude"/"longitude")`；
///   * `MapManager.java:418-424` 地图 marker 就是 `new LatLng(gps.latitude, gps.longitude)`。
///
/// ⚠️ **必须按"键存在性"判定，不许判数值**：官方 Gson 缺键时默认 `(0.0, 0.0)`，
/// 于是"缺 `gps` 键"与"真实赤道/本初子午线 (0,0)"在 double 上**不可分**。
/// 本 DTO 只在 `additional` 里**确实存在 `gps` 键**时才被构造
/// （见 [FotoItemDto.fromJson]）→ 字段为 `null` 一律表示"这条没有坐标"。
class FotoGpsDto {
  const FotoGpsDto({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;

  static FotoGpsDto fromJson(Map<String, dynamic> j) => FotoGpsDto(
    latitude: fDouble(j['latitude']),
    longitude: fDouble(j['longitude']),
  );
}

/// 一张照片 / 一段视频（`Browse.Item/list` 的元素）。
class FotoItemDto {
  const FotoItemDto({
    required this.id,
    required this.filename,
    this.filesize = 0,
    this.time = 0,
    this.indexedTime = 0,
    this.folderId = '',
    this.type = 'photo',
    this.ownerUserId = '',
    this.thumb = const FotoThumbDto(),
    this.isFavorite = false,
    this.albumIds = const [],
    this.live = false,
    this.rating = 0,
    this.gps,
    this.liveType = '',
    this.motionPhoto,
  });

  final String id;
  final String filename;

  /// 字节数
  final int filesize;

  /// **拍摄时间，单位秒**（服务端 `time`）
  final int time;
  final int indexedTime;
  final String folderId;

  /// `photo` / `video` / `live` / `burst` / `photo360` / `video360` / `motion_photo`
  /// / `panorama` —— 权威取值与判定见 [FotoMediaKind]。
  final String type;
  final String ownerUserId;
  final FotoThumbDto thumb;
  final bool isFavorite;
  final List<String> albumIds;

  /// ⚠️ **本字段曾被错误解读**（P13 修正）：旧实现是
  /// `fBool(additional['motion_photo']) || type == 'live_photo'`，两半都错 ——
  ///   1. `additional.motion_photo` 是**对象**不是布尔（官方
  ///      `ImageTableAdditional.java:43-44` `@SerializedName("motion_photo")
  ///      private ImageTableVideoMeta motionPhoto;`），`fBool(Map)` 恒为 false；
  ///   2. 服务端条目类型里**没有 `live_photo`** 这个字面量（是 `live` /
  ///      `motion_photo`，见 [FotoMediaKind]）。
  /// 于是它**恒为 false、且全仓无调用方** —— 即"实况照片识别"从来没有生效过。
  /// 现在它改用 [isLiveLike] 的真判定，保留字段只为不破坏既有构造点。
  final bool live;

  /// `additional.rating` —— 官方 APK `ApiBrowseItem.ADDITIONAL_RATING = "rating"`。
  ///
  /// `0` = **未评分**（官方 `rating_bar` 的语义；服务端对没评过的条目回 0 或
  /// 干脆不给这个键，两种都归一到 0）。写入走 `Browse.Item/set` 的 `rating`
  /// 参数（见 `FotoApi.setItemRating`）。
  final int rating;

  /// 这条评过星没有（[rating] > 0）。
  bool get hasRating => rating > 0;

  /// `additional.gps`（WGS-84）。`null` = **服务端没给这个键**（不是"坐标是 0"）。
  final FotoGpsDto? gps;

  /// 这条有没有可用坐标（判**键存在性**的结论，见 [FotoGpsDto] 的警告）。
  bool get hasGps => gps != null;

  /// `live_type`（实况照片分组成员角色：`photo` / `video` / `live`）。
  ///
  /// 空串 = 服务端没给这个键（普通照片就是没有）。
  final String liveType;

  /// `additional.motion_photo` 的**原始对象**（动态照片内嵌短视频的 `video_meta`）。
  ///
  /// `null` = 服务端没给这个键 → 这条**不是**可播放的动态照片
  /// （官方 `getMotionPhotoVideoUri` 在此返回 `Uri.EMPTY`，见报告）。
  /// 形状是 `video_meta`（`duration` / `video_codec` / `resolution_x` …），
  /// 我们**只判存在性**、顺带把 duration 读出来给界面用，不臆造别的字段。
  final Map<String, dynamic>? motionPhoto;

  /// 条目种类（服务端 `type` 的权威解析）。
  FotoMediaKind get kind => FotoMediaKind.fromWire(type);

  /// 分组成员角色（服务端 `live_type` 的权威解析）。
  FotoLiveType get liveTypeRole => FotoLiveType.fromWire(liveType);

  /// 是不是视频 —— 官方的 `isVideo()` 口径：`video` **或 `video360`**。
  ///
  /// ⚠️ 以前写死 `type == 'video'`：服务端真会给 `video360`，那种条目会被
  /// 当成静图去渲染（播放按钮消失）。这里跟随官方口径。
  ///
  /// 另外**实况照片的 video 成员也算视频**：那种条目的 `type` 是 `live`，
  /// 但它 `live_type == "video"`，本身就**是一段可播放的短视频**
  /// （文件名通常是 `.mov`）。若这里返回 false，查看器会把它当静图渲染
  /// ⇒ 缩略图上没有播放按钮，用户根本点不进那段视频。
  bool get isVideo => kind.isVideo || isLiveVideoMember;

  /// 360 全景（`photo360` / `video360`，官方 `is360()`）。
  bool get is360 => kind.is360;

  /// 全景静图（`photo360` / 旧口径 `panorama`）→ 要球面重投影才能看。
  bool get isPanoramaPhoto => kind.isPanoramaPhoto;

  /// 全景视频（`video360`）→ 本仓播放器不做球面，只能如实降级。
  bool get isPanoramaVideo => kind.isPanoramaVideo;

  /// 动态照片（`type == "motion_photo"`）：静图 + 内嵌短视频在同一条目里。
  bool get isMotionPhoto => kind.isMotionPhoto;

  /// 实况照片分组的成员（`type == "live"` **且** `live_type` 给出了已知角色）。
  ///
  /// ⚠️ 这里**不能**只判 `kind.isLive`：服务端会给 `live_type` 缺失/为空
  /// 的 `live` 条目，那种条目**认不出角色**（不知道它是静图那一半还是视频那一半），
  /// 官方口径同样要求 `liveType` 必须是一个**可识别的** LiveType 才算实况照片。
  /// 若只判 `type == "live"`，界面会给一个根本播不了的条目点亮 LIVE 徽标
  /// ⇒ 用户点下去才发现是死路。
  ///
  /// 角色已知时 `photo` 与 `video` **都算**实况照片成员（`photo` 是静图那一半，
  /// `video` 是短视频那一半，两者由 [pairLivePhotoVideo] 配对）。
  bool get isLivePhoto => kind.isLive && liveTypeRole != FotoLiveType.none;

  /// 可被"实况/动态"播放开关覆盖（官方 `isLiveOrMotion()`）。
  ///
  /// 与 [isLivePhoto] 保持一致的角色门槛：`live_type` 缺失的 `live` 条目
  /// **不算**可播放，否则开关会覆盖到一个认不出角色的条目上。
  bool get isLiveOrMotion => isLivePhoto || kind.isMotionPhoto;

  /// 动态照片的内嵌短视频**真的**能播吗 —— 官方判据是
  /// `additional.motion_photo` 非空（`getMotionPhotoVideoUri`）。
  bool get hasMotionPhotoVideo => motionPhoto != null;

  /// 实况照片这条**就是**那段短视频（配对时用它当"视频成员"）。
  bool get isLiveVideoMember => liveTypeRole.isVideoMember;

  DateTime get takenAt => DateTime.fromMillisecondsSinceEpoch(time * 1000);

  static FotoItemDto fromJson(Map<String, dynamic> j) {
    final additional = (j['additional'] as Map?)?.cast<String, dynamic>() ?? {};
    final thumbRaw = additional['thumbnail'];
    // **键存在性**：`containsKey` 才是"服务端给了 gps"的判据；数值 0 不算缺失。
    final gpsRaw = additional.containsKey('gps') ? additional['gps'] : null;
    // 同样按**键存在性**判 `motion_photo`（它是对象，不是布尔）。
    final motionRaw = additional.containsKey(kFotoAdditionalMotionPhoto)
        ? additional[kFotoAdditionalMotionPhoto]
        : null;
    final liveType = fText(j['live_type']);
    final type = fText(j['type']).isEmpty ? 'photo' : fText(j['type']);
    final item = FotoItemDto(
      id: fText(j['id']),
      filename: fText(j['filename']),
      filesize: fInt(j['filesize']),
      time: fInt(j['time']),
      indexedTime: fInt(j['indexed_time']),
      folderId: fText(j['folder_id']),
      type: type,
      ownerUserId: fText(j['owner_user_id']),
      thumb: thumbRaw is Map
          ? FotoThumbDto.fromJson(thumbRaw.cast<String, dynamic>())
          : const FotoThumbDto(),
      isFavorite: fBool(additional['favorite']),
      albumIds:
          (j['album_ids'] as List?)?.map((e) => '$e').toList() ?? const [],
      // 官方 `isLiveOrMotion()`（TimelineImage:521-523）：
      //   `isLivePhoto()` = type==LIVE && live_type.isLive()
      //   `isMotionPhoto()` = type==MOTION_PHOTO
      live:
          FotoMediaKind.fromWire(type) == FotoMediaKind.live ||
          FotoMediaKind.fromWire(type) == FotoMediaKind.motionPhoto,
      // 官方只在 `additional` 里读 rating（`filterByApiVersion` 决定要不要这个键）；
      // 但少数回包会把 additional 剥掉并把键放在顶层（同 gps 的处理），两种都认。
      rating: fInt(
        additional.containsKey('rating') ? additional['rating'] : j['rating'],
      ),
      gps: gpsRaw is Map
          ? FotoGpsDto.fromJson(gpsRaw.cast<String, dynamic>())
          : null,
      liveType: liveType,
      motionPhoto: motionRaw is Map ? motionRaw.cast<String, dynamic>() : null,
    );
    return item;
  }
}

/// 文件夹（`Browse.Folder/list`）。
class FotoFolderDto {
  const FotoFolderDto({
    required this.id,
    required this.name,
    this.parentId = '',
    this.shared = false,
    this.ownerUserId = '',
    this.itemCount = 0,
    this.covers = const [],
  });

  final String id;
  final String name;
  final String parentId;
  final bool shared;
  final String ownerUserId;

  /// 服务端只在部分接口给 `item_count`
  final int itemCount;

  /// 封面图（官方取第一张）
  final List<FotoThumbDto> covers;

  FotoThumbDto? get cover => covers.isEmpty ? null : covers.first;

  static FotoFolderDto fromJson(Map<String, dynamic> j) {
    final additional = (j['additional'] as Map?)?.cast<String, dynamic>() ?? {};
    final covers = additional['thumbnail'];
    return FotoFolderDto(
      id: fText(j['id']),
      name: fText(j['name']),
      parentId: fText(j['parent']),
      shared: fBool(j['shared']),
      ownerUserId: fText(j['owner_user_id']),
      itemCount: fInt(j['item_count']),
      covers: covers is List
          ? covers
                .whereType<Map>()
                .map((e) => FotoThumbDto.fromJson(e.cast<String, dynamic>()))
                .toList()
          : const [],
    );
  }
}

/// 相册（`Browse.Album/list`；普通相册另有 `Browse.NormalAlbum/list`）。
class FotoAlbumDto {
  const FotoAlbumDto({
    required this.id,
    required this.name,
    this.itemCount = 0,
    this.shared = false,
    this.ownerUserId = '',
    this.cover,
    this.type = 'normal',
  });

  final String id;
  final String name;
  final int itemCount;
  final bool shared;
  final String ownerUserId;
  final FotoThumbDto? cover;

  /// `normal`（普通相册）/ `condition`（条件相册）/ `person` 等
  final String type;

  static FotoAlbumDto fromJson(Map<String, dynamic> j) {
    final additional = (j['additional'] as Map?)?.cast<String, dynamic>() ?? {};
    final cover = additional['thumbnail'];
    return FotoAlbumDto(
      id: fText(j['id']),
      name: fText(j['name']),
      itemCount: fInt(j['item_count']),
      shared: fBool(j['shared']),
      ownerUserId: fText(j['owner_user_id']),
      type: fText(j['type']).isEmpty ? 'normal' : fText(j['type']),
      cover: cover is Map
          ? FotoThumbDto.fromJson(cover.cast<String, dynamic>())
          : null,
    );
  }
}

/// 人物（`SYNO.Foto.Browse.Person/list|get|suggest` 的元素）。
///
/// 字段名来自官方 Web 前端（SPK `ui/react_bundle.js` 的智能相册 reducer）：
/// `{id, name, item_count, show, type, cover, additional:{thumbnail}}`。
/// 封面**两种形态都认**：顶层 `cover`，或 `additional.thumbnail`；
/// 后者既可能是单个 Map，也可能是 List（取第一项）—— 服务端两种都出现过。
///
/// ⚠️ **未核实**：人物封面的 `additional.thumbnail` 到底带不带 `unit_id`。
/// 官方缩略图拼接（`ConnectionManager` 同族）的规则是：**有 `unit_id` 就
/// 用 `type="unit"` + `id=unit_id`**，否则用实体 id + `type="person"`；
/// 本 DTO 把两种情况都保留，交给 `photoSmartAlbumCoverRequest` 决定。
class FotoPersonDto {
  const FotoPersonDto({
    required this.id,
    required this.name,
    this.itemCount = 0,
    this.show = true,
    this.type = 'person',
    this.cover,
  });

  final String id;
  final String name;

  /// 这个人名下被索引到的照片数（`item_count`）
  final int itemCount;

  /// 服务端是否把这个人算作"可见"（`show`；DB 里有 `person.hidden`）
  final bool show;

  /// 官方这里恒为 `person`
  final String type;

  final FotoThumbDto? cover;

  static FotoPersonDto fromJson(Map<String, dynamic> j) => FotoPersonDto(
    id: fText(j['id']),
    name: fText(j['name']),
    itemCount: fInt(j['item_count']),
    show: j.containsKey('show') ? fBool(j['show']) : true,
    type: fText(j['type']).isEmpty ? 'person' : fText(j['type']),
    cover: fotoSmartAlbumCover(j),
  );
}

/// 场景 / 主题（`SYNO.Foto.Browse.Concept/list|get` 的元素）。
///
/// 字段与 [FotoPersonDto] 同形（官方 smart album 是同一套 reducer）；
/// `type` 官方为 `concept`。`Browse.Category`（顶层分类页签）本轮**不做**。
class FotoConceptDto {
  const FotoConceptDto({
    required this.id,
    required this.name,
    this.itemCount = 0,
    this.show = true,
    this.type = 'concept',
    this.cover,
  });

  final String id;
  final String name;
  final int itemCount;
  final bool show;
  final String type;
  final FotoThumbDto? cover;

  static FotoConceptDto fromJson(Map<String, dynamic> j) => FotoConceptDto(
    id: fText(j['id']),
    name: fText(j['name']),
    itemCount: fInt(j['item_count']),
    show: j.containsKey('show') ? fBool(j['show']) : true,
    type: fText(j['type']).isEmpty ? 'concept' : fText(j['type']),
    cover: fotoSmartAlbumCover(j),
  );
}

/// 人物 / 场景的封面缩略对象：顶层 `cover` 优先，退回 `additional.thumbnail`。
///
/// `cover` 与 `thumbnail` 都可能是 Map（单个）或 List（多张，取第一张）；
/// 空 Map 当"没有封面"（官方 `!Object.keys(t).length → None`）。
FotoThumbDto? fotoSmartAlbumCover(Map<String, dynamic> j) {
  final direct = _fotoCoverThumb(j['cover']);
  if (direct != null) return direct;
  final additional = (j['additional'] as Map?)?.cast<String, dynamic>() ?? {};
  return _fotoCoverThumb(additional['thumbnail']);
}

FotoThumbDto? _fotoCoverThumb(Object? raw) {
  if (raw is Map) {
    if (raw.isEmpty) return null;
    return FotoThumbDto.fromJson(raw.cast<String, dynamic>());
  }
  if (raw is List) {
    for (final e in raw) {
      if (e is Map && e.isNotEmpty) {
        return FotoThumbDto.fromJson(e.cast<String, dynamic>());
      }
    }
  }
  return null;
}

/// `SYNO.Foto.Browse.Person/get_migration_status` 的响应。
///
/// 官方 Web 前端：`getMigrationStatus`（无参）→ `{status, completion, total}`，
/// 失败时会命中服务端错误码 `901 PERSON_MIGRATION_IS_NOT_FINISHED`
/// （SPK `ui/react_bundle.js` 的 `SYNO_PHOTO_ERR` 表）。
///
/// ⚠️ **`status` 的取值枚举未核实**（没有从包/前端里抠到字符串表），
/// 所以这里**只原样保留**，不做"完成 / 进行中"的猜测；界面一律以
/// `Person/list` 自己的 `901` 错误为准，进度条只在 `total > 0` 时画。
class FotoPersonMigrationDto {
  const FotoPersonMigrationDto({
    this.status = '',
    this.completion = 0,
    this.total = 0,
  });

  final String status;
  final int completion;
  final int total;

  /// 服务端给了总量才谈得上进度
  bool get hasProgress => total > 0;

  /// `completion / total`，夹在 0..1（服务端偶尔给越界值）
  double get ratio =>
      total <= 0 ? 0 : (completion / total).clamp(0.0, 1.0).toDouble();

  static FotoPersonMigrationDto fromJson(Map<String, dynamic> j) =>
      FotoPersonMigrationDto(
        status: fText(j['status']),
        completion: fInt(j['completion']),
        total: fInt(j['total']),
      );
}

/// 一个标签（`SYNO.Foto.Browse.GeneralTag` 的实体）。
///
/// 字段名对照官方 Web 前端（SPK `ui/react_bundle.js` 的标签 saga）：
///   * `list`/`suggest` → `{list:[{id,name,…}]}`
///   * `create`         → `{tag:[{id,name}]}`
///   * `Browse.Item/get_tag` → `{intersection:[tagId…]}`（**只回 id**，名字另取 `list`）
class FotoTagDto {
  const FotoTagDto({required this.id, required this.name, this.count = 0});

  final String id;
  final String name;

  /// 打过这个标签的照片数（部分接口给 `count`）
  final int count;

  static FotoTagDto fromJson(Map<String, dynamic> j) => FotoTagDto(
    id: fText(j['id']),
    name: fText(j['name']),
    count: fInt(j['count']),
  );
}

/// `additional.video_meta`（官方 `ImageTableVideoMeta`）。
///
/// 字段名逐条对照官方 Android 2.4.0-644（`VideoInfoHelper.java`，jadx 1.5.3）
/// 的 getter 名 + Web 前端 `react_bundle.js` 的 `videoMeta` 用法：
/// `container_type` / `video_codec` / `audio_codec` / `resolution.{width,height}` /
/// `framerate` / `video_bitrate`。解析一律容错（缺字段给默认值，不抛）。
class FotoVideoMetaDto {
  const FotoVideoMetaDto({
    this.containerType = '',
    this.videoCodec = '',
    this.audioCodec = '',
    this.width = 0,
    this.height = 0,
    this.framerate = 0,
    this.videoBitrate = 0,
  });

  final String containerType;
  final String videoCodec;
  final String audioCodec;
  final int width;
  final int height;

  /// 帧率（官方 `FRAME_RATE_THRESHOLD = 50.0` 比较用）
  final double framerate;
  final int videoBitrate;

  /// 官方 `isUnderFHD`：宽高任一 ≤ 1080 即算"不到全高清"
  /// （`VideoInfoHelper.isUnderFHD`：`width>1080 ? height<=1080 : true`）。
  bool get underFhd => width > 1080 ? height <= 1080 : true;

  static FotoVideoMetaDto fromJson(Map<String, dynamic> j) {
    final res = (j['resolution'] as Map?)?.cast<String, dynamic>();
    return FotoVideoMetaDto(
      containerType: fText(j['container_type']),
      videoCodec: fText(j['video_codec']),
      audioCodec: fText(j['audio_codec']),
      width: fInt(res?['width']),
      height: fInt(res?['height']),
      framerate: fDouble(j['framerate']),
      videoBitrate: fInt(j['video_bitrate']),
    );
  }
}

/// `additional.video_convert[]` 的一项（官方 `VideoConvert`）。
///
/// 官方 `VideoInfoHelper.getVideoPlayInfo`：**先过滤掉 `quality` 以 `orig` 开头
/// 的转换档**，再按 `metadata.video_bitrate` 取最大（HIGHEST）/ 最小（LOWEST）；
/// 这个 `quality` 就是 `SYNO.Foto.Streaming/streaming` 要的档位字面量。
class FotoVideoConvertDto {
  const FotoVideoConvertDto({
    this.quality = '',
    this.metadata = const FotoVideoMetaDto(),
  });

  /// 服务端白名单短名（`high`/`medium`/`low`/`mobile`/`orig_*`…）
  final String quality;
  final FotoVideoMetaDto metadata;

  int get videoBitrate => metadata.videoBitrate;

  static FotoVideoConvertDto fromJson(Map<String, dynamic> j) {
    // 官方模型 `VideoConvert.getMetadata()`；也见过 metadata 平铺在同一层的形态。
    final meta = (j['metadata'] as Map?)?.cast<String, dynamic>() ?? j;
    return FotoVideoConvertDto(
      quality: fText(j['quality']),
      metadata: FotoVideoMetaDto.fromJson(meta),
    );
  }
}

/// `Browse.Item/get` 带 `additional:[video_convert,video_meta]` 的解析结果。
class FotoVideoInfoDto {
  const FotoVideoInfoDto({
    this.converts = const [],
    this.meta = const FotoVideoMetaDto(),
  });

  final List<FotoVideoConvertDto> converts;
  final FotoVideoMetaDto meta;

  /// 官方 `getVideoPlayInfo` 的候选集：非 `orig*` 且能过 `isVideoAvailableByMeta`。
  /// 这里只做"非 orig"这一半（另一半是纯策略，见 `chooseFotoVideoPlayback`）。
  List<FotoVideoConvertDto> get nonOriginalConverts => [
    for (final c in converts)
      if (!c.quality.startsWith('orig')) c,
  ];

  static FotoVideoInfoDto fromJson(Map<String, dynamic> j) {
    final additional = (j['additional'] as Map?)?.cast<String, dynamic>() ?? {};
    final converts = additional['video_convert'];
    final meta = (additional['video_meta'] as Map?)?.cast<String, dynamic>();
    // 有的接口把 `additional` 剥掉了，直接给顶层键 —— 两种都认
    final metaTop = (j['video_meta'] as Map?)?.cast<String, dynamic>();
    final convertsTop = j['video_convert'];
    final rawConverts = converts is List
        ? converts
        : (convertsTop is List ? convertsTop : const []);
    return FotoVideoInfoDto(
      converts: [
        for (final e in rawConverts)
          if (e is Map) FotoVideoConvertDto.fromJson(e.cast<String, dynamic>()),
      ],
      meta: FotoVideoMetaDto.fromJson(meta ?? metaTop ?? const {}),
    );
  }
}

/// 相册列表的默认排序（`Browse.Album/get_album_list_order` / `set_album_list_order`）。
///
/// 证据（官方 Web `ui/react_bundle.js`）：
///   * `bS(Browse.Album.setAlbumListOrder,{albumListSortBy:t,albumListSortDirection:n})`
///     —— 请求键是 camelCase，前端统一转 snake（模块 75296：
///     `replace(/([A-Z])/g, e => "_" + e.toLowerCase())`）→ 线上是
///     `album_list_sort_by` / `album_list_sort_direction`；
///   * 响应 `{album_list_sort_by, album_list_sort_direction,
///     shared_with_me_sort_by, shared_with_me_sort_direction,
///     shared_with_others_sort_by, shared_with_others_sort_direction}`；
///   * `get/set_album_list_order` 的版本：服务端 v2+（`api-server-authoritative:225`），
///     官方 Web 版本表钉 `2`。
class FotoAlbumListOrder {
  const FotoAlbumListOrder({
    this.sortBy = '',
    this.sortDirection = '',
    this.sharedWithMeSortBy = '',
    this.sharedWithMeSortDirection = '',
    this.sharedWithOthersSortBy = '',
    this.sharedWithOthersSortDirection = '',
  });

  final String sortBy;
  final String sortDirection;
  final String sharedWithMeSortBy;
  final String sharedWithMeSortDirection;
  final String sharedWithOthersSortBy;
  final String sharedWithOthersSortDirection;

  static FotoAlbumListOrder fromJson(Map<String, dynamic> j) {
    final data = (j['data'] as Map?)?.cast<String, dynamic>() ?? j;
    return FotoAlbumListOrder(
      sortBy: fText(data['album_list_sort_by']),
      sortDirection: fText(data['album_list_sort_direction']),
      sharedWithMeSortBy: fText(data['shared_with_me_sort_by']),
      sharedWithMeSortDirection: fText(data['shared_with_me_sort_direction']),
      sharedWithOthersSortBy: fText(data['shared_with_others_sort_by']),
      sharedWithOthersSortDirection: fText(
        data['shared_with_others_sort_direction'],
      ),
    );
  }
}

/// `SYNO.Foto.Setting.User/get` —— 决定界面要不要显示共享空间等。
class FotoSettingDto {
  const FotoSettingDto({
    this.teamSpacePermission = 'none',
    this.enablePerson = false,
    this.enableConcept = false,
    this.enableSimilar = false,
    this.timelineGroupUnit = 'day',
    this.itemSortBy = 'takentime',
    this.sortDirection = 'asc',
    this.autoGenerateThumbnail = true,
    this.dateFormat = 'yyyy-mm-dd',
  });

  /// `none` / `view` / `full` —— **普通用户经常是 `none`**（真机就是）
  final String teamSpacePermission;
  final bool enablePerson;
  final bool enableConcept;
  final bool enableSimilar;

  /// `day` / `month`
  final String timelineGroupUnit;
  final String itemSortBy;
  final String sortDirection;
  final bool autoGenerateThumbnail;
  final String dateFormat;

  /// 能不能看共享空间
  bool get canViewTeamSpace =>
      teamSpacePermission == 'view' || teamSpacePermission == 'full';

  /// 能不能往共享空间传
  bool get canUploadTeamSpace => teamSpacePermission == 'full';

  static FotoSettingDto fromJson(Map<String, dynamic> j) => FotoSettingDto(
    teamSpacePermission: fText(j['team_space_permission']).isEmpty
        ? 'none'
        : fText(j['team_space_permission']),
    enablePerson: fBool(j['enable_person']),
    enableConcept: fBool(j['enable_concept']),
    enableSimilar: fBool(j['enable_similar']),
    timelineGroupUnit: fText(j['timeline_group_unit']).isEmpty
        ? 'day'
        : fText(j['timeline_group_unit']),
    itemSortBy: fText(j['item_sort_by']).isEmpty
        ? 'takentime'
        : fText(j['item_sort_by']),
    sortDirection: fText(j['sort_direction']).isEmpty
        ? 'asc'
        : fText(j['sort_direction']),
    autoGenerateThumbnail: fBool(j['auto_generate_thumbnail']),
    dateFormat: fText(j['date_format']).isEmpty
        ? 'yyyy-mm-dd'
        : fText(j['date_format']),
  );
}
