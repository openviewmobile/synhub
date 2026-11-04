// 相册业务 API —— 在 [DsmWebApi] 之上把 `SYNO.Foto.*` / `SYNO.FotoTeam.*`
// 收敛成强类型方法。
//
// ★ 事实来源（逐条对照，不许猜）：
//   1. 服务端能力表（真机 `SYNO.API.Info`，73 个 `*Foto*` API，见
//      docs/api-inventory-modules.md §4）
//   2. 官方 Photos 2.4.0-644 反编译：
//      `datasource/network/api/ApiName.kt`（两套前缀）
//      `datasource/network/api/ApiBrowseItem.java`（方法名 + 参数名）
//      `datasource/network/ConnectionManager.java`（缩略图/原图 URL 拼法）
//   3. 真机实测（tool/foto_probe.dart，DSM 7.4 / DS923+ / SynologyPhotos 1.9.1-10928）
//
// 真机实测要点：
//   * 登录 session 名用官方 Photos 的 `synofoto`（`SynoApiAuth.VALUE_SESSION`）；
//     但用聊天那套 `Chat` 登录的 sid 调 Foto API 也能通（同一用户 sid 通用）。
//   * **本机没有 `Browse.Timeline` 这个方法**（调它 → `103 方法不存在`）；
//     时间轴就是 `Browse.Item/list` + `sort_by=takentime`，官方 App 的
//     `listTimelineByOffset` 也是走 `ApiBrowseItem`。
//   * 缩略图 URL 里 `type`/`size`/`cache_key` **都过 Gson（带引号）**，
//     `id` 裸着；照抄官方拼接即可（实测返回 JPEG）。
//   * 原图 URL 的参数名是 **`unit_id`**（不是 `id`），值是**裸数字的 JSON 数组**：
//     `SYNO.Foto.Download&version=1&method=download&unit_id=[9317]`
//     —— 实测正好等于 filesize；换成 `id=[9547]` 会得到 `117`。
library;

import 'dart:convert';

import '../core/i18n/data_text.dart';
import '../core/net/traffic_meter.dart';
import '../dsm/webapi.dart';
import 'dto/foto_dto.dart';
import 'dto/foto_wave3_dto.dart';
import 'foto_media_kinds.dart';

/// 空间：个人（`SYNO.Foto.`）/ 共享（`SYNO.FotoTeam.`）。
enum FotoSpace {
  personal('SYNO.Foto.', '个人空间'),
  team('SYNO.FotoTeam.', '共享空间');

  const FotoSpace(this.prefix, this.label);

  final String prefix;

  /// 中文回落（界面侧读 [labelText]；`lib/src/features/**` 本轮不在迁移范围内）
  final String label;

  /// ARB key（多语言用；数据层不能碰 `AppText`）
  String get labelKey => switch (this) {
    FotoSpace.personal => 'fotoSpacePersonal',
    FotoSpace.team => 'fotoSpaceTeam',
  };

  /// 当前语言文案（走 `data_text.dart` 的 [dataText]；没装翻译器时回落 [label]）
  String labelText() => dataText(labelKey, label);
}

/// 批量打标签的分批大小（官方 Web 前端常量 `BATCH_UPDATE_GENERAL_TAG_SIZE = 50`）。
const int kFotoTagBatchSize = 50;

/// 人物 / 场景列表的一页大小。
///
/// 官方 Web 前端常量表（SPK `ui/react_bundle.js`）：
/// `AUTO_SMART_ALBUM: 100`（人物 / 场景这类"智能相册"的 `loadLimit`）。
const int kFotoSmartAlbumPageSize = 100;

/// 人物名字建议的条数上限（官方 Web 前端常量 `PERSON_SUGGESTION_LIMIT = 10`）。
const int kFotoPersonSuggestionLimit = 10;

/// 标签浏览（`Browse.Item/list_with_filter`）每页大小。
///
/// 与时间线同一个口径：分页而不是"一次全拉"；页大小取 100（官方 Web 前端
/// 智能相册常量 `AUTO_SMART_ALBUM: 100` 同档）。
const int kFotoTagItemsPageSize = 100;

/// 「最近添加」（`Browse.RecentlyAdded/list`）每页大小。
///
/// 与标签浏览同档（100）。服务端 `limit` 上限没有逐字取证，`limit` 是**必需参数**
/// （真机 `{offset:0}` → `120 {"name":"limit","reason":"required"}`），所以这里
/// 只给默认值、绝不下发空值。
const int kFotoRecentlyAddedPageSize = 100;

/// 时间轴**每页**大小（`Browse.Item/list` 的 `limit`）。
///
/// 这就是以前写死的 `200`，但现在它是**分页状态机的页大小**，不再是"总量上限"
/// —— 触底时用 `offset = 已加载条数` 继续取下一页（见 `timeline()` 与
/// `PhotoTimelineNotifier`）。服务端 `limit` 上限没有逐字取证，取 200 与旧行为
/// 一致，避免一次拉太多缩略图。
const int kFotoTimelinePageSize = 200;

/// `SYNO.Foto.Streaming / streaming` 的 `type` = 一个 **timeline item**（官方默认）。
///
/// 服务端 `.so` 的 rodata 白名单只有两个值（`APIValidator::IsBelong`）：
/// `["item", "unit"]`。官方前端视频播放组件的 `defaultProps.type` 就是 `"item"`，
/// 且**每次都带**这个参数（`SYNO.Foto.Streaming.so` 的 `type` 与错误原因串
/// `required` 相邻）→ 本仓库以前不带它是错的，见 docs/media-streaming-diagnosis.md。
const String kFotoStreamingTypeItem = 'item';

/// `SYNO.Foto.Streaming / streaming` 的 `type` = 一个 **unit**（存储单元 id）。
const String kFotoStreamingTypeUnit = 'unit';

/// `SYNO.Foto.Streaming / streaming` 的 `quality` 白名单（服务端 `.so` rodata）。
///
/// **每一项都是"服务端转码产物"的名字**（对应 `video_convert.quality` +
/// `libsynofoto-control-video.so` 的 `SYNOPHOTO_FILM_*` 文件）：原文件本身
/// **没有**对应的 `quality` —— 官方对"本来就能直接播"的视频走
/// `SYNO.Foto.Download`（见 [FotoApi.streamingUrl] 与 [FotoApi.downloadUrl]）。
const List<String> kFotoStreamingQualities = [
  'flv',
  'high',
  'medium',
  'low',
  'mobile',
  'orig_iphone',
  'orig_android',
  'orig_h264',
  'orig_mp4',
  'convert_mp4',
  'motion_photo',
];

/// `SYNO.Foto.Streaming` 通道的 Range / 可用性取证状态：**false = 未取证**。
///
/// 2026-09-22 真机（`docs/live-nas-verification.md` §4.4）只证明了
/// **`SYNO.Foto.Download:download`** 的 `206`；`Streaming` 因必填 `quality`
/// 是字符串枚举、14 个候选值全被拒（`reason:"condition"`；`high/low/medium`
/// 另撞 404 HTML）→ **一个字节都没取到，既未证真也未证伪**。
///
/// 所以：相册的 `supportsRange`（可拖动 / 可续播）只由 **Download** 的证据打开
/// （见 [downloadUrl]），本通道恒为 false，**不许**跟着 Download 一起翻成 true。
const bool kFotoStreamingRangeProven = false;

/// `Browse.Item/delete` 的候选版本（服务端 `.lib`：`delete` 在 v1..v7 都在；
/// 官方 Android `ApiBrowseItem.API_VERSION = 7`、官方 Web 能力表也是 `delete:7`）。
const List<int> kFotoItemDeleteVersions = [7, 6, 5, 4, 3, 2, 1];

/// 产出**照片条目**的 `Browse.Item/list` 请求的 `additional`。
///
/// 保留第一期的 `thumbnail` / `favorite`，**追加 `gps`** —— 让 NAS 索引器写进
/// `metadata.latitude/longitude` 的 WGS-84 坐标真的回到客户端，地图入口才能做
/// "精确 marker"。证据链（SPK 白名单 + APK 读取路径）见
/// `docs/photo-map-queries-and-coords.md` §5：`additional` 的 `"gps"` 与
/// `"exif"` 是两个**独立**白名单项，且**不需要新权限**（`authLevel` 与 `list` 同）。
///
/// **只**给本文件里产出 [FotoItemDto] 的那几个 `Browse.Item/list` 用；
/// 相册 / 文件夹 / 人物 / 场景的**列表**（`Browse.Album`、`Browse.Folder`、
/// `Browse.Person`、`Browse.Concept`）**不加** —— 它们不产照片条目，
/// 加了只是白掏解析成本。
const List<String> kFotoItemAdditional = ['thumbnail', 'favorite', 'gps'];

/// `additional.motion_photo`（动态照片内嵌短视频元数据）的**能力位版本**。
///
/// 官方口径（`ConnectionManager.java:1814`
/// `new ApiCapabilities(apiMaxVersionWithName >= 2, apiMaxVersionWithName >= 3, …)`
/// 与 `ApiBrowseItem.filterByApiVersion:1392`
/// `if (!ADDITIONAL_MOTION_PHOTO.equals(obj) || isSupportMotionPhoto())`）：
/// `Browse.Item` 的 `maxVersion >= 3` 才允许把这个键放进 `additional`。
/// 按 §5.3 走**应用层能力表**裁剪，不硬编码 `maxVersion`。
///
/// 真机旁证（2026-09-22，只读）：这个键被服务端**静默丢弃**而不是报错 ——
/// 请求 `additional=["thumbnail","favorite","gps","motion_photo","exif",
/// "resolution","orientation","rating"]` 时回包里只有
/// `exif/orientation/orientation_original/resolution/rating/thumbnail`。
/// 所以裁剪不是"省流量"，是**让版本语义正确**。
const int kFotoMotionPhotoSupportVersion = 3;

/// 评分（P40）—— 官方 APK `ApiBrowseItem` 原文（jadx 1.5.3，2.4.0-644）：
///
/// ```
/// public static final int SUPPORT_RATING_VERSION = 2;   // :97
/// private static final String METHOD_SET = "set";       // :42
/// private static final String KEY_RATING = "rating";    // :71
/// public static final String ADDITIONAL_RATING = "rating"; // :53
/// ```
///
/// 写入路径（`:478-479`，`getSetPhotoRatingResponse`）：
/// `getSetResponse(list, new SetParamBuilder(…).rating(i).build(), …)` →
/// `browseItemApiRequests.set(api, "set", version, gson.toJson(idList), map)`
/// 且 `SetParamBuilder.build()` 里 `map.put("rating", String.valueOf(num))`
/// —— 注意 rating 值是**十进制字符串、不带 JSON 引号**（与 `rotate_action` 不同）。
///
/// 能力位（`ConnectionManager.java:1814`）：
/// `isSupportRating = (Browse.Item 的 maxVersion) >= 2`；
/// 读取时官方用 `filterByApiVersion` 把 `"rating"` 从 `additional` 里**按能力位裁掉**
/// （`:1386`）。所以本仓库也照此：只有 [FotoApi.supportsRating] 为真才带这个 additional。
const int kFotoRatingSupportVersion = 2;

/// 评分的取值范围：`0`（未评分）.. `5`（官方 `rating_one/rating_plural` 的满值）。
const int kFotoRatingMax = 5;

/// 服务端不支持评分（`Browse.Item` maxVersion < [kFotoRatingSupportVersion]）。
///
/// 界面不该在 [FotoApi.supportsRating] 为 false 时给出入口；这里只是数据层的
/// **兜底**，防止有人绕过能力位直接调用。
class FotoRatingUnsupportedException implements Exception {
  const FotoRatingUnsupportedException();

  @override
  String toString() =>
      'FotoRatingUnsupportedException(Browse.Item maxVersion < '
      '$kFotoRatingSupportVersion)';
}

/// `Browse.Item/move|copy` 的同名冲突动作 —— 官方 APK `PreferenceManager.CopyMoveAction`
/// 原文（jadx：`SKIP = new CopyMoveAction("SKIP", 0, "skip")`、
/// `OVERWRITE = new CopyMoveAction("OVERWRITE", 1, "overwrite")`）。
///
/// 服务端 `action` 字段要的是这个**字符串值**（官方把 `getValue()` 原样发出）。
enum FotoCopyMoveAction {
  skip('skip'),
  overwrite('overwrite');

  const FotoCopyMoveAction(this.value);

  final String value;
}

/// `Browse.Item/set` 的旋转动作 —— 官方 `ApiBrowseItem.ROTATE_ACTIONS` 原文。
///
/// 证据（官方 APK 2.4.0-644，jadx 1.5.3）：
///   * `datasource/network/api/ApiBrowseItem.java:115`
///     `private static final String[] ROTATE_ACTIONS = {"clockwise", "180", "counter_clockwise"};`
///   * `:486` `getSetPhotoRotationResponse` 里
///     `new SetParamBuilder(...).rotateAction(ROTATE_ACTIONS[i - 1]).build()`
///     且 `:482-483` 明确 `throw new IllegalArgumentException("rotateIndex can only be 1, 2 or 3")`
///     （`EditorViewModelKt.calculateRotateResult`：`(i ± 1 + 4) % 4`）。
///   * `:1204` 参数写入 `map.put(KEY_ROTATE_ACTION, gson.toJson(str2))` —— 值是**带引号的 JSON 串**。
///
/// 官方 Android **只有旋转**（无裁剪 / 滤镜 / 调整），见
/// `docs/photo-p1-implementation.md` 的编辑取证结论。
enum FotoRotateAction {
  clockwise('clockwise'),
  rotate180('180'),
  counterClockwise('counter_clockwise');

  const FotoRotateAction(this.value);

  /// 服务端 `rotate_action` 的字面量
  final String value;
}

/// `Browse.Item/set` 的候选版本（官方 `ApiBrowseItem.API_VERSION = 7`；
/// 服务端 `.lib` 里 `set` 在 v1..v7 都在）。
const List<int> kFotoItemSetVersions = [7, 6, 5, 4, 3, 2, 1];

/// `Browse.Item/get` 取 `video_convert` / `video_meta` 的候选版本
/// （官方 `ApiBrowseItem.API_VERSION = 7`，官方 Web 能力表 `get:7`）。
const List<int> kFotoVideoInfoVersions = [7, 6, 5, 4, 3, 2, 1];

/// 视频画质偏好三档 —— 官方 `array/video_quality_value` 原文。
///
/// 证据（官方 APK 2.4.0-644，E2/E1）：
///   * `resources.arsc`：`array/video_quality_value = [auto | quality | speed]`
///     （标签 `array/video_quality = [Auto | Quality first | Speed first]`）；
///   * `PreferenceManager.PLAY_QUALITY`（jadx：`private static final String
///     PLAY_QUALITY = "play_quality"`）读写 `VideoInfoHelper.QualityBias`；
///   * `VideoInfoHelper.QualityBias`：`QUALITY("quality")` / `SPEED("speed")` /
///     `AUTO("auto")`（jadx 常量池原文）。
///
/// 这三档**不是**直接发给服务端的字符串：它们是**选档策略**。官方
/// `VideoInfoHelper`（jadx 1.5.3，`getVideoPlayInfo` / `determinePlayConvertQuality`）
/// 的实际语义见 [chooseFotoVideoPlayback] 的逐条注释。
enum FotoVideoQualityBias {
  auto('auto'),
  quality('quality'),
  speed('speed');

  const FotoVideoQualityBias(this.wireValue);

  /// 官方持久化值（`play_quality` 的取值）
  final String wireValue;

  static FotoVideoQualityBias fromWire(String? v) {
    for (final b in values) {
      if (b.wireValue == v) return b;
    }
    return FotoVideoQualityBias.auto;
  }
}

/// 官方 `VideoInfoHelper` 的常量（jadx 1.5.3 原文）：
/// `CONTAINER_WHITELIST = {"mp4"}`、`CODEC_WHITELIST = {"h264","hevc"}`、
/// `NO_HEVC_VIDEO_CODEC_WHITELIST = {"h264"}`、`FRAME_RATE_THRESHOLD = 50.0`。
const Set<String> kFotoVideoContainerWhitelist = {'mp4'};
const Set<String> kFotoVideoCodecWhitelist = {'h264', 'hevc'};
const Set<String> kFotoVideoNoHevcCodecWhitelist = {'h264'};
const double kFotoVideoFrameRateThreshold = 50.0;

/// 一次视频播放最终用哪条通道。
///
/// * [isOriginal] = true → 走 `SYNO.Foto.Download / download`（**原文件**，
///   与官方 `composeOriginalVideoPlayInfo` → `composeDownloadUnitUrl` 一致）；
/// * [isOriginal] = false → 走 `SYNO.Foto.Streaming / streaming` + [streamingQuality]
///   （**转码产物**，官方 `composeVideoPlayInfo`）。
///
/// ⚠️ **`raw`/`original` 永不作为 [streamingQuality]**：官方 `QT()` 对"原文件"
/// 回 `"raw"`，而 `"raw"===n` 分支直接走 `u9`（Download），根本不进 Streaming
/// （`ui/react_bundle.js` 模块 4040）。服务端 `Streaming` 白名单里也**没有**
/// `raw`/`original`（`SYNO.Foto.Streaming.so` rodata）。本类由构造器保证。
class FotoVideoPlaybackPlan {
  const FotoVideoPlaybackPlan.original()
    : isOriginal = true,
      streamingQuality = null;

  const FotoVideoPlaybackPlan.streaming(this.streamingQuality)
    : isOriginal = false;

  final bool isOriginal;

  /// 服务端白名单短名；[isOriginal] 时恒为 null
  final String? streamingQuality;

  bool get playable => isOriginal || (streamingQuality?.isNotEmpty ?? false);
}

/// 按官方 `VideoInfoHelper` 的算法选播放通道（**纯函数，可离线断言**）。
///
/// 逐条照抄官方 Android 2.4.0-644（jadx 1.5.3）：
/// 1. 候选转换档 = `video_convert` 里 **`quality` 不以 `orig` 开头** 且
///    `metadata` 过 [isVideoAvailableByMeta] 的那些；
/// 2. 候选为空 → **原文件**（Download）；
/// 3. 否则按偏好定档：
///    * [FotoVideoQualityBias.quality]：原文件本身可直放
///      （mp4 ∧ codec∈{h264,hevc}）→ 原文件；否则 **码率最高** 的转码档；
///    * [FotoVideoQualityBias.auto]：**Wi-Fi** 时若原文件可直放
///      （mp4 ∧ codec=h264 ∧ 不到 FHD ∧ 帧率 < 50）→ 原文件，否则码率最高；
///      非 Wi-Fi → **码率最低**；
///    * [FotoVideoQualityBias.speed]：**码率最低**。
///
/// ⚠️ 这里选出的 `quality` 是**该 unit 的 `video_convert` 里真实存在**的档
/// （官方也是这么做的）—— 不要凭空造档位。服务端白名单见
/// [kFotoStreamingQualities]，但"unit 上有没有这一档"只能由响应决定。
FotoVideoPlaybackPlan chooseFotoVideoPlayback({
  required FotoVideoInfoDto info,
  required FotoVideoQualityBias bias,
  required bool onWifi,
}) {
  bool available(FotoVideoConvertDto c, FotoVideoQualityBias b) {
    final m = c.metadata;
    if (!kFotoVideoContainerWhitelist.contains(m.containerType)) return false;
    if (b == FotoVideoQualityBias.quality) {
      return kFotoVideoCodecWhitelist.contains(m.videoCodec);
    }
    // AUTO：不允许 HEVC（NO_HEVC_VIDEO_CODEC_WHITELIST），且要不到 FHD、帧率低
    if (!kFotoVideoNoHevcCodecWhitelist.contains(m.videoCodec)) return false;
    if (!m.underFhd) return false;
    return m.framerate < kFotoVideoFrameRateThreshold;
  }

  final candidates = [
    for (final c in info.nonOriginalConverts)
      if (available(c, bias)) c,
  ];

  // 原文件本身能不能直放（决定 QUALITY / AUTO(Wi-Fi) 是否走 Download）
  final meta = info.meta;
  final metaAvailable = switch (bias) {
    FotoVideoQualityBias.quality =>
      kFotoVideoContainerWhitelist.contains(meta.containerType) &&
          kFotoVideoCodecWhitelist.contains(meta.videoCodec),
    FotoVideoQualityBias.auto =>
      onWifi &&
          kFotoVideoContainerWhitelist.contains(meta.containerType) &&
          kFotoVideoNoHevcCodecWhitelist.contains(meta.videoCodec) &&
          meta.underFhd &&
          meta.framerate < kFotoVideoFrameRateThreshold,
    FotoVideoQualityBias.speed => false,
  };

  final preferOriginal = switch (bias) {
    FotoVideoQualityBias.quality => metaAvailable,
    FotoVideoQualityBias.auto => metaAvailable,
    // SPEED 恒取最低档；只有"连一档转码都没有"时才回落原文件（官方同款顺序）
    FotoVideoQualityBias.speed => false,
  };
  if (preferOriginal || candidates.isEmpty) {
    return const FotoVideoPlaybackPlan.original();
  }

  final wantLowest = switch (bias) {
    FotoVideoQualityBias.speed => true,
    FotoVideoQualityBias.auto => !onWifi,
    FotoVideoQualityBias.quality => false,
  };
  var best = candidates.first;
  for (final c in candidates.skip(1)) {
    if (wantLowest
        ? c.videoBitrate < best.videoBitrate
        : c.videoBitrate > best.videoBitrate) {
      best = c;
    }
  }
  final quality = best.quality;
  // 结构保证：raw/original 永不进 Streaming（官方 `QT()` 的 `"raw"` 走 Download）
  if (quality.isEmpty || quality == 'raw' || quality == 'original') {
    return const FotoVideoPlaybackPlan.original();
  }
  return FotoVideoPlaybackPlan.streaming(quality);
}

/// `Upload.Item/backup_check` 的**一个查重条目**。
///
/// 键名来自 SPK 反汇编（`SYNO.Foto.Upload.so` 的 `UploadItemImpl::BackupCheck` /
/// `BackupCheckV4` 内联构造）：`name` / `hash_code` / `takentime` / `mtime`。
class FotoBackupCheckEntry {
  const FotoBackupCheckEntry({
    required this.name,
    this.hash = '',
    this.takenTime = 0,
    this.mtime = 0,
  });

  final String name;

  /// 客户端算的内容哈希。**算法未知**（SPK 无任何线索）→ 默认空串；
  /// 服务端仍会按 `name`/`mtime` 判定。
  ///
  /// ⚠️ 字段名不能叫 `hashCode`（会和 `Object.hashCode` 冲突）。
  final String hash;

  /// 拍摄时间（**秒**）
  final int takenTime;

  /// 文件修改时间（**秒**）
  final int mtime;

  Map<String, dynamic> toJson() => {
    'name': name,
    'hash_code': hash,
    'takentime': takenTime,
    'mtime': mtime,
  };
}

/// `backup_check` 的解析结果。
///
/// ⚠️ 响应结构**未核实**：只从几个可能的键里尽力认（`list` / `check` /
/// `duplicate_list` / `items` / `duplicate`）。一个都认不出 → [usable] = false，
/// 调用方**必须**回落到客户端去重（列目标文件夹比文件名+大小），不要据此跳过上传。
class FotoBackupCheckResult {
  const FotoBackupCheckResult({
    this.existingNames = const {},
    this.usable = false,
  });

  /// 服务端认为"已存在"的文件名
  final Set<String> existingNames;

  /// 这次响应形态认没认出来
  final bool usable;

  static const List<String> _candidateKeys = [
    'list',
    'check',
    'duplicate_list',
    'items',
    'duplicate',
  ];

  static FotoBackupCheckResult parse(
    Map<String, dynamic> data,
    List<FotoBackupCheckEntry> entries,
  ) {
    final byHash = {
      for (final e in entries)
        if (e.hash.isNotEmpty) e.hash: e.name,
    };
    for (final key in _candidateKeys) {
      final raw = data[key];
      if (raw is! List) continue;
      final names = <String>{};
      for (final e in raw) {
        if (e is String && e.isNotEmpty) {
          names.add(e);
        } else if (e is Map) {
          final name = '${e['name'] ?? ''}';
          if (name.isNotEmpty) {
            names.add(name);
          } else {
            final hash = '${e['hash_code'] ?? ''}';
            final mapped = byHash[hash];
            if (mapped != null) names.add(mapped);
          }
        }
      }
      return FotoBackupCheckResult(existingNames: names, usable: true);
    }
    return const FotoBackupCheckResult();
  }
}

/// 相册**播放设置**对媒体 URL 的改写（P48，纯函数、可单测）。
///
/// 官方 Android 的相册设置里有三项（`photo-parity-audit.md:170` 的
/// `str_stream_http` / `str_stream_http_port` / `str_video_play_cert_invalid_desc`）：
///   * `useHttp`：**用 HTTP 而不是 HTTPS 取流**；
///   * `httpPort`：HTTP 端口（`error_http_port_incorrect` 是端口非法的报错）；
///   * `ignoreCert`：自签证书时忽略证书错误。
///
/// 语义**只在客户端**（服务端 API 不适用）：改写的是本地拼出来的直链
/// （`Download/download`、`Streaming/streaming`），`_sid`/`SynoToken` 查询串
/// **原样保留**。
///
/// ⚠️ 只改**播放**（download / streaming）两条 URL，不动缩略图（缩略图走
/// 应用自己的 Dio，本来就信任自签证书，改了反而多一次握手）。
class FotoMediaUrlOverride {
  const FotoMediaUrlOverride({
    this.useHttp = false,
    this.httpPort,
    this.ignoreCert = false,
  });

  /// 关闭覆盖（默认）：媒体 URL 一律保持会话原本的 scheme/端口。
  static const FotoMediaUrlOverride none = FotoMediaUrlOverride();

  final bool useHttp;
  final int? httpPort;

  /// 忽略证书错误。本仓库的 HTTP 客户端（`DioFactory`）本来就无条件放行自签
  /// 证书，这一位只用于**界面/日志**如实标注"用户已选择忽略证书错误"，
  /// 不改 URL。
  final bool ignoreCert;

  bool get isNoop => !useHttp && httpPort == null;

  /// 端口合法性（1–65535）。返回 null = 合法。
  static String? validatePort(int? port) {
    if (port == null) return null;
    if (port < 1 || port > 65535) return 'photoPlaybackPortInvalid';
    return null;
  }

  /// 改写一个媒体 URL。
  ///
  /// * URL 解析不出来 / 覆盖是空操作 → **原样返回**（绝不把一个好 URL 弄坏）；
  /// * `useHttp` → scheme 换成 `http`；
  /// * `httpPort` 合法 → 换端口；非法 → 忽略端口、只按 [useHttp] 处理。
  String apply(String url) {
    if (isNoop) return url;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    var scheme = uri.scheme;
    if (useHttp && scheme != 'http') scheme = 'http';
    final port = (httpPort != null && validatePort(httpPort) == null)
        ? httpPort!
        : null;
    if (scheme == uri.scheme && port == null) return url;
    // `Uri.replace` 不能把端口置空（`port: null` 表示"用默认端口"），
    // 所以只在真的要换端口时才传 port；否则保持原端口。
    return port == null
        ? uri.replace(scheme: scheme).toString()
        : uri.replace(scheme: scheme, port: port).toString();
  }

  @override
  bool operator ==(Object other) =>
      other is FotoMediaUrlOverride &&
      other.useHttp == useHttp &&
      other.httpPort == httpPort &&
      other.ignoreCert == ignoreCert;

  @override
  int get hashCode => Object.hash(useHttp, httpPort, ignoreCert);

  @override
  String toString() =>
      'FotoMediaUrlOverride(useHttp: $useHttp, httpPort: $httpPort, '
      'ignoreCert: $ignoreCert)';
}

class FotoApi {
  FotoApi(
    DsmWebApi api, {
    this.space = FotoSpace.personal,
    this.mediaUrlOverride,
  }) : api = api.withModule(TrafficModules.photos);

  final DsmWebApi api;
  final FotoSpace space;

  /// 播放设置（P48）：媒体直链的 scheme/端口覆盖；null = 不改写。
  final FotoMediaUrlOverride? mediaUrlOverride;

  FotoApi inSpace(FotoSpace s) => s == space
      ? this
      : FotoApi(api, space: s, mediaUrlOverride: mediaUrlOverride);

  /// 挂上/替换播放设置覆盖（返回 `this` 表示无需新建）。
  FotoApi withMediaUrlOverride(FotoMediaUrlOverride? override) =>
      override == null || override.isNoop
      ? (mediaUrlOverride == null ? this : FotoApi(api, space: space))
      : FotoApi(api, space: space, mediaUrlOverride: override);

  /// 给媒体直链套播放设置（缩略图不走这里，见 [FotoMediaUrlOverride]）。
  String _playbackUrl(String url) => mediaUrlOverride?.apply(url) ?? url;

  String _name(String apiId) => '${space.prefix}$apiId';

  /// 候选版本里挑服务器真正支持的最大版本（与 `FileStationApi.negotiate` 同规则）。
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

  int _version(String apiId, List<int> candidates) =>
      negotiate(_name(apiId), candidates);

  /// 服务端支持评分吗？（P40）
  ///
  /// 官方口径：`ConnectionManager.java:1814` 的
  /// `isSupportRating = getApiMaxVersionWithName("Browse.Item") >= 2`。
  /// 能力表**没发现**（`apiTable == null`）或没有这个 API → 一律 **false**
  /// （宁可不给入口，也不给一个点了报错的按钮）。
  bool get supportsRating {
    final entry = api.apiTable?[_name('Browse.Item')];
    if (entry == null) return false;
    return entry.maxVersion >= kFotoRatingSupportVersion;
  }

  /// 服务端支持 `additional.motion_photo`（动态照片内嵌短视频元数据）吗？（P13）
  ///
  /// 官方口径：`isSupportMotionPhoto = getApiMaxVersionWithName("Browse.Item") >= 3`
  /// （`ConnectionManager.java:1814` × `ApiBrowseItem.SUPPORT_MOTION_PHOTO_VERSION:96`）。
  /// 与 [supportsRating] 同一套 fail-closed：能力表没发现 → false。
  bool get supportsMotionPhoto {
    final entry = api.apiTable?[_name('Browse.Item')];
    if (entry == null) return false;
    return entry.maxVersion >= kFotoMotionPhotoSupportVersion;
  }

  /// 产出照片条目时实际下发的 `additional`。
  ///
  /// 评分键**按能力位裁剪**（对齐官方 `ApiBrowseItem.filterByApiVersion`：
  /// `if (!"rating".equals(str) || isSupportRating())`）——老服务器不会被塞一个
  /// 它不认识的 `additional`，新服务器则能一次把星级带回来。
  ///
  /// `motion_photo`（P13）同理裁剪：只有 [supportsMotionPhoto] 为真才追加，
  /// 否则返回的 `additional` 与旧行为**逐字一致**（不改变既有请求）。
  List<String> itemAdditional([List<String> base = kFotoItemAdditional]) {
    var out = base;
    if (supportsRating && !out.contains('rating')) out = [...out, 'rating'];
    if (supportsMotionPhoto && !out.contains(kFotoAdditionalMotionPhoto)) {
      out = [...out, kFotoAdditionalMotionPhoto];
    }
    return out;
  }

  /// 复杂参数必须是 **JSON 字符串**（`additional`、`id` 数组…），官方一律 Gson 串。
  static String js(Object? v) => jsonEncode(v);

  // --------------------------------------------------------------- 设置

  /// `Setting.User/get`（官方 `ApiSettingUser`）。
  Future<FotoSettingDto> setting() async {
    final apiId = 'Setting.User';
    final data = await api.call(
      _name(apiId),
      'get',
      preferredVersion: _version(apiId, const [1]),
    );
    return FotoSettingDto.fromJson(data);
  }

  // ------------------------------------------------- 预览再生成（HEIC / AME）

  /// 正在"再生成预览"的条目（`RegeneratePreview / list_regenerating`，**v1**）。
  ///
  /// ### 为什么是它
  /// 官方 Android 的 HEIC/HEIF 显示不是自己解码，而是**靠服务端 Image Assistant
  /// / AME 先生成 JPEG 预览**；拿不到预览时官方会引导用户"生成预览"
  /// （`str_ame_defect_alert_title` / `str_auto_generate_thumbnail_desc` /
  /// `str_ame_need_to_reindex_*`，见 `photo-parity-audit.md:132`）。
  /// 本方法就是那条引导链路的**状态查询**。
  ///
  /// ### 证据
  ///   * 权威表 `docs/api-server-authoritative.md:250`：
  ///     `SYNO.Foto.RegeneratePreview` v1 `list_regenerating,
  ///     regenerate_preview_by_nas, restore_from_regenerating, set_regenerating`
  ///     —— **普通用户**；
  ///   * 真机只读探针（2026-09-22，本批）：
  ///     `GET /webapi/query.cgi?api=SYNO.Foto.RegeneratePreview&method=list_regenerating&version=1`
  ///     → `{"data":{"list":[]},"success":true}`；
  ///     且 `SYNO.API.Info` 回 `minVersion:1 maxVersion:1 path:entry.cgi`。
  ///
  /// ⚠️ **成功回包只有 `list` 一个键有原文**（真机空列表）→ 列表项结构**未取证**，
  /// 因此这里返回原始 Map 列表、**不猜字段**，界面只按"有没有正在生成的条目"
  /// 用（见 `photoHeicPreview*`）。
  Future<List<Map<String, dynamic>>> listRegeneratingPreviews() async {
    final apiId = 'RegeneratePreview';
    final data = await api.call(
      _name(apiId),
      'list_regenerating',
      preferredVersion: _version(apiId, const [1]),
    );
    final raw = data['list'];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) Map<String, dynamic>.from(e),
    ];
  }

  /// 让 NAS 侧（Image Assistant / AME）再生成预览
  /// （`RegeneratePreview / regenerate_preview_by_nas`，**v1**）。
  ///
  /// ⚠️ **只发无参调用**：方法与版本有权威表 + 真机注册表原文，但**参数形态
  /// 未取证**（本批不猜参数，见任务书纪律 3）。这是一个**写操作**（会占用 NAS
  /// 的转码算力），所以调用方必须：
  ///   1. 只对 HEIC/HEIF 这类"服务端预览缺失"的项提供入口；
  ///   2. 先弹确认框；
  ///   3. **绝不**在探测循环里调用。本批的真机探针**没有**调用它。
  Future<void> regeneratePreviewByNas() async {
    final apiId = 'RegeneratePreview';
    await api.call(
      _name(apiId),
      'regenerate_preview_by_nas',
      preferredVersion: _version(apiId, const [1]),
    );
  }

  // --------------------------------------------------------------- 浏览

  /// 时间轴 = `Browse.Item/list` + `sort_by=takentime`。
  ///
  /// 官方 App 同样没有用 `Browse.Timeline`（那个 API 在本机也不存在）。
  ///
  /// **分页**：这是时间轴**首屏 + 触底续取**的唯一取数口。`offset` 是"已加载
  /// 条数"，服务端按 `offset/limit` 切片；页大小见 [kFotoTimelinePageSize]。
  /// 以前调用方只发一次 `limit:200`、从不递增 `offset`，超过 200 张就再也取不到
  /// —— 那正是本批修掉的 P0 缺陷。
  ///
  /// ⚠️ `Browse.Diff` **不用于**这条路径，本批也**没有**封装它：真机实探
  /// （`docs/photo-api-live.md` §4）确认它是"给我自上次同步以来的变更"的双参数
  /// 同步接口（缺 `diff_version` → 120、再缺 `version_time` → 120；v1 无此方法），
  /// **不能当翻页游标**；且其成功回包结构仍未取证（同文档 §5）→ 按"不猜着实现"
  /// 原则留作后续独立项（变更同步），不混进分页。
  Future<List<FotoItemDto>> timeline({
    int offset = 0,
    int limit = 100,
    String sortBy = 'takentime',
    String sortDirection = 'desc',
    List<String> additional = kFotoItemAdditional,
  }) async {
    final apiId = 'Browse.Item';
    final data = await api.call(
      _name(apiId),
      'list',
      preferredVersion: _version(apiId, const [7, 6, 5, 4, 3, 2, 1]),
      params: {
        'offset': '$offset',
        'limit': '$limit',
        'sort_by': sortBy,
        'sort_direction': sortDirection,
        'additional': js(itemAdditional(additional)),
      },
    );
    return _items(data);
  }

  /// 某个相册里的照片（`Browse.Item/list` + `album_id`）。
  Future<List<FotoItemDto>> albumItems(
    String albumId, {
    int offset = 0,
    int limit = 200,
  }) async {
    final apiId = 'Browse.Item';
    final data = await api.call(
      _name(apiId),
      'list',
      preferredVersion: _version(apiId, const [7, 6, 5, 4, 3, 2, 1]),
      params: {
        'album_id': albumId,
        'offset': '$offset',
        'limit': '$limit',
        'additional': js(itemAdditional()),
      },
    );
    return _items(data);
  }

  /// 某个文件夹里的照片（`Browse.Item/list` + `folder_id`）。
  Future<List<FotoItemDto>> folderItems(
    String folderId, {
    int offset = 0,
    int limit = 200,
  }) async {
    final apiId = 'Browse.Item';
    final data = await api.call(
      _name(apiId),
      'list',
      preferredVersion: _version(apiId, const [7, 6, 5, 4, 3, 2, 1]),
      params: {
        'folder_id': folderId,
        'offset': '$offset',
        'limit': '$limit',
        'additional': js(itemAdditional()),
      },
    );
    return _items(data);
  }

  /// 收藏里的全部照片。
  ///
  /// 真机取证（2026-09-18）：
  ///   * `Browse.Favorite/list_all` 只回 `{list:[{item_id, user_id}]}` —— **不带
  ///     文件名/缩略图**，客户端还得再按 id 取一次；而 `Browse.Item/list` 的
  ///     `id` 过滤**不生效**（给 `[9547]` 也会把全部照片吐回来，数字/字符串数组
  ///     都一样）。所以拿 `list_all` 拼列表这条路走不通。
  ///   * `Browse.Item/list` + `favorite: true` 直接返回**完整条目**（含缩略图），
  ///     真机验证只回已收藏的那张 → 就用它。
  Future<List<FotoItemDto>> favorites({int offset = 0, int limit = 200}) async {
    final apiId = 'Browse.Item';
    final data = await api.call(
      _name(apiId),
      'list',
      preferredVersion: _version(apiId, const [7, 6, 5, 4, 3, 2, 1]),
      params: {
        'offset': '$offset',
        'limit': '$limit',
        'favorite': 'true',
        'additional': js(itemAdditional()),
      },
    );
    return _items(data);
  }

  /// 最近添加（`Browse.RecentlyAdded/list`）。
  ///
  /// 权威依据（官方 Photos 2.4.0-644 反编译 `ApiBrowseRecentlyAdded.java`）：
  ///   * `:29` `API_ID = "Browse.RecentlyAdded"`（经 `ApiName.getApiName` 拼
  ///     `SYNO.Foto.` / `SYNO.FotoTeam.` —— 所以这里只能用 [_name] 动态拼名）；
  ///   * `:27` `METHOD_LIST = "list"`；
  ///   * `:21-25` 线参白名单 `additional / end_time / limit / offset / start_time`；
  ///   * `:38` 请求接口逐个 `@Field`：`offset`(int) / `limit`(int) /
  ///     `start_time`(long) / `additional`(String，Gson 串)；
  ///   * `:56-62` 官方自己发 `offset:0, limit:4, start_time=<30 天前>, additional=["thumbnail"]`
  ///     （那是"封面"用途；页面列表用下面的分页参数）。
  ///
  /// 真机取证（2026-09-22，本会话只读探针）：
  ///   * `SYNO.Foto.Browse.RecentlyAdded` 在 `SYNO.API.Info` 里 **v1–6** 都在
  ///     （`SYNO.FotoTeam.Browse.RecentlyAdded` 同区间）；
  ///   * `list v1|v4|v6 {offset:0, limit:3}` → ✅ 真实数据，首条
  ///     `{"filename":"SVID_20250606_193253_1.mp4", "id":9659, …}`；
  ///   * **`offset` 是必需参数**：`{limit:3}` → `120 {"name":"offset","reason":"required"}`；
  ///     **`limit` 也是必需参数**：`{offset:0}` → `120 {"name":"limit","reason":"required"}`，
  ///     且 `{offset:0, limit:"x"}` → `120 {"name":"limit","reason":"type"}`（整数）；
  ///   * `additional:["thumbnail"]`（JSON 串）→ 回包里带
  ///     `additional.thumbnail.{cache_key,unit_id,sm,xl}`（与 [thumbnailUrl] 同形）；
  ///   * `end_time` 被接受（`{offset:0,limit:3,end_time:<ts>}` → 合法空列表）。
  ///
  /// 版本：候选取 v6→v1（本机 maxVersion=6，三种版本实测同形），由
  /// [_version] 与能力表协商出服务器真正支持的最大版本。
  Future<List<FotoItemDto>> recentlyAdded({
    int offset = 0,
    int limit = kFotoRecentlyAddedPageSize,
    // 时间下界（**epoch 秒**），服务端按 `time` 过滤。
    int? startTime,
    // 时间上界（**epoch 秒**）。
    int? endTime,
    List<String> additional = kFotoItemAdditional,
  }) async {
    final apiId = 'Browse.RecentlyAdded';
    final data = await api.call(
      _name(apiId),
      'list',
      preferredVersion: _version(apiId, const [6, 5, 4, 3, 2, 1]),
      params: {
        // 两个都**必需**（真机 120 点名），所以恒定下发。
        'offset': '$offset',
        'limit': '$limit',
        if (startTime != null) 'start_time': '$startTime',
        if (endTime != null) 'end_time': '$endTime',
        'additional': js(itemAdditional(additional)),
      },
    );
    return _items(data);
  }

  /// 相册列表（`Browse.Album/list`，官方 `ApiBrowseAlbum`）。
  ///
  /// `sortBy`/`sortDirection` 逐字对照官方 APK：
  /// `ApiBrowseAlbum.KEY_SORT_BY = "sort_by"`、`KEY_SORT_DIRECTION =
  /// "sort_direction"`，且 `SUPPORT_ALBUM_SORTING_VERSION = 2`（v2 起服务端接受
  /// 排序参数）→ 这里只在调用方**显式给了**排序时才发，保持默认行为不变。
  /// 取值：`album_name` / `album_type` / `create_time` / `starting_time` /
  /// `sharing_status` / `share_mod_time`（`SortingManager.AlbumSortBy`），方向
  /// `asc` / `desc`（`SortingManager.SortDirection`）。
  Future<List<FotoAlbumDto>> albums({
    int offset = 0,
    int limit = 100,
    String? sortBy,
    String? sortDirection,
  }) async {
    final apiId = 'Browse.Album';
    final data = await api.call(
      _name(apiId),
      'list',
      preferredVersion: _version(apiId, const [5, 4, 3, 2, 1]),
      params: {
        'offset': '$offset',
        'limit': '$limit',
        if (sortBy != null && sortBy.isNotEmpty) 'sort_by': sortBy,
        if (sortDirection != null && sortDirection.isNotEmpty)
          'sort_direction': sortDirection,
        'additional': js(const ['thumbnail']),
      },
    );
    return _list(data, FotoAlbumDto.fromJson);
  }

  /// 相册列表的**默认排序**（`Browse.Album/get_album_list_order`）。
  ///
  /// 证据：服务端 v2+ 有此方法（`api-server-authoritative:225`）；官方 Web 版本表
  /// 钉 `get_album_list_order:2`；响应键 `album_list_sort_by` /
  /// `album_list_sort_direction`（见 [FotoAlbumListOrder]）。
  Future<FotoAlbumListOrder> getAlbumListOrder() async {
    final apiId = 'Browse.Album';
    final data = await api.call(
      _name(apiId),
      'get_album_list_order',
      preferredVersion: _version(apiId, const [5, 4, 3, 2]),
    );
    return FotoAlbumListOrder.fromJson(data);
  }

  /// 保存相册列表的默认排序（`Browse.Album/set_album_list_order`）。
  ///
  /// 请求键 `album_list_sort_by` / `album_list_sort_direction` —— 官方 Web 传
  /// camelCase，前端统一转 snake 后落地为这两个名字（证据见 [FotoAlbumListOrder]）。
  Future<void> setAlbumListOrder({
    required String sortBy,
    required String sortDirection,
  }) async {
    final apiId = 'Browse.Album';
    await api.call(
      _name(apiId),
      'set_album_list_order',
      preferredVersion: _version(apiId, const [5, 4, 3, 2]),
      params: {
        'album_list_sort_by': sortBy,
        'album_list_sort_direction': sortDirection,
      },
    );
  }

  /// 普通相册（用户手建的，`Browse.NormalAlbum/list`）。
  ///
  /// 真机坑：能力表写 `NormalAlbum v1-4`，但 **v4 里没有 `list`**
  /// （实测 v1~v3 通、v4 → `103 方法不存在`），所以候选版本上限取 3。
  Future<List<FotoAlbumDto>> normalAlbums({
    int offset = 0,
    int limit = 100,
  }) async {
    final apiId = 'Browse.NormalAlbum';
    final data = await api.call(
      _name(apiId),
      'list',
      preferredVersion: _version(apiId, const [3, 2, 1]),
      params: {
        'offset': '$offset',
        'limit': '$limit',
        'additional': js(const ['thumbnail']),
      },
    );
    return _list(data, FotoAlbumDto.fromJson);
  }

  /// 文件夹树的一层（`id = 0` 是根；`folder_id` 形式见真机返回 `parent`）。
  Future<List<FotoFolderDto>> folders({
    String parentId = '0',
    int offset = 0,
    int limit = 200,
  }) async {
    final apiId = 'Browse.Folder';
    final data = await api.call(
      _name(apiId),
      'list',
      preferredVersion: _version(apiId, const [2, 1]),
      params: {
        'id': parentId,
        'offset': '$offset',
        'limit': '$limit',
        'additional': js(const ['thumbnail']),
      },
    );
    return _list(data, FotoFolderDto.fromJson);
  }

  /// 当前空间的**根文件夹对象**（`Browse.Folder/get`，**不带 `id`**）。
  ///
  /// 官方 Web 前端就是这么取根目录 id 的（`ui/react_bundle.js`：`Pa()` →
  /// `FolderAPI.get()` → `sent().folder`，随后把 `.id` 当 `targetFolderId` 用）。
  ///
  /// ⚠️ 真机教训（2026-09-20，DSM 7 / Photos 1.9.1）：`list` 习惯用 `id=0` 表示
  /// "当前空间的根"，但 **`create` 不能拿 `0` 当 `target_id`** —— 服务端回
  /// `120 请求参数无效`（不是权限问题）。先用本方法取到**真实根 id**，再用它建
  /// 目录，立刻成功（已真机验证 `folderprobe/sub1`）。
  Future<FotoFolderDto> folderRoot() async {
    final apiId = 'Browse.Folder';
    final data = await api.call(
      _name(apiId),
      'get',
      preferredVersion: _version(apiId, const [2, 1]),
    );
    final folder = (data['folder'] as Map?)?.cast<String, dynamic>();
    if (folder == null) {
      throw DsmApiException(
        DsmErrorCode.internalError,
        method: 'SYNO.Foto.Browse.Folder.get',
      );
    }
    return FotoFolderDto.fromJson(folder);
  }

  /// 新建文件夹（`Browse.Folder/create`）。
  ///
  /// 形态与**版本**都来自官方 Web 前端（SPK `ui/react_bundle.js`）：
  ///   * 调用：`FolderAPI.create({target_id: 父文件夹 id, name})`，回包 `{folder:{…}}`；
  ///   * 版本表（官方前端钉死的）：`create:1, rename:1, delete:1, move:1, copy:1,
  ///     list:2, get:2, set_order:1, set_cover:2` —— **写操作是 v1**，照抄。
  ///   * ⚠️ `parentId` 必须是**真实 folder id**，根目录请先走 [folderRoot]
  ///     （传 `'0'` 会被服务端判成 `120 请求参数无效`，真机踩过）。
  Future<FotoFolderDto> createFolder({
    required String parentId,
    required String name,
  }) async {
    final apiId = 'Browse.Folder';
    final target = parentId == '0' ? (await folderRoot()).id : parentId;
    final data = await api.call(
      _name(apiId),
      'create',
      preferredVersion: _version(apiId, const [1]),
      params: {'target_id': target, 'name': name},
    );
    final folder = (data['folder'] as Map?)?.cast<String, dynamic>();
    if (folder == null) {
      return FotoFolderDto(id: '', name: name, parentId: target);
    }
    return FotoFolderDto.fromJson(folder);
  }

  /// 重命名文件夹（`Browse.Folder/rename`，**v1**，理由同 `createFolder`）。
  ///
  /// 官方 Web 前端：`FolderAPI.rename({id: 文件夹 id, name})`，回包 `{folder:{…}}`。
  Future<void> renameFolder({
    required String folderId,
    required String name,
  }) async {
    final apiId = 'Browse.Folder';
    await api.call(
      _name(apiId),
      'rename',
      preferredVersion: _version(apiId, const [1]),
      params: {'id': folderId, 'name': name},
    );
  }

  /// 删除文件夹（`Browse.Folder/delete`，**v1**，理由同 `createFolder`）。
  ///
  /// ⚠️ 与删相册同一个坑：**`id` 必须是数字数组的 JSON 串**。官方 Web 前端传的
  /// 就是数组（`FolderAPI.delete({id: folderitemArray})`），裸 id 会静默无效。
  /// 官方语义是**移入回收站**（`confirm_delete_item` 文案），不是永久删除。
  Future<void> deleteFolders(List<String> folderIds) async {
    if (folderIds.isEmpty) return;
    final ids = _intIds(folderIds);
    // id 全不是数字（理论上不会发生）→ 别发一个必然静默无效的请求
    if (ids.isEmpty) return;
    final apiId = 'Browse.Folder';
    await api.call(
      _name(apiId),
      'delete',
      preferredVersion: _version(apiId, const [1]),
      params: {'id': js(ids)},
    );
  }

  /// 删除一批照片 / 视频（`Browse.Item/delete`，**v7**）。
  ///
  /// ### 证据（三处一致，逐条给原文）
  /// 1. **服务端方法表**（SPK SynologyPhotos 1.9.1-10928，`usr/webapi/SYNO.Foto.lib`）：
  ///    `SYNO.Foto.Browse.Item` 的 `delete` 在 **v1..v7 每个版本都有**
  ///    （`analyze_package.py apis` 的 `--method delete` 输出）。
  /// 2. **官方 Android 2.4.0-644（E1，jadx 1.5.3）**：
  ///    `ApiBrowseItem.API_VERSION = 7`；内部 `DeleteParameters{api, method:"delete",
  ///    version, id:List of Long}` 由 `generateDeleteParameters` 构造，**item 的 id
  ///    直接进 `id`**（文件夹另走 `ApiBrowseFolder/delete`，两者不混）。
  /// 3. **官方 Web 能力表**（同 SPK `ui/react_bundle.js` 模块 5137）：
  ///    `Item:{… delete:7 …}`；删除 saga 传 `{item_id, folder_id}`。
  ///
  /// ### 参数形态：用 `id`（官方 Android）而不是 `item_id`（官方 Web）
  /// 本仓库是**移动端**实现，与官方 Android 同族：`Browse.Item` 的其它方法
  /// （`get`/`list`/`add_tag`/`set_favorite`）本仓库已全部用 `id`，服务端真机也
  /// 一直认 `id`（`foto_api.dart` 的既有真机注释）。**不混用两种键名**。
  ///
  /// ### 语义：**进回收站**，不是永久删除
  /// 服务端删除走 `synophoto::lib_delete::RecycleDelete`（`libsynofoto-delete.so`
  /// 导出符号），是否真的能还原取决于 **DSM 共享文件夹的"启用回收站"** ——
  /// 官方 App 的原文就是 `str_setting_deletion_desc = "Deleted items can be
  /// restored from the Recycle Bin if enabled in DSM Control Panel > Shared Folder."`。
  /// **官方 Foto 侧没有任何"回收站浏览/还原/彻底删除"API**（`SYNO.Foto.lib` 73 个
  /// API 里零命中 `trash/recycle/restore`；`libsynofoto-delete.so` 只有
  /// RecycleDelete/RecycleDeleteFolder，没有还原符号）→ 本仓库**不伪造回收站视图**，
  /// 只把这句话如实告诉用户（见 `photoDeleteHint`）。
  ///
  /// 返回服务端 `error_list` 里的失败项 id（空 = 全成功）。**部分失败不抛**，
  /// 交给界面显示"成功 N / 失败 M"；只有会话过期这类才冒出去。
  Future<List<String>> deleteItems(List<String> itemIds) async {
    final ids = _intIds(itemIds);
    if (ids.isEmpty) return const [];
    const apiId = 'Browse.Item';
    final version = _version(apiId, kFotoItemDeleteVersions);
    try {
      final data = await api.call(
        _name(apiId),
        'delete',
        preferredVersion: version,
        params: {'id': js(ids)},
      );
      final errors = data['error_list'];
      if (errors is List) {
        return [for (final e in errors) '${(e as Map?)?['id'] ?? e}'];
      }
      return const [];
    } on DsmApiException catch (err) {
      if (_isSessionError(err.code)) rethrow;
      // 整批失败 → 这一批全算失败（不静默）
      return [for (final id in ids) '$id'];
    }
  }

  // --------------------------------------------------------------- 移动 / 复制

  /// `Browse.Item/move|copy` 的冲突动作（官方 `PreferenceManager.CopyMoveAction`：
  /// `SKIP("skip")` / `OVERWRITE("overwrite")`）。
  ///
  /// 官方 `ConnectionManager.copyMovePhotos` 把 `getCopyMoveDefaultAction()` 的结果
  /// 原样塞进 `action` 字段 —— 目标目录里已有同名文件时服务端按它处理。
  ///
  /// ⚠️ **未真机验证**：这是 APK 反编译的枚举值，本批没有在真机上跑过写操作。
  /// 默认取 `skip`（改名保留两者更安全；`overwrite` 会覆盖目标同名文件）。
  Future<List<String>> moveItems({
    required List<String> itemIds,
    required String targetFolderId,
    FotoCopyMoveAction action = FotoCopyMoveAction.skip,
  }) => _copyMoveItems(
    method: 'move',
    itemIds: itemIds,
    targetFolderId: targetFolderId,
    action: action,
  );

  /// 复制一批照片 / 视频到目标目录（`Browse.Item/copy`，**v7**）。
  ///
  /// 形态与证据见 [moveItems]。
  Future<List<String>> copyItems({
    required List<String> itemIds,
    required String targetFolderId,
    FotoCopyMoveAction action = FotoCopyMoveAction.skip,
  }) => _copyMoveItems(
    method: 'copy',
    itemIds: itemIds,
    targetFolderId: targetFolderId,
    action: action,
  );

  /// `Browse.Item/move|copy` 的公共实现。
  ///
  /// ### 证据（官方 APK 2.4.0-644，jadx）
  /// `datasource/network/api/ApiBrowseItem.java`：
  /// ```
  /// Object copyMove(@Path("path") String str,
  ///                 @Field("api") String api, @Field("method") String method,
  ///                 @Field("version") int i,
  ///                 @Field("id") String id,          // gson.toJson(List<Long>)
  ///                 @Field("target_folder_id") long j,
  ///                 @Field("action") String str2,     // CopyMoveAction.getValue()
  ///                 Continuation<...>);
  /// ```
  /// 其中 `KEY_TARGET_ID = "target_folder_id"`（`:KEY_TARGET_ID`）、
  /// `METHOD_MOVE = "move"` / `METHOD_COPY = "copy"`；`ConnectionManager.copyMovePhotos`
  /// 传入 `List<Long>` 与 `targetId`。
  ///
  /// ### 重要：目标是**目录**，不是相册
  /// 官方这条写操作的目标字段就是 `target_folder_id`（`Browse.Item` 的目录树），
  /// 语义是"把照片移到/复制到某个照片文件夹"。**相册成员关系**走的是另一条：
  /// `Browse.NormalAlbum/add_item`（本仓库已实现为「加入相册」）。所以界面文案
  /// 是「移到文件夹 / 复制到文件夹」，文档里同时登记这条与 P32 的措辞差异。
  ///
  /// `id` 是**数字数组的 JSON 串**（与 `delete` 同一形态，真机已验字符串数组会
  /// 回 `120`）；`target_folder_id` 是**裸数字**（官方 `long`）。回包的 `error_list`
  /// 若存在按既有的逐条失败模型解析，否则整批失败算全失败。
  Future<List<String>> _copyMoveItems({
    required String method,
    required List<String> itemIds,
    required String targetFolderId,
    required FotoCopyMoveAction action,
  }) async {
    final ids = _intIds(itemIds);
    if (ids.isEmpty) return const [];
    final target = int.tryParse(targetFolderId);
    if (target == null) {
      // 目录 id 不是数字 → 必然 `120`，直接按"全部失败"如实回报
      return [for (final id in ids) '$id'];
    }
    const apiId = 'Browse.Item';
    try {
      final data = await api.call(
        _name(apiId),
        method,
        preferredVersion: _version(apiId, const [7, 6, 5, 4, 3, 2, 1]),
        params: {
          'id': js(ids),
          'target_folder_id': '$target',
          'action': action.value,
        },
      );
      final errors = data['error_list'];
      if (errors is List) {
        return [for (final e in errors) '${(e as Map?)?['id'] ?? e}'];
      }
      return const [];
    } on DsmApiException catch (err) {
      if (_isSessionError(err.code)) rethrow;
      return [for (final id in ids) '$id'];
    }
  }

  // --------------------------------------------------------------- 地址
  /// 缩略图 URL —— **逐字照抄**官方 `ConnectionManager` 的拼接：
  /// `…&method=get&id=<id>&type="item"&size="sm"&cache_key="<key>"`
  /// （`type`/`size`/`cache_key` 过 Gson，`id` 裸着）。
  ///
  /// [type] 默认 `item`（照片/视频）。人物 / 场景的封面另有取值：官方前端
  /// （SPK `ui/react_bundle.js` 的缩略图工具）的枚举是
  /// `album/folder/general_tag/geocoding/item/person/unit/concept/face`；
  /// 缩略对象带 `unit_id` 时用 `unit`（`id` 传 `unit_id`），否则用
  /// `person` / `concept`（`id` 传实体 id）。
  String thumbnailUrl({
    required String itemId,
    required String cacheKey,
    String size = 'sm',
    String type = 'item',
  }) => api.authenticatedUrl(api.apiPath(_name('Thumbnail')), {
    'api': _name('Thumbnail'),
    'version': '${_version('Thumbnail', const [2, 1])}',
    'method': 'get',
    'id': itemId,
    'type': js(type),
    'size': js(size),
    // ⚠️ `type=unit`（**文件夹封面**走这条）时 `cache_key` 常常是空的
    //    （`Browse.Folder:list additional=["thumbnail"]` 的候选里没有它）——
    //    空串不发，别塞一个 `cache_key=""` 给服务端。
    if (cacheKey.isNotEmpty) 'cache_key': js(cacheKey),
  });

  /// ★ **文件夹封面**（`Browse.Folder:list|get additional=["thumbnail"]` 的候选）
  /// 走 [thumbnailUrl] 的 `type: 'unit'` 形态 —— 真机取证
  /// （`docs/thumbnail-apis.md` §1.8/§2③）：旧形态 `type=folder` +
  /// `folder_cover_seq` **在本机不可用**（v1 回 `120 {"name":"type","reason":"condition"}`、
  /// v2 回 **HTTP 502**）；正确路线是拿候选数组里某个就绪候选的 `unit_id`，
  /// 走 `type=unit` + `id=<unit_id>`（实测 200 `image/jpeg`）。
  /// 候选**不能盲取第一项**（本机第一项恰好是一条坏视频 `sm:"ame_defect"`，盲取 404）
  /// ⇒ 用 [pickFolderCover] 挑；界面侧见 `photo_browse_page.dart` 的 `_FolderRow`。
  /// 从 `Browse.Folder:list|get` 的封面备选里挑**第一个就绪**的。
  ///
  /// 判据是 [FotoThumbDto.hasAny]（`sm`/`m`/`xl` 任一 `ready`）—— 状态串
  /// （`ame_defect`/`broken`/`not_ready`）表示"图坏了"，不是"有图"。
  /// 一个就绪的都没有 → `null`（调用方画占位，不发请求）。
  static FotoThumbDto? pickFolderCover(List<FotoThumbDto> candidates) {
    for (final c in candidates) {
      if (c.unitId.isNotEmpty && c.hasAny) return c;
    }
    return null;
  }

  /// 原图 / 原视频 URL：`Download&method=download&item_id=[…]` / `unit_id=[…]`
  ///
  /// **id 必须是裸数字的 JSON 数组**（真机：字符串数组 → `120 type`；
  /// 用 `id` → `117`）。
  ///
  /// ### `item_id` vs `unit_id`：按 id 的**种类**，不是按喜好（官方 `u9` 逐字）
  /// 官方前端唯一的 `Download` 构造函数（`ui/react_bundle.js` 偏移 **2544763**）：
  /// ```js
  /// var u9=function(e){var t=e.id,n=e.type,r=void 0===n?b.Zk.Unit:n,… p={};
  ///   i&&(p.cache_key=i),
  ///   r===b.Zk.Item?p.item_id=[t]:r===b.Zk.Unit&&(p.unit_id=[t]);
  ///   … return (0,n1.n_)("Download","download",p,h)}
  /// ```
  /// 即：`Item` 种类 → **`item_id=[id]`**；`Unit` 种类 → **`unit_id=[id]`**。
  /// `Browse.Item/list` / `Browse.Item/get` 给我们的是 **item id**，官方从这条
  /// 上下文取原文件走的就是 `item_id=[…]`（同文件偏移 2626646 的 `w`：`"raw"===n`
  /// 时 `u9({id,type})`）。
  ///
  /// ⚠️ 真机对照：`unit_id=[9317]`（缩略图对象的 `unit_id`）实测正好等于 filesize；
  /// 把 **item id** 塞进 `unit_id`（本仓库旧形态）官方证据不支持 —— 本次改为按种类
  /// 选参数名，见 docs/media-streaming-diagnosis.md §1.2/§5。
  ///
  /// ### Range：**真机已证**（2026-09-22，`docs/live-nas-verification.md` §4.3）
  /// `Range: bytes=0-1023` → **HTTP `206` + `Content-Range: bytes 0-1023/1876693`**；
  /// `1000-1999` / `0-0` / `-500`（后缀）全 `206`，越界 `1876693-` → **`416` +
  /// `bytes */1876693`**；无 Range 时带 `Accept-Ranges: bytes`（`video/mp4`）。
  /// 4 种形态 + 416 全部符合 RFC 7233 ⇒ **`Download` 通道 `supportsRange = true`
  /// 有据**（这是 `resolvePhotosSource` 里 Download 腿的来源，见
  /// `lib/src/features/media/media_source.dart`）。
  ///
  /// ⚠️ 该证据**只覆盖 Download**；`Streaming` 未取到任何字节，见
  /// [kFotoStreamingRangeProven]。
  ///
  /// 必须**恰好给一个** [itemId] / [unitId]，两者都给或都不给都是接线 bug（断言）。
  String downloadUrl({String? itemId, String? unitId}) {
    assert(
      (itemId != null && itemId.isNotEmpty) !=
          (unitId != null && unitId.isNotEmpty),
      'downloadUrl 必须且只能给 itemId（Item 种类）或 unitId（Unit 种类）之一',
    );
    final useItem = itemId != null && itemId.isNotEmpty;
    // 播放设置（P48）：HTTP / 端口覆盖只作用于**取流**两条腿（Download / Streaming）
    return _playbackUrl(
      api.authenticatedUrl(api.apiPath(_name('Download')), {
        'api': _name('Download'),
        'version': '${_version('Download', const [2, 1])}',
        'method': 'download',
        if (useItem) 'item_id': '[$itemId]' else 'unit_id': '[$unitId]',
      }),
    );
  }

  /// 批量下载 URL（`Download/download` + **数组** `item_id` / `folder_id`）。
  ///
  /// 证据（官方 Web 前端 `ui/react_bundle.js` 的 `iD`，本批逐字取证）：
  /// ```js
  /// function iD(e,t,n,r,i){ … var l={force_download:!0};
  ///   e.length>0&&(l.item_id=e), t.length>0&&(l.folder_id=t),
  ///   o?l.album_id=o:a&&(l.passphrase=a), l.download_type=i;
  ///   var u=(0,iT.Yl)("Download","download",l,r,s); iC(u.url,u.params) }
  /// ```
  /// 服务端多文件时走 `DownloadAbilityAPIImpl::HandleDownloadZip`（`libwebapi-common-download.so`
  /// 里有 `/usr/bin/zip` 与 `.zip` 字面量）→ 回一个 zip。
  ///
  /// ⚠️ **未在真机取证**：单张 `item_id=[…]` 的 206 已证（`live-nas-verification.md` §4.3），
  /// 但"多张 → zip"没跑过真机 → 待 R8 复验（判据见
  /// `docs/photo-p0-implementation.md`）。`download_type` 的取值没有原文，
  /// 所以**不发**这个参数（只发有原文的 `force_download` + 数组 id）。
  String downloadManyUrl({
    List<String> itemIds = const [],
    List<String> folderIds = const [],
    String? albumId,
  }) {
    assert(
      itemIds.isNotEmpty || folderIds.isNotEmpty,
      '批量下载至少要给 itemIds 或 folderIds 之一',
    );
    return _playbackUrl(
      api.authenticatedUrl(api.apiPath(_name('Download')), {
        'api': _name('Download'),
        'version': '${_version('Download', const [2, 1])}',
        'method': 'download',
        // 官方每次批量下载都带；服务端据此回 zip 而不是单文件
        'force_download': 'true',
        if (itemIds.isNotEmpty) 'item_id': js(_intIds(itemIds)),
        if (folderIds.isNotEmpty) 'folder_id': js(_intIds(folderIds)),
        if (albumId != null && albumId.isNotEmpty) 'album_id': albumId,
      }),
    );
  }

  /// 视频流播（`Streaming` v1-2，官方 `ApiStreaming`）。
  ///
  /// ⚠️ 方法名是 **`streaming`**，不是 `stream`。三处权威证据一致：
  ///   1. `SYNO.Foto.lib` 的 `methods`（`SYNO.Foto.Streaming` 下只有 `streaming`）；
  ///   2. 官方 Photos 前端 `react_bundle.js` 的能力表 `Streaming:{streaming:2}`；
  ///   3. `SYNO.Foto.Streaming.so` 的 rodata（`streaming` + `quality`/`use_mov`…）。
  ///
  /// ### 逐字请求形态（官方前端 `react_bundle.js` 的 `U`，本批重新取证）
  /// ```js
  /// function U(e){ var t=e.id, n=e.type, r=e.quality, o=e.albumId, i=e.passphrase, a=e.library,
  ///     s={id:t, type:n, quality:r};
  ///   if(o) s.album_id=o; else if(i) s.passphrase=i;
  ///   (isSafari()||isiOS()) && (s.use_mov=!0);
  ///   return k("Streaming","streaming",s,a) }   // → webapi/entry.cgi?…
  /// ```
  /// 即 `entry.cgi?api=SYNO.Foto.Streaming&version=2&method=streaming&id={id}&type={type}`
  /// （+ 可选 `quality` / `album_id` / `passphrase`）再拼 `&_sid={sid}&SynoToken={token}`。
  ///   * `version` = 协商后的 v1–v2（本机 [设备表] `minVersion:1 maxVersion:2`）；
  ///   * `id` = **item id**（官方 `id` 直传，不是 `unit_id=[…]`，那是 `Download` 的形态）；
  ///   * **`type` 必须带** —— 官方前端每次都带（视频播放组件的 `defaultProps.type`
  ///     就是 `"item"`），服务端 `.so` 的 rodata 白名单是 `["item","unit"]`
  ///     （`IsBelong`），且 `type` 与错误原因串 `required` 相邻；
  ///   * `use_mov` **只有** Safari/iOS 分支才带（服务端按 UA 出 MOV 容器）
  ///     → 我们（Media3 / Android）**绝不能带**；
  ///   * `_sid` + `SynoToken` 全部在**查询串**里（`DsmWebApi.authenticatedUrl` →
  ///     传输层的 `_urlWith`），播放器只吃 URL、不需要任何自定义头。
  ///
  /// ### `quality` 是什么（决定本方法能不能取到"原文件"）
  /// 服务端的 `SYNO.Foto.Streaming` **只从 `video_convert` 转换表里按 `quality`
  /// 取一个转码产物**（`etc/sql/1.sql` 的 `video_convert(quality, id_unit, …)`；
  /// rodata 白名单 `["flv","high","medium","low","mobile","orig_iphone",
  /// "orig_android","orig_h264","orig_mp4","convert_mp4","motion_photo"]`；
  /// `libsynofoto-control-video.so` 的 `kQuality*→SYNOPHOTO_FILM_*` 映射）。
  /// **没有 `quality` 表示原文件**这一档 —— 官方对"原文件本来就能直接播"的视频
  /// （mp4 + h264）根本不走 `Streaming`，而是走 `Download`（`react_bundle.js`：
  /// `QT()` 回 `"raw"` → `u9({id,type:"item"})` → `SYNO.Foto.Download / download`）。
  /// 所以调用方**不要猜** `quality`；要原文件请走 [downloadUrl]，要转码产物必须
  /// 先知道该 unit 的 `video_convert` 里有哪一档。详见
  /// docs/media-streaming-diagnosis.md。
  ///
  /// ### ⚠️ 真机可用性：**未取证 / 很可能不可用**（2026-09-22）
  /// `docs/live-nas-verification.md` §4.4 实测：**不带 `quality`** 时服务端直接
  /// `120 {"name":"quality","reason":"required"}` —— 官方前端每次都给 `quality`
  /// （`react_bundle.js` 的 `U`），且 `raw` 档**根本不走 Streaming**
  /// （`"raw"===n` → `u9` → Download）。即本方法当前形态在真机上**拿不到流**。
  /// 这是**通道未取证**，不是"服务端没这个功能"、更不是"文件坏了" ——
  /// 失败文案必须照此区分（见 `MediaUnavailableReason.streamRejected`）。
  ///
  /// ### Accept-Ranges / Range（如实标注，不猜）
  /// 这个方法**不发送也不承诺** `Accept-Ranges`：那是**响应头**，只有服务端能决定。
  /// 离线取证结论（`docs/native-media-playback-research.md` §3.3 + §7 第 1 条）：
  /// SynologyPhotos 包里**零** `Accept-Ranges` / `Content-Range` / `HTTP_RANGE`
  /// 字面量 → **Range 未证实**。
  ///
  /// ⚠️ 2026-09-22 真机复核（`docs/live-nas-verification.md` §4.4）**仍未证**：
  /// `streaming` 必填 `quality`，14 个候选值全被拒（`120 reason:"condition"`；
  /// `high/low/medium` 另撞 404 HTML）→ **没取到任何字节**。**既未证真也未证伪**。
  /// 因此本通道恒按 `kFotoStreamingRangeProven = false` 处理（进度条置灰），
  /// 真机拿到 `206` 之前不许写 true
  /// （见 `lib/src/features/media/media_source.dart` 的 `resolvePhotosSource`）。
  String streamingUrl({
    required String itemId,
    String type = kFotoStreamingTypeItem,
    String? quality,
  }) => _playbackUrl(
    api.authenticatedUrl(api.apiPath(_name('Streaming')), {
      'api': _name('Streaming'),
      'version': '${_version('Streaming', const [2, 1])}',
      'method': 'streaming',
      'id': itemId,
      // 官方前端**每次**都带 `type`；漏了它服务端按 `required` 拒绝（取流层失败，
      // Media3 只会报 `Source error`，看起来像"文件坏了"）。
      'type': type,
      if (quality != null && quality.isNotEmpty) 'quality': quality,
    }),
  );

  /// 取一段视频的**播放素材**（`Browse.Item/get` + `additional:[video_convert,
  /// video_meta]`）—— 用来决定"原文件（Download）还是哪一档转码（Streaming）"。
  ///
  /// 证据：官方 Android `VideoInfoHelper.getVideoPlayInfo` 就是先 `Browse.Item/get`
  /// 拿 `unitInfo.additional.video_convert` / `video_meta`，再走
  /// `getVideoPlayInfo(isRemote, unitItem, …)` 选档（jadx 1.5.3）。
  /// 官方 Web 的 `additional` 白名单（`react_bundle.js` 的 `IMAGE_ITEM_INFO_ADDITIONAL`）
  /// 里同样有 `video_convert` / `video_meta` / `video_convert_status` 三项。
  ///
  /// ⚠️ 取不到（响应没有 `video_convert`）时返回空 [FotoVideoInfoDto]，
  /// 调用方按 [chooseFotoVideoPlayback] 的规则会自动回落到 **Download 原文件** ——
  /// 这正是官方"没转码档 → composeOriginalVideoPlayInfo"的分支。
  Future<FotoVideoInfoDto> videoPlaybackInfo(String itemId) async {
    final id = int.tryParse(itemId);
    if (id == null) return const FotoVideoInfoDto();
    final apiId = 'Browse.Item';
    final data = await api.call(
      _name(apiId),
      'get',
      preferredVersion: _version(apiId, kFotoVideoInfoVersions),
      params: {
        'id': js([id]),
        'additional': js(const [
          'video_convert',
          'video_meta',
          'video_convert_status',
        ]),
      },
    );
    final list = data['list'];
    if (list is List && list.isNotEmpty && list.first is Map) {
      return FotoVideoInfoDto.fromJson(
        (list.first as Map).cast<String, dynamic>(),
      );
    }
    return FotoVideoInfoDto.fromJson(data);
  }

  // --------------------------------------------------------------- 写

  /// `id` 数组服务端要的是**数字**（真机：字符串数组一律 `120`）。
  /// 非数字 id（文件夹封面那类）直接丢掉，避免给一个必然报错的请求。
  static List<int> _intIds(Iterable<String> ids) => [
    for (final id in ids)
      if (int.tryParse(id) != null) int.parse(id),
  ];

  /// 新建普通相册（`Browse.NormalAlbum/create` v4）。
  ///
  /// 真机钉死的形态（`tool/photo_album_write*_probe.dart`）：
  ///   * 参数：`{name, item?}`，`item` 是**数字**数组的 JSON 串；
  ///   * 回包：`{album:{id,name,item_count,…}, error_list:[]}`；
  ///   * 版本：**v4**（v1–v3 回 `120`）。
  Future<FotoAlbumDto> createAlbum({
    required String name,
    List<String> itemIds = const [],
  }) async {
    final data = await api.call(
      _name('Browse.NormalAlbum'),
      'create',
      preferredVersion: _version('Browse.NormalAlbum', const [4, 3, 2, 1]),
      params: {
        'name': name,
        if (itemIds.isNotEmpty) 'item': js(_intIds(itemIds)),
      },
    );
    final album = (data['album'] as Map?)?.cast<String, dynamic>();
    if (album == null) return FotoAlbumDto(id: '', name: name);
    return FotoAlbumDto.fromJson(album);
  }

  /// 往相册里加照片（`Browse.NormalAlbum/add_item` v4）。
  ///
  /// `id` 是**裸相册 id**、`item` 是**数字数组的 JSON 串**（真机：两个都写成
  /// 数组串 → `120`）。回包的 `error_list` 是"没加进去的那些"（比如照片已被
  /// 别的相册占用/不存在），不为空不算失败，交给调用方提示。
  Future<List<String>> addItemsToAlbum({
    required String albumId,
    required List<String> itemIds,
  }) async {
    if (itemIds.isEmpty) return const [];
    final data = await api.call(
      _name('Browse.NormalAlbum'),
      'add_item',
      preferredVersion: _version('Browse.NormalAlbum', const [4, 3, 2, 1]),
      params: {'id': albumId, 'item': js(_intIds(itemIds))},
    );
    final errors = data['error_list'];
    return [
      if (errors is List)
        for (final e in errors) '${(e as Map?)?['id'] ?? e}',
    ];
  }

  /// 从相册里移除照片（`Browse.NormalAlbum/delete_item` v4）。
  /// **只移出相册，照片本身还在**（和删照片是两件事）。
  Future<void> removeItemsFromAlbum({
    required String albumId,
    required List<String> itemIds,
  }) async {
    final ids = _intIds(itemIds);
    if (ids.isEmpty) return;
    await api.call(
      _name('Browse.NormalAlbum'),
      'delete_item',
      preferredVersion: _version('Browse.NormalAlbum', const [4, 3, 2, 1]),
      params: {'id': albumId, 'item': js(ids)},
    );
  }

  /// 换相册封面（`Browse.Album/set_cover` v5）。
  ///
  /// ⚠️ 真机：照片**必须已经在相册里**，否则回 `804`；`id` 和 `id_item` 都是
  /// **裸值**（写成数组串 → `120`）。
  Future<void> setAlbumCover({
    required String albumId,
    required String itemId,
  }) async {
    await api.call(
      _name('Browse.Album'),
      'set_cover',
      preferredVersion: _version('Browse.Album', const [5, 4, 3, 2, 1]),
      params: {'id': albumId, 'id_item': itemId},
    );
  }

  /// 相册改名（`Browse.Album/set_name` v5，`id` 裸值 + `name`）。
  Future<void> renameAlbum({
    required String albumId,
    required String name,
  }) async {
    await api.call(
      _name('Browse.Album'),
      'set_name',
      preferredVersion: _version('Browse.Album', const [5, 4, 3, 2, 1]),
      params: {'id': albumId, 'name': name},
    );
  }

  /// 删除相册（`Browse.Album/delete` v5）。
  ///
  /// ⚠️ **必须传数组**（`id` 的 JSON 数字数组串）。真机上写成裸 id / 裸数字
  /// 一律回 `{}` 却什么也不做 —— 静默无效，比报错更坑（探针第 3 轮查出来的）。
  Future<void> deleteAlbums(List<String> albumIds) async {
    if (albumIds.isEmpty) return;
    await api.call(
      _name('Browse.Album'),
      'delete',
      preferredVersion: _version('Browse.Album', const [5, 4, 3, 2, 1]),
      params: {'id': js(_intIds(albumIds))},
    );
  }

  /// 收藏 / 取消收藏（`Browse.Item/set_favorite`，官方 `ApiBrowseItem`）。
  Future<void> setFavorite(List<String> itemIds, bool favorite) async {
    final apiId = 'Browse.Item';
    await api.call(
      _name(apiId),
      'set_favorite',
      preferredVersion: _version(apiId, const [7, 6, 5, 4, 3, 2, 1]),
      params: {
        'id': js(_intIds(itemIds)),
        'favorite': favorite ? 'true' : 'false',
      },
    );
  }

  /// 旋转一张 / 多张照片（`Browse.Item/set` **v7** + `rotate_action`）。
  ///
  /// 证据（官方 APK 2.4.0-644，jadx）：
  ///   * `ApiBrowseItem.java:139` 请求签名
  ///     `set(path, api, "set", version, @Field("id") String, @FieldMap Map<String,String>)`
  ///     —— `id` 是 **JSON 数字数组串**（`:542` `gson.toJson(idList)`）；
  ///   * `:1204` `map.put(KEY_ROTATE_ACTION, gson.toJson(str2))` —— `rotate_action`
  ///     的值也是 **JSON 串**（带引号），所以这里用 [js]；
  ///   * 服务端 `.so` 的 `Browse.Item` rodata 有 `rotate_action`。
  ///
  /// ⚠️ 这里**就是官方编辑器在 NAS 侧的全部能力**：旋转（顺时针 / 180 / 逆时针）。
  /// 官方 Android 客户端没有裁剪 / 滤镜 / 亮度对比度调整（全库 grep 零命中）——
  /// 所以本仓库**不臆造**这些能力。本地拍摄的照片走 EXIF 原地改写（`CanEdit` +
  /// `isSupportMediaUriOp`），那是设备侧行为，本仓库不覆盖。
  ///
  /// 多张一起转时服务端按 `rotate_action` 统一作用（与 `set_favorite` 同形）。
  Future<void> setItemRotation({
    required List<String> itemIds,
    required FotoRotateAction action,
  }) async {
    final ids = _intIds(itemIds);
    if (ids.isEmpty) return;
    final apiId = 'Browse.Item';
    await api.call(
      _name(apiId),
      'set',
      preferredVersion: _version(apiId, kFotoItemSetVersions),
      params: {'id': js(ids), 'rotate_action': js(action.value)},
    );
  }

  /// 修改一张 / 多张照片的**拍摄时间**（`Browse.Item/set` + `time`）。P36
  ///
  /// ⚠️ **这是写操作**：本仓只在用户于确认弹窗里点过"保存"之后才调用它；
  /// 离线用例一律用 `FakeTransport` 断言请求形状，**绝不真调**（见报告 §5.1）。
  ///
  /// ### 逐字证据（官方 APK 2.4.0-644，jadx 1.5.3；本批重新取证）
  ///   * 参数名 `time`：`ApiBrowseItem.java:77` `KEY_TIME = "time"`；
  ///   * 官方**只用 `time`、从不调 `shift_time`**（这点很容易搞反）：
  ///     `ApiBrowseItem.java:489-491`
  ///     ```java
  ///     public final Object getSetPhotoTimeResponse(ConnectionManager cm, List<Long> list,
  ///                                                 long j, boolean z, Continuation<...> c) {
  ///         return getSetResponse(cm, list,
  ///             new SetParamBuilder(null,null,null,null,null, 31, null).time(j).build(), z, c);
  ///     }
  ///     ```
  ///     全树 grep：`shiftTime` / `KEY_SHIFT_TIME` **只在 `ApiBrowseItem` 里被声明与实现，
  ///     没有任何调用方**（`build()` 里 `:1196-1199` 的那条分支是死代码）。
  ///     所以本仓照官方走**绝对时间**，不臆造"相对偏移"语义。
  ///   * 值形态是**裸整数字符串**，不是 JSON 串：
  ///     `ApiBrowseItem.java:1192-1195`
  ///     ```java
  ///     Long l = this.time;
  ///     if (l != null) { map.put(ApiBrowseItem.KEY_TIME, String.valueOf(l.longValue())); }
  ///     ```
  ///     对比 `:1206` 的 `rotate_action` 走 `gson.toJson(...)`（带引号）——
  ///     两者形态**不同**，所以这里 `time` 用 `'${epochSeconds}'`、`id` 仍用 [js]。
  ///   * 单位是 **epoch 秒**：官方 `EditDateViewModel` 的
  ///     `getEditedTime()` = 选中的日期 + `hour*3600 + minute*60`，直接喂给
  ///     `time`；服务端 `Browse.Item/list` 回的 `time` 也是同一口径的秒。
  ///   * 版本：`min(服务端 maxVersion, 7)`（`ConnectionManager.java:1862-1865`
  ///     × `ApiBrowseItem.API_VERSION = 7`）→ 走 [kFotoItemSetVersions] 协商。
  ///
  /// `time` **没有**能力位版本门槛（官方 `filterByApiVersion` 只裁 `additional`），
  /// 所以这里不对 [time] 做额外 gate —— 照 `set` 的既有版本区间走。
  Future<void> setItemTime({
    required List<String> itemIds,
    required DateTime time,
  }) async {
    final ids = _intIds(itemIds);
    if (ids.isEmpty) return;
    final apiId = 'Browse.Item';
    await api.call(
      _name(apiId),
      'set',
      preferredVersion: _version(apiId, kFotoItemSetVersions),
      params: {'id': js(ids), 'time': '${time.millisecondsSinceEpoch ~/ 1000}'},
    );
  }

  /// 给一张 / 多张照片设星级（`Browse.Item/set` + `rating`，**v2+**）。
  ///
  /// ### 逐字证据（官方 APK 2.4.0-644，jadx 1.5.3）
  ///   * `ApiBrowseItem.java:97` `SUPPORT_RATING_VERSION = 2`
  ///     （能力位：`ConnectionManager.java:1814`
  ///      `new ApiCapabilities(apiMaxVersionWithName >= 2, …)` 的第一项就是
  ///      `isSupportRating`）→ 版本候选交给 [negotiate] 收敛，**不硬编码**；
  ///   * `:478-479` `getSetPhotoRatingResponse(list, i, …)` →
  ///     `new SetParamBuilder(…).rating(i).build()`；
  ///   * `:1208-1210` `map.put("rating", String.valueOf(num.intValue()))`
  ///     —— 值是**十进制字符串、不套 JSON 引号**（和 `rotate_action` 的
  ///     `gson.toJson` 不同，这里照抄官方）；
  ///   * `:542` id 仍是 **JSON 数字数组串**。
  ///
  /// `rating = 0` 就是**清除评分**（官方 `rating_bar` 允许回到"未评分"）。
  ///
  /// ### 门控
  /// 服务端 `Browse.Item` maxVersion < [kFotoRatingSupportVersion]（老 Photos）
  /// 时直接抛 [FotoRatingUnsupportedException]，**不发请求**；界面在
  /// [supportsRating] 为 false 时也不该给入口。
  ///
  /// ⚠️ 本批次**只写代码与离线用例，绝不真调**（§5.1：不调变更动词方法）。
  Future<void> setItemRating(List<String> itemIds, int rating) async {
    if (!supportsRating) throw const FotoRatingUnsupportedException();
    final ids = _intIds(itemIds);
    if (ids.isEmpty) return;
    final value = rating.clamp(0, kFotoRatingMax);
    final apiId = 'Browse.Item';
    await api.call(
      _name(apiId),
      'set',
      preferredVersion: _version(apiId, kFotoItemSetVersions),
      params: {'id': js(ids), 'rating': '$value'},
    );
  }

  /// 清除星级 = 设 0（官方 `rating_bar` 的"未评分"）。
  Future<void> clearItemRating(List<String> itemIds) =>
      setItemRating(itemIds, 0);

  // --------------------------------------------------------------- 标签

  /// 标签接口的版本 / 分批常量（官方 Web 前端钉死）：
  /// `GeneralTag {count:2,create:2,get:2,list:2,suggest:2}`、
  /// `Item {add_tag:7,remove_tag:7,get_tag:7}`、
  /// `BATCH_UPDATE_GENERAL_TAG_SIZE = 50`。
  static const List<int> _tagVersions = [2, 1];
  static const List<int> _itemTagVersions = [7, 6, 5, 4, 3, 2, 1];

  /// 打完一批照片上的**交集标签 id**（`Browse.Item/get_tag` v7）。
  ///
  /// 响应是 `{intersection:[tagId…]}`（**只回 id**，名字要另走 [generalTags]/[suggestTags]）。
  Future<List<String>> itemTagIds(List<String> itemIds) async {
    final ids = _intIds(itemIds);
    if (ids.isEmpty) return const [];
    final apiId = 'Browse.Item';
    final data = await api.call(
      _name(apiId),
      'get_tag',
      preferredVersion: _version(apiId, _itemTagVersions),
      params: {'id': js(ids)},
    );
    final raw = data['intersection'];
    if (raw is! List) return const [];
    return [for (final e in raw) '$e'];
  }

  /// 全部标签（`Browse.GeneralTag/list` v2）。
  Future<List<FotoTagDto>> generalTags({
    int offset = 0,
    int limit = 200,
  }) async {
    final apiId = 'Browse.GeneralTag';
    final data = await api.call(
      _name(apiId),
      'list',
      preferredVersion: _version(apiId, _tagVersions),
      params: {'offset': '$offset', 'limit': '$limit'},
    );
    return _list(data, FotoTagDto.fromJson);
  }

  /// 标签总数（`Browse.GeneralTag/count` v2）→ `{count}`。
  ///
  /// 官方 Web 前端钉死 `GeneralTag {count:2,create:2,get:2,list:2,suggest:2}`；
  /// 官方用它来卡 `GENERAL_TAG = 500` 的**总数上限**（`k9` 里
  /// `limit: Math.min(n.length + 5, GENERAL_TAG)` 的同一个常量）。
  ///
  /// ⚠️ **count 的参数形态未逐字取证**（bundle 里没抠到调用点）：这里按
  /// `Person|Concept/count` 的对称形态**不带参数**发。真机若回 `120`，
  /// 优先怀疑这里 → 见报告「要我去 NAS 探的 API 清单」。
  Future<int> generalTagCount() async {
    final apiId = 'Browse.GeneralTag';
    final data = await api.call(
      _name(apiId),
      'count',
      preferredVersion: _version(apiId, _tagVersions),
    );
    return fInt(data['count']);
  }

  /// 按 id 取标签详情（`Browse.GeneralTag/get` v2 `{id:[数字…]}` → `{list}`）。
  ///
  /// 官方 Web 前端原文（`ui/react_bundle.js`，`function TX(e)`）：
  /// ```
  /// bS(n.get, {id:e})     // e = idArray（数字数组）
  /// ```
  /// 用来在删照片之后刷新这些标签的计数（`count` 字段）。
  /// `id` 是**数字数组的 JSON 串**（与 `get_tag` 同形），非数字项直接丢掉。
  Future<List<FotoTagDto>> tagDetails(List<String> tagIds) async {
    final ids = _intIds(tagIds);
    if (ids.isEmpty) return const [];
    final apiId = 'Browse.GeneralTag';
    final data = await api.call(
      _name(apiId),
      'get',
      preferredVersion: _version(apiId, _tagVersions),
      params: {'id': js(ids)},
    );
    return _list(data, FotoTagDto.fromJson);
  }

  /// 某个标签名下的照片（`Browse.Item/list_with_filter` **v7** + `general_tag_id`）。
  ///
  /// 证据（官方 Web 前端 `ui/react_bundle.js`）：
  ///   * 过滤键 `general_tag_id` 出现在 `ER(e)` 构造的 filter 里，且
  ///     `EG/EV` 分支明确用它决定"要不要 InitTimelineAPI"
  ///     （`(e.person_id||e.geocoding_id||e.concept_id||e.general_tag_id||e.type)
  ///       && (t.InitTimelineAPI = void 0)`）；
  ///   * 带过滤的时间线走 `ItemAPI = Browse.Item.listWithFilter`（`EV(e)`），
  ///     通用 saga 的入参是 `{offset, limit, additional:[…], ...filter}`；
  ///   * 官方钉死版本表 `Item {list_with_filter:7}`。
  ///
  /// 值是**数字**（`docs/p2-photos-backup-research.md` §4.2：`general_tag_id`
  /// 是数字，不是数组）。分页用既有 v7 `offset`/`limit` 惯例。
  Future<List<FotoItemDto>> tagItems(
    String tagId, {
    int offset = 0,
    int limit = kFotoTagItemsPageSize,
  }) async {
    final id = int.tryParse(tagId);
    if (id == null) return const [];
    final apiId = 'Browse.Item';
    final data = await api.call(
      _name(apiId),
      'list_with_filter',
      preferredVersion: _version(apiId, _itemTagVersions),
      params: {
        'general_tag_id': '$id',
        'offset': '$offset',
        'limit': '$limit',
        'additional': js(itemAdditional()),
      },
    );
    return _items(data);
  }

  /// 新建标签（`Browse.GeneralTag/create` v2）。
  ///
  /// 官方 Web 前端写的是 `{tag:[{id,name}]}`，但**现场 NAS 实测**（DSM 7.x，
  /// nas.example.com）回的是**单个对象** `{"tag":{"id":1,"name":"huihubtag"}}`；
  /// 只认 List 会让「新建标签」静默无效（点了没反应、搜索框不清空）。
  /// 所以三种形态都认。
  Future<FotoTagDto?> createTag(String name) async {
    final apiId = 'Browse.GeneralTag';
    final data = await api.call(
      _name(apiId),
      'create',
      preferredVersion: _version(apiId, _tagVersions),
      params: {'name': name},
    );
    final tag = data['tag'];
    if (tag is Map) {
      return FotoTagDto.fromJson(tag.cast<String, dynamic>());
    }
    if (tag is List && tag.isNotEmpty && tag.first is Map) {
      return FotoTagDto.fromJson((tag.first as Map).cast<String, dynamic>());
    }
    final list = _list(data, FotoTagDto.fromJson);
    return list.isEmpty ? null : list.first;
  }

  /// 标签联想（`Browse.GeneralTag/suggest` v2）→ `{list:[…]}`。
  ///
  /// 官方 Web 前端：`suggest({keyword, limit})`，上限 `GENERAL_TAG = 500`。
  Future<List<FotoTagDto>> suggestTags(String keyword, {int limit = 20}) async {
    final apiId = 'Browse.GeneralTag';
    final data = await api.call(
      _name(apiId),
      'suggest',
      preferredVersion: _version(apiId, _tagVersions),
      params: {'keyword': keyword, 'limit': '$limit'},
    );
    return _list(data, FotoTagDto.fromJson);
  }

  /// 给一批照片**加标签**（`Browse.Item/add_tag` v7）。
  ///
  /// **`id` 与 `tag` 都是数字数组**（官方 Web：`bS(addTag,{id, tag})`），
  /// 天然支持批量；按官方常量 50 一批。返回服务端 `error_list` 里的失败项
  /// id（空 = 全成功）—— 部分失败**不抛**，交给界面提示。
  Future<List<String>> addTags({
    required List<String> itemIds,
    required List<String> tagIds,
  }) => _updateItemsTag('add_tag', itemIds: itemIds, tagIds: tagIds);

  /// 给一批照片**去标签**（`Browse.Item/remove_tag` v7），语义同 [addTags]。
  Future<List<String>> removeTags({
    required List<String> itemIds,
    required List<String> tagIds,
  }) => _updateItemsTag('remove_tag', itemIds: itemIds, tagIds: tagIds);

  Future<List<String>> _updateItemsTag(
    String method, {
    required List<String> itemIds,
    required List<String> tagIds,
  }) async {
    final ids = _intIds(itemIds);
    final tags = _intIds(tagIds);
    if (ids.isEmpty || tags.isEmpty) return const [];
    final apiId = 'Browse.Item';
    final version = _version(apiId, _itemTagVersions);
    final failed = <String>{};
    for (var i = 0; i < ids.length; i += kFotoTagBatchSize) {
      final end = (i + kFotoTagBatchSize).clamp(0, ids.length);
      final batch = ids.sublist(i, end);
      try {
        final data = await api.call(
          _name(apiId),
          method,
          preferredVersion: version,
          params: {'id': js(batch), 'tag': js(tags)},
        );
        final errors = data['error_list'];
        if (errors is List) {
          for (final e in errors) {
            failed.add(e is Map ? '${e['id'] ?? e}' : '$e');
          }
        }
      } on DsmApiException catch (err) {
        // 会话过期这类必须冒出去（重登逻辑在外面）；其它网络/参数错误
        // 只把这一批记为失败，不牵连其他批次。
        if (_isSessionError(err.code)) rethrow;
        failed.addAll([for (final id in batch) '$id']);
      }
    }
    return failed.toList();
  }

  static bool _isSessionError(int code) =>
      code == DsmErrorCode.sessionTimeout ||
      code == DsmErrorCode.sidNotFound ||
      code == DsmErrorCode.sessionInterrupt;

  // --------------------------------------------------------------- 人脸 / 场景

  /// `Browse.Person` 的候选版本：官方 Web 前端把每个方法的版本**钉死**成
  /// `Person {add_face:3, count:1, delete_face:1, get:1, get_migration_status:1,
  ///         list:1, list_face:1, merge:2, separate:1, set:1, set_cover:1,
  ///         show:1, suggest:3}`。
  ///
  /// 本轮只做**读**：`list` / `count` / `get` / `get_migration_status` **全是 v1**，
  /// 所以候选写 `[1]` —— 与文件夹写操作同一个口径：以官方钉死表为准，
  /// 不协商到能力表的 `maxVersion`（那会挑到 v3，反而不可靠）。
  static const List<int> _personVersions = [1];

  /// `merge` 官方 Web 版本表钉的是 **v2**（`Person:{…,merge:2,…}`）。
  static const List<int> _personMergeVersions = [2];

  /// `show` 钉的是 **v1**。
  static const List<int> _personShowVersions = [1];

  /// `Browse.Person/suggest` 的候选版本。
  ///
  /// 官方 Web 前端把它**钉死**成 `suggest:3`（`ui/react_bundle.js` 的
  /// `Person:Object.freeze({…,suggest:3})`）；服务端 `.lib` 的
  /// `SYNO.Foto.Browse.Person` 在 v1/v2/v3 都列了 `suggest`，所以这里保留
  /// 降级链 `[3,2,1]`（老包上仍能拿到建议，不会因为协商不到 v3 就整个功能消失）。
  static const List<int> _personSuggestVersions = [3, 2, 1];

  /// `Browse.Person/list_face` 的候选版本。
  ///
  /// 官方钉死 `list_face:1`（服务端 `.lib` v1/v2/v3 皆有），与既有的
  /// `_personVersions` 同口径：**以官方钉死表为准**。
  static const List<int> _personListFaceVersions = [1];

  /// `Browse.Concept` 的官方钉死表：
  /// `{count:2, get:2, list:2, set_cover:1, hide_item:1, set_visibility:2}`。
  /// 本轮的读方法 `list` / `count` / `get` 都是 **v2**（回落到 v1 兼容老包）。
  static const List<int> _conceptVersions = [2, 1];

  static String _bool(bool v) => v ? 'true' : 'false';

  /// 人物列表（`Browse.Person/list` **v1**）。
  ///
  /// 参数形态逐字来自官方 Web 前端（SPK `ui/react_bundle.js` 的智能相册 saga）：
  ///   * 列表：`bS(PersonAPI.list, {additional:["thumbnail"], ...filter})`，
  ///     filter = `{offset, limit, show_more, show_hidden}`
  ///     （`I=function(e,r){…{offset:e,limit:r,show_more:u,show_hidden:E}…}`）；
  ///   * `count`：`bS(PersonAPI.count, {...filter})`，另外会用
  ///     `{show_more:true, show_hidden:…}` 再算一次"更多 / 隐藏"的数量。
  Future<List<FotoPersonDto>> persons({
    int offset = 0,
    int limit = kFotoSmartAlbumPageSize,
    bool showHidden = false,
    bool showMore = false,
  }) async {
    final apiId = 'Browse.Person';
    final data = await api.call(
      _name(apiId),
      'list',
      preferredVersion: _version(apiId, _personVersions),
      params: {
        'offset': '$offset',
        'limit': '$limit',
        'show_more': _bool(showMore),
        'show_hidden': _bool(showHidden),
        'additional': js(const ['thumbnail']),
      },
    );
    return _list(data, FotoPersonDto.fromJson);
  }

  /// 人物数量（`Browse.Person/count` **v1**）→ `{count}`。
  Future<int> personCount({
    bool showHidden = false,
    bool showMore = false,
  }) async {
    final apiId = 'Browse.Person';
    final data = await api.call(
      _name(apiId),
      'count',
      preferredVersion: _version(apiId, _personVersions),
      params: {'show_more': _bool(showMore), 'show_hidden': _bool(showHidden)},
    );
    return fInt(data['count']);
  }

  /// 按 id 取人物详情（`Browse.Person/get` **v1**）。
  ///
  /// 官方前端：`bS(PersonAPI.get, {id:[n], additional:["thumbnail"]})` → `{list}`。
  /// `id` 是**数字数组**（与其它列表接口一致），非数字项直接丢掉。
  Future<List<FotoPersonDto>> personDetails(List<String> personIds) async {
    final ids = _intIds(personIds);
    if (ids.isEmpty) return const [];
    final apiId = 'Browse.Person';
    final data = await api.call(
      _name(apiId),
      'get',
      preferredVersion: _version(apiId, _personVersions),
      params: {
        'id': js(ids),
        'additional': js(const ['thumbnail']),
      },
    );
    return _list(data, FotoPersonDto.fromJson);
  }

  /// 人物建议分组 / 名字联想（`Browse.Person/suggest`，官方钉死 **v3**）。
  ///
  /// 参数形态逐字来自官方 Web 前端（`ui/react_bundle.js`，人物编辑窗 saga）：
  /// ```
  /// bS(t.suggest, {name_prefix:r, additional:["thumbnail"],
  ///                limit:b.ZP.PERSON_SUGGESTION_LIMIT})   // → {list:[…]}
  /// ```
  /// 其中 `PERSON_SUGGESTION_LIMIT = 10`（官方常量），所以默认 [limit] = 10。
  /// `name_prefix` 是**前缀**（不是任意子串）；空串官方也照发（用来列候选）。
  Future<List<FotoPersonDto>> personSuggest(
    String namePrefix, {
    int limit = kFotoPersonSuggestionLimit,
  }) async {
    final apiId = 'Browse.Person';
    final data = await api.call(
      _name(apiId),
      'suggest',
      preferredVersion: _version(apiId, _personSuggestVersions),
      params: {
        'name_prefix': namePrefix,
        'limit': '$limit',
        'additional': js(const ['thumbnail']),
      },
    );
    return _list(data, FotoPersonDto.fromJson);
  }

  /// 某人物在指定照片上的**人脸裁切**（`Browse.Person/list_face` **v1**）。
  ///
  /// 参数形态逐字来自官方 Web 前端：
  /// ```
  /// bS(n.listFace, {person_id:r, item_id:t})   // t = itemIdList
  /// ```
  /// —— `person_id` 是**裸数字**，`item_id` 是**数字数组**（JSON 串）。
  /// 官方是"把当前可见条目的 id 列表一起发过去，只回这些条目里的人脸"，
  /// 所以 [itemIds] 为空时**不发请求**（避免服务端按"全部条目"扫）。
  ///
  /// 返回**原始人脸对象**（字段未取证，见报告"未取证清单"）：界面只做只读展示，
  /// 不猜测字段语义。会话类错误照旧冒出去。
  Future<List<Map<String, dynamic>>> personFaces(
    String personId, {
    required List<String> itemIds,
  }) async {
    final pid = int.tryParse(personId);
    final ids = _intIds(itemIds);
    if (pid == null || ids.isEmpty) return const [];
    final apiId = 'Browse.Person';
    final data = await api.call(
      _name(apiId),
      'list_face',
      preferredVersion: _version(apiId, _personListFaceVersions),
      params: {'person_id': '$pid', 'item_id': js(ids)},
    );
    return _list(data, (j) => j);
  }

  /// 人脸识别迁移进度（`Browse.Person/get_migration_status` **v1**，**无参**）。
  ///
  /// 官方：`bS(PersonAPI.getMigrationStatus)` → `{status, completion, total}`。
  /// 失败（`103 方法不存在` / 功能未开）**不抛**，回一个空的
  /// [FotoPersonMigrationDto]（界面按"暂时拿不到进度"降级，不白屏）；
  /// 会话类错误照旧冒出去触发重登。
  Future<FotoPersonMigrationDto> personMigrationStatus() async {
    final apiId = 'Browse.Person';
    try {
      final data = await api.call(
        _name(apiId),
        'get_migration_status',
        preferredVersion: _version(apiId, _personVersions),
      );
      return FotoPersonMigrationDto.fromJson(data);
    } on DsmApiException catch (err) {
      if (_isSessionError(err.code)) rethrow;
      return const FotoPersonMigrationDto();
    }
  }

  /// 某个人物名下的照片（`Browse.Item/list` **v7** + `person_id`）。
  ///
  /// 证据（官方 Web 前端）：人物 / 场景的"时间轴"用 `Browse.Timeline.*` **取分组**，
  /// 照片本身仍是 `ItemAPI = Browse.Item.list`；调用形态是
  ///   `bS(ItemAPI, {offset, limit, additional:[…], ...filter})`，
  /// 而 filter 里带 `person_id`（`ER()` 构造）—— 见
  /// `docs/p2-photos-backup-research.md` §3.2 的 `InitTimelineAPI` 分支。
  ///
  /// ⚠️ **未核实**：本机没有 `Browse.Timeline`（见文件头注释），`person_id` 过滤
  /// 在真机上能不能直接过滤 `Browse.Item/list` **还没验**（`Item/list` 的 `id`
  /// 过滤此前已证**不生效**，`person_id` 是另一回事）。真机验收优先验这条。
  Future<List<FotoItemDto>> personItems(
    String personId, {
    int offset = 0,
    int limit = 200,
  }) async {
    final apiId = 'Browse.Item';
    final data = await api.call(
      _name(apiId),
      'list',
      preferredVersion: _version(apiId, const [7, 6, 5, 4, 3, 2, 1]),
      params: {
        'person_id': personId,
        'offset': '$offset',
        'limit': '$limit',
        'additional': js(itemAdditional()),
      },
    );
    return _items(data);
  }

  /// 场景 / 主题列表（`Browse.Concept/list` **v2**）。
  ///
  /// 官方前端：`bS(SmartAPI.list, {additional:["thumbnail"], ...filter})`，
  /// 场景的 filter 只有 `{offset, limit, show_hidden}`（**没有** `show_more`）。
  Future<List<FotoConceptDto>> concepts({
    int offset = 0,
    int limit = kFotoSmartAlbumPageSize,
    bool showHidden = false,
  }) async {
    final apiId = 'Browse.Concept';
    final data = await api.call(
      _name(apiId),
      'list',
      preferredVersion: _version(apiId, _conceptVersions),
      params: {
        'offset': '$offset',
        'limit': '$limit',
        'show_hidden': _bool(showHidden),
        'additional': js(const ['thumbnail']),
      },
    );
    return _list(data, FotoConceptDto.fromJson);
  }

  /// 场景数量（`Browse.Concept/count` **v2**）→ `{count}`。
  ///
  /// 官方前端在场景列表为空时会用 `{show_hidden:true}` 再数一次（估算隐藏项）。
  Future<int> conceptCount({bool showHidden = false}) async {
    final apiId = 'Browse.Concept';
    final data = await api.call(
      _name(apiId),
      'count',
      preferredVersion: _version(apiId, _conceptVersions),
      params: {'show_hidden': _bool(showHidden)},
    );
    return fInt(data['count']);
  }

  /// 按 id 取场景详情（`Browse.Concept/get` **v2**）。
  ///
  /// ⚠️ **未直接取证**：本批没抠到官方前端 `Concept/get` 的调用点；这里照
  /// **`Person/get` 的对称形态**写（`{id:[数字…], additional:["thumbnail"]}`）。
  /// 真机若回 `120`，优先怀疑是这里。
  Future<List<FotoConceptDto>> conceptDetails(List<String> conceptIds) async {
    final ids = _intIds(conceptIds);
    if (ids.isEmpty) return const [];
    final apiId = 'Browse.Concept';
    final data = await api.call(
      _name(apiId),
      'get',
      preferredVersion: _version(apiId, _conceptVersions),
      params: {
        'id': js(ids),
        'additional': js(const ['thumbnail']),
      },
    );
    return _list(data, FotoConceptDto.fromJson);
  }

  /// 某个场景名下的照片（`Browse.Item/list` **v7** + `concept_id`）。
  ///
  /// 形态与 [personItems] 完全同源（官方 `ER()` 的 filter 里是 `concept_id`）。
  Future<List<FotoItemDto>> conceptItems(
    String conceptId, {
    int offset = 0,
    int limit = 200,
  }) async {
    final apiId = 'Browse.Item';
    final data = await api.call(
      _name(apiId),
      'list',
      preferredVersion: _version(apiId, const [7, 6, 5, 4, 3, 2, 1]),
      params: {
        'concept_id': conceptId,
        'offset': '$offset',
        'limit': '$limit',
        'additional': js(itemAdditional()),
      },
    );
    return _items(data);
  }

  // ================================================== P18 人物：写操作
  //
  // **字段证据（官方安卓 APK smali 的 `@Field` 逐字）** ——
  // `ApiBrowsePerson$BrowsePersonRequests`：
  //   * `set`：`id`, `name`
  //   * `set_cover`：`id`, `photo_id`
  //   * `delete_face`：`person_id`, `face_id`
  //   * `separate`：`face_id`, `name`, `target_id`
  // （`merge` / `show` 走的是 **JSON body**（`MergeParameters` / `ShowHideParameters`），
  //  体内键 `merged_id`/`target_id`/`id`(数组)/`show` 已在 smali 里读到，
  //  但 body 编码路径没有 `@Field` 那么直白 ⇒ **本轮不实现**，登记为待取证。）

  /// 给人物**改名**（`Browse.Person / set`）。
  Future<void> personSetName({
    required String personId,
    required String name,
  }) async {
    if (personId.isEmpty || name.isEmpty) return;
    final apiId = 'Browse.Person';
    await api.call(
      _name(apiId),
      'set',
      preferredVersion: _version(apiId, _personVersions),
      params: {'id': personId, 'name': name},
    );
  }

  /// 设人物的**封面**（`Browse.Person / set_cover`；`photo_id` 是封面照片）。
  Future<void> personSetCover({
    required String personId,
    required String photoId,
  }) async {
    if (personId.isEmpty || photoId.isEmpty) return;
    final apiId = 'Browse.Person';
    await api.call(
      _name(apiId),
      'set_cover',
      preferredVersion: _version(apiId, _personVersions),
      params: {'id': personId, 'photo_id': photoId},
    );
  }

  /// 从人物里**移除一张人脸**（`Browse.Person / delete_face`）。
  /// ⚠️ **193 轮纠错**：`face_id` 是**数组**（官方 Web
  /// `De(n.deleteFace, {person_id: i, face_id: s})` 里 `s = photoIdArray`），
  /// 而 APK 请求接口签名是 `deleteFace(…, long person_id, String face_id)`
  /// —— 数组被序列化成**一个 JSON 串**。本仓 183 轮误发单值，此处改为
  /// [js] 序列化的数组；空列表 ⇒ 零请求。
  Future<void> personDeleteFace({
    required String personId,
    required List<String> faceIds,
  }) async {
    final ids = _intIds(faceIds);
    if (personId.isEmpty || ids.isEmpty) return;
    final apiId = 'Browse.Person';
    await api.call(
      _name(apiId),
      'delete_face',
      preferredVersion: _version(apiId, _personVersions),
      params: {'person_id': personId, 'face_id': js(ids)},
    );
  }

  /// 把一张人脸**拆成新人物**（`Browse.Person / separate`）。
  ///
  /// `target_id` = 拆到哪个已有人物（空串 = 新建，官方同名参数就是可空）。
  /// ⚠️ **193 轮纠错**：与 `delete_face` 同理，官方 Web
  /// `De(n.separate, {name: a, target_id: r, face_id: i})` 里 `i = faceIdList`
  /// ⇒ `face_id` 是 **JSON 数组串**（不是单值）。空列表 ⇒ 零请求。
  Future<void> personSeparateFace({
    required List<String> faceIds,
    String name = '',
    String targetId = '',
  }) async {
    final ids = _intIds(faceIds);
    if (ids.isEmpty) return;
    final apiId = 'Browse.Person';
    await api.call(
      _name(apiId),
      'separate',
      preferredVersion: _version(apiId, _personVersions),
      params: {
        'face_id': js(ids),
        if (name.isNotEmpty) 'name': name,
        if (targetId.isNotEmpty) 'target_id': targetId,
      },
    );
  }

  // ================================================== P19 概念：写操作
  //
  // `ApiBrowseConcept$BrowseConceptRequests`：`hide_item` → `id`, `item_id`；
  // `set_cover` → `id`, `photo_id`（`.lib` 钉 `hide_item:1` / `set_cover:1`）。

  /// 把一张照片**从场景/主题里移除**（`Browse.Concept / hide_item`）。
  Future<void> conceptHideItem({
    required String conceptId,
    required String itemId,
  }) async {
    if (conceptId.isEmpty || itemId.isEmpty) return;
    final apiId = 'Browse.Concept';
    await api.call(
      _name(apiId),
      'hide_item',
      preferredVersion: _version(apiId, _conceptVersions),
      params: {'id': conceptId, 'item_id': itemId},
    );
  }

  /// 设场景/主题的**封面**（`Browse.Concept / set_cover`）。
  Future<void> conceptSetCover({
    required String conceptId,
    required String photoId,
  }) async {
    if (conceptId.isEmpty || photoId.isEmpty) return;
    final apiId = 'Browse.Concept';
    await api.call(
      _name(apiId),
      'set_cover',
      preferredVersion: _version(apiId, _conceptVersions),
      params: {'id': conceptId, 'photo_id': photoId},
    );
  }

  /// **合并人物**（`Browse.Person / merge`，**v2**）。
  ///
  /// 证据：
  /// * 版本：官方 Web `react_bundle.js` 的方法版本表
  ///   `Person:{count:1,delete_face:1,get:1,get_migration_status:1,list:1,
  ///   list_face:1,merge:2,separate:1,set:1,set_cover:1,show:1,suggest:1}`
  ///   ⇒ `merge` 走 **v2**（不是 v1）；
  /// * 字段：APK smali `ApiBrowsePerson$MergeParameters` 的
  ///   `@SerializedName`：`target_id` / `merged_id` / `name`；
  /// * 用法：官方 Web `De(s.merge, {target_id: c, merged_id: u, name: l})`
  ///   —— `merged_id` 传的是**数组**（`mergedIdArray`）。
  ///
  /// `merged_id` 用 JSON 数字数组串（与 `Person/separate` 的 id 口径一致）；
  /// 空数组 / 空 targetId ⇒ **零请求**。§5.1：只写代码与离线用例。
  Future<void> personMerge({
    required String targetId,
    required List<String> mergedIds,
    String? name,
  }) async {
    final target = int.tryParse(targetId);
    final merged = _intIds(mergedIds);
    if (target == null || merged.isEmpty) return;
    await api.call(
      _name('Browse.Person'),
      'merge',
      preferredVersion: _version('Browse.Person', _personMergeVersions),
      params: {
        'target_id': '$target',
        'merged_id': js(merged),
        if (name != null && name.isNotEmpty) 'name': name,
      },
    );
  }

  /// **显示 / 隐藏人物**（`Browse.Person / show`，**v1**）。
  ///
  /// 证据：`ApiBrowsePerson$ShowHideParameters` 字段为
  /// `id`（**List**）/ `show`（boolean）+ 信封三件套；版本表里 `show:1`。
  ///
  /// `id` 与 `show` 都是必填语义：空 id 列表 ⇒ **零请求**（不猜"隐藏全部"）。
  Future<void> personShow({
    required List<String> personIds,
    required bool show,
  }) async {
    final ids = _intIds(personIds);
    if (ids.isEmpty) return;
    await api.call(
      _name('Browse.Person'),
      'show',
      preferredVersion: _version('Browse.Person', _personShowVersions),
      params: {'id': js(ids), 'show': show ? 'true' : 'false'},
    );
  }

  /// 某个地点名下的照片（`Browse.Item/list` **v7** + `geocoding_id`）。
  ///
  /// 证据（官方 APK 2.4.0-644，jadx）：
  ///   * `ApiBrowseItem.java:106` `KEY_GEOCODING_ID = "geocoding_id"`；
  ///   * `ApiBrowseItem.java:331-332` `getListGeoAlbumResponse(...)`
  ///     = `getListResponse(..., new ListParamBuilder(...).geocodingId(j).build(), ...)`
  ///     —— 地点内容的 filter 就是 `geocoding_id`；
  ///   * `ConnectionManager$listSmartAlbumContent$resp$3.java:58` 在
  ///     `SmartAlbumType.PLACE` 分支调用它。
  ///
  /// 官方 Web 前端同样用 `geocoding_id` 过滤（`zI`：`ALBUM_TYPE.GEOCODING` →
  /// `{geocoding_id: id}`）。形态与 [personItems] / [conceptItems] 同源。
  Future<List<FotoItemDto>> geocodingItems(
    String geocodingId, {
    int offset = 0,
    int limit = 200,
  }) async {
    final apiId = 'Browse.Item';
    final data = await api.call(
      _name(apiId),
      'list',
      preferredVersion: _version(apiId, const [7, 6, 5, 4, 3, 2, 1]),
      params: {
        'geocoding_id': geocodingId,
        'offset': '$offset',
        'limit': '$limit',
        'additional': js(itemAdditional()),
      },
    );
    return _items(data);
  }

  /// 当前用户 id（`UserInfo / me` **v1**）。
  ///
  /// 官方证据（jadx `ApiUserInfo.java`）：`API_ID="UserInfo"`、`API_VERSION=1`、
  /// `METHOD_ME="me"`、`METHOD_GET="get"`（带 `id`）、`KEY_ID="id"`；SPK 官方版本表
  /// `SYNO.Foto.UserInfo:{me:1, get:1}`。
  ///
  /// **为什么需要它**：条件相册的 `condition` 必须带 `user_id`
  /// （官方 Web `ui/react_bundle.js` 的 `function S(...)`：`h={user_id:e,item_type:p(n)}`），
  /// 而 `function P9(e)` 决定取值 —— **共享空间（team）恒为 `0`**，
  /// 个人空间才取当前用户 id。所以个人空间拿不到 id 时必须报错，
  /// 不能退回 `0`（否则会查出别人/空的相册）。
  ///
  /// ⚠️ `me` 响应体的字段名没有逐字取证（Android 只给了 `get` 的 `id`），
  /// 因此 `id` / `user_id` / `list[0].id` 三种形态都认。
  Future<String> userInfoMe() async {
    final apiId = 'UserInfo';
    final data = await api.call(
      _name(apiId),
      'me',
      preferredVersion: _version(apiId, const [1]),
    );
    String pick(Map<String, dynamic> m) {
      final id = fText(m['id']);
      return id.isNotEmpty ? id : fText(m['user_id']);
    }

    final direct = pick(data);
    if (direct.isNotEmpty) return direct;
    final list = data['list'];
    if (list is List && list.isNotEmpty) {
      final first = list.first;
      if (first is Map) return pick(first.cast<String, dynamic>());
    }
    return '';
  }

  // --------------------------------------------------------------- wave3
  //
  // 照片 EXIF / 相册缓存状态与大小 / 相册列表显示偏好。
  // 三条都是**只读**：`Download/clear_cache` 是写操作（官方 Web 的
  // `function BL()`），本批**未取证清理语义 → 不做**（见 docs/photo-gaps-wave3.md §7）。

  /// 照片 EXIF（`Browse.Item/get_exif` **v1**）。
  ///
  /// 真机证据（`docs/api-method-level-gaps.md` §「真机复核」）：
  ///   * 方法在 `Browse.Item` **v1..v7 全程存在**（服务端方法表并集）；
  ///   * 无参调用回 `120`，点名缺 **`id`**（照片 id）。
  ///
  /// ⚠️ `id` 的**形态（数字数组 vs 标量）未逐字取证**：这里与同族
  /// `Browse.Item/get` / `get_tag` / `set` 一致，发**数字数组的 JSON 串**
  /// （`js([id])`）。逐字回包同样没抓到 → 解析走 [FotoExifDto.fromJson] 的
  /// 宽松路径，只认官方 APK `ImageTableExif.java` 的六个字段名。
  Future<FotoExifDto> getExif(String itemId) async {
    final id = int.tryParse(itemId);
    if (id == null) return const FotoExifDto();
    final apiId = 'Browse.Item';
    final data = await api.call(
      _name(apiId),
      'get_exif',
      preferredVersion: _version(apiId, const [1]),
      params: {
        'id': js([id]),
      },
    );
    return FotoExifDto.fromJson(data);
  }

  /// 相册缓存状态（`Download/get_cache_status` **v2**；v1 是 `103`）。
  ///
  /// 真机回包 `{"status":"done"}`；官方 Web 读 `status` 并单判 `processing`。
  Future<FotoCacheStatusDto> getCacheStatus() async {
    final apiId = 'Download';
    final data = await api.call(
      _name(apiId),
      'get_cache_status',
      preferredVersion: _version(apiId, const [2]),
    );
    return FotoCacheStatusDto.fromJson(data);
  }

  /// 相册缓存大小（`Download/calculate_cache_size` **v2**；v1 是 `103`）。
  ///
  /// 官方 Web 原文 `function BD()`：`bS(uF.Z.Foto.Download.calculateCacheSize)`
  /// 之后读 `r.sent().cache_size`（字节）。取不到键 → [FotoCacheSizeDto.bytes]
  /// 为 null，界面显示"暂时取不到"（不显示 0）。
  Future<FotoCacheSizeDto> calculateCacheSize() async {
    final apiId = 'Download';
    final data = await api.call(
      _name(apiId),
      'calculate_cache_size',
      preferredVersion: _version(apiId, const [2]),
    );
    return FotoCacheSizeDto.fromJson(data);
  }

  /// 相册列表显示偏好（`Browse.Album/get_album_list_display` **v3**；v1/v2 是 `103`）。
  ///
  /// 官方 Web 原文 `function OP()`：`getAlbumListDisplay` → 读
  /// `album_display_type`；服务端白名单 `["all_album","my_album"]`
  /// （`SYNO.Foto.Browse.so` rodata）。
  ///
  /// ⚠️ 同族的 `set_album_list_display`（官方 `Oq(e)`，参数 `albumDisplayType`）
  /// 是**写**操作且本批**未取证** → **不实现、不进 UI**（见报告 §7）。
  Future<FotoAlbumListDisplayDto> getAlbumListDisplay() async {
    final apiId = 'Browse.Album';
    final data = await api.call(
      _name(apiId),
      'get_album_list_display',
      preferredVersion: _version(apiId, const [3]),
    );
    return FotoAlbumListDisplayDto.fromJson(data);
  }

  // --------------------------------------------------------------- 上传 / 备份

  /// `Upload.Item` 的候选版本（官方 Web 前端钉死 `upload:8 / upload_to_folder:8`）。
  static const List<int> _uploadVersions = [8, 7, 6, 5, 4, 3, 2, 1];

  /// 手机备份的**服务端查重**（`Upload.Item/backup_check`）。
  ///
  /// 请求形态来自 SPK 反汇编（`SYNO.Foto.Upload.so` 的 `UploadItemImpl::BackupCheck`）：
  /// `check=[{name, hash_code, takentime, mtime}, …]`。
  /// ⚠️ **响应结构未核实**（成功路径没有内联键），所以这里只做"认得出就认"的解析，
  /// 认不出时 [FotoBackupCheckResult.usable] 为 false，调用方应回落到
  /// 「列目标文件夹 + 文件名/大小」的客户端去重。
  ///
  /// ⚠️ 本 NAS 的 `.lib` 注册名是 `backup_check`，而官方 Web 写的 `upload_check`
  /// （同一个能力两名）。先试 `backup_check`，`103` 再试 `upload_check`。
  Future<FotoBackupCheckResult> backupCheck(
    List<FotoBackupCheckEntry> entries,
  ) async {
    if (entries.isEmpty) return const FotoBackupCheckResult();
    final apiId = 'Upload.Item';
    final params = {
      'check': js([for (final e in entries) e.toJson()]),
    };
    Map<String, dynamic>? data;
    Object? lastError;
    for (final method in const ['backup_check', 'upload_check']) {
      try {
        data = await api.call(
          _name(apiId),
          method,
          preferredVersion: _version(apiId, _uploadVersions),
          params: params,
        );
        break;
      } on DsmApiException catch (err) {
        lastError = err;
        if (err.code != DsmErrorCode.methodNotFound) rethrow;
      }
    }
    if (data == null) {
      if (lastError is DsmApiException &&
          lastError.code != DsmErrorCode.methodNotFound) {
        throw lastError;
      }
      return const FotoBackupCheckResult();
    }
    return FotoBackupCheckResult.parse(data, entries);
  }

  /// 把一个文件上传到**时间轴**（`Upload.Item/upload` v8）。
  ///
  /// 形态逐字照抄官方 Web 前端（SPK `ui/react_bundle.js` 的 `RO`+`RN`）：
  /// `{file, uploadDestination:"timeline", duplicate, name, mtime(秒),
  ///   folder:["PhotoLibrary"], api}`；`file` 是 raw part，其余是 form 字段，
  /// 且**除 api/method/version 外每个值都过 `JSON.stringify`**
  /// （字符串带引号、数字裸写 —— 真机 2026-09-21 实测不带引号报 120）。
  Future<String> uploadToTimeline({
    required String filePath,
    required String fileName,
    required int mtimeMs,
    String duplicate = 'rename',
    String? mimeType,
    void Function(int sent, int total)? onProgress,
  }) => _uploadItem(
    method: 'upload',
    filePath: filePath,
    fileName: fileName,
    mtimeMs: mtimeMs,
    duplicate: duplicate,
    mimeType: mimeType,
    onProgress: onProgress,
    extra: const {
      'uploadDestination': 'timeline',
      // 官方 `UploadFolder:["PhotoLibrary"]`
      'folder': ['PhotoLibrary'],
    },
  );

  /// 把一个文件上传到**指定相册文件夹**（`Upload.Item/upload_to_folder` v8）。
  ///
  /// 形态逐字照抄官方 Web 前端（同上的 `RO`+`RM`）：
  /// `{file, duplicate, name, mtime(秒), target_folder_id, api}`。
  /// `targetFolderId` 是 `Browse.Folder` 的真实目录 id（见 [folderRoot]）；
  /// 官方状态里 folder id 是 **number**，所以数字串会按数字发（`7` 而不是 `"7"`）。
  Future<String> uploadToFolder({
    required String folderId,
    required String filePath,
    required String fileName,
    required int mtimeMs,
    String duplicate = 'rename',
    String? mimeType,
    void Function(int sent, int total)? onProgress,
  }) => _uploadItem(
    method: 'upload_to_folder',
    filePath: filePath,
    fileName: fileName,
    mtimeMs: mtimeMs,
    duplicate: duplicate,
    mimeType: mimeType,
    onProgress: onProgress,
    extra: {'target_folder_id': int.tryParse(folderId) ?? folderId},
  );

  Future<String> _uploadItem({
    required String method,
    required String filePath,
    required String fileName,
    required int mtimeMs,
    required String duplicate,
    required Map<String, Object?> extra,
    String? mimeType,
    void Function(int sent, int total)? onProgress,
  }) async {
    final apiId = 'Upload.Item';
    final version = _version(apiId, _uploadVersions);
    // 官方 `RO` 的规则：除 api/method/version 外**每个值都 JSON.stringify**。
    // 2026-09-21 真机实测：`name` 不带引号 → 错误码 120「请求参数无效」。
    final fields = <String, String>{
      'api': _name(apiId),
      'method': method,
      'version': '$version',
      'name': js(fileName),
      // 官方 `Math.round(lastModified/1e3)`：**秒**（数字，裸写）
      'mtime': '${(mtimeMs / 1000).round()}',
      'duplicate': js(duplicate),
    };
    for (final entry in extra.entries) {
      fields[entry.key] = js(entry.value);
    }
    final raw = await api.postMultipart(
      api.apiPath(_name(apiId)),
      query: {'_sid': api.session?.sid ?? ''},
      fields: fields,
      fileField: 'file',
      filePath: filePath,
      fileName: fileName,
      mimeType: mimeType ?? 'application/octet-stream',
      onProgress: onProgress,
    );
    final data = api.decodeData(raw, '$_name($apiId).$method');
    return '${data['unit_id'] ?? data['item_id'] ?? data['id'] ?? ''}';
  }

  // --------------------------------------------------------------- 解析

  static List<FotoItemDto> _items(Map<String, dynamic> data) =>
      _list(data, FotoItemDto.fromJson);

  static List<T> _list<T>(
    Map<String, dynamic> data,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    final raw = data['list'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => fromJson(e.cast<String, dynamic>()))
        .toList();
  }
}
