// Office C' — session layer: M1 schema + M2 OT queue + M0 client assembly.
//
// This binds the three finished pieces into one offline-testable unit:
//
//   M1  `DocSchema` / `DocNode`   parse and validate the raw `.odoc` document
//                                 (`@C_text/content.data`) - `doc_schema.dart`.
//   M2  `DocOtQueue` / `DocStep`  pending/confirmed step queue, apply + rebase
//                                 - `doc_ot_queue.dart`, `doc_transform.dart`.
//   M0  `OfficeCollabClient`      handshake/ready gate/frames/acks/heartbeat
//                                 - `office_collab_client.dart`.
//
// It is deliberately *not* wired into `lib/src/data/office_api.dart` (the
// orchestrator's ruling ①): the editor UI batch will call [DocOtSession]. The
// public surface here is the read/write contract that batch needs.
//
// Version rule (M0-measured, see `docs/office-collab-m2-implementation.md` ④):
// the `event` frame carries the server's **current** version, so the check is
// `incoming == current`, never `current + 1`. The sheet `rev` counter is a
// different protocol and is not mixed in here.
//
// `structure` (orchestrator ruling ②): M2 proved `ReplaceStep.fromJSON` ignores
// it, so by default the session strips `structure` from outgoing `replace`
// steps rather than pretend it is honoured. Flip [sendStructure] to emit the
// official `toJSON` shape once the fork actually reads it.
//
// Pure Dart, platform independent, offline, no dependencies.

import 'dart:async';

import 'doc_ot_queue.dart';
import 'doc_schema.dart';
import 'doc_step.dart';
import 'doc_transform.dart';
import 'office_collab_client.dart';

/// The `.odoc` `@C_text/content` section: `{data: <ProseMirror doc>, version: N}`.
///
/// M0 evidence: the BSON section is exactly `{'content': {data, version}}` and a
/// `fetch` ack nests the same pair under `{doc: {version, data, comment_store}}`.
class OfficeCollabContent {
  const OfficeCollabContent({required this.version, required this.data});

  final int version;
  final DocJson data;

  /// ★★ 第 310 轮：[parse] 的**可空**版本 —— "服务端根本没有内容"返回 `null`。
  ///
  /// 与 [parse] 的分工**必须分清**（§2.0.47 ③ 的判据）：
  /// * `null` = 回包里**没有文档**（缺 `doc`/`data`，或没有数字 `version`）；
  /// * 抛异常 = **有**文档但形态不是对象（真怪形态，不许伪装成空文档）。
  ///
  /// 官方对"取不到内容"的处置是 `content?.data || getDefaultDocJson()`（回落客户端
  /// 预设，且**那份预设就是编辑器的文档**）。协作 `fetch` 是同一个语义面：
  /// 空文档的 `fetch` 就是取不到内容。
  static OfficeCollabContent? tryParse(Object? section) {
    if (section is! Map) {
      throw OfficeCollabException('@C_text/content is not an object');
    }
    final map = section.cast<String, Object?>();
    final doc = map['doc'];
    final src = doc is Map ? doc.cast<String, Object?>() : map;
    final version = src['version'];
    final data = src['data'];
    if (version is! num) return null;
    if (data is! Map) return null;
    return OfficeCollabContent(
      version: version.toInt(),
      data: data.cast<String, Object?>(),
    );
  }

  /// Accepts either the section `{data, version}` or the `fetch`/`Snapshot:get`
  /// wrapper `{doc: {data, version}}`.
  static OfficeCollabContent parse(Object? section) {
    if (section is! Map) {
      throw OfficeCollabException('@C_text/content is not an object');
    }
    final map = section.cast<String, Object?>();
    final doc = map['doc'];
    final src = doc is Map ? doc.cast<String, Object?>() : map;
    final version = src['version'];
    final data = src['data'];
    if (version is! num) {
      throw OfficeCollabException('@C_text/content has no numeric version');
    }
    if (data is! Map) {
      throw OfficeCollabException('@C_text/content has no document data');
    }
    return OfficeCollabContent(
      version: version.toInt(),
      data: data.cast<String, Object?>(),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'data': data,
    'version': version,
  };
}

/// A `fetch` result: the server doc, its M1-mandated parse and the canonical raw
/// tree the M2 queue actually steps on.
class DocFetchResult {
  const DocFetchResult({
    required this.version,
    required this.raw,
    required this.node,
    required this.canonical,
  });

  final int version;
  final DocJson raw;

  /// M1-validated view (`DocSchema.nodeFromJson`).
  final DocNode node;

  /// [node] re-serialised; `== raw` for editor-produced docs, and the R1-filled
  /// form for an `Office.Import`-produced `@C_text/content`.
  final DocJson canonical;

  @override
  String toString() =>
      'DocFetchResult(version: $version, '
      'top: ${canonical['type']})';
}

/// One session-level event, for UI/state observers.
enum DocOtSessionEventKind {
  ready,
  fetched,
  ackConfirmed,
  versionNotCurrent,
  invalidCommand,
  stepDropped,
  rebasing,
  rebased,
  pendingDroppedOnResync,
  reconnected,
  closed,
}

class DocOtSessionEvent {
  const DocOtSessionEvent(this.kind, [this.message]);

  final DocOtSessionEventKind kind;
  final String? message;

  @override
  String toString() =>
      'DocOtSessionEvent(${kind.name}'
      '${message == null ? '' : ', $message'})';
}

/// The increment returned by `poll {version: from}` — the remote steps a `402`
/// recovery rebases the local pending steps over.
class _RemoteIncrement {
  const _RemoteIncrement(this.version, this.steps);
  final int version;
  final List<DocStep> steps;
}

/// Assembles M1 (schema) + M2 (OT queue) + M0 (client) into a doc editing session.
///
/// ```dart
/// final session = DocOtSession(client: client);
/// await session.open();                 // connect, ready, say_hello, ask_peers, fetch
/// await session.localEdit(ReplaceStep(37, 37, DocSlice(...), false));
/// await session.close();
/// ```
class DocOtSession {
  DocOtSession({
    required this.client,
    DocSchema? schema,
    this.clientId = 'dart01',
    this.sendStructure = false,
    this.maxRecoveryAttempts = 5,
    this.defaultDoc,
  }) : schema = schema ?? DocSchema.document;

  final OfficeCollabClient client;
  final DocSchema schema;

  /// The `clientId` echoed in every `event` frame. The server adopts it and
  /// overwrites `uid` with the authenticated user (M0 §2.4).
  final String clientId;

  /// Emit `structure` on `replace` steps? Default **false**: M2 proved the
  /// server's `Step.fromJSON` drops the field (`ReplaceStep.fromJSON` never reads
  /// it), while the official `toJSON` writes it. See the orchestrator ruling ②.
  final bool sendStructure;

  final int maxRecoveryAttempts;

  /// ★★ 第 310 轮：`fetch` **取不到内容**时，用它当会话的基线文档（版本 0）。
  ///
  /// 这是官方 `content?.data || getDefaultDocJson()` 的协作面等价物：官方那份
  /// **客户端预设就是编辑器的文档**，所以第一个编辑动作是相对它的步。本仓此前
  /// 把"回落树"只喂给渲染层，会话仍拿服务端的空文档 ⇒
  /// `isEditablePath()`（它只看会话的 `doc`）在整棵树里找不到 `edit_area`
  /// ⇒ **每一个段落都判成只读**、页面上没有可聚焦的输入框（第 309 轮真机现象）。
  /// 传 `null` 时行为不变：`fetch` 没内容就照旧失败（**不静默伪造文档**）。
  final DocJson? defaultDoc;

  DocOtQueue? _queue;
  StreamSubscription<void>? _reconnectSub;
  final StreamController<DocOtSessionEvent> _events =
      StreamController<DocOtSessionEvent>.broadcast();

  int _recoveryAttempts = 0;
  DocOtAckOutcome? _lastAckBeforeRecovery;

  /// Last `fetch` result (M1 node + canonical raw tree).
  DocFetchResult? lastFetch;

  /// Last `event` ack outcome (after any recovery).
  DocOtAckOutcome? lastAck;

  /// Last frame sent.
  DocOtEventFrame? lastFrame;

  /// Last rebase performed during a `402` recovery (dropped steps are reported).
  DocRebaseResult? lastRebase;

  /// Human-readable recovery trail (for the UI / diagnostics).
  final List<String> recoveryLog = <String>[];

  /// Session-level event stream.
  Stream<DocOtSessionEvent> get events => _events.stream;

  bool get isSynced => _queue != null;

  int get version => _queue?.version ?? -1;

  /// Optimistic local document (confirmed + pending), raw M2 tree.
  DocJson? get doc => _queue?.doc;

  /// The M1-validated view of the current optimistic doc.
  DocNode get docNode => DocNode.fromRawJson(_queue!.doc);

  int get pendingCount => _queue?.pendingCount ?? 0;

  bool get hasUnconfirmed => _queue?.hasUnconfirmed ?? false;

  DocOtQueue? get queue => _queue;

  // ------------------------------------------------------------------ setup --

  /// Connects, waits for `ready`, announces (optional) and `fetch`es the doc.
  ///
  /// [announce] mirrors the M0 client (`say_hello` then `ask_peers`); both are
  /// best-effort - a failure does not abort the session because neither changes
  /// document state.
  Future<void> open({bool announce = true}) async {
    await client.connect();
    _reconnectSub ??= client.onReconnected.listen((_) {
      unawaited(_onReconnected());
    });
    if (announce) {
      await _safeEmit('say_hello');
      await _safeEmit('ask_peers');
    }
    await refetch();
    _addEvent(DocOtSessionEvent(DocOtSessionEventKind.ready));
  }

  Future<void> close() async {
    await _reconnectSub?.cancel();
    _reconnectSub = null;
    if (!_events.isClosed) {
      _addEvent(const DocOtSessionEvent(DocOtSessionEventKind.closed));
      await _events.close();
    }
    await client.close();
  }

  Future<void> _onReconnected() async {
    _addEvent(const DocOtSessionEvent(DocOtSessionEventKind.reconnected));
    final dropped = pendingCount;
    try {
      await refetch();
      if (dropped > 0) {
        _addEvent(
          DocOtSessionEvent(
            DocOtSessionEventKind.pendingDroppedOnResync,
            '$dropped unconfirmed step(s) dropped: the reconnect re-`fetch` has '
            'no remote increment to rebase over',
          ),
        );
      }
    } on Object catch (e) {
      _addEvent(
        DocOtSessionEvent(
          DocOtSessionEventKind.pendingDroppedOnResync,
          'refetch failed: $e',
        ),
      );
    }
  }

  // ------------------------------------------------------------------ fetch --

  /// `fetch` the server document, validate it through M1 and (re)build the queue.
  ///
  /// A re-`fetch` is destructive for unconfirmed steps (there is no remote
  /// increment to rebase over); the count is logged. The `402` path uses
  /// [more] instead, which preserves and rebases the pending steps.
  Future<DocFetchResult> refetch() async {
    final reply = await client.emit('fetch');
    if (classifyCollabReply(reply) != OfficeCollabErrorKind.ok) {
      throw OfficeCollabException('fetch failed: $reply');
    }
    final payload = collabAckPayload(reply);
    // ★★ 第 310 轮：`fetch` **取不到内容**（空文档）与"形态怪"分开处置。
    final fetched = OfficeCollabContent.tryParse(payload);
    final OfficeCollabContent content;
    if (fetched != null) {
      content = fetched;
    } else {
      final seed = defaultDoc;
      if (seed == null) {
        // 没有种子 ⇒ 照旧失败（调用方据此显示"协作会话未建立"，**不静默伪造**）。
        throw OfficeCollabException(
          'fetch has no document and no default doc was provided',
        );
      }
      // 官方语义：`content?.data || getDefaultDocJson()` —— 空文档用**客户端预设**
      // 当编辑器的文档，版本从 0 起（服务端还没有这一版）。
      content = OfficeCollabContent(version: 0, data: seed);
    }
    // M1: validate + canonicalise (R1 required defaults, R3 empty maps dropped).
    final node = schema.normalizeFromImport(content.data);
    final canonical = node.toRawJson();
    final result = DocFetchResult(
      version: content.version,
      raw: content.data,
      node: node,
      canonical: canonical,
    );
    _queue = DocOtQueue(
      doc: canonical,
      version: content.version,
      clientId: clientId,
    );
    lastFetch = result;
    _addEvent(
      DocOtSessionEvent(
        DocOtSessionEventKind.fetched,
        'version=${content.version}',
      ),
    );
    return result;
  }

  // ------------------------------------------------------------------ edits --

  /// Applies [step] locally (optimistic), enqueues it and drives the protocol,
  /// including `402` rebase-and-resend and `411` drop-invalid-step.
  Future<DocOtAckOutcome> localEdit(DocStep step) async {
    _ensureSynced();
    _recoveryAttempts = 0;
    final frame = _queue!.localEdit(step);
    return _sendFrame(frame);
  }

  /// [localEdit] from a raw StepJSON (`Step.fromJSON`).
  Future<DocOtAckOutcome> localEditJson(Object? stepJson) =>
      localEdit(DocStep.fromJson(stepJson));

  /// The exact `event` frame body put on the wire.
  ///
  /// `structure` is stripped by default (see [sendStructure]).
  Map<String, Object?> wireEventJson(DocOtEventFrame frame) {
    final json = frame.toJson();
    if (sendStructure) return json;
    final steps = json['steps'];
    if (steps is! List) return json;
    return <String, Object?>{
      ...json,
      'steps': steps.map(_stripStructure).toList(growable: false),
    };
  }

  static Map<String, Object?> _stripStructure(Object? step) {
    if (step is! Map) return <String, Object?>{};
    final m = step.cast<String, Object?>();
    // Only `replace` carries it; the official `toJSON` writes `structure:false`
    // but the server's `ReplaceStep.fromJSON` ignores it entirely (M2 ② #3).
    if (m['stepType'] != 'replace' || !m.containsKey('structure')) return m;
    return <String, Object?>{...m}..remove('structure');
  }

  Future<DocOtAckOutcome> _sendFrame(DocOtEventFrame frame) async {
    lastFrame = frame;
    final reply = await client.emit('event', wireEventJson(frame));
    final outcome = _queue!.onEventAck(reply);
    lastAck = outcome;
    switch (outcome.kind) {
      case DocOtAckKind.confirmed:
        _addEvent(
          DocOtSessionEvent(
            DocOtSessionEventKind.ackConfirmed,
            'version=${outcome.version}',
          ),
        );
        return outcome;
      case DocOtAckKind.versionNotCurrent:
        _lastAckBeforeRecovery = outcome;
        _addEvent(
          DocOtSessionEvent(
            DocOtSessionEventKind.versionNotCurrent,
            outcome.message,
          ),
        );
        return _recoverFrom402();
      case DocOtAckKind.invalidCommand:
        _lastAckBeforeRecovery = outcome;
        _addEvent(
          DocOtSessionEvent(
            DocOtSessionEventKind.invalidCommand,
            outcome.message,
          ),
        );
        return _recoverFrom411();
      case DocOtAckKind.otherError:
        return outcome;
    }
  }

  // --------------------------------------------------------------- recovery --

  /// `402 Not current version` -> `poll` the remote increment from the confirmed
  /// version, `rebaseOnto` the pending steps and resend.
  ///
  /// If no usable increment is available (or it parses to nothing), fall back to
  /// a full re-`fetch`, which drops the pending steps and records why.
  Future<DocOtAckOutcome> _recoverFrom402() async {
    if (_recoveryAttempts >= maxRecoveryAttempts) {
      throw OfficeCollabException(
        '402 recovery exceeded $maxRecoveryAttempts attempts; giving up',
      );
    }
    _recoveryAttempts++;
    final increment = await _pollRemoteIncrement();
    if (increment == null || increment.steps.isEmpty) {
      final dropped = pendingCount;
      recoveryLog.add(
        '402: no remote increment -> full refetch, '
        '$dropped unconfirmed step(s) dropped',
      );
      await refetch();
      _addEvent(
        DocOtSessionEvent(
          DocOtSessionEventKind.pendingDroppedOnResync,
          '402 without remote steps: dropped $dropped step(s)',
        ),
      );
      return _lastAckBeforeRecovery ?? lastAck!;
    }
    recoveryLog.add(
      '402: rebasing $pendingCount step(s) over '
      '${increment.steps.length} remote step(s) to version ${increment.version}',
    );
    final frame = _queue!.rebaseOnto(
      remoteSteps: increment.steps,
      remoteVersion: increment.version,
    );
    lastRebase = _queue!.lastRebase;
    _addEvent(
      DocOtSessionEvent(
        DocOtSessionEventKind.rebased,
        'version=${increment.version}, dropped=${lastRebase?.droppedAny ?? false}',
      ),
    );
    return _sendFrame(frame);
  }

  /// `411 Invalid command` -> drop the offending (last enqueued) step and resend
  /// the remainder. Returns the original 411 outcome when nothing is left.
  Future<DocOtAckOutcome> _recoverFrom411() async {
    final droppedVersion = _queue!.version;
    final frame = _queue!.dropInvalidStep();
    recoveryLog.add(
      '411: dropped invalid step, '
      '${frame == null ? 'queue now empty' : '$pendingCount step(s) resending'}',
    );
    _addEvent(
      DocOtSessionEvent(
        DocOtSessionEventKind.stepDropped,
        'version=$droppedVersion',
      ),
    );
    if (frame == null) return _lastAckBeforeRecovery ?? lastAck!;
    return _sendFrame(frame);
  }

  /// `poll {version: confirmed}` -> the server's incremental steps.
  Future<_RemoteIncrement?> _pollRemoteIncrement() async {
    final from = _queue!.version;
    Object? reply;
    try {
      reply = await client.emit('poll', <String, Object?>{'version': from});
    } on OfficeCollabException catch (e) {
      recoveryLog.add('402: poll failed ($e)');
      return null;
    }
    if (classifyCollabReply(reply) != OfficeCollabErrorKind.ok) return null;
    final payload = collabAckPayload(reply);
    if (payload is! Map) return null;
    final version = (payload['version'] as num?)?.toInt();
    if (version == null) return null;
    final rawSteps = payload['steps'];
    if (rawSteps is! List) return _RemoteIncrement(version, const <DocStep>[]);
    final steps = <DocStep>[];
    for (final raw in rawSteps) {
      try {
        steps.add(DocStep.fromJson(raw));
      } on DocStepParseException catch (e) {
        recoveryLog.add('402: remote poll step rejected ($e)');
        return null;
      }
    }
    return _RemoteIncrement(version, steps);
  }

  // ----------------------------------------------------------------- helpers --

  Future<void> _safeEmit(String event) async {
    try {
      await client.emit(event);
    } on OfficeCollabException catch (e) {
      recoveryLog.add('$event failed: $e');
    }
  }

  void _ensureSynced() {
    if (_queue == null) {
      throw OfficeCollabException(
        'session not synced: call open()/refetch() first',
      );
    }
  }

  void _addEvent(DocOtSessionEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}
