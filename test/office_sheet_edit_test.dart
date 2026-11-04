// Office C′ 表格（Sheet）批 2 —— 编辑链路（`value`/`set`）离线测试。
//
// 无网络、无设备、无构建：
//   * 纯逻辑/状态机走 `_FakeSink`（脚本化 ack + 注入 peer 事件）；
//   * 真实帧用真机探针产物 `test/fixtures/office_sheet_ui2/set_frames.json`
//     （LAN NAS 上一次丢弃式草稿的原始帧，见 `docs/office-sheet-ui-2.md` §①），
//     经 `FakeCollabTransport` 回放，证明 `emit('set')` 的接线与三态解析；
//   * 页面级用 `_ScriptedSession`（覆写 `sendSet`/`incoming`，不碰 socket）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_api.dart';
import 'package:synhub/src/data/office_collab/office_collab_client.dart';
import 'package:synhub/src/features/office/office_sheet_edit.dart';
import 'package:synhub/src/features/office/office_sheet_page.dart';
import 'package:synhub/src/features/office/office_sheet_view.dart';
import 'package:synhub/src/features/office/office_write_gate.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'office_collab_client_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

// ---------------------------------------------------------------------------
// 夹具
// ---------------------------------------------------------------------------

Map<String, Object?> _sections() => <String, Object?>{
  'index': <String, Object?>{
    'gcVer': 1,
    'maxIndex': 1,
    'order': <Object?>['sh_1'],
    'schemaVersion': 5,
    'sheets': <String, Object?>{
      'sh_1': <String, Object?>{'title': 'C3Spike'},
    },
    'ver': 7,
  },
  'style': <String, Object?>{
    'alignments': <Object?>[],
    'borders': <Object?>[],
    'fills': <Object?>[],
    'fonts': <Object?>[],
    'numberFormats': <Object?>[],
    'styles': <Object?>[],
  },
  'sh_1': <String, Object?>{
    'cells': <String, Object?>{
      '0': <String, Object?>{
        '0': <String, Object?>{'v': 'C3SPIKE-SHEET-BASE'},
      },
    },
    'colCount': 8,
    'rowCount': 12,
    'rows': <String, Object?>{},
    'cols': <String, Object?>{},
    'global': <String, Object?>{'h': 22, 'w': 96},
    'mergeCells': <Object?>[],
  },
};

Map<int, Map<int, Object?>> _base() =>
    officeSheetBaseCells(_sections(), 'sh_1');

/// Socket.IO ack 的三种真实形状（探针原文，见报告 §①）。
const List<Object?> kAckOk = <Object?>[1, 1, 1, null];
const List<Object?> kAckStale = <Object?>[99, 2, 2];
const List<Object?> kAckRejected = <Object?>[4, 3, 0];

/// 脚本化发送通道：每次 `sendSet` 从 [script] 取一个 ack；耗尽后回"回声 rev 成功"。
class _FakeSink implements OfficeSheetCommandSink {
  _FakeSink({List<Object?>? script}) : script = script ?? <Object?>[];

  final List<Object?> script;
  final List<Map<String, Object?>> sent = <Map<String, Object?>>[];
  final StreamController<OfficeCollabEvent> _events =
      StreamController<OfficeCollabEvent>.broadcast();
  int _cursor = 0;

  /// 发送前抛出的异常（模拟超时/断链）。
  Object? throwError;

  /// 发送前等待（模拟在飞）。
  Completer<void>? gate;

  @override
  Future<Object?> sendSet(Map<String, Object?> payload) async {
    sent.add(<String, Object?>{...payload});
    final g = gate;
    if (g != null) await g.future;
    if (throwError != null) throw throwError!;
    if (_cursor < script.length) return script[_cursor++];
    return <Object?>[payload['rev'], payload['rev'], 1, null];
  }

  @override
  Stream<OfficeCollabEvent> get incoming => _events.stream;

  void push(String name, Object? arg) =>
      _events.add(OfficeCollabEvent(name, <Object?>[arg]));

  Future<void> close() => _events.close();
}

Future<void> _settle([int turns = 6]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

OfficeCollabClient _fakeClient() => OfficeCollabClient(
  target: OfficeCollabTarget(
    baseUrl: Uri.parse('https://nas.example.com:5001'),
    objectId: '1028_F2OS4D955D3VP39MCL5GE86HGG.sh',
    linkId: '19yfWkVZHIH3a47vkOhJ0YKmOeD9xPl2',
  ),
  transport: FakeCollabTransport(
    ReplayScript(<ReplayExchange>[], handshakeBody: '0{"sid":"<redacted>"}'),
  ),
  sessionCookieId: 'test-sid',
);

/// 可脚本化的会话：不接 socket，直接受控 ack/事件流（页面级用例用）。
class _ScriptedSession extends OfficeSheetSession {
  _ScriptedSession({this.acks = const <Object?>[], this.failWith})
    : super(
        client: _fakeClient(),
        initAck: const <Object?>['7cf2e91ff8cbf8e9', 0, <Object?>[]],
      );

  final List<Object?> acks;
  final Object? failWith;
  final List<Map<String, Object?>> sent = <Map<String, Object?>>[];
  final StreamController<OfficeCollabEvent> events =
      StreamController<OfficeCollabEvent>.broadcast();

  /// 未完成时把 ack 挂起，用来观察"在飞/未确认"态。
  Completer<void>? gate;

  int _cursor = 0;

  @override
  Future<Object?> sendSet(Map<String, Object?> payload) async {
    sent.add(<String, Object?>{...payload});
    final g = gate;
    if (g != null) await g.future;
    if (failWith != null) throw failWith!;
    if (_cursor < acks.length) return acks[_cursor++];
    return <Object?>[payload['rev'], payload['rev'], 1, null];
  }

  @override
  Stream<OfficeCollabEvent> get incoming => events.stream;
}

class _Backend implements OfficeSheetBackend {
  _Backend({required this.session, this.gate = _allowAll});

  final OfficeSheetSession session;
  final OfficeWriteGateInputs gate;

  @override
  Future<OfficeWriteGateInputs> loadGate() async => gate;

  @override
  Future<OfficeSheetSnapshot> loadSnapshot() async => OfficeSheetSnapshot(
    sections: _sections(),
    version: 7,
    raw: <String, dynamic>{'ntype': 'sheet'},
  );

  @override
  Future<OfficeSheetSession> openSession() async => session;

  @override
  Future<void> closeSession(OfficeSheetSession session) async =>
      session.close();
}

const OfficeWriteGateInputs _allowAll = OfficeWriteGateInputs(
  canWrite: true,
  canComment: true,
  schemaMobile: 2003,
);

Widget _viewHarness(OfficeSheetEditController edit) => MaterialApp(theme: AppTheme.dark(), 
  home: Scaffold(
    body: OfficeSheetView(sections: _sections(), edit: edit),
  ),
);

Widget _pageHarness(_Backend backend, {VoidCallback? onFallback}) =>
    ProviderScope(
      child: MaterialApp(theme: AppTheme.dark(), 
        home: OfficeSheetPage(
          request: const OfficeSheetRequest(
            fileId: '1',
            name: 'a.osheet',
            permanentLink: '19yf',
          ),
          backend: backend,
          onFallbackToNativePreview: onFallback,
        ),
      ),
    );

void main() {
  group('E1. value 命令 / changes / ack 形状（纯函数，与探针帧同形）', () {
    test('changes 三元组：0 基 [row, col, value]，多元素原样序列化', () {
      final payload = officeSheetValueCommand(
        sheetId: 'sh_1',
        changes: const <OfficeSheetChange>[
          OfficeSheetChange(0, 2, 'P2SET-r0c2'),
          OfficeSheetChange(2, 0, 'P2SET-r2c0'),
          OfficeSheetChange(3, 1, '=SUM(A1:B1)'),
          OfficeSheetChange(3, 2, true),
          OfficeSheetChange(3, 3, ''),
        ],
        rev: 2,
        source: 'dsh-probe2',
      );
      expect(payload['cmd'], 'value');
      expect(payload['id'], 'sh_1');
      expect(payload['rev'], 2);
      expect(payload['source'], 'dsh-probe2');
      expect(payload['changes'], <Object?>[
        <Object?>[0, 2, 'P2SET-r0c2'],
        <Object?>[2, 0, 'P2SET-r2c0'],
        <Object?>[3, 1, '=SUM(A1:B1)'],
        <Object?>[3, 2, true],
        <Object?>[3, 3, ''],
      ]);
      // 与真机原文逐字同形（探针 [2] 帧）。
      expect(
        jsonEncode(payload),
        '{"cmd":"value","id":"sh_1","changes":[[0,2,"P2SET-r0c2"],'
        '[2,0,"P2SET-r2c0"],[3,1,"=SUM(A1:B1)"],[3,2,true],[3,3,""]],'
        '"source":"dsh-probe2","rev":2}',
      );
    });

    test('rev 缺失/非正/空 changes 一律抛（服务端 !rev → status 2）', () {
      expect(
        () => officeSheetValueCommand(
          sheetId: 'sh_1',
          changes: const <OfficeSheetChange>[OfficeSheetChange(0, 0, 'x')],
          rev: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => officeSheetValueCommand(
          sheetId: 'sh_1',
          changes: const <OfficeSheetChange>[],
          rev: 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => officeSheetValueCommand(
          sheetId: '',
          changes: const <OfficeSheetChange>[OfficeSheetChange(0, 0, 'x')],
          rev: 1,
        ),
        throwsArgumentError,
      );
    });

    test('changes 解析：形状不对必须返回 null（不许当空）', () {
      expect(
        officeSheetChangesOf(<Object?>[
          <Object?>[0, 1, 'v'],
        ]),
        hasLength(1),
      );
      expect(
        officeSheetChangesOf(<Object?>[
          <Object?>[0, 1],
        ]),
        isNull,
      );
      expect(
        officeSheetChangesOf(<Object?>[
          <Object?>['x', 1, 'v'],
        ]),
        isNull,
      );
      expect(officeSheetChangesOf(<String, Object?>{}), isNull);
      expect(officeSheetChangesOf(null), isNull);
      expect(officeSheetChangesOf(<Object?>[]), isEmpty);
    });

    test('ack 三态：探针原文 [1,1,1,null] / [99,2,2] / [null,4,2] / [4,3,0]', () {
      final ok = officeSheetSetAck(kAckOk);
      expect(ok.status, OfficeSheetSetStatus.ok);
      expect(ok.revIncoming, 1);
      expect(ok.currentRev, 1);
      expect(ok.statusCode, 1);

      final stale = officeSheetSetAck(kAckStale);
      expect(stale.status, OfficeSheetSetStatus.staleRev);
      expect(stale.revIncoming, 99);
      expect(stale.currentRev, 2);

      final noRev = officeSheetSetAck(<Object?>[null, 4, 2]);
      expect(noRev.status, OfficeSheetSetStatus.staleRev);
      expect(noRev.revIncoming, isNull);

      final rejected = officeSheetSetAck(kAckRejected);
      expect(rejected.status, OfficeSheetSetStatus.rejected);

      final malformed = officeSheetSetAck(<Object?>[1, 1]);
      expect(malformed.status, OfficeSheetSetStatus.unknown);
      expect(malformed.malformed, isTrue);
      expect(officeSheetSetAck(null).malformed, isTrue);
      expect(
        officeSheetSetAck(<Object?>[
          <Object?>[1, 1, 1, null],
        ]).status,
        OfficeSheetSetStatus.ok,
      );
    });

    test('输入文本 → v：公式原样、原有数字/布尔保持类型、空=清空', () {
      expect(officeSheetValueFromText('=SUM(A1:B1)'), '=SUM(A1:B1)');
      expect(officeSheetValueFromText('', previous: 'x'), '');
      expect(officeSheetValueFromText('42', previous: 41), 42);
      expect(officeSheetValueFromText('42.5', previous: 1.0), 42.5);
      expect(officeSheetValueFromText('true', previous: false), isTrue);
      // 原类型不匹配 → 字符串（不猜）。
      expect(officeSheetValueFromText('42', previous: 'x'), '42');
    });
  });

  group('E2. 乐观显示 + ack 三态（状态机）', () {
    test('status 1：乐观值落地、出队、rev 用 ack 的 currentRev', () async {
      final sink = _FakeSink()..gate = Completer<void>();
      final c = OfficeSheetEditController(
        sink: sink,
        base: _base(),
        initialRev: 0,
      );
      c.editable = true;
      unawaited(c.editCell(0, 0, 'X'));
      await _settle();
      // 乐观显示：立即可见且标记未确认。
      expect(c.valueAt(0, 0).value, 'X');
      expect(c.valueAt(0, 0).pending, isTrue);
      expect(c.pendingCount, 1);
      expect(sink.sent.single['rev'], 1);
      sink.gate!.complete();
      sink.gate = null;
      await _settle();
      expect(c.pendingCount, 0);
      expect(c.valueAt(0, 0).pending, isFalse);
      expect(c.valueAt(0, 0).value, 'X');
      expect(c.rev, 1);
      expect(c.confirmedCount, 1);
      expect(sink.sent.single['changes'], <Object?>[
        <Object?>[0, 0, 'X'],
      ]);
      c.dispose();
      await sink.close();
    });

    test('status 0：乐观显示回滚 + 可解释失败（哪一格/为什么）', () async {
      final sink = _FakeSink(script: <Object?>[kAckRejected]);
      final c = OfficeSheetEditController(
        sink: sink,
        base: _base(),
        initialRev: 3,
      );
      c.editable = true;
      await c.editCell(0, 1, 'REJ');
      await _settle();
      expect(c.pendingCount, 0);
      // 回滚：原本没有值的 B1 回到"无值"。
      expect(c.valueAt(0, 1).present, isFalse);
      expect(c.failures, hasLength(1));
      expect(c.failures.last.kind, OfficeSheetEditFailureKind.rejected);
      expect(c.failures.last.cellsLabel, 'B1');
      expect(officeSheetDescribeFailure(c.failures.last), contains('B1'));
      expect(officeSheetDescribeFailure(c.failures.last), contains('status 0'));
      expect(c.rev, 3);
      c.dispose();
      await sink.close();
    });

    test('发送异常/超时：**绝不丢输入**（留在队列 + 可重试）', () async {
      final sink = _FakeSink()..throwError = TimeoutException('ack timeout');
      final c = OfficeSheetEditController(
        sink: sink,
        base: _base(),
        initialRev: 0,
      );
      c.editable = true;
      await c.editCell(2, 2, 'KEEP');
      await _settle();
      expect(c.pendingCount, 1, reason: '超时后改动必须仍在未确认队列');
      expect(c.valueAt(2, 2).value, 'KEEP');
      expect(c.sendError, isNotNull);
      expect(c.failures.last.kind, OfficeSheetEditFailureKind.transport);

      sink.throwError = null;
      await c.retryPending();
      await _settle();
      expect(c.pendingCount, 0);
      expect(c.valueAt(2, 2).value, 'KEEP');
      expect(c.valueAt(2, 2).pending, isFalse);
      c.dispose();
      await sink.close();
    });

    test('ack 形状不认：结果未知 → 留在队列 + 明确登记（不假装成功）', () async {
      final sink = _FakeSink(
        script: <Object?>[
          <String, Object?>{'unexpected': true},
        ],
      );
      final c = OfficeSheetEditController(
        sink: sink,
        base: _base(),
        initialRev: 0,
      );
      c.editable = true;
      await c.editCell(1, 1, 'MAL');
      await _settle();
      expect(c.pendingCount, 1);
      expect(c.sendError, isNotNull);
      expect(c.failures.last.kind, OfficeSheetEditFailureKind.malformedAck);
      c.dispose();
      await sink.close();
    });

    test(
      'status 2：undo → 重放 remoteQueue → redo → _adjustRev 重发（不丢输入）',
      () async {
        final sink = _FakeSink(script: <Object?>[kAckStale, kAckOk]);
        final c = OfficeSheetEditController(
          sink: sink,
          base: _base(),
          initialRev: 0,
        );
        c.editable = true;
        await c.editCell(0, 0, 'LOCAL');
        await _settle();
        // 第一次 rev=1 → status 2（服务端 currentRev=2）；重发必须是 3。
        expect(sink.sent, hasLength(2));
        expect(sink.sent[0]['rev'], 1);
        expect(sink.sent[1]['rev'], 3, reason: '_adjustRev(currentRev)+重发');
        expect(
          sink.sent[1]['changes'],
          sink.sent[0]['changes'],
          reason: '重发的必须是**同一条**改动（不许丢）',
        );
        expect(c.staleReplays, 1);
        expect(c.undoCount, 1);
        expect(c.pendingCount, 0);
        expect(c.valueAt(0, 0).value, 'LOCAL');
        c.dispose();
        await sink.close();
      },
    );

    test('status 2 一直过期：重放上限后停下，但改动仍在队列且可解释', () async {
      final sink = _FakeSink(
        script: <Object?>[
          <Object?>[1, 2, 2],
          <Object?>[2, 2, 2],
          <Object?>[3, 2, 2],
          <Object?>[4, 2, 2],
        ],
      );
      final c = OfficeSheetEditController(
        sink: sink,
        base: _base(),
        initialRev: 0,
      );
      c.editable = true;
      await c.editCell(4, 0, 'LOOP');
      await _settle(12);
      expect(c.pendingCount, 1, reason: '重放失败也不许丢用户输入');
      expect(c.sendError, isNotNull);
      expect(c.failures.last.kind, OfficeSheetEditFailureKind.staleBlocked);
      expect(c.valueAt(4, 0).value, 'LOOP');
      c.dispose();
      await sink.close();
    });

    test('多格提交（粘贴式）：一条命令多元素 + 未确认格子计数', () async {
      final sink = _FakeSink()..gate = Completer<void>();
      final c = OfficeSheetEditController(
        sink: sink,
        base: _base(),
        initialRev: 0,
      );
      c.editable = true;
      unawaited(
        c.stage(const <OfficeSheetChange>[
          OfficeSheetChange(1, 1, 'a'),
          OfficeSheetChange(1, 2, 'b'),
          OfficeSheetChange(2, 1, 'c'),
        ]),
      );
      await _settle();
      expect(c.pendingCount, 1);
      expect(c.pendingCellCount, 3);
      expect(sink.sent.single['changes'], hasLength(3));
      sink.gate!.complete();
      sink.gate = null;
      await _settle(10);
      expect(c.pendingCount, 0);
      expect(c.valueAt(1, 2).value, 'b');
      c.dispose();
      await sink.close();
    });

    test('队列串联：第二个编辑等第一个 ack 后才发（rev 连续）', () async {
      final sink = _FakeSink();
      sink.gate = Completer<void>();
      final c = OfficeSheetEditController(
        sink: sink,
        base: _base(),
        initialRev: 0,
      );
      c.editable = true;
      final f1 = c.editCell(0, 0, 'one');
      final f2 = c.editCell(0, 1, 'two');
      await _settle();
      expect(sink.sent, hasLength(1), reason: '同一时刻只允许一条在飞');
      expect(c.pendingCount, 2);
      sink.gate!.complete();
      sink.gate = null;
      await Future.wait(<Future<void>>[f1, f2]);
      await _settle(10);
      expect(sink.sent, hasLength(2));
      expect(sink.sent[1]['rev'], 2);
      expect(c.pendingCount, 0);
      c.dispose();
      await sink.close();
    });
  });

  group('E3. 远端广播（无 ack）：应用 + 不与本地未确认打架', () {
    test('干净格子：远端改动直接进 base，并推进本地 rev', () async {
      final sink = _FakeSink();
      final c = OfficeSheetEditController(
        sink: sink,
        base: _base(),
        initialRev: 0,
      );
      c.editable = true;
      sink.push('set', <String, Object?>{
        'cmd': 'value',
        'id': 'sh_1',
        'changes': <Object?>[
          <Object?>[0, 3, 'REMOTE'],
        ],
        'rev': 9,
      });
      await _settle();
      expect(c.valueAt(0, 3).value, 'REMOTE');
      expect(c.valueAt(0, 3).pending, isFalse);
      // 下一次本地发送必须接在远端 rev 之后（10）。
      await c.editCell(1, 1, 'MINE');
      await _settle();
      expect(sink.sent.single['rev'], 10);
      c.dispose();
      await sink.close();
    });

    test('peer 事件名是 set（探针原文）；无 ack、同形', () async {
      final sink = _FakeSink();
      final c = OfficeSheetEditController(
        sink: sink,
        base: _base(),
        initialRev: 0,
      );
      c.editable = true;
      // `peer` 事件名也接受（selection/update 等协作光标命令，本批忽略）。
      sink.push('peer', <String, Object?>{'cmd': 'select', 'row': 0, 'col': 0});
      sink.push('set', <String, Object?>{
        'cmd': 'value',
        'id': 'sh_1',
        'changes': <Object?>[
          <Object?>[2, 2, 'P'],
        ],
        'rev': 1,
      });
      await _settle();
      expect(c.valueAt(2, 2).value, 'P');
      expect(c.ignoredRemoteCommands['select'], 1);
      expect(c.malformedRemoteCommands, 0);
      c.dispose();
      await sink.close();
    });

    test('**不覆盖本地未确认格子**：压进 remoteQueue，本地值继续显示', () async {
      final sink = _FakeSink()..gate = Completer<void>();
      final c = OfficeSheetEditController(
        sink: sink,
        base: _base(),
        initialRev: 0,
      );
      c.editable = true;
      unawaited(c.editCell(0, 0, 'LOCAL'));
      await _settle();
      expect(c.isPending(0, 0), isTrue);
      sink.push('set', <String, Object?>{
        'cmd': 'value',
        'id': 'sh_1',
        'changes': <Object?>[
          <Object?>[0, 0, 'REMOTE'],
        ],
        'rev': 5,
      });
      await _settle();
      expect(c.valueAt(0, 0).value, 'LOCAL', reason: '远端不许覆盖本地未确认值');
      expect(c.valueAt(0, 0).pending, isTrue);
      expect(c.remoteQueueLength, 1);
      // 本地被确认后，过期的远端值被丢弃（我们的写入已在服务端生效）。
      sink.gate!.complete();
      sink.gate = null;
      await _settle(10);
      expect(c.valueAt(0, 0).value, 'LOCAL');
      expect(c.remoteQueueLength, 0);
      c.dispose();
      await sink.close();
    });

    test('status 2 的四步里 remoteQueue 被重放到 base（undo→replay→redo）', () async {
      // 第一个 ack 先挂起，确保远端广播发生在"本地在飞未确认"期间。
      final sink = _FakeSink(script: <Object?>[kAckStale, kAckOk])
        ..gate = Completer<void>();
      final c = OfficeSheetEditController(
        sink: sink,
        base: _base(),
        initialRev: 0,
      );
      c.editable = true;
      unawaited(c.editCell(0, 0, 'LOCAL'));
      await _settle();
      sink.push('set', <String, Object?>{
        'cmd': 'value',
        'id': 'sh_1',
        'changes': <Object?>[
          <Object?>[0, 0, 'REMOTE'],
        ],
        'rev': 2,
      });
      await _settle();
      expect(c.remoteQueueLength, 1);
      expect(c.valueAt(0, 0).value, 'LOCAL');
      // 放行第一个 ack = status 2 → 触发四步：remoteQueue 落到 base，本地值 redo 回显示。
      sink.gate!.complete();
      sink.gate = null;
      await _settle(12);
      expect(c.undoCount, 1);
      expect(c.remoteReplayed, 1);
      expect(c.valueAt(0, 0).value, 'LOCAL');
      expect(c.remoteQueueLength, 0);
      expect(sink.sent, hasLength(2));
      expect(sink.sent[1]['rev'], 3, reason: '_adjustRev(currentRev)+重发');
      c.dispose();
      await sink.close();
    });

    test('本地被拒绝时，暂缓的远端值必须显形（我们的写入从未发生）', () async {
      final sink = _FakeSink(script: <Object?>[kAckRejected])
        ..gate = Completer<void>();
      final c = OfficeSheetEditController(
        sink: sink,
        base: _base(),
        initialRev: 0,
      );
      c.editable = true;
      unawaited(c.editCell(0, 0, 'LOCAL'));
      await _settle();
      expect(c.valueAt(0, 0).value, 'LOCAL');
      sink.push('set', <String, Object?>{
        'cmd': 'value',
        'id': 'sh_1',
        'changes': <Object?>[
          <Object?>[0, 0, 'REMOTE'],
        ],
        'rev': 4,
      });
      await _settle();
      expect(c.remoteQueueLength, 1);
      expect(c.valueAt(0, 0).value, 'LOCAL', reason: '未确认期间本地值优先');
      // 在飞 ack = status 0（拒绝）→ 本地回滚，被压住的远端值显形。
      sink.gate!.complete();
      sink.gate = null;
      await _settle(10);
      expect(c.pendingCount, 0);
      expect(c.valueAt(0, 0).value, 'REMOTE', reason: '本地写入从未发生，远端值必须显形');
      expect(c.remoteQueueLength, 0);
      expect(c.failures.last.kind, OfficeSheetEditFailureKind.rejected);
      c.dispose();
      await sink.close();
    });

    test('别的表 / 别的命令：只登记不猜（不静默丢）', () async {
      final sink = _FakeSink();
      final c = OfficeSheetEditController(
        sink: sink,
        base: _base(),
        initialRev: 0,
      );
      c.editable = true;
      c.applyRemoteCommand(<String, Object?>{
        'cmd': 'value',
        'id': 'sh_9',
        'changes': <Object?>[
          <Object?>[0, 0, 'OTHER'],
        ],
        'rev': 3,
      });
      c.applyRemoteCommand(<String, Object?>{
        'cmd': 'note',
        'id': 'sh_1',
        'changes': <Object?>[],
      });
      c.applyRemoteCommand(<String, Object?>{'cmd': 'value', 'id': 'sh_1'});
      expect(c.valueAt(0, 0).value, 'C3SPIKE-SHEET-BASE');
      expect(c.ignoredRemoteOtherSheet['sh_9'], 1);
      expect(c.ignoredRemoteCommands['note'], 1);
      expect(c.malformedRemoteCommands, 1);
      c.dispose();
      await sink.close();
    });
  });

  group('E4. 可编辑网格（widget）：格子 → 输入组件 → 提交', () {
    testWidgets('点格子 → 输入组件；提交生成 value 命令；未确认可见标记', (tester) async {
      final sink = _FakeSink()..gate = Completer<void>();
      final c = OfficeSheetEditController(
        sink: sink,
        base: _base(),
        initialRev: 0,
      )..editable = true;
      addTearDown(c.dispose);
      addTearDown(sink.close);

      await tester.pumpWidget(_viewHarness(c));
      expect(find.text('C3SPIKE-SHEET-BASE'), findsOneWidget);

      await tester.tap(find.byKey(const Key('office-sheet-cell-hit-0-0')));
      // 单元格同时挂 onTap/onDoubleTap：tap 要等双击判定窗口过去。
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byKey(const Key('office-sheet-cell-input-0-0')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('office-sheet-cell-input-0-0')),
        'EDITED',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(sink.sent.single['cmd'], 'value');
      expect(sink.sent.single['changes'], <Object?>[
        <Object?>[0, 0, 'EDITED'],
      ]);
      // 乐观显示 + 未确认标记（在飞未确认）。
      expect(find.text('EDITED'), findsOneWidget);
      await tester.pump();
      expect(
        find.byKey(const Key('office-sheet-cell-pending-0-0')),
        findsOneWidget,
      );
      sink.gate!.complete();
      sink.gate = null;
      await tester.pump(const Duration(milliseconds: 20));
    });

    testWidgets('只读（门控不允）→ 没有点击入口，也没有输入组件', (tester) async {
      final sink = _FakeSink();
      final c = OfficeSheetEditController(
        sink: sink,
        base: _base(),
        initialRev: 0,
      ); // editable 默认 false
      addTearDown(c.dispose);
      addTearDown(sink.close);

      await tester.pumpWidget(_viewHarness(c));
      expect(find.byKey(const Key('office-sheet-cell-hit-0-0')), findsNothing);
      await tester.tap(find.byKey(const Key('office-sheet-cell-0-0')));
      await tester.pump();
      expect(
        find.byKey(const Key('office-sheet-cell-input-0-0')),
        findsNothing,
      );
      expect(sink.sent, isEmpty);
      expect(c.canEdit, isFalse);
    });

    testWidgets('远端改动会刷新网格（view 订阅编辑层）', (tester) async {
      final sink = _FakeSink();
      final c = OfficeSheetEditController(
        sink: sink,
        base: _base(),
        initialRev: 0,
      )..editable = true;
      addTearDown(c.dispose);
      addTearDown(sink.close);

      await tester.pumpWidget(_viewHarness(c));
      sink.push('set', <String, Object?>{
        'cmd': 'value',
        'id': 'sh_1',
        'changes': <Object?>[
          <Object?>[1, 1, 'FROM_PEER'],
        ],
        'rev': 1,
      });
      await tester.pump();
      expect(find.text('FROM_PEER'), findsOneWidget);
    });
  });

  group('E5. 真实帧回放（探针夹具）：emit(set) 的接线与三态', () {
    Map<String, Object?> fixture() =>
        (jsonDecode(
                  File(
                    'test/fixtures/office_sheet_ui2/set_frames.json',
                  ).readAsStringSync(),
                )
                as Map)
            .cast<String, Object?>();

    test('真机帧逐条回放：init/peek/set 三态（1/2/0 语义）', () async {
      final transport = FakeCollabTransport(
        ReplayScript.fromFixture(fixture()),
      );
      final client = OfficeCollabClient(
        target: OfficeCollabTarget(
          baseUrl: Uri.parse('https://nas.example.com:5001'),
          objectId: '1028_F2OS4D955D3VP39MCL5GE86HGG.sh',
          linkId: '19yfWkVZHIH3a47vkOhJ0YKmOeD9xPl2',
        ),
        transport: transport,
        sessionCookieId: 'test-sid',
      );
      await client.connect();
      final init = await client.emit('init');
      expect(init, <Object?>['8e3063b7d999caeb', 0, <Object?>[]]);
      final peek = await client.emit('peek');
      expect(peek, <Object?>['8e3063b7d999caeb', 0, true]);

      // 夹具按真机顺序回放：第 1、2 条 set → status 1；第 3 条（探针 rev=99）
      // → status 2（currentRev=2）；第 4 条（rev=3）→ status 1（恢复）。
      final ack1 = officeSheetSetAck(
        await client.emit('set', <String, Object?>{
          'cmd': 'value',
          'id': 'sh_1',
          'changes': <Object?>[
            <Object?>[0, 2, 'X'],
          ],
          'source': 'test',
          'rev': 1,
        }),
      );
      expect(ack1.status, OfficeSheetSetStatus.ok);
      expect(ack1.revIncoming, 1);
      expect(ack1.currentRev, 1);

      final ack2 = officeSheetSetAck(
        await client.emit('set', <String, Object?>{
          'cmd': 'value',
          'id': 'sh_1',
          'changes': <Object?>[
            <Object?>[3, 0, 42.5],
          ],
          'source': 'test',
          'rev': 2,
        }),
      );
      expect(ack2.status, OfficeSheetSetStatus.ok);
      expect(ack2.currentRev, 2);

      final stale = officeSheetSetAck(
        await client.emit('set', <String, Object?>{
          'cmd': 'value',
          'id': 'sh_1',
          'changes': <Object?>[
            <Object?>[5, 0, 'Y'],
          ],
          'source': 'test',
          'rev': 99,
        }),
      );
      expect(stale.status, OfficeSheetSetStatus.staleRev);
      expect(stale.revIncoming, 99);
      expect(stale.currentRev, 2);

      final recovered = officeSheetSetAck(
        await client.emit('set', <String, Object?>{
          'cmd': 'value',
          'id': 'sh_1',
          'changes': <Object?>[
            <Object?>[5, 0, 'Y'],
          ],
          'source': 'test',
          'rev': 3,
        }),
      );
      expect(recovered.status, OfficeSheetSetStatus.ok);
      expect(recovered.revIncoming, 3);
      await client.close();
    });

    test('客户端身份被服务端覆写（uid/client_id）——peer 帧原文', () {
      final frames = (fixture()['frames']! as List).cast<Map>();
      // peer 帧来自探针第二个 socket 的事件日志（记录在报告 §①，此处校验形状）。
      const peerFrame =
          '{"cmd":"value","id":"sh_1","changes":[[0,2,"P2SET-r0c2"],'
          '[2,0,"P2SET-r2c0"],[1,1,"P2SET-r1c1"],[0,0,"P2SET-r0c0"]],'
          '"source":"dsh-probe2","rev":1,"uid":1028,'
          '"client_id":"wHc3_05O8QsZwA1UAAAV"}';
      final command = (jsonDecode(peerFrame) as Map).cast<String, Object?>();
      expect(command['uid'], 1028);
      expect(command['client_id'], isA<String>());
      expect(officeSheetChangesOf(command['changes']), hasLength(4));
      expect(frames, isNotEmpty);
    });
  });

  group('E6. 页面接线：门控 / 常显未确认数 / 失败解释', () {
    testWidgets('allowed + 会话就绪：编辑提示 + 常显未确认数 + 格子可点', (tester) async {
      final session = _ScriptedSession();
      addTearDown(session.events.close);
      await tester.pumpWidget(_pageHarness(_Backend(session: session)));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('office-sheet-edit-hint')), findsOneWidget);
      expect(find.byKey(const Key('office-sheet-pending')), findsOneWidget);
      expect(find.text('所有改动已确认'), findsOneWidget);
      expect(
        find.byKey(const Key('office-sheet-cell-hit-0-0')),
        findsOneWidget,
      );

      // 在飞未确认 → 计数常显为 1。
      session.gate = Completer<void>();
      await tester.tap(find.byKey(const Key('office-sheet-cell-hit-0-0')));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.enterText(
        find.byKey(const Key('office-sheet-cell-input-0-0')),
        'PEND',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(session.sent.single['cmd'], 'value');
      expect(
        find.byKey(const Key('office-sheet-cell-pending-0-0')),
        findsOneWidget,
      );
      expect(find.textContaining('待确认改动：1 项'), findsOneWidget);
      session.gate!.complete();
      session.gate = null;
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('所有改动已确认'), findsOneWidget);
    });

    testWidgets('无写权限（105）：只读——无编辑提示/无点击入口/入口隐藏', (tester) async {
      final session = _ScriptedSession();
      addTearDown(session.events.close);
      await tester.pumpWidget(
        _pageHarness(
          _Backend(
            session: session,
            gate: const OfficeWriteGateInputs(
              canWrite: false,
              canComment: false,
              schemaMobile: 2003,
              loadError: DsmErrorCode.noPermission,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-sheet-edit-entry')), findsNothing);
      expect(find.byKey(const Key('office-sheet-edit-hint')), findsNothing);
      expect(find.byKey(const Key('office-sheet-cell-hit-0-0')), findsNothing);
      expect(find.text('C3SPIKE-SHEET-BASE'), findsOneWidget);
    });

    testWidgets('被拒绝：失败横幅点名格子 + 原因，且回滚乐观显示', (tester) async {
      final session = _ScriptedSession(acks: <Object?>[kAckRejected]);
      addTearDown(session.events.close);
      await tester.pumpWidget(_pageHarness(_Backend(session: session)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('office-sheet-cell-hit-1-1')));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.enterText(
        find.byKey(const Key('office-sheet-cell-input-1-1')),
        'NOPE',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(
        find.byKey(const Key('office-sheet-edit-failure')),
        findsOneWidget,
      );
      expect(find.textContaining('B2'), findsOneWidget);
      expect(find.textContaining('status 0'), findsOneWidget);
      expect(find.text('所有改动已确认'), findsOneWidget);
    });

    testWidgets('发送超时：未确认数仍在 + 重试按钮出现（不丢输入）', (tester) async {
      final session = _ScriptedSession(failWith: TimeoutException('boom'));
      addTearDown(session.events.close);
      await tester.pumpWidget(_pageHarness(_Backend(session: session)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('office-sheet-cell-hit-2-0')));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.enterText(
        find.byKey(const Key('office-sheet-cell-input-2-0')),
        'TIMEOUT',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.textContaining('待确认改动：1 项'), findsOneWidget);
      expect(
        find.byKey(const Key('office-sheet-pending-retry')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('office-sheet-edit-failure')),
        findsOneWidget,
      );
      // 重试点一下（仍失败 → 输入还在）。
      await tester.tap(find.byKey(const Key('office-sheet-pending-retry')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.textContaining('待确认改动：1 项'), findsOneWidget);
    });

    test('控制器：门控不允许时编辑层恒只读（editable=false）', () async {
      final session = _ScriptedSession();
      final controller = OfficeSheetController(
        _Backend(
          session: session,
          gate: const OfficeWriteGateInputs(
            canWrite: true,
            canComment: true,
            schemaMobile: 1000, // schema 太旧 → 隐藏入口
          ),
        ),
      );
      await controller.load();
      expect(controller.state.editable, isFalse);
      expect(controller.edit, isNotNull);
      expect(controller.edit!.canEdit, isFalse);
      controller.dispose();
      await session.events.close();
    });

    test('控制器：P4 形态的生产后端仍只读（无会话 → 无编辑层）', () async {
      final transport = FakeTransport(
        <String, Map<String, dynamic>>{
          'SYNO.Office.Snapshot.get': <String, dynamic>{
            'content': _sections(),
            'ntype': 'sheet',
          },
        },
        <String, Map<String, dynamic>>{
          'SYNO.Office.Snapshot': <String, dynamic>{
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 4,
          },
        },
      );
      final backend = OfficeApiSheetBackend(
        officeApi: OfficeApi(DsmWebApi(transport)),
        request: const OfficeSheetRequest(
          fileId: '1',
          name: 'a.osheet',
          permanentLink: '19yf',
        ),
      );
      final controller = OfficeSheetController(backend);
      await controller.load();
      expect(controller.state.phase, OfficeSheetPhase.ready);
      // 门控命令走不通（FakeTransport 只回 Snapshot:get）→ fail-open 且无会话。
      expect(controller.edit, isNull);
      expect(controller.state.editable, isFalse);
      controller.dispose();
    });
  });
}
