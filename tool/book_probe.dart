// 造一本真实的最小 EPUB / CBZ 上传到 NAS，用来做**真机**阅读验证。
//
// 用法：
//   SYNO_NAS_URL=... SYNO_ACCOUNT=... SYNO_PASSWORD=... dart run tool/book_probe.dart seed
//   ... clean   # 删掉这些测试书
//
// 真机（2026-09-18）验证点：EPUB 的 container.xml/OPF 路径解析、spine 章节顺序、
// 插图（zip 内资源）能否显示、CBZ 的翻页。
// CHM（自研 ITSF+LZX）的真机验证点：hhc 三层目录、中文 UTF-8/GBK/UTF-16 正文、
// 插图与封面。真实 CHM 由用户提供（本工具只造最小合法样本）。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'make_chm_fixture.dart';
import 'make_djvu_fixture.dart';

/// 1×1 PNG（够解码，验证"插图有没有出来"）
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

Uint8List _zip(Map<String, String> text, {Map<String, List<int>>? bin}) {
  final a = Archive();
  text.forEach((k, v) {
    final b = utf8.encode(v);
    a.addFile(ArchiveFile(k, b.length, b));
  });
  bin?.forEach((k, v) => a.addFile(ArchiveFile(k, v.length, v)));
  return Uint8List.fromList(ZipEncoder().encode(a));
}

Uint8List epub() => _zip(
  {
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml':
        '<?xml version="1.0"?><container version="1.0"><rootfiles>'
        '<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
        '</rootfiles></container>',
    'OEBPS/content.opf':
        '<?xml version="1.0"?><package version="3.0">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:title>真机测试之书</dc:title><dc:creator>AutoProbe</dc:creator></metadata>'
        '<manifest><item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>'
        '<item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>'
        '<item id="i1" href="images/pic.png" media-type="image/png"/></manifest>'
        '<spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>',
    'OEBPS/text/ch1.xhtml':
        '<html><body><h1>第一章 起点</h1>'
        '<p>这是<strong>正文</strong>。</p><p><img src="../images/pic.png"/></p></body></html>',
    'OEBPS/text/ch2.xhtml':
        '<html><body><h1>第二章 继续</h1>'
        '<ul><li>要点一</li><li>要点二</li></ul></body></html>',
  },
  bin: {'OEBPS/images/pic.png': _png},
);

Uint8List cbz() =>
    _zip({}, bin: {'p1.png': _png, 'p2.png': _png, 'p3.png': _png});

String fb2() =>
    '<?xml version="1.0"?><FictionBook xmlns:l="http://www.w3.org/1999/xlink">'
    '<description><title-info><book-title>真机 FB2</book-title>'
    '<author><first-name>Auto</first-name><last-name>Probe</last-name></author>'
    '</title-info></description><body>'
    '<section><title><p>第一节</p></title><p>正文一</p><subtitle>小标题</subtitle></section>'
    '<section><title><p>第二节</p></title><p>正文二</p></section>'
    '</body></FictionBook>';

Future<void> main(List<String> args) async {
  final api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  await api.login(
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
    session: 'FileStation',
  );
  final fs = FileStationApi(api);
  const dir = '/home/Books';
  final existing = await fs.listFolder(folderPath: '/home');
  if (!existing.entries.any((e) => e.name == 'Books')) {
    await fs.createFolder(folderPath: '/home', name: 'Books');
    print('建了 /home/Books');
  }
  final mode = args.isEmpty ? 'seed' : args.first;
  if (mode == 'clean') {
    for (final name in const [
      'probe.epub',
      'probe.cbz',
      'probe.fb2',
      'probe.cbr',
      'probe.chm',
      'probe.djvu',
      'probe-scan.djvu',
    ]) {
      try {
        await fs.deleteItems(['$dir/$name']);
        print('删了 $name');
      } catch (e) {
        print('$name 不在（跳过）');
      }
    }
    await api.logout();
    exit(0);
  }
  final files = <String, List<int>>{
    'probe.epub': epub(),
    'probe.cbz': cbz(),
    'probe.fb2': utf8.encode(fb2()),
    // CBR 是 RAR，故意塞个假内容：验证客户端**不做内嵌**、只给"用其他应用打开"
    'probe.cbr': utf8.encode('Rar!\x1a\x07\x00 fake'),
    // CHM：自研 ITSF+LZX 的最小合法书（三层 hhc 目录 + 中文三种编码 + 插图），
    // 真机上验证"目录/正文/图片/封面"是否都出来
    'probe.chm': buildChmFixture(chmFixtureFiles()),
  };
  // DJVU：自研容器 + BZZ 文本层 + JB2 掩码（多页 DIRM/NAVM 书 + 位图扫描页）。
  // 真机验证点：文本层抽章节、NAVM 目录面板、位图页走翻页器、封面。
  // ⚠️ 样本里**没有真实 IW44 系数**，所以验证不了扫描件的像素还原。
  final djvu = buildDjvuFixtures();
  files['probe.djvu'] = djvu['djvu-multi.djvu']!;
  files['probe-scan.djvu'] = djvu['djvu-jb2-mask.djvu']!;
  final tmp = Directory.systemTemp.createTempSync('book_probe');
  for (final e in files.entries) {
    final local = '${tmp.path}/${e.key}';
    File(local).writeAsBytesSync(e.value);
    await fs.upload(folderPath: dir, filePath: local, fileName: e.key);
    print('上传 ${e.key}（${e.value.length} 字节）');
  }
  tmp.deleteSync(recursive: true);
  await api.logout();
  exit(0);
}
