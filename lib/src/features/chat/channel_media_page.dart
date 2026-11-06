// 频道的「媒体与文件」页 —— 原 App 的图片墙 / 文件列表。
//
// 数据来源：`Post/list` v3（`file_type` + `attributes`），
// 见 ChatApi.listPostsByType 的注释与 docs/phase5-protocol.md §9。
//
// 真机实测的分类行为（决定了这里的 tab 怎么查）：
//   * `file_type=["image"]`：服务端判定为图片的消息（`is_image=true`）；
//   * `file_type=["video"]` / `["audio"]`：分类有效；
//   * `["file"]` / `["document"]` / `["other"]` **不是**有效分类（筛不出来），
//     所以"文件"tab 查全部再在本地排除图片/视频/音频。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../core/media/aspect_image.dart';
import '../../data/chat_api.dart';
import '../../data/dto/file_prop_dto.dart';
import '../../data/dto/post_dto.dart';
import 'attachment_access.dart';
import 'attachment_view.dart';
import 'chat_image.dart';
import 'chat_session_controller.dart';
import '../../core/user_facing_error.dart';

/// 媒体页的 tab
enum MediaTab {
  image,
  video,
  audio,
  file;

  /// 界面按语言取文案；[label] 只是中文回落（无 delegate 的老测试仍走它）。
  String labelIn(AppText text) => switch (this) {
    MediaTab.image => text.chatMediaImage,
    MediaTab.video => text.photoVideo,
    MediaTab.audio => text.chatMediaAudio,
    MediaTab.file => text.chatFilterFile,
  };

  String get label => labelIn(currentText());
}

/// 每个 tab 的查询参数
class MediaQuery {
  const MediaQuery({this.fileTypes = const [], this.clientFilter});

  /// 发给服务端的 `file_type`
  final List<String> fileTypes;

  /// 服务端筛不出来的部分在本地补（file tab 用）
  final bool Function(FilePropDto)? clientFilter;
}

/// 反编译依据 `AccountManager.fetchImagePosts` / 实测：
/// 图片/视频/音频是服务端分类，文件得自己筛。
MediaQuery mediaQueryFor(MediaTab tab) {
  switch (tab) {
    case MediaTab.image:
      return const MediaQuery(fileTypes: [kMediaImage]);
    case MediaTab.video:
      return const MediaQuery(fileTypes: [kMediaVideo]);
    case MediaTab.audio:
      return const MediaQuery(fileTypes: [kMediaAudio]);
    case MediaTab.file:
      return MediaQuery(clientFilter: isGenericFile);
  }
}

/// 不是图片/视频/音频的附件 => "文件"tab 要显示的
bool isGenericFile(FilePropDto prop) {
  final ext = prop.extension;
  if (prop.showsThumbnail) return false;
  if (kVideoExtensions.contains(ext)) return false;
  if (kAudioExtensions.contains(ext)) return false;
  return true;
}

/// 某频道某 tab 的媒体列表。
///
/// 数据源是**本地库**（`loadMedia` 把服务端结果写进去），
/// 这样刚上传/刚收到的附件会自动出现在这里，和原 App 的行为一致。
final mediaPostsProvider =
    StreamProvider.family<List<PostDto>, ({int channelId, MediaTab tab})>((
      ref,
      key,
    ) {
      final q = mediaQueryFor(key.tab);
      return ref
          .watch(chatStoreProvider)
          .watchPosts(key.channelId, limit: 500)
          .map((posts) => posts.where((p) => matchesTab(q, p)).toList());
    });

/// 这条消息属于这个 tab 吗（服务端筛过的就不再用扩展名挑一遍）
bool matchesTab(MediaQuery q, PostDto post) {
  final props = post.attachments;
  if (props.isEmpty) return false;
  if (q.clientFilter != null) return props.any(q.clientFilter!);
  if (q.fileTypes.contains(kMediaImage)) {
    return props.any((f) => f.showsThumbnail);
  }
  if (q.fileTypes.contains(kMediaVideo)) {
    return props.any((f) => kVideoExtensions.contains(f.extension));
  }
  if (q.fileTypes.contains(kMediaAudio)) {
    return props.any((f) => kAudioExtensions.contains(f.extension));
  }
  return true;
}

/// 一页拉多少
const kMediaPageSize = 50;

/// 频道的媒体与文件页
class ChannelMediaPage extends ConsumerStatefulWidget {
  const ChannelMediaPage({super.key, required this.channelId});

  final int channelId;

  @override
  ConsumerState<ChannelMediaPage> createState() => _ChannelMediaPageState();
}

class _ChannelMediaPageState extends ConsumerState<ChannelMediaPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);

  @override
  void initState() {
    super.initState();
    // 每个 tab 的首次加载由 _MediaTabView 自己在 initState 里做
    //（TabBarView 懒构建，切到哪个才建哪个）
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final channel = ref.watch(channelProvider(widget.channelId));
    final title = channel == null || channel.name.isEmpty
        ? '#${widget.channelId}'
        : channel.name;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.t.chatMediaTitle(title)),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            for (final tab in MediaTab.values)
              Tab(text: tab.labelIn(context.t)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          for (final tab in MediaTab.values)
            _MediaTabView(channelId: widget.channelId, tab: tab),
        ],
      ),
    );
  }
}

class _MediaTabView extends ConsumerStatefulWidget {
  const _MediaTabView({required this.channelId, required this.tab});

  final int channelId;
  final MediaTab tab;

  @override
  ConsumerState<_MediaTabView> createState() => _MediaTabViewState();
}

class _MediaTabViewState extends ConsumerState<_MediaTabView> {
  /// 上一页是不是"满的"（满了才可能有更早的）
  bool _maybeMore = false;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetch());
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(
      mediaPostsProvider((channelId: widget.channelId, tab: widget.tab)),
    );
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _ErrorView(message: userFacingError(e), onRetry: _reload),
      data: (page) {
        if (page.isEmpty) {
          if (_error != null) {
            return _ErrorView(message: _error!, onRetry: _reload);
          }
          return Center(child: Text(context.t.chatMediaEmpty));
        }
        final body =
            widget.tab == MediaTab.image || widget.tab == MediaTab.video
            ? _MediaGrid(
                channelId: widget.channelId,
                tab: widget.tab,
                page: page,
              )
            : _MediaList(
                channelId: widget.channelId,
                tab: widget.tab,
                page: page,
              );
        if (!_maybeMore) return body;
        return Column(
          children: [
            Expanded(child: body),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: _loadingMore
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton.icon(
                        onPressed: page.isEmpty
                            ? null
                            : () => _loadMore(page.last.postId),
                        icon: const Icon(Icons.expand_more),
                        label: Text(context.t.chatMediaLoadEarlier),
                      ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _reload() async {
    setState(() => _error = null);
    await _fetch();
  }

  Future<void> _fetch({int olderThanPostId = 0}) async {
    final t = context.t;
    try {
      final n = await ref
          .read(chatSessionControllerProvider.notifier)
          .loadMedia(
            channelId: widget.channelId,
            fileTypes: mediaQueryFor(widget.tab).fileTypes,
            olderThanPostId: olderThanPostId,
          );
      if (!mounted) return;
      setState(() {
        _maybeMore = n >= kMediaPageSize;
        _loadingMore = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = t.botsLoadFailed(userFacingError(e));
        _loadingMore = false;
      });
    }
  }

  Future<void> _loadMore(int oldestPostId) async {
    setState(() => _loadingMore = true);
    await _fetch(olderThanPostId: oldestPostId);
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        FilledButton(onPressed: onRetry, child: Text(context.t.photoRetry)),
      ],
    ),
  );
}

/// 图片/视频：网格
class _MediaGrid extends ConsumerWidget {
  const _MediaGrid({
    required this.channelId,
    required this.tab,
    required this.page,
  });

  final int channelId;
  final MediaTab tab;
  final List<PostDto> page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(chatApiProvider);
    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: page.length,
      itemBuilder: (context, i) {
        final post = page[i];
        final prop = post.attachments.first;
        return _GridTile(
          post: post,
          prop: prop,
          api: api,
          access: ref
              .read(chatSessionControllerProvider.notifier)
              .attachmentAccessFor(ref.watch(channelProvider(channelId))),
        );
      },
    );
  }
}

class _GridTile extends StatelessWidget {
  const _GridTile({
    required this.post,
    required this.prop,
    this.api,
    this.access,
  });

  final PostDto post;
  final FilePropDto prop;
  final ChatApi? api;
  final AttachmentAccess? access;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final access = this.access;
    final url = access != null
        ? null
        : api?.fileUrl(post.postId, thumbnail: true, size: ChatApi.thumbMedium);
    return InkWell(
      onTap: () {
        if (url == null && access == null) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ImageViewerPage(
              url: access != null ? '' : api!.fileUrl(post.postId),
              title: access?.decodeName(prop.label) ?? prop.label,
              api: api,
              post: post,
              prop: prop,
              access: access,
            ),
          ),
        );
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (access != null)
            FutureBuilder<List<int>?>(
              future: access.bytes(post.postId),
              builder: (context, snap) {
                final bytes = snap.data;
                if (bytes == null || bytes.isEmpty) {
                  return Container(
                    color: theme.colorScheme.surfaceContainerHighest,
                  );
                }
                final raw = Uint8List.fromList(bytes);
                // 频道媒体墙同样不裁切（读不出比例就 contain 留白）
                final aspect = aspectOfImageBytes(raw);
                return AspectImage(
                  aspect: aspect,
                  child: Image.memory(
                    raw,
                    fit: aspect == null ? BoxFit.contain : BoxFit.cover,
                    // 坏图/半截图不许抛未捕获异常（真机遇到损坏缩略图同样）：
                    // 失败必须可见且可诊断（§2.0.17）
                    errorBuilder: (_, _, _) {
                      debugPrint(
                        '[channelMediaThumb] decode failed post=${post.postId}',
                      );
                      return Container(
                        color: theme.colorScheme.surfaceContainerHighest,
                        alignment: Alignment.center,
                        child: const Icon(Icons.broken_image_outlined),
                      );
                    },
                  ),
                );
              },
            )
          else if (url == null)
            Container(color: theme.colorScheme.surfaceContainerHighest)
          else
            ChatRemoteImage(
              url: url,
              // 网络图拿不到字节头 → 先 `contain` 留白，也不裁
              fit: BoxFit.contain,
              loading: Container(
                color: theme.colorScheme.surfaceContainerHighest,
              ),
              failure: Container(
                color: theme.colorScheme.surfaceContainerHighest,
                alignment: Alignment.center,
                child: const Icon(Icons.broken_image_outlined),
              ),
            ),
          if (prop.isVoiceMessage)
            const Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.mic, size: 16, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}

/// 音频/文件：列表
class _MediaList extends ConsumerWidget {
  const _MediaList({
    required this.channelId,
    required this.tab,
    required this.page,
  });

  final int channelId;
  final MediaTab tab;
  final List<PostDto> page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(chatApiProvider);
    final access = ref
        .read(chatSessionControllerProvider.notifier)
        .attachmentAccessFor(ref.watch(channelProvider(channelId)));
    final users = ref.watch(usersProvider).value ?? const [];
    final names = {
      for (final u in users)
        if (u.nickname.isNotEmpty) u.userId: u.nickname,
    };
    return ListView.separated(
      itemCount: page.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final post = page[i];
        final prop = post.attachments.first;
        final sender =
            names[post.creatorId] ?? context.t.chatUserFallback(post.creatorId);
        return DesignRowTile(
          leading: Icon(_icon(prop)),
          title: Text(
            access?.decodeName(prop.label) ?? prop.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [
              sender,
              if (prop.humanSize.isNotEmpty) prop.humanSize,
              if (post.attachments.length > 1)
                context.t.chatMediaAttachmentCount(post.attachments.length),
            ].join(' · '),
          ),
          trailing: const Icon(Icons.download_outlined),
          onTap: () async {
            final err = await openAttachment(api, post, prop, access: access);
            if (err != null && context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(err)));
            }
          },
        );
      },
    );
  }

  static IconData _icon(FilePropDto prop) {
    if (kAudioExtensions.contains(prop.extension)) {
      return Icons.audiotrack_outlined;
    }
    if (kVideoExtensions.contains(prop.extension)) {
      return Icons.movie_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }
}
