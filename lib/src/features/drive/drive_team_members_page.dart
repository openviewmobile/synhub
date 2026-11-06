// Drive 团队文件夹成员页（C1）。
//
// 协议事实（原文见 [DriveApi] 与文档实施记录）：
//   * 团队文件夹列表 `TeamFolders/list` v1（既有实现，`driveTeamProvider`）；
//   * 成员 `TeamFolders/list_members` v1，参数
//     `{team_id, offset, limit}`（官方成员 store 的 baseParams，
//     `drive/synodrive_common.js:225431`），读字段
//     `display_name` / `name` / `uid` / `role`（同处）。
//
// 普通用户在 `TeamFolders/list` 上可能拿到**空表**（真机 2026-09-18 实测
// `{items:[],total:0}`），那种情况下这里就是一个诚实的空态，不是错误。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../../data/dto/drive_team_member_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../files/drive_providers.dart';
import 'drive_c1_text.dart';

/// 先选团队文件夹
class DriveTeamMembersPage extends ConsumerWidget {
  const DriveTeamMembersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final async = ref.watch(driveTeamProvider(''));
    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            key: const Key('drive-team-members-page'),
            children: [
              _Header(
                title: driveC1(DriveC1TextKeys.teamMembers, '团队成员'),
                onRefresh: () => ref.invalidate(driveTeamProvider('')),
              ),
              Expanded(
                child: async.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => AppEmptyState(
                    icon: Icons.error_outline,
                    title: t.driveListOpenFailed,
                    message: describeFileError(e),
                    actionLabel: t.photoRetry,
                    onAction: () => ref.invalidate(driveTeamProvider('')),
                  ),
                  data: (data) => data.items.isEmpty
                      ? AppEmptyState(
                          icon: Icons.groups_outlined,
                          title: t.driveNoTeamTitle,
                          message: t.driveNoTeamMessage,
                        )
                      : Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: Gap.md,
                                vertical: Gap.xs,
                              ),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  driveC1(
                                    DriveC1TextKeys.teamMembersPick,
                                    '选一个团队文件夹查看成员',
                                  ),
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: hud.dim),
                                ),
                              ),
                            ),
                            Expanded(
                              child: ListView.separated(
                                padding: const EdgeInsets.only(bottom: Gap.xl),
                                itemCount: data.items.length,
                                separatorBuilder: (_, _) => Divider(
                                  height: 1,
                                  color: hud.dim.withValues(alpha: 0.12),
                                ),
                                itemBuilder: (context, i) =>
                                    _TeamFolderRow(entry: data.items[i]),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
    );
  }
}

class _TeamFolderRow extends StatelessWidget {
  const _TeamFolderRow({required this.entry});

  final DriveEntryDto entry;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Material(
      type: MaterialType.transparency,
      child: DesignRowTile(
        key: Key('drive-team-folder-${entry.fileId}'),
        leading: Icon(Icons.folder_outlined, color: hud.dim),
        title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Icon(Icons.chevron_right, color: hud.dim),
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => DriveTeamMemberListPage(
              teamId: entry.fileId,
              teamName: entry.name,
            ),
          ),
        ),
      ),
    );
  }
}

/// 某个团队文件夹的成员列表
class DriveTeamMemberListPage extends ConsumerWidget {
  const DriveTeamMemberListPage({
    super.key,
    required this.teamId,
    required this.teamName,
  });

  final String teamId;
  final String teamName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final async = ref.watch(driveTeamMembersProvider(teamId));
    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            key: const Key('drive-team-member-list'),
            children: [
              _Header(
                title: teamName,
                onRefresh: () =>
                    ref.invalidate(driveTeamMembersProvider(teamId)),
              ),
              Expanded(
                child: async.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => AppEmptyState(
                    icon: Icons.error_outline,
                    title: t.driveListOpenFailed,
                    message: describeFileError(e),
                    actionLabel: t.photoRetry,
                    onAction: () =>
                        ref.invalidate(driveTeamMembersProvider(teamId)),
                  ),
                  data: (members) => members.isEmpty
                      ? AppEmptyState(
                          icon: Icons.person_outline,
                          title: driveC1(
                            DriveC1TextKeys.teamMembersEmpty,
                            '看不到成员',
                          ),
                          message: t.driveNoTeamMessage,
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: Gap.xl),
                          itemCount: members.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            color: hud.dim.withValues(alpha: 0.12),
                          ),
                          itemBuilder: (context, i) =>
                              _MemberRow(member: members[i]),
                        ),
                ),
              ),
            ],
          ),
        ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.member});

  final DriveTeamMemberDto member;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Material(
      type: MaterialType.transparency,
      child: DesignRowTile(
        key: Key('drive-team-member-${member.name}'),
        leading: Icon(Icons.person_outline, color: hud.dim),
        title: Text(member.label, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            if (member.name.isNotEmpty && member.name != member.label)
              member.name,
            if (member.role.isNotEmpty) member.role,
          ].join(' · '),
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: hud.dim),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.onRefresh});

  final String title;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: t.calBack,
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          IconButton(
            tooltip: t.photoRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }
}
