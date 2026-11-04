// Drive「扩展」页（C1）：把回收站 / 请求文件 / 通知 / 团队文件夹成员四个
// **不依赖具体文件**的入口集中在一处。
//
// 为什么单独一页而不是塞进「更多」的 chip：`DriveMoreSection` 的五个 chip
// 是"浏览视图"，而这四个是**操作型**入口；分开后能力位降级也更干净——
// 每个入口只在自己那个可选 API 缺失时消失（`partial`），**绝不隐藏 Drive**。
//
// 逐文件的两个能力（高级共享、文件锁）在文件列表行菜单里，见
// `drive_browse_view.dart` 的 `_DriveRow`：同样按能力位隐藏菜单项。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/drive_api.dart' show kDriveRoot;
import '../admin/admin_gate.dart';
import 'drive_admin_page.dart';
import 'drive_c1_text.dart';
import 'drive_collection_page.dart';
import 'drive_collection_text.dart';
import 'drive_computers_page.dart';
import 'drive_connections_page.dart';
import 'drive_file_request_page.dart';
import 'drive_g4_text.dart';
import 'drive_g6_providers.dart';
import 'drive_g6_text.dart';
import 'drive_local_files_page.dart';
import 'drive_notifications_page.dart';
import 'drive_quota_page.dart';
import 'drive_recycle_text.dart';
import 'drive_team_members_page.dart';
import 'drive_team_trash_page.dart';
import 'drive_trash_page.dart';
import 'drive_wave2_providers.dart';
import 'drive_wave2_text.dart';

Widget _buildDriveAdminPage(BuildContext context) => const DriveAdminPage();

class DriveExtrasPage extends ConsumerWidget {
  const DriveExtrasPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final availability = ref.watch(serviceAvailabilityProvider);
    bool has(String api) => availability.hasApi(StationService.drive, api);

    // 逐项能力位（缺失 → 该入口直接不出现；模块本身照常）
    final entries = <Widget>[
      if (has(kDriveTrashApi))
        _ExtraTile(
          key: const Key('drive-extras-trash'),
          icon: Icons.delete_outline,
          title: t.noteRecycle,
          subtitle: t.driveTrashEmptyMessage,
          builder: (_) => const DriveTrashPage(),
        ),
      if (has(kDriveFileRequestApi))
        _ExtraTile(
          key: const Key('drive-extras-file-requests'),
          icon: Icons.file_download_outlined,
          title: driveC1(DriveC1TextKeys.fileRequests, '请求文件'),
          subtitle: driveC1(
            DriveC1TextKeys.fileRequestsEntry,
            '管理你发出的"请求文件"链接：查看、关闭、重开、删除',
          ),
          builder: (_) => const DriveFileRequestPage(),
        ),
      if (has(kDriveNotificationsApi))
        _ExtraTile(
          key: const Key('drive-extras-notifications'),
          icon: Icons.notifications_none,
          title: driveC1(DriveC1TextKeys.notifications, '通知'),
          subtitle: driveC1(
            DriveC1TextKeys.notificationsEntry,
            'Drive 的上传/同步事件通知',
          ),
          builder: (_) => const DriveNotificationsPage(),
        ),
      if (has(kDriveTeamFoldersApi))
        _ExtraTile(
          key: const Key('drive-extras-team-members'),
          icon: Icons.groups_outlined,
          title: driveC1(DriveC1TextKeys.teamMembers, '团队成员'),
          subtitle: driveC1(
            DriveC1TextKeys.teamMembersEntry,
            '查看团队文件夹里有哪些成员、各自什么角色',
          ),
          builder: (_) => const DriveTeamMembersPage(),
        ),
      // ★ 新规 B1：Drive **管理员**页（`Settings/list` + `Config/get` +
      // `DBUsage/get` + `Privilege/list`，全部 v1、只读）。
      // 门控：`AdminOnly` —— 非管理员**完全看不见**（fail-closed）；
      // 接口一律走 Mock Server 核实（`test/drive_admin_mock_test.dart`）。
      AdminOnly(
        child: _ExtraTile(
          key: const Key('drive-extras-admin'),
          icon: Icons.admin_panel_settings_outlined,
          title: context.t.driveAdminEntryTitle,
          subtitle: context.t.driveAdminEntrySubtitle,
          builder: _buildDriveAdminPage,
        ),
      ),
      // wave2：配额 / 用量（`Info:quota` **v2**）。
      // 门控：缺失 / 105 / 160 → 隐藏；119 / 106 → 保留（失败时才提示）。
      if (driveQuotaAvailable(ref))
        _ExtraTile(
          key: const Key('drive-extras-quota'),
          icon: Icons.pie_chart_outline,
          title: driveWave2(DriveWave2TextKeys.quotaTitle, '存储空间'),
          subtitle: driveWave2(
            DriveWave2TextKeys.quotaEntry,
            '查看 Drive 的已用空间与配额',
          ),
          builder: (_) => const DriveQuotaPage(),
        ),
      // G4 / D21：计算机（`Files:list_backup_tasks` **v3**）。
      // 门控：`Files` 是 Drive 的必需 API；能力表明确缺才隐藏（fail-open）。
      if (driveFilesCapabilityAvailable(ref))
        _ExtraTile(
          key: const Key('drive-extras-computers'),
          icon: Icons.computer_outlined,
          title: driveG4(DriveG4TextKeys.computersTitle, '计算机'),
          subtitle: driveG4(
            DriveG4TextKeys.computersEntry,
            '查看哪些电脑 / 设备在用 Drive 客户端同步',
          ),
          builder: (_) => const DriveComputersPage(),
        ),
      // G4 / D22：本地文件（**纯客户端**；上传走既有 FileStation 通道）。
      // 不依赖任何可选 API → 永远显示；未连接由页面自己提示。
      _ExtraTile(
        key: const Key('drive-extras-local-files'),
        icon: Icons.folder_open_outlined,
        title: driveG4(DriveG4TextKeys.localFilesTitle, '本地文件'),
        subtitle: driveG4(
          DriveG4TextKeys.localFilesEntry,
          '浏览本机目录，把文件上传到 Drive',
        ),
        builder: (_) => const DriveLocalFilesPage(targetDrivePath: kDriveRoot),
      ),
      // G6：已连接的设备（`Connection:list`，**v2 优先回退 v1**）。
      // 门控：能力位缺失 → 只隐藏这一个入口（`partial`），Drive 模块照常。
      // ⚠️ 真机回空数据 ⇒ 页面必须画人话空态（见 DriveConnectionsPage）。
      if (has(kDriveConnectionApi))
        _ExtraTile(
          key: const Key('drive-extras-connections'),
          icon: Icons.devices_other_outlined,
          title: driveG6(DriveG6TextKeys.connectionsEntry, '已连接的设备'),
          subtitle: driveG6(
            DriveG6TextKeys.connectionsEntryHint,
            '查看哪些客户端 / 设备正连着这台 NAS 的 Drive',
          ),
          builder: (_) => const DriveConnectionsPage(),
        ),
      // D8：收藏集（`Labels/list` + `type=photo_album|document_folder|…`）。
      // 门控：`Labels` 能力位；缺失 → 只隐藏这一个入口（`partial`）。
      // 真机四个类型都回空表成功 ⇒ 页面必须画人话空态。
      if (driveCollectionsAvailable(ref))
        _ExtraTile(
          key: const Key('drive-extras-collections'),
          icon: Icons.collections_bookmark_outlined,
          title: driveCollection(DriveCollectionTextKeys.entry, '收藏集'),
          subtitle: driveCollection(
            DriveCollectionTextKeys.entryHint,
            '把散在不同目录的文件聚成照片 / 文档 / 音乐 / 视频四类收藏集',
          ),
          builder: (_) => const DriveCollectionPage(),
        ),
      // D12：团队文件夹回收站（`Trash/list` + `path=id:<团队文件夹 id>`）。
      // 门控：`TeamFolders` 能力位（没有团队文件夹就没有这个回收站）。
      // ⚠️ 该页只**读**列表；还原 / 彻底删除本批不真调（见页面注释）。
      if (has(kDriveTeamFoldersApi))
        _ExtraTile(
          key: const Key('drive-extras-team-trash'),
          icon: Icons.restore_from_trash_outlined,
          title: driveRecycle(DriveRecycleTextKeys.entry, '团队文件夹回收站'),
          subtitle: driveRecycle(
            DriveRecycleTextKeys.pickFolder,
            '选一个团队文件夹，查看并还原里面误删的文件',
          ),
          builder: (_) => const DriveTeamTrashPage(),
        ),
    ];

    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            key: const Key('drive-extras-page'),
            children: [
              Padding(
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
                        t.driveMoreTitle,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: Gap.xl),
                  children: entries,
                ),
              ),
            ],
          ),
        ),
    );
  }
}

class _ExtraTile extends StatelessWidget {
  const _ExtraTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.builder,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Material(
      type: MaterialType.transparency,
      child: DesignRowTile(
        leading: Icon(icon, color: hud.dim),
        title: Text(title),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: hud.dim),
        ),
        trailing: Icon(Icons.chevron_right, color: hud.dim),
        onTap: () => Navigator.of(
          context,
        ).push<void>(MaterialPageRoute<void>(builder: builder)),
      ),
    );
  }
}
