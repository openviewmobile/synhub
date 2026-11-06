// 相册模块的共享小部件与文案。
import '../../design/kit/design_kit.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/media/aspect_image.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/foto_dto.dart';
import '../../data/foto_api.dart';
import '../../dsm/webapi.dart';
import '../files/file_thumb.dart' show looksLikeImage;
import '../media/media_cover.dart' show normalizeMediaExtension;
import '../media/media_source.dart' show MediaKind, resolvePhotosSource;
import '../media/video_frame_thumb.dart'
    show
        VideoFrameThumbFailure,
        VideoFrameThumbRequest,
        kVideoFrameContainers,
        videoFrameRequestFailureReason,
        videoFrameThumbCacheProvider,
        videoFrameThumbProvider,
        videoFrameThumbSupported,
        logVideoFrameThumbFailure;
import '../media/video_thumb_unavailable.dart' show VideoThumbUnavailable;
import 'image_edit_providers.dart';
import 'photo_ai_edit_sheet.dart';
import 'photo_ai_edit_text.dart';
import 'photo_delete_undo.dart';
import 'photo_share.dart';
import '../chat/media_stream.dart' show mimeForFileName;
import 'photo_format_support.dart';
import 'photo_grid_density.dart';
import 'photo_p0_text.dart';
import 'photo_providers.dart';
import 'photo_rating.dart';
import 'photo_tag_sheet.dart' show showPhotoTagSheet;
import 'photo_wave1_text.dart';
import '../../core/user_facing_error.dart';

/// 相册错误文案（对齐官方 App 的提示语，把错误码翻成人话）。
///
/// 没有 `BuildContext` 的调用点（测试/服务）走 [currentText]；界面一律传 `context.t`。
String describePhotoError(Object error, [AppText? l10n]) {
  final t = l10n ?? currentText();
  // 评分（P40）：老 Photos（`Browse.Item` maxVersion < 2）没有这条能力。
  // 界面本该按能力位把入口藏掉，这里是绕过能力位时的兜底文案。
  if (error is FotoRatingUnsupportedException) return t.photoErrApiVersion;
  if (error is DsmApiException) {
    switch (error.code) {
      case 801:
        return t.photoErrSpacePermission;
      case 802:
        return t.photoErrNotFound;
      case 160:
        return t.photoErrAccount;
      case 402:
        return t.photoErrDsmDenied;
      // 官方 `SYNO_PHOTO_ERR`：901 = PERSON_MIGRATION_IS_NOT_FINISHED（人脸
      // 识别正在做迁移）、902 = PERSON_CLUSTERING_IS_NOT_FINISHED（正在聚类）。
      // 两者都不是"坏了"，是"还没跑完"，文案要说清楚。
      case 901:
        return t.photoErrPersonMigrating;
      case 902:
        return t.photoErrConceptClustering;
      case DsmErrorCode.apiNotFound:
        return t.photoErrNotInstalled;
      case DsmErrorCode.methodNotFound:
        return t.photoErrApiVersion;
      case DsmErrorCode.sessionTimeout:
      case DsmErrorCode.sidNotFound:
        return t.errLoginExpired;
      default:
        return DsmErrorCode.describe(error.code, method: error.method);
    }
  }
  return userFacingError(error);
}

/// 时间轴分组标题：官方按 `timeline_group_unit`（day / month）分组。
///
/// 本批补 **year**（官方 `str_year_view_mode = Year`）。year 的文案走
/// `photo_wave1_text.dart`（`.arb` 本批禁碰），day/month 仍复用既有 `photoGroup*`。
String photoGroupLabel(DateTime t, {String unit = 'day', AppText? l10n}) {
  final l = l10n ?? currentText();
  if (unit == 'year') {
    return photoWave1Fill(PhotoWave1TextKeys.groupYear, '{year} 年', {
      'year': '${t.year}',
    });
  }
  if (unit == 'month') return l.photoGroupMonth(t.year, t.month);
  return l.photoGroupDay(t.year, t.month, t.day);
}

/// 把时间轴切成 [(分组标题, 该组照片)]，顺序保持服务端给的顺序。
List<(String, List<FotoItemDto>)> groupPhotos(
  List<FotoItemDto> items, {
  String unit = 'day',
  AppText? l10n,
}) {
  final out = <(String, List<FotoItemDto>)>[];
  for (final it in items) {
    final label = photoGroupLabel(it.takenAt, unit: unit, l10n: l10n);
    if (out.isNotEmpty && out.last.$1 == label) {
      out.last.$2.add(it);
    } else {
      out.add((label, [it]));
    }
  }
  return out;
}

/// 人类可读大小（相册里复用文件模块的写法）。
String photoBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 10 ? 0 : 1)} ${units[i]}';
}

/// 该档位在服务端是否**就绪**（`ready`）。
///
/// `additional.thumbnail` 的每个尺寸值是状态串，不是"有没有图"：
/// 真机视频例 `sm/m/xl="ame_defect"`、`preview="broken"` —— 这些**都不是
/// ready**，发 `Foto.Thumbnail:get` 必然 404（`docs/thumbnail-apis.md` §1.8）。
/// 判据照抄 [FotoThumbDto.hasAny]（只看 `sm`/`m`/`xl`，`preview` 不算）。
bool fotoThumbSizeReady(FotoThumbDto thumb, String size) => switch (size) {
  'm' => thumb.m == 'ready',
  'xl' => thumb.xl == 'ready',
  _ => thumb.sm == 'ready',
};

/// 请求的档位若没就绪就降到 [FotoThumbDto.bestSize]（避免"要 m 但只有 sm ready"）。
String _fotoThumbEffectiveSize(FotoThumbDto thumb, String size) =>
    fotoThumbSizeReady(thumb, size) ? size : thumb.bestSize;

/// 由一个照片条目生成缩略图请求（`space` 决定 `SYNO.Foto.` / `SYNO.FotoTeam.`）。
///
/// **非 ready 就返回 `null`**（占位由 [PhotoThumb] 画）—— 以前无条件发
/// `size='sm'`，于是 `ame_defect` 的视频每次都在列表里打一个必然 404 的请求，
/// 真机上表现为破图/空白格（`docs/thumbnail-apis.md` §2①、§3 第 3 条）。
PhotoThumbRequest? photoThumbRequest(
  FotoItemDto item,
  FotoSpace space, {
  String size = 'sm',
}) {
  final thumb = item.thumb;
  if (!thumb.hasAny) return null;
  return PhotoThumbRequest(
    itemId: item.id,
    cacheKey: thumb.cacheKey,
    space: space,
    size: _fotoThumbEffectiveSize(thumb, size),
  );
}

/// 由相册封面生成缩略图请求。
///
/// ⚠️ **两个都必须对**（`docs/thumbnail-apis.md` §1.8，真机 404 取证）：
///   * 封面的 id 在 `unit_id` 里（不是照片的 item id）；
///   * `type` 必须配 `unit` —— `SYNO.Foto.Thumbnail:get` 的 `type` 与 `id`
///     **不可互换**：`type=item` 只认 item id，`type=unit` 只认 unit id。
/// 旧实现默认 `type=item` 却传 `unit_id` ⇒ 真机**必然 404**。
///
/// 状态非 ready（`ame_defect`/`broken`/缺 `unit_id`）→ 返回 `null`，画占位。
PhotoThumbRequest? photoCoverRequest(
  FotoThumbDto? cover,
  FotoSpace space, {
  String size = 'sm',
}) {
  if (cover == null || cover.unitId.isEmpty) return null;
  if (!cover.hasAny) return null;
  return PhotoThumbRequest(
    itemId: cover.unitId,
    cacheKey: cover.cacheKey,
    space: space,
    size: _fotoThumbEffectiveSize(cover, size),
    thumbType: 'unit',
  );
}

/// 人物 / 场景（智能相册）封面的缩略图请求。
///
/// 规则逐字照抄官方 Web 前端的缩略图工具（SPK `ui/react_bundle.js`）：
///   * 缩略对象**带 `unit_id`** → `type="unit"`，`id` 用 `unit_id`（封面是某张照片）；
///   * 否则 → `type="person"` / `"concept"`，`id` 用**人物 / 场景自己的 id**
///     （服务端直接回人脸裁切图 / 场景封面）。
///
/// 两种都拿不到（没有封面、或缩略对象里连 `sm` 状态都没有）→ 返回 null，
/// 由 [PhotoAlbumTile] 画占位图标，不发一个必然报错的请求。
PhotoThumbRequest? photoSmartAlbumCoverRequest(
  FotoThumbDto? cover,
  FotoSpace space, {
  required String type,
  required String id,
  String size = 'sm',
}) {
  if (cover == null) return null;
  // 状态非 ready（`ame_defect`/`broken`）→ 一律占位，不发必然 404 的请求。
  if (!cover.hasAny) return null;
  final effective = _fotoThumbEffectiveSize(cover, size);
  if (cover.unitId.isNotEmpty) {
    return PhotoThumbRequest(
      itemId: cover.unitId,
      cacheKey: cover.cacheKey,
      space: space,
      size: effective,
      thumbType: 'unit',
    );
  }
  if (id.isEmpty) return null;
  return PhotoThumbRequest(
    itemId: id,
    cacheKey: cover.cacheKey,
    space: space,
    size: effective,
    thumbType: type,
  );
}

// ============================================================ 相册视频抽帧

/// 相册视频抽帧的**缓存身份路径**（`VideoFrameThumbRequest.forPath` 的 `path` 位）。
///
/// 形如 `photos:personal:28045` —— **含空间**，因为共享空间的 item id 与个人空间
/// 不保证不撞；真正的缓存键由 `videoFrameCacheKey` 再拼上 `time`（拍摄时间）
/// 与 `filesize`，与 Files 侧「路径 + mtime + size」同一约定
/// （`lib/src/features/media/video_frame_thumb.dart`）。
String photoVideoFrameCachePath(FotoItemDto item, FotoSpace space) =>
    'photos:${space.name}:${item.id}';

/// 由一个相册视频条目构造**本机抽帧**请求。
///
/// **直链一律复用既有实现**：[resolvePhotosSource] → `SYNO.Foto.Download`
/// 的 `authenticatedUrl`（`_sid` / `SynoToken` 已在查询串里，`Download` 腿的
/// Range 真机已证 206 ⇒ `supportsRange = true`，只取 6 MiB 头部即可，不会把
/// 整个视频拉下来）。这里**一个 URL 都不拼**。
///
/// 返回 `null` = **连抽帧都不该发**：API 未连接 / 后缀不在视频容器白名单 /
/// 直链为空（隧道传输 / 证书固定等被 [resolvePhotosSource] 判为不可播）。
/// 调用方据此直接画占位，而不是让抽帧层白跑一次。
///
/// ⚠️ 相册视频**从不**走 `SYNO.Foto.Thumbnail:get`：真机对视频恒
/// `ame_defect` → 404（`docs/thumbnail-apis.md`），发它只是白发一个必然失败的请求。
VideoFrameThumbRequest? photoVideoFrameRequest(
  FotoItemDto item,
  FotoApi? foto,
  FotoSpace space,
) {
  if (foto == null) return null;
  final ext = normalizeMediaExtension(item.filename);
  if (!kVideoFrameContainers.contains(ext)) return null;
  final source = resolvePhotosSource(
    displayName: item.filename,
    kind: MediaKind.video,
    // `item.id` 是 **item id**（官方取流就是 `id` + `type="item"`），
    // 不是 `thumb.unitId`。
    itemId: item.id,
    foto: foto,
    team: space == FotoSpace.team,
    size: item.filesize,
  );
  if (source.uri.isEmpty) return null;
  return VideoFrameThumbRequest.forPath(
    path: photoVideoFrameCachePath(item, space),
    uri: source.uri,
    extension: ext,
    size: item.filesize,
    // 相册条目没有文件系统 mtime ⇒ 用**拍摄时间**（秒）当版本戳，
    // 与 `filesize` 一起保证"同 id 换了内容"时缓存键会变。
    mtime: item.time,
    rangeSupported: source.supportsRange,
  );
}

/// 相册视频缩略图的**中间态**（第 263 轮）。
///
/// 以前"还在抽帧"和"抽帧失败"画的是**同一个**图标 ⇒ 用户分不清"慢"和"坏"，
/// 日志里也没有落点（AGENTS §2.0.17②：静默降级必须分得清中间态、能说出原因）。
enum PhotoVideoThumbStage {
  /// 排队中 / 正在下载头部 + 原生抽帧 —— 界面画骨架，**不是**"坏了"。
  loading,

  /// 确实失败（失败记忆命中）—— 画"摄像机不可用"图标，并打一条原因日志。
  failed,

  /// **连抽帧都不该发**：没有直链 / 后缀不在容器白名单 / Range 与大小不满足。
  unavailable,
}

/// 相册视频抽帧失败的**请求侧可判定原因**（纯函数，离线可测）。
///
/// ⚠️ 这里只能给出"请求侧"的事实（直链/后缀/大小/Range）。**容器解不了、
/// 编解码器不支持、没有视频轨**这些平台侧结论由 Android 桥落 logcat
/// （tag `VideoFrameBridge`，见 `android/.../VideoFrameBridge.kt` 的
/// `stage=open|frame|encode` + 元数据）——两边合起来才能定位到具体是哪一段。
@visibleForTesting
String photoVideoFrameFailureReason(VideoFrameThumbRequest? request) {
  if (request == null) return 'no-request';
  if (request.uri.isEmpty) return 'no-url';
  // 第 267 轮起与 media 层**同一份实现**（`videoFrameRequestFailureReason`），
  // 免得两处各写一遍、日后改一处漏一处。
  return videoFrameRequestFailureReason(
    extension: request.extension,
    size: request.size,
    rangeSupported: request.rangeSupported,
  );
}

/// **平台侧**的失败分层（第 267 轮）：容器打不开 / 没有视频轨 / 编码失败。
///
/// 由原生 `extractFrameEx` 给出（tag `VideoFrameBridge` 的 `stage=`），Dart 侧
/// 从失败记忆里读回。null = 平台没给出分层（老构建 / 通道缺席 / 请求侧就做不了）
/// —— **这不是"未知错误"**，是"没有这一档信息"。
VideoFrameThumbFailure? photoVideoFrameFailure(
  WidgetRef ref,
  VideoFrameThumbRequest? request,
) {
  if (request == null) return null;
  final cache = ref.watch(videoFrameThumbCacheProvider);
  if (!cache.isRememberedFailure(request.cacheKey)) return null;
  return cache.failureFor(request.cacheKey);
}

/// 一张缩略图（**字节版**）。
///
/// 不用 `Image.network`：相册的 URL 是 NAS 自签证书 + `_sid`，`Image.network`
/// 自带的 `HttpClient` 既不认自签证书也不带我们的 Dio 配置 —— 真机上表现为
/// **整格不画**（像素停在上一帧，看着像"残影"）。所以统一走
/// `photoThumbProvider`（`api.getBytes`）再 `Image.memory`。
///
/// [request] 为 `null` = **服务端缩略状态非 ready**（`ame_defect`/`broken`，
/// 见 [photoThumbRequest]）⇒ 直接画"暂无封面"占位，**一个请求都不发**。
///
/// 加载中 / 失败都画**不透明**底色 + 占位图标，不留透明格子。
class PhotoThumb extends ConsumerWidget {
  const PhotoThumb({
    super.key,
    required this.request,
    this.fit = BoxFit.cover,
    this.isVideo = false,
    this.showFavorite = false,
    this.filename,
    this.videoItem,
  });

  final PhotoThumbRequest? request;
  final BoxFit fit;
  final bool isVideo;
  final bool showFavorite;

  /// 视频条目的**原始 DTO**（可选）：`isVideo == true` 时用它构造本机抽帧请求
  /// （见 [photoVideoFrameRequest]）。为 `null` ⇒ 视频只画占位，不抽帧
  /// （既有 `PhotoThumb(request: null, isVideo: true)` 的调用点行为不变）。
  final FotoItemDto? videoItem;

  /// 文件名（可选）：用来判定"这个格式官方本来就不承诺"（P16 RAW/AVIF 兜底）。
  ///
  /// 传了就多一层解释：缩略图取不到 + 扩展名属于 RAW/AVIF/HEIC 时，格子给
  /// "格式不支持"图标 + tooltip，而不是一个看起来像"网坏了"的破图。
  final String? filename;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    // 服务端缩略状态非 ready（`ame_defect` / `broken`）：这里是"图**坏**了"，
    // 不是"还没生成" ⇒ 画占位 + 说明，**绝不**发一个必然 404 的请求。
    // 放在能力位之前：坏图与"服务端有没有这个 API"无关，也不该去 watch 能力位。
    //
    // ⚠️ 说明用 `Semantics(label:)`，**不要**用 `Tooltip`：`Tooltip` 默认
    // **长按触发**，会把相册网格的"长按进多选"手势吞掉
    // （第 261 轮实测：`photo_tag_test` / `photo_person_concept_test` 的
    // 多选用例当场变红）。这里只要"读屏能念出原因"，不参与手势竞技。
    final req = request;

    // 相册视频：服务端缩略图对视频**不成立**（真机 `sm/m/xl = ame_defect` ⇒
    // `Foto.Thumbnail:get` 恒 404，`docs/thumbnail-apis.md` §1.8）⇒ **恒走本机抽帧**
    // （只取 6 MiB 头部，见 `video_frame_thumb.dart`），**绝不**为视频发那个注定
    // 404 的服务端请求。出帧就渲染（保留下载/播放角标）；拿不到直链 / 抽帧失败
    // ⇒ 退回下面的占位（不空白、不抛）。
    if (isVideo) {
      final videoReq = _videoFrameRequest(ref);
      final frame = _videoFrameBytes(ref, videoReq);
      if (frame != null) return _videoFrameTile(context, frame);
      // ⚠️ 抽帧做不了 / 还没抽好 / 失败 → **不在这里**下结论，继续走下面的既有逻辑：
      //   * 真机视频常态是 `ame_defect`（`req == null`）⇒ 落到"缩略图不可用"占位；
      //   * 若服务端确实把视频缩略标成 `ready`（老服务器 / 已生成转码缩略图），
      //     仍按老路走服务端 `Foto.Thumbnail:get` —— 既有用例
      //     （`photo_browse_test` 的 ready 视频）与老服务器行为**保持不变**。
      // 真机上视频是前者，所以**不会**为视频发那个注定 404 的请求。
      if (req == null) {
        // ★ 第 263 轮：服务端帮不上忙时，把"还在抽"和"确实失败"**分开画**。
        // ★ 第 267 轮：失败不再只画一个"摄像机不可用"——用**带原因**的占位
        //   （`格式不支持 · AVI/RIFF · FMP4` 这类；真机取证见
        //   `docs/device-verification.md §⑩.7`）。文案**不写"编码不支持"**：
        //   FMP4 本机有解码器，卡住的是**容器解析**。
        return switch (_videoFrameStage(ref, videoReq)) {
          PhotoVideoThumbStage.loading => _videoFrameLoadingPlaceholder(
            context,
          ),
          PhotoVideoThumbStage.failed => VideoThumbUnavailable(
            key: const Key('photo-thumb-unavailable'),
            failure: photoVideoFrameFailure(ref, videoReq),
            background: DesignPalette.of(context).bg,
          ),
          PhotoVideoThumbStage.unavailable => _unavailablePlaceholder(context),
        };
      }
    }

    if (req == null) {
      return _unavailablePlaceholder(context);
    }
    // S2 能力位降级：服务端缺 `SYNO.Foto.Thumbnail` → 不再请求缩略图，
    // 直接回退成**占位图**（不空白、不崩）。`hasApi` fail-open，未确定时不降级。
    final canThumb = ref
        .watch(serviceAvailabilityProvider)
        .hasApi(StationService.photo, kFotoThumbnailApi);
    if (!canThumb) {
      return ColoredBox(
        key: const Key('photo-thumb-fallback'),
        color: hud.bg,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(child: Icon(Icons.image_outlined, color: hud.dim, size: 20)),
            if (isVideo)
              const Positioned(
                right: 6,
                bottom: 6,
                child: Icon(
                  Icons.play_circle_fill,
                  size: 20,
                  color: Colors.white70,
                ),
              ),
          ],
        ),
      );
    }
    final bytes = ref.watch(photoThumbProvider(req)).value;

    // P16：官方对 RAW / DNG / AVIF **不承诺**机内显示，只给一句兜底
    // （`str_ame_unsupported_format_message`）。缩略图拿不到 + 扩展名命中 →
    // 图标换成"此格式不支持"，并用 tooltip 说清（不再像"网坏了"）。
    final formatHint = filename == null
        ? null
        : photoFormatFallbackText(filename!);
    final unsupportedIcon = ColoredBox(
      color: hud.bg,
      child: Center(
        child: Icon(
          Icons.image_not_supported_outlined,
          color: hud.dim,
          size: 20,
        ),
      ),
    );

    Widget inner;
    if (bytes == null || !looksLikeImage(bytes)) {
      final placeholder = ColoredBox(
        color: hud.bg,
        child: Center(
          child: Icon(
            bytes == null ? Icons.image_outlined : Icons.broken_image_outlined,
            color: hud.dim,
            size: 20,
          ),
        ),
      );
      inner = formatHint == null
          ? placeholder
          : Tooltip(message: formatHint, child: unsupportedIcon);
    } else {
      // 相册里的照片同样**按真实比例**摆（服务端的 `Foto.Thumbnail` 是原比例：
      // 实测 1148×2492 的原图 → sm 240×521 / m 320×695，见
      // `docs/book-covers-and-pdf-toc.md` §1.5）。以前 `BoxFit.cover` 会把横图
      // 砍两边、手机截图砍掉一半。比例读不出来时退 `contain`，也不裁。
      final aspect = aspectOfImageBytes(bytes);
      // ★ r499：**保住比例 ⇒ 竖图会在方格子里留出左右留白**，
      //   于是"图片自己的四个角"落在格子内部，看起来是**直角**
      //   （真机对照：横图填满格子有圆角，竖图居中显示却是方形角）。
      //   这里给**图片本体**也套同一圆角，保证"每一张图都是圆角"。
      // ⚠️ 圆角必须套在 **AspectRatio 里面**：`AspectImage` 是
      //   `Center(AspectRatio(child))`，若把 `ClipRRect` 套在它外面，
      //   裁剪框拿到的是**整格**尺寸（Stack 的 expand），而图片比格子窄，
      //   于是"裁在格子边界上"= 图片自己的角根本没被裁（r499 第一次就是这么错的）。
      inner = AspectImage(
        aspect: aspect,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Radii.cut),
          child: Image.memory(
            bytes,
            fit: aspect == null ? BoxFit.contain : BoxFit.cover,
            gaplessPlayback: true,
            cacheWidth: req.decodeWidth,
            // 解码失败也要有交代（不白屏、不整格透明）
            errorBuilder: (_, _, _) => formatHint == null
                ? ColoredBox(
                    color: hud.bg,
                    child: Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: hud.dim,
                        size: 20,
                      ),
                    ),
                  )
                : Tooltip(message: formatHint, child: unsupportedIcon),
          ),
        ),
      );
    }

    return ColoredBox(
      color: hud.bg,
      child: Stack(
        fit: StackFit.expand,
        children: [
          inner,
          if (isVideo)
            const Positioned(
              right: 6,
              bottom: 6,
              child: Icon(
                Icons.play_circle_fill,
                size: 20,
                color: Colors.white70,
              ),
            ),
          if (showFavorite)
            const Positioned(
              right: 6,
              top: 6,
              child: Icon(Icons.star, size: 16, color: Colors.amber),
            ),
        ],
      ),
    );
  }

  /// 失败日志（release 包也进 logcat，tag `flutter`）。
  ///
  /// 格式固定成 `[photoVideoThumb] FAIL key=… ext=… size=… range=… reason=…`，
  /// 与 office 侧的 `[officeThumb] FAIL` 同一套排查口径（AGENTS §2.0.17②）。
  /// 第 267 轮起由 media 层的**共用**实现 [logVideoFrameThumbFailure] 打，
  /// 并在 `reason=` 之后**追加**平台侧分层（`stage=`/`container=`/`fourcc=`）
  /// —— 老格式（前缀到 `reason=` 为止）逐字不变，老用例仍绿。
  void _logVideoFrameFailure(
    VideoFrameThumbRequest request,
    VideoFrameThumbFailure? failure,
  ) {
    logVideoFrameThumbFailure(request, failure, tag: 'photoVideoThumb');
  }

  /// 视频项的本机抽帧**请求**；不是视频 / 拿不到直链 → null。
  VideoFrameThumbRequest? _videoFrameRequest(WidgetRef ref) {
    final item = videoItem;
    if (item == null) return null;
    return photoVideoFrameRequest(
      item,
      ref.watch(fotoSpaceApiProvider),
      ref.watch(fotoSpaceProvider),
    );
  }

  /// 视频项的本机抽帧字节；**拿不到直链 / 做不了 / 抽帧失败** → null。
  ///
  /// `videoFrameThumbSupported` 为 false 时**连 provider 都不 watch** ——
  /// 保证"没有直链 ⇒ 一次抽帧都不发"，直接让调用方画占位。
  Uint8List? _videoFrameBytes(WidgetRef ref, VideoFrameThumbRequest? videoReq) {
    if (!videoFrameThumbSupported(videoReq)) return null;
    final bytes = ref.watch(videoFrameThumbProvider(videoReq!)).value;
    return (bytes != null && looksLikeImage(bytes)) ? bytes : null;
  }

  /// 抽帧现在处于哪一态（骨架 / 失败 / 做不了；见 [PhotoVideoThumbStage]）。
  PhotoVideoThumbStage _videoFrameStage(
    WidgetRef ref,
    VideoFrameThumbRequest? videoReq,
  ) {
    if (!videoFrameThumbSupported(videoReq)) {
      return PhotoVideoThumbStage.unavailable;
    }
    final async = ref.watch(videoFrameThumbProvider(videoReq!));
    if (ref
        .watch(videoFrameThumbCacheProvider)
        .isRememberedFailure(videoReq.cacheKey)) {
      _logVideoFrameFailure(videoReq, photoVideoFrameFailure(ref, videoReq));
      return PhotoVideoThumbStage.failed;
    }
    if (async.isLoading) return PhotoVideoThumbStage.loading;
    // 完成但没有字节、也没记成失败（例如刚被滚出屏幕取消）：当作"做不了"，
    // **不假装还在加载** —— 否则会永久转圈。
    return PhotoVideoThumbStage.unavailable;
  }

  /// 抽帧进行中的骨架：中性"影片"图标 + 播放角标，**不是**"摄像机不可用"。
  Widget _videoFrameLoadingPlaceholder(BuildContext context) {
    final hud = DesignPalette.of(context);
    return ColoredBox(
      key: const Key('photo-video-thumb-loading'),
      color: hud.bg,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(child: Icon(Icons.movie_outlined, color: hud.dim, size: 20)),
          const Positioned(
            right: 6,
            bottom: 6,
            child: Icon(
              Icons.play_circle_fill,
              size: 20,
              color: Colors.white70,
            ),
          ),
        ],
      ),
    );
  }

  /// 抽到真帧：按真实比例摆，**保留下载/播放角标**（产品要求）。
  Widget _videoFrameTile(BuildContext context, Uint8List bytes) {
    final hud = DesignPalette.of(context);
    final aspect = aspectOfImageBytes(bytes);
    return ColoredBox(
      color: hud.bg,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ★ r499：与照片同一条规矩 —— 圆角套在 AspectRatio **里面**
          AspectImage(
            aspect: aspect,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.cut),
              child: Image.memory(
                bytes,
                fit: aspect == null ? BoxFit.contain : BoxFit.cover,
                gaplessPlayback: true,
                // 抽帧失败（坏字节）也要有交代 —— 不白屏、不抛。
                errorBuilder: (_, _, _) => Center(
                  child: Icon(
                    Icons.videocam_off_outlined,
                    color: hud.dim,
                    size: 20,
                  ),
                ),
              ),
            ),
          ),
          const Positioned(
            right: 6,
            bottom: 6,
            child: Icon(
              Icons.play_circle_fill,
              size: 20,
              color: Colors.white70,
            ),
          ),
        ],
      ),
    );
  }

  /// "缩略图不可用"占位（视频 = 摄像机图标 + 播放角标；其它 = 破图图标）。
  ///
  /// 与第 261 轮之前的实现**逐字一致**，只是抽成方法给"视频抽帧失败"复用，
  /// 免得两条路各画一份占位、日后改一处漏一处。
  Widget _unavailablePlaceholder(BuildContext context) {
    final hud = DesignPalette.of(context);
    return ColoredBox(
      key: const Key('photo-thumb-unavailable'),
      color: hud.bg,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Semantics(
              label: context.t.mediaCoverUnavailable,
              image: true,
              child: Icon(
                isVideo
                    ? Icons.videocam_off_outlined
                    : Icons.broken_image_outlined,
                color: hud.dim,
                size: 20,
              ),
            ),
          ),
          if (isVideo)
            const Positioned(
              right: 6,
              bottom: 6,
              child: Icon(
                Icons.play_circle_fill,
                size: 20,
                color: Colors.white70,
              ),
            ),
        ],
      ),
    );
  }
}

/// 多选状态（长按进入；只在页面内部用，不进 Riverpod）。
///
/// 与文件模块的多选同一口径：**选中集合非空即为多选模式**，
/// 取消最后一个自动退出（不给"0 张还停在多选"的死状态）。
class PhotoSelectionController extends ChangeNotifier {
  final Set<String> ids = {};

  bool contains(String id) => ids.contains(id);
  bool get active => ids.isNotEmpty;
  int get count => ids.length;

  void enter(String id) {
    ids.add(id);
    notifyListeners();
  }

  void toggle(String id) {
    if (!ids.remove(id)) ids.add(id);
    notifyListeners();
  }

  void tap(String id) {
    if (active) {
      toggle(id);
    } else {
      enter(id);
    }
  }

  void selectAll(Iterable<String> all) {
    ids
      ..clear()
      ..addAll(all);
    notifyListeners();
  }

  void clear() {
    if (ids.isEmpty) return;
    ids.clear();
    notifyListeners();
  }
}

/// 多选模式下的顶部计数条（计数 + 全选/取消全选 + 退出）。
class PhotoSelectionHeader extends StatelessWidget {
  const PhotoSelectionHeader({
    super.key,
    required this.count,
    required this.total,
    required this.onSelectAll,
    required this.onClear,
  });

  final int count;
  final int total;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final all = count >= total && total > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      child: Row(
        children: [
          IconButton(
            key: const Key('photo-selection-close'),
            tooltip: t.ptExitSelection,
            icon: const Icon(Icons.close, size: 18),
            onPressed: onClear,
          ),
          Expanded(
            child: Text(
              t.ptSelectedCount(count),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          TextButton(
            key: const Key('photo-selection-all'),
            onPressed: all ? onClear : onSelectAll,
            child: Text(all ? t.ptClearSelection : t.ptSelectAll),
          ),
        ],
      ),
    );
  }
}

/// 多选模式下的底部批量操作条（P0-2）。
///
/// 五个官方能力一次到位：**下载 / 删除 / 收藏 / 加入相册 / 打标签**
/// （在相册内多出**移出相册**）。每个操作都以"成功 N / 失败 M"如实反馈，
/// **绝不静默失败**：
///   * `Browse.Item/delete` → `error_list`（无则整批失败算全失败）；
///   * `Browse.Item/set_favorite` → 整批错误码；
///   * `NormalAlbum/add_item` → `error_list`；`delete_item` 同；
///   * `add_tag`/`remove_tag` → `error_list`（`photoTagActionsProvider` 已汇总）；
///   * 批量下载 → `Download/download` + `force_download` + `item_id=[…]`（zip）。
class PhotoSelectionBar extends ConsumerWidget {
  const PhotoSelectionBar({
    super.key,
    required this.items,
    required this.space,
    this.albumId,
    required this.onClear,
    required this.onAddToAlbum,
    this.onSetCover,
    this.onRemoveSmart,
  });

  /// **已选中**的项（收藏状态也从这里读，决定按钮是"收藏"还是"取消收藏"）
  final List<FotoItemDto> items;
  final FotoSpace space;

  /// 在相册内浏览时有值 → 多一个"移出相册"
  final String? albumId;
  final VoidCallback onClear;
  final VoidCallback onAddToAlbum;

  /// P18/P19：人物/概念的**设封面**（官方 `set_cover`）。为空 ⇒ 不渲染按钮。
  final VoidCallback? onSetCover;

  /// P19：把选中照片**从该场景移除**（官方 `Concept/hide_item`）。
  final VoidCallback? onRemoveSmart;

  int get count => items.length;

  List<String> get _ids => [for (final e in items) e.id];

  /// 统一反馈：全成功 / 部分失败 / 全失败，三种都说清楚
  void _report(
    BuildContext context, {
    required int ok,
    required int fail,
    String? successText,
    String? failText,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    var text = fail == 0
        ? (successText ??
              photoP0Fill(
                PhotoP0TextKeys.batchResult,
                '成功 {ok} 项，失败 {fail} 项',
                {'ok': '$ok', 'fail': '0'},
              ))
        : ok == 0
        ? photoP0Fill(PhotoP0TextKeys.batchAllFailed, '全部失败（{fail} 项）', {
            'fail': '$fail',
          })
        : photoP0Fill(PhotoP0TextKeys.batchResult, '成功 {ok} 项，失败 {fail} 项', {
            'ok': '$ok',
            'fail': '$fail',
          });
    // 失败时把服务端原因**追加**在计数后面（而不是替换掉计数 —— 审计
    // 明确要求"显式成功/失败计数"）
    if (fail > 0 && failText != null) text = '$text\n$failText';
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _tag(BuildContext context, WidgetRef ref) async {
    final changed = await showPhotoTagSheet(context, ref, itemIds: _ids);
    if (changed) onClear();
  }

  Future<void> _favorite(BuildContext context, WidgetRef ref) async {
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) return;
    final t = context.t;
    // 全是收藏 → 这次是取消收藏；否则是收藏（官方多选栏的同一逻辑）
    final allFavorite = items.every((e) => e.isFavorite);
    final ids = _ids;
    try {
      await api.setFavorite(ids, !allFavorite);
      if (!context.mounted) return;
      _report(
        context,
        ok: ids.length,
        fail: 0,
        successText: allFavorite ? t.photoUnfavorited : t.photoFavorited,
      );
      onClear();
      ref.invalidate(photoTimelineProvider);
      ref.invalidate(photoFavoritesProvider);
      ref.invalidate(photoAlbumItemsProvider);
      ref.invalidate(photoFolderItemsProvider);
    } catch (err) {
      _report(
        context,
        ok: 0,
        fail: ids.length,
        failText: t.photoFavoriteFailed(describePhotoError(err, t)),
      );
    }
  }

  /// 批量评分（P40）—— 官方多选栏的 `dialog_set_ratings`。
  ///
  /// 选中的条目星级**一致**就用那个值当初始值，否则从「未评分」开始
  /// （绝不把某一项的星级冒充成整批的）。门控：能力位缺失时按钮不渲染。
  Future<void> _rating(BuildContext context, WidgetRef ref) async {
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null || !api.supportsRating) return;
    final initial = items.every((e) => e.rating == items.first.rating)
        ? items.first.rating
        : 0;
    final picked = await showPhotoRatingSheet(context, initial: initial);
    if (picked == null || !context.mounted) return;
    final ok = await setPhotoRating(
      context,
      ref,
      itemIds: _ids,
      rating: picked,
    );
    if (ok) onClear();
  }

  /// P52：发送到系统分享面板。
  ///
  /// 顺序：**先下载到本地**（`Download/download` 的原图字节），再交给
  /// [sharePhotoTargets]（`canShare` → `share`）。
  /// * 一条都没成功 ⇒ 明确失败提示，**不谎报成功**；
  /// * 桥不可用（桌面/未实现）⇒ 同样走失败提示（`unsupported` 会计数）。
  Future<void> _share(BuildContext context, WidgetRef ref) async {
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) return;
    final bridge = ref.read(photoShareBridgeProvider);
    final t = context.t;
    final dir = await ref.read(photoDownloadDirectoryProvider)();
    final targets = <PhotoShareTarget>[];
    var failed = 0;
    for (final it in items) {
      try {
        final bytes = await api.api.getBytes(api.downloadUrl(itemId: it.id));
        final file = File('${dir.path}/${it.filename}');
        await file.writeAsBytes(bytes);
        targets.add(
          PhotoShareTarget(
            path: file.path,
            name: it.filename,
            mime: mimeForFileName(it.filename),
          ),
        );
      } catch (_) {
        failed++;
      }
    }
    if (!context.mounted) return;
    if (targets.isEmpty) {
      _report(
        context,
        ok: 0,
        fail: items.length,
        failText: t.photoDownloadFailed(''),
      );
      return;
    }
    final out = await sharePhotoTargets(bridge: bridge, targets: targets);
    if (!context.mounted) return;
    _report(
      context,
      ok: out.shared,
      fail: failed + out.unsupported,
      successText: photoP0(PhotoP0TextKeys.shareDone, '已交给系统分享'),
    );
    if (out.shared > 0) onClear();
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) return;
    final t = context.t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(photoP0(PhotoP0TextKeys.deleteTitle, '删除所选项？')),
        content: Text(
          photoP0(
            PhotoP0TextKeys.deleteBody,
            '删除后会移入 DSM 回收站；能否还原取决于共享文件夹是否已启用回收站。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            key: const Key('photo-selection-delete-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.dtoActionDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!context.mounted) return;
    final ids = _ids;
    // P29：**延迟删除 + Snackbar 撤销**。
    //
    // 官方 `str_undo_success` 说明撤销要能把东西"恢复"；但 `SYNO.Foto` 没有回收站
    // 还原 API（P63 取证），所以唯一诚实的实现是"请求先不发"——窗口内撤销 ⇒
    // 一个字节都不发给 NAS；窗口到点才真删。详见 `photo_delete_undo.dart`。
    final grace = ref.read(photoDeleteGraceProvider);
    final messenger = ScaffoldMessenger.of(context);
    final outcome = ref.read(photoDeleteUndoProvider.notifier).begin(ids);
    onClear();
    messenger.showSnackBar(
      SnackBar(
        key: const Key('photo-delete-undo-snackbar'),
        duration: grace,
        content: Text(
          photoG1Fill(
            PhotoG1TextKeys.deleteUndoPending,
            '将在 {seconds} 秒后删除 {count} 项',
            {'seconds': '${grace.inSeconds}', 'count': '${ids.length}'},
          ),
        ),
        action: SnackBarAction(
          key: const Key('photo-delete-undo-action'),
          label: photoG1(PhotoG1TextKeys.deleteUndoAction, '撤销'),
          onPressed: () {
            if (ref.read(photoDeleteUndoProvider.notifier).undo()) {
              messenger.hideCurrentSnackBar();
              messenger.showSnackBar(
                SnackBar(
                  key: const Key('photo-delete-undone'),
                  content: Text(
                    photoG1(PhotoG1TextKeys.deleteUndone, '已撤销，未删除'),
                  ),
                ),
              );
            }
          },
        ),
      ),
    );
    final PhotoDeleteUndoResult result;
    try {
      result = await outcome;
    } catch (err) {
      if (!context.mounted) return;
      messenger.hideCurrentSnackBar();
      _report(
        context,
        ok: 0,
        fail: ids.length,
        failText: t.photoDeleteFailed(describePhotoError(err, t)),
      );
      return;
    }
    if (!context.mounted) return;
    // 撤销了 → 已经给过"已撤销"提示，不再报一次
    if (result.undone) return;
    // 结局出来了 → 顶掉"还有 N 秒"那条，直接给结果
    messenger.hideCurrentSnackBar();
    _report(
      context,
      ok: result.deletedCount,
      fail: result.failed.length,
      successText: photoP0Fill(PhotoP0TextKeys.deletedCount, '已删除 {count} 项', {
        'count': '${result.deletedCount}',
      }),
      failText: result.error != null
          ? describePhotoError(result.error!, t)
          : t.photoDeleteFailed('${result.failed.length}'),
    );
  }

  Future<void> _download(BuildContext context, WidgetRef ref) async {
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) return;
    final t = context.t;
    final ids = _ids;
    try {
      // 多张 → 服务端打 zip 回（`force_download` + `item_id=[…]`，官方 `iD`）
      final bytes = await api.api.getBytes(api.downloadManyUrl(itemIds: ids));
      if (!context.mounted) return;
      if (bytes.isEmpty) {
        // 服务端回空体（例如它打不了包的类型）→ **不落一个 0 字节的 zip**，
        // 如实说"没内容"，别让用户以为下载成功了。
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              photoP0(
                PhotoP0TextKeys.downloadZipEmpty,
                '服务端没有返回内容，这些照片可能无法打包下载',
              ),
            ),
          ),
        );
        return;
      }
      final dir = await ref.read(photoDownloadDirectoryProvider)();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.\-]'), '')
          .substring(0, 14);
      final name = 'photos_$stamp.zip';
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(bytes);
      if (!context.mounted) return;
      _report(
        context,
        ok: ids.length,
        fail: 0,
        successText: photoP0Fill(
          PhotoP0TextKeys.downloadZipReady,
          '已保存 {name}',
          {'name': name},
        ),
      );
      onClear();
    } catch (err) {
      if (!context.mounted) return;
      _report(
        context,
        ok: 0,
        fail: ids.length,
        failText: t.photoDownloadFailed(describePhotoError(err, t)),
      );
    }
  }

  Future<void> _removeFromAlbum(BuildContext context, WidgetRef ref) async {
    final album = albumId;
    if (album == null) return;
    final t = context.t;
    final ids = _ids;
    try {
      await ref.read(photoAlbumActionsProvider).removeItems(album, ids);
      if (!context.mounted) return;
      _report(
        context,
        ok: ids.length,
        fail: 0,
        successText: t.photoRemovedFromAlbum,
      );
      onClear();
    } catch (err) {
      if (!context.mounted) return;
      _report(
        context,
        ok: 0,
        fail: ids.length,
        failText: t.photoRemoveFailed(describePhotoError(err, t)),
      );
    }
  }

  /// 「移到文件夹 / 复制到文件夹」（`Browse.Item/move|copy`）。
  ///
  /// 目标形态见 `FotoApi.moveItems`：`id`（数字数组 JSON 串）+ `target_folder_id`
  /// （裸数字）+ `action`（`skip`/`overwrite`）。官方这条写操作的落点字段就是
  /// **目录**（`KEY_TARGET_ID = "target_folder_id"`），所以这里是"到文件夹"；
  /// 相册成员关系的写口是「加入相册」（`NormalAlbum/add_item`）。
  ///
  /// 失败逐条回报：`error_list` 有就按条算，没有则整批失败算全失败 —— 与既有
  /// 批量模型（[_report]）一致，绝不静默。
  Future<void> _moveCopy(
    BuildContext context,
    WidgetRef ref, {
    required bool move,
  }) async {
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) return;
    final t = context.t;
    final folders = await ref
        .read(photoFoldersProvider.future)
        .catchError((_) => <FotoFolderDto>[]);
    if (!context.mounted) return;
    final picked = await _pickTargetFolder(context, folders);
    if (picked == null || !context.mounted) return;
    final ids = _ids;
    try {
      final failed = move
          ? await api.moveItems(itemIds: ids, targetFolderId: picked.id)
          : await api.copyItems(itemIds: ids, targetFolderId: picked.id);
      if (!context.mounted) return;
      _report(
        context,
        ok: ids.length - failed.length,
        fail: failed.length,
        successText: move
            ? photoWave1Fill(PhotoWave1TextKeys.movedCount, '已移动 {count} 项', {
                'count': '${ids.length}',
              })
            : photoWave1Fill(PhotoWave1TextKeys.copiedCount, '已复制 {count} 项', {
                'count': '${ids.length}',
              }),
        failText: failed.isEmpty
            ? null
            : photoWave1Fill(
                PhotoWave1TextKeys.moveCopyFailed,
                '操作失败：{error}',
                {'error': '${failed.length}'},
              ),
      );
      onClear();
      ref.invalidate(photoTimelineProvider);
      ref.invalidate(photoFolderItemsProvider);
      ref.invalidate(photoFavoritesProvider);
    } catch (err) {
      if (!context.mounted) return;
      _report(
        context,
        ok: 0,
        fail: ids.length,
        failText: photoWave1Fill(
          PhotoWave1TextKeys.moveCopyFailed,
          '操作失败：{error}',
          {'error': describePhotoError(err, t)},
        ),
      );
    }
  }

  Future<FotoFolderDto?> _pickTargetFolder(
    BuildContext context,
    List<FotoFolderDto> folders,
  ) => showModalBottomSheet<FotoFolderDto>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DesignRowTile(
            title: Text(
              photoWave1(PhotoWave1TextKeys.moveCopyPickFolder, '选择目标文件夹'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            trailing: IconButton(
              tooltip: context.t.photoClose,
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          const Divider(height: 1),
          if (folders.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: Text(
                photoWave1(PhotoWave1TextKeys.moveCopyNoFolders, '没有可选择的文件夹'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: folders.length,
                itemBuilder: (context, i) => DesignRowTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(folders[i].name),
                  onTap: () => Navigator.of(context).pop(folders[i]),
                ),
              ),
            ),
          const SizedBox(height: Gap.xs),
        ],
      ),
    ),
  );

  /// AI 美化（图生图）：**V1 只支持单选**（多选置灰 + 说明，方案 §7.3
  /// "禁止多选 N 张并行：N 张必须串行、每张一次确认"，V1 直接只放 1 张）。
  Future<void> _aiEdit(BuildContext context, WidgetRef ref) async {
    if (count != 1) return;
    await showPhotoAiEditSheet(context, item: items.first);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final allFavorite = items.every((e) => e.isFavorite);
    // AI 美化：入口可见性同大图页（总开关 + 后端已配置）；并发中禁用；多选禁用
    final aiEditVisible = ref.watch(photoAiEditEntryVisibleProvider);
    final aiEditBusy = ref.watch(imageEditBusyProvider);
    final aiEditEnabled = count == 1 && !aiEditBusy;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(Radii.cut),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _BarButton(
                    buttonKey: const Key('photo-selection-download'),
                    icon: Icons.download_outlined,
                    label: photoP0(PhotoP0TextKeys.actionDownload, '下载'),
                    onPressed: () => _download(context, ref),
                  ),
                  // P52：发送到（系统分享面板）—— 先落到本地再交系统
                  _BarButton(
                    buttonKey: const Key('photo-selection-share'),
                    icon: Icons.ios_share_outlined,
                    label: photoP0(PhotoP0TextKeys.actionShare, '发送到'),
                    onPressed: () => _share(context, ref),
                  ),
                  _BarButton(
                    buttonKey: const Key('photo-selection-delete'),
                    icon: Icons.delete_outline,
                    label: context.t.dtoActionDelete,
                    onPressed: () => _delete(context, ref),
                  ),
                  _BarButton(
                    buttonKey: const Key('photo-selection-favorite'),
                    icon: allFavorite ? Icons.star : Icons.star_border,
                    label: allFavorite
                        ? photoP0(PhotoP0TextKeys.actionUnfavorite, '取消收藏')
                        : photoP0(PhotoP0TextKeys.actionFavorite, '收藏'),
                    onPressed: () => _favorite(context, ref),
                  ),
                  _BarButton(
                    buttonKey: const Key('photo-selection-album'),
                    icon: Icons.add_photo_alternate_outlined,
                    label: photoP0(PhotoP0TextKeys.actionAddToAlbum, '加入相册'),
                    onPressed: onAddToAlbum,
                  ),
                  if (onSetCover != null)
                    _BarButton(
                      buttonKey: const Key('photo-selection-set-cover'),
                      icon: Icons.photo_camera_front_outlined,
                      label: photoP0(PhotoP0TextKeys.actionSetCover, '设为封面'),
                      onPressed: onSetCover!,
                    ),
                  if (onRemoveSmart != null)
                    _BarButton(
                      buttonKey: const Key('photo-selection-remove-smart'),
                      icon: Icons.visibility_off_outlined,
                      label: photoP0(
                        PhotoP0TextKeys.actionRemoveSmart,
                        '从该场景移除',
                      ),
                      onPressed: onRemoveSmart!,
                    ),
                  _BarButton(
                    buttonKey: const Key('photo-selection-tag'),
                    icon: Icons.sell_outlined,
                    label: context.t.ptTag,
                    onPressed: () => _tag(context, ref),
                  ),
                  if (aiEditVisible)
                    _BarButton(
                      buttonKey: const Key('photo-selection-ai-edit'),
                      icon: Icons.auto_fix_high,
                      label: photoAiEdit(
                        PhotoAiEditTextKeys.entryTitle,
                        'AI 美化',
                      ),
                      tooltip: aiEditEnabled
                          ? null
                          : photoAiEdit(
                              PhotoAiEditTextKeys.singleOnly,
                              'AI 美化一次只能处理 1 张，请只选 1 张',
                            ),
                      onPressed: aiEditEnabled
                          ? () => _aiEdit(context, ref)
                          : null,
                    ),
                  // 置灰时把原因**写出来**（不只靠 tooltip，避免"点了没反应"）
                  if (aiEditVisible && !aiEditEnabled)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
                      child: Text(
                        photoAiEdit(
                          PhotoAiEditTextKeys.singleOnly,
                          'AI 美化一次只能处理 1 张，请只选 1 张',
                        ),
                        key: const Key('photo-selection-ai-edit-hint'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  if (albumId != null)
                    _BarButton(
                      buttonKey: const Key('photo-selection-remove'),
                      icon: Icons.playlist_remove,
                      label: photoP0(
                        PhotoP0TextKeys.actionRemoveFromAlbum,
                        '移出相册',
                      ),
                      onPressed: () => _removeFromAlbum(context, ref),
                    ),
                  // `Browse.Item/move|copy`（目标 = 照片文件夹；见 [_moveCopy]）。
                  // 放在**末尾**：不改变既有按钮顺序（横向滚动条里老按钮位置不变）。
                  _BarButton(
                    buttonKey: const Key('photo-selection-move'),
                    icon: Icons.drive_file_move_outlined,
                    label: photoWave1(PhotoWave1TextKeys.moveToFolder, '移到文件夹'),
                    onPressed: () => _moveCopy(context, ref, move: true),
                  ),
                  _BarButton(
                    buttonKey: const Key('photo-selection-copy'),
                    icon: Icons.copy_all_outlined,
                    label: photoWave1(
                      PhotoWave1TextKeys.copyToFolder,
                      '复制到文件夹',
                    ),
                    onPressed: () => _moveCopy(context, ref, move: false),
                  ),
                  // 评分（P40）：官方多选栏的 `dialog_set_ratings`。
                  // 服务端能力位缺失（`Browse.Item` maxVersion < 2）→ 不渲染。
                  if (ref.watch(fotoSpaceApiProvider)?.supportsRating ?? false)
                    _BarButton(
                      buttonKey: const Key('photo-selection-rating'),
                      icon: Icons.star_outline,
                      label: context.t.asRating,
                      onPressed: () => _rating(context, ref),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: Gap.sm),
          Text(
            context.t.ptSelectedCount(count),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.primary),
          ),
          const SizedBox(width: Gap.sm),
        ],
      ),
    );
  }
}

/// 批量操作条上的一个按钮（图标 + 文字，紧凑）。
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tooltip,
  });

  final Key buttonKey;
  final IconData icon;
  final String label;

  /// `null` = 置灰（**不是隐藏**）：调用方必须同时给 [tooltip] 说明原因
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = TextButton.icon(
      key: buttonKey,
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
    final hint = tooltip;
    if (hint == null || hint.isEmpty) return button;
    return Tooltip(message: hint, child: button);
  }
}

/// 相册网格：默认列数来自**用户选的密度**（P4），每格 1:1，点开看大图（或进入多选）。
class PhotoGrid extends ConsumerWidget {
  const PhotoGrid({
    super.key,
    required this.items,
    required this.space,
    required this.onTap,
    this.size = 'sm',
    this.columns,
    this.padding = const EdgeInsets.all(Gap.xs),
    this.sliver = false,
    this.selecting = false,
    this.selectedIds = const {},
    this.onLongPress,
  });

  final List<FotoItemDto> items;
  final FotoSpace space;

  /// `sm`（网格）/ `m`（详情缩略）/ `xl`（大图原图）
  final String size;

  /// 显式列数；**null = 用 [photoGridColumnsProvider] 的用户密度档**。
  ///
  /// 相册各处（时间轴/相册/收藏/人物/共享/条件相册…）都走 [PhotoGrid]，把
  /// 密度收在这里就不会漏掉某一页 —— 官方的 `segment_view_mode` 也是全局生效。
  final int? columns;
  final void Function(int index) onTap;
  final EdgeInsets padding;

  /// true → 作为 sliver 用在 `CustomScrollView` 里
  final bool sliver;

  /// 多选模式：格子右上角画勾选圈
  final bool selecting;

  /// 已选中的 item id（[selecting] 为 true 时决定勾没勾）
  final Set<String> selectedIds;

  /// 长按回调（进入多选用）
  final void Function(int index)? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int resolvedColumns = columns ?? ref.watch(photoGridColumnsProvider);
    final grid = SliverGrid.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: resolvedColumns,
        mainAxisSpacing: Gap.xs,
        crossAxisSpacing: Gap.xs,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) => PhotoCell(
        item: items[i],
        space: space,
        size: size,
        selecting: selecting,
        selected: selectedIds.contains(items[i].id),
        onTap: () => onTap(i),
        onLongPress: onLongPress == null ? null : () => onLongPress!(i),
      ),
    );
    if (sliver) return SliverPadding(padding: padding, sliver: grid);
    return GridView.custom(
      padding: padding,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: resolvedColumns,
        mainAxisSpacing: Gap.xs,
        crossAxisSpacing: Gap.xs,
      ),
      childrenDelegate: SliverChildBuilderDelegate(
        (context, i) => PhotoCell(
          item: items[i],
          space: space,
          size: size,
          selecting: selecting,
          selected: selectedIds.contains(items[i].id),
          onTap: () => onTap(i),
          onLongPress: onLongPress == null ? null : () => onLongPress!(i),
        ),
        childCount: items.length,
      ),
    );
  }
}

/// 网格里的一格（缩略图 + 点开大图 / 多选勾选）。**所有网格都走它**，
/// 保证"不透明底色 + 字节缩略图 + 圆角 + 多选勾选圈"只有一处实现。
class PhotoCell extends StatelessWidget {
  const PhotoCell({
    super.key,
    required this.item,
    required this.space,
    required this.onTap,
    this.size = 'sm',
    this.selecting = false,
    this.selected = false,
    this.onLongPress,
  });

  final FotoItemDto item;
  final FotoSpace space;
  final VoidCallback onTap;
  final String size;

  /// 多选模式（长按进入后为 true）
  final bool selecting;
  final bool selected;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final thumb = ClipRRect(
      borderRadius: BorderRadius.circular(Radii.cut),
      child: PhotoThumb(
        request: photoThumbRequest(item, space, size: size),
        isVideo: item.isVideo,
        // 视频：给抽帧层拿到 item（直链 / 缓存键都从它来），见 photoVideoFrameRequest。
        videoItem: item.isVideo ? item : null,
        showFavorite: item.isFavorite && !selecting,
        // P16：RAW/AVIF/HEIC 的缩略图兜底要按**扩展名**给解释
        filename: item.filename,
      ),
    );
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          thumb,
          if (selecting) ...[
            if (selected)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.28),
                  borderRadius: BorderRadius.circular(Radii.cut),
                ),
              ),
            Positioned(
              right: 4,
              top: 4,
              child: Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 20,
                color: selected ? scheme.primary : Colors.white70,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 白色半透明胶囊（相册页顶部分段用）。
/// 分段切换（时间轴 / 相册 / 文件夹 / 收藏 / 人物 / 场景）。
///
/// ★ 第 237 轮（`DA181`，用户裁定 ③）：**选中段必须在可视区内**。
///   原来是纯 `SingleChildScrollView` + `Row`，没有任何"滚到选中项"的逻辑：
///   真机上点最后一项「人物」时，那一颗胶囊被屏幕右缘**切掉一半**（文字只剩「Peop」）。
///   现在用 `ScrollController` + 每颗一个 `GlobalKey`，在选中变化时
///   `Scrollable.ensureVisible(alignment: 0.5)` 把它居中对齐。
class PhotoSegment extends StatefulWidget {
  const PhotoSegment({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  State<PhotoSegment> createState() => _PhotoSegmentState();
}

class _PhotoSegmentState extends State<PhotoSegment> {
  final ScrollController _scroll = ScrollController();
  final List<GlobalKey> _keys = [];

  @override
  void initState() {
    super.initState();
    _syncKeys();
    _scheduleEnsureVisible();
  }

  @override
  void didUpdateWidget(covariant PhotoSegment old) {
    super.didUpdateWidget(old);
    _syncKeys();
    if (old.index != widget.index || old.labels.length != widget.labels.length) {
      _scheduleEnsureVisible();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _syncKeys() {
    while (_keys.length < widget.labels.length) {
      _keys.add(GlobalKey());
    }
  }

  /// 等这一帧布局完再滚：首帧 `currentContext` 才有尺寸。
  void _scheduleEnsureVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final i = widget.index.clamp(0, _keys.length - 1);
      final ctx = _keys.isEmpty ? null : _keys[i].currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // ★ 第 232 轮（用户裁定 ③「亮色与暗色同等精细」/ `DA176`）：
    //   选中胶囊原来是 `scheme.primary` 文字压在 `scheme.primary` 的 **16% 透明**底上，
    //   而底下是页面底色 ⇒ 实际合成出来的底比 `primaryContainer` 暗一档：
    //   真机量到 **4.42:1**（亮色）/ 4.36:1（暗色），都低于 AA。
    //   现在改成**不透明** `primarySoft` 底 + `primary` 文字（两者由
    //   `design_contrast_symmetry_test` 保证 ≥ 4.5，动态取色还会再做一次钳制）。
    final p = DesignPalette.of(context);
    return SingleChildScrollView(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      child: Row(
        children: [
          for (var i = 0; i < widget.labels.length; i++)
            Padding(
              key: _keys[i],
              padding: const EdgeInsets.only(right: Gap.sm),
              child: Material(
                color: i == widget.index
                    ? p.primarySoft
                    : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(Radii.capsule),
                child: InkWell(
                  borderRadius: BorderRadius.circular(Radii.capsule),
                  onTap: () => widget.onChanged(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Gap.md,
                      vertical: 7,
                    ),
                    child: Text(
                      widget.labels[i],
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: i == widget.index ? p.primary : p.muted,
                        fontWeight: i == widget.index
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 相册 / 文件夹的封面格子（列表用）。
class PhotoAlbumTile extends StatelessWidget {
  const PhotoAlbumTile({
    super.key,
    required this.title,
    this.subtitle,
    this.coverUrl,
    this.coverRequest,
    this.onTap,
    this.onLongPress,
    this.iconFallback = Icons.photo_album_outlined,
  });

  final String title;
  final String? subtitle;

  /// 兼容旧用法：直接给一个**相册封面请求**（推荐）
  final PhotoThumbRequest? coverRequest;

  /// 已废弃：以前是网络地址（自签证书下不工作）
  @Deprecated('用 coverRequest（走鉴权字节链路）')
  final String? coverUrl;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final IconData iconFallback;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Gap.md),
              child: coverRequest == null
                  ? ColoredBox(
                      color: hud.bg,
                      child: Icon(iconFallback, color: hud.dim),
                    )
                  : PhotoThumb(request: coverRequest),
            ),
          ),
          const SizedBox(height: Gap.xs),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (subtitle != null)
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: hud.dim),
            ),
        ],
      ),
    );
  }
}

/// 统一的加载 / 错误 / 空态包装（相册各页共用）。
class PhotoAsync<T> extends StatelessWidget {
  const PhotoAsync({
    super.key,
    required this.value,
    required this.builder,
    required this.emptyTitle,
    this.emptyMessage,
    this.emptyIcon = Icons.photo_library_outlined,
    this.onRetry,
    this.isEmpty,
  });

  final AsyncValueLike<T> value;
  final Widget Function(T data) builder;
  final String emptyTitle;
  final String? emptyMessage;
  final IconData emptyIcon;
  final VoidCallback? onRetry;
  final bool Function(T data)? isEmpty;

  @override
  Widget build(BuildContext context) {
    if (value.hasError) {
      return AppEmptyState(
        icon: Icons.error_outline,
        title: context.t.photoLoadFailed,
        message: describePhotoError(value.error!, context.t),
        actionLabel: onRetry == null ? null : context.t.photoRetry,
        onAction: onRetry,
      );
    }
    final data = value.dataOrNull;
    if (data == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (isEmpty?.call(data) ?? false) {
      return AppEmptyState(
        icon: emptyIcon,
        title: emptyTitle,
        message: emptyMessage,
      );
    }
    return builder(data);
  }
}

/// 只用到 `hasError` / `dataOrNull` 这两个能力，抽个小接口方便单测直接构造。
abstract class AsyncValueLike<T> {
  bool get hasError;
  Object? get error;
  T? get dataOrNull;
}

/// `AsyncValue` 适配。
///
/// ⚠️ 别用 `_value.hasError` / `_value.error` 这种写法：Riverpod 3 里
/// `hasError` **只在 `AsyncError` 上有**（`AsyncLoading` 上没有这个 getter），
/// 用 `dynamic` 调用会直接 `NoSuchMethodError` 炸在 build 里（相册页第一版
/// 就是这么白屏的）。这里老老实实按类型判断。
class RiverpodAsync<T> implements AsyncValueLike<T> {
  const RiverpodAsync(this._value);

  final AsyncValue<T> _value;

  @override
  bool get hasError => _value is AsyncError<T>;

  @override
  Object? get error => _value is AsyncError<T> ? _value.error : null;

  @override
  T? get dataOrNull => _value is AsyncData<T> ? _value.value : null;
}
