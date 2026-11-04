// 第 265 轮：Office **模板正文预览**（官方 `Office.Export/download`）的离线验收。
//
// 背景（全文见 `docs/office-template-gallery.md` §9）：
//   第 260 轮的结论"服务端没有给普通用户的模板正文接口 ⇒ 只能看缩略图"
//   是在**参数错**的前提下得出的：
//     * `Office.Doc/Presentation.Snapshot:get` → `105` 是**真实权限结论**
//       （`webapi/SYNO.Office.lib` 里 `allowUser` 只有 admin）；
//     * `Office.Snapshot:get` → `57379` 是因为它要的是 **`link_id`**
//       （缺参回 `120 {"name":"link_id","reason":"required"}`）——
//       那是 Drive **分享链接**的预览通道，不是模板通道；
//     * 模板的正文通道是 `Office.Export/download`：官方 `ui.doc.js` 的
//       `downloadOffice()` 对 `Env.is_template` 走
//       `{object_id: Env.objectId}`，模板右键菜单第一项 `cf.preview` 就是
//       "在阅读器里打开模板本体"。
//   真机（只读 POST 表单）53 个系统模板全部可导 → 真 OOXML。
//
// 本文件钉三件事：
//   ① 请求形状（api/version/method/参数）逐字对齐官方 `exportNode` 白名单，
//      且**必须走 POST 表单**（format 放查询串会被服务端忽略）；
//   ② 三种 `ntype` 的正文都用**既有阅读器**渲染（xlsx = 网格、docx/pptx =
//      书籍阅读器 `FileBookBytesStage`），并且真能看到模板正文的文字；
//   ③ 失败/加载是**两种不同的状态**，失败要**说得出为什么**（界面文案 +
//      `debugPrint` 可查询原因），绝不静默当成缩略图。
import 'dart:async';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/office_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/office/office_template_document.dart';
import 'package:synhub/src/features/office/office_template_preview.dart';
import 'package:synhub/src/features/office/office_template_thumbs.dart';

import 'support/chat_harness.dart';
import 'support/pptx_fixture.dart';

// ------------------------------------------------------------------ 夹具

/// 真机 `Template:list` 的逐字条目（53 条里的三条，只留本文件要的键）。
Map<String, dynamic> _item({
  required String objectId,
  required String ntype,
  required String title,
  bool system = true,
}) => <String, dynamic>{
  'capabilities': <String, dynamic>{
    'can_download': true,
    'can_preview': true,
    'can_read': true,
  },
  'category': 'node',
  'ctime': 0,
  'encrypt': false,
  'is_template': true,
  'mtime': 0,
  'ntype': ntype,
  'object_id': objectId,
  'perm': 'ro',
  'system': system,
  'title': title,
  'ver': 'f26e4bacf7a38332c3f078c399c2bacdc8a198f6',
};

OfficeTemplateDto _dto(Map<String, dynamic> json) =>
    OfficeTemplateDto.fromJson(json);

Uint8List _zip(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

const String _docxNs =
    'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';

/// 最小合法 DOCX（结构同 `parseDocxBook` 的真夹具口径）。
Uint8List _docxBytes(String text) => _zip(<String, List<int>>{
  '[Content_Types].xml': utf8.encode(
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
    '</Types>',
  ),
  'word/document.xml': utf8.encode(
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<w:document $_docxNs><w:body>'
    '<w:p><w:r><w:t>$text</w:t></w:r></w:p>'
    '</w:body></w:document>',
  ),
});

/// **带版式的** DOCX：真机 `Meeting minutes.docx` 的关键样式逐项复刻（字号
/// `w:sz` / 颜色 `w:color` / 字体 `w:rFonts` / 标题样式 / A4 页边距 `w:sectPr`）。
///
/// 这是第 272 轮的**保真度判据夹具**：`ODocxDocument` 会把它们解析出来，
/// `OfficeDocxView` 必须把它们画进 `TextSpan.style`（书籍阅读器会全部丢掉）。
Uint8List _styledDocxBytes(String text) => _zip(<String, List<int>>{
  '[Content_Types].xml': utf8.encode(
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '</Types>',
  ),
  'word/document.xml': utf8.encode(
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<w:document $_docxNs><w:body>'
    '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>'
    '<w:r><w:rPr><w:sz w:val="52"/><w:color w:val="7B8187"/>'
    '<w:rFonts w:ascii="Trebuchet MS"/></w:rPr><w:t>$text</w:t></w:r></w:p>'
    '<w:p><w:r><w:rPr><w:sz w:val="26"/><w:color w:val="E55D50"/>'
    '<w:rFonts w:ascii="Trebuchet MS"/></w:rPr>'
    '<w:t>正文段落</w:t></w:r></w:p>'
    '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
    '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/>'
    '</w:sectPr>'
    '</w:body></w:document>',
  ),
});

/// **能让书籍阅读器读懂、但 `ODocxDocument.parse` 认不出来**的 DOCX：
/// 有 `word/document.xml` 但**没有 `<w:body>`**（`ODocxDocument` 要求 body）。
/// 用来钉"高保真路径不可用时必须如实回落"。
Uint8List _brokenDocxBytes(String text) => _zip(<String, List<int>>{
  '[Content_Types].xml': utf8.encode(
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '</Types>',
  ),
  'word/document.xml': utf8.encode(
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<w:document $_docxNs>'
    '<w:p><w:r><w:t>$text</w:t></w:r></w:p>'
    '</w:document>',
  ),
});

/// 最小合法 XLSX（中文表名 + inlineStr + sharedStrings，口径同既有 O2 用例）。
Uint8List _xlsxBytes(String inlineText, String sharedText) => _zip({
  'xl/workbook.xml': utf8.encode(
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
    ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    '<sheets><sheet name="一月预算" sheetId="1" state="visible" r:id="rId1"/>'
    '</sheets></workbook>',
  ),
  'xl/_rels/workbook.xml.rels': utf8.encode(
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"'
    ' Target="worksheets/sheet1.xml"/></Relationships>',
  ),
  'xl/worksheets/sheet1.xml': utf8.encode(
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '<dimension ref="A1:B1"/><sheetData><row r="1">'
    '<c r="A1" t="inlineStr"><is><t>$inlineText</t></is></c>'
    '<c r="B1" t="s"><v>0</v></c>'
    '</row></sheetData></worksheet>',
  ),
  'xl/sharedStrings.xml': utf8.encode(
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '<si><t>$sharedText</t></si></sst>',
  ),
});

/// 最小合法 PPTX（复用既有合成夹具，保证走的是真解析路径）。
///
/// 第 272 轮加了**真实 EMU 几何**（`a:off`/`a:ext`）：没有几何的形状在
/// `OSlidesDeck` 里 `drawableShapeCount == 0` ⇒ 幻灯片画布只会显示"没有内容"，
/// 那样"文字真的画出来了"就无从谈起。
Uint8List _pptxBytes(String text) => buildSyntheticPptx(
  slideSpTree:
      '<p:sp><p:nvSpPr><p:cNvPr id="2" name="t"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>'
      '<p:spPr><a:xfrm><a:off x="914400" y="914400"/>'
      '<a:ext cx="7315200" cy="1143000"/></a:xfrm>'
      '<a:prstGeom prst="rect"/></p:spPr>'
      '<p:txBody><a:bodyPr/><a:lstStyle/>'
      '<a:p><a:r><a:rPr lang="en-US" sz="2400"/>'
      '<a:t>$text</a:t></a:r></a:p></p:txBody></p:sp>',
);

// ------------------------------------------------------------------ 泵

OfficeTemplateThumbCache _memoryOnlyThumbCache() =>
    OfficeTemplateThumbCache(diskRoot: () async => null);

/// 泵一页预览。**必须给 ProviderScope**：docx/pptx 的正文走
/// `FileBookBytesStage` → `_BookReader`（ConsumerStatefulWidget，会读
/// `bookStoreProvider` → `chatDatabaseProvider`），所以给一个内存 Drift 库
/// （与 `test/file_book_test.dart` 同一口径）。
Future<ProviderContainer> _pumpPreview(
  WidgetTester tester, {
  required List<OfficeTemplateDto> templates,
  OfficeTemplateBodyFetcher? bodyFetcher,
  OfficeTemplateBodyCache? bodyCache,
  int initialIndex = 0,
  void Function(OfficeTemplateDto)? onUseTemplate,
}) async {
  final db = ChatDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [chatDatabaseProvider.overrideWithValue(db)],
  );
  addTearDown(container.dispose);
  addTearDown(db.close);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: OfficeTemplatePreviewPage(
          templates: templates,
          initialIndex: initialIndex,
          thumbFetcher: ({required objectId, ver, required retina}) async =>
              Uint8List.fromList(_png1x1),
          thumbCache: _memoryOnlyThumbCache(),
          bodyFetcher: bodyFetcher,
          // ★ 每个用例一份**独立**缓存：进程级默认实例会在用例之间串数据
          //   （第 260 轮踩过同类坑：上一条用例缓存的正文让下一条直接命中，
          //   "加载态"用例因此永远看不到加载态）。
          bodyCache: bodyCache ?? OfficeTemplateBodyCache(),
          onUseTemplate: onUseTemplate,
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

Future<void> _settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 书籍阅读器把正文放在 `RichText` 里（不是 `Text`）⇒ `find.text*` 默认找不到
/// （第 265 轮实测：docx 正文在 `RichText.toPlainText()` 里，`find.text` 命中 0）。
/// 这里直接量**已画出的富文本**，比"找到某个 key"更接近"用户真看见了字"。
bool _richTextHas(WidgetTester tester, String needle) => tester
    .widgetList<RichText>(find.byType(RichText))
    .any((r) => r.text.toPlainText().contains(needle));

/// 找到**含 [needle] 的那一段** `TextSpan` 的样式（第 272 轮的保真度判据）。
///
/// AGENTS §2.0.18：渲染/版式类的断言必须量**画出来的东西**，
/// 不能用 `find.text` 反推（它既能命中截断也证明不了字号/颜色）。
TextStyle? _spanStyleFor(WidgetTester tester, String needle) {
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    TextStyle? found;
    rich.text.visitChildren((span) {
      if (span is TextSpan && (span.text ?? '').contains(needle)) {
        found = span.style;
        return false;
      }
      return true;
    });
    if (found != null) return found;
  }
  return null;
}

/// 1×1 透明 PNG（缩略图占位用；正文用例不依赖它）
final Uint8List _png1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

void main() {
  // ------------------------------------------------------------ P1 请求形状
  group('P1. 数据层：模板正文导出的请求形状（官方 exportNode 白名单）', () {
    late FakeTransport t;
    late OfficeApi office;

    setUp(() async {
      t = FakeTransport(const <String, Map<String, dynamic>>{}, <
        String,
        Map<String, dynamic>
      >{
        ...FakeTransport.table,
        'SYNO.Office.Export': <String, dynamic>{
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 1,
        },
      });
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      office = OfficeApi(api);
    });

    test('★ {object_id, format:"ms"} 走 POST 表单；不混入 path/link_id/ver', () async {
      t.downloadBytes = <int>[0x50, 0x4B, 0x03, 0x04, 1, 2, 3];
      final bytes = await office.templateExportBytes(
        objectId: '1_country_road.tpl.slide',
      );
      expect(bytes, hasLength(7));
      expect(t.postDownloads, hasLength(1), reason: '必须走 POST 表单通道');
      final q = t.postDownloads.single;
      expect(q, contains('api=SYNO.Office.Export'));
      expect(q, contains('version=1'));
      expect(q, contains('method=download'));
      expect(q, contains('object_id=1_country_road.tpl.slide'));
      expect(q, contains('format=ms'), reason: '第 265 轮实测唯一可用产物格式');
      // 官方 `exportNode` 白名单是 path,object_id,password,format,ver；
      // 模板只能给 object_id（真机 `path=id:` 是**节点**的形态）。
      expect(q, isNot(contains('path=')));
      expect(q, isNot(contains('link_id')));
      expect(q, isNot(contains('ver=')));
    });

    test('空 object_id → 本地就挡住（不发请求）', () async {
      await expectLater(
        office.templateExportBytes(objectId: ''),
        throwsA(
          isA<OfficeAttachmentException>().having(
            (e) => e.kind,
            'kind',
            OfficeAttachmentErrorKind.missingParam,
          ),
        ),
      );
      expect(t.postDownloads, isEmpty);
    });

    test('服务端回 HTTP 500 → 分类成"未分类失败"，不假装成功', () async {
      t.failures['SYNO.Office.Export'] = 500;
      await expectLater(
        office.templateExportBytes(objectId: 'x.tpl.doc'),
        throwsA(
          isA<OfficeAttachmentException>().having(
            (e) => e.kind,
            'kind',
            OfficeAttachmentErrorKind.network,
          ),
        ),
      );
    });

    test('空字节 → empty（界面据此回落，绝不画空白页）', () async {
      t.downloadBytes = const <int>[];
      await expectLater(
        office.templateExportBytes(objectId: 'x.tpl.doc'),
        throwsA(
          isA<OfficeAttachmentException>().having(
            (e) => e.kind,
            'kind',
            OfficeAttachmentErrorKind.empty,
          ),
        ),
      );
    });
  });

  // ------------------------------------------------------------ P2 格式映射
  group('P2. ntype → 导出格式（官方 EXPORT_EXTENSION 逐字）', () {
    test('doc→docx / sheet→xlsx / presentation→pptx', () {
      expect(
        officeTemplateBodyKind('doc'),
        OfficeTemplateBodyKind.docx,
      );
      expect(
        officeTemplateBodyKind('sheet'),
        OfficeTemplateBodyKind.xlsx,
      );
      expect(
        officeTemplateBodyKind('presentation'),
        OfficeTemplateBodyKind.pptx,
      );
      expect(officeTemplateBodyKind('doc').toString(), contains('docx'));
    });

    test('★ 认不出的 ntype → null（不猜，回落缩略图）', () {
      for (final ntype in <String>['', 'odoc', 'pdf', 'slideshow']) {
        expect(officeTemplateBodyKind(ntype), isNull, reason: ntype);
      }
    });
  });

  // ------------------------------------------------------------ P3 真正文
  group('P3. 正文真的渲染出来（三种格式各走既有阅读器）', () {
    testWidgets('★ xlsx 模板 → 只读网格，且看得到单元格中文', (tester) async {
      final tpl = _dto(
        _item(
          objectId: '1_project_timeline.tpl.sh',
          ntype: 'sheet',
          title: 'template_sheet:project_timeline',
        ),
      );
      var calls = 0;
      await _pumpPreview(
        tester,
        templates: [tpl],
        bodyFetcher: (t) async {
          calls++;
          expect(t.objectId, '1_project_timeline.tpl.sh');
          return _xlsxBytes('项目名称', '餐饮与差旅');
        },
      );
      await _settle(tester);
      expect(calls, 1, reason: '一个模板只导一次');
      expect(
        find.byKey(const Key('office-template-body-sheet')),
        findsOneWidget,
        reason: '★ 必须是内嵌网格（与文件预览里的 .xlsx 同一对组件）',
      );
      expect(find.text('项目名称'), findsOneWidget);
      expect(find.text('餐饮与差旅'), findsOneWidget);
      // 正文模式不该出现缩略图模式的 PageView
      expect(
        find.byKey(const Key('office-template-preview-pager')),
        findsNothing,
      );
    });

    testWidgets('★ docx 模板 → OfficeDocxView（.odoc 的同一条 A4 纸面路径）', (
      tester,
    ) async {
      final tpl = _dto(
        _item(
          objectId: '1_meeting_minutes.tpl.doc',
          ntype: 'doc',
          title: 'template_doc:meeting_minutes',
        ),
      );
      await _pumpPreview(
        tester,
        templates: [tpl],
        bodyFetcher: (t) async => _styledDocxBytes('会议纪要正文'),
      );
      await _settle(tester);
      expect(
        find.byKey(const Key('office-template-body-docx')),
        findsOneWidget,
        reason: '★ 第 272 轮：docx 走 .odoc 的 OOXML 阅读器（A4 纸面），不再走书籍阅读器',
      );
      expect(
        find.byKey(const Key('office-template-body-book')),
        findsNothing,
        reason: '★ 高保真路径可用时**不许**再落到文字流兜底',
      );
      expect(
        _richTextHas(tester, '会议纪要正文'),
        isTrue,
        reason: '正文文字必须**真的画出来**（不是"有个容器"就算了）',
      );
    });

    testWidgets('★ docx 里 OOXML 解不出来 → 仍如实回落到书籍阅读器（不回归）', (
      tester,
    ) async {
      final tpl = _dto(
        _item(
          objectId: '1_meeting_minutes.tpl.doc',
          ntype: 'doc',
          title: 'template_doc:meeting_minutes',
        ),
      );
      // 半截 ZIP：`ODocxDocument.parse` 认不出来 ⇒ 必须回落，且**不空白**。
      await _pumpPreview(
        tester,
        templates: [tpl],
        bodyFetcher: (t) async => _brokenDocxBytes('兜底正文'),
      );
      await _settle(tester);
      expect(
        find.byKey(const Key('office-template-body-book')),
        findsOneWidget,
        reason: '★ 兜底路径必须还在（老服务端 / 半截字节不许比以前更差）',
      );
      expect(_richTextHas(tester, '兜底正文'), isTrue);
    });

    testWidgets('★ pptx 模板 → OfficeSlidesDeckView（.oslides 的同一条 16:9 画布）', (
      tester,
    ) async {
      final tpl = _dto(
        _item(
          objectId: '1_country_road.tpl.slide',
          ntype: 'presentation',
          title: 'theme_presentation:country_road',
        ),
      );
      await _pumpPreview(
        tester,
        templates: [tpl],
        bodyFetcher: (t) async => _pptxBytes('乡村主题演示'),
      );
      await _settle(tester);
      expect(
        find.byKey(const Key('office-template-body-slides')),
        findsOneWidget,
        reason: '★ 第 272 轮：pptx 走 .oslides 的 PPTX 画布阅读器',
      );
      expect(
        find.byKey(const Key('office-template-body-book')),
        findsNothing,
        reason: '★ 高保真路径可用时**不许**退化成"一页一章的文字流"',
      );
      expect(_richTextHas(tester, '乡村主题演示'), isTrue);
    });

    testWidgets('正文模式：头部能换模板（正文阅读器自带横滑，不再用 PageView）', (
      tester,
    ) async {
      final a = _dto(
        _item(
          objectId: 'a.tpl.doc',
          ntype: 'doc',
          title: 'template_doc:meeting_minutes',
        ),
      );
      final b = _dto(
        _item(
          objectId: 'b.tpl.doc',
          ntype: 'doc',
          title: 'template_doc:invoice',
        ),
      );
      await _pumpPreview(
        tester,
        templates: [a, b],
        bodyFetcher: (t) async =>
            _docxBytes(t.objectId == 'a.tpl.doc' ? '甲正文' : '乙正文'),
      );
      await _settle(tester);
      expect(find.text('1 / 2'), findsOneWidget);
      await tester.tap(find.byKey(const Key('office-template-preview-next')));
      await _settle(tester);
      expect(find.text('2 / 2'), findsOneWidget);
      expect(_richTextHas(tester, '乙正文'), isTrue);
    });

    testWidgets('顶部动作都满足 48dp 最小点击区（AGENTS §2.0.10）', (tester) async {
      final a = _dto(
        _item(objectId: 'a.tpl.doc', ntype: 'doc', title: 'template_doc:invoice'),
      );
      final b = _dto(
        _item(objectId: 'b.tpl.doc', ntype: 'doc', title: 'template_doc:invoice'),
      );
      await _pumpPreview(
        tester,
        templates: [a, b],
        bodyFetcher: (t) async => _docxBytes('正文'),
      );
      await _settle(tester);
      for (final key in <String>[
        'office-template-preview-close',
        'office-template-preview-prev',
        'office-template-preview-next',
        'office-template-preview-toggle',
      ]) {
        final size = tester.getSize(find.byKey(Key(key)));
        expect(size.width, greaterThanOrEqualTo(48), reason: key);
        expect(size.height, greaterThanOrEqualTo(48), reason: key);
      }
    });
  });

  // ------------------------------------------------------------ P4 加载/失败
  group('P4. 中间态与失败态分得清，失败说得出为什么（AGENTS §2.0.17 ②）', () {
    testWidgets('★ 导出还没回来 = 加载态（不是失败态）', (tester) async {
      final tpl = _dto(
        _item(objectId: 'a.tpl.doc', ntype: 'doc', title: 'template_doc:invoice'),
      );
      final gate = Completer<Uint8List>();
      await _pumpPreview(
        tester,
        templates: [tpl],
        bodyFetcher: (t) => gate.future,
      );
      await _settle(tester, frames: 4);
      expect(
        find.byKey(const Key('office-template-preview-body-loading')),
        findsOneWidget,
        reason: '★ 加载中必须看得见（不能和失败长得一样）',
      );
      expect(
        find.byKey(const Key('office-template-preview-body-reason')),
        findsNothing,
      );
      // ★ 第 272 轮：中间态要**说得出在干什么**（取字节 vs 排版是两个阶段）。
      expect(
        tester
            .widget<Semantics>(
              find.byKey(const Key('office-template-preview-body-stage')),
            )
            .properties
            .label,
        'fetching',
        reason: '字节还没回来 ⇒ 阶段必须是 fetching',
      );
      gate.complete(_styledDocxBytes('到货了'));
      await _settle(tester);
      expect(
        find.byKey(const Key('office-template-body-docx')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('office-template-preview-body-loading')),
        findsNothing,
        reason: '★ 到了就**必须收起加载态**（不能永远转圈）',
      );
    });

    testWidgets('★ 导出失败 = 缩略图 + 说得出的原因 + 可重试，并打可查询日志', (
      tester,
    ) async {
      final logs = <String>[];
      final previous = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = previous);

      final tpl = _dto(
        _item(
          objectId: '1_invoice.tpl.doc',
          ntype: 'doc',
          title: 'template_doc:invoice',
        ),
      );
      var calls = 0;
      await _pumpPreview(
        tester,
        templates: [tpl],
        bodyFetcher: (t) async {
          calls++;
          throw const OfficeAttachmentExceptionStub('105 无权限');
        },
      );
      await _settle(tester);
      expect(calls, 1);
      expect(
        find.byKey(
          const Key('office-template-preview-body-fallback-1_invoice.tpl.doc'),
        ),
        findsOneWidget,
      );
      // 缩略图仍要出（诚实回落，不是空白）
      expect(
        find.byKey(const Key('office-template-preview-image-1_invoice.tpl.doc')),
        findsOneWidget,
      );
      final reason = tester.widget<Text>(
        find.byKey(const Key('office-template-preview-body-reason')),
      );
      expect(reason.data, contains('105 无权限'), reason: '原因必须上屏');
      expect(
        find.byKey(const Key('office-template-preview-body-retry')),
        findsOneWidget,
      );
      // 可查询的失败日志（release 也进 logcat）
      expect(
        logs.where((l) => l.contains('[officeTemplatePreview] FAIL')).length,
        1,
        reason: '一次失败只打一条；且必须带 object_id/原因',
      );
      expect(
        logs.firstWhere((l) => l.contains('[officeTemplatePreview] FAIL')),
        allOf(contains('object_id=1_invoice.tpl.doc'), contains('105 无权限')),
      );
      // ★ 失败记忆：重建同一页不该重新打网络（calls 仍为 1）——再 pump 一次
      await _settle(tester, frames: 4);
      expect(calls, 1, reason: '失败记忆要挡住重复请求');

      // ★ 必须在**用例体内**还原：`debugPrint` 是 foundation 调试变量，
      //   `flutter_test` 在用例体结束后、tearDown 之前就校验它没被改动
      //   （不还原 → "The value of a foundation debug variable was changed"）。
      debugPrint = previous;
    });

    testWidgets('加密模板：不发请求，如实说需要口令', (tester) async {
      final tpl = _dto(<String, dynamic>{
        ..._item(
          objectId: 'enc.tpl.doc',
          ntype: 'doc',
          title: 'template_doc:invoice',
        ),
        'encrypt': true,
      });
      var calls = 0;
      await _pumpPreview(
        tester,
        templates: [tpl],
        bodyFetcher: (t) async {
          calls++;
          return _docxBytes('不该到这里');
        },
      );
      await _settle(tester);
      expect(calls, 0, reason: '加密模板本页没有口令 ⇒ 不试，别浪费一次失败请求');
      final reason = tester.widget<Text>(
        find.byKey(const Key('office-template-preview-body-reason')),
      );
      expect(reason.data, contains('口令'));
    });
  });

  // ------------------------------------------- P7 保真度（第 272 轮的正题）
  group('P7. 正文保真度：高保真阅读器优先 + 逐级回落（第 272 轮）', () {
    // 纯函数：把"哪条路"钉死（离线可跑，不需要渲染）。
    test('★ 路由：docx/pptx/xlsx 各有高保真模型，OOXML 解不出来才回落字节兜底', () {
      final docx = prepareOfficeTemplateBody(
        OfficeTemplateBodyKind.docx,
        _styledDocxBytes('标题'),
      );
      expect(docx, isA<OfficeTemplateDocxBody>());
      final document = (docx as OfficeTemplateDocxBody).document;
      expect(document.allParagraphs.length, 2);
      final runs = document.allParagraphs.expand((p) => p.runs).toList();
      expect(runs.length, 2);
      expect(
        runs.where((r) => r.sizePt != null).length,
        runs.length,
        reason: '★ 字号必须全部解析出来（书籍阅读器是 0）',
      );
      expect(runs.where((r) => r.color != null).length, runs.length);
      expect(runs.where((r) => r.fontFamily != null).length, runs.length);

      final fallback = prepareOfficeTemplateBody(
        OfficeTemplateBodyKind.docx,
        _brokenDocxBytes('兜底'),
      );
      expect(
        fallback,
        isA<OfficeTemplateRawBody>(),
        reason: '★ OOXML 认不出来 ⇒ 回落第 265 轮的书籍阅读器，而不是空白',
      );

      final pptx = prepareOfficeTemplateBody(
        OfficeTemplateBodyKind.pptx,
        _pptxBytes('主题页'),
      );
      expect(pptx, isA<OfficeTemplatePptxBody>());
      expect((pptx as OfficeTemplatePptxBody).deck.slides, isNotEmpty);

      final sheet = prepareOfficeTemplateBody(
        OfficeTemplateBodyKind.xlsx,
        _xlsxBytes('一季度', '合计'),
      );
      expect(sheet, isA<OfficeTemplateSheetBody>());

      expect(
        prepareOfficeTemplateBody(
          OfficeTemplateBodyKind.xlsx,
          Uint8List.fromList(<int>[1, 2, 3]),
        ),
        isA<OfficeTemplateUnsupportedBody>(),
      );
    });

    testWidgets('★ docx：字号/颜色/字体/页边距**真的画进了 TextSpan**（书籍阅读器全丢）', (
      tester,
    ) async {
      final tpl = _dto(
        _item(
          objectId: '1_meeting_minutes.tpl.doc',
          ntype: 'doc',
          title: 'template_doc:meeting_minutes',
        ),
      );
      await _pumpPreview(
        tester,
        templates: [tpl],
        bodyFetcher: (t) async => _styledDocxBytes('会议纪要标题'),
      );
      await _settle(tester);
      final title = _spanStyleFor(tester, '会议纪要标题');
      expect(title, isNotNull, reason: '标题必须画出来');
      // `w:sz=52`（半磅）→ 26pt → 26*96/72 ≈ 34.67px。
      expect(title!.fontSize, closeTo(52 / 2 * 96 / 72, 0.01));
      expect(title.fontFamily, 'Trebuchet MS');
      final body = _spanStyleFor(tester, '正文段落');
      expect(body, isNotNull);
      // `w:sz=26` → 13pt ≈ 17.33px；`w:color=E55D50`。
      expect(body!.fontSize, closeTo(26 / 2 * 96 / 72, 0.01));
      expect(body.color, const Color(0xFFE55D50));
    });

    testWidgets('★ pptx：走 16:9 幻灯片画布（不是"一页一章的文字流"）', (tester) async {
      final tpl = _dto(
        _item(
          objectId: '1_country_road.tpl.slide',
          ntype: 'presentation',
          title: 'theme_presentation:country_road',
        ),
      );
      await _pumpPreview(
        tester,
        templates: [tpl],
        bodyFetcher: (t) async => _pptxBytes('主题页文字'),
      );
      await _settle(tester);
      expect(
        find.byKey(const Key('office-slides-deck')),
        findsOneWidget,
        reason: '★ 必须是幻灯片画布（有页码指示/翻页），不是书籍分章',
      );
      expect(_richTextHas(tester, '主题页文字'), isTrue);
      // 画布必须是 16:9 的横向舞台，而不是文字行的自然高度。
      final stage = tester.getSize(find.byKey(const Key('office-slides-deck')));
      expect(stage.width, greaterThan(stage.height));
    });

    testWidgets('★ 失败原因分类上屏（不是把异常 toString 甩给用户）', (tester) async {
      final tpl = _dto(
        _item(
          objectId: 't.tpl.doc',
          ntype: 'doc',
          title: 'template_doc:invoice',
        ),
      );
      await _pumpPreview(
        tester,
        templates: [tpl],
        bodyFetcher: (t) async => throw const OfficeAttachmentException(
          OfficeAttachmentErrorKind.timeout,
          dsmCode: 6,
        ),
      );
      await _settle(tester);
      final reason = tester.widget<Text>(
        find.byKey(const Key('office-template-preview-body-reason')),
      );
      expect(reason.data, isNotNull);
      expect(reason.data, contains('超时'), reason: '超时要说得出来（可重试）');
      expect(
        reason.data,
        isNot(contains('OfficeAttachmentException')),
        reason: '★ 不许把工程异常的 toString 直接上屏',
      );
    });

    test('★ 失败原因映射：每一种 kind 都有**各不相同的**用户语言', () {
      final seen = <String>{};
      for (final kind in OfficeAttachmentErrorKind.values) {
        final text = officeTemplateBodyFailureReason(
          OfficeAttachmentException(kind, dsmCode: 1, detail: 'x'),
        );
        expect(text.trim(), isNotEmpty, reason: kind.name);
        expect(text, isNot(contains('OfficeAttachmentException')));
        // `unknown` 走 detail 兜底，与其它 kind 的固定文案不同；这里只要求
        // **非空且不重复暴露异常类型**，去重断言放在下面的固定文案集合里。
        if (kind != OfficeAttachmentErrorKind.unknown) seen.add(text);
      }
      expect(
        seen.length,
        OfficeAttachmentErrorKind.values.length - 1,
        reason: '★ 每个 kind 必须有自己的说明（不能全都回落成同一句）',
      );
      // 未归类异常：原样带一句（绝不吞原因）。
      expect(
        officeTemplateBodyFailureReason(
          const OfficeAttachmentExceptionStub('105 无权限'),
        ),
        contains('105 无权限'),
      );
    });
  });

  // ------------------------------------------------------------ P5 缩略图模式
  group('P5. 没注入正文提供者时仍是纯缩略图预览（既有行为不回归）', () {
    testWidgets('未注入 bodyFetcher → PageView + 缩略图说明行；不出现正文键', (
      tester,
    ) async {
      final tpl = _dto(
        _item(
          objectId: '1_country_road.tpl.slide',
          ntype: 'presentation',
          title: 'theme_presentation:country_road',
        ),
      );
      await _pumpPreview(tester, templates: [tpl]);
      await _settle(tester);
      expect(
        find.byKey(const Key('office-template-preview-pager')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('office-template-preview-note')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('office-template-preview-body')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('office-template-preview-toggle')),
        findsNothing,
      );
      expect(find.text('乡村'), findsOneWidget);
    });

    testWidgets('切到缩略图模式：正文模式的一键回落（并保持同一模板）', (tester) async {
      final a = _dto(
        _item(objectId: 'a.tpl.doc', ntype: 'doc', title: 'template_doc:invoice'),
      );
      final b = _dto(
        _item(objectId: 'b.tpl.doc', ntype: 'doc', title: 'template_doc:invoice'),
      );
      await _pumpPreview(
        tester,
        templates: [a, b],
        initialIndex: 1,
        bodyFetcher: (t) async => _docxBytes('正文'),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('office-template-preview-toggle')));
      await _settle(tester);
      expect(
        find.byKey(const Key('office-template-preview-pager')),
        findsOneWidget,
      );
      expect(find.text('2 / 2'), findsOneWidget, reason: '切模式不换模板');
      // 正文模式下的换模板按钮应消失（缩略图模式用横滑）
      expect(
        find.byKey(const Key('office-template-preview-next')),
        findsNothing,
      );
    });
  });

  // ------------------------------------------------------------ P6 缓存
  group('P6. 正文缓存：内存命中 + 失败记忆', () {
    test('同一 key 第二次 load 不再调用 fetch', () async {
      final cache = OfficeTemplateBodyCache(capacity: 2);
      var calls = 0;
      Future<Uint8List> fetch() async {
        calls++;
        return Uint8List.fromList(<int>[1, 2, 3]);
      }

      await cache.load('a', fetch);
      await cache.load('a', fetch);
      expect(calls, 1);
      expect(cache.memoryKeys, contains('a'));
    });

    test('★ 失败被记住：第二次直接重抛，不打第二次网络', () async {
      final cache = OfficeTemplateBodyCache(capacity: 2);
      var calls = 0;
      Future<Uint8List> fetch() async {
        calls++;
        throw const OfficeAttachmentExceptionStub('119 会话失效');
      }

      await expectLater(cache.load('b', fetch), throwsA(anything));
      await expectLater(cache.load('b', fetch), throwsA(anything));
      expect(calls, 1, reason: '失败记忆必须挡住重复请求');
      expect(cache.failedKeys, contains('b'));
      cache.invalidate('b');
      expect(cache.failedKeys, isEmpty, reason: '重试要能清掉失败记忆');
    });
  });
}

/// 测试用的最小异常（只带一句人能懂的话；生产用
/// `OfficeAttachmentException`，这里避免构造它的全部字段）。
class OfficeAttachmentExceptionStub implements Exception {
  const OfficeAttachmentExceptionStub(this.message);

  final String message;

  @override
  String toString() => message;
}
