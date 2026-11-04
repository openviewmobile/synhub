// ⑥下载 **D-6d**：F2 eMule 服务器/Kad 管理（**管理员**，Mock 核实）。
//
// 新规 B1：涉及管理员的接口一律走 Mock Server 验证 ⇒ 本文件就是 F2 的
// Mock 证据。参数逐字来自官方 `ui/download.js` 的 aMule ServerGridPanel。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/dsm/webapi.dart';

import 'download_gaps_g3_test.dart' show boot, callOf;

const _serverApi = 'SYNO.DownloadStation2.eMule.Server';

/// 管理员接口也必须先在能力表里存在（`SYNO.API.Info`）才谈得上调用。
const _serverTable = {
  _serverApi: {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
};

void main() {
  group('F2 eMule 服务器/Kad（管理员，Mock 核实）', () {
    test('list：v1 + offset/limit，root results，字段解析', () async {
      final (ds, t) = await boot(
        apiTable: _serverTable,
        responses: {
          '$_serverApi.list': {
            'results': [
              {
                'id': 's1',
                'ip': '1.2.3.4',
                'port': 4661,
                'name': 'DonkeyServer',
                'description': 'ds',
                'ping': 30,
                'user_count': 100,
                'user_max': 200,
                'file_count': 1000,
              },
            ],
            'total': 1,
          },
        },
      );
      final page = await ds.emuleServers(offset: 0, limit: 50);
      final call = callOf(t, 'list');
      expect(call['api'], _serverApi);
      expect(call['version'], '1');
      expect(call['offset'], 0);
      expect(call['limit'], 50);
      expect(page.total, 1);
      final s = page.items.single;
      expect(s.id, 's1');
      expect(s.ip, '1.2.3.4');
      expect(s.port, 4661);
      expect(s.userCount, 100);
      expect(s.userMax, 200);
      expect(s.fileCount, 1000);
    });

    test('get_status：宽容解析（子对象与顶层两种形态都要认）', () async {
      final (ds, t) = await boot(
        apiTable: _serverTable,
        responses: {
          '$_serverApi.get_status': {
            'ed2k': {'status': 'connected', 'ip': '5.6.7.8', 'port': 4661},
            'kad': {'status': 'connecting'},
          },
        },
      );
      final st = await ds.emuleServerStatus();
      expect(callOf(t, 'get_status')['api'], _serverApi);
      expect(st.ed2kStatus, 'connected');
      expect(st.kadStatus, 'connecting');
      expect(st.ed2kIp, '5.6.7.8');
      expect(st.ed2kPort, 4661);

      final (ds2, _) = await boot(
        apiTable: _serverTable,
        responses: {
          '$_serverApi.get_status': {
            'ed2k_status': 'disconnected',
            'kad_status': 'disconnected',
          },
        },
      );
      final st2 = await ds2.emuleServerStatus();
      expect(st2.ed2kStatus, 'disconnected');
      expect(st2.kadStatus, 'disconnected');
    });

    test('connect：`{id}`；connect_kad：无参', () async {
      final (ds, t) = await boot(
        apiTable: _serverTable,
        responses: {
          '$_serverApi.connect': {'ok': true},
          '$_serverApi.connect_kad': {'ok': true},
        },
      );
      await ds.emuleConnect('s1');
      expect(callOf(t, 'connect')['id'], 's1');
      await ds.emuleConnectKad();
      final kad = callOf(t, 'connect_kad');
      expect(kad['api'], _serverApi);
      expect(kad.keys.where((k) => k != '_sid' && k != 'api' && k != 'method' && k != 'version'), isEmpty);
    });

    test('disconnect：`{type:"all"}`', () async {
      final (ds, t) = await boot(
        apiTable: _serverTable,
        responses: {
          '$_serverApi.disconnect': {'ok': true},
        },
      );
      await ds.emuleDisconnect();
      expect(callOf(t, 'disconnect')['type'], 'all');
    });

    test('delete：`id` 是数组（JSON 文本）；空选不发', () async {
      final (ds, t) = await boot(
        apiTable: _serverTable,
        responses: {
          '$_serverApi.delete': {'ok': true},
        },
      );
      await ds.emuleDeleteServers(['s1', 's2']);
      expect(callOf(t, 'delete')['id'], jsonEncode(['s1', 's2']));
      await expectLater(
        ds.emuleDeleteServers(const []),
        throwsA(isA<DsmApiException>()),
      );
      expect(t.calls.where((c) => c['method'] == 'delete').length, 1);
    });

    test('add：`{ip, port}`（name 有才发）；空 ip 不发', () async {
      final (ds, t) = await boot(
        apiTable: _serverTable,
        responses: {
          '$_serverApi.add': {'ok': true},
        },
      );
      await ds.emuleAddServer(ip: ' 9.9.9.9 ', port: 4661);
      var call = callOf(t, 'add');
      expect(call['ip'], '9.9.9.9');
      expect(call['port'], 4661);
      expect(call.containsKey('name'), isFalse);

      await ds.emuleAddServer(ip: '9.9.9.10', port: 4662, name: ' MyServer ');
      call = callOf(t, 'add');
      expect(call['name'], 'MyServer');

      await expectLater(
        ds.emuleAddServer(ip: '   ', port: 4661),
        throwsA(isA<DsmApiException>()),
      );
      expect(t.calls.where((c) => c['method'] == 'add').length, 2);
    });
  });
}
