// ★ r698：Linux 上"钥匙串能不能用"的**起飞前检查**。
//
// 为什么要有这个（Linux 容器实测，2026-10-31）：
//   * `flutter_secure_storage` 在 Linux 走 **libsecret**；当**没有默认 keyring** 时
//     它会请 GNOME **新建**一个 —— 那是一个**模态**「Choose password for new
//     keyring」，而且这个调用是**同步阻塞 GTK 主循环**的；
//   * 后果不是"报错"，是**整个 App 停帧**：连 `tester.pump()` 都不返回，
//     登录按钮永远停在 `AUTHENTICATING`（同一轮里 `pkill` 掉 keyring 守护进程也
//     救不回来 —— 线程还阻塞在那个调用里）；
//   * 反证（同一台机、`login.keyring` 在位）：手动登录 **42 s 成功**
//     （`01 登录成功：account=demo_user sid=86位`，像素 `02_login_page`）。
//
// ⇒ 在**碰插件之前**先看"这台机器有没有一个已存在的默认 keyring"：
//   没有就**根本不调 libsecret**，凭据只留在内存里（下次冷启动要重输）。
//   这比"让用户去关那个模态框"好：无头 / 最小 WM / 没装 gnome-keyring 的机器
//   上那个框**可能根本弹不出来**。
//
// 判据只看**文件**（`<XDG_DATA_HOME>/keyrings/*.keyring` 至少一个）——
// 那是 gnome-keyring 落盘默认 collection 的位置；目录存在但**空**也不行
// （空 = 还没有 collection ⇒ 一调就会弹"新建"）。
// ★ 本文件**不许** import `dart:io`（`test/platform_web_test.dart` 的
//   「`dart:io` 移植面只许缩不许涨」闸门盯着 lib/ 里的文件数）。
//   真实列目录由调用方注入：生产走 `keystore_secret_keeper.dart`（它本来就 import
//   `dart:io`），用例注入假文件表。这也让判据可以**纯函数**地反证。
//
// 判据只看"目录里有没有 `*.keyring`"这一件事 —— 不看 libsecret 的返回值，
// 也不看守护进程在不在（在也不代表有默认 collection）。

/// ★ r701 · `DA340`：**文件在 ≠ 集合能用**。
///
/// r698 的判据是"`keyrings/` 里至少一个 `*.keyring`"。r701 在**已解锁**的装置上验
/// libsecret 往返时撞到反面：把守护进程换掉之后，文件还在、但 collection 处于
/// **锁定**态 —— App 一调 libsecret，GNOME 立刻弹
/// 「Unlock Login Keyring / The login keyring did not get unlocked when you logged
/// into your computer.」（像素 `docs/evidence-r701-linux/shots/209_locked_keyring_prompt.png`），
/// 那个调用同样是**同步阻塞 GTK 主循环**的（与 `DA338` 同一个病根）。
///
/// ⇒ "能不能用"必须同时满足两件事实：
///   ① 磁盘上有 collection 文件（r698 判据）；
///   ② 通过 **Secret Service 的 D-Bus 属性**看到**至少一个未锁**的 collection
///      （`org.freedesktop.Secret.Collection.Locked == false`）。
///
/// [anyUnlocked] 传 `null` = **探测不出来**（没有 session bus / 超时 / 服务没起）。
/// 这时按**不可用**处理（fail-closed）：代价是"这台机器不记住口令"，
/// 收益是**绝不冻界面** —— 与 `DA338` 的取舍一致。
bool linuxKeyringUsable({
  required bool hasCollectionFile,
  required bool? anyUnlocked,
}) {
  if (!hasCollectionFile) return false;
  return anyUnlocked == true;
}

/// 该目录下有没有**已经存在**的默认 keyring。
///
/// [dataHome] / [home] 为空串或 null 时按 XDG 规则回退；
/// [listDir] 必须由调用方给（生产＝真实文件系统，用例＝假文件表），
/// 它抛异常一律当"没有"。
bool linuxKeyringHasDefaultCollection({
  String? dataHome,
  String? home,
  required List<String> Function(String dir) listDir,
}) {
  String? dir;
  try {
    final xdg = dataHome;
    final h = home;
    if (xdg != null && xdg.trim().isNotEmpty) {
      dir = '${xdg.trim()}/keyrings';
    } else if (h != null && h.trim().isNotEmpty) {
      dir = '${h.trim()}/.local/share/keyrings';
    }
  } catch (_) {
    return false;
  }
  if (dir == null) return false;

  final List<String> names;
  try {
    names = listDir(dir);
  } catch (_) {
    return false; // 目录不存在 / 没权限 ⇒ 当成"没有钥匙串"
  }
  return names.any((n) => n.endsWith('.keyring'));
}
