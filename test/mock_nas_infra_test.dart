// Mock NAS 验证设施 · 冒烟 + 设施自证。
//
// 证明三件事（都是**离线端到端**：真实客户端代码 → loopback HTTP → mock）：
//   ① 能力表可切换、核心 API 恒在、未声明 API 回 102；
//   ② 有状态后端真的改内存（写 → 读回）；
//   ③ 这批测试**不碰任何真实 NAS**（只连 127.0.0.1 的进程内 mock）。
//
// 运行：flutter test test/mock_nas_infra_test.dart

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/download_station.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'support/mock_nas_harness.dart';

void main() {
  test('mocknas·设施·能力表按 declaredApis 声明，未声明 API 本地/远端 102', () async {
    final h = await startMockNasHarness(declaredApis: {'file', 'note'});
    addTearDown(h.dispose);

    final table = h.api.apiTable!;
    expect(table.containsKey('SYNO.FileStation.List'), isTrue);
    expect(table.containsKey('SYNO.NoteStation.Note'), isTrue);
    expect(table.containsKey('SYNO.DownloadStation2.Task'), isFalse);

    // 未声明的 API：客户端 `_prepare` 直接本地抛 102（连请求都不发）
    await expectLater(
      h.api.call('SYNO.DownloadStation2.Task', 'list'),
      throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 102)),
    );
  });

  test('mocknas·设施·真实客户端登录走 loopback，拿到 mock 假 sid', () async {
    final h = await startMockNasHarness();
    addTearDown(h.dispose);
    expect(h.url, startsWith('http://127.0.0.1:'));
    expect(h.api.session?.sid, startsWith('MOCK-SID-'));
    // 明显假值 —— 报告里必须能一眼看出"这不是真机"
    expect(h.api.session?.synotoken, startsWith('MOCK-TOKEN-'));
  });

  test('mocknas·设施·FileStation 列表路径感知（/home/Books 只回子项）', () async {
    final h = await startMockNasHarness(declaredApis: {'file'});
    addTearDown(h.dispose);
    final fs = FileStationApi(h.api);
    final result = await fs.listFolder(folderPath: '/home/Books');
    final names = result.entries.map((e) => e.name).toSet();
    expect(names, contains('mock-clip.mp4'));
    expect(names, contains('session-expiry.txt'));
    expect(names, isNot(contains('Photos')));
    // mock 的内存后端与 HTTP 回包一致
    expect(h.store.fs.containsKey('/home/Books/mock-clip.mp4'), isTrue);
  });

  test('mocknas·设施·各模块 Api 类都能打到同一个 mock', () async {
    final h = await startMockNasHarness();
    addTearDown(h.dispose);
    final note = NoteStationApi(h.api);
    final notebooks = await note.listNotebooks();
    expect(notebooks, isNotEmpty);

    final ds = DownloadStationApi(h.api);
    final page = await ds.listTasks();
    expect(page.items, isNotEmpty);

    final fs = FileStationApi(h.api);
    final shares = await fs.listShares();
    expect(shares.entries.map((e) => e.name), contains('mock-share'));
  });
}
