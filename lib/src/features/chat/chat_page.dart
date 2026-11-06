// 频道消息页 —— Phase 3 的可见成果：能看、能发。
//
// 数据流：
//   postsProvider(channelId) → ChatStore.watchPosts()（local-first，新的在前）
//   → 本页反向渲染（ListView.reverse），底部是输入框
//   滚动到顶部（也就是最旧的一端）时自动 loadOlderPosts
//
// 进频道时做两件事：`Post/list` 拉第一页 + `Channel/view` 上报已读。
// 页面停留期间每收到一条新消息也顺手标已读（用户就在看，不该涨未读）。
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:image_picker/image_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/kit/design_kit.dart';
import '../../design/design_palette.dart';
import '../../core/dev/dev_tools.dart';
import '../../core/i18n/l10n.dart';
import '../../core/media/camera_support.dart';
import '../../core/i18n/data_text.dart';
import '../../core/router/app_routes.dart';
import '../../core/settings/acl.dart';
import '../../core/settings/app_settings.dart';
import '../../core/theme/app_tokens.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../../core/theme/app_typography.dart';
import '../../core/ui/app_sheet.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/glass_pane.dart';
import '../../core/ui/hud_widgets.dart';
import '../../core/ui/tech_frame.dart';
import '../../core/ui/orb_button.dart';
import '../../data/dto/channel_dto.dart';
import '../../data/dto/post_dto.dart';
import '../../data/dto/sticker_dto.dart';
import '../../data/dto/user_dto.dart';
import '../../data/chat_api.dart';
import '../../data/emoji_table.dart';

import 'attachment_access.dart';
import 'channel_type_label.dart';
import 'channel_content_page.dart';
import 'subscribed_threads_page.dart';
import 'link_preview_card.dart';
import 'url_actions.dart';
import 'attachment_view.dart';
import 'voice_message.dart';
import 'chatbot_attachment.dart';
import 'chatbot_welcome.dart';
import 'chat_session_controller.dart';
import 'channel_manage_sheet.dart';
import 'channel_notification_sheet.dart';
import 'file_actions.dart';
import 'post_actions_sheet.dart';
import 'read_status_page.dart';
import 'system_message.dart';
import 'user_avatar.dart';
import 'user_profile_sheet.dart';
import 'post_editable.dart';
import 'emoji_picker_sheet.dart';
import 'sticker_view.dart';
import '../../core/settings/server_settings.dart';
import 'rich_text.dart';
import 'typing_notifier.dart';
import 'vote_card.dart';
import 'autocomplete.dart';
import 'slash_command.dart';
import 'vote_editor.dart';
import '../../data/e2ee/e2ee_service.dart';
import '../notifications/notification_service.dart';
import '../settings/e2ee_controller.dart';
import '../../core/user_facing_error.dart';

/// 「相册选视频 / 录制视频」真正拉起系统选择器/相机的方式。
///
/// 抽成 provider 只为单测：真机走 `image_picker`（`pickVideo(gallery)` =
/// 官方 `launchVideo` 的 `video/*.` 选择器；`pickVideo(camera)` = 官方
/// `launchRecord` 的 `android.media.action.VIDEO_CAPTURE`），测试环境里没有
/// 平台通道，换成假实现就能离线断言"调了哪个 source、拿到路径后走了上传链"。
typedef ChatVideoPicker = Future<XFile?> Function(ImageSource source);

final chatVideoPickerProvider = Provider<ChatVideoPicker>(
  (ref) =>
      (source) => ImagePicker().pickVideo(source: source),
);

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key, required this.channelId, this.focusPostId = 0});

  final int channelId;

  /// 从搜索结果跳进来时，滚到这条消息附近（0 = 正常打开）
  final int focusPostId;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _scroll = ScrollController();

  /// 提前抓住控制器：`dispose()` 里再用 `ref` 会报
  /// "Using ref when a widget is about to or has been unmounted is unsafe"
  ChatSessionController? _session;
  final _input = TextEditingController();
  final _inputFocus = FocusNode();

  bool _loadingOlder = false;
  bool _hasMore = true;
  bool _sending = false;
  bool _initialLoadStarted = false;

  /// 发送成功次数：只用来给"发射光扫"换 key（换一次 = 重放一次一次性动画）
  int _sendSweeps = 0;

  /// 进频道那一刻的 postId 水位：比它新的消息算"未读"，用来画
  /// "以下为新消息"分隔线（本地库没有 last_read_post_id，这是最接近的近似）
  int _unreadAfterPostId = 0;

  /// 是否停在底部（reverse 列表 offset ≈ 0）
  bool _atBottom = true;

  /// 离开底部后新到的消息条数（滚动到底的球上显示）
  int _pendingBelow = 0;

  /// 已知的最新一条（用来发现"新消息到了"）
  int _topPostId = 0;

  /// Phase 8：通知服务（initState 里取好，dispose 里只用字段）
  NotificationService? _notifications;
  int _lastSeenCount = 0;

  /// 每频道草稿（原版 `ChatChannelPosting`）：initState 里抓住 settings，
  /// 这样 `dispose()` 里不用再碰 `ref` 就能落盘。
  SettingsService? _settings;
  Timer? _draftTimer;

  /// 上次落盘的草稿文本：变了才写，避免每次 setState 都打一次库
  String _savedDraft = '';

  @override
  void initState() {
    super.initState();
    // 提前抓住控制器：dispose() 里再用 ref 会抛
    // "Using ref when a widget is about to or has been unmounted is unsafe"
    _session = ref.read(chatSessionControllerProvider.notifier);
    _scroll.addListener(_onScroll);
    _input.addListener(_onInputChanged);
    _settings = ref.read(settingsServiceProvider);
    _restoreDraft();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialLoad());
    // Phase 8：正在看的频道不弹通知（进频道就登记，退出清掉）。
    // 注意要在 initState 里存字段：dispose() 里再用 ref.read 会抛
    // "Using ref when a widget is about to or has been unmounted is unsafe"。
    final notifications = ref.read(notificationServiceProvider);
    notifications.activeChannelId = widget.channelId;
    _notifications = notifications;
  }

  @override
  void didUpdateWidget(covariant ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 同一个 State 被复用但换了频道（例如 `go` 到另一条 `/chat/<id>`）：
    // 先把旧频道的草稿按**旧 id** 落盘，再清空输入并回填新频道的草稿，
    // 否则草稿会被写错频道、或直接丢。
    if (oldWidget.channelId != widget.channelId) {
      _flushDraft(oldWidget.channelId);
      _input.clear();
      _savedDraft = '';
      _restoreDraft();
    }
  }

  /// 进频道回填草稿（原版 `ChannelFragment.java:436` `fetchPostingText`）
  Future<void> _restoreDraft() async {
    final settings = _settings;
    if (settings == null) return;
    final text = await settings.channelPostingText(widget.channelId);
    if (!mounted || text.isEmpty || _input.text.isNotEmpty) return;
    _savedDraft = text;
    _input.text = text;
    _input.selection = TextSelection.collapsed(offset: text.length);
  }

  void _onInputChanged() {
    // 300ms 防抖：官方只在离开频道时存一次，但切后台/被杀就丢了；
    // 打字停顿即落盘更稳，又不会每敲一下打一次库。
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 300), _saveDraftNow);
  }

  void _saveDraftNow() {
    _draftTimer?.cancel();
    _draftTimer = null;
    _flushDraft(widget.channelId);
  }

  /// 把当前输入落到 [channelId] 的草稿行（文本没变就跳过）
  void _flushDraft(int channelId) {
    final settings = _settings;
    if (settings == null) return;
    final text = _input.text;
    if (text == _savedDraft) return;
    _savedDraft = text;
    unawaited(settings.setChannelPostingText(channelId, text));
  }

  @override
  void dispose() {
    if (_notifications?.activeChannelId == widget.channelId) {
      _notifications?.activeChannelId = null;
    }
    // 离开频道页就别再挂着"正在输入"（原版 detach 时同样 clearTyping）
    _session?.clearTyping();
    // 原版 `ChannelFragment.onDestroyView:582` 在这里 savePostingText
    _draftTimer?.cancel();
    _draftTimer = null;
    _flushDraft(widget.channelId);
    _input.removeListener(_onInputChanged);
    _scroll.dispose();
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _initialLoad() async {
    if (_initialLoadStarted) return;
    _initialLoadStarted = true;
    final t = context.t;
    final ctrl = ref.read(chatSessionControllerProvider.notifier);
    // analytics: entering the "My Space" section (synobot channel)
    final channel = ref
        .read(channelsProvider)
        .value
        ?.where((c) => c.channelId == widget.channelId)
        .firstOrNull;
    if (channel != null && channel.type == 'synobot') {
      trackView(UsageModule.chat, screen: 'my_space');
    }
    // 记录"进频道时的水位"：比它新的消息就是这次要标"以下为新消息"的部分
    final before = await ref
        .read(chatStoreProvider)
        .postsForChannel(widget.channelId, limit: 1);
    if (before.isNotEmpty) _unreadAfterPostId = before.first.postId;
    // 原版顺序：进频道先 `Channel/enter`（带 conn_id），再拉消息/标已读
    await ctrl.enterChannel(widget.channelId);
    try {
      await ctrl.loadPosts(
        widget.channelId,
        force: widget.focusPostId > 0,
        aroundPostId: widget.focusPostId,
      );
    } catch (e) {
      trackOnceFailure(
        UsageModule.chat,
        UsageAction.open,
        objectType: 'messages',
        reason: 'load_posts',
        error: e,
      );
      if (mounted) _toast(t.chatLoadMessagesFailed(userFacingError(e)));
    }
    await ctrl.markRead(widget.channelId);
  }

  void _onScroll() {
    // reverse 列表：滚到顶部（maxScrollExtent）就是最旧的一端
    if (!_scroll.hasClients) return;
    final pixels = _scroll.position.pixels;
    final atTop = pixels >= _scroll.position.maxScrollExtent - 120;
    if (atTop) _loadOlder();
    // 底部判定：offset 足够小；回到 8dp 以内算到底，清掉待读计数
    final atBottom = pixels <= 8;
    if (atBottom != _atBottom || (atBottom && _pendingBelow != 0)) {
      setState(() {
        _atBottom = atBottom;
        if (atBottom) _pendingBelow = 0;
      });
    }
  }

  /// 回到最新一条
  void _jumpToBottom() {
    HapticFeedbackCompat.tick();
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      0,
      duration: Motion.resolve(Motion.base),
      curve: Motion.out,
    );
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasMore) return;
    final t = context.t;
    setState(() => _loadingOlder = true);
    try {
      final more = await ref
          .read(chatSessionControllerProvider.notifier)
          .loadOlderPosts(widget.channelId);
      if (mounted) setState(() => _hasMore = more);
    } catch (e) {
      if (mounted) _toast(t.chatLoadOlderFailed(userFacingError(e)));
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  Future<void> _send() async {
    final t = context.t;
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final ctrl = ref.read(chatSessionControllerProvider.notifier);
    final ok = await _sendOrSlash(text, ctrl);
    if (!mounted) return;
    setState(() => _sending = false);
    if (ok) {
      // 使用日志：只记"发了一条消息"，正文一律不记
      track(ref, UsageModule.chat, UsageAction.create, objectType: 'message');
      _input.clear();
      // 发送成功 → 草稿行删掉（原版发送后 `posting_text` 随之清空）
      _savedDraft = '';
      _draftTimer?.cancel();
      _draftTimer = null;
      final settings = _settings;
      if (settings != null) {
        unawaited(settings.setChannelPostingText(widget.channelId, ''));
      }
      // 发射光扫：发送成功的一瞬间给仪表台打一道光（一次性动画）
      setState(() => _sendSweeps++);
      // 发完就不再是"正在输入"了（原版 onCreatePost 之后同样 clearTyping）
      ref.read(chatSessionControllerProvider.notifier).clearTyping();
      // 回到最新一条
      if (_scroll.hasClients) {
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    } else {
      trackOnceFailure(
        UsageModule.chat,
        UsageAction.create,
        objectType: 'message',
        reason: 'send_failed',
      );
      _toast(t.chatSendFailedKept);
    }
  }

  /// 发消息前的分流（原版 `ChannelFragment.onCreatePost`）：
  /// 正文以 `/jumpchat` / `/jitsi` 开头、频道**未加密**、且服务端有对应的斜杠机器人时，
  /// 走 `Webhook.Slash/execute`（机器人去发会议卡片），**不发普通消息**；
  /// 其它情况一律走普通 `Post/create`。
  Future<bool> _sendOrSlash(String text, ChatSessionController ctrl) async {
    final t = context.t;
    if (!isConferenceSlashFormat(text)) {
      return ctrl.sendMessage(widget.channelId, text);
    }

    final channel = ref
        .read(channelsProvider)
        .value
        ?.where((c) => c.channelId == widget.channelId)
        .firstOrNull;
    if (channel == null || channel.encrypted) {
      // 原版判断里就有 `!channel.encrypted()`：加密频道不走斜杠命令
      return ctrl.sendMessage(widget.channelId, text);
    }
    final bots = ref.read(slashCommandsProvider).value ?? const <UserDto>[];
    final bot = findSlashBot(bots, text);
    if (bot == null) {
      // 原版这里是"过滤后什么都不做"（消息静默消失）；我们至少给个提示
      if (mounted) {
        _toast(t.chatSlashCommandNotFound(parseSlashCommandFromMessage(text)));
      }
      return false;
    }
    return ctrl.executeSlashCommand(
      channelId: widget.channelId,
      message: text,
      botUserId: bot.userId,
    );
  }

  /// 面板里点了贴纸/表情：贴纸直接发（`type=sticker`），表情插进输入框
  /// （原版 `ChannelFragment.createSticker` 的两条分支）。
  Future<void> _pickSticker() async {
    final t = context.t;
    final picked = await showEmojiPicker(context);
    if (picked == null || !mounted) return;
    if (picked.isEmoji) {
      final text = StickerCatalog.messageFor(picked.shortcode!);
      final offset = _input.selection.baseOffset;
      // baseOffset 是 double，换算成 int（-1 表示没有选区）
      final at = offset >= 0 && offset.toInt() <= _input.text.length
          ? offset.toInt()
          : _input.text.length;
      _input.text = _input.text.replaceRange(at, at, text);
      _input.selection = TextSelection.collapsed(offset: at + text.length);
      _inputFocus.requestFocus();
      return;
    }
    if (_sending) return;
    final sticker = picked.sticker!;
    setState(() => _sending = true);
    final ok = await ref
        .read(chatSessionControllerProvider.notifier)
        .sendSticker(widget.channelId, sticker.name);
    if (!mounted) return;
    setState(() => _sending = false);
    if (!ok) _toast(t.chatStickerSendFailed);
  }

  /// 给消息加标签
  Future<void> _addHashtag(PostDto post) async {
    final t = context.t;
    final controller = TextEditingController();
    final tag = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.chatAddHashtag),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            prefixText: '#',
            hintText: t.chatHashtagNameHint,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text(t.chatAdd),
          ),
        ],
      ),
    );
    controller.dispose();
    if (tag == null || tag.trim().isEmpty) return;
    final ok = await ref
        .read(chatSessionControllerProvider.notifier)
        .setPostHashtag(channelId: widget.channelId, post: post, hashtag: tag);
    if (!ok) _toast(t.chatAddHashtagFailed);
  }

  /// 移除消息上的某个标签（多个时先选一个）
  Future<void> _removeHashtag(PostDto post) async {
    final t = context.t;
    var tag = post.hashtags.first;
    if (post.hashtags.length > 1) {
      final picked = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(t.chatRemoveHashtagWhich),
          children: [
            for (final t in post.hashtags)
              SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(t),
                child: Text('#$t'),
              ),
          ],
        ),
      );
      if (picked == null) return;
      tag = picked;
    }
    final ok = await ref
        .read(chatSessionControllerProvider.notifier)
        .deletePostHashtag(
          channelId: widget.channelId,
          post: post,
          hashtag: tag,
        );
    if (!ok) _toast(t.chatRemoveHashtagFailed);
  }

  /// 选个时间提醒我（`SYNO.Chat.Post.Reminder`）
  Future<void> _setReminder(PostDto post) async {
    final t = context.t;
    final now = DateTime.now();
    final at = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(hours: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (at == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
    );
    if (time == null || !mounted) return;
    final when = DateTime(at.year, at.month, at.day, time.hour, time.minute);
    if (when.millisecondsSinceEpoch <= DateTime.now().millisecondsSinceEpoch) {
      _toast(t.chatReminderFuture);
      return;
    }
    final ok = await ref
        .read(chatSessionControllerProvider.notifier)
        .setReminder(
          channelId: widget.channelId,
          post: post,
          remindAt: when.millisecondsSinceEpoch,
        );
    if (!ok) _toast(t.chatSetReminderFailed);
  }

  /// 建投票（Phase 6）：正文 + 选项 + 三个开关 + 过期时间
  Future<void> _createVote() async {
    final t = context.t;
    final out = await showVoteEditor(context);
    if (out == null) return;
    setState(() => _sending = true);
    try {
      final ok = await ref
          .read(chatSessionControllerProvider.notifier)
          .createVote(
            channelId: widget.channelId,
            message: out.message,
            choices: [for (final c in out.choices) c.text],
            multiple: out.multiple,
            anonymous: out.anonymous,
            addOption: out.addOption,
            expireAt: out.expireAt,
          );
      if (!ok) _toast(t.chatCreateVoteFailed);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 定时消息：填内容 + 选时间
  Future<void> _scheduleMessage() async {
    final t = context.t;
    final out = await showDialog<_ScheduleDraft>(
      context: context,
      builder: (_) => const _ScheduleDialog(),
    );
    if (out == null) return;
    final id = await ref
        .read(chatSessionControllerProvider.notifier)
        .createScheduledPost(
          channelId: widget.channelId,
          message: out.message,
          sendAt: out.sendAt,
        );
    if (!mounted) return;
    _toast(id > 0 ? t.chatScheduledOk(out.describe()) : t.chatScheduleFailed);
  }

  /// 录音 → 发送语音消息（最长 60 秒）
  Future<void> _recordVoice() async {
    final t = context.t;
    final chosen = await showVoiceRecorderSheet(context);
    if (chosen == null) return;
    setState(() => _sending = true);
    try {
      final ok = await ref
          .read(chatSessionControllerProvider.notifier)
          .sendVoiceMessage(
            channelId: widget.channelId,
            filePath: chosen.path,
            seconds: chosen.seconds,
          );
      if (!ok && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t.chatVoiceSendFailed)));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _attach() async {
    final t = context.t;
    final sync = ref.read(chatSessionControllerProvider);
    if (sync.connId == null || sync.connId!.isEmpty) {
      _toast(t.chatRealtimeNotReady);
      return;
    }
    // 宫格面板：图标 + 标签，一眼看全 5 个入口（原来是 5 行 ListTile，
    // 还得上下扫）
    final source = await showAppSheet<String>(
      context,
      title: t.chatAddToConversation,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.sm, 0, Gap.sm, Gap.md),
          child: Wrap(
            spacing: Gap.md,
            runSpacing: Gap.lg,
            children: [
              _AttachTile(
                icon: Icons.photo_library_outlined,
                label: t.chatAttachGallery,
                onTap: () => Navigator.of(context).pop('image'),
              ),
              // ★ DA293：桌面端没有相机实现（`image_picker` 的 camera 源在
              //   macOS/Windows/Linux 会抛 UnimplementedError，原来是一句
              //   try/catch 都没有的 await ⇒ 点了"没反应"）⇒ 没相机就不摆。
              if (kCameraCaptureSupported)
                _AttachTile(
                  icon: Icons.photo_camera_outlined,
                  label: t.profileEditTakePhoto,
                  onTap: () => Navigator.of(context).pop('camera'),
                ),
              // 官方 composer 有独立的视频按钮：`input_section.xml:104` `video`
              // （相册选视频，`launchVideo`）与 `:112` `record`（录视频，
              // `launchRecord`）。两者都走系统选择器/相机，不额外申请重权限。
              _AttachTile(
                icon: Icons.video_library_outlined,
                label: dataText('chatAttachVideo', '相册视频'),
                onTap: () => Navigator.of(context).pop('video'),
              ),
              if (kCameraCaptureSupported)
                _AttachTile(
                  icon: Icons.videocam_outlined,
                  label: dataText('chatAttachRecordVideo', '录制视频'),
                  onTap: () => Navigator.of(context).pop('record'),
                ),
              _AttachTile(
                icon: Icons.attach_file,
                label: t.chatFilterFile,
                onTap: () => Navigator.of(context).pop('file'),
              ),
              _AttachTile(
                icon: Icons.how_to_vote_outlined,
                label: t.chatFilterVote,
                onTap: () => Navigator.of(context).pop('vote'),
              ),
              // ★ DA190：这里原来的 label 是页面标题 `chatScheduledTitle`
              //   （en "Scheduled messages"）—— 瓦片只有 72dp 宽、`maxLines: 1`，
              //   真机截图里被截成 **"Scheduled ..."**（`§2.0.18`：固定预算里的
              //   截断只能改文案，不能缩字号）。换成专用短标签「定时 / Schedule」。
              _AttachTile(
                icon: Icons.schedule_send_outlined,
                label: t.chatAttachSchedule,
                onTap: () => Navigator.of(context).pop('schedule'),
              ),
            ],
          ),
        ),
      ],
    );
    if (source == null || !mounted) return;
    if (source == 'vote') {
      await _createVote();
      return;
    }
    if (source == 'schedule') {
      await _scheduleMessage();
      return;
    }

    String? path;
    String? name;
    String? mime;
    if (source == 'file') {
      // file_picker 13 起是静态 API（`FilePicker.platform` 没了）
      final f = await FilePicker.pickFile();
      path = f?.path;
      name = f?.name;
    } else if (source == 'video' || source == 'record') {
      // 视频：相册用 `pickVideo(gallery)`（官方 `launchVideo`，系统文件选择器
      // `video/*`）；录制用 `pickVideo(camera)`（官方 `launchRecord`，
      // `android.media.action.VIDEO_CAPTURE`）。两者都复用既有上传链路。
      final recording = source == 'record';
      try {
        final XFile? picked = await ref.read(chatVideoPickerProvider)(
          recording ? ImageSource.camera : ImageSource.gallery,
        );
        path = picked?.path;
        name = picked?.name;
        mime = picked?.mimeType;
        if (mime == null && name != null && name.contains('.')) {
          mime = _videoMimeForExtension(name.split('.').last);
        }
      } on PlatformException catch (e) {
        // 权限被拒 / 没有可用相机应用：给明确分支，不要静默什么都不发生
        if (mounted) {
          _toast(
            recording
                ? dataText(
                    'chatVideoRecordPermissionDenied',
                    '无法访问相机或麦克风，请在系统设置里允许权限后重试。',
                  )
                : dataText(
                    'chatVideoGalleryPermissionDenied',
                    '无法读取相册视频，请检查系统权限后重试。',
                  ),
          );
        }
        debugPrint('[chat] pickVideo 失败（$source）：${e.code} ${e.message}');
        return;
      } catch (e) {
        if (mounted) {
          _toast(dataText('chatVideoPickFailed', '选择视频失败，请重试。'));
        }
        debugPrint('[chat] pickVideo 异常（$source）：$e');
        return;
      }
    } else {
      final picker = ImagePicker();
      // ★ DA293：这里原来是裸 `await`。桌面端 camera 源会抛
      //   `UnimplementedError`，异常落进异步缝隙，界面**零反馈**
      //   （用户原话："take photo 点了没反应"）。现在兜住并给原因。
      try {
        final XFile? shot = source == 'camera'
            ? await picker.pickImage(source: ImageSource.camera)
            : await picker.pickImage(source: ImageSource.gallery);
        path = shot?.path;
        name = shot?.name;
        mime = shot?.mimeType;
      } catch (e) {
        if (mounted) {
          _toast(kCameraCaptureSupported
              ? dataText('chatImagePickFailed', '选择图片失败，请重试。')
              : dataText('chatCameraUnavailable',
                  '这台设备没有可用的相机，请改用「相册」选择图片。'));
        }
        debugPrint('[chat] pickImage 异常（$source）：$e');
        return;
      }
    }
    if (path == null || name == null || !mounted) return;
    if (mime == null) {
      final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
      mime = mimeForExtension(ext);
    }
    // 服务端下发的单文件大小上限（`SYNO.Chat.Admin.Setting.file_size_limit`，
    // 0 = 不限）。原版文案 `error_file_size_exceed` = "文件大小超出限制。"
    final settings = ref.read(serverSettingsProvider);
    final size = await File(path).length().catchError((_) => 0);
    if (settings.fileTooLarge(size)) {
      _toast(t.chatFileTooLarge(settings.fileSizeLimitMb));
      return;
    }
    await _upload(path, name, mime);
  }

  /// 上传并显示进度（大文件可能几十秒，没有进度条用户会以为卡死）
  Future<void> _upload(String path, String name, String mime) async {
    final t = context.t;
    final progress = ValueNotifier<double>(0);
    var closed = false;
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(t.chatUploading(name)),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (context, value, _) =>
              LinearProgressIndicator(value: value <= 0 ? null : value),
        ),
      ),
    ).then((_) => closed = true);
    try {
      final ok = await ref
          .read(chatSessionControllerProvider.notifier)
          .sendAttachment(
            channelId: widget.channelId,
            filePath: path,
            fileName: name,
            mimeType: mime,
            onProgress: (sent, total) {
              if (total > 0) progress.value = sent / total;
            },
          );
      if (mounted && !ok) _toast(t.chatUploadFailed);
    } finally {
      if (!closed && mounted) Navigator.of(context, rootNavigator: true).pop();
      await dialog;
    }
  }

  /// 顶栏溢出菜单（15 项，一个能力都不丢；第 3 批会整体搬进"频道信息页"）
  void _onMenuSelected(String value) {
    final channel = ref.read(channelProvider(widget.channelId));
    switch (value) {
      case 'search':
        context.push(AppRoutes.search);
      case 'media':
        context.push(AppRoutes.mediaOf(widget.channelId));
      // 频道内容列表（原版 TabPostFragment 的置顶/文件/链接 三个 tab
      // + TabBookmarkFragment 的 @我）
      case 'content-pinned':
        context.push(
          AppRoutes.contentOf(widget.channelId, ChannelContentKind.pinned.name),
        );
      case 'content-files':
        context.push(
          AppRoutes.contentOf(widget.channelId, ChannelContentKind.files.name),
        );
      case 'content-links':
        context.push(
          AppRoutes.contentOf(widget.channelId, ChannelContentKind.links.name),
        );
      case 'content-mentions':
        context.push(
          AppRoutes.contentOf(
            widget.channelId,
            ChannelContentKind.mentions.name,
          ),
        );
      // 官方频道菜单的 Bookmarks（`BookmarkFragment`，`has:["star"]`）
      case 'content-bookmarks':
        context.push(
          AppRoutes.contentOf(
            widget.channelId,
            ChannelContentKind.bookmarks.name,
          ),
        );
      // 官方频道菜单的 Threads（`CommentsFragment`，订阅话题列表）
      case 'threads':
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SubscribedThreadsPage(channelId: widget.channelId),
          ),
        );
      case 'scheduled':
        context.push(AppRoutes.scheduledOf(widget.channelId));
      case 'reminders':
        context.push(AppRoutes.remindersOf(widget.channelId));
      case 'hashtags':
        context.push(AppRoutes.hashtagsOf(widget.channelId));
      case 'notification':
        if (channel != null) {
          showChannelNotificationSheet(context, ref, channel);
        }
      case 'members':
        context.push(AppRoutes.membersOf(widget.channelId));
      case 'invite':
        _inviteMembers();
      case 'manage':
        if (channel != null) {
          showChannelManageSheet(
            context,
            ref,
            channel,
            onRemoved: () {
              if (context.mounted) context.pop();
            },
          );
        }
    }
  }

  /// 失败/过期消息的内联"重试"：附件已经不在本地时退回操作面板（那里能编辑/删除）
  Future<void> _retryPost(PostDto post) async {
    final t = context.t;
    HapticFeedbackCompat.light();
    final ctrl = ref.read(chatSessionControllerProvider.notifier);
    final ok = await ctrl.resendPost(post);
    if (!mounted) return;
    if (!ok) {
      _toast(t.chatResendFailedAttachmentGone);
    }
  }

  /// 点回应 chip：切换自己的回应（原版只能从长按菜单点）
  Future<void> _toggleReaction(PostDto post, String label, bool mine) async {
    final t = context.t;
    HapticFeedbackCompat.light();
    final name = _emojiNameOf(label);
    if (name == null) return;
    final ok = await ref
        .read(chatSessionControllerProvider.notifier)
        .setReaction(
          widget.channelId,
          post.postId,
          on: !mine,
          stickerName: name,
        );
    if (!ok && mounted) _toast(t.chatOperationFailed);
  }

  /// 连接状态面板（点顶栏副标题的状态点）
  void _showConnectionSheet(ChatSyncState sync) {
    final t = context.t;
    showAppSheet(
      context,
      title: t.chatConnectionStatus,
      children: [
        AppSheetSection(
          children: [
            AppSheetAction(
              icon: sync.realtime ? Icons.bolt : Icons.bolt_outlined,
              label: sync.realtime
                  ? t.chatRealtimeConnected
                  : t.chatRealtimeDisconnected,
              description: sync.connId == null || sync.connId!.isEmpty
                  ? t.chatRealtimePushHint
                  : 'conn_id ${sync.connId}',
            ),
            AppSheetAction(
              icon: Icons.cloud_outlined,
              label: switch (sync.phase) {
                ChatSyncPhase.idle => t.chatStatusWaitingSync,
                ChatSyncPhase.syncing => t.chatSyncSyncing,
                ChatSyncPhase.ready => t.chatSyncDone,
                ChatSyncPhase.degraded => t.chatSyncDegraded,
                ChatSyncPhase.error => t.chatLinkSyncFailed,
              },
              description: t.chatSyncCounts(sync.channelCount, sync.userCount),
            ),
            if (sync.error != null)
              AppSheetAction(
                icon: Icons.error_outline,
                label: t.chatLastError,
                description: sync.error,
              ),
          ],
        ),
        AppSheetSection(
          children: [
            AppSheetAction(
              icon: Icons.refresh,
              label: t.chatResyncNow,
              onTap: () {
                Navigator.of(context).pop();
                ref.read(chatSessionControllerProvider.notifier).refresh();
              },
            ),
            if (kDevTools)
              AppSheetAction(
                icon: Icons.bug_report_outlined,
                label: t.chatDiagnostics,
                onTap: () {
                  Navigator.of(context).pop();
                  context.push(AppRoutes.diagnostics);
                },
              ),
          ],
        ),
      ],
    );
  }

  /// emoji 字符 → emojione 短代码（服务端只认短代码）
  static String? _emojiNameOf(String label) {
    _emojiNames ??= {for (final e in kEmojiShortcodes.entries) e.value: e.key};
    return _emojiNames![label];
  }

  static Map<String, String>? _emojiNames;

  /// 长按消息 → 操作面板（原 App 的长按 ActionSheet）
  Future<void> _onPostLongPress(PostDto post) async {
    final t = context.t;
    // 「没发出去的消息」（失败 2 / 已过期 3）走原版 `showTempOption` 那套：
    // 只给 重新发送 / 编辑 / 删除，不给星标置顶转发这些（服务端没有这条消息）。
    if (post.postId <= 0 && (post.state == 2 || post.state == 3)) {
      final ctrl = ref.read(chatSessionControllerProvider.notifier);
      final action = await showTempPostActionsSheet(context, post: post);
      if (action == null || !mounted) return;
      switch (action) {
        case TempPostAction.resend:
          final ok = await ctrl.resendPost(post);
          if (!ok && mounted) _toast(t.chatResendFailed);
        case TempPostAction.edit:
          final text = await showEditPostDialog(context, post.message);
          if (text != null && mounted) {
            final ok = await ctrl.editTempPost(post, text);
            if (!ok && mounted) _toast(t.chatResendFailed);
          }
        case TempPostAction.delete:
          await ctrl.deleteTempPost(post);
      }
      return;
    }
    final sync = ref.read(chatSessionControllerProvider);
    final channel = ref.read(channelProvider(widget.channelId));
    final settings = ref.read(serverSettingsProvider);
    // 能不能编辑照抄原版 `PostUtil.isPostEditable`：老服务器只有
    // `Post/list_editable` 返回的那一条能编辑，新服务器按"自己发的 + 时间窗口"。
    final users = ref.read(usersProvider).value ?? const <UserDto>[];
    final deleted = {for (final u in users) u.userId: u.isDisabled};
    var editable = false;
    if (channel != null && post.creatorId == sync.myUserId) {
      var editablePostId = 0;
      if (!sync.supportsEditAllPost) {
        editablePostId = await ref.read(
          channelEditableProvider(widget.channelId).future,
        );
      }
      editable = isPostEditable(
        post,
        channel,
        myUserId: sync.myUserId,
        settings: settings,
        supportsEditAllPost: sync.supportsEditAllPost,
        editablePostId: editablePostId,
        allUsersDisabled: isAllOtherUsersDisabled(
          channel,
          sync.myUserId,
          isDisabled: (uid) => deleted[uid] ?? false,
        ),
      );
    }
    if (!mounted) return;
    final action = await showPostActionsSheet(
      context,
      post: post,
      mine: post.creatorId == sync.myUserId,
      canWrite:
          sync.connId != null && sync.connId!.isNotEmpty && !post.encrypted,
      allowPin: !sync.pinUnsupported,
      // 话题内置顶（`Post/stick` v2）：能力关闭（Post < v2）或已探到 407 就隐藏
      allowStick: sync.supportsStick && !sync.stickUnsupported,
      allowEdit: editable,
      // 原版：`allowReadStatus && post.user().userId == myUserId`
      // （另外频道整体禁用时不显示，见 action sheet 的 mIsChannelDisable 判断）
      allowReadStatus:
          settings.allowReadStatus &&
          post.creatorId == sync.myUserId &&
          channel != null &&
          !isAllOtherUsersDisabled(
            channel,
            sync.myUserId,
            isDisabled: (uid) => deleted[uid] ?? false,
          ),
      allowDownload: isAllowDownload(post),
    );
    if (action == null || !mounted) return;
    final ctrl = ref.read(chatSessionControllerProvider.notifier);
    switch (action) {
      case PostAction.copy:
        await copyPostMessage(context, post.message);
      case PostAction.replyThread:
        if (mounted) {
          context.push(AppRoutes.threadOf(widget.channelId, post.postId));
        }
      case PostAction.react:
        final emoji = await showReactionPicker(context);
        if (emoji != null) {
          await ctrl.setReaction(
            widget.channelId,
            post.postId,
            on: true,
            stickerName: emoji,
          );
        }
      case PostAction.star:
        await ctrl.setStar(widget.channelId, post.postId, star: true);
      case PostAction.unstar:
        await ctrl.setStar(widget.channelId, post.postId, star: false);
      case PostAction.pin:
        await ctrl.setPin(widget.channelId, post.postId, pin: true);
      case PostAction.unpin:
        await ctrl.setPin(widget.channelId, post.postId, pin: false);
      case PostAction.stick:
        await _toggleStick(post, stick: true);
      case PostAction.unstick:
        await _toggleStick(post, stick: false);
      case PostAction.forward:
        await _forward(post);
      case PostAction.reminder:
        await _setReminder(post);
      case PostAction.addHashtag:
        await _addHashtag(post);
      case PostAction.removeHashtag:
        await _removeHashtag(post);
      case PostAction.clearReminder:
        final ok = await ctrl.clearReminder(
          channelId: widget.channelId,
          post: post,
        );
        if (!ok && mounted) _toast(t.chatClearReminderFailed);
      case PostAction.edit:
        if (!mounted) return;
        final text = await showEditPostDialog(context, post.message);
        if (text != null) {
          await ctrl.editMessage(widget.channelId, post.postId, text);
        }
      case PostAction.download:
        await _downloadAttachment(post);
      case PostAction.delete:
        final ok = await ctrl.deleteMessage(widget.channelId, post.postId);
        if (!ok && mounted) _toast(t.chatDeleteFailed);
      case PostAction.readUsers:
      case PostAction.unreadUsers:
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ReadStatusPage(
              postId: post.postId,
              readUsers: action == PostAction.readUsers,
            ),
          ),
        );
    }
  }

  /// 话题内置顶 / 取消（`Post/stick` v2，写 `is_sticky`）—— 与 `PostAction.pin`
  /// （**消息置顶** `Post/pin` v1）是两套东西，见 docs/phase4-protocol.md §5.1。
  ///
  /// 失败**不静默**：407（服务端没开话题置顶）给明确提示，入口随后自动隐藏；
  /// 其它错误码也给重试提示。
  Future<void> _toggleStick(PostDto post, {required bool stick}) async {
    final ctrl = ref.read(chatSessionControllerProvider.notifier);
    final ok = await ctrl.setStick(widget.channelId, post.postId, stick: stick);
    if (!mounted || ok) return;
    final unsupported = ref
        .read(chatSessionControllerProvider)
        .stickUnsupported;
    _toast(
      unsupported
          ? dataText('chatStickUnsupported', '服务端未开启话题内置顶')
          : dataText('chatStickFailed', '话题内置顶失败，请重试。'),
    );
  }

  /// 下载附件到系统「下载」目录（原版长按面板的「下载」→ `DownloadFragment`
  /// option 1：先下到缓存，再让 MediaStore 写进公共下载目录）。
  Future<void> _downloadAttachment(PostDto post) async {
    final t = context.t;
    final prop = post.attachments.isEmpty ? null : post.attachments.first;
    if (prop == null) return;
    final access = ref
        .read(chatSessionControllerProvider.notifier)
        .attachmentAccessFor(ref.watch(channelProvider(widget.channelId)));
    final name = access?.decodeName(prop.label) ?? prop.label;
    final api = ref.read(chatApiProvider);
    final cache = ref.read(cacheServiceProvider);
    final path = await cache.pathFor(post.postId, name);
    if (!mounted) return;
    final outcome = await saveAttachmentToDownloads(
      context,
      api: api,
      post: post,
      access: access,
      cachePath: path,
      name: name,
    );
    if (!mounted) return;
    if (outcome.cancelled) return;
    if (outcome.error != null) {
      _toast(outcome.error!);
      return;
    }
    await cache.touch(path);
    if (mounted) _toast(t.chatSavedToDownloads(name));
  }

  /// 转发：选频道（多选）→ `Post/forward`
  Future<void> _forward(PostDto post) async {
    final t = context.t;
    final channels = ref.read(channelsProvider).value ?? const <ChannelDto>[];
    // `channel_anonymous`：没有权限时转发的目标列表里不出现一对一会话
    // （原版 `ForwardConversationsFragment.java:121` `showAnonymous(...)`）
    final canAnonymous = ref.hasPrivilege(kAclChannelAnonymous);
    final others = channels.where(
      (c) =>
          c.channelId != widget.channelId &&
          (canAnonymous || c.type != 'anonymous'),
    );
    final picked = <int>{};
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.chatForwardTo),
        // P2-1：这里是**最大宽度意图**（转发选择列表不该超出 320），
        // 不是"固定 320"。用 `ConstrainedBox(maxWidth:)` 表达：窄屏自动收窄，
        // 宽屏仍由 `ListView` 撑满到 320 —— 与旧 `SizedBox(width: 320)` 视觉等价。
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: StatefulBuilder(
            builder: (context, setState) => ListView(
              shrinkWrap: true,
              children: [
                for (final c in others)
                  DesignCheckRow(
                    value: picked.contains(c.channelId),
                    title: Text(c.name.isEmpty ? '#${c.channelId}' : c.name),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        picked.add(c.channelId);
                      } else {
                        picked.remove(c.channelId);
                      }
                    }),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.chatForward),
          ),
        ],
      ),
    );
    if (ok != true || picked.isEmpty || !mounted) return;
    final done = await ref
        .read(chatSessionControllerProvider.notifier)
        .forwardPost(post.postId, picked.toList());
    if (mounted) _toast(done ? t.chatForwarded : t.chatForwardFailed);
  }

  /// 会话内直接邀请：跳成员页的邀请列表，选完回来发邀请。
  Future<void> _inviteMembers() async {
    final t = context.t;
    final channel = ref.read(channelProvider(widget.channelId));
    if (channel == null) return;
    final myId = ref.read(chatSessionControllerProvider).myUserId;
    final users = ref.read(usersProvider).value ?? const <UserDto>[];
    final byId = {for (final u in users) u.userId: u};
    final exclude = channel.members.toSet()..add(myId);
    var candidates = users
        .where(
          (u) =>
              u.userId != myId &&
              !u.isDeleted &&
              u.type == 'human' &&
              !exclude.contains(u.userId),
        )
        .toList();
    if (channel.encrypted) {
      candidates = candidates.where((u) => u.publicKey.isNotEmpty).toList();
    }
    if (candidates.isEmpty) {
      _toast(t.chatNoInvitableUsers);
      return;
    }
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(t.chatInviteTitle),
        children: [
          for (final u in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, u.userId),
              child: Text(
                u.username == u.displayName
                    ? u.displayName
                    : ctx.t.chatUserWithAccount(u.displayName, u.username),
              ),
            ),
        ],
      ),
    );
    if (picked == null) return;
    // 这里只邀请一个人（多选在成员页里做）；单个也走同一条 compound/密钥分发链路
    final ok = await ref
        .read(chatSessionControllerProvider.notifier)
        .inviteMembers(widget.channelId, [picked]);
    if (!mounted) return;
    _toast(
      ok
          ? t.chatInvitedUser(byId[picked]?.displayName ?? '#$picked')
          : t.chatInviteFailed,
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final channel = ref.watch(channelProvider(widget.channelId));
    final posts = ref.watch(postsProvider(widget.channelId));
    final users = ref.watch(usersProvider).value ?? const <UserDto>[];
    final sync = ref.watch(chatSessionControllerProvider);
    final connId = sync.connId;

    // ★ 第 40 轮：管理员批量删了帖子 → **必须告诉用户**。
    // 官方 `str_post_delete_by_admin`：「部分帖子已被管理员删除。此页面将在一分钟后刷新。」
    // 原版在 `SocketHelper.deletePostByAdmin` 里弹这句；我们此前是**静默清空**。
    // 用**计数**比较（不是 bool），连着两次也能弹两次。
    ref.listen(chatSessionControllerProvider, (prev, next) {
      if (prev != null &&
          next.adminDeletedSeq > prev.adminDeletedSeq &&
          mounted) {
        _toast(t.chatPostsDeletedByAdmin);
      }
    });

    // 页面开着的时候收到新消息 → 直接标已读
    final list = posts.value ?? const <PostDto>[];
    if (list.length > _lastSeenCount) {
      final grew = _lastSeenCount != 0;
      _lastSeenCount = list.length;
      if (grew && connId != null && connId.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ref
                .read(chatSessionControllerProvider.notifier)
                .markRead(widget.channelId);
          }
        });
      }
    }

    final userMap = <int, UserDto>{for (final u in users) u.userId: u};
    // 聊天机器人会话开头的欢迎卡片（原版 `addChatBotWelcomeMessageToList`，
    // 是客户端自己造的一条"假消息"，服务端不发）
    final botUser = chatbotOf(
      channel?.type ?? '',
      channel?.members ?? const <int>[],
      userMap,
      sync.myUserId,
    );
    final usernames = <String, int>{
      for (final u in users)
        if (u.username.isNotEmpty) u.username: u.userId,
      for (final u in users)
        if (u.displayName.isNotEmpty) u.displayName: u.userId,
    };
    // 匿名会话（1:1）= 对方那个用户；有头像就显示真图（原版 `CommonViewBinder`）
    final conversationPeer = channel != null && channel.isConversation
        ? channel.members
              .where((id) => id != sync.myUserId)
              .map((id) => userMap[id])
              .whereType<UserDto>()
              .firstOrNull
        : null;

    // DA288（r667）：go_router 的分支导航器上 `Navigator.canPop` 可能是假，
    //   以 go_router 自己的判定为准（它是真正管这条路由的栈）。
    final canPop = GoRouter.maybeOf(context)?.canPop() ??
        Navigator.of(context).canPop();

    return Scaffold(
      appBar: AppBar(
        // 左头像：一眼看出是在跟谁/哪个频道聊（点开进频道管理）
        leadingWidth: canPop ? 104 : 56,
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // DA288（r667）：桌面/宽屏原来没有任何返回入口（leading 被头像独占，AppBar 的自动箭头不会出现；底栏在详情页也不在）
            if (canPop)
              IconButton(
                key: const Key('chat-back'),
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                // 用 Navigator（不是 go_router 的 `context.pop()`）：宿主路由在
                // 测试/独立页面里也可能没有 GoRouter，`pop` 会抛 "No GoRouter found"。
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back),
              ),
            if (channel != null)
              Padding(
                padding: const EdgeInsets.only(left: Gap.sm),
                child: Center(
                  child: conversationPeer != null
                      ? UserAvatar(
                          size: 36,
                          user: conversationPeer,
                          background: _channelColor(channel, theme),
                          ring: sync.realtime
                              ? DesignPalette.of(context).ok
                              : null,
                          semanticLabel: t.chatChannelSemantic(
                            _title(channel, userMap, sync.myUserId, text: t),
                          ),
                          onTap: () =>
                              showChannelManageSheet(context, ref, channel),
                        )
                      : RingAvatar(
                          size: 36,
                          icon:
                              channel.isChatBotType || channel.type == 'synobot'
                              ? Icons.smart_toy
                              : null,
                          label:
                              channel.isChatBotType || channel.type == 'synobot'
                              ? null
                              : _avatarInitial(channel, userMap, sync.myUserId),
                          background: _channelColor(channel, theme),
                          ring: sync.realtime
                              ? DesignPalette.of(context).ok
                              : null,
                          semanticLabel: t.chatChannelSemantic(
                            _title(channel, userMap, sync.myUserId, text: t),
                          ),
                          onTap: () => showChannelManageSheet(
                            context,
                            ref,
                            channel,
                            onRemoved: () {
                              if (context.mounted) context.pop();
                            },
                          ),
                        ),
                ),
              ),
          ],
        ),
        titleSpacing: 0,
        // 切频道时一次"仪表光扫"（一次性动画，key 换了才重放）
        flexibleSpace: ScanSweep(
          key: ValueKey('sweep-${widget.channelId}'),
          strength: 0.22,
          duration: const Duration(milliseconds: 720),
          child: const SizedBox.expand(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    _title(channel, userMap, sync.myUserId, text: t),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (channel?.encrypted ?? false)
                  Padding(
                    padding: const EdgeInsets.only(left: Gap.xs + 2),
                    child: Icon(
                      Icons.lock_outline,
                      size: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                if (channel?.isStar ?? false)
                  Padding(
                    padding: const EdgeInsets.only(left: Gap.xs),
                    child: Icon(
                      Icons.star,
                      size: 13,
                      color: DesignPalette.of(context).accent,
                    ),
                  ),
              ],
            ),
            // 副标题：优先显示"正在输入"，否则显示人数/类型 + 连接状态点
            channel == null
                ? const SizedBox.shrink()
                : _ChannelSubtitle(
                    channel: channel,
                    users: userMap,
                    myUserId: sync.myUserId,
                    realtime: sync.realtime,
                    degraded:
                        sync.phase == ChatSyncPhase.degraded ||
                        sync.phase == ChatSyncPhase.error,
                    onTapStatus: () => _showConnectionSheet(sync),
                  ),
          ],
        ),
        actions: [
          HudIconButton(
            icon: Icons.search,
            tooltip: t.chatSearchInChannel,
            onPressed: () => context.push(AppRoutes.search),
          ),
          _ChannelMenuButton(channel: channel, onSelected: _onMenuSelected),
          const SizedBox(width: Gap.xs),
        ],
      ),
      body: Column(
        children: [
          if (channel != null && channel.encrypted)
            _EncryptionBar(channel: channel),
          Expanded(
            child: Stack(
              children: [
                // 深空座舱背景：透视网格 + 星尘 + 扫描线。
                // 强度压得比较低（0.55）+ 粒子很少（14）—— 消息文字的可读性优先，
                // 背景只负责"氛围"，不抢内容。常驻动效走 AppEffects 闸门。
                Positioned.fill(
                  child: RepaintBoundary(child: const SizedBox.expand()),
                ),
                Positioned.fill(
                  child: posts.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Center(
                      child: Text(t.botsLoadFailed(userFacingError(e))),
                    ),
                    data: (msgs) {
                      // 内联已读回执只画在"我发的最后一条"上（跟 Telegram/WhatsApp 一致），
                      // 而且受服务端 `allow_read_status` 门控
                      final lastOwnPostId =
                          msgs
                              .where(
                                (m) =>
                                    m.creatorId == sync.myUserId &&
                                    m.postId > 0,
                              )
                              .firstOrNull
                              ?.postId ??
                          0;
                      final allowReadStatus = ref
                          .read(serverSettingsProvider)
                          .allowReadStatus;
                      // "下方还有几条新消息"：数值在 build 里顺手更新（本轮已经在重建，
                      // 不需要再 setState，避免 build 期间触发重建）
                      _trackNewPosts(msgs);
                      final items = _buildChatItems(
                        msgs,
                        botUser: botUser,
                        myUserId: sync.myUserId,
                        unreadAfterPostId: _unreadAfterPostId,
                        text: t,
                      );
                      if (items.isEmpty) {
                        return AppEmptyState(
                          icon: Icons.forum_outlined,
                          title: t.chatNoMessages,
                          message: t.chatNoMessagesHint,
                        );
                      }
                      return ListView.builder(
                        controller: _scroll,
                        reverse: true,
                        padding: EdgeInsets.zero,
                        // 拖动列表顺手收键盘（现代 IM 的默认手感）
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        // 快速滚动时别让图片/预览白屏（默认 ~250 太紧）
                        scrollCacheExtent: const ScrollCacheExtent.pixels(700),
                        itemCount: items.length + (_loadingOlder ? 1 : 0),
                        itemBuilder: (_, i) {
                          if (i >= items.length) {
                            return const Padding(
                              padding: EdgeInsets.all(Gap.md),
                              child: Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                            );
                          }
                          final item = items[i];
                          switch (item) {
                            case _WelcomeItem():
                              return _ChatbotWelcomeTile(bot: botUser!);
                            case _DateItem(:final label):
                              return _DateSeparator(label: label);
                            case _UnreadMark():
                              return const _UnreadDivider();
                            case _MsgItem():
                              final post = item.post;
                              return _MaterializeIn(
                                play: item.isNew,
                                child: _PostTile(
                                  key: ValueKey(
                                    'post-${post.postId}-${post.tmpPostId}',
                                  ),
                                  post: post,
                                  groupTop: item.groupTop,
                                  groupBottom: item.groupBottom,
                                  // 加密频道在这里解密：解锁/换钥匙后 watch 会触发重绘
                                  decodedMessage: post.encrypted
                                      ? ref
                                            .read(
                                              e2eeControllerProvider.notifier,
                                            )
                                            .displayMessage(
                                              channel,
                                              post.message,
                                            )
                                      : null,
                                  // 加密频道的附件要自己解密（文件名 + 内容）
                                  attachmentAccess: ref
                                      .read(
                                        chatSessionControllerProvider.notifier,
                                      )
                                      .attachmentAccessFor(channel),
                                  usernames: usernames,
                                  usersById: userMap,
                                  channel: channel,
                                  onMentionTap: (uid, name) =>
                                      _openMentionProfile(
                                        uid,
                                        name,
                                        channel,
                                        userMap,
                                      ),
                                  sender: userMap[post.creatorId],
                                  mine: post.creatorId == sync.myUserId,
                                  myUserId: sync.myUserId,
                                  onLongPress: () => _onPostLongPress(post),
                                  // 原版：**单击**未发出的消息才弹 temp 面板
                                  // （`ChannelAdapter.onClick` → `state() == 2 || 3` →
                                  //  `showTempOption`），`onLongClick` 只对 state 0 弹普通面板。
                                  // 我们长按也认 temp（更好按到），单击同样认，两边都能进。
                                  onTap:
                                      (post.postId <= 0 &&
                                          (post.state == 2 || post.state == 3))
                                      ? () => _onPostLongPress(post)
                                      : null,
                                  // 失败/过期消息：气泡下方直接给"重试"，不必再长按
                                  onRetry:
                                      (post.postId <= 0 &&
                                          (post.state == 2 || post.state == 3))
                                      ? () => _retryPost(post)
                                      : null,
                                  // 点回应 chip = 切换自己的回应（原版只能长按菜单点）
                                  onReactionTap: post.postId > 0
                                      ? (label, mine) =>
                                            _toggleReaction(post, label, mine)
                                      : null,
                                  // 内联已读回执：只画在"我发的最后一条"上，且受服务端
                                  // `allow_read_status` 门控（原版没有内联 tick，属自愿偏离）。
                                  //
                                  // 回执按服务端给的 `read_users.length` 渲「已读 / 已读 N 人」；
                                  // 加载中 / 接口失败 / 能力关闭一律为 null → 只留普通 ✓，
                                  // 不报错、不占空白。
                                  readReceipt:
                                      post.postId > 0 &&
                                          post.postId == lastOwnPostId &&
                                          allowReadStatus
                                      ? ref
                                            .watch(
                                              readStatusProvider(post.postId),
                                            )
                                            .maybeWhen(
                                              data: (r) => (
                                                readCount: r.readUsers.length,
                                                allRead:
                                                    r.unreadUsers.isEmpty &&
                                                    r.readUsers.isNotEmpty,
                                              ),
                                              orElse: () => null,
                                            )
                                      : null,
                                  // 服务端可以要求客户端不显示链接预览
                                  // （`Admin.Setting.hide_post_url_preview`；原版 2.11.1
                                  //  还没这个设置，服务端 2.4.6 默认 true）
                                  allowLinkPreview: !ref
                                      .watch(serverSettingsProvider)
                                      .hidePostUrlPreview,
                                  onOpenUrl: (url) => _openUrl(
                                    context,
                                    url,
                                    baseUrlOf(ref),
                                    unsafe: !post.safeUrl,
                                  ),
                                  api: ref.read(chatApiProvider),
                                  pendingLocalPath:
                                      sync.pendingFiles[post.tmpPostId],
                                  onOpenThread: post.commentCount > 0
                                      ? () => context.push(
                                          AppRoutes.threadOf(
                                            widget.channelId,
                                            post.postId,
                                          ),
                                        )
                                      : null,
                                ),
                              );
                          }
                        },
                      );
                    },
                  ),
                ),
                // 滚离底部时的"回到最新"球；有新消息时带上计数
                if (!_atBottom)
                  Positioned(
                    right: Gap.lg,
                    bottom: Gap.md,
                    child: OrbButton(
                      icon: Icons.arrow_downward_rounded,
                      tooltip: t.chatBackToLatest,
                      semanticLabel: _pendingBelow > 0
                          ? t.chatBackToLatestUnread(_pendingBelow)
                          : t.chatBackToLatest,
                      size: 44,
                      iconSize: 20,
                      badge: _pendingBelow > 0
                          ? CountBadge(count: _pendingBelow, dense: true)
                          : null,
                      onPressed: _jumpToBottom,
                    ),
                  ),
              ],
            ),
          ),
          // 「正在输入」现在是顶栏副标题的一部分（原版是列表下方一整条），
          // 省掉一整行高度；文案与 loading dots 逻辑不变。
          _Composer(
            channelId: widget.channelId,
            sweepToken: _sendSweeps,
            controller: _input,
            focusNode: _inputFocus,
            sending: _sending,
            enabled: connId != null && connId.isNotEmpty,
            onSend: _send,
            onAttach: _attach,
            onRecord: _recordVoice,
            onSticker: _pickSticker,
            onTyping: () => ref
                .read(chatSessionControllerProvider.notifier)
                // typing 载荷是 thread_id：频道内恒 0（原版同此）
                .typing(0),
          ),
        ],
      ),
    );
  }

  static String _title(
    ChannelDto? channel,
    Map<int, UserDto> users,
    int myUserId, {
    AppText? text,
  }) {
    final t = text ?? currentText();
    if (channel == null) return t.chatChannel;
    // 原版 `Channel.displayName()`：synobot ⇒ "我的空间"/"My Space"
    // （服务端 `name` 是字面量 `synobot`，不覆盖会当成机器人频道）。
    if (channel.type == 'synobot') return t.chatMySpace;
    if (channel.name.isNotEmpty) return channel.name;
    final others = channel.members.where((id) => id != myUserId).toList();
    final names = others
        .map((id) => users[id]?.displayName)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toList();
    if (names.isNotEmpty) return names.join(t.chatRowNameSeparator);
    return '#${channel.channelId}';
  }

  /// 点 `@提及` → 打开那个人的资料弹窗（原版 `MentionUtil` 的点击分支 →
  /// `ProfileFragment.newInstance(userId)`）。
  ///
  /// 解析规则：**id 来自消息载荷**（正文里的 `@u:<id>`，或 `PostVo.mentions`
  /// 按出现顺序回填），**不解析显示文本**。本地用户表里查不到时补拉一次
  /// `SYNO.Chat.User / list`；仍查不到就显示"资料不可用 + 提及里的名字"，
  /// **不让这次点击变成死操作**。
  Future<void> _openMentionProfile(
    int userId,
    String name,
    ChannelDto? channel,
    Map<int, UserDto> userMap,
  ) async {
    if (!mounted) return;
    if (userId <= 0) {
      // 老服务端 / 加密频道：正文里根本没有 id（原版也认不出这个人）
      await showUnavailableUserProfile(context, name: name);
      return;
    }
    var user = userMap[userId];
    if (user == null) {
      final api = ref.read(chatApiProvider);
      if (api != null) {
        try {
          final list = await api.listUsersByIds([userId]);
          if (list.isNotEmpty) user = list.first;
        } catch (e) {
          debugPrint('[chat] 提及用户解析失败 user_id=$userId: $e');
        }
      }
    }
    if (!mounted) return;
    if (user == null) {
      await showUnavailableUserProfile(context, name: name, userId: userId);
      return;
    }
    await showUserProfileSheet(context, ref, user: user, channel: channel);
  }

  /// 发现"又来了新消息"：不在底部时累加计数，给滚动到底球上的徽标用
  void _trackNewPosts(List<PostDto> msgs) {
    if (msgs.isEmpty) return;
    final topId = msgs.first.postId;
    if (topId == _topPostId) return;
    // 第一次进来不算"新消息"
    if (_topPostId != 0 && topId > _topPostId && !_atBottom) {
      _pendingBelow++;
    }
    _topPostId = topId;
  }
}

// ---------------------------------------------------------------- 列表条目模型
//
// 渲染一个"平整的条目序列"（而不是直接渲染消息列表），这样日期分隔、未读分隔
// 就是序列里的普通元素，不用去和 reverse + index 的偏移打架。

sealed class _ChatItem {
  const _ChatItem();
}

class _MsgItem extends _ChatItem {
  const _MsgItem(
    this.post, {
    required this.groupTop,
    required this.groupBottom,
    this.isNew = false,
  });

  final PostDto post;

  /// 视觉上"这一段消息"的第一条（上方是别人/更旧的消息）——名字与上方圆角画它
  final bool groupTop;

  /// 视觉上"这一段消息"的最后一条（下方是新消息）——头像、时间、状态画它
  final bool groupBottom;

  /// 进频道之后才到的消息：会播一次"材料化"进场（有限动画，只对新消息）
  final bool isNew;
}

class _DateItem extends _ChatItem {
  const _DateItem(this.label);
  final String label;
}

class _UnreadMark extends _ChatItem {
  const _UnreadMark();
}

class _WelcomeItem extends _ChatItem {
  const _WelcomeItem();
}

/// 同一天判定（本地时区）
bool _sameDay(int a, int b) {
  if (a <= 0 || b <= 0) return a == b;
  final da = DateTime.fromMillisecondsSinceEpoch(a);
  final db = DateTime.fromMillisecondsSinceEpoch(b);
  return da.year == db.year && da.month == db.month && da.day == db.day;
}

/// 日期分隔文案：今天 / 昨天 / 星期X（一周内）/ 2025年3月4日
String dayLabel(int millis, {AppText? text}) {
  final t = text ?? currentText();
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(d.year, d.month, d.day);
  final days = today.difference(that).inDays;
  if (days == 0) return t.calToday;
  if (days == 1) return t.fileYesterday;
  if (days == 2) return t.chatDayBeforeYesterday;
  if (days > 2 && days < 7) {
    final names = [
      t.chatWeekdayMon,
      t.chatWeekdayTue,
      t.chatWeekdayWed,
      t.chatWeekdayThu,
      t.chatWeekdayFri,
      t.chatWeekdaySat,
      t.chatWeekdaySun,
    ];
    return t.chatWeekday(names[d.weekday - 1]);
  }
  if (d.year == now.year) {
    return t.chatDateMonthDay(d.month, d.day);
  }
  return t.chatDateFull(d.year, d.month, d.day);
}

/// 把消息列表（新→旧）铺成条目序列（reverse ListView 直接消费）。
///
/// 规则：
///   * `msgs` 是"新的在前"，所以**索引更大 = 更旧**；reverse 渲染后视觉上
///     索引更大 = 更靠上；
///   * 日期分隔插在"那一天最旧的一条"之上（同一天只有一条时也一样）；
///   * "以下为新消息"插在进入频道后第一条非自己发的消息之上。
List<_ChatItem> _buildChatItems(
  List<PostDto> msgs, {
  UserDto? botUser,
  required int myUserId,
  int unreadAfterPostId = 0,
  AppText? text,
}) {
  final t = text ?? currentText();
  final items = <_ChatItem>[];
  var unreadMarked = unreadAfterPostId <= 0;

  // 从旧往新扫，这样"第一条未读"好找；再整体反转成 reverse 需要的顺序
  for (var i = msgs.length - 1; i >= 0; i--) {
    final post = msgs[i];
    final newer = i > 0 ? msgs[i - 1] : null; // 视觉上在下面（更新）
    final older = i + 1 < msgs.length ? msgs[i + 1] : null; // 视觉上在上面

    final sys = post.isSystem;
    final groupTop =
        sys ||
        older == null ||
        older.isSystem ||
        older.creatorId != post.creatorId;
    final groupBottom =
        sys ||
        newer == null ||
        newer.isSystem ||
        newer.creatorId != post.creatorId;

    items.add(
      _MsgItem(
        post,
        groupTop: groupTop,
        groupBottom: groupBottom,
        // 水位线 >0 才算"进过频道"，否则首次加载时会把一整屏都当新消息
        isNew: unreadAfterPostId > 0 && post.postId > unreadAfterPostId,
      ),
    );

    // 未读分隔线：第一条"我没读过的、非自己发的"消息
    if (!unreadMarked &&
        post.postId > unreadAfterPostId &&
        post.creatorId != myUserId &&
        !sys) {
      items.add(const _UnreadMark());
      unreadMarked = true;
    }

    // 日期分隔：这一条是"那天最旧的一条"
    if (older == null || !_sameDay(older.createAt, post.createAt)) {
      items.add(_DateItem(dayLabel(post.createAt, text: t)));
    }
  }

  // 机器人欢迎卡片挂在最早的位置（原版就是这么建的）
  if (botUser != null) items.add(const _WelcomeItem());
  return items.reversed.toList(growable: false);
}

/// 日期分隔：两侧收窄的细线 + 中间**日期文字**。
///
/// ★ r502：以前中间是 `TelemetryLabel`（等宽 + 字距 1.2 的"遥测字"），
/// 真机上 `10/7` 看着像仪表读数；日期是**内容**不是遥测，改设计令牌的
/// `labelSmall` + `hud.dim`。两侧细线也换成设计令牌的 `line`（浅底下才有边界）。
class _DateSeparator extends StatelessWidget {
  const _DateSeparator({required this.label});

  final String label;

  /// 一侧渐隐的细线（两端各画一次，中间留出日期）
  static Widget _fadeLine(Color color, {required bool fadeToRight}) {
    final clear = color.withValues(alpha: 0);
    return Container(
      height: 0.8,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: fadeToRight ? [clear, color] : [color, clear],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
      child: Row(
        children: [
          Expanded(child: _fadeLine(hud.line, fadeToRight: true)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
            child: Text(
              label,
              style: TextStyle(
                fontSize: DesignType.labelSmallSize,
                fontWeight: FontWeight.w600,
                color: hud.dim,
              ),
            ),
          ),
          Expanded(child: _fadeLine(hud.line, fadeToRight: false)),
        ],
      ),
    );
  }
}

/// 「以下为新消息」分隔线
class _UnreadDivider extends StatelessWidget {
  const _UnreadDivider();

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 1,
              color: hud.primary.withValues(alpha: 0.45),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
            child: HudChip(
              text: context.t.chatNewMessagesBelow,
              icon: Icons.arrow_downward,
              glow: true,
            ),
          ),
          Expanded(
            child: Container(
              height: 1,
              color: hud.primary.withValues(alpha: 0.45),
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶栏副标题：优先"正在输入"，否则人数/类型；末尾一个连接状态点（可点开面板）
class _ChannelSubtitle extends ConsumerWidget {
  const _ChannelSubtitle({
    required this.channel,
    required this.users,
    required this.myUserId,
    required this.realtime,
    required this.degraded,
    this.onTapStatus,
  });

  final ChannelDto channel;
  final Map<int, UserDto> users;
  final int myUserId;
  final bool realtime;
  final bool degraded;
  final VoidCallback? onTapStatus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final hud = DesignPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final typingIds = ref.watch(typingUsersProvider(channel.channelId));

    String text;
    if (typingIds.isNotEmpty) {
      final names = <String>[
        for (final id in typingIds)
          if ((users[id]?.displayName ?? '').isNotEmpty) users[id]!.displayName,
      ];
      final isConversation =
          channel.isConversation && channel.members.length == 2;
      if (typingIds.length == 1) {
        final name = names.isEmpty ? '' : names.first;
        text = (isConversation && name.isNotEmpty && name.length <= 20)
            ? t.chatTypingUser(name)
            : t.chatTypingOne;
      } else {
        text = t.chatTypingMany(typingIds.length);
      }
    } else {
      final bits = <String>[
        // ★★ r348 D58：这里原来是**裸枚举** `channel.type`（真机逐字 `public · 3 人`）。
        //   D55 只修了列表行与频道管理弹层两处，**漏了详情页副标题**；守卫也只看那两个
        //   文件、且只认 `${….type}` 插值形状 ⇒ 这个"裸表达式当值"的形状两头都漏。
        channelTypeLabel(channel.type, t),
        if (channel.totalMemberCount > 0)
          t.chatRowMembers(channel.totalMemberCount),
      ];
      text = bits.join(' · ');
    }

    final statusColor = degraded
        ? hud.danger
        : realtime
        ? hud.ok
        : scheme.outline;
    return Row(
      children: [
        Flexible(
          child: typingIds.isEmpty
              ? Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: DesignType.labelSmallSize,
                    color: hud.dim,
                  ),
                )
              : Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: DesignType.labelSmallSize,
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        ),
        const SizedBox(width: Gap.sm),
        PulseDot(
          color: statusColor,
          size: 5,
          pulsing: realtime && !degraded,
          semanticLabel: degraded
              ? t.chatRealtimeDegraded
              : realtime
              ? t.chatLinkReady
              : t.chatRealtimeOffline,
        ),
        if (onTapStatus != null)
          InkWell(
            onTap: onTapStatus,
            borderRadius: BorderRadius.circular(Radii.capsule),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: Gap.xs, vertical: 2),
              child: SizedBox.shrink(),
            ),
          ),
      ],
    );
  }
}

/// 顶栏溢出菜单：13 项能力一个不少，行高用 Row（原来是 PopupMenuItem 套
/// ListTile，双重内边距把每行撑到 ~56dp）
class _ChannelMenuButton extends StatelessWidget {
  const _ChannelMenuButton({required this.channel, required this.onSelected});

  final ChannelDto? channel;
  final ValueChanged<String> onSelected;

  static Widget _row(IconData icon, String label, {Color? color}) => Row(
    children: [
      Icon(icon, size: 19, color: color),
      const SizedBox(width: Gap.md),
      Text(label),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final scheme = Theme.of(context).colorScheme;
    final showMembers =
        channel != null &&
        !channel!.isChatBotType &&
        channel!.type != 'synobot' &&
        channel!.type != 'anonymous';
    return PopupMenuButton<String>(
      tooltip: t.photoMore,
      onSelected: onSelected,
      icon: const Icon(Icons.more_vert),
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.pane),
      ),
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'search',
          child: _row(Icons.search, t.chatSearchThisChannel),
        ),
        if (showMembers)
          PopupMenuItem(
            value: 'members',
            child: _row(
              channel!.brokenUsers.isEmpty
                  ? Icons.group_outlined
                  : Icons.report_gmailerrorred_outlined,
              channel!.brokenUsers.isEmpty
                  ? t.chatSectionMembers
                  : t.chatMembersBroken,
              color: channel!.brokenUsers.isEmpty ? null : scheme.error,
            ),
          ),
        PopupMenuItem(
          value: 'invite',
          child: _row(Icons.person_add_alt, t.chatInvite),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'media',
          child: _row(Icons.photo_library_outlined, t.chatMediaPhotosVideos),
        ),
        PopupMenuItem(
          value: 'content-pinned',
          child: _row(Icons.push_pin_outlined, t.chatPinnedMessages),
        ),
        PopupMenuItem(
          value: 'content-files',
          child: _row(Icons.insert_drive_file_outlined, t.chatAllFiles),
        ),
        PopupMenuItem(
          value: 'content-links',
          child: _row(Icons.link_outlined, t.chatAllLinks),
        ),
        PopupMenuItem(
          value: 'content-mentions',
          child: _row(Icons.alternate_email, t.chatMentions),
        ),
        // 官方 `menu_channel.xml`：Threads / Bookmarks 两个入口（本批补齐）
        PopupMenuItem(
          value: 'threads',
          child: _row(
            Icons.forum_outlined,
            dataText('chatSubscribedThreadsTitle', '订阅话题'),
          ),
        ),
        PopupMenuItem(
          value: 'content-bookmarks',
          child: _row(Icons.star_border, dataText('chatBookmarks', '书签')),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'scheduled',
          child: _row(Icons.schedule_send_outlined, t.chatScheduledInfo),
        ),
        PopupMenuItem(
          value: 'reminders',
          child: _row(
            Icons.notifications_active_outlined,
            t.notifyReminderTitle,
          ),
        ),
        PopupMenuItem(
          value: 'hashtags',
          child: _row(Icons.tag, t.chatHashtags),
        ),
        PopupMenuItem(
          value: 'notification',
          child: _row(Icons.tune, t.chatNotifications),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'manage',
          child: _row(Icons.settings_outlined, t.chatChannelManage),
        ),
      ],
    );
  }
}

/// 频道头像首字母 / 频道色（列表与顶栏共用同一套规则）
String _avatarInitial(
  ChannelDto channel,
  Map<int, UserDto> users,
  int myUserId, {
  AppText? text,
}) {
  if (channel.type == 'synobot') {
    final t = text ?? currentText();
    return t.chatMySpace.characters.first.toUpperCase();
  }
  final title = channel.name.isNotEmpty
      ? channel.name
      : (channel.members
                .where((id) => id != myUserId)
                .map((id) => users[id]?.displayName ?? '')
                .where((s) => s.isNotEmpty)
                .firstOrNull ??
            '#${channel.channelId}');
  return title.isEmpty ? '#' : title.characters.first.toUpperCase();
}

Color _channelColor(ChannelDto channel, ThemeData theme) {
  if (channel.encrypted) return const Color(0xFF0E7490);
  if (channel.type == 'private') return const Color(0xFF4F46E5);
  if (channel.type == 'anonymous') return const Color(0xFF7C3AED);
  if (channel.isChatBotType || channel.type == 'synobot') {
    return const Color(0xFF0F766E);
  }
  return theme.colorScheme.primary;
}

/// 把 reactions 聚合成「emoji × 次数」，并标注自己有没有点过。
///
/// 真机实测的载荷是 `{sticker_name: 'thumbsup', user_ids: [14]}` ——
/// **一个回应一条记录，点了的人装在 `user_ids` 数组里**（不是一人一条）。
/// 反编译的 `ReactionVo` 也是 `userIds` 列表。老版本/别的接口偶尔给
/// 单数 `user_id`，两种都认。
///
/// `sticker_name` 是 **emojione 短代码**（`thumbsup`），要过一遍
/// `emoji_table.dart` 转成字符；服务端贴纸只有 `sticker_id`，Phase 6 再接图片。
List<({String label, int count, bool mine})> aggregateReactions(
  List<Map<String, dynamic>> raw, {
  required int myUserId,
}) {
  final order = <String>[];
  final counts = <String, int>{};
  final mine = <String, bool>{};
  for (final r in raw) {
    final name = '${r['sticker_name'] ?? ''}';
    final label = name.isNotEmpty
        ? emojiForName(name)
        : '🖼${r['sticker_id'] ?? ''}';
    // user_ids 数组优先；没有就退回单数 user_id
    final ids = <int>[
      if (r['user_ids'] is List)
        for (final id in r['user_ids'] as List)
          if (id is num)
            id.toInt()
          else if (id is String)
            int.tryParse(id) ?? 0,
      if (r['user_id'] is num) (r['user_id'] as num).toInt(),
    ];
    final tappers = ids.isEmpty ? 1 : ids.length;
    if (!counts.containsKey(label)) order.add(label);
    counts[label] = (counts[label] ?? 0) + tappers;
    mine[label] = (mine[label] ?? false) || ids.contains(myUserId);
  }
  return [
    for (final label in order)
      (label: label, count: counts[label]!, mine: mine[label]!),
  ];
}

/// 加密频道顶部的状态条：已解锁 / 锁定 / 解不开，后两种情况给一个入口。
class _EncryptionBar extends ConsumerWidget {
  const _EncryptionBar({required this.channel});

  final ChannelDto channel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    // watch 解锁状态，解锁/锁定后这条自动变色
    ref.watch(e2eeControllerProvider);
    final notifier = ref.read(e2eeControllerProvider.notifier);
    final keyState = notifier.keyStateOf(channel);
    final scheme = Theme.of(context).colorScheme;
    final (icon, text, color) = switch (keyState) {
      ChannelKeyState.ready => (Icons.lock, t.chatE2eeUnlocked, scheme.primary),
      ChannelKeyState.locked => (
        Icons.lock_clock,
        t.chatE2eeLockedHint,
        scheme.tertiary,
      ),
      ChannelKeyState.missing => (
        Icons.report_gmailerrorred,
        t.chatE2eeKeyUnreadable,
        scheme.error,
      ),
      ChannelKeyState.notEncrypted => (
        Icons.lock_open,
        t.e2eeKeyStateNotEncrypted,
        scheme.outline,
      ),
    };

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          border: Border(left: BorderSide(color: color, width: 2.5)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: DesignType.bodySmallSize,
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (keyState != ChannelKeyState.ready &&
                keyState != ChannelKeyState.notEncrypted)
              TextButton(
                onPressed: () => context.push(AppRoutes.e2ee),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  keyState == ChannelKeyState.locked ? t.e2eeUnlock : t.e2eeFix,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 点正文里的 URL：本机频道链接 → App 内跳转，其余丢系统浏览器
/// （对齐原版 `UrlUtil.viewUrlOrJumpChannel`，见 `url_actions.dart`）
void _openUrl(
  BuildContext context,
  String url,
  String baseUrl, {
  bool unsafe = false,
}) => openUrlOrJumpChannel(context, url, baseUrl: baseUrl, unsafe: unsafe);

/// 聊天机器人会话开头的欢迎卡片（原版视图类型 112 / `item_post_welcome_message`）
class _ChatbotWelcomeTile extends StatelessWidget {
  const _ChatbotWelcomeTile({required this.bot});

  final UserDto bot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = chatbotWelcomeText(bot, text: context.t);
    final scheme = theme.colorScheme;
    final hud = DesignPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
      child: GlassPane(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.pane),
        ),
        fill: hud.surface2,
        showEdge: true,
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.xl, Gap.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  kChatbotWelcomeTitle,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(width: Gap.md),
                Icon(Icons.smart_toy_outlined, size: 22, color: scheme.primary),
              ],
            ),
            if (text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Text(
                  text,
                  style: AppType.chatBody.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PostTile extends StatelessWidget {
  const _PostTile({
    super.key,
    required this.post,
    required this.sender,
    required this.mine,
    this.groupTop = true,
    this.groupBottom = true,
    this.onRetry,
    this.onReactionTap,
    this.readReceipt,
    this.usernames = const {},
    this.onLongPress,
    this.onTap,
    this.onOpenThread,
    this.myUserId = 0,
    this.api,
    this.pendingLocalPath,
    this.decodedMessage,
    this.attachmentAccess,
    this.usersById = const {},
    this.channel,
    this.allowLinkPreview = true,
    this.onOpenUrl,
    this.onMentionTap,
  });

  /// 是否允许画链接预览卡片（服务端 `hide_post_url_preview` 为真时不画）
  final bool allowLinkPreview;

  /// 点正文链接（要跳频道还是丢浏览器由上层决定）
  final void Function(String url)? onOpenUrl;

  /// 点正文里的 `@提及`：打开那个人的资料弹窗（原版 `MentionUtil` 的点击分支）。
  /// 为空时退回旧的 toast（老测试与独立使用场景照旧）。
  final void Function(int userId, String name)? onMentionTap;

  /// 加密频道的附件访问器（null = 普通频道）
  final AttachmentAccess? attachmentAccess;

  /// 加密频道里已经解好的明文（非加密频道为 null，直接用 post.message）
  final String? decodedMessage;

  final VoidCallback? onLongPress;

  /// 单击回调。目前只有「未发出去的消息」（state 2/3）会挂它 → 弹 temp 面板。
  final VoidCallback? onTap;
  final VoidCallback? onOpenThread;
  final int myUserId;

  /// 附件缩略图/下载要用（拿不到就只显示占位）
  final ChatApi? api;
  final String? pendingLocalPath;

  /// `@名字` → user_id（原文里 @ 的顺序不一定和 mentions 对得上）
  final Map<String, int> usernames;

  /// 系统消息文案要把 user_id 翻成名字（成员进出、踢人…）
  final Map<int, UserDto> usersById;

  /// 系统消息文案里的频道名
  final ChannelDto? channel;

  final PostDto post;
  final UserDto? sender;
  final bool mine;

  /// 这一段消息的第一条（上方圆角 + 显示名字）
  final bool groupTop;

  /// 这一段消息的最后一条（头像 + 时间/状态画在这里）
  final bool groupBottom;

  /// 失败/过期时气泡下方的"重试"
  final VoidCallback? onRetry;

  /// 点回应 chip：切换自己的回应
  final void Function(String label, bool mine)? onReactionTap;

  /// 内联已读回执：null = 不展示已读信息（能力关闭 / 加载中 / 接口失败），
  /// 非 null = 服务端给出的 `read_users.length` 与"是否全部读完"。
  final ({int readCount, bool allRead})? readReceipt;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hud = DesignPalette.of(context);

    // 系统消息：居中切角标签（原来是裸灰字，像日志不像 IM 提示）
    if (post.isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.xl,
          vertical: Gap.sm,
        ),
        child: Center(
          child: HudChip(
            text: _systemText(
              post,
              usersById: usersById,
              text: t,
              channel: channel,
              myUserId: myUserId,
            ),
            dense: true,
          ),
        ),
      );
    }

    final name = sender?.displayName ?? t.chatUserFallback(post.creatorId);
    final color = _colorOf(sender, theme);
    final isBot = post.hasBot || (sender?.isBot ?? false);
    final textColor = mine ? hud.onPrimary : hud.text;

    // 时间/状态行的显示条件：一段消息的最后一条；或本身有"需要被看到"的状态
    // （发送中/失败/过期/星标/已编辑）——失败消息必须每条都能单独重试。
    final showMeta =
        groupBottom ||
        post.state != 0 ||
        post.isStar ||
        post.isSticky ||
        _isEdited(post);

    final avatar = isBot
        ? RingAvatar(
            size: 32,
            icon: Icons.smart_toy_outlined,
            background: color,
            semanticLabel: t.chatAvatarSemantic(name),
          )
        : UserAvatar(
            size: 32,
            user: sender,
            background: color,
            semanticLabel: t.chatAvatarSemantic(name),
          );

    // 贴纸消息不套彩色气泡（Telegram/Signal 的贴纸都是"浮"在背景上的）
    final isSticker = post.type == 'sticker';

    final bubbleRadius = BorderRadius.only(
      topLeft: (groupTop || mine) ? _outer : _inner,
      topRight: (groupTop || !mine) ? _outer : _inner,
      bottomLeft: (groupBottom || mine) ? _outer : _inner,
      bottomRight: (groupBottom || !mine) ? _outer : _inner,
    );

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 加密标记只在这段消息的第一条上出现一次（原来每条都重复一行）
        if (post.encrypted && groupTop)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 12,
                  color: textColor.withValues(alpha: 0.7),
                ),
                const SizedBox(width: Gap.xs),
                Text(
                  t.meE2ee,
                  // ★ r501：消息时间戳不再用等宽"遥测字"，改用设计令牌的 labelSmall
                  style: TextStyle(
                    fontSize: DesignType.labelSmallSize,
                    color: textColor.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        // 注意：这里**不能**套 SelectionArea —— 文本选择的"长按"会抢走手势，
        // 长按操作面板就出不来了（原 App 的长按也是直接弹 ActionSheet）。
        //
        // 贴纸消息（`type=sticker`，正文是 `:<name>:`）：原版
        // `CommonViewBinder.bindSticker` 画 150dp 的贴纸图，不再显示正文。
        if (isSticker)
          StickerView(name: post.message)
        else
          MessageText(
            decodedMessage ?? post.message,
            mentions: post.mentions,
            usernames: usernames,
            mentionNames: mentionNamesById(usersById.values),
            style: AppType.chatBody.copyWith(color: textColor),
            onUrl: (url) => (onOpenUrl ?? (u) => _openUrl(context, u, ''))(url),
            onHashtag: (tag) => _toastHashtag(context, tag),
            onMention: (uid, name) {
              final cb = onMentionTap;
              if (cb != null) {
                cb(uid, name);
              } else {
                _toastMention(context, name);
              }
            },
          ),
        if (post.isThreadReply)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(
              t.chatThreadReply,
              style: TextStyle(
                fontSize: DesignType.labelSmallSize,
                color: textColor.withValues(alpha: 0.75),
              ),
            ),
          ),
        // 机器人消息的附件 + 按钮（props.attachments）
        if (post.chatbotAttachments.isNotEmpty)
          ChatbotAttachmentList(
            channelId: channel?.channelId ?? 0,
            post: post,
            usernames: usernames,
            usersById: usersById,
            onOpenUrl: onOpenUrl ?? (u) => _openUrl(context, u, ''),
            onHashtag: (tag) => _toastHashtag(context, tag),
            onMention: (uid, name) {
              final cb = onMentionTap;
              if (cb != null) {
                cb(uid, name);
              } else {
                _toastMention(context, name);
              }
            },
          ),
        // 投票（props.vote）
        if (post.vote != null) VoteCard(post: post),
        // 附件（图片 / 文本预览 / 文件 / 语音）
        if (post.attachments.isNotEmpty || pendingLocalPath != null)
          AttachmentList(
            post: post,
            api: api,
            access: attachmentAccess,
            pendingLocalPath: pendingLocalPath,
            onError: (msg) => _toast(context, msg),
          ),
        // 链接预览（OG）—— 有附件就不画（原版 `bindFirstUrlOg` 同款）
        if (allowLinkPreview && post.attachments.isEmpty)
          ...(() {
            final preview = post.linkPreview;
            if (preview == null) return const <Widget>[];
            return [
              LinkPreviewCard(
                postId: post.postId,
                prop: preview,
                safeUrl: post.safeUrl,
                availableWidth: 260,
              ),
            ];
          })(),
      ],
    );

    final bubble = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: math.min(560, MediaQuery.sizeOf(context).width * 0.78),
      ),
      child: isSticker
          ? content
          : GlassPane(
              shape: RoundedRectangleBorder(borderRadius: bubbleRadius),
              fill: mine ? hud.primary : hud.surface,
              showEdge: true,
              // 气泡**不开毛玻璃**：一屏十几条 BackdropFilter 会掉帧，
              // 高不透明填充已经足够（性能模式也不必特殊处理）
              padding: const EdgeInsets.fromLTRB(
                Gap.md,
                Gap.sm + 1,
                Gap.md,
                Gap.sm,
              ),
              child: content,
            ),
    );

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress == null
          ? null
          : () {
              HapticFeedbackCompat.medium();
              onLongPress!();
            },
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          Gap.md,
          groupTop ? Gap.md : Gap.xxs,
          Gap.md,
          0,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: mine
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: [
            // 对方的头像只画在"这一段"的最后一条上；其余留等宽占位保持对齐
            if (!mine)
              SizedBox(width: 32 + Gap.sm, child: groupBottom ? avatar : null),
            Flexible(
              child: Column(
                crossAxisAlignment: mine
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  if (groupTop && !mine)
                    Padding(
                      padding: const EdgeInsets.only(
                        bottom: Gap.xs,
                        left: Gap.md,
                      ),
                      child: Text(
                        name,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: hud.dim,
                        ),
                      ),
                    ),
                  bubble,
                  if (showMeta)
                    Padding(
                      padding: const EdgeInsets.only(
                        top: Gap.xs,
                        left: Gap.xs,
                        right: Gap.xs,
                      ),
                      child: _PostMetaRow(
                        post: post,
                        mine: mine,
                        metaColor: hud.dim,
                        readReceipt: readReceipt,
                        edited: _isEdited(post),
                      ),
                    ),
                  // 失败/过期：气泡下方直接给"重试"（不必再长按）
                  if (onRetry != null)
                    Padding(
                      padding: const EdgeInsets.only(
                        top: Gap.xs,
                        right: Gap.xs,
                      ),
                      child: InkWell(
                        onTap: onRetry,
                        borderRadius: BorderRadius.circular(Radii.capsule),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Gap.xs,
                            vertical: 2,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.refresh,
                                size: 13,
                                color: scheme.error,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                t.chatSendFailedRetry,
                                style: TextStyle(
                                  fontSize: DesignType.labelSmallSize,
                                  color: scheme.error,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (post.isSticky)
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.xs, left: Gap.xs),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.push_pin, size: 12, color: hud.dim),
                          const SizedBox(width: 3),
                          Text(
                            t.chatPinned,
                            style: TextStyle(
                              fontSize: DesignType.labelSmallSize,
                              color: hud.dim,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (onOpenThread != null)
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.xs),
                      child: TextButton.icon(
                        onPressed: onOpenThread,
                        icon: const Icon(Icons.forum_outlined, size: 15),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Gap.sm,
                          ),
                          minimumSize: const Size(0, 30),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        label: Text(t.chatReplyCount(post.commentCount)),
                      ),
                    ),
                  if (post.reactions.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.xs, left: Gap.xs),
                      child: Wrap(
                        spacing: Gap.xs,
                        runSpacing: Gap.xs,
                        children: [
                          for (final r in aggregateReactions(
                            post.reactions,
                            myUserId: myUserId,
                          ))
                            _ReactionChip(
                              label: r.label,
                              count: r.count,
                              mine: r.mine,
                              onTap: onReactionTap == null
                                  ? null
                                  : () => onReactionTap!(r.label, r.mine),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 编辑过的消息（服务端 `Post/set` 会更新 update_at）
  static bool _isEdited(PostDto post) =>
      post.updateAt > 0 && post.updateAt > post.createAt + 1000;

  static const _outer = Radius.circular(Radii.bubble);
  static const _inner = Radius.circular(Radii.bubbleInner);

  static void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 点 #话题：Phase 6 会跳到话题搜索页
  static void _toastHashtag(BuildContext context, String tag) =>
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.t.chatHashtagTapHint(tag))),
      );

  /// 提及成功的提示（★ r343 D52：原来在这里**把服务端主键印给用户** ——
  /// 逐字 `@名字（user_id=14）`。提及这件事用户只需要"我提到了谁"，
  /// 主键是内部值（D39/D43/D46/D51 同族）⇒ 只报"已提及谁"。
  /// ⇒ `userId` 形参**一并删掉**（唯一的用途就是那个被删掉的主键）。
  static void _toastMention(BuildContext context, String name) =>
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            dataText(
              'chatMentionSent',
              '已提及 @{name}',
            ).replaceAll('{name}', name),
          ),
        ),
      );

  /// 系统消息文案（完整映射见 `system_message.dart`）
  static String _systemText(
    PostDto post, {
    required Map<int, UserDto> usersById,
    required AppText text,
    ChannelDto? channel,
    int myUserId = 0,
  }) => systemMessageText(
    post,
    usersById: usersById,
    text: text,
    channel: channel,
    myUserId: myUserId,
  );

  static Color _colorOf(UserDto? user, ThemeData theme) {
    final hex = user?.avatarColor ?? '';
    if (hex.startsWith('#') && hex.length == 7) {
      final v = int.tryParse(hex.substring(1), radix: 16);
      if (v != null) return Color(0xFF000000 | v);
    }
    return theme.colorScheme.primary;
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
    return '${d.month}/${d.day} $hm';
  }
}

/// 气泡下方的遥测行：时间 + 星标/加密/发送中/失败/已编辑/已读
class _PostMetaRow extends StatelessWidget {
  const _PostMetaRow({
    required this.post,
    required this.mine,
    required this.metaColor,
    this.readReceipt,
    this.edited = false,
  });

  final PostDto post;
  final bool mine;
  final Color metaColor;

  /// 内联已读回执：null = 不展示已读信息（能力关闭 / 加载中 / 接口失败）
  final ({int readCount, bool allRead})? readReceipt;
  final bool edited;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final scheme = Theme.of(context).colorScheme;
    final hud = DesignPalette.of(context);
    final failed = post.state == 2 || post.state == 3;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _PostTile._time(post.createAt),
          style: TextStyle(
            fontSize: DesignType.labelSmallSize,
            color: metaColor,
          ),
        ),
        if (edited)
          Padding(
            padding: const EdgeInsets.only(left: Gap.xs),
            child: Text(
              t.chatEdited,
              style: TextStyle(
                fontSize: DesignType.labelSmallSize,
                color: metaColor,
              ),
            ),
          ),
        if (post.isStar)
          Padding(
            padding: const EdgeInsets.only(left: Gap.xs),
            child: Semantics(
              label: t.chatStarred,
              child: Icon(Icons.star, size: 13, color: hud.accent),
            ),
          ),
        if (post.encrypted)
          Padding(
            padding: const EdgeInsets.only(left: Gap.xs),
            child: Icon(Icons.lock_outline, size: 12, color: metaColor),
          ),
        // 发送中：环形扫描（"闹钟"图标语义有歧义）
        if (post.state == 1)
          Padding(
            padding: const EdgeInsets.only(left: Gap.xs),
            child: ScanRing(size: 12, semanticLabel: t.chatSending),
          ),
        // 失败/过期：红叹号（原版 `state() == 2 || state() == 3` 同一个图标）
        if (failed)
          Padding(
            padding: const EdgeInsets.only(left: Gap.xs),
            child: Semantics(
              label: t.chatSendFailed,
              child: Icon(Icons.error_outline, size: 14, color: scheme.error),
            ),
          ),
        // 我发的：✓ / ✓✓（✓✓ 只在服务端允许且确实都读过时显示）
        if (mine && post.postId > 0 && !failed)
          Padding(
            padding: const EdgeInsets.only(left: Gap.xs),
            child: Semantics(
              label: readReceipt?.allRead == true ? t.chatRead : t.chatSent,
              child: Icon(
                readReceipt?.allRead == true ? Icons.done_all : Icons.done,
                size: 14,
                color: readReceipt?.allRead == true ? hud.ok : metaColor,
              ),
            ),
          ),
        // 已读回执文案：服务端名单里有已读者才画（`read_users.length > 0`）。
        // 全部读完 = 「已读」；只读了一部分 = 「已读 N 人」。
        // readReceipt == null（能力关闭 / 加载中 / 接口失败）或 0 人时不占位。
        if (mine &&
            post.postId > 0 &&
            !failed &&
            (readReceipt?.readCount ?? 0) > 0)
          Padding(
            padding: const EdgeInsets.only(left: Gap.xs),
            child: Text(
              readReceipt!.allRead
                  ? t.chatRead
                  : t.chatReadStatusReadCount(readReceipt!.readCount),
              style: TextStyle(
                fontSize: DesignType.labelSmallSize,
                color: metaColor,
              ),
            ),
          ),
      ],
    );
  }
}

/// 回应 chip（可点：切换自己的回应；热区撑到 ≥32dp）
class _ReactionChip extends StatelessWidget {
  const _ReactionChip({
    required this.label,
    required this.count,
    required this.mine,
    this.onTap,
  });

  final String label;
  final int count;
  final bool mine;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: mine
          ? t.chatReactionSemanticsMine(label, count)
          : t.chatReactionSemantics(label, count),
      button: onTap != null,
      child: GlassTap(
        radius: Radii.capsule,
        // ★ `DA186`：自己点过的表情胶囊原来是「primary 字 + primary@18% 半透明底」
        //   ⇒ 真机亮色合成只有 ~4.4:1。改不透明 `primarySoft`。
        fill: mine
            ? DesignPalette.of(context).primarySoft
            : scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        showEdge: mine,
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.sm + 1,
          vertical: 4,
        ),
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 一个 Text 里放 "👍 2"：语义完整（读屏会念成整体），
            // 也让测试能一句 `find.text('👍 2')` 命中
            Text(
              count > 1 ? '$label $count' : label,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.15,
                fontWeight: mine ? FontWeight.w700 : FontWeight.w500,
                color: mine ? scheme.primary : scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 消息里的斜杠命令（来自 `User.slash_props`，只有 `bot_type = "slash"` 的机器人有）。
/// 这台 NAS 上是 `/jitsi`（原 App 的 `SlashCommand` 还认 `jumpchat`，由服务端下发）。
final slashCommandsProvider = FutureProvider<List<UserDto>>((ref) async {
  final users = await ref.watch(chatStoreProvider).allUsers();
  return users.where((u) => u.isSlashBot).toList();
});

// ------------------------------------------------------- 正在输入
//
// 文案完全照原版 `ChannelFragment.showTyping` + strings.xml：
//   * 1:1 会话 + 1 个人 + 名字 ≤ 20 字 → `{%1$s} 正在输入`（名字加粗，去掉花括号）
//   * 1 个人（其它情况）              → `1 个人正在输入`
//   * N 个人                          → `%1$d 个人正在输入`
// 右侧是原版那个 LoadingDots（三个跳动的小点）。
class _TypingBar extends ConsumerStatefulWidget {
  const _TypingBar({
    required this.channel,
    required this.users,
    required this.myUserId,
  });

  final ChannelDto? channel;
  final Map<int, UserDto> users;
  final int myUserId;

  @override
  ConsumerState<_TypingBar> createState() => _TypingBarState();
}

class _TypingBarState extends ConsumerState<_TypingBar> {
  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final ids = ref.watch(typingUsersProvider(widget.channel?.channelId ?? 0));
    if (ids.isEmpty) return const SizedBox.shrink();

    final names = <String>[];
    for (final id in ids) {
      final u = widget.users[id];
      if (u != null && u.displayName.isNotEmpty) names.add(u.displayName);
    }
    final channel = widget.channel;
    // 原版 `ChannelFragment.showTyping` 的条件：匿名会话 **且** 成员恰好 2 个
    final isConversation =
        channel != null &&
        channel.isConversation &&
        channel.members.length == 2;
    final String text;
    if (ids.length == 1) {
      final name = names.isEmpty ? '' : names.first;
      text = (isConversation && name.isNotEmpty && name.length <= 20)
          ? t.chatTypingUser(name)
          : t.chatTypingOne;
    } else {
      text = t.chatTypingMany(ids.length);
    }

    final theme = Theme.of(context);
    // 名字加粗（对应原版 SpanUtil.userSpan）
    final rich =
        ids.length == 1 &&
            isConversation &&
            names.isNotEmpty &&
            names.first.length <= 20
        ? TextSpan(
            children: [
              TextSpan(
                text: names.first,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              TextSpan(text: text.substring(names.first.length)),
            ],
          )
        : TextSpan(text: text);

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text.rich(
              rich,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
            ),
          ),
          const SizedBox(width: 4),
          const _TypingDots(),
        ],
      ),
    );
  }
}

/// 三个依次跳动的小点（原版 `LoadingDots`，1s 一个循环）
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void initState() {
    super.initState();
    // "对方正在输入"是**语义上就该持续**的动效，但仍然要受减少动效开关管辖：
    // 关掉动画时三个点保持静态（信息不丢），测试/无障碍也因此可控。
    if (Motion.enabled) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outline;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Opacity(
              // 三个点错开 1/3 个周期，做出"依次跳动"的感觉
              opacity: 0.25 + 0.75 * _wave((_c.value - i / 3) % 1.0),
              child: Container(
                width: 3,
                height: 3,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 0→1→0 的三角波
  static double _wave(double t) => t < 0.5 ? t * 2 : (1 - t) * 2;
}

class _Composer extends ConsumerStatefulWidget {
  const _Composer({
    required this.channelId,
    required this.sweepToken,
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.enabled,
    required this.onSend,
    required this.onTyping,
    required this.onAttach,
    required this.onRecord,
    required this.onSticker,
  });

  final int channelId;

  /// 发送成功计数（换 key → 重放仪表台"发射光扫"）
  final int sweepToken;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final bool enabled;
  final Future<void> Function() onSend;
  final VoidCallback onTyping;
  final Future<void> Function() onAttach;
  final Future<void> Function() onRecord;
  final Future<void> Function() onSticker;

  @override
  ConsumerState<_Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<_Composer> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() => setState(() {});

  /// 光标所在的那个词（空格/换行分隔，原版 `SpaceTokenizer`）
  String get _word {
    final text = widget.controller.text;
    final sel = widget.controller.selection;
    final cursor = sel.isValid ? sel.baseOffset : text.length;
    return currentWord(text, cursor);
  }

  /// 当前该提示什么（`@` 用户 / `#` 标签 / `/` 斜杠命令）
  List<AutocompleteItem> _suggestions() {
    final word = _word;
    if (word.isEmpty) return const [];
    final channel = ref
        .read(channelsProvider)
        .value
        ?.where((c) => c.channelId == widget.channelId)
        .firstOrNull;
    final users = ref.read(usersProvider).value ?? const <UserDto>[];
    final humans = [
      for (final u in users)
        if (u.type == 'human' &&
            !u.isDeleted &&
            u.userId !=
                ref.read(
                  chatSessionControllerProvider.select((s) => s.myUserId),
                ))
          u,
    ];
    return filterAutocomplete(
      word: word,
      fullText: widget.controller.text,
      slashCommands:
          ref.watch(slashCommandsProvider).value ?? const <UserDto>[],
      // 本地缓存的标签（`Channel.Hashtag/list` 的结果，进频道时刷新过）——
      // 每敲一个字符都发请求太浪费，原版也是读本地库
      hashtags:
          ref.watch(channelProvider(widget.channelId))?.hashtags ?? const [],
      mentions: mentionCandidates(users: humans, channel: channel),
    );
  }

  /// 点了一个候选：把当前那个词换成它（原版 `terminateToken` 再补一个空格）
  void _pick(AutocompleteItem item) {
    final text = widget.controller.text;
    final sel = widget.controller.selection;
    final cursor = sel.isValid ? sel.baseOffset : text.length;
    final word = currentWord(text, cursor);
    if (word.isEmpty) return;
    var start = cursor;
    while (start > 0 && text[start - 1] != ' ' && text[start - 1] != '\n') {
      start--;
    }
    var end = cursor;
    while (end < text.length && text[end] != ' ' && text[end] != '\n') {
      end++;
    }
    final next = text.replaceRange(start, end, item.insertText);
    widget.controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        offset: start + item.insertText.length,
      ),
    );
  }

  /// composer 独立「@」按钮：在光标处补一个 `@` 触发词，复用既有候选面板
  /// （`_suggestions()` → `@` 分支把所有真人 + `@channel`/`@here` 列出来）。
  ///
  /// 不在词中间硬贴：前一个字符不是空白就补一个空格（否则会把 `@` 接到上一个
  /// 词尾，原版 `SpaceTokenizer` 会把它当成同一个词，反而过滤不出候选）。
  void _insertMention() {
    final controller = widget.controller;
    final text = controller.text;
    final sel = controller.selection;
    final cursor = sel.isValid
        ? sel.baseOffset.clamp(0, text.length)
        : text.length;
    final needsSpace =
        cursor > 0 && text[cursor - 1] != ' ' && text[cursor - 1] != '\n';
    final insert = needsSpace ? ' @' : '@';
    controller.value = TextEditingValue(
      text: text.replaceRange(cursor, cursor, insert),
      selection: TextSelection.collapsed(offset: cursor + insert.length),
    );
    widget.focusNode.requestFocus();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final items = _suggestions();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (items.isNotEmpty) _AutocompleteHints(items: items, onPick: _pick),
        _buildRow(context),
      ],
    );
  }

  Widget _buildRow(BuildContext context) {
    final t = context.t;
    final scheme = Theme.of(context).colorScheme;
    final hud = DesignPalette.of(context);
    final hasText = widget.controller.text.trim().isNotEmpty;
    final canInteract = widget.enabled && !widget.sending;
    // ★ 表情是**内置**的（1787 项），服务端有没有贴纸目录不该影响这个入口；
    //   上一版只在"有贴纸目录"时摆按钮 ⇒ 没有贴纸目录的服务器上用户一个表情
    //   都点不到（`DA278`）。
    final sendByEnter = ref.watch(sendByEnterProvider);

    return SafeArea(
      top: false,
      child: ScanSweep(
        // key 里带上发送计数：每发一条成功消息，进度条就"扫"一次
        key: ValueKey('send-sweep-${widget.sweepToken}'),
        strength: 0.35,
        duration: const Duration(milliseconds: 620),
        // ★ r493：输入区从"座舱仪表台"（上缘细高光 + 16 根刻度 + 1px 线）
        //   改成设计语言的一条输入栏：`surface2` 底 + 顶部 1px 描边。
        //   刻度是纯装饰，读数一条信息都不承载，留着只会与新的行卡打架。
        child: GlassPane(
          shape: const RoundedRectangleBorder(),
          blur: 16,
          fill: hud.surface2,
          showEdge: true,
          padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, Gap.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: Gap.xs),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // 「+」：图片 / 文件 / 相机 / 投票 / 定时消息 —— 现在是一张
                  // 切角宫格面板（原来是三层弹窗菜单）
                  _ComposerIconButton(
                    icon: Icons.add,
                    tooltip: t.chatSendPhotoFile,
                    onPressed: canInteract ? widget.onAttach : null,
                  ),
                  _ComposerIconButton(
                    icon: Icons.emoji_emotions_outlined,
                    tooltip: t.chatStickersEmoji,
                    onPressed: canInteract ? widget.onSticker : null,
                  ),
                  // 「@」：直接弹既有 autocomplete 候选面板（@真人 / @channel / @here）
                  _ComposerIconButton(
                    icon: Icons.alternate_email,
                    tooltip: t.chatMentionButton,
                    onPressed: canInteract ? _insertMention : null,
                  ),
                  Expanded(
                    child: TextField(
                      controller: widget.controller,
                      focusNode: widget.focusNode,
                      enabled: widget.enabled,
                      minLines: 1,
                      // 「回车发送」（原版 `sendByEnter`，默认关）：开着时输入框变
                      // **单行** + IME 动作是"发送"，回车直接发（`ChannelFragment
                      // .setMessageViewProperty`：`IME_ACTION_SEND` + `setSingleLine`）
                      maxLines: sendByEnter ? 1 : 5,
                      textInputAction: sendByEnter
                          ? TextInputAction.send
                          : TextInputAction.newline,
                      onSubmitted: sendByEnter
                          ? (_) {
                              if (canInteract) widget.onSend();
                            }
                          : null,
                      onChanged: (_) => widget.onTyping(),
                      style: AppType.chatBody.copyWith(color: scheme.onSurface),
                      decoration: InputDecoration(
                        hintText: widget.enabled
                            ? t.chatMessageHint
                            : t.chatRealtimeNotReady,
                        isDense: true,
                        filled: true,
                        fillColor: scheme.surfaceContainerHighest.withValues(
                          alpha: 0.55,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: Gap.lg,
                          vertical: Gap.md,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(Radii.pane),
                          borderSide: BorderSide(color: hud.line),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(Radii.pane),
                          borderSide: BorderSide(color: hud.line),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(Radii.pane),
                          borderSide: BorderSide(
                            color: scheme.primary,
                            width: 1.4,
                          ),
                        ),
                        disabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(Radii.pane),
                          borderSide: BorderSide(
                            color: hud.line.withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
                  // 麦克风 ⇄ 发送 的形态切换球：
                  //   * 输入框空 → 麦克风（点一下进录音面板）
                  //   * 有文字 → 发送
                  // 想按住说话就长按麦克风（`_VoiceRecordSheet` 也是按住录）
                  MorphOrbButton(
                    morph: hasText,
                    icon: hasText ? Icons.send : Icons.mic_none,
                    busy: widget.sending,
                    size: 44,
                    tooltip: hasText
                        ? t.chatSend
                        : t.chatRecordVoice(kVoiceMaxSeconds),
                    onPressed: !canInteract
                        ? null
                        : hasText
                        ? widget.onSend
                        : widget.onRecord,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 视频上传用的 MIME（`image_picker` 在部分 Android 机型上不回 `mimeType`，
/// 落回 `mimeForExtension` 的话会变成 `application/octet-stream`，
/// 服务端 `file_props.type` 只认扩展名不影响渲染，但播放器拿 MIME 分流时
/// 更愿意看到 `video/*`）。
String _videoMimeForExtension(String ext) {
  switch (ext.toLowerCase()) {
    case 'mp4':
    case 'm4v':
      return 'video/mp4';
    case 'mov':
      return 'video/quicktime';
    case 'webm':
      return 'video/webm';
    case 'mkv':
      return 'video/x-matroska';
    case 'avi':
      return 'video/x-msvideo';
    case '3gp':
      return 'video/3gpp';
    default:
      return mimeForExtension(ext.toLowerCase());
  }
}

/// 宫格面板里的一格（切角玻璃方块 + 遥测标签）
class _AttachTile extends StatelessWidget {
  const _AttachTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 只标 button，不再重复给 label（会把内部 Text 的文案拼两遍）
    return Semantics(
      button: true,
      child: SizedBox(
        width: 72,
        child: InkWell(
          onTap: () {
            HapticFeedbackCompat.light();
            onTap();
          },
          borderRadius: BorderRadius.circular(Radii.embed),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.sm),
            child: Column(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  // ★ r493：快捷动作块从"双角切角"改成设计语言的圆角块
                  //   （与行首图标块同一族：圆角 13 / 主色淡底 / 1px 描边）。
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(
                      color: scheme.primary.withValues(alpha: 0.5),
                    ),
                    color: scheme.primary.withValues(alpha: 0.10),
                  ),
                  child: Icon(icon, size: 24, color: scheme.primary),
                ),
                const SizedBox(height: Gap.sm),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: DesignType.labelSmallSize),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 输入区的小圆角图标按钮（统一 40dp 热区 + 玻璃描边）
class _ComposerIconButton extends StatelessWidget {
  const _ComposerIconButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: 42,
              height: 44,
              child: Icon(
                icon,
                size: 22,
                color: onPressed == null
                    ? scheme.onSurfaceVariant.withValues(alpha: 0.4)
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 输入联想提示条（`@` 用户 / `#` 标签 / `/` 斜杠命令，出现在输入框上方）
///
/// 对位原版 `AutocompleteAdapter`：同一个列表里混排三类候选
/// （`#标签` / `username (nickname)` / `/命令`）。
class _AutocompleteHints extends StatelessWidget {
  const _AutocompleteHints({required this.items, required this.onPick});

  final List<AutocompleteItem> items;
  final void Function(AutocompleteItem item) onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 用 Material 而不是带背景色的 Container：ListTile 的水波纹画在最近的
    // Material 上，套 DecoratedBox 会被盖住（Flutter 会直接断言报错）
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 180),
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final item in items)
              DesignRowTile(
                dense: true,
                leading: Icon(_iconOf(item), size: 18),
                title: Text(_titleOf(item)),
                subtitle: _subtitleOf(context, item),
                onTap: () => onPick(item),
              ),
          ],
        ),
      ),
    );
  }

  static IconData _iconOf(AutocompleteItem item) => switch (item) {
    MentionTarget() => Icons.alternate_email,
    HashtagTarget() => Icons.tag,
    SlashTarget() => Icons.terminal,
  };

  static String _titleOf(AutocompleteItem item) => switch (item) {
    final MentionTarget m => m.label,
    final HashtagTarget h => h.label,
    final SlashTarget s => s.label,
  };

  static Widget? _subtitleOf(BuildContext context, AutocompleteItem item) =>
      switch (item) {
        final MentionTarget m =>
          m.description.isEmpty ? null : Text(m.descriptionIn(context.t)),
        final SlashTarget s =>
          s.bot.slashDescription.isEmpty
              ? null
              : Text(
                  _SlashHintText.describe(
                    s.bot.slashDescription,
                    text: context.t,
                  ),
                ),
        _ => null,
      };
}

/// 斜杠命令描述文案（`webhook_builtin:desc_conference_jitsi` 这种服务端 i18n key）
abstract final class _SlashHintText {
  static String describe(String raw, {AppText? text}) {
    final t = text ?? currentText();
    return switch (raw) {
      'webhook_builtin:desc_conference_jitsi' => t.chatSlashJitsiDesc,
      'webhook_builtin:desc_conference_jumpchat' => t.chatSlashJumpchatDesc,
      _ => raw,
    };
  }
}

/// 定时消息对话框的返回值
class _ScheduleDraft {
  const _ScheduleDraft(this.message, this.sendAt);

  final String message;
  final int sendAt;

  String describe() =>
      DateTime.fromMillisecondsSinceEpoch(sendAt).toString().substring(0, 16);
}

class _ScheduleDialog extends StatefulWidget {
  const _ScheduleDialog();

  @override
  State<_ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends State<_ScheduleDialog> {
  final _message = TextEditingController();
  DateTime _at = DateTime.now().add(const Duration(hours: 1));

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _at,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_at),
    );
    if (t == null) return;
    setState(() => _at = DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.t.chatScheduledTitle),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _message,
          autofocus: true,
          maxLines: 3,
          decoration: InputDecoration(
            labelText: context.t.chatContent,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _pick,
          icon: const Icon(Icons.schedule, size: 18),
          label: Text(
            context.t.chatScheduledSendAt(_at.toString().substring(0, 16)),
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(context.t.actionCancel),
      ),
      FilledButton(
        onPressed: _message.text.trim().isEmpty
            ? null
            : () => Navigator.of(context).pop(
                _ScheduleDraft(
                  _message.text.trim(),
                  _at.millisecondsSinceEpoch,
                ),
              ),
        child: Text(context.t.actionOk),
      ),
    ],
  );
}

/// 新消息"材料化"进场：淡入 + 轻微上浮（有限动画）。
///
/// 只在 `play` 为真的条目上播一次 —— 也就是"进频道之后才到的消息"。
/// 用 `isNew` 而不是"每次构建都播"，是为了让翻历史、滚动重建这些场景完全静止
/// （也就不会在测试里引入不确定的中间帧）。
class _MaterializeIn extends StatefulWidget {
  const _MaterializeIn({required this.child, required this.play});

  final Widget child;
  final bool play;

  @override
  State<_MaterializeIn> createState() => _MaterializeInState();
}

class _MaterializeInState extends State<_MaterializeIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.base,
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _c,
    curve: Motion.out,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.08),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _c, curve: Motion.out));

  @override
  void initState() {
    super.initState();
    if (widget.play && Motion.enabled) {
      _c.forward();
    } else {
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_c.value == 1 && !_c.isAnimating) return widget.child;
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}
