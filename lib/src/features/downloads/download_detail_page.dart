// Download Station 任务详情页：任务字段 + **单任务 BT 限速**（`Task.BT.get/set` v2）。
//
// 关键事实（`docs/stage2-audio-download-api.md` §3.3 A-2d）：
//   * **全局限速是 admin-only**（`Settings.BT.set` / `Settings.Global.set`），本 App 不做；
//   * **单任务** BT 限速/做种走 `SYNO.DownloadStation2.Task.BT.set`，`allowUser`
//     含 `normal.local` —— **普通用户可改**，所以只做这一处限速。
//   * 字段名逐字对齐官方 `_getBTSetFieldValues`：`max_upload_rate` /
//     `max_download_rate` / `seeding_ratio` / `max_peers` / `seeding_interval`
//     / `destination`；限速单位 **KB/s**，`0 = 不限`。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/hud_widgets.dart';
import '../../data/download_station.dart';
import '../../data/dto/download_task_dto.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'download_export.dart';
import 'download_labels.dart';
import 'download_providers.dart';

class DownloadDetailPage extends ConsumerWidget {
  const DownloadDetailPage({super.key, required this.taskId});

  final String taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final task = ref.watch(downloadTaskProvider(taskId));
    return DesignScaffold(
      appBar: AppBar(title: Text(t.dsDetail)),
      body: task.when(
        loading: () => const AppListSkeleton(rows: 5),
        error: (e, __) => AppErrorView(
          title: t.dsErrLoadDetail,
          detail: describeDownloadError(e),
          onRetry: () => ref.invalidate(downloadTaskProvider(taskId)),
        ),
        data: (row) => row == null
            ? AppEmptyState(icon: Icons.search_off, title: t.dsErrTaskNotFound)
            : RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(downloadTaskProvider(taskId));
                  ref.invalidate(downloadBtSettingsProvider(taskId));
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(
                    top: Gap.sm,
                    bottom: Gap.xxl * 2,
                  ),
                  children: [
                    _TaskSummary(task: row),
                    const SizedBox(height: Gap.md),
                    _FieldSection(task: row),
                    if (row.isError ||
                        row.isPaused ||
                        (row.isFinished && row.isBt)) ...[
                      const SizedBox(height: Gap.md),
                      _ForceCompleteAction(task: row),
                    ],
                    // 种子导出（F7，`Task.Source.download` v2）：只有 BT 任务
                    // 才有原始 `.torrent`（官方 InfoGeneral 也只在 `type==="bt"` 显示）。
                    if (row.isBt) ...[
                      const SizedBox(height: Gap.sm),
                      _ExportTorrentAction(task: row),
                    ],
                    if (row.isBt) ...[
                      const SizedBox(height: Gap.md),
                      _BtSection(taskId: taskId),
                      const SizedBox(height: Gap.md),
                      _FileSection(taskId: taskId),
                      const SizedBox(height: Gap.md),
                      _TrackerSection(taskId: taskId),
                      const SizedBox(height: Gap.md),
                      _PeerSection(taskId: taskId),
                    ],
                    // NZB 任务的**文件清单 + 日志**（F5/F6，v1）；非 NZB 不显示。
                    if (row.type == 'nzb') ...[
                      const SizedBox(height: Gap.md),
                      _NzbFilesSection(taskId: taskId),
                      const SizedBox(height: Gap.md),
                      _NzbLogSection(taskId: taskId),
                    ],
                  ],
                ),
              ),
      ),
    );
  }
}

class _TaskSummary extends StatelessWidget {
  const _TaskSummary({required this.task});

  final DownloadTaskDto task;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final scheme = Theme.of(context).colorScheme;
    final color = task.isError
        ? scheme.error
        : task.isFinished
        ? scheme.primary
        : DesignPalette.of(context).dim;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // BT 预览缩略图（F8）：取不到就回落状态图标，绝不空白。
          _PreviewThumb(task: task, color: color, size: 56),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(task.title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: Gap.sm),
                TelemetryLabel(dsStatusLabel(t, task.status), color: color),
                if (task.progress > 0 && !task.isFinished) ...[
                  const SizedBox(height: Gap.md),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: task.progress,
                      minHeight: 4,
                    ),
                  ),
                  const SizedBox(height: Gap.xs),
                  TelemetryLabel(
                    '${(task.progress * 100).toStringAsFixed(0)}%',
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 缩略图（F8，`Thumbnail.get`/`download` v2）—— **失败/为空回落到既有图标**。
///
/// 事实：`docs/download-api-live.md:32`（`get` v2，参数 `id`，本机 120 缺 id
/// 已确认参数名）+ NAS 包内官方 `ui/download.js` 的 `InfoPreview`。
/// 字节走 `getBytes`（带 `_sid` 的自签证书 Dio），不用 `Image.network`。
class _PreviewThumb extends ConsumerWidget {
  const _PreviewThumb({
    required this.task,
    required this.color,
    this.size = 40,
  });

  final DownloadTaskDto task;
  final Color color;
  final double size;

  IconData get _fallbackIcon => task.isError
      ? Icons.error_outline
      : task.isFinished
      ? Icons.check_circle_outline
      : task.isPaused
      ? Icons.pause_circle_outline
      : Icons.downloading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 只有 BT 任务可能有预览；其它类型连请求都不发。
    if (!task.isBt) return Icon(_fallbackIcon, color: color, size: size);
    final bytes = ref.watch(downloadThumbnailProvider(task.id)).value;
    if (bytes == null || bytes.isEmpty) {
      return Icon(_fallbackIcon, color: color, size: size);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.memory(
        bytes,
        key: Key('ds-thumb-${task.id}'),
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        // 解码失败也不留空白（回落到状态图标）。
        errorBuilder: (_, __, ___) =>
            Icon(_fallbackIcon, color: color, size: size),
      ),
    );
  }
}

class _FieldSection extends StatelessWidget {
  const _FieldSection({required this.task});

  final DownloadTaskDto task;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final rows = <(String, String)>[
      (t.dsStatusLabel, dsStatusLabel(t, task.status)),
      (t.dsType, dsTypeLabel(task.type)),
      (t.dsSize, dsHumanBytes(task.size)),
      (t.dsProgress, dsHumanBytes(task.transfer.sizeDownloaded)),
      (t.dsDownloadSpeed, dsHumanRate(task.transfer.speedDownload)),
      (t.dsUploadSpeed, dsHumanRate(task.transfer.speedUpload)),
      (t.dsEta, dsEtaText(task.etaSeconds)),
      (t.dsDestination, task.detail.destination),
      (t.dsCreator, task.username),
      if (task.detail.hash.isNotEmpty) (t.dsHash, task.detail.hash),
      if (task.detail.totalPeers > 0)
        (t.dsPeers, '${task.detail.connectedPeers}/${task.detail.totalPeers}'),
      if (task.detail.createdTime > 0)
        (t.dsAddedTime, _stamp(task.detail.createdTime)),
      if (task.detail.completedTime > 0)
        (t.dsCompletedTime, _stamp(task.detail.completedTime)),
      (t.dsTaskId, task.id),
    ];
    return _Panel(
      title: t.dsDetail,
      child: Column(
        children: [
          for (final (label, value) in rows)
            if (value.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 108,
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: DesignPalette.of(context).dim,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        value,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    // 目的地修改（B8，`Task.edit` v1–v2）：官方 `dl_edit` 对
                    // 已完成/完成中的任务是禁用的，这里同口径（只在这一行给入口，
                    // 不额外占一整行高度）。
                    if (label == t.dsDestination && !task.isFinished)
                      _DestinationEditButton(task: task),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  static String _stamp(int seconds) {
    if (seconds <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }
}

/// 目标文件夹输入对话框（B8 目的地修改 / B10 复制到… 共用）。
///
/// 返回用户输入的路径（已 trim）；取消/空输入返回 null。
///
/// 控制器由 [_DestinationDialog] 这个 StatefulWidget 自己持有并 dispose ——
/// **不能**在这里 `await showDialog(...)` 之后直接 dispose：弹窗退场动画期间
/// 仍会引用控制器（真机/测试都会报 "TextEditingController was used after being
/// disposed"）。
Future<String?> showDsDestinationDialog(
  BuildContext context, {
  required String title,
  required String initial,
  Key? fieldKey,
}) => showDialog<String>(
  context: context,
  builder: (_) =>
      _DestinationDialog(title: title, initial: initial, fieldKey: fieldKey),
);

class _DestinationDialog extends StatefulWidget {
  const _DestinationDialog({
    required this.title,
    required this.initial,
    this.fieldKey,
  });

  final String title;
  final String initial;
  final Key? fieldKey;

  @override
  State<_DestinationDialog> createState() => _DestinationDialogState();
}

class _DestinationDialogState extends State<_DestinationDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: widget.fieldKey ?? const Key('ds-dest-field'),
      controller: _controller,
      autofocus: true,
      decoration: InputDecoration(
        labelText: dataText('dsDestination', '目的地'),
        hintText: dataText('dsDestinationHint', '例如 /volume1/downloads'),
        border: const OutlineInputBorder(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(context.t.actionCancel),
      ),
      FilledButton(
        key: const Key('ds-dest-confirm'),
        onPressed: () {
          final v = _controller.text.trim();
          Navigator.of(context).pop(v.isEmpty ? null : v);
        },
        child: Text(context.t.actionSave),
      ),
    ],
  );
}

/// 目的地修改（B8，`Task.edit` v1–v2，normal）。
///
/// 官方 `DLM.EditTaskWindow.saveDestination`：`{id:[task_id], destination}`；
/// 对已完成/完成中任务是禁用的（见 `_FieldSection` 的显示条件）。
class _DestinationEditButton extends ConsumerStatefulWidget {
  const _DestinationEditButton({required this.task});

  final DownloadTaskDto task;

  @override
  ConsumerState<_DestinationEditButton> createState() =>
      _DestinationEditButtonState();
}

class _DestinationEditButtonState
    extends ConsumerState<_DestinationEditButton> {
  bool _busy = false;

  Future<void> _edit() async {
    final messenger = ScaffoldMessenger.of(context);
    final current = widget.task.detail.destination;
    final dest = await showDsDestinationDialog(
      context,
      title: dataText('dsEditDestination', '修改下载目的地'),
      initial: current,
      fieldKey: const Key('ds-edit-dest-field'),
    );
    if (dest == null) return;
    if (dest == current.trim()) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(downloadActionsProvider)
          .editDestination([widget.task.id], destination: dest);
      ref.invalidate(downloadTaskProvider(widget.task.id));
      messenger.showSnackBar(
        SnackBar(content: Text(dataText('dsDestinationSaved', '下载目的地已修改'))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            dataText(
              'dsDestinationSaveFailed',
              '修改失败：{msg}',
            ).replaceAll('{msg}', describeDownloadError(e)),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('ds-edit-destination'),
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    tooltip: dataText('dsEditDestination', '修改下载目的地'),
    icon: const Icon(Icons.edit_outlined, size: 16),
    onPressed: _busy ? null : _edit,
  );
}

/// NZB 文件清单（F6，`Task.NZB.File.list` v1，**只读**）。
///
/// 官方 store：root `items`、total `total`、字段 `name`/`size`、
/// `paramNames:{offset,limit}`。`404` 是中性态（不是 NZB 任务）。
class _NzbFilesSection extends ConsumerStatefulWidget {
  const _NzbFilesSection({required this.taskId});

  final String taskId;

  @override
  ConsumerState<_NzbFilesSection> createState() => _NzbFilesSectionState();
}

class _NzbFilesSectionState extends ConsumerState<_NzbFilesSection> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(downloadNzbFilesProvider(widget.taskId).notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final state = ref.watch(downloadNzbFilesProvider(widget.taskId));
    return _Panel(
      title: dataText('dsNzbFiles', 'NZB 文件列表'),
      child: state.loading && !state.loaded
          ? const Padding(
              padding: EdgeInsets.all(Gap.md),
              child: Center(child: CircularProgressIndicator()),
            )
          : state.unavailable
          ? Text(
              dataText('dsNzbUnavailable', '这个任务没有可用的 NZB 信息'),
              style: t.bodyMedium,
            )
          : state.errorText != null && state.items.isEmpty
          ? Text(state.errorText!, style: t.bodyMedium)
          : state.items.isEmpty
          ? Text(dataText('dsNzbFileEmpty', '没有 NZB 文件信息'), style: t.bodyMedium)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final f in state.items)
                  Padding(
                    key: Key('ds-nzb-file-${f.name}'),
                    padding: const EdgeInsets.symmetric(vertical: Gap.xxs),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            f.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: t.bodySmall,
                          ),
                        ),
                        const SizedBox(width: Gap.sm),
                        TelemetryLabel(dsHumanBytes(f.size), size: 11),
                      ],
                    ),
                  ),
                const SizedBox(height: Gap.sm),
                if (state.loadingMore)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(Gap.sm),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                else if (state.hasMore)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const Key('ds-nzb-files-more'),
                      onPressed: () => ref
                          .read(downloadNzbFilesProvider(widget.taskId).notifier)
                          .loadMore(),
                      child: Text(dataText('dsLoadMore', '加载更多')),
                    ),
                  )
                else
                  Text(
                    dataText(
                      'dsNzbFilesTotal',
                      '共 {n} 个文件',
                    ).replaceAll('{n}', '${state.items.length}'),
                    style: t.labelSmall?.copyWith(
                      color: DesignPalette.of(context).dim,
                    ),
                  ),
              ],
            ),
    );
  }
}

/// NZB 日志（F5，`Task.NZB.Log.get` v1，**只读**）。
///
/// 官方字段是 `nzblog`；`404` 是中性态（任务不存在/没有日志），给空态不是报错。
class _NzbLogSection extends ConsumerWidget {
  const _NzbLogSection({required this.taskId});

  final String taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final log = ref.watch(downloadNzbLogProvider(taskId));
    return _Panel(
      title: dataText('dsNzbLog', 'NZB 日志'),
      child: log.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(Gap.md),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (e, __) => Text(describeDownloadError(e), style: t.bodyMedium),
        data: (text) => text.trim().isEmpty
            ? Text(dataText('dsNzbLogEmpty', '暂无 NZB 日志'), style: t.bodyMedium)
            : SelectableText(
                text,
                key: const Key('ds-nzb-log-text'),
                style: t.bodySmall,
              ),
      ),
    );
  }
}

/// 单任务 BT 限速（**普通用户可用**；全局限速 admin-only，不做）。
class _BtSection extends ConsumerStatefulWidget {
  const _BtSection({required this.taskId});

  final String taskId;

  @override
  ConsumerState<_BtSection> createState() => _BtSectionState();
}

class _BtSectionState extends ConsumerState<_BtSection> {
  final _down = TextEditingController();
  final _up = TextEditingController();
  final _ratio = TextEditingController();
  final _peers = TextEditingController();
  final _interval = TextEditingController();
  bool _saving = false;

  /// 单任务优先级（`high`/`normal`/`low`；`''` = 自动/不下发）。
  String? _priority;

  @override
  void dispose() {
    _down.dispose();
    _up.dispose();
    _ratio.dispose();
    _peers.dispose();
    _interval.dispose();
    super.dispose();
  }

  void _fill(DownloadBtSettings s) {
    _down.text = '${s.maxDownloadRate}';
    _up.text = '${s.maxUploadRate}';
    _ratio.text = '${s.seedingRatio}';
    _peers.text = '${s.maxPeers}';
    _interval.text = '${s.seedingInterval}';
    _priority = s.priority;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final settings = ref.watch(downloadBtSettingsProvider(widget.taskId));
    return settings.when(
      loading: () => _Panel(
        title: t.dsBtSettings,
        child: const Padding(
          padding: EdgeInsets.all(Gap.lg),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (e, __) => _Panel(
        title: t.dsBtSettings,
        child: Padding(
          padding: const EdgeInsets.all(Gap.lg),
          child: Text(
            describeDownloadError(e),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ),
      data: (s) {
        // 首次拿到数据时填表（用户正在编辑时不覆盖）。
        if (_down.text.isEmpty) _fill(s);
        return _Panel(
          title: t.dsBtSettings,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 单任务优先级（官方 BT 属性表单的 `priority` combobox，经
              // `Task.BT.set` 下发；原 DC-4 之外的另一处参数缺口）。
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  key: const Key('ds-bt-priority'),
                  initialValue: _priority ?? '',
                  decoration: InputDecoration(
                    labelText: dataText('dsPriority', '优先级'),
                    isDense: true,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: '',
                      child: Text(dsPriorityLabel('')),
                    ),
                    for (final p in const ['high', 'normal', 'low'])
                      DropdownMenuItem(
                        value: p,
                        child: Text(dsPriorityLabel(p)),
                      ),
                  ],
                  onChanged: _saving
                      ? null
                      : (v) => setState(() => _priority = v ?? ''),
                ),
              ),
              _RateField(
                key: const Key('ds-bt-down'),
                controller: _down,
                label: t.dsBtMaxDownload,
              ),
              _RateField(
                key: const Key('ds-bt-up'),
                controller: _up,
                label: t.dsBtMaxUpload,
              ),
              _RateField(
                key: const Key('ds-bt-ratio'),
                controller: _ratio,
                label: t.dsBtSeedingRatio,
              ),
              _RateField(
                key: const Key('ds-bt-peers'),
                controller: _peers,
                label: t.dsBtMaxPeers,
              ),
              _RateField(
                key: const Key('ds-bt-interval'),
                controller: _interval,
                label: t.dsBtSeedingInterval,
              ),
              const SizedBox(height: Gap.sm),
              Text(
                t.dsBtRateHint,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: DesignPalette.of(context).dim,
                ),
              ),
              const SizedBox(height: Gap.md),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const Key('ds-bt-save'),
                  onPressed: _saving ? null : () => _save(s),
                  child: Text(t.actionSave),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _save(DownloadBtSettings origin) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    int parse(TextEditingController c) => int.tryParse(c.text.trim()) ?? 0;
    final next = origin.copyWith(
      maxDownloadRate: parse(_down),
      maxUploadRate: parse(_up),
      seedingRatio: parse(_ratio),
      maxPeers: parse(_peers),
      seedingInterval: parse(_interval),
      priority: _priority ?? origin.priority,
    );
    try {
      await ref
          .read(downloadActionsProvider)
          .saveBtSettings(widget.taskId, next);
      messenger.showSnackBar(SnackBar(content: Text(t.dsBtSaved)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(t.dsBtSaveFailed(describeDownloadError(e)))),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// 「结束下载任务」（官方 `str_force_complete`，`force_complete=true`）。
///
/// **不删文件**：只是把任务终结、不能再续传（官方确认文案
/// `str_force_complete_confirm` 明说文件位置会变、无法恢复下载）。
class _ForceCompleteAction extends ConsumerStatefulWidget {
  const _ForceCompleteAction({required this.task});

  final DownloadTaskDto task;

  @override
  ConsumerState<_ForceCompleteAction> createState() =>
      _ForceCompleteActionState();
}

class _ForceCompleteActionState extends ConsumerState<_ForceCompleteAction> {
  bool _busy = false;

  Future<void> _confirm() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('ds-force-complete-dialog'),
        title: Text(dataText('dsForceComplete', '结束任务')),
        content: Text(
          dataText(
            'dsForceCompleteConfirm',
            '结束后无法再恢复下载，已下载的文件会保留在目标文件夹。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(dataText('dsForceComplete', '结束任务')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(downloadActionsProvider).forceComplete([widget.task.id]);
      trackOnce(UsageModule.downloads, UsageAction.delete, objectType: 'task');
      messenger.showSnackBar(
        SnackBar(content: Text(dataText('dsForceCompleted', '已结束任务'))),
      );
      navigator.pop();
    } catch (e) {
      trackOnceFailure(
        UsageModule.downloads,
        UsageAction.delete,
        objectType: 'task',
        reason: 'force_complete_failed',
        error: e,
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            dataText(
              'dsBatchFailed',
              '操作失败：{msg}',
            ).replaceAll('{msg}', describeDownloadError(e)),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
    child: Align(
      alignment: Alignment.centerRight,
      child: OutlinedButton.icon(
        key: const Key('ds-force-complete'),
        onPressed: _busy ? null : _confirm,
        icon: const Icon(Icons.stop_circle_outlined, size: 18),
        label: Text(dataText('dsForceComplete', '结束任务')),
      ),
    ),
  );
}

/// Tracker 列表（`Task.BT.Tracker.list` v2，**只读**）。
class _TrackerSection extends ConsumerWidget {
  const _TrackerSection({required this.taskId});

  final String taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(downloadTrackersProvider(taskId));
    return _Panel(
      title: dataText('dsTrackerList', 'Tracker 列表'),
      child: page.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(Gap.md),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (e, __) => Text(
          describeDownloadError(e),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        data: (p) => p.items.isEmpty
            ? Text(
                dataText('dsTrackerEmpty', '没有 Tracker 信息'),
                style: Theme.of(context).textTheme.bodyMedium,
              )
            : Column(
                children: [
                  for (final tr in p.items)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Gap.xxs),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              tr.url,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          const SizedBox(width: Gap.sm),
                          // 官方 tracker 列表的 status 列没有 renderer，直接显示
                          // 服务端数值；这里保持只读原样，不自造状态文案。
                          TelemetryLabel(
                            'S${tr.seeds} · L${tr.peers} · #${tr.status}',
                            size: 11,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

/// Peer 列表（`Task.BT.Peer.list` v2，**只读**）。
class _PeerSection extends ConsumerWidget {
  const _PeerSection({required this.taskId});

  final String taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(downloadPeersProvider(taskId));
    return _Panel(
      title: dataText('dsPeerList', 'Peer 列表'),
      child: page.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(Gap.md),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (e, __) => Text(
          describeDownloadError(e),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        data: (p) => p.items.isEmpty
            ? Text(
                dataText('dsPeerEmpty', '没有 Peer 信息'),
                style: Theme.of(context).textTheme.bodyMedium,
              )
            : Column(
                children: [
                  for (final peer in p.items)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Gap.xxs),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  peer.ip,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                if (peer.client.isNotEmpty)
                                  Text(
                                    peer.client,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.labelSmall
                                        ?.copyWith(
                                          color: DesignPalette.of(context).dim,
                                        ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: Gap.sm),
                          TelemetryLabel(
                            '${(peer.progress * 100).toStringAsFixed(0)}% · '
                            '↓${dsHumanRate(peer.speedDownload)}',
                            size: 11,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

/// 任务内文件清单（A6，`Task.BT.File.list` v1–v2，**只读**）。
///
/// 事实来源：NAS 包内官方前端 `ui/download.js` 的 file store —— root `items`、
/// total `total`、参数 `{task_id, offset, limit}`、每页 25。
///
/// **收尾态**：显式「加载更多」按钮 + 加载完给「共 N 个文件」；
/// 服务端回空页即 `reachedEnd`，不会无限转圈（见 `DownloadFilesState`）。
class _FileSection extends ConsumerStatefulWidget {
  const _FileSection({required this.taskId});

  final String taskId;

  @override
  ConsumerState<_FileSection> createState() => _FileSectionState();
}

class _FileSectionState extends ConsumerState<_FileSection> {
  @override
  void initState() {
    super.initState();
    // build 里不能发请求：首帧之后再拉第一页。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(downloadFilesProvider(widget.taskId).notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final state = ref.watch(downloadFilesProvider(widget.taskId));
    return _Panel(
      title: dataText('dsFileList', '文件列表'),
      child: state.loading && !state.loaded
          ? const Padding(
              padding: EdgeInsets.all(Gap.md),
              child: Center(child: CircularProgressIndicator()),
            )
          // 1913（任务未激活/已完成）是**中性态**：不是"加载失败"。
          : state.inactive
          ? Text(
              dataText('dsFilesInactive', '任务未激活或已完成，暂无文件列表'),
              style: t.bodyMedium,
            )
          : state.errorText != null && state.items.isEmpty
          ? Text(state.errorText!, style: t.bodyMedium)
          : state.items.isEmpty
          ? Text(
              dataText('dsFileEmpty', '没有文件信息'),
              style: t.bodyMedium,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final f in state.items)
                  Padding(
                    key: Key('ds-file-row-${f.index}'),
                    padding: const EdgeInsets.symmetric(vertical: Gap.xxs),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                f.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: t.bodySmall,
                              ),
                              Text(
                                dsHumanBytes(f.size),
                                style: t.labelSmall?.copyWith(
                                  color: DesignPalette.of(context).dim,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: Gap.sm),
                        // 跳过 / 优先级（官方 `priorityRenderer`：wanted=false
                        // 显示"跳过"，否则显示 high/normal/low）。
                        TelemetryLabel(
                          f.isSkipped
                              ? dataText('dsFileSkipped', '跳过')
                              : dsPriorityLabel(f.priority),
                          size: 11,
                        ),
                        // 优先级 / 跳过（A6，`Task.BT.File.set` v2）——
                        // 官方同一行内的 `btnPriority` 菜单 + `btnSkip`。
                        PopupMenuButton<String>(
                          key: Key('ds-file-priority-${f.index}'),
                          tooltip: dataText('dsFilePriority', '优先级'),
                          enabled: !f.isSkipped,
                          onSelected: (v) => _setFile(
                            context,
                            ref,
                            index: f.index,
                            priority: v,
                          ),
                          itemBuilder: (_) => [
                            for (final v in const ['high', 'normal', 'low'])
                              PopupMenuItem(
                                key: Key('ds-file-priority-${f.index}-$v'),
                                value: v,
                                child: Text(dsPriorityLabel(v)),
                              ),
                          ],
                        ),
                        IconButton(
                          key: Key('ds-file-skip-${f.index}'),
                          visualDensity: VisualDensity.compact,
                          tooltip: f.isSkipped
                              ? dataText('dsFileUnskip', '恢复下载')
                              : dataText('dsFileSkip', '跳过'),
                          icon: Icon(
                            f.isSkipped
                                ? Icons.playlist_add_check
                                : Icons.playlist_remove,
                            size: 18,
                          ),
                          onPressed: () => _setFile(
                            context,
                            ref,
                            index: f.index,
                            wanted: f.isSkipped,
                          ),
                        ),
                        // 复制到…（B10，`Task.BT.File.copy` v2，normal）。
                        IconButton(
                          key: Key('ds-file-copy-${f.index}'),
                          visualDensity: VisualDensity.compact,
                          tooltip: dataText('dsFileCopyTo', '复制到…'),
                          icon: const Icon(Icons.copy_all_outlined, size: 18),
                          onPressed: () => _copyTo(context, ref, f),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: Gap.sm),
                if (state.loadingMore)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(Gap.sm),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                else if (state.hasMore)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const Key('ds-files-more'),
                      onPressed: () => ref
                          .read(downloadFilesProvider(widget.taskId).notifier)
                          .loadMore(),
                      child: Text(dataText('dsLoadMore', '加载更多')),
                    ),
                  )
                else
                  // 明确收尾态：不会再有下一页。
                  Text(
                    dataText(
                      'dsFilesTotal',
                      '共 {n} 个文件',
                    ).replaceAll('{n}', '${state.items.length}'),
                    style: t.labelSmall?.copyWith(
                      color: DesignPalette.of(context).dim,
                    ),
                  ),
              ],
            ),
    );
  }

  /// 把这一行文件复制到别的目录（B10，`Task.BT.File.copy` v2）。
  /// A6：任务内文件的优先级 / 跳过（`Task.BT.File.set` v2，**写操作**）。
  ///
  /// 官方 `ui/download.js` 的 `setFiles` 一次只带一个字段：
  /// 优先级菜单带 `priority`，跳过按钮带 `wanted:false`（恢复带 `true`）。
  Future<void> _setFile(
    BuildContext context,
    WidgetRef ref, {
    required int index,
    String? priority,
    bool? wanted,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(downloadActionsProvider).setFileOptions(
        taskId: widget.taskId,
        indexes: [index],
        priority: priority,
        wanted: wanted,
      );
      ref.read(downloadFilesProvider(widget.taskId).notifier).load();
      messenger.showSnackBar(
        SnackBar(content: Text(dataText('dsFileOptionSaved', '已提交'))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            dataText(
              'dsFileOptionFailed',
              '操作失败：{msg}',
            ).replaceAll('{msg}', describeDownloadError(e)),
          ),
        ),
      );
    }
  }

  Future<void> _copyTo(
    BuildContext context,
    WidgetRef ref,
    DownloadFileDto file,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final dest = await showDsDestinationDialog(
      context,
      title: dataText('dsFileCopyTo', '复制到…'),
      initial: '',
      fieldKey: const Key('ds-copy-dest-field'),
    );
    if (dest == null) return;
    try {
      await ref
          .read(downloadActionsProvider)
          .copyFileTo(
            taskId: widget.taskId,
            indexes: [file.index],
            destination: dest,
          );
      messenger.showSnackBar(
        SnackBar(content: Text(dataText('dsFileCopied', '已开始复制文件'))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            dataText(
              'dsFileCopyFailed',
              '复制失败：{msg}',
            ).replaceAll('{msg}', describeDownloadError(e)),
          ),
        ),
      );
    }
  }
}

/// 「导出 .torrent」（F7，`Task.Source.download` v2，只读）。
/// 落盘走既有通道（`dsDownloadDirProvider` = `fileDownloadDirectory`，
/// 与 Office 导出/FileStation 下载同一条），**不新造平台通道**。
class _ExportTorrentAction extends ConsumerStatefulWidget {
  const _ExportTorrentAction({required this.task});

  final DownloadTaskDto task;

  @override
  ConsumerState<_ExportTorrentAction> createState() =>
      _ExportTorrentActionState();
}

class _ExportTorrentActionState extends ConsumerState<_ExportTorrentAction> {
  bool _busy = false;

  Future<void> _export() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final saver = ref.read(dsSourceSaverProvider);
      final path = await saver(widget.task.id, widget.task.title);
      final name = path.isEmpty
          ? dsTorrentFileName(widget.task.title)
          : path.split('/').last;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            dataText(
              'dsTorrentExported',
              '已导出 {name}',
            ).replaceAll('{name}', name),
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            dataText(
              'dsTorrentExportFailed',
              '导出失败：{msg}',
            ).replaceAll('{msg}', describeDownloadError(e)),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
    child: Align(
      alignment: Alignment.centerRight,
      child: OutlinedButton.icon(
        key: const Key('ds-export-torrent'),
        onPressed: _busy ? null : _export,
        icon: const Icon(Icons.file_download_outlined, size: 18),
        label: Text(dataText('dsExportTorrent', '导出 .torrent')),
      ),
    ),
  );
}

class _RateField extends StatelessWidget {
  const _RateField({super.key, required this.controller, required this.label});

  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Gap.sm),
    child: TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(labelText: label, isDense: true),
    ),
  );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Gap.lg),
        decoration: BoxDecoration(
          color: DesignPalette.of(context).surface,
          borderRadius: BorderRadius.circular(Radii.pane),
          border: Border.all(color: DesignPalette.of(context).line.withValues(alpha: 0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TelemetryLabel(title, uppercase: false),
            const SizedBox(height: Gap.sm),
            child,
          ],
        ),
      ),
    );
  }
}
