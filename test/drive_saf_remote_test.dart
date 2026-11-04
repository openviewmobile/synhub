// ★★ ③Drive 第 221 轮 **D66「SAF 远端半边」** 用例：
//   ① 远端目录树镜像（纯离线，注入 lister）；
//   ② 合并索引（离线优先 + 云端条目拿到本地副本路径）；
//   ③ 端到端走 **Mock Server**：`Files/list` 递归 → 写进注入的索引 sink。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_entry_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/drive_saf_index.dart';
import 'package:synhub/src/features/files/drive_saf_remote.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

DriveEntryDto _e(
  String id,
  String name, {
  bool dir = false,
  int size = 10,
  int mtime = 1000,
  String type = 'application/pdf',
}) => DriveEntryDto(
  fileId: id,
  name: name,
  type: dir ? 'dir' : 'file',
  path: '/mydrive/$name',
  displayPath: '/mydrive/$name',
  parentId: '0',
  size: size,
  modifiedTime: mtime,
  createdTime: mtime,
  contentType: type,
  starred: false,
  shared: false,
  owner: '',
  canDownload: true,
  canPreview: true,
  canWrite: true,
  capabilities: const <String, Object?>{},
);

void main() {
  group('D66 远端镜像 · 目录树', () {
    test('递归到深度上限，目录也在索引里且用官方 :real: 前缀', () async {
      final tree = <String, List<DriveEntryDto>>{
        '/mydrive': [_e('d1', '项目', dir: true), _e('f1', 'a.pdf')],
        '/mydrive/项目': [_e('d2', '子', dir: true), _e('f2', 'b.docx')],
        '/mydrive/项目/子': [_e('f3', 'c.txt')],
      };
      final r = await buildSafRemoteIndex(
        folders: const ['/mydrive'],
        listFolder: (p) async => tree[p] ?? const [],
        maxDepth: 1,
      );
      final names = r.entries.map((e) => e.name).toList();
      expect(names, containsAll(['项目', 'a.pdf', '子', 'b.docx']));
      expect(names, isNot(contains('c.txt')), reason: 'maxDepth=1 不再往下');
      final dir = r.entries.firstWhere((e) => e.name == '项目');
      expect(dir.documentId, ':real:d1');
      expect(dir.mimeType, 'vnd.android.document/directory');
      expect(dir.size, 0);
      expect(dir.localPath, isEmpty, reason: '镜像条目没有本地副本');
      expect(
        SafDocumentId.kindOf(dir.documentId),
        SafDocumentKind.real,
        reason: '能和 :local: 区分开（Kotlin provider 靠前缀分派）',
      );
      expect(r.listedFolders, 2);
    });

    test('单个目录失败只记录，不中断其他目录', () async {
      final r = await buildSafRemoteIndex(
        folders: const ['/bad', '/good'],
        listFolder: (p) async {
          if (p == '/bad') throw StateError('103');
          return [_e('f1', 'ok.txt')];
        },
      );
      expect(r.entries.single.name, 'ok.txt');
      expect(r.errors.single, contains('/bad'));
      expect(r.errors.single, contains('103'));
    });

    test('条目上限生效（大盘不把索引写成几 MB）', () async {
      final r = await buildSafRemoteIndex(
        folders: const ['/mydrive'],
        listFolder: (p) async =>
            [for (var i = 0; i < 50; i++) _e('f$i', 'n$i.txt')],
        maxEntries: 5,
      );
      expect(r.entries, hasLength(5));
    });

    test('重复 fileId 去重', () async {
      final r = await buildSafRemoteIndex(
        folders: const ['/a', '/b'],
        listFolder: (p) async => [_e('same', 'x.txt')],
      );
      expect(r.entries, hasLength(1));
    });
  });

  group('D66 远端镜像 · 与离线索引合并', () {
    test('云端条目拿到本地副本路径（同名匹配）；离线条目一条不丢', () {
      final local = SafIndex(
        rootTitle: safOfflineRootTitle,
        entries: [
          SafIndexEntry(
            documentId: SafDocumentId.local('/data/a.pdf'),
            name: 'a.pdf',
            mimeType: 'application/pdf',
            size: 9,
            localPath: '/data/a.pdf',
          ),
        ],
      );
      final remote = SafIndex(
        rootTitle: safRemoteRootTitle,
        entries: [
          SafIndexEntry(
            documentId: SafDocumentId.real('f1'),
            name: 'a.pdf',
            mimeType: 'application/pdf',
          ),
          SafIndexEntry(
            documentId: SafDocumentId.real('f2'),
            name: 'b.pdf',
            mimeType: 'application/pdf',
          ),
        ],
      );
      final m = mergeSafIndexes(local: local, remote: remote);
      expect(m.entries, hasLength(3));
      expect(
        m.entries.firstWhere((e) => e.documentId == ':real:f1').localPath,
        '/data/a.pdf',
        reason: '云端条目挂上本地副本 ⇒ provider 能直接开',
      );
      expect(
        m.entries.firstWhere((e) => e.documentId == ':real:f2').localPath,
        isEmpty,
      );
      expect(m.rootTitle, safOfflineRootTitle);
    });

    test('JSON 往返（Kotlin 读的就是这个结构）', () {
      final m = mergeSafIndexes(
        local: SafIndex(rootTitle: safOfflineRootTitle, entries: const []),
        remote: SafIndex(
          rootTitle: safRemoteRootTitle,
          entries: [
            SafIndexEntry(
              documentId: SafDocumentId.real('f1'),
              name: 'a.pdf',
              mimeType: 'application/pdf',
              lastModified: 7,
            ),
          ],
        ),
      );
      final back = SafIndex.fromJson(m.toJson());
      expect(back.entries.single.documentId, ':real:f1');
      expect(back.entries.single.lastModified, 7);
      expect(back.rootTitle, safRemoteRootTitle, reason: '没有离线条目时用云端标题');
    });
  });

  group('D66 远端镜像 · 走 Mock Server 的端到端', () {
    test('DriveApi.list 递归 → 合并索引里既有离线也有 :real:', () async {
      final backend = MockDsmBackend(catalog: DsmCatalog.load());
      backend.login(username: 'u', admin: false);
      backend.fixture('SYNO.SynologyDrive.Files', 'list', (p) {
        final path = '${p['path']}';
        final items = path == '/mydrive'
            ? [
                {
                  'file_id': 'd1',
                  'name': '项目',
                  'type': 'dir',
                  'size': 0,
                  'modified_time': 5,
                },
                {
                  'file_id': 'f1',
                  'name': '离线.pdf',
                  'type': 'file',
                  'size': 12,
                  'modified_time': 6,
                },
              ]
            : <Object?>[];
        return {
          'success': true,
          'data': {'total': items.length, 'items': items, 'offset': 0},
        };
      });
      final web = DsmWebApi(MockDsmTransport(backend));
      await web.discover();
      await web.login(account: 'u', password: 'x');
      final api = DriveApi(web);

      final mirror = await buildSafRemoteIndex(
        folders: const ['/mydrive'],
        listFolder: (p) async => (await api.list(path: p, limit: 200)).items,
      );
      expect(mirror.errors, isEmpty);
      expect(mirror.entries.map((e) => e.name), containsAll(['项目', '离线.pdf']));

      final merged = mergeSafIndexes(
        local: SafIndex(
          rootTitle: safOfflineRootTitle,
          entries: [
            SafIndexEntry(
              documentId: SafDocumentId.local('/data/离线.pdf'),
              name: '离线.pdf',
              mimeType: 'application/pdf',
              localPath: '/data/离线.pdf',
            ),
          ],
        ),
        remote: SafIndex(rootTitle: safRemoteRootTitle, entries: mirror.entries),
      );
      expect(merged.entries, hasLength(3));
      expect(
        merged.entries.firstWhere((e) => e.documentId == ':real:f1').localPath,
        '/data/离线.pdf',
      );
      // 真发过请求（Mock 上核对 wire）
      expect(
        backend.requests.any(
          (r) => '${r.params['api']}' == 'SYNO.SynologyDrive.Files' &&
              '${r.params['method']}' == 'list',
        ),
        isTrue,
      );
    });
  });
}
