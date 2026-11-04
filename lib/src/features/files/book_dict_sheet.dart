// 「查词」弹层：内置词表命中给词性 + 释义，查不到给明确提示（E2）。
//
// 单独成文件是为了**可离线测**：`showBookDictionarySheet(context, word: 'Books')`
// 不依赖任何 provider，widget 测试搭一个 `MaterialApp` 就能验命中/未命中两种态。
import 'package:flutter/material.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import 'book_dictionary.dart';

/// 打开查词弹层
Future<void> showBookDictionarySheet(
  BuildContext context, {
  required String word,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (_) => BookDictionarySheet(word: word),
  );
}

class BookDictionarySheet extends StatelessWidget {
  const BookDictionarySheet({super.key, required this.word});

  /// 选中的原文（可以是一句话，[lookupWord] 自己会取第一个词）
  final String word;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    final entry = lookupWord(word);
    final query = normalizeLookupWord(word);
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.menu_book_outlined,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(
                      t.bookDictTitle,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: t.photoClose,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: Gap.xs),
              if (entry == null) ...[
                // 查不到必须说清楚"是词表没有"，而不是让用户以为点错了
                Text(
                  t.bookDictNotFound(query.isEmpty ? word.trim() : query),
                  key: const Key('book-dict-notfound'),
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: Gap.xs),
                Text(
                  t.bookDictNotFoundHint,
                  style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                ),
              ] else ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      entry.word,
                      key: const Key('book-dict-word'),
                      style: theme.textTheme.titleLarge,
                    ),
                    if (entry.phonetic.isNotEmpty) ...[
                      const SizedBox(width: Gap.sm),
                      Text(
                        entry.phonetic,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: hud.dim,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: Gap.sm),
                for (final sense in entry.senses)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Gap.sm),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          margin: const EdgeInsets.only(top: 2),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.5,
                              ),
                            ),
                          ),
                          child: Text(
                            sense.pos.labelIn(t),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                        const SizedBox(width: Gap.sm),
                        Expanded(
                          child: Text(
                            sense.meaning,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
                Text(
                  t.bookDictSource(kBookDictionarySize),
                  style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
