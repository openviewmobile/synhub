// N6 主题（第 125 轮）：**笔记内可达的主题入口**。
//
// 官方取证：DSnote `res/values/strings.xml:860-862`
// `theme_dark`/`theme_default`/`theme_light`（= Dark / System default / Light）
// —— 官方把主题放在**应用设置**里，笔记模块内没有独立主题体系。
// 我方主题本来就是 **App 级**（`themeChoiceProvider` → `MaterialApp.themeMode`），
// 这里只补一个**笔记里能点到的入口**（写同一个偏好），
// 避免"功能有、但从笔记找不到"的口径缺口。**不新增第二套主题状态**。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'note_storage_location.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/data_text.dart';
import '../../core/settings/app_settings.dart';

/// 弹出主题选择面板（跟随系统 / 浅色 / 深色）。
Future<void> showNoteThemeSheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: DesignPalette.of(context).bg,
    builder: (_) => const _NoteThemeSheet(),
  );
}

/// 与 [showNoteThemeSheet] 同一条路径，只是显式接一个 [ProviderContainer]
/// （widget 用例里 `ProviderScope.containerOf` 拿到的就是同一个容器）。
Future<void> showNoteThemeSheetImpl(
  BuildContext context,
  ProviderContainer container,
) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: DesignPalette.of(context).bg,
    builder: (_) => UncontrolledProviderScope(
      container: container,
      child: const _NoteThemeSheet(),
    ),
  );
}

class _NoteThemeSheet extends ConsumerWidget {
  const _NoteThemeSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final current = ref.watch(themeChoiceProvider);
    final options = <(AppThemeChoice, String, String)>[
      (AppThemeChoice.system, 'themeSystem', dataText('themeSystem', '跟随系统')),
      (AppThemeChoice.light, 'themeLight', dataText('themeLight', '浅色')),
      (AppThemeChoice.dark, 'themeDark', dataText('themeDark', '深色')),
    ];
    return SafeArea(
      // 多出来的「存储位置」两行会让内容超过半屏 ⇒ 必须可滚动，
      // 否则小屏/测试视口会 RenderFlex overflow（第 235 轮踩到）。
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.brightness_6_outlined, color: hud.dim, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    dataText('noteThemeTitle', '主题'),
                    style: TextStyle(color: hud.dim, fontSize: 13),
                  ),
                ],
              ),
            ),
            for (final (choice, key, label) in options)
              DesignRowTile(
                key: Key('note-theme-$key'),
                leading: Icon(
                  choice == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: hud.dim,
                  size: 20,
                ),
                title: Text(label, style: TextStyle(color: hud.dim)),
                onTap: () async {
                  // 立刻改 App 主题 + 落盘（同一个偏好，不另起一套）
                  await ref.read(themeChoiceProvider.notifier).set(choice);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.sd_storage_outlined, color: hud.dim, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    dataText('noteStorageTitle', '存储位置（附件/离线数据）'),
                    style: TextStyle(color: hud.dim, fontSize: 13),
                  ),
                  const Spacer(),
                  if (ref.watch(noteStorageLocationProvider) ==
                      NoteStorageLocation.external)
                    Text(
                      dataText('noteStorageExternalShort', '外置'),
                      style: TextStyle(color: hud.dim, fontSize: 12),
                    ),
                ],
              ),
            ),
            for (final loc in NoteStorageLocation.values)
              DesignRowTile(
                key: Key('note-storage-${loc.wire}'),
                leading: Icon(
                  ref.watch(noteStorageLocationProvider) == loc
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: hud.dim,
                  size: 20,
                ),
                title: Text(
                  loc == NoteStorageLocation.internal
                      ? dataText('noteStorageInternal', '内部存储（应用私有）')
                      : dataText('noteStorageExternal', '外置存储（应用专属目录）'),
                  style: TextStyle(color: hud.dim),
                ),
                onTap: () async {
                  await ref.read(noteStorageLocationProvider.notifier).set(loc);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
