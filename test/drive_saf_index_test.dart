// ★★ ③Drive 第 213 轮 **D66「SAF / ContentProvider 暴露」** 的离线用例。
//
// 覆盖三件事：
//   ① **id 方案**：官方 `DriveDocumentsProvider` 的 `virtualTop` / `:real:` /
//      `:label:` / `:local:` / `:create_folder:` 前缀逐个对齐（逐字）；
//   ② **索引**：只有**真的在本地有副本**的离线文件才进索引（别的进索引 =
//      给用户一个点不开的条目）；JSON 落盘/读回；Dart↔Kotlin 的文件契约；
//   ③ **接线**：登记/取消登记/清空都会同步索引（用可注入的 sink 断言，
//      不碰 path_provider 平台通道），并核验 `AndroidManifest.xml` +
//      `DriveDocumentsProvider.kt` 里的 authority 与 Dart 侧**三处一致**。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/files/drive_saf_index.dart';
import 'package:synhub/src/features/files/file_offline_pin.dart';

OfflinePinEntry _pin(
  String path, {
  String name = '',
  int size = 0,
  int pinnedAt = 0,
  String localPath = '',
}) => OfflinePinEntry(
  path: path,
  name: name.isEmpty ? path.split('/').last : name,
  size: size,
  pinnedAt: pinnedAt,
  localPath: localPath,
);

void main() {
  group('D66 · 文档 id 方案（对齐官方 smali 常量）', () {
    test('前缀与虚拟根逐字一致', () {
      expect(SafDocumentId.virtualTop, 'virtualTop');
      expect(SafDocumentId.realPrefix, ':real:');
      expect(SafDocumentId.labelPrefix, ':label:');
      expect(SafDocumentId.localPrefix, ':local:');
      expect(SafDocumentId.createFolderPrefix, ':create_folder:');
      expect(SafDocumentId.real('42'), ':real:42');
      expect(SafDocumentId.local('/data/x/a.docx'), ':local:/data/x/a.docx');
    });

    test('kindOf / payloadOf 覆盖全部五种 + 未知', () {
      expect(SafDocumentId.kindOf('virtualTop'), SafDocumentKind.virtualTop);
      expect(SafDocumentId.payloadOf('virtualTop'), '');
      expect(SafDocumentId.kindOf(':real:f1'), SafDocumentKind.real);
      expect(SafDocumentId.payloadOf(':real:f1'), 'f1');
      expect(SafDocumentId.kindOf(':label:9'), SafDocumentKind.label);
      expect(SafDocumentId.payloadOf(':label:9'), '9');
      expect(SafDocumentId.kindOf(':local:/a/b'), SafDocumentKind.local);
      expect(SafDocumentId.payloadOf(':local:/a/b'), '/a/b');
      expect(SafDocumentId.kindOf(':create_folder:x'), SafDocumentKind.createFolder);
      expect(SafDocumentId.kindOf('whatever'), SafDocumentKind.unknown);
      expect(SafDocumentId.payloadOf('whatever'), isNull);
    });
  });

  group('D66 · 索引构造（只收真在本地有副本的）', () {
    test('没下载的登记项不进索引；下载了才进', () {
      final pins = [
        _pin('/home/Drive/a.docx', localPath: ''),
        _pin('/home/Drive/b.pdf', size: 12, pinnedAt: 111, localPath: '/data/b.pdf'),
      ];
      final index = buildSafIndex(
        pins,
        isFile: (p) => p == '/data/b.pdf',
        mimeOf: (_) => 'application/pdf',
      );
      expect(index, hasLength(1));
      final e = index.single;
      expect(e.documentId, ':local:/data/b.pdf');
      expect(e.name, 'b.pdf');
      expect(e.mimeType, 'application/pdf');
      expect(e.size, 12);
      expect(e.lastModified, 111);
      expect(e.localPath, '/data/b.pdf');
    });

    test('登记项说本地有副本、但文件其实不在 ⇒ 不进索引（防点开 404）', () {
      final index = buildSafIndex(
        [_pin('/home/Drive/x.txt', localPath: '/gone/x.txt')],
        isFile: (_) => false,
      );
      expect(index, isEmpty);
    });

    test('默认 MIME 表覆盖办公/媒体/电子书常用后缀，认不出回 */*', () {
      final pins = [
        _pin('/p/a.docx', localPath: '/l/a.docx'),
        _pin('/p/b.osheet', localPath: '/l/b.osheet'),
        _pin('/p/c.oslides', localPath: '/l/c.oslides'),
        _pin('/p/d.epub', localPath: '/l/d.epub'),
        _pin('/p/e.weird', localPath: '/l/e.weird'),
      ];
      final index = buildSafIndex(pins, isFile: (_) => true);
      final byName = {for (final e in index) e.name: e.mimeType};
      expect(byName['a.docx'], contains('wordprocessingml'));
      expect(byName['b.osheet'], contains('spreadsheetml'));
      expect(byName['c.oslides'], contains('presentationml'));
      expect(byName['d.epub'], 'application/epub+zip');
      expect(byName['e.weird'], '*/*');
    });
  });

  group('D66 · 索引落盘 / 读回（Dart↔Kotlin 的文件契约）', () {
    test('写到 <dir>/saf/drive_index.json，读回来一模一样', () async {
      final dir = await Directory.systemTemp.createTemp('d66_saf_');
      addTearDown(() => dir.delete(recursive: true));
      final index = SafIndex(
        rootTitle: safOfflineRootTitle,
        entries: [
          const SafIndexEntry(
            documentId: ':local:/data/a.docx',
            name: 'a.docx',
            mimeType: 'application/pdf',
            size: 7,
            lastModified: 42,
            localPath: '/data/a.docx',
          ),
        ],
      );
      final file = await writeSafIndex(dir, index);
      expect(file.path, '${dir.path}/saf/drive_index.json');
      final raw = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      expect(raw['version'], 1);
      expect(raw['authority'], safAuthority);
      expect(raw['root_id'], 'virtualTop');
      expect(raw['root_title'], safOfflineRootTitle);

      final back = readSafIndexSync(file);
      expect(back, isNotNull);
      expect(back!.entries, hasLength(1));
      expect(back.entries.single.documentId, ':local:/data/a.docx');
      expect(back.entries.single.size, 7);
      expect(back.entries.single.lastModified, 42);
    });

    test('文件不在 / 内容是垃圾 ⇒ 回 null（不猜、不炸）', () async {
      final dir = await Directory.systemTemp.createTemp('d66_saf_bad_');
      addTearDown(() => dir.delete(recursive: true));
      expect(readSafIndexSync(File('${dir.path}/nope.json')), isNull);
      final bad = File('${dir.path}/bad.json')..writeAsStringSync('{not json');
      expect(readSafIndexSync(bad), isNull);
      final arr = File('${dir.path}/arr.json')..writeAsStringSync('[1,2]');
      expect(readSafIndexSync(arr), isNull);
    });

    test('根标题是"离线文件"这一档（不假装暴露整个 Drive）', () {
      expect(safOfflineRootTitle, contains('离线文件'));
    });
  });

  group('D66 · 接线：清单变了就同步索引', () {
    test('pin / setLocalPath / unpin / clear 都触发 sink', () async {
      final calls = <List<OfflinePinEntry>>[];
      final c = ProviderContainer(
        overrides: [
          offlinePinStoreProvider.overrideWithValue(MemoryOfflinePinStore()),
          safIndexSinkProvider.overrideWithValue((pins) async {
            calls.add(List.of(pins));
          }),
        ],
      );
      addTearDown(c.dispose);
      final n = c.read(offlinePinProvider.notifier);

      await n.pin(_pin('/home/Drive/a.docx', pinnedAt: 1));
      expect(calls, hasLength(1));
      expect(calls.last.single.path, '/home/Drive/a.docx');

      await n.setLocalPath('/home/Drive/a.docx', '/data/a.docx');
      expect(calls, hasLength(2));
      expect(calls.last.single.localPath, '/data/a.docx');

      await n.unpin('/home/Drive/a.docx');
      expect(calls, hasLength(3));
      expect(calls.last, isEmpty);

      await n.pin(_pin('/home/Drive/b.txt', pinnedAt: 2));
      await n.clear();
      expect(calls, hasLength(5));
      expect(calls.last, isEmpty);
    });

    test('sink 抛异常不影响清单本身（索引是锦上添花）', () async {
      final c = ProviderContainer(
        overrides: [
          offlinePinStoreProvider.overrideWithValue(MemoryOfflinePinStore()),
          safIndexSinkProvider.overrideWithValue(
            (_) async => throw StateError('disk full'),
          ),
        ],
      );
      addTearDown(c.dispose);
      final n = c.read(offlinePinProvider.notifier);
      await n.pin(_pin('/home/Drive/a.docx', pinnedAt: 1));
      expect(c.read(offlinePinProvider), hasLength(1));

      // 真实 sink 自己吞异常（默认实现把异常吃掉）
      final real = c.read(safIndexSinkProvider);
      expect(real, isNotNull);
    });
  });

  group('D66 · 原生侧契约核验（authority 三处一致 + provider 已注册）', () {
    test('AndroidManifest 注册了 provider，且 authority 与 Dart 一致', () {
      final xml = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(xml, contains('android.content.action.DOCUMENTS_PROVIDER'));
      expect(
        xml,
        contains('android:authorities="$safAuthority"'),
        reason: 'Dart 的 safAuthority 必须与 Manifest 一致',
      );
      expect(xml, contains('android.permission.MANAGE_DOCUMENTS'));
      expect(xml, contains('android:name=".DriveDocumentsProvider"'));
    });

    test('Kotlin provider 的 AUTHORITY 与 Dart 一致，且 id 前缀逐字对齐', () {
      final kt = File(
        'android/app/src/main/kotlin/com/openviewai/synhub/'
        'DriveDocumentsProvider.kt',
      ).readAsStringSync();
      expect(kt, contains('const val AUTHORITY = "$safAuthority"'));
      for (final p in [
        SafDocumentId.realPrefix,
        SafDocumentId.labelPrefix,
        SafDocumentId.localPrefix,
        SafDocumentId.createFolderPrefix,
      ]) {
        expect(kt, contains('"$p"'), reason: 'Kotlin 侧缺前缀 $p');
      }
      expect(kt, contains('const val ROOT_ID = "${SafDocumentId.virtualTop}"'));
      expect(kt, contains('const val INDEX_FILE = "$safIndexFileName"'));
      // provider 必须实现官方那套查询面
      for (final m in [
        'queryRoots',
        'queryDocument',
        'queryChildDocuments',
        'querySearchDocuments',
        'openDocument',
        'openDocumentThumbnail',
        'createDocument',
      ]) {
        expect(kt, contains(m), reason: 'Kotlin 侧缺 $m');
      }
      // 只读：不许在 provider 里假装能写
      expect(kt, contains('只读'));
    });

    test('★ DA20：provider 边界的 lastModified 必须是**毫秒**（索引里存的是秒）', () {
      final kt = File(
        'android/app/src/main/kotlin/com/openviewai/synhub/'
        'DriveDocumentsProvider.kt',
      ).readAsStringSync();
      // 契约（r368 读官方 `DocumentsContract.Document.COLUMN_LAST_MODIFIED`）：
      // 单位是 **毫秒**；而我们的索引 JSON 存的是服务端给的 **epoch 秒**
      // （同一文件上方那条"索引字段仍是秒"的断言就是它的另一半）
      // ⇒ 转换责任**只能**钉在 provider 边界这一处。
      // 真机症状（修前）：系统文件选择器里文件日期显示 `Jan 22, 1970`。
      expect(
        kt.contains('e.lastModified * 1000L'),
        isTrue,
        reason: 'DA20：provider 少了 ×1000 ⇒ 选择器里日期会回到 1970 年',
      );
      expect(
        RegExp(r'COLUMN_LAST_MODIFIED').hasMatch(kt),
        isTrue,
        reason: 'DA20：这行的 key 必须是 SAF 的 COLUMN_LAST_MODIFIED',
      );
    });
  });
}
