// r693 · Linux **桌面通知**（`org.freedesktop.Notifications`）。
//
// 为什么自己写一份：
//   * `flutter_local_notifications` 与 `audio_service` 都**没有 linux 列**，
//     所以这条能力在 Linux 上一直是 `unavailable:not-implemented-on-host`；
//   * 但 Linux 桌面的标准做法是走 D-Bus 的 `org.freedesktop.Notifications`
//     （`notify-send` 就是 libnotify 提供的官方客户端），
//     **不引入新依赖**就能连上（本仓没有 `dbus` 包，用子进程更省）。
//
// 判据（AGENTS §2.0.6 第 3 条"宿主不编事实"）：
//   * 能力位是否可用 **只看 PATH 上有没有那个客户端**，不看"我们有没有写过代码"；
//   * 缺客户端 ⇒ 如实报未实现（面板会说"不可用"），不许假装发出去。
//
// ★ 一个容易骗自己的地方：`notify-send` 在**没有通知守护进程**的容器里也会
//   `exit 0`（它只是把消息丢给 D-Bus）。所以"返回 true"只能证明"调用通了"，
//   证明"真弹出去了"必须是**消费方**的读数（`dunst` 的计数 / `dbus-monitor` 的
//   `member=Notify`）。这条区分写在 `docs/platform-linux-acceptance.md` §2.6e。
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 在 [env] 的 `PATH` 上找可执行文件；找不到返回 null。
///
/// **同步**实现：能力表是同步算出来的（`AppPlatformCapabilities.current()`），
/// 不能在这里 await。
String? resolveOnPath(String name, {Map<String, String>? env}) {
  final e = env ?? Platform.environment;
  final path = e['PATH'] ?? '';
  for (final dir in path.split(':')) {
    if (dir.isEmpty) continue;
    final f = File('$dir${Platform.pathSeparator}$name');
    if (f.existsSync()) return f.path;
  }
  return null;
}

/// PATH 上有没有 libnotify 的 `notify-send`（纯函数，测试可注入 env）。
bool linuxNotifyClientOnPath({Map<String, String>? env}) =>
    resolveOnPath('notify-send', env: env) != null;

/// 当前宿主是不是"能发桌面通知的 Linux"。
bool linuxDesktopNotifyAvailable() {
  if (kIsWeb) return false;
  if (!Platform.isLinux) return false;
  return linuxNotifyClientOnPath();
}

/// Linux 桌面通知的最小实现（`notify-send` / `dunstctl` 子进程）。
class LinuxDesktopNotifier {
  const LinuxDesktopNotifier();

  /// 发一条通知。返回 `true` 只代表**客户端接受了这条消息**（见文件头）。
  Future<bool> show({
    required String title,
    required String body,
    String appName = 'SynHub',
    String? icon,
  }) async {
    final bin = resolveOnPath('notify-send');
    if (bin == null) return false;
    try {
      final r = await Process.run(bin, [
        '--app-name=$appName',
        if (icon != null && icon.isNotEmpty) '--icon=$icon',
        '--urgency=normal',
        title,
        body,
      ]);
      return r.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// 全部收起。没有 `dunstctl`（别的守护进程）时返回 `false` —— 不假装成功。
  Future<bool> clearAll() async {
    final bin = resolveOnPath('dunstctl');
    if (bin == null) return false;
    try {
      final r = await Process.run(bin, ['close-all']);
      return r.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }
}

/// 把标题为 [title] 的窗口叫到前台（Linux 桌面托盘项用；`DA341`）。
///
/// ★ 顺序：`wmctrl -a`（EWMH 标准做法，openbox/metacity/KWin 都认）⇒
///   `xdotool search --name … windowactivate`（没有 wmctrl 的机器）⇒ 都不行返回 false。
/// ★ 为什么放在这个文件：web 站的守卫要求"`lib/` 里 import `dart:io` 的文件数只许降"，
///   所以进程调用集中到**已存在**的 Linux 桌面集成文件里，不新开一个 `dart:io` 文件。
Future<bool> raiseAppWindow(String title) async {
  try {
    final r = await Process.run('wmctrl', ['-a', title]);
    if (r.exitCode == 0) return true;
  } catch (e) {
    debugPrint('[tray] wmctrl 不可用：$e');
  }
  try {
    final r = await Process.run('xdotool', [
      'search', '--name', title, 'windowactivate',
    ]);
    if (r.exitCode == 0) return true;
  } catch (e) {
    debugPrint('[tray] xdotool 不可用：$e');
  }
  debugPrint('[tray] 没有可用的窗口管理器客户端（wmctrl/xdotool）');
  return false;
}

/// 系统是否偏好深色（Linux；`DA342`）。
///
/// 为什么需要它：Flutter 的 Linux 嵌入层**不把 GTK 的深色偏好送进
/// `platformBrightness`**（r701 实测：`GTK_THEME=Adwaita:dark` 与
/// `~/.config/gtk-3.0/settings.ini` 的 `gtk-application-prefer-dark-theme=1`
/// 都改不动 `ThemeMode.system`，界面仍是浅色）。所以由我们自己读 GNOME 的设置：
///   ① `gsettings get org.gnome.desktop.interface color-scheme` → `'prefer-dark'`；
///   ② 退一步看 `gtk-theme` 名字里有没有 `dark`；
///   ③ 再看 GTK 的 `settings.ini`（`gtk-application-prefer-dark-theme` / `gtk-theme-name`）；
///   ④ 最后看环境变量 `GTK_THEME`。
/// 三条都读不到 ⇒ 返回 `null`（**不知道就别猜**，交回 Flutter 自己的判断）。
Future<bool?> linuxSystemPrefersDark() async {
  Future<String?> readGSettings(String key) async {
    try {
      final r = await Process.run('gsettings', ['get', key]);
      if (r.exitCode != 0) return null;
      return '${r.stdout}'.trim().toLowerCase();
    } catch (e) {
      debugPrint('[theme] gsettings 不可用：$e');
      return null;
    }
  }

  final scheme = await readGSettings('org.gnome.desktop.interface color-scheme');
  if (scheme != null && scheme.isNotEmpty) {
    return scheme.contains('prefer-dark');
  }
  final theme = await readGSettings('org.gnome.desktop.interface gtk-theme');
  if (theme != null && theme.isNotEmpty) {
    return theme.contains('dark');
  }
  // ④ GTK 的 settings.ini（最小安装 / 容器里常常没有 `gsettings` 也没有 dconf，
  //   但 `gtk-application-prefer-dark-theme=1` 与 `gtk-theme-name=*-dark` 就在这儿）。
  for (final path in <String>[
    '/root/.config/gtk-3.0/settings.ini',
    '/etc/gtk-3.0/settings.ini',
  ]) {
    try {
      final f = File(path);
      if (!f.existsSync()) continue;
      final text = f.readAsStringSync().toLowerCase();
      if (text.contains('gtk-application-prefer-dark-theme=1') ||
          text.contains('gtk-application-prefer-dark-theme=true')) {
        return true;
      }
      final m = RegExp(r'gtk-theme-name\s*=\s*(\S+)').firstMatch(text);
      if (m != null) return m.group(1)!.contains('dark');
    } catch (e) {
      debugPrint('[theme] 读 $path 失败：$e');
    }
  }
  final env = Platform.environment['GTK_THEME']?.toLowerCase();
  if (env != null && env.isNotEmpty) return env.contains('dark');
  return null;
}

