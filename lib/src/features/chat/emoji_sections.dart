// 内置表情的分组（面板「顶上的分类」与下面的段落都用这一份，唯一来源）。
//
// 反编译依据（Android-SynologyChat 2.11.1）：
//   * `EmojiPagerFragment.java:117-149` —— 面板的表情**不来自服务端**，是 APK
//     内置的 `emojione1..8` 八组；我们现在这张 `emoji_table.dart` 就是从同一份
//     `EmojiOne.java` 生成的（1787 项，每项自带分类），所以八组能原样还原。
//   * 上一版实现只画服务端 `is_emoji=true` 的分类 ⇒ 服务端不给就**一个表情都没有**，
//     给了也只是它的子集（`DA278`）。
//
// 顺序 = 官方 `emojione1..8`：people / nature / food / activity / travel /
// objects / symbols / flags。
import '../../data/emoji_table.dart';

/// 八组的固定顺序（也是面板里从上到下的段落顺序）
const List<String> kEmojiCategoryOrder = <String>[
  'people',
  'nature',
  'food',
  'activity',
  'travel',
  'objects',
  'symbols',
  'flags',
];

/// 分类的兜底文案（英文，和官方一致；翻译缺失时至少不是空白）。
///
/// 界面上的标题走 `context.t.emojiCatXxx`（本地化），这里只在拿不到译文时兜底。
String emojiCategoryFallbackLabel(String category) => switch (category) {
  'people' => 'People',
  'nature' => 'Nature',
  'food' => 'Food',
  'activity' => 'Activity',
  'travel' => 'Travel',
  'objects' => 'Objects',
  'symbols' => 'Symbols',
  'flags' => 'Flags',
  _ => category,
};

/// 一个内置表情分组：短代码清单（顺序 = `emoji_table.dart` 里的原始顺序）
class EmojiGroup {
  const EmojiGroup(this.category, this.names);

  /// `people` / `nature` / … / `flags`
  final String category;

  /// emojione 短代码，可直接发给服务端（回应要的就是它）
  final List<String> names;

  int get length => names.length;
}

List<EmojiGroup>? _groups;

/// 按 [kEmojiCategoryOrder] 分好组的内置表情（懒计算，只算一次）。
///
/// 组内顺序就是表里的顺序 —— 官方 `emojione1..8` 数组的顺序，即它定义的表情
/// 排版顺序（不是按码点排的，别自作聪明排序）。
List<EmojiGroup> emojiGroups() => _groups ??= _buildGroups();

List<EmojiGroup> _buildGroups() {
  final buckets = <String, List<String>>{
    for (final c in kEmojiCategoryOrder) c: <String>[],
  };
  for (final name in kEmojiShortcodes.keys) {
    final cat = kEmojiCategories[name];
    buckets[cat]?.add(name);
  }
  return <EmojiGroup>[
    for (final c in kEmojiCategoryOrder)
      EmojiGroup(c, List<String>.unmodifiable(buckets[c]!)),
  ];
}

/// 内置表里没有的短代码（= 服务端自定义表情）。
///
/// 服务端若下发 `is_emoji=true` 的分类，里面绝大多数名字内置表都有；只把
/// **内置表没有的**拿出来，否则同一个表情会出现两遍。
List<String> customEmojiNames(Iterable<String> names) => <String>[
  for (final n in names)
    if (!kEmojiShortcodes.containsKey(n)) n,
];

