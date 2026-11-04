// 高级搜索页（Phase 6）。
//
// 接口：`SYNO.Chat.Post / search` v5，结果在 **`search_results`** 里，
// 带 `total` 可以做"共 N 条 + 加载更多"。
// 参数编码与过滤器语义见 `ChatApi.searchPosts` 的注释和 docs/phase6-protocol.md。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../core/router/app_routes.dart';
import '../../data/chat_api.dart';
import '../../data/dto/channel_dto.dart';
import '../../data/dto/post_dto.dart';
import '../../data/dto/user_dto.dart';
import '../chat/chat_session_controller.dart';
import '../chat/rich_text.dart';
import '../../core/ui/app_states.dart';
import '../../core/user_facing_error.dart';
import '../../core/theme/app_theme.dart';

/// 搜索结果的本地状态（分页 + 条件 + 是否有更多）
class SearchState {
  const SearchState({
    this.query = const PostSearchQuery(),
    this.posts = const [],
    this.total = 0,
    this.loading = false,
    this.loadingMore = false,
    this.searched = false,
    this.error,
  });

  final PostSearchQuery query;
  final List<PostDto> posts;
  final int total;
  final bool loading;
  final bool loadingMore;
  final bool searched;
  final String? error;

  bool get hasMore => posts.length < total;

  SearchState copyWith({
    PostSearchQuery? query,
    List<PostDto>? posts,
    int? total,
    bool? loading,
    bool? loadingMore,
    bool? searched,
    String? error,
    bool clearError = false,
  }) => SearchState(
    query: query ?? this.query,
    posts: posts ?? this.posts,
    total: total ?? this.total,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    searched: searched ?? this.searched,
    error: clearError ? null : (error ?? this.error),
  );
}

/// 搜索条件变了就换 key，页面自己管分页
class SearchController extends Notifier<SearchState> {
  @override
  SearchState build() => const SearchState();

  ChatApi? get _api => ref.read(chatApiProvider);

  /// 改条件（不自动搜）
  void setQuery(PostSearchQuery q) => state = state.copyWith(query: q);

  void toggleHas(String value) {
    final has = [...state.query.has];
    has.contains(value) ? has.remove(value) : has.add(value);
    state = state.copyWith(query: state.query.copyWith(has: has));
  }

  Future<void> search() async {
    final api = _api;
    if (api == null) return;
    final q = state.query.copyWith(offset: 0);
    state = state.copyWith(
      loading: true,
      searched: true,
      posts: const [],
      total: 0,
      clearError: true,
    );
    try {
      final r = await api.searchPosts(q);
      state = state.copyWith(
        loading: false,
        posts: _parse(r.posts),
        total: r.total,
        query: q,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: currentText().calEnvSearchFailed(userFacingError(e)),
      );
    }
  }

  Future<void> loadMore() async {
    if (state.loadingMore || !state.hasMore) return;
    final api = _api;
    if (api == null) return;
    final q = state.query.copyWith(offset: state.posts.length);
    state = state.copyWith(loadingMore: true);
    try {
      final r = await api.searchPosts(q);
      state = state.copyWith(
        loadingMore: false,
        posts: [...state.posts, ..._parse(r.posts)],
        total: r.total,
      );
    } catch (e) {
      state = state.copyWith(
        loadingMore: false,
        error: currentText().searchLoadMoreFailed(userFacingError(e)),
      );
    }
  }

  List<PostDto> _parse(List<Map<String, dynamic>> raw) => raw
      .map(PostDto.fromJson)
      .where((p) => p.postId > 0 && !p.isDeleted)
      .toList();
}

final searchControllerProvider =
    NotifierProvider<SearchController, SearchState>(SearchController.new);

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _keyword = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
        ref.read(searchControllerProvider.notifier).loadMore();
      }
    });
  }

  @override
  void dispose() {
    _keyword.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(searchControllerProvider);
    final ctrl = ref.read(searchControllerProvider.notifier);
    // 搜索结果页也用深空底（顶栏的"仪表边框"是主题级，自动就有）
    return DesignScaffold(
      appBar: AppBar(
        title: TextField(
          controller: _keyword,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) {
            ctrl.setQuery(state.query.copyWith(keyword: _keyword.text));
            ctrl.search();
          },
          decoration: InputDecoration(
            hintText: context.t.searchMessagesHint,
            border: InputBorder.none,
          ),
        ),
        actions: [
          IconButton(
            tooltip: context.t.searchFilter,
            icon: const Icon(Icons.tune),
            onPressed: () => _openFilters(context, state.query, ctrl),
          ),
        ],
      ),
      body: Column(
        children: [
          _FilterBar(state: state, ctrl: ctrl),
          // 有结果时（分页失败）用顶部横幅提示；一个结果都没有时由
          // `_results` 渲染带重试的错误态，避免同一句错误显示两遍。
          if (state.error != null && state.posts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                state.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (state.searched)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  Text(
                    context.t.searchTotalCount(state.total),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const Spacer(),
                  if (state.query.labels.isNotEmpty)
                    Flexible(
                      child: Text(
                        state.query.labels.join(' · '),
                        style: Theme.of(context).textTheme.labelSmall,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                      ),
                    ),
                ],
              ),
            ),
          Expanded(child: _results(state, ctrl)),
        ],
      ),
    );
  }

  Widget _results(SearchState state, SearchController ctrl) {
    if (state.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!state.searched) {
      return Center(child: Text(context.t.searchPrompt));
    }
    // ★ 失败不能被渲染成"没有匹配结果"：搜索请求出错时 `posts` 为空，
    //   原来会显示空态文案，用户以为真没搜到，也找不到重试入口。
    if (state.error != null && state.posts.isEmpty) {
      return AppErrorView(
        key: const Key('search-error'),
        detail: state.error,
        onRetry: () => ctrl.search(),
      );
    }
    if (state.posts.isEmpty) {
      return Center(child: Text(context.t.searchNoMatch));
    }
    return ListView.separated(
      controller: _scroll,
      itemCount: state.posts.length + (state.loadingMore ? 1 : 0),
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i >= state.posts.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return _ResultTile(post: state.posts[i]);
      },
    );
  }

  Future<void> _openFilters(
    BuildContext context,
    PostSearchQuery q,
    SearchController ctrl,
  ) async {
    final out = await showModalBottomSheet<PostSearchQuery>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _FilterSheet(query: q),
    );
    if (out != null) {
      ctrl.setQuery(out);
      _keyword.text = out.keyword;
      await ctrl.search();
    }
  }
}

/// 顶部快捷筛选（`has` 那六个）
class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.state, required this.ctrl});

  final SearchState state;
  final SearchController ctrl;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final f in kHasFilters)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FilterChip(
                label: Text(hasLabelText(f)),
                selected: state.query.has.contains(f),
                onSelected: (_) => ctrl.toggleHas(f),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            // ⚠️ 这个按钮必须在**有界宽度**里渲染：横向 `ListView` 给子项的
            // 宽度约束是**无界**的（maxWidth = infinity），而全局主题的
            // `FilledButtonThemeData.minimumSize = Size.fromHeight(48)` 里宽度
            // 也是 `infinity`，两者相遇会让 `ButtonStyleButton` 拿到
            // `BoxConstraints(w=Infinity)` 去 layout → 布局断言直接抛
            // （debug 红屏；release 是无限宽）。这里用**局部主题**把最小宽度
            // 收成有限值，按钮回到"内容宽度"，不硬编码宽度。
            child: FilledButtonTheme(
              data: FilledButtonThemeData(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              ),
              child: FilledButton.tonalIcon(
                onPressed: ctrl.search,
                icon: const Icon(Icons.search, size: 18),
                label: Text(
                  context.t.calEnvSearch,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 更多筛选：频道 / 作者 / 扩展名 / 时间范围
class _FilterSheet extends ConsumerStatefulWidget {
  const _FilterSheet({required this.query});

  final PostSearchQuery query;

  @override
  ConsumerState<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends ConsumerState<_FilterSheet> {
  late final TextEditingController _keyword = TextEditingController(
    text: widget.query.keyword,
  );
  late final TextEditingController _tags = TextEditingController(
    text: widget.query.hashtags.join(' '),
  );
  late final TextEditingController _files = TextEditingController(
    text: widget.query.fileTypes.join(' '),
  );
  late final Set<int> _channels = {...widget.query.inChannels};
  late final Set<int> _users = {...widget.query.fromUsers};
  late DateTime? _after = widget.query.after > 0
      ? DateTime.fromMillisecondsSinceEpoch(widget.query.after)
      : null;
  late DateTime? _before = widget.query.before > 0
      ? DateTime.fromMillisecondsSinceEpoch(widget.query.before)
      : null;

  @override
  void dispose() {
    _keyword.dispose();
    _tags.dispose();
    _files.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final channels = ref.watch(channelsProvider).value ?? const <ChannelDto>[];
    final users = ref.watch(usersProvider).value ?? const <UserDto>[];
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.t.searchFilter,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _keyword,
              decoration: InputDecoration(
                labelText: context.t.searchKeyword,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tags,
              decoration: InputDecoration(
                labelText: context.t.searchHashtagHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _files,
              decoration: InputDecoration(
                labelText: context.t.searchFileTypeHint,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            _SectionLabel(context.t.chatChannelsTitle),
            Wrap(
              spacing: 8,
              children: [
                for (final c in channels)
                  FilterChip(
                    label: Text(c.name.isEmpty ? '#${c.channelId}' : c.name),
                    selected: _channels.contains(c.channelId),
                    onSelected: (on) => setState(
                      () => on
                          ? _channels.add(c.channelId)
                          : _channels.remove(c.channelId),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _SectionLabel(context.t.searchAuthor),
            Wrap(
              spacing: 8,
              children: [
                for (final u in users)
                  FilterChip(
                    label: Text(u.displayName),
                    selected: _users.contains(u.userId),
                    onSelected: (on) => setState(
                      () => on ? _users.add(u.userId) : _users.remove(u.userId),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _SectionLabel(context.t.searchTimeRange),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: _after ?? DateTime.now(),
                        firstDate: DateTime(2015),
                        lastDate: DateTime.now(),
                      );
                      if (d != null) setState(() => _after = d);
                    },
                    child: Text(
                      _after == null
                          ? context.t.searchStartDate
                          : '${_after!.year}-${_after!.month}-${_after!.day}',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: _before ?? DateTime.now(),
                        firstDate: DateTime(2015),
                        lastDate: DateTime.now(),
                      );
                      if (d != null) {
                        setState(
                          () => _before = d
                              .add(const Duration(days: 1))
                              .subtract(const Duration(milliseconds: 1)),
                        );
                      }
                    },
                    child: Text(
                      _before == null
                          ? context.t.searchEndDate
                          : '${_before!.year}-${_before!.month}-${_before!.day}',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).pop(const PostSearchQuery(keyword: '', limit: 30)),
                  child: Text(context.t.actionClear),
                ),
                const Spacer(),
                FilledButton(
                  style: InlineButtonStyle.filled,
                  onPressed: () => Navigator.of(context).pop(
                    widget.query.copyWith(
                      keyword: _keyword.text,
                      hashtags: _split(_tags.text),
                      fileTypes: _split(_files.text),
                      inChannels: _channels.toList(),
                      fromUsers: _users.toList(),
                      after: _after?.millisecondsSinceEpoch ?? 0,
                      before: _before?.millisecondsSinceEpoch ?? 0,
                      offset: 0,
                    ),
                  ),
                  child: Text(context.t.searchApply),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static List<String> _split(String s) => s
      .split(RegExp(r'[\s,]+'))
      .map((e) => e.trim().replaceFirst('#', ''))
      .where((e) => e.isNotEmpty)
      .toList();
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: Theme.of(context).textTheme.labelLarge),
  );
}

/// 一条搜索结果：频道 + 作者 + 时间 + 正文（带高亮链接/提及），点进去定位
class _ResultTile extends ConsumerWidget {
  const _ResultTile({required this.post});

  final PostDto post;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final channel = ref.watch(channelProvider(post.channelId));
    final users = ref.watch(usersProvider).value ?? const <UserDto>[];
    final sender = users
        .where((u) => u.userId == post.creatorId)
        .map((u) => u.displayName)
        .firstOrNull;
    final channelName = channel == null || channel.name.isEmpty
        ? '#${post.channelId}'
        : channel.name;
    final attachments = post.attachments;
    return DesignRowTile(
      isThreeLine: attachments.isNotEmpty,
      title: Row(
        children: [
          Expanded(
            child: Text(
              channelName,
              style: theme.textTheme.labelLarge,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(_time(post.createAt), style: theme.textTheme.labelSmall),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            sender ?? context.t.chatUserFallback(post.creatorId),
            style: theme.textTheme.labelSmall,
          ),
          if (post.message.isNotEmpty)
            MessageText(
              post.message,
              mentions: post.mentions,
              style: theme.textTheme.bodyMedium,
            ),
          if (attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  const Icon(Icons.attach_file, size: 14),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      attachments.map((a) => a.label).join(context.t.listSeparator),
                      style: theme.textTheme.labelSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      onTap: () => context.push(AppRoutes.chatAt(post.channelId, post.postId)),
    );
  }

  static String _time(int millis) {
    if (millis <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(millis);
    final now = DateTime.now();
    final hm =
        '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return hm;
    }
    return '${d.year}/${d.month}/${d.day}';
  }
}
