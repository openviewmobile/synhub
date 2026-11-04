// r701 / DA341：**真会话总线 + 假宿主**上的托盘闭环。
//
// 容器里没有真正的面板（GNOME/KDE 的 watcher），所以这里**自己当宿主**：
// 一个 `org.kde.StatusNotifierWatcher` 的假实现，收下我们的注册；
// 然后用 `gdbus`（GLib 的官方命令行客户端，**另一个进程**）读属性、调 Activate、
// 读菜单布局、点菜单条目 —— 判据全落在"别的进程能不能看到/调到我们"。
//
// 宿主上没有会话总线 ⇒ 整组跳过（`DBUS_SESSION_BUS_ADDRESS` 为空）。
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/status_notifier_linux.dart';

final bool _hasBus =
    (Platform.environment['DBUS_SESSION_BUS_ADDRESS'] ?? '').isNotEmpty;

Future<ProcessResult> _gdbus(List<String> args) => Process.run(
  'gdbus',
  args,
  environment: {
    'DBUS_SESSION_BUS_ADDRESS':
        Platform.environment['DBUS_SESSION_BUS_ADDRESS']!,
    'LANG': 'C.UTF-8',
    'LC_ALL': 'C.UTF-8',
  },
).timeout(const Duration(seconds: 15));

/// 假宿主：只实现面板侧真正会用到的那几样。
class _FakeWatcher extends DBusObject {
  _FakeWatcher() : super(DBusObjectPath(StatusNotifierLinuxService.watcherPath));

  final List<String> registered = <String>[];

  static const _iface = 'org.kde.StatusNotifierWatcher';

  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      _iface,
      methods: [
        DBusIntrospectMethod(
          'RegisterStatusNotifierItem',
          args: [
            DBusIntrospectArgument(DBusSignature('s'), DBusArgumentDirection.in_,
                name: 'service'),
          ],
        ),
        DBusIntrospectMethod(
          'RegisterStatusNotifierHost',
          args: [
            DBusIntrospectArgument(DBusSignature('s'), DBusArgumentDirection.in_,
                name: 'service'),
          ],
        ),
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
    if (call.interface != _iface) {
      return DBusMethodErrorResponse.unknownMethod();
    }
    switch (call.name) {
      case 'RegisterStatusNotifierItem':
        registered.add(call.values[0].asString());
        await emitSignal(_iface, 'StatusNotifierItemRegistered', [
          DBusString(call.values[0].asString()),
        ]);
        return DBusMethodSuccessResponse();
      case 'RegisterStatusNotifierHost':
        return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface != _iface) return DBusMethodErrorResponse.unknownProperty();
    switch (name) {
      case 'RegisteredStatusNotifierItems':
        return DBusGetPropertyResponse(DBusArray.string(registered));
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
        if (interface == _iface) ...{
          'RegisteredStatusNotifierItems': DBusArray.string(registered),
          'IsStatusNotifierHostRegistered': const DBusBoolean(true),
          'ProtocolVersion': const DBusInt32(0),
        },
      });
}

void main() {
  final skip = _hasBus ? null : '没有会话总线（宿主上跳过；容器里跑）';

  group('DA341 · 假宿主上的托盘项', () {
    late DBusClient host;
    late _FakeWatcher watcher;
    late StatusNotifierLinuxService svc;
    var activations = 0;

    setUp(() async {
      host = DBusClient.session();
      final reply = await host.requestName(
        StatusNotifierLinuxService.watcherName,
        flags: {DBusRequestNameFlag.doNotQueue},
      );
      expect(
        reply,
        anyOf(DBusRequestNameReply.primaryOwner,
            DBusRequestNameReply.alreadyOwner),
      );
      watcher = _FakeWatcher();
      await host.registerObject(watcher);
      final s = await StatusNotifierLinuxService.start(
        callbacks: SniCallbacks(
          activate: () async => activations++,
        ),
        title: 'SynHub',
        menuLabel: '显示主窗口',
      );
      expect(s, isNotNull, reason: '有宿主时必须起得来');
      svc = s!;
    });

    tearDown(() async {
      await svc.dispose();
      try {
        await host.releaseName(StatusNotifierLinuxService.watcherName);
      } catch (_) {}
      await host.close();
    });

    test('① 宿主真的收到了注册（判据在宿主那一侧，不是我们自己的日志）', () async {
      expect(watcher.registered, contains(StatusNotifierLinuxService.busName));
      expect(svc.registeredOnHost, isTrue);
      expect(svc.menuItems, hasLength(1));
    }, skip: skip);

    test('② gdbus（另一个进程）读得到属性', () async {
      Future<String> get(String prop) async {
        final r = await _gdbus([
          'call', '--session',
          '--dest', StatusNotifierLinuxService.busName,
          '--object-path', StatusNotifierLinuxService.objectPath,
          '--method', 'org.freedesktop.DBus.Properties.Get',
          StatusNotifierLinuxService.interface, prop,
        ]);
        return '${r.stdout}${r.stderr}'.trim();
      }

      expect(await get('Id'), contains("'synhub'"));
      expect(await get('Title'), contains("'SynHub'"));
      expect(await get('Status'), contains("'Active'"));
      expect(await get('Category'), contains("'ApplicationStatus'"));
      expect(
        await get('Menu'),
        contains(StatusNotifierLinuxService.menuPath),
      );
      expect(await get('IconName'), contains("'com.openviewai.synhub'"));
    }, skip: skip);

    test('③ gdbus 调 Activate ⇒ 我们的回调真的响了', () async {
      final r = await _gdbus([
        'call', '--session',
        '--dest', StatusNotifierLinuxService.busName,
        '--object-path', StatusNotifierLinuxService.objectPath,
        '--method', '${StatusNotifierLinuxService.interface}.Activate',
        '0', '0',
      ]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      // 回调是异步的：轮询到它响（最多 3 s）
      for (var i = 0; i < 30 && activations == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(activations, 1);
    }, skip: skip);

    test('④ 菜单布局读得到「显示主窗口」，点它（Event）回调也响', () async {
      final layout = await _gdbus([
        'call', '--session',
        '--dest', StatusNotifierLinuxService.busName,
        '--object-path', StatusNotifierLinuxService.menuPath,
        '--method', 'com.canonical.dbusmenu.GetLayout', '0', '1', '[]',
      ]);
      expect(layout.exitCode, 0, reason: '${layout.stdout}${layout.stderr}');
      expect('${layout.stdout}', contains('显示主窗口'));

      final before = activations;
      final ev = await _gdbus([
        'call', '--session',
        '--dest', StatusNotifierLinuxService.busName,
        '--object-path', StatusNotifierLinuxService.menuPath,
        '--method', 'com.canonical.dbusmenu.Event',
        '1', 'clicked', '<\'\'>', '0',
      ]);
      expect(ev.exitCode, 0, reason: '${ev.stdout}${ev.stderr}');
      for (var i = 0; i < 30 && activations == before; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(activations, greaterThan(before));
    }, skip: skip);

    test('⑤ dispose 之后名字真的没了（不留幽灵托盘项）', () async {
      await svc.dispose();
      final r = await _gdbus([
        'call', '--session',
        '--dest', 'org.freedesktop.DBus',
        '--object-path', '/org/freedesktop/DBus',
        '--method', 'org.freedesktop.DBus.GetNameOwner',
        StatusNotifierLinuxService.busName,
      ]);
      expect(
        r.exitCode,
        isNot(0),
        reason: '名字还在 ⇒ ${r.stdout}${r.stderr}',
      );
    }, skip: skip);
  });
}
