// ★★★ D37「保存为扫描件」—— 第 99 轮实现。
//
// ## 官方证据（docs/drive-apk391113-evidence.md §2）
// * 官方 `SynologyDrive 3.9.0-1113` 的 manifest 里有
//   `com.synology.sylibx.documentscanner.ui.activity.DocumentScannerActivity`
//   （从 `ShowFolderActivity` 等入口调）；
// * 输出是 **PDF**：`"%s.pdf"`、`"\\.(png|pdf)$"`、
//   `Landroid/graphics/pdf/PdfDocument;`（smali 字符串级证据）。
//
// ## 我方实现口径（诚实边界）
// * **多页拍照 → 合成 PDF → `Files/upload` 整文件上传**。
//   `Files/upload`（offset<=-1 分支，v=min(8,maxVersion)、
//   `path=id:<folder>/<name>.pdf`、`conflict_action=version`）是**既有已验证**
//   的上传通道，不新造 API。
// * ⚠️ 官方扫描器有边缘检测/自动裁边/OCR（mlkit）；我方**没有**做图像增强，
//   只是"拍照合成 PDF"——这是**功能子集**，如实登记，不冒充对齐。
// * 合成用 `pdf` 包（纯 Dart，把每页 JPEG 整页放入）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/i18n/data_text.dart';
import '../../core/media/camera_support.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../files/drive_providers.dart';
import 'drive_scan_enhance.dart';
import 'drive_scan_ocr_template.dart';

/// 扫描页的来源（官方扫描器既能**拍**新页，也能**从相册导入**）。
enum ScanPageSource {
  /// 相机拍一页
  camera,

  /// 相册多选导入（可以一次导入多张）
  gallery,
}

/// 逐页拍照（相机）/ 相册多选；返回本地文件列表。
///
/// ⚠️ `ImageSource.camera` 一次一张（`image_picker` 官方行为）；
/// 官方扫描器是连续拍摄页。这里用"拍一页→加一页"的循环替代。
Future<List<File>> captureScanPages(ImageSource source) async {
  final picker = ImagePicker();
  final pages = <File>[];
  if (source == ImageSource.gallery) {
    // ★ 216 轮：相册**多选**导入（官方扫描器也从相册加页）
    final picked = await picker.pickMultiImage(imageQuality: 85);
    for (final x in picked) {
      pages.add(File(x.path));
    }
    return pages;
  }
  while (true) {
    final x = await picker.pickImage(source: source, imageQuality: 85);
    if (x == null) break; // 用户取消 ⇒ 结束本页循环
    pages.add(File(x.path));
    // 连续拍：取消即停（官方同款交互：拍完可继续/结束）。
    break;
  }
  return pages;
}

/// 取页的出口（可注入 ⇒ **离线用例不需要原生相机/相册**）。
typedef ScanPagePicker = Future<List<File>> Function(ScanPageSource source);

Future<List<File>> _defaultScanPicker(ScanPageSource source) async {
  // ★ DA293：桌面端 camera 源必然抛 `UnimplementedError`；这里给出**具名**异常，
  //   让页面能显示一句人话（原来它会直接落进 `_addPages` 的异步缝隙）。
  if (source == ScanPageSource.camera && !kCameraCaptureSupported) {
    throw UnsupportedError('这台设备没有可用的相机');
  }
  return captureScanPages(
    source == ScanPageSource.gallery
        ? ImageSource.gallery
        : ImageSource.camera,
  );
}

final scanPagePickerProvider = Provider<ScanPagePicker>(
  (ref) => _defaultScanPicker,
);

/// 把多张 JPEG 合成一个 PDF（每张一页，A4 整页铺满）。
Future<File> composePdf(List<File> pages, String title) async {
  assert(pages.isNotEmpty, '至少要有一页');
  final doc = pw.Document();
  for (final page in pages) {
    final bytes = await page.readAsBytes();
    final image = pw.Image(pw.MemoryImage(bytes));
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (ctx) => pw.Center(child: image),
      ),
    );
  }
  final dir = await getTemporaryDirectory();
  final safe = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  final out = File(
    '${dir.path}/scan_${DateTime.now().millisecondsSinceEpoch}_$safe.pdf',
  );
  return out.writeAsBytes(await doc.save());
}

/// 扫描页：拍页 → 合成 PDF → 上传到当前 Drive 目录。
class DriveScanPage extends ConsumerStatefulWidget {
  const DriveScanPage({super.key, required this.folderId});

  /// 目标目录的 file_id
  final String folderId;

  @override
  ConsumerState<DriveScanPage> createState() => _DriveScanPageState();
}

class _DriveScanPageState extends ConsumerState<DriveScanPage> {
  final _pages = <File>[];
  final _nameController = TextEditingController(text: 'Scan');
  bool _busy = false;

  /// ★ 232 轮：逐页做版面分析（文字行/词块），**只报数字，不编文字**。
  Future<void> _analyzeLines() async {
    setState(() => _busy = true);
    var lines = 0;
    var words = 0;
    var failed = 0;
    var chars = 0;
    var unknown = 0;
    for (final f in [..._pages]) {
      try {
        final decoded = img.decodeImage(await f.readAsBytes());
        if (decoded == null) {
          failed += 1;
          continue;
        }
        // ★ 243 轮：从"只切版面"升级为**真识别**（自研点阵模板引擎）。
        // 边界如实写在结果里：中文/手写认不出 ⇒ 会以 `?` 计入 unknown。
        final r = await const ScanGlyphOcrEngine().recognize(decoded);
        lines += r.layout.lines.length;
        for (final l in r.layout.lines) {
          words += l.words.length;
        }
        if (r.recognized) {
          for (final t in r.text) {
            chars += t.replaceAll(' ', '').length;
            unknown += '?'.allMatches(t).length;
          }
        } else {
          unknown += 1; // 整页没认出来：记 1，不虚报字符数
        }
      } catch (_) {
        failed += 1;
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    // ★ D37 诚实口径：自研引擎只保证**点阵风格印刷体的 0-9 A-Z**；
    // 中文/手写会落到 `?`（unknown），**绝不假装认出来了**。
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          [
            context.t.driveScanLayoutStats(lines, words),
            if (failed != 0) context.t.driveScanLayoutFailPart(failed),
            context.t.driveScanOcrStats(chars),
            if (unknown != 0) context.t.driveScanUnknownPart(unknown),
          ].join(),
        ),
      ),
    );
  }

  /// ★ 225 轮：逐页跑"检测 → 矫正 → 增强"，**原地**写回（页模型不变）。
  /// 如实汇报：有多少页真的检测到边界、多少页用了整幅兜底。
  Future<void> _enhanceAll() async {
    setState(() => _busy = true);
    var detected = 0;
    var failed = 0;
    for (final f in [..._pages]) {
      try {
        final decoded = img.decodeImage(await f.readAsBytes());
        if (decoded == null) {
          failed += 1;
          continue;
        }
        final r = scanDocumentPipeline(decoded);
        if (r.detected) detected += 1;
        await f.writeAsBytes(img.encodePng(r.image));
      } catch (_) {
        failed += 1;
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          [
            context.t.driveScanProcessedStats(_pages.length, detected),
            if (failed != 0) context.t.driveScanLayoutFailPart(failed),
          ].join(),
        ),
      ),
    );
  }
  String? _error;
  String? _savedName;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _addPages(ScanPageSource source) async {
    // ★ DA293：挑页失败要**说出原因**（权限被拒 / 桌面无相机），
    //   不能再让它落进异步缝隙变成"点了没反应"。
    late final List<File> picked;
    try {
      picked = await ref.read(scanPagePickerProvider)(source);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e is UnsupportedError
          ? dataText('chatCameraUnavailable', '这台设备没有可用的相机，请改用「相册」选择图片。')
          : dataText('driveScanPickFailed', '取页失败，请重试。'));
      debugPrint('[drive-scan] 取页失败（$source）：$e');
      return;
    }
    if (picked.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _pages.addAll(picked);
      _error = null;
    });
  }

  /// ★ 216 轮：页管理（官方扫描器有逐页审阅）——移序。
  void _move(int from, int to) {
    if (to < 0 || to >= _pages.length) return;
    setState(() {
      final page = _pages.removeAt(from);
      _pages.insert(to, page);
    });
  }

  void _removeAt(int i) {
    setState(() {
      _pages.removeAt(i);
      if (_pages.isEmpty) _savedName = null;
    });
  }

  Future<void> _upload() async {
    if (_pages.isEmpty) {
      setState(() => _error = context.t.driveScanNeedPage);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final name =
          '${_nameController.text.trim().isEmpty ? 'Scan' : _nameController.text.trim()}.pdf';
      final pdf = await composePdf(_pages, _nameController.text.trim());
      final api = ref.read(driveApiProvider);
      if (api == null) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = context.t.setNotConnected;
        });
        return;
      }
      await api.uploadFile(
        folderId: widget.folderId,
        filePath: pdf.path,
        fileName: name,
        mimeType: 'application/pdf',
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _savedName = name;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '${context.t.driveScanUploadFailed}: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    return Scaffold(
      key: const Key('drive-scan-page'),
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(t.driveScanTitle),
        actions: [
          // ★ 225 轮 D37：**自动裁边 + 透视矫正 + 增强**（纯 Dart 实现；
          // 官方走 MLKit，我方算法更弱但离线可验，见台账 D37）。
          IconButton(
            key: const Key('drive-scan-enhance'),
            tooltip: context.t.driveScanEnhance,
            icon: const Icon(Icons.auto_fix_high_outlined),
            onPressed: _pages.isEmpty || _busy ? null : _enhanceAll,
          ),
          // ★ 232 轮 D37：**版面分析**（切文字行/词块）。
          // 如实说明：本仓库不内置字符识别 ⇒ 只报"切了多少行"，
          // **不**编造识别文字（识别层留 `ScanOcrEngine` 接口）。
          IconButton(
            key: const Key('drive-scan-lines'),
            tooltip: context.t.driveScanLines,
            icon: const Icon(Icons.format_align_left_outlined),
            onPressed: _pages.isEmpty || _busy ? null : _analyzeLines,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              enabled: !_busy,
              decoration: InputDecoration(labelText: t.driveScanTitle),
            ),
            const SizedBox(height: Gap.lg),
            Text(t.driveScanPages(_pages.length)),
            const SizedBox(height: Gap.md),
            Expanded(
              child: _pages.isEmpty
                  ? AppEmptyState(
                      icon: Icons.document_scanner_outlined,
                      title: t.driveScanTitle,
                      message: t.driveScanCapture,
                    )
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: Gap.sm,
                            mainAxisSpacing: Gap.sm,
                          ),
                      itemCount: _pages.length,
                      itemBuilder: (context, i) => Stack(
                        key: Key(
                          'drive-scan-page-${_pages[i].path.split('/').last}',
                        ),
                        fit: StackFit.expand,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(Gap.sm),
                            child: Image.file(_pages[i], fit: BoxFit.cover),
                          ),
                          // 页管理：移序（←/→）+ 删除（官方扫描器逐页审阅）
                          Positioned(
                            left: 0,
                            top: 0,
                            child: _PageAction(
                              key: Key('drive-scan-page-left-$i'),
                              icon: Icons.chevron_left,
                              tooltip: context.t.driveScanMovePrev,
                              onTap: i == 0 ? null : () => _move(i, i - 1),
                            ),
                          ),
                          Positioned(
                            left: 28,
                            top: 0,
                            child: _PageAction(
                              key: Key('drive-scan-page-right-$i'),
                              icon: Icons.chevron_right,
                              tooltip: context.t.driveScanMoveNext,
                              onTap: i == _pages.length - 1
                                  ? null
                                  : () => _move(i, i + 1),
                            ),
                          ),
                          Positioned(
                            right: 0,
                            top: 0,
                            child: _PageAction(
                              key: Key('drive-scan-page-remove-$i'),
                              icon: Icons.close,
                              tooltip: context.t.driveScanRemovePage,
                              onTap: () => _removeAt(i),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            Row(
              children: [
                // ★ DA293：桌面端没有相机实现 ⇒ 不摆「拍摄」（假控件）
                if (kCameraCaptureSupported) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('drive-scan-capture'),
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: Text(t.driveScanCapture),
                      onPressed: _busy
                          ? null
                          : () => _addPages(ScanPageSource.camera),
                    ),
                  ),
                  const SizedBox(width: Gap.md),
                ],
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('drive-scan-gallery'),
                    icon: const Icon(Icons.photo_library_outlined),
                    label: Text(context.t.driveScanGallery),
                    onPressed: _busy
                        ? null
                        : () => _addPages(ScanPageSource.gallery),
                  ),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('drive-scan-upload'),
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.picture_as_pdf_outlined),
                    label: Text(t.driveScanDone),
                    onPressed: _busy ? null : _upload,
                  ),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: Gap.md),
                child: Text(
                  key: const Key('drive-scan-error'),
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_savedName != null)
              Padding(
                padding: const EdgeInsets.only(top: Gap.md),
                child: Text(
                  key: const Key('drive-scan-saved'),
                  t.driveScanSaved(_savedName!),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 页角上的小动作按钮（移序/删除）。
class _PageAction extends StatelessWidget {
  const _PageAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return Material(
      color: hud.surface2,
      shape: const CircleBorder(),
      child: IconButton(
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        tooltip: onTap == null ? null : tooltip,
        onPressed: onTap,
        icon: Icon(icon, color: onTap == null ? hud.dim : null),
      ),
    );
  }
}
