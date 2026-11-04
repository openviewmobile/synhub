// EPUB 章节 / PDF 书签**共用的目录面板**。
//
// 为什么要抽成一个：EPUB 阅读器和 PDF 阅读器各自写了一套目录面板，样式、计数文案、
// 空态、缩进规则都不一样（PDF 那套连筛选都没有）。用户要求"PDF 目录的界面风格和
// EPUB 用同一套"，所以这里把面板本身收口：两个阅读器只负责把自己那份目录
// **翻译成 [TocEntry]**，其余（标题行、筛选、层级缩进、当前项高亮、空态）都在这里。
//
// 于是有一个统一契约：不管目录来自 epub 的 `nav.xhtml` 还是 PDF 的 `/Outlines`，
// 用户看到的是同一个面板、同一套键位（`book-toc-filter` / `book-toc-list`），
// 自动化测试也只需要一套断言。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';

/// 目录面板里的一条。
///
/// [index] 的含义由调用方解释：EPUB 是章节下标，PDF 是 **0 基页码** ——
/// 面板不关心它是什么，只是回传给 [showBookTocSheet] 的 `onPick`。
class TocEntry {
  const TocEntry({
    required this.title,
    this.depth = 0,
    this.index,
    this.trailing,
    this.current = false,
    this.enabled = true,
  });

  final String title;

  /// 0 = 顶层（层级靠左缩进表达）
  final int depth;

  /// 调用方自己解释的载荷（EPUB = 章节下标；PDF = 0 基页码）
  final int? index;

  /// 右侧的补充信息（PDF 用来看页码；EPUB 一般留空）
  final String? trailing;

  /// 是不是"当前所在的那一条"（当前章 / 当前页）→ 高亮 + 定位图标
  final bool current;

  /// 目标丢了（例如 PDF 命名目标解析不到页）→ 灰显、点不动
  final bool enabled;
}

/// 弹出目录面板。
///
/// * [sourceLabel]：目录来源说明（`原书目录` / `书签`）；为 null 时用
///   [fallbackUnitLabel] 拼"按顺序列的章节"那种计数（`12 章`）。
/// * [onPick]：选中一条（点完自动关面板）
Future<void> showBookTocSheet(
  BuildContext context, {
  required List<TocEntry> entries,
  required ValueChanged<TocEntry> onPick,
  String? sourceLabel,
  String? fallbackUnitLabel,
  String? filterHint,
}) {
  final theme = Theme.of(context);
  final hud = DesignPalette.of(context);
  final t = context.t;
  final unit = fallbackUnitLabel ?? t.bookTocUnit;
  final hint = filterHint ?? t.bookTocFilterHint;
  final filter = TextEditingController();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheet) {
        // 目录内搜索：只筛标题（目录本来就短，够用）
        final q = filter.text.trim().toLowerCase();
        final shown = q.isEmpty
            ? entries
            : [
                for (final e in entries)
                  if (e.title.toLowerCase().contains(q)) e,
              ];
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          builder: (context, scroll) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Gap.md,
                  Gap.sm,
                  Gap.xs,
                  Gap.xs,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        t.bookTocTitle,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    Text(
                      q.isEmpty
                          ? (sourceLabel == null
                                ? '${shown.length} $unit'
                                : t.bookTocCount(shown.length, sourceLabel))
                          : t.bookTocCountFiltered(
                              shown.length,
                              entries.length,
                            ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: hud.dim,
                      ),
                    ),
                    IconButton(
                      tooltip: t.photoClose,
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                child: TextField(
                  key: const Key('book-toc-filter'),
                  controller: filter,
                  onChanged: (_) => setSheet(() {}),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: hint,
                    prefixIcon: const Icon(Icons.filter_alt_outlined, size: 18),
                  ),
                ),
              ),
              const SizedBox(height: Gap.xs),
              const Divider(height: 1),
              Expanded(
                child: shown.isEmpty
                    ? Center(
                        child: Text(
                          t.bookTocNoMatch(filter.text.trim()),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: hud.dim,
                          ),
                        ),
                      )
                    : ListView.builder(
                        key: const Key('book-toc-list'),
                        controller: scroll,
                        itemCount: shown.length,
                        itemBuilder: (context, i) {
                          final e = shown[i];
                          return DesignRowTile(
                            dense: true,
                            enabled: e.enabled,
                            selected: e.current,
                            // 层级靠左缩进表达，最多缩 6 层（再深就没地方了）
                            contentPadding: EdgeInsets.only(
                              left: Gap.md + Gap.sm * e.depth.clamp(0, 6),
                              right: Gap.md,
                            ),
                            leading: e.current
                                ? Icon(
                                    Icons.my_location,
                                    size: 16,
                                    color: theme.colorScheme.primary,
                                  )
                                : null,
                            title: Text(
                              e.title.isEmpty ? t.calNoTitle : e.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: e.depth == 0
                                  ? theme.textTheme.bodyMedium
                                  : theme.textTheme.bodySmall?.copyWith(
                                      color: e.current
                                          ? theme.colorScheme.primary
                                          : hud.dim,
                                    ),
                            ),
                            trailing: e.trailing == null
                                ? null
                                : Text(
                                    e.trailing!,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: hud.dim,
                                    ),
                                  ),
                            onTap: !e.enabled
                                ? null
                                : () {
                                    Navigator.of(context).pop();
                                    onPick(e);
                                  },
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
