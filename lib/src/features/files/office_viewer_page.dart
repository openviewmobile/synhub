// Office 原生文档（`.odoc` / `.osheet` / `.oslides`）的**只读**内嵌查看器。
//
// 上游（已定稿，本批**只调用不修改**）：`lib/src/data/office_native/**`
//   * 单一入口 `OfficeNativeDocument.parse(bytes)`（`office_native_reader.dart`）；
//   * 三格式模型 `osheet_model.dart` / `odoc_model.dart` / `oslides_model.dart`
//     + `prosemirror_model.dart`（ProseMirror 结构/文本抽取）。
//
// 本批**只做只读**（编辑/写回是后续独立的"自研写"阶段，这里**不做**）：
//   * `.osheet`：表格网格（行/列、表头与基础样式区分、合并单元格**如实标注**）；
//   * `.odoc`：块级渲染（标题层级/段落/列表/表格/**图片引用卡**）；
//   * `.oslides`：**16:9 幻灯片画布**（真实 EMU 坐标 + 母版/版式继承 + 图片/
//     文本样式，见 `office_slides_deck_view.dart`）；拿不到 PPTX 字节时才退化成
//     同比例的文本画布，并给一行用户语言的说明。
//   * `.odoc` 不再有顶部标识；`.osheet` 的标识由表格批次负责。
//
// 取字节走**既有**的下载链路（`fileBytesProvider`，见 `file_providers.dart`），
// 不新造通道。对来自 Drive 的原生文档，调用方会优先传
// [OfficeNativeViewer.bytesUrl] = **FileStation 真实路径**的下载直链：真机批次
// 证实 Drive 自己的 `Files/download` 会把 Office 原生文档**转码成 OOXML**
// （内容与扩展名不符），而 File Station 下载 `home/Drive/...` 能拿到原生字节。
// 拿不到真实路径时退化为 Drive 直链：此时若解析到的是 OOXML/PDF 包，给出
// **专属的"服务端返回的是转换后的文件"**提示（绝不落进泛化的"解析失败"）。
//
// 已知边界（如实说明，不假装）：
//   * 内嵌图片字节解不开（阶段 2b）→ 只渲染 `PmImageRef` **引用占位卡**；
//   * `.osheet` 的样式槽位语义、`mergeCells` 四元组语义在解析层标注为**推测**，
//     本查看器只据此做"表头/有无样式"的基本区分与合并标注，不做真实字体/颜色还原；
//   * `.oslides` 的母版/版式继承与坐标还原**已经做在 OOXML 路径**上
//     （`lib/src/data/office_native/oslides_ooxml.dart`），OFile 模型本身仍不含
//     几何 —— 所以拿不到 PPTX 字节时只能退化成文本画布；
//   * 不做动画 / 切换效果 / 图表与 SmartArt（只给可读的"暂不支持"占位卡）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/services/service_registry.dart'
    show AvailabilityState, classifyErrorCode;
import '../../core/theme/app_tokens.dart';
import '../../data/dto/file_entry_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../../data/office_api.dart'
    show
        OfficeSnapshotUnavailableException,
        exportFileName,
        isOfficeNativeName,
        kOfficeSnapshotApi,
        officeSectionsFromSnapshot;
import '../../data/office_native/odoc_model.dart';
import '../../data/office_native/office_native_reader.dart';
import '../../data/office_native/ofile.dart';
import '../../data/office_native/osheet_model.dart';
import '../../data/office_native/oslides_model.dart';
import '../../data/office_native/oslides_ooxml.dart';
import '../../data/office_native/prosemirror_model.dart';
import '../../dsm/webapi.dart' show DsmApiException;
import '../drive/drive_c1_text.dart';
import '../office/office_sheet_view.dart';
import 'drive_providers.dart' show driveApiProvider;
import 'file_providers.dart' show FileBytesRequest, fileBytesProvider;
import '../office/office_slides_deck_view.dart';
import 'office_providers.dart' show officeApiProvider;
import '../../core/user_facing_error.dart';
import '../../core/theme/app_theme.dart';

/// 超过这个大小就不内嵌解析（先问一句，别把几百 MB 读进内存）。
const int kOfficeNativeMaxInlineBytes = 40 * 1024 * 1024;

/// 网格最多渲染的行 / 列（稀疏表按"有数据的范围"渲染，超出就截断并说明）。
const int kOSheetMaxRenderRows = 500;
const int kOSheetMaxRenderCols = 100;

/// 嗅探"这不是 OFile 原生字节，而是一个包"。
///
/// 真机缺陷证据：Drive 的 `Files/download` 对 `.osheet` 回的是 **xlsx（OOXML）**
/// 字节，文件名叫 `*.osheet`。这里只做**只读识别**，不试图解释包内容。
/// 返回人类可读的包类型，非包返回 `null`。
String? sniffOfficePackage(List<int> bytes) {
  if (bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4B &&
      bytes[2] == 0x03 &&
      bytes[3] == 0x04) {
    return 'OOXML/zip';
  }
  if (bytes.length >= 4 &&
      bytes[0] == 0x25 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x44 &&
      bytes[3] == 0x46) {
    return 'PDF';
  }
  if (bytes.length >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B) {
    return 'gzip';
  }
  return null;
}

/// Drive 条目 → FileStation 真实路径（Office 原生文档取**原生字节**的钥匙）。
///
/// 证据：`DriveEntryDto.dsmPath` 的文档注释（`dsm_path` 是同一份文件在 DSM 文件
/// 系统里的路径，个人空间 `/mydrive/x` ↔ `/home/Drive/x`）。真机批次证实
/// File Station 下载这条真实路径能拿到原生字节，而 Drive 自己的下载会转码。
///
/// 无法确定时返回 `null`（**不猜**，尤其团队文件夹 / 共享目录的映射未取证）。
String? officeNativeFileStationPath({
  required String dsmPath,
  required String displayPath,
}) {
  if (dsmPath.isNotEmpty) return dsmPath;
  const myDrive = '/mydrive';
  if (displayPath == myDrive) return '/home/Drive';
  if (displayPath.startsWith('$myDrive/')) {
    return '/home/Drive/${displayPath.substring(myDrive.length + 1)}';
  }
  return null;
}

/// FileStation 真实路径 → Drive 视角路径（`/mydrive/...`），无法确定时 `null`。
///
/// 这一条是**用户 2026-09-25 裁决**的落点：「同一份文档在 nas files 里和 my drive 里
/// 打开不一样 ⇒ 必须统一，nas files 打开 office 三种格式要调用 my drive 里的阅读器」。
///
/// 为什么映射一下就能统一：阅读器本来就是同一套（[officeNativeReadProvider] 三跳），
/// 差别只在**输入**——`Snapshot:get` 那一跳（My Drive 用的高保真通道）要有 `link_id`，
/// 而它只能由 Drive 视角的路径换出来（[DriveApi.permanentLinkForPath]）。
/// 从「文件」打开时只有 DSM 路径（`/home/Drive/x`），拿到这里映射成 `/mydrive/x`
/// 就能走**同一跳**，于是三种格式在两边渲染一致。
///
/// 只映射**个人空间**这一种已取证的对应关系（`dsm_path` 注释 + 真机批次）；
/// 团队文件夹/共享目录的对应关系未取证 ⇒ 返回 `null`，**不猜**（回落原有字节跳）。
String? officeDrivePathForFileStationPath(String dsmPath) {
  const fsRoot = '/home/Drive';
  const driveRoot = '/mydrive';
  final p = dsmPath.trim();
  if (p.isEmpty) return null;
  if (p == fsRoot) return driveRoot;
  if (p.startsWith('$fsRoot/')) {
    return '$driveRoot/${p.substring(fsRoot.length + 1)}';
  }
  return null;
}

/// 一次「下载 Office 文档」的决策结果（**内容与文件名必须一致**）。
class OfficeDownloadPlan {
  const OfficeDownloadPlan({
    required this.url,
    required this.saveName,
    required this.transcoded,
  });

  /// 实际取字节用的直链（原生字节优先）。
  final String url;

  /// 落盘文件名。
  final String saveName;

  /// 是否只能拿到**转码产物**（此时 [saveName] 是真实扩展名，界面要提示已转换）。
  final bool transcoded;
}

/// 决定 Office 文档"下载"走哪条链路、存成什么名字。
///
/// 真机缺陷（设备批次）：Drive 的 `Files/download` 会把 `.osheet` 转成 xlsx 字节
/// 却仍叫 `.osheet`。因此：
///   * 有 File Station 真实路径的**原生字节**直链 → 用原生直链，**保留原名**；
///   * 只有 Drive 直链 → 产物是 OOXML，**文件名改成真实扩展名**（`exportFileName`：
///     odoc→docx / osheet→xlsx / oslides→pptx）并置 [OfficeDownloadPlan.transcoded]，
///     由界面明确提示"已转换为 Office 格式"。
///
/// 非原生 Office 文件（xlsx/docx/…）不受影响，一律原名。
OfficeDownloadPlan planOfficeDownload({
  required String name,
  required String driveUrl,
  String? nativeUrl,
}) {
  final isNative = isOfficeNativeName(name);
  final useNative = isNative && nativeUrl != null && nativeUrl.isNotEmpty;
  return OfficeDownloadPlan(
    url: useNative ? nativeUrl : driveUrl,
    saveName: (isNative && !useNative) ? exportFileName(name) : name,
    transcoded: isNative && !useNative,
  );
}

/// 带格式的取字节请求（`FileBytesRequest` 的 path 对 Drive 是 `drive:<id>`，
/// 判不出扩展名，所以格式由调用方按文件名显式带上）。
@immutable
class OfficeNativeBytesRequest {
  const OfficeNativeBytesRequest({required this.bytes, required this.format});

  final FileBytesRequest bytes;
  final OfficeNativeFormat format;

  @override
  bool operator ==(Object other) =>
      other is OfficeNativeBytesRequest &&
      other.bytes == bytes &&
      other.format == format;

  @override
  int get hashCode => Object.hash(bytes, format);
}

/// 字节不是一个 OFile，而是被转码后的包（真机缺陷，见 [sniffOfficePackage]）。
class OfficeNativeTranscodedBytesException implements Exception {
  OfficeNativeTranscodedBytesException(this.packageKind);

  /// `OOXML/zip` / `PDF` / `gzip`。
  final String packageKind;

  @override
  String toString() =>
      'OfficeNativeTranscodedBytesException(package=$packageKind): '
      '字节不是 Synology Office 原生 OFile，而是转换后的包';
}

/// 取字节 + 解析成模型（一次，`autoDispose` 缓存；失败可 `invalidate` 重试）。
///
/// **关闭自动重试**：解析失败是确定性的（密码/转码包/损坏），riverpod 3 的默认
/// 重试会把它一直挂在 `AsyncLoading(retrying: true)` 上——界面就成了永远转圈，
/// 恰好是"不要白屏/要明确错误"的反面。重试交给用户点"重试"（`invalidate`）。
final officeNativeDocumentProvider = FutureProvider.autoDispose
    .family<OfficeNativeDocument, OfficeNativeBytesRequest>((ref, req) async {
      final bytes = await ref.watch(fileBytesProvider(req.bytes).future);
      // 先判"转码包"：Drive 下载会回 OOXML/PDF，这是真机缺陷，必须给专属文案。
      final kind = sniffOfficePackage(bytes);
      if (kind != null) throw OfficeNativeTranscodedBytesException(kind);
      return OfficeNativeDocument.parse(bytes, format: req.format);
    }, retry: (_, _) => null);

// ------------------------------------------------------- 三跳只读优先级（本批）

/// 一条只读通道，**按优先级从高到低**尝试（见 [officeReadHopOrder]）。
enum OfficeReadHop {
  /// ① `SYNO.Office.Snapshot:get` v4：原生内容树，**不需要先 convert**。
  snapshot,

  /// ② File Station 真实路径（`/home/Drive/...`）下载的**原生字节**。
  fileStationNative,

  /// ③ Drive 的 `Files/download`（真机会把它**转码**成 OOXML/PDF → 改名 + 提示）。
  driveBytes,

  /// 无现成直链时按 `entry.path` 走既有链路（FileStation 或 Drive，由 path 决定）。
  byPath,
}

/// 这次连接要用哪些跳、什么顺序（纯函数，便于单测断言"优先级不混用"）。
///
/// * [snapshotUsable]：能力位在 **且** 能拿到 `link_id`（Drive 的 `permanent_link`）；
/// * [hasNativeUrl]：File Station 真人路径的原生字节直链；
/// * [hasDriveUrl]：Drive 直链（会被转码）。
///
/// 两条直链都没有时才退到 [OfficeReadHop.byPath]（保持原有 FileStation 预览行为）。
List<OfficeReadHop> officeReadHopOrder({
  required bool snapshotUsable,
  required bool hasNativeUrl,
  required bool hasDriveUrl,
}) => [
  if (snapshotUsable) OfficeReadHop.snapshot,
  if (hasNativeUrl) OfficeReadHop.fileStationNative,
  if (hasDriveUrl) OfficeReadHop.driveBytes,
  if (!hasNativeUrl && !hasDriveUrl) OfficeReadHop.byPath,
];

/// 一次只读读取的全部来源（按优先级由 [officeReadHopOrder] 排）。
@immutable
class OfficeNativeReadRequest {
  const OfficeNativeReadRequest({
    required this.entryPath,
    required this.format,
    this.linkId = '',
    this.drivePath,
    this.nativeBytesUrl,
    this.driveBytesUrl,
    this.snapshotApiPresent = true,
  });

  /// 兜底取字节用的 path（Drive 条目是 `drive:<file_id>`）。
  final String entryPath;

  final OfficeNativeFormat format;

  /// Drive 的 `permanent_link` = Office 的 `link_id`（调用方已知时直接给）。
  final String linkId;

  /// Drive 视角的展示路径（`/mydrive/...`）：[linkId] 为空时按真机取法现取一次
  /// （`SynologyDrive.Files:get {path:'/mydrive/<name>'}` → `permanent_link`）。
  final String? drivePath;

  /// File Station 真实路径的**原生字节**直链（`/home/Drive/...`）。
  final String? nativeBytesUrl;

  /// Drive 直链（真机会转码，第三跳）。
  final String? driveBytesUrl;

  /// 能力位 `SYNO.Office.Snapshot` 是否存在（缺位 → 第一跳跳过）。
  final bool snapshotApiPresent;

  bool get hasNativeUrl =>
      nativeBytesUrl != null && nativeBytesUrl!.isNotEmpty;

  bool get hasDriveUrl => driveBytesUrl != null && driveBytesUrl!.isNotEmpty;

  bool get snapshotUsable =>
      snapshotApiPresent &&
      (linkId.trim().isNotEmpty ||
          (drivePath != null && drivePath!.startsWith(kDriveRootForRead)));

  @override
  bool operator ==(Object other) =>
      other is OfficeNativeReadRequest &&
      other.entryPath == entryPath &&
      other.format == format &&
      other.linkId == linkId &&
      other.drivePath == drivePath &&
      other.nativeBytesUrl == nativeBytesUrl &&
      other.driveBytesUrl == driveBytesUrl &&
      other.snapshotApiPresent == snapshotApiPresent;

  @override
  int get hashCode => Object.hash(
    entryPath,
    format,
    linkId,
    drivePath,
    nativeBytesUrl,
    driveBytesUrl,
    snapshotApiPresent,
  );
}

/// Drive 视角的根（**只给 Drive API 用**；File Station 视角是 `/home/Drive`）。
const String kDriveRootForRead = '/mydrive';

/// 三跳只读读取：`Snapshot:get` → File Station 原生字节 → Drive（转码）。
///
/// **回落不弹错误面板**：任何一跳失败（缺能力位 / `103` / `105` / `119` /
/// 域错误 / 内容树形态对不上 / 字节被转码）都静默尝试下一跳；只有**全部失败**
/// 才把最后一跳的错误抛给界面（此时才可能看到错误面板）。
final officeNativeReadProvider = FutureProvider.autoDispose
    .family<OfficeNativeDocument, OfficeNativeReadRequest>((ref, req) async {
      final hops = officeReadHopOrder(
        snapshotUsable: req.snapshotUsable,
        hasNativeUrl: req.hasNativeUrl,
        hasDriveUrl: req.hasDriveUrl,
      );
      Object? lastError;
      StackTrace? lastTrace;
      for (final hop in hops) {
        try {
          return await _readOfficeHop(ref, req, hop);
        } catch (e, st) {
          lastError = e;
          lastTrace = st;
          // 静默回落：不在这里弹面板（只有循环走完才抛）。
        }
      }
      if (lastError != null) {
        Error.throwWithStackTrace(lastError, lastTrace ?? StackTrace.current);
      }
      throw StateError('Office 只读通道不可用：没有可尝试的来源');
    }, retry: (_, _) => null);

/// 执行一跳。
Future<OfficeNativeDocument> _readOfficeHop(
  Ref ref,
  OfficeNativeReadRequest req,
  OfficeReadHop hop,
) async {
  switch (hop) {
    case OfficeReadHop.snapshot:
      final linkId = await _resolveOfficeLinkId(ref, req);
      if (linkId.isEmpty) {
        throw OfficeSnapshotUnavailableException('拿不到 link_id');
      }
      final api = ref.read(officeApiProvider);
      if (api == null) {
        throw OfficeSnapshotUnavailableException('未连接 / Office 套件不可用');
      }
      final data = await api.snapshotGet(linkId: linkId);
      final sections = officeSectionsFromSnapshot(data, format: req.format);
      if (sections == null) {
        // `.osheet` 的内容树 ↔ 原生 section 映射未取证：不猜，回落。
        throw OfficeSnapshotUnavailableException('内容树形态对不上原生 section');
      }
      return OfficeNativeReader.parseSections(sections, format: req.format);
    case OfficeReadHop.fileStationNative:
      return _readOfficeBytesHop(ref, req, req.nativeBytesUrl);
    case OfficeReadHop.driveBytes:
      return _readOfficeBytesHop(ref, req, req.driveBytesUrl);
    case OfficeReadHop.byPath:
      return _readOfficeBytesHop(ref, req, null);
  }
}

/// 取字节 → 解析（复用既有的 [officeNativeDocumentProvider]：包嗅探 + 专属文案）。
Future<OfficeNativeDocument> _readOfficeBytesHop(
  Ref ref,
  OfficeNativeReadRequest req,
  String? url,
) => ref.watch(
  officeNativeDocumentProvider(
    OfficeNativeBytesRequest(
      bytes: FileBytesRequest(req.entryPath, url: url),
      format: req.format,
    ),
  ).future,
);

/// 拿 `link_id`：优先调用方给的 `permanent_link`；没有时按真机取法现取一次
/// （`SynologyDrive.Files:get {path:'/mydrive/<name>'}`，**只给 Drive API**）。
Future<String> _resolveOfficeLinkId(
  Ref ref,
  OfficeNativeReadRequest req,
) async {
  final given = req.linkId.trim();
  if (given.isNotEmpty) return given;
  final p = req.drivePath;
  if (p == null || !p.startsWith(kDriveRootForRead)) return '';
  final drive = ref.read(driveApiProvider);
  if (drive == null) return '';
  final link = await drive.permanentLinkForPath(path: p);
  return link.trim();
}

/// 只读查看器的错误分类（每类一个 UI 分支、各不相同的文案）。
enum OfficeNativeErrorKind {
  /// 带打开密码（`E_OFFICE_PASSWORD_PROTECTED`）。
  passwordProtected,

  /// 部分 section 已加密（无打开密码，算法不可判定）。
  encryptedSection,

  /// `105`/`160`：账号无权限。
  noPermission,

  /// `119`/`106`：会话失效/超时（**只提示，绝不隐藏模块**）。
  sessionExpired,

  /// 服务端回的是转码后的包（扩展名与内容不符）。
  transcodedBytes,

  /// 下载失败。
  downloadFailed,

  /// 未知 / 损坏 / 不是原生文档。
  damaged,
}

/// 错误 → 界面信息（纯函数，便于单测）。
class OfficeNativeErrorInfo {
  const OfficeNativeErrorInfo({
    required this.kind,
    required this.title,
    required this.detail,
    required this.canRetry,
  });

  final OfficeNativeErrorKind kind;
  final String title;
  final String detail;
  final bool canRetry;
}

/// 把解析/下载异常映射成**互不相同**的界面文案。
OfficeNativeErrorInfo officeNativeErrorInfo(Object error, {AppText? t}) {
  if (error is OfficeDocumentPasswordProtectedException) {
    return OfficeNativeErrorInfo(
      kind: OfficeNativeErrorKind.passwordProtected,
      title: driveC1('officeViewerPasswordTitle', '需要文档密码'),
      // 解析层已定稿的专属文案（明确"不是文件损坏/格式不支持"）。
      detail: error.message,
      canRetry: false,
    );
  }
  if (error is OfficeSectionEncryptedException) {
    return OfficeNativeErrorInfo(
      kind: OfficeNativeErrorKind.encryptedSection,
      title: driveC1('officeViewerEncryptedSectionTitle', '部分内容已加密'),
      detail:
          '${error.message}\n'
          '${driveC1('officeViewerEncryptedSectionDetail', '只能显示未加密的部分，解密排期在后续阶段。')}',
      canRetry: false,
    );
  }
  if (error is OfficeNativeTranscodedBytesException) {
    return OfficeNativeErrorInfo(
      kind: OfficeNativeErrorKind.transcodedBytes,
      title: driveC1('officeViewerTranscodedTitle', '拿到的是转换后的文件'),
      detail:
          '${driveC1('officeViewerTranscodedDetail', '这条下载链路把 Office 原生文档转成了别的格式（内容不再是 .odoc/.osheet/.oslides 原生字节），所以打不开。')}'
          '${driveC1Fill('officeViewerTranscodedKind', '（识别为 ${error.packageKind}）', {
            'kind': error.packageKind,
          })}',
      canRetry: false,
    );
  }
  if (error is DsmApiException) {
    final state = classifyErrorCode(error.code);
    if (state == AvailabilityState.unauthorized) {
      return OfficeNativeErrorInfo(
        kind: OfficeNativeErrorKind.noPermission,
        title: driveC1('officeViewerNoPermissionTitle', '无权限读取这份文档'),
        detail:
            '${driveC1('officeViewerNoPermissionDetail', '当前账号没有读取/下载该文件的权限。')}'
            '${t?.serviceEntryUnauthorized ?? ''}',
        canRetry: false,
      );
    }
    if (state == AvailabilityState.sessionExpired) {
      return OfficeNativeErrorInfo(
        kind: OfficeNativeErrorKind.sessionExpired,
        title: driveC1('officeViewerSessionTitle', '会话已过期'),
        detail:
            '${driveC1('officeViewerSessionDetail', '登录状态已失效，请重新登录后再试。')}'
            '${t?.serviceEntrySessionExpired ?? ''}',
        canRetry: true,
      );
    }
    return OfficeNativeErrorInfo(
      kind: OfficeNativeErrorKind.downloadFailed,
      title: driveC1('officeViewerDownloadFailedTitle', '读取文件字节失败'),
      detail: describeFileError(error),
      canRetry: true,
    );
  }
  if (error is OFileFormatException) {
    return OfficeNativeErrorInfo(
      kind: OfficeNativeErrorKind.damaged,
      title: driveC1('officeViewerLoadFailedTitle', '打不开这个 Office 文档'),
      detail:
          '${driveC1('officeViewerLoadFailedHint', '文件可能已损坏，或不是有效的 Synology Office 原生文档（.odoc/.osheet/.oslides）。')}\n'
          '${error.codeWire}: ${error.message}',
      canRetry: true,
    );
  }
  return OfficeNativeErrorInfo(
    kind: OfficeNativeErrorKind.damaged,
    title: driveC1('officeViewerLoadFailedTitle', '打不开这个 Office 文档'),
    detail:
        '${driveC1('officeViewerLoadFailedHint', '文件可能已损坏，或不是有效的 Synology Office 原生文档（.odoc/.osheet/.oslides）。')}\n'
        '${userFacingError(error)}',
    canRetry: true,
  );
}

/// 只读查看器（三格式统一入口）。
///
/// 读取优先级（本批真机修正，见 [officeNativeReadProvider]）：
///   ① `Office.Snapshot:get v4`（原生内容树，无需 convert）→
///   ② File Station 真实路径的**原生字节**（[nativeBytesUrl]）→
///   ③ Drive 直链（[bytesUrl]，会被转码 → 专属提示）。
///
/// [bytesUrl] 同时是"没有 [nativeBytesUrl] 时的兜底"；两者都为空时
/// `fileBytesProvider` 会按 [entry].path 走既有链路。
class OfficeNativeViewer extends ConsumerWidget {
  const OfficeNativeViewer({
    super.key,
    required this.entry,
    this.bytesUrl,
    this.nativeBytesUrl,
    this.linkId = '',
    this.drivePath,
    required this.onDownload,
    required this.onOpen,
  });

  final FileEntryDto entry;

  /// Drive/兜底取字节直链（第三跳；Drive 直链会把原生文档转码）。
  final String? bytesUrl;

  /// File Station 真实路径（`/home/Drive/...`）的**原生字节**直链（第二跳）。
  final String? nativeBytesUrl;

  /// Drive 的 `permanent_link` = `Office.Snapshot:get` 的 `link_id`（第一跳）。
  final String linkId;

  /// Drive 视角的展示路径（`/mydrive/...`）：[linkId] 为空时用它现取 `link_id`。
  final String? drivePath;

  final VoidCallback onDownload;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final format = OfficeNativeReader.formatForFileName(entry.name);
    if (format == null) {
      return _OfficeErrorStage(
        info: OfficeNativeErrorInfo(
          kind: OfficeNativeErrorKind.damaged,
          title: driveC1('officeViewerLoadFailedTitle', '打不开这个 Office 文档'),
          detail: driveC1(
            'officeViewerNotNativeDetail',
            '这不是 Synology Office 原生文档（.odoc/.osheet/.oslides）。',
          ),
          canRetry: false,
        ),
        onDownload: onDownload,
        onOpen: onOpen,
      );
    }
    if (entry.size > kOfficeNativeMaxInlineBytes) {
      return _OfficeTooBigStage(
        entry: entry,
        onDownload: onDownload,
        onOpen: onOpen,
      );
    }

    // 能力位（可选）：`SYNO.Office.Snapshot` 不在能力表里 → 第一跳跳过
    // （服务只降级成 `partial`，**不隐藏模块**）；能力表未拿到（null）→ fail-open。
    // 读的是 `officeApiProvider` 背后的**真能力表**，不额外触发一轮服务检测。
    final snapshotApiPresent =
        ref.watch(officeApiProvider)?.api.apiTable?.containsKey(
          kOfficeSnapshotApi,
        ) ??
        true;
    // ★ 统一入口（用户 2026-09-25 裁决）：从 NAS「文件」打开时调用方给不出
    // Drive 视角路径，这里按已取证的映射补一条，让三种格式走**和 My Drive 同一跳**
    // （`Snapshot:get` → 高保真渲染），而不是落到低保真的字节/文本降级路径。
    final effectiveDrivePath =
        (drivePath != null && drivePath!.trim().isNotEmpty)
        ? drivePath
        : officeDrivePathForFileStationPath(entry.path);
    final req = OfficeNativeReadRequest(
      entryPath: entry.path,
      format: format,
      linkId: linkId,
      drivePath: effectiveDrivePath,
      nativeBytesUrl: nativeBytesUrl,
      driveBytesUrl: bytesUrl,
      snapshotApiPresent: snapshotApiPresent,
    );
    final doc = ref.watch(officeNativeReadProvider(req));
    return doc.when(
      loading: () => const _OfficeLoadingStage(),
      error: (err, _) {
        final info = officeNativeErrorInfo(err, t: context.t);
        return _OfficeErrorStage(
          info: info,
          onDownload: onDownload,
          onOpen: onOpen,
          onRetry: info.canRetry
              ? () => ref.invalidate(officeNativeReadProvider(req))
              : null,
        );
      },
      data: (d) => _OfficeDocumentStage(document: d),
    );
  }
}

class _OfficeLoadingStage extends StatelessWidget {
  const _OfficeLoadingStage();

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('office-native-loading'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: Gap.md),
          Text(
            driveC1('officeViewerParsing', '正在解析 Office 文档…'),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
          ),
        ],
      ),
    );
  }
}

class _OfficeTooBigStage extends StatelessWidget {
  const _OfficeTooBigStage({
    required this.entry,
    required this.onDownload,
    required this.onOpen,
  });

  final FileEntryDto entry;
  final VoidCallback onDownload;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return _OfficeErrorStage(
      key: const Key('office-native-too-big'),
      info: OfficeNativeErrorInfo(
        kind: OfficeNativeErrorKind.damaged,
        title: driveC1('officeViewerTooBigTitle', '文档太大，未内嵌解析'),
        detail:
            '${driveC1Fill('officeViewerTooBig', '这份文档有 {size}，超过内嵌解析上限。', {'size': entry.humanSize})}\n'
            '${driveC1('officeViewerTooBigHint', '可以下载后再读，或换一台网络更快的设备重试。')}',
        canRetry: false,
      ),
      onDownload: onDownload,
      onOpen: onOpen,
    );
  }
}

/// 错误/降级舞台：标题 + 详情 + （可选）重试 + 下载/交给系统。
class _OfficeErrorStage extends StatelessWidget {
  const _OfficeErrorStage({
    super.key,
    required this.info,
    required this.onDownload,
    required this.onOpen,
    this.onRetry,
  });

  final OfficeNativeErrorInfo info;
  final VoidCallback onDownload;
  final VoidCallback onOpen;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final icon = switch (info.kind) {
      OfficeNativeErrorKind.passwordProtected => Icons.lock_outline,
      OfficeNativeErrorKind.encryptedSection => Icons.enhanced_encryption,
      OfficeNativeErrorKind.noPermission => Icons.block_outlined,
      OfficeNativeErrorKind.sessionExpired => Icons.timer_off_outlined,
      OfficeNativeErrorKind.transcodedBytes => Icons.swap_horiz,
      _ => Icons.broken_image_outlined,
    };
    return Center(
      key: const Key('office-native-error'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: hud.dim),
            const SizedBox(height: Gap.md),
            Text(info.title, style: theme.textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            Text(
              info.detail,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
            ),
            const SizedBox(height: Gap.lg),
            Wrap(
              spacing: Gap.sm,
              runSpacing: Gap.sm,
              children: [
                if (onRetry != null)
                  OutlinedButton( style: InlineButtonStyle.outlined,
                    key: const Key('office-native-retry'),
                    onPressed: onRetry,
                    child: Text(context.t.photoRetry),
                  ),
                FilledButton.tonalIcon( style: InlineButtonStyle.filled,
                  onPressed: onOpen,
                  icon: const Icon(Icons.open_in_new),
                  label: Text(context.t.photoOpenWithOther),
                ),
                OutlinedButton.icon( style: InlineButtonStyle.outlined,
                  onPressed: onDownload,
                  icon: const Icon(Icons.download_outlined),
                  label: Text(context.t.dtoActionDownload),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 解析成功后的正文舞台：只读标识 + 按格式渲染。
class _OfficeDocumentStage extends StatelessWidget {
  const _OfficeDocumentStage({required this.document});

  final OfficeNativeDocument document;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const Key('office-native-viewer'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // **三种格式都不再有开发者横幅**：文件本身就是内容，只读是默认语义，
        // 不需要"只读预览 / 本批不支持编辑"这种工程话术。
        // `.osheet` 的那一条由表格批次（O2）在本批一并删除；格式名与工作表
        // 数量已经由页面标题栏（文件名）与底部表标签表达，不再重复。
        if (document.encryptionNotice != null)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Gap.md,
              vertical: Gap.xs,
            ),
            color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
            child: Text(
              document.encryptionNotice!,
              style: theme.textTheme.bodySmall,
            ),
          ),
        Expanded(child: _body(context)),
      ],
    );
  }


  Widget _body(BuildContext context) {
    final workbook = document.workbook;
    if (workbook != null) return OSheetView(workbook: workbook);
    final doc = document.document;
    if (doc != null) return ODocView(document: doc);
    final presentation = document.presentation;
    if (presentation != null) {
      return OSlidesView(presentation: presentation);
    }
    return Center(
      child: Text(
        driveC1('officeViewerEmptyModel', '没有可显示的内容。'),
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
      ),
    );
  }
}

// ------------------------------------------------------------------ .osheet

/// 工作表网格：**直接复用 O2 的新渲染器**（`OfficeSheetView`）。
///
/// 旧实现（`_SheetGrid` + 两行"版式从简"说明）已删除：它按 `Table` 拉满宽度、
/// 不做真实列宽/冻结/数字格式，正是用户抱怨的"离预期很远"。
/// 这里作为**旧宿主**（File Station 原生 OFile 字节 / `OfficeNativeDocument`）
/// 的适配点，把已解析好的 `OSheetWorkbook` 交给同一个渲染器。
class OSheetView extends StatefulWidget {
  const OSheetView({super.key, required this.workbook});

  final OSheetWorkbook workbook;

  @override
  State<OSheetView> createState() => _OSheetViewState();
}

class _OSheetViewState extends State<OSheetView> {
  @override
  Widget build(BuildContext context) {
    final sheets = widget.workbook.sheets;
    if (sheets.isEmpty) {
      return _EmptyNote(text: driveC1('officeViewerSheetEmpty', '这个工作簿没有工作表'));
    }
    final mergeCount = sheets.fold<int>(
      0,
      (sum, sheet) => sum + sheet.mergedRegions.length,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: OfficeSheetView(
            workbook: widget.workbook,
            // 旧宿主只有 OFile 解析结果；OOXML 主通道由 `OfficeSheetPage` 负责。
            sections: const <String, Object?> {},
          ),
        ),
        if (mergeCount > 0)
          _Note(
            key: const Key('office-sheet-merges'),
            driveC1Fill(
              'officeViewerSheetMerges',
              '表格里有 {n} 处合并单元格。',
              <String, String>{'n': '$mergeCount'},
            ),
          ),
        _Note(
          key: const Key('office-sheet-style-note'),
          driveC1(
            'officeViewerSheetStyleNote',
            '表头与单元格样式按文件中的实际设置显示。',
          ),
        ),
      ],
    );
  }
}

/// 列标：0→A、25→Z、26→AA（电子表格习惯）。
String sheetColumnLabel(int index) {
  var i = index;
  final out = StringBuffer();
  while (i >= 0) {
    out.write(String.fromCharCode(65 + (i % 26)));
    i = (i ~/ 26) - 1;
  }
  return out.toString().split('').reversed.join();
}


// -------------------------------------------------------------------- .odoc

/// 文档块级只读渲染。
class ODocView extends StatelessWidget {
  const ODocView({super.key, required this.document});

  final ODocDocument document;

  @override
  Widget build(BuildContext context) {
    final blocks = document.blocks;
    final images = document.images;
    if (blocks.isEmpty && images.isEmpty) {
      return _EmptyNote(
        text: driveC1(
          'officeViewerDocEmpty',
          '这份文档还没有内容。在 Synology Office / WPS / Microsoft Word 里写点什么'
          '并保存，再重新打开即可看到。',
        ),
      );
    }
    final rendered = decoratePmBlocks(blocks);
    return ListView(
      key: const Key('office-doc-blocks'),
      padding: const EdgeInsets.all(Gap.md),
      children: [
        // **没有版式说明横幅**：正文就是正文（旧实现在这里印
        // "只读渲染：…版式从简。"，属于工程话术，已删除）。
        for (final item in rendered) _PmBlockWidget(item: item),
        if (images.isNotEmpty) ...[
          const Divider(),
          for (final image in images) PmImageCard(image: image),
        ],
      ],
    );
  }
}

/// 一个块 + 列表标记（有序列表要按层级连续编号）。
class RenderedPmBlock {
  const RenderedPmBlock(this.block, this.marker);

  final PmBlock block;
  final String? marker;
}

/// 给块补列表标记（有序列表按层级计数；遇到非列表块清零）。
///
/// 简化说明：编号只在同一层连续，跨层/跨非列表块会重置——官方编号规则未取证。
List<RenderedPmBlock> decoratePmBlocks(List<PmBlock> blocks) {
  final counters = <int, int>{};
  final out = <RenderedPmBlock>[];
  for (final b in blocks) {
    String? marker;
    if (b.isListItem) {
      if (b.ordered) {
        final n = (counters[b.listLevel] ?? 0) + 1;
        counters[b.listLevel] = n;
        marker = '$n.';
      } else {
        marker = '•';
      }
    } else {
      counters.clear();
    }
    out.add(RenderedPmBlock(b, marker));
  }
  return out;
}

class _PmBlockWidget extends StatelessWidget {
  const _PmBlockWidget({required this.item});

  final RenderedPmBlock item;

  @override
  Widget build(BuildContext context) {
    final block = item.block;
    final theme = Theme.of(context);
    if (block.kind == PmBlockKind.table) {
      return PmTableView(table: block.table!);
    }
    if (block.isHeading) {
      return Padding(
        padding: const EdgeInsets.only(top: Gap.sm, bottom: Gap.xs),
        child: SelectableText.rich(
          TextSpan(
            children: _spans(context, block),
            style: _headingStyle(theme, block.headingLevel),
          ),
        ),
      );
    }
    if (block.isListItem) {
      return Padding(
        padding: EdgeInsets.only(
          left: Gap.md * block.listLevel,
          top: 2,
          bottom: 2,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 24,
              child: Text(
                item.marker ?? '•',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            Expanded(
              child: SelectableText.rich(
                TextSpan(children: _spans(context, block)),
              ),
            ),
          ],
        ),
      );
    }
    if (block.text.isEmpty) {
      // 空段落：给一点行距（正文里的空行），不渲染空 rich text。
      return const SizedBox(height: Gap.sm);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: SelectableText.rich(
        TextSpan(children: _spans(context, block)),
        style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
      ),
    );
  }

  TextStyle _headingStyle(ThemeData theme, int level) {
    final size = switch (level) {
      <= 1 => 22.0,
      2 => 19.0,
      3 => 17.0,
      4 => 15.5,
      5 => 14.5,
      _ => 13.5,
    };
    return (theme.textTheme.titleMedium ?? const TextStyle()).copyWith(
      fontSize: size,
      fontWeight: FontWeight.w700,
      height: 1.3,
    );
  }

  /// mark → 基础样式（**只做已取证的名字**；`font_size`/`color`/`background_color`
  /// 的语义未取证，本批不解释，如实忽略）。
  List<InlineSpan> _spans(BuildContext context, PmBlock block) {
    final scheme = Theme.of(context).colorScheme;
    return [
      for (final span in block.spans)
        TextSpan(text: span.text, style: _spanStyle(scheme, span)),
      if (block.spans.isEmpty && block.text.isNotEmpty)
        TextSpan(text: block.text),
    ];
  }

  TextStyle _spanStyle(ColorScheme scheme, PmSpan span) {
    var style = const TextStyle();
    if (span.marks.contains('strong')) {
      style = style.copyWith(fontWeight: FontWeight.w700);
    }
    if (span.marks.contains('em')) {
      style = style.copyWith(fontStyle: FontStyle.italic);
    }
    if (span.marks.contains('underline')) {
      style = style.copyWith(decoration: TextDecoration.underline);
    }
    if (span.linkHref != null) {
      style = style.copyWith(
        color: scheme.primary,
        decoration: TextDecoration.underline,
      );
    }
    return style;
  }
}

/// ProseMirror 表格（`.odoc` / `.oslides` 共用）：边框网格 + 文本。
///
/// 简化说明：`colspan` 用"占位列"近似（内容只在首列）；`rowspan` **不**还原
/// （解析层拿到了值，Flutter `Table` 不支持跨行，硬做会错位）。
class PmTableView extends StatelessWidget {
  const PmTableView({super.key, required this.table});

  final PmTable table;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    if (table.rows.isEmpty) return const SizedBox.shrink();
    var columns = 1;
    for (final row in table.rows) {
      var span = 0;
      for (final cell in row.cells) {
        span += cell.colspan < 1 ? 1 : cell.colspan;
      }
      if (span > columns) columns = span;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          border: TableBorder.all(
            color: hud.dim.withValues(alpha: 0.3),
            width: 0.5,
          ),
          defaultVerticalAlignment: TableCellVerticalAlignment.top,
          columnWidths: {
            for (var c = 0; c < columns; c++) c: const IntrinsicColumnWidth(),
          },
          children: [
            for (final row in table.rows)
              TableRow(
                children: [
                  for (final cell in row.cells) ...[
                    Container(
                      constraints: const BoxConstraints(
                        minWidth: 72,
                        maxWidth: 260,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      child: Text(cell.text, style: theme.textTheme.bodySmall),
                    ),
                    for (
                      var i = 1;
                      i < (cell.colspan < 1 ? 1 : cell.colspan);
                      i++
                    )
                      const SizedBox.shrink(),
                  ],
                  // 补齐到 columns（Table 允许短行，但显式补齐更直观）
                  for (var i = _rowWidth(row); i < columns; i++)
                    const SizedBox.shrink(),
                ],
              ),
          ],
        ),
      ),
    );
  }

  int _rowWidth(PmTableRow row) {
    var span = 0;
    for (final cell in row.cells) {
      span += cell.colspan < 1 ? 1 : cell.colspan;
    }
    return span;
  }
}

/// 图片**引用**占位卡（字节解不开，如实说明）。
class PmImageCard extends StatelessWidget {
  const PmImageCard({super.key, required this.image});

  final PmImageRef image;

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final id = image.fileId;
    final label = id == null
        ? driveC1('officeViewerDocImageNoId', '图片（无附件 id）')
        : driveC1Fill('officeViewerDocImagePlaceholder', '图片（附件 id：{id}）', {
            'id': id,
          });
    final size = (image.width != null && image.height != null)
        ? ' · ${image.width!.toStringAsFixed(0)}×${image.height!.toStringAsFixed(0)}'
        : '';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: Gap.xs),
      padding: const EdgeInsets.all(Gap.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(Radii.embed),
      ),
      child: Row(
        children: [
          Icon(Icons.image_outlined, color: hud.dim),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              '$label$size${image.alt == null ? '' : ' · ${image.alt}'}',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------- .oslides

/// 演示文稿阅读器（**16:9 幻灯片画布** + 左右滑动翻页 + 页码指示）。
///
/// 两条路径：
///   * [deck] 非空 —— 真实 PPTX 解析结果（`drive.downloadUrl` → `Files:download`
///     字节 = 标准 PPTX），按**真实 EMU 坐标**、母版/版式继承、图片与文本样式绘制
///     （见 `office_slides_deck_view.dart`）。这是对齐 WPS / Office 安卓版的路径。
///   * [deck] 为空 —— 只有 OFile 文本抽取结果时，退化成**同样比例的幻灯片画布**
///     （标题 + 正文按版心摆位），并给一行用户语言的说明；绝不空白、绝不出现
///     "本批/从简/不支持编辑"这类工程措辞。
class OSlidesView extends StatefulWidget {
  const OSlidesView({super.key, required this.presentation, this.deck});

  final OSlidesPresentation presentation;

  /// 真实 PPTX 解析结果（调用方拿到字节时给这里）。
  final OSlidesDeck? deck;

  @override
  State<OSlidesView> createState() => _OSlidesViewState();
}

class _OSlidesViewState extends State<OSlidesView> {
  final _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final deck = widget.deck;
    if (deck != null && deck.slides.isNotEmpty) {
      return OfficeSlidesDeckView(deck: deck);
    }
    final slides = widget.presentation.slides;
    if (slides.isEmpty) {
      return _EmptyNote(
        text: driveC1('officeViewerSlidesEmpty', '这份演示文稿没有幻灯片'),
      );
    }
    final index = _index.clamp(0, slides.length - 1);
    return Column(
      key: const Key('office-slides-fallback'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: PageView.builder(
            key: const Key('office-slides-pages'),
            controller: _controller,
            itemCount: slides.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) => _SlidePage(slide: slides[i]),
          ),
        ),
        _slidePager(context, index, slides.length),
      ],
    );
  }

  /// 页码指示 `2 / 15` + 上一页/下一页（与左右滑动等效的可点入口）。
  Widget _slidePager(BuildContext context, int index, int total) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            key: const Key('office-slides-prev'),
            onPressed: index > 0
                ? () => _controller.previousPage(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                  )
                : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Text(
            '${index + 1} / $total',
            key: const Key('office-slides-page-indicator'),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          IconButton(
            key: const Key('office-slides-next'),
            onPressed: index < total - 1
                ? () => _controller.nextPage(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                  )
                : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}

/// 没有 PPTX 字节时的**文本版幻灯片画布**（16:9，标题在版心上方、正文在下方）。
class _SlidePage extends StatelessWidget {
  const _SlidePage({required this.slide});

  final OSlide slide;

  /// 与 `p:sldSz` 一致的 16:9 版心（px）。
  static const double canvasWidth = 960;
  static const double canvasHeight = 540;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    final body = slide.blocks
        .map((b) => b.text.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    final title = slide.title;
    final bodyText = body.where((t) => t != title).join('\n');
    return Padding(
      padding: const EdgeInsets.all(Gap.sm),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availW = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : canvasWidth;
          final availH = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : canvasHeight;
          var scale = availW / canvasWidth;
          final byHeight = availH / canvasHeight;
          if (byHeight < scale) scale = byHeight;
          final hasContent = title.isNotEmpty || bodyText.isNotEmpty;
          return Center(
            child: SizedBox(
              width: canvasWidth * scale,
              height: canvasHeight * scale,
              child: ClipRect(
                // ⚠️⚠️ **必须用 `OverflowBox` 解开紧约束**（真机缺陷根因，2026-09-25）。
                //
                // 现象（真机 LGE-AN10，从 NAS「文件」打开 `.oslides`）：整页幻灯片
                // 只画出左上角一小块（实测约 140x78 dp，其余是底色）——
                // 用户原话「从 NAS file 打开 office 三种格式显示有问题」。
                //
                // 数值对账（设备 375 dp 宽）：`scale = 375/960 = 0.39` ⇒
                // 内容只占 `960 * 0.39² = 146 dp`，与实测 ~140 dp 吻合
                // ⇒ 内容被缩放**两次**。
                //
                // 根因与 `office_slides_deck_view.dart` 2026-09-22 修掉的那一处**完全相同**：
                // 外层 `SizedBox` 给的是紧约束 → `Transform.scale`（RenderProxyBox）
                // 原样下传 → 内层 `Container(width:960,height:540)` 被
                // `BoxConstraints.enforce` 压成 `960*scale`，再被 `Transform.scale` 缩一次。
                //
                // 为什么漏了这里：deck 路径（真 PPTX 字节）当天就修了并加了回归用例；
                // 而**这条降级路径**只在"拿不到 PPTX、只有 OFile 文本"时走 ——
                // 从 NAS「文件」打开的 `.oslides` 正好是这条（见 [OSlidesView] 注释）。
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth: 0,
                  maxWidth: double.infinity,
                  minHeight: 0,
                  maxHeight: double.infinity,
                  child: Transform.scale(
                  scale: scale,
                  alignment: Alignment.topLeft,
                  child: Container(
                    key: Key('office-slides-fallback-canvas-${slide.order}'),
                    width: canvasWidth,
                    height: canvasHeight,
                    color: Colors.white,
                    padding: const EdgeInsets.fromLTRB(56, 40, 56, 40),
                    child: hasContent
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (slide.isVisible == false)
                                Text(
                                  driveC1(
                                    'officeViewerSlidesHidden',
                                    '（隐藏页）',
                                  ),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: Colors.black54,
                                  ),
                                ),
                              if (title.isNotEmpty)
                                Text(
                                  title,
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(
                                        color: Colors.black,
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                              const SizedBox(height: 20),
                              Expanded(
                                child: SingleChildScrollView(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (bodyText.isNotEmpty)
                                        Text(
                                          bodyText,
                                          style: theme.textTheme.titleMedium
                                              ?.copyWith(
                                                color: Colors.black87,
                                              ),
                                        ),
                                      // 图片在 OFile 路径里只有引用（解不开字节），
                                      // 照实写成"这是什么图"，不静默丢掉。
                                      for (final ref in slide.images)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: Gap.xs,
                                          ),
                                          child: Text(
                                            context.t.officeViewerImageRef(
                                              ref.alt ??
                                                  driveC1(
                                                    'officeViewerSlidesImage',
                                                    '图片',
                                                  ),
                                              ref.fileId ?? '',
                                            ),
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                                  color: Colors.black54,
                                                ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                              if (slide.notes.trim().isNotEmpty) ...[
                                const Divider(height: Gap.md),
                                Text(
                                  driveC1(
                                    'officeViewerSlidesNotes',
                                    '演讲者备注',
                                  ),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: Colors.black54,
                                  ),
                                ),
                                Text(
                                  slide.notes.trim(),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: Colors.black87,
                                  ),
                                ),
                              ],
                            ],
                          )
                        : Center(
                            child: Text(
                              driveC1(
                                'officeViewerSlideEmptyBody',
                                '这一页没有可显示的内容',
                              ),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: hud.dim,
                              ),
                            ),
                          ),
                  ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// -------------------------------------------------------------------- 小部件

class _Note extends StatelessWidget {
  const _Note(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 6),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: DesignPalette.of(context).dim,
        ),
      ),
    );
  }
}

class _EmptyNote extends StatelessWidget {
  const _EmptyNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Text(
          text,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
        ),
      ),
    );
  }
}
