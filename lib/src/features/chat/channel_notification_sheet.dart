// Phase 9：频道通知档位（原版 `ChannelSettingFragment.onNotificationClicked` + `Channel.Preference`）。
//
// 档位取值与原版一致（`Common.java:142-146`）：
//   all / mention_subscribe / mention / none，外加服务端可能返回的 `by_admin_console`
//   （= 跟随全局默认，展示时替换成本地默认档位）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../data/chat_api.dart';
import '../../data/dto/channel_dto.dart';
import '../chat/chat_session_controller.dart';

/// 弹「通知设置」底部面板
Future<void> showChannelNotificationSheet(
  BuildContext context,
  WidgetRef ref,
  ChannelDto channel,
) {
  return showModalBottomSheet<void>(
    context: context,
    // ★★★ r332：**必须放开 9/16 的高度上限**。默认 `showModalBottomSheet` 把弹层限制在屏高
    // 的 9/16，而这张面板是"标题 + N 个 `RadioListTile`"的**不可滚动 Column**
    // ⇒ 换了真实产品主题后（`ListTile` 更高）在 800x600 下当场
    // `A RenderFlex overflowed by 7.5 pixels on the bottom`（黄黑条 = 用户可见缺陷）。
    // 同一个面板在"横向/小窗/大字号"下都会撞到这条上限 —— 放开限制 + 内容可滚动（见下面的 Flexible）。
    isScrollControlled: true,
    builder: (_) => _ChannelNotificationSheet(channel: channel),
  );
}

/// 档位 → 中文说明（跟原版 `notification_*` 文案对应）
String channelNotificationLabel(String value, [AppText? text]) {
  final t = text ?? currentText();
  return switch (value) {
    ChatApi.notificationAll => t.chatNotificationAll,
    ChatApi.notificationMentionSubscribe => t.chatNotificationMentionSubscribe,
    ChatApi.notificationMention => t.chatNotificationMention,
    ChatApi.notificationNone => t.chatNotificationNone,
    _ => t.chatNotificationAll,
  };
}

class _ChannelNotificationSheet extends ConsumerStatefulWidget {
  const _ChannelNotificationSheet({required this.channel});

  final ChannelDto channel;

  @override
  ConsumerState<_ChannelNotificationSheet> createState() =>
      _ChannelNotificationSheetState();
}

class _ChannelNotificationSheetState
    extends ConsumerState<_ChannelNotificationSheet> {
  String? _current;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final value = await ref
        .read(chatSessionControllerProvider.notifier)
        .loadChannelNotification(widget.channel.channelId);
    if (!mounted) return;
    setState(() {
      // `by_admin_console`（跟随全局默认）在 UI 上按"全部消息"展示，
      // 用户不改就保持服务端的原值（跟原版 `hasMentionMe()` 的替换逻辑一致）
      _current = value == ChatApi.notificationByAdminConsole || value.isEmpty
          ? ChatApi.notificationAll
          : value;
    });
  }

  Future<void> _pick(String value) async {
    if (_busy) return;
    final t = context.t;
    setState(() => _busy = true);
    final ok = await ref
        .read(chatSessionControllerProvider.notifier)
        .setChannelNotification(widget.channel.channelId, value);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t.chatNotificationChanged(channelNotificationLabel(value, t)),
          ),
        ),
      );
    } else {
      setState(() => _busy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.chatNotificationSaveFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final options = ChatApi.notificationOptionsFor(widget.channel);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DesignRowTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: Text(t.chatNotificationTitle),
            subtitle: Text(widget.channel.name),
          ),
          const Divider(height: 1),
          if (_current == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            // ★ r332：条目放 `Flexible` + `ListView(shrinkWrap: true)` —— 少的时候"贴着内容"、
            //   多的时候（更多档位 / 大字号 / 窄高窗口）**可以滚**，不会再撑爆 Column。
            Flexible(
              child: RadioGroup<String>(
                groupValue: _current,
                onChanged: (v) {
                  if (v != null) _pick(v);
                },
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    for (final value in options)
                      RadioListTile<String>(
                        value: value,
                        title: Text(channelNotificationLabel(value, t)),
                        enabled: !_busy,
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
