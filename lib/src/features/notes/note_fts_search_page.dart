// G1：笔记**全文检索**页（`SYNO.NoteStation.FTS : search` v1）。
//
// 与笔记列表页的"本地过滤"不同：这一页只认**服务端** FTS 结果（root
// `data.matches`），因为官方 Universal Search 插件就是这么取的。三条纪律：
//   1. 空关键字**不发请求**（进页面就有明确提示，不是空白）；
//   2. 0 条给**明确空态**（不是"加载中"或"出错了"）；
//   3. 失败**如实报错**（带服务端错误码描述），不静默回落本地过滤。
//
// 内部 id（`object_id`）只用于 Key 与跳转，不进标题/副标题（`NoteRow` 只画
// title / 时间 / 笔记本），符合"内部 id 不上屏"的口径。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/note_dto.dart';
import 'note_view_page.dart';
import 'note_wave4_providers.dart';
import 'note_wave4_text.dart';
import 'note_widgets.dart';

class NoteFtsSearchPage extends ConsumerStatefulWidget {
  const NoteFtsSearchPage({super.key});

  @override
  ConsumerState<NoteFtsSearchPage> createState() => _NoteFtsSearchPageState();
}

class _NoteFtsSearchPageState extends ConsumerState<NoteFtsSearchPage> {
  final _ctrl = TextEditingController();

  /// **已提交**的关键词（不是输入框的实时值）—— 每次按键都发一次 FTS 是浪费，
  /// 而且会让"空关键字不发请求"这条纪律变得不可断言。
  String _keyword = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _ctrl.text.trim();
    if (value == _keyword) return;
    setState(() => _keyword = value);
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final hint = noteWave4(NoteWave4TextKeys.ftsHint, '按标题、正文、附件文本检索');
    final rows = _keyword.isEmpty
        ? const AsyncValue<List<NoteDto>>.data(<NoteDto>[])
        : ref.watch(noteFtsSearchProvider(_keyword));
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(noteWave4(NoteWave4TextKeys.ftsTitle, '全文检索')),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm),
            child: TextField(
              key: const Key('note-fts-field'),
              controller: _ctrl,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: hint,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  key: const Key('note-fts-submit'),
                  tooltip: noteWave4(NoteWave4TextKeys.ftsTitle, '全文检索'),
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: _submit,
                ),
              ),
              onSubmitted: (_) => _submit(),
              onChanged: (_) {
                // 清空输入框 → 立刻回到"未检索"提示态（也不发请求）
                if (_ctrl.text.trim().isEmpty && _keyword.isNotEmpty) {
                  setState(() => _keyword = '');
                }
              },
            ),
          ),
          Expanded(
            child: _keyword.isEmpty
                ? AppEmptyState(
                    key: const Key('note-fts-prompt'),
                    icon: Icons.manage_search,
                    title: noteWave4(
                      NoteWave4TextKeys.ftsPrompt,
                      '输入关键词开始检索',
                    ),
                    message: hint,
                  )
                : rows.when(
                    loading: () => const AppListSkeleton(),
                    error: (e, __) => AppErrorView(
                      key: const Key('note-fts-error'),
                      title: noteWave4(NoteWave4TextKeys.ftsFailed, '检索失败'),
                      detail: describeNoteError(e, context.t),
                      onRetry: () =>
                          ref.invalidate(noteFtsSearchProvider(_keyword)),
                    ),
                    data: (matches) => matches.isEmpty
                        ? AppEmptyState(
                            key: const Key('note-fts-empty'),
                            icon: Icons.search_off,
                            title: noteWave4(
                              NoteWave4TextKeys.ftsEmpty,
                              '没有匹配的笔记',
                            ),
                            message: noteWave4(
                              NoteWave4TextKeys.ftsEmptyHint,
                              '换个关键词试试；若服务端未启用全文检索，可回到列表页按标题过滤',
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.only(bottom: 96),
                            itemCount: matches.length,
                            separatorBuilder: (_, __) => Divider(
                              height: 1,
                              indent: Gap.lg * 2,
                              color: hud.line,
                            ),
                            itemBuilder: (context, i) {
                              final note = matches[i];
                              return NoteRow(
                                key: Key('note-fts-row-${note.objectId}'),
                                note: note,
                                onTap: () =>
                                    Navigator.of(
                                      context,
                                      rootNavigator: true,
                                    ).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => NoteViewPage(note: note),
                                      ),
                                    ),
                              );
                            },
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}
