// 守卫（第 434 轮 / `DA89`）：**PDF 的落盘副本不许再出现在缓存根层**。
//
// 真机读数（r434，只读）：`/data/data/com.openviewai.synhub/cache/` 根层躺着
// **18 个** `<32 位十六进制>.pdf`（962 B 那份的正文 = r344 的 `ai_report_en.pdf`）；
// 根因 = `pdfx-2.11.0` 的 `openDataDocument()`
// （`Messages.kt:360`：`File(cacheDir, "$randomFilename.pdf")`，
// `randomFilename` = UUID 去横线）—— 凡 `PdfDocument.openData` 都会写根层。
//
// 后果：根层文件不在 `kRegenerableCacheDirs` 任何目录下 ⇒
// ①「缓存用量」看不到 ②「清空缓存」删不掉 ③ 上限淘汰不碰它，而对话框明说会删预览副本。
//
// 修法两条腿，本文件逐条钉住：
//   * A（源头）：`lib/` 里 `openData(` **归零**，改走 `pdf_local_copy.dart`
//     （落到**已登记**的 `pdf_renderer_cache/`，内容摘要命名 ⇒ 复用）；
//   * B（兜底）：`CacheService` 的根层登记表认那种名字，回收历史遗留。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/media/cache_service.dart';
import 'package:synhub/src/core/media/media_key_hash.dart';
import 'package:synhub/src/core/media/pdf_local_copy.dart';

Uint8List _bytes(List<int> v) => Uint8List.fromList(v);

void main() {
  test('A-①：`lib/` 里一行 `openData(` 都不许有（pdfx 会写缓存根层）', () {
    final offenders = <String>[];
    for (final e in Directory('lib/src').listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      for (final line in e.readAsLinesSync()) {
        final t = line.trimLeft();
        if (t.startsWith('//') || t.startsWith('*')) continue;
        if (line.contains('openData(')) offenders.add('${e.path}: ${line.trim()}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '`PdfDocument.openData` 会让 pdfx 把整份 PDF 写到缓存**根层**'
          '（`<32 位十六进制>.pdf`，用量统计不到、清空缓存删不掉、无上限增长）。'
          '改走 `defaultPdfLocalCopy()` + `openFile()`：\n${offenders.join('\n')}',
    );
  });

  test('A-②：三个 PDF 调用点都接上了本地副本（不是"删了没替"）', () {
    // 只扫"必须接上"的三个文件：删掉一条注入就会红。
    const expected = {
      'lib/src/features/files/file_pdf_view.dart': 'pdfLocalCopyProvider',
      'lib/src/features/files/pdf_cover.dart': 'defaultPdfLocalCopy',
      'lib/src/features/drive/drive_pdf_markup_page.dart':
          'defaultPdfLocalCopy',
    };
    for (final entry in expected.entries) {
      final f = File(entry.key);
      expect(f.existsSync(), isTrue, reason: '${entry.key} 不见了');
      expect(
        f.readAsStringSync().contains(entry.value),
        isTrue,
        reason: '${entry.key} 没用 ${entry.value} ⇒ 它可能又回去走 openData 了',
      );
    }
  });

  test('A-③：副本落在**已登记**的目录里，且同名复用、异内容换名', () async {
    // 目录名必须真的是登记表里的一条：否则"统计/清理覆盖不到"这个缺陷原样复现。
    final registered = {
      for (final e in kRegenerableCacheDirs) ...e.name.split('/'),
    };
    expect(
      registered.contains(kPdfLocalCopyDirName),
      isTrue,
      reason: '$kPdfLocalCopyDirName 没登记 ⇒ 副本不会被统计/清理（DA89 复发）',
    );

    final root = Directory.systemTemp.createTempSync('pdf_copy_');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    final a = _bytes([1, 2, 3, 4, 5]);
    final p1 = await defaultPdfLocalCopy(a, root: root);
    expect(p1, startsWith('${root.path}/$kPdfLocalCopyDirName/'));
    expect(p1, endsWith('.pdf'));
    expect(File(p1).existsSync(), isTrue);
    expect(File(p1).lengthSync(), a.length);

    // ★ 落点**不在**缓存根层（根层 = 缺陷的现场）
    final rootEntries = root
        .listSync()
        .whereType<File>()
        .map((f) => f.path)
        .toList();
    expect(rootEntries, isEmpty, reason: '副本不许落在缓存根层：$rootEntries');

    final stamp = File(p1).lastModifiedSync();
    final p2 = await defaultPdfLocalCopy(a, root: root);
    expect(p2, p1, reason: '同一份内容必须复用同一个文件（否则又是无上限增长）');
    expect(
      File(p1).lastModifiedSync(),
      stamp,
      reason: '复用不该重写文件（mtime 被刷新会让 LRU 语义失真）',
    );

    final b = _bytes([9, 9, 9]);
    final p3 = await defaultPdfLocalCopy(b, root: root);
    expect(p3, isNot(p1), reason: '内容不同 ⇒ 文件名必须不同（否则会读到旧内容）');
  });

  test('A-④：字节命名空间与字符串命名空间是两个（别互换 ⇒ 缓存名漂移）', () {
    // 逐字节相同 ⇒ 摘要相同；差一个字节 ⇒ 必须不同。
    expect(
      fnv1a64HexBytes(_bytes([1, 2, 3])),
      fnv1a64HexBytes(_bytes([1, 2, 3])),
    );
    expect(
      fnv1a64HexBytes(_bytes([1, 2, 3])),
      isNot(fnv1a64HexBytes(_bytes([1, 2, 4]))),
    );
    expect(fnv1a64HexBytes(const []), isNotEmpty);
  });

  test('B-①：根层登记表的正则真的匹配 pdfx 名字，且不误伤别的根层文件', () {
    expect(kCacheRootRegenerablePatterns, isNotEmpty);
    for (final p in kCacheRootRegenerablePatterns) {
      expect(p.why.trim(), isNotEmpty, reason: '根层登记项必须写"为什么可再生"');
      expect(p.regex.hasMatch('a' * 31 + '1.pdf'), isTrue);
      // 反例：不该命中的（大写十六进制 / 别的后缀 / 带前缀的下载件 / 在线字幕）
      for (final bad in [
        'A' * 31 + '1.pdf',
        'a' * 31 + '1.PDF',
        'a' * 31 + '1.srt',
        'note-nas-${'a' * 25}.pdf',
        'subtitle_x.gestdown.abc.srt',
        '${'a' * 31}1.pdf.bak',
      ]) {
        expect(
          p.regex.hasMatch(bad),
          isFalse,
          reason: '${p.source} 误命中 $bad',
        );
      }
    }
  });

  test('B-②：用量/清空**包含**根层那种 pdf，且**不碰**根层其它文件', () async {
    final root = Directory.systemTemp.createTempSync('cache_root_');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    // 根层：一个 pdfx 遗留副本 + 用户/系统内容（在线字幕、笔记附件临时件）
    final stray = File('${root.path}/${'d' * 31}7.pdf')
      ..writeAsBytesSync(List.filled(100, 7));
    final srt = File('${root.path}/subtitle_a.gestdown.x.srt')
      ..writeAsStringSync('1\n00:00 --> 00:01\nhi\n');
    final noteTmp = File('${root.path}/note-nas-photo.png')
      ..writeAsBytesSync(List.filled(10, 1));
    // 登记目录里的普通缓存（对照组）
    final reg = File('${root.path}/chat_cache/keep.bin')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(50, 3));

    final cache = CacheService(root: root);
    final u = await cache.usage();
    expect(u.files, 2, reason: '用量应只含：登记目录 1 + 根层登记模式 1');
    expect(u.bytes, 150);

    final freed = await cache.clear();
    expect(freed, 150);
    expect(stray.existsSync(), isFalse, reason: '根层 pdfx 副本必须被清掉');
    expect(reg.existsSync(), isFalse, reason: '登记目录里的缓存必须被清掉');
    expect(srt.existsSync(), isTrue, reason: '在线字幕**不是**可再生缓存，不许动');
    expect(noteTmp.existsSync(), isTrue, reason: '用户内容/临时件不许动');
  });
}
