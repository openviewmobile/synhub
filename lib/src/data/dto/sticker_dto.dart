// 贴纸 / 表情目录（`SYNO.Chat.Sticker / list` v1）。
//
// 反编译结论（Android-SynologyChat 2.11.1）：
//   * `ChatSticker.API = "SYNO.Chat.Sticker"`，`VERSION = 1`、`VERSION_EMOJI = 2`；
//     `AccountManager.fetchStickers()` 固定用 **v1** 调 `list`。
//   * 返回 `{data:{categories:[{category_id, is_emoji, name, stickers:[…]}]}}`，
//     每个贴纸 `{sticker_id, name, keywords, skin_color, support_skin}`。
//   * 图片直链 `GET {base}sc/stickers/{sticker_id}/{size}`，size ∈ `1x|2x|4x`；
//     **要带 cookie，不能挂 `_sid`**（真机实测：挂 `_sid` 回 HTML 登录页）。
//   * `is_emoji=true` 的分类里，贴纸 `name` 是 emojione 短代码，原版用**内置**
//     EmojiOne 图片表渲染（`EmojiOne.emojiResId(name)`），名字为空才回落到服务端
//     图；真机这台服务端只回了 3 个非 emoji 分类。
//   * 发贴纸 = 普通 `Post/create`，`type=sticker`、`message=":<name>:"`
//     （`ChannelFragment.createSticker` → `createPost(channelId, ":$name:", "sticker")`）；
//     表情则只**插进输入框**，不直接发。
import 'dart:convert';

/// 单个贴纸
class StickerDto {
  const StickerDto({
    required this.stickerId,
    required this.name,
    this.keywords = const [],
    this.supportSkin = false,
    this.skinColor = 0,
  });

  final int stickerId;
  final String name;
  final List<String> keywords;
  final bool supportSkin;
  final int skinColor;

  static StickerDto? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = _int(raw['sticker_id']) ?? 0;
    final name = (raw['name'] ?? '').toString();
    if (id <= 0 || name.isEmpty) return null;
    return StickerDto(
      stickerId: id,
      name: name,
      keywords: raw['keywords'] is List
          ? (raw['keywords'] as List).map((e) => '$e').toList()
          : const [],
      supportSkin: raw['support_skin'] == true,
      skinColor: _int(raw['skin_color']) ?? 0,
    );
  }
}

/// 一个分类（`is_emoji=true` = emoji 分类，走内置 emoji 表）
class StickerCategoryDto {
  const StickerCategoryDto({
    required this.categoryId,
    required this.name,
    required this.isEmoji,
    this.stickers = const [],
  });

  final int categoryId;
  final String name;
  final bool isEmoji;
  final List<StickerDto> stickers;

  static StickerCategoryDto? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final stickers = <StickerDto>[];
    final list = raw['stickers'];
    if (list is List) {
      for (final s in list) {
        final dto = StickerDto.tryParse(s);
        if (dto != null) stickers.add(dto);
      }
    }
    return StickerCategoryDto(
      categoryId: _int(raw['category_id']) ?? 0,
      name: (raw['name'] ?? '').toString(),
      isEmoji: raw['is_emoji'] == true,
      stickers: stickers,
    );
  }
}

/// 整份目录（登录后拉一次就够）
class StickerCatalog {
  const StickerCatalog({this.categories = const []});

  final List<StickerCategoryDto> categories;

  static const empty = StickerCatalog();

  /// `list` 的返回体（`data.categories`；[DsmWebApi.call] 已经把 `data` 拆掉了）
  static StickerCatalog parse(Map<String, dynamic> data) {
    final list = data['categories'];
    if (list is! List) return empty;
    return StickerCatalog(
      categories: [
        for (final c in list)
          ?StickerCategoryDto.tryParse(c),
      ],
    );
  }

  bool get isEmpty => categories.every((c) => c.stickers.isEmpty);

  /// 非 emoji 的贴纸分类（面板第一段）
  List<StickerCategoryDto> get stickerCategories =>
      categories.where((c) => !c.isEmoji).toList();

  /// emoji 分类
  List<StickerCategoryDto> get emojiCategories =>
      categories.where((c) => c.isEmoji).toList();

  /// `name → sticker_id`：消息里存的是名字，取图要先查回 id
  /// （原版 `StickerLoader` 用 `DatabaseHelper.getStickerId(name)`）
  Map<String, int> get idByName => {
    for (final c in categories)
      for (final s in c.stickers) s.name: s.stickerId,
  };

  int? idOf(String name) => idByName[name];

  /// 从消息正文里抠出短代码：原版正则 `:(\S+?):`
  static String? nameFromMessage(String message) {
    final m = RegExp(r':(\S+?):').firstMatch(message);
    return m?.group(1);
  }

  /// 贴纸消息（`type=sticker`，`message=":<name>:"`）
  static String messageFor(String stickerName) => ':$stickerName:';
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

/// 仅供调试：把目录打成一行 JSON
String catalogToJson(StickerCatalog catalog) => jsonEncode({
  'categories': [
    for (final c in catalog.categories)
      {
        'category_id': c.categoryId,
        'name': c.name,
        'is_emoji': c.isEmoji,
        'count': c.stickers.length,
      },
  ],
});
