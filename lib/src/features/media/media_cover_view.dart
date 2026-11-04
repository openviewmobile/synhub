// 内嵌封面的**展示**小部件（无封面 → 回落到调用方给的 fallback，绝不显示破图）。
//
// 为什么要有这一层：同一个"有封面画封面、没封面退图标/黑底"的逻辑会用在
// 播放页（海报）和文件列表（缩略图）两处，写一遍比抄两遍好。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/data_text.dart';
import 'media_cover_provider.dart';

/// 封面的**两级来源**：① 文件内嵌封面 → ② 服务端缩略图；都没有时画
/// [placeholder]（**明确占位，绝不留空白框**）。
///
/// 为什么两级缺一不可（用户明确要求）：
///   * 内嵌封面是"文件自带的专辑封面/海报"，最保真，但相册视频、部分容器
///     (`avi` 等) 没有内嵌图；
///   * 服务端缩略图（`SYNO.FileStation.Thumb`）是兜底 —— DSM 能对视频抽帧、
///     对音频出图；
///   * 两级都拿不到 → [placeholder]（图标 + 说明），不能是长度 0 的空白。
class MediaCoverLayers extends ConsumerWidget {
  const MediaCoverLayers({
    super.key,
    required this.embedded,
    required this.placeholder,
    this.thumbBytes,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.cacheWidth,
  });

  /// ① 内嵌封面请求（null = 这条来源不支持取内嵌图）
  final MediaCoverKey? embedded;

  /// ② 服务端缩略图字节（由调用方用 `fileThumbProvider` 取好；null = 没有/还没好）
  final Uint8List? thumbBytes;

  /// 两级都没有时的**明确占位**（不许是空 `SizedBox`）
  final Widget placeholder;

  final BoxFit fit;
  final double? width;
  final double? height;
  final int? cacheWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final req = embedded;
    final cover = req == null ? null : ref.watch(mediaCoverProvider(req)).value;
    final bytes = cover?.bytes ?? thumbBytes;
    if (bytes == null || bytes.isEmpty) return placeholder;
    final Widget image = Image.memory(
      bytes,
      fit: fit,
      gaplessPlayback: true,
      cacheWidth: cacheWidth,
      errorBuilder: (_, _, _) => placeholder,
    );
    if (width == null && height == null) return image;
    return SizedBox(width: width, height: height, child: image);
  }
}

/// 封面缺失时的**明确占位**：图标 + 一行说明，带固定 [Key]。
///
/// 与"黑底/空框"的区别：用户能一眼看出"这里本来该有封面，只是没取到"，
/// 而不是以为界面坏了。文案走 `dataText(key, zh)`（本批禁改 ARB）。
class MediaCoverPlaceholder extends StatelessWidget {
  const MediaCoverPlaceholder({
    super.key,
    this.icon = Icons.image_not_supported_outlined,
    this.size = 72,
    this.showLabel = true,
    this.iconColor,
  });

  final IconData icon;
  final double size;
  final bool showLabel;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: size, color: iconColor ?? scheme.onSurfaceVariant),
        if (showLabel) ...[
          const SizedBox(height: 8),
          Text(
            mediaCoverUnavailableText(),
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

/// 「没有可用封面」的说明句（ARB key `mediaCoverUnavailable`，未落库前中文回落）
String mediaCoverUnavailableText() =>
    dataText('mediaCoverUnavailable', '暂无封面');

/// 内嵌封面图：拿不到封面 / 解码失败 → 画 [fallback]。
class MediaCoverImage extends ConsumerWidget {
  const MediaCoverImage({
    super.key,
    required this.request,
    required this.fallback,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.cacheWidth,
  });

  /// 封面请求；为 null（来源不支持 Range / 容器没有内嵌封面）时直接用 fallback
  final MediaCoverKey? request;

  final Widget fallback;
  final BoxFit fit;
  final double? width;
  final double? height;
  final int? cacheWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final req = request;
    if (req == null) return fallback;
    final cover = ref.watch(mediaCoverProvider(req)).value;
    if (cover == null) return fallback;
    final Widget image = Image.memory(
      cover.bytes,
      fit: fit,
      gaplessPlayback: true,
      cacheWidth: cacheWidth,
      errorBuilder: (_, _, _) => fallback,
    );
    if (width == null && height == null) return image;
    return SizedBox(width: width, height: height, child: image);
  }
}

/// 播放页的**海报背景**：有封面时铺满并压一层暗罩（保证控件/字幕可读），
/// 没封面时画 [fallback]（默认黑底）——不会留空白框。
///
/// 两级来源：内嵌封面（[request]）→ 服务端缩略图（[thumbBytes]）→ [fallback]。
/// 相册视频等没有内嵌封面时，服务端 `Thumb` 抽帧的那张图就是第二级兜底。
class MediaCoverBackdrop extends ConsumerWidget {
  const MediaCoverBackdrop({
    super.key,
    required this.request,
    this.thumbBytes,
    this.scrim = 0.35,
    this.fallback = const ColoredBox(color: Colors.black),
  });

  final MediaCoverKey? request;

  /// 服务端缩略图字节（调用方取好；null = 没取到/取不了）
  final Uint8List? thumbBytes;

  /// 封面之上的黑色蒙版强度（0 = 不加）
  final double scrim;

  final Widget fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final req = request;
    final cover = req == null ? null : ref.watch(mediaCoverProvider(req)).value;
    final bytes = cover?.bytes ?? thumbBytes;
    if (bytes == null || bytes.isEmpty) return fallback;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        Image.memory(
          bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
        if (scrim > 0) ColoredBox(color: Colors.black.withValues(alpha: scrim)),
      ],
    );
  }
}
