// G3 笔记**高级搜索**面板（多条件组合：关键词 / 标题 / 标签（+操作符）/ 排除标签
// 及其子标签 / 笔记本 / 修改时间 / 创建时间）。
//
// ## 数据来源与纪律
//
// * 搜索走**服务端** `SYNO.NoteStation.FTS / search` v1，只用**行为已取证**的参数
//   （见 `NoteStationApi.searchNotes` 的文档与 `note_adv_search.dart` 顶部）：
//   `keyword` / `title` / `tag`(标签 id) / `parent_id` /
//   `mtime_start`/`mtime_end`/`ctime_start`/`ctime_end` / `offset` / `limit`。
//   **绝不发** `note_title` / `notebook` / `date_from` / `date_to` 这些被服务端
//   静默忽略的名字。
// * G7「排除标签及其子标签」是**客户端**行为（服务端无对应参数，行为对照已证：
//   `tag_exclude_subtag` / `exclude_tag` / `exclude_tags` 全被忽略）；实现见
//   `NoteAdvSearchQuery.clientExcludedNoteIds`——用 `Tag/list` 每个标签的
//   直接成员做集合运算，不依赖 `Note/list` 不返回的 `tag` 字段。
// * 文案一律**用户语言**：界面上不出现任何 API 名/参数名/内部 id
//   （`NoteRow` 也只画标题/时间/笔记本；标签选的是**标题**）。
//
// ## 三种结果态（与全仓通例一致）
//   1. 没搜过 → 明确提示（不是空白，也不是"加载中"）；
//   2. 搜到 0 条 → 明确空态；
//   3. 失败 → 如实报错（带服务端错误码描述），不静默回落。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/note_dto.dart';
import 'note_adv_search.dart';
import 'note_adv_search_text.dart';
import 'note_providers.dart';
import 'note_view_page.dart';
import 'note_widgets.dart';

class NoteAdvSearchPage extends ConsumerStatefulWidget {
  const NoteAdvSearchPage({super.key});

  @override
  ConsumerState<NoteAdvSearchPage> createState() => _NoteAdvSearchPageState();
}

class _NoteAdvSearchPageState extends ConsumerState<NoteAdvSearchPage> {
  NoteAdvSearchQuery _query = const NoteAdvSearchQuery();

  bool _busy = false;

  /// 搜索失败（网络/权限/服务端错误）——整块错误态 + 可重试。
  String? _error;

  /// 表单校验错误（日期区间非法）——贴在表单下方的行内提示，不是"搜索失败"。
  String? _validationError;

  /// `null` = 还没搜过（提示态）；空列表 = 搜过但 0 条（空态）。
  List<NoteDto>? _results;

  List<TagDto> get _tags =>
      ref.watch(noteTagsProvider).value ?? const <TagDto>[];
  List<NotebookDto> get _notebooks =>
      ref.watch(notebooksProvider).value ?? const <NotebookDto>[];

  void _set(NoteAdvSearchQuery next) {
    setState(() {
      _query = next;
      _error = null;
      _validationError = null;
    });
  }

  void _clear() {
    setState(() {
      _query = const NoteAdvSearchQuery();
      _results = null;
      _error = null;
      _validationError = null;
    });
  }

  Future<void> _run() async {
    final t = context.t;
    final dateError =
        noteAdvSearchDateOrderError(_query.mtimeFrom, _query.mtimeTo) ??
        noteAdvSearchDateOrderError(_query.ctimeFrom, _query.ctimeTo);
    if (dateError != null) {
      setState(
        () => _validationError = noteAdv(
          NoteAdvTextKeys.dateInvalid,
          '起始日期不能晚于结束日期',
        ),
      );
      return;
    }
    if (_query.isEmpty) return;

    final api = ref.read(noteApiProvider);
    if (api == null) {
      setState(() => _error = t.setNotConnected);
      return;
    }

    final tags = ref.read(noteTagsProvider).value ?? const <TagDto>[];
    final tagIdByTitle = {for (final tg in tags) tg.title: tg.tagId};

    setState(() {
      _busy = true;
      _error = null;
      _validationError = null;
      _results = null;
    });
    try {
      final raw = await api.searchNotes(
        keyword: _query.keyword,
        title: _query.title,
        tagIds: _query.resolvedTagIds(tagIdByTitle),
        parentIds: _query.parentIds,
        mtimeStart: _query.mtimeFromSeconds,
        mtimeEnd: _query.mtimeToSeconds,
        ctimeStart: _query.ctimeFromSeconds,
        ctimeEnd: _query.ctimeToSeconds,
        limit: 200,
      );
      // G7：客户端把"被排除的标签及其子标签"下的笔记摘掉。
      final excluded = _query.clientExcludedNoteIds(
        tags.map((tg) => (title: tg.title, itemIds: tg.itemIds)),
      );
      final rows = applyNoteIdExclusions(raw, (n) => n.objectId, excluded);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _results = rows;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeNoteError(e, t);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(noteAdv(NoteAdvTextKeys.title, '高级搜索')),
        actions: [
          if (_query.isNotEmpty)
            IconButton(
              key: const Key('note-adv-clear'),
              tooltip: noteAdv(NoteAdvTextKeys.clear, '清空条件'),
              icon: const Icon(Icons.filter_alt_off_outlined),
              onPressed: _clear,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 96),
        children: [
          _form(hud),
          const SizedBox(height: Gap.lg),
          _resultBody(hud),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- 条件表单

  Widget _form(DesignPalette hud) {
    final tags = _tags;
    final notebooks = _notebooks;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const Key('note-adv-keyword'),
          onChanged: (v) => _set(_query.copyWith(keyword: v)),
          decoration: InputDecoration(
            labelText: noteAdv(NoteAdvTextKeys.keyword, '关键词'),
            hintText: noteAdv(
              NoteAdvTextKeys.keywordHint,
              '在标题、正文和附件文字里查找',
            ),
            prefixIcon: const Icon(Icons.search),
          ),
        ),
        const SizedBox(height: Gap.md),
        TextField(
          key: const Key('note-adv-title'),
          onChanged: (v) => _set(_query.copyWith(title: v)),
          decoration: InputDecoration(
            labelText: noteAdv(NoteAdvTextKeys.titleLabel, '标题包含'),
            hintText: noteAdv(NoteAdvTextKeys.titleHint, '例如：周报'),
          ),
        ),

        // ---- 标签（G4 操作符）----
        const SizedBox(height: Gap.lg),
        _section(
          hud,
          noteAdv(NoteAdvTextKeys.tags, '标签'),
          child: tags.isEmpty
              ? Text(
                  noteAdv(NoteAdvTextKeys.tagsAny, '不限'),
                  style: TextStyle(color: hud.dim),
                )
              : Wrap(
                  spacing: Gap.sm,
                  runSpacing: Gap.xs,
                  children: [
                    for (final tg in tags)
                      FilterChip(
                        key: Key('note-adv-tag-${tg.title}'),
                        label: Text(tg.title),
                        selected: _query.tagTitles.contains(tg.title),
                        onSelected: (on) {
                          final next = [..._query.tagTitles];
                          on ? next.add(tg.title) : next.remove(tg.title);
                          _set(_query.copyWith(tagTitles: next));
                        },
                      ),
                  ],
                ),
        ),
        if (_query.tagTitles.length > 1)
          Row(
            children: [
              for (final (value, label, key) in [
                (
                  true,
                  noteAdv(NoteAdvTextKeys.tagAnd, '同时包含所选标签'),
                  const Key('note-adv-tag-and'),
                ),
                (
                  false,
                  noteAdv(NoteAdvTextKeys.tagOr, '包含任一标签'),
                  const Key('note-adv-tag-or'),
                ),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: Gap.sm),
                  child: ChoiceChip(
                    key: key,
                    label: Text(label),
                    selected: _query.tagAndOperator == value,
                    onSelected: (_) =>
                        _set(_query.copyWith(tagAndOperator: value)),
                  ),
                ),
            ],
          ),
        if (_query.tagTitles.isNotEmpty)
          DesignSwitchRow(
            key: const Key('note-adv-subtags'),
            contentPadding: EdgeInsets.zero,
            value: _query.includeSubTags,
            onChanged: (v) => _set(_query.copyWith(includeSubTags: v)),
            title: Text(noteAdv(NoteAdvTextKeys.includeSubTags, '包含子标签')),
            subtitle: Text(
              noteAdv(
                NoteAdvTextKeys.includeSubTagsHint,
                '关闭后只显示恰好带有所选标签的笔记',
              ),
              style: TextStyle(color: hud.dim, fontSize: 12),
            ),
          ),

        // ---- G7：排除标签（连子标签一起）----
        const SizedBox(height: Gap.md),
        _section(
          hud,
          noteAdv(NoteAdvTextKeys.excludeTags, '排除标签'),
          hint: noteAdv(
            NoteAdvTextKeys.excludeTagsHint,
            '被排除的标签连同它的子标签一起排除',
          ),
          child: tags.isEmpty
              ? Text(
                  noteAdv(NoteAdvTextKeys.tagsAny, '不限'),
                  style: TextStyle(color: hud.dim),
                )
              : Wrap(
                  spacing: Gap.sm,
                  runSpacing: Gap.xs,
                  children: [
                    for (final tg in tags)
                      FilterChip(
                        key: Key('note-adv-exclude-${tg.title}'),
                        label: Text(tg.title),
                        selected: _query.excludeTagTitles.contains(tg.title),
                        onSelected: (on) {
                          final next = [..._query.excludeTagTitles];
                          on ? next.add(tg.title) : next.remove(tg.title);
                          _set(_query.copyWith(excludeTagTitles: next));
                        },
                      ),
                  ],
                ),
        ),

        // ---- 笔记本 ----
        const SizedBox(height: Gap.md),
        _section(
          hud,
          noteAdv(NoteAdvTextKeys.notebooks, '笔记本'),
          child: notebooks.isEmpty
              ? Text(
                  noteAdv(NoteAdvTextKeys.notebooksAny, '全部笔记本'),
                  style: TextStyle(color: hud.dim),
                )
              : Wrap(
                  spacing: Gap.sm,
                  runSpacing: Gap.xs,
                  children: [
                    for (final nb in notebooks)
                      FilterChip(
                        key: Key('note-adv-nb-${nb.objectId}'),
                        label: Text(nb.displayTitle),
                        selected: _query.parentIds.contains(nb.objectId),
                        onSelected: (on) {
                          final next = [..._query.parentIds];
                          on
                              ? next.add(nb.objectId)
                              : next.remove(nb.objectId);
                          _set(_query.copyWith(parentIds: next));
                        },
                      ),
                  ],
                ),
        ),

        // ---- 时间区间 ----
        const SizedBox(height: Gap.md),
        _dateRow(
          hud,
          label: noteAdv(NoteAdvTextKeys.timeModified, '修改时间'),
          from: _query.mtimeFrom,
          to: _query.mtimeTo,
          fromKey: const Key('note-adv-mtime-from'),
          toKey: const Key('note-adv-mtime-to'),
          onFrom: (d) => d == null
              ? _set(_query.copyWith(clearMtimeFrom: true))
              : _set(_query.copyWith(mtimeFrom: d)),
          onTo: (d) => d == null
              ? _set(_query.copyWith(clearMtimeTo: true))
              : _set(_query.copyWith(mtimeTo: d)),
        ),
        const SizedBox(height: Gap.sm),
        _dateRow(
          hud,
          label: noteAdv(NoteAdvTextKeys.timeCreated, '创建时间'),
          from: _query.ctimeFrom,
          to: _query.ctimeTo,
          fromKey: const Key('note-adv-ctime-from'),
          toKey: const Key('note-adv-ctime-to'),
          onFrom: (d) => d == null
              ? _set(_query.copyWith(clearCtimeFrom: true))
              : _set(_query.copyWith(ctimeFrom: d)),
          onTo: (d) => d == null
              ? _set(_query.copyWith(clearCtimeTo: true))
              : _set(_query.copyWith(ctimeTo: d)),
        ),

        if (_validationError != null) ...[
          const SizedBox(height: Gap.md),
          Text(
            _validationError!,
            key: const Key('note-adv-form-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],

        const SizedBox(height: Gap.lg),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                key: const Key('note-adv-run'),
                onPressed: _busy ? null : _run,
                icon: const Icon(Icons.search),
                label: Text(noteAdv(NoteAdvTextKeys.run, '搜索')),
              ),
            ),
            const SizedBox(width: Gap.sm),
            TextButton(
              key: const Key('note-adv-reset'),
              onPressed: _busy ? null : _clear,
              child: Text(noteAdv(NoteAdvTextKeys.clear, '清空条件')),
            ),
          ],
        ),
      ],
    );
  }

  Widget _section(
    DesignPalette hud,
    String title, {
    required Widget child,
    String? hint,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: TextStyle(color: hud.dim, fontSize: 12)),
      if (hint != null)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(hint, style: TextStyle(color: hud.dim, fontSize: 11)),
        ),
      const SizedBox(height: Gap.xs),
      child,
    ],
  );

  Widget _dateRow(
    DesignPalette hud, {
    required String label,
    required DateTime? from,
    required DateTime? to,
    required Key fromKey,
    required Key toKey,
    required ValueChanged<DateTime?> onFrom,
    required ValueChanged<DateTime?> onTo,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: TextStyle(color: hud.dim, fontSize: 12)),
      const SizedBox(height: Gap.xs),
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              key: fromKey,
              onPressed: () => _pick(onFrom, from),
              child: Text(
                from == null
                    ? noteAdv(NoteAdvTextKeys.dateFrom, '起始日期')
                    : _fmt(from),
              ),
            ),
          ),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: OutlinedButton(
              key: toKey,
              onPressed: () => _pick(onTo, to),
              child: Text(
                to == null
                    ? noteAdv(NoteAdvTextKeys.dateTo, '结束日期')
                    : _fmt(to),
              ),
            ),
          ),
        ],
      ),
    ],
  );

  Future<void> _pick(ValueChanged<DateTime?> onPicked, DateTime? current) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? now,
      firstDate: DateTime(now.year - 30),
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null) onPicked(picked);
  }

  String _fmt(DateTime d) => '${d.year}-${d.month}-${d.day}';

  // --------------------------------------------------------------- 结果区

  Widget _resultBody(DesignPalette hud) {
    if (_busy) return const AppListSkeleton();
    if (_error != null) {
      return AppErrorView(
        key: const Key('note-adv-error'),
        title: noteAdv(NoteAdvTextKeys.failed, '搜索失败'),
        detail: _error,
        onRetry: _run,
      );
    }
    final rows = _results;
    if (rows == null) {
      return AppEmptyState(
        key: const Key('note-adv-prompt'),
        icon: Icons.manage_search,
        title: noteAdv(NoteAdvTextKeys.prompt, '设置条件后开始搜索'),
        message: noteAdv(NoteAdvTextKeys.promptHint, '至少设置一个条件'),
      );
    }
    if (rows.isEmpty) {
      return AppEmptyState(
        key: const Key('note-adv-empty'),
        icon: Icons.search_off,
        title: noteAdv(NoteAdvTextKeys.empty, '没有符合条件的笔记'),
        message: noteAdv(
          NoteAdvTextKeys.emptyHint,
          '换个关键词或放宽条件试试',
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          noteAdvFill(NoteAdvTextKeys.resultsCount, '{count} 条结果', {
            'count': '${rows.length}',
          }),
          key: const Key('note-adv-count'),
          style: TextStyle(color: hud.dim, fontSize: 12),
        ),
        const SizedBox(height: Gap.xs),
        for (final note in rows)
          NoteRow(
            key: Key('note-adv-row-${note.objectId}'),
            note: note,
            onTap: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                builder: (_) => NoteViewPage(note: note),
              ),
            ),
          ),
      ],
    );
  }
}
