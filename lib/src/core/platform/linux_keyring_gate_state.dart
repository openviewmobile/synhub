// ★ r701 · `DA340`：Linux 钥匙串的**全局闸门状态**。
//
// 为什么需要它：起飞前检查原来只装在 `KeystoreSecretKeeper` 上，可是仓里还有
// 几个**直连** `appSecureStorage()` 的调用点（照片休眠备份偏好、离线固定、
// 书签等）。实测（`docs/evidence-r701-linux/shots/211_locked_second_source.png`）：
// keeper 已判"不可用"、日志也打了 `usable=false`，**解锁框照样弹** ——
// 因为别处一上来就 `read()` 了 libsecret，而那个调用同步阻塞 GTK 主循环。
//
// ⇒ 闸门必须装在**唯一的构造点**（`app_secure_storage.dart`）：
//   * `main()` 里 `KeystoreSecretKeeper.warmUpLinuxKeyringProbe()` 探测后置位；
//   * 置位后，所有 `read` 一律当"没有这条"、`write`/`delete` 当"存不了"，
//     **一次都不碰插件**。
//
// 默认 `false`（不阻断）：非 Linux 平台永远不置位；Linux 上没预热过（宿主单测、
// 没走到 `main`）时行为与 r698 一致，既有用例不会被这条闸门改变。
library;

/// `true` ⇒ 这台机器上**不许碰 libsecret**（无 keyring / 默认集合锁定 / 探测不出来）。
bool linuxKeyringBlocked = false;
