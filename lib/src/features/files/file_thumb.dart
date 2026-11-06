// 文件缩略图（P0.1）。
//
// 三种状态都要"好看且不闪"：
//   * 有图 → 按 `ChamferBorder` 切角裁剪后显示（与列表行的观感一致）
//   * 没图/失败/还没加载好 → 退回原来的分类图标（[fileIconFor]）
//   * 不该有缩略图的（文件夹、压缩包、文本…）→ 直接图标，**不发请求**
//
// 只对"服务端真会给缩略图"的类型请求：**只有图片**。其余类型请求了也是
// 白跑一趟（还占并发名额），所以由 [showsFileThumbnail] 先挡掉。
//
// ⚠️ **视频走的是"自研抽帧"，不是服务端缩略图**（第 260/261 轮真机实测推翻旧说法）：
// `SYNO.FileStation.Thumb` 对视频恒 `404 + 11939B HTML`、Drive `get_thumbnail`
// 对视频恒 `400 + 0 字节`、`SYNO.Office.Video.Thumb` 也出不了图。
// 所以视频在这里的分支顺序是：**内嵌海报**（文件自带 `covr`）→
// **本机抽首帧**（[videoFrameThumbProvider]，只下 6 MiB 头部）→ 图标；
// **永远不会**为视频去发那个注定 404 的服务端请求。
//
// ⚠️ PDF **不在**这里：真机验证过 `SYNO.FileStation.Thumb.get` 对 PDF 回
// 404 + 一页 11.9KB 的 HTML 错误页（同目录图片 200 带真 JPEG）。PDF 和电子书
// 的封面走**客户端自己出图**那条路（[showsBookCover] + [bookCoverProvider]）。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/media/aspect_image.dart';
import '../../core/media/image_size.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/file_entry_dto.dart';
import '../../data/office_api.dart' show kOfficeSnapshotApi;
import '../../data/office_native/office_native_reader.dart'
    show OfficeNativeDocument, OfficeNativeFormat, OfficeNativeReader;
import '../media/media_cover.dart'
    show mediaCoverRequestFor, normalizeMediaExtension;
import '../media/media_cover_provider.dart';
import '../media/media_source.dart'
    show MediaKind, driveFileIdOf, resolveEntryMediaSource;
import '../media/video_frame_thumb.dart'
    show
        VideoFrameThumbRequest,
        kVideoFrameContainers,
        videoFrameThumbProvider,
        videoFrameThumbRequestFor,
        videoFrameThumbSupported;
import '../office/office_doc_thumb.dart';
import 'drive_providers.dart' show driveApiProvider;
import 'file_providers.dart';
import 'folder_cover.dart';
import 'file_row.dart' show fileIconFor;
import 'office_providers.dart' show officeApiProvider;
import 'office_viewer_page.dart'
    show
        OfficeNativeReadRequest,
        officeDrivePathForFileStationPath,
        officeNativeReadProvider;

/// Office 缩略图"取模型"用的一层 **keepAlive 包装**。
///
/// ★ 为什么非要这一层（第 261 轮真机排查，logcat 逐字）：
/// `officeNativeReadProvider` 是 `FutureProvider.autoDispose.family`，而缩略图任务
/// 是在 `OfficeDocThumb` 的**异步回调**里跑的 —— 那里**没有 watcher**。
/// Riverpod 对"只被 `read`、没人 `listen`"的 autoDispose provider 会**当帧就销毁**，
/// 于是异步回调里拿到的是**已销毁的 Ref**：
///
/// ```
/// Cannot use the Ref of FutureProvider<OfficeNativeDocument>#f0953
/// (Instance of 'OfficeNativeReadRequest') after it has been disposed.
/// ```
///
/// 后果：**8 个 office 行全部在 1 秒内"失败"**，界面只剩分类图标（看起来像
/// "功能没做"，其实是取模型那一跳被自己拆掉了）。真机像素证据 +
/// `[officeThumb] FETCH-FAIL` 日志都指向这一条。
///
/// 修法：包装成 keepAlive，**只在这一个任务存活期间**钉住（`whenComplete` 就放），
/// 既不泄漏内存，也不让抽屉式列表把正在跑的任务销毁。
final officeThumbModelProvider =
    FutureProvider.family<OfficeNativeDocument, OfficeNativeReadRequest>((
      ref,
      req,
    ) {
      final link = ref.keepAlive();
      return ref
          .watch(officeNativeReadProvider(req).future)
          .whenComplete(link.close);
    });

/// 这个条目要不要去要缩略图？
///
/// 图片/视频/PDF 是 DSM 会给缩略图的类型；文件夹和压缩包之类不给。
bool showsFileThumbnail(FileEntryDto e) {
  if (e.isDir) return false;
  return switch (e.extension) {
    'jpg' ||
    'jpeg' ||
    'png' ||
    'gif' ||
    'webp' ||
    'bmp' ||
    'heic' ||
    'heif' ||
    'mp4' ||
    'mov' ||
    'mkv' ||
    'avi' ||
    'webm' ||
    'm4v' => true,
    _ => false,
  };
}

/// 这个文件的**原图字节客户端解不了**，只能靠服务端缩略图转码成 JPEG。
///
/// HEIC/HEIF 就在这一档：`showsFileThumbnail` 与 `filePreviewKind` 都把它当图片
/// 声明（白名单里有），但 Flutter 的 `Image.memory` **不认** HEIC —— 直接拿原图
/// 字节喂解码器只会报解码异常。所以要求是：
///   * 缩略图 / 预览**必须**走服务端 `SYNO.FileStation.Thumb`（回的是 JPEG，
///     自然通过 [looksLikeImage]）；
///   * 服务端给不出（能力位缺失 / 404 / 200+HTML）时，**明确说"解不开"**，
///     不能静默退回分类图标 —— 那等于"声明支持、实际不可用"地骗用户。
const Set<String> kServerDecodedImageExtensions = {'heic', 'heif'};

bool needsServerDecodedImage(String extension) =>
    kServerDecodedImageExtensions.contains(extension.toLowerCase());

/// 缩略图尺寸档（对应 `SYNO.FileStation.Thumb` 的 `size`）
enum ThumbScale {
  /// 列表行里的小图
  small,

  /// 网格视图
  medium,

  /// 大图（预览页的过渡图）
  large;

  String get apiValue => switch (this) {
    ThumbScale.small => 'small',
    ThumbScale.medium => 'medium',
    ThumbScale.large => 'large',
  };

  /// 给 `Image` 的解码宽度上限。
  ///
  /// 网格里几十张 2MB 的图如果都按原尺寸解码，滚动会明显掉帧；
  /// 列表行只需要 40dp（≈120px @3x）。
  int get decodeWidth => switch (this) {
    ThumbScale.small => 160,
    ThumbScale.medium => 512,
    ThumbScale.large => 1600,
  };
}

/// 书封没有可读比例时的兜底宽高比（≈ 2:3 的trade paperback / 大多数电子书封面）。
const double kBookCoverAspect = 0.70;

/// 比例的合理区间：比 0.45 更窄或比 0.95 更宽的"封面"基本是解析出错或裁切图，
/// 真按它摆会让列表参差不齐，所以夹住。
const double kBookCoverMinAspect = 0.45;
const double kBookCoverMaxAspect = 0.95;

/// Office 三格式缩略图的**离屏渲染器注入点**（生产 = null ⇒ [OfficeDocThumb]
/// 用真实离屏渲染器，行为与不接这个 provider 完全一致）。
///
/// 存在的唯一理由：[OfficeDocThumb.renderer] 没有别的注入途径，而 widget 测试里
/// `RenderRepaintBoundary.toImage()` 是**引擎异步**、在假时钟下不会完成 ⇒
/// 离线用例必须能把它换成一个"直接回字节"的假渲染器。
final officeThumbRendererProvider = Provider<OfficeThumbPngRenderer?>(
  (ref) => null,
);

/// 一个文件缩略图。用 [entry] 的 mtime/size 做缓存键，所以文件被覆盖后自动刷新。
///
/// **形状**（这一条是用户提的）：
///   * 图片/视频：方形（`BoxFit.cover` 裁切）—— 这是 DSM 相册/文件列表的习惯；
///   * 电子书/PDF **封面：按真实比例竖着摆**。书的封面不是正方形，塞进方框里
///     就得裁掉两侧（实测服务端的 `Thumb.get` 其实返回**原比例**图片，方框纯粹是
///     我们 UI 的做法，所以完全可以按图书封面标准来）。
class FileThumb extends ConsumerWidget {
  const FileThumb({
    super.key,
    required this.entry,
    this.scale = ThumbScale.small,
    this.size = 40,
    this.radius = 11,
    this.iconSize = 20,
    this.fit = BoxFit.cover,
    this.showUnavailableReason = false,
  });

  final FileEntryDto entry;
  final ThumbScale scale;

  /// "服务端缩略图不可用"时，除了占位图标是否**再显示一句话原因**。
  ///
  /// 列表行只有 40dp，塞不下文字（会 overflow）→ 默认 false，这时原因走
  /// [FileIconTile.reason] 的 Tooltip/Semantics；预览页空间够 → true。
  final bool showUnavailableReason;

  /// 控件边长
  final double size;
  final double radius;
  final double iconSize;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fallback = FileIconTile(
      entry: entry,
      size: size,
      iconSize: iconSize,
      chamfer: radius <= 10 && size >= 36,
      radius: radius,
    );

    // 文件夹：服务端不给封面（真机实测 `Thumb.get` 对目录 404 + HTML），
    // 用里面的图在客户端拼个小九宫格（见 `folder_cover.dart`）
    if (entry.isDir) {
      final shots = ref
          .watch(folderCoverProvider(FolderCoverRequest.of(entry)))
          .value;
      if (shots == null || shots.isEmpty) return fallback;
      return FolderCoverMosaic(images: shots, size: size, radius: radius);
    }

    // 音频/视频：**内嵌封面优先**（文件自带的专辑封面/海报）。
    // 只在 FileStation 直链上取（Drive 写死 `Accept-Ranges: none` → 不取，
    // 免得为了列表里一张小图把整个视频下载下来），且只发 Range 片段请求。
    final coverKey = _embeddedCoverKey(ref, entry);
    if (coverKey != null) {
      final cover = ref.watch(mediaCoverProvider(coverKey)).value;
      if (cover != null && looksLikeImage(cover.bytes)) {
        return _imageTile(cover.bytes, false, fallback);
      }
    }

    // 视频：服务端**没有**视频缩略图（真机 404，见文件头），改用本机抽首帧。
    // 走到这里说明"文件自带海报"那条也没出图。
    // 顺序上必须在服务端缩略图之前 —— 否则每行视频都会白发一个注定 404 的请求。
    if (!entry.isDir && _isVideoContainer(entry.extension)) {
      final req = _videoFrameRequest(ref, entry);
      // `supported == false`（后缀不在白名单 / 拿不到直链 / Drive 又不支持 Range
      // 且大小未知或超上限）⇒ **连请求都不发**，直接占位图标。
      if (videoFrameThumbSupported(req)) {
        final bytes = ref.watch(videoFrameThumbProvider(req!)).value;
        if (bytes != null && looksLikeImage(bytes)) {
          return _imageTile(bytes, false, fallback);
        }
      }
      // 抽帧失败 / 做不了 / 还没抽好：**都是图标**，绝不回落到服务端请求。
      // （失败记忆在 provider 里，10 分钟内不会再试，所以滚动不会反复下头部。）
      return fallback;
    }

    // Office 三格式（`.odoc` / `.osheet` / `.oslides`）：服务端**没有**缩略图
    // 通道（真机：`FileStation.Thumb` 恒 404 + 11939B HTML、Drive `get_thumbnail`
    // 恒 400 + 0 字节），只能客户端离屏渲染第一页 —— 实现见
    // `features/office/office_doc_thumb.dart`（自带缓存 / 限流 / 超时 / 兜底）。
    //
    // 必须放在**服务端缩略图之前**：否则每一行 office 都会白发一个注定 404 的
    // 请求，还把并发名额占掉（与上面视频分支同一个道理）。
    final officeFormat = entry.isDir
        ? null
        : OfficeNativeReader.formatForFileName(entry.name);
    if (officeFormat != null) {
      return _officeThumbTile(ref, officeFormat, fallback);
    }

    // 电子书/PDF：服务端不给缩略图，封面由客户端出（解析包 / 渲第一页）
    final isBook = showsBookCover(entry);
    if (!isBook && !showsFileThumbnail(entry)) return fallback;

    // Riverpod 3 的 AsyncValue：取值统一用 `value`（data 之外都是 null）
    final thumb = isBook
        ? ref.watch(bookCoverProvider(BookCoverRequest.of(entry)))
        : ref.watch(fileThumbProvider(FileThumbRequest.of(entry, scale)));
    final bytes = thumb.value;
    if (bytes != null && looksLikeImage(bytes)) {
      return _imageTile(bytes, isBook, fallback);
    }
    // 服务端 200 回 HTML / 404 / 空 → 不喂 `Image.memory`（会抛解码异常）。
    //
    // 但对"客户端解不了、只能靠服务端转码"的图片（HEIC/HEIF），静默退回分类图标
    // 等于"声明支持、实际不可用" —— 必须给带原因的明确占位。
    final serverOnly =
        needsServerDecodedImage(entry.extension) ||
        (bytes != null && bytes.isNotEmpty && looksLikeHeic(bytes));
    if (serverOnly && !thumb.isLoading) {
      return FileThumbUnavailable(
        key: const Key('file-thumb-server-required'),
        entry: entry,
        size: size,
        iconSize: iconSize,
        radius: radius,
        showReason: showUnavailableReason,
      );
    }
    return fallback;
  }

  /// Office 三格式的缩略图格子：交给 [OfficeDocThumb] 离屏渲染第一页。
  ///
  /// ## 档位
  /// 列表/网格行用 [OfficeThumbSize.list]（宽 96dp，按格式比例算高）；
  /// 大格子/预览（`medium`/`large`）用 [OfficeThumbSize.card]（宽 320dp）。
  /// 渲染尺寸与显示尺寸**解耦**：`OfficeDocThumb` 内部按档位逻辑尺寸构图 + 按
  /// `pixelRatio` 出物理像素，外面这个 `size × size` 的紧框只负责"列表行高对齐"
  /// （与 [_imageTile] 的做法一致，不给框就会撑破 `Row`）。
  ///
  /// ## 失败 / 渲染中
  /// [OfficeDocThumb.fallback] 与 `.placeholder` 都传现有 [fallback]（分类图标）⇒
  /// 绝不空白、绝不挂住。渲染失败会进 [OfficeThumbCache] 的失败记忆，滚动不会
  /// 反复重渲染同一个坏文档。
  Widget _officeThumbTile(
    WidgetRef ref,
    OfficeNativeFormat format,
    Widget fallback,
  ) {
    // 能力位 `SYNO.Office.Snapshot`：不在能力表里 ⇒ 第一跳跳过（服务只降级成
    // 低保真字节/文本路径，不隐藏模块）；能力表未拿到（null）⇒ fail-open。
    // 取法与 `office_viewer_page.dart` 的预览页**逐字一致**，不另发明一套。
    final snapshotApiPresent =
        ref.watch(officeApiProvider)?.api.apiTable?.containsKey(
          kOfficeSnapshotApi,
        ) ??
        true;
    // Drive 视角路径（`/home/Drive/x` → `/mydrive/x`）：统一走 My Drive 的高保真
    // `Snapshot:get` 那一跳（用户 2026-09-25 裁决）。团队文件夹/共享目录未取证 ⇒
    // `null`，**不猜**（回落字节/文本跳）。
    final drivePath = officeDrivePathForFileStationPath(entry.path);
    // File Station 真实路径的原生字节直链（可能为 null：未连接 / Drive 条目）。
    final nativeBytesUrl = ref.watch(fileApiProvider)?.downloadUrl([entry.path]);

    final request = OfficeThumbRequest(
      sourceKey: entry.path,
      versionStamp: officeThumbVersionStamp(
        mtimeSec: entry.mtime > 0 ? entry.mtime : null,
        sizeBytes: entry.size > 0 ? entry.size : null,
      ),
      format: format,
      size: scale == ThumbScale.small
          ? OfficeThumbSize.list
          : OfficeThumbSize.card,
    );

    final thumb = OfficeDocThumb(
      key: const Key('file-thumb-office'),
      request: request,
      // 生产 = 真离屏渲染；测试用 provider 注入假渲染器（见该 provider 的注释）。
      renderer: ref.watch(officeThumbRendererProvider),
      fetchModel: (req) {
        final readReq = OfficeNativeReadRequest(
          entryPath: entry.path,
          format: format,
          drivePath: drivePath,
          nativeBytesUrl: nativeBytesUrl,
          snapshotApiPresent: snapshotApiPresent,
        );
        // 诊断（第 261 轮真机排查）：把"取模型"这一跳的异常打出来。
        // ★ 必须走 [officeThumbModelProvider]（keepAlive 包装），
        // 直接 `read(officeNativeReadProvider(...))` 会被 autoDispose 当帧销毁。
        return ref
            .read(officeThumbModelProvider(readReq).future)
            .catchError((Object e, StackTrace st) {
              debugPrint('[officeThumb] FETCH-FAIL entry=${entry.path} error=$e');
              debugPrint('$st');
              throw e;
            });
      },
      // ★ 真机实测（第 261 轮）：任务里含**两跳 NAS 往返** + 解析 + 光栅化，
      // 默认 1800ms 在真机上几乎必然超时 ⇒ office 行永远是分类图标。
      // 列表场景放宽到 12s（渲染是异步的，占位期间不阻塞滚动）。
      timeout: const Duration(seconds: 12),
      fallback: fallback,
      // ⚠️ `placeholder` **故意不传** = 用组件的骨架底色：
      // 之前把 `fallback` 同时当占位 ⇒ "渲染中"和"渲染失败"长得一模一样，
      // 真机上根本分不出是慢还是坏（我第 261 轮就因此误判过一次）。
      // 现在：骨架 = 还在渲染，分类图标 = 确实失败。
    );

    // 与 [_imageTile] 同样的切角/圆角，保持列表行观感一致；
    // 外层紧框让"96×128 的 odoc 缩略图"在 40dp 行里也不会撑破布局。
    final box = SizedBox(width: size, height: size, child: thumb);
    if (radius <= 10 && size >= 36) {
      return ClipPath(
        clipper: const ShapeBorderClipper(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(11)),
          ),
        ),
        child: box,
      );
    }
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: box);
  }

  /// 把一张已校验过的图按"书封 / 普通图"两种形状摆好。
  ///
  /// 内嵌封面也走这里（`isBook = false`）：音频/视频的封面按真实比例摆。
  Widget _imageTile(Uint8List bytes, bool isBook, Widget fallback) {
    // 书封：高度与其它缩略图一致，宽度按封面自己的比例算，**不裁切**。
    // 外层仍然是 `size × size` 的方框（居中），所以列表里左边距照样对齐、
    // 行高也不会因为某行是书就变高 —— 看起来就是书架上的一本书。
    if (isBook) {
      final pixels = imageSizeFromBytes(bytes);
      final raw = (pixels == null || pixels.height == 0)
          ? kBookCoverAspect
          : pixels.width / pixels.height;
      final aspect = raw.clamp(kBookCoverMinAspect, kBookCoverMaxAspect);
      final bookRadius = (size * 0.06).clamp(2.0, 8.0);
      return SizedBox(
        width: size,
        height: size,
        child: AspectImage(
          aspect: aspect,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(bookRadius),
              border: Border.all(
                color: Colors.black.withValues(alpha: 0.12),
                width: 0.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.16),
                  blurRadius: 3,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(bookRadius),
              child: Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: scale.decodeWidth,
                errorBuilder: (_, _, _) => fallback,
              ),
            ),
          ),
        ),
      );
    }

    // 图片/视频：**按真实比例摆，不裁切**。
    // 服务端给的就是原比例（实测见 `docs/book-covers-and-pdf-toc.md` §1.5），
    // 以前套 `width/height = size` + `BoxFit.cover` 会把 16:9 的照片砍上下、
    // 把手机截图砍掉一大半。比例读不出来（HEIC/坏字节）→ 退 `contain`，也不裁。
    final aspect = aspectOfImageBytes(bytes);
    // ⚠️ 必须显式给 `size × size` 的框：`Image` 自己会按**固有尺寸**铺开，
    // 而列表行那边是 `Row`（宽度无界）—— 不给框就会撑破行（真踩过）。
    final image = SizedBox(
      width: size,
      height: size,
      child: AspectImage(
        aspect: aspect,
        child: Image.memory(
          bytes,
          fit: aspect == null ? BoxFit.contain : BoxFit.cover,
          gaplessPlayback: true,
          cacheWidth: scale.decodeWidth,
          errorBuilder: (_, _, _) => fallback,
        ),
      ),
    );
    if (radius <= 10 && size >= 36) {
      return ClipPath(
        clipper: const ShapeBorderClipper(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(11)),
          ),
        ),
        child: image,
      );
    }
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: image);
  }
}

/// 退回用分类图标（文件夹/压缩包/文本…），也是加载中的占位。
class FileIconTile extends StatelessWidget {
  const FileIconTile({
    super.key,
    required this.entry,
    this.size = 40,
    this.iconSize = 20,
    this.chamfer = false,
    this.radius = 8,
    this.reason,
  });

  final FileEntryDto entry;
  final double size;
  final double iconSize;
  final bool chamfer;
  final double radius;

  /// 可选的一句话原因：给了就挂到 Tooltip + Semantics 上（长按/读屏可见）。
  ///
  /// 只为"这不是普通无图，而是有原因的不可用"（HEIC 等）准备；列表行太小，
  /// 文字塞不进去，所以用无障碍标签承载。
  final String? reason;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hud = DesignPalette.of(context);
    final tile = Container(
      width: size,
      height: size,
      decoration: chamfer
          ? ShapeDecoration(
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(11)),
              ),
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
            )
          : BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(radius),
            ),
      child: Icon(
        fileIconFor(entry),
        size: iconSize,
        color: entry.isDir ? scheme.primary : hud.dim,
      ),
    );
    final why = reason;
    if (why == null) return tile;
    return Tooltip(
      message: why,
      child: Semantics(label: why, child: tile),
    );
  }
}

/// "**服务端缩略图不可用**"的明确占位 —— 专给客户端解不了的格式（HEIC/HEIF）。
///
/// 与 [FileIconTile] 的区别：带固定 [Key]（`file-thumb-server-required`）与
/// **一句话原因**，语义上不假装"只是还没加载出来"。`showReason` 为 true 时
/// 把原因直接画在占位下方（预览页空间够）；列表行用 false + Tooltip。
class FileThumbUnavailable extends StatelessWidget {
  const FileThumbUnavailable({
    super.key,
    required this.entry,
    this.size = 40,
    this.iconSize = 20,
    this.radius = 8,
    this.showReason = false,
  });

  final FileEntryDto entry;
  final double size;
  final double iconSize;
  final double radius;
  final bool showReason;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    // 复用既有 key，不加新 ARB："解不开这张图"。
    final why = context.t.fileImageDecodeFailed;
    final tile = FileIconTile(
      entry: entry,
      size: size,
      iconSize: iconSize,
      radius: radius,
      chamfer: radius <= 10 && size >= 36,
      reason: why,
    );
    if (!showReason) return tile;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        tile,
        const SizedBox(height: Gap.sm),
        Text(
          why,
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: hud.dim),
        ),
      ],
    );
  }
}

/// 字节看起来是不是一张图（PNG/JPEG/GIF/WEBP/BMP）。
///
/// 为什么不信服务端：`entry.cgi` 有时会用 **200** 回一整页 HTML
/// （例如缩略图生成失败），直接喂给 `Image.memory` 会抛解码异常。
bool looksLikeImage(Uint8List b) {
  if (b.length < 12) return false;
  bool at(int i, int v) => b[i] == v;
  // PNG
  if (at(0, 0x89) && at(1, 0x50) && at(2, 0x4E) && at(3, 0x47)) return true;
  // JPEG
  if (at(0, 0xFF) && at(1, 0xD8)) return true;
  // GIF87a / GIF89a
  if (at(0, 0x47) && at(1, 0x49) && at(2, 0x46)) return true;
  // BMP
  if (at(0, 0x42) && at(1, 0x4D)) return true;
  // WEBP: RIFF….WEBP
  if (at(0, 0x52) &&
      at(1, 0x49) &&
      at(2, 0x46) &&
      at(3, 0x46) &&
      at(8, 0x57) &&
      at(9, 0x45) &&
      at(10, 0x42) &&
      at(11, 0x50)) {
    return true;
  }
  return false;
}

/// 字节是不是 HEIC/HEIF（ISO-BMFF：offset 4 的 `ftyp` + major brand）。
///
/// **故意不放进 [looksLikeImage]**：Flutter 解不了 HEIC，把它当"可以喂
/// `Image.memory` 的图"会抛解码异常。这里单独认出来，是为了在"服务端直接把
/// 原图 HEIC 字节回下来"（而不是转好的 JPEG）时，能给**明确原因**而不是静默占位。
bool looksLikeHeic(List<int> b) {
  if (b.length < 12) return false;
  // 'ftyp' @4
  if (b[4] != 0x66 || b[5] != 0x74 || b[6] != 0x79 || b[7] != 0x70) {
    return false;
  }
  final major = String.fromCharCodes(b.sublist(8, 12));
  return const {
    'heic',
    'heix',
    'hevc',
    'hevx',
    'heim',
    'heis',
    'hevm',
    'hevs',
    'heif',
    'mif1',
    'msf1',
  }.contains(major);
}

/// 这个后缀要不要走"本机抽首帧"（容器白名单来自抽帧层，避免两处各写一份）。
bool _isVideoContainer(String extension) =>
    kVideoFrameContainers.contains(normalizeMediaExtension(extension));

/// 视频首帧请求：**直链一律复用既有实现**（`resolveEntryMediaSource` →
/// FileStation `Download` 的 `authenticatedUrl`，`_sid` 已在查询串里；
/// §2.0.11 的 TLS 放宽也因此自动生效）。
///
/// Drive 视频仍然解析得出 `uri`（只是 `playable == false`）⇒ 这里能拿到请求，
/// 但 `rangeSupported == false`，于是 `videoFrameThumbSupported` 只在
/// "已知大小且 ≤ 6 MiB"时才放行 —— 4.7 GB 的 MKV 不可能被整份拉下来。
VideoFrameThumbRequest? _videoFrameRequest(WidgetRef ref, FileEntryDto entry) {
  final source = resolveEntryMediaSource(
    entry: entry,
    kind: MediaKind.video,
    fs: ref.watch(fileApiProvider),
    drive: ref.watch(driveApiProvider),
  );
  final request = videoFrameThumbRequestFor(entry, source);
  // ★ 诊断（第 41 轮，临时）：证明 Files 侧**确实走到了**这里，
  //   并给出源的 kind/uri/range（uri 不外泄，只报有无）。
  debugPrint(
    '[fileThumb] videoReq path=${entry.path} kind=${source.kind} '
    'uri=${source.uri.isEmpty ? "empty" : "ok"} '
    'range=${source.supportsRange} size=${entry.size} '
    'ext=${entry.extension} req=${request != null}',
  );
  return request;
}

/// 音频/视频文件里**内嵌封面**的请求；不是音视频 / 拿不到 FileStation 直链 /
/// 不需要 Range 的来源 → null（列表直接用现有图标或服务端缩略图）。
///
/// 两条边界：
///   * **Drive 不取**：`path` 是 `drive:<file_id>` 时返回 null —— Drive 写死
///     `Accept-Ranges: none`，为了封面整份下载不划算（同 `media_source.dart`）；
///   * **容器没把握不取**：`mediaCoverRequestFor(...).supported == false`
///     （例如 AVI）直接返回 null，连 Range 请求都不发。
MediaCoverKey? _embeddedCoverKey(WidgetRef ref, FileEntryDto entry) {
  if (entry.isDir) return null;
  final ext = normalizeMediaExtension(entry.extension);
  final kind = switch (ext) {
    'mp3' ||
    'mp2' ||
    'mp1' ||
    'aac' ||
    'flac' ||
    'ogg' ||
    'oga' ||
    'opus' ||
    'spx' ||
    'wma' ||
    'asf' ||
    'wav' ||
    'wave' ||
    'm4a' ||
    'm4b' ||
    'm4p' => MediaKind.audio,
    'mp4' ||
    'm4v' ||
    'mov' ||
    'mkv' ||
    'webm' ||
    '3gp' ||
    '3g2' ||
    'avi' ||
    'wmv' => MediaKind.video,
    _ => null,
  };
  if (kind == null) return null;
  final plan = mediaCoverRequestFor(
    kind: kind,
    extension: ext,
    fileSize: entry.size,
  );
  if (!plan.supported) return null;
  // Drive 不支持 Range（`media_source.dart` 的调研 §3.4）→ 不为了封面整份下载
  if (driveFileIdOf(entry.path) != null) return null;
  final fs = ref.watch(fileApiProvider);
  final uri = fs?.downloadUrl([entry.path]);
  if (uri == null || uri.isEmpty) return null;
  return MediaCoverKey(
    cacheKey: '${entry.path}|${entry.mtime}|${entry.size}',
    uri: uri,
    kind: kind,
    extension: ext,
    fileSize: entry.size,
    rangeSupported: true,
  );
}
