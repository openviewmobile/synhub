// Office C′ 编辑器 UI 批 2 —— `.odoc` 页：编辑交互 + 工具栏 + 保存 UX。
//
// 本批在批 1 的"打开 / 只读渲染 / 保存 / 门控"之上接入**编辑**：
//
//   * 可编辑模式：门控 `editable` **且**协作会话已建立时才开；否则保持批 1 的
//     只读路径（`_editEntryPlaceholder`）。门控逻辑不重写，仍走
//     `decideOfficeWriteGate`（`office_write_gate.dart`）。
//   * step 构造 / 位置算术全部在 `office_doc_edit.dart`（用 M1 `DocSchema.nodeSize`）；
//     本文件只负责"把哪些目标交给它"和"提交/反馈"。
//   * 提交走 `DocOtSession.localEdit(step)`（M2 + M0），本地立即生效 = **乐观显示**；
//     `pendingCount` 常显。
//   * `402`：会话层 `rebaseOnto` 重发（`doc_ot_session.dart:350`）。UI 在
//     `versionNotCurrent` 事件上提示"正在与服务器对齐"，在 `rebased`/`ackConfirmed`
//     上清除——**据实反映**，不掩盖。
//   * `411`：会话层 `dropInvalidStep` 丢掉那一步（`doc_ot_session.dart:378`）。
//     控制器把**我们刚发出的那一步**的描述显示给用户（明确告知哪一步没生效）。
//   * 撤销/重做：**单步**。M2 没有 invert，因此逆 step 由 `office_doc_edit.dart`
//     为本批实际发出的 step 类型实现，并用官方 transform 的 result 当预言机
//     （`test/office_doc_edit_test.dart` E4）。栈深度如实标注：只有已确认的 step
//     入栈，不假装有完整 undo 栈。
//
// 工具栏只做**有证据**的能力（逐项依据见 `docs/office-editor-ui-2.md` §③）：
// 加粗/斜体/下划线（presence mark）、标题级别（`paragraph.headingLevel`）、
// 列表（`paragraph.listId/listLevel/listMarks`）。块级 attr mark（text_align/
// line_height/direction/text_indent）写侧未取证 → 不做，保持只读降级。
//
// 保存只用**已验证**的 M0 `save` ack（真机帧 `["save",{}]` →
// `[{"success":true,"snapshot_version":…}]`）。失败帧未取证 → 不猜 `status`/`code`。
// UI 批 2 已把 M0 的 `classifyCollabReply` 修好以识别该 ack（UI 批 1 §④ 的缺陷），
// 所以 `parseOfficeDocSaveAck` 现在走统一分类路径。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/drive_api.dart' show DriveApi;
import '../../data/office_api.dart';
import '../../data/office_collab/doc_ot_queue.dart';
import '../../data/office_collab/doc_ot_session.dart';
import '../../data/office_collab/doc_schema.dart';
import '../../data/office_collab/doc_step.dart';
import '../../data/office_collab/office_collab_client.dart';
import '../../data/office_native/office_native_reader.dart'
    show OfficeNativeFormat;
import '../../dsm/webapi.dart' show DsmApiException, DsmErrorCode;
import '../files/drive_providers.dart' show driveApiProvider;
import '../files/office_providers.dart' show officeApiProvider;
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'office_doc_edit.dart';
import 'office_doc_image.dart' show OfficeAttachmentBytesProvider;
import 'office_doc_ooxml.dart' show ODocxDocument;
import 'office_doc_ooxml_view.dart' show OfficeDocxView;
import 'office_doc_tolerant_parse.dart';
import 'office_doc_view.dart'
    show OfficeDocEditHost, OfficeDocRenderReport, OfficeDocView;
import 'office_write_gate.dart';
import 'office_error_text.dart';
import '../../core/user_facing_error.dart';
import '../../core/theme/app_theme.dart';

String _t(String key, String zh) => dataText(key, zh);

String _fill(String key, String zh, Map<String, String> values) =>
    officeDocFill(key, zh, values);

/// 打开一个 `.odoc` 需要的最小信息（从 Drive/FileStation 入口传入）。
class OfficeDocRequest {
  const OfficeDocRequest({
    required this.fileId,
    this.password = '',
    required this.name,
    this.permanentLink = '',
    this.drivePath = '',
  });

  /// Drive/FileStation 的 `file_id`。
  final String fileId;

  /// ★★ 第 66 轮 D58：**加密文档的访问密码**（明文；未加密时为空串）。
  ///
  /// 来源：`drive_open_entry.dart` 里的 `drivePromptOfficePassword()`。
  /// 官方语义（`ApiSynoOfficeSnapshot.setAsGet(linkId, password)`）：
  /// `Snapshot/get` **总是**带 `password`，空串代表"没加密/不传"。
  ///
  /// ⚠️ 这里存**明文**是有意的：服务端就用明文（`putParam`），
  /// 客户端加密只会让服务端把密文当密码（见附录 AV/BB）。
  /// 它只活在这个 request 对象里，不落盘、不进日志。
  final String password;
  final String name;

  /// Drive `permanent_link`（`Office.Snapshot:get` 只认它）。
  final String permanentLink;

  /// `/mydrive/...` 展示路径（没有 [permanentLink] 时现取用）。
  final String drivePath;

  @override
  String toString() =>
      'OfficeDocRequest(fileId: $fileId, name: $name, '
      'hasLink: ${permanentLink.isNotEmpty})';
}

/// 一次只读读取的结果：`@C_text/content` 的 M1 视图 + 版本。
class OfficeDocSnapshot {
  const OfficeDocSnapshot({
    required this.node,
    required this.version,
    required this.raw,
    this.objectId = '',
    this.parseNote,
    this.contentMissing = false,
  });

  final DocNode node;
  final int version;
  final Map<String, Object?> raw;

  /// 只读解析时的**如实降级说明**（没有降级时为 null）。
  ///
  /// 真实 NAS 文档里有"M1 校验器判为非法、但删掉某个不规范字段后内容完整"的写法
  /// （真机 `Restaurant menu.odoc`：10 个 `picture` 节点上挂了字符级 marks）。
  /// 详见 `office_doc_tolerant_parse.dart`。**有降级就必须显示**，不许静默。
  final String? parseNote;

  /// ★★ 第 312 轮：本次装载**没有**拿到 Office 内容（回落了空白文档）。
  ///
  /// 门控要用它区分"Office 对象还没建出来"与"真的没有写权限"（见
  /// [OfficeWriteGateInputs.contentMissing]）。
  final bool contentMissing;

  /// `Snapshot:get` 回包里的 `data.object_id`（形如 `1028_35AO…`）。
  ///
  /// 它是**取图片字节的唯一钥匙**（`Attachment:get` 必须同时带
  /// `object_id` + `picture.config.file_id`，见 `office_api.dart`）。
  /// 之前这个字段被直接丢掉，正是"图片显示不出来"的根因之一。
  /// 缺省空串 = 回包里没有（老服务端 / 非原生文档），此时图片走失败态。
  final String objectId;

  @override
  String toString() => 'OfficeDocSnapshot(version: $version)';
}

/// 一次 `save` 的结果（严格照 M0 真机 ack 语义）。
class OfficeDocSaveResult {
  const OfficeDocSaveResult({
    required this.success,
    this.snapshotVersion,
    this.statusCode,
    this.message,
  });

  final bool success;

  /// 服务端 `snapshot_version`（成功时通常有）。
  final String? snapshotVersion;

  /// 失败时的状态码（可空）。
  final int? statusCode;

  /// 失败时的服务端消息（可空）。
  final String? message;

  @override
  String toString() =>
      'OfficeDocSaveResult(success: $success, '
      'snapshot: ${snapshotVersion ?? '-'}, status: ${statusCode ?? '-'})';
}

/// 页面依赖的外部世界（生产实现 = 既有 Office 数据层；测试 = 假实现）。
///
/// UI 批 2 **没有**给这个接口加方法：编辑直接走 [DocOtSession]（控制器已持有它），
/// 这样批 1 的假后端实现不需要跟着改。
abstract class OfficeDocBackend {
  /// 用**既有 Office 数据层**读 `@C_text/content`。
  Future<OfficeDocSnapshot> loadSnapshot();

  /// 读门控输入（`Permission:check` + `Info:get`）。
  Future<OfficeWriteGateInputs> loadGate();

  /// 建一个已 `open()` 的协作会话（M0 client + M1/M2 session）。
  Future<DocOtSession> openSession();

  /// 用 M0 的 `save` ack 语义做一次快照保存。
  Future<OfficeDocSaveResult> save(DocOtSession session);

  /// 关闭会话（页面 dispose 时调用）。
  Future<void> closeSession(DocOtSession session);
}

/// **可选能力**：后端能提供标准 OOXML（DOCX）字节。
///
/// 为什么**不**直接加进 [OfficeDocBackend]：那是 `implements` 关系，加一个成员
/// 就会**强制**批 1 的假后端/其它实现跟着改（并要求它们提供 OOXML）。这里用
/// **能力接口 + `is` 判定**，拿不到能力 = 走回落路径，既有实现零改动。
///
/// 真机实测（`docs/ooxml-ground-truth.md`）：`SYNO.SynologyDrive.Files:download`
/// 会把 `.odoc` **转码成标准 DOCX**（`PK\x03\x04` ZIP：`word/document.xml` +
/// `styles.xml` + `numbering.xml` + `header/footer*.xml` + `media/*`），
/// A4 页面尺寸/页边距/标题层级/编号/列宽**全在里面**——这是**首选**数据源。
/// 返回 null = 拿不到（离线 / 老服务端 / 无权限 / 加密 / 不是 OOXML）。
abstract class OfficeDocOoxmlSource {
  Future<Uint8List?> loadOoxmlBytes();
}

// ---------------------------------------------------------------------------
// 生产实现：既有 Office 数据层 + M0 客户端
// ---------------------------------------------------------------------------

/// 读门控输入失败但拿不到 DSM 码时的占位（走 fail-open）。
const int kOfficeGateUnknownError = -1;

class OfficeApiDocBackend implements OfficeDocBackend, OfficeDocOoxmlSource {
  /// 第 310 轮：`loadSnapshot()` 走"服务端没有内容 ⇒ 空白回落"时记下的树。
  /// 非空 ⇒ 协作会话以它当基线（版本 0），保证**渲染与编辑是同一份文档**。
  DocJson? _docSeed;

  OfficeApiDocBackend({
    required this.officeApi,
    required this.request,
    this.driveApi,
    this.clientId,
    this.clientFactory,
  });

  final OfficeApi officeApi;
  final OfficeDocRequest request;
  final DriveApi? driveApi;

  /// 与登录用户一致的 `clientId`（服务端会把 `uid` 覆写为鉴权用户）。
  final String? clientId;

  /// 测试/高级用法：替换掉真实 socket 客户端。
  final OfficeCollabClient Function(OfficeCollabTarget target)? clientFactory;

  String? _objectId;
  String? _linkId;

  /// 解析 `link_id`（Drive `permanent_link`）：调用方给的优先；否则按真机取法
  /// 用 Drive API 现取（`SynologyDrive.Files:get {path:'/mydrive/...'}`）。
  Future<String> _resolveLinkId() async {
    final given = request.permanentLink.trim();
    if (given.isNotEmpty) return given;
    final path = request.drivePath.trim();
    final drive = driveApi;
    if (path.isEmpty || drive == null) return '';
    final link = await drive.permanentLinkForPath(path: path);
    return link.trim();
  }

  Future<String?> _resolveObjectId() async {
    if (_objectId != null) return _objectId;
    final id = await officeApi.resolveObjectId(fileId: request.fileId);
    _objectId = id;
    return id;
  }

  @override
  Future<OfficeDocSnapshot> loadSnapshot() async {
    final linkId = _linkId ??= await _resolveLinkId();
    if (linkId.isEmpty) {
      throw const OfficeDocLoadException(
        'no_link_id',
        '这个文件没有 permanent_link，取不到 @C_text/content',
      );
    }
    // ★★ 第 66 轮 D58：**带上密码** —— `Snapshot/get` 是"取已解密内容"
    // 的通道（官方 `setAsGet(linkId, password)`，总是发）。
    // 未加密时 `request.password` 是空串，与官方一致。
    // ★★ 第 309 轮：**读内容前先要快照** —— 官方 Web 客户端逐字
    // `if("odoc"===n||"oslides"===n)try{…Snapshot/create v2{link_id}}catch{}`。
    // 新建出来的空白文档服务端**不会**自动产生快照（真机：21 分钟后仍取不到内容），
    // 所以这一步是"打开自己刚建的文件"的必要条件。
    // 失败按官方**吞掉**（老路径行为逐字不变，最坏与今天一样）。
    try {
      await officeApi.snapshotCreate(linkId: linkId);
    } catch (error) {
      logOfficeErrorForDiagnostics('doc-snapshotCreate', error);
    }
    final data = await officeApi.snapshotGet(
      linkId: linkId,
      password: request.password,
    );
    final sections = officeSectionsFromSnapshot(
      data,
      format: OfficeNativeFormat.odoc,
    );
    final contentSection = sections == null ? null : sections['content'];
    if (contentSection == null) {
      // ★★ 第 309 轮：**取不到内容 ⇒ 回落空白文档**，不再报错。
      // 真机缺陷：本 App 新建的空白 `.odoc`（新建 21 分钟后仍）打开即失败 ——
      // 服务端对"刚建出来的原生文档"没有内容，而官方对此的处置是
      // `var a = o.content?.data || this.getDefaultDocJson()`（`ui.doc.js`）。
      // 判据分两半（**不许合并**）：
      //   * 缺 content / 空 / 无 `data`  ⇒ 空白文档（本分支）；
      //   * 有 content 却不是我们能认的形态 ⇒ **仍按坏形态报错**（不伪造）。
      if (!officeSnapshotContentMissing(data)) {
        throw const OfficeDocLoadException(
          'bad_content_shape',
          'Snapshot:get 的内容树与 @C_text/content 形态对不上',
        );
      }
      // 证据只进日志：把回包的**键形态**记下来（下次真机复查要靠它分辨
      // "服务端没内容" 与 "我们没认出来"）。
      logOfficeErrorForDiagnostics(
        'docLoad:blankFallback contentKeys=${data['content'] is Map ? (data['content'] as Map).keys.toList() : data['content'].runtimeType}',
        StateError('snapshot has no content'),
      );
      final blank = officeDocParseNodeTolerant(kOfficeBlankDocTree);
      // 记下"本轮渲染用的是空白回落树" ⇒ `openSession()` 把它当协作会话的基线，
      // 否则渲染层有 `edit_area`、编辑判定层（只看会话文档）没有 ⇒ 全篇只读。
      _docSeed = kOfficeBlankDocTree;
      final blankNode = blank.node;
      if (blankNode == null) {
        throw const OfficeDocLoadException('bad_content_shape', '空白文档树解析不出文档');
      }
      return OfficeDocSnapshot(
        node: blankNode,
        version: 0,
        raw: blankNode.toRawJson(),
        objectId: '${data['object_id'] ?? ''}'.trim(),
        parseNote: blank.note,
        // ★★ 第 312 轮：这一次装载**没有**内容 ⇒ 门控据此区分
        // "Office 对象还没建出来" 与 "真的没有写权限"。
        contentMissing: true,
      );
    }
    // ★★ 第 309 轮：**形态真的对不上 ⇒ 统一成 `bad_content_shape`**。
    // 此前 `OfficeCollabContent.parse` 抛的 `OfficeCollabException`
    // （如 `@C_text/content has no numeric version`）会**绕过**装载失败文案，
    // 把实现者术语当用户文案显示（§2.0.47 ④ 同型缺陷）。
    final OfficeCollabContent content;
    try {
      content = OfficeCollabContent.parse(contentSection);
    } catch (error) {
      logOfficeErrorForDiagnostics('docLoad:bad_content_shape(parse)', error);
      throw const OfficeDocLoadException(
        'bad_content_shape',
        'Snapshot:get 的内容树解析不出文档',
      );
    }
    // **容错解析**：真实文档里"非 text 节点带 marks"会让 M1 抛异常 ⇒ 整篇打不开
    // （真机 `Restaurant menu.odoc`）。这里只清洗这一种写法，并如实带回 note。
    final parsed = officeDocParseNodeTolerant(content.data);
    final node = parsed.node;
    if (node == null) {
      throw const OfficeDocLoadException(
        'bad_content_shape',
        'Snapshot:get 的内容树解析不出文档',
      );
    }
    return OfficeDocSnapshot(
      node: node,
      version: content.version,
      raw: node.toRawJson(),
      // 图片字节通道的钥匙：`Snapshot:get` 回包里的 `object_id`
      // （形如 `1028_…`，见 `office_api.dart` 的 Attachment 取证注释）。
      objectId: '${data['object_id'] ?? ''}'.trim(),
      parseNote: parsed.note,
    );
  }

  @override
  Future<OfficeWriteGateInputs> loadGate() async {
    try {
      final objectId = await _resolveObjectId();
      final linkId = _linkId ??= await _resolveLinkId();
      // ★★ 第 311 轮：把"我们有没有问到"登记下来，别让"没解析到 id"伪装成"没权限"。
      final objectMissing = objectId == null || objectId.isEmpty;
      final linkMissing = linkId.isEmpty;
      if (objectMissing || linkMissing) {
        debugPrint(
          '[office:gate] idsUnresolved object=${objectMissing ? 'empty' : 'ok'} '
          'link=${linkMissing ? 'empty' : 'ok'} '
          '(object_id/link_id 取不到 ⇒ 没有问 Permission:check)',
        );
      }
      var canWrite = false;
      var canComment = false;
      if (objectId != null && objectId.isNotEmpty && linkId.isNotEmpty) {
        // 真机探针原文：docs/office-collab-protocol-spike.md §2.5
        // `Permission:check v1 {object_id, link_id, ntype}` →
        // `{readable, writable, commentable, …}`。
        final perm = await officeApi.api.call(
          'SYNO.Office.Permission',
          'check',
          preferredVersion: 1,
          params: <String, dynamic>{
            'object_id': objectId,
            'link_id': linkId,
            'ntype': officePermissionNtype(objectId),
          },
        );
        canWrite = perm['writable'] == true;
        canComment = perm['commentable'] == true;
        // ★ 第 312 轮：把 `Permission:check` 的**原文**打出来。
        // 空白新文件的真机现象是"canWrite=false 且 canComment=false"，
        // 而 `readable` 到底是 false（**对象还不存在** ⇒ 不是权限不足）还是
        // true（真被拒），决定了门控该说哪句话。
        debugPrint(
          '[office:gate] perm readable=${perm['readable']} '
          'writable=${perm['writable']} commentable=${perm['commentable']} '
          'object=${objectId.length > 8 ? '${objectId.substring(0, 8)}…' : objectId} '
          'ntype=${officePermissionNtype(objectId)}',
        );
      } else {
        debugPrint('[office:gate] perm skipped (no object_id/link_id)');
      }
      // `Office.Info:get v1` 的 `schema_mobile`（既有 `OfficeApi.info()` 的模型
      // 没有这个字段，所以这里读原始回包；方法与既有实现同一个）。
      final info = await officeApi.api.call(
        'SYNO.Office.Info',
        'get',
        preferredVersion: 1,
      );
      final schemaMobile = info['schema_mobile'] is num
          ? (info['schema_mobile'] as num).toInt()
          : 0;
      return OfficeWriteGateInputs(
        canWrite: canWrite,
        canComment: canComment,
        schemaMobile: schemaMobile,
        idsUnresolved: objectMissing || linkMissing,
      );
    } on DsmApiException catch (e) {
      return OfficeWriteGateInputs(
        canWrite: false,
        canComment: false,
        schemaMobile: 0,
        loadError: e.code,
      );
    } on Object {
      return const OfficeWriteGateInputs(
        canWrite: false,
        canComment: false,
        schemaMobile: 0,
        loadError: kOfficeGateUnknownError,
      );
    }
  }

  @override
  Future<DocOtSession> openSession() async {
    final objectId = await _resolveObjectId();
    if (objectId == null || objectId.isEmpty) {
      throw const OfficeDocLoadException(
        'no_object_id',
        '拿不到 Office object_id（socket 需要它，permanent_link 会被拒）',
      );
    }
    final linkId = _linkId ??= await _resolveLinkId();
    if (linkId.isEmpty) {
      throw const OfficeDocLoadException('no_link_id', '拿不到 permanent_link');
    }
    final target = OfficeCollabTarget(
      baseUrl: Uri.parse(officeApi.api.transport.baseUrl),
      objectId: objectId,
      linkId: linkId,
    );
    final client =
        clientFactory?.call(target) ??
        OfficeCollabClient(
          target: target,
          sessionCookieId: officeApi.api.session?.sid,
          synoToken: officeApi.api.transport.synoToken ?? '',
        );
    final session = DocOtSession(
      client: client,
      clientId: clientId ?? officeApi.api.session?.account?.trim() ?? 'dart01',
      // ★★ 第 310 轮：**渲染用的那份文档必须同时是编辑用的那份**。
      // `_docSeed` 只在 `loadSnapshot()` 走了"服务端没有内容 ⇒ 空白回落"时才非空
      // ⇒ 会话基线 = 渲染基线 = 官方 preset 语义（见 `docs/evidence-r310`）。
      defaultDoc: _docSeed,
    );
    await session.open();
    return session;
  }

  /// OOXML 主通道：`Files:download`（Drive `file_id`）。
  ///
  /// 返回的字节**必须**是 ZIP（`PK\x03\x04`）；否则交给 [ODocxDocument.parse]
  /// 判定失败并回落（见 [OfficeDocOoxmlSource] 的契约）。
  @override
  Future<Uint8List?> loadOoxmlBytes() async {
    final drive = driveApi;
    if (drive == null) return null;
    try {
      final url = drive.downloadUrl(fileId: request.fileId);
      final bytes = await officeApi.api.getBytes(url);
      if (bytes.isEmpty) return null;
      final data = Uint8List.fromList(bytes);
      // ZIP 头校验：不是 OOXML 就当拿不到（回落，绝不把垃圾当文档）。
      return ODocxDocument.looksLikeDocx(data) ? data : null;
    } on Object {
      // 下载失败不是致命错误：回落 OFile 路径 + 明确告知。
      return null;
    }
  }

  @override
  Future<OfficeDocSaveResult> save(DocOtSession session) async {
    // 真机帧：replay_doc_write.json seq20/21。
    final reply = await session.client.emit('save', <String, Object?>{});
    return parseOfficeDocSaveAck(reply);
  }

  @override
  Future<void> closeSession(DocOtSession session) => session.close();
}

/// 解析 M0 `save` ack（**纯函数**，可离线单测）。
///
/// 真机原文 `test/fixtures/office_collab/replay_doc_write.json` seq21：
/// `435[{"success":true,"snapshot_version":"6346a6c1b3848e9a2d712225ca75095dc1e47f09"}]`
/// —— 首元素就是结果对象，**没有 `null` 占位**。
///
/// UI 批 1 时 `classifyCollabReply` 会因为首元素没有 `status` 把它误判成 `other`，
/// 所以当时这里绕过分类器直接读 payload。UI 批 2 已把
/// `classifyCollabReply` 修好（新增 save-ack 分支，`office_collab_client.dart`），
/// 因此现在**走统一分类路径**：`classifyCollabReply == ok` 且 `success == true`
/// 才算成功。`save` 失败帧字段未取证，`status`/`code` 只做"能读就读"。
OfficeDocSaveResult parseOfficeDocSaveAck(Object? reply) {
  final payload = collabAckPayload(reply);
  final classified = classifyCollabReply(reply);
  if (classified == OfficeCollabErrorKind.ok &&
      payload is Map &&
      payload['success'] == true) {
    final snapshot = payload['snapshot_version'];
    return OfficeDocSaveResult(
      success: true,
      snapshotVersion: snapshot == null ? null : '$snapshot',
    );
  }
  return OfficeDocSaveResult(
    success: false,
    // `status` 是其它 ack 的字段；真机 `save` **失败**的形态未取证，
    // 所以只做"能读就读"，读不到把整个 payload 原样带进消息（不猜字段）。
    statusCode: collabAckStatus(reply),
    message: collabAckMessage(reply) ?? '$payload',
  );
}

/// 读取/会话建立失败（带一个稳定的 reason code，便于 UI 分类）。
class OfficeDocLoadException implements Exception {
  const OfficeDocLoadException(this.reason, this.message);

  final String reason;
  final String message;

  @override
  String toString() => 'OfficeDocLoadException($reason): $message';
}

// ---------------------------------------------------------------------------
// 状态与控制器
// ---------------------------------------------------------------------------

enum OfficeDocPhase {
  loading,
  ready,

  /// 会话失效/超时（119/106）——与普通失败分开，文案不同且**不隐藏页面**。
  sessionExpired,

  failure,
}

enum OfficeDocSaveState { idle, saving, saved, failed }

/// 一次已确认编辑的历史条目（用于单步撤销/重做）。
class _EditHistoryEntry {
  const _EditHistoryEntry(this.label, this.inverse);

  final String label;

  /// 把这次编辑还原的逆 step（`office_doc_edit.dart`）。
  final DocStep inverse;
}

class OfficeDocState {
  const OfficeDocState({
    required this.phase,
    required this.gate,
    this.snapshot,
    this.liveNode,
    this.liveVersion,
    this.errorMessage,
    this.errorCode,
    this.sessionReady = false,
    this.sessionNote,
    this.saveState = OfficeDocSaveState.idle,
    this.saveMessage,
    this.pendingCount = 0,
    this.syncNote,
    this.editNote,
    this.selection,
    this.activeParagraph,
    this.headingLevel = 0,
    this.listOn = false,
    this.canUndo = false,
    this.canRedo = false,
    this.undoLabel,
    this.ooxml,
    this.layoutNote,
  });

  factory OfficeDocState.loading() =>
      OfficeDocState(phase: OfficeDocPhase.loading, gate: _pendingGate);

  final OfficeDocPhase phase;
  final OfficeWriteGateDecision gate;
  final OfficeDocSnapshot? snapshot;

  /// 协作会话里的实时树（`session.docNode`）；会话没起来时 null。
  final DocNode? liveNode;
  final int? liveVersion;
  final String? errorMessage;
  final int? errorCode;

  /// 协作会话是否已建立。
  final bool sessionReady;

  /// 会话建立失败时的如实说明（不静默）。
  final String? sessionNote;

  final OfficeDocSaveState saveState;
  final String? saveMessage;

  /// 尚未被服务器确认的本地 step 数（乐观显示下的 pending）。
  final int pendingCount;

  /// `402` 对齐过程 / 重连 / 对齐失败时的一句说明（null = 无）。
  final String? syncNote;

  /// 最近一次编辑的反馈（`411` 哪一步没生效 / 编辑失败）；null = 无。
  final String? editNote;

  /// 当前文本选区（段落 + 纯文本字符区间）。
  final OfficeDocTextSelection? selection;

  /// 当前光标所在段落（工具栏的标题/列表目标）。
  final OfficeDocPath? activeParagraph;

  /// 当前段落的标题级别（按钮态）。
  final int headingLevel;

  /// 当前段落是否在列表里（按钮态）。
  final bool listOn;

  final bool canUndo;
  final bool canRedo;

  /// 撤销栈顶那一步的说明（按钮 tooltip）。
  final String? undoLabel;

  /// **首选数据源**：从 `Files:download` 拿到的标准 DOCX（见 `office_doc_ooxml.dart`）。
  ///
  /// 非 null 时页面用 [OfficeDocxView] 渲染（A4 纸 + 真实页边距 + 标题层级 +
  /// 真实列表标记 + `w:tblGrid` 列宽），**而不是** OFile 的文本抽取结果。
  final ODocxDocument? ooxml;

  /// OOXML 拿不到时的**如实说明**（用户语言，可关闭；null = 走的是主通道）。
  final String? layoutNote;

  /// 页面实际渲染的树：会话实时树优先，否则 Snapshot 只读树。
  DocNode? get node => liveNode ?? snapshot?.node;

  int get version => liveVersion ?? snapshot?.version ?? -1;

  bool get isReady => phase == OfficeDocPhase.ready;

  /// 可编辑 = 门控允许 **且** 协作会话可用。
  bool get editable => gate.editable && sessionReady && isReady;

  /// 有未确认的本地编辑（离开页面要提示）。
  bool get hasUnconfirmedEdits => pendingCount > 0;

  bool get hasSelection => selection != null && !(selection!.isCollapsed);

  OfficeDocState copyWith({
    OfficeDocPhase? phase,
    OfficeWriteGateDecision? gate,
    OfficeDocSnapshot? snapshot,
    DocNode? liveNode,
    int? liveVersion,
    ValueGetter<String?>? errorMessage,
    ValueGetter<int?>? errorCode,
    bool? sessionReady,
    ValueGetter<String?>? sessionNote,
    OfficeDocSaveState? saveState,
    ValueGetter<String?>? saveMessage,
    int? pendingCount,
    ValueGetter<String?>? syncNote,
    ValueGetter<String?>? editNote,
    ValueGetter<OfficeDocTextSelection?>? selection,
    ValueGetter<OfficeDocPath?>? activeParagraph,
    int? headingLevel,
    bool? listOn,
    bool? canUndo,
    bool? canRedo,
    ValueGetter<String?>? undoLabel,
    ValueGetter<ODocxDocument?>? ooxml,
    ValueGetter<String?>? layoutNote,
  }) {
    return OfficeDocState(
      phase: phase ?? this.phase,
      gate: gate ?? this.gate,
      snapshot: snapshot ?? this.snapshot,
      liveNode: liveNode ?? this.liveNode,
      liveVersion: liveVersion ?? this.liveVersion,
      errorMessage: errorMessage == null ? this.errorMessage : errorMessage(),
      errorCode: errorCode == null ? this.errorCode : errorCode(),
      sessionReady: sessionReady ?? this.sessionReady,
      sessionNote: sessionNote == null ? this.sessionNote : sessionNote(),
      saveState: saveState ?? this.saveState,
      saveMessage: saveMessage == null ? this.saveMessage : saveMessage(),
      pendingCount: pendingCount ?? this.pendingCount,
      syncNote: syncNote == null ? this.syncNote : syncNote(),
      editNote: editNote == null ? this.editNote : editNote(),
      selection: selection == null ? this.selection : selection(),
      activeParagraph: activeParagraph == null
          ? this.activeParagraph
          : activeParagraph(),
      headingLevel: headingLevel ?? this.headingLevel,
      listOn: listOn ?? this.listOn,
      canUndo: canUndo ?? this.canUndo,
      canRedo: canRedo ?? this.canRedo,
      undoLabel: undoLabel == null ? this.undoLabel : undoLabel(),
      ooxml: ooxml == null ? this.ooxml : ooxml(),
      layoutNote: layoutNote == null ? this.layoutNote : layoutNote(),
    );
  }
}

final OfficeWriteGateDecision _pendingGate = OfficeWriteGateDecision(
  OfficeWriteGateState.unknownFailOpen,
  reasonKey: 'officeDocGatePending',
  reasonText: dataText('officeDocGatePending', '正在确认写权限…（暂以只读方式打开）'),
);

/// 页面逻辑（可单测）：读 → 门控 → 会话 → 渲染 → 编辑 → 保存 → 关闭。
class OfficeDocController extends ChangeNotifier {
  OfficeDocController(this.backend);

  final OfficeDocBackend backend;

  OfficeDocState _state = OfficeDocState.loading();
  OfficeDocState get state => _state;

  DocOtSession? _session;
  DocOtSession? get session => _session;

  bool _disposed = false;
  final OfficeDocRenderReport renderReport = OfficeDocRenderReport();

  /// ★ 第 313 轮："点正文任意处即开始输入"的信号（见 `OfficeDocView.caretPrompt`）。
  /// 真机实测空白文档里那个可输入段落只有 351x20 dp，点页面别处毫无反应。
  final ValueNotifier<int> caretPrompt = ValueNotifier<int>(0);

  final List<_EditHistoryEntry> _undo = <_EditHistoryEntry>[];
  final List<_EditHistoryEntry> _redo = <_EditHistoryEntry>[];
  int _listSeq = 0;
  String? _syncNote;
  String? _editNote;
  OfficeDocTextSelection? _selection;
  OfficeDocPath? _activeParagraph;

  /// 串行化编辑提交：每次提交都基于**当时**的乐观树构造 step，避免并发帧互相踩。
  Future<void> _editChain = Future<void>.value();

  void _set(OfficeDocState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  Future<void> load() async {
    _set(OfficeDocState.loading());

    // 1) 门控（不因门控失败而挡住页面：fail-open 由 gate 自己决定）。
    OfficeWriteGateDecision gate;
    // ★★ 第 312 轮：把**原始输入**留一份。快照回来之后才知道"这个文件有没有内容"，
    // 而门控的第二判据要用它（见下面 `contentMissing` 复判）。
    OfficeWriteGateInputs? rawGateInputs;
    try {
      rawGateInputs = await backend.loadGate();
      gate = decideOfficeWriteGate(rawGateInputs);
    } on Object catch (e) {
      gate = decideOfficeWriteGate(
        OfficeWriteGateInputs(
          canWrite: false,
          canComment: false,
          schemaMobile: 0,
          loadError: e is DsmApiException ? e.code : kOfficeGateUnknownError,
        ),
      );
    }

    // 2) **首选**：标准 OOXML（DOCX）。拿不到就回落 OFile，并如实告知。
    ODocxDocument? ooxml;
    String? layoutNote;
    try {
      // 能力判定（见 [OfficeDocOoxmlSource]）：没有该能力 = 直接走回落路径。
      final source = backend is OfficeDocOoxmlSource
          ? backend as OfficeDocOoxmlSource
          : null;
      final bytes = source == null ? null : await source.loadOoxmlBytes();
      if (bytes != null) ooxml = ODocxDocument.parse(bytes);
    } on Object {
      ooxml = null;
    }
    if (ooxml == null) {
      layoutNote = _t(
        'officeDocLayoutFallback',
        '未能读取标准 Office 格式，已改用兼容排版——字号、缩进、列宽可能与原版有差异。',
      );
    }

    // 3) 既有 Office 数据层读 `@C_text/content`（编辑会话 / 回落渲染都需要）。
    OfficeDocSnapshot snapshot;
    try {
      snapshot = await backend.loadSnapshot();
    } on Object catch (e) {
      final code = e is DsmApiException ? e.code : null;
      _set(
        OfficeDocState(
          phase: _isExpired(code)
              ? OfficeDocPhase.sessionExpired
              : OfficeDocPhase.failure,
          gate: gate,
          errorCode: code,
          errorMessage: _describeError(e),
        ),
      );
      return;
    }

    // ★★ 第 312 轮：快照回来后再判一次门控。
    //
    // 真机证据（同一文件、同一账号、中间无任何权限变更）：
    //   新建后**立刻**打开 → `Permission:check` = `readable=false writable=false
    //   commentable=false`；4 分钟后打开 → 全 `true`。
    // 所以"三个 false + 这个文件还没有内容"= **Office 对象尚未建出来**，
    // 不是"这个账号没有权限"。此前那句话是**假话**，还藏掉了编辑入口（§2.0.8 ②）。
    if (snapshot.contentMissing && rawGateInputs != null) {
      gate = decideOfficeWriteGate(
        OfficeWriteGateInputs(
          canWrite: rawGateInputs.canWrite,
          canComment: rawGateInputs.canComment,
          schemaMobile: rawGateInputs.schemaMobile,
          loadError: rawGateInputs.loadError,
          idsUnresolved: rawGateInputs.idsUnresolved,
          contentMissing: true,
        ),
      );
    }

    // 3b) 解析侧的如实降级（"非 text 节点带 marks"被忽略）**必须让用户看见**。
    if (snapshot.parseNote != null) {
      layoutNote = layoutNote == null
          ? snapshot.parseNote
          : '$layoutNote\n${snapshot.parseNote}';
    }

    // 4) 协作会话（失败不挡住只读渲染，但**不静默**）。
    String? sessionNote;
    var sessionReady = false;
    try {
      final session = await backend.openSession();
      _session = session;
      sessionReady = true;
      session.events.listen(_onSessionEvent);
    } on Object catch (e) {
      // ★ 闸门已判"只读打开"（gate.editable 为假）时，协作权限拒绝只是该结论的
      // 必然推论 —— 不再重复报成红色 `Collaboration session unavailable`
      // （见 `docs/office-readonly-banner-defect.md` / [officeSessionNoteRedundant]）。
      // 闸门判定可写时不静音；只读时的其它协作故障也照常报错。
      if (officeSessionNoteRedundant(e, gateAllowsEditing: gate.editable)) {
        logOfficeErrorForDiagnostics('doc-session', e, StackTrace.current);
      } else {
        sessionNote = _t(
          'officeDocSessionUnavailable',
          '协作会话未建立：{name}',
        ).replaceAll('{name}', _describeError(e));
      }
    }

    _set(
      OfficeDocState(
        phase: OfficeDocPhase.ready,
        gate: gate,
        snapshot: snapshot,
        liveNode: _session?.docNode,
        liveVersion: _session?.version,
        sessionReady: sessionReady,
        sessionNote: sessionNote,
        pendingCount: _session?.pendingCount ?? 0,
        ooxml: ooxml,
        layoutNote: layoutNote,
      ),
    );
  }

  /// 会话事件 → UI 如实反映（402 对齐 / 411 丢步 / 重连）。
  void _onSessionEvent(DocOtSessionEvent event) {
    if (_disposed) return;
    switch (event.kind) {
      case DocOtSessionEventKind.versionNotCurrent:
        _rebasedThisEdit = false;
        _syncNote = _t('officeDocAligning', '版本不一致，正在与服务器对齐…');
      case DocOtSessionEventKind.rebased:
        _rebasedThisEdit = true;
        _syncNote = _t('officeDocAligned', '已与服务器对齐并重发本地修改。');
      case DocOtSessionEventKind.ackConfirmed:
        // 一次 402 恢复成功后，对齐说明保留到下一次编辑——让用户看得见"发生过
        // 对齐"，而不是无声无息地成功。
        _syncNote = _rebasedThisEdit
            ? _t('officeDocAligned', '已与服务器对齐并重发本地修改。')
            : null;
        _rebasedThisEdit = false;
      case DocOtSessionEventKind.stepDropped:
        _editNote = _fill(
          'officeDocEditStepDropped',
          '这一步没有生效（服务器判定无效）：{name}',
          <String, String>{'name': _lastSentLabel},
        );
      case DocOtSessionEventKind.pendingDroppedOnResync:
        _syncNote = null;
        _rebasedThisEdit = false;
        _editNote = _t('officeDocEditDropped', '未能与服务器对齐，未确认的本地修改已丢弃。');
      case DocOtSessionEventKind.reconnected:
        _syncNote = _t('officeDocReconnecting', '连接已恢复，正在重新读取文档…');
      case DocOtSessionEventKind.ready:
      case DocOtSessionEventKind.fetched:
      case DocOtSessionEventKind.invalidCommand:
      case DocOtSessionEventKind.rebasing:
      case DocOtSessionEventKind.closed:
        break;
    }
    _emitFromSession();
  }

  /// 最近一次发出的 step 的说明（411 时告诉用户"哪一步"）。
  String _lastSentLabel = '';

  /// 本次编辑是否经历过 `402 → rebaseOnto → 重发`。
  bool _rebasedThisEdit = false;

  /// 从会话同步 liveNode / version / pendingCount 与编辑相关字段。
  void _emitFromSession() {
    final s = _state;
    _set(
      s.copyWith(
        liveNode: _session?.docNode,
        liveVersion: _session?.version,
        sessionReady: _session != null,
        pendingCount: _session?.pendingCount ?? 0,
        syncNote: () => _syncNote,
        editNote: () => _editNote,
        selection: () => _selection,
        activeParagraph: () => _activeParagraph,
        headingLevel: _activeHeadingLevel(),
        listOn: _activeListOn(),
        canUndo: _undo.isNotEmpty,
        canRedo: _redo.isNotEmpty,
        undoLabel: () => _undo.isEmpty ? null : _undo.last.label,
      ),
    );
  }

  DocNode? _rootNode() {
    final raw = _session?.doc;
    if (raw == null) return null;
    try {
      return DocNode.fromRawJson(raw);
    } on Object catch (e) {
      _editNote = _fill(
        'officeDocEditUnavailable',
        '当前文档无法编辑：{name}',
        <String, String>{'name': userFacingError(e)},
      );
      return null;
    }
  }

  DocNode? _nodeAt(OfficeDocPath path) {
    final root = _rootNode();
    if (root == null) return null;
    try {
      return officeDocNodeAt(root, officeDocNodeStart(root, path));
    } on Object {
      return null;
    }
  }

  int _activeHeadingLevel() {
    final path = _activeParagraph;
    if (path == null) return 0;
    final attrs = _nodeAt(path)?.attrs;
    final v = attrs == null ? null : attrs['headingLevel'];
    return v is num ? v.toInt() : 0;
  }

  bool _activeListOn() {
    final path = _activeParagraph;
    if (path == null) return false;
    final v = _nodeAt(path)?.attrs['listId'];
    return v is String && v.isNotEmpty;
  }

  /// 该路径是否是可编辑段落（只支持 `edit_area` 下的 `paragraph`）。
  bool isEditablePath(OfficeDocPath path) {
    final raw = _session?.doc;
    if (raw == null) return false;
    try {
      final root = DocNode.fromRawJson(raw);
      var parent = root;
      for (var i = 0; i < path.indices.length; i++) {
        if (parent.type == 'edit_area') return true;
        final kids = parent.content;
        final index = path.indices[i];
        if (kids == null || index < 0 || index >= kids.length) return false;
        parent = kids[index];
      }
      return false;
    } on Object {
      return false;
    }
  }

  // ------------------------------------------------------------------ 选区 --

  void selectText(OfficeDocPath path, int start, int end) {
    final s = _state;
    _selection = OfficeDocTextSelection(path: path, start: start, end: end);
    _activeParagraph = path;
    _set(
      s.copyWith(
        selection: () => _selection,
        activeParagraph: () => path,
        headingLevel: _activeHeadingLevel(),
        listOn: _activeListOn(),
      ),
    );
  }

  void focusParagraph(OfficeDocPath path) {
    _activeParagraph = path;
    _set(
      _state.copyWith(
        activeParagraph: () => path,
        headingLevel: _activeHeadingLevel(),
        listOn: _activeListOn(),
      ),
    );
  }

  // ------------------------------------------------------------------ 编辑 --

  /// 段落纯文本被改成 [newText]（`office_doc_view` 的 `_EditableParagraph` 回调）。
  ///
  /// 只把**变化的那一段**换成 `ReplaceStep`（前后共同前后缀不动），这样区间外的
  /// mark 不会被抹掉；新输入的字符**不带 mark**（本批限制，报告如实登记）。
  Future<bool> replaceParagraphText(OfficeDocPath path, String newText) {
    return _enqueueEdit(_t('driveGapEditText', '编辑文本'), (root) {
      final inline = _requireParagraph(root, path);
      final old = inline.text;
      if (old == newText) return null;
      var prefix = 0;
      final maxPrefix = old.length < newText.length
          ? old.length
          : newText.length;
      while (prefix < maxPrefix &&
          old.codeUnitAt(prefix) == newText.codeUnitAt(prefix)) {
        prefix++;
      }
      var suffix = 0;
      final maxSuffix = (old.length - prefix) < (newText.length - prefix)
          ? (old.length - prefix)
          : (newText.length - prefix);
      while (suffix < maxSuffix &&
          old.codeUnitAt(old.length - 1 - suffix) ==
              newText.codeUnitAt(newText.length - 1 - suffix)) {
        suffix++;
      }
      return officeDocReplaceText(
        root,
        path,
        charFrom: prefix,
        charTo: old.length - suffix,
        insert: newText.substring(prefix, newText.length - suffix),
      );
    });
  }

  OfficeDocInlineText _requireParagraph(DocNode root, OfficeDocPath path) {
    final node = officeDocNodeAt(root, officeDocNodeStart(root, path));
    if (node == null) {
      throw DocRangeError('路径 ${path.key} 上没有节点');
    }
    final inline = officeDocInlineText(node);
    if (inline == null) {
      throw DocRangeError('节点 ${node.type} 含非 text 内联内容，本批不支持编辑');
    }
    return inline;
  }

  /// 工具栏：加粗/斜体/下划线（presence mark）。选区已整段带上 → 取消。
  Future<bool> togglePresenceMark(String markName) {
    final sel = _selection;
    if (sel == null || sel.isCollapsed) {
      _editNote = _t('officeDocEditNeedSelection', '请先选中要设置格式的文本。');
      _emitFromSession();
      return Future<bool>.value(false);
    }
    final label = markName == 'strong'
        ? _t('officeDocBold', '加粗')
        : (markName == 'em'
              ? _t('officeDocItalic', '斜体')
              : _t('officeDocUnderline', '下划线'));
    final count = sel.end - sel.start;
    var removed = false;
    return _enqueueEdit(label, (root) {
      final has = officeDocSelectionFullyMarked(root, sel, markName);
      removed = has;
      return has
          ? officeDocRemovePresenceMark(
              root,
              sel.path,
              charFrom: sel.start,
              charTo: sel.end,
              markName: markName,
            )
          : officeDocAddPresenceMark(
              root,
              sel.path,
              charFrom: sel.start,
              charTo: sel.end,
              markName: markName,
            );
    }).then((ok) {
      // ★ DA207（真机 r616）：编辑态的段落控件**只渲染纯文本**（`_EditableParagraph`
      //   的注释写得很明白），所以加粗/斜体/下划线打上之后**屏幕上一点变化都没有** ——
      //   当时唯一的反馈是 Undo 按钮的 tooltip 变了。用户会以为按钮坏了。
      //   这里明确回一句"已对 N 个字符设置加粗 / 已取消加粗"。
      if (!ok || _disposed) return ok;
      _editNote = removed
          ? _fill('officeDocMarkRemoved', '已取消{label}', <String, String>{
              'label': label,
            })
          : _fill(
              'officeDocMarkApplied',
              '已对 {count} 个字符设置{label}',
              <String, String>{'count': '$count', 'label': label},
            );
      _emitFromSession();
      return ok;
    });
  }

  /// 工具栏：标题级别（`paragraph.headingLevel`；0 = 正文）。
  Future<bool> setHeadingLevel(int level) {
    final path = _activeParagraph;
    if (path == null) {
      _editNote = _t('officeDocEditNeedParagraph', '请先把光标放到一个段落里。');
      _emitFromSession();
      return Future<bool>.value(false);
    }
    return _enqueueEdit(
      _t(
        'officeDocHeadingLevelLabel',
        '标题级别 $level',
      ).replaceAll('{level}', '$level'),
      (root) => officeDocSetHeadingLevel(root, path, level),
    );
  }

  /// 工具栏：列表开关（`listId/listLevel/listMarks`）。
  Future<bool> toggleList() {
    final path = _activeParagraph;
    if (path == null) {
      _editNote = _t('officeDocEditNeedParagraph', '请先把光标放到一个段落里。');
      _emitFromSession();
      return Future<bool>.value(false);
    }
    final on = !_activeListOn();
    // ⚠️ listId 的具体取值规则未取证（见 office_doc_edit.dart 文件头）；
    // 这里用一个本地稳定串，报告 ⑫ 登记真机判据。
    final listId = on ? 'list-${++_listSeq}' : '';
    final level = 0;
    return _enqueueEdit(
      on ? _t('officeDocList', '列表') : _t('officeDocListOff', '取消列表'),
      (root) => officeDocSetList(
        root,
        path,
        on: on,
        listId: listId,
        listLevel: level,
      ),
    );
  }

  Future<bool> undo() => _stepHistory(undo: true);

  Future<bool> redo() => _stepHistory(undo: false);

  Future<bool> _stepHistory({required bool undo}) async {
    final source = undo ? _undo : _redo;
    if (source.isEmpty) return false;
    final entry = source.last;
    final root = _rootNode();
    if (root == null) return false;
    // 逆 step 的逆 step（redo 用）= 当前 doc 上的还原。
    DocStep? opposite;
    try {
      opposite = officeDocInvertStep(entry.inverse, _session!.doc!);
    } on Object {
      opposite = null;
    }
    final ok = await _enqueueEdit(
      undo
          ? _t(
              'officeDocUndoLabel',
              '撤销 ${entry.label}',
            ).replaceAll('{label}', entry.label)
          : _t(
              'officeDocRedoLabel',
              '重做 ${entry.label}',
            ).replaceAll('{label}', entry.label),
      (_) => entry.inverse,
      recordHistory: false,
    );
    if (ok) {
      source.removeLast();
      if (opposite != null) {
        (undo ? _redo : _undo).add(_EditHistoryEntry(entry.label, opposite));
      }
    }
    _emitFromSession();
    return ok;
  }

  /// 把一次编辑排进串行链：在**执行时**用当时的乐观树构造 step（避免并发踩踏）。
  ///
  /// [build] 返回 null = 无需提交（例如文本没变）。
  Future<bool> _enqueueEdit(
    String label,
    DocStep? Function(DocNode root) build, {
    bool recordHistory = true,
  }) {
    final pending = _editChain.then(
      (_) => _applyEditNow(label, build, recordHistory: recordHistory),
    );
    _editChain = pending.then((_) {}, onError: (_) {});
    return pending;
  }

  Future<bool> _applyEditNow(
    String label,
    DocStep? Function(DocNode root) build, {
    required bool recordHistory,
  }) {
    final session = _session;
    if (session == null) {
      _editNote = _t('officeDocEditNoSession', '协作会话未建立，无法编辑。');
      _emitFromSession();
      return Future<bool>.value(false);
    }
    final root = _rootNode();
    if (root == null) {
      _emitFromSession();
      return Future<bool>.value(false);
    }
    DocStep? step;
    try {
      step = build(root);
    } on Object catch (e) {
      _editNote = _fill('officeDocEditFailed', '编辑失败：{name}', <String, String>{
        'name': userFacingError(e),
      });
      _emitFromSession();
      return Future<bool>.value(false);
    }
    if (step == null) return Future<bool>.value(true);

    final before = session.doc;
    DocStep? inverse;
    if (before != null) {
      try {
        inverse = officeDocInvertStep(step, before);
      } on Object {
        inverse = null;
      }
    }
    _lastSentLabel = label;
    _editNote = null;
    _syncNote = null;
    _rebasedThisEdit = false;
    _emitFromSession();

    // `localEdit` 在第一个 await 之前就把 step 入队（乐观应用），所以调用它之后
    // 立刻再同步一次状态，pending 指示才会马上显示这一步。
    final pending = session.localEdit(step);
    _emitFromSession();
    return pending.then(
      (outcome) {
        if (outcome.kind == DocOtAckKind.confirmed) {
          if (recordHistory && inverse != null) {
            _undo.add(_EditHistoryEntry(label, inverse));
            _redo.clear();
          }
          // 一次 402→rebase→重发成功后，保留"已对齐"说明，让用户看得见发生过对齐；
          // 没有 402 的普通确认才把临时说明清掉。
          if (!_rebasedThisEdit) _syncNote = null;
          final ok = true;
          _emitFromSession();
          return ok;
        }
        // 411 → 会话层已丢弃这一步；402 恢复失败 → 回退到 refetch。
        _editNote ??= outcome.kind == DocOtAckKind.invalidCommand
            ? _fill(
                'officeDocEditStepDropped',
                '这一步没有生效（服务器判定无效）：{name}',
                <String, String>{'name': label},
              )
            : _fill(
                'officeDocEditRolledBack',
                '这一步没有被服务器确认，已回退：{name}',
                <String, String>{'name': label},
              );
        _emitFromSession();
        return false;
      },
      onError: (Object e) {
        _editNote ??= _fill(
          'officeDocEditFailed',
          '编辑失败：{name}',
          <String, String>{'name': userFacingError(e)},
        );
        _emitFromSession();
        return false;
      },
    );
  }

  Future<void> save() async {
    final session = _session;
    if (session == null) {
      _set(
        _state.copyWith(
          saveState: OfficeDocSaveState.failed,
          saveMessage: () => _t('officeDocSaveNoSession', '协作会话未建立，无法保存'),
        ),
      );
      return;
    }
    _set(
      _state.copyWith(
        saveState: OfficeDocSaveState.saving,
        saveMessage: () => null,
      ),
    );
    try {
      final result = await backend.save(session);
      if (result.success) {
        _set(
          _state.copyWith(
            saveState: OfficeDocSaveState.saved,
            // DA208：`snapshot_version` 是 40 位对象 id（真机形如
            // `58c00e89e3b444f81e6b7f97260c760c781b4444`），对用户没有意义
            // —— 以前原样塞进提示条，等于把诊断串当文案。现在只回一句"已保存快照"，
            // id 只进诊断日志。
            saveMessage: () {
              final v = result.snapshotVersion;
              if (v != null && v.isNotEmpty) {
                logOfficeErrorForDiagnostics('doc-snapshotVersion', v);
              }
              return _t('officeDocSaveOk', '已保存快照');
            },
          ),
        );
      } else {
        // 保存失败**绝不静默**：明确错误 + 允许重试。
        _set(
          _state.copyWith(
            saveState: OfficeDocSaveState.failed,
            saveMessage: () =>
                _t('officeDocSaveFailed', '保存失败：{name}').replaceAll(
                  '{name}',
                  result.message ?? '${result.statusCode ?? ''}',
                ),
          ),
        );
      }
    } on Object catch (e) {
      _set(
        _state.copyWith(
          saveState: OfficeDocSaveState.failed,
          saveMessage: () => _t(
            'officeDocSaveFailed',
            '保存失败：{name}',
          ).replaceAll('{name}', _describeError(e)),
        ),
      );
    }
  }

  /// 离开页面前若有未确认编辑 → 提示文案（null = 可直接离开）。
  String? leavePrompt() {
    final pending = _state.pendingCount;
    if (pending <= 0) return null;
    return _fill(
      'officeDocLeavePending',
      '还有 {count} 步修改没被服务器确认；现在离开可能丢失这些修改。',
      <String, String>{'count': '$pending'},
    );
  }

  /// 页面 dispose / 显式关闭。**幂等**。
  Future<void> closeSession() async {
    final session = _session;
    _session = null;
    if (session != null) {
      await backend.closeSession(session);
    }
  }

  static bool _isExpired(int? code) =>
      code == DsmErrorCode.sessionTimeout || code == DsmErrorCode.sidNotFound;

  /// ⚠️ 真机缺陷修复（2026-09-22）：这里**曾经**是 `return '$error'`，
  /// 导致内部类名 + 原始 JSON 报文被当成用户文案弹在界面顶部（真机实测见
  /// `docs/office-error-banner-device-defect.md`）。
  /// 现在：已知类型给**用户语言**，未知类型给通用人话，原文只进日志。
  static String _describeError(Object error) {
    if (error is OfficeDocLoadException) {
      // ★★ 第 308 轮：`message` 是实现者诊断串（含 `@C_text/*` 这类 section 名、且只有中文），
      // 在英文环境下会把中文顶到界面上（真机 LGE-AN10 实测）⇒ 原文只进日志，界面走本地化。
      logOfficeErrorForDiagnostics('docLoad:${error.reason}', error);
      return officeLoadFailureText(error.reason);
    }
    logOfficeErrorForDiagnostics('describeError', error);
    return officeUserFacingError(error);
  }

  @override
  void dispose() {
    _disposed = true;
    caretPrompt.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// 页面
// ---------------------------------------------------------------------------

class OfficeDocPage extends ConsumerStatefulWidget {
  const OfficeDocPage({
    super.key,
    required this.request,
    this.backend,
    this.onFallbackToNativePreview,
  });

  final OfficeDocRequest request;

  /// 测试注入；为 null 时用既有 Office 数据层装配。
  final OfficeDocBackend? backend;

  /// 只读失败时可选的回退入口（接到既有原生只读预览）。
  final VoidCallback? onFallbackToNativePreview;

  @override
  ConsumerState<OfficeDocPage> createState() => _OfficeDocPageState();
}

class _OfficeDocPageState extends ConsumerState<OfficeDocPage>
    implements OfficeDocEditHost {
  late final OfficeDocController _controller;

  /// 是否处于**编辑模式**。
  ///
  /// 默认 false：显示的是 `Files:download` 回来的标准 DOCX（A4 纸 + 真实页边距 +
  /// 标题层级 + 真实列表标记 + `w:tblGrid` 列宽），**读起来像 WPS/Word**。
  /// 只有用户主动点"编辑"才切到可编辑的 OFile 渲染路径——两者的编辑目标树不同，
  /// 不能同时挂在一份视图上（否则工具栏改了树、画面不变，等于骗用户）。
  bool _editing = false;

  /// 用户是否关掉了"兼容排版"提示（**可关闭**，不是常驻横幅）。
  bool _layoutNoteClosed = false;

  @override
  void initState() {
    super.initState();
    trackView(UsageModule.office, screen: 'doc_reader');
    _controller = OfficeDocController(widget.backend ?? _buildBackend());
    unawaited(_controller.load());
  }

  OfficeDocBackend _buildBackend() {
    final officeApi = ref.read(officeApiProvider);
    if (officeApi == null) {
      return _DisconnectedBackend();
    }
    return OfficeApiDocBackend(
      officeApi: officeApi,
      request: widget.request,
      driveApi: ref.read(driveApiProvider),
    );
  }

  /// 图片字节提供者：把 `OfficeApi.attachmentGet`（Attachment:get v2）接给
  /// 渲染器的 `OfficeDocImage`。未连接时为 null → 图片组件显示失败态 + 重试，
  /// **不会**把任何内部标识（file_id/ref/路径）写到界面上。
  OfficeAttachmentBytesProvider? get _imageBytesProvider {
    final officeApi = ref.read(officeApiProvider);
    if (officeApi == null) return null;
    return ({required String objectId, required String fileId}) =>
        officeApi.attachmentGet(objectId: objectId, fileId: fileId);
  }

  @override
  void dispose() {
    // 契约：页面 dispose 时 `await session.close()`。这里用 unawaited 触发，
    // 关闭本身在 controller 里做（幂等）。
    unawaited(_controller.closeSession());
    _controller.dispose();
    super.dispose();
  }

  // ------------------------------------------------ OfficeDocEditHost 实现 --

  @override
  bool get enabled => _controller.state.editable;

  @override
  bool isEditablePath(OfficeDocPath path) => _controller.isEditablePath(path);

  @override
  void onParagraphChanged(OfficeDocPath path, String text) {
    unawaited(_controller.replaceParagraphText(path, text));
  }

  @override
  void onParagraphSelection(OfficeDocPath path, int start, int end) {
    _controller.selectText(path, start, end);
  }

  @override
  void onParagraphFocused(OfficeDocPath path) {
    _controller.focusParagraph(path);
  }

  // --------------------------------------------------------------- 离开保护 --

  Future<void> _handleBack(bool didPop, Object? result) async {
    if (didPop) return;
    final prompt = _controller.leavePrompt();
    if (prompt == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => OfficeDocLeaveDialog(prompt: prompt),
    );
    if (leave == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  /// ★ 第 312 轮：一次性把"两边到底长什么样"打成机制量。
  ///
  /// r311 只能推出"服务端回包或我方解析缺 `edit_area`"两种可能，靠猜没用。
  /// 这里把三件事同时打出来，对账即可判定：
  /// ① 渲染树（`state.node`）顶层节点类型序列；
  /// ② 我方解析的会话 doc 里 `edit_area` 的存在性与位置；
  /// ③ 首帧之后**实际渲染出的可输入字段数**（`EditableText`）。
  bool _loggedShapeOnce = false;

  void _logDocShapeOnce(OfficeDocState state) {
    if (_loggedShapeOnce) return;
    _loggedShapeOnce = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      String typesOf(DocJson? raw) {
        if (raw == null) return 'none';
        final kids = raw['content'];
        if (kids is! List) return 'noContent';
        return kids
            .whereType<Map>()
            .map((e) => e['type']?.toString() ?? '?')
            .join(',');
      }

      final rawSession = _controller.session?.doc;
      var editAreaIndex = -1;
      final rawKids = rawSession?['content'];
      if (rawKids is List) {
        for (var i = 0; i < rawKids.length; i++) {
          final k = rawKids[i];
          if (k is Map && k['type'] == 'edit_area') editAreaIndex = i;
        }
      }
      // 两边各取"edit_area 下第一个段落"的路径，看编辑判定是否一致。
      var sessionPathOk = false;
      if (editAreaIndex >= 0) {
        sessionPathOk = isEditablePath(OfficeDocPath(<int>[editAreaIndex, 0]));
      }
      final renderedRoot = state.node;
      var renderedPathOk = false;
      final rKids = renderedRoot?.content;
      if (rKids != null) {
        for (var i = 0; i < rKids.length; i++) {
          if (rKids[i].type == 'edit_area') {
            renderedPathOk = isEditablePath(OfficeDocPath(<int>[i, 0]));
            break;
          }
        }
      }

      var fields = 0;
      void walk(Element e) {
        if (e.widget is EditableText) fields++;
        e.visitChildren(walk);
      }

      final rootEl = WidgetsBinding.instance.rootElement;
      if (rootEl != null) walk(rootEl);
      debugPrint(
        '[office:liveDoc] edition=${_editing ? 'on' : 'off'} '
        'liveTypes=${typesOf(rawSession)} '
        'renderedTypes=${typesOf(renderedRoot?.toJson())} '
        'sessionEditAreaIdx=$editAreaIndex sessionEditable=$sessionPathOk '
        'renderedEditArea=$renderedPathOk renderedFields=$fields',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final state = _controller.state;
        if (state.isReady) _logDocShapeOnce(state);
        return PopScope(
          canPop: !state.hasUnconfirmedEdits,
          onPopInvokedWithResult: (didPop, result) =>
              unawaited(_handleBack(didPop, result)),
          child: Scaffold(
            appBar: AppBar(
              title: Text(
                widget.request.name.isEmpty
                    ? _t('officeDocTitle', '文档')
                    : widget.request.name,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                if (state.isReady && state.gate.showEditorEntry)
                  state.editable
                      ? (_effectsEditing(state)
                            ? _editDone(context)
                            : _editStart(context))
                      : _editEntryPlaceholder(context, state),
                if (state.isReady)
                  IconButton(
                    key: const Key('office-doc-save'),
                    tooltip: _t('officeDocSave', '保存快照'),
                    icon: state.saveState == OfficeDocSaveState.saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    onPressed: state.saveState == OfficeDocSaveState.saving
                        ? null
                        : () => unawaited(_controller.save()),
                  ),
              ],
            ),
            body: _body(context, state),
          ),
        );
      },
    );
  }

  /// 只读/未就绪时的编辑入口**占位**（批 1 行为保持）。
  Widget _editEntryPlaceholder(BuildContext context, OfficeDocState state) {
    final enabled = state.gate.editable;
    return IconButton(
      key: const Key('office-doc-edit-entry'),
      tooltip: enabled
          ? _t('officeDocEditNoSession', '协作会话未建立，无法编辑。')
          : (state.gate.reasonText ?? ''),
      icon: Icon(enabled ? Icons.edit_outlined : Icons.edit_off_outlined),
      onPressed: null,
    );
  }

  /// 当前画面是否走可编辑的 OFile 路径。
  bool _effectsEditing(OfficeDocState state) => state.editable && _editing;

  /// 进入编辑模式（用户主动；**默认是阅读模式**）。
  Widget _editStart(BuildContext context) {
    return IconButton(
      key: const Key('office-doc-edit-entry'),
      tooltip: _t('officeDocEnterEdit', '编辑'),
      icon: const Icon(Icons.edit_outlined),
      onPressed: () => setState(() => _editing = true),
    );
  }

  /// 退出编辑模式（回到标准排版阅读）。
  Widget _editDone(BuildContext context) {
    return IconButton(
      key: const Key('office-doc-edit-entry'),
      tooltip: _t('officeDocExitEdit', '完成编辑（回到标准排版）'),
      icon: const Icon(Icons.check_outlined),
      onPressed: () => setState(() => _editing = false),
    );
  }

  Widget _body(BuildContext context, OfficeDocState state) {
    switch (state.phase) {
      case OfficeDocPhase.loading:
        return Center(
          key: const Key('office-doc-loading'),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: Gap.md),
              Text(_t('officeDocLoading', '正在读取文档…')),
            ],
          ),
        );
      case OfficeDocPhase.sessionExpired:
        return _StatusPane(
          key: const Key('office-doc-session-expired'),
          icon: Icons.lock_clock,
          title: _t('officeDocSessionExpired', '登录会话已失效'),
          body: state.errorMessage ?? '',
          primaryLabel: _t('officeDocRetry', '重试'),
          onPrimary: () => unawaited(_controller.load()),
          secondaryLabel: widget.onFallbackToNativePreview == null
              ? null
              : _t('officeDocFallbackPreview', '改用只读预览'),
          onSecondary: widget.onFallbackToNativePreview,
        );
      case OfficeDocPhase.failure:
        return _StatusPane(
          key: const Key('office-doc-failure'),
          icon: Icons.error_outline,
          title: _t('officeDocLoadFailed', '打开失败'),
          body: state.errorMessage ?? '',
          primaryLabel: _t('officeDocRetry', '重试'),
          onPrimary: () => unawaited(_controller.load()),
          secondaryLabel: widget.onFallbackToNativePreview == null
              ? null
              : _t('officeDocFallbackPreview', '改用只读预览'),
          onSecondary: widget.onFallbackToNativePreview,
        );
      case OfficeDocPhase.ready:
        return _readyBody(context, state);
    }
  }

  Widget _readyBody(BuildContext context, OfficeDocState state) {
    final node = state.node;
    final ooxml = state.ooxml;
    final editing = _effectsEditing(state);
    final showPaper = ooxml != null && !editing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _gateBanner(context, state),
        if (editing) _toolbar(context, state),
        if (state.layoutNote != null && !_layoutNoteClosed)
          _layoutFallbackNote(state.layoutNote!),
        if (state.sessionNote != null)
          _sessionNote(context, state.sessionNote!),
        if (state.syncNote != null)
          _note(context, 'office-doc-sync-note', state.syncNote!, false),
        if (state.editNote != null)
          _note(context, 'office-doc-edit-note', state.editNote!, true),
        if (state.saveState == OfficeDocSaveState.failed ||
            state.saveState == OfficeDocSaveState.saved)
          _saveBanner(context, state),
        const Divider(height: 1),
        Expanded(
          child: showPaper
              // **首选路径**：标准 DOCX → A4 纸面。
              ? OfficeDocxView(key: const Key('office-doc-view'), doc: ooxml)
              : node == null
              ? _emptyDoc()
              : OfficeDocView(
                  doc: node,
                  report: _controller.renderReport,
                  editHost: this,
                  caretPrompt: _controller.caretPrompt,
                  // `Snapshot:get` 的 `object_id` 与内容一起交给视图层；
                  // 图片字节通道（Attachment:get v2）需要它。
                  objectId: state.snapshot?.objectId ?? '',
                  imageBytesProvider: _imageBytesProvider,
                ),
        ),
      ],
    );
  }

  /// 没有内容时的**可行动**空状态（不是一行"没有可显示的内容"就完事）。
  Widget _emptyDoc() {
    return Center(
      key: const Key('office-doc-empty-doc'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.description_outlined,
              size: 40,
              color: Color(0xFF9AA0A6),
            ),
            const SizedBox(height: Gap.md),
            Text(
              _t('officeDocNoContent', '这份文档还没有内容'),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: Gap.xs),
            Text(
              _t(
                'officeDocNoContentHint',
                '在 Synology Office / WPS / Microsoft Word 里写点什么并保存，再回来下拉刷新即可看到。',
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFF6B7075)),
            ),
            const SizedBox(height: Gap.md),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton(
                  style: InlineButtonStyle.filled,
                  key: const Key('office-doc-empty-retry'),
                  onPressed: () => unawaited(_controller.load()),
                  child: Text(_t('officeDocRetry', '重试')),
                ),
                if (widget.onFallbackToNativePreview != null) ...[
                  const SizedBox(width: Gap.sm),
                  TextButton(
                    key: const Key('office-doc-empty-native'),
                    onPressed: widget.onFallbackToNativePreview,
                    child: Text(_t('officeDocOpenInOffice', '用官方 Office 应用打开')),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 拿不到标准格式时的**如实、可关闭**说明（用户语言，不是工程话术）。
  Widget _layoutFallbackNote(String note) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('office-doc-layout-note'),
      width: double.infinity,
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.only(left: Gap.md, right: Gap.xs),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 16),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Text(note, style: Theme.of(context).textTheme.bodySmall),
          ),
          IconButton(
            key: const Key('office-doc-layout-note-close'),
            tooltip: _t('officeDocNoteDismiss', '知道了'),
            icon: const Icon(Icons.close, size: 16),
            onPressed: () => setState(() => _layoutNoteClosed = true),
          ),
        ],
      ),
    );
  }

  /// 工具栏：**只做有证据的能力**（see 文件头）；实现见 [OfficeDocToolbar]。
  Widget _toolbar(BuildContext context, OfficeDocState state) {
    return OfficeDocToolbar(
      state: state,
      onPresenceMark: (mark) => unawaited(_controller.togglePresenceMark(mark)),
      onHeadingLevel: (level) => unawaited(_controller.setHeadingLevel(level)),
      onToggleList: () => unawaited(_controller.toggleList()),
      onUndo: () => unawaited(_controller.undo()),
      onRedo: () => unawaited(_controller.redo()),
    );
  }

  /// 门控原因**永远可见**（"不满足 → 只读 + 明确原因"，不是隐藏整个页面）。
  Widget _gateBanner(BuildContext context, OfficeDocState state) {
    final reason = state.gate.reasonText;
    if (reason == null) return const SizedBox.shrink();
    return Container(
      key: const Key('office-doc-gate-banner'),
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 16),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Text(reason, style: Theme.of(context).textTheme.bodySmall),
          ),
          // ★★ 第 311 轮：原因若是"我们还没问到"（不是服务端拒绝），必须给重试 ——
          // §2.0.8 ②「错误态不许吞掉用户可改的入口」。真机主诉路径
          // "新建 → 立刻打开"就落在这条（`object_id`/`link_id` 尚未就绪）。
          if (state.gate.retryable)
            TextButton(
              key: const Key('office-doc-gate-retry'),
              onPressed: () => unawaited(_controller.load()),
              child: Text(_t('officeDocGateRecheck', '重新检查')),
            ),
        ],
      ),
    );
  }

  Widget _sessionNote(BuildContext context, String note) {
    return Container(
      key: const Key('office-doc-session-note'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      child: Text(
        note,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.error,
        ),
      ),
    );
  }

  /// 编辑/对齐提示（`402` 对齐、`411` 丢步、重连）——**不静默**。
  Widget _note(BuildContext context, String key, String text, bool isError) {
    return Container(
      key: Key(key),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      color: isError
          ? Theme.of(context).colorScheme.errorContainer
          : Theme.of(context).colorScheme.secondaryContainer,
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }

  Widget _saveBanner(BuildContext context, OfficeDocState state) {
    final failed = state.saveState == OfficeDocSaveState.failed;
    return Container(
      key: const Key('office-doc-save-banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      color: failed
          ? Theme.of(context).colorScheme.errorContainer
          : Theme.of(context).colorScheme.secondaryContainer,
      child: Row(
        children: [
          Expanded(
            child: Text(
              state.saveMessage ?? '',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (failed)
            TextButton(
              key: const Key('office-doc-save-retry'),
              onPressed: () => unawaited(_controller.save()),
              child: Text(_t('officeDocRetry', '重试')),
            ),
        ],
      ),
    );
  }
}

class _StatusPane extends StatelessWidget {
  const _StatusPane({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.primaryLabel,
    required this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final String title;
  final String body;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40),
            const SizedBox(height: Gap.md),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (body.isNotEmpty) ...[
              const SizedBox(height: Gap.xs),
              Text(body, textAlign: TextAlign.center),
            ],
            const SizedBox(height: Gap.lg),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton(
                  style: InlineButtonStyle.filled,
                  onPressed: onPrimary,
                  child: Text(primaryLabel),
                ),
                if (secondaryLabel != null && onSecondary != null) ...[
                  const SizedBox(width: Gap.sm),
                  TextButton(
                    onPressed: onSecondary,
                    child: Text(secondaryLabel!),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 未连接 / Office 套件不可用时的后端：只给明确错误，**不静默**。
class _DisconnectedBackend implements OfficeDocBackend {
  @override
  Future<OfficeDocSnapshot> loadSnapshot() async =>
      throw const OfficeDocLoadException(
        'not_connected',
        '未连接 DSM 或 Office 套件不可用',
      );

  @override
  Future<OfficeWriteGateInputs> loadGate() async => const OfficeWriteGateInputs(
    canWrite: false,
    canComment: false,
    schemaMobile: 0,
    loadError: kOfficeGateUnknownError,
  );

  @override
  Future<DocOtSession> openSession() async => throw OfficeDocLoadException(
    'not_connected',
    dataText('officeNotConnectedDsm', '未连接 DSM'),
  );

  @override
  Future<OfficeDocSaveResult> save(DocOtSession session) async =>
      OfficeDocSaveResult(
        success: false,
        message: dataText('setNotConnected', '未连接'),
      );

  @override
  Future<void> closeSession(DocOtSession session) async {}
}

/// 编辑工具栏（UI 批 2）——**独立可测**（不依赖协作会话/定时器）。
///
/// 每一项都只做**有证据**的能力（逐项依据见 `docs/office-editor-ui-2.md` §③）：
///   * 加粗/斜体/下划线：`transform_vectors.json` 的
///     `add-strong-presence` / `add-em-presence` / `add-underline-presence`；
///   * 标题级别：schema `paragraph.attrs.headingLevel`（`SetNodeAttrsStep` 通道由
///     `.vectors.attrs[set-paragraph-text-align]` 取证）；
///   * 列表：schema `paragraph.attrs.{listId,listLevel,listMarks}`；
///   * 撤销/重做：**单步**，逆 step 在 `office_doc_edit.dart`。
///
/// 没做的项（块级 attr mark、链接/图片/表格）**没有入口**，不是隐藏的。
class OfficeDocToolbar extends StatelessWidget {
  const OfficeDocToolbar({
    super.key,
    required this.state,
    required this.onPresenceMark,
    required this.onHeadingLevel,
    required this.onToggleList,
    required this.onUndo,
    required this.onRedo,
  });

  final OfficeDocState state;
  final ValueChanged<String> onPresenceMark;
  final ValueChanged<int> onHeadingLevel;
  final VoidCallback onToggleList;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  @override
  Widget build(BuildContext context) {
    final hasSelection = state.hasSelection;
    final hasParagraph = state.activeParagraph != null;
    return Material(
      key: const Key('office-doc-toolbar'),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            if (state.pendingCount > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
                child: Chip(
                  key: const Key('office-doc-pending'),
                  visualDensity: VisualDensity.compact,
                  label: Text(
                    officeDocFill(
                      'officeDocPendingCount',
                      '{count} 步未确认',
                      <String, String>{'count': '${state.pendingCount}'},
                    ),
                  ),
                ),
              ),
            IconButton(
              key: const Key('office-doc-bold'),
              tooltip: officeDocText('officeDocBold', '加粗'),
              onPressed: hasSelection ? () => onPresenceMark('strong') : null,
              icon: const Icon(Icons.format_bold),
            ),
            IconButton(
              key: const Key('office-doc-italic'),
              tooltip: officeDocText('officeDocItalic', '斜体'),
              onPressed: hasSelection ? () => onPresenceMark('em') : null,
              icon: const Icon(Icons.format_italic),
            ),
            IconButton(
              key: const Key('office-doc-underline'),
              tooltip: officeDocText('officeDocUnderline', '下划线'),
              onPressed: hasSelection
                  ? () => onPresenceMark('underline')
                  : null,
              icon: const Icon(Icons.format_underline),
            ),
            const SizedBox(width: Gap.sm),
            PopupMenuButton<int>(
              key: const Key('office-doc-heading'),
              enabled: hasParagraph,
              tooltip: officeDocText('officeDocHeading', '标题级别'),
              onSelected: onHeadingLevel,
              itemBuilder: (context) => <PopupMenuEntry<int>>[
                for (var level = 0; level <= 6; level++)
                  PopupMenuItem<int>(
                    value: level,
                    child: Text(
                      level == 0
                          ? officeDocText('officeDocHeadingBody', '正文')
                          : officeDocFill(
                              'officeDocHeadingLevel',
                              '标题 {level}',
                              <String, String>{'level': '$level'},
                            ),
                    ),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.format_size),
                    const SizedBox(width: Gap.xxs),
                    Text(
                      state.headingLevel == 0
                          ? officeDocText('officeDocHeadingBody', '正文')
                          : 'H${state.headingLevel}',
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              key: const Key('office-doc-list'),
              tooltip: officeDocText('officeDocList', '列表'),
              isSelected: state.listOn,
              onPressed: hasParagraph ? onToggleList : null,
              icon: const Icon(Icons.format_list_bulleted),
            ),
            const SizedBox(width: Gap.sm),
            IconButton(
              key: const Key('office-doc-undo'),
              tooltip: state.undoLabel == null
                  ? officeDocText('officeDocUndo', '撤销')
                  : officeDocFill(
                      'officeDocUndoOf',
                      '撤销：{name}',
                      <String, String>{'name': state.undoLabel!},
                    ),
              onPressed: state.canUndo ? onUndo : null,
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              key: const Key('office-doc-redo'),
              tooltip: officeDocText('officeDocRedo', '重做'),
              onPressed: state.canRedo ? onRedo : null,
              icon: const Icon(Icons.redo),
            ),
          ],
        ),
      ),
    );
  }
}

/// 离开确认框（UI 批 2）——**独立可测**。返回 true = 仍然离开。
class OfficeDocLeaveDialog extends StatelessWidget {
  const OfficeDocLeaveDialog({super.key, required this.prompt});

  final String prompt;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('office-doc-leave-dialog'),
      title: Text(officeDocText('officeDocLeaveTitle', '还有未确认的修改')),
      content: Text(prompt),
      actions: [
        TextButton(
          key: const Key('office-doc-leave-stay'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(officeDocText('officeDocLeaveStay', '留在本页')),
        ),
        FilledButton(
          key: const Key('office-doc-leave-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(officeDocText('officeDocLeaveConfirm', '仍然离开')),
        ),
      ],
    );
  }
}
