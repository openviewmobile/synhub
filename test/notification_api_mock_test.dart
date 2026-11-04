// ★ **`SYNO.Personal.Notification.*` 只读族的 Mock 覆盖测试**
// （②聊天 的 API 级对照 · 第 31 轮）
//
// ## 这套用例要回答的两个问题
//  1. 官方 Chat APK 里列出的 `SYNO.Personal.Notification.{Mobile,Settings,Token}`
//     等 API，我方**真的**能打通吗？（不是我声称能，而是 Mock 上跑通）
//  2. `build_catalog.py` 新加的**文档方法表 overlay** 到底有没有让 Mock
//     从"方法名不校验"变成"真会校验"？
//     —— 这一条必须能被**反证**：故意写错方法名，Mock 要回 `103`。
//
// 全部打**内存 Mock Server**，不碰真机（规程 §5.1；本文件无任何真实会话）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/notification_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

void main() {
  late DsmCatalog catalog;
  late MockDsmBackend backend;
  late MockDsmTransport transport;
  late DsmWebApi web;
  late PersonalNotificationApi n;

  Future<void> boot() async {
    catalog = DsmCatalog.load();
    backend = MockDsmBackend(catalog: catalog);
    backend.login(username: 'u', admin: false);
    transport = MockDsmTransport(backend);
    web = DsmWebApi(transport);
    await web.discover();
    await web.login(account: 'u', password: 'x');
    n = PersonalNotificationApi(web);
  }

  setUp(boot);

  group('PN-1. 目录覆盖：10 个 API 全在，且方法表**真被校验**', () {
    test('★ kPersonalNotificationApis 有 10 个，且全部在权威目录里', () {
      expect(kPersonalNotificationApis, hasLength(10));
      final missing = kPersonalNotificationApis
          .where((a) => catalog[a] == null)
          .toList();
      expect(missing, isEmpty, reason: '这 10 个必须都在目录里');
    });

    test('★ 10 个的 methodsVerified 都是 true（不再是"不校验"）', () {
      for (final a in kPersonalNotificationApis) {
        final spec = catalog[a]!;
        expect(
          spec.methodsVerified,
          isTrue,
          reason: '$a 的方法表没被 overlay 填上 ⇒ 方法名写错也抓不住',
        );
        expect(spec.methods, isNotEmpty);
      }
    });

    test('★ 来源可分辨：标成 doc:… 而**不是** spk（不冒充二进制实证）', () {
      for (final a in kPersonalNotificationApis) {
        expect(
          catalog[a]!.source,
          'doc:api-server-authoritative',
          reason: '$a 的来源必须写明是文档，不能冒充 .lib 实证',
        );
      }
    });

    test('★ 文档说的"普通用户"已修正（不是 live 快照的"未知"）', () {
      for (final a in kPersonalNotificationApis) {
        expect(catalog[a]!.normal, isTrue, reason: '$a 应为普通用户');
        expect(catalog[a]!.adminOnly, isFalse, reason: '$a 不是仅管理员');
      }
    });

    test('版本区间与文档一致（Mobile v1-3 / Settings v1-2 / Conf v1-2…）', () {
      expect(catalog['SYNO.Personal.Notification.Mobile']!.maxVersion, 3);
      expect(catalog['SYNO.Personal.Notification.Settings']!.maxVersion, 2);
      expect(catalog['SYNO.Personal.Notification.Conf']!.maxVersion, 2);
      expect(catalog['SYNO.Personal.Notification.Device']!.maxVersion, 2);
      expect(catalog['SYNO.Personal.Notification.Event']!.maxVersion, 2);
      expect(catalog['SYNO.Personal.Notification.Token']!.maxVersion, 1);
      expect(catalog['SYNO.Personal.Notification.Filter']!.maxVersion, 1);
      expect(catalog['SYNO.Personal.Notification.GDPR']!.maxVersion, 1);
      expect(catalog['SYNO.Personal.Notification.Identifier']!.maxVersion, 1);
      expect(
        catalog['SYNO.Personal.Notification.VapidPublicKey']!.maxVersion,
        1,
      );
    });
  });

  group('PN-2. ★ 反证：方法名写错必须被 Mock 抓住（证明 overlay 生效）', () {
    test('不存在的 `get`（Event 只有 list/get/delete/send，Filter 只有 list/set）', () {
      // `Event` 在 v2 上是 `delete, list` —— **没有** `get`
      final r = backend.handle('entry.cgi', {
        'api': 'SYNO.Personal.Notification.Event',
        'method': 'get',
        'version': 2,
        '_sid': backend.sessions.first,
      });
      expect(r.errorCode, 103, reason: 'v2 的 Event 没有 get ⇒ 必须 103');
    });

    test('完全发明的方法名 ⇒ 103', () {
      final r = backend.handle('entry.cgi', {
        'api': 'SYNO.Personal.Notification.Mobile',
        'method': 'subscribe',
        'version': 3,
        '_sid': backend.sessions.first,
      });
      expect(r.errorCode, 103);
    });

    test('`pair` 只在 Mobile 上、且 v1-v3 都有 ⇒ 合法（不误杀）', () {
      final r = backend.handle('entry.cgi', {
        'api': 'SYNO.Personal.Notification.Mobile',
        'method': 'pair',
        'version': 3,
        '_sid': backend.sessions.first,
      });
      expect(r.errorCode, isNull, reason: 'pair 是文档给的真实方法，不该被拦');
    });

    test('★ 对照组：overlay **没**覆盖的 API 仍然不校验（说明差异真实存在）', () {
      // 随便挑一个 live 快照补入、`methodsVerified=false` 的 API
      final unverified = catalog.apis.entries
          .where((e) => !e.value.methodsVerified)
          .map((e) => e.key)
          .firstWhere((k) => !k.startsWith('SYNO.Personal.Notification'));
      final r = backend.handle('entry.cgi', {
        'api': unverified,
        'method': 'definitely_not_a_real_method',
        'version': catalog[unverified]!.minVersion,
        '_sid': backend.sessions.first,
      });
      expect(
        r.errorCode,
        isNull,
        reason: '$unverified 没有方法表 ⇒ 方法名不校验（这正是 overlay 存在的理由）',
      );
    });
  });

  group('PN-3. 只读族逐个驱动（10 个方法，无 101/103/105）', () {
    final calls = <String, Future<void> Function()>{
      'Settings/get': () => n.settingsGet(),
      'Conf/get': () => n.confGet(),
      'Device/list': () => n.deviceList(),
      'Event/list': () => n.eventList(),
      'Filter/list': () => n.filterList(),
      'GDPR/get': () => n.gdprGet(),
      'Identifier/get': () => n.identifierGet(),
      'Mobile/stat': () => n.mobileStat(),
      'Token/get': () => n.tokenGet(),
      'VapidPublicKey/get': () => n.vapidPublicKeyGet(),
    };

    for (final e in calls.entries) {
      test('${e.key} 组合合法', () async {
        await e.value();
        final r = backend.requests.last;
        expect(
          transport.last!.errorCode,
          isNull,
          reason:
              '${e.key} 被 Mock 拒绝：code=${transport.last!.errorCode}，'
              'api=${r.params['api']} method=${r.params['method']} '
              'version=${r.params['version']}',
        );
        // 版本必须落在目录声明的区间内（规程 §5.3：候选交给能力表收敛）
        final spec = catalog['${r.params['api']}']!;
        final v = int.parse('${r.params['version']}');
        expect(v, greaterThanOrEqualTo(spec.minVersion));
        expect(v, lessThanOrEqualTo(spec.maxVersion));
      });
    }

    test('★ 10 个方法覆盖 10 个 API —— 一个不漏', () {
      expect(calls, hasLength(10));
    });

    test('★ 协商到的是**服务器支持的版本**（Mobile 应挑到 v3，不是 v1）', () async {
      await n.mobileStat();
      expect('${backend.requests.last.params['version']}', '3');
      await n.settingsGet();
      expect('${backend.requests.last.params['version']}', '2');
      await n.tokenGet();
      expect('${backend.requests.last.params['version']}', '1');
    });
  });

  group('PN-4. §5.1 只读承诺（结构性保证）', () {
    test('★ 本文件所有请求的 method 都在只读白名单内', () async {
      await n.settingsGet();
      await n.confGet();
      await n.deviceList();
      await n.eventList();
      await n.filterList();
      await n.gdprGet();
      await n.identifierGet();
      await n.mobileStat();
      await n.tokenGet();
      await n.vapidPublicKeyGet();
      const readOnly = {'get', 'list', 'stat'};
      // 只看**本家族**的请求：`boot()` 阶段还有 `SYNO.API.Info/Query`
      // 和 `SYNO.API.Auth/Login`，它们不属于本文件要证明的范围。
      final mine = backend.requests
          .where(
            (r) =>
                '${r.params['api']}'.startsWith('SYNO.Personal.Notification'),
          )
          .toList();
      for (final r in mine) {
        expect(
          readOnly,
          contains('${r.params['method']}'),
          reason: '本文件只允许只读动词，出现 ${r.params['method']} 即违规',
        );
      }
      expect(mine, hasLength(10), reason: '10 个只读方法各发一次');
      // 且**真的**一个写动词都没发出去（对真机也一样安全的形状）
      expect(
        mine.where((r) => !readOnly.contains('${r.params['method']}')),
        isEmpty,
      );
    });

    test('★ 本文件不持有真实会话（全部请求都进了内存 Mock）', () {
      expect(transport, isA<MockDsmTransport>());
    });
  });
}
