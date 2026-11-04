// Office C′ 表格（Sheet）批 1 —— `.osheet` 打开生命周期 + 写权限门控。
//
// 本批**只读**：页面的任务是把既有 Office 数据层的 section 字典交给
// `office_sheet_view.dart` 渲染，并按既有门控（`office_write_gate.dart`）决定
// "编辑入口是否显示"（本批只做占位，**没有编辑交互**）。
//
// 数据链路（**复用既有接口，没有发明新的 Office 数据层**）：
//
//   Drive/FileStation 条目（先过既有加密门 `drive_encrypt_gate.dart`）
//     └─ drive_open_entry.dart 的 `.osheet` 分流
//          └─ OfficeSheetPage
//               ├─ OfficeApiSheetBackend.loadSnapshot()
//               │     officeApi.snapshotGet(linkId)            （既有 v4 只读通道）
//               │     officeSectionsFromSnapshot(..., osheet)  （既有适配器）
//               │     → {index, style, sh_N, …}
//               ├─ OfficeApiSheetBackend.loadGate()
//               │     Permission:check v1 + Info:get v1 → decideOfficeWriteGate
//               └─ OfficeApiSheetBackend.openSession()
//                     OfficeCollabClient(M0) connect → emit('init')
//                     ack = [identifier, rev, commands[]]（server/sheet/core/client.js
//                     的 `_onInit` 原文）
//    dispose ─ session.close() → client.close()（幂等）
//
// `init` ack 的 `commands[]` **不回放**（基础模型从 index + sh_N 重建，
// `office-collab-schema-export.md` §C.1），但命令名会被 `scanOfficeSheetCommands`
// 全部登记：认识的进 `seenCommands`，不认识的进 `unknownCommands`（可见降级）。
//
// 三态：`loading / ready / sessionExpired / failure`；会话建立失败**不挡住只读
// 渲染**，但一定有 `sessionNote`（不静默）。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/drive_api.dart' show DriveApi;
import '../../data/office_api.dart';
import '../../data/office_collab/office_collab_client.dart';
import '../../data/office_native/office_json.dart';
import '../../data/office_native/office_native_reader.dart'
    show OfficeNativeFormat;
import '../../dsm/webapi.dart' show DsmApiException, DsmErrorCode;
import '../files/drive_providers.dart' show driveApiProvider;
import '../files/office_providers.dart' show officeApiProvider;
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'office_sheet_edit.dart';
import 'office_sheet_view.dart';
import 'office_sheet_xlsx.dart';
import 'office_write_gate.dart';
import 'office_error_text.dart';
import '../../core/theme/app_theme.dart';

String _t(String key, String zh) => dataText(key, zh);

String _fill(String key, String zh, Map<String, String> values) =>
    officeSheetFill(key, zh, values);

/// 打开一个 `.osheet` 需要的最小信息（从 Drive/FileStation 入口传入）。
class OfficeSheetRequest {
  const OfficeSheetRequest({
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
      'OfficeSheetRequest(fileId: $fileId, name: $name, '
      'hasLink: ${permanentLink.isNotEmpty})';
}

/// 一次只读读取的结果：`@C_text/*` 的 section 字典 + `index.ver`。
class OfficeSheetSnapshot {
  const OfficeSheetSnapshot({
    required this.sections,
    required this.version,
    required this.raw,
  });

  final Map<String, Object?> sections;

  /// `index.ver`（§C.3：`index` 每次快照 `S.index.ver += 1`）。
  final int version;

  /// `Snapshot:get` 的原始回包（诊断用）。
  final Map<String, dynamic> raw;

  @override
  String toString() =>
      'OfficeSheetSnapshot(version: $version, sections: ${sections.keys.toList()})';
}

/// 已建立的 `Sheet.Snapshot:init` 会话（M0 client + init ack）。
///
/// 批 2 起它同时是编辑层的**发送通道**（[OfficeSheetCommandSink]）：
/// `emit('set', …)` 已由 M0 客户端路由 ack，`onEvent` 就是 `set`/`peer` 广播。
class OfficeSheetSession implements OfficeSheetCommandSink {
  OfficeSheetSession({required this.client, required this.initAck});

  final OfficeCollabClient client;

  /// `init` ack 原文：`[identifier, rev, commands[]]`。
  final Object? initAck;

  List<Object?> get initAckList => asJsonList(initAck) ?? const <Object?>[];

  /// 会话 identifier（`init` ack 第 0 项）。
  String get identifier {
    final v = initAckList.isEmpty ? null : initAckList[0];
    return v == null ? '' : '$v';
  }

  /// 当前 rev（`init` ack 第 1 项）。
  int get rev {
    final v = initAckList.length > 1 ? asJsonInt(initAckList[1]) : null;
    return v ?? 0;
  }

  /// 自上次快照以来的增量命令（`init` ack 第 2 项；**本批不回放**）。
  Object? get commands => initAckList.length > 2 ? initAckList[2] : null;

  /// 编辑层发送一条 `set`（`value` 命令）；ack 由 M0 客户端路由回来。
  @override
  Future<Object?> sendSet(Map<String, Object?> payload) =>
      client.emit('set', payload);

  /// 服务端推送（`set` / `peer` 广播，**无 ack**）。
  @override
  Stream<OfficeCollabEvent> get incoming => client.onEvent;

  bool _closed = false;

  /// **幂等**关闭（页面 dispose 调它）。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await client.close();
  }

  @override
  String toString() =>
      'OfficeSheetSession(identifier: $identifier, rev: $rev, '
      'commands: ${asJsonList(commands)?.length ?? 0})';
}

/// 页面依赖的外部世界（生产实现 = 既有 Office 数据层；测试 = 假实现）。
///
/// **没有新接口进 `lib/src/data/office_collab/**`**：会话直接复用 M0 的
/// [OfficeCollabClient]（connect / emit / close 都是既有方法）。
abstract class OfficeSheetBackend {
  /// 用既有 Office 数据层读 `@C_text/*`（`Snapshot:get v4`）。
  Future<OfficeSheetSnapshot> loadSnapshot();

  /// 读门控输入（`Permission:check` + `Info:get`）。
  Future<OfficeWriteGateInputs> loadGate();

  /// 建一个已 `init` 的协作会话。
  Future<OfficeSheetSession> openSession();

  /// 关闭会话（页面 dispose 时调用）。
  Future<void> closeSession(OfficeSheetSession session);
}

/// **可选能力**：能拿到服务端转码出来的 OOXML(XLSX) 字节的后端。
///
/// 刻意**不并入** [OfficeSheetBackend]：并入会让既有假实现（测试/无 Drive 的
/// 场景）必须实现新方法。页面用 `backend is OfficeSheetOoxmlSource` 做能力探测。
abstract class OfficeSheetOoxmlSource {
  /// 拿不到 / 不是 OOXML 时返回 `null`（页面回落到 OFile 兼容通道）。
  Future<Uint8List?> loadOoxml();
}

/// 读门控输入但拿不到 DSM 码时的占位（走 fail-open）。
const int kOfficeSheetGateUnknownError = -1;

// ---------------------------------------------------------------------------
// 生产实现：既有 Office 数据层 + M0 客户端
// ---------------------------------------------------------------------------

class OfficeApiSheetBackend implements OfficeSheetBackend, OfficeSheetOoxmlSource {
  OfficeApiSheetBackend({
    required this.officeApi,
    required this.request,
    this.driveApi,
    this.clientId,
    this.clientFactory,
  });

  final OfficeApi officeApi;
  final OfficeSheetRequest request;
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

  /// 只露"够对账"的头尾（诊断用；不打印整串）。
  static String _shapeOf(String id) {
    final dot = id.lastIndexOf('.');
    final tail = dot == -1 ? '' : id.substring(dot);
    final head = id.length > 8 ? id.substring(0, 8) : id;
    return '$head…${id.length}${tail.isEmpty ? '' : '…$tail'}';
  }


  @override
  Future<OfficeSheetSnapshot> loadSnapshot() async {
    final linkId = _linkId ??= await _resolveLinkId();
    if (linkId.isEmpty) {
      throw const OfficeSheetLoadException(
        'no_link_id',
        '这个文件没有 permanent_link，取不到 @C_text/* section',
      );
    }
    // ★★ 第 66 轮 D58：**带上密码** —— `Snapshot/get` 是"取已解密内容"
    // 的通道（官方 `setAsGet(linkId, password)`，总是发）。
    // 未加密时 `request.password` 是空串，与官方一致。
    final data = await officeApi.snapshotGet(
      linkId: linkId,
      password: request.password,
    );
    final sections = officeSectionsFromSnapshot(
      data,
      format: OfficeNativeFormat.osheet,
    );
    if (sections == null) {
      throw const OfficeSheetLoadException(
        'bad_sheet_shape',
        'Snapshot:get 的内容树与 @C_text/index + sh_N 形态对不上',
      );
    }
    final index = asJsonMap(sections['index']);
    return OfficeSheetSnapshot(
      sections: sections,
      version: asJsonInt(index?['ver']) ?? 0,
      raw: data,
    );
  }

  /// **OOXML 主通道**：`SYNO.SynologyDrive.Files:download`（只读，无任何
  /// mutating 动词）对 `.osheet` 回的是**标准 XLSX**（真机取证
  /// `docs/ooxml-ground-truth.md`）。这里只做"取字节 + 校验 ZIP 头"，
  /// 不符合就返回 `null`，由页面回落到 `Snapshot:get` 的 OFile 通道。
  @override
  Future<Uint8List?> loadOoxml() async {
    final drive = driveApi;
    final fileId = request.fileId.trim();
    if (drive == null || fileId.isEmpty) return null;
    try {
      final url = drive.downloadUrl(fileId: fileId);
      if (url.trim().isEmpty) return null;
      final bytes = await officeApi.api.getBytes(url);
      if (bytes.length < 4) return null;
      final data = Uint8List.fromList(bytes);
      if (!isOfficeSheetOoxmlBytes(data)) {
        // File Station 的 `home/Drive/...` 路径回的是原生 OFile(BSON)，
        // 那种字节交给 XLSX 解析器只会崩 —— 明确拒绝并回落。
        return null;
      }
      return data;
    } on Object {
      return null;
    }
  }

  @override
  Future<OfficeWriteGateInputs> loadGate() async {
    try {
      final objectId = await _resolveObjectId();
      final linkId = _linkId ??= await _resolveLinkId();
      var canWrite = false;
      var canComment = false;
      Map<String, dynamic>? perm;
      if (objectId != null && objectId.isNotEmpty && linkId.isNotEmpty) {
        // 与 `office_doc_page.dart` 的 loadGate 同一形态（真机探针
        // `docs/office-collab-protocol-spike.md` §2.5）。
        perm = await officeApi.api.call(
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
      // ★ 第 314 轮：与 `office_doc_page.dart` 同一形态的诊断。
      // 真机缺口：**成熟表格**（`Sales tracker.osheet`，09-21 有图有表）也报
      // "No write/comment permission" ⇒ 必须先看清"发出去的 id 长什么样、
      // 服务端回了什么"，再决定是"id 形态错"还是"真被拒"。
      debugPrint(
        '[office:sheet-gate] perm=${perm ?? '(skipped)'} '
        'object=${objectId == null || objectId.isEmpty ? 'empty' : _shapeOf(objectId)} '
        'link=${linkId.isEmpty ? 'empty' : _shapeOf(linkId)} '
        // ★ r314：把**发出去的** ntype 打出来（旧代码发的是原始后缀 `sh`，
        // 而官方取值是 `sheet` —— 正是这条缺陷的关键读数）。
        'ntype=${objectId == null || objectId.isEmpty ? '-' : officePermissionNtype(objectId)}',
      );
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
        loadError: kOfficeSheetGateUnknownError,
      );
    }
  }

  @override
  Future<OfficeSheetSession> openSession() async {
    final objectId = await _resolveObjectId();
    if (objectId == null || objectId.isEmpty) {
      throw const OfficeSheetLoadException(
        'no_object_id',
        '拿不到 Office object_id（socket 需要它，permanent_link 会被拒）',
      );
    }
    final linkId = _linkId ??= await _resolveLinkId();
    if (linkId.isEmpty) {
      throw const OfficeSheetLoadException('no_link_id', '拿不到 permanent_link');
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
    await client.connect();
    // `Sheet.Snapshot:init`：ack = [identifier, rev, commands[]]
    // （`server/sheet/core/client.js :: _onInit` 原文）。
    final ack = await client.emit('init');
    return OfficeSheetSession(client: client, initAck: ack);
  }

  @override
  Future<void> closeSession(OfficeSheetSession session) => session.close();
}

/// 读取/会话建立失败（带一个稳定的 reason code，便于 UI 分类）。
class OfficeSheetLoadException implements Exception {
  const OfficeSheetLoadException(this.reason, this.message);

  final String reason;
  final String message;

  @override
  String toString() => 'OfficeSheetLoadException($reason): $message';
}

// ---------------------------------------------------------------------------
// 状态与控制器
// ---------------------------------------------------------------------------

enum OfficeSheetPhase {
  loading,
  ready,

  /// 会话失效/超时（119/106）——与普通失败分开，文案不同且**不隐藏页面**。
  sessionExpired,

  failure,
}

class OfficeSheetState {
  const OfficeSheetState({
    required this.phase,
    required this.gate,
    this.snapshot,
    this.errorMessage,
    this.errorCode,
    this.sessionReady = false,
    this.sessionNote,
    this.sessionIdentifier,
    this.sessionRev = 0,
    this.editable = false,
    this.ooxmlBytes,
  });

  factory OfficeSheetState.loading() =>
      OfficeSheetState(phase: OfficeSheetPhase.loading, gate: _pendingGate);

  final OfficeSheetPhase phase;
  final OfficeWriteGateDecision gate;
  final OfficeSheetSnapshot? snapshot;

  /// **主通道**字节（OOXML/XLSX）。null = 只有 OFile 兼容通道可用。
  final Uint8List? ooxmlBytes;

  final String? errorMessage;
  final int? errorCode;

  final bool sessionReady;

  /// 会话建立失败时的如实说明（不静默）。
  final String? sessionNote;
  final String? sessionIdentifier;
  final int sessionRev;

  bool get isReady => phase == OfficeSheetPhase.ready;

  /// 批 2：门控允许 **且** 协作会话已建立（编辑命令要有通道）才可编辑。
  final bool editable;

  OfficeSheetState copyWith({
    OfficeSheetPhase? phase,
    OfficeWriteGateDecision? gate,
    OfficeSheetSnapshot? snapshot,
    ValueGetter<String?>? errorMessage,
    ValueGetter<int?>? errorCode,
    bool? sessionReady,
    ValueGetter<String?>? sessionNote,
    ValueGetter<String?>? sessionIdentifier,
    int? sessionRev,
    bool? editable,
    ValueGetter<Uint8List?>? ooxmlBytes,
  }) {
    return OfficeSheetState(
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
      editable: editable ?? this.editable,
      ooxmlBytes: ooxmlBytes == null ? this.ooxmlBytes : ooxmlBytes(),
    );
  }
}

final OfficeWriteGateDecision _pendingGate = OfficeWriteGateDecision(
  OfficeWriteGateState.unknownFailOpen,
  reasonKey: 'officeDocGatePending',
  reasonText: dataText('officeDocGatePending', '正在确认写权限…（暂以只读方式打开）'),
);

/// 页面逻辑（可单测）：读 → 门控 → `init` 会话 → 渲染 → 关闭。
class OfficeSheetController extends ChangeNotifier {
  OfficeSheetController(this.backend);

  final OfficeSheetBackend backend;

  OfficeSheetState _state = OfficeSheetState.loading();
  OfficeSheetState get state => _state;

  OfficeSheetSession? _session;
  OfficeSheetSession? get session => _session;

  /// 批 2 编辑层（会话建立后才有；只读渲染/失败态恒 null）。
  OfficeSheetEditController? _edit;
  OfficeSheetEditController? get edit => _edit;

  bool _disposed = false;

  /// 渲染报告：页面的降级/未渲染项都进这里（与 `.odoc` 批同构）。
  final OfficeSheetRenderReport renderReport = OfficeSheetRenderReport();

  void _set(OfficeSheetState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  Future<void> load() async {
    _set(OfficeSheetState.loading());

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
              : kOfficeSheetGateUnknownError,
        ),
      );
    }

    // 2) 既有 Office 数据层的只读 section 字典。
    OfficeSheetSnapshot snapshot;
    try {
      snapshot = await backend.loadSnapshot();
    } on Object catch (e) {
      final code = e is DsmApiException ? e.code : null;
      _set(
        OfficeSheetState(
          phase: _isExpired(code)
              ? OfficeSheetPhase.sessionExpired
              : OfficeSheetPhase.failure,
          gate: gate,
          errorCode: code,
          errorMessage: _describeError(e),
        ),
      );
      return;
    }

    // 2.5) **OOXML 主通道**（可选能力）：拿到 ZIP 头正确的 XLSX 字节就走它。
    //      失败/能力缺失**不报错**，只是回落 —— 页面会用用户语言说明。
    Uint8List? ooxmlBytes;
    final source = backend is OfficeSheetOoxmlSource
        ? backend as OfficeSheetOoxmlSource
        : null;
    if (source != null) {
      try {
        ooxmlBytes = await source.loadOoxml();
      } on Object catch (e) {
        renderReport.note('OOXML 字节获取失败 → 回落 OFile 兼容通道：$e');
        ooxmlBytes = null;
      }
      if (ooxmlBytes == null) {
        renderReport.note('未取到 OOXML(XLSX) 字节 → 回落 OFile 兼容通道');
        // **空字节 ≠ 没试过**：这里显式告诉视图"主通道试过了但拿不到"，
        // 视图据此给出用户语言说明（不得静默空白）。`null` 仍表示"没走主通道"。
        ooxmlBytes = Uint8List(0);
      }
    }

    // 3) `Sheet.Snapshot:init` 会话（失败不挡住只读渲染，但**不静默**）。
    String? sessionNote;
    var sessionReady = false;
    try {
      final session = await backend.openSession();
      _session = session;
      sessionReady = true;
      // `init` ack 的 commands[] **不回放**，但命令名全部登记（认识的/不认识的）。
      scanOfficeSheetCommands(
        session.commands,
        renderReport,
        source: 'Sheet.Snapshot:init（rev ${session.rev}）',
      );
      // 批 2：会话即编辑层的发送通道；`changes` 的 base 从 section 网格读。
      // **门控是唯一闸门**：`gate.editable` 为假时编辑层恒只读。
      final sheetId = officeSheetDefaultSheetId(snapshot.sections);
      final edit = OfficeSheetEditController(
        sink: session,
        base: officeSheetBaseCells(snapshot.sections, sheetId),
        initialRev: session.rev,
        sheetId: sheetId,
        source: 'dsh-sheet-mobile',
      );
      edit.editable = gate.editable;
      _edit = edit;
    } on Object catch (e) {
      // ★ 闸门已判"只读打开"（gate.editable 为假）时，协作权限拒绝只是该结论的
      // 必然推论 —— 不再重复报成红色（见 `docs/office-readonly-banner-defect.md`）。
      // 闸门判定可写时不静音；只读时的其它协作故障也照常报错。
      if (officeSessionNoteRedundant(e, gateAllowsEditing: gate.editable)) {
        logOfficeErrorForDiagnostics('sheet-session', e, StackTrace.current);
      } else {
        sessionNote = _fill(
          'officeSheetSessionUnavailable',
          '协作会话未建立：{name}',
          <String, String>{'name': _describeError(e)},
        );
      }
    }

    _set(
      OfficeSheetState(
        phase: OfficeSheetPhase.ready,
        gate: gate,
        snapshot: snapshot,
        ooxmlBytes: ooxmlBytes,
        sessionReady: sessionReady,
        sessionNote: sessionNote,
        sessionIdentifier: _session?.identifier,
        sessionRev: _session?.rev ?? 0,
        editable: gate.editable && sessionReady && _edit != null,
      ),
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
    if (error is OfficeSheetLoadException) {
      // ★★ 第 308 轮：`message` 是实现者诊断串（含 `@C_text/*` 这类 section 名、且只有中文），
      // 在英文环境下会把中文顶到界面上（真机 LGE-AN10 实测）⇒ 原文只进日志，界面走本地化。
      logOfficeErrorForDiagnostics('sheetLoad:${error.reason}', error);
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

class OfficeSheetPage extends ConsumerStatefulWidget {
  const OfficeSheetPage({
    super.key,
    required this.request,
    this.backend,
    this.onFallbackToNativePreview,
    this.initialScale,
  });

  final OfficeSheetRequest request;

  /// 初始缩放；`null` = **打开即自适应宽**（对齐 WPS/Office 安卓版）。
  /// 显式传值用于恢复上次缩放，或让测试拿到确定几何。
  final double? initialScale;

  /// 测试注入；为 null 时用既有 Office 数据层装配。
  final OfficeSheetBackend? backend;

  /// 只读失败时可选的回退入口（接到既有原生只读预览）。
  final VoidCallback? onFallbackToNativePreview;

  @override
  ConsumerState<OfficeSheetPage> createState() => _OfficeSheetPageState();
}

class _OfficeSheetPageState extends ConsumerState<OfficeSheetPage> {
  late final OfficeSheetController _controller;

  @override
  void initState() {
    super.initState();
    trackView(UsageModule.office, screen: 'sheet_reader');
    _controller = OfficeSheetController(widget.backend ?? _buildBackend());
    unawaited(_controller.load());
  }

  OfficeSheetBackend _buildBackend() {
    final officeApi = ref.read(officeApiProvider);
    if (officeApi == null) {
      return _DisconnectedBackend();
    }
    return OfficeApiSheetBackend(
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
    // 编辑层的每次状态变化（乐观显示/未确认计数/远端应用）都要刷新页面。
    // 用**嵌套**的 ListenableBuilder 直接订阅编辑层（不依赖 merge 出的中间对象）。
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final edit = _controller.edit;
        if (edit == null) return _scaffold(context);
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
      key: const Key('office-sheet-page'),
      appBar: AppBar(
        title: Text(
          widget.request.name.isEmpty
              ? _t('officeSheetTitle', '表格')
              : widget.request.name,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          // 写权限门控：无权限 / schema 太旧 → **隐藏**入口；
          // 119/106 / 认不出 → 保留入口并给原因。批 2 起入口可进入编辑
          // （门控不允许时仍是不可点的只读指示）。
          if (state.isReady && state.gate.showEditorEntry)
            _editEntry(context, state),
        ],
      ),
      body: _body(context, state),
    );
  }

  /// 编辑入口：**门控的可见闸门 + 编辑态指示**（照 `.odoc` 批 2 的 `_editEntry`：
  /// 真实编辑落点在网格单元格，入口本身不承载动作）。
  ///
  /// 刻意保持 `IconButton`（`onPressed: null`）形态：批 1 的两个既有断言
  /// （allowed → 可见不可点；119 → 保留入口 + 重登提示）**逐字不变**。
  Widget _editEntry(BuildContext context, OfficeSheetState state) {
    return IconButton(
      key: const Key('office-sheet-edit-entry'),
      tooltip: state.editable
          ? _t('officeSheetEditHint', '点按单元格即可编辑（改动会即时同步）。')
          : state.gate.editable
              ? _t('officeSheetEditNoSession', '协作会话未建立，当前只读。')
              : (state.gate.reasonText ?? ''),
      icon: Icon(
        state.gate.editable ? Icons.edit_outlined : Icons.edit_off_outlined,
      ),
      onPressed: null,
    );
  }

  Widget _body(BuildContext context, OfficeSheetState state) {
    switch (state.phase) {
      case OfficeSheetPhase.loading:
        return Center(
          key: const Key('office-sheet-loading'),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: Gap.md),
              Text(_t('officeSheetLoading', '正在读取表格…')),
            ],
          ),
        );
      case OfficeSheetPhase.sessionExpired:
        return _StatusPane(
          key: const Key('office-sheet-session-expired'),
          icon: Icons.lock_clock,
          title: _t('officeSheetSessionExpired', '登录会话已失效'),
          body: state.errorMessage ?? '',
          primaryLabel: _t('officeSheetRetry', '重试'),
          onPrimary: () => unawaited(_controller.load()),
          secondaryLabel: widget.onFallbackToNativePreview == null
              ? null
              : _t('officeSheetFallbackPreview', '改用只读预览'),
          onSecondary: widget.onFallbackToNativePreview,
        );
      case OfficeSheetPhase.failure:
        return _StatusPane(
          key: const Key('office-sheet-failure'),
          icon: Icons.error_outline,
          title: _t('officeSheetLoadFailed', '打开失败'),
          body: state.errorMessage ?? '',
          primaryLabel: _t('officeSheetRetry', '重试'),
          onPrimary: () => unawaited(_controller.load()),
          secondaryLabel: widget.onFallbackToNativePreview == null
              ? null
              : _t('officeSheetFallbackPreview', '改用只读预览'),
          onSecondary: widget.onFallbackToNativePreview,
        );
      case OfficeSheetPhase.ready:
        return _readyBody(context, state);
    }
  }

  Widget _readyBody(BuildContext context, OfficeSheetState state) {
    final sections = state.snapshot?.sections;
    final edit = _controller.edit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _gateBanner(context, state),
        if (state.sessionNote != null)
          _sessionNote(context, state.sessionNote!),
        if (state.editable)
          _plainBanner(
            key: const Key('office-sheet-edit-hint'),
            icon: Icons.edit_outlined,
            text: _t('officeSheetEditHint', '点按单元格即可编辑（改动会即时同步）。'),
          ),
        if (edit != null) _pendingBanner(context, edit),
        if (edit != null && edit.failures.isNotEmpty)
          _failureBanner(context, edit.failures.last),
        const Divider(height: 1),
        Expanded(
          child: sections == null
              ? Center(
                  key: const Key('office-sheet-no-content'),
                  child: Text(_t('officeSheetNoContent', '没有可显示的表格内容')),
                )
              : OfficeSheetView(
                  sections: sections,
                  ooxmlBytes: state.ooxmlBytes,
                  report: _controller.renderReport,
                  edit: edit,
                  initialScale: widget.initialScale,
                ),
        ),
      ],
    );
  }

  /// **常显**未确认命令数（`docs/office-sheet-ui-2.md` §④）：
  /// 即使为 0 也显示（"所有改动已确认"），发送出错时附带**重试**。
  Widget _pendingBanner(BuildContext context, OfficeSheetEditController edit) {
    final count = edit.pendingCount;
    final text = count == 0
        ? _t('officeSheetPendingNone', '所有改动已确认')
        : _fill('officeSheetPendingCount', '待确认改动：{count} 项（{cells} 格）', {
            'count': '$count',
            'cells': '${edit.pendingCellCount}',
          });
    return Container(
      key: const Key('office-sheet-pending'),
      width: double.infinity,
      color: count == 0
          ? Theme.of(context).colorScheme.surfaceContainerHighest
          : Theme.of(context).colorScheme.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      child: Row(
        children: [
          Icon(count == 0 ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined,
              size: 16),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
          if (edit.sendError != null)
            TextButton(
              key: const Key('office-sheet-pending-retry'),
              onPressed: () => unawaited(edit.retryPending()),
              child: Text(_t('officeSheetEditRetry', '重试')),
            ),
        ],
      ),
    );
  }

  /// 拒绝/失败**必须可解释**：哪一格 + 为什么没生效。
  Widget _failureBanner(BuildContext context, OfficeSheetEditFailure failure) {
    return _plainBanner(
      key: const Key('office-sheet-edit-failure'),
      icon: Icons.error_outline,
      text: _failureText(failure),
      color: Theme.of(context).colorScheme.errorContainer,
    );
  }

  String _failureText(OfficeSheetEditFailure failure) {
    final reason = switch (failure.kind) {
      OfficeSheetEditFailureKind.rejected => _t(
          'officeSheetEditReasonRejected',
          '服务端拒绝了这次改动（status 0）',
        ),
      OfficeSheetEditFailureKind.staleBlocked => _fill(
          'officeSheetEditReasonStale',
          '服务端版本一直过期，已重放 {count} 次',
          <String, String>{'count': '${failure.attempts}'},
        ),
      OfficeSheetEditFailureKind.transport => _fill(
          'officeSheetEditReasonTransport',
          '发送失败：{detail}',
          <String, String>{'detail': failure.detail},
        ),
      OfficeSheetEditFailureKind.malformedAck => _fill(
          'officeSheetEditReasonUnknown',
          '无法确认服务端结果：{detail}',
          <String, String>{'detail': failure.detail},
        ),
    };
    return _fill(
      'officeSheetEditFailedCell',
      '「{cell}」的改动未生效：{reason}',
      <String, String>{'cell': failure.cellsLabel, 'reason': reason},
    );
  }

  Widget _plainBanner({
    required Key key,
    required IconData icon,
    required String text,
    Color? color,
  }) {
    return Container(
      key: key,
      width: double.infinity,
      color: color ?? Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
      child: Row(
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  /// 门控原因**永远可见**（"不满足 → 只读 + 明确原因"，不是隐藏整个页面）。
  Widget _gateBanner(BuildContext context, OfficeSheetState state) {
    final reason = state.gate.reasonText;
    if (reason == null) return const SizedBox.shrink();
    return Container(
      key: const Key('office-sheet-gate-banner'),
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
      key: const Key('office-sheet-session-note'),
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
class _DisconnectedBackend implements OfficeSheetBackend {
  @override
  Future<OfficeSheetSnapshot> loadSnapshot() async =>
      throw const OfficeSheetLoadException(
        'not_connected',
        '未连接 DSM 或 Office 套件不可用',
      );

  @override
  Future<OfficeWriteGateInputs> loadGate() async => const OfficeWriteGateInputs(
    canWrite: false,
    canComment: false,
    schemaMobile: 0,
    loadError: kOfficeSheetGateUnknownError,
  );

  @override
  Future<OfficeSheetSession> openSession() async =>
      throw const OfficeSheetLoadException('not_connected', '未连接 DSM');

  @override
  Future<void> closeSession(OfficeSheetSession session) async {}
}
