// 链接预览卡片（OG）—— 对齐 APK 的 `ui/adapter/UrlAdapter.java` +
// `CommonViewBinder.bindFirstUrlOg` / `bindPartialUrlView` / `bindUnsafeUrl`。
//
// 原版两套布局：
//   * **大图卡**（`item_url_large_thumb`）：左边一条 `og_starter` 竖条，
//     右边图 + 标题 + 域名 + 描述；图按 `setupImageSize` 定宽高比
//     （横图 0.6、竖图 0.7×1.25、方图 0.7×0.7）。
//   * **小图卡**（`item_url_small_thumb`）：图 ≤64px（或强制小图）时，
//     左边一个小方图，右边标题/域名/描述。
//
// 图与 favicon 都是**外链**，一律经 `SYNO.Chat.Post.File / og` 代理取
// （原版 `OGLoader`），不在客户端直连外网；取到的字节在内存里缓存。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/theme/app_typography.dart';
import '../../data/dto/url_prop_dto.dart';
import 'chat_session_controller.dart';
import 'url_actions.dart';

/// 内存里的 OG 图缓存：`postId|url` → 字节。
///
/// 用 **LRU（上限 50 条）**：长会话里每张 OG 图只增不减，无上限 Map 最后必然
/// OOM。Dart 的 Map 保持插入顺序，取用时重新插入即把最近用的排到最后。
class _OgCache {
  static const int maxEntries = 50;

  final _map = <String, Uint8List>{};

  Uint8List? get(String key) {
    final value = _map.remove(key);
    if (value != null) _map[key] = value;
    return value;
  }

  void put(String key, Uint8List bytes) {
    _map.remove(key);
    _map[key] = bytes;
    if (_map.length > maxEntries) {
      _map.remove(_map.keys.first); // 最久未用
    }
  }

  void clear() => _map.clear();
}

final _ogCache = _OgCache();

/// 测试用：清掉缓存
@visibleForTesting
void clearOgCache() => _ogCache.clear();

/// 遥测字色（主题没注册 `DesignPalette` 时退回 colorScheme，避免硬编码颜色）
Color _metaColor(BuildContext context) {
  final theme = Theme.of(context);
  return theme.extension<DesignPalette>()?.dim ??
      theme.colorScheme.onSurfaceVariant;
}

/// 警告语义色（固定琥珀色，不跟随主色）
Color _warningColor(BuildContext context) {
  final theme = Theme.of(context);
  return theme.extension<DesignPalette>()?.danger ?? theme.colorScheme.error;
}

class LinkPreviewCard extends ConsumerStatefulWidget {
  const LinkPreviewCard({
    super.key,
    required this.postId,
    required this.prop,
    this.safeUrl = true,
    this.forceSmallThumb = false,
    this.availableWidth = 280,
    this.onOpen,
  });

  final int postId;
  final UrlPropDto prop;

  /// `post.props.safe_url == false` → 显示"链接可能有风险"提示
  /// （原版 `CommonViewBinder.bindUnsafeUrl`）
  final bool safeUrl;

  /// 评论/引用里强制小图（原版 `CommentsAdapter` 传 true）
  final bool forceSmallThumb;

  /// 可用宽度（算图框用）
  final double availableWidth;

  /// 覆盖点击行为（测试用）；默认走 `openUrlOrJumpChannel`
  final void Function(UrlPropDto prop)? onOpen;

  @override
  ConsumerState<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends ConsumerState<LinkPreviewCard> {
  Uint8List? _image;
  Uint8List? _favicon;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(LinkPreviewCard old) {
    super.didUpdateWidget(old);
    if (old.postId != widget.postId || old.prop.image != widget.prop.image) {
      _image = null;
      _favicon = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    final api = ref.read(chatSessionControllerProvider.notifier).chatApi;
    if (api == null) {
      // ★ 以前这里直接 `return`：`_failed` 保持 false、`_image` 为 null
      //   ⇒ 预览图占位永久转圈（会话未就绪 / 断开时）。现在如实置失败态。
      if (mounted) setState(() => _failed = true);
      return;
    }
    final prop = widget.prop;
    if (prop.hasImage) {
      final key = '${widget.postId}|${prop.image}';
      final cached = _ogCache.get(key);
      if (cached != null) {
        _image = cached;
      } else {
        try {
          final bytes = await api.downloadOgImage(widget.postId, prop.image);
          final data = Uint8List.fromList(bytes);
          _ogCache.put(key, data);
          _image = data;
        } catch (_) {
          _failed = true;
        }
      }
    }
    if (prop.hasFavicon) {
      final key = '${widget.postId}|${prop.favicon}';
      final cached = _ogCache.get(key);
      if (cached != null) {
        _favicon = cached;
      } else {
        try {
          final bytes = await api.downloadOgImage(widget.postId, prop.favicon);
          final data = Uint8List.fromList(bytes);
          _ogCache.put(key, data);
          _favicon = data;
        } catch (_) {
          // favicon 失败无所谓
        }
      }
    }
    if (mounted) setState(() {});
  }

  /// 失败后重试：清掉失败/旧图，重新走一次 [_load]（真的重新发请求）。
  Future<void> _retry() async {
    if (mounted) {
      setState(() {
        _failed = false;
        _image = null;
        _favicon = null;
      });
    }
    await _load();
  }

  void _open() {
    if (widget.onOpen != null) {
      widget.onOpen!(widget.prop);
      return;
    }
    openUrlOrJumpChannel(
      context,
      widget.prop.url,
      baseUrl: baseUrlOf(ref),
      unsafe: !widget.safeUrl,
    );
  }

  @override
  Widget build(BuildContext context) {
    final prop = widget.prop;
    final small = widget.forceSmallThumb || prop.isSmallThumb;
    final hasImage = prop.hasImage;
    final box = prop.imageBox(
      widget.availableWidth,
      forceSmallThumb: widget.forceSmallThumb,
    );
    // favicon/OG 图都按显示尺寸 × 像素比解码，别按原始分辨率解
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final faviconCache = (16 * dpr).round();

    final textColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (_favicon != null) ...[
              Image.memory(
                _favicon!,
                width: 16,
                height: 16,
                fit: BoxFit.cover,
                cacheWidth: faviconCache,
                cacheHeight: faviconCache,
              ),
              const SizedBox(width: 6),
            ] else if (prop.hasFavicon)
              const SizedBox(
                width: 16,
                height: 16,
                child: _FaviconPlaceholder(),
              ),
            Expanded(
              child: Text(
                prop.displayTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        // 域名是 meta，走 HUD 遥测字
        Text(
          prop.domain,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppType.telemetry(size: 11.5, color: _metaColor(context)),
        ),
        if (prop.hasDescription) ...[
          const SizedBox(height: 4),
          Text(
            prop.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (!widget.safeUrl) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 14,
                color: _warningColor(context),
              ),
              const SizedBox(width: 4),
              Text(
                context.t.chatLinkRisky,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: _warningColor(context)),
              ),
            ],
          ),
        ],
      ],
    );

    final imageBox = _image == null
        ? Container(
            width: box.width,
            height: box.height,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            alignment: Alignment.center,
            child: _failed
                ? IconButton(
                    key: const Key('link-preview-retry'),
                    tooltip: context.t.photoRetry,
                    iconSize: 20,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    onPressed: _retry,
                    icon: const Icon(Icons.refresh),
                  )
                : const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
          )
        : Image.memory(
            _image!,
            width: box.width,
            height: box.height,
            fit: BoxFit.cover,
            cacheWidth: (box.width * dpr).round(),
            cacheHeight: (box.height * dpr).round(),
          );

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        // 内嵌内容统一 Radii.embed（原来是 10）
        borderRadius: BorderRadius.circular(Radii.embed),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _open,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: !hasImage
                ? textColumn
                : small
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(Radii.bubbleInner),
                        child: imageBox,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: textColumn),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(Radii.bubbleInner),
                        child: SizedBox(
                          width: box.width,
                          height: box.height,
                          child: imageBox,
                        ),
                      ),
                      const SizedBox(height: 6),
                      textColumn,
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _FaviconPlaceholder extends StatelessWidget {
  const _FaviconPlaceholder();

  @override
  Widget build(BuildContext context) => Icon(
    Icons.public,
    size: 16,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  );
}
