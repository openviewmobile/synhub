// Office C′ 演示文稿（Slides）批 1 —— `.oslides` 打开生命周期 + 写权限门控。
//
// 本批**只读**：页面把既有 Office 数据层读到的 section 字典交给
// `office_slides_view.dart` 渲染，并按既有门控（`office_write_gate.dart`）决定
// "编辑入口是否显示"（本批只做占位，**没有编辑交互**）。
//
// 数据链路（**复用既有接口，没有发明新的 Office 数据层**）：
//
//   Drive/FileStation 条目（先过既有加密门 `drive_encrypt_gate.dart`）
//     └─ drive_open_entry.dart 的 `.oslides` 分流
//          └─ OfficeSlidesPage
//               ├─ OfficeApiSlidesBackend.loadSnapshot()
//               │     officeApi.snapshotGet(linkId)             （既有 v4 只读通道）
//               │     officeSectionsFromSnapshot(..., oslides)   （既有适配器）
//               │     → {'content': {data, version}}（真机 2 帧实测：
//               │        data.content.data.attrs = {cx:960, cy:540, schema:13,
//               │        type:"presentation"}；另把 data.comment / data.file
//               │        这两个 @C_text/* section 一并带上）
//               ├─ OfficeApiSlidesBackend.loadGate()
//               │     Permission:check v1 + Info:get v1 → decideOfficeWriteGate
//               └─ OfficeApiSlidesBackend.openSession()
//                     OfficeCollabClient(M0) connect → emit('init')
//                     ack = [identifier, rev, steps[]]
//    dispose ─ session.close() → client.close()（幂等）
//
// `init` ack 的 `commands[]`/step 列表**不回放**（基础模型从 content section 重建），
// 但 step 名会被 `scanOfficeSlidesCommands` 全部登记：认识的进 `seenSteps`，
// 不认识的进 `unknownSteps`（可见降级）。
//
// 三态：`loading / ready / sessionExpired / failure`；会话建立失败**不挡住只读
// 渲染**，但一定有 `sessionNote`（不静默）。
//
// 未验证项（如实登记，见 `docs/office-slides-ui-1.md` §⑪）：presentation 的
// socket 命名空间由既有 `OfficeCollabTarget._deriveNamespace` 从 object_id 后缀推
// （`.slide → presentation`，M0 未连过）；本批**不**硬编码命名空间，也不因会话
// 失败而挡住只读渲染。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/drive_api.dart' show DriveApi;
import '../../data/office_api.dart';
import '../../data/office_collab/office_collab_client.dart';
import '../../data/office_native/office_json.dart';
import '../../data/office_native/office_native_reader.dart'
    show OfficeNativeFormat;
import '../../data/office_native/oslides_ooxml.dart';
import '../../dsm/webapi.dart' show DsmApiException, DsmErrorCode;
import '../files/drive_providers.dart' show driveApiProvider;
import '../files/office_providers.dart' show officeApiProvider;
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'office_doc_image.dart';
import 'office_slides_deck_view.dart';
import 'office_slides_edit.dart';
import 'office_slides_view.dart';
import 'office_write_gate.dart';
import 'office_error_text.dart';
import '../../core/theme/app_theme.dart';

String _t(String key, String zh) => dataText(key, zh);

String _fill(String key, String zh, Map<String, String> values) =>
    officeSlidesFill(key, zh, values);

/// **`.oslides` 的真实显示数据源**：Drive 下载直链（`SynologyDrive.Files:download`）
/// 拿回来的字节就是**标准 PPTX**（`PK\x03\x04`，见 `docs/ooxml-ground-truth.md`），
/// 解析出的几何/母版/版式/图片就是 WPS 那种显示效果的全部原料。
///
/// 失败（离线 / 无权限 / 老服务端 / 字节不是 PPTX）一律返回 **null**：
/// 页面回落到既有 OFile 文本渲染，并**用用户语言说明**（绝不静默空白）。
Future<OSlidesDeck?> loadOfficeSlidesDeck({
  required DriveApi drive,
  required String fileId,
}) async {
  if (fileId.trim().isEmpty) return null;
  try {
    final url = drive.downloadUrl(fileId: fileId);
    final bytes = await drive.api.getBytes(url);
    return OSlidesDeck.parse(bytes);
  } on Object {
    return null;
  }
}

/// 打开一个 `.oslides` 需要的最小信息（从 Drive/FileStation 入口传入）。
class OfficeSlidesRequest {
  const OfficeSlidesRequest({
    required this.fileId,
    this.password = '',
    required this.name,
    this.permanentLink = '',
    this.drivePath = '',
  });

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
      'OfficeSlidesRequest(fileId: $fileId, name: $name, '
      'hasLink: ${permanentLink.isNotEmpty})';
}

/// 一次只读读取的结果：`@C_text/*` 的 section 字典 + `content.version`。
class OfficeSlidesSnapshot {
  const OfficeSlidesSnapshot({
    required this.sections,
    required this.version,
    required this.raw,
    this.objectId = '',
  });

  final Map<String, Object?> sections;

  /// `Snapshot:get` 回包里的 `object_id` —— **文档内图片字节通道的钥匙**
  /// （批 A 的 `Attachment:get v2` 必须同时带它和 `file_id`；真机实测回包
  /// `data.keys` 含 `object_id`）。
  final String objectId;

  /// `content.version`（真机 2 帧实测 `{data, version}`）；没有就 0。
  final int version;

  /// `Snapshot:get` 的原始回包（诊断用）。
  final Map<String, dynamic> raw;

  @override
  String toString() =>
      'OfficeSlidesSnapshot(version: $version, sections: ${sections.keys.toList()})';
}

/// 已建立的 presentation 会话（M0 client + `fetch` ack）。
///
/// **批 2 真机修正**：演示文稿用的是 `fetch`（`init` 没有 ack，12s 超时），
/// `fetch` 回包 `[null, {doc: {version, data:{type,attrs,content}}, comment_store}]`
/// 直接给出权威文档树与 version（见 `docs/office-slides-ui-2.md` §①）。
class OfficeSlidesSession {
  OfficeSlidesSession({
    required this.client,
    required this.initAck,
    this.fetchDoc,
    this.fetchVersion,
  });

  final OfficeCollabClient client;

  /// `fetch` ack 原文（`[null, {doc:{…}}]`）；兼容测试里的 `[identifier, rev, steps]`。
  final Object? initAck;

  /// `fetch` 回包里的 `doc`（`{version, data:{type,attrs,content}}`）。
  final Map<String, Object?>? fetchDoc;

  /// `fetch` 回包里的 `doc.version`（权威 version）。
  final int? fetchVersion;

  List<Object?> get initAckList => asJsonList(initAck) ?? const <Object?>[];

  /// 会话 identifier（`init`/`fetch` ack 第 0 项；fetch 为 null）。
  String get identifier {
    final v = initAckList.isEmpty ? null : initAckList[0];
    return v == null ? '' : '$v';
  }

  /// 当前 rev/version：优先 `fetch` 的权威 version，回落 init ack 第 1 项。
  int get rev {
    if (fetchVersion != null) return fetchVersion!;
    final v = initAckList.length > 1 ? asJsonInt(initAckList[1]) : null;
    return v ?? 0;
  }

  /// 版本别名（doc 协议里叫 version）。
  int get version => rev;

  /// `fetch` 给回的权威文档树（`data`），编辑位置算术的 base。
  Map<String, Object?>? get docData {
    final doc = fetchDoc;
    if (doc == null) return null;
    return asJsonMap(doc['data']);
  }

  /// 自上次快照以来的增量 step（`init` ack 第 2 项；**本批不回放**）。
  Object? get commands => initAckList.length > 2 ? initAckList[2] : null;

  /// 服务端推送（`broadcast` 等，**无 ack**）。
  Stream<OfficeCollabEvent> get incoming => client.onEvent;

  /// `emit('event', frame)`：写 step 的**唯一**通道（批 2 真机确证）。
  Future<Object?> sendEvent(Map<String, Object?> frame) =>
      client.emit('event', frame);

  /// `emit('poll', {version})`：取服务端自 [version] 以来的远端增量。
  Future<Object?> poll(int version) =>
      client.emit('poll', <String, Object?>{'version': version});

  bool _closed = false;

  /// **幂等**关闭（页面 dispose 调它）。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await client.close();
  }

  @override
  String toString() =>
      'OfficeSlidesSession(identifier: $identifier, rev: $rev, '
      'hasDoc: ${fetchDoc != null})';
}

/// 页面依赖的外部世界（生产实现 = 既有 Office 数据层；测试 = 假实现）。
///
/// **没有新接口进 `lib/src/data/office_collab/**`**：会话直接复用 M0 的
/// [OfficeCollabClient]（connect / emit / close 都是既有方法）。
abstract class OfficeSlidesBackend {
  /// 用既有 Office 数据层读 `@C_text/*`（`Snapshot:get v4`）。
  Future<OfficeSlidesSnapshot> loadSnapshot();

  /// 读门控输入（`Permission:check` + `Info:get`）。
  Future<OfficeWriteGateInputs> loadGate();

  /// 建一个已 `init` 的协作会话。
  Future<OfficeSlidesSession> openSession();

  /// 关闭会话（页面 dispose 时调用）。
  Future<void> closeSession(OfficeSlidesSession session);
}

/// 读门控输入失败但拿不到 DSM 码时的占位（走 fail-open）。
const int kOfficeSlidesGateUnknownError = -1;

// ---------------------------------------------------------------------------
// 生产实现：既有 Office 数据层 + M0 客户端
// ---------------------------------------------------------------------------

class OfficeApiSlidesBackend implements OfficeSlidesBackend {
  OfficeApiSlidesBackend({
    required this.officeApi,
    required this.request,
    this.driveApi,
    this.clientId,
    this.clientFactory,
  });

  final OfficeApi officeApi;
  final OfficeSlidesRequest request;
  final DriveApi? driveApi;

  /// 与登录用户一致的 `clientId`（服务端会覆写 `uid`）。
  final String? clientId;

  /// 测试/高级用法：替换掉真实 socket 客户端。
  final OfficeCollabClient Function(OfficeCollabTarget target)? clientFactory;

  String? _objectId;
  String? _linkId;

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
  Future<OfficeSlidesSnapshot> loadSnapshot() async {
    final linkId = _linkId ??= await _resolveLinkId();
    if (linkId.isEmpty) {
      throw const OfficeSlidesLoadException(
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
      logOfficeErrorForDiagnostics('slides-snapshotCreate', error);
    }
    final data = await officeApi.snapshotGet(
      linkId: linkId,
      password: request.password,
    );
    final sections = officeSectionsFromSnapshot(
      data,
      format: OfficeNativeFormat.oslides,
    );
    // ★★ 第 314 轮：**把"服务端没给内容"与"给了内容却没认出来"分开**
    // （与 `office_doc_page.dart` 第 309 轮同一判据，此前只有 doc 页有）。
    //
    // 真机缺陷：本 App 新建的空白 `.oslides` 每次打开都记一条
    // `[office:slidesLoad:bad_content_shape]`（"形态对不上"），而真相是服务端
    // **连 `content` 键都没给**（官方 Web 逐字
    // `sourceInfo.content ? sourceInfo.content.data : preset` ⇒ 缺内容用预设空白
    // 演示文稿，**不报错**）。
    //
    // 判据看适配器的**返回值**（比自造启发式更硬）：
    //   * `sections == null` ⇒ 回包里连"像 section 字典"的东西都没有
    //     （`_looksLikeNativeSectionMap` 只认 `sh_*` / `style`+`define`；
    //      真机的 `content=Null` 就走这里）⇒ **空白演示文稿**；
    //   * `sections != null` 但 `sections['content'] == null` ⇒ 回包**是**一份
    //     section 字典、只是没有我们能解释的 `content` ⇒ **仍报坏形态**
    //     （不伪造空文档；既有用例正是在守这一半）。
    if (sections == null) {
      // 证据只进日志：把回包的**键形态**记下来（下次真机复查要靠它分辨
      // "服务端没内容" 与 "我们没认出来"）。
      logOfficeErrorForDiagnostics(
        'slidesLoad:blankFallback contentKeys=${data['content'] is Map ? (data['content'] as Map).keys.toList() : data['content'].runtimeType}',
        StateError('snapshot has no content'),
      );
      final blankSections = <String, Object?>{
        // 与官方 `getPresetJson()` 同义：**空内容**交给渲染层出空白页；
        // 这里不伪造任何幻灯片节点（不假装有内容）。
        'content': <String, Object?>{'data': null, 'version': 0},
      };
      if (data['comment'] != null) blankSections['comment'] = data['comment'];
      if (data['file'] != null) blankSections['file'] = data['file'];
      return OfficeSlidesSnapshot(
        sections: blankSections,
        version: 0,
        raw: data,
        objectId: '${data['object_id'] ?? ''}'.trim(),
      );
    }
    if (sections['content'] == null) {
      throw const OfficeSlidesLoadException(
        'bad_content_shape',
        'Snapshot:get 的内容树与 @C_text/content 形态对不上',
      );
    }
    // 真机 2 帧的 `data` 顶层还有 `comment` / `file` 两个 @C_text/* section
    // （`snap_probe_native_dynamic.oslides.json` / `snap_probe_exported.oslides.json`）。
    // 既有适配器只包 `content`，这里按**实测回包**把它们补进 section 字典，
    // 让"只登记不解释"的 section 在报告里可见（不静默丢）。
    final merged = <String, Object?>{...sections};
    if (!merged.containsKey('comment') && data['comment'] != null) {
      merged['comment'] = data['comment'];
    }
    if (!merged.containsKey('file') && data['file'] != null) {
      merged['file'] = data['file'];
    }
    final content = asJsonMap(merged['content']);
    return OfficeSlidesSnapshot(
      sections: merged,
      version: asJsonInt(content?['version']) ?? 0,
      raw: data,
      objectId: '${data['object_id'] ?? ''}'.trim(),
    );
  }

  @override
  Future<OfficeWriteGateInputs> loadGate() async {
    try {
      final objectId = await _resolveObjectId();
      final linkId = _linkId ??= await _resolveLinkId();
      var canWrite = false;
      var canComment = false;
      if (objectId != null && objectId.isNotEmpty && linkId.isNotEmpty) {
        // 与 `office_doc_page.dart` / `office_sheet_page.dart` 的 loadGate 同一形态
        // （真机探针 `docs/office-collab-protocol-spike.md` §2.5）。
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
      }
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
        loadError: kOfficeSlidesGateUnknownError,
      );
    }
  }

  @override
  Future<OfficeSlidesSession> openSession() async {
    final objectId = await _resolveObjectId();
    if (objectId == null || objectId.isEmpty) {
      throw const OfficeSlidesLoadException(
        'no_object_id',
        '拿不到 Office object_id（socket 需要它，permanent_link 会被拒）',
      );
    }
    final linkId = _linkId ??= await _resolveLinkId();
    if (linkId.isEmpty) {
      throw const OfficeSlidesLoadException('no_link_id', '拿不到 permanent_link');
    }
    // **不**显式传 namespace：沿用既有 `OfficeCollabTarget._deriveNamespace`
    // （object_id 后缀 `.slide → presentation`，M0 未连过，见 §⑨ 未验证项）。
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
    await client.connect();
    // **批 2 真机修正**：演示文稿用 `fetch`（`init` 无 ack，12s 超时）。
    final ack = await client.emit('fetch');
    final list = asJsonList(ack);
    final payload = (list != null && list.length > 1) ? asJsonMap(list[1]) : null;
    final doc = payload == null ? null : asJsonMap(payload['doc']);
    if (list == null || list.isEmpty || list[0] != null || doc == null) {
      // 形状对不上 → 明确失败（**不假装**会话建立）。
      throw OfficeSlidesLoadException(
        'bad_fetch_ack',
        'fetch 回包不是 [null,{doc:{…}}]：${ack is List ? 'list' : ack.runtimeType}',
      );
    }
    return OfficeSlidesSession(
      client: client,
      initAck: ack,
      fetchDoc: doc,
      fetchVersion: asJsonInt(doc['version']),
    );
  }

  @override
  Future<void> closeSession(OfficeSlidesSession session) => session.close();
}

/// 读取/会话建立失败（带一个稳定的 reason code，便于 UI 分类）。
class OfficeSlidesLoadException implements Exception {
  const OfficeSlidesLoadException(this.reason, this.message);

  final String reason;
  final String message;

  @override
  String toString() => 'OfficeSlidesLoadException($reason): $message';
}

/// 把 [OfficeSlidesSession] 的 `event`/`poll`/`incoming` 接到编辑层。
///
/// **没有新接口进 `lib/src/data/office_collab/**`**：`emit` 是 M0 既有方法。
class _SessionCommandSink implements OfficeSlidesCommandSink {
  _SessionCommandSink(this.session);

  final OfficeSlidesSession session;

  @override
  Future<Object?> sendEvent(Map<String, Object?> frame) =>
      session.sendEvent(frame);

  @override
  Future<Object?> poll(int version) => session.poll(version);

  @override
  Stream<OfficeCollabEvent> get incoming => session.incoming;
}

// ---------------------------------------------------------------------------
// 状态与控制器
// ---------------------------------------------------------------------------

enum OfficeSlidesPhase {
  loading,
  ready,

  /// 会话失效/超时（119/106）——与普通失败分开，文案不同且**不隐藏页面**。
  sessionExpired,

  failure,
}

class OfficeSlidesState {
  const OfficeSlidesState({
    required this.phase,
    required this.gate,
    this.snapshot,
    this.errorMessage,
    this.errorCode,
    this.sessionReady = false,
    this.sessionNote,
    this.sessionIdentifier,
    this.sessionRev = 0,
  });

  factory OfficeSlidesState.loading() =>
      OfficeSlidesState(phase: OfficeSlidesPhase.loading, gate: _pendingGate);

  final OfficeSlidesPhase phase;
  final OfficeWriteGateDecision gate;
  final OfficeSlidesSnapshot? snapshot;
  final String? errorMessage;
  final int? errorCode;

  final bool sessionReady;

  /// 会话建立失败时的如实说明（不静默）。
  final String? sessionNote;
  final String? sessionIdentifier;
  final int sessionRev;

  bool get isReady => phase == OfficeSlidesPhase.ready;

  OfficeSlidesState copyWith({
    OfficeSlidesPhase? phase,
    OfficeWriteGateDecision? gate,
    OfficeSlidesSnapshot? snapshot,
    ValueGetter<String?>? errorMessage,
    ValueGetter<int?>? errorCode,
    bool? sessionReady,
    ValueGetter<String?>? sessionNote,
    ValueGetter<String?>? sessionIdentifier,
    int? sessionRev,
  }) {
    return OfficeSlidesState(
      phase: phase ?? this.phase,
      gate: gate ?? this.gate,
      snapshot: snapshot ?? this.snapshot,
      errorMessage: errorMessage == null ? this.errorMessage : errorMessage(),
      errorCode: errorCode == null ? this.errorCode : errorCode(),
      sessionReady: sessionReady ?? this.sessionReady,
      sessionNote: sessionNote == null ? this.sessionNote : sessionNote(),
      sessionIdentifier: sessionIdentifier == null
          ? this.sessionIdentifier
          : sessionIdentifier(),
      sessionRev: sessionRev ?? this.sessionRev,
    );
  }
}

final OfficeWriteGateDecision _pendingGate = OfficeWriteGateDecision(
  OfficeWriteGateState.unknownFailOpen,
  reasonKey: 'officeDocGatePending',
  reasonText: dataText('officeDocGatePending', '正在确认写权限…（暂以只读方式打开）'),
);

/// 页面逻辑（可单测）：读 → 门控 → `init` 会话 → 渲染 → 关闭。
class OfficeSlidesController extends ChangeNotifier {
  OfficeSlidesController(this.backend);

  final OfficeSlidesBackend backend;

  OfficeSlidesState _state = OfficeSlidesState.loading();
  OfficeSlidesState get state => _state;

  OfficeSlidesSession? _session;
  OfficeSlidesSession? get session => _session;

  /// 批 2 编辑层（会话可用时才有；门控决定 `editable`）。
  OfficeSlidesEditController? _edit;
  OfficeSlidesEditController? get edit => _edit;

  bool _disposed = false;

  /// 渲染报告：页面与渲染器共用（未知项都进这里）。
  final OfficeSlidesRenderReport renderReport = OfficeSlidesRenderReport();

  void _set(OfficeSlidesState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  Future<void> load() async {
    _set(OfficeSlidesState.loading());

    // 1) 门控（失败不挡住页面：fail-open 由 gate 自己决定）。
    OfficeWriteGateDecision gate;
    try {
      gate = decideOfficeWriteGate(await backend.loadGate());
    } on Object catch (e) {
      gate = decideOfficeWriteGate(
        OfficeWriteGateInputs(
          canWrite: false,
          canComment: false,
          schemaMobile: 0,
          loadError: e is DsmApiException
              ? e.code
              : kOfficeSlidesGateUnknownError,
        ),
      );
    }

    // 2) 既有 Office 数据层的只读 section 字典。
    OfficeSlidesSnapshot snapshot;
    try {
      snapshot = await backend.loadSnapshot();
    } on Object catch (e) {
      final code = e is DsmApiException ? e.code : null;
      _set(
        OfficeSlidesState(
          phase: _isExpired(code)
              ? OfficeSlidesPhase.sessionExpired
              : OfficeSlidesPhase.failure,
          gate: gate,
          errorCode: code,
          errorMessage: _describeError(e),
        ),
      );
      return;
    }

    // 3) `fetch` 会话（失败不挡住只读渲染，但**不静默**）。
    String? sessionNote;
    var sessionReady = false;
    try {
      final session = await backend.openSession();
      _session = session;
      sessionReady = true;
      // step 列表**不回放**，但名字全部登记（认识的/不认识的）。
      scanOfficeSlidesCommands(
        session.commands,
        renderReport,
        source: 'Presentation.Snapshot:fetch（version ${session.rev}）',
      );
      // 编辑层的 base：优先 `fetch` 的权威文档树，回落 Snapshot 的 content.data
      // （两者都是 `{type,attrs,content}`，位置空间一致）。
      final base = session.docData ??
          asJsonMap(asJsonMap(snapshot.sections['content'])?['data']);
      if (base != null) {
        _edit?.dispose();
        _edit = OfficeSlidesEditController(
          sink: _SessionCommandSink(session),
          base: base,
          initialVersion: session.rev,
          clientId: 'dsh-slides-mobile',
        )..editable = gate.editable;
      }
    } on Object catch (e) {
      // ★ 闸门已判"只读打开"（gate.editable 为假）时，协作权限拒绝只是该结论的
      // 必然推论 —— 不再重复报成红色（见 `docs/office-readonly-banner-defect.md`）。
      // 闸门判定可写时不静音；只读时的其它协作故障也照常报错。
      if (officeSessionNoteRedundant(e, gateAllowsEditing: gate.editable)) {
        logOfficeErrorForDiagnostics('slides-session', e, StackTrace.current);
      } else {
        sessionNote = _fill(
          'officeSlidesSessionUnavailable',
          '协作会话未建立：{name}',
          <String, String>{'name': _describeError(e)},
        );
      }
    }

    _set(
      OfficeSlidesState(
        phase: OfficeSlidesPhase.ready,
        gate: gate,
        snapshot: snapshot,
        sessionReady: sessionReady,
        sessionNote: sessionNote,
        sessionIdentifier: _session?.identifier,
        sessionRev: _session?.rev ?? 0,
      ),
    );
  }

  /// 页面 dispose / 显式关闭。**幂等**。
  Future<void> closeSession() async {
    _edit?.dispose();
    _edit = null;
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
    if (error is OfficeSlidesLoadException) {
      // ★★ 第 308 轮：`message` 是实现者诊断串（含 `@C_text/*` 这类 section 名、且只有中文），
      // 在英文环境下会把中文顶到界面上（真机 LGE-AN10 实测）⇒ 原文只进日志，界面走本地化。
      logOfficeErrorForDiagnostics('slidesLoad:${error.reason}', error);
      return officeLoadFailureText(error.reason);
    }
    logOfficeErrorForDiagnostics('describeError', error);
    return officeUserFacingError(error);
  }

  @override
  void dispose() {
    _disposed = true;
    _edit?.dispose();
    _edit = null;
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// 页面
// ---------------------------------------------------------------------------

class OfficeSlidesPage extends ConsumerStatefulWidget {
  const OfficeSlidesPage({
    super.key,
    required this.request,
    this.backend,
    this.onFallbackToNativePreview,
    this.deckLoader,
  });

  final OfficeSlidesRequest request;

  /// 测试注入；为 null 时用既有 Office 数据层装配。
  final OfficeSlidesBackend? backend;

  /// **PPTX 显示数据源的注入点**：生产用 [loadOfficeSlidesDeck]（Drive 下载直链），
  /// 测试直接给一份用真实样本字节解析出来的 [OSlidesDeck]。返回 null = 回落
  /// 既有 OFile 文本渲染（页面上会有一行用户语言的说明）。
  final Future<OSlidesDeck?> Function()? deckLoader;

  /// 只读失败时可选的回退入口（接到既有原生只读预览）。
  final VoidCallback? onFallbackToNativePreview;

  @override
  ConsumerState<OfficeSlidesPage> createState() => _OfficeSlidesPageState();
}

class _OfficeSlidesPageState extends ConsumerState<OfficeSlidesPage> {
  late final OfficeSlidesController _controller;

  /// 真实 PPTX 解析结果（null = 没读到，回落文本渲染）。
  OSlidesDeck? _deck;

  /// 是否已经问过 PPTX 数据源（用来决定要不要显示"版式没读到"的说明）。
  bool _deckTried = false;

  /// 画布重读次数（诊断 + "写完重读"的机制量）。
  int _deckLoads = 0;

  @override
  void initState() {
    super.initState();
    trackView(UsageModule.office, screen: 'slides_reader');
    _controller = OfficeSlidesController(widget.backend ?? _buildBackend());
    unawaited(_controller.load());
    unawaited(_loadDeck());
  }

  /// 读真实 PPTX（与 OFile 读取**并行**，互不阻塞）。
  Future<void> _loadDeck() async {
    OSlidesDeck? deck;
    try {
      deck = await (widget.deckLoader ?? _defaultDeckLoader)();
    } on Object {
      deck = null;
    }
    if (!mounted) return;
    // 诊断：把"重读了几次、这次读到多少页"记下来 —— 真机上"写了看不见"要靠它
    // 分辨"没重读"与"服务端还没导出新版 PPTX"（第 314 轮）。
    debugPrint(
      '[office:slides-deck] load#${++_deckLoads} pages=${deck?.slides.length ?? 0} '
      '${deck == null ? '(null: 回落 OFile 渲染)' : ''}',
    );
    setState(() {
      _deck = deck;
      _deckTried = true;
    });
  }

  Future<OSlidesDeck?> _defaultDeckLoader() async {
    final drive = ref.read(driveApiProvider);
    if (drive == null) return null;
    return loadOfficeSlidesDeck(drive: drive, fileId: widget.request.fileId);
  }

  OfficeSlidesBackend _buildBackend() {
    final officeApi = ref.read(officeApiProvider);
    if (officeApi == null) {
      return _DisconnectedBackend();
    }
    return OfficeApiSlidesBackend(
      officeApi: officeApi,
      request: widget.request,
      driveApi: ref.read(driveApiProvider),
    );
  }

  @override
  void dispose() {
    // 契约：页面 dispose 时关闭会话（幂等）。
    unawaited(_controller.closeSession());
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final edit = _controller.edit;
        if (edit == null) return _scaffold(context);
        // 编辑层自己的变更（乐观显示 / 未确认数 / 失败）也要重建。
        return ListenableBuilder(
          listenable: edit,
          builder: (context, _) => _scaffold(context),
        );
      },
    );
  }

  Widget _scaffold(BuildContext context) {
    final state = _controller.state;
    return Scaffold(
      key: const Key('office-slides-page'),
      appBar: AppBar(
        title: Text(
          widget.request.name.isEmpty
              ? _t('officeSlidesTitle', '演示文稿')
              : widget.request.name,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          // 写权限门控：无权限 / schema 太旧 → **隐藏**入口；
          // 119/106 / 认不出 → 保留入口并给原因。本批入口**不可点**（只读批）。
          if (state.isReady && state.gate.showEditorEntry)
            _editEntry(context, state),
        ],
      ),
      body: _body(context, state),
    );
  }

  /// 编辑入口：门控 + **会话就绪** + 编辑层存在时才可点（批 2 起是真实编辑）。
  ///
  /// 门控语义与 `.odoc` / `.osheet` 完全一致（复用同一个决定对象）：
  /// `105/160` 或权限位全假 → 隐藏入口；`schema_mobile < 2000` → 隐藏入口；
  /// `119/106` → 保留入口 + 重登提示；认不出 → fail-open 显示入口。
  /// 会话没建起来（拿不到 `fetch` 文档）→ 入口保留但**不可点**（只读）。
  Widget _editEntry(BuildContext context, OfficeSlidesState state) {
    final edit = _controller.edit;
    final enabled =
        state.gate.editable && state.sessionReady && edit != null;
    return IconButton(
      key: const Key('office-slides-edit-entry'),
      tooltip: state.gate.reasonText ??
          (edit == null
              ? _t('officeSlidesEditNoSession', '协作会话未建立，当前只读。')
              : _t('officeSlidesEditHint', '点按幻灯片里的文字即可编辑（改动会即时同步）。')),
      icon: Icon(enabled ? Icons.edit_outlined : Icons.edit_off_outlined),
      onPressed: enabled ? () => unawaited(_showEditSheet(context)) : null,
    );
  }

  /// 编辑面板：列出全部可编辑文本块（点一条 → 对话框改文本）。
  Future<void> _showEditSheet(BuildContext context) async {
    final edit = _controller.edit;
    if (edit == null) return;
    final blocks = edit.blocks.where((b) => b.editable).toList();
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          key: const Key('office-slides-edit-sheet'),
          shrinkWrap: true,
          children: [
            if (blocks.isEmpty)
              DesignRowTile(
                key: const Key('office-slides-edit-empty'),
                title: Text(
                  _t('officeSlidesEditNoBlocks', '这份演示文稿里没有可编辑的文本'),
                ),
              )
            else
              for (final block in blocks)
                DesignRowTile(
                  key: Key('office-slides-edit-block-${block.id}'),
                  title: Text(
                    block.text.isEmpty
                        ? _t('officeSlidesEditEmptyBlock', '（空文本块）')
                        : block.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    _fill(
                      'officeSlidesSlidePage',
                      '第 {index} 页',
                      <String, String>{'index': '${block.slideOrder + 1}'},
                    ),
                  ),
                  trailing: edit.isPendingBlock(block.id)
                      ? const Icon(Icons.cloud_upload_outlined)
                      : null,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_editBlockDialog(context, block));
                  },
                ),
          ],
        ),
      ),
    );
  }

  /// 编辑单块文本的对话框（乐观显示 + 未确认由编辑层统一负责）。
  Future<void> _editBlockDialog(
    BuildContext context,
    OfficeSlidesEditableBlock block,
  ) async {
    final edit = _controller.edit;
    if (edit == null || !edit.canEdit) return;
    final field = TextEditingController(
      text: edit.optimisticText(block.id) ?? block.text,
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('office-slides-edit-dialog'),
        title: Text(
          _fill(
            'officeSlidesSlidePage',
            '第 {index} 页',
            <String, String>{'index': '${block.slideOrder + 1}'},
          ),
        ),
        content: TextField(
          key: const Key('office-slides-edit-field'),
          controller: field,
          autofocus: true,
          maxLines: null,
          decoration: InputDecoration(
            hintText: _t('officeSlidesEditHintShort', '输入文本'),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('office-slides-edit-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(_t('officeSlidesEditCancel', '取消')),
          ),
          FilledButton(
            key: const Key('office-slides-edit-save'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(_t('officeSlidesEditSave', '保存')),
          ),
        ],
      ),
    );
    if (saved == true) {
      await edit.editBlockText(block.id, field.text);
      // ★★ 第 314 轮真机缺陷（已修）：写成功**必须重读画布**。
      // 真机取证：编辑 `Countrysider314tpl.oslides` 的标题块为 `Slide314` 后
      // 会话回 "All changes confirmed"、**离开重进**文本块列表已变成
      // `Slide314 | Slide 1`（服务端确实落盘），但**画布上一直看不到这几个字**
      // —— 因为画布优先渲染的是 `_deck`（PPTX 通道，`_body()` 里
      // `if (_deck != null)`），它只在 `initState` 拉过一次。用户的心智是
      // "我写了 → 应该看见"，所以写完立刻重拉一次。
      // ⚠️ 如实登记：服务端**导出 PPTX** 可能比 Office 原生写入慢，
      // 所以画布仍可能短暂是旧的（此时以"文本块列表"为准，见
      // `docs/evidence-r314/README.md`）。
      await _loadDeck();
    }
  }

  Widget _body(BuildContext context, OfficeSlidesState state) {
    // ⭐ 拿到真实 PPTX 时**优先**渲染真实幻灯片（不受 OFile/会话状态影响）：
    // 这才是用户要看的"演示文稿"，会话/门控问题不该挡住显示。
    if (_deck != null) return _readyBody(context, state);
    switch (state.phase) {
      case OfficeSlidesPhase.loading:
        return Center(
          key: const Key('office-slides-loading'),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: Gap.md),
              Text(_t('officeSlidesLoading', '正在读取演示文稿…')),
            ],
          ),
        );
      case OfficeSlidesPhase.sessionExpired:
        return _StatusPane(
          key: const Key('office-slides-session-expired'),
          icon: Icons.lock_clock,
          title: _t('officeSlidesSessionExpired', '登录会话已失效'),
          body: state.errorMessage ?? '',
          primaryLabel: _t('officeSlidesRetry', '重试'),
          onPrimary: () => unawaited(_controller.load()),
          secondaryLabel: widget.onFallbackToNativePreview == null
              ? null
              : _t('officeSlidesFallbackPlain', '用文字方式打开'),
          onSecondary: widget.onFallbackToNativePreview,
        );
      case OfficeSlidesPhase.failure:
        return _StatusPane(
          key: const Key('office-slides-failure'),
          icon: Icons.error_outline,
          title: _t('officeSlidesLoadFailed', '打开失败'),
          body: state.errorMessage ?? '',
          primaryLabel: _t('officeSlidesRetry', '重试'),
          onPrimary: () => unawaited(_controller.load()),
          secondaryLabel: widget.onFallbackToNativePreview == null
              ? null
              : _t('officeSlidesFallbackPlain', '用文字方式打开'),
          onSecondary: widget.onFallbackToNativePreview,
        );
      case OfficeSlidesPhase.ready:
        return _readyBody(context, state);
    }
  }

  Widget _readyBody(BuildContext context, OfficeSlidesState state) {
    final sections = state.snapshot?.sections;
    final edit = _controller.edit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _gateBanner(context, state),
        if (state.sessionNote != null)
          _sessionNote(context, state.sessionNote!),
        if (edit != null) _pendingBanner(context, edit),
        if (edit != null && edit.failures.isNotEmpty)
          _failureBanner(context, edit),
        const Divider(height: 1),
        Expanded(child: _content(context, state, sections, edit)),
      ],
    );
  }

  /// 正文：真实 PPTX 画布优先；没读到就回落既有文本渲染（并说明原因）。
  Widget _content(
    BuildContext context,
    OfficeSlidesState state,
    Map<String, Object?>? sections,
    dynamic edit,
  ) {
    final deck = _deck;
    if (deck != null) {
      return OfficeSlidesDeckView(deck: deck);
    }
    if (sections == null) {
      return Center(
        key: const Key('office-slides-no-content'),
        child: Text(_t('officeSlidesNoContent', '没有可显示的演示文稿内容')),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 只在**真的**没读到版式时出现一次，且是用户语言（不是工程措辞）。
        if (_deckTried) _fallbackNote(context),
        Expanded(
          child: OfficeSlidesView(
            sections: sections,
            // 回落视图不再显示"只读渲染 · 版式 N 个 · 图片 N 张"这种工程摘要。
            showHeaderNote: false,
            report: _controller.renderReport,
            edit: edit,
            onEditBlock: (block) =>
                unawaited(_editBlockDialog(context, block)),
            objectId: state.snapshot?.objectId ?? '',
            imageBytesProvider: _imageBytesProvider,
            imageCache: officeDocImageCache,
          ),
        ),
      ],
    );
  }

  /// 版式没读到时的**一次性**说明（不常驻横幅、无"本批/从简"字样）。
  Widget _fallbackNote(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('office-slides-deck-fallback-note'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      child: Text(
        _t(
          'officeSlidesDeckFallbackNote',
          '这份演示文稿的版式没有读到，下面按文字内容显示。',
        ),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 图片字节提供者：把 `OfficeApi.attachmentGet`（`Attachment:get v2`）接给
  /// 批 A 的 `OfficeDocImage`。未连接时为 null → 图片显示"加载失败 + 重试"，
  /// **绝不上屏 `file_id`/`ref`/路径**（用户最初投诉的正是这一点）。
  OfficeAttachmentBytesProvider? get _imageBytesProvider {
    final officeApi = ref.read(officeApiProvider);
    if (officeApi == null) return null;
    return ({required String objectId, required String fileId}) =>
        officeApi.attachmentGet(objectId: objectId, fileId: fileId);
  }

  /// **常显**未确认计数（`count == 0` 也渲染：所有改动已确认）。
  Widget _pendingBanner(BuildContext context, OfficeSlidesEditController edit) {
    final theme = Theme.of(context);
    final hasError = edit.sendError != null;
    return Container(
      key: const Key('office-slides-pending'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Icon(
            edit.pendingCount == 0
                ? Icons.cloud_done_outlined
                : Icons.cloud_upload_outlined,
            size: 16,
          ),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Text(
              edit.pendingCount == 0
                  ? _t('officeSlidesPendingNone', '所有改动已确认')
                  : _fill(
                      'officeSlidesPendingCount',
                      '待确认改动：{count} 项（{blocks} 段）',
                      <String, String>{
                        'count': '${edit.pendingCount}',
                        'blocks': '${edit.pendingBlockCount}',
                      },
                    ),
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (hasError)
            TextButton(
              key: const Key('office-slides-pending-retry'),
              onPressed: () => unawaited(edit.retryPending()),
              child: Text(_t('officeSlidesEditRetry', '重试')),
            ),
        ],
      ),
    );
  }

  /// 失败横幅：点名**哪一段、为什么**没生效。
  Widget _failureBanner(
    BuildContext context,
    OfficeSlidesEditController edit,
  ) {
    final failure = edit.failures.last;
    final theme = Theme.of(context);
    final reason = switch (failure.kind) {
      OfficeSlidesEditFailureKind.rejected =>
        _t('officeSlidesEditReasonRejected', '服务端拒绝了这次改动（status 411）'),
      OfficeSlidesEditFailureKind.staleBlocked => _fill(
          'officeSlidesEditReasonStale',
          '服务端版本一直过期，已重放 {count} 次',
          <String, String>{'count': '${failure.attempts}'},
        ),
      OfficeSlidesEditFailureKind.historyNotAvail => _fill(
          'officeSlidesEditReasonHistory',
          '拉取远端增量失败：{detail}',
          <String, String>{'detail': failure.detail},
        ),
      OfficeSlidesEditFailureKind.transport => _fill(
          'officeSlidesEditReasonTransport',
          '发送失败：{detail}',
          <String, String>{'detail': failure.detail},
        ),
      OfficeSlidesEditFailureKind.malformedAck => _fill(
          'officeSlidesEditReasonUnknown',
          '无法确认服务端结果：{detail}',
          <String, String>{'detail': failure.detail},
        ),
    };
    return Container(
      key: const Key('office-slides-edit-failure'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      color: theme.colorScheme.errorContainer,
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 16),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Text(
              _fill(
                'officeSlidesEditFailedBlock',
                '「{block}」的改动未生效：{reason}',
                <String, String>{
                  'block': failure.label,
                  'reason': reason,
                },
              ),
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  /// 门控原因**永远可见**（"不满足 → 只读 + 明确原因"，不是隐藏整个页面）。
  Widget _gateBanner(BuildContext context, OfficeSlidesState state) {
    final reason = state.gate.reasonText;
    if (reason == null) return const SizedBox.shrink();
    return Container(
      key: const Key('office-slides-gate-banner'),
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
        ],
      ),
    );
  }

  Widget _sessionNote(BuildContext context, String note) {
    return Container(
      key: const Key('office-slides-session-note'),
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
                  style: InlineButtonStyle.filled,onPressed: onPrimary, child: Text(primaryLabel)),
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
class _DisconnectedBackend implements OfficeSlidesBackend {
  @override
  Future<OfficeSlidesSnapshot> loadSnapshot() async =>
      throw const OfficeSlidesLoadException(
        'not_connected',
        '未连接 DSM 或 Office 套件不可用',
      );

  @override
  Future<OfficeWriteGateInputs> loadGate() async => const OfficeWriteGateInputs(
    canWrite: false,
    canComment: false,
    schemaMobile: 0,
    loadError: kOfficeSlidesGateUnknownError,
  );

  @override
  Future<OfficeSlidesSession> openSession() async =>
      throw const OfficeSlidesLoadException('not_connected', '未连接 DSM');

  @override
  Future<void> closeSession(OfficeSlidesSession session) async {}
}
