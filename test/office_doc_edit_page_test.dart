// Office C′ 编辑器 UI 批 2 —— 编辑交互 / 工具栏 / 保存 UX 的离线测试。
//
// 会话用 M0 的真机回放夹具（`FakeCollabTransport` + 真机帧模板），文档用 M1 的
// 真机 `dart_fetched_doc_v1.json`。`402`/`411` 的 ack 形状取自
// `docs/office-collab-protocol-spike.md` 的真机探针；`save` ack 取自
// `replay_doc_write.json` seq21。
//
// 无网络、无设备、无构建。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_collab/doc_ot_session.dart';
import 'package:synhub/src/data/office_collab/doc_schema.dart';
import 'package:synhub/src/data/office_collab/office_collab_client.dart';
import 'package:synhub/src/features/office/office_doc_edit.dart';
import 'package:synhub/src/features/office/office_doc_page.dart';
import 'package:synhub/src/features/office/office_write_gate.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'office_collab_client_test.dart';

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('test/fixtures/office_collab/$name').readAsStringSync())
        as Map<String, Object?>;

const String _objectId = '1028_FATHU56MD53F5ARCP55HVG877S.doc';

String _fetchAck(int version, Map<String, Object?> doc) =>
    '433[null,{"doc":{"version":$version,"data":${jsonEncode(doc)},'
    '"comment_store":{}}}]';

String _confirmed(int version) =>
    '434[null,{"id":"<redacted>","version":$version,"steps":[],'
    '"clientIDs":["dart01"],"selection":null}]';

String _err(int status, String message) =>
    '434[{"status":$status},"Error: $_objectId: $message"]';

String _remoteInsert(int pos, String text) => jsonEncode(<String, Object?>{
  'stepType': 'replace',
  'from': pos,
  'to': pos,
  'slice': <String, Object?>{
    'content': <Object?>[
      <String, Object?>{'type': 'text', 'text': text},
    ],
    'openLeft': 0,
    'openRight': 0,
  },
  'structure': false,
});

String _pollAck(int version, List<String> steps) =>
    '434[null,{"version":$version,"wait":true,"steps":[${steps.join(',')}],'
    '"clientIDs":["other"],"selections":[]}]';

const String _saveOk =
    '434[{"success":true,"snapshot_version":"6346a6c1b3848e9a2d712225ca75095dc1e47f09"}]';

List<ReplayExchange> _boot() => <ReplayExchange>[
  ReplayExchange('2probe', <String>['3probe']),
  ReplayExchange('5'),
  ReplayExchange('40', <String>['40{"sid":"<redacted>"}', '42["ready"]']),
];

List<ReplayExchange> _announce() => <ReplayExchange>[
  ReplayExchange('421["say_hello"]', <String>[
    '431[{"id":"<redacted>","serverId":"f663682760b06e48"}]',
  ]),
  ReplayExchange('422["ask_peers"]', <String>['432[[]]']),
];

ReplayScript _script(
  Map<String, Object?> doc,
  List<ReplayExchange> afterFetch,
) => ReplayScript(
  <ReplayExchange>[
    ..._boot(),
    ..._announce(),
    ReplayExchange('423["fetch"]', <String>[_fetchAck(1, doc)]),
    ...afterFetch,
  ],
  handshakeBody:
      '0{"sid":"<redacted>","upgrades":["websocket"],'
      '"pingInterval":25000,"pingTimeout":60000}',
);

DocOtSession _newSession(FakeCollabTransport transport) => DocOtSession(
  client: OfficeCollabClient(
    target: OfficeCollabTarget(
      baseUrl: Uri.parse('https://nas.example.com:5001'),
      objectId: _objectId,
      linkId: '19yfWXfe2ZGfFb5oigOvzXifW0g5LZnn',
    ),
    transport: transport,
    sessionCookieId: 'test-sid',
  ),
  clientId: 'dart01',
);

class _FakeBackend implements OfficeDocBackend {
  _FakeBackend({required this.snapshot, required this.transport});

  final OfficeDocSnapshot snapshot;
  final FakeCollabTransport transport;

  static const OfficeWriteGateInputs _gate = OfficeWriteGateInputs(
    canWrite: true,
    canComment: true,
    schemaMobile: 2003,
  );

  DocOtSession? opened;

  @override
  Future<OfficeDocSnapshot> loadSnapshot() async => snapshot;

  @override
  Future<OfficeWriteGateInputs> loadGate() async => _gate;

  @override
  Future<DocOtSession> openSession() async {
    final session = _newSession(transport);
    await session.open();
    opened = session;
    return session;
  }

  @override
  Future<OfficeDocSaveResult> save(DocOtSession session) async {
    final reply = await session.client.emit('save', <String, Object?>{});
    return parseOfficeDocSaveAck(reply);
  }

  @override
  Future<void> closeSession(DocOtSession session) => session.close();
}

OfficeDocSnapshot _snapshot(Map<String, Object?> doc, {int version = 1}) =>
    OfficeDocSnapshot(
      node: DocNode.fromRawJson(doc),
      version: version,
      raw: DocNode.fromRawJson(doc).toRawJson(),
    );

/// 文档里第一个 `edit_area` 下第一个 `paragraph` 的路径。
OfficeDocPath _firstEditablePath(Map<String, Object?> doc) {
  final root = doc['content'] as List;
  for (var i = 0; i < root.length; i++) {
    final node = (root[i] as Map).cast<String, Object?>();
    if (node['type'] != 'edit_area') continue;
    final kids = (node['content'] as List?) ?? const <Object?>[];
    for (var j = 0; j < kids.length; j++) {
      if ((kids[j] as Map)['type'] == 'paragraph') {
        return OfficeDocPath(<int>[i, j]);
      }
    }
  }
  throw StateError('fixture has no editable paragraph');
}

/// 从已发送帧里取出 `event` 携带的 steps（真实上线形态）。
List<Map<String, Object?>> _sentEventSteps(FakeCollabTransport transport) {
  final out = <Map<String, Object?>>[];
  for (final raw in transport.sent) {
    if (!raw.startsWith('4')) continue;
    final packet = SioPacket.parse(raw.substring(1));
    if (packet.type != SioPacketType.event) continue;
    final decoded = jsonDecode(packet.payload) as List;
    if (decoded.isEmpty || decoded.first != 'event') continue;
    if (decoded.length < 2) continue;
    final data = (decoded[1] as Map).cast<String, Object?>();
    final steps = data['steps'];
    if (steps is List) {
      for (final s in steps) {
        out.add((s as Map).cast<String, Object?>());
      }
    }
  }
  return out;
}

void main() {
  final fetchDoc = _fixture('dart_fetched_doc_v1.json');

  group('H1. 控制器：编辑链路（输入 → step → 上线帧）', () {
    test('追加一个字符 → ReplaceStep(37,37) 且上线帧无 structure', () async {
      final transport = FakeCollabTransport(
        _script(fetchDoc, <ReplayExchange>[
          ReplayExchange('424["event",{}]', <String>[_confirmed(2)]),
        ]),
      );
      final backend = _FakeBackend(
        snapshot: _snapshot(fetchDoc),
        transport: transport,
      );
      final controller = OfficeDocController(backend);
      addTearDown(controller.closeSession);
      await controller.load();
      expect(controller.state.editable, isTrue);

      final path = _firstEditablePath(fetchDoc);
      expect(controller.isEditablePath(path), isTrue);
      // 只读区域（style_editor 的样式定义）不可编辑。
      expect(
        controller.isEditablePath(const OfficeDocPath(<int>[1, 0])),
        isFalse,
      );

      final ok = await controller.replaceParagraphText(
        path,
        'C3SPIKE-DOC-BASE!',
      );
      expect(ok, isTrue);
      expect(transport.mismatch, isNull);

      final steps = _sentEventSteps(transport);
      expect(steps, hasLength(1));
      final step = steps.single;
      expect(step['stepType'], 'replace');
      expect(step['from'], 37, reason: '内容起点 21 + 16 字 = 37');
      expect(step['to'], 37);
      expect(
        step.containsKey('structure'),
        isFalse,
        reason: 'M2 已证 structure 是 write-only；UI 批 2 不发它',
      );
      final slice = (step['slice']! as Map).cast<String, Object?>();
      expect(slice['openLeft'], 0);
      expect(slice['openRight'], 0);
      expect(step['structure'], isNull);
      // 本地乐观显示已生效。
      expect(controller.state.version, 2);
      expect(controller.state.pendingCount, 0);
    });

    test('选区 + 加粗 → AddMarkStep（openLeft/right=0，无 structure）', () async {
      final transport = FakeCollabTransport(
        _script(fetchDoc, <ReplayExchange>[
          ReplayExchange('424["event",{}]', <String>[_confirmed(2)]),
        ]),
      );
      final controller = OfficeDocController(
        _FakeBackend(snapshot: _snapshot(fetchDoc), transport: transport),
      );
      addTearDown(controller.closeSession);
      await controller.load();

      final path = _firstEditablePath(fetchDoc);
      controller.selectText(path, 0, 5);
      expect(controller.state.hasSelection, isTrue);
      await controller.togglePresenceMark('strong');

      final step = _sentEventSteps(transport).single;
      expect(step['stepType'], 'addMark');
      expect(step['from'], 21);
      expect(step['to'], 26);
      expect((step['mark']! as Map)['_'], 'strong');
      expect(step.containsKey('structure'), isFalse);
    });

    test('DA207 加粗之后必须回一句"已对 N 个字符…"，不能只有 Undo 的 tooltip 变', () async {
      // 真机 r616：编辑态段落控件只渲染纯文本（`_EditableParagraph`），
      // 加粗打上之后**屏幕一个像素都不变**；当时唯一反馈是 Undo 的 tooltip。
      final transport = FakeCollabTransport(
        _script(fetchDoc, <ReplayExchange>[
          ReplayExchange('424["event",{}]', <String>[_confirmed(2)]),
          ReplayExchange('424["event",{}]', <String>[_confirmed(3)]),
        ]),
      );
      final controller = OfficeDocController(
        _FakeBackend(snapshot: _snapshot(fetchDoc), transport: transport),
      );
      addTearDown(controller.closeSession);
      await controller.load();

      final path = _firstEditablePath(fetchDoc);
      controller.selectText(path, 0, 5);
      final ok = await controller.togglePresenceMark('strong');
      expect(ok, isTrue);
      final note = controller.state.editNote ?? '';
      expect(note, contains('加粗'), reason: '必须说清是哪个格式：$note');
      expect(note, contains('5'), reason: '必须说清影响几个字符：$note');

      // 再点一次 = 取消，提示也要跟着变
      controller.selectText(path, 0, 5);
      await controller.togglePresenceMark('strong');
      final note2 = controller.state.editNote ?? '';
      expect(note2, contains('取消'), reason: '取消加粗也要有回执：$note2');
    });

    test('标题级别 / 列表 → setNodeAttrs pos=20（段落起点）', () async {
      final transport = FakeCollabTransport(
        _script(fetchDoc, <ReplayExchange>[
          ReplayExchange('424["event",{}]', <String>[_confirmed(2)]),
          ReplayExchange('424["event",{}]', <String>[_confirmed(3)]),
        ]),
      );
      final controller = OfficeDocController(
        _FakeBackend(snapshot: _snapshot(fetchDoc), transport: transport),
      );
      addTearDown(controller.closeSession);
      await controller.load();

      final path = _firstEditablePath(fetchDoc);
      controller.focusParagraph(path);
      await controller.setHeadingLevel(2);
      await controller.toggleList();

      final steps = _sentEventSteps(transport);
      expect(steps, hasLength(2));
      expect(steps[0]['stepType'], 'setNodeAttrs');
      expect(steps[0]['pos'], 20);
      expect((steps[0]['attrs']! as Map)['headingLevel'], 2);
      expect(steps[1]['stepType'], 'setNodeAttrs');
      expect(steps[1]['pos'], 20);
      final attrs = (steps[1]['attrs']! as Map).cast<String, Object?>();
      expect(attrs['listId'], isA<String>());
      expect(attrs['listMarks'], isEmpty);
    });
  });

  group('H2. 402 对齐 / 411 丢步：UI 据实反映', () {
    test('402 → poll 拿远端增量 → rebase 重发 → UI 保留"已对齐"说明', () async {
      final transport = FakeCollabTransport(
        _script(fetchDoc, <ReplayExchange>[
          ReplayExchange('424["event",{}]', <String>[
            _err(402, 'Not current version. incoming: 1, current: 2'),
          ]),
          ReplayExchange('424["poll",{}]', <String>[
            _pollAck(2, <String>[_remoteInsert(21, 'R')]),
          ]),
          ReplayExchange('424["event",{}]', <String>[_confirmed(3)]),
        ]),
      );
      final controller = OfficeDocController(
        _FakeBackend(snapshot: _snapshot(fetchDoc), transport: transport),
      );
      addTearDown(controller.closeSession);
      await controller.load();

      final path = _firstEditablePath(fetchDoc);
      final ok = await controller.replaceParagraphText(
        path,
        'C3SPIKE-DOC-BASE!',
      );
      expect(ok, isTrue);
      expect(transport.mismatch, isNull, reason: 'rebased 帧必须被消费');
      expect(controller.state.pendingCount, 0);
      expect(controller.state.syncNote, isNotNull);
      expect(controller.state.syncNote!, contains('对齐'));
      // 重发帧里的本地 step 已被映射（远端在 21 插了 1 个字符 → 37 变成 38）。
      final steps = _sentEventSteps(transport);
      expect(steps.last['from'], 38);
      // 乐观树同时含远端 'R'（插在内容起点 = 字符 0）与本地 '!'。
      final text = DocNode.fromRawJson(
        controller.state.node!.toRawJson(),
      ).content![3].content![0].content!.map((n) => n.text ?? '').join();
      expect(text, 'RC3SPIKE-DOC-BASE!');
    });

    test('411 → 丢弃这步 → 明确告诉用户"哪一步没生效"，且 pending 归零', () async {
      final transport = FakeCollabTransport(
        _script(fetchDoc, <ReplayExchange>[
          ReplayExchange('424["event",{}]', <String>[
            _err(411, 'Invalid command'),
          ]),
        ]),
      );
      final controller = OfficeDocController(
        _FakeBackend(snapshot: _snapshot(fetchDoc), transport: transport),
      );
      addTearDown(controller.closeSession);
      await controller.load();

      final path = _firstEditablePath(fetchDoc);
      final ok = await controller.replaceParagraphText(
        path,
        'C3SPIKE-DOC-BASE!',
      );
      expect(ok, isFalse);
      expect(controller.state.pendingCount, 0);
      expect(controller.state.editNote, isNotNull);
      expect(controller.state.editNote!, contains('没有生效'));
      expect(controller.state.editNote!, contains('编辑文本'));
      // 乐观树已回滚到服务器版本（没有 '!'）。
      final text = DocNode.fromRawJson(
        controller.state.node!.toRawJson(),
      ).content![3].content![0].content!.map((n) => n.text ?? '').join();
      expect(text, 'C3SPIKE-DOC-BASE');
      expect(
        controller.state.canUndo,
        isFalse,
        reason: '被丢弃的 step 不许进撤销栈（不假装可撤销）',
      );
    });
  });

  group('H3. 撤销/重做（单步，逆 step 由 UI 层实现）', () {
    test('撤销 → 上线的是插入的逆 step，文档回到原样；重做再次前进', () async {
      final transport = FakeCollabTransport(
        _script(fetchDoc, <ReplayExchange>[
          ReplayExchange('424["event",{}]', <String>[_confirmed(2)]),
          ReplayExchange('424["event",{}]', <String>[_confirmed(3)]),
          ReplayExchange('424["event",{}]', <String>[_confirmed(4)]),
        ]),
      );
      final controller = OfficeDocController(
        _FakeBackend(snapshot: _snapshot(fetchDoc), transport: transport),
      );
      addTearDown(controller.closeSession);
      await controller.load();

      final path = _firstEditablePath(fetchDoc);
      await controller.replaceParagraphText(path, 'C3SPIKE-DOC-BASE!');
      expect(controller.state.canUndo, isTrue);
      expect(controller.state.undoLabel, contains('编辑文本'));

      final undone = await controller.undo();
      expect(undone, isTrue);
      final steps = _sentEventSteps(transport);
      expect(steps[1]['from'], 37);
      expect(steps[1]['to'], 38, reason: '反向删除刚插入的 1 个字符');
      final afterUndo = DocNode.fromRawJson(
        controller.state.node!.toRawJson(),
      ).content![3].content![0].content!.map((n) => n.text ?? '').join();
      expect(afterUndo, 'C3SPIKE-DOC-BASE');
      expect(controller.state.canRedo, isTrue);

      final redone = await controller.redo();
      expect(redone, isTrue);
      final afterRedo = DocNode.fromRawJson(
        controller.state.node!.toRawJson(),
      ).content![3].content![0].content!.map((n) => n.text ?? '').join();
      expect(afterRedo, 'C3SPIKE-DOC-BASE!');
    });
  });

  group('H4. 保存 UX 与离开保护', () {
    // ★ DA208（r624）：`snapshot_version` 是 40 位对象 id，**不许**进用户文案。
    // 这条用例原来断言"提示条里能看到它"——那正是缺陷本身，改成"看不到"。
    test('保存成功 → 只回「已保存快照」，不许显示 snapshot_version', () async {
      final transport = FakeCollabTransport(
        _script(fetchDoc, <ReplayExchange>[
          ReplayExchange('424["save",{}]', <String>[_saveOk]),
        ]),
      );
      final controller = OfficeDocController(
        _FakeBackend(snapshot: _snapshot(fetchDoc), transport: transport),
      );
      addTearDown(controller.closeSession);
      await controller.load();

      await controller.save();
      expect(controller.state.saveState, OfficeDocSaveState.saved);
      expect(controller.state.saveMessage, '已保存快照');
      expect(
        controller.state.saveMessage,
        isNot(contains('6346a6c1b3848e9a2d712225ca75095dc1e47f09')),
      );
      expect(controller.leavePrompt(), isNull);
    });

    test('有未确认编辑 → leavePrompt 明确计数（不许静默丢弃）', () async {
      // event 帧没有 ack → localEdit 一直 pending。
      final transport = FakeCollabTransport(
        _script(fetchDoc, <ReplayExchange>[ReplayExchange('424["event",{}]')]),
      );
      final controller = OfficeDocController(
        _FakeBackend(snapshot: _snapshot(fetchDoc), transport: transport),
      );
      addTearDown(controller.closeSession);
      await controller.load();

      final path = _firstEditablePath(fetchDoc);
      unawaited(controller.replaceParagraphText(path, 'C3SPIKE-DOC-BASE!'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(controller.state.pendingCount, 1);
      expect(controller.state.hasUnconfirmedEdits, isTrue);
      final prompt = controller.leavePrompt();
      expect(prompt, isNotNull);
      expect(prompt!, contains('1'));
    });
  });

  group('H5. 工具栏 / 离开框 widget（独立可测，不建协作会话）', () {
    OfficeDocState toolbarState({
      int pending = 0,
      bool selection = false,
      bool paragraph = true,
      int heading = 0,
      bool listOn = false,
      bool canUndo = false,
      bool canRedo = false,
    }) => OfficeDocState(
      phase: OfficeDocPhase.ready,
      gate: const OfficeWriteGateDecision(
        OfficeWriteGateState.allowed,
        reasonKey: 'officeDocGateAllowed',
        reasonText: null,
      ),
      pendingCount: pending,
      selection: selection
          ? const OfficeDocTextSelection(
              path: OfficeDocPath(<int>[3, 0]),
              start: 0,
              end: 5,
            )
          : null,
      activeParagraph: paragraph ? const OfficeDocPath(<int>[3, 0]) : null,
      headingLevel: heading,
      listOn: listOn,
      canUndo: canUndo,
      canRedo: canRedo,
      undoLabel: canUndo ? '编辑文本' : null,
    );

    Widget host(
      OfficeDocState state, {
      void Function(String)? mark,
      void Function(int)? heading,
      VoidCallback? list,
      VoidCallback? undo,
      VoidCallback? redo,
    }) => MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: OfficeDocToolbar(
          state: state,
          onPresenceMark: mark ?? (_) {},
          onHeadingLevel: heading ?? (_) {},
          onToggleList: list ?? () {},
          onUndo: undo ?? () {},
          onRedo: redo ?? () {},
        ),
      ),
    );

    testWidgets('pending 指示 + 无选区时格式按钮禁用 + 无段落时标题/列表禁用', (tester) async {
      await tester.pumpWidget(host(toolbarState(pending: 3, paragraph: false)));
      expect(find.byKey(const Key('office-doc-toolbar')), findsOneWidget);
      expect(find.byKey(const Key('office-doc-pending')), findsOneWidget);
      expect(find.textContaining('3'), findsWidgets);
      for (final key in <String>[
        'office-doc-bold',
        'office-doc-italic',
        'office-doc-underline',
        'office-doc-list',
        'office-doc-undo',
        'office-doc-redo',
      ]) {
        expect(
          tester.widget<IconButton>(find.byKey(Key(key))).onPressed,
          isNull,
          reason: key,
        );
      }
      expect(
        tester
            .widget<PopupMenuButton<int>>(
              find.byKey(const Key('office-doc-heading')),
            )
            .enabled,
        isFalse,
      );
    });

    testWidgets('有选区 → 加粗可用并回调 strong；标题/列表/撤销也可用', (tester) async {
      final marks = <String>[];
      var list = 0;
      var undo = 0;
      await tester.pumpWidget(
        host(
          toolbarState(
            selection: true,
            heading: 2,
            listOn: true,
            canUndo: true,
          ),
          mark: marks.add,
          list: () => list++,
          undo: () => undo++,
        ),
      );
      await tester.tap(find.byKey(const Key('office-doc-bold')));
      await tester.tap(find.byKey(const Key('office-doc-italic')));
      await tester.tap(find.byKey(const Key('office-doc-underline')));
      await tester.tap(find.byKey(const Key('office-doc-list')));
      await tester.tap(find.byKey(const Key('office-doc-undo')));
      expect(marks, <String>['strong', 'em', 'underline']);
      expect(list, 1);
      expect(undo, 1);
      // 当前标题级别如实显示。
      expect(find.text('H2'), findsOneWidget);
    });

    testWidgets('标题菜单选中级别 → 回调 level', (tester) async {
      final levels = <int>[];
      await tester.pumpWidget(host(toolbarState(), heading: levels.add));
      await tester.tap(find.byKey(const Key('office-doc-heading')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('标题 3'));
      await tester.pumpAndSettle();
      expect(levels, <int>[3]);
    });

    testWidgets('离开确认框：留在本页=false / 仍然离开=true', (tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const Key('open'),
                onPressed: () async {
                  result = await showDialog<bool>(
                    context: context,
                    builder: (_) =>
                        const OfficeDocLeaveDialog(prompt: '还有 2 步没确认'),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-doc-leave-dialog')), findsOneWidget);
      expect(find.text('还有 2 步没确认'), findsOneWidget);
      await tester.tap(find.byKey(const Key('office-doc-leave-stay')));
      await tester.pumpAndSettle();
      expect(result, isFalse);

      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('office-doc-leave-confirm')));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    });
  });
}
