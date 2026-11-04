// r709 · guest 探针：Windows **本地通知**真发一条 toast 并读回结论。
//
// 为什么要有这一份：
//   能力位翻不翻只认**消费方读数**（AGENTS：只改代码不验证 = 假绿）。
//   单测只能证"参数怎么拼"，证不了"系统真弹出来了"。这台探针在 guest 上跑：
//     ① 用**真实安装位置**（`…\WindowsApps\<PFN 目录>\synhub.exe`）推导 AUMID；
//     ② 真起 `powershell.exe` 发 toast；
//     ③ 再取一次**当前注册的 AUMID 列表**（`Get-StartApps`）核对推导值在不在里面
//        —— 这一条挡住"拼出来的 AUMID 根本没人注册"的假绿。
//
// 跑法（guest 上，工程根目录）：
//   C:\src\flutter\bin\cache\dart-sdk\bin\dart.exe run tool\probe\windows_toast_probe.dart
// 可选参数：`--exe <安装位置>`、`--app-id <AppId>`、`--no-send`（只推导不发）。
//
// 这个文件**不 import flutter**，纯 `dart:io`，所以 `dart run` 就能跑。
import 'dart:async';
import 'dart:io';

import 'package:synhub/src/core/platform/desktop_notify_windows.dart';

String? _aumidForHistory;

Future<void> main(List<String> argv) async {
  final exeArg = _arg(argv, '--exe');
  final appId = _arg(argv, '--app-id') ?? 'synhub';
  final send = !argv.contains('--no-send');

  // ① 安装位置：显式不给就自己找（`Get-AppxPackage` 的 InstallLocation）
  var exe = exeArg;
  if (exe == null) {
    final r = await Process.run('powershell.exe', <String>[
      '-NoProfile',
      '-Command',
      r'$p = Get-AppxPackage -Name "com.flutter.synhub"; if ($p) { Join-Path $p.InstallLocation "synhub.exe" }',
    ]);
    exe = '${r.stdout}'.trim();
    if (exe.isEmpty) {
      stdout.writeln('READING exe=<none>  ⇒ 没装 MSIX，探针无事可做');
      exit(2);
    }
  }
  stdout.writeln('READING exe=$exe  exists=${File(exe).existsSync()}');

  // ①b 历史读数（操作中心里的持久条目）：`History.GetHistory(aumid)` 的条数与首行文字
  Future<void> history(String tag) async {
    final r = await Process.run(
      'powershell.exe',
      <String>[
        '-NoProfile',
        '-Command',
        r'[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null;'
            r'$h = [Windows.UI.Notifications.ToastNotificationManager]::History.GetHistory($env:SYNHUB_TOAST_APPID);'
            r'"count=" + $h.Count;'
            r'foreach ($t in $h) { "text=" + $t.Content.GetElementsByTagName("text").Item(0).InnerText }',
      ],
      environment: <String, String>{
        'SYNHUB_TOAST_APPID': _aumidForHistory ?? '',
      },
    );
    final out = '${r.stdout}'.trim().replaceAll(RegExp(r'\s*\n\s*'), ' | ');
    stdout.writeln(
      'READING history[$tag]=${out.replaceAll(RegExp(r"\r?\n"), " | ")}',
    );
  }

  // ★ r710：`--channel/--thread` 直接拼出与 App 完全一致的 Tag/Group（省掉命令行里的
  //   花括号与引号 —— cmd 对 `{"a":1}` 这种参数很挑，r710 实测会被吃掉）。
  //   **这段必须放在 `--remove-tag` 之前**：第一次放在④里，结果 `--remove-tag`
  //   拿到的是 null ⇒ 走成 `History.Clear`（"全清"冒充"按条撤"）＝假绿。
  final ch = int.tryParse(_arg(argv, '--channel') ?? '');
  final th = int.tryParse(_arg(argv, '--thread') ?? '') ?? 0;
  final tag =
      _arg(argv, '--tag') ??
      (ch == null ? null : '{"channel_id":$ch,"thread_id":$th}');
  final group = _arg(argv, '--group') ?? (ch == null ? null : 'ch$ch');
  stdout.writeln('READING tag=${tag ?? "(none)"} group=${group ?? "(none)"}');

  // ② 推导 AUMID（真代码路径）
  final aumid = windowsToastAumid(exePath: exe, appId: appId);
  stdout.writeln('READING derived_aumid=$aumid');
  if (aumid == null) {
    stdout.writeln('VERDICT derived=null ⇒ 免安装形态（能力位应为未实现）');
    exit(3);
  }

  // ②b `--remove-tag`：按 tag 撤一条（r710 的 `cancelTag` 落地形态）
  if (argv.contains('--remove-tag')) {
    final n0 = WindowsDesktopNotifier(aumid: aumid);
    final ok = await n0.remove(tag: tag, group: group);
    stdout.writeln('READING remove_tag=$ok  tag=${tag ?? "(none)"}');
    await Future<void>.delayed(const Duration(seconds: 1));
    _aumidForHistory = aumid;
    await history('after_remove_tag');
    stdout.writeln('VERDICT removed=$ok');
    exit(ok ? 0 : 7);
  }

  // ③ 注册表核对：推导出来的 AUMID 必须真的在 Start 菜单的 AppID 列表里
  final reg = await Process.run('powershell.exe', <String>[
    '-NoProfile',
    '-Command',
    r'Get-StartApps | ForEach-Object { $_.AppID }',
  ]);
  final ids = '${reg.stdout}'
      .split(RegExp(r'\r?\n'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  final registered = ids.contains(aumid);
  stdout.writeln(
    'READING registered=$registered  total_appids=${ids.length}'
    '  match=${ids.where((e) => e == aumid).join(",")}',
  );

  _aumidForHistory = aumid;
  await history('before');

  if (argv.contains('--clear')) {
    final n0 = WindowsDesktopNotifier(aumid: aumid);
    final ok = await n0.clearAll();
    stdout.writeln('READING clearAll=$ok');
    await Future<void>.delayed(const Duration(seconds: 1));
    await history('after');
    stdout.writeln('VERDICT cleared=$ok');
    exit(ok ? 0 : 6);
  }

  if (!send) {
    stdout.writeln('VERDICT no-send 模式，结束');
    exit(registered ? 0 : 4);
  }

  // ④ 真发一条（走的就是 App 里那条路：`WindowsDesktopNotifier.show`）
  final n = WindowsDesktopNotifier(aumid: aumid);
  final ok = await n.show(
    title: _arg(argv, '--title') ?? 'SynHub · r709 探针',
    body: '这是一条来自 SynHub 的 Windows 本地通知（AUMID=$aumid）',
    appName: 'SynHub',
    tag: tag,
    group: group,
  );
  stdout.writeln(
    'READING show_exit_ok=$ok  tag=${tag ?? "(none)"}  group=${group ?? "(none)"}',
  );
  if (!ok) {
    stdout.writeln('VERDICT show=false ⇒ 不许翻能力位');
    exit(5);
  }

  // ⑤ 等两秒，让通知横幅出来（消费方读数由外层截屏取）
  await Future<void>.delayed(const Duration(seconds: 2));
  stdout.writeln('VERDICT toast_sent aumid=$aumid registered=$registered');
}

/// 取 `--key value` 形式的参数（没有就 null）。
String? _arg(List<String> argv, String key) {
  final i = argv.indexOf(key);
  if (i < 0 || i + 1 >= argv.length) return null;
  return argv[i + 1];
}
