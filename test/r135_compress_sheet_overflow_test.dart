// 第 135 轮真机缺陷回归：**「压缩」弹层在英文下右侧溢出 35 px**。
//
// ## 真机证据（先有像素，后有本用例）
//
// `/private/tmp/r134_ui/033_d2_compress.png`（Honor LGE-AN10，1148×2492 @490dpi，
// App 语言 = English）里弹出 `showCompressSheet` 时，界面上出现 Flutter 的
// 黄黑溢出条；裁剪图 `/private/tmp/r134_ui/033_crop_overflow.png` 逐字显示
// `RIGHT OVERFLOWED BY 35 PIXELS`，位置正好在「压缩格式 / 压缩级别」那一行。
//
// ## 根因
//
// 那一行是 `Row(children: [Expanded(DropdownButtonFormField<CompressFormat>),
// SizedBox, Expanded(DropdownButtonFormField<CompressLevel>)])`。
// `DropdownButtonFormField` 默认 `isExpanded: false` ⇒ 它内部的
// `DropdownButton` 在**有限宽度**里按**内容固有宽度**排版（选中项 + 箭头图标），
// 而不是充满 `Expanded` 给的那一格；英文标签/选中项比中文长
// （`Compression level` / `Archive format`）⇒ 内部 `Row` 撑破格子。
// 中文下标签短，所以**一直没暴露** —— 这正是"离线全绿 ≠ 真机可用"的又一例。
//
// 修法：所有表单式下拉一律 `isExpanded: true`（本文件只对压缩弹层做回归，
// 全仓 19 处一起改；另有 9 处 `DropdownButton` 在 `ListTile.trailing` 里、
// 未在真机取证到溢出，**未改**，见文档记录）。
//
// ## 本用例的双向验证（本仓规矩：证明用例真抓得住缺陷）
//
// * ①②③ 打开**真实的** `_CompressDialog`，断言 `takeException()` 为空；
// * ④ 用**修复前**的写法（同一形态的 `Row` + 两个 `Expanded` 下拉、
//   **不设** `isExpanded`）在同一宽度下渲染 ⇒ 必须**真的**抛 overflow。
//   没有④，"全绿"可能只是断言写错。
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/files/file_sheets.dart';

const List<LocalizationsDelegate<Object>> _delegates = [
  AppText.delegate,
  FlutterQuillLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

const List<Locale> _locales = [Locale('zh'), Locale('en')];

void main() {
  Future<void> pumpCompressSheet(
    WidgetTester tester, {
    required Locale locale,
    required Size size,
    double scale = 1.0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // ★ 数据层文案（`fsC5` / `fsGap2` 走 dataText）要靠这个才切到英文，
    //   只设 `MaterialApp.locale` 不够 —— 那样下拉标签仍是中文，
    //   溢出就复现不出来（这正是当初漏掉这个缺陷的原因）。
    setCurrentText(lookupAppText(locale));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        locale: locale,
        localizationsDelegates: _delegates,
        supportedLocales: _locales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const Key('open-compress-sheet'),
                onPressed: () => showCompressSheet(
                  context,
                  defaultName: 'Archive.zip',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-compress-sheet')));
    await tester.pumpAndSettle();
  }

  group('r135 · 压缩弹层在英文下不溢出（真机 033_d2_compress.png）', () {
    testWidgets('英文 + 360×640：零布局异常', (tester) async {
      await pumpCompressSheet(
        tester,
        locale: const Locale('en'),
        size: const Size(360, 640),
      );
      // 先确认语言真的切成英文了（否则这条用例什么都没验）
      expect(find.text('Archive format'), findsOneWidget);
      expect(find.text('Compression level'), findsOneWidget);
      expect(find.text('Standard'), findsWidgets);
      expect(
        tester.takeException(),
        isNull,
        reason: '英文下「压缩格式 / 压缩级别」那一行溢出（真机 35px）',
      );
    });

    testWidgets('英文 + 320×568 + 1.3 倍字号（最窄真机组合）：零布局异常', (tester) async {
      await pumpCompressSheet(
        tester,
        locale: const Locale('en'),
        size: const Size(320, 568),
        scale: 1.3,
      );
      expect(find.text('Archive format'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('中文 + 360×640：修英文不许把中文弄坏', (tester) async {
      await pumpCompressSheet(
        tester,
        locale: const Locale('zh'),
        size: const Size(360, 640),
      );
      expect(find.text('压缩格式'), findsOneWidget);
      expect(find.text('压缩级别'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // ------------------------------------------------------------ 反向验证
  //
  // 把**修复前**的形态原样写出来（`isExpanded` 缺席），证明上面那三条
  // `takeException() == null` 不是恒真。
  group('r135 · 反向验证（证明用例抓得住）', () {
    Widget mirroredRow({required bool isExpanded, required Locale locale}) {
      return MaterialApp(
        theme: AppTheme.dark(),
        locale: locale,
        localizationsDelegates: _delegates,
        supportedLocales: _locales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              // 与压缩弹层里那一行等宽：对话框左右各留 24 边距 + 中间 12 间距
              width: 360 - 48,
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<CompressFormat>(
                      isExpanded: isExpanded,
                      initialValue: CompressFormat.sevenZip,
                      decoration: const InputDecoration(
                        labelText: 'Archive format',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: CompressFormat.zip,
                          child: Text('ZIP'),
                        ),
                        DropdownMenuItem(
                          value: CompressFormat.sevenZip,
                          child: Text('7z'),
                        ),
                      ],
                      onChanged: (_) {},
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<CompressLevel>(
                      isExpanded: isExpanded,
                      initialValue: CompressLevel.store,
                      decoration: const InputDecoration(
                        labelText: 'Compression level',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: CompressLevel.store,
                          child: Text('Store only'),
                        ),
                        DropdownMenuItem(
                          value: CompressLevel.best,
                          child: Text('Best'),
                        ),
                      ],
                      onChanged: (_) {},
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('修复前形态（无 isExpanded）在英文下必须溢出', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        mirroredRow(isExpanded: false, locale: const Locale('en')),
      );
      await tester.pump();
      final e = tester.takeException();
      expect(
        e,
        isNotNull,
        reason:
            '把修复前的写法（DropdownButtonFormField 不设 isExpanded）放回同一宽度，'
            '却没被判溢出 —— 说明上面三条断言恒真、抓不到真机那个 35px 溢出',
      );
      expect(e.toString(), contains('overflowed'));
    });

    testWidgets('修复后形态（isExpanded: true）在同一宽度下零异常', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        mirroredRow(isExpanded: true, locale: const Locale('en')),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
