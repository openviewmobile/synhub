// 笔记的**双向冲突**裁决页（P1 续 · NoteStation）。
//
// 什么时候会出现：离线改了一条笔记（`dirty`，队列里攒着 `set`），与此同时
// 服务端/别的客户端也改了同一条 —— 服务端 `ver` 已经不是我们改动前那个版本。
// 同步时 `note_store.mergeNoteList` 探测出来（见 `NoteConflictDraft`），
// `note_sync` 顺手把服务端正文抓下来，这里让用户**看着两边内容**选：
//
//   * 保留我的 → `Note/set` 带上服务端最新 `ver`（覆盖服务端），本地队列清掉；
//   * 用服务端的 → 扔掉本地待推送改动，把服务端正文写回缓存。
//
// 官方 App 有更细的合并（`Note.Polling` + Ghost），我们只做"二选一"，
// 但**绝不静默丢改动**：不选就留着，下次同步还会出现。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/user_facing_error.dart';
import 'note_body.dart';
import 'note_sync.dart';

class NoteConflictPage extends ConsumerStatefulWidget {
  const NoteConflictPage({super.key});

  @override
  ConsumerState<NoteConflictPage> createState() => _NoteConflictPageState();
}

class _NoteConflictPageState extends ConsumerState<NoteConflictPage> {
  int _index = 0;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final conflicts = ref.watch(noteSyncProvider).conflicts;
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(
          conflicts.isEmpty
              ? context.t.noteConflictTitle
              : context.t.noteConflictTitleCount(conflicts.length),
        ),
      ),
      body: conflicts.isEmpty
          ? AppEmptyState(
              icon: Icons.check_circle_outline,
              title: context.t.noteNoConflicts,
              message: context.t.noteNoConflictsMessage,
            )
          : _body(context, hud, conflicts),
    );
  }

  Widget _body(BuildContext context, DesignPalette hud, List<NoteConflict> list) {
    final index = _index.clamp(0, list.length - 1);
    final c = list[index];
    return Column(
      children: [
        if (list.length > 1)
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
              itemCount: list.length,
              separatorBuilder: (_, _) => const SizedBox(width: Gap.xs),
              itemBuilder: (context, i) => Center(
                child: ChoiceChip(
                  label: Text(
                    list[i].title.isEmpty
                        ? context.t.noteConflictUntitled(i + 1)
                        : list[i].title,
                  ),
                  selected: i == index,
                  onSelected: (_) => setState(() => _index = i),
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_outlined, size: 16),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(
                  context.t.noteConflictExplain,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: hud.dim),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Gap.sm),
        Expanded(
          child: DefaultTabController(
            length: 2,
            child: Column(
              children: [
                TabBar(
                  tabs: [
                    Tab(text: context.t.noteConflictLocal),
                    Tab(text: context.t.noteConflictServer),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _preview(
                        context,
                        c.localContent,
                        hud,
                        emptyHint: context.t.noteConflictLocalEmpty,
                      ),
                      _preview(
                        context,
                        c.serverContent,
                        hud,
                        emptyHint: c.serverFetched
                            ? context.t.noteConflictServerEmpty
                            : context.t.noteConflictServerFetchFailed,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(Gap.md),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const Key('note-conflict-keep-local'),
                    onPressed: _busy
                        ? null
                        : () => _resolve(c, keepLocal: true),
                    child: Text(context.t.noteConflictKeepLocal),
                  ),
                ),
                const SizedBox(width: Gap.sm),
                // ★ 124 轮 / M5：官方冲突处理 = **把本地那版另存成副本**
                //   （`<标题> Conflict`，默认笔记本），两边都不丢。
                Expanded(
                  child: OutlinedButton(
                    key: const Key('note-conflict-keep-both'),
                    onPressed: _busy
                        ? null
                        : () => _resolve(c, keepLocal: null),
                    child: Text(
                      dataText('noteConflictKeepBoth', '两个都保留'),
                    ),
                  ),
                ),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: FilledButton(
                    key: const Key('note-conflict-use-server'),
                    onPressed: _busy
                        ? null
                        : () => _resolve(c, keepLocal: false),
                    child: Text(context.t.noteConflictUseServer),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 正文预览：走笔记详情同一套 HTML → 只读渲染（样式一致，别自己造）
  Widget _preview(
    BuildContext context,
    String html,
    DesignPalette hud, {
    required String emptyHint,
  }) {
    if (html.trim().isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Text(
            emptyHint,
            textAlign: TextAlign.center,
            style: TextStyle(color: hud.dim),
          ),
        ),
      );
    }
    // ⚠️ Quill 需要**有界**高度：别套 SingleChildScrollView（正文自己滚）
    return Padding(
      padding: const EdgeInsets.all(Gap.md),
      // 和笔记详情用同一个只读渲染器（样式/附件一致，别自己造一套）
      child: NoteBody(html: html, padding: EdgeInsets.zero),
    );
  }

  /// [keepLocal] = `true` 用本地、`false` 用服务端、**`null` 两个都保留**
  /// （官方策略：本地另存为副本，原笔记取服务端版）。
  Future<void> _resolve(NoteConflict c, {required bool? keepLocal}) async {
    final t = context.t;
    final sync = ref.read(noteSyncProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      if (keepLocal == null) {
        await sync.keepBothOnConflict(c);
      } else if (keepLocal) {
        await sync.resolveWithLocal(c);
      } else {
        await sync.resolveWithServer(c);
      }
      final left = ref.read(noteSyncProvider).conflicts.length;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            switch (keepLocal) {
              null => dataText('noteConflictKeptBoth', '两边都保留了'),
              true => t.noteConflictUsedLocal,
              false => t.noteConflictUsedServer,
            },
          ),
        ),
      );
      if (left == 0 && mounted) Navigator.of(context).maybePop();
    } catch (e) {
      // 以前这里没有 catch：处理失败（网络/版本冲突）会被**静默吞掉**，
      // 用户只看到按钮恢复可点、却不知道刚才那次为什么没生效。
      // 现在如实报错，并给一个**可点的重试入口**（再走同一条裁决）。
      logErrorForDiagnostics('note_conflict.resolve', e);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            t.calTodoActionFailed(
              userFacingError(e, fallback: t.noteConflictResolveIncomplete),
            ),
          ),
          action: SnackBarAction(
            label: t.photoRetry,
            onPressed: () => _resolve(c, keepLocal: keepLocal),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
