// ★ r701 · `DA340`：用 **D-Bus** 问 Secret Service「有没有未锁的 collection」。
//
// 为什么不用 libsecret 自己问：`secret_service_get_sync()` 在 collection 锁定/缺失时
// 会去**请 GNOME 解锁或新建**（模态 + 同步阻塞 GTK 主循环）—— 那正是 `DA338`/`DA340`
// 要避开的调用。D-Bus 只读属性（`Locked`）**不会**触发解锁，也**不会**弹框。
//
// 判据（缺一即"探测不出来"→ 调用方按 fail-closed 处理）：
//   ① `org.freedesktop.Secret.Service.ReadAlias('default')` 拿到**默认 collection**；
//   ② 路径不是 `/`（= 真的存在默认 collection）；
//   ③ 它的 `org.freedesktop.Secret.Collection.Locked == false`。
//
// ★ 坑（r701 实测）：**不能用"任意一个 collection 未锁"当判据** ——
//   Secret Service 永远有一个内存态 `session` collection（未锁、掉电即失），
//   于是 login 锁着时也会判"可用"，然后一碰 libsecret 就弹解锁框。
//
// ★ 本文件**不许** import `dart:io`（web 面闸门盯着 lib/ 的 `dart:io` 文件数）；
//   `package:dbus` 自己在 Linux 上会用到 socket，但那是它的实现细节。
import 'package:dbus/dbus.dart';

/// 有没有**未锁**的 collection。
///
/// * `true`  = 至少一个未锁（可以用 libsecret）；
/// * `false` = 有 collection，但全锁着（**不许**调 libsecret，否则弹解锁框）；
/// * `null`  = 探测不出来（没有 session bus / 超时 / 服务未起）。
Future<bool?> linuxKeyringDefaultCollectionUnlocked({
  Duration timeout = const Duration(milliseconds: 1500),
  DBusClient? client,
}) async {
  final ownClient = client == null;
  final c = client ?? DBusClient.session();
  try {
    final service = DBusRemoteObject(
      c,
      name: 'org.freedesktop.secrets',
      path: DBusObjectPath('/org/freedesktop/secrets'),
    );
    // ★ 只看 **default collection**（`login`）—— Secret Service 永远有一个
    //   内存态 `session` collection（未锁、掉电即失），拿"任意未锁"当判据会在
    //   **login 锁着**时说"可用"，然后一碰 libsecret 就弹解锁框（r701 实测）。
    final reply = await service
        .callMethod(
          'org.freedesktop.Secret.Service',
          'ReadAlias',
          [DBusString('default')],
          replySignature: DBusSignature('o'),
        )
        .timeout(timeout);
    final path = reply.returnValues.isEmpty
        ? '/'
        : reply.returnValues.first.asObjectPath().value;
    if (path == '/' || path.isEmpty) return false; // 没有默认 collection
    final col = DBusRemoteObject(
      c,
      name: 'org.freedesktop.secrets',
      path: DBusObjectPath(path),
    );
    final locked = (await col
            .getProperty('org.freedesktop.Secret.Collection', 'Locked')
            .timeout(timeout))
        .asBoolean();
    return !locked;
  } catch (_) {
    return null; // 没有 session bus / 超时 / 服务未起 ⇒ 探测不出来
  } finally {
    if (ownClient) {
      try {
        await c.close();
      } catch (_) {}
    }
  }
}
