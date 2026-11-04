// 链接预览（OG）—— 字段逐一对齐 APK 的 `data/vo/chat/UrlVo.java`，
// 并用真机实测响应校验过（见 docs/phase5-protocol.md「链接预览」）。
//
// 真机 `SYNO.Chat.Post / list` 里的 `url_props` 元素长这样：
// ```json
// {
//   "description": "Centralize data storage and backup, …",
//   "favicon": "https://fileres.synology.com/images/common/favicon/syno/icon-120x120.png",
//   "hidden": false,
//   "image": "https://fileres.synology.com/images/common/meta-tag-preview-image/img_synology.jpg",
//   "image_prop": {"height": 628, "width": 1200},
//   "mime_type": "text/html",
//   "title": "Download Center - download | Synology Inc.",
//   "url": "https://www.synology.com/zh-cn/products/DS920+"
// }
// ```
//
// ⚠️ 两个坑：
//   1. `url_props` **是异步填的** —— 发消息那一刻服务端回 `[]`，抓完 OG 之后
//      再由 `post.update`（或下次 `Post/list`）带出来（真机实测：几秒内）。
//   2. `image` / `favicon` 都是**外链**，但客户端不能直接去外网抓（会泄漏 IP、
//      且服务端要记账），原版走 `SYNO.Chat.Post.File / og` 代理（见 chat_api）。
library;

/// 一个 OG 预览块。
class UrlPropDto {
  const UrlPropDto({
    required this.url,
    this.title = '',
    this.description = '',
    this.image = '',
    this.favicon = '',
    this.mimeType = '',
    this.hidden = false,
    this.imageWidth = 0,
    this.imageHeight = 0,
  });

  /// 链接本身
  final String url;

  /// 网页标题（可能为空）
  final String title;

  /// 网页描述（可能为空）
  final String description;

  /// OG 大图（外链，要经服务端代理取）
  final String image;

  /// 站点图标（外链，走同一个代理）
  final String favicon;

  /// 网页 MIME（基本都是 `text/html`）
  final String mimeType;

  /// ⭐️ 服务端说这条预览**不要展示**（原版 `bindFirstUrlOg` 会跳过 `hidden`）
  final bool hidden;

  /// OG 图原始尺寸 —— 决定卡片里图的宽高比（原版 `setupImageSize`）
  final int imageWidth;
  final int imageHeight;

  bool get hasImage => image.isNotEmpty;
  bool get hasFavicon => favicon.isNotEmpty;
  bool get hasDescription => description.isNotEmpty;

  /// 卡片标题：没标题就退化成 URL（原版 `bindPartialUrlView`）
  String get displayTitle => title.isNotEmpty ? title : url;

  /// 域名：去掉协议头，取到第一个 `/`（原版 `UrlUtil.getDomainFromUrl`）
  String get domain {
    var rest = url;
    final lower = url.toLowerCase();
    if (lower.startsWith('http://')) {
      rest = url.substring(7);
    } else if (lower.startsWith('https://')) {
      rest = url.substring(8);
    }
    final slash = rest.indexOf('/');
    return slash < 0 ? rest : rest.substring(0, slash);
  }

  /// 图是不是"小图"（原版 `getItemViewType`：任一边 ≤ 64 就当缩略图排）
  bool get isSmallThumb => imageHeight <= 64 || imageWidth <= 64;

  static UrlPropDto? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final url = raw['url'];
    if (url is! String || url.isEmpty) return null;
    final imageProp = raw['image_prop'];
    final w = imageProp is Map ? _int(imageProp['width']) : _int(raw['width']);
    final h = imageProp is Map
        ? _int(imageProp['height'])
        : _int(raw['height']);
    return UrlPropDto(
      url: url,
      title: _str(raw['title']),
      description: _str(raw['description']),
      image: _str(raw['image']),
      favicon: _str(raw['favicon']),
      mimeType: _str(raw['mime_type']),
      hidden: raw['hidden'] == true,
      imageWidth: w,
      imageHeight: h,
    );
  }

  static List<UrlPropDto> parseList(Object? raw) {
    if (raw is! List) return const [];
    return raw.map(tryParse).whereType<UrlPropDto>().toList(growable: false);
  }

  static String _str(Object? v) => v is String ? v : '';
  static int _int(Object? v) =>
      v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? 0 : 0);

  /// 卡片的图框尺寸（宽, 高）—— 照抄原版 `UrlAdapter.setupImageSize`：
  ///   * 小图（任一边 ≤ 64，含尺寸未知的 0）：固定 88×88 的缩略图
  ///   * 横图（宽 > 高）：宽 = 可用宽，高 = 宽 × 0.6
  ///   * 竖图（宽 < 高）：宽 = 可用宽 × 0.7，高 = 宽 × 1.25
  ///   * 方图：宽 = 可用宽 × 0.7，高 = 同宽
  ///
  /// ⚠️ 原版 `getItemViewType` 判的是 `imageHeight <= 64 || imageWidth <= 64`，
  /// 所以**尺寸未知（0）也会走小图**；大图分支里那段"尺寸为 0 就用 XML 默认值"
  /// 实际是死代码，我们也就不写了。
  ({double width, double height}) imageBox(
    double availableWidth, {
    bool forceSmallThumb = false,
  }) {
    if (forceSmallThumb || isSmallThumb) {
      return (width: 88, height: 88);
    }
    if (imageWidth > imageHeight) {
      return (width: availableWidth, height: availableWidth * 0.6);
    }
    final w = availableWidth * 0.7;
    if (imageWidth < imageHeight) return (width: w, height: w * 1.25);
    return (width: w, height: w);
  }

  @override
  String toString() => 'UrlPropDto($url, title="$title")';
}

/// 一条消息要展示的预览：**第一条没被 hidden 的**（原版 `bindFirstUrlOg`）。
///
/// 另外原版在 `post.file() != null` 时直接不显示预览（有附件就不叠卡片）。
UrlPropDto? firstVisiblePreview(
  List<UrlPropDto> list, {
  bool hasAttachment = false,
}) {
  if (hasAttachment) return null;
  for (final u in list) {
    if (!u.hidden) return u;
  }
  return null;
}
