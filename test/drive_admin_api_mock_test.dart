// ★★ ③Drive 管理员接口的 **Mock Server 验证** —— 第 233 轮（结项必交项 B1）。
//
// 目录（反编译 SPK 的权威 `webapi/*.lib`）里，Drive 家族的 `adminOnly: true`
// 接口共 **17 个**（不含 `SynologyDriveShareSync` 家族）。这些在真机上我方
// **非管理员根本验不了** —— 这正是自建 Mock Server 的意义。
//
// 本文件四件事：
//   ① 用目录交叉核对"管理员接口就是这 17 个"，不多不少（防止悄悄漏掉）；
//   ② 逐接口：非管理员会话调 ⇒ Mock 必须回 `105`（门控真的存在）；
//   ③ 逐接口：管理员会话调 ⇒ 拿得到 fixture 数据（管理员路径真的走得通）；
//   ④ 客户端**调用面**核对：`lib/` 只碰其中 5 个（Config/DBUsage/Privilege/
//      Profiles/Settings），且使用它们的界面必须走 `admin_gate`。
//
// 官方手机端**没有**共享报表/统计/Webhook 等控制台功能的界面：这些接口
// 客户端不实现（结项报告里如实登记，不是"漏做"）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

/// 目录里 Drive 家族的**全部** adminOnly 接口（17 个）
const Map<String, (int, String)> kDriveAdminProbe = {
  'SYNO.SynologyDrive.Activation': (1, 'get'),
  'SYNO.SynologyDrive.AppIntegration': (1, 'list'),
  'SYNO.SynologyDrive.Config': (1, 'get'),
  'SYNO.SynologyDrive.DBUsage': (1, 'status'),
  'SYNO.SynologyDrive.Dashboard': (1, 'top_access_files'),
  'SYNO.SynologyDrive.HybridShare.Privilege': (1, 'list'),
  'SYNO.SynologyDrive.Index': (1, 'get_native_client_status'),
  'SYNO.SynologyDrive.KeyManagement': (1, 'list'),
  'SYNO.SynologyDrive.Metrics.Token': (1, 'get'),
  'SYNO.SynologyDrive.Migration.UserHome': (1, 'start'),
  'SYNO.SynologyDrive.NodeLockingOption': (1, 'get'),
  'SYNO.SynologyDrive.Privilege': (1, 'list'),
  'SYNO.SynologyDrive.Profiles': (1, 'list'),
  'SYNO.SynologyDrive.Settings': (1, 'list'),
  'SYNO.SynologyDrive.Sharing.Report': (1, 'list_target'),
  'SYNO.SynologyDrive.Statistics': (1, 'get'),
  'SYNO.SynologyDrive.Webhooks': (1, 'create'),
};

/// 客户端**确实调用**的管理员接口（其余 12 个是网页控制台功能，手机端不实现）
const List<String> kDriveAdminApisUsedByClient = [
  'SYNO.SynologyDrive.Config',
  'SYNO.SynologyDrive.DBUsage',
  'SYNO.SynologyDrive.Privilege',
  'SYNO.SynologyDrive.Profiles',
  'SYNO.SynologyDrive.Settings',
];

void main() {
  group('Drive 管理员接口 · 目录事实', () {
    late DsmCatalog catalog;

    setUpAll(() => catalog = DsmCatalog.load());

    test('目录里 Drive 家族的 adminOnly 就是这 17 个（多一个少一个都算账不对）', () {
      final actual = catalog.apis.values
          .where(
            (a) =>
                a.name.startsWith('SYNO.SynologyDrive') &&
                !a.name.startsWith('SYNO.SynologyDriveShareSync') &&
                a.adminOnly,
          )
          .map((a) => a.name)
          .toList()
        ..sort();
      final expected = kDriveAdminProbe.keys.toList()..sort();
      expect(actual, expected);
      expect(actual, hasLength(17));
    });

    test('每个管理员接口的 allowUser 只含 admin.*，且 authLevel > 0', () {
      kDriveAdminProbe.forEach((api, _) {
        final spec = catalog.apis[api]!;
        expect(spec.authLevel, greaterThan(0));
        expect(spec.allowUser, isNotEmpty);
        expect(
          spec.allowUser.every((u) => u.startsWith('admin.')),
          isTrue,
          reason: '$api 的 allowUser 应全是 admin.*：${spec.allowUser}',
        );
      });
    });

    test('探查用的方法与版本确实在目录里（版本也不许瞎写）', () {
      kDriveAdminProbe.forEach((api, probe) {
        final spec = catalog.apis[api]!;
        final methods = spec.methods[probe.$1];
        expect(methods, isNotNull, reason: '$api 没有 v${probe.$1}');
        expect(
          methods,
          contains(probe.$2),
          reason: '$api v${probe.$1} 没有 ${probe.$2}',
        );
      });
    });
  });

  group('Drive 管理员接口 · 门控（Mock）', () {
    test('非管理员会话 ⇒ 17 个接口一律 105', () async {
      final backend = MockDsmBackend(catalog: DsmCatalog.load());
      backend.login(username: 'normal', admin: false);
      final web = DsmWebApi(MockDsmTransport(backend));
      await web.discover();
      await web.login(account: 'normal', password: 'x');
      for (final entry in kDriveAdminProbe.entries) {
        await expectLater(
          web.call(
            entry.key,
            entry.value.$2,
            preferredVersion: entry.value.$1,
          ),
          throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 105)),
          reason: '${entry.key} 对非管理员必须 105',
        );
      }
    });

    test('管理员会话 ⇒ 17 个接口都能拿到 fixture 数据', () async {
      final backend = MockDsmBackend(catalog: DsmCatalog.load());
      backend.login(username: 'admin', admin: true);
      for (final entry in kDriveAdminProbe.entries) {
        backend.fixture(entry.key, entry.value.$2, (p) {
          return {
            'success': true,
            'data': {'probe': entry.key},
          };
        });
      }
      final web = DsmWebApi(MockDsmTransport(backend));
      await web.discover();
      await web.login(account: 'admin', password: 'x');
      final got = <String>[];
      for (final entry in kDriveAdminProbe.entries) {
        final data = await web.call(
          entry.key,
          entry.value.$2,
          preferredVersion: entry.value.$1,
        );
        expect(data['probe'], entry.key);
        got.add(entry.key);
      }
      expect(got, hasLength(17));
    });
  });

  group('Drive 管理员接口 · 客户端调用面', () {
    test('客户端只碰 5 个管理员接口（其余 12 个是控制台功能，手机端不实现）', () async {
      // ★ r447：**一次扫盘**判 17 个名字（原来每个名字扫一遍 `lib/` = 17×IO，
      // 全量并发下会顶到 30s 默认超时 ⇒ 假红）。判据一模一样：名字在 `lib/` 里出现过。
      final byNeedle = await _libFilesByNeedle(kDriveAdminProbe.keys);
      final used = byNeedle.entries
          .where((e) => e.value.isNotEmpty)
          .map((e) => e.key)
          .toSet();
      final expected = [...kDriveAdminApisUsedByClient]..sort();
      final actual = used.toList()..sort();
      expect(
        actual,
        expected,
        reason: '客户端调用面变了 ⇒ 台账/结项报告必须同步（不是"少一个也无所谓"）',
      );
    });

    test('调这些接口的界面必须走 admin_gate（门控不许散落）', () async {
      // 同上：一次扫盘拿全部命中（7 个名字原来扫 7 遍）
      final byNeedle = await _libFilesByNeedle(
        [
          ...kDriveAdminApisUsedByClient,
          'drive_admin_api.dart',
          'DriveAdminApi',
        ],
        underFeatures: true,
      );
      final users = <String>{};
      for (final api in kDriveAdminApisUsedByClient) {
        users.addAll(byNeedle[api] ?? const <String>[]);
      }
      // 界面通常通过数据层包装类调用（不在 UI 里写裸 API 名）——两种都算
      users.addAll(byNeedle['drive_admin_api.dart'] ?? const <String>[]);
      users.addAll(byNeedle['DriveAdminApi'] ?? const <String>[]);
      expect(users, isNotEmpty, reason: '至少要有一个界面用到这些数据');
      for (final f in users) {
        final s = await File(f).readAsString();
        expect(
          s.contains('admin_gate.dart') || s.contains('AdminGate'),
          isTrue,
          reason: '$f 调用了管理员接口但没走 admin_gate',
        );
      }
    });
  });
}

/// 一次扫盘，返回"每个名字命中了哪些文件"（`lib/` 或 `lib/src/features/`）。
///
/// ★ r447：把"每个名字扫一遍"改成"一遍里判所有名字"，判据不变、IO 降一个数量级。
Future<Map<String, List<String>>> _libFilesByNeedle(
  Iterable<String> needles, {
  bool underFeatures = false,
}) async {
  final list = needles.toList();
  final out = <String, List<String>>{for (final n in list) n: <String>[]};
  final dir = Directory(underFeatures ? 'lib/src/features' : 'lib');
  if (!dir.existsSync()) return out;
  await for (final e in dir.list(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final s = await e.readAsString();
    for (final n in list) {
      // ★ 每个文件只读一次、所有名字在这**一份内容**上判 —— 但**不截断**结果：
      // 原来"某接口被哪些文件用到"的判据必须逐文件给全（否则 admin_gate 那条会漏检）。
      if (s.contains(n)) out[n]!.add(e.path);
    }
  }
  for (final v in out.values) {
    v.sort();
  }
  return out;
}

