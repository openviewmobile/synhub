// 附件（`template/**/files/<file_id>`，73 个裸 PNG/JPEG）与模型引用的对账。
//
// 研究文档 §5.4/§4.1(3)：`attachment.json[].file_id` ↔ `files/<file_id>` 文件名一一对应，
// 内容是**原始图片字节、无再编码**；模型里的图片引用（`.odoc` 的 `picture.attrs.config.file_id`、
// `.oslides` 的 `image.attrs.file_id`）必须能取到这些字节。
//
// 真实 `.odoc/.osheet/.oslides` 里图片是**内嵌 BSON binary**（阶段 2 才解得开）；
// 本测试验证的是"文本侧 file_id → 原始字节"这条链路（样本布局）。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_native/office_native_reader.dart';
import 'support/office_samples.dart';

final Directory _root = Directory(
  officeTemplateRoot().path,
);

final String? _skipReason = _root.existsSync()
    ? null
    : '官方样本缺失：${_root.path}（包内样本，不 vendored；'
          '见 docs/office-native-format-research.md §5）';

bool _isPng(List<int> b) =>
    b.length >= 8 &&
    b[0] == 0x89 &&
    b[1] == 0x50 &&
    b[2] == 0x4E &&
    b[3] == 0x47;

bool _isJpeg(List<int> b) =>
    b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

/// 实测有 2 个 SVG（文本 XML），放宽为"XML 头或 `<svg`"。
bool _isSvg(List<int> b) {
  final head = b.take(256).toList();
  final text = String.fromCharCodes(head.where((c) => c < 128));
  final trimmed = text.trimLeft();
  return trimmed.startsWith('<?xml') || trimmed.startsWith('<svg');
}

void main() {
  test('files/ 裸图片共 73 个，且每个都对得上 attachment.json 的 file_id', () {
    if (_skipReason != null) {
      markTestSkipped(_skipReason!);
      return;
    }
    final allFiles = <String>[];
    for (final kind in ['doc', 'slides']) {
      final dir = Directory('${_root.path}/$kind');
      if (!dir.existsSync()) continue;
      for (final sample in dir.listSync().whereType<Directory>()) {
        final filesDir = Directory('${sample.path}/files');
        if (!filesDir.existsSync()) continue;
        allFiles.addAll(
          filesDir.listSync().whereType<File>().map((f) => f.path),
        );
      }
    }
    expect(allFiles, hasLength(73), reason: '官方附件样本应为 73 个');

    var png = 0;
    var jpeg = 0;
    var svg = 0;
    var attachmentEntries = 0;
    var resolved = 0;

    for (final kind in ['doc', 'slides']) {
      final dir = Directory('${_root.path}/$kind');
      if (!dir.existsSync()) continue;
      for (final sample in dir.listSync().whereType<Directory>()) {
        final attachment = File('${sample.path}/attachment.json');
        if (!attachment.existsSync()) continue;
        final entries = (jsonDecode(attachment.readAsStringSync()) as List)
            .cast<Map<String, dynamic>>();
        for (final entry in entries) {
          attachmentEntries++;
          final fileId = entry['file_id'] as String;
          final file = File('${sample.path}/files/$fileId');
          expect(file.existsSync(), isTrue, reason: '$fileId 无对应字节');
          final bytes = file.readAsBytesSync();
          expect(bytes, isNotEmpty);
          expect(
            bytes.length,
            entry['size'],
            reason: '$fileId 大小与 attachment.json 不一致',
          );
          resolved++;

          final ext = entry['ext'] as String?;
          if (_isPng(bytes)) {
            png++;
            expect(ext, 'png', reason: '$fileId: magic 是 PNG 但 ext=$ext');
          } else if (_isJpeg(bytes)) {
            jpeg++;
            expect(
              ext,
              anyOf('jpg', 'jpeg'),
              reason: '$fileId: magic 是 JPEG 但 ext=$ext',
            );
          } else if (_isSvg(bytes)) {
            // 研究文档 §5.4 说"裸 PNG/JPEG"，实测 73 个里有 2 个是 **SVG**
            //（如 slides/technology 的 img_dot_dark.svg）—— 如实修正，不硬套结论。
            svg++;
            expect(ext, 'svg', reason: '$fileId: 是 SVG 但 ext=$ext');
          } else {
            fail('$fileId: 既不是 PNG/JPEG 也不是 SVG');
          }
        }
      }
    }
    expect(attachmentEntries, 73);
    expect(resolved, 73);
    expect(png + jpeg + svg, 73);
    expect(svg, 2, reason: '实测 2 个 SVG（修正 §5.4 的"全是 PNG/JPEG"）');
    // ignore: avoid_print
    print(
      'ATTACH_SAMPLES files=${allFiles.length} entries=$attachmentEntries '
      'resolved=$resolved png=$png jpeg=$jpeg svg=$svg',
    );
  }, skip: _skipReason ?? false);

  test('模型里的图片引用能取到字节（doc 的 picture / slides 的 image）', () {
    if (_skipReason != null) {
      markTestSkipped(_skipReason!);
      return;
    }
    var refs = 0;
    var withFileId = 0;
    var resolved = 0;
    final unresolved = <String>[];

    void check(String kind, String samplePath, Object? modelRefs) {
      // modelRefs: List<PmImageRef>
      for (final ref in modelRefs as List<dynamic>) {
        refs++;
        final fileId = ref.fileId as String?;
        if (fileId == null) continue;
        withFileId++;
        final file = File('$samplePath/files/$fileId');
        if (!file.existsSync()) {
          unresolved.add('$kind/$fileId');
          continue;
        }
        expect(file.readAsBytesSync(), isNotEmpty);
        resolved++;
      }
    }

    for (final sample in Directory(
      '${_root.path}/doc',
    ).listSync().whereType<Directory>()) {
      final raw =
          (jsonDecode(File('${sample.path}/text.json').readAsStringSync())
                  as Map)
              .cast<String, Object?>();
      final doc = OfficeNativeReader.parseSections(raw);
      check('doc', sample.path, doc.document!.images);
    }
    for (final sample in Directory(
      '${_root.path}/slides',
    ).listSync().whereType<Directory>()) {
      final raw =
          (jsonDecode(File('${sample.path}/text.json').readAsStringSync())
                  as Map)
              .cast<String, Object?>();
      final doc = OfficeNativeReader.parseSections(raw);
      final images = [
        // 母版/版式里的图片单独抽（本批不做母版继承，只做引用对账）。
        ...doc.presentation!.master.images,
        for (final s in doc.presentation!.slides) ...s.images,
      ];
      check('slides', sample.path, images);
    }

    // 样本里的引用都能落到字节；有 ref 但 model 抽不到 file_id 的才是问题。
    expect(unresolved, isEmpty, reason: '有 file_id 但取不到字节：$unresolved');
    expect(withFileId, greaterThan(0), reason: '至少应有若干图片引用');
    // ignore: avoid_print
    print('IMAGE_REFS total=$refs withFileId=$withFileId resolved=$resolved');
  }, skip: _skipReason ?? false);
}
