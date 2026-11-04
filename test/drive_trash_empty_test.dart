// D10 守卫（r719）：Drive「回收站」在**空**的时候必须给空态，不许报"打不开这个位置"。
//
// 背景：r715 的 macOS 审计像素 `f23_files_recycle.png` 显示
// `Couldn't open this location / Target location not found`。追下去不是产品 bug，
// 而是 **Mock 没有 `SynologyDrive.Trash` 夹具** ⇒ 页面走了 error 分支。
// 真 NAS 只读实测（r719）：`Trash:list {path:"/mydrive"}` → `{"total":0}` success。
// 本用例把 provider 覆写成"空回收站"，钉住空态文案（error 分支不许再冒出来）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/data/dto/drive_entry_dto.dart';
import 'package:synhub/src/features/files/drive_more_page.dart';
import 'package:synhub/src/features/files/drive_providers.dart';

void main() {
  testWidgets('回收站为空：出空态文案，不出"打不开这个位置"', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          driveTrashProvider.overrideWith((ref, path) async {
            return (items: <DriveEntryDto>[], total: 0);
          }),
          driveTrashSizeProvider.overrideWith((ref, path) async => 0),
        ],
        child: const MaterialApp(home: DriveMorePage()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    // Drive More 页默认停在「回收站」分节（见 DriveMoreSectionNotifier.build）
    final t = currentText();
    expect(find.text(t.driveTrashEmpty), findsWidgets,
        reason: '空回收站必须出空态标题（D10）');
    expect(find.text(t.noteOpenRecycleFailed), findsNothing,
        reason: '空回收站不许报"打不开这个位置"（D10 的原始症状）');
  });
}
