// ★★ ③Drive 第 216 轮 **D37「保存为扫描件」** 的页面用例。
//
// 背景：D37 在台账里一直记 **❌未实现**，但代码在**第 99 轮**就落地了
// （`drive_scan_page.dart`：拍照 → `pdf` 包合成 → 既有 `Files/upload`），
// 而且有 Mock 契约用例（`test/drive_scan_mock_test.dart`）。**台账是旧账**。
//
// 本轮（216）做两件事：
//   ① 旧账纠错（向上）：把 D37 从 ❌ 如实改成"已实现的功能子集"；
//   ② 补齐官方扫描器的**相册导入**与**逐页审阅（移序/删除）**，
//      并让取页出口可注入 ⇒ 整页离线可测（原来的 `captureScanPages` 直接
//      打原生相机，页面层根本测不了）。
//
// ⚠️ 仍缺（挂账，不冒充对齐）：官方 `DocumentScannerActivity` 的
// **边缘检测/自动裁边/OCR**（APK 里带 Google MLKit：`mlkit_vision_text_common`）。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/drive/drive_scan_page.dart';

final _png = // 1x1 PNG（足以让 `Image.file` 解码）
    <int>[
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0x00,
      0x00,
      0x00,
      0x0D,
      0x49,
      0x48,
      0x44,
      0x52,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x08,
      0x06,
      0x00,
      0x00,
      0x00,
      0x1F,
      0x15,
      0xC4,
      0x89,
      0x00,
      0x00,
      0x00,
      0x0A,
      0x49,
      0x44,
      0x41,
      0x54,
      0x78,
      0x9C,
      0x63,
      0x00,
      0x01,
      0x00,
      0x00,
      0x05,
      0x00,
      0x01,
      0x0D,
      0x0A,
      0x2D,
      0xB4,
      0x00,
      0x00,
      0x00,
      0x00,
      0x49,
      0x45,
      0x4E,
      0x44,
      0xAE,
      0x42,
      0x60,
      0x82,
    ];

/// 造 n 张"已导入的页"（真实临时文件，页面里 `Image.file` 能解码）。
List<File> _pages(int n) {
  final dir = Directory.systemTemp.createTempSync('d37_scan_');
  return [
    for (var i = 0; i < n; i++)
      File('${dir.path}/page$i.png')..writeAsBytesSync(_png),
  ];
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required List<File> camera,
  required List<File> gallery,
}) async {
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      scanPagePickerProvider.overrideWithValue(
        (source) async =>
            source == ScanPageSource.gallery ? gallery : camera,
      ),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: const DriveScanPage(folderId: '77'),
      ),
    ),
  );
  await tester.pump();
  return c;
}

/// 页缩略图的 key 形如 `drive-scan-page-page0.png`
/// （页角按钮是 `drive-scan-page-left-0` 等 ⇒ 只认**文件名**那一种）。
final _pageKey = RegExp(r'^drive-scan-page-page\d+\.png$');

bool _isPageWidget(Widget w) =>
    w.key is ValueKey<String> &&
    _pageKey.hasMatch((w.key as ValueKey<String>).value);

int _pageCount(WidgetTester tester) =>
    tester.widgetList(find.byWidgetPredicate(_isPageWidget)).length;

List<String> _pageOrder(WidgetTester tester) => tester
    .widgetList(find.byWidgetPredicate(_isPageWidget))
    .map((w) => (w.key as ValueKey<String>).value)
    .toList();

void main() {
  testWidgets('相册导入：一次多选全部加进来', (tester) async {
    final gal = _pages(3);
    await _pump(tester, camera: const [], gallery: gal);
    expect(_pageCount(tester), 0, reason: '初始没有页');

    await tester.tap(find.byKey(const Key('drive-scan-gallery')));
    await tester.pump();
    await tester.pump();
    expect(_pageCount(tester), 3);
    expect(find.textContaining('3'), findsWidgets);
  });

  testWidgets('拍照：走相机出口（一次一页）', (tester) async {
    final shot = _pages(1);
    await _pump(tester, camera: shot, gallery: const []);
    await tester.tap(find.byKey(const Key('drive-scan-capture')));
    await tester.pump();
    await tester.pump();
    expect(_pageCount(tester), 1);
  });

  testWidgets('逐页审阅：移序与删除（官方扫描器有页管理）', (tester) async {
    final gal = _pages(3);
    await _pump(tester, camera: const [], gallery: gal);
    await tester.tap(find.byKey(const Key('drive-scan-gallery')));
    await tester.pump();
    await tester.pump();
    final before = _pageOrder(tester);
    expect(before, hasLength(3));

    // 把第 3 页前移两次 ⇒ 到最前
    await tester.tap(find.byKey(const Key('drive-scan-page-left-2')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('drive-scan-page-left-1')));
    await tester.pump();
    final after = _pageOrder(tester);
    expect(after.first, before[2], reason: '第 3 页应移到最前');

    // 删除当前第 1 页
    await tester.tap(find.byKey(const Key('drive-scan-page-remove-0')));
    await tester.pump();
    expect(_pageCount(tester), 2);
    expect(_pageOrder(tester), after.sublist(1));

    // 第一页的"前移"按钮是禁用的（不该越界）
    final left = tester.widget<IconButton>(
      find.descendant(
        of: find.byKey(const Key('drive-scan-page-left-0')),
        matching: find.byType(IconButton),
      ),
    );
    expect(left.onPressed, isNull);
  });

  testWidgets('没有页就上传 ⇒ 明确报错，**不发上传**', (tester) async {
    await _pump(tester, camera: const [], gallery: const []);
    await tester.tap(find.byKey(const Key('drive-scan-upload')));
    await tester.pump();
    expect(find.byKey(const Key('drive-scan-error')), findsOneWidget);
    expect(find.byKey(const Key('drive-scan-saved')), findsNothing);
  });

  testWidgets('删光所有页 ⇒ 清掉"已保存"提示（不留下过时结论）', (tester) async {
    final gal = _pages(1);
    await _pump(tester, camera: const [], gallery: gal);
    await tester.tap(find.byKey(const Key('drive-scan-gallery')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('drive-scan-page-remove-0')));
    await tester.pump();
    expect(_pageCount(tester), 0);
    expect(find.byKey(const Key('drive-scan-saved')), findsNothing);
  });
}
