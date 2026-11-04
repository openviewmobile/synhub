// r701 · `DA340`：**keyring 文件在 ≠ 集合能用**（锁着的 collection 一碰就弹模态框）。
//
// 现场（`docs/evidence-r701-linux/shots/209_locked_keyring_prompt.png`）：
// 已解锁装置验证完之后，把守护进程换掉 ⇒ 文件还在、collection 锁定；
// deb 装好的 App 一启动就弹出「Unlock Login Keyring / The login keyring did not get
// unlocked when you logged into your computer.」——它与 `DA338` 是同一个病根：
// libsecret 的解锁/新建调用**同步阻塞 GTK 主循环**。
//
// 修法两条（本用例逐条钉住）：
//   ① 判据从"文件在"升级成"文件在 **且** 至少一个 collection 未锁"（纯函数）；
//   ② 锁定态只能问 D-Bus ⇒ 起飞前检查改为**启动时异步预热**，同步 getter 只读缓存；
//      探测不出来（null）按**不可用**处理（fail-closed，宁可"不记住口令"也不冻界面）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/security/linux_keyring_probe.dart';

void main() {
  group('① linuxKeyringUsable（纯函数，四态）', () {
    test('没有文件 ⇒ 不可用（哪怕探测说未锁）', () {
      expect(
        linuxKeyringUsable(hasCollectionFile: false, anyUnlocked: true),
        isFalse,
      );
    });

    test('文件在但全锁着 ⇒ 不可用（DA340 的核心）', () {
      expect(
        linuxKeyringUsable(hasCollectionFile: true, anyUnlocked: false),
        isFalse,
      );
    });

    test('文件在但探测不出来 ⇒ 不可用（fail-closed）', () {
      expect(
        linuxKeyringUsable(hasCollectionFile: true, anyUnlocked: null),
        isFalse,
      );
    });

    test('文件在且至少一个未锁 ⇒ 可用', () {
      expect(
        linuxKeyringUsable(hasCollectionFile: true, anyUnlocked: true),
        isTrue,
      );
    });
  });

  test('② keeper 必须走 warmUp ＋ 新判据（不许退回只看文件）', () {
    final keeper =
        File('lib/src/core/security/keystore_secret_keeper.dart').readAsStringSync();
    expect(keeper, contains('warmUpLinuxKeyringProbe'));
    expect(keeper, contains('linuxKeyringUsable'));
    expect(keeper, contains('linuxKeyringDefaultCollectionUnlocked'));
    expect(keeper, contains('DA340'));
  });

  test('③ main 必须在 runApp 之前预热（Linux only）', () {
    final main = File('lib/main.dart').readAsStringSync();
    final call = main.indexOf('warmUpLinuxKeyringProbe');
    final run = main.indexOf('runApp(');
    expect(call, greaterThan(-1), reason: 'main 必须调预热');
    expect(run, greaterThan(call), reason: '预热必须在 runApp 之前 await');
    expect(main, contains('TargetPlatform.linux'));
  });

  test('④ D-Bus 探测器不许 import dart:io（web 面闸门）', () {
    final probe =
        File('lib/src/core/security/linux_keyring_dbus_probe.dart')
            .readAsStringSync();
    expect(probe, isNot(contains("import 'dart:io'")));
    expect(probe, contains('org.freedesktop.Secret.Collection'));
    expect(probe, contains('Locked'));
    // 必须只认 default collection（session collection 永远未锁 ⇒ 假绿）
    expect(probe, contains("ReadAlias"));
    expect(probe, contains("DBusString('default')"));
    // 探测不出来必须是 null，而不是 false（否则"没有 bus"会被记成"全锁"）
    expect(probe, contains('return null;'));
  });
}
