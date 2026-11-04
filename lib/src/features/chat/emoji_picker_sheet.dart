// 表情 / 贴纸面板（`DA278`）。
//
// 反编译依据（Android-SynologyChat 2.11.1）：
//   * 表情面板 = `EmojiPagerFragment`：**内置** `emojione1..8` 八组，不依赖服务端；
//   * 贴纸面板 = `StickerPagerFragment`：服务端 `Sticker/list` 的分类；
//   * 表情点一下是**插进输入框**（`ChatUtil.insertEmojiInEditText`），贴纸点一下
//     直接发 `type=sticker` 消息。
//
// 上一版的两个毛病（用户 2026-10-25 报「emoji 不全，很多没有展示」「顶上的分类
// 定位不准」）：
//   ① 面板只画服务端 `is_emoji=true` 的分类 ⇒ 服务端不给就**一个表情都没有**
//      （真机这台 NAS 就只回了 3 个贴纸分类，面板里一个表情都看不到）；给了也只是
//      服务端那份子集。现在改成内置八组全量 1787 项 + 服务端贴纸分类；
//   ② 分类条是一个裸 `ListView`：选中项不会滚进视野、最后一个 chip 被屏幕边缘
//      切一半，而且它和下面的内容**没有任何联动** ⇒ 用户不知道自己在哪一组。
//      现在分类条与内容双向定位：点 chip 滚到那一段，滚动内容时 chip 跟着高亮
//      并自动居中。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/sticker_dto.dart';
import '../../data/emoji_table.dart';
import 'emoji_sections.dart';
import 'sticker_catalog.dart';
import 'sticker_view.dart';

/// 面板选中的东西：要么是表情短代码（插进输入框 / 当回应名），要么是一张贴纸。
class EmojiPicked {
  const EmojiPicked.emoji(this.shortcode) : sticker = null;
  const EmojiPicked.sticker(this.sticker) : shortcode = null;

  /// emojione 短代码（服务端只认它，不认字符）
  final String? shortcode;

  /// 服务端贴纸（`is_emoji=false` 的分类）
  final StickerDto? sticker;

  bool get isEmoji => shortcode != null;
}

/// 弹面板。[reactionsOnly] = 只给表情（给"表情回应"用，不要让用户以为
/// 贴纸也能当回应发出去）。
Future<EmojiPicked?> showEmojiPicker(
  BuildContext context, {
  bool reactionsOnly = false,
}) {
  return showModalBottomSheet<EmojiPicked>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => EmojiPickerSheet(reactionsOnly: reactionsOnly),
  );
}

/// 面板里的一段（表情组 / 贴纸分类）
class _Section {
  _Section({
    required this.key,
    required this.label,
    required this.names,
    required this.stickers,
  });

  final String key;
  final String label;

  /// 内置表情的短代码（画字符）；贴纸段为空
  final List<String> names;

  /// 服务端条目（贴纸段用它取图；表情段用来兜底服务端自定义表情）
  final List<StickerDto> stickers;

  bool get isEmoji => names.isNotEmpty;

  int get count => isEmoji ? names.length : stickers.length;
}

class EmojiPickerSheet extends ConsumerStatefulWidget {
  const EmojiPickerSheet({super.key, this.reactionsOnly = false});

  /// 只给表情（"表情回应"入口用）
  final bool reactionsOnly;

  @override
  ConsumerState<EmojiPickerSheet> createState() => _EmojiPickerSheetState();
}

class _EmojiPickerSheetState extends ConsumerState<EmojiPickerSheet> {
  static const double _pad = Gap.sm;
  static const double _headerH = 30;
  static const int _emojiCols = 8;
  static const int _stickerCols = 4;
  static const double _emojiGap = 2;
  static const double _stickerGap = Gap.sm;

  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _chipKeys = <String, GlobalKey>{};

  int _active = 0;

  /// 每段的起始滚动偏移（build 时按面板宽度算出来的，见 [_layout]）
  List<double> _offsets = const <double>[];
  List<_Section> _sections = const <_Section>[];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  /// 面板里每一段的高度是**算得出来的**（固定列数的网格），所以滚动定位不靠
  /// `ensureVisible`（离屏的 sliver 没有 context），直接按偏移量跳。
  void _layout(List<_Section> sections, double width) {
    _sections = sections;
    final offsets = <double>[];
    var y = 0.0;
    for (final s in sections) {
      offsets.add(y);
      final cols = s.isEmoji ? _emojiCols : _stickerCols;
      final gap = s.isEmoji ? _emojiGap : _stickerGap;
      final cell = (width - 2 * _pad - (cols - 1) * gap) / cols;
      final rows = (s.count / cols).ceil();
      final gridH = rows * cell + (rows - 1) * gap;
      y += _headerH + gridH + _pad;
    }
    _offsets = offsets;
  }

  void _onScroll() {
    if (!_scroll.hasClients || _offsets.isEmpty) return;
    final pixels = _scroll.offset;
    var active = 0;
    for (var i = 0; i < _offsets.length; i++) {
      if (_offsets[i] <= pixels + 1) active = i;
    }
    // 到底了：最后一段可能比视口短，永远达不到它的起点
    if (_scroll.position.maxScrollExtent - pixels <= 1) {
      active = _offsets.length - 1;
    }
    if (active != _active) _setActive(active);
  }

  void _setActive(int index) {
    if (index == _active || index < 0 || index >= _sections.length) return;
    setState(() => _active = index);
    // 让高亮的那颗 chip 自己滚进视野并居中（修"顶上的分类定位不准"）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _chipKeys['${_sections[index].key}#$index']?.currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: Motion.fast,
        curve: Motion.out,
      );
    });
  }

  void _jumpTo(int index) {
    if (index < 0 || index >= _offsets.length) return;
    _setActive(index);
    final target = _offsets[index].clamp(
      0.0,
      _scroll.hasClients ? _scroll.position.maxScrollExtent : double.infinity,
    );
    if (!_scroll.hasClients) return;
    _scroll.animateTo(target, duration: Motion.base, curve: Motion.out);
  }

  List<_Section> _buildSections() {
    final out = <_Section>[];
    for (final g in emojiGroups()) {
      if (g.names.isEmpty) continue;
      out.add(
        _Section(
          key: 'e:${g.category}',
          label: _labelFor(g.category),
          names: g.names,
          stickers: const <StickerDto>[],
        ),
      );
    }
    if (widget.reactionsOnly) return out;
    final cats = ref.watch(stickerCatalogProvider).value?.categories ??
        const <StickerCategoryDto>[];
    for (final c in cats) {
      if (c.stickers.isEmpty) continue;
      if (c.isEmoji) {
        // 服务端也有一份表情分类：**只留内置表没有的名字**（服务端自定义表情），
        // 否则同一个表情在面板里出现两遍
        final extra = customEmojiNames(c.stickers.map((s) => s.name));
        if (extra.isEmpty) continue;
        out.add(
          _Section(
            key: 'c:${c.categoryId}',
            label: c.name.isNotEmpty ? c.name : _labelFor('custom'),
            names: extra,
            stickers: c.stickers,
          ),
        );
        continue;
      }
      out.add(
        _Section(
          key: 's:${c.categoryId}',
          label: c.name.isNotEmpty ? c.name : 'stickers',
          names: const <String>[],
          stickers: c.stickers,
        ),
      );
    }
    return out;
  }

  String _labelFor(String category) => switch (category) {
    'people' => context.t.emojiCatPeople,
    'nature' => context.t.emojiCatNature,
    'food' => context.t.emojiCatFood,
    'activity' => context.t.emojiCatActivity,
    'travel' => context.t.emojiCatTravel,
    'objects' => context.t.emojiCatObjects,
    'symbols' => context.t.emojiCatSymbols,
    'flags' => context.t.emojiCatFlags,
    _ => emojiCategoryFallbackLabel(category),
  };

  @override
  Widget build(BuildContext context) {
    final sections = _buildSections();
    final media = MediaQuery.of(context);
    final height = (media.size.height * 0.62).clamp(320.0, 560.0);
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _layout(sections, constraints.maxWidth);
          final active = _active.clamp(0, sections.isEmpty ? 0 : sections.length - 1);
          return Column(
            children: [
              _categoryStrip(sections, active),
              const Divider(height: 1),
              Expanded(
                child: sections.isEmpty
                    ? Center(child: Text(context.t.chatStickerNoCatalog))
                    : CustomScrollView(
                        controller: _scroll,
                        slivers: [
                          for (var i = 0; i < sections.length; i++) ...[
                            SliverToBoxAdapter(
                              child: _sectionHeader(sections[i]),
                            ),
                            SliverPadding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: _pad,
                              ),
                              sliver: SliverGrid(
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: sections[i].isEmoji
                                          ? _emojiCols
                                          : _stickerCols,
                                      mainAxisSpacing: sections[i].isEmoji
                                          ? _emojiGap
                                          : _stickerGap,
                                      crossAxisSpacing: sections[i].isEmoji
                                          ? _emojiGap
                                          : _stickerGap,
                                    ),
                                delegate: SliverChildBuilderDelegate(
                                  (context, index) =>
                                      _cell(context, sections[i], index),
                                  childCount: sections[i].count,
                                ),
                              ),
                            ),
                            const SliverToBoxAdapter(
                              child: SizedBox(height: Gap.sm),
                            ),
                          ],
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _sectionHeader(_Section s) => SizedBox(
    height: _headerH,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          s.label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ),
  );

  /// 分类条：横滑 chip。`SingleChildScrollView` 会把所有 chip 都布局出来，
  /// 所以能按 key 让选中的那颗居中（裸 `ListView` 做不到，离屏的没有 context）。
  Widget _categoryStrip(List<_Section> sections, int active) {
    return SizedBox(
      height: 48,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
        child: Row(
          children: [
            for (var i = 0; i < sections.length; i++)
              Padding(
                key: _chipKeys.putIfAbsent(
                  '${sections[i].key}#$i',
                  GlobalKey.new,
                ),
                padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
                child: Center(
                  child: ChoiceChip(
                    label: Text(sections[i].label),
                    selected: i == active,
                    onSelected: (_) => _jumpTo(i),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _cell(BuildContext context, _Section section, int index) {
    if (section.isEmoji) {
      final name = section.names[index];
      final ch = kEmojiShortcodes[name];
      if (ch == null) {
        // 内置表没有的自定义表情：回落到服务端图
        StickerDto? dto;
        for (final s in section.stickers) {
          if (s.name == name) {
            dto = s;
            break;
          }
        }
        return Center(
          child: dto == null
              ? Text(':$name:')
              : StickerView(stickerId: dto.stickerId, size: '4x', edge: 36),
        );
      }
      return InkWell(
        onTap: () => Navigator.of(context).pop(EmojiPicked.emoji(name)),
        child: Center(
          child: Text(
            ch,
            style: const TextStyle(fontSize: 24),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final s = section.stickers[index];
    return InkWell(
      onTap: () => Navigator.of(context).pop(EmojiPicked.sticker(s)),
      child: StickerView(stickerId: s.stickerId, size: '2x', edge: 56),
    );
  }
}
