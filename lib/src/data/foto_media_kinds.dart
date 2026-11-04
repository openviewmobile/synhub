// 相册**媒体种类**判定：实况照片（Live / Motion Photo）与 360 全景（P13 / P14）。
//
// 本文件是**纯 Dart**（不 import flutter / dart:ui），因为
//   * `lib/src/data/dto/foto_dto.dart` 要复用它来给 `FotoItemDto` 分类；
//   * 离线用例要能直接对着字符串表断言，不需要 widget 环境。
//
// ## 服务端条目 `type` 的**权威取值**（逐字取证，不猜）
//
// 1. 官方 Web 前端（SPK `SynologyPhotos 1.9.1-10928` 的 `ui/react_bundle.js`）：
//    ```js
//    q=Object.freeze({PHOTO:"photo",VIDEO:"video",BURST:"burst",LIVE:"live",
//                     PHOTO_360:"photo360",VIDEO_360:"video360",MOTION_PHOTO:"motion_photo"})
//    ```
//    且该枚举是**直接与服务器返回的条目 `type` 比较**的：
//    `function(e){...if(t===r.qG.PHOTO||t===r.qG.PHOTO_360||t===r.qG.BURST||t===r.qG.MOTION_PHOTO)return!0;
//     var n=e.get("live_type"); return n===r.M6.PHOTO||n===r.M6.LIVE}`
//
// 2. 官方 Android APK（2.4.0-644，jadx）`datasource/database/entity/ImageTable.java:1380-1387`
//    的 `ImageType` 常量值**逐字一致**：
//    ```java
//    PHOTO = new ImageType(..., ApiBrowseItem.TYPE_PHOTO);      // "photo"
//    VIDEO = new ImageType(..., MimeTypes.BASE_TYPE_VIDEO);     // "video"
//    PHOTO360 = new ImageType(..., "photo360");
//    VIDEO360 = new ImageType(..., "video360");
//    BURST  = new ImageType(..., "burst");
//    LIVE   = new ImageType(..., ApiBrowseItem.TYPE_LIVE);      // "live"
//    MOTION_PHOTO = new ImageType(..., "motion_photo");
//    PANORAMA = new ImageType(..., "panorama");
//    ```
//    并给出同文件的判定函数（**这就是官方的口径，本文件照抄**）：
//    ```java
//    public final boolean isVideo() { return this == VIDEO || this == VIDEO360; }
//    public final boolean is360()   { return this == PHOTO360 || this == VIDEO360; }
//    public final boolean isTraditionalPhoto() { ... this == PHOTO360 && !AbiUtil.supportsGoogleVR(); }
//    ```
//
// 3. 服务端 `SYNO.Foto.Browse.so` rodata 的类型枚举（本批重新提取，
//    偏移 `0x1d6c00` / `0x1d6d00`）：
//    `["photo", "video", "360", "live"]` →（更新版）`["photo", "video", "360", "live", "motion_photo"]`。
//
// ⚠️ 关于 `"360"`：**它不是条目的 `type`**，而是**智能相册 / 搜索建议的类型键**。
//    APK 里它只出现在 `SearchHistoryTable.SuggestionType PANORAMA = (..., TYPE_360, 1)`
//    与相册类型分支（Web `case b.aS.DEGREE_360: ... name:"360"`）。
//    真机实测（2026-09-22，`Browse.Item/list|count` v1..v7 全试）：
//    `type=360` → **`120 {name:"type",reason:"type"}` 全版本被拒**；
//    而 `type=live` / `type=motion_photo` 被接受（v1-v3 时 motion_photo 回
//    `reason:"condition"`，v4+ 起接受）→ 本条是**实测结论**，不是推断。
//    所以：`"360"` 只在本文件里被认成"全景**相册**键"，
//    **绝不**当成条目类型来判 `is360`。
library;

/// 相册条目的媒体种类（服务端 `type` 字段）。
///
/// 取值与官方 `ImageTable.ImageType` **一一对应**（见文件头证据链）。
enum FotoMediaKind {
  /// 普通照片：`type == "photo"`
  photo('photo'),

  /// 普通视频：`type == "video"`
  video('video'),

  /// 360 全景**照片**：`type == "photo360"`（等距柱状投影静图）
  photo360('photo360'),

  /// 360 全景**视频**：`type == "video360"`
  video360('video360'),

  /// 连拍：`type == "burst"`
  burst('burst'),

  /// 实况照片（Live Photo）**分组**成员：`type == "live"`
  live('live'),

  /// 动态照片（Motion Photo）：`type == "motion_photo"`，静图与短视频在**同一条目**内
  motionPhoto('motion_photo'),

  /// 全景（旧口径）：`type == "panorama"`
  panorama('panorama'),

  /// 认不出来的类型 —— **当作普通照片**处理（官方 `fromString` 的回落分支也是
  /// `: ImageType.PHOTO`），绝不因为"没认出"就把它藏起来。
  unknown('');

  const FotoMediaKind(this.wire);

  /// 服务端 `type` 字面量（[unknown] 为空串，表示"没有匹配的字面量"）。
  final String wire;

  /// 官方的 `isVideo()`：`VIDEO || VIDEO360`。
  ///
  /// ⚠️ `video360` **也是视频**：拿它不当视频会让全景视频走进静图链路
  /// （只会渲染出一张退化的平面图，且播放入口消失）。
  bool get isVideo =>
      this == FotoMediaKind.video || this == FotoMediaKind.video360;

  /// 官方的 `is360()`：`PHOTO360 || VIDEO360`。
  ///
  /// 注意官方**没有**把 `panorama` 算进来；本文件同样不把 `panorama` 算进
  /// [is360]（尊重官方口径），但把它单列成 [isPanoramaLike]，让它能被
  /// "按全景方式打开"的入口覆盖到，且判据写清楚。
  bool get is360 =>
      this == FotoMediaKind.photo360 || this == FotoMediaKind.video360;

  /// 可作全景渲染的种类：`photo360` / `video360` / 旧口径 `panorama`。
  bool get isPanoramaLike => is360 || this == FotoMediaKind.panorama;

  /// 静图侧的 360（要球面重投影才能看）：`photo360` / `panorama`
  bool get isPanoramaPhoto =>
      this == FotoMediaKind.photo360 || this == FotoMediaKind.panorama;

  /// 视频侧的 360（本仓播放器**不做球面**，只能如实降级，见报告）
  bool get isPanoramaVideo => this == FotoMediaKind.video360;

  /// 动态照片：静图 + 内嵌短视频在同一条目里，视频走
  /// `SYNO.Foto.Streaming/streaming?quality=motion_photo`。
  bool get isMotionPhoto => this == FotoMediaKind.motionPhoto;

  /// 实况照片分组（`type == "live"`，真正的配对关系看 `live_type`）。
  bool get isLive => this == FotoMediaKind.live;

  /// 能被"实况/动态"播放开关覆盖到（[isLive] 或 [isMotionPhoto]）。
  bool get isLiveLike => isLive || isMotionPhoto;

  /// 静图侧（`photo360` / `panorama` / 普通 `photo` / `burst` / `unknown`）。
  bool get isStillImage => !isVideo && !isMotionPhoto;

  static FotoMediaKind fromWire(String? raw) {
    final v = (raw ?? '').trim().toLowerCase();
    for (final k in FotoMediaKind.values) {
      if (k != FotoMediaKind.unknown && k.wire == v) return k;
    }
    return FotoMediaKind.unknown;
  }
}

/// 条目 `live_type` 字段（实况照片分组成员角色）。
///
/// 证据：官方 APK `ImageTable.java:1469-1471` 的 `LiveType` 常量值
/// `PHOTO:"photo"` / `VIDEO:"video"` / `LIVE:"live"`
/// （前两个直接复用 `ApiBrowseItem.TYPE_PHOTO` / `MimeTypes.BASE_TYPE_VIDEO`）。
///
/// 官方 Web 也是这么配对的 —— `react_bundle.js`：
/// ```js
/// pu = function(e){
///   var t = e.find(function(e){ return e.get("live_type") === b.M6.VIDEO });   // 找组里的视频成员
///   if(void 0===t) return !1;
///   var n = t.getIn(["additional","video_convert"], List()).toJS(),
///       r = t.getIn(["additional","video_meta"]).toJS();
///   return "" !== QT(n, r);                                                   // 该视频真的能播
/// }
/// ```
enum FotoLiveType {
  photo('photo'),
  video('video'),
  live('live'),
  none('');

  const FotoLiveType(this.wire);

  final String wire;

  /// 这一条**就是**实况照片里的那段短视频 → 可直接交给播放器。
  bool get isVideoMember => this == FotoLiveType.video;

  static FotoLiveType fromWire(String? raw) {
    final v = (raw ?? '').trim().toLowerCase();
    for (final k in FotoLiveType.values) {
      if (k != FotoLiveType.none && k.wire == v) return k;
    }
    return FotoLiveType.none;
  }
}

/// 智能相册 / 搜索建议里的**全景键**：`type == "360"`（**不是**条目类型）。
///
/// 真机实测已证 `Browse.Item/list` 的 `type` 过滤器**拒收** `"360"`（见文件头），
/// 所以这个字面量只用于识别"这是一个全景相册入口"。
const String kFotoPanoramaAlbumTypeKey = '360';

/// `additional.motion_photo` —— 动态照片的内嵌短视频元数据。
///
/// 这是**服务端给的配对信息**：官方 Web 播放动态照片时
/// （`react_bundle.js`）：
/// ```js
/// S = r.get("type") === b.qG.MOTION_PHOTO;
/// I = function(){ if(S) return { convertInfo: [],
///         videoMeta: r.getIn(["additional","motion_photo"]).toJS(),   // ← 就在这里
///         quality: "motion_photo", videoConvertStatus: Ready };
///       ... };
/// w = function(e){ ... return S
///         ? i_({id:i, type:o, quality:"motion_photo", albumId:s, passphrase:a, library:l})
///         : ... };
/// ```
/// 即：**不需要在客户端把两个条目拼起来** —— 元数据来自同一个条目的
/// `additional.motion_photo`，视频字节来自 `Streaming` 的 `quality=motion_photo` 档
/// （该档位也在服务端 `SYNO.Foto.Streaming.so` rodata 白名单里）。
const String kFotoAdditionalMotionPhoto = 'motion_photo';

/// 动态照片取内嵌短视频用的 `quality` 档（服务端 rodata 白名单成员）。
const String kFotoMotionPhotoQuality = 'motion_photo';
