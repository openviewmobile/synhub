// 「可加入的公开频道」完整浏览页（收尾遗留 3）。
//
// 审计原文（`docs/chat-p0-implementation.md:134-140,305-306`）登记：
// P0-4 为了让 `channel_join` / `channel_public` 有真实可门控的落点，只补了一个
// **最小**的「加入公开频道」底部弹层；官方（`NamedChannelFragment` +
// `NamedAdapter`）是一个**独立列表页**，本页把它补齐。
//
// 官方证据（E2，`/tmp/chat_audit_src` 反编译）：
//   * `NamedChannelFragment.java:165`：`showPublic(hasPrivilege(ACL_CHANNEL_JOIN)
//     && hasPrivilege(ACL_CHANNEL_PUBLIC))` —— 两个权限**都**有才列公开频道；
//   * `NamedChannelPresenter.java:66` → `AccountManager.java:602`
//     `fetchChannels("")`：`SYNO.Chat.Channel / list`，参数只有 `is_joined`；
//   * `NamedAdapter.java:71-105`：客户端按 `type == "public"` 与关键字过滤；
//     行文案 `String.format("%s (%d)", displayName, totalMemberCount)`；
//   * `NamedAdapter.java:119-127`：`isJoined()` → 选中进入，否则 `onJoinNamed`。
//
// 边界（如实登记，不做假）：
//   * **没有分页**：`Channel/list` 官方与我们都只带 `is_joined`，服务端一次回全量，
//     没有 `offset` / `limit`（官方也没有）——所以这里是"一次拉全量 + 客户端关键字
//     过滤"，不是"假分页"。
//   * 本页只**浏览 + 加入**（加入用既有 `Channel.Named/join`），不新增任何写 API。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/router/app_routes.dart';
import '../../core/settings/acl.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/channel_dto.dart';
import 'chat_session_controller.dart';

/// 可加入的公开频道列表（`Channel/list is_joined=false` → 客户端只留 public 未加入）。
///
/// `FutureProvider` 让"重试"就是一个 `ref.invalidate`，不用自己维护 loading 状态机。
final availableChannelsProvider = FutureProvider<List<ChannelDto>>((ref) async {
  final api = ref.watch(chatApiProvider);
  if (api == null) throw StateError('chat not connected');
  final list = await api.listChannels(isJoined: 'false');
  return list
      .where((c) => c.type == 'public' && !c.isJoined)
      .toList(growable: false);
  // 与 `office_viewer_page` / `photo_c2_sections` 同款：**失败就停在错误态**，
  // 交给用户点「重试」，不要 Riverpod 3 的自动重试把错误态盖掉。
}, retry: (_, _) => null);

/// 公开频道浏览页。
class AvailableChannelsPage extends ConsumerStatefulWidget {
  const AvailableChannelsPage({super.key});

  @override
  ConsumerState<AvailableChannelsPage> createState() =>
      _AvailableChannelsPageState();
}

class _AvailableChannelsPageState extends ConsumerState<AvailableChannelsPage> {
  final _filter = TextEditingController();

  /// 正在加入的频道 id（防重复点击；加入是写操作，不能连点）
  int? _joining;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final acl = ref.watch(myAclProvider);
    // 门控：`channel_join` 且 `channel_public`（fail-open，与官方 `showPublic` 一致）。
    // 入口本身已隐藏，这里再兜一层，避免深链/异常路径绕过。
    if (!allowsPublicChannels((n) => acl[n] ?? true)) {
      return Scaffold(
        appBar: AppBar(title: Text(dataText('chatAvailableChannelsTitle', '公开频道'))),
        body: AppEmptyState(
          key: const Key('chat-public-no-privilege'),
          icon: Icons.lock_outline,
          title: dataText('chatAvailableChannelsNoPrivilege', '没有查看公开频道的权限'),
        ),
      );
    }
    final async = ref.watch(availableChannelsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(dataText('chatAvailableChannelsTitle', '公开频道')),
      ),
      body: apiMissing
          ? AppEmptyState(
              key: const Key('chat-public-not-connected'),
              icon: Icons.cloud_off,
              title: t.setNotConnected,
            )
          : async.when(
              loading: () => const AppListSkeleton(rows: 5),
              error: (e, _) => AppErrorView(
                key: const Key('chat-public-error'),
                title: dataText(
                  'chatAvailableChannelsLoadFailed',
                  '公开频道加载失败',
                ),
                detail: dataText(
                  'chatAvailableChannelsLoadFailedDetail',
                  '请检查网络后重试',
                ),
                onRetry: () => ref.invalidate(availableChannelsProvider),
              ),
              data: (channels) {
                if (channels.isEmpty) {
                  return AppEmptyState(
                    key: const Key('chat-public-empty'),
                    icon: Icons.group_add_outlined,
                    title: dataText(
                      'chatJoinPublicEmpty',
                      '没有可以加入的公开频道。',
                    ),
                  );
                }
                final keyword = _filter.text.trim().toLowerCase();
                final visible = keyword.isEmpty
                    ? channels
                    : channels
                          .where(
                            (c) =>
                                channelDisplayName(c).toLowerCase().contains(
                                  keyword,
                                ),
                          )
                          .toList(growable: false);
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Gap.lg,
                        Gap.sm,
                        Gap.lg,
                        Gap.xs,
                      ),
                      child: TextField(
                        key: const Key('chat-public-filter'),
                        controller: _filter,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search, size: 18),
                          hintText: dataText(
                            'chatAvailableChannelsSearch',
                            '搜索频道名',
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: visible.isEmpty
                          ? AppEmptyState(
                              key: const Key('chat-public-no-match'),
                              icon: Icons.search_off,
                              title: dataText(
                                'chatAvailableChannelsNoMatch',
                                '没有匹配的频道',
                              ),
                            )
                          : ListView.separated(
                              key: const Key('chat-public-list'),
                              itemCount: visible.length,
                              separatorBuilder: (_, _) => const Divider(
                                height: 1,
                              ),
                              itemBuilder: (context, i) =>
                                  _channelTile(visible[i]),
                            ),
                    ),
                  ],
                );
              },
            ),
    );
  }

  bool get apiMissing => ref.watch(chatApiProvider) == null;

  Widget _channelTile(ChannelDto c) {
    final purpose = c.purpose.trim();
    final members = dataText(
      'chatAvailableChannelsMembers',
      '{count} 名成员',
    ).replaceAll('{count}', '${c.totalMemberCount}');
    final joining = _joining == c.channelId;
    return DesignRowTile(
      key: Key('chat-public-${c.channelId}'),
      leading: const Icon(Icons.tag),
      title: Text(
        channelDisplayName(c),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        purpose.isEmpty ? members : '$purpose · $members',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: joining
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              key: Key('chat-public-join-${c.channelId}'),
              onPressed: () => _join(c),
              child: Text(dataText('chatAvailableChannelsJoin', '加入')),
            ),
      onTap: joining ? null : () => _join(c),
    );
  }

  Future<void> _join(ChannelDto c) async {
    final api = ref.read(chatApiProvider);
    if (api == null || _joining != null) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final router = GoRouter.maybeOf(context);
    setState(() => _joining = c.channelId);
    try {
      await api.joinNamedChannel(c.channelId);
    } catch (_) {
      if (!mounted) return;
      setState(() => _joining = null);
      messenger.showSnackBar(
        SnackBar(
          content: Text(dataText('chatJoinPublicFailed', '加入频道失败，请稍后再试。')),
        ),
      );
      return;
    }
    await ref.read(chatSessionControllerProvider.notifier).refresh();
    if (!mounted) return;
    // 列表已变（这条不再是"未加入"）→ 回列表页并进频道
    navigator.pop();
    router?.push(AppRoutes.chatOf(c.channelId));
  }
}

/// 频道展示名：没名字退回 `#id`（官方 `Channel.displayName()` 的等价回落）。
String channelDisplayName(ChannelDto c) =>
    c.name.isEmpty ? '#${c.channelId}' : c.name;
