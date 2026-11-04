// `SYNO.FileStation.Timeout / avoid` v1 —— **长任务期间给会话保活**。
//
// ## 这条 API 是"文件家族 46 个 API"机械对差里挑出来的
// 真机 `SYNO.FileStation.*` 共 **46** 个，我方覆盖 31 个，剩 15 个。
// 用 **DSfile smali 全量 grep** 复核后发现：**15 个在官方安卓端一个都不用**
// （对照组 `List`/`Upload`/`PhotoUpload` 都命中）。
//
// ⇒ 那 15 个里绝大多数记 `➖ 非缺口（官方也不用）`。**但 `Timeout/avoid` 例外**：
// 它不属于"对齐 DSfile"，而属于**移动端特有缺口** —— NAS 空闲超时真机实测
// **15 分钟**，而压缩/解压/MD5 能跑十几分钟；手机上"放着让它跑完"比网页端常见。
// 官方 File Station 的 **Web 前端**正是靠它续命。
//
// ## 权威性
// * `.lib`：`SYNO.FileStation.Timeout` v1，方法只有 `avoid`；
// * 真机只读探针（普通用户）：`avoid v1` → `200 {"success":true}`。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

void main() {
  group('FA1. 目录事实', () {
    late DsmCatalog catalog;
    setUpAll(() => catalog = DsmCatalog.load());

    test('SYNO.FileStation.Timeout v1 有 avoid，且普通用户可及', () {
      final spec = catalog['SYNO.FileStation.Timeout'];
      expect(spec, isNotNull);
      expect(spec!.versionsWith('avoid'), contains(1));
      expect(spec.normal, isTrue, reason: '真机普通用户实测通了');
      expect(spec.path, 'entry.cgi');
    });

    test('★ 方法表里**只有** avoid（别乱发明方法名）', () {
      final spec = catalog['SYNO.FileStation.Timeout']!;
      expect(spec.methodsAt(1), ['avoid']);
    });

    test('★ 分母口径：真机快照 46 个 / 权威目录 47 个（联合，多 SPK 独有的）', () {
      // ⚠️ 两个口径**必须分清**，混用会把账算错：
      //   * `test/fixtures/api_table.json` = **真机 `API.Info` 快照**（1047）
      //     → `SYNO.FileStation.*` **46** 个，这是"这台机器真有什么"；
      //   * `catalog.json` = **联合**（SPK 的 `.lib` ∪ 真机快照）
      //     → **47** 个，多出的是 `SYNO.FileStation.SharingCustom`
      //     （SPK 里有、本机没装）。
      final live = jsonDecode(
        File('test/fixtures/api_table.json').readAsStringSync(),
      );
      final liveData = (live['data'] ?? live) as Map<String, dynamic>;
      final liveFs = liveData.keys
          .where((a) => a.startsWith('SYNO.FileStation'))
          .toList();
      expect(liveFs, hasLength(46), reason: '真机快照口径');

      final catFs = catalog.apis.keys
          .where((a) => a.startsWith('SYNO.FileStation'))
          .toList();
      expect(catFs, hasLength(47), reason: '权威目录是联合');
      expect(catFs.toSet().difference(liveFs.toSet()), {
        'SYNO.FileStation.SharingCustom',
      }, reason: '差集必须只有 SPK 独有的那一个 —— 多出别的说明快照或目录被改坏了');
      // 覆盖数由机械对差脚本产出（`docs/dsfile-apk-parity.md`），
      // **故意不在这里硬编码**，避免数字漂移变成"用例跟着代码走"。
    });
  });

  group('FA2. 真实 FileStationApi × Mock Server', () {
    late DsmCatalog catalog;
    late MockDsmBackend backend;
    late MockDsmTransport transport;
    late FileStationApi fs;

    setUp(() async {
      catalog = DsmCatalog.load();
      backend = MockDsmBackend(catalog: catalog);
      backend.login(username: 'u', admin: false);
      transport = MockDsmTransport(backend);
      final web = DsmWebApi(transport);
      await web.discover();
      await web.login(account: 'u', password: 'x');
      fs = FileStationApi(web);
    });

    test('avoidTimeout() 发出 v1 的 avoid，组合通过权威校验', () async {
      await fs.avoidTimeout();
      final req = backend.requests.lastWhere(
        (r) => r.params['api'] == 'SYNO.FileStation.Timeout',
      );
      expect(req.params['method'], 'avoid');
      expect('${req.params['version']}', '1');
      expect(transport.last!.errorCode, isNull, reason: '不该被 mock 拒绝');
    });

    test('★ 方法名写错就被 mock 抓住（证明这条用例不是必过）', () {
      final r = backend.handle('entry.cgi', {
        'api': 'SYNO.FileStation.Timeout',
        'method': 'keepalive', // 发明的方法名
        'version': 1,
        '_sid': backend.sessions.first,
      });
      expect(r.errorCode, 103);
    });
  });

  group('FA3. 接线：只在**有未完成任务**时才保活', () {
    test('fileTasksProvider 的保活调用受"未完成任务"门控', () {
      // 读源码切片断言（与 M68/M73 的接线守卫同一套手法）：
      // 防"无条件每次都发保活"（那会让每次轮询都多一个请求）。
      final src = _read('lib/src/features/files/file_providers.dart');
      final i = src.indexOf('final fileTasksProvider');
      expect(i, greaterThan(0));
      final body = src.substring(i, src.indexOf('}, retry: _noRetry)', i));
      expect(
        body,
        contains('any((t) => !t.finished)'),
        reason: '必须有"还有没跑完的任务"这个门控',
      );
      expect(body, contains('api.avoidTimeout()'));
      expect(body, contains('catchError'), reason: '保活是尽力而为：失败不能影响任务列表');
    });

    test('avoidTimeout 确实用 v1（v2 不在方法表里）', () {
      final src = _read('lib/src/data/filestation_api.dart');
      final i = src.indexOf('Future<void> avoidTimeout()');
      expect(i, greaterThan(0));
      final body = src.substring(i, i + 260);
      expect(body, contains("'SYNO.FileStation.Timeout'"));
      expect(body, contains("'avoid'"));
      expect(body, contains('preferredVersion: 1'));
    });
  });
}

String _read(String p) => File(p).readAsStringSync();
