// Download Station「选择要下载的文件」页（消费 `Task.create create_list=true`
// 返回的 `list_id`）。
//
// 取证（NAS 上 DownloadStation 4.1.2-5012 的 `ui/download.js`，逐字）：
//   * 建任务 `Task.create {create_list:true}` 返回 `data.list_id`；
//   * 官方 `QueueAddFilePanel` 用 `Task.List.get {list_id}`（v2，root=`files`，
//     字段 `index`/`name`/`size`/`download_url`/`enable`）填网格；
//   * 确认时对每个 list_id 发 `Task.List.Polling.download`
//     `{list_id, destination, create_subfolder, selected:[index…]}`；
//   * 关闭窗口时 `Task.List.delete {list_id}` 清掉服务端临时清单。
//
// wave5 补充（`Task.List` v1–v2 的**降级路径**）：老 NAS 可能只有 `Task.List`
// 而没有 `Task.List.Polling`（`.lib` 的 `minVersion=2`）——那时改发
// `Task.List.download {list_id, destination}`（真机只读探针钉死这两个参数）。
// 清单过期/不存在时服务端回 **1910**，由 `describeDownloadError` 给
// "文件清单已过期，请重新添加这个任务"，**不是**"加载失败"。
//
// 这就是 P0 里"D-C2：`listId` 全仓无消费"的接线目标。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/download_station.dart';
import '../../data/dto/download_task_dto.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'download_providers.dart';

class DownloadFileSelectPage extends ConsumerStatefulWidget {
  const DownloadFileSelectPage({
    super.key,
    required this.listId,
    this.destination,
    this.extractPassword,
  });

  final String listId;
  final String? destination;
  final String? extractPassword;

  @override
  ConsumerState<DownloadFileSelectPage> createState() =>
      _DownloadFileSelectPageState();
}

class _DownloadFileSelectPageState
    extends ConsumerState<DownloadFileSelectPage> {
  /// 用户改过的勾选状态（`index` → 是否下载）。没改过的用服务端的 `enable`。
  final Map<int, bool> _enabled = {};
  bool _starting = false;
  bool _started = false;

  bool _isEnabled(DownloadCreateListFile f) => _enabled[f.index] ?? f.enable;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final list = ref.watch(downloadCreateListProvider(widget.listId));
    return PopScope(
      // 离开这一页（未开始下载）就清掉服务端临时清单，避免 list_id 泄漏。
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && !_started) _discard();
      },
      child: DesignScaffold(
        appBar: AppBar(
          title: Text(dataText('dsSelectFiles', '选择要下载的文件')),
        ),
        body: list.when(
          loading: () => const AppListSkeleton(rows: 6),
          error: (e, _) => AppErrorView(
            title: dataText('dsFileSelectFailed', '文件清单加载失败'),
            detail: describeDownloadError(e),
            onRetry: () =>
                ref.invalidate(downloadCreateListProvider(widget.listId)),
          ),
          data: (data) => data.files.isEmpty
              ? AppEmptyState(
                  icon: Icons.folder_off_outlined,
                  title: dataText('dsFileListEmpty', '这个种子没有文件清单'),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Gap.lg,
                        Gap.sm,
                        Gap.lg,
                        0,
                      ),
                      child: Text(
                        dataText('dsSelectFilesHint', '取消勾选不想下载的文件'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: DesignPalette.of(context).dim,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.only(bottom: Gap.lg),
                        itemCount: data.files.length,
                        itemBuilder: (context, i) {
                          final f = data.files[i];
                          return DesignCheckRow(
                            key: Key('ds-file-${f.index}'),
                            value: _isEnabled(f),
                            onChanged: _starting
                                ? null
                                : (v) => setState(() => _enabled[f.index] = v),
                            title: Text(
                              f.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(dsHumanBytes(f.size)),
                          );
                        },
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.all(Gap.lg),
                        child: Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                key: const Key('ds-file-cancel'),
                                onPressed: _starting
                                    ? null
                                    : () => Navigator.of(context).pop(false),
                                child: Text(t.actionCancel),
                              ),
                            ),
                            const SizedBox(width: Gap.md),
                            Expanded(
                              child: FilledButton(
                                key: const Key('ds-file-start'),
                                onPressed: _starting
                                    ? null
                                    : () => _start(data),
                                child: _starting
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : Text(
                                        dataText('dsStartDownload', '开始下载'),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Future<void> _start(DownloadCreateList data) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _starting = true);
    try {
      await ref
          .read(downloadActionsProvider)
          .startCreateList(
            listId: widget.listId,
            destination: widget.destination,
            selected: [
              for (final f in data.files)
                if (_isEnabled(f)) f.index,
            ],
            extractPassword: widget.extractPassword,
          );
      _started = true;
      trackOnce(UsageModule.downloads, UsageAction.create, objectType: 'file');
      messenger.showSnackBar(
        SnackBar(content: Text(dataText('dsFilesStarted', '已开始下载选中的文件'))),
      );
      navigator.pop(true);
    } catch (e) {
      trackOnceFailure(
        UsageModule.downloads,
        UsageAction.create,
        objectType: 'file',
        reason: 'start_list_failed',
        error: e,
      );
      if (mounted) setState(() => _starting = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(t.dsCreateFailed(describeDownloadError(e))),
        ),
      );
    }
  }

  void _discard() {
    unawaited(
      ref
          .read(downloadActionsProvider)
          .discardCreateList(widget.listId)
          .then((_) {}, onError: (Object _) {}),
    );
  }
}
