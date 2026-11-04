// 「不要把假文件交给系统应用打开」这条规矩的钉子。
//
// 背景（用户提的）：本机（mac）跑测试时，测试用的假文件如果真交给系统，
// 就是 Preview / QuickTime 弹出来报错。所以：
//   * `flutter test` 进程里 `FLUTTER_TEST` 存在 → 所有"系统打开/开浏览器"
//     的默认实现都 must no-op；
//   * 需要断言"到底开没开"的地方，用 provider / 参数注入假实现。
//
// 这里同时钉住"注入点真的接上了"：`file_preview_page` 的「下载并打开」走
// `systemOpenProvider`，覆盖成假的就能看到调用、且**不会**碰真实实现。
//
// ignore_for_file: avoid_manual_injections
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_filex/open_filex.dart';
import 'package:synhub/src/core/system_open.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/chat/media_stream.dart';

void main() {
  test('flutter test 进程里 isTestEnvironment 为真（FLUTTER_TEST 由 tool 注入）', () {
    expect(isTestEnvironment, isTrue);
  });

  test('默认实现：测试环境直接 no-op，绝不调 open_filex', () async {
    // 路径是随便编的"假文件"：真要交给系统打开，mac 上就会弹报错
    final r = await defaultSystemOpen('/tmp/definitely-not-a-real-file.pdf');
    expect(r.type, ResultType.done);
    expect(r.message, 'test-noop');
  });

  test('注入点可以换成假的（记录调用的那种）', () async {
    final container = ProviderContainer(
      overrides: [
        systemOpenProvider.overrideWithValue((path) async {
          calls.add(path);
          return OpenResult(type: ResultType.done);
        }),
      ],
    );
    addTearDown(container.dispose);
    calls.clear();
    await container.read(systemOpenProvider)('/tmp/fake.png');
    expect(calls, ['/tmp/fake.png']);
  });

  test('媒体直链的"外部打开"回归：测试环境不发 url_launcher', () async {
    // 非 Android 分支会走 `_launchExternally`；测试环境必须直接 false，
    // 不能去开浏览器/播放器
    expect(
      await defaultMediaStreamOpener('http://nas/x.mp4', 'video/mp4'),
      isFalse,
    );
  });

  group('本地文件外部打开的 MIME（.mkv 被 InstallStart 接走的根）', () {
    test('.mkv 给真实视频 MIME，不是 `*/*`', () {
      // open_filex 的内置表没有 mkv → default 回 `*/*`，真机（HONOR/API 31）
      // 会把它解析到 com.android.packageinstaller/.InstallStart（不弹选择器）。
      // 显式给 video/x-matroska 才和 .mp4 一样走系统选择器。
      expect(externalOpenMimeOf('/tmp/theora.mkv'), 'video/x-matroska');
      expect(externalOpenMimeOf('/tmp/clip-h264.mp4'), 'video/mp4');
      expect(externalOpenMimeOf('/tmp/a.webm'), 'video/webm');
      expect(externalOpenMimeOf('/tmp/song.flac'), 'audio/flac');
      expect(externalOpenMimeOf('/tmp/probe-inline.pdf'), 'application/pdf');
    });

    test('认不出来的扩展名才回 `*/*`', () {
      expect(externalOpenMimeOf('/tmp/no-extension'), '*/*');
      expect(externalOpenMimeOf('/tmp/weird.zzz'), '*/*');
    });

    test('`viewLocal` 的 MIME 来自这个纯函数（Android 侧不再猜）', () {
      // 断言意图的 type 字段：桥收到的 mime 就是上面这个值
      // （原生 `MediaOpenBridge.viewLocal` 用它 setDataAndType）
      expect(
        <String, String>{
          'mime': externalOpenMimeOf('/tmp/theora.mkv'),
          'path': '/tmp/theora.mkv',
        }['mime'],
        'video/x-matroska',
      );
    });
  });

  testWidgets('「下载并打开」走的是可注入的 systemOpenProvider（不会碰真实实现）', (tester) async {
    // 用最小部件验证接线：点了按钮 → 记录到假实现
    final recorded = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          systemOpenProvider.overrideWithValue((path) async {
            recorded.add(path);
            return OpenResult(type: ResultType.done);
          }),
        ],
        child: MaterialApp(theme: AppTheme.dark(), 
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  await ref.read(systemOpenProvider)('/tmp/fake-download.docx');
                },
                child: const Text('下载并打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('下载并打开'));
    await tester.pumpAndSettle();
    expect(recorded, ['/tmp/fake-download.docx']);
  });
  group('r295 桌面外部打开的退出码判据（纯函数 ⇒ 任意宿主都能测）', () {
    test('Windows：`explorer` 回 1 也算成功（真桌面确实开了新窗口）', () {
      expect(desktopOpenExitIsSuccess(isWindows: true, exitCode: 0), isTrue);
      expect(
        desktopOpenExitIsSuccess(isWindows: true, exitCode: 1),
        isTrue,
        reason:
            '★ 真 Windows VM 实测：`explorer <目录>` 返回 1，而 '
            '`CabinetWClass` 窗口数 3 → 4、标题是目标目录 ⇒ '
            '退出码不是成功信号（原判据把它报成 desktop-open-exit-1）',
      );
      expect(desktopOpenExitIsSuccess(isWindows: true, exitCode: 2), isFalse);
    });

    test('非 Windows：只认 0（成对断言：放宽不波及 open / xdg-open）', () {
      expect(desktopOpenExitIsSuccess(isWindows: false, exitCode: 0), isTrue);
      expect(
        desktopOpenExitIsSuccess(isWindows: false, exitCode: 1),
        isFalse,
        reason: '★ macOS/Linux 的启动器失败确实给非 0，不许顺手放宽',
      );
    });
  });
}

final calls = <String>[];
