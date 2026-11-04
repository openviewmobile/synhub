// Office L2：**「下载为 …」** 与 **「转换为 Office 文档」** 两个动作的公共实现。
//
// 两个入口共用（Drive 列表的行菜单、文件预览页的溢出菜单），所以放在这里而不是页面里。
//
// 官方调用点（NAS 上实际装的 Office 3.8.0-22711 的 `ui/dist/ui.doc.js` /
// `ui.sheet.js`，逐字对齐）：
//   * 下载/导出：`downloadOffice` → `exportNode` →
//     `SYNO.Office.Export/download {path:'id:<file_id>', password, format, ver}`；
//     **写入批次真机只验过 `{path:"id:<file_id>", format:"xlsx"}`**（→ `200` +
//     OOXML ZIP；`link_id`→`57350`、`object_id`→`57351`、`Excel.save`→`57383`），
//     所以 `format` 发的是**目标扩展名**（[officeExportServerFormat]），文件名按
//     官方 `EXPORT_EXTENSION` 换后缀；服务端的 `Content-Disposition` basename
//     **不带扩展名**，扩展名由客户端自己补（见 [officeExportFileName]）；
//   * 转换：`checkImportOffice`（`Import/check {files:[{path}]}`，只挑 `57373` 弹口令窗）
//     → `convertOffice`（`Import/convert {files, conflict_action:'autorename',
//     to_parent_folder}`）。转换结果官方**不读回包**，只刷新列表。
//
// ⚠️ `Office.Export/download` 只对 **Office 原生文档**（.odoc/.osheet/.oslides）有效：
// 对直接上传的 .docx 会回 `57350/57351/1000`（真机实测）——那种文件必须先"转换"。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../dsm/webapi.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../../data/office_api.dart';
import '../../core/i18n/l10n.dart';
import '../../core/system_open.dart';
import 'file_providers.dart';
import 'office_providers.dart';
import '../../core/user_facing_error.dart';

/// 「下载为 <格式>」：`Office.Export/download` → 取字节 → 落盘（可选交给系统打开）。
///
/// 返回落盘后的文件名（给调用方做文案），失败抛异常（调用方翻译成文案）。
Future<String> downloadOfficeAs(
  WidgetRef ref, {
  required String fileId,
  required String name,
  required OfficeExportFormat format,
  bool openAfter = false,
  AppText? t,
}) async {
  final text = t ?? currentText();
  final office = ref.read(officeApiProvider);
  if (office == null) {
    throw StateError(text.fileOfficeNoService);
  }
  // await 之前把要用的 provider 一次性取好：widget 卸载后 `ref` 就不能再碰了
  // （riverpod 3 的 `_assertNotDisposed` 会抛 StateError）。异步续体只依赖这些
  // 局部引用 —— 否则导出/落盘这类长 await 结束时页面若已卸载，续体就炸在外面
  // （无人 await 的 Future → 错误逃逸，可能挂到当时正在跑的其它用例上）。
  final downloadDir = ref.read(officeDownloadDirProvider);
  final systemOpen = ref.read(systemOpenProvider);
  final bytes = await office.exportBytes(
    fileId: fileId,
    // 服务端认的是目标扩展名（真机唯一验过的形状是 format:"xlsx"）
    format: officeExportServerFormat(name, format.code),
    fileName: name,
  );
  final dir = await downloadDir();
  final fileName = officeExportFileName(name, format.code);
  final file = File('${dir.path}/$fileName');
  await file.writeAsBytes(bytes);
  officeProbeBytes(fileName, bytes);
  if (openAfter) await systemOpen(file.path);
  return fileName;
}

/// 真机验证探针开关。
///
/// 只在 `flutter build apk --dart-define=OFFICE_PROBE=true` 的包里打印
/// "导出了多少字节、头几个字节是什么"（`%PDF-` / `PK`）。**正常构建里整段被
/// 编译掉**（`bool.fromEnvironment` 是编译期常量，release AOT 会摇掉死分支），
/// 所以正式包不会打印任何导出内容。见 `docs/device-verification.md`。
const bool kOfficeProbe = bool.fromEnvironment('OFFICE_PROBE');

/// 真机验证用的结构检查（**只在 `--dart-define=OFFICE_PROBE=true` 构建里输出**）：
/// 原始字节数 + magic 头 + 压缩包里的第一个条目名（`mimetype…` = ODF、
/// `[Content_Types].xml` = OOXML、`%PDF` = PDF）。不交给任何系统应用打开。
void officeProbeBytes(String fileName, List<int> bytes) {
  if (!kOfficeProbe) return;
  String asc(Iterable<int> it) =>
      String.fromCharCodes(it.map((b) => b >= 32 && b < 127 ? b : 46));
  // ignore: avoid_print
  print(
    'OFFICE_PROBE export file=$fileName bytes=${bytes.length} '
    'head=${asc(bytes.take(8))} slug=${asc(bytes.take(160))}',
  );
}

/// 落盘目录（`<应用文档>/downloads`）。做成 provider 是为了**测试**：
/// 纯 Dart/widget 测试里没有 `path_provider` 通道，覆盖成临时目录即可。
final officeDownloadDirProvider = Provider<Future<Directory> Function()>(
  (ref) => fileDownloadDirectory,
);

/// 「转换为 Office 文档」：`Import/check`（必要时问口令）→ `Import/convert`。
///
/// 返回**转换后的文件名**（服务端 `autorename` 可能加 ` (2)`，这里给的是预期名；
/// 调用方刷新列表后就看到真身了）。需要口令/不支持时抛 [OfficeConvertException]。
Future<String> convertToOfficeDocument(
  WidgetRef ref, {
  required String fileId,
  required String name,
  String? parentId,
  String password = '',
  AppText? t,
}) async {
  final text = t ?? currentText();
  final office = ref.read(officeApiProvider);
  if (office == null) {
    throw OfficeConvertException(text.fileOfficeNoService);
  }
  // 1) check：空 errors = 能转；57373 = 要口令；其它码 = 这个文件转不了
  final issues = await office.importCheck(fileId: fileId, password: password);
  final needsPassword = issues.any((i) => i.needsPassword);
  if (needsPassword && password.isEmpty) {
    throw OfficeConvertException(
      text.fileOfficeNeedsPassword,
      needsPassword: true,
    );
  }
  final blockers = issues.where((i) => !i.needsPassword).toList();
  if (blockers.isNotEmpty) {
    throw OfficeConvertException(
      text.fileOfficeConvertUnsupported(blockers.first.code),
    );
  }
  // 2) convert：官方固定 `conflict_action:'autorename'`，目标文件夹由调用方给
  await office.importConvert(
    fileId: fileId,
    toParentFolderId: parentId,
    password: password,
  );
  return officeConvertedFileName(name);
}

/// Office 私有错误码的人话（真机/官方出处见 `lib/src/data/office_api.dart` 顶部）。
///
/// * `57373` = 需要文档口令（官方 `checkImportOfficeDone` 只挑这个码弹口令窗）；
/// * `57350` / `57351` / `1000` = 传了服务端不认的那种 id（或这份文件本来不是
///   Office 原生文档 —— 真机对直接上传的 .docx 就是这三个码）；
/// * 其它码退回 [describeFileError]（DSM 通用码的人话）。
String describeOfficeError(Object error, [AppText? t]) {
  final text = t ?? currentText();
  if (error is DsmApiException) {
    return switch (error.code) {
      57373 => text.fileOfficeNeedsPassword,
      57350 || 57351 || 1000 => text.fileOfficeUnrecognized,
      _ => describeFileError(error),
    };
  }
  return userFacingError(error);
}

/// 转换失败（带"是不是缺口令"的标记，页面据此决定弹不弹口令框）。
class OfficeConvertException implements Exception {
  OfficeConvertException(this.message, {this.needsPassword = false});

  final String message;
  final bool needsPassword;

  @override
  String toString() => message;
}

/// 文档口令输入框（官方是 `SYNO.SDS.Office.PasswordWindow`）。
/// 返回 null = 用户取消。
Future<String?> promptOfficePassword(BuildContext context, {String? name}) {
  final controller = TextEditingController();
  final t = context.t;
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(t.fileOfficePasswordTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name == null || name.isEmpty
                ? t.fileOfficePasswordBody
                : t.fileOfficePasswordBodyNamed(name),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('office-password-field'),
            controller: controller,
            autofocus: true,
            obscureText: true,
            decoration: InputDecoration(labelText: t.fileOfficePasswordField),
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(t.actionCancel),
        ),
        FilledButton(
          key: const Key('office-password-ok'),
          onPressed: () => Navigator.of(ctx).pop(controller.text),
          child: Text(t.actionOk),
        ),
      ],
    ),
  );
}
