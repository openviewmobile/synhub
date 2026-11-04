// r709 · Windows 桌面通知（WinRT toast）的**判据**用例。
//
// 这一份故意**不发真通知**（宿主是 macOS）：它守的是四件事：
//   ① AUMID 推导：只有跑在 `…\WindowsApps\<Name>_<x.y.z.w>_<arch>__<pubId>\` 里
//      才给 AUMID；免安装路径、目录名不合形状**一律 null**（不猜）；
//   ② AUMID 的拼法是 **PackageFamilyName**（去掉版本与架构）`!<appId>`
//      —— 这是 r708 在 guest 上量到的真值
//      （`com.flutter.synhub_fxkeb4dgdm144!synhub`），不是拍脑袋；
//   ③ 能力位只认安装形态：非 Windows 宿主上不允许因为"代码写了"就 available；
//   ④ 发送失败/没有 AUMID 时 `show()` 必须 `false`（fail-closed，不假装成功）。
//
// 真链路的读数在 guest 上（`docs/platform-windows.md` §23 ·
// `docs/evidence-r709-win/`）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/core/platform/desktop_notify_windows.dart';

void main() {
  test('① AUMID 推导：打包态按 PFN+appId 拼，免安装态一律 null（不猜）', () {
    // guest 上量到的真实安装位置（r708）
    const packaged =
        r'C:\Program Files\WindowsApps\com.flutter.synhub_1.0.0.0_x64__fxkeb4dgdm144\synhub.exe';
    expect(
      windowsToastAumid(exePath: packaged),
      'com.flutter.synhub_fxkeb4dgdm144!synhub',
    );
    // 正斜杠也要认（有人从 Dart 侧拼路径）
    expect(
      windowsToastAumid(
        exePath:
            'C:/Program Files/WindowsApps/com.flutter.synhub_1.0.0.0_x64__fxkeb4dgdm144/synhub.exe',
      ),
      'com.flutter.synhub_fxkeb4dgdm144!synhub',
    );
    // appId 可换（别的 target 名）
    expect(
      windowsToastAumid(exePath: packaged, appId: 'other'),
      'com.flutter.synhub_fxkeb4dgdm144!other',
    );

    // 免安装（dev 版）：`build\windows\x64\runner\Release\synhub.exe`
    expect(
      windowsToastAumid(
        exePath:
            r'C:\src\synhub_r703\build\windows\x64\runner\Release\synhub.exe',
      ),
      isNull,
    );
    // 目录名不合 `<Name>_<ver>_<arch>__<pub>` ⇒ null（不拿别的 App 的目录瞎拼）
    expect(
      windowsToastAumid(exePath: r'C:\Program Files\WindowsApps\Weird\a.exe'),
      isNull,
    );
    // 带 arm64 架构也要认（将来 Windows on ARM 原生包）
    expect(
      windowsToastAumid(
        exePath:
            r'C:\Program Files\WindowsApps\com.flutter.synhub_1.0.0.0_arm64__fxkeb4dgdm144\synhub.exe',
      ),
      'com.flutter.synhub_fxkeb4dgdm144!synhub',
    );
  });

  test('② PowerShell 参数：走 -EncodedCommand（UTF-16LE base64），标题不出现在命令行', () {
    final args = powershellArgs(r"Write-Output 'hello'");
    expect(args.first, '-NoProfile');
    expect(args, contains('-EncodedCommand'));
    final b64 = args[args.indexOf('-EncodedCommand') + 1];
    // 解回来必须是**同一段脚本**（UTF-16LE）：这条能挡住"编码写错但看着像成功"
    final bytes = base64.decode(b64);
    expect(bytes.length.isEven, isTrue);
    final units = <int>[
      for (var i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8),
    ];
    expect(String.fromCharCodes(units), r"Write-Output 'hello'");
    // 非 ASCII 也要能往返（中文标题）
    final zh = powershellArgs('写中文');
    final zhBytes = base64.decode(zh[zh.indexOf('-EncodedCommand') + 1]);
    final zhUnits = <int>[
      for (var i = 0; i < zhBytes.length; i += 2)
        zhBytes[i] | (zhBytes[i + 1] << 8),
    ];
    expect(String.fromCharCodes(zhUnits), '写中文');
  });

  test('③ 没有 AUMID ⇒ show/clearAll 都 false，且**不起子进程**', () async {
    var spawned = 0;
    final n = WindowsDesktopNotifier(
      aumid: '',
      run: (exe, args, {environment}) async {
        spawned++;
        return ProcessResult(0, 0, '', '');
      },
    );
    expect(await n.show(title: 't', body: 'b'), isFalse);
    expect(await n.clearAll(), isFalse);
    expect(spawned, 0, reason: '没有 AUMID 就不该浪费一次 PowerShell 启动');
  });

  test('④ 起子进程时：环境变量带 AUMID/标题/正文，退出码非 0 ⇒ false', () async {
    Map<String, String>? seenEnv;
    String? seenScript;
    var rc = 0;
    final n = WindowsDesktopNotifier(
      aumid: 'com.flutter.synhub_fxkeb4dgdm144!synhub',
      run: (exe, args, {environment}) async {
        expect(exe, 'powershell.exe');
        final b64 = args[args.indexOf('-EncodedCommand') + 1];
        final bytes = base64.decode(b64);
        final units = <int>[
          for (var i = 0; i < bytes.length; i += 2)
            bytes[i] | (bytes[i + 1] << 8),
        ];
        seenScript = String.fromCharCodes(units);
        seenEnv = environment;
        return ProcessResult(0, rc, '', '');
      },
    );

    // 宿主是 macOS ⇒ 真实现会先 `Platform.isWindows` 短路；这里要测的是
    // "参数与环境怎么传"，所以用**非空 AUMID** 也不该在 macOS 上真的跑。
    // 结论：在非 Windows 宿主上，即使给了 AUMID 也必须 false（fail-closed）。
    expect(await n.show(title: '标题', body: '正文'), isFalse);
    expect(seenEnv, isNull, reason: '非 Windows 宿主不许起 PowerShell');
    expect(seenScript, isNull);

    // 下面这段只在 Windows 宿主上才有意义；macOS/Linux 上跳过（不假装验过）。
    if (!Platform.isWindows) {
      // ignore: avoid_print
      print('[skip] ④ 的"参数与环境"分支只在 Windows 宿主上执行');
      return;
    }
    rc = 0;
    expect(await n.show(title: '标题', body: '正文'), isTrue);
    expect(
      seenEnv?['SYNHUB_TOAST_APPID'],
      'com.flutter.synhub_fxkeb4dgdm144!synhub',
    );
    expect(seenEnv?['SYNHUB_TOAST_TITLE'], '标题');
    expect(seenEnv?['SYNHUB_TOAST_BODY'], '正文');
    expect(seenScript, contains('CreateToastNotifier'));
    rc = 1;
    expect(await n.show(title: '标题', body: '正文'), isFalse);
    expect(await n.clearAll(), isFalse);
    rc = 0;
    expect(await n.clearAll(), isTrue);
    expect(seenScript, contains('History.Clear'));
  });

  test('⑦ r710：tag/group 进环境变量，且按 tag 撤销走 History.Remove', () async {
    // 只验**参数形状**（真弹/真撤由 guest 上的探针给消费方读数，见 §24）。
    final calls = <({List<String> args, Map<String, String>? env})>[];
    Future<ProcessResult> fake(
      String exe,
      List<String> args, {
      Map<String, String>? environment,
    }) async {
      calls.add((args: args, env: environment));
      return ProcessResult(1, 0, '', '');
    }

    const tag = '{"channel_id":271,"thread_id":9}';
    final n = WindowsDesktopNotifier(aumid: 'pkg_abc!synhub', run: fake);
    // 非 Windows 宿主上一律 false 且不起子进程 —— 这个文件的两条路都要这么判。
    final showed = await n.show(
      title: 't',
      body: 'b',
      tag: tag,
      group: 'ch271',
    );
    final removed = await n.remove(tag: tag, group: 'ch271');
    if (!Platform.isWindows) {
      expect(showed, isFalse);
      expect(removed, isFalse);
      expect(calls, isEmpty, reason: '非 Windows 宿主不许起 PowerShell');
      return;
    }
    expect(showed, isTrue);
    expect(calls.first.env!['SYNHUB_TOAST_TAG'], tag);
    expect(calls.first.env!['SYNHUB_TOAST_GROUP'], 'ch271');
    // 脚本本身要含 Tag 设置与 Remove 调用（否则"撤销"只是换了个壳）
    final showScript = utf8.decode(
      base64.decode(calls.first.args.last),
      allowMalformed: true,
    );
    expect(showScript, contains(r'$toast.Tag = $env:SYNHUB_TOAST_TAG'));
    expect(showScript, contains('History.Remove'));
    final removeScript = utf8.decode(
      base64.decode(calls.last.args.last),
      allowMalformed: true,
    );
    expect(removeScript, contains(r'History.Remove($env:SYNHUB_TOAST_TAG'));
  });

  test('⑤ 能力判据（可注入）：四格真值表，不随测试宿主机变', () {
    const packaged =
        r'C:\Program Files\WindowsApps\com.flutter.synhub_1.0.0.0_x64__fxkeb4dgdm144\synhub.exe';
    const unpackaged =
        r'C:\src\synhub_r703\build\windows\x64\runner\Release\synhub.exe';
    // Windows + 打包态 ⇒ 可用（这是 r709 要翻的那一格）
    expect(windowsToastCapability(exePath: packaged, isWindows: true), isTrue);
    // Windows + 免安装 ⇒ 不可用（AUMID 推导不出来，fail-closed）
    expect(
      windowsToastCapability(exePath: unpackaged, isWindows: true),
      isFalse,
    );
    // 非 Windows 宿主 ⇒ 一律不可用（哪怕路径写成 WindowsApps 形状）
    expect(
      windowsToastCapability(exePath: packaged, isWindows: false),
      isFalse,
    );
  });

  test('⑥ 能力位：非 Windows 宿主上这条能力不许因为"代码写了"就 available', () {
    final caps = staticCapabilitiesFor(AppHost.windows);
    final st = caps.statusOf(AppCapability.localNotifications);
    // 在 macOS 上跑 flutter test 时，`Platform.isWindows` 为 false ⇒ 能力位
    // 必须是"未实现"（这正是 fail-closed 的样子）；真 Windows 宿主上则可用。
    expect(
      st.isAvailable,
      Platform.isWindows,
      reason: 'Windows 宿主=可用，其它宿主=未实现（不许两边都绿）',
    );
  });
}
