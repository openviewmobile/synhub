// r701 / DA341：Linux **托盘项**（`org.kde.StatusNotifierItem`）的宿主级判据。
//
// 这一层只钉"我们**摆了什么**、**没摆什么**"（真总线上的行为在
// `test/status_notifier_linux_bus_test.dart`，那里是"别的进程能不能调到我们"）。
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/status_notifier_linux.dart';

void main() {
  group('DA341 · 托盘菜单只摆真做得到的东西', () {
    test('① 有 activate 才给「显示主窗口」；没有就一个都不摆', () {
      final withAction = sniMenuItems(canActivate: true, label: '显示主窗口');
      expect(withAction, hasLength(1));
      expect(withAction.single.id, 1);
      expect(withAction.single.label, '显示主窗口');
      expect(withAction.single.enabled, isTrue);
      expect(withAction.single.visible, isTrue);

      expect(sniMenuItems(canActivate: false, label: '显示主窗口'), isEmpty);
      // 没有文案（比如调用方还没准备好本地化资源）⇒ 不摆空标签条目
      expect(sniMenuItems(canActivate: true, label: ''), isEmpty);
    });

    test('② 没有「退出」这种假动作（本仓没有保存状态后优雅退出的路径）', () {
      final labels =
          sniMenuItems(canActivate: true, label: '显示主窗口').map((e) => e.label).toList();
      for (final word in const ['退出', 'Quit', 'Exit', '注销', '重启']) {
        expect(
          labels.any((l) => l.contains(word)),
          isFalse,
          reason: '摆出来的每个条目都必须真做得到；「$word」现在做不到',
        );
      }
    });

    test('③ 布局是 dbusmenu 的形状：根 0 带「submenu」，子项带 label/enabled/visible', () {
      final layout = sniMenuLayout(
        revision: 3,
        items: sniMenuItems(canActivate: true, label: '显示主窗口'),
      ) as DBusStruct;
      expect(layout.children, hasLength(2));
      expect((layout.children[0] as DBusUint32).value, 3); // revision
      final root = layout.children[1] as DBusStruct;
      expect((root.children[0] as DBusInt32).value, 0);
      final rootProps = (root.children[1] as DBusDict).children;
      expect(
        (rootProps[const DBusString('children-display')] as DBusVariant)
            .value
            .asString(),
        'submenu',
      );
      final kids = (root.children[2] as DBusArray).children;
      expect(kids, hasLength(1));
      // `av` 的每个元素都是变体，真值在 `.value` 里
      final kid = (kids.single as DBusVariant).value as DBusStruct;
      expect((kid.children[0] as DBusInt32).value, 1);
      final props = (kid.children[1] as DBusDict).children;
      expect(
        (props[const DBusString('label')] as DBusVariant).value.asString(),
        '显示主窗口',
      );
      expect(
        (props[const DBusString('enabled')] as DBusVariant).value.asBoolean(),
        isTrue,
      );
    });

    test('④ ToolTip 的形状是 (sa(iiay)ss)：图标名 + 空 pixmap + 标题 + 空副标题', () {
      final tip = sniToolTip(title: 'SynHub', iconName: kSniIconName)
          as DBusStruct;
      expect(tip.children, hasLength(4));
      expect(tip.children[0].asString(), kSniIconName);
      expect((tip.children[1] as DBusArray).children, isEmpty);
      expect(tip.children[2].asString(), 'SynHub');
      expect(tip.children[3].asString(), '');
    });

    test('⑤ 契约常量：接口名/对象路径/菜单路径/宿主名（面板按这些找我们）', () {
      expect(StatusNotifierLinuxService.interface, 'org.kde.StatusNotifierItem');
      expect(StatusNotifierLinuxService.objectPath, '/StatusNotifierItem');
      expect(StatusNotifierLinuxService.menuPath, '/StatusNotifierItem/Menu');
      expect(StatusNotifierLinuxService.menuInterface, 'com.canonical.dbusmenu');
      expect(StatusNotifierLinuxService.watcherName, 'org.kde.StatusNotifierWatcher');
      expect(StatusNotifierLinuxService.watcherPath, '/StatusNotifierWatcher');
      // 图标名与 deb 装的图标同名（否则面板显示占位符）
      expect(kSniIconName, 'com.openviewai.synhub');
    });
  });

  group('DA341 · 接线与降级', () {
    test('⑥ 服务文件不 import dart:io（可在宿主跑；进程调用集中在接线层）', () {
      final src = File(
        'lib/src/core/platform/status_notifier_linux.dart',
      ).readAsStringSync();
      expect(src.contains("import 'dart:io'"), isFalse);
      expect(src.contains('Process.run'), isFalse);
    });

    test('⑦ 接线层先 wmctrl、退 xdotool，两条都没有就如实 false', () {
      final src = File(
        'lib/src/core/platform/desktop_notify_linux.dart',
      ).readAsStringSync();
      final wm = src.indexOf("'wmctrl'");
      final xd = src.indexOf("'xdotool'");
      expect(wm, greaterThan(-1));
      expect(xd, greaterThan(wm), reason: 'wmctrl 是主路，xdotool 是退路');
      expect(src.contains('return false;'), isTrue);
    });

    test('⑧ main 只在 Linux 起托盘，且失败不拦启动', () {
      final src = File('lib/main.dart').readAsStringSync();
      final idx = src.indexOf('startLinuxDesktopTray(');
      expect(idx, greaterThan(-1));
      final around = src.substring(
        idx - 400 < 0 ? 0 : idx - 400,
        idx + 400 > src.length ? src.length : idx + 400,
      );
      expect(around.contains('TargetPlatform.linux'), isTrue);
      expect(around.contains('catchError'), isTrue);
      expect(around.contains('unawaited'), isTrue);
      expect(around.contains('currentText().trayShowMainWindow'), isTrue,
          reason: '托盘菜单文案要跟界面同语言，不许硬编码');
    });

    test('⑨ DA341 编号与证据路径都写在这份实现里', () {
      final src = File(
        'lib/src/core/platform/status_notifier_linux.dart',
      ).readAsStringSync();
      expect(src.contains('DA341'), isTrue);
    });
  });
}
