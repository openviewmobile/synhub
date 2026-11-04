// ConnectionService 真实链路验证（需要真实 NAS）
//
// 运行：
//   SYNO_LIVE=1 SYNO_NAS_QC=demo_admin-qq \
//   SYNO_NAS_ACCOUNT=demo_user SYNO_NAS_PASSWORD='…' \
//   flutter test test/connection_live_test.dart
//
// 覆盖：QuickConnect 发现 → 地址候选 → 探测连通 → 真实登录。
// 打洞已搁置（docs/holepunch-findings.md），这里走直连路径。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';

void main() {
  final live = Platform.environment['SYNO_LIVE'] == '1';
  final qc = Platform.environment['SYNO_NAS_QC'];
  final account = Platform.environment['SYNO_NAS_ACCOUNT'];
  final password = Platform.environment['SYNO_NAS_PASSWORD'];

  group('ConnectionService 真实链路', () {
    test('QuickConnect 解析 → 探测连通', () async {
      if (!live || qc == null) {
        markTestSkipped('需要 SYNO_LIVE=1 与 SYNO_NAS_QC');
        return;
      }

      final steps = <ConnectStep>[];
      final conn = await ConnectionService().connect(
        ServerProfile(kind: ServerAddressKind.quickConnect, value: qc),
        onStep: steps.add,
      );

      for (final s in steps) {
        // ignore: avoid_print
        print('  ${s.ok ? "OK  " : "FAIL"} ${s.text}');
      }

      expect(conn.endpoint.reachable, isTrue);
      expect(conn.endpoint.baseUrl, contains(':'));
      // 同局域网时应命中 lan 候选（官方 App 也是这么选的）
      // ignore: avoid_print
      print('  选中: ${conn.endpoint}');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('探测成功后能真实登录', () async {
      if (!live || qc == null || account == null || password == null) {
        markTestSkipped(
          '需要 SYNO_LIVE=1 / SYNO_NAS_QC / SYNO_NAS_ACCOUNT / SYNO_NAS_PASSWORD',
        );
        return;
      }

      final conn = await ConnectionService().connect(
        ServerProfile(kind: ServerAddressKind.quickConnect, value: qc),
      );

      final session = await conn.api.login(
        account: account,
        password: password,
        session: 'Chat',
      );

      expect(session.sid, isNotEmpty);
      // ignore: avoid_print
      print('  登录成功 sid=${session.sid.substring(0, 8)}… did=${session.did}');

      await conn.api.logout();
      await conn.api.transport.close();
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('直连地址也能连上（同一台 NAS 的局域网 IP）', () async {
      final url = Platform.environment['SYNO_NAS_URL'];
      if (!live || url == null) {
        markTestSkipped('需要 SYNO_LIVE=1 与 SYNO_NAS_URL');
        return;
      }

      final conn = await ConnectionService().connect(
        ServerProfile(kind: ServerAddressKind.direct, value: url),
      );
      expect(conn.endpoint.source, 'direct');
      await conn.api.transport.close();
    }, timeout: const Timeout(Duration(minutes: 1)));
  });
}
