// 「打开一个 Drive 节点」的统一入口（P0-3 / P0-6 / P0-11 复用）。
//
// 为什么单独拎出来：团队文件夹 / 共享列表 / 搜索 / 最近这几处都要"点一行打开
// 文件"，而 P0-11 要求**打开 Office 原生文档前先探加密**。把这段逻辑收在一处，
// 避免每个列表各写一遍（写歪一处就会漏掉加密探测）。
//
// 打开流程（与官方一致的顺序）：
//   1. 加密探测（只对 .odoc/.osheet/.oslides；`SYNO.Office.Node.Encrypt:check`）
//      —— 命中就弹官方那句提示并**不打开**（我们拿不到解密凭据，见
//      `drive_encrypt_gate.dart` 的说明）；
//   2. Office 原生文档优先用 File Station 的真实路径取原生字节（Drive 直链会把
//      它转码成 OOXML，内容与扩展名不符）；
//   3. 其余交给统一预览页 `FilePreviewPage`。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dto/drive_entry_dto.dart';
import '../../data/dto/file_entry_dto.dart';
import '../../data/office_api.dart' show isOfficeNativeName;
import '../files/drive_browse_view.dart' show driveEntryAsFile;
import '../files/drive_providers.dart';
import '../files/file_preview_page.dart';
import '../files/file_providers.dart' show fileApiProvider;
import '../files/office_viewer_page.dart' show officeNativeFileStationPath;
import '../files/office_viewer_page.dart' show officeDrivePathForFileStationPath;
import '../office/office_doc_page.dart' show OfficeDocPage, OfficeDocRequest;
import '../office/office_sheet_page.dart'
    show OfficeSheetPage, OfficeSheetRequest;
import '../office/office_slides_page.dart'
    show OfficeSlidesPage, OfficeSlidesRequest;
import 'drive_encrypt_gate.dart';
import 'drive_wave2_providers.dart';

/// ★★★ 用户 2026-09-25 裁决：**NAS「文件」打开 Office 三种格式要走「我的 Drive」的
/// 同一个阅读器**（原话：「同一份文档在 nas files 里和 my drive 里打开不一样？
/// 这块我觉得需要保持统一，nas files 如果打开 office 三种格式的文档要调用 my drive
/// 里的阅读器」）。
///
/// 真机证据（LGE-AN10，`Dynamic.oslides`，同一份文件）：
/// * 从「我的 Drive」打开 → `OfficeSlidesPage`：渐变母版、白字标题、**缩略图 1/15**；
/// * 从「NAS files」打开（修复前）→ `OfficeNativeViewer` 的**降级**渲染：白底黑字小标题。
/// 差别不在数据，而在**路由**：Drive 侧走 [driveOpenEntry]（三种格式各有专页），
/// FileStation 侧直接进统一预览页 ⇒ 落到只读原生降级视图。
///
/// 所以这里把「文件」侧的打开也接到 [driveOpenEntry] 上：
///   1. 只有 Office **原生**三种扩展名才分流（其余一律走原来的 [openFilePreview]）；
///   2. 只有能按**已取证的映射**得到 Drive 路径（`/home/Drive/…` → `/mydrive/…`）
///      才分流；解析失败（非个人空间、无权限、网络）**静默回落**到原来的
///      原生只读预览 —— 绝不因为"想统一"而让文件打不开。
Future<void> openFileUnified(
  BuildContext context,
  WidgetRef ref,
  FileEntryDto entry, {
  List<FileEntryDto> siblings = const [],
  String? bytesUrl,
  String? downloadUrl,
  String? officeLinkId,
  String? officeDrivePath,
  String? officeNativeBytesUrl,
}) async {
  void fallback() {
    openFilePreview(
      context,
      entry,
      siblings: siblings,
      bytesUrl: bytesUrl,
      downloadUrl: downloadUrl,
      officeLinkId: officeLinkId,
      officeDrivePath: officeDrivePath,
      officeNativeBytesUrl: officeNativeBytesUrl,
    );
  }

  if (!isOfficeNativeName(entry.name)) {
    fallback();
    return;
  }
  final drivePath = officeDrivePathForFileStationPath(entry.path);
  final api = ref.read(driveApiProvider);
  if (drivePath == null || api == null) {
    fallback();
    return;
  }
  DriveEntryDto dto;
  try {
    // 与「我的 Drive」同一个身份解析（`Files:get {path:/mydrive/…}`）
    dto = await api.get(path: drivePath);
  } catch (_) {
    if (context.mounted) fallback();
    return;
  }
  if (!context.mounted) return;
  await driveOpenEntry(context, ref, dto);
}

/// 打开一个 Drive 节点（文件）。目录请走 `DriveFolderPage`。
Future<void> driveOpenEntry(
  BuildContext context,
  WidgetRef ref,
  DriveEntryDto entry,
) async {
  final api = ref.read(driveApiProvider);
  if (api == null) return;

  // 1) 加密 Office 文档：**弹密码框并校验**（第 66 轮 D58 收口）。
  //
  // ★ 这里从"只提示"改成"要密码"，是因为 `Snapshot/get` 本来就收
  //   `password`（官方 `setAsGet(linkId, password)`）—— 以前那条通道
  //   没接起来，用户输对密码也打不开。现在把校验过的密码一路带到
  //   office 页面（`Office.*Request.password` → `snapshotGet(password:)`）。
  //
  // 返回 `null` = 未加密 或 用户放弃；两种情况都**继续走**
  // （未加密本来就走得通；放弃时下游会照旧报错，不会静默出错）。
  final officePassword = await drivePromptOfficePassword(context, ref, entry);
  if (!context.mounted) return;

  // 1b) wave2：访问事件上报（`Files:access` v1，`event_type` + `path`）。
  //     官方语义：通用查看器**打开/预览**条目时报 `event_type:"preview"`
  //     （`drive/synodrive.js` 的 `accessFile({params:{path:"id:"+file_id,
  //     event_type:"preview"}})`；描述符 `access_file` v10 在
  //     `synodrive_common.js`）。真机契约发 v1 + `{event_type,path}`。
  //     **fire-and-forget**：绝不阻塞打开，失败静默。
  unawaited(reportDriveAccess(ref, entry));

  // 2) Office 原生文档走 File Station 真实路径
  final nativePath = isOfficeNativeName(entry.name)
      ? officeNativeFileStationPath(
          dsmPath: entry.dsmPath,
          displayPath: entry.displayPath,
        )
      : null;
  final nativeUrl = nativePath == null
      ? null
      : ref.read(fileApiProvider)?.downloadUrl([nativePath]);
  final downloadUrl = api.downloadUrl(fileId: entry.fileId);

  Future<void> openNativePreview() {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => FilePreviewPage(
          entry: driveEntryAsFile(entry),
          bytesUrl: downloadUrl,
          downloadUrl: downloadUrl,
          officeLinkId: entry.permanentLink,
          // Snapshot 通道取不到 permanent_link 时按 `/mydrive/...` 现取
          officeDrivePath: entry.displayPath,
          officeNativeBytesUrl: nativeUrl,
        ),
      ),
    );
  }

  // 2b) `.odoc`：C′ 编辑器 UI 的只读页（schema 驱动渲染 + 门控 + 会话生命周期）。
  //     只在这一种扩展名上分流；读失败时页面里保留回退到既有原生只读预览的入口。
  if (entry.extension == 'odoc') {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => OfficeDocPage(
          request: OfficeDocRequest(
            password: officePassword ?? '',
            fileId: entry.fileId,
            name: entry.name,
            permanentLink: entry.permanentLink,
            drivePath: entry.displayPath,
          ),
          onFallbackToNativePreview: openNativePreview,
        ),
      ),
    );
    return;
  }

  // 2c) `.osheet`：C′ 表格批 1 的只读页（证据驱动网格 + 门控 + init 会话生命周期）。
  //     与 `.odoc` 一样只在扩展名上分流；**加密探测仍在最前面**（L38），
  //     所以加密的 `.osheet` 根本走不到这里。
  if (entry.extension == 'osheet') {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => OfficeSheetPage(
          request: OfficeSheetRequest(
            password: officePassword ?? '',
            fileId: entry.fileId,
            name: entry.name,
            permanentLink: entry.permanentLink,
            drivePath: entry.displayPath,
          ),
          onFallbackToNativePreview: openNativePreview,
        ),
      ),
    );
    return;
  }

  // 2d) `.oslides`：C′ 演示文稿批 1 的只读页（证据驱动幻灯片 + 门控 + init 会话
  //     生命周期）。与 `.odoc`/`.osheet` 一样只在扩展名上分流；**加密探测仍在
  //     最前面**（L39），所以加密的 `.oslides` 根本走不到这里。
  if (entry.extension == 'oslides') {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => OfficeSlidesPage(
          request: OfficeSlidesRequest(
            password: officePassword ?? '',
            fileId: entry.fileId,
            name: entry.name,
            permanentLink: entry.permanentLink,
            drivePath: entry.displayPath,
          ),
          onFallbackToNativePreview: openNativePreview,
        ),
      ),
    );
    return;
  }

  // 3) 统一预览页
  await openNativePreview();
}
