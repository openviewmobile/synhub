// 「转成 Office 格式」底部面板（wave2）：`SYNO.SynologyDrive.Files:convert_office` **v1**。
//
// 真机契约（用户取证）：
//   * `files` = `'["id:<file_id>"]'`（**必须带 `id:` 前缀 + JSON 数组字符串**）；
//   * `format`（真机验证值 `"docx"`）；
//   * 回包 `{"data":{"async_task_id":"task-140"}}`。
//
// 结果提示纪律（**不谎报成功**）：
//   * 提交成功但轮询通道未确认 → "已提交转换"（[DriveConvertOutcome.pending]）；
//   * 只有轮询到 `status == "finished"` 才显示"转换完成"；
//   * 任务报错 → "转换失败"。
//   * `async_task_id` **绝不显示在界面上**（只在内部轮询 / Key / 测试断言里）。
//
// 能力门控：入口按 `SYNO.SynologyDrive.Files` 能力位隐藏（见 [DriveExtrasPage] /
// `DriveFolderPage`）；面板内再按错误码给 105/160 / 119/106 的说明。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/drive_entry_dto.dart';
import 'drive_p0_text.dart';
import 'drive_wave2_providers.dart';
import 'drive_wave2_text.dart';
import '../../core/theme/app_theme.dart';

/// 打开"转成 Office 格式"面板
Future<void> showDriveConvertOfficeSheet(
  BuildContext context,
  WidgetRef ref,
  DriveEntryDto entry,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => DriveConvertOfficeSheet(entry: entry),
);

class DriveConvertOfficeSheet extends ConsumerStatefulWidget {
  const DriveConvertOfficeSheet({super.key, required this.entry});

  final DriveEntryDto entry;

  @override
  ConsumerState<DriveConvertOfficeSheet> createState() =>
      _DriveConvertOfficeSheetState();
}

class _DriveConvertOfficeSheetState
    extends ConsumerState<DriveConvertOfficeSheet> {
  bool _submitting = false;
  DriveConvertOutcome? _outcome;
  Object? _error;

  Future<void> _submit() async {
    final runner = ref.read(driveConvertOfficeRunnerProvider);
    if (runner == null) {
      setState(() => _error = StateError('not connected'));
      return;
    }
    setState(() {
      _submitting = true;
      _outcome = null;
      _error = null;
    });
    final result = await runner.run(
      fileId: widget.entry.fileId,
      format: kDriveConvertDefaultFormat,
    );
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _outcome = result.outcome;
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final available = driveFilesCapabilityAvailable(ref);
    return SafeArea(
      key: const Key('drive-convert-sheet'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              driveWave2(DriveWave2TextKeys.convertTitle, '转成 Office 格式'),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: Gap.xs),
            Text(
              widget.entry.name,
              key: const Key('drive-convert-name'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: Gap.sm),
            Row(
              children: [
                Text(
                  driveWave2(
                    DriveWave2TextKeys.convertTarget,
                    '目标格式',
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                ),
                const SizedBox(width: Gap.sm),
                Text(
                  driveWave2(
                    DriveWave2TextKeys.convertTargetDocx,
                    'Word 文档（.docx）',
                  ),
                  key: const Key('drive-convert-target'),
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
            if (_statusText() != null) ...[
              const SizedBox(height: Gap.md),
              Text(
                _statusText()!,
                key: const Key('drive-convert-status'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: _outcome == DriveConvertOutcome.failed
                      ? hud.danger
                      : hud.dim,
                ),
              ),
            ],
            const SizedBox(height: Gap.md),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(
                      driveWave2(DriveWave2TextKeys.convertClose, '关闭'),
                    ),
                  ),
                  const SizedBox(width: Gap.xs),
                  FilledButton(
                    style: InlineButtonStyle.filled,
                    key: const Key('drive-convert-submit'),
                    onPressed: (!available || _submitting || _done)
                        ? null
                        : _submit,
                    child: Text(
                      _submitting
                          ? driveWave2(
                              DriveWave2TextKeys.convertSubmitting,
                              '正在提交转换…',
                            )
                          : driveWave2(
                              DriveWave2TextKeys.convertSubmit,
                              '开始转换',
                            ),
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

  /// 已确认完成 / 已提交后不再重复提交（失败可重试）。
  bool get _done =>
      _outcome == DriveConvertOutcome.finished ||
      _outcome == DriveConvertOutcome.pending;

  String? _statusText() {
    if (!driveFilesCapabilityAvailable(ref)) {
      return driveWave2(
        DriveWave2TextKeys.convertUnavailable,
        '这台 NAS 没有提供该转换服务',
      );
    }
    if (_submitting) {
      return driveWave2(
        DriveWave2TextKeys.convertSubmitting,
        '正在提交转换…',
      );
    }
    if (_outcome == null) return null;
    switch (_outcome!) {
      case DriveConvertOutcome.finished:
        return driveWave2(
          DriveWave2TextKeys.convertFinished,
          '转换完成',
        );
      case DriveConvertOutcome.pending:
        return driveWave2(
          DriveWave2TextKeys.convertSubmitted,
          '已提交转换，正在后台处理。完成后会出现在原文件夹中。',
        );
      case DriveConvertOutcome.failed:
        final gate = driveEntryGate(_error);
        if (gate != DriveEntryGate.available) return driveGateMessage(gate);
        // 业务失败（无错误码）：官方措辞"转换 {0} 失败"
        return driveWave2(
          DriveWave2TextKeys.convertFailed,
          '转换失败，请稍后重试',
        );
    }
  }
}
