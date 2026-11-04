// Download Station **BT 搜索**页（wave4）。
//
// 数据/状态机在 `download_bt_search_providers.dart`；API 在 `download_station.dart`。
//
// 硬约束（任务书）：
//   * **老代优先**：`getModule` → 模块**多选**（只显示 `enabled:true` 的）→
//     搜索结果列表；`finished` 轮询（5 秒、有上限、离开即停）；
//   * 结果展示：`title` / **`size` 按字节格式化**（`dsHumanBytes`）/ `date` /
//     `seeds` / `peers` / **`module_title`**（显示名）；
//   * **r388/DA35：结果行有「下载」入口**（`Task.create type=url url=[magnet]`，
//     即官方 `download_now`）。★ **必须带 `destination`** —— 官方前端
//     `downloadSelected` 逐字是 `{type:"url", url:c, destination:a, create_list:false}`，
//     且 `if(!Ext.isDefined(a)){return}`（**没目录连请求都不发**）。我第一次漏了
//     `destination` ⇒ 真机 `120 Invalid request parameter`（台账 r388 §S2.3）。
//     目录取「设置里的默认下载目录」；万一取不到 ⇒ 交给「新建任务」页确认目录。
//     ★ 官方 `download_to`（选目录）没做，改目录仍走「新建任务」页（见台账 r388）
//   * **绝不显示任何内部 id**（`taskid` / `id` / `module_id` 只存在于状态里，
//     本文件从不把它们渲染成文本）；
//   * 能力缺失 → 入口被隐藏（`download_page.dart` 门控），这里只做空态说明。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/download_task_dto.dart';
import '../../core/user_facing_error.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../shell/capability_hint.dart';
import 'download_bt_search_providers.dart';
import 'download_create_page.dart';
import 'download_providers.dart';
import '../../core/theme/app_theme.dart';

class DownloadBtSearchPage extends ConsumerStatefulWidget {
  const DownloadBtSearchPage({super.key});

  @override
  ConsumerState<DownloadBtSearchPage> createState() =>
      _DownloadBtSearchPageState();
}

class _DownloadBtSearchPageState extends ConsumerState<DownloadBtSearchPage> {
  final _keyword = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(btSearchProvider.notifier).loadSources();
    });
  }

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  void _runSearch() {
    final kw = _keyword.text.trim();
    if (kw.isEmpty) return;
    FocusScope.of(context).unfocus();
    // 不 await：状态机自己推进；页面只消费状态。
    ref.read(btSearchProvider.notifier).search(keyword: kw);
    trackOnce(
      UsageModule.downloads,
      UsageAction.search,
      objectType: 'bt',
      value: 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(btSearchProvider);
    return DesignScaffold(
      appBar: AppBar(
        title: Text(dataText('dsBtSearchTitle', 'BT 搜索')),
        leading: IconButton(
          key: const Key('ds-bt-back'),
          tooltip: dataText('dsBtBack', '返回'),
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            // 主动离开：打断轮询（autoDispose 的 onDispose 是兜底第二道）。
            ref.read(btSearchProvider.notifier).cancelSearch();
            Navigator.of(context, rootNavigator: true).maybePop();
          },
        ),
        actions: [
          // D1：结果排序（客户端排序，见 provider `sortedEntries` 的说明）
          PopupMenuButton<String>(
            key: const Key('ds-bt-sort'),
            tooltip: dataText('dsBtSort', '排序'),
            icon: const Icon(Icons.sort),
            onSelected: (v) {
              if (v == 'toggle') {
                ref.read(btSearchProvider.notifier).toggleSortDirection();
              } else {
                ref.read(btSearchProvider.notifier).setSort(v);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                key: const Key('ds-bt-sort-default'),
                value: '',
                child: Text(dataText('dsBtSortDefault', '默认顺序')),
              ),
              PopupMenuItem(
                key: const Key('ds-bt-sort-title'),
                value: 'title',
                child: Text(dataText('dsBtSortTitle', '按名称')),
              ),
              PopupMenuItem(
                key: const Key('ds-bt-sort-size'),
                value: 'size',
                child: Text(dataText('dsBtSortSize', '按大小')),
              ),
              PopupMenuItem(
                key: const Key('ds-bt-sort-seeds'),
                value: 'seeds',
                child: Text(dataText('dsBtSortSeeds', '按做种数')),
              ),
              PopupMenuItem(
                key: const Key('ds-bt-sort-date'),
                value: 'date',
                child: Text(dataText('dsBtSortDate', '按日期')),
              ),
              PopupMenuItem(
                key: const Key('ds-bt-sort-toggle'),
                value: 'toggle',
                child: Text(
                  s.sortDescending
                      ? dataText('dsBtSortAsc', '改为升序')
                      : dataText('dsBtSortDesc', '改为降序'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _SearchBar(controller: _keyword, state: s, onSubmit: _runSearch),
          // D2：服务端 `list_category` 的分类（为空则整条不出现）
          if (s.categories.isNotEmpty) _CategorySelector(state: s),
          if (s.sourcesLoaded && s.sources.isNotEmpty)
            _ModuleSelector(state: s),
          if (s.incomplete)
            CapabilityDegradeHint(
              icon: Icons.warning_amber_rounded,
              detail: dataText(
                'dsBtIncompleteHint',
                '部分搜索数据源无法连接，结果可能不完整。',
              ),
            ),
          if (s.phase == BtSearchPhase.starting ||
              (s.phase == BtSearchPhase.running && !s.finished))
            _PollingBar(state: s),
          Expanded(child: _body(s)),
        ],
      ),
    );
  }

  Widget _body(BtSearchState s) {
    switch (s.phase) {
      case BtSearchPhase.idle:
        return AppEmptyState(
          key: const Key('ds-bt-idle'),
          icon: Icons.travel_explore,
          title: dataText('dsBtIdleTitle', '搜索种子'),
          message: dataText(
            'dsBtIdleMessage',
            '输入关键词，从 NAS 上已启用的搜索数据源里查找。',
          ),
        );
      case BtSearchPhase.starting:
      case BtSearchPhase.running:
        if (s.visibleEntries.isEmpty) {
          return Center(
            key: const Key('ds-bt-running'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: Gap.md),
                Text(dataText('dsBtSearching', '正在搜索…')),
              ],
            ),
          );
        }
        return _ResultList(state: s);
      case BtSearchPhase.unavailable:
        return _UnavailableView(block: s.block);
      case BtSearchPhase.done:
        if (s.errorText != null) {
          return AppErrorView(
            key: const Key('ds-bt-error'),
            title: dataText('dsBtErrorTitle', '搜索失败'),
            detail: s.errorText,
            onRetry: _runSearch,
          );
        }
        if (s.visibleEntries.isEmpty) {
          return AppEmptyState(
            key: const Key('ds-bt-no-result'),
            icon: Icons.search_off,
            title: dataText('dsBtNoResultsTitle', '没有找到结果'),
            message: s.selectedModules.isEmpty
                ? dataText('dsBtNoResultsMessage', '换个关键词再试试。')
                : dataText(
                    'dsBtNoResultsFilteredMessage',
                    '所选数据源没有结果，或换个关键词再试试。',
                  ),
          );
        }
        return _ResultList(state: s);
    }
  }
}

/// 搜索结果列表（分页走 `list` 的 `offset`/`limit`；触底/按钮取下一页）。
class _ResultList extends ConsumerWidget {
  const _ResultList({required this.state});

  final BtSearchState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = state.visibleEntries;
    return ListView.separated(
      key: const Key('ds-bt-results'),
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xl),
      itemCount: rows.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: Gap.sm),
      itemBuilder: (context, i) {
        if (i == rows.length) return _footer(context, ref);
        return _ResultTile(entry: rows[i]);
      },
    );
  }

  Widget _footer(BuildContext context, WidgetRef ref) {
    if (!state.hasMore) {
      return Padding(
        padding: const EdgeInsets.only(top: Gap.md),
        child: Center(
          child: Text(
            dataText('dsBtEndOfResults', '已经到底了'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: Gap.md),
      child: Center(
        child: state.loadingMore
            ? const CircularProgressIndicator()
            : TextButton(
                key: const Key('ds-bt-load-more'),
                onPressed: () => ref.read(btSearchProvider.notifier).loadMore(),
                child: Text(dataText('dsBtLoadMore', '加载更多')),
              ),
      ),
    );
  }
}

/// 一条搜索结果（老代 11 字段 / 归一化后的 [BtSearchEntry]）。
///
/// ★ r388/DA35：右下角有「下载」按钮 —— `Task.create type=url`，url 逐字取
/// [BtSearchEntry.downloadUri]（老代 `download_uri`）。服务端没给 uri 的那条
/// **按钮置灰**（不是"点了没反应"，是可见但点不动，理由写在这里）。
class _ResultTile extends ConsumerStatefulWidget {
  const _ResultTile({required this.entry});

  final BtSearchEntry entry;

  @override
  ConsumerState<_ResultTile> createState() => _ResultTileState();
}

class _ResultTileState extends ConsumerState<_ResultTile> {
  /// 防连点（一次建任务可能几秒）。
  bool _adding = false;

  Future<void> _download() async {
    final entry = widget.entry;
    if (!entry.hasDownloadLink || _adding) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _adding = true);
    try {
      // ★ 目录**必须**给：官方 `downloadSelected` 逐字带 `destination`，且没目录
      //   连请求都不发。取值与「新建任务」页预填**同一个来源**（§2.0.51：入口
      //   不同不许走到不同实现）。
      final dest = await ref.read(downloadDefaultDestProvider.future);
      if (!mounted) return;
      if (dest.isEmpty) {
        // 官方在这里弹「选目录」；我们没有目录选择器 ⇒ 把链接交给
        // 「新建任务」页（用户在那里确认目录），而不是报一个查不出原因的错。
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              dataText(
                'dsBtNeedDest',
                '未能取到默认下载目录：请在「新建任务」里确认目录后再创建',
              ),
            ),
          ),
        );
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => DownloadCreatePage(initialUrl: entry.downloadUri),
          ),
        );
        return;
      }
      await ref
          .read(downloadActionsProvider)
          .createUrl(urls: [entry.downloadUri], destination: dest);
      trackOnce(
        UsageModule.downloads,
        UsageAction.create,
        objectType: 'magnet',
      );
      // ★ 任务列表要**重新拉**（不是作废）：`downloadListProvider` 是
      //   `NotifierProvider`，它的 `build()` 只给空初始值、**不发请求**
      //   ⇒ `invalidate` 会把列表直接清成 `0 tasks` 且没人再拉（真机
      //   `r8_23` 就是这样：提示条说"已添加"，列表却是空态）。
      //   与「新建任务」返回后的收尾同款：`refresh()`（§2.0.51）。
      await ref.read(downloadListProvider.notifier).refresh();
      messenger.showSnackBar(
        SnackBar(
          content: Text(dataText('dsBtDownloadAdded', '已添加到下载任务')),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            dataText(
              'dsBtDownloadFailed',
              '添加下载失败：{error}',
            ).replaceAll('{error}', userFacingError(e)),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final theme = Theme.of(context);
    final meta = theme.textTheme.bodySmall;
    final title = entry.title.isEmpty
        ? dataText('dsBtUntitled', '（无标题）')
        : entry.title;
    final unknown = dataText('dsBtUnknown', '未知');
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: Gap.xs),
            Wrap(
              spacing: Gap.md,
              runSpacing: Gap.xs,
              children: [
                // `size` 是字符串字节数 → 必须按字节格式化，不能直接上屏。
                _meta(
                  meta,
                  '${dataText('dsBtSizeLabel', '大小')}'
                  '${dataText('dsLabelSep', '：')}'
                  '${entry.sizeBytes > 0 ? dsHumanBytes(entry.sizeBytes) : unknown}',
                ),
                _meta(
                  meta,
                  '${dataText('dsBtSeedsLabel', '种子')}'
                  '${dataText('dsLabelSep', '：')}'
                  '${entry.seeds ?? unknown}',
                ),
                _meta(
                  meta,
                  '${dataText('dsBtPeersLabel', '连接')}'
                  '${dataText('dsLabelSep', '：')}'
                  '${entry.peers ?? unknown}',
                ),
                // 显示名 = `module_title`（内部 `module_id` 绝不上屏）。
                if (entry.moduleTitle.isNotEmpty)
                  _meta(meta, entry.moduleTitle),
                if (entry.dateText.isNotEmpty)
                  _meta(meta, entry.dateText),
              ],
            ),
            const SizedBox(height: Gap.sm),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: Key('ds-bt-download-${entry.dedupeKey}'),
                // 服务端没给下载链接 ⇒ 置灰（不是隐藏：用户要看得见"这里本该有"）。
                onPressed: entry.hasDownloadLink && !_adding ? _download : null,
                icon: _adding
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download, size: 18),
                label: Text(dataText('dsBtDownload', '下载')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _meta(TextStyle? style, String text) => Text(text, style: style);
}

/// `finished` 轮询进行中的进度条（5 秒一次、有上限、离开即停）。
class _PollingBar extends StatelessWidget {
  const _PollingBar({required this.state});

  final BtSearchState state;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('ds-bt-polling'),
      children: [
        const LinearProgressIndicator(minHeight: 2),
        Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          child: Text(
            dataText('dsBtPollingHint', '正在搜索数据源，结果会持续增加…'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// 中性不可用态（**不是**"加载失败"）：给标题 + 一句说明。
class _UnavailableView extends StatelessWidget {
  const _UnavailableView({required this.block});

  final BtSearchBlock? block;

  @override
  Widget build(BuildContext context) {
    final (title, message, icon) = switch (block) {
      BtSearchBlock.apiMissing => (
        dataText('dsBtUnavailableTitle', 'BT 搜索暂不可用'),
        dataText('dsBtUnavailableApiMissing', '还没有连接 NAS。'),
        Icons.link_off,
      ),
      BtSearchBlock.notInstalled => (
        dataText('dsBtUnavailableTitle', 'BT 搜索暂不可用'),
        dataText('dsBtUnavailableNotInstalled', '这台 NAS 没有安装 Download Station。'),
        Icons.extension_off,
      ),
      BtSearchBlock.noPrivilege => (
        dataText('dsBtUnavailableTitle', 'BT 搜索暂不可用'),
        dataText('dsBtUnavailableNoPrivilege', '这个账号没有使用 BT 搜索的权限。'),
        Icons.lock_outline,
      ),
      BtSearchBlock.idNotFound => (
        dataText('dsBtUnavailableTitle', 'BT 搜索暂不可用'),
        dataText(
          'dsBtUnavailableIdNotFound',
          '这台 NAS 未启用 BT 搜索，或搜索会话已失效。',
        ),
        Icons.search_off,
      ),
      BtSearchBlock.noPlugins => (
        dataText('dsBtUnavailableTitle', 'BT 搜索暂不可用'),
        dataText(
          'dsBtUnavailableNoPlugins',
          '这台 NAS 未启用 BT 搜索，或没有可用的搜索数据源。',
        ),
        Icons.hub_outlined,
      ),
      BtSearchBlock.noSources => (
        dataText('dsBtUnavailableTitle', 'BT 搜索暂不可用'),
        dataText('dsBtUnavailableSources', '没有读取到可用的搜索数据源。'),
        Icons.hub_outlined,
      ),
      BtSearchBlock.network => (
        dataText('dsBtUnavailableTitle', 'BT 搜索暂不可用'),
        dataText('dsBtUnavailableOffline', '网络连接失败，请检查网络后重试。'),
        Icons.cloud_off,
      ),
      null => (
        dataText('dsBtUnavailableTitle', 'BT 搜索暂不可用'),
        dataText(
          'dsBtUnavailableNoPlugins',
          '这台 NAS 未启用 BT 搜索，或没有可用的搜索数据源。',
        ),
        Icons.search_off,
      ),
    };
    return AppEmptyState(
      key: const Key('ds-bt-unavailable'),
      icon: icon,
      title: title,
      message: message,
    );
  }
}

/// 关键词 + 搜索按钮。
class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.state,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final BtSearchState state;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.sm),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('ds-bt-keyword'),
              controller: controller,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => onSubmit(),
              decoration: InputDecoration(
                hintText: dataText('dsBtSearchHint', '输入关键词搜索种子'),
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: Gap.sm),
          FilledButton(
            style: InlineButtonStyle.filled,
            key: const Key('ds-bt-submit'),
            onPressed: onSubmit,
            child: Text(dataText('dsBtSearchAction', '搜索')),
          ),
        ],
      ),
    );
  }
}

/// D2：分类筛选（`list_category`）。空分类不显示；选中即**带 `categories`
/// 重新取列表**（官方 `beforeSearchPolling` 的同一参数）。
class _CategorySelector extends ConsumerWidget {
  const _CategorySelector({required this.state});

  final BtSearchState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = state.selectedCategory;
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: Gap.xs),
            child: FilterChip(
              key: const Key('ds-bt-cat-all'),
              label: Text(dataText('dsBtCatAll', '全部分类')),
              selected: selected == null,
              onSelected: (_) =>
                  ref.read(btSearchProvider.notifier).selectCategory(null),
            ),
          ),
          for (var i = 0; i < state.categories.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: Gap.xs),
              child: FilterChip(
                key: Key('ds-bt-cat-$i'),
                label: Text(state.categories[i]),
                selected: selected == state.categories[i],
                onSelected: (_) => ref
                    .read(btSearchProvider.notifier)
                    .selectCategory(state.categories[i]),
              ),
            ),
        ],
      ),
    );
  }
}

/// 模块**多选**（`getModule`，只显示 `enabled:true` 的）。
///
/// 选择是**纯客户端筛选**（按 `module_id`）；服务端 `start` 的 `module` 参数
/// 真机未取证线参形态，**不下发**（见 provider 头注）。
class _ModuleSelector extends ConsumerWidget {
  const _ModuleSelector({required this.state});

  final BtSearchState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = state.selectedModules;
    final all = selected.isEmpty;
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: Gap.xs),
            child: FilterChip(
              key: const Key('ds-bt-source-all'),
              label: Text(dataText('dsBtSourceAll', '全部数据源')),
              selected: all,
              onSelected: (_) =>
                  ref.read(btSearchProvider.notifier).clearModules(),
            ),
          ),
          for (final m in state.sources)
            Padding(
              padding: const EdgeInsets.only(right: Gap.xs),
              child: FilterChip(
                key: Key('ds-bt-source-${m.id}'),
                // 显示名：title（内部 id 只进 key，**绝不上屏**；无 title 也
                // 不回落成 id，而是中性"未命名数据源"）。
                label: Text(
                  m.title.isEmpty
                      ? dataText('dsBtSourceUnnamed', '未命名数据源')
                      : m.title,
                ),
                selected: selected.contains(m.id),
                onSelected: (_) =>
                    ref.read(btSearchProvider.notifier).toggleModule(m.id),
              ),
            ),
        ],
      ),
    );
  }
}
