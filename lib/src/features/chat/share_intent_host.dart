// 「分享到 Chat」的接收端：接住原生送来的 [ShareIntentData]，
// 让用户选一个频道，再用**既有**发送链路发出去。
//
// 挂在频道列表页外层（见 `channel_list_page.dart` 的 `body`），因为分享进来的
// 冷启动落点就是主页。选频道用底部弹层，避免为一个入口新增路由。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/data_text.dart';
import '../../core/router/app_routes.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/channel_dto.dart';
import '../notes/note_gaps_text.dart';
import '../notes/note_share_clip.dart';
import 'chat_session_controller.dart';
import 'share_intent.dart';

/// `_pickChannel` 里"剪藏到笔记"分支的哨兵值（频道 id 恒为正，不会撞车）
const int kClipToNoteValue = -1;

class ShareIntentHost extends ConsumerStatefulWidget {
  const ShareIntentHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ShareIntentHost> createState() => _ShareIntentHostState();
}

class _ShareIntentHostState extends ConsumerState<ShareIntentHost> {
  StreamSubscription<ShareIntentData>? _sub;
  bool _busy = false;

  /// 还没处理的那次分享（频道列表可能还没加载完，等它到位再弹选频道）
  ShareIntentData? _pending;

  @override
  void initState() {
    super.initState();
    final source = ref.read(shareIntentSourceProvider);
    _sub = source.incoming.listen(_enqueue);
    // 冷启动：Activity 起来时带来的分享
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final pending = await source.takePending();
      if (pending != null) _enqueue(pending);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _enqueue(ShareIntentData data) {
    _pending = data;
    _maybeHandle();
  }

  /// 频道列表到位才处理；否则留着，等 `channelsProvider` 第一次吐出数据。
  void _maybeHandle() {
    if (_busy || !mounted || _pending == null) return;
    final channels = ref.read(channelsProvider).value;
    if (channels == null || channels.isEmpty) return;
    final data = _pending!;
    _pending = null;
    _busy = true;
    _handle(data, channels).whenComplete(() {
      _busy = false;
      if (_pending != null) _maybeHandle();
    });
  }

  Future<void> _handle(ShareIntentData data, List<ChannelDto> channels) async {
    final channelId = await _pickChannel(channels);
    if (channelId == null || !mounted) return;
    // J8/L2：分享面板的「剪藏到笔记」分支（不经过 Chat 发送链路）
    if (channelId == kClipToNoteValue) {
      await _clipToNote(data);
      return;
    }

    final ctrl = ref.read(chatSessionControllerProvider.notifier);
    var ok = true;
    if (data.hasFiles) {
      // 附件：正文当第一条的说明（原版 `ShareEditFragment` 也是把文字当 caption）
      for (var i = 0; i < data.files.length; i++) {
        final f = data.files[i];
        final sent = await ctrl.sendAttachment(
          channelId: channelId,
          filePath: f.path,
          fileName: f.name,
          mimeType: f.mime.isEmpty ? null : f.mime,
          message: i == 0 ? data.text : '',
        );
        ok = ok && sent;
      }
    } else {
      ok = await ctrl.sendMessage(channelId, data.text.trim());
    }
    if (!mounted) return;
    if (!ok) {
      _toast(dataText('chatShareFailed', '分享失败，请重试。'));
      return;
    }
    _toast(dataText('chatSharedToChannel', '已分享到频道。'));
    if (data.overflow > 0) {
      _toast(
        dataText('chatShareExceedMaxFiles', '一次最多分享 50 个文件，已忽略多余的。'),
      );
    }
    // 单测里没有 GoRouter（只搭 MaterialApp），别为了跳转把用例打挂
    if (context.mounted && GoRouter.maybeOf(context) != null) {
      context.push(AppRoutes.chatOf(channelId));
    }
  }

  /// 剪藏到笔记（J8/L2）：URL → 官方网页剪藏；纯文本 → 新建笔记；
  /// 图片/文件 → `Note/create` + `Note/set` multipart 附件。
  Future<void> _clipToNote(ShareIntentData data) async {
    try {
      await clipSharedPayloadToNote(ref, data);
      _toast(noteGaps(NoteGapsTextKeys.shareClipDone, '已剪藏到笔记。'));
    } catch (_) {
      _toast(noteGaps(NoteGapsTextKeys.shareClipFailed, '分享剪藏失败，请稍后再试。'));
    }
  }

  Future<int?> _pickChannel(List<ChannelDto> channels) {
    return showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, Gap.sm),
              child: Text(
                dataText('chatShareToChannel', '分享到频道'),
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            // 分享目标：剪藏到笔记（官方 DS note 的 SEND 目标之一）
            DesignRowTile(
              key: const Key('note-clip-share-entry'),
              leading: const Icon(Icons.bookmark_add_outlined),
              title: Text(noteGaps(NoteGapsTextKeys.shareClip, '剪藏到笔记')),
              onTap: () => Navigator.of(ctx).pop(kClipToNoteValue),
            ),
            const Divider(height: 1),
            for (final c in channels)
              DesignRowTile(
                leading: const Icon(Icons.tag),
                title: Text(c.name.isEmpty ? '#${c.channelId}' : c.name),
                onTap: () => Navigator.of(ctx).pop(c.channelId),
              ),
            const SizedBox(height: Gap.sm),
          ],
        ),
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    // 频道列表是 Drift 的 watch 流：冷启动分享进来时它可能还是空的，
    // 等第一次吐出数据再弹选频道。
    ref.listen(channelsProvider, (_, next) {
      if ((next.value ?? const <ChannelDto>[]).isNotEmpty) _maybeHandle();
    });
    return widget.child;
  }
}
