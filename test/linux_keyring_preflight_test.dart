// r698 / DA338：Linux「钥匙串起飞前检查」的判据。
//   DA338 = "Linux 上没有已存在的默认 keyring 时，libsecret 建库弹窗**同步阻塞
//   GTK 主循环** ⇒ 整个 App 停帧（登录页永远 AUTHENTICATING）"。
//
// 现场（Linux 容器，2026-10-31，像素证据 `/tmp/stuck_login.png` 与
// `docs/evidence-r698-linux/`）：
//   * 把 `~/.local/share/keyrings/` 清空后手动登录 ⇒ App 停在 `AUTHENTICATING`，
//     `flutter test` 卡死 9 分钟，抓根窗口看到 GNOME 的
//     「Choose password for new keyring」模态框；
//   * 它对 libsecret 是**同步阻塞**调用 ⇒ 整个 App 停帧（连 `pump()` 都不返回）；
//   * 同一台机、`login.keyring` 在位 ⇒ 手动登录 42 s 成功。
//
// ⇒ 判据：**没有已存在的默认 keyring 就根本不碰 libsecret**。
// 本用例锁住"哪些目录算有 / 算没有"，防止有人把检查放宽成"目录存在就算有"
// （那样空目录会立刻把 App 冻住）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/security/linux_keyring_probe.dart';

void main() {
  List<String> Function(String) withFiles(Map<String, List<String>> fs) =>
      (dir) {
        final names = fs[dir];
        if (names == null) throw const FileSystemExceptionLikeNotFound();
        return names;
      };

  test('没有 keyring 目录 ⇒ false（不许碰 libsecret）', () {
    expect(
      linuxKeyringHasDefaultCollection(
        dataHome: '/data',
        listDir: withFiles(const {}),
      ),
      isFalse,
    );
  });

  test('目录存在但是空 ⇒ false（一调就会弹"新建 keyring"）', () {
    expect(
      linuxKeyringHasDefaultCollection(
        dataHome: '/data',
        listDir: withFiles(const {'/data/keyrings': <String>[]}),
      ),
      isFalse,
    );
  });

  test('只有 user.keystore、没有 *.keyring ⇒ false', () {
    expect(
      linuxKeyringHasDefaultCollection(
        dataHome: '/data',
        listDir: withFiles(const {
          '/data/keyrings': ['user.keystore'],
        }),
      ),
      isFalse,
    );
  });

  test('有 login.keyring ⇒ true（实测这条机器手动登录成功）', () {
    expect(
      linuxKeyringHasDefaultCollection(
        dataHome: '/data',
        listDir: withFiles(const {
          '/data/keyrings': ['login.keyring', 'user.keystore'],
        }),
      ),
      isTrue,
    );
  });

  test(r'没有 XDG_DATA_HOME 时回退 <home>/.local/share/keyrings', () {
    expect(
      linuxKeyringHasDefaultCollection(
        dataHome: '',
        home: '/root',
        listDir: withFiles(const {
          '/root/.local/share/keyrings': ['login.keyring'],
        }),
      ),
      isTrue,
    );
    expect(
      linuxKeyringHasDefaultCollection(
        dataHome: '',
        home: '/root',
        listDir: withFiles(const {}),
      ),
      isFalse,
    );
  });

  test('连 HOME 都没有 ⇒ false（不许抛出去）', () {
    expect(
      linuxKeyringHasDefaultCollection(
        dataHome: '',
        home: '',
        listDir: withFiles(const {}),
      ),
      isFalse,
    );
  });
}

/// 让 `listDir` 抛一个"目录不存在"型的异常（生产实现是 `Directory.listSync`）。
class FileSystemExceptionLikeNotFound implements Exception {
  const FileSystemExceptionLikeNotFound();
}
