// 错误态回归（第 260 轮，R1）· Drive 本地文件页（H3）。
//
// 单独成文件的原因：本页 import 了 `drive_browse_view`（取 `driveDsmFolderOf`），
// 而那条依赖链会一路拉到 `media_player_view.dart`；把它与其它用例分开
// 可以避免"媒体页正在被别人改"时整份错误态回归都编译不过。
//
// 症状：`_list` 把 `listSync` 的异常吞掉返回 `const []` ⇒ 读不了的目录
// **被渲染成"这个目录是空的"**，用户以为文件没了，且没有任何重试入口。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/drive/drive_local_files_page.dart';

void main() {
  testWidgets('读目录失败 → 错误态 + 重试；重试后真的重新读取并列出', (tester) async {
    final dir = Directory.systemTemp.createTempSync('r1_local');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    File('${dir.path}/note.txt').writeAsStringSync('hi');

    var calls = 0;
    final c = ProviderContainer(
      overrides: [
        driveLocalRootsProvider.overrideWith((ref) async => [dir]),
        driveLocalListerProvider.overrideWithValue((d) {
          calls++;
          if (calls == 1) {
            throw const FileSystemException('simulated permission denied');
          }
          return d.listSync(followLinks: false);
        }),
      ],
    );
    addTearDown(c.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(theme: AppTheme.dark(), 
          home: DriveLocalFilesPage(targetDrivePath: '/mydrive'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    await tester.tap(find.byKey(const Key('drive-local-root-0')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('drive-local-list-error')),
      findsOneWidget,
      reason: '★ 读取失败必须如实报错',
    );
    expect(
      find.byKey(const Key('drive-local-empty')),
      findsNothing,
      reason: '★★ 失败绝不能渲染成"这个目录是空的"',
    );
    expect(find.textContaining('重试'), findsWidgets);
    expect(calls, 1);

    await tester.tap(find.textContaining('重试').first);
    await tester.pumpAndSettle();
    expect(calls, 2, reason: '★★ 重试必须真的重新读取');
    expect(
      find.byKey(const Key('drive-local-list')),
      findsOneWidget,
      reason: '第二次成功 → 真实列出条目',
    );
    expect(find.byKey(const Key('drive-local-entry-note.txt')), findsOneWidget);
  });
}
