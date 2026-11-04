// ★★★ ③Drive **D61「PDF 批注 / 签名」** —— 第 219 轮（最后一个 ❌）。
//
// ## 官方证据
// 官方 Drive 包内带 **`pdftool` / pdfium / pdfbox**（`libpdfium*.so` +
// `com.synology.pdftool.*` 的 smali），App 内可直接给 PDF 加批注/签名后再存回 Drive。
//
// ## 我方口径（诚实边界）
// * **批注**：高亮框 / 手写笔迹（含"签名"复用）/ 便签文字 —— 三种都在；
// * **落地**：批注存**同名 sidecar**（`<名字>.pdf.markups.json`，键 `drive_pdf_markup_v1`），
//   再次打开自动带出来；
// * **导出**：把每页位图 + 批注**烙平**成新 PDF（`pdf` 包），可保存回 Drive
//   （走既有的 `Files/upload`，wire 契约已 Mock 核实）。
// * ⚠️ **没有**做官方 pdfium 那种"写进 PDF 对象层的注释对象"
//   （即导出后批注不可再单独编辑/删除）；烙平是我们的实现选择，如实登记。
import 'dart:convert';
import 'dart:io';

/// 批注种类
enum PdfMarkupKind {
  /// 高亮框（矩形）
  highlight('highlight', '高亮'),

  /// 手写笔迹（含签名）
  ink('ink', '手写'),

  /// 便签文字
  note('note', '便签');

  const PdfMarkupKind(this.wire, this.label);
  final String wire;
  final String label;
}

PdfMarkupKind pdfMarkupKindOf(String? wire) {
  for (final k in PdfMarkupKind.values) {
    if (k.wire == wire) return k;
  }
  return PdfMarkupKind.highlight;
}

/// 一条批注。坐标一律 **归一化到 0..1**（相对页宽/页高）——
/// 这样换渲染尺寸/换设备都不用重算，导出时再乘回去。
class PdfMarkup {
  const PdfMarkup({
    required this.id,
    required this.page,
    required this.kind,
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
    this.points = const [],
    this.color = 0xFFFFD54F,
    this.note = '',
    this.createdAtMs = 0,
    this.quads = const [],
    this.selectedText = '',
  });

  final String id;

  /// 0 起页号（与 pdfx / 官方的页序一致）
  final int page;
  final PdfMarkupKind kind;

  /// 高亮框（归一化）
  final double left;
  final double top;
  final double right;
  final double bottom;

  /// 手写笔迹的点（归一化；`[x0,y0,x1,y1,…]`）
  final List<double> points;

  /// ARGB
  final int color;

  /// 便签文字
  final String note;
  final int createdAtMs;

  /// ★ 245 轮 D61：**文字层联动** —— 框选到的文字行四边形
  /// （PDF 坐标、每 8 个数一个四边形：左上/右上/左下/右下）。
  /// 为空时高亮的 `/QuadPoints` 由 `left/top/right/bottom` 推出。
  final List<double> quads;

  /// 框选到的文字（`/Contents` 在 `note` 为空时用它）
  final String selectedText;

  bool get isRect => kind == PdfMarkupKind.highlight;

  Map<String, Object?> toJson() => {
    'id': id,
    'page': page,
    'kind': kind.wire,
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
    'points': points,
    'color': color,
    'note': note,
    'created_at': createdAtMs,
    if (quads.isNotEmpty) 'quads': quads,
    if (selectedText.isNotEmpty) 'selected_text': selectedText,
  };

  static PdfMarkup fromJson(Map<String, Object?> j) => PdfMarkup(
    id: '${j['id'] ?? ''}',
    page: (j['page'] as num?)?.toInt() ?? 0,
    kind: pdfMarkupKindOf(j['kind'] as String?),
    left: (j['left'] as num?)?.toDouble() ?? 0,
    top: (j['top'] as num?)?.toDouble() ?? 0,
    right: (j['right'] as num?)?.toDouble() ?? 0,
    bottom: (j['bottom'] as num?)?.toDouble() ?? 0,
    points: [
      for (final p in (j['points'] as List?) ?? const []) (p as num).toDouble(),
    ],
    color: (j['color'] as num?)?.toInt() ?? 0xFFFFD54F,
    note: '${j['note'] ?? ''}',
    createdAtMs: (j['created_at'] as num?)?.toInt() ?? 0,
    // 旧 sidecar 没有这两个字段 ⇒ 默认空（向后兼容）
    quads: [
      for (final q in (j['quads'] as List?) ?? const []) (q as num).toDouble(),
    ],
    selectedText: '${j['selected_text'] ?? ''}',
  );

  PdfMarkup copyWith({int? color, String? note}) => PdfMarkup(
    id: id,
    page: page,
    kind: kind,
    left: left,
    top: top,
    right: right,
    bottom: bottom,
    points: points,
    color: color ?? this.color,
    note: note ?? this.note,
    createdAtMs: createdAtMs,
    quads: quads,
    selectedText: selectedText,
  );
}

/// 一份 PDF 的全部批注（sidecar 内容）
class PdfMarkupDoc {
  PdfMarkupDoc({List<PdfMarkup>? marks}) : marks = [...?marks];

  final List<PdfMarkup> marks;

  List<PdfMarkup> marksForPage(int page) =>
      marks.where((m) => m.page == page).toList()
        ..sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));

  void add(PdfMarkup m) => marks.add(m);

  bool remove(String id) {
    final before = marks.length;
    marks.removeWhere((m) => m.id == id);
    return marks.length != before;
  }

  bool replace(PdfMarkup m) {
    final i = marks.indexWhere((x) => x.id == m.id);
    if (i < 0) return false;
    marks[i] = m;
    return true;
  }

  int get count => marks.length;
  bool get isEmpty => marks.isEmpty;

  Map<String, Object?> toJson() => {
    'key': kPdfMarkupSidecarKey,
    'version': 1,
    'marks': [for (final m in marks) m.toJson()],
  };

  static PdfMarkupDoc fromJson(Map<String, Object?> j) => PdfMarkupDoc(
    marks: [
      for (final e in (j['marks'] as List?) ?? const [])
        if (e is Map) PdfMarkup.fromJson(Map<String, Object?>.from(e)),
    ],
  );

  String encode() => jsonEncode(toJson());

  static PdfMarkupDoc decode(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return PdfMarkupDoc();
      return PdfMarkupDoc.fromJson(Map<String, Object?>.from(j));
    } catch (_) {
      // 坏 sidecar（截断/不是 JSON）不该让 PDF 打不开
      return PdfMarkupDoc();
    }
  }
}

const String kPdfMarkupSidecarKey = 'drive_pdf_markup_v1';

/// sidecar 文件名：`报告.pdf` → `报告.pdf.markups.json`
String pdfMarkupSidecarName(String fileName) => '$fileName.markups.json';

/// 归一化坐标 → 像素（给绘制/导出用）
({double left, double top, double right, double bottom}) pdfMarkupRectOnPage(
  PdfMarkup m,
  double width,
  double height,
) => (
  left: m.left * width,
  top: m.top * height,
  right: m.right * width,
  bottom: m.bottom * height,
);

/// 归一化笔迹 → 像素点对
List<Offset2> pdfInkPointsOnPage(PdfMarkup m, double width, double height) {
  final out = <Offset2>[];
  for (var i = 0; i + 1 < m.points.length; i += 2) {
    out.add(Offset2(m.points[i] * width, m.points[i + 1] * height));
  }
  return out;
}

/// 不依赖 Flutter 的二维点（核心层保持纯 Dart，用例可离线跑）
class Offset2 {
  const Offset2(this.dx, this.dy);
  final double dx;
  final double dy;

  @override
  bool operator ==(Object other) =>
      other is Offset2 && other.dx == dx && other.dy == dy;

  @override
  int get hashCode => Object.hash(dx, dy);

  @override
  String toString() => '($dx, $dy)';
}

/// 把像素坐标**夹回页内**再归一化（手滑出界不该产生越界批注）
PdfMarkup normalizePdfInk({
  required String id,
  required int page,
  required List<double> pixelPoints,
  required double width,
  required double height,
  int color = 0xFFE53935,
  int createdAtMs = 0,
}) {
  final pts = <double>[];
  for (var i = 0; i + 1 < pixelPoints.length; i += 2) {
    pts.add((pixelPoints[i] / width).clamp(0.0, 1.0));
    pts.add((pixelPoints[i + 1] / height).clamp(0.0, 1.0));
  }
  return PdfMarkup(
    id: id,
    page: page,
    kind: PdfMarkupKind.ink,
    points: pts,
    color: color,
    createdAtMs: createdAtMs,
  );
}

/// 两个像素点 → 归一化高亮框（左下/右上自动归位）
PdfMarkup normalizePdfHighlight({
  required String id,
  required int page,
  required double x0,
  required double y0,
  required double x1,
  required double y1,
  required double width,
  required double height,
  int color = 0xFFFFD54F,
  String note = '',
  int createdAtMs = 0,
}) => PdfMarkup(
  id: id,
  page: page,
  kind: PdfMarkupKind.highlight,
  left: (x0 < x1 ? x0 : x1) / width,
  top: (y0 < y1 ? y0 : y1) / height,
  right: (x0 < x1 ? x1 : x0) / width,
  bottom: (y0 < y1 ? y1 : y0) / height,
  color: color,
  note: note,
  createdAtMs: createdAtMs,
);

/// 一页的位图（导出时烙平用）
class PdfPageBitmap {
  const PdfPageBitmap({
    required this.page,
    required this.width,
    required this.height,
    required this.pngBytes,
  });

  final int page;
  final int width;
  final int height;
  final Uint8ListLike pngBytes;
}

/// `Uint8List` 的别名（核心层不 import `dart:typed_data` 也能读，
/// 但为了调用方方便这里直接用真实类型别名）。
typedef Uint8ListLike = List<int>;

/// 把批注**烙平**成 PDF 页面的绘制指令（纯数据，真正画在界面层做）。
///
/// 为什么要这一步：导出与上屏必须用**同一套几何**，否则"看到的"和"导出的"不一致。
class PdfPageDrawOp {
  const PdfPageDrawOp({
    required this.kind,
    required this.rect,
    this.points = const [],
    this.color = 0,
    this.note = '',
  });

  final PdfMarkupKind kind;
  final ({double left, double top, double right, double bottom}) rect;
  final List<Offset2> points;
  final int color;
  final String note;
}

List<PdfPageDrawOp> pdfPageDrawOps(
  PdfMarkupDoc doc,
  int page,
  double width,
  double height,
) => [
  for (final m in doc.marksForPage(page))
    if (m.isRect)
      PdfPageDrawOp(
        kind: m.kind,
        rect: pdfMarkupRectOnPage(m, width, height),
        color: m.color,
        note: m.note,
      )
    else
      PdfPageDrawOp(
        kind: m.kind,
        rect: pdfMarkupRectOnPage(m, width, height),
        points: pdfInkPointsOnPage(m, width, height),
        color: m.color,
        // ★ 231 轮修 bug：便签不是 rect，走的是这条分支 —— 之前 `note` **没有
        // 带出来**，导致 219 轮导出的便签只是一个**空黄框**（文字丢了）。
        note: m.note,
      ),
];

// ------------------------------------------------------------ sidecar 存储

abstract class PdfMarkupStore {
  Future<PdfMarkupDoc> load(String filePath);
  Future<void> save(String filePath, PdfMarkupDoc doc);
}

/// 内存实现（用例用）
class MemoryPdfMarkupStore implements PdfMarkupStore {
  MemoryPdfMarkupStore([Map<String, PdfMarkupDoc>? initial])
    : _docs = {...?initial};

  final Map<String, PdfMarkupDoc> _docs;

  Map<String, PdfMarkupDoc> get snapshot => Map.unmodifiable(_docs);

  @override
  Future<PdfMarkupDoc> load(String filePath) async =>
      _docs[filePath] ?? PdfMarkupDoc();

  @override
  Future<void> save(String filePath, PdfMarkupDoc doc) async {
    // 存一份**拷贝**，免得调用方后续改动影响"已存盘"的内容（真实文件也一样）
    _docs[filePath] = PdfMarkupDoc.decode(doc.encode());
  }
}

/// sidecar 落在 **PDF 旁边**（`<dir>/<name>.pdf.markups.json`）。
///
/// 为什么放旁边而不是应用私有目录：导出/同步时批注跟着文件走，
/// 用户重装 App 也不会丢（与官方"注释属于文档"的语义一致）。
class SidecarPdfMarkupStore implements PdfMarkupStore {
  const SidecarPdfMarkupStore();

  File _fileFor(String filePath) =>
      File('${File(filePath).parent.path}/${pdfMarkupSidecarName(filePath.split('/').last)}');

  @override
  Future<PdfMarkupDoc> load(String filePath) async {
    final f = _fileFor(filePath);
    if (!await f.exists()) return PdfMarkupDoc();
    try {
      return PdfMarkupDoc.decode(await f.readAsString());
    } catch (_) {
      // 坏 sidecar 不该让 PDF 打不开
      return PdfMarkupDoc();
    }
  }

  @override
  Future<void> save(String filePath, PdfMarkupDoc doc) async {
    final f = _fileFor(filePath);
    await f.parent.create(recursive: true);
    await f.writeAsString(doc.encode());
  }
}
