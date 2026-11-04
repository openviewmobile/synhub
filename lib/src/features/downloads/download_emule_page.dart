// ⑥下载 F1：**eMule 任务页**（对齐官方安卓端的 `EmuleListFragment`）。
//
// * 上半：eMule **上传**列表 —— `Task.eMule / list_upload` v1。该 API 的
//   `allowUser` 不含普通用户 ⇒ **管理员专属**，只放在 `AdminOnly` 子树里
//   （新规 R2/R3：非管理员隐藏，不是提示"无权限"）。
// * 下半：eMule **下载**任务 —— `Task / list` v2 带 `type:["emule"]`
//   （官方 aMule 面板逐字，不带 `type_inverse`）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/hud_widgets.dart';
import '../../data/dto/download_task_dto.dart';
import '../admin/admin_gate.dart';
import 'download_detail_page.dart';
import 'download_labels.dart';
import 'download_emule_providers.dart';
import 'download_emule_search_page.dart';
import 'download_emule_server_page.dart';
import 'download_emule_search_providers.dart';

class DownloadEmulePage extends ConsumerWidget {
  const DownloadEmulePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final s = ref.watch(emuleTasksProvider);
    return DesignScaffold(
      appBar: AppBar(
        title: Text(dataText('dsEmuleTitle', 'eMule')),
        leading: IconButton(
          key: const Key('ds-emule-back'),
          tooltip: dataText('dsBack', '返回'),
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context, rootNavigator: true).maybePop(),
        ),
        actions: [
          // F2：eMule 服务器/Kad 管理 —— **管理员专属**（新规 R2：非管理员
          // 连入口都不出现，不是提示无权限）。
          if (adminOnlyVisible(ref))
            IconButton(
              key: const Key('ds-emule-servers-open'),
              tooltip: dataText('dsEmuleServers', 'eMule 服务器'),
              icon: const Icon(Icons.dns_outlined),
              onPressed: () => Navigator.of(context, rootNavigator: true)
                  .push<void>(
                    MaterialPageRoute(
                      builder: (_) => const DownloadEmuleServerPage(),
                    ),
                  ),
            ),
          // F3：eMule 搜索入口 —— 能力表里有 `eMule.Search` 才出现。
          if (ref.watch(emuleSearchAvailableProvider))
            IconButton(
              key: const Key('ds-emule-search-open'),
              tooltip: dataText('dsEmuleSearch', 'eMule 搜索'),
              icon: const Icon(Icons.search),
              onPressed: () => Navigator.of(context, rootNavigator: true)
                  .push<void>(
                    MaterialPageRoute(
                      builder: (_) => const DownloadEmuleSearchPage(),
                    ),
                  ),
            ),
          IconButton(
            key: const Key('ds-emule-refresh'),
            tooltip: t.photoRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.read(emuleTasksProvider.notifier).load();
              ref.invalidate(emuleUploadsProvider);
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(emuleTasksProvider.notifier).load(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            // 管理员专属：eMule 上传列表（非管理员整段不出现）
            const AdminOnly(child: _UploadSection()),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
              child: Text(
                dataText('dsEmuleDownloads', 'eMule 下载任务'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (s.loading)
              const Padding(
                padding: EdgeInsets.all(Gap.lg),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (!s.loading && s.errorText != null)
              Padding(
                padding: const EdgeInsets.all(Gap.lg),
                child: Text(s.errorText!, key: const Key('ds-emule-error')),
              ),
            if (!s.loading && s.errorText == null && s.items.isEmpty)
              Padding(
                padding: const EdgeInsets.all(Gap.lg),
                child: Text(
                  dataText('dsEmuleEmpty', '没有 eMule 任务。'),
                  key: const Key('ds-emule-empty'),
                ),
              ),
            for (final task in s.items) _EmuleTaskTile(task: task),
            if (s.hasMore && !s.loading)
              Center(
                child: TextButton(
                  key: const Key('ds-emule-more'),
                  onPressed: () =>
                      ref.read(emuleTasksProvider.notifier).loadMore(),
                  child: Text(dataText('dsLoadMore', '加载更多')),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmuleTaskTile extends ConsumerWidget {
  const _EmuleTaskTile({required this.task});

  final DownloadTaskDto task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ★★ DA63（r408 真机）：eMule 行以前**只有体积**（真机逐字 `1.0 MB`），
    //   状态一个字都不显示 —— 任务卡在"等待中/错误"时用户看不出为什么不动。
    //   同页的主队列行**有**状态签（`download_page.dart` 的 `TelemetryLabel`），
    //   这里照抄同一套判据（颜色也一致），不再另立一套。
    final meta = dsTaskMetaLine(task);
    final theme = Theme.of(context);
    final statusColor = task.isError
        ? theme.colorScheme.error
        : task.isFinished
        ? theme.colorScheme.primary
        : DesignPalette.of(context).dim;
    return DesignRowTile(
      key: Key('ds-emule-task-${task.id}'),
      title: Text(task.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TelemetryLabel(
            dsStatusLabel(context.t, task.status),
            size: 11,
            color: statusColor,
          ),
          if (meta.isNotEmpty)
            Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
      onTap: () => Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute(builder: (_) => DownloadDetailPage(taskId: task.id)),
      ),
      trailing: PopupMenuButton<String>(
        key: Key('ds-emule-menu-${task.id}'),
        onSelected: (v) {
          final n = ref.read(emuleTasksProvider.notifier);
          if (v == 'pause') n.pause([task.id]);
          if (v == 'resume') n.resume([task.id]);
          if (v == 'delete') n.delete([task.id]);
        },
        itemBuilder: (_) => [
          if (!task.isFinished)
            PopupMenuItem(
              value: 'pause',
              child: Text(dataText('dsPause', '暂停')),
            ),
          PopupMenuItem(
            value: 'resume',
            child: Text(dataText('dsResume', '继续')),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Text(dataText('dsDelete', '删除')),
          ),
        ],
      ),
    );
  }
}

/// eMule 上传列表（**管理员**）。取不到就显示中性空态，不抛错。
class _UploadSection extends ConsumerWidget {
  const _UploadSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uploads = ref.watch(emuleUploadsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
          child: Text(
            dataText('dsEmuleUploads', 'eMule 上传'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        uploads.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(horizontal: Gap.lg),
            child: LinearProgressIndicator(),
          ),
          error: (_, __) => const SizedBox.shrink(),
          data: (list) => list.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
                  child: Text(
                    dataText('dsEmuleUploadsEmpty', '当前没有上传。'),
                    key: const Key('ds-emule-uploads-empty'),
                  ),
                )
              : Column(
                  children: [
                    for (var i = 0; i < list.length; i++)
                      DesignRowTile(
                        key: Key('ds-emule-upload-$i'),
                        dense: true,
                        title: Text(
                          list[i].fileName.isEmpty
                              ? dataText('dsEmuleUnnamed', '（未命名文件）')
                              : list[i].fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${list[i].clientName} · '
                          '${dsHumanBytes(list[i].sizeUploaded)}',
                          maxLines: 1,
                        ),
                        trailing: Text(
                          dsHumanRate(list[i].uploadSpeed),
                        ),
                      ),
                  ],
                ),
        ),
        const Divider(),
      ],
    );
  }
}
