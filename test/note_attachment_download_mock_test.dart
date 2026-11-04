// ★★★ 第 118 轮 / 台账 J9：笔记附件**二进制下载**（`Note/download` v1）。
//
// 官方取证：
//   * SPK 权威方法表 `NoteStation/webapi/SYNO.NoteStation.lib`：
//     `SYNO.NoteStation.Note` 的 v1 方法含 **`download`**，且带
//     `"allowDownload": true, "skipCheckIP": true`（下载类特例）；
//   * APK `net/ApiNSNote$Method` 枚举同样有 `"download"`。
// 我方目录（`tool/mock_dsm/catalog.json`）**早就**收录了 `download`（v1..v4），
// 但客户端从未调用它 ⇒ J9 的"有附件那一支"缺的正是这个下载。
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/data/note_api.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.NoteStation.Note': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
};

void main() {
  group('118. 笔记附件下载（Note/download v1）', () {
    late FakeTransport t;
    late NoteStationApi notes;

    Future<void> boot() async {
      t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.downloadBytes = List<int>.filled(64, 7);
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      notes = NoteStationApi(api);
    }

    test('★ URL 参数逐字：api/method/version/object_id/file_id', () async {
      await boot();
      final bytes = await notes.downloadAttachment('n1', 'f9');
      expect(bytes, hasLength(64));
      expect(t.downloads, hasLength(1));
      final url = t.downloads.single;
      expect(url, contains('api=SYNO.NoteStation.Note'));
      expect(url, contains('method=download'));
      expect(url, contains('version=1'), reason: 'download 在 v1 就存在（权威方法表）');
      expect(url, contains('object_id=n1'));
      expect(url, contains('file_id=f9'));
    });

    test('★ 带 _sid（附件是鉴权下载，缺了服务端回 119）', () async {
      await boot();
      await notes.downloadAttachment('n1', 'f9');
      expect(t.downloads.single, contains('_sid='));
    });

    test('★ 传 onProgress 不改变行为（进度由传输层回放）', () async {
      await boot();
      var called = 0;
      final bytes = await notes.downloadAttachment(
        'n1',
        'f9',
        onProgress: (received, total) => called++,
      );
      expect(bytes, hasLength(64));
      expect(t.downloads, hasLength(1));
    });

    test('★ 服务端失败 ⇒ 抛（不吞成"空文件"）', () async {
      await boot();
      t.failures['method=download'] = 404;
      await expectLater(
        notes.downloadAttachment('n1', 'f9'),
        throwsA(isA<DsmTransportException>()),
      );
    });
  });
}
