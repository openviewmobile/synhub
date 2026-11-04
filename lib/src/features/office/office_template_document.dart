// Office 模板**正文预览**：把模板导出成 OOXML，再交给**既有阅读器**渲染。
//
// 为什么不是"缩略图 + 元数据"（第 260 轮的旧结论已推翻）：
//   第 260 轮说"服务端没有给普通用户的模板正文接口"，依据是真机
//   `Office.Snapshot:get` 回 57379、`Office.Doc.Snapshot:get` 回 105。
//   第 265 轮重新取证（SPK + 真机只读）证明那两类结论各有原因，**不是**"没有"：
//     * `Office.Doc.Snapshot` / `Office.Presentation.Snapshot` 在
//       `webapi/SYNO.Office.lib` 里 `allowUser` **只有 admin** ⇒ 普通用户
//       回 105 是**真实的权限结论**，它们本来就只是编辑器内部的快照接口；
//     * `Office.Snapshot:get` 的参数是 **`link_id`**（缺就回
//       `120 {"name":"link_id","reason":"required"}`，给 Drive 分享链接以外的
//       id 才回 57379）——它是 **Drive 分享链接的预览通道**，不是模板通道；
//     * 模板的正文通道是 **`Office.Export/download`**：官方 `ui.doc.js` 的
//       `downloadOffice()` 对 `Env.is_template` 走的分支逐字是
//       `e = Ext.apply({object_id: SYNO.SDS.Office.Env.objectId}, e)`；
//       模板右键菜单第一项 `itemId:"open"` 文案就是 `cf.preview`（预览），
//       处理函数 `openTemplate()` → 在 Office 阅读器里打开模板本体。
//
// 真机实测（第 265 / 272 轮，只读 POST 表单，53 个系统模板全部可导）：
//   `{object_id, format:"ms"}` → HTTP 200 + 真 OOXML：
//   doc 13,039 B（Meeting minutes.docx）/ sheet 14,536 B（Project timeline.xlsx）
//   / presentation 29,008 B（Countryside.pptx）。证据全文见
//   `docs/office-template-gallery.md` §9/§10。
//
// ★ 第 272 轮改：**改用高保真的既有 Office 阅读器**（仍然"一个文档一个阅读器"）。
//
//   第 265 轮把 docx/pptx 交给**书籍阅读器**（`FileBookBytesStage`）—— 实测
//   （`tool/office_template_preview_probe.dart`，真机导出字节）它把模板正文压成
//   纯文字流：
//     * docx（Meeting minutes，13,039 B）：正文带 **39 个 run 的字号/颜色/字体、
//       27 段行距、13 段项目符号、3 个页眉 3 个页脚、A4 793.7×1122.5px 页边距
//       96px**，而书籍阅读器产出的 HTML 里 `font-size=0 color=0 font-family=0
//       text-align=0`、页眉页脚不读 ⇒ 用户看到的是"一坨没版式的字"；
//     * pptx（Countryside，29,008 B）：真 PPTX 有 **960×540 画布、9 个版式 +
//       1 个母版、16 个形状（2 个几何继承自版式、背景继承）**，而书籍阅读器只
//       产出 `<h2>第 1 页</h2>`（14 B）⇒ 主题模板**几乎空白**。
//   这两条就是用户说的"模版预览的效果很差"。
//
//   仓库里**已经有**同一批字节的高保真阅读器（.odoc/.oslides/.osheet 的 Drive
//   阅读路径就在用），所以这里只是**换用**它们，不新写渲染器（AGENTS §2.0.8 ④）：
//     * docx → `ODocxDocument.parse` + `OfficeDocxView`（A4 纸面/真实页边距/标题
//       层级/字号颜色字体/对齐行距/列表/表格列宽/页眉页脚/分页/缩放适宽）；
//     * pptx → `OSlidesDeck.parse` + `OfficeSlidesDeckView`（16:9 画布/真实 EMU
//       坐标/母版版式继承/背景/图片/文本样式/翻页指示/缩放全屏）；
//     * xlsx → `parseOfficeSheetXlsx` + `OfficeSheetView`（与第 265 轮一致）。
//   **拿不到 / 解析不出来的 OOXML 一律回落到第 265 轮的老路径**（书籍阅读器），
//   所以老服务端、半截字节、非 OOXML 的形态都**不会**比以前更差。
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/i18n/data_text.dart';
import '../../data/office_api.dart';
import '../../data/office_native/osheet_model.dart' show OSheetWorkbook;
import '../../data/office_native/oslides_ooxml.dart' show OSlidesDeck;
import '../files/file_book.dart' show BookFormat;
import '../files/file_book_view.dart' show FileBookBytesStage;
import 'office_doc_ooxml.dart' show ODocxDocument;
import 'office_doc_ooxml_view.dart' show OfficeDocxView;
import 'office_sheet_view.dart';
import 'office_sheet_xlsx.dart';
import 'office_slides_deck_view.dart' show OfficeSlidesDeckView;

/// 取一个模板的**正文字节**（生产 = `OfficeApi.templateExportBytes`）。
///
/// 测试注入假实现即可离线跑（不需要 NAS / 不需要 Mock Server）。
typedef OfficeTemplateBodyFetcher =
    Future<Uint8List> Function(OfficeTemplateDto template);

/// 模板正文导出后的格式（决定用哪个既有阅读器）。
enum OfficeTemplateBodyKind {
  /// `ms` 导出的 `docx` → 富文本阅读器。
  docx('docx'),

  /// `ms` 导出的 `xlsx` → 只读网格。
  xlsx('xlsx'),

  /// `ms` 导出的 `pptx` → 分页阅读器。
  pptx('pptx');

  const OfficeTemplateBodyKind(this.extension);

  final String extension;
}

/// `ntype` → 导出格式（官方 `EXPORT_EXTENSION = {odoc:"docx", osheet:"xlsx",
/// oslides:"pptx"}`，`ui.doc.js` 偏移 3661674 逐字）。
///
/// 认不出来时返回 `null`（**不猜**：未知 `ntype` 一律回落缩略图）。
OfficeTemplateBodyKind? officeTemplateBodyKind(String ntype) {
  switch (ntype.trim().toLowerCase()) {
    case 'doc':
      return OfficeTemplateBodyKind.docx;
    case 'sheet':
      return OfficeTemplateBodyKind.xlsx;
    case 'presentation':
      return OfficeTemplateBodyKind.pptx;
    default:
      return null;
  }
}

/// 模板正文在内存里的短缓存（跨预览页复用，避免左右换模板时反复导）。
///
/// 只放内存：模板正文是**服务端现算**的导出产物（几十 KB），磁盘缓存意义
/// 不大；失败记忆让"这个模板导不出来"不要在每次重建时重打一次网络
/// （同 `OfficeTemplateThumbCache` 的失败记忆语义，AGENTS §2.0.17 ②）。
class OfficeTemplateBodyCache {
  OfficeTemplateBodyCache({this.capacity = 8});

  final int capacity;
  final Map<String, Uint8List> _memory = <String, Uint8List>{};
  final Map<String, Object> _failed = <String, Object>{};
  final Map<String, Future<Uint8List>> _inflight =
      <String, Future<Uint8List>>{};

  Iterable<String> get memoryKeys => _memory.keys;
  Iterable<String> get failedKeys => _failed.keys;

  /// 加载：内存命中 → 直接返回；失败记忆命中 → 重抛（不发网络）；
  /// 否则并发去重取一次并落内存。
  Future<Uint8List> load(String key, Future<Uint8List> Function() fetch) {
    final cached = _memory[key];
    if (cached != null) return Future<Uint8List>.value(cached);
    final failure = _failed[key];
    if (failure != null) return Future<Uint8List>.error(failure);
    final pending = _inflight[key];
    if (pending != null) return pending;
    final future = fetch();
    _inflight[key] = future;
    future.then<void>(
      (bytes) {
        _inflight.remove(key);
        _memory[key] = bytes;
        if (_memory.length > capacity) {
          _memory.remove(_memory.keys.first);
        }
      },
      onError: (Object e) {
        _inflight.remove(key);
        _failed[key] = e;
      },
    );
    return future;
  }

  /// 忘掉一个模板的记忆（失败后重试 / 主动刷新）。
  void invalidate(String key) {
    _memory.remove(key);
    _failed.remove(key);
  }
}

/// 进程级默认缓存（预览页不注入时用它）。
final OfficeTemplateBodyCache officeTemplateBodyCache =
    OfficeTemplateBodyCache();

// ------------------------------------------------------------------ 解析模型
//
// 「取字节」与「解析成阅读器模型」在这里**分开**：取字节（网络/错误分类/失败
// 记忆）是异步且有副作用的；解析是**纯函数**（离线用例可以直接钉），渲染是
// 纯 widget。预览页的三个中间态（fetching / rendering / failed）也因此有据可依。

/// 一份**已解析**的模板正文；每个子类都对应一个**既有**阅读器组件。
sealed class OfficeTemplateBodyModel {
  const OfficeTemplateBodyModel();
}

/// docx → `OfficeDocxView`（`.odoc` 的首选路径，同一份解析器）。
final class OfficeTemplateDocxBody extends OfficeTemplateBodyModel {
  const OfficeTemplateDocxBody(this.document);

  final ODocxDocument document;
}

/// pptx → `OfficeSlidesDeckView`（`.oslides` 的首选路径，同一份解析器）。
final class OfficeTemplatePptxBody extends OfficeTemplateBodyModel {
  const OfficeTemplatePptxBody(this.deck);

  final OSlidesDeck deck;
}

/// xlsx → `OfficeSheetView`（与第 265 轮一致；文件预览里的 `.xlsx` 也是它）。
final class OfficeTemplateSheetBody extends OfficeTemplateBodyModel {
  const OfficeTemplateSheetBody(this.workbook);

  final OSheetWorkbook workbook;
}

/// OOXML 解不出来时的**字节兜底**：交给第 265 轮的书籍阅读器（docx/pptx）。
///
/// 只有这一条路会用到它；**不是**"新写了第二个阅读器"，而是保留升级前的行为。
final class OfficeTemplateRawBody extends OfficeTemplateBodyModel {
  const OfficeTemplateRawBody(this.bytes, this.kind);

  final Uint8List bytes;
  final OfficeTemplateBodyKind kind;
}

/// 连兜底阅读器都用不上（xlsx 不是 OOXML / 解析抛异常）→ 一句可读的说明。
final class OfficeTemplateUnsupportedBody extends OfficeTemplateBodyModel {
  const OfficeTemplateUnsupportedBody({
    required this.icon,
    required this.text,
  });

  final IconData icon;
  final String text;
}

/// 纯函数：把导出的字节解析成**既有阅读器**要的模型（可离线单测）。
///
/// 优先级 = "高保真 → 老路径 → 可读说明"，任何一步失败都**如实降级**，
/// 绝不抛给界面（界面只负责显示）。
OfficeTemplateBodyModel prepareOfficeTemplateBody(
  OfficeTemplateBodyKind kind,
  Uint8List bytes,
) {
  switch (kind) {
    case OfficeTemplateBodyKind.docx:
      // 首选：`.odoc` 的同一条 OOXML 路径（A4 纸面 + 真实版式）。
      final document = ODocxDocument.parse(bytes);
      if (document != null && !document.isEmpty) {
        return OfficeTemplateDocxBody(document);
      }
      // 兜底：第 265 轮的书籍阅读器（老服务端 / 半截字节 / 非 ZIP）。
      return OfficeTemplateRawBody(bytes, kind);
    case OfficeTemplateBodyKind.pptx:
      // 首选：`.oslides` 的同一条 OOXML 路径（16:9 画布 + 母版版式继承）。
      final deck = OSlidesDeck.parse(bytes);
      if (deck != null && deck.slides.isNotEmpty) {
        return OfficeTemplatePptxBody(deck);
      }
      return OfficeTemplateRawBody(bytes, kind);
    case OfficeTemplateBodyKind.xlsx:
      // 与第 265 轮**逐字一致**：非 OOXML 或解析失败都给一句可读说明
      // （表格没有"文字流兜底"的意义，网格渲不出来就是渲不出来）。
      if (!isOfficeSheetOoxmlBytes(bytes)) {
        return OfficeTemplateUnsupportedBody(
          icon: Icons.table_chart_outlined,
          text: dataText(
            'officeTemplateBodyNotOoxml',
            '服务端返回的不是标准表格文件，无法预览',
          ),
        );
      }
      try {
        return OfficeTemplateSheetBody(parseOfficeSheetXlsx(bytes));
      } catch (e) {
        return OfficeTemplateUnsupportedBody(
          icon: Icons.table_chart_outlined,
          text: dataText(
            'officeTemplateBodyParseFailed',
            '这份模板解析失败，暂时看不了正文',
          ).replaceAll('{error}', '$e'),
        );
      }
  }
}

/// 一份模板正文的**只读渲染**（模型已在手；解析是调用方的事）。
class OfficeTemplateBodyView extends StatelessWidget {
  const OfficeTemplateBodyView({
    super.key,
    required this.model,
    this.title = '',
  });

  final OfficeTemplateBodyModel model;

  /// 阅读器的兜底标题（本地化模板名）。
  final String title;

  @override
  Widget build(BuildContext context) {
    final model = this.model;
    switch (model) {
      case OfficeTemplateDocxBody(:final document):
        return OfficeDocxView(
          key: const Key('office-template-body-docx'),
          doc: document,
        );
      case OfficeTemplatePptxBody(:final deck):
        return OfficeSlidesDeckView(
          key: const Key('office-template-body-slides'),
          deck: deck,
        );
      case OfficeTemplateSheetBody(:final workbook):
        return OfficeSheetView(
          key: const Key('office-template-body-sheet'),
          sections: const <String, Object?>{},
          workbook: workbook,
        );
      case OfficeTemplateRawBody(:final bytes, :final kind):
        // 第 265 轮的老路径（书籍阅读器：docx/pptx 的文字流），原样保留作兜底。
        return FileBookBytesStage(
          key: const Key('office-template-body-book'),
          bytes: bytes,
          format: kind == OfficeTemplateBodyKind.docx
              ? BookFormat.docx
              : BookFormat.pptx,
          title: title,
        );
      case OfficeTemplateUnsupportedBody(:final icon, :final text):
        return _TemplateBodyHint(
          key: const Key('office-template-body-unsupported'),
          icon: icon,
          text: text,
        );
    }
  }
}

class _TemplateBodyHint extends StatelessWidget {
  const _TemplateBodyHint({
    super.key,
    required this.icon,
    required this.text,
  });

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
