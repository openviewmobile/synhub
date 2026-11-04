// ★★ **③Drive 第 64 轮：D56 的 UI 半边** —— 新建弹层里的空白 Office 入口
//
// 第 63 轮把 `Office.Node/create` 实现了（协议层），但用户在界面上仍然
// 新建不了空白文档 —— 那时 D56 仍记 🟠。本轮补上入口并**真渲染验证**。
//
// ## 这条测试为什么值得单独写
// 只断言"代码里有 `Key('drive-create-doc')`"是没用的（那是文本搜索）。
// 这里**真的把弹层弹出来**，证明 ListTile 确实被构建、并且
// 每项都带着各自的 `action`（`'doc'` / `'sheet'`）——
// 后者才是决定调 `ntype=doc` 还是 `ntype=sheet` 的东西，
// 写反了会**安静地建出错误的文档类型**。
//
// 全程内存 Mock，不碰真机（规程 §5.1）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/files/drive_browse_view.dart';

void main() {
  /// 用一个按钮触发 [showDriveCreateSheet]（它自己负责分发，返回 void）
  Future<void> openSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(theme: AppTheme.dark(), 
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Center(
                child: ElevatedButton(
                  key: const Key('open-sheet'),
                  onPressed: () =>
                      showDriveCreateSheet(context, ref, '/mydrive'),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-sheet')));
    await tester.pumpAndSettle();
  }

  group('DC56-1. ★★ 新建弹层**真的**列出了空白 Office 入口', () {
    testWidgets('★★ 「文档」与「电子表格」两项都在（且是分开的两个入口）', (tester) async {
      await openSheet(tester);
      expect(
        find.byKey(const Key('drive-create-doc')),
        findsOneWidget,
        reason: '★ 没有这一项，用户就新建不了空白文档（D56 的 UI 半边）',
      );
      expect(
        find.byKey(const Key('drive-create-sheet')),
        findsOneWidget,
        reason:
            '★ 表格是**独立**入口，不能和文档共用一个 ——'
            ' 共用一个就只能发一种 `ntype`',
      );
      // 既有的三项也不能被挤掉
      expect(find.byKey(const Key('drive-create-folder')), findsOneWidget);
      expect(find.byKey(const Key('drive-create-text')), findsOneWidget);
      expect(find.byKey(const Key('drive-create-upload')), findsOneWidget);
    });

    testWidgets('★ 文案能让用户分清"Office 文档"与"文本文件"', (tester) async {
      await openSheet(tester);
      expect(find.textContaining('Synology Office 文档'), findsOneWidget);
      expect(find.textContaining('Synology Office 电子表格'), findsOneWidget);
      expect(
        find.textContaining('文本文件'),
        findsOneWidget,
        reason:
            '★ 两者都存在且文案不同：`.txt` 与 `.odoc` 是两种东西，'
            '文案混了用户会选错',
      );
    });
  });

  group('DC56-2. ★★★ 两条入口走**不同**分支（决定 ntype）', () {
    // `showDriveCreateSheet` 自己分发、返回 void，所以不能靠返回值观察。
    // 改从**它接下来弹出的命名对话框标题**观察 ——
    // `_createOfficeNode` 用 label 当对话框标题，doc/sheet 的 label 不同，
    // 于是"点了哪一项"变成可观测的事实。
    //
    // 两条入口写成两个独立用例（而不是循环）：循环里上一个用例残留的
    // 对话框会干扰下一个，清理逻辑本身就成为假失败源。
    for (final probe in const [
      ('drive-create-doc', 'Synology Office 文档'),
      ('drive-create-sheet', 'Synology Office 电子表格'),
    ]) {
      testWidgets('★★★ 点「${probe.$2}」⇒ 进入**该类型**的命名流程', (tester) async {
        await openSheet(tester);
        await tester.tap(find.byKey(Key(probe.$1)));
        await tester.pumpAndSettle();

        expect(
          find.text(probe.$2),
          findsWidgets,
          reason:
              '★★★ 点「${probe.$1}」后应进入 **${probe.$2}** 的命名流程。'
              '若两条入口走同一分支，就只有一种 label 出现 —— 后果是'
              '**安静地建出错误类型**（服务端对 `ntype` 不报错，'
              '用户只会觉得"建出来的文件打不开"）',
        );
      });
    }
  });
}
