// Office C′ 表格（Sheet）批 2 —— **编辑链路**（纯逻辑，可离线单测）。
//
// 本文件只做 `.osheet` 的**写侧状态机**，不做任何 UI/socket 细节：
//   * `changes` 三元组 ↔ [OfficeSheetChange]（真实帧形状见 `docs/office-sheet-ui-2.md`）；
//   * `value` 命令的 payload 构造（含 **`rev`**——服务端 `_onSet` 的乐观锁字段）；
//   * `set` ack 的三态解析：`(revIncoming, currentRev, status)` → 1 ok / 2 版本过期 / 0 拒绝
//     （`server/sheet/core/client.js :: _onSet` 原文，见
//     `docs/office-collab-schema-export.md` §B.1/§C.2）；
//   * 未确认命令队列 + 乐观显示 + **status 2 的四步重放**：
//         undo 本地未确认改动 → 重放 remoteQueue → redo 本地改动 →
//         `_adjustRev(currentRev)` 后**重发**（绝不丢用户输入）。
//
// ## 关键纪律（都有伪证用例）
//
// 1. **不丢输入**：任何发送失败/超时/status 2 都不能把命令从队列里丢掉；
//    只有服务端**明确** status 1（确认）或 status 0（拒绝）才出队，且 status 0
//    要回滚乐观显示并把"哪一格、为什么没生效"记进 [OfficeSheetEditFailure]。
// 2. **不与自己未确认的改动打架**：远端广播命中"本地有未确认改动"的格子时，
//    只把它压进 [remoteQueue]（不直接覆盖显示）；等本地命令有了结果再决定：
//       * 本地被确认 → 丢弃这些过期远端值（我们的写入已在服务端生效）；
//       * 本地被拒绝 → 把 remoteQueue 应用到 base（我们的写入从未发生）。
// 3. **表格没有 OT transform**：这里不做 `doc_transform` 那套位置映射，
//     `changes` 是绝对 (row, col) 三元组，服务端按 rev 逐条执行。
import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier;

import '../../core/i18n/data_text.dart';
import '../../data/office_collab/office_collab_client.dart';
import '../../data/office_native/office_json.dart';
import 'office_sheet_schema.dart' show
    kOfficeSheetSetStatusOk,
    kOfficeSheetSetStatusRejected,
    kOfficeSheetSetStatusStaleRev;
import 'office_sheet_view.dart' show officeSheetColumnLabel;

/// 一个单元格改动：`[row, col, v]` 三元组里的语义（**0 基**行列，真机探针确证，
/// 见 `docs/office-sheet-ui-2.md` §①）。
class OfficeSheetChange {
  const OfficeSheetChange(this.row, this.col, this.value);

  final int row;
  final int col;
  final Object? value;

  /// A1 记法（与批 1 的行列头同一口径，`officeSheetColumnLabel`）。
  String get label => officeSheetCellAddress(row, col);

  List<Object?> toTriple() => <Object?>[row, col, value];

  @override
  bool operator ==(Object other) =>
      other is OfficeSheetChange &&
      other.row == row &&
      other.col == col &&
      other.value == value;

  @override
  int get hashCode => Object.hash(row, col, value);

  @override
  String toString() => 'OfficeSheetChange($label, ${_short(value)})';
}

/// `(row, col)` → `A1`。
String officeSheetCellAddress(int row, int col) =>
    '${officeSheetColumnLabel(col)}${row + 1}';

String _short(Object? v) {
  final s = '$v';
  return s.length <= 40 ? s : '${s.substring(0, 40)}…';
}

/// 把一个 `changes` 数组解析成 [OfficeSheetChange]。
///
/// 任何形状不对（不是数组 / 元素不是三元组 / 行列不是整数）返回 null——
/// 调用方必须把它当**降级**处理（可见登记），不许静默当空。
List<OfficeSheetChange>? officeSheetChangesOf(Object? raw) {
  final list = asJsonList(raw);
  if (list == null) return null;
  final out = <OfficeSheetChange>[];
  for (final item in list) {
    final triple = asJsonList(item);
    if (triple == null || triple.length < 3) return null;
    final row = asJsonInt(triple[0]);
    final col = asJsonInt(triple[1]);
    if (row == null || col == null) return null;
    out.add(OfficeSheetChange(row, col, triple[2]));
  }
  return out;
}

/// 构造 `value` 命令 payload。
///
/// 原文依据（`@ss/core.js@697583` 工厂 + `client.js :: _onSet` 乐观锁）：
/// `{cmd:"value", id, changes:[[r,c,v],…], source, rev}`。
/// `rev` 是**必需**字段：服务端 `!a || a !== c+1` 一律回 status 2。
/// `source` 只在非 null 时带上（官方客户端给的是编辑来源标签）。
Map<String, Object?> officeSheetValueCommand({
  required String sheetId,
  required List<OfficeSheetChange> changes,
  required int rev,
  String? source,
}) {
  if (sheetId.trim().isEmpty) {
    throw ArgumentError('value 命令必须有 sheet id（sh_N）');
  }
  if (changes.isEmpty) {
    throw ArgumentError('value 命令至少要有一个 change 三元组');
  }
  if (rev <= 0) {
    throw ArgumentError('value 命令的 rev 必须为正（服务端 !rev → status 2）');
  }
  for (final change in changes) {
    if (change.row < 0 || change.col < 0) {
      throw ArgumentError('change 行列必须是 0 基非负：${change.row},${change.col}');
    }
  }
  return <String, Object?>{
    'cmd': 'value',
    'id': sheetId,
    'changes': <Object?>[for (final c in changes) c.toTriple()],
    if (source != null) 'source': source,
    'rev': rev,
  };
}

/// `set` ack 的三态。
enum OfficeSheetSetStatus { ok, staleRev, rejected, unknown }

/// 解析后的 `set` ack：`s(revIncoming, currentRev, status[, extra])`
/// （`client.js :: _onSet`；Socket.IO ack 的**位置参数列表**就是这三/四项）。
class OfficeSheetSetAck {
  const OfficeSheetSetAck({
    required this.status,
    this.revIncoming,
    this.currentRev,
    this.extra,
    this.statusCode,
    this.malformed = false,
  });

  final OfficeSheetSetStatus status;

  /// ack 第 0 项 = 服务端回显的"我们发去的 rev"。
  final int? revIncoming;

  /// ack 第 1 项 = 服务端当前 queue.rev。
  final int? currentRev;

  /// ack 第 3 项（成功时的执行结果，形状未取证）。
  final Object? extra;

  /// ack 第 2 项的原始整数（诊断/登记用；认不出时为 null）。
  final int? statusCode;

  /// ack 形状对不上（不是列表 / 项不够）——调用方必须当"结果未知"，**不丢输入**。
  final bool malformed;

  bool get isOk => status == OfficeSheetSetStatus.ok;
  bool get isStaleRev => status == OfficeSheetSetStatus.staleRev;
  bool get isRejected => status == OfficeSheetSetStatus.rejected;

  @override
  String toString() => 'OfficeSheetSetAck(${status.name}, '
      'revIncoming: $revIncoming, currentRev: $currentRev, '
      'statusCode: $statusCode${malformed ? ', malformed' : ''})';
}

/// 把 `emit('set', …)` 的回包解析成 [OfficeSheetSetAck]。**纯函数，不抛。**
OfficeSheetSetAck officeSheetSetAck(Object? ack) {
  var list = asJsonList(ack);
  // 少数服务端把回调参数再包一层（`[[a,b,c]]`）；只在单元素列表里剥一次。
  if (list != null && list.length == 1) {
    final inner = asJsonList(list.first);
    if (inner != null) list = inner;
  }
  if (list == null || list.length < 3) {
    return const OfficeSheetSetAck(
      status: OfficeSheetSetStatus.unknown,
      malformed: true,
    );
  }
  final code = asJsonInt(list[2]);
  final status = switch (code) {
    kOfficeSheetSetStatusOk => OfficeSheetSetStatus.ok,
    kOfficeSheetSetStatusStaleRev => OfficeSheetSetStatus.staleRev,
    kOfficeSheetSetStatusRejected => OfficeSheetSetStatus.rejected,
    _ => OfficeSheetSetStatus.unknown,
  };
  return OfficeSheetSetAck(
    status: status,
    revIncoming: asJsonInt(list[0]),
    currentRev: asJsonInt(list[1]),
    statusCode: code,
    extra: list.length > 3 ? list[3] : null,
  );
}

// `kOfficeSheetSetStatusOk` / `StaleRev` / `Rejected` 三个常量直接复用批 1
// `office_sheet_schema.dart` 的定义（见文件头 import），保证三态口径**同一来源**。

/// 一条**未确认**的本地编辑命令（乐观显示 + 待重发）。
class OfficeSheetPendingEdit {
  OfficeSheetPendingEdit(this.changes);

  final List<OfficeSheetChange> changes;

  /// 已发出去过几次（status 2 / 超时会加）。
  int attempts = 0;

  List<String> get cellLabels =>
      <String>[for (final c in changes) c.label];

  @override
  String toString() =>
      'OfficeSheetPendingEdit(${cellLabels.join(",")}, attempts: $attempts)';
}

/// 一次失败/拒绝的**可解释**记录：哪一格 + 为什么没生效。
enum OfficeSheetEditFailureKind {
  /// status 0：服务端 validateCommand/execCommand 拒绝。
  rejected,

  /// status 2 重放超过上限：服务端 rev 一直在变，改动**仍保留在队列**。
  staleBlocked,

  /// 发送超时 / 通道异常（结果未知，改动**仍保留在队列**）。
  transport,

  /// ack 形状对不上（结果未知，改动**仍保留在队列**）。
  malformedAck,
}

class OfficeSheetEditFailure {
  const OfficeSheetEditFailure({
    required this.kind,
    required this.changes,
    required this.detail,
    this.attempts = 1,
  });

  final OfficeSheetEditFailureKind kind;
  final List<OfficeSheetChange> changes;

  /// 诊断明细：DSM 错误串 / ack 原文摘要 / status 值。
  final String detail;
  final int attempts;

  String get cellsLabel =>
      <String>[for (final c in changes) c.label].join(
        dataText('listSeparator', '、'),
      );

  @override
  String toString() => 'OfficeSheetEditFailure(${kind.name}, $cellsLabel, $detail)';
}

/// 单元格的显示值（编辑层的权威视图）。
class OfficeSheetCellValue {
  const OfficeSheetCellValue(this.value, {required this.present, required this.pending});

  /// `null` + `present:true` = 明确清空。
  final Object? value;

  /// 文件/远端/本地是否有这个格子的值。
  final bool present;

  /// 当前值是否来自**未确认**的本地改动（UI 要用它标记）。
  final bool pending;

  String get text => value == null ? '' : '$value';
}

/// 编辑层依赖的**发送通道**（生产 = [OfficeSheetSession]，测试 = 假实现）。
abstract class OfficeSheetCommandSink {
  /// `emit('set', payload)`（M0 已把 ack 路由好；返回解析后的回包）。
  Future<Object?> sendSet(Map<String, Object?> payload);

  /// 服务端推送的事件（`set` / `peer` 广播；无 ack）。
  Stream<OfficeCollabEvent> get incoming;
}

/// 从 `@C_text/sh_N.cells`（`{"<r>":{"<c>":{"v":…}}}`）读出 base 网格。
Map<int, Map<int, Object?>> officeSheetBaseCells(
  Map<String, Object?> sections,
  String sheetId,
) {
  final sheet = asJsonMap(sections[sheetId]);
  final cells = asJsonMap(sheet?['cells']);
  final out = <int, Map<int, Object?>>{};
  if (cells == null) return out;
  cells.forEach((rowKey, rowValue) {
    final row = int.tryParse(rowKey);
    final rowMap = asJsonMap(rowValue);
    if (row == null || rowMap == null) return;
    rowMap.forEach((colKey, cellValue) {
      final col = int.tryParse(colKey);
      final cell = asJsonMap(cellValue);
      if (col == null || cell == null) return;
      if (cell.containsKey('v')) {
        (out[row] ??= <int, Object?>{})[col] = cell['v'];
      }
    });
  });
  return out;
}

/// 当前应写入哪张表：`index.order[0]`，缺省取第一个 `sh_*` section。
String officeSheetDefaultSheetId(Map<String, Object?> sections) {
  final order = asJsonList(asJsonMap(sections['index'])?['order']);
  if (order != null) {
    for (final id in order) {
      final name = asJsonString(id);
      if (name != null && sections.containsKey(name)) return name;
    }
  }
  final worksheet = sections.keys.where((k) => k.startsWith('sh_')).toList()
    ..sort();
  return worksheet.isEmpty ? 'sh_1' : worksheet.first;
}

/// `status 2` 允许的重放次数上限（防止服务端 rev 一直变时无限重发）。
const int kOfficeSheetMaxStaleReplays = 3;

/// `.osheet` 编辑状态机：乐观显示 + 未确认队列 + ack 三态 + status 2 四步重放。
class OfficeSheetEditController extends ChangeNotifier {
  OfficeSheetEditController({
    required this.sink,
    required Map<int, Map<int, Object?>> base,
    required int initialRev,
    this.sheetId = 'sh_1',
    this.source,
  })  : _base = <int, Map<int, Object?>>{
          for (final e in base.entries) e.key: <int, Object?>{...e.value},
        },
        _rev = initialRev < 0 ? 0 : initialRev {
    _sub = sink.incoming.listen(handleEvent);
  }

  final OfficeSheetCommandSink sink;

  /// 要写的表（`sh_1`）。
  final String sheetId;

  /// `source` 字段（官方是编辑来源标签；本批给一个稳定的本地标识）。
  final String? source;

  final Map<int, Map<int, Object?>> _base;

  /// 远端广播里"命中本地未确认格子"而**暂缓**应用的改动（四步重放的 remoteQueue）。
  final List<OfficeSheetChange> _remoteQueue = <OfficeSheetChange>[];

  /// 未确认队列（FIFO）；队首可能正在飞。
  final List<OfficeSheetPendingEdit> _pending = <OfficeSheetPendingEdit>[];

  OfficeSheetPendingEdit? _inFlight;

  /// 是否显示本地乐观覆盖（status 2 的第一步"undo"会把它关掉）。
  bool _overlayVisible = true;

  int _rev;
  int _staleReplays = 0;
  int _undoCount = 0;
  int _remoteReplayed = 0;
  int _confirmed = 0;
  String? _sendError;
  bool _disposed = false;

  StreamSubscription<OfficeCollabEvent>? _sub;

  /// 门控：只有 `gate.editable` 才允许编辑（页面设置；默认 false = 只读）。
  bool editable = false;

  /// 最近的失败/拒绝（可解释；页面据此渲染"哪一格、为什么"）。
  final List<OfficeSheetEditFailure> failures = <OfficeSheetEditFailure>[];

  /// 降级/诊断登记（与批 1 的 [OfficeSheetRenderReport] 同构：不认识的东西不静默丢）。
  final Map<String, int> ignoredRemoteCommands = <String, int>{};
  final Map<String, int> ignoredRemoteOtherSheet = <String, int>{};
  int malformedRemoteCommands = 0;

  int get rev => _rev;
  int get pendingCount => _pending.length + (_inFlight == null ? 0 : 1);
  int get inFlightCount => _inFlight == null ? 0 : 1;
  int get pendingCellCount {
    final cells = <String>{};
    for (final p in _pending) {
      cells.addAll(p.cellLabels);
    }
    final flying = _inFlight;
    if (flying != null) cells.addAll(flying.cellLabels);
    return cells.length;
  }

  int get staleReplays => _staleReplays;
  int get undoCount => _undoCount;
  int get remoteReplayed => _remoteReplayed;
  int get confirmedCount => _confirmed;
  int get remoteQueueLength => _remoteQueue.length;

  /// 通道错误（超时/异常）——有值时**停止自动重发**，改动仍在队列里。
  String? get sendError => _sendError;

  bool get canEdit => editable && !_disposed;

  /// 单元格显示值：未确认覆盖 > base（远端/文件）。
  OfficeSheetCellValue valueAt(int row, int col) {
    final overlay = _overlayVisible ? _pendingFor(row, col) : null;
    if (overlay != null) {
      return OfficeSheetCellValue(overlay, present: true, pending: true);
    }
    final rowMap = _base[row];
    if (rowMap != null && rowMap.containsKey(col)) {
      return OfficeSheetCellValue(rowMap[col], present: true, pending: false);
    }
    return const OfficeSheetCellValue(null, present: false, pending: false);
  }

  bool isPending(int row, int col) =>
      _overlayVisible && _pendingFor(row, col) != null;

  Object? _pendingFor(int row, int col) {
    for (var i = _pending.length - 1; i >= 0; i--) {
      final hit = _lastChangeFor(_pending[i].changes, row, col);
      if (hit != null) return hit.value;
    }
    final flying = _inFlight;
    if (flying != null) {
      final hit = _lastChangeFor(flying.changes, row, col);
      if (hit != null) return hit.value;
    }
    return null;
  }

  static OfficeSheetChange? _lastChangeFor(
    List<OfficeSheetChange> changes,
    int row,
    int col,
  ) {
    for (var i = changes.length - 1; i >= 0; i--) {
      final c = changes[i];
      if (c.row == row && c.col == col) return c;
    }
    return null;
  }

  bool _pendingCovers(int row, int col) => isPending(row, col);

  // ---------------------------------------------------------------- 本地编辑

  /// 提交一格编辑（**乐观显示立刻生效**，命令进入未确认队列）。
  Future<void> editCell(int row, int col, Object? value) =>
      stage(<OfficeSheetChange>[OfficeSheetChange(row, col, value)]);

  /// 提交多格（粘贴式；`changes` 支持多元素——探针已确证）。
  Future<void> stage(List<OfficeSheetChange> changes) async {
    if (changes.isEmpty || _disposed) return;
    _sendError = null;
    _overlayVisible = true;
    _pending.add(OfficeSheetPendingEdit(List<OfficeSheetChange>.of(changes)));
    // 乐观显示立刻可见。
    notifyListeners();
    _pump();
  }

  /// 通道出错后用户显式重试（把整条队列继续推下去）。
  Future<void> retryPending() async {
    if (_disposed || _pending.isEmpty) return;
    _sendError = null;
    notifyListeners();
    _pump();
  }

  /// 丢弃所有未确认改动（**只有用户显式"放弃"才允许调用**；不用于失败路径）。
  void discardPending() {
    if (_pending.isEmpty && _inFlight == null) return;
    _pending.clear();
    _inFlight = null;
    _sendError = null;
    notifyListeners();
  }

  void _pump() {
    if (_disposed || _sendError != null) return;
    if (_inFlight != null || _pending.isEmpty) return;
    final next = _pending.removeAt(0);
    _inFlight = next;
    next.attempts++;
    final targetRev = _rev + 1;
    final payload = officeSheetValueCommand(
      sheetId: sheetId,
      changes: next.changes,
      rev: targetRev,
      source: source,
    );
    notifyListeners();
    unawaited(_send(next, targetRev, payload));
  }

  Future<void> _send(
    OfficeSheetPendingEdit pending,
    int sentRev,
    Map<String, Object?> payload,
  ) async {
    Object? raw;
    try {
      raw = await sink.sendSet(payload);
    } on Object catch (e) {
      if (_disposed) return;
      // **绝不丢用户输入**：命令回到队首，等显式重试。
      _inFlight = null;
      _pending.insert(0, pending);
      _sendError = '$e';
      failures.add(
        OfficeSheetEditFailure(
          kind: OfficeSheetEditFailureKind.transport,
          changes: pending.changes,
          detail: '$e',
          attempts: pending.attempts,
        ),
      );
      notifyListeners();
      return;
    }
    if (_disposed) return;
    final ack = officeSheetSetAck(raw);
    switch (ack.status) {
      case OfficeSheetSetStatus.ok:
        _inFlight = null;
        _confirmed++;
        _rev = _max(_rev, ack.currentRev ?? sentRev);
        _commit(pending.changes);
        // 本地写入已被服务端接受：此前压住的远端值已被我们的写入覆盖，丢弃。
        _dropDeferredFor(pending.changes);
        notifyListeners();
        _pump();
      case OfficeSheetSetStatus.rejected:
        _inFlight = null;
        _rev = _max(_rev, ack.currentRev ?? _rev);
        // 乐观显示回滚 + 让被压住的远端值显形（我们的写入从未发生）。
        _replayDeferredFor(pending.changes);
        failures.add(
          OfficeSheetEditFailure(
            kind: OfficeSheetEditFailureKind.rejected,
            changes: pending.changes,
            detail: 'status ${ack.statusCode ?? 0}',
            attempts: pending.attempts,
          ),
        );
        notifyListeners();
        _pump();
      case OfficeSheetSetStatus.staleRev:
        _resolveStale(pending, ack);
      case OfficeSheetSetStatus.unknown:
        _inFlight = null;
        _pending.insert(0, pending);
        _sendError = 'ack=${_short(raw)}';
        failures.add(
          OfficeSheetEditFailure(
            kind: OfficeSheetEditFailureKind.malformedAck,
            changes: pending.changes,
            detail: 'ack=${_short(raw)}',
            attempts: pending.attempts,
          ),
        );
        notifyListeners();
    }
  }

  /// **status 2 的四步流程**（官方 `_resolveConflict`，`§B.1`/`§C.2`）：
  /// undo 本地未确认 → 重放 remoteQueue → redo 本地 → `_adjustRev` 重发。
  void _resolveStale(OfficeSheetPendingEdit pending, OfficeSheetSetAck ack) {
    // 1) undo：把本地未确认的乐观覆盖藏起来（显示回到 base）。
    _overlayVisible = false;
    _undoCount++;
    // 2) 重放 remoteQueue：把压在队列里的远端改动apply到 base。
    _replayRemoteQueue();
    // 3) redo：本地未确认改动重新覆盖显示。
    _overlayVisible = true;
    _inFlight = null;
    // 4) _adjustRev(currentRev) 后重发（同一条命令，绝不丢）。
    if (ack.currentRev != null) _rev = ack.currentRev!;
    if (pending.attempts >= kOfficeSheetMaxStaleReplays) {
      _pending.insert(0, pending);
      _sendError = 'status 2 重放 ${pending.attempts} 次仍过期';
      failures.add(
        OfficeSheetEditFailure(
          kind: OfficeSheetEditFailureKind.staleBlocked,
          changes: pending.changes,
          detail: 'revIncoming=${ack.revIncoming}, currentRev=${ack.currentRev}',
          attempts: pending.attempts,
        ),
      );
      notifyListeners();
      return;
    }
    _staleReplays++;
    _pending.insert(0, pending);
    notifyListeners();
    _pump();
  }

  // ---------------------------------------------------------------- 远端广播

  /// 处理服务端推送事件（`set` / `peer`，与 `set` 同形、**无 ack**）。
  void handleEvent(OfficeCollabEvent event) {
    if (event.name != 'set' && event.name != 'peer') return;
    applyRemoteCommand(event.args.isEmpty ? null : event.args.first);
  }

  /// 应用一条远端命令。**不覆盖本地未确认的格子**（压进 remoteQueue）。
  void applyRemoteCommand(Object? command) {
    if (_disposed) return;
    final map = asJsonMap(command);
    if (map == null) {
      malformedRemoteCommands++;
      notifyListeners();
      return;
    }
    final cmd = asJsonString(map['cmd']) ?? '';
    if (cmd != 'value') {
      // 批 2 只应用 `value`；其它命令（`note`/`format`/…）如实登记不猜。
      ignoredRemoteCommands[cmd.isEmpty ? '(no cmd)' : cmd] =
          (ignoredRemoteCommands[cmd.isEmpty ? '(no cmd)' : cmd] ?? 0) + 1;
      notifyListeners();
      return;
    }
    final remoteSheet = asJsonString(map['id']) ?? '';
    if (remoteSheet.isNotEmpty && remoteSheet != sheetId) {
      ignoredRemoteOtherSheet[remoteSheet] =
          (ignoredRemoteOtherSheet[remoteSheet] ?? 0) + 1;
      notifyListeners();
      return;
    }
    final changes = officeSheetChangesOf(map['changes']);
    if (changes == null) {
      malformedRemoteCommands++;
      notifyListeners();
      return;
    }
    // 远端命令也推进服务端 queue.rev：本地下一次发送必须接在它后面。
    final remoteRev = asJsonInt(map['rev']);
    if (remoteRev != null && remoteRev > _rev) _rev = remoteRev;
    var changed = false;
    for (final change in changes) {
      if (_pendingCovers(change.row, change.col)) {
        _remoteQueue.add(change);
        changed = true;
      } else {
        (_base[change.row] ??= <int, Object?>{})[change.col] = change.value;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// 把 remoteQueue 整体应用到 base（status 2 的第 2 步）。
  void _replayRemoteQueue() {
    if (_remoteQueue.isEmpty) return;
    for (final change in _remoteQueue) {
      (_base[change.row] ??= <int, Object?>{})[change.col] = change.value;
      _remoteReplayed++;
    }
    _remoteQueue.clear();
  }

  /// 只回放命中这些格子的暂缓远端值（本地命令被拒绝时）。
  void _replayDeferredFor(List<OfficeSheetChange> local) {
    if (_remoteQueue.isEmpty) return;
    final keys = <String>{for (final c in local) '${c.row},${c.col}'};
    _remoteQueue.removeWhere((remote) {
      if (!keys.contains('${remote.row},${remote.col}')) return false;
      (_base[remote.row] ??= <int, Object?>{})[remote.col] = remote.value;
      _remoteReplayed++;
      return true;
    });
  }

  /// 丢掉命中这些格子的暂缓远端值（本地命令被确认，我们的写入更新）。
  void _dropDeferredFor(List<OfficeSheetChange> local) {
    if (_remoteQueue.isEmpty) return;
    final keys = <String>{for (final c in local) '${c.row},${c.col}'};
    _remoteQueue.removeWhere(
      (remote) => keys.contains('${remote.row},${remote.col}'),
    );
  }

  void _commit(List<OfficeSheetChange> changes) {
    for (final change in changes) {
      (_base[change.row] ??= <int, Object?>{})[change.col] = change.value;
    }
  }

  static int _max(int a, int b) => a > b ? a : b;

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sub?.cancel());
    _sub = null;
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// 输入文本 → `v` 的 JSON 形态
// ---------------------------------------------------------------------------

/// 把编辑框文本转成 `v`。
///
/// **证据边界**：批 2 真机探针确证了"字符串 / 数字 / 布尔 / 公式字符串 / 空串"
/// 五种写入形态都能被服务端接受并按原 JSON 存回（见 `docs/office-sheet-ui-2.md` §①），
/// 但官方 UI"用户输入 `42` 时到底发数字还是字符串"**没有取证**。本批采用**保守规则**
/// （报告 §⑫ 登记为待真机确认）：
///
///   * 空文本 → `''`（探针确证可接受的清空形态）；
///   * 以 `=` 开头 → 原样字符串（公式是字符串，服务端不求值，批 1 结论）；
///   * 原来就是数字/布尔的格子，且文本能精确解析成同类型 → 保持该类型；
///   * 其它一律字符串（**不猜**用户意图、不做隐式数字化）。
Object? officeSheetValueFromText(String text, {Object? previous}) {
  if (text.isEmpty) return '';
  if (text.startsWith('=')) return text;
  if (previous is num) {
    final n = num.tryParse(text);
    if (n != null && '$n' == text) return n;
    if (previous is int && int.tryParse(text) != null) return int.parse(text);
  }
  if (previous is bool) {
    if (text == 'true') return true;
    if (text == 'false') return false;
  }
  return text;
}

/// 编辑失败 → 诊断串（开发者可读；UI 文案由页面走 `dataText`）。
String officeSheetDescribeFailure(OfficeSheetEditFailure failure) {
  switch (failure.kind) {
    case OfficeSheetEditFailureKind.rejected:
      return '${failure.cellsLabel} 被服务端拒绝（${failure.detail}）';
    case OfficeSheetEditFailureKind.staleBlocked:
      return '${failure.cellsLabel} 版本一直过期，改动仍保留在待确认队列'
          '（${failure.detail}，重放 ${failure.attempts} 次）';
    case OfficeSheetEditFailureKind.transport:
      return '${failure.cellsLabel} 发送失败：${failure.detail}（改动仍在待确认队列）';
    case OfficeSheetEditFailureKind.malformedAck:
      return '${failure.cellsLabel} 的服务端结果无法确认：${failure.detail}'
          '（改动仍在待确认队列）';
  }
}
