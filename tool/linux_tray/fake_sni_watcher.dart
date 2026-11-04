// r701 · `DA341` 的**假宿主**：一个最小可用的 `org.kde.StatusNotifierWatcher`。
//
// 容器里没有桌面面板（GNOME/KDE 的 AppIndicator 扩展），所以托盘项的"宿主侧"
// 只能自己造一个。它做三件事：
//   ① 占住 `org.kde.StatusNotifierWatcher` 这个名字；
//   ② 收 `RegisterStatusNotifierItem`，把注册到的服务名 **追加到日志**；
//   ③ 暴露 `RegisteredStatusNotifierItems` 属性 —— 外部 `gdbus` 能读到"谁注册了"。
//
// 用法（容器里，与 App 同一个会话总线）：
//   dart run tool/linux_tray/fake_sni_watcher.dart --seconds 180 --log /tmp/sni_watch.log
import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';

Future<void> main(List<String> args) async {
  var seconds = 180;
  var logPath = '/tmp/sni_watch.log';
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--seconds') seconds = int.tryParse(args[i + 1]) ?? seconds;
    if (args[i] == '--log') logPath = args[i + 1];
  }
  final log = File(logPath).openWrite(mode: FileMode.append);
  void note(String s) {
    final line = '${DateTime.now().toIso8601String()} $s';
    log.writeln(line);
    stdout.writeln(line);
  }

  final client = DBusClient.session();
  final watcher = _Watcher(note);
  final reply = await client.requestName(
    _Watcher.name,
    flags: {DBusRequestNameFlag.doNotQueue},
  );
  note('HOST start reply=$reply');
  await client.registerObject(watcher);
  note('HOST ready path=${_Watcher.objectPath}');

  await Future<void>.delayed(Duration(seconds: seconds));
  await client.releaseName(_Watcher.name);
  await client.close();
  await log.flush();
  await log.close();
  note('HOST bye');
}

class _Watcher extends DBusObject {
  _Watcher(this.note) : super(DBusObjectPath(objectPath));

  final void Function(String) note;

  static const name = 'org.kde.StatusNotifierWatcher';
  static const objectPath = '/StatusNotifierWatcher';
  static const iface = 'org.kde.StatusNotifierWatcher';

  final List<String> items = [];

  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      iface,
      methods: [
        DBusIntrospectMethod('RegisterStatusNotifierItem', args: [
          DBusIntrospectArgument(DBusSignature('s'), DBusArgumentDirection.in_,
              name: 'service'),
        ]),
        DBusIntrospectMethod('RegisterStatusNotifierHost', args: [
          DBusIntrospectArgument(DBusSignature('s'), DBusArgumentDirection.in_,
              name: 'service'),
        ]),
      ],
      properties: [
        DBusIntrospectProperty('RegisteredStatusNotifierItems',
            DBusSignature('as'), access: DBusPropertyAccess.read),
        DBusIntrospectProperty('IsStatusNotifierHostRegistered',
            DBusSignature('b'), access: DBusPropertyAccess.read),
        DBusIntrospectProperty('ProtocolVersion', DBusSignature('i'),
            access: DBusPropertyAccess.read),
      ],
      signals: [
        DBusIntrospectSignal('StatusNotifierItemRegistered', args: [
          DBusIntrospectArgument(DBusSignature('s'), DBusArgumentDirection.out,
              name: 'service'),
        ]),
        DBusIntrospectSignal('StatusNotifierHostRegistered'),
      ],
    ),
  ];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != iface) {
      return DBusMethodErrorResponse.unknownMethod();
    }
    if (call.name == 'RegisterStatusNotifierItem') {
      final svc = call.values[0].asString();
      items.add(svc);
      note('HOST registered item=$svc');
      await emitSignal(iface, 'StatusNotifierItemRegistered', [DBusString(svc)]);
      return DBusMethodSuccessResponse();
    }
    if (call.name == 'RegisterStatusNotifierHost') {
      note('HOST registered a host=${call.values.isEmpty ? "?" : call.values[0]}');
      return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface != iface) return DBusMethodErrorResponse.unknownProperty();
    switch (name) {
      case 'RegisteredStatusNotifierItems':
        return DBusGetPropertyResponse(DBusArray.string(items));
      case 'IsStatusNotifierHostRegistered':
        return DBusGetPropertyResponse(const DBusBoolean(true));
      case 'ProtocolVersion':
        return DBusGetPropertyResponse(const DBusInt32(0));
    }
    return DBusMethodErrorResponse.unknownProperty();
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse({
        if (interface == iface) ...{
          'RegisteredStatusNotifierItems': DBusArray.string(items),
          'IsStatusNotifierHostRegistered': const DBusBoolean(true),
          'ProtocolVersion': const DBusInt32(0),
        },
      });
}
