// 频道内容列表：**置顶 / 文件 / 链接 / @我 / 书签** —— 对齐原版
// `TabPostFragment`（置顶·文件·链接 三个 tab，`PostFragment`/`FileFragment`/`UrlFragment`）、
// `MentionFragment`（@我）与 `BookmarkFragment`（书签）。
//
// 数据源全部是 `SYNO.Chat.Post / search`，只是过滤条件不同（原版各 presenter
// 也都继承 `LoadMoreBasePresenter`，靠 `getHas()` 区分）：
//
//   | 列表 | 请求参数 | 原版类 |
//   |---|---|---|
//   | 置顶 | `in:[channelId]` + `has:["pin"]`（老服务端用 `has:["thread"]`） | `PostPresenter.getHas` |
//   | 文件 | `in:[channelId]` + `has:["file"]`（v3 起挪进 `post_type`） | `FilePresenter.getHas` |
//   | 链接 | `in:[channelId]` + `has:["url"]` | `UrlPresenter.getHas` |
//   | @我  | `in:[channelId]` + `mention:[myUserId]` | `MentionPresenter.fetchPosts` |
//   | 书签 | `in:[channelId]` + `has:["star"]`；行尾可取消星标 | `BookmarkPresenter.getHas` / `unstar` |
//
// 分页用 `offset`/`limit`（原版 `fetchPosts(channelId, offset, limit)`）。
// 点一条 → 跳到该消息在频道正文里的位置（原版 `UrlFragment.Callbacks.onJump`）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/router/app_routes.dart';
import '../../core/settings/server_settings.dart';
import '../../data/chat_api.dart';
import '../../data/dto/post_dto.dart';
import '../../data/dto/user_dto.dart';
import 'attachment_access.dart';
import 'attachment_view.dart';
import 'chat_session_controller.dart';
import 'link_preview_card.dart';
import '../../core/user_facing_error.dart';

/// 频道内容列表的过滤项（原版三个 tab + @我 + 书签）
enum ChannelContentKind {
  pinned(Icons.push_pin_outlined),
  files(Icons.folder_outlined),
  links(Icons.link),
  mentions(Icons.alternate_email),
  // 官方频道菜单里的 Bookmarks（`menu_channel.xml @+id/bookmark` →
  // `BookmarkFragment` + `BookmarkPresenter.getHas()` = ["star"]）
  bookmarks(Icons.star_border);

  const ChannelContentKind(this.icon);

  final IconData icon;

  /// 界面按语言取文案；[label] 只是中文回落（无 delegate 的老测试仍走它）。
  String labelIn(AppText text) => switch (this) {
    ChannelContentKind.pinned => text.chatFilterPin,
    ChannelContentKind.files => text.chatFilterFile,
    ChannelContentKind.links => text.chatFilterUrl,
    ChannelContentKind.mentions => text.chatContentMentions,
    ChannelContentKind.bookmarks => dataText('chatBookmarks', '书签'),
  };

  String get label => labelIn(currentText());
}

/// 一页多少条（原版 `LoadMoreBasePresenter` 也是分页拉）
const int kChannelContentPageSize = 30;

/// 列表状态：已经拿到的帖子 + 还有没有更多
class ChannelContentState {
  const ChannelContentState({
    this.posts = const [],
    this.loading = true,
    this.loadingMore = false,
    this.hasMore = true,
    this.error,
  });

  final List<PostDto> posts;
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final String? error;

  ChannelContentState copyWith({
    List<PostDto>? posts,
    bool? loading,
    bool? loadingMore,
    bool? hasMore,
    String? error,
    bool clearError = false,
  }) => ChannelContentState(
    posts: posts ?? this.posts,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    hasMore: hasMore ?? this.hasMore,
    error: clearError ? null : (error ?? this.error),
  );
}

/// 按 kind 组装搜索条件（`has` 的 file 会在 chat_api 里按版本挪进 `post_type`）
PostSearchQuery channelContentQuery({
  required ChannelContentKind kind,
  required int channelId,
  required int myUserId,
  required bool supportsSubscribeApi,
  int offset = 0,
  int limit = kChannelContentPageSize,
}) => PostSearchQuery(
  inChannels: [channelId],
  // 老服务端没有 pin，原版 `PostPresenter.getHas` 就退回 thread
  has: switch (kind) {
    ChannelContentKind.pinned => [supportsSubscribeApi ? 'pin' : 'thread'],
    ChannelContentKind.files => const ['file'],
    ChannelContentKind.links => const ['url'],
    ChannelContentKind.mentions => const [],
    // 原版 `BookmarkPresenter.getHas()` 就是 `["star"]`（服务端
    // `SearchControl::HasStar(int)`）
    ChannelContentKind.bookmarks => const ['star'],
  },
  mentions: kind == ChannelContentKind.mentions ? [myUserId] : const [],
  offset: offset,
  limit: limit,
);

class ChannelContentPage extends ConsumerStatefulWidget {
  const ChannelContentPage({
    super.key,
    required this.channelId,
    required this.kind,
  });

  final int channelId;
  final ChannelContentKind kind;

  @override
  ConsumerState<ChannelContentPage> createState() => _ChannelContentPageState();
}

class _ChannelContentPageState extends ConsumerState<ChannelContentPage> {
  final _scroll = ScrollController();
  ChannelContentState _state = const ChannelContentState();
  Map<int, UserDto> _users = const {};

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(refresh: true));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _state.loadingMore || !_state.hasMore) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 240) {
      _load();
    }
  }

  Future<void> _load({bool refresh = false}) async {
    if (_state.loadingMore) return;
    final t = context.t;
    final ctrl = ref.read(chatSessionControllerProvider.notifier);
    final api = ctrl.chatApi;
    final sync = ref.read(chatSessionControllerProvider);
    if (api == null) {
      setState(
        () =>
            _state = _state.copyWith(loading: false, error: t.setNotConnected),
      );
      return;
    }
    setState(() {
      _state = refresh
          ? _state.copyWith(
              loading: true,
              loadingMore: false,
              hasMore: true,
              clearError: true,
            )
          : _state.copyWith(loadingMore: true, clearError: true);
    });
    try {
      final offset = refresh ? 0 : _state.posts.length;
      final result = await api.searchPosts(
        channelContentQuery(
          kind: widget.kind,
          channelId: widget.channelId,
          myUserId: sync.myUserId,
          supportsSubscribeApi: sync.supportsSubscribeApi,
          offset: offset,
        ),
      );
      // 搜索回的是原始 JSON，转成 DTO（并写进本地库，附件才能下载/预览）
      final parsed = result.posts
          .map((j) => PostDto.fromJson(Map<String, dynamic>.from(j)))
          .where((p) => p.postId > 0)
          .toList();
      final merged = refresh
          ? parsed
          : [
              ..._state.posts,
              ...parsed.where(
                (p) => !_state.posts.any((old) => old.postId == p.postId),
              ),
            ];
      final store = ref.read(chatStoreProvider);
      if (parsed.isNotEmpty) await store.upsertPosts(parsed);
      final users = <int, UserDto>{..._users};
      for (final u in await store.allUsers()) {
        if (parsed.any((p) => p.creatorId == u.userId)) {
          users[u.userId] = u;
        }
      }
      if (!mounted) return;
      setState(() {
        _users = users;
        _state = ChannelContentState(
          posts: merged,
          loading: false,
          hasMore: result.posts.length >= kChannelContentPageSize,
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _state.copyWith(
          loading: false,
          loadingMore: false,
          error: userFacingError(e),
        );
      });
    }
  }

  /// 加密频道的附件要自己解密（和频道正文用同一套访问器）
  AttachmentAccess? _attachmentAccess() {
    final list = ref.watch(channelsProvider).value;
    if (list == null) return null;
    for (final c in list) {
      if (c.channelId == widget.channelId) {
        return ref
            .read(chatSessionControllerProvider.notifier)
            .attachmentAccessFor(c);
      }
    }
    return null;
  }

  /// 取消星标（书签列表的"移除"）—— 成功后才从列表里拿掉；失败提示并保留。
  Future<void> _unstar(PostDto post) async {
    final ok = await ref
        .read(chatSessionControllerProvider.notifier)
        .setStar(widget.channelId, post.postId, star: false);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(dataText('chatBookmarkRemoveFailed', '取消星标失败，请重试。'))),
      );
      return;
    }
    setState(() {
      _state = _state.copyWith(
        posts: _state.posts.where((p) => p.postId != post.postId).toList(),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(chatSessionControllerProvider);
    final settings = ref.watch(serverSettingsProvider);
    final mine = sync.myUserId;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(widget.kind.icon, size: 18),
            const SizedBox(width: 6),
            Text(widget.kind.labelIn(context.t)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: context.t.photoRefresh,
            onPressed: () => _load(refresh: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _state.loading
          ? const Center(child: CircularProgressIndicator())
          : _state.error != null && _state.posts.isEmpty
          ? _ErrorView(
              message: _state.error!,
              onRetry: () => _load(refresh: true),
            )
          : _state.posts.isEmpty
          ? _EmptyView(kind: widget.kind)
          : RefreshIndicator(
              onRefresh: () => _load(refresh: true),
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                controller: _scroll,
                itemCount: _state.posts.length + (_state.hasMore ? 1 : 0),
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  if (i >= _state.posts.length) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  }
                  final post = _state.posts[i];
                  final sender = _users[post.creatorId];
                  return _ContentRow(
                    post: post,
                    sender: sender,
                    kind: widget.kind,
                    hideLinkPreview: settings.hidePostUrlPreview,
                    attachmentAccess: _attachmentAccess(),
                    api: ref.read(chatApiProvider),
                    isMine: post.creatorId == mine,
                    // 官方 `BookmarkFragment.onRemoveBookmark` → `Presenter.unstar`
                    // → `AccountManager.unstarPost`（`Post / unstar` v1）
                    onUnstar: widget.kind == ChannelContentKind.bookmarks
                        ? () => _unstar(post)
                        : null,
                    onOpen: () => context.push(
                      AppRoutes.chatAt(widget.channelId, post.postId),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

/// 贴一个只读的"这条在频道里的位置"跳转（原版 `UrlFragment.Callbacks.onJump`）
class _ContentRow extends StatelessWidget {
  const _ContentRow({
    required this.post,
    required this.sender,
    required this.kind,
    required this.hideLinkPreview,
    required this.attachmentAccess,
    required this.api,
    required this.isMine,
    required this.onOpen,
    this.onUnstar,
  });

  final PostDto post;
  final UserDto? sender;
  final ChannelContentKind kind;
  final bool hideLinkPreview;
  final AttachmentAccess? attachmentAccess;
  final ChatApi? api;
  final bool isMine;
  final VoidCallback onOpen;

  /// 书签列表专用：取消星标（其它 kind 为 null）
  final VoidCallback? onUnstar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = hideLinkPreview ? null : post.linkPreview;
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  isMine
                      ? context.t.chatAuthorMe
                      : (sender?.displayName ??
                            context.t.chatUserFallback(post.creatorId)),
                  style: theme.textTheme.labelLarge,
                ),
                const SizedBox(width: 8),
                Text(
                  formatPostTime(post.createAt),
                  style: theme.textTheme.bodySmall,
                ),
                const Spacer(),
                if (post.isSticky)
                  Icon(
                    Icons.push_pin,
                    size: 14,
                    color: theme.colorScheme.primary,
                  ),
                if (post.isStar)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Icon(Icons.star, size: 14, color: Colors.amber),
                  ),
                if (onUnstar != null)
                  IconButton(
                    tooltip: context.t.driveUnstar,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.bookmark_remove_outlined, size: 18),
                    onPressed: onUnstar,
                  )
                else
                  const Icon(Icons.chevron_right, size: 16),
              ],
            ),
            if (post.message.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                post.message,
                maxLines: kind == ChannelContentKind.links ? 3 : 4,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ],
            if (kind == ChannelContentKind.files && post.attachments.isNotEmpty)
              AttachmentList(
                post: post,
                api: api,
                access: attachmentAccess,
                onError: (msg) => ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(msg))),
              ),
            if (preview != null)
              LinkPreviewCard(
                postId: post.postId,
                prop: preview,
                safeUrl: post.safeUrl,
                availableWidth: 300,
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.kind});

  final ChannelContentKind kind;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(kind.icon, size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(height: 8),
        Text(context.t.chatContentEmpty(kind.labelIn(context.t))),
      ],
    ),
  );
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 36),
          const SizedBox(height: 8),
          Text(context.t.botsLoadFailed(message), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: Text(context.t.photoRetry)),
        ],
      ),
    ),
  );
}

/// 消息时间（列表里用的短格式，和频道正文一致）
String formatPostTime(int millis) {
  if (millis <= 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int v) => v < 10 ? '0$v' : '$v';
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}
