// 编辑拍摄日期 / 时刻（P36）—— `sheet_edit_date` 的等价物。
//
// ## 官方口径（APK 2.4.0-644，jadx）
//   * UI：`ui/dateeditor/EditDateSheet.java`（`layout/sheet_edit_date`，
//     按钮 `id/btn_edit_date` / `id/btn_save`），`EditDateViewModel` 把**日期**
//     与**时刻**分成两个字段编辑（`setDate(year,month,day)` / `setTime(hour,minute)`，
//     与 `invalidateModifiedDate` / `invalidateModifiedTime` 两个入口一致）；
//   * `EditDateSheet.INSTANCE.showIfNotShowing(fm, timelineImage, lightboxAlbumItem)`
//     —— 同一时刻只允许一个 sheet（`findFragmentByTag(TAG) == null` 才 show）。
//     本仓用 `showModalBottomSheet` 天然满足（模态栈里不会叠两个同样的 sheet）。
//   * 提交：`EditDateViewModel.applyEdit()` → `ImageRepository.editPhotoTime`
//     → `ConnectionManager.editPhotoTime:6977` → `ApiBrowseItem.getSetPhotoTimeResponse:489`
//     → **`Browse.Item/set` + `time`**（绝对 epoch 秒，**不是** JSON 串；
//     与 `rotate_action` 的形态**不同**，见 `FotoApi.setItemTime` 的逐字证据）。
//
// ## 本仓的取舍
//   * 只做**照片**（官方也是从 PhotoInfo 的 `btn_edit_date` 进；视频没有这个入口）。
//   * ⚠️ **写操作**：界面上必须先过一个**明确的确认框**（把"原时间 → 新时间"
//     写清楚）才允许发请求；取消 = 一个请求都不发。
//   * 失败提示由调用方负责（`describePhotoError` + `editDateFailed`）——
//     本文件不发请求，只负责"收集用户意图 + 确认"。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../data/dto/foto_dto.dart';
import '../../core/theme/app_tokens.dart';
import 'photo_media_text.dart';
import 'photo_widgets.dart' show photoGroupLabel;
import '../../core/theme/app_theme.dart';

/// 弹出「编辑日期时间」sheet。
///
/// 返回**用户确认后的新拍摄时间**；返回 `null` = 取消 / 没改动 / 没确认
/// （调用方据此**不发起任何写请求**）。
Future<DateTime?> showPhotoEditDateSheet(
  BuildContext context, {
  required FotoItemDto item,
}) {
  return showModalBottomSheet<DateTime>(
    context: context,
    isScrollControlled: true,
    backgroundColor: DesignPalette.of(context).bg,
    builder: (_) => _PhotoEditDateSheet(item: item),
  );
}

class _PhotoEditDateSheet extends StatefulWidget {
  const _PhotoEditDateSheet({required this.item});

  final FotoItemDto item;

  @override
  State<_PhotoEditDateSheet> createState() => _PhotoEditDateSheetState();
}

class _PhotoEditDateSheetState extends State<_PhotoEditDateSheet> {
  late DateTime _value = widget.item.takenAt;
  bool _invalid = false;

  /// 原始时间（用来判"有没有真的改过"）。
  DateTime get _original => widget.item.takenAt;

  bool get _changed =>
      _value.year != _original.year ||
      _value.month != _original.month ||
      _value.day != _original.day ||
      _value.hour != _original.hour ||
      _value.minute != _original.minute;

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _value,
      // 年份范围取宽一点：官方允许改到很早（老照片扫描件常见）。
      firstDate: DateTime(1900),
      lastDate: DateTime(2200),
    );
    if (picked == null) return;
    setState(() {
      _value = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _value.hour,
        _value.minute,
      );
      _invalid = false;
    });
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _value.hour, minute: _value.minute),
    );
    if (picked == null) return;
    setState(() {
      _value = DateTime(
        _value.year,
        _value.month,
        _value.day,
        picked.hour,
        picked.minute,
      );
      _invalid = false;
    });
  }

  /// 保存 → **先过确认框**（写操作，必须明确告知改的是什么）。
  Future<void> _save() async {
    final t = context.t;
    if (!_changed) {
      setState(() => _invalid = true);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('photo-edit-date-confirm-dialog'),
        title: Text(
          photoMedia(PhotoMediaTextKeys.editDateConfirmTitle, '修改拍摄时间？'),
        ),
        content: Text(
          photoMediaFill(
            PhotoMediaTextKeys.editDateConfirmBody,
            '这会把这张照片的拍摄时间从 {from} 改为 {to}。原文件不会被重新编码，'
                '但相册里的时间轴与排序会随之变化。',
            {
              'from': photoGroupLabel(
                _original,
                unit: 'minute',
                l10n: t,
              ),
              'to': photoGroupLabel(_value, unit: 'minute', l10n: t),
            },
          ),
        ),
        actions: [
          TextButton(
            key: const Key('photo-edit-date-confirm-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.actionCancel),
          ),
          FilledButton(
            key: const Key('photo-edit-date-confirm-ok'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(photoMedia(PhotoMediaTextKeys.editDateAction, '保存')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    Navigator.of(context).pop(_value);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return SafeArea(
      key: const Key('photo-edit-date-sheet'),
      child: Padding(
        padding: EdgeInsets.only(
          left: Gap.lg,
          right: Gap.lg,
          top: Gap.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              photoMedia(PhotoMediaTextKeys.editDateTitle, '编辑日期时间'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Gap.md),
            DesignRowTile(
              key: const Key('photo-edit-date-date'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined),
              title: Text(
                photoMedia(PhotoMediaTextKeys.editDateField, '日期'),
              ),
              subtitle: Text(photoGroupLabel(_value, unit: 'day', l10n: t)),
              onTap: _pickDate,
            ),
            DesignRowTile(
              key: const Key('photo-edit-date-time'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule_outlined),
              title: Text(
                photoMedia(PhotoMediaTextKeys.editTimeField, '时间'),
              ),
              subtitle: Text(photoGroupLabel(_value, unit: 'minute', l10n: t)),
              onTap: _pickTime,
            ),
            if (_invalid)
              Padding(
                key: const Key('photo-edit-date-invalid'),
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Text(
                  photoMedia(
                    PhotoMediaTextKeys.editDateInvalid,
                    '时间没有变化 —— 请先改日期或时刻。',
                  ),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: Gap.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const Key('photo-edit-date-cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(t.actionCancel),
                ),
                const SizedBox(width: Gap.sm),
                FilledButton(
                  style: InlineButtonStyle.filled,
                  key: const Key('photo-edit-date-save'),
                  onPressed: _save,
                  child: Text(photoMedia(PhotoMediaTextKeys.editDateAction, '保存')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
