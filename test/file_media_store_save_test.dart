// M68（审计行 220）：把已下载的文件**导出到系统「下载」目录**的测试。
//
// ## 用户可见的缺口（原话）
// > "下载的文件用户找不到、传不出去"
//
// 根因：下载落在 `<应用文档>/downloads`（**应用私有目录**），
// 系统「文件」App 看不到。修法：`MediaStore.Downloads` 导出（Android 10+ 免权限）。
//
// 本组覆盖两层：
//   * **接口层** `mediaStore_save.dart`：MIME 推断、通道往返、三种失败降级；
//   * **页面层**：下载任务行上的「存到系统「下载」」按钮真的调用桥、真的给提示。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/app_platform.dart';

import 'package:synhub/src/features/files/file_download_resume.dart';
import 'package:synhub/src/features/files/file_download_tasks.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/files/media_store_save.dart';

// ---------------------------------------------------------------- 假件

/// 假桥：记录每次调用，可指定返回什么。
class _FakeSaver implements MediaStoreSaver {
  _FakeSaver({this.supported = true, MediaStoreSaveResult? result})
    : result = result ?? const MediaStoreSaveResult.saved('content://dl/1');

  final bool supported;
  MediaStoreSaveResult result;

  final List<({String path, String name, String mime})> calls = [];

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<MediaStoreSaveResult> saveToDownloads({
    required String sourcePath,
    required String name,
    String mimeType = 'application/octet-stream',
  }) async {
    calls.add((path: sourcePath, name: name, mime: mimeType));
    return result;
  }
}

class _Controlled {
  final completer = Completer<FileDownloadOutcome>();

  FileDownloadRunner get runner =>
      (path, {required session}) => completer.future;
}

FileDownloadOutcome _done(String path) =>
    FileDownloadOutcome(localPath: path, totalBytes: 8);

void main() {
  // ★ 第 55 轮：这些用例验证的是**桥被调用时发什么载荷**（Android 语义），
  //   而能力层在 macOS 宿主上会正确地拦住 Android-only 桥 ⇒ 先把门打开
  //   （反向验证：门打开时确实去碰通道；见 `platform_capability_test.dart`）。
  setUp(() => debugForceCapabilityGate = true);
  tearDown(() => debugForceCapabilityGate = false);
  // =====================================================================
  // 接口层
  // =====================================================================
  group('M68-1. 接口层：MIME 推断', () {
    test('常见类型逐个对上（写错 MIME 会被系统归到"其他"，用户照样难找）', () {
      expect(mediaStoreMimeForName('a.pdf'), 'application/pdf');
      expect(mediaStoreMimeForName('a.TXT'), 'text/plain');
      expect(mediaStoreMimeForName('a.csv'), 'text/csv');
      expect(mediaStoreMimeForName('a.zip'), 'application/zip');
      expect(mediaStoreMimeForName('a.7z'), 'application/x-7z-compressed');
      expect(mediaStoreMimeForName('a.rar'), 'application/vnd.rar');
      expect(mediaStoreMimeForName('a.docx'), contains('wordprocessingml'));
      expect(mediaStoreMimeForName('a.xlsx'), contains('spreadsheetml'));
      expect(mediaStoreMimeForName('a.pptx'), contains('presentationml'));
      expect(mediaStoreMimeForName('a.jpg'), 'image/jpeg');
      expect(mediaStoreMimeForName('a.PNG'), 'image/png');
      expect(mediaStoreMimeForName('a.mp3'), 'audio/mpeg');
      expect(mediaStoreMimeForName('a.mp4'), 'video/mp4');
      expect(mediaStoreMimeForName('a.epub'), 'application/epub+zip');
    });

    test('无扩展名 / 未知扩展名 / 结尾是点 ⇒ 退回 octet-stream（不猜错）', () {
      expect(mediaStoreMimeForName('README'), 'application/octet-stream');
      expect(mediaStoreMimeForName('a.weird'), 'application/octet-stream');
      expect(mediaStoreMimeForName('a.'), 'application/octet-stream');
      expect(mediaStoreMimeForName('.gitignore'), 'application/octet-stream');
    });
  });

  group('M68-2. 接口层：通道往返与降级', () {
    const channel = MethodChannel(MethodChannelMediaStoreSaver.channelName);
    late List<MethodCall> log;

    setUp(() {
      log = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            log.add(call);
            switch (call.method) {
              case 'isSupported':
                return true;
              case 'saveToDownloads':
                return 'content://media/external/downloads/42';
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('成功：把 path/name/mimeType 三个参数逐字传下去，并回带 URI', () async {
      final saver = MethodChannelMediaStoreSaver();
      final r = await saver.saveToDownloads(
        sourcePath: '/data/app/files/downloads/报告.pdf',
        name: '报告.pdf',
        mimeType: 'application/pdf',
      );
      expect(r.ok, isTrue);
      expect(r.uri, 'content://media/external/downloads/42');
      expect(log.single.method, 'saveToDownloads');
      expect(log.single.arguments, {
        'path': '/data/app/files/downloads/报告.pdf',
        'name': '报告.pdf',
        'mimeType': 'application/pdf',
      });
    });

    test('平台回 null / 空串 ⇒ failed（不是 unsupported，两者提示文案不同）', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
      final r = await MethodChannelMediaStoreSaver().saveToDownloads(
        sourcePath: '/x',
        name: 'x',
      );
      expect(r.ok, isFalse);
      expect(r.unsupported, isFalse, reason: '这是"失败"，不是"不支持"');
    });

    test(
      '平台抛 PlatformException ⇒ failed；抛 MissingPluginException ⇒ unsupported',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              throw PlatformException(code: 'save_failed');
            });
        var r = await MethodChannelMediaStoreSaver().saveToDownloads(
          sourcePath: '/x',
          name: 'x',
        );
        expect(r.unsupported, isFalse);
        expect(r.ok, isFalse);

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              throw MissingPluginException('no impl');
            });
        r = await MethodChannelMediaStoreSaver().saveToDownloads(
          sourcePath: '/x',
          name: 'x',
        );
        expect(r.unsupported, isTrue, reason: '桌面/测试/未注册 ⇒ 降级成"不支持"');
        expect(r.ok, isFalse);
      },
    );

    test('isSupported：平台没实现一律 false（不抛异常）', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw MissingPluginException('no impl');
          });
      expect(await MethodChannelMediaStoreSaver().isSupported(), isFalse);
    });
  });

  // =====================================================================
  // 页面层
  // =====================================================================
  group('M68-3. 页面层：下载任务行上的「存到系统「下载」」', () {
    Future<FileDownloadTaskList> pumpDone(
      WidgetTester tester,
      _FakeSaver saver, {
      String name = '报告.pdf',
      String localPath = '/d/报告.pdf',
    }) async {
      final c = _Controlled();
      final list = FileDownloadTaskList();
      addTearDown(list.dispose);
      list.start(sourcePath: '/v/$name', name: name, runner: c.runner);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [mediaStoreSaverProvider.overrideWithValue(saver)],
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: FileDownloadTasksDialog(
                controller: list,
                openHandler: (_) async {},
                onClose: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      c.completer.complete(_done(localPath));
      await tester.pump();
      await tester.pump();
      return list;
    }

    testWidgets('P1. 完成的任务出现该按钮；点了真的把 path/name/MIME 传给桥，并提示成功', (
      tester,
    ) async {
      final saver = _FakeSaver();
      await pumpDone(tester, saver);

      final btn = find.byKey(const ValueKey('download-task-save-dl-0'));
      expect(btn, findsOneWidget, reason: '下载完就该能导出到公共下载目录');

      await tester.tap(btn);
      await tester.pumpAndSettle();

      expect(saver.calls, hasLength(1));
      expect(saver.calls.single.path, '/d/报告.pdf');
      expect(saver.calls.single.name, '报告.pdf');
      expect(saver.calls.single.mime, 'application/pdf');
      expect(
        find.text(fileDownloadTaskSaveOk()),
        findsOneWidget,
        reason: '必须给一句"去哪找"的人话',
      );
    });

    testWidgets('P2. 平台不支持 ⇒ 提示"不支持"，**不是**"失败"', (tester) async {
      final saver = _FakeSaver(
        supported: false,
        result: const MediaStoreSaveResult.unsupported(),
      );
      await pumpDone(tester, saver);
      await tester.tap(find.byKey(const ValueKey('download-task-save-dl-0')));
      await tester.pumpAndSettle();
      expect(find.text(fileDownloadTaskSaveUnsupported()), findsOneWidget);
      expect(find.text(fileDownloadTaskSaveFailed()), findsNothing);
    });

    testWidgets('P3. 系统拒绝 ⇒ 提示"失败"（与"不支持"区分开）', (tester) async {
      final saver = _FakeSaver(result: const MediaStoreSaveResult.failed());
      await pumpDone(tester, saver);
      await tester.tap(find.byKey(const ValueKey('download-task-save-dl-0')));
      await tester.pumpAndSettle();
      expect(find.text(fileDownloadTaskSaveFailed()), findsOneWidget);
      expect(find.text(fileDownloadTaskSaveUnsupported()), findsNothing);
    });

    testWidgets('P4. 未完成的任务**没有**这个按钮（没文件可导）', (tester) async {
      final saver = _FakeSaver();
      final c = _Controlled();
      final list = FileDownloadTaskList();
      addTearDown(list.dispose);
      list.start(sourcePath: '/v/a.bin', name: 'a.bin', runner: c.runner);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [mediaStoreSaverProvider.overrideWithValue(saver)],
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: FileDownloadTasksDialog(
                controller: list,
                openHandler: (_) async {},
                onClose: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('download-task-save-dl-0')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('download-task-open-dl-0')),
        findsNothing,
      );
    });
  });

  // =====================================================================
  // 平台契约守卫：Dart 侧通道名/方法名与 Kotlin 侧必须逐字一致
  // =====================================================================
  group('M68-4. 平台契约（改一处必须改两处）', () {
    test('通道名与 Kotlin `MediaStoreBridge.CHANNEL` 逐字一致', () {
      expect(
        MethodChannelMediaStoreSaver.channelName,
        'synhub/mediastore',
      );
    });

    test('Kotlin 源码里确实注册了同名通道与两个方法（防"只改了 Dart"）', () {
      final kt = File(
        'android/app/src/main/kotlin/com/openviewai/synhub/MediaStoreBridge.kt',
      ).readAsStringSync();
      expect(kt, contains('"synhub/mediastore"'));
      expect(kt, contains('"saveToDownloads"'));
      expect(kt, contains('"isSupported"'));
      // API 29+ 走 MediaStore，且用 IS_PENDING 保证"写完整才可见"。
      expect(kt, contains('MediaStore.Downloads.EXTERNAL_CONTENT_URI'));
      expect(kt, contains('MediaStore.Downloads.IS_PENDING'));
      final activity = File(
        'android/app/src/main/kotlin/com/openviewai/synhub/MainActivity.kt',
      ).readAsStringSync();
      expect(
        activity,
        contains('MediaStoreBridge.attach'),
        reason: '桥必须真的注册进 FlutterEngine，否则运行期永远是 MissingPlugin',
      );
    });
  });
}
