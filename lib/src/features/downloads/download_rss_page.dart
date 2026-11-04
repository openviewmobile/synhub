// Download Station **RSS 订阅**页（wave3）。
//
// 数据/状态机在 `download_rss_providers.dart`；API 在 `download_station.dart`；
// 线参形态逐字来自包内官方前端 `ui/download.js` 的 `DLM.RSS*`（见报告中
// "官方 JS 取证"一节）。
//
// 硬约束（任务书）：
//   * 订阅列表 + `is_updating` 时轮询/提示、添加、删除、全部更新；
//   * 条目列表 `Item:list`（`feed_id`）→ 分页 / 空态 / 失败**三态**；
//   * 过滤器至少只读；`Filter:add` / `test` 已取到线参形态，一并接 UI；
//   * `2404`/`2405` **语义未定** → 走 `describeDownloadRssError` 的
//     "未知错误 + 原始码"通用提示，**本文件不出现任何写死的 RSS 错误文案**；
//   * **绝不 `Text(...)` 内部标识**（`id` / `feed_id`）——
//     它们只出现在 `Key` 之外的数据传参里，从不进文本树；
//   * 未取证的成功路径不伪造条目：空就是空态。
import 'package:flutter/material.dart';
import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/theme/app_theme.dart';
import '../../data/download_station.dart';
import '../../data/dto/download_task_dto.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../shell/capability_hint.dart';
import 'download_rss_providers.dart';

/// RSS 订阅源列表页。
class DownloadRssPage extends ConsumerStatefulWidget {
  const DownloadRssPage({super.key});

  @override
  ConsumerState<DownloadRssPage> createState() => _DownloadRssPageState();
}

class _DownloadRssPageState extends ConsumerState<DownloadRssPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(rssProvider.notifier).loadFeeds();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(rssProvider);
    return DesignScaffold(
      appBar: AppBar(
        title: Text(dataText('dsRssTitle', 'RSS 订阅')),
        leading: IconButton(
          key: const Key('ds-rss-back'),
          tooltip: dataText('dsRssBack', '返回'),
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context, rootNavigator: true).maybePop(),
        ),
        actions: [
          IconButton(
            key: const Key('ds-rss-update-all'),
            tooltip: dataText('dsRssUpdateAll', '全部更新'),
            icon: const Icon(Icons.refresh),
            onPressed: s.busy ? null : () => _updateAll(context),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('ds-rss-add'),
        onPressed: s.busy ? null : () => _openAddDialog(context),
        icon: const Icon(Icons.add),
        label: Text(dataText('dsRssAdd', '添加订阅')),
      ),
      body: _body(context, s),
    );
  }

  Widget _body(BuildContext context, RssState s) {
    if (s.block != null) return _UnavailableView(block: s.block);
    if (s.loading && s.feeds.isEmpty) {
      return const Center(
        key: Key('ds-rss-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (s.errorText != null && s.feeds.isEmpty) {
      return AppErrorView(
        key: const Key('ds-rss-error'),
        title: dataText('dsRssErrorTitle', '加载订阅失败'),
        detail: s.errorText,
        onRetry: () => ref.read(rssProvider.notifier).loadFeeds(),
      );
    }
    if (s.loaded && s.feeds.isEmpty) {
      return AppEmptyState(
        key: const Key('ds-rss-empty'),
        icon: Icons.rss_feed,
        title: dataText('dsRssEmptyTitle', '还没有订阅源'),
        message: dataText('dsRssEmptyMessage', '点右下角添加一个 RSS 订阅地址。'),
      );
    }
    return Column(
      children: [
        // `is_updating` 为真 → "正在更新…"提示（官方列渲染 `updating`）。
        if (s.polling || s.anyUpdating)
          CapabilityDegradeHint(
            key: const Key('ds-rss-updating'),
            icon: Icons.sync,
            detail: dataText('dsRssUpdatingHint', '订阅源正在更新，列表会自动刷新。'),
          ),
        if (s.busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => ref.read(rssProvider.notifier).refreshFeeds(),
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              key: const Key('ds-rss-feed-list'),
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xxl),
              itemCount: s.feeds.length,
              separatorBuilder: (_, _) => const SizedBox(height: Gap.sm),
              itemBuilder: (context, i) => _FeedTile(
                index: i,
                feed: s.feeds[i],
                onOpen: () => _openFeed(context, s.feeds[i]),
                onUpdate: () => _updateOne(context, s.feeds[i]),
                onDelete: () => _deleteOne(context, s.feeds[i]),
                onEdit: () => _editOne(context, s.feeds[i]),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _updateAll(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(rssProvider.notifier).updateAll();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(describeDownloadRssError(e))),
      );
    }
  }

  Future<void> _updateOne(BuildContext context, DsRssFeed feed) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(rssProvider.notifier).updateFeeds([feed.id]);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(describeDownloadRssError(e))),
      );
    }
  }

  Future<void> _deleteOne(BuildContext context, DsRssFeed feed) async {
    final ok = await _confirm(
      context,
      title: dataText('dsRssDeleteTitle', '删除订阅'),
      body: dataText('dsRssDeleteConfirm', '要删除这个订阅源吗？该源的条目也会一并移除。'),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(rssProvider.notifier).deleteFeeds([feed.id]);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(describeDownloadRssError(e))),
      );
    }
  }

  /// E4：编辑订阅（`Feed:set`，改名/改地址）—— 原先只有增/删，没有修改。
  Future<void> _editOne(BuildContext context, DsRssFeed feed) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _EditFeedDialog(feed: feed),
    );
    if (ok == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(dataText('dsRssFeedSaved', '订阅已更新'))),
      );
    }
  }

  Future<void> _openAddDialog(BuildContext context) async {
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => const _AddFeedDialog(),
    );
    if (added == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(dataText('dsRssAddQueued', '已提交订阅，正在抓取。'))),
      );
    }
  }

  Future<void> _openFeed(BuildContext context, DsRssFeed feed) async {
    await ref.read(rssProvider.notifier).selectFeed(feed.id);
    if (!context.mounted) return;
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute(
        builder: (_) => DownloadRssFeedPage(
          // 只把**可显示**的标题带过去；`id` 留在 provider 里（不上屏）。
          title: feed.title.isEmpty
              ? dataText('dsRssUntitled', '（未命名订阅）')
              : feed.title,
        ),
      ),
    );
  }
}

/// 一条订阅源。**不渲染 `id`**。
class _FeedTile extends StatelessWidget {
  const _FeedTile({
    required this.index,
    required this.feed,
    required this.onOpen,
    required this.onUpdate,
    required this.onDelete,
    required this.onEdit,
  });

  final int index;
  final DsRssFeed feed;
  final VoidCallback onOpen;
  final VoidCallback onUpdate;
  final VoidCallback onDelete;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final meta = Theme.of(context).textTheme.bodySmall;
    final title = feed.title.isEmpty
        ? dataText('dsRssUntitled', '（未命名订阅）')
        : feed.title;
    return Card(
      key: Key('ds-rss-feed-$index'),
      margin: EdgeInsets.zero,
      child: DesignRowTile(
        onTap: onOpen,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (feed.url.isNotEmpty)
              Text(feed.url, maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: Gap.xs),
            Text(
              feed.isUpdating
                  ? dataText('dsRssUpdating', '更新中…')
                  : _updatedText(feed.lastUpdate),
              style: meta,
            ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          key: Key('ds-rss-feed-menu-$index'),
          onSelected: (v) {
            if (v == 'update') onUpdate();
            if (v == 'delete') onDelete();
            if (v == 'edit') onEdit();
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              key: Key('ds-rss-feed-edit-$index'),
              value: 'edit',
              child: Text(dataText('dsRssEditFeed', '编辑订阅')),
            ),
            PopupMenuItem(
              value: 'update',
              child: Text(dataText('dsRssUpdate', '立即更新')),
            ),
            PopupMenuItem(
              value: 'delete',
              child: Text(dataText('dsRssDelete', '删除')),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单个订阅源的**条目 + 过滤器**页。
///
/// 条目三态：加载中 / 空态 / 失败；分页参数 = `offset`/`limit`（官方
/// `paramNames:{start:"offset", limit:"limit"}`）。
class DownloadRssFeedPage extends ConsumerStatefulWidget {
  const DownloadRssFeedPage({super.key, required this.title});

  /// **可显示**的订阅标题（绝不传 `id`）。
  final String title;

  @override
  ConsumerState<DownloadRssFeedPage> createState() =>
      _DownloadRssFeedPageState();
}

class _DownloadRssFeedPageState extends ConsumerState<DownloadRssFeedPage> {
  @override
  Widget build(BuildContext context) {
    final s = ref.watch(rssProvider);
    return DefaultTabController(
      length: 2,
      child: DesignScaffold(
        appBar: AppBar(
          title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          leading: IconButton(
            key: const Key('ds-rss-detail-back'),
            tooltip: dataText('dsRssBack', '返回'),
            icon: const Icon(Icons.arrow_back),
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).maybePop(),
          ),
          actions: [
            IconButton(
              key: const Key('ds-rss-clear-items'),
              tooltip: dataText('dsRssClearItems', '清空条目'),
              icon: const Icon(Icons.cleaning_services_outlined),
              onPressed: s.busy || s.items.isEmpty
                  ? null
                  : () => _clearItems(context),
            ),
          ],
          bottom: TabBar(
            tabs: [
              Tab(
                key: const Key('ds-rss-tab-items'),
                text: dataText('dsRssTabItems', '条目'),
              ),
              Tab(
                key: const Key('ds-rss-tab-filters'),
                text: dataText('dsRssTabFilters', '自动下载'),
              ),
            ],
          ),
        ),
        body: TabBarView(
          children: [_itemsTab(s), _filtersTab(s)],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 条目

  Widget _itemsTab(RssState s) {
    if (s.itemsLoading && s.items.isEmpty) {
      return const Center(
        key: Key('ds-rss-items-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (s.itemsError != null && s.items.isEmpty) {
      return AppErrorView(
        key: const Key('ds-rss-items-error'),
        title: dataText('dsRssItemsErrorTitle', '加载条目失败'),
        detail: s.itemsError,
        onRetry: () => ref.read(rssProvider.notifier).loadItems(),
      );
    }
    if (s.itemsLoaded && s.items.isEmpty) {
      return AppEmptyState(
        key: const Key('ds-rss-items-empty'),
        icon: Icons.article_outlined,
        title: dataText('dsRssItemsEmptyTitle', '还没有条目'),
        message: dataText(
          'dsRssItemsEmptyMessage',
          '这个订阅源还没有抓到条目，稍后刷新试试。',
        ),
      );
    }
    return ListView.separated(
      key: const Key('ds-rss-items'),
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xl),
      itemCount: s.items.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: Gap.sm),
      itemBuilder: (context, i) {
        if (i == s.items.length) return _itemsFooter(s);
        return _ItemTile(index: i, item: s.items[i]);
      },
    );
  }

  Widget _itemsFooter(RssState s) {
    if (s.itemsError != null) {
      return Padding(
        padding: const EdgeInsets.only(top: Gap.md),
        child: Center(
          child: Text(
            s.itemsError!,
            key: const Key('ds-rss-items-more-error'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    if (!s.hasMoreItems) {
      return Padding(
        padding: const EdgeInsets.only(top: Gap.md),
        child: Center(
          child: Text(
            dataText('dsRssEndOfItems', '已经到底了'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: Gap.md),
      child: Center(
        child: s.itemsLoadingMore
            ? const CircularProgressIndicator()
            : TextButton(
                key: const Key('ds-rss-items-load-more'),
                onPressed: () =>
                    ref.read(rssProvider.notifier).loadMoreItems(),
                child: Text(dataText('dsRssLoadMore', '加载更多')),
              ),
      ),
    );
  }

  Future<void> _clearItems(BuildContext context) async {
    final ok = await _confirm(
      context,
      title: dataText('dsRssClearItems', '清空条目'),
      body: dataText('dsRssClearItemsConfirm', '要清空这个订阅源已抓取的条目吗？'),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(rssProvider.notifier).clearItems();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(describeDownloadRssError(e))),
      );
    }
  }

  // ---------------------------------------------------------------- 过滤器

  Widget _filtersTab(RssState s) {
    if (s.filtersLoading && s.filters.isEmpty) {
      return const Center(
        key: Key('ds-rss-filters-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (s.filtersError != null && s.filters.isEmpty) {
      return AppErrorView(
        key: const Key('ds-rss-filters-error'),
        title: dataText('dsRssFiltersErrorTitle', '加载过滤器失败'),
        detail: s.filtersError,
        onRetry: () => ref.read(rssProvider.notifier).loadFilters(),
      );
    }
    return Column(
      children: [
        if (s.filtersLoaded && s.filters.isEmpty)
          Expanded(
            child: AppEmptyState(
              key: const Key('ds-rss-filters-empty'),
              icon: Icons.filter_alt_outlined,
              title: dataText('dsRssFiltersEmptyTitle', '还没有自动下载规则'),
              message: dataText(
                'dsRssFiltersEmptyMessage',
                '规则按关键词匹配新条目，命中后自动下载到指定目录。',
              ),
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              key: const Key('ds-rss-filters'),
              padding: const EdgeInsets.fromLTRB(
                Gap.lg,
                Gap.sm,
                Gap.lg,
                Gap.xl,
              ),
              itemCount: s.filters.length,
              separatorBuilder: (_, _) => const SizedBox(height: Gap.sm),
              itemBuilder: (context, i) => _FilterTile(
                index: i,
                filter: s.filters[i],
                onDelete: () => _deleteFilter(context, s.filters[i].id),
                onTest: () => _openFilterDialog(context, existing: s.filters[i]),
              ),
            ),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.lg),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('ds-rss-filter-add'),
                    onPressed: s.busy
                        ? null
                        : () => _openFilterDialog(context, existing: null),
                    icon: const Icon(Icons.add),
                    label: Text(dataText('dsRssFilterAdd', '新建规则')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _deleteFilter(BuildContext context, String id) async {
    final ok = await _confirm(
      context,
      title: dataText('dsRssFilterDeleteTitle', '删除规则'),
      body: dataText('dsRssFilterDeleteConfirm', '要删除这条自动下载规则吗？'),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(rssProvider.notifier).deleteFilter(id);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(describeDownloadRssError(e))),
      );
    }
  }

  Future<void> _openFilterDialog(
    BuildContext context, {
    required DsRssFilter? existing,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _FilterDialog(existing: existing),
    );
    if (ok == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(dataText('dsRssFilterSaved', '规则已保存'))),
      );
    }
  }
}

/// 一条过滤器（`name` / `match` / `destination` 可显示；`id` 不上屏）。
class _FilterTile extends StatelessWidget {
  const _FilterTile({
    required this.index,
    required this.filter,
    required this.onDelete,
    required this.onTest,
  });

  final int index;
  final DsRssFilter filter;
  final VoidCallback onDelete;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final meta = Theme.of(context).textTheme.bodySmall;
    return Card(
      key: Key('ds-rss-filter-$index'),
      margin: EdgeInsets.zero,
      child: DesignRowTile(
        title: Text(filter.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (filter.match.isNotEmpty)
              Text(
                context.t.dsRssFilterMatchLine(filter.match),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            if (filter.notMatch.isNotEmpty)
              Text(
                context.t.dsRssFilterNotMatchLine(filter.notMatch),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            if (filter.destination.isNotEmpty)
              Text(
                context.t.dsRssFilterDestLine(filter.destination),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: meta,
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: Key('ds-rss-filter-test-$index'),
              tooltip: dataText('dsRssFilterTest', '试跑'),
              icon: const Icon(Icons.play_arrow_outlined),
              onPressed: onTest,
            ),
            IconButton(
              key: Key('ds-rss-filter-delete-$index'),
              tooltip: dataText('dsRssDelete', '删除'),
              icon: const Icon(Icons.delete_outline),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

/// 一条订阅条目（`title` / `size` / `date` / `link`；`id`/`feed_id` 不上屏）。
class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.index, required this.item});

  final int index;
  final DsRssItem item;

  @override
  Widget build(BuildContext context) {
    final meta = Theme.of(context).textTheme.bodySmall;
    final title = item.title.isEmpty
        ? dataText('dsRssItemUntitled', '（无标题）')
        : item.title;
    return Card(
      key: Key('ds-rss-item-$index'),
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
                if (item.size > 0) Text(dsHumanBytes(item.size), style: meta),
                if (item.date > 0) Text(_dateText(item.date), style: meta),
                if (item.isNew)
                  Text(dataText('dsRssItemNew', '新'), style: meta),
                // 官方 actionExternalHandler 读 `link`，只在有值时给外链文本。
                if (item.link.isNotEmpty)
                  Text(
                    item.link,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: meta,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 添加订阅对话框（`url` 必填；可选"全部自动下载" + 目标目录）。
class _AddFeedDialog extends ConsumerStatefulWidget {
  const _AddFeedDialog();

  @override
  ConsumerState<_AddFeedDialog> createState() => _AddFeedDialogState();
}

class _AddFeedDialogState extends ConsumerState<_AddFeedDialog> {
  final _url = TextEditingController();
  final _dest = TextEditingController();
  bool _auto = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _dest.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(dataText('dsRssAdd', '添加订阅')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('ds-rss-url'),
              controller: _url,
              autofocus: true,
              decoration: InputDecoration(
                labelText: dataText('dsRssUrlLabel', 'RSS 地址'),
                hintText: 'https://example.com/feed.xml',
              ),
            ),
            const SizedBox(height: Gap.md),
            DesignCheckRow(
              key: const Key('ds-rss-auto'),
              value: _auto,
              contentPadding: EdgeInsets.zero,
              title: Text(dataText('dsRssAutoDownload', '自动下载新条目')),
              onChanged: (v) => setState(() => _auto = v),
            ),
            if (_auto)
              TextField(
                key: const Key('ds-rss-dest'),
                controller: _dest,
                decoration: InputDecoration(
                  labelText: dataText('dsRssDestLabel', '下载目录（可选）'),
                  hintText: dataText('dsRssDestHint', '留空用默认目录'),
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: Gap.md),
              Text(
                _error!,
                key: const Key('ds-rss-add-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(dataText('dsRssCancel', '取消')),
        ),
        FilledButton(
          key: const Key('ds-rss-add-submit'),
          onPressed: _submit,
          child: Text(dataText('dsRssAddSubmit', '添加')),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final url = _url.text.trim();
    if (url.isEmpty) {
      setState(() => _error = dataText('dsRssUrlRequired', '请填写 RSS 地址'));
      return;
    }
    setState(() => _error = null);
    try {
      await ref
          .read(rssProvider.notifier)
          .addFeed(
            url,
            enableAutoDownload: _auto,
            destination: _auto ? _dest.text.trim() : null,
          );
      trackOnce(UsageModule.downloads, UsageAction.create, objectType: 'rss');
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      trackOnceFailure(
        UsageModule.downloads,
        UsageAction.create,
        objectType: 'rss',
        reason: 'add_feed_failed',
        error: e,
      );
      if (mounted) setState(() => _error = describeDownloadRssError(e));
    }
  }
}

/// 新建 / 试跑过滤器对话框。
///
/// 线参逐字（官方 `RSSAddFilterDialog` / `RSSAddFilterTestingTool`）：
/// 新建 `{feed_id, name, match, not_match, destination, is_regex}`；
/// 试跑 `{test_string, match, not_match, is_regex}` → 回包 `matched`。
/// 编辑订阅对话框（E4）：改标题 / 改地址（都走 `Feed:set`）。
class _EditFeedDialog extends ConsumerStatefulWidget {
  const _EditFeedDialog({required this.feed});

  final DsRssFeed feed;

  @override
  ConsumerState<_EditFeedDialog> createState() => _EditFeedDialogState();
}

class _EditFeedDialogState extends ConsumerState<_EditFeedDialog> {
  late final TextEditingController _title =
      TextEditingController(text: widget.feed.title);
  late final TextEditingController _url =
      TextEditingController(text: widget.feed.url);
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _url.text.trim();
    if (url.isEmpty) {
      setState(() => _error = dataText('dsRssUrlRequired', '请填写 RSS 地址'));
      return;
    }
    setState(() => _error = null);
    try {
      await ref
          .read(rssProvider.notifier)
          .editFeed(id: widget.feed.id, title: _title.text.trim(), url: url);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = describeDownloadRssError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(dataText('dsRssEditFeed', '编辑订阅')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('ds-rss-edit-title'),
              controller: _title,
              decoration: InputDecoration(
                labelText: dataText('dsRssTitleLabel', '名称'),
              ),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              key: const Key('ds-rss-edit-url'),
              controller: _url,
              decoration: InputDecoration(
                labelText: dataText('dsRssUrlLabel', 'RSS 地址'),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: Gap.sm),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('ds-rss-edit-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(dataText('dsRssCancel', '取消')),
        ),
        FilledButton(
          key: const Key('ds-rss-edit-save'),
          onPressed: _save,
          child: Text(dataText('dsRssSave', '保存')),
        ),
      ],
    );
  }
}

class _FilterDialog extends ConsumerStatefulWidget {
  const _FilterDialog({required this.existing});

  final DsRssFilter? existing;

  @override
  ConsumerState<_FilterDialog> createState() => _FilterDialogState();
}

class _FilterDialogState extends ConsumerState<_FilterDialog> {
  late final TextEditingController _name;
  late final TextEditingController _match;
  late final TextEditingController _notMatch;
  late final TextEditingController _dest;
  late final TextEditingController _testString;
  bool _regex = false;
  String? _error;
  bool? _matched;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _match = TextEditingController(text: e?.match ?? '');
    _notMatch = TextEditingController(text: e?.notMatch ?? '');
    _dest = TextEditingController(text: e?.destination ?? '');
    _testString = TextEditingController();
    _regex = e?.isRegex ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _match.dispose();
    _notMatch.dispose();
    _dest.dispose();
    _testString.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return AlertDialog(
      title: Text(
        isEdit
            ? dataText('dsRssFilterEditTitle', '编辑规则')
            : dataText('dsRssFilterAdd', '新建规则'),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('ds-rss-filter-name'),
              controller: _name,
              decoration: InputDecoration(
                labelText: dataText('dsRssFilterName', '规则名称'),
              ),
            ),
            const SizedBox(height: Gap.sm),
            TextField(
              key: const Key('ds-rss-filter-match'),
              controller: _match,
              decoration: InputDecoration(
                labelText: dataText('dsRssFilterMatch', '包含'),
              ),
            ),
            const SizedBox(height: Gap.sm),
            TextField(
              key: const Key('ds-rss-filter-not-match'),
              controller: _notMatch,
              decoration: InputDecoration(
                labelText: dataText('dsRssFilterNotMatch', '排除'),
              ),
            ),
            const SizedBox(height: Gap.sm),
            TextField(
              key: const Key('ds-rss-filter-dest'),
              controller: _dest,
              decoration: InputDecoration(
                labelText: dataText('dsRssFilterDest', '下载到'),
                hintText: dataText('dsRssDestHint', '留空用默认目录'),
              ),
            ),
            DesignCheckRow(
              key: const Key('ds-rss-filter-regex'),
              value: _regex,
              contentPadding: EdgeInsets.zero,
              title: Text(dataText('dsRssFilterRegex', '按正则表达式解析')),
              onChanged: (v) => setState(() => _regex = v),
            ),
            const Divider(),
            TextField(
              key: const Key('ds-rss-filter-test-string'),
              controller: _testString,
              decoration: InputDecoration(
                labelText: dataText('dsRssFilterTestString', '试跑文本'),
              ),
            ),
            const SizedBox(height: Gap.sm),
            Row(
              children: [
                OutlinedButton.icon( style: InlineButtonStyle.outlined,
                  key: const Key('ds-rss-filter-run-test'),
                  onPressed: _runTest,
                  icon: const Icon(Icons.play_arrow_outlined),
                  label: Text(dataText('dsRssFilterTest', '试跑')),
                ),
                const SizedBox(width: Gap.md),
                if (_matched != null)
                  Expanded(
                    child: Text(
                      _matched!
                          ? dataText('dsRssFilterMatched', '规则匹配成功')
                          : dataText('dsRssFilterNotMatched', '规则不匹配'),
                      key: const Key('ds-rss-filter-test-result'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: Gap.md),
              Text(
                _error!,
                key: const Key('ds-rss-filter-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(dataText('dsRssCancel', '取消')),
        ),
        FilledButton(
          key: const Key('ds-rss-filter-save'),
          onPressed: _save,
          child: Text(dataText('dsRssSave', '保存')),
        ),
      ],
    );
  }

  Future<void> _runTest() async {
    final text = _testString.text;
    if (text.isEmpty) {
      setState(() => _error = dataText('dsRssTestRequired', '请填写试跑文本'));
      return;
    }
    setState(() {
      _error = null;
      _matched = null;
    });
    try {
      final matched = await ref
          .read(rssProvider.notifier)
          .testFilter(
            testString: text,
            match: _match.text,
            notMatch: _notMatch.text,
            isRegex: _regex,
          );
      trackOnce(
        UsageModule.downloads,
        UsageAction.search,
        objectType: 'rss',
        value: matched ? 1 : 0,
      );
      if (mounted) setState(() => _matched = matched);
    } catch (e) {
      trackOnceFailure(
        UsageModule.downloads,
        UsageAction.search,
        objectType: 'rss',
        reason: 'filter_test_failed',
        error: e,
      );
      if (mounted) setState(() => _error = describeDownloadRssError(e));
    }
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = dataText('dsRssFilterNameRequired', '请填写规则名称'));
      return;
    }
    setState(() => _error = null);
    final notifier = ref.read(rssProvider.notifier);
    try {
      final existing = widget.existing;
      if (existing == null) {
        await notifier.addFilter(
          name: name,
          destination: _dest.text.trim(),
          match: _match.text,
          notMatch: _notMatch.text,
          isRegex: _regex,
        );
      } else {
        // E5：编辑已有规则必须走 `Filter:set` —— 原先误走 `addFilter`，
        // 结果是"编辑"反而**多出一条规则**（真 bug，已修）。
        await notifier.editFilter(
          id: existing.id,
          name: name,
          destination: _dest.text.trim(),
          match: _match.text,
          notMatch: _notMatch.text,
          isRegex: _regex,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = describeDownloadRssError(e));
    }
  }
}

/// 中性不可用态（**不是**"加载失败"）。
class _UnavailableView extends StatelessWidget {
  const _UnavailableView({required this.block});

  final RssBlock? block;

  @override
  Widget build(BuildContext context) {
    final (title, message, icon) = switch (block) {
      RssBlock.apiMissing => (
        dataText('dsRssUnavailableTitle', 'RSS 暂不可用'),
        dataText('dsRssUnavailableApiMissing', '还没有连接 NAS。'),
        Icons.link_off,
      ),
      RssBlock.notInstalled => (
        dataText('dsRssUnavailableTitle', 'RSS 暂不可用'),
        dataText('dsRssUnavailableNotInstalled', '这台 NAS 没有安装 Download Station。'),
        Icons.extension_off,
      ),
      RssBlock.noPrivilege => (
        dataText('dsRssUnavailableTitle', 'RSS 暂不可用'),
        dataText('dsRssUnavailableNoPrivilege', '这个账号没有使用 RSS 订阅的权限。'),
        Icons.lock_outline,
      ),
      RssBlock.network => (
        dataText('dsRssUnavailableTitle', 'RSS 暂不可用'),
        dataText('dsRssUnavailableOffline', '网络连接失败，请检查网络后重试。'),
        Icons.cloud_off,
      ),
      null => (
        dataText('dsRssUnavailableTitle', 'RSS 暂不可用'),
        dataText('dsRssUnavailableNotInstalled', '这台 NAS 没有安装 Download Station。'),
        Icons.extension_off,
      ),
    };
    return AppEmptyState(
      key: const Key('ds-rss-unavailable'),
      icon: icon,
      title: title,
      message: message,
    );
  }
}

Future<bool?> _confirm(
  BuildContext context, {
  required String title,
  required String body,
}) => showDialog<bool>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: Text(title),
    content: Text(body),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(ctx).pop(false),
        child: Text(dataText('dsRssCancel', '取消')),
      ),
      FilledButton(
        key: const Key('ds-rss-confirm'),
        onPressed: () => Navigator.of(ctx).pop(true),
        child: Text(dataText('dsRssConfirm', '确定')),
      ),
    ],
  ),
);

String _updatedText(int epochSeconds) {
  if (epochSeconds <= 0) return dataText('dsRssNeverUpdated', '尚未更新');
  final when = _dateText(epochSeconds);
  return dataText(
    'dsRssLastUpdateLine',
    '上次更新：$when',
  ).replaceAll('{when}', when);
}

String _dateText(int epochSeconds) {
  if (epochSeconds <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} '
      '${two(d.hour)}:${two(d.minute)}';
}
