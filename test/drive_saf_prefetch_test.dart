// ★★ ③Drive 第 227 轮 **D66 SAF 云端条目按需下载（有界预取）** 用例。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/drive_saf_index.dart';
import 'package:synhub/src/features/files/drive_saf_prefetch.dart';
import 'package:synhub/src/features/files/drive_saf_remote.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

SafIndexEntry _real(
  String fileId,
  String name, {
  int size = 100,
  String mime = 'application/pdf',
}) => SafIndexEntry(
  documentId: SafDocumentId.real(fileId),
  name: name,
  mimeType: mime,
  size: size,
);

void main() {
  group('D66 预取 · 边界', () {
    test('超过单文件上限 ⇒ 不下载，只记 skippedTooBig', () async {
      final fetched = <String>[];
      final r = await prefetchSafCloudEntries(
        entries: [_real('a', 'big.pdf', size: 9 << 20), _real('b', 'ok.pdf')],
        policy: const SafPrefetchPolicy(maxFileBytes: 8 << 20),
        fetch: (id, name) async {
          fetched.add(id);
          return List<int>.filled(10, 1);
        },
        writeLocal: (doc, name, bytes) async => '/c/$doc',
      );
      expect(fetched, ['b'], reason: '大的那条不许发请求');
      expect(r.result.skippedTooBig, [':real:a']);
      expect(r.result.downloaded, [':real:b']);
    });

    test('文件个数上限 ⇒ 多出来的记 skippedByLimit', () async {
      final r = await prefetchSafCloudEntries(
        entries: [_real('1', '1.pdf'), _real('2', '2.pdf'), _real('3', '3.pdf')],
        policy: const SafPrefetchPolicy(maxFiles: 2),
        fetch: (id, name) async => List<int>.filled(4, 1),
        writeLocal: (doc, name, bytes) async => '/c/$doc',
      );
      expect(r.result.downloaded, hasLength(2));
      expect(r.result.skippedByLimit, [':real:3']);
    });

    test('总量上限：写到一半顶破就停（不写超限的那条）', () async {
      final r = await prefetchSafCloudEntries(
        entries: [_real('a', 'a.pdf'), _real('b', 'b.pdf'), _real('c', 'c.pdf')],
        policy: const SafPrefetchPolicy(maxTotalBytes: 10),
        fetch: (id, name) async => List<int>.filled(6, 1),
        writeLocal: (doc, name, bytes) async => '/c/$doc',
      );
      expect(r.result.downloaded, [':real:a'], reason: '6 + 6 > 10 ⇒ 第二条不写');
      expect(r.result.skippedByLimit, contains(':real:b'));
      expect(r.result.bytes, 6);
    });

    test('单条失败不影响其他条', () async {
      final r = await prefetchSafCloudEntries(
        entries: [_real('bad', 'bad.pdf'), _real('good', 'good.pdf')],
        fetch: (id, name) async {
          if (id == 'bad') throw StateError('网络断了');
          return List<int>.filled(3, 1);
        },
        writeLocal: (doc, name, bytes) async => '/c/$doc',
      );
      expect(r.result.failed, [':real:bad']);
      expect(r.result.downloaded, [':real:good']);
    });

    test('目录条目与非 :real: 条目都不碰', () async {
      final fetched = <String>[];
      final r = await prefetchSafCloudEntries(
        entries: [
          _real('d', '文件夹', mime: 'vnd.android.document/directory'),
          SafIndexEntry(
            documentId: SafDocumentId.local('/x/a.pdf'),
            name: 'a.pdf',
            mimeType: 'application/pdf',
          ),
        ],
        fetch: (id, name) async {
          fetched.add(id);
          return const <int>[];
        },
        writeLocal: (doc, name, bytes) async => '/c/$doc',
      );
      expect(fetched, isEmpty);
      expect(r.localPaths, isEmpty);
      expect(r.result.considered, 0);
    });

    test('策略关闭 ⇒ 什么都不做（不请求、不写盘）', () async {
      var called = 0;
      final r = await prefetchSafCloudEntries(
        entries: [_real('a', 'a.pdf')],
        policy: SafPrefetchPolicy.off,
        fetch: (id, name) async {
          called += 1;
          return const <int>[];
        },
        writeLocal: (doc, name, bytes) async => '/c/$doc',
      );
      expect(called, 0);
      expect(r.localPaths, isEmpty);
    });

    test('成功路径：documentId → 本地路径，且带对了 fileId 与名字', () async {
      final seen = <String>[];
      final r = await prefetchSafCloudEntries(
        entries: [_real('f9', '报告.pdf', size: 50)],
        fetch: (id, name) async {
          seen.add('$id|$name');
          return List<int>.filled(50, 7);
        },
        writeLocal: (doc, name, bytes) async {
          expect(bytes, hasLength(50));
          return '/cache/f9_报告.pdf';
        },
      );
      expect(seen, ['f9|报告.pdf']);
      expect(r.localPaths, {':real:f9': '/cache/f9_报告.pdf'});
      expect(r.result.bytes, 50);
      expect(r.result.toJson()['downloaded'], 1);
    });

    test('真实写盘器：落到 <cache>/<fileId>_<名字>，且清理非法字符', () async {
      final dir = Directory.systemTemp.createTempSync('d66_prefetch');
      final w = SafPrefetchFileWriter(dir.path);
      final p1 = await w.write(':real:f1', 'a/b.pdf', [1, 2, 3]);
      expect(p1, '${dir.path}/f1_a_b.pdf');
      expect(File(p1).readAsBytesSync(), [1, 2, 3]);
      dir.deleteSync(recursive: true);
    });
  });

  group('D66 预取 · 合并进 SAF 索引', () {
    test('预取到的本地路径优先于"按文件名猜"', () {
      final merge = mergeSafIndexes(
        local: SafIndex(
          rootTitle: safOfflineRootTitle,
          entries: [
            SafIndexEntry(
              documentId: SafDocumentId.local('/data/报告.pdf'),
              name: '报告.pdf',
              mimeType: 'application/pdf',
              localPath: '/data/报告.pdf',
            ),
          ],
        ),
        remote: SafIndex(
          rootTitle: safRemoteRootTitle,
          entries: [_real('f1', '报告.pdf')],
        ),
        localByDocumentId: const {':real:f1': '/cache/f1_报告.pdf'},
      );
      expect(
        merge.entries.firstWhere((e) => e.documentId == ':real:f1').localPath,
        '/cache/f1_报告.pdf',
        reason: '预取的副本才是最准的那个',
      );
    });
  });

  group('D66 预取 · 端到端（条目来自 Mock Server 的 Files/list）', () {
    test('Mock 列目录 → 预取拿到的 fileId 与 Mock 返回的一致', () async {
      final backend = MockDsmBackend(catalog: DsmCatalog.load());
      backend.login(username: 'u', admin: false);
      backend.fixture('SYNO.SynologyDrive.Files', 'list', (p) => {
        'success': true,
        'data': {
          'total': 1,
          'offset': 0,
          'items': [
            {
              'file_id': 'MOCK77',
              'name': '云端.pdf',
              'type': 'file',
              'size': 12,
              'modified_time': 9,
            },
          ],
        },
      });
      final web = DsmWebApi(MockDsmTransport(backend));
      await web.discover();
      await web.login(account: 'u', password: 'x');
      final api = DriveApi(web);

      final mirror = await buildSafRemoteIndex(
        folders: const ['/mydrive'],
        listFolder: (p) async => (await api.list(path: p, limit: 200)).items,
      );
      final asked = <String>[];
      final r = await prefetchSafCloudEntries(
        entries: mirror.entries,
        fetch: (id, name) async {
          asked.add('$id|$name');
          return List<int>.filled(12, 1);
        },
        writeLocal: (doc, name, bytes) async => '/cache/$doc',
      );
      expect(asked, ['MOCK77|云端.pdf']);
      expect(r.localPaths.keys, [':real:MOCK77']);
      // 下载直链用的是同一个 fileId（真实链路 = downloadUrl + getBytes）
      expect(api.downloadUrl(fileId: 'MOCK77', isPreview: false), contains('MOCK77'));
    });
  });
}
