// Office C' · M2 — local unconfirmed-step queue and server version reconciliation.
//
// This is the client half of the M0 doc protocol:
//
//   c2s 424["event",{"version":1,"steps":[…],"clientId":"…","selection":null}]
//   s2c 434[null,{"id":"…","version":2,"steps":[…],"clientIDs":[…]}]
//   s2c 434[{"status":402},"Error: <objectId>: Not current version. incoming: 7, current: 2"]
//   s2c 435[{"status":411},"Error: <objectId>: Invalid command"]
//
// Semantics pinned by the M0 device probe (docs/office-collab-protocol-spike.md):
//   * the `event` frame's `version` must equal the server's CURRENT version
//     (incoming 1 against current 1 -> accepted, version becomes 2);
//     `incoming != current` -> 402 ERR_VERSION_NOT_CURRENT;
//   * an unparsable step (`Step.fromJSON` throwing) -> 411 ERR_INVALID_COMMAND;
//   * a 402 is recovered by refetching and rebasing the unconfirmed steps
//     ([DocOtQueue.rebaseOnto]); nothing is silently dropped.
//
// Pure Dart, offline, no sockets, no dependencies.

import 'doc_step.dart';
import 'doc_transform.dart';

/// Verified on device in M0 (`Constants.js` + live negative probes).
const int kDocErrVersionNotCurrent = 402;
const int kDocErrInvalidCommand = 411;

/// A server-side doc error carrying its protocol status.
class DocOtException implements Exception {
  const DocOtException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => 'DocOtException($status): $message';
}

/// Classifies a server status code into the two M2-relevant semantics.
enum DocOtAckKind {
  /// `[null, {version, steps, …}]` — the edit was accepted.
  confirmed,

  /// `[{"status":402}, "Error: … Not current version …"]`.
  versionNotCurrent,

  /// `[{"status":411}, "Error: … Invalid command"]`.
  invalidCommand,

  /// Any other error ack.
  otherError,
}

/// Parsed server ack.
class DocOtAckOutcome {
  const DocOtAckOutcome(this.kind, {this.status, this.version, this.message});

  final DocOtAckKind kind;
  final int? status;
  final int? version;
  final String? message;

  @override
  String toString() =>
      'DocOtAckOutcome($kind, status: $status, '
      'version: $version, message: $message)';
}

/// Parses the socket.io positional ack shape the Office server emits.
///
/// Accepts either the decoded `[cbArg0, cbArg1?]` list or a raw error map.
DocOtAckOutcome parseDocEventAck(Object? ack) {
  if (ack is Map) {
    return _fromErrorAck((ack).cast<String, Object?>(), null);
  }
  if (ack is List) {
    if (ack.isEmpty) {
      throw const DocOtException(0, 'empty ack');
    }
    final first = ack.first;
    final second = ack.length > 1 ? ack[1] : null;
    if (first == null) {
      if (second is Map) {
        final m = second.cast<String, Object?>();
        return DocOtAckOutcome(
          DocOtAckKind.confirmed,
          version: (m['version'] as num?)?.toInt(),
        );
      }
      return const DocOtAckOutcome(DocOtAckKind.confirmed);
    }
    if (first is Map) {
      return _fromErrorAck(
        first.cast<String, Object?>(),
        second is String ? second : second?.toString(),
      );
    }
    throw DocOtException(0, 'unrecognised ack: $ack');
  }
  throw DocOtException(0, 'unrecognised ack: $ack');
}

DocOtAckOutcome _fromErrorAck(Map<String, Object?> error, String? message) {
  final status = (error['status'] as num?)?.toInt();
  final kind = switch (status) {
    kDocErrVersionNotCurrent => DocOtAckKind.versionNotCurrent,
    kDocErrInvalidCommand => DocOtAckKind.invalidCommand,
    _ => DocOtAckKind.otherError,
  };
  return DocOtAckOutcome(kind, status: status, message: message);
}

/// The local `version` check the server performs (`incoming` must equal the
/// server's current version). Throws [DocOtException] with 402 on mismatch.
void assertIncomingVersionCurrent(int incoming, int current) {
  if (incoming != current) {
    throw DocOtException(
      kDocErrVersionNotCurrent,
      'Not current version. incoming: $incoming, current: $current',
    );
  }
}

/// One locally applied, not-yet-confirmed step.
class DocOtPendingEdit {
  const DocOtPendingEdit(this.step, this.version);
  final DocStep step;

  /// The server version this step was composed against.
  final int version;
}

/// The `event` frame body (`{version, steps, clientId, selection}`).
class DocOtEventFrame {
  const DocOtEventFrame({
    required this.version,
    required this.steps,
    required this.clientId,
    this.selection,
  });

  final int version;
  final List<DocStep> steps;
  final String clientId;
  final Object? selection;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': version,
    'steps': steps.map((s) => s.toJson()).toList(),
    'clientId': clientId,
    'selection': selection,
  };

  @override
  String toString() =>
      'DocOtEventFrame(version: $version, '
      'steps: ${steps.length}, clientId: $clientId)';
}

/// The local unconfirmed-step queue.
///
/// `doc` is the optimistic local document (confirmed + pending); [confirmedDoc]
/// is the last server-acknowledged document, which is the base for rebasing.
class DocOtQueue {
  DocOtQueue({
    required DocJson doc,
    required this.version,
    this.clientId = 'dart01',
  }) : confirmedDoc = doc,
       _doc = doc;

  DocJson _doc;

  /// Last server-confirmed document (the rebase base).
  DocJson confirmedDoc;

  /// Last server-confirmed version.
  int version;

  final String clientId;
  final List<DocOtPendingEdit> _pending = <DocOtPendingEdit>[];

  DocJson get doc => _doc;

  int get pendingCount => _pending.length;

  bool get hasUnconfirmed => _pending.isNotEmpty;

  List<DocOtPendingEdit> get pending => List.unmodifiable(_pending);

  /// Applies [step] locally, enqueues it, and returns the frame to send.
  DocOtEventFrame localEdit(DocStep step) {
    final result = step.apply(_doc);
    if (!result.succ) {
      throw DocReplaceError(result.reason ?? 'local step failed');
    }
    _doc = result.doc!;
    _pending.add(DocOtPendingEdit(step, version));
    return nextFrame();
  }

  /// The cumulative `event` frame for all unconfirmed steps.
  DocOtEventFrame nextFrame() {
    if (_pending.isEmpty) {
      throw StateError('no unconfirmed steps to send');
    }
    return DocOtEventFrame(
      version: version,
      steps: _pending.map((e) => e.step).toList(growable: false),
      clientId: clientId,
    );
  }

  /// Handles an `event` ack. On confirmation the queue is drained; on 402 the
  /// caller must refetch and call [rebaseOnto]; on 411 the caller must drop the
  /// invalid step. Never silently discards steps.
  DocOtAckOutcome onEventAck(Object? ack) {
    final outcome = parseDocEventAck(ack);
    switch (outcome.kind) {
      case DocOtAckKind.confirmed:
        version = outcome.version ?? (version + _pending.length);
        confirmedDoc = _doc;
        _pending.clear();
      case DocOtAckKind.versionNotCurrent:
      case DocOtAckKind.invalidCommand:
      case DocOtAckKind.otherError:
        break;
    }
    return outcome;
  }

  /// Recovery for a `402 Not current version`: applies the freshly fetched
  /// remote steps to the confirmed base, rebases every unconfirmed step over
  /// them, and returns the frame to resend at [remoteVersion].
  ///
  /// Steps fully deleted by the remote mapping are dropped (reported via
  /// [lastRebase]); a step whose rebase application fails is dropped rather
  /// than retried forever.
  DocRebaseResult? lastRebase;

  DocOtEventFrame rebaseOnto({
    required List<DocStep> remoteSteps,
    required int remoteVersion,
  }) {
    final rebase = rebaseSteps(
      baseDoc: confirmedDoc,
      remoteSteps: remoteSteps,
      localSteps: _pending.map((e) => e.step).toList(growable: false),
      suppressFailure: true,
    );
    lastRebase = rebase;
    // Re-apply only the surviving mapped steps to the remote document; the
    // `rebaseSteps` result already did that, but we rebuild the pending list so
    // each entry carries the new base version.
    var newDoc = rebase.doc;
    final survivors = <DocOtPendingEdit>[];
    for (var i = 0; i < rebase.mappedLocalSteps.length; i++) {
      final mapped = rebase.mappedLocalSteps[i];
      if (mapped == null) continue;
      survivors.add(DocOtPendingEdit(mapped, remoteVersion));
    }
    confirmedDoc = rebase.remoteDoc;
    version = remoteVersion;
    _doc = newDoc;
    _pending
      ..clear()
      ..addAll(survivors);
    return nextFrame();
  }

  /// Recovery for a `411 Invalid command`: drops the most recently enqueued
  /// step and recomputes the optimistic document from the confirmed base.
  DocOtEventFrame? dropInvalidStep() {
    if (_pending.isEmpty) return null;
    _pending.removeLast();
    _doc = applySteps(
      confirmedDoc,
      _pending.map((e) => e.step).toList(growable: false),
    );
    return _pending.isEmpty ? null : nextFrame();
  }
}
