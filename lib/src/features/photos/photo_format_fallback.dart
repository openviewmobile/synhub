// 相册**格式兜底面板**：HEIC 生成预览引导（P15）+ RAW/AVIF 不支持提示（P16）。
//
// 官方证据：
//   * P15 `str_ame_defect_alert_title` / `str_auto_generate_thumbnail_desc` /
//     `str_ame_need_to_reindex_*` —— HEIC/HEIF 靠服务端 Image Assistant / AME
//     生成 JPEG 预览；拿不到预览时引导"生成预览"；
//   * P16 `str_ame_unsupported_format_message` —— RAW/DNG/AVIF 官方**不承诺**，
//     只给一句兜底文案。
//
// 服务端接口（P15）：`SYNO.Foto.RegeneratePreview` **v1**
// `list_regenerating`（**只读**，状态查询）/ `regenerate_preview_by_nas`
// （**写**，用户确认后才发）。两者都在 `foto_api.dart` 里。
//
// 本面板只做**表现 + 一次显式用户动作**：绝不自动发写请求。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import 'photo_format_support.dart';
import 'photo_providers.dart';
import 'photo_widgets.dart';

Duration? _noRetry(int retryCount, Object error) => null;

/// NAS 正在"再生成预览"的条目（`RegeneratePreview/list_regenerating` v1）。
///
/// 真机只读探针（2026-09-22）：`{"data":{"list":[]},"success":true}` ——
/// 空列表 = 当前没有正在生成的任务。列表项结构**未取证**，所以这里只按
/// "有没有"用，不解析字段。
final photoRegeneratingProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final api = ref.watch(fotoSpaceApiProvider);
      if (api == null) return const [];
      return api.listRegeneratingPreviews();
    }, retry: _noRetry);

/// 加载大图失败时的格式兜底面板（HEIC 引导 / RAW·AVIF 不支持）。
class PhotoFormatFallback extends ConsumerStatefulWidget {
  const PhotoFormatFallback({
    super.key,
    required this.filename,
    this.onDownload,
    this.onOpenExternal,
  });

  final String filename;
  final VoidCallback? onDownload;
  final VoidCallback? onOpenExternal;

  @override
  ConsumerState<PhotoFormatFallback> createState() =>
      _PhotoFormatFallbackState();
}

class _PhotoFormatFallbackState extends ConsumerState<PhotoFormatFallback> {
  bool _busy = false;

  bool get _needsPreview => photoNeedsServerPreview(widget.filename);

  bool get _notPromised => photoFormatNotPromised(widget.filename);

  Future<void> _regenerate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          photoG1(PhotoG1TextKeys.heicPreviewConfirmTitle, '让 NAS 生成预览？'),
        ),
        content: Text(
          photoG1(
            PhotoG1TextKeys.heicPreviewConfirmBody,
            '会在 NAS 上重新生成预览图，可能占用一些时间与算力。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            key: const Key('photo-heic-regenerate-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              photoG1(PhotoG1TextKeys.heicPreviewAction, '让 NAS 生成预览'),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) return;
    setState(() => _busy = true);
    try {
      await api.regeneratePreviewByNas();
      if (!mounted) return;
      ref.invalidate(photoRegeneratingProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          key: const Key('photo-heic-regenerate-done'),
          content: Text(
            photoG1(
              PhotoG1TextKeys.heicPreviewRequested,
              '已请求 NAS 生成预览，稍后回到这里刷新。',
            ),
          ),
        ),
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            photoG1Fill(PhotoG1TextKeys.heicPreviewFailed, '请求失败：{reason}', {
              'reason': describePhotoError(err, context.t),
            }),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final bodyStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: Colors.white70);
    final String title;
    final String body;
    if (_needsPreview) {
      title = photoG1(PhotoG1TextKeys.heicPreviewTitle, '这张 HEIC 照片还没有预览');
      body = photoG1(
        PhotoG1TextKeys.heicPreviewBody,
        'HEIC/HEIF 由 NAS 的 Image Assistant 转成 JPEG 预览后才能在应用内显示。',
      );
    } else if (_notPromised) {
      title = photoFormatFallbackText(widget.filename) ?? '';
      body = photoG1(
        PhotoG1TextKeys.formatUnsupportedBody,
        '与官方一致：RAW / DNG / AVIF 不在应用内解码；可下载后用其他应用打开，'
        '或在 NAS 上启用 Image Assistant。',
      );
    } else {
      title = context.t.photoDecodeFailed;
      body = photoFormatFallbackText(widget.filename) ?? '';
    }
    return Center(
      key: const Key('photo-format-fallback'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _needsPreview
                  ? Icons.image_search_outlined
                  : Icons.image_not_supported_outlined,
              size: 48,
              color: hud.dim,
            ),
            const SizedBox(height: Gap.md),
            Text(
              widget.filename,
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: Gap.sm),
            Text(title, style: bodyStyle, textAlign: TextAlign.center),
            if (body.isNotEmpty) ...[
              const SizedBox(height: Gap.xs),
              Text(body, style: bodyStyle, textAlign: TextAlign.center),
            ],
            if (_needsPreview) ...[
              const SizedBox(height: Gap.md),
              // 正在生成的状态：`list_regenerating` 非空就如实说一声
              Consumer(
                builder: (context, ref, _) {
                  final pending =
                      ref.watch(photoRegeneratingProvider).value?.length ?? 0;
                  if (pending == 0) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: Gap.sm),
                    child: Text(
                      photoG1Fill(
                        PhotoG1TextKeys.heicRegenerating,
                        'NAS 正在生成 {count} 个预览',
                        {'count': '$pending'},
                      ),
                      key: const Key('photo-heic-regenerating-count'),
                      style: bodyStyle,
                    ),
                  );
                },
              ),
              // ★ 第 240 轮（`DA184`，用户裁定 ③）：这块面板出现在**黑底**大图查看器里
              //   （`photo_viewer_page` 的 `backgroundColor: Colors.black`），
              //   而 `tonalIcon` 的底是 `secondaryContainer`，**跟着主题走**
              //   —— 亮色下是一块淡紫色板子贴在黑底上（与 `DA168` 同一类）。
              //   黑底容器里的按钮一律用 `primary/onPrimary`。
              FilledButton.icon(
                style: InlineButtonStyle.filled,
                key: const Key('photo-heic-regenerate'),
                onPressed: _busy ? null : _regenerate,
                icon: _busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_fix_high, size: 16),
                label: Text(
                  photoG1(PhotoG1TextKeys.heicPreviewAction, '让 NAS 生成预览'),
                ),
              ),
            ],
            if (widget.onOpenExternal != null || widget.onDownload != null) ...[
              const SizedBox(height: Gap.sm),
              Wrap(
                spacing: Gap.sm,
                children: [
                  if (widget.onDownload != null)
                    TextButton.icon(
                      key: const Key('photo-format-download'),
                      onPressed: widget.onDownload,
                      icon: const Icon(Icons.download_outlined, size: 16),
                      label: Text(context.t.dtoActionDownload),
                    ),
                  if (widget.onOpenExternal != null)
                    TextButton.icon(
                      key: const Key('photo-format-open-external'),
                      onPressed: widget.onOpenExternal,
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: Text(context.t.photoOpenWithOther),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
