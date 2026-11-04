// ★ r701 · `DA341`：Linux 的**系统托盘项**（`org.kde.StatusNotifierItem`）。
//
// 为什么要有这个：
//   * Linux 桌面（GNOME 的 AppIndicator 扩展 / KDE 的 StatusNotifier / 各家面板）
//     显示"应用指示器"的公共契约是会话 D-Bus 上的
//     `org.kde.StatusNotifierWatcher`（宿主）＋ `org.kde.StatusNotifierItem`（我们）；
//   * 本仓在此之前**一个托盘项都没有** —— App 最小化/被别的窗口盖住之后，
//     桌面上没有任何入口能把它叫回来（用户只能靠 Alt+Tab / 任务栏找）。
//     这不是"环境不可得"，是**应用侧没实现**。
//
// 三条纪律（与 `DA339` 的 MPRIS 同一套）：
//   ① **失败一律降级，不许崩**：没有会话总线 / 没有宿主（watcher）/ 名字被占 ⇒
//      `start()` 返回 `null`，App 照常运行；
//   ② **不摆假控件**：菜单里只放**真做得到**的动作（"显示主窗口"），
//      做不到的（优雅退出、未读计数、快捷动作）**不放**；
//   ③ **动作要真被调到**：`Activate` / 菜单 `clicked` 都走注入的回调，
//      用例在真会话总线上用 `gdbus` 调一遍，看回调是不是真的响了。
//
// 依赖：`dbus` 包（纯 Dart，不需要额外 apt）。图标走主题名，找不到图标时
// 面板会退化成占位符 —— 那是主题的事，不是我们假装有图标。
import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

/// 托盘项能触发的动作（全部可选：没接的那路就不进菜单）。
class SniCallbacks {
  const SniCallbacks({this.activate});

  /// 点击托盘图标 / 菜单「显示主窗口」都走这一条。
  final Future<void> Function()? activate;
}

/// 菜单里的**一个条目**（纯数据 ⇒ 用例可以脱总线断言）。
@immutable
class SniMenuItem {
  const SniMenuItem({
    required this.id,
    required this.label,
    this.enabled = true,
    this.visible = true,
  });

  final int id;
  final String label;
  final bool enabled;
  final bool visible;
}

/// 托盘图标（`IconName`）—— 与 deb 的 `/usr/share/icons/.../com.openviewai.synhub.png` 同名。
const String kSniIconName = 'com.openviewai.synhub';

/// 菜单清单：**只列真做得到的动作**。
///
/// ★ 这里没有「退出」：本仓没有"保存状态后优雅退出"的路径，
/// 摆一个 `exit(0)` 的假退出只会让用户丢会话（`DA332`–`DA335` 的教训：
/// 摆出来但点不动的入口一律不许摆）。
List<SniMenuItem> sniMenuItems({
  required bool canActivate,
  required String label,
}) => [
  // 文案由调用方（`main` → `currentText().trayShowMainWindow`）注入：
  // lib/ 里不许出现硬编码中文界面文案（i18n 守卫），而且托盘菜单要跟界面同语言。
  if (canActivate && label.isNotEmpty) SniMenuItem(id: 1, label: label),
];

/// `ToolTip` 的编码（纯函数，签名为 `(sa(iiay)ss)`）。
DBusValue sniToolTip({required String title, required String iconName}) =>
    DBusStruct([
      DBusString(iconName),
      DBusArray(DBusSignature('(iiay)'), const []),
      DBusString(title),
      const DBusString(''),
    ]);

/// 菜单布局（`com.canonical.dbusmenu.GetLayout` 的回包体）。
///
/// 返回 `(revision, layout)`，`layout` 是 `a(ia{sv}av)` 的递归结构：
/// 根 `id=0`（子树）、子项各自带 `label` / `enabled` / `visible`。
DBusValue sniMenuLayout({
  required int revision,
  required List<SniMenuItem> items,
}) {
  // 签名的第三段是 `av`（**变体数组**）：每个子节点都要包成 `DBusVariant`，
  // 否则 `DBusArray` 会以"children 与签名 v 不匹配"直接抛（r701 第一版就撞了）。
  DBusValue node(
    int id,
    List<DBusValue> children,
    Map<String, DBusValue> props,
  ) => DBusStruct([
    DBusInt32(id),
    DBusDict.stringVariant(props),
    DBusArray(DBusSignature('v'), [for (final c in children) DBusVariant(c)]),
  ]);

  final childNodes = [
    for (final it in items)
      node(it.id, const [], {
        'label': DBusString(it.label),
        'enabled': DBusBoolean(it.enabled),
        'visible': DBusBoolean(it.visible),
      }),
  ];
  return DBusStruct([
    DBusUint32(revision),
    node(0, childNodes, {
      'children-display': const DBusString('submenu'),
      'visible': const DBusBoolean(true),
    }),
  ]);
}

/// Linux 托盘项服务。`start()` 拿不到总线 / 没有宿主时返回 `null`。
class StatusNotifierLinuxService {
  StatusNotifierLinuxService._(this._client, this._item, this._menu);

  final DBusClient _client;
  final _SniObject _item;
  final _SniMenuObject _menu;

  /// 本进程在总线上**唯一**的名字（同一台机器多开时第二个会注册失败 —— 这是好事：
  /// 一个 App 只该有一个托盘项）。
  static const String busName = 'org.kde.StatusNotifierItem-synhub';
  static const String objectPath = '/StatusNotifierItem';
  static const String interface = 'org.kde.StatusNotifierItem';
  static const String menuPath = '/StatusNotifierItem/Menu';
  static const String menuInterface = 'com.canonical.dbusmenu';
  static const String watcherName = 'org.kde.StatusNotifierWatcher';
  static const String watcherPath = '/StatusNotifierWatcher';
  static const String watcherInterface = 'org.kde.StatusNotifierWatcher';

  /// 宿主有没有确认收下我们（诊断/用例用）。
  bool get registeredOnHost => _item.registeredOnHost;

  /// 托盘菜单当前真有的条目（诊断/用例用；与 `Menu` 属性的布局同源）。
  List<SniMenuItem> get menuItems => _menu.menuItems;

  /// 起服务。**任何失败都退化成 `null`**（没有总线 / 没有宿主 / 名字被占）。
  static Future<StatusNotifierLinuxService?> start({
    required SniCallbacks callbacks,
    String title = 'SynHub',
    String iconName = kSniIconName,
    String menuLabel = '',
  }) async {
    DBusClient? client;
    try {
      client = DBusClient.session();
      final reply = await client.requestName(
        busName,
        flags: {DBusRequestNameFlag.doNotQueue},
      );
      if (reply != DBusRequestNameReply.primaryOwner &&
          reply != DBusRequestNameReply.alreadyOwner) {
        await client.close();
        return null;
      }
      final item = _SniObject(
        callbacks: callbacks,
        title: title,
        iconName: iconName,
        menuLabel: menuLabel,
      );
      final menu = _SniMenuObject(callbacks: callbacks, menuLabel: menuLabel);
      await client.registerObject(item);
      await client.registerObject(menu);
      final service = StatusNotifierLinuxService._(client, item, menu);

      // 告诉宿主"我在这儿"。没有宿主（容器里默认没有）就如实降级。
      final watcher = DBusClient.session();
      try {
        await DBusRemoteObject(
          watcher,
          name: watcherName,
          path: DBusObjectPath(watcherPath),
        ).callMethod(
          watcherInterface,
          'RegisterStatusNotifierItem',
          [DBusString(busName)],
        );
        item.registeredOnHost = true;
      } catch (e) {
        debugPrint('[tray] 没有 StatusNotifierWatcher（降级为无托盘项）：$e');
        await service.dispose();
        return null;
      } finally {
        try {
          await watcher.close();
        } catch (_) {}
      }
      return service;
    } catch (e) {
      debugPrint('[tray] 不可用（降级为无托盘项）：$e');
      try {
        await client?.close();
      } catch (_) {}
      return null;
    }
  }

  Future<void> dispose() async {
    try {
      await _client.releaseName(busName);
    } catch (_) {}
    try {
      await _client.close();
    } catch (_) {}
  }
}

/// `/StatusNotifierItem`（一个对象，一个接口）。
class _SniObject extends DBusObject {
  _SniObject({
    required this.callbacks,
    required this.title,
    required this.iconName,
    required this.menuLabel,
  }) : super(DBusObjectPath(StatusNotifierLinuxService.objectPath));

  final SniCallbacks callbacks;
  final String title;
  final String iconName;
  final String menuLabel;
  bool registeredOnHost = false;

  List<SniMenuItem> get _items =>
      sniMenuItems(canActivate: callbacks.activate != null, label: menuLabel);

  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      StatusNotifierLinuxService.interface,
      methods: [
        DBusIntrospectMethod('Activate', args: [
          DBusIntrospectArgument(DBusSignature('i'),
              DBusArgumentDirection.in_, name: 'x'),
          DBusIntrospectArgument(DBusSignature('i'),
              DBusArgumentDirection.in_, name: 'y'),
        ]),
        DBusIntrospectMethod('SecondaryActivate', args: [
          DBusIntrospectArgument(DBusSignature('i'),
              DBusArgumentDirection.in_, name: 'x'),
          DBusIntrospectArgument(DBusSignature('i'),
              DBusArgumentDirection.in_, name: 'y'),
        ]),
        DBusIntrospectMethod('ContextMenu', args: [
          DBusIntrospectArgument(DBusSignature('i'),
              DBusArgumentDirection.in_, name: 'x'),
          DBusIntrospectArgument(DBusSignature('i'),
              DBusArgumentDirection.in_, name: 'y'),
        ]),
        DBusIntrospectMethod('Scroll', args: [
          DBusIntrospectArgument(DBusSignature('i'),
              DBusArgumentDirection.in_, name: 'delta'),
          DBusIntrospectArgument(DBusSignature('s'),
              DBusArgumentDirection.in_, name: 'orientation'),
        ]),
      ],
      properties: [
        DBusIntrospectProperty('Category', DBusSignature('s'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('Id', DBusSignature('s'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('Title', DBusSignature('s'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('Status', DBusSignature('s'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('WindowId', DBusSignature('u'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('IconName', DBusSignature('s'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('IconPixmap', DBusSignature('a(iiay)'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('OverlayIconName', DBusSignature('s'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('AttentionIconName', DBusSignature('s'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('ToolTip', DBusSignature('(sa(iiay)ss)'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('ItemIsMenu', DBusSignature('b'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('Menu', DBusSignature('o'),
            access: DBusPropertyAccess.read),
      ],
      signals: [
        DBusIntrospectSignal('NewIcon'),
        DBusIntrospectSignal('NewToolTip'),
        DBusIntrospectSignal('NewStatus', args: [
          DBusIntrospectArgument(DBusSignature('s'), DBusArgumentDirection.out,
              name: 'status'),
        ]),
      ],
    ),
  ];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface == StatusNotifierLinuxService.interface) {
      switch (call.name) {
        case 'Activate':
        case 'SecondaryActivate':
        // 右键菜单交给面板自己弹（我们把 `Menu` 属性给了它）。
        // 这里如实回成功、不做额外动作 —— 不是"假控件"，是规范允许的空实现。
        case 'ContextMenu':
        case 'Scroll':
          if (call.name == 'Activate') {
            await callbacks.activate?.call();
          }
          return DBusMethodSuccessResponse();
      }
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface != StatusNotifierLinuxService.interface) {
      return DBusMethodErrorResponse.unknownProperty();
    }
    switch (name) {
      case 'Category':
        return DBusGetPropertyResponse(const DBusString('ApplicationStatus'));
      case 'Id':
        return DBusGetPropertyResponse(const DBusString('synhub'));
      case 'Title':
        return DBusGetPropertyResponse(DBusString(title));
      case 'Status':
        return DBusGetPropertyResponse(const DBusString('Active'));
      case 'WindowId':
        return DBusGetPropertyResponse(const DBusUint32(0));
      case 'IconName':
        return DBusGetPropertyResponse(DBusString(iconName));
      case 'IconPixmap':
        return DBusGetPropertyResponse(
          DBusArray(DBusSignature('(iiay)'), const []),
        );
      case 'OverlayIconName':
      case 'AttentionIconName':
        return DBusGetPropertyResponse(const DBusString(''));
      case 'ToolTip':
        return DBusGetPropertyResponse(
          sniToolTip(title: title, iconName: iconName),
        );
      case 'ItemIsMenu':
        // 左键 = Activate（面板直接调），不是"左键只弹菜单"。
        return DBusGetPropertyResponse(const DBusBoolean(false));
      case 'Menu':
        return DBusGetPropertyResponse(
          DBusObjectPath(StatusNotifierLinuxService.menuPath),
        );
    }
    return DBusMethodErrorResponse.unknownProperty();
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse({
        if (interface == StatusNotifierLinuxService.interface) ...{
          'Category': const DBusString('ApplicationStatus'),
          'Id': const DBusString('synhub'),
          'Title': DBusString(title),
          'Status': const DBusString('Active'),
          'WindowId': const DBusUint32(0),
          'IconName': DBusString(iconName),
          'IconPixmap': DBusArray(DBusSignature('(iiay)'), const []),
          'OverlayIconName': const DBusString(''),
          'AttentionIconName': const DBusString(''),
          'ToolTip': sniToolTip(title: title, iconName: iconName),
          'ItemIsMenu': const DBusBoolean(false),
          'Menu': DBusObjectPath(StatusNotifierLinuxService.menuPath),
        },
      });

  /// 菜单条目（`Menu` 对象用它算布局；只读不写 ⇒ 不需要 setProperty）。
  List<SniMenuItem> get menuItems => _items;

}

/// `/StatusNotifierItem/Menu`（`com.canonical.dbusmenu`）。
class _SniMenuObject extends DBusObject {
  _SniMenuObject({required this.callbacks, required this.menuLabel})
    : super(DBusObjectPath(StatusNotifierLinuxService.menuPath));

  final SniCallbacks callbacks;
  final String menuLabel;
  final int _revision = 1;

  List<SniMenuItem> get _items =>
      sniMenuItems(canActivate: callbacks.activate != null, label: menuLabel);

  /// 菜单条目（诊断/用例用；与 `GetLayout` 同源）。
  List<SniMenuItem> get menuItems => _items;

  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      StatusNotifierLinuxService.menuInterface,
      methods: [
        DBusIntrospectMethod('GetLayout', args: [
          DBusIntrospectArgument(DBusSignature('i'),
              DBusArgumentDirection.in_, name: 'parentId'),
          DBusIntrospectArgument(DBusSignature('i'),
              DBusArgumentDirection.in_, name: 'recursionDepth'),
          DBusIntrospectArgument(DBusSignature('as'),
              DBusArgumentDirection.in_, name: 'propertyNames'),
        ]),
        DBusIntrospectMethod('Event', args: [
          DBusIntrospectArgument(DBusSignature('i'),
              DBusArgumentDirection.in_, name: 'id'),
          DBusIntrospectArgument(DBusSignature('s'),
              DBusArgumentDirection.in_, name: 'eventId'),
          DBusIntrospectArgument(DBusSignature('v'),
              DBusArgumentDirection.in_, name: 'data'),
          DBusIntrospectArgument(DBusSignature('u'),
              DBusArgumentDirection.in_, name: 'timestamp'),
        ]),
        DBusIntrospectMethod('AboutToShow', args: [
          DBusIntrospectArgument(DBusSignature('i'),
              DBusArgumentDirection.in_, name: 'id'),
        ]),
        DBusIntrospectMethod('GetGroupProperties', args: [
          DBusIntrospectArgument(DBusSignature('ai'),
              DBusArgumentDirection.in_, name: 'ids'),
          DBusIntrospectArgument(DBusSignature('as'),
              DBusArgumentDirection.in_, name: 'propertyNames'),
        ]),
        DBusIntrospectMethod('GetProperty', args: [
          DBusIntrospectArgument(DBusSignature('i'),
              DBusArgumentDirection.in_, name: 'id'),
          DBusIntrospectArgument(DBusSignature('s'),
              DBusArgumentDirection.in_, name: 'name'),
        ]),
      ],
      signals: [
        DBusIntrospectSignal('LayoutUpdated', args: [
          DBusIntrospectArgument(DBusSignature('u'), DBusArgumentDirection.out,
              name: 'revision'),
          DBusIntrospectArgument(DBusSignature('i'), DBusArgumentDirection.out,
              name: 'parent'),
        ]),
        DBusIntrospectSignal('ItemsPropertiesUpdated'),
      ],
    ),
  ];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != StatusNotifierLinuxService.menuInterface) {
      return DBusMethodErrorResponse.unknownMethod();
    }
    switch (call.name) {
      case 'GetLayout':
        return DBusMethodSuccessResponse([
          sniMenuLayout(revision: _revision, items: _items),
        ]);
      case 'AboutToShow':
        return DBusMethodSuccessResponse([const DBusBoolean(false)]);
      case 'GetGroupProperties':
        return DBusMethodSuccessResponse([
          DBusArray(DBusSignature('(ia{sv})'), [
            for (final it in _items)
              DBusStruct([
                DBusInt32(it.id),
                DBusDict.stringVariant({
                  'label': DBusString(it.label),
                  'enabled': DBusBoolean(it.enabled),
                  'visible': DBusBoolean(it.visible),
                }),
              ]),
          ]),
        ]);
      case 'GetProperty':
        final id = call.values[0].asInt32();
        for (final it in _items) {
          if (it.id == id) {
            return DBusMethodSuccessResponse([
              DBusVariant(DBusString(it.label)),
            ]);
          }
        }
        return DBusMethodErrorResponse.unknownProperty();
      case 'Event':
        final id = call.values[0].asInt32();
        final eventId = call.values[1].asString();
        if (eventId == 'clicked') {
          if (id == 1 && callbacks.activate != null) {
            await callbacks.activate!.call();
          }
          // 未定义的 id 不回错误也不做事：面板可能拿到旧 revision 的布局。
          return DBusMethodSuccessResponse();
        }
        return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async =>
      DBusMethodErrorResponse.unknownProperty();
}
