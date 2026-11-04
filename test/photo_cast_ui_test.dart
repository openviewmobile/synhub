// P65：投送（Chromecast）UI 的离线用例。
//
// 用**假桥**顶掉 MethodChannel —— 不碰设备、不发一个字节。
// 桥契约（我方定义，真机侧由原生实现）：
//   availability() → {'available': bool, 'devices': [{'id','name'}, …]}
//   connect(deviceId) / send(envelope) / disconnect()
//
// 与官方对齐的时序（见 `photo_cast.dart` 注释：`CastSessionManagerListener`
// + `ChromecastHelper`）：availability → connect → identify →（翻页）goto_index
// → disconnect。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/photos/photo_cast.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';
import 'package:synhub/src/features/photos/photo_viewer_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

const _png = <int>[137, 80, 78, 71];

/// 假桥：记录每一次调用（**不碰设备**）。
class FakeCastBridge implements PhotoCastBridge {
  FakeCastBridge({this.available = true, this.devices = const [], this.failConnect = false});

  final bool available;
  final List<Map<String, dynamic>> devices;
  final bool failConnect;

  final List<String> called = [];
  final List<Map<String, dynamic>> sent = [];
  String? connected;

  @override
  Future<Map<String, dynamic>> availability() async {
    called.add('availability');
    return {'available': available, 'devices': devices};
  }

  @override
  Future<void> connect(String deviceId) async {
    called.add('connect:$deviceId');
    if (failConnect) throw StateError('cast connect failed');
    connected = deviceId;
  }

  @override
  Future<void> send(Map<String, dynamic> message) async {
    called.add('send');
    sent.add(message);
  }

  @override
  Future<void> disconnect() async {
    called.add('disconnect');
    connected = null;
  }
}

FotoItemDto _photo(String id) => FotoItemDto.fromJson({
  'id': id,
  'filename': 'IMG_$id.jpg',
  'type': 'photo',
  'additional': {
    'thumbnail': {'sm': 'sm_$id', 'cache_key': 'ck_$id'},
  },
});

Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester, {
  required PhotoCastBridge bridge,
  List<FotoItemDto>? items,
}) async {
  final t = FakeTransport(const {}, FakeTransport.table);
  t.downloadBytes = _png;
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fotoApiProvider.overrideWithValue(FotoApi(api)),
      photoCastBridgeProvider.overrideWithValue(bridge),
      serviceAvailabilityProvider.overrideWith(
        () => _FixedAvailability(
          ServiceAvailabilitySnapshot(
            states: {
              for (final s in StationService.values)
                s: AvailabilityState.available,
            },
            apis: const {},
            checkedAt: DateTime(2026, 9, 22),
          ),
        ),
      ),
    ],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), 
        home: PhotoViewerPage(items: items ?? [_photo('11'), _photo('12')]),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return (t: t, c: c);
}

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);

  final ServiceAvailabilitySnapshot snapshot;

  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

void main() {
  group('P65 投送 UI', () {
    testWidgets('桥说没有 Cast 能力 ⇒ 按钮根本不出现（也不乱发消息）', (tester) async {
      final bridge = FakeCastBridge(available: false);
      await _pump(tester, bridge: bridge);
      expect(find.byKey(const Key('photo-viewer-cast')), findsNothing);
      expect(bridge.called, ['availability']);
    });

    testWidgets('有能力但一台设备都没有 ⇒ 点按钮明确提示、不 connect/不 send', (tester) async {
      final bridge = FakeCastBridge(devices: const []);
      await _pump(tester, bridge: bridge);
      expect(find.byKey(const Key('photo-viewer-cast')), findsOneWidget);
      await tester.tap(find.byKey(const Key('photo-viewer-cast')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SnackBar), findsOneWidget);
      expect(bridge.called.any((c) => c.startsWith('connect')), isFalse);
      expect(bridge.sent, isEmpty);
    });

    testWidgets('选设备 → identify → 当前这张 goto_index；翻页再发 goto_index', (tester) async {
      final bridge = FakeCastBridge(
        devices: const [
          {'id': 'tv-1', 'name': '客厅电视'},
        ],
      );
      await _pump(tester, bridge: bridge);
      await tester.tap(find.byKey(const Key('photo-viewer-cast')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('photo-cast-device-picker')), findsOneWidget);
      await tester.tap(find.byKey(const Key('photo-cast-device-tv-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(bridge.connected, 'tv-1');
      expect(bridge.sent, hasLength(2), reason: 'identify + 当前这张');
      final identify = jsonDecode(jsonEncode(bridge.sent[0]));
      expect(identify['command'], 'identify');
      expect(identify['version'], 1);
      final goto = jsonDecode(jsonEncode(bridge.sent[1]));
      expect(goto['command'], 'goto_index');
      expect((goto['data'] as Map)['index'], 0);

      // 翻到第二张 → 再发一条 goto_index=1
      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final last = jsonDecode(jsonEncode(bridge.sent.last));
      expect(last['command'], 'goto_index');
      expect((last['data'] as Map)['index'], 1);
    });

    testWidgets('连接失败 ⇒ 明确报错，且不发 identify', (tester) async {
      final bridge = FakeCastBridge(
        devices: const [
          {'id': 'tv-1', 'name': '客厅电视'},
        ],
        failConnect: true,
      );
      await _pump(tester, bridge: bridge);
      await tester.tap(find.byKey(const Key('photo-viewer-cast')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('photo-cast-device-tv-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SnackBar), findsOneWidget);
      expect(bridge.sent, isEmpty, reason: 'connect 失败 ⇒ 一个投送消息都不发');
    });

    testWidgets('再点一次 → stop：发 disconnect 并断开桥', (tester) async {
      final bridge = FakeCastBridge(
        devices: const [
          {'id': 'tv-1', 'name': '客厅电视'},
        ],
      );
      await _pump(tester, bridge: bridge);
      await tester.tap(find.byKey(const Key('photo-viewer-cast')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('photo-cast-device-tv-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byKey(const Key('photo-viewer-cast')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(bridge.called.contains('disconnect'), isTrue);
      expect(bridge.connected, isNull);
      final last = jsonDecode(jsonEncode(bridge.sent.last));
      expect(last['command'], 'disconnect');
    });

    testWidgets('设备选择框点取消 ⇒ 零 connect、零 send', (tester) async {
      final bridge = FakeCastBridge(
        devices: const [
          {'id': 'tv-1', 'name': '客厅电视'},
        ],
      );
      await _pump(tester, bridge: bridge);
      await tester.tap(find.byKey(const Key('photo-viewer-cast')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('photo-cast-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(bridge.called.any((c) => c.startsWith('connect')), isFalse);
      expect(bridge.sent, isEmpty);
    });
  });
}
