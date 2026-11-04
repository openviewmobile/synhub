// r284：**macOS 真像素**——文件 / Drive 模块的「宽屏双栏」vs「窄屏单列」。
//
// ## 为什么是这条路（沿用 r131/r279 的既有取证口径，不另造一套）
//   * 宿主没有 Screen Recording / Accessibility 的 TCC 授权 ⇒
//     `screencapture` / `osascript`(System Events) 都不可用；TCC 不许绕过。
//   * 用 **应用内自渲染**：`RenderRepaintBoundary.toImage(pixelRatio: 2.0)`
//     （与 `integration_test/macos_ui_audit_test.dart` 同一手法），落盘到
//     App 沙箱容器的 `tmp/r284_macos_files/`（沙箱不许写 `/tmp`）。
//   * **窗口逻辑尺寸是真的**：`macos/Runner/MainFlutterWindow.swift` 新增了
//     `SYNHUB_WINDOW_SIZE=WxH` 环境变量钩子（缺省不生效），本脚本按阶段设
//     1280×860（宽屏）与 420×900（窄屏）—— 不是 `setSurfaceSize` 合成的尺寸。
//   * 断言全部钉**机制量**：`file-wide-region` 在不在树里、两栏矩形的 x 关系。
//
// ## 只读纪律（AGENTS §5.1）
//   对真 NAS 只有：`SYNO.API.Info:query`（discover）、`login`、
//   `FileStation.List:list|list_share`、`SynologyDrive.Files:list`。
//   **没有**任何 set/delete/create/update/upload/rename 动词。
//
// 用法（见 tool/r284_macos_files.sh）：
//   SYNHUB_WINDOW_SIZE=1280x860 flutter test -d macos \
//     integration_test/r284_macos_files_panes_test.dart \
//     --dart-define=R284_PHASE=wide --dart-define=SYNO_NAS_URL=…
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/drive_providers.dart';
import 'package:synhub/src/features/files/file_browse_page.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/files/file_row.dart' show FileRow;

const String _url = String.fromEnvironment(
  'SYNO_NAS_URL',
  defaultValue: 'https://nas.example.com:5001',
);
const String _account = String.fromEnvironment(
  'SYNO_NAS_ACCOUNT',
  defaultValue: 'demo_user',
);
const String _password = String.fromEnvironment(
  'SYNO_NAS_PASSWORD',
  defaultValue: '', // 用 --dart-define=SYNO_NAS_PASSWORD=… 提供
);

/// `wide` = 宽屏双栏；`narrow` = 窄屏单列。
const String _phase = String.fromEnvironment(
  'R284_PHASE',
  defaultValue: 'wide',
);

final Directory _shotDir = Directory(
  '${Directory.systemTemp.path}/r284_macos_files',
)..createSync(recursive: true);

final GlobalKey _rootKey = GlobalKey(debugLabel: 'r284-root');

void _note(String s) => debugPrint('[r284] $s');

/// 推帧 + 真实等待（页面有常驻动画 ⇒ 不能用 pumpAndSettle）。
Future<void> _wait(WidgetTester tester, [int ms = 400]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 32));
    await Future<void>.delayed(const Duration(milliseconds: 32));
  }
}

/// 抓一张真实渲染像素图（超时只丢这一张，不拖死整轮 —— r131 的坑）。
Future<bool> _shot(WidgetTester tester, String name) async {
  await _wait(tester, 500);
  final ro = _rootKey.currentContext?.findRenderObject();
  if (ro is! RenderRepaintBoundary) {
    _note('SHOT-FAIL $name :: 没有 RepaintBoundary');
    return false;
  }
  var ok = false;
  await tester.runAsync(() async {
    try {
      final img = await ro
          .toImage(pixelRatio: 2.0)
          .timeout(const Duration(seconds: 30));
      final bd = await img
          .toByteData(format: ui.ImageByteFormat.png)
          .timeout(const Duration(seconds: 30));
      File('${_shotDir.path}/$name.png')
          .writeAsBytesSync(bd!.buffer.asUint8List());
      // 同时把"这张图对应的窗口逻辑尺寸"记在旁边（台账要注明逻辑尺寸）。
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      File('${_shotDir.path}/$name.size.txt').writeAsStringSync(
        'windowLogical=${size.width.toStringAsFixed(1)}x'
        '${size.height.toStringAsFixed(1)}\n'
        'image=${img.width}x${img.height}\n'
        'phase=$_phase\n',
      );
      _note(
        'SHOT $name (${img.width}x${img.height}) 窗口逻辑 '
        '${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)}',
      );
      ok = true;
    } catch (e) {
      _note('SHOT-FAIL $name :: $e');
    }
  });
  return ok;
}

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('r284 macOS 文件/Drive 宽窄窗口真像素（phase=$_phase）', (tester) async {
    _note('截图目录 = ${_shotDir.path}');
    _note('目标 NAS = $_url  阶段 = $_phase');

    // ---- 真 NAS 只读会话（discover + login；无任何写动词）----
    final api = DsmWebApi(
      DirectTransport.url(
        _url,
        dio: DioFactory.create(allowSelfSigned: true),
      ),
    );
    await api.discover();
    final session = await api.login(account: _account, password: _password);
    _note('login sid=${session.sid.length} 位');
    expect(
      session.sid.isNotEmpty,
      isTrue,
      reason: '真 NAS 登录失败 ⇒ 本屏只能记「未拍」',
    );

    final db = ChatDatabase(NativeDatabase.memory());
    final c = ProviderContainer(
      overrides: [
        chatDatabaseProvider.overrideWithValue(db),
        fileApiProvider.overrideWithValue(FileStationApi(api)),
        driveApiProvider.overrideWithValue(DriveApi(api)),
      ],
    );
    addTearDown(() {
      c.dispose();
      db.close();
      api.transport.close();
    });

    // ★ 渲染视口尺寸（真机逻辑点）：本机没有 Screen Recording / Accessibility
    //   的 TCC 授权 ⇒ `osascript` 改不了 OS 窗口尺寸。两条都做，互不冲突：
    //   ① `macos/Runner/MainFlutterWindow.swift` 的 `SYNHUB_WINDOW_SIZE` 钩子
    //      （真正改 OS 窗口；生效与否由 `r284_window_hook.txt` 如实记录）；
    //   ② 这里把**框架渲染视口**设成同一尺寸 —— 这是本用例断言与出图所依赖的
    //      那一个尺寸（`MediaQuery` 读的就是 `View.of(context)`）。
    final logical = _phase == 'narrow'
        ? const Size(420, 900)
        : const Size(1280, 860);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = logical;
    addTearDown(tester.view.reset);
    _note('渲染视口逻辑尺寸（设定值）= ${logical.width}x${logical.height}');

    await tester.pumpWidget(
      RepaintBoundary(
        key: _rootKey,
        child: UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: FileBrowsePage(initialPath: '/home')),
        ),
      ),
    );
    // 等真 NAS 的目录列表回来（首帧 + 网络）。
    await _wait(tester, 4000);

    final windowSize = tester.view.physicalSize / tester.view.devicePixelRatio;
    _note(
      '真实窗口逻辑尺寸 = ${windowSize.width.toStringAsFixed(0)}x'
      '${windowSize.height.toStringAsFixed(0)}',
    );
    _note('分级 = ${windowSize.width < 600 ? 'compact' : (windowSize.width < 840 ? 'medium' : 'expanded')}');

    if (_phase == 'narrow') {
      // ---- 窄屏：单列（右栏**不许在树里**）----
      expect(
        find.byKey(const Key('file-wide-region')),
        findsNothing,
        reason: '窄屏（${windowSize.width.toStringAsFixed(0)}dp）右栏不许进树',
      );
      expect(find.byKey(const Key('file-wide-master')), findsOneWidget);
      expect(find.byType(FileRow), findsWidgets, reason: '真 NAS 的目录列表要有行');
      await _shot(tester, 'r284_files_narrow_single_column');
      return;
    }

    // ---- 宽屏：双栏 ----
    expect(
      find.byKey(const Key('file-wide-region')),
      findsOneWidget,
      reason: '宽屏（${windowSize.width.toStringAsFixed(0)}dp）必须并排右栏',
    );
    final mr = tester.getRect(find.byKey(const Key('file-wide-master')));
    final dr = tester.getRect(find.byKey(const Key('file-wide-region')));
    _note(
      '左栏=${mr.left.toStringAsFixed(0)},${mr.top.toStringAsFixed(0)} '
      '${mr.width.toStringAsFixed(0)}x${mr.height.toStringAsFixed(0)}  '
      '右栏=${dr.left.toStringAsFixed(0)},${dr.top.toStringAsFixed(0)} '
      '${dr.width.toStringAsFixed(0)}x${dr.height.toStringAsFixed(0)}',
    );
    expect(
      dr.left,
      greaterThanOrEqualTo(mr.right - 1),
      reason: '右栏必须在左栏右侧（不重叠）',
    );
    expect(
      find.byKey(const Key('file-wide-empty')),
      findsOneWidget,
      reason: '未选中时右栏应是空态',
    );
    await _shot(tester, 'r284_files_wide_empty_right');

    // 点左栏第一个**目录**行 ⇒ 右栏就地列它的内容（不推路由）
    final dirRow = find.byWidgetPredicate((w) => w is FileRow && w.entry.isDir);
    expect(dirRow, findsWidgets, reason: '/home 里要有目录行');
    await tester.ensureVisible(dirRow.first);
    await _wait(tester, 300);
    await tester.tap(dirRow.first);
    await _wait(tester, 2500);
    expect(
      find.byKey(const Key('file-wide-empty')),
      findsNothing,
      reason: '点目录后右栏应换成该目录的内容',
    );
    await _shot(tester, 'r284_files_wide_two_pane');

    // ---- Drive 源：同样宽屏双栏（Drive 的行是 `_DriveRow` = ListTile）----
    c.read(fileSourceProvider.notifier).select(FileSource.drive);
    await _wait(tester, 5000);
    final dRow = find.byType(ListTile);
    _note('Drive 源左栏行数 = ${dRow.evaluate().length}');
    if (dRow.evaluate().isNotEmpty) {
      await tester.ensureVisible(dRow.first);
      await _wait(tester, 300);
      await tester.tap(dRow.first);
      await _wait(tester, 3000);
    }
    _note(
      'Drive 右栏：empty=${find.byKey(const Key('file-wide-empty')).evaluate().isNotEmpty} '
      'driveList=${find.byKey(const Key('file-wide-drive-list')).evaluate().isNotEmpty} '
      'detail=${find.byKey(const Key('file-wide-detail')).evaluate().isNotEmpty}',
    );
    await _shot(tester, 'r284_drive_wide_two_pane');
  });
}
