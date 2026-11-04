// Office C′ 编辑器 UI 批 1 —— 打开/保存生命周期 + 写权限门控（离线测试）。
//
// 会话用 `office_collab_client_test.dart` 的 `FakeCollabTransport` 回放真机帧
// （M0），文档用 M1 的两个黄金夹具。无网络、无设备、无构建。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_collab/doc_ot_session.dart';
import 'package:synhub/src/data/office_collab/doc_schema.dart';
import 'package:synhub/src/data/office_collab/office_collab_client.dart';
import 'package:synhub/src/dsm/webapi.dart'
    show DsmApiException, DsmErrorCode, DsmWebApi;
import 'package:synhub/src/features/office/office_doc_page.dart';
import 'package:synhub/src/features/office/office_doc_view.dart'
    show OfficeDocRenderReport, OfficeDocView;
import 'package:synhub/src/features/office/office_write_gate.dart';

import 'package:synhub/src/data/office_api.dart';

import 'office_collab_client_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('test/fixtures/office_collab/$name').readAsStringSync())
        as Map<String, Object?>;

const String _objectId = '1028_FATHU56MD53F5ARCP55HVG877S.doc';

String _fetchAck(int version, Map<String, Object?> doc) =>
    '433[null,{"doc":{"version":$version,"data":${jsonEncode(doc)},'
    '"comment_store":{}}}]';

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

/// 会话建立 + `fetch` 的完整真机回放；`saveAck` 决定保存结果。
FakeCollabTransport _transport(
  Map<String, Object?> doc, {
  String saveAck =
      '434[{"success":true,"snapshot_version":"6346a6c1b3848e9a2d712225ca75095dc1e47f09"}]',
}) {
  return FakeCollabTransport(
    ReplayScript(
      <ReplayExchange>[
        ..._boot(),
        ..._announce(),
        ReplayExchange('423["fetch"]', <String>[_fetchAck(1, doc)]),
        ReplayExchange('424["save",{}]', <String>[saveAck]),
      ],
      handshakeBody:
          '0{"sid":"<redacted>","upgrades":["websocket"],'
          '"pingInterval":25000,"pingTimeout":60000}',
    ),
  );
}

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
  _FakeBackend({
    required this.snapshot,
    this.gate = const OfficeWriteGateInputs(
      canWrite: true,
      canComment: true,
      schemaMobile: 2003,
    ),
    this.transport,
    this.loadSnapshotError,
    this.openSessionError,
    this.saveError,
  });

  final OfficeDocSnapshot? snapshot;
  final OfficeWriteGateInputs gate;
  final FakeCollabTransport? transport;
  final Object? loadSnapshotError;
  final Object? openSessionError;
  final Object? saveError;

  int closeCount = 0;
  int saveCount = 0;
  DocOtSession? opened;

  @override
  Future<OfficeDocSnapshot> loadSnapshot() async {
    if (loadSnapshotError != null) throw loadSnapshotError!;
    return snapshot!;
  }

  @override
  Future<OfficeWriteGateInputs> loadGate() async => gate;

  @override
  Future<DocOtSession> openSession() async {
    if (openSessionError != null) throw openSessionError!;
    final t = transport;
    if (t == null) {
      throw const OfficeDocLoadException('no_transport', '测试未提供会话传输');
    }
    final session = _newSession(t);
    await session.open();
    opened = session;
    return session;
  }

  @override
  Future<OfficeDocSaveResult> save(DocOtSession session) async {
    saveCount++;
    if (saveError != null) throw saveError!;
    // 用生产侧的同一个纯函数解析 ack（真机帧回放）。
    return parseOfficeDocSaveAck(
      await session.client.emit('save', <String, Object?>{}),
    );
  }

  @override
  Future<void> closeSession(DocOtSession session) async {
    closeCount++;
    await session.close();
  }
}

OfficeDocSnapshot _snapshot(Map<String, Object?> doc) {
  final node = DocNode.fromRawJson(doc);
  return OfficeDocSnapshot(node: node, version: 1, raw: node.toRawJson());
}

void main() {
  final fetchDoc = _fixture('dart_fetched_doc_v1.json');

  group('G1. 门控判定（纯函数）', () {
    test('canWrite && schema 2003 → allowed + 显示入口', () {
      final d = decideOfficeWriteGate(
        const OfficeWriteGateInputs(
          canWrite: true,
          canComment: false,
          schemaMobile: 2003,
        ),
      );
      expect(d.state, OfficeWriteGateState.allowed);
      expect(d.showEditorEntry, isTrue);
      expect(d.editable, isTrue);
      expect(d.reasonText, isNull);
    });

    test('canComment 单独成立也算（canWrite||canComment）', () {
      final d = decideOfficeWriteGate(
        const OfficeWriteGateInputs(
          canWrite: false,
          canComment: true,
          schemaMobile: 2000,
        ),
      );
      expect(d.state, OfficeWriteGateState.allowed);
    });

    test('两者都为假 → hiddenNoPermission（隐藏入口 + 原因）', () {
      final d = decideOfficeWriteGate(
        const OfficeWriteGateInputs(
          canWrite: false,
          canComment: false,
          schemaMobile: 2003,
        ),
      );
      expect(d.state, OfficeWriteGateState.hiddenNoPermission);
      expect(d.showEditorEntry, isFalse);
      expect(d.reasonText, isNotNull);
    });

    // ★★ 第 311 轮：真机缺陷"新建后立刻打开显示『没有写入权限』"其实是我们
    // **还没问到**（`object_id`/`link_id` 没解析出来，`Permission:check` 根本没发）。
    // 判据：状态必须是 unresolvedIds（不是 hiddenNoPermission）、必须可重试。
    test('★ id 没解析出来 → unresolvedIds（不许说成"没有权限"）+ 可重试', () {
      final d = decideOfficeWriteGate(
        const OfficeWriteGateInputs(
          canWrite: false,
          canComment: false,
          schemaMobile: 2003,
          idsUnresolved: true,
        ),
      );
      expect(d.state, OfficeWriteGateState.unresolvedIds);
      expect(d.state, isNot(OfficeWriteGateState.hiddenNoPermission));
      expect(d.retryable, isTrue, reason: '没问到 ⇒ 必须给"重新检查"入口');
      expect(d.showEditorEntry, isFalse, reason: 'id 都没解析出来，会话建不起来');
      expect(d.editable, isFalse);
      expect(d.reasonKey, 'officeDocGateUnresolved');
      expect(d.reasonText, isNotNull);
    });

    // ★★ 第 312 轮真机证据：同一文件、同一账号、中间没有任何权限变更 ——
    //   新建后**立刻**打开：`readable=false writable=false commentable=false`；
    //   4 分钟后打开：三者全 true。
    // ⇒ "三个 false + 这个文件还没有 Office 内容" = **Office 对象还没建出来**，
    //   不是"没有权限"。判据：状态必须是 notProvisioned、可重试、且**不说**"无权限"。
    test('★ r312：无内容 + 三个权限位全 false → notProvisioned（不许说成"没有权限"）', () {
      final d = decideOfficeWriteGate(
        const OfficeWriteGateInputs(
          canWrite: false,
          canComment: false,
          schemaMobile: 2003,
          contentMissing: true,
        ),
      );
      expect(d.state, OfficeWriteGateState.notProvisioned);
      expect(d.state, isNot(OfficeWriteGateState.hiddenNoPermission));
      expect(d.retryable, isTrue, reason: '服务端只是还没就绪 ⇒ 必须给"重新检查"');
      expect(d.showEditorEntry, isFalse, reason: '此刻协作握手必然被拒');
      expect(d.editable, isFalse);
      expect(d.reasonKey, 'officeDocGateNotProvisioned');
      expect(d.reasonText, isNotNull);
      // 反向：文案里不许出现"没有写入或评论权限"这种断言。
      expect(d.reasonText, isNot(contains('没有写入')));
    });

    test('★ r312 反向：有内容 + 三个权限位全 false → 仍是真·无权限（不可重试）', () {
      final d = decideOfficeWriteGate(
        const OfficeWriteGateInputs(
          canWrite: false,
          canComment: false,
          schemaMobile: 2003,
          contentMissing: false,
        ),
      );
      expect(d.state, OfficeWriteGateState.hiddenNoPermission);
      expect(d.retryable, isFalse);
    });

    test('★ 反向：真·无权限（idsUnresolved=false）不许被当成"没问到"', () {
      final d = decideOfficeWriteGate(
        const OfficeWriteGateInputs(
          canWrite: false,
          canComment: false,
          schemaMobile: 2003,
        ),
      );
      expect(d.state, OfficeWriteGateState.hiddenNoPermission);
      expect(d.retryable, isFalse, reason: '服务端明确拒绝 ⇒ 不该给"重新检查"来伪装可恢复');
    });

    test('schema_mobile 1999 → hiddenSchemaTooOld（隐藏入口 + 原因带版本号）', () {
      final d = decideOfficeWriteGate(
        const OfficeWriteGateInputs(
          canWrite: true,
          canComment: true,
          schemaMobile: 1999,
        ),
      );
      expect(d.state, OfficeWriteGateState.hiddenSchemaTooOld);
      expect(d.showEditorEntry, isFalse);
      expect(d.reasonText, contains('1999'));
    });

    test('105 / 160 → hiddenNoPermission', () {
      for (final code in <int>[
        DsmErrorCode.noPermission,
        DsmErrorCode.noAppPrivilege,
      ]) {
        final d = decideOfficeWriteGate(
          OfficeWriteGateInputs(
            canWrite: true,
            canComment: true,
            schemaMobile: 2003,
            loadError: code,
          ),
        );
        expect(
          d.state,
          OfficeWriteGateState.hiddenNoPermission,
          reason: '$code',
        );
      }
    });

    test('119 / 106 → reloginOnly（**入口必须保留**）', () {
      for (final code in <int>[
        DsmErrorCode.sidNotFound,
        DsmErrorCode.sessionTimeout,
      ]) {
        final d = decideOfficeWriteGate(
          OfficeWriteGateInputs(
            canWrite: true,
            canComment: true,
            schemaMobile: 2003,
            loadError: code,
          ),
        );
        expect(d.state, OfficeWriteGateState.reloginOnly, reason: '$code');
        expect(d.showEditorEntry, isTrue, reason: '119/106 不许隐藏入口');
        expect(d.editable, isFalse);
      }
    });

    test('认不出的失败 → unknownFailOpen（保守显示）', () {
      final d = decideOfficeWriteGate(
        const OfficeWriteGateInputs(
          canWrite: false,
          canComment: false,
          schemaMobile: 0,
          loadError: 103,
        ),
      );
      expect(d.state, OfficeWriteGateState.unknownFailOpen);
      expect(d.showEditorEntry, isTrue);
    });
  });

  group('G2. 打开/保存生命周期（controller）', () {
    test('load() → ready，读回 @C_text/content 并建立会话', () async {
      final transport = _transport(fetchDoc);
      final backend = _FakeBackend(
        snapshot: _snapshot(fetchDoc),
        transport: transport,
      );
      final controller = OfficeDocController(backend);
      await controller.load();

      expect(controller.state.phase, OfficeDocPhase.ready);
      expect(controller.state.snapshot, isNotNull);
      expect(controller.state.node, isNotNull);
      expect(controller.state.version, 1);
      expect(controller.state.sessionReady, isTrue);
      expect(controller.state.sessionNote, isNull);
      expect(controller.state.gate.state, OfficeWriteGateState.allowed);
      expect(transport.mismatch, isNull);

      await controller.closeSession();
      expect(backend.closeCount, 1);
    });

    test('协作会话建不起来 → 仍 ready（只读），但有明确 sessionNote', () async {
      final backend = _FakeBackend(
        snapshot: _snapshot(fetchDoc),
        openSessionError: const OfficeDocLoadException(
          'no_object_id',
          '拿不到 object_id',
        ),
      );
      final controller = OfficeDocController(backend);
      await controller.load();
      expect(controller.state.phase, OfficeDocPhase.ready);
      expect(controller.state.sessionReady, isFalse);
      // ★ r308：界面文案走本地化（旧断言钉的是实现者诊断串 —— 那正是真机上
      // 英文环境漏中文的来源）。reason=`no_object_id` ⇒ 本地化的用户语言。
      expect(controller.state.sessionNote, contains('缺少文档内部 id'));
      // 反向验证：诊断串**不许**出现在界面文案里。
      expect(controller.state.sessionNote, isNot(contains('拿不到 object_id')));
      expect(controller.state.node, isNotNull);
      await controller.closeSession();
    });

    // -----------------------------------------------------------------------
    // ★ 只读横幅缺陷（`docs/office-readonly-banner-defect.md`）：闸门已判只读时，
    // 协作的 PermissionDenied 是必然推论 ⇒ 不再重复成红色 sessionNote。
    // -----------------------------------------------------------------------

    /// 四种只读原因各取一个代表性输入（覆盖 NoPermission / SchemaTooOld /
    /// Relogin / Unverified）；都带一个非空 `reasonText`（= 已出现信息横幅）。
    final readOnlyGates = <OfficeWriteGateInputs>[
      const OfficeWriteGateInputs(
        canWrite: false,
        canComment: false,
        schemaMobile: 2003,
      ),
      const OfficeWriteGateInputs(
        canWrite: true,
        canComment: true,
        schemaMobile: 2003,
        loadError: DsmErrorCode.noPermission,
      ),
      const OfficeWriteGateInputs(
        canWrite: true,
        canComment: true,
        schemaMobile: 1999,
      ),
      const OfficeWriteGateInputs(
        canWrite: true,
        canComment: true,
        schemaMobile: 2003,
        loadError: DsmErrorCode.sidNotFound,
      ),
      const OfficeWriteGateInputs(
        canWrite: true,
        canComment: true,
        schemaMobile: 2003,
        loadError: DsmErrorCode.apiNotFound,
      ),
    ];

    test('★ 只读（四种原因）+ 协作 PermissionDenied → 不再报红色 sessionNote', () async {
      for (final gate in readOnlyGates) {
        final backend = _FakeBackend(
          snapshot: _snapshot(fetchDoc),
          gate: gate,
          openSessionError: OfficeCollabPermissionDeniedException(
            'Permission denied',
          ),
        );
        final controller = OfficeDocController(backend);
        await controller.load();
        expect(controller.state.phase, OfficeDocPhase.ready, reason: '$gate');
        expect(controller.state.sessionReady, isFalse, reason: '$gate');
        expect(controller.state.gate.reasonText, isNotNull, reason: '$gate');
        expect(controller.state.sessionNote, isNull, reason: '$gate');
        await controller.closeSession();
      }
    });

    test('★ 反向：闸门判可写 + 协作 PermissionDenied → 必须仍报错', () async {
      final backend = _FakeBackend(
        snapshot: _snapshot(fetchDoc),
        openSessionError: OfficeCollabPermissionDeniedException(
          'Permission denied',
        ),
      );
      final controller = OfficeDocController(backend);
      await controller.load();
      expect(controller.state.gate.state, OfficeWriteGateState.allowed);
      expect(controller.state.sessionNote, isNotNull);
      await controller.closeSession();
    });

    test('只读 + 其它协作故障（超时）→ 仍报错（只静音权限拒绝）', () async {
      final backend = _FakeBackend(
        snapshot: _snapshot(fetchDoc),
        gate: readOnlyGates.first,
        openSessionError: OfficeCollabTimeoutException(
          'sync',
          const Duration(seconds: 60),
        ),
      );
      final controller = OfficeDocController(backend);
      await controller.load();
      expect(controller.state.sessionNote, isNotNull);
      await controller.closeSession();
    });

    test('读 @C_text/content 失败 119 → sessionExpired 态', () async {
      final backend = _FakeBackend(
        snapshot: null,
        loadSnapshotError: _dsmError(DsmErrorCode.sidNotFound),
      );
      final controller = OfficeDocController(backend);
      await controller.load();
      expect(controller.state.phase, OfficeDocPhase.sessionExpired);
      expect(controller.state.errorCode, DsmErrorCode.sidNotFound);
      expect(controller.state.errorMessage, isNotNull);
    });

    test('读 @C_text/content 失败（其它） → failure 态，不静默', () async {
      final backend = _FakeBackend(
        snapshot: null,
        loadSnapshotError: _dsmError(DsmErrorCode.apiNotFound),
      );
      final controller = OfficeDocController(backend);
      await controller.load();
      expect(controller.state.phase, OfficeDocPhase.failure);
      expect(controller.state.errorMessage, contains('102'));
    });

    test('save() 成功 → saved + snapshot_version', () async {
      final transport = _transport(fetchDoc);
      final backend = _FakeBackend(
        snapshot: _snapshot(fetchDoc),
        transport: transport,
      );
      final controller = OfficeDocController(backend);
      await controller.load();
      await controller.save();

      expect(controller.state.saveState, OfficeDocSaveState.saved);
      // ★ DA208（r624）：`snapshot_version` 是 40 位对象 id，**不许**进用户文案。
      expect(controller.state.saveMessage, '已保存快照');
      expect(controller.state.saveMessage, isNot(contains('6346a6c1')));
      // 真机保存帧：`["save",{}]`（replay_doc_write.json seq20）。
      final saveFrame = transport.sent.firstWhere(
        (f) => replayKeyOf(f) == 'ev:save',
      );
      final payload =
          (jsonDecode(SioPacket.parse(saveFrame.substring(1)).payload)
              as List)[1];
      expect(payload, isEmpty);
      expect(transport.mismatch, isNull);
      await controller.closeSession();
    });

    test('save() 失败 → failed + 明确错误（**绝不静默**）', () async {
      final backend = _FakeBackend(
        snapshot: _snapshot(fetchDoc),
        openSessionError: const OfficeDocLoadException('x', 'x'),
      );
      final controller = OfficeDocController(backend);
      await controller.load();
      await controller.save();
      expect(controller.state.saveState, OfficeDocSaveState.failed);
      expect(controller.state.saveMessage, isNotEmpty);
    });

    test('save() 被服务端拒绝（success:false） → failed + 状态码', () async {
      final transport = _transport(
        fetchDoc,
        saveAck: '434[{"success":false,"code":500}]',
      );
      final backend = _FakeBackend(
        snapshot: _snapshot(fetchDoc),
        transport: transport,
      );
      final controller = OfficeDocController(backend);
      await controller.load();
      await controller.save();
      expect(controller.state.saveState, OfficeDocSaveState.failed);
      expect(controller.state.saveMessage, contains('500'));
      await controller.closeSession();
    });

    test('保存抛异常 → failed（不吞）', () async {
      final backend = _FakeBackend(
        snapshot: _snapshot(fetchDoc),
        openSessionError: const OfficeDocLoadException('x', 'x'),
        saveError: OfficeCollabPermissionDeniedException('Permission denied'),
      );
      final controller = OfficeDocController(backend);
      await controller.load();
      await controller.save();
      expect(controller.state.saveState, OfficeDocSaveState.failed);
    });
  });

  group('G3. save ack 解析（真机帧；UI 批 2 后走统一分类路径）', () {
    test('真机 save ack → success + snapshot_version', () {
      final reply = jsonDecode(
        '[{"success":true,"snapshot_version":'
        '"6346a6c1b3848e9a2d712225ca75095dc1e47f09"}]',
      );
      final result = parseOfficeDocSaveAck(reply);
      expect(result.success, isTrue);
      expect(
        result.snapshotVersion,
        '6346a6c1b3848e9a2d712225ca75095dc1e47f09',
      );
      // UI 批 1 记录的坑（同一 ack 落到 other）**已在 UI 批 2 修掉**：
      // `classifyCollabReply` 现在有 save-ack 分支，所以 UI 层可以走统一分类路径。
      // 真机帧回归用例见 `test/office_collab_client_test.dart` group E。
      expect(classifyCollabReply(reply), OfficeCollabErrorKind.ok);
    });

    test('success:false → failure + 原样带出 payload（失败字段未取证，不猜）', () {
      final result = parseOfficeDocSaveAck(
        jsonDecode('[{"success":false,"code":500}]'),
      );
      expect(result.success, isFalse);
      expect(result.message, contains('500'));
      // 真机只取证过 `save` 成功帧；失败帧的 `status` 字段没有证据 → 不解析。
      expect(result.statusCode, isNull);
    });

    test('异常形态 → failure，不抛', () {
      expect(parseOfficeDocSaveAck(null).success, isFalse);
      expect(parseOfficeDocSaveAck('nope').success, isFalse);
    });
  });

  group('G4. 页面三态 + 门控入口（widget）', () {
    testWidgets('loading → ready：门控允许时显示编辑入口占位 + 保存按钮', (tester) async {
      final backend = _FakeBackend(
        snapshot: _snapshot(fetchDoc),
        openSessionError: const OfficeDocLoadException('x', 'x'),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeDocPage(
              request: const OfficeDocRequest(fileId: '1', name: 'a.odoc'),
              backend: backend,
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('office-doc-loading')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-doc-save')), findsOneWidget);
      expect(find.byKey(const Key('office-doc-edit-entry')), findsOneWidget);
      // 会话没起来 → 有明确说明，不静默。
      expect(find.byKey(const Key('office-doc-session-note')), findsOneWidget);
    });

    testWidgets('无权限 → 隐藏编辑入口，但页面照常只读显示 + 给原因', (tester) async {
      final backend = _FakeBackend(
        snapshot: _snapshot(fetchDoc),
        gate: const OfficeWriteGateInputs(
          canWrite: false,
          canComment: false,
          schemaMobile: 2003,
        ),
        openSessionError: const OfficeDocLoadException('x', 'x'),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeDocPage(
              request: const OfficeDocRequest(fileId: '1', name: 'a.odoc'),
              backend: backend,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-doc-edit-entry')), findsNothing);
      expect(find.byKey(const Key('office-doc-gate-banner')), findsOneWidget);
      // 页面本体仍在（不是隐藏整个页面）。
      expect(find.text('C3SPIKE-DOC-BASE', findRichText: true), findsOneWidget);
    });

    testWidgets('★ 只读 + 协作 PermissionDenied → 只有信息横幅，无红色横幅', (tester) async {
      final backend = _FakeBackend(
        snapshot: _snapshot(fetchDoc),
        gate: const OfficeWriteGateInputs(
          canWrite: false,
          canComment: false,
          schemaMobile: 2003,
        ),
        openSessionError: OfficeCollabPermissionDeniedException(
          'Permission denied',
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeDocPage(
              request: const OfficeDocRequest(fileId: '1', name: 'a.odoc'),
              backend: backend,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-doc-gate-banner')), findsOneWidget);
      expect(find.byKey(const Key('office-doc-session-note')), findsNothing);
    });

    testWidgets('★ 反向：可写 + 协作 PermissionDenied → 仍显示红色横幅', (tester) async {
      final backend = _FakeBackend(
        snapshot: _snapshot(fetchDoc),
        openSessionError: OfficeCollabPermissionDeniedException(
          'Permission denied',
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeDocPage(
              request: const OfficeDocRequest(fileId: '1', name: 'a.odoc'),
              backend: backend,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-doc-session-note')), findsOneWidget);
    });

    testWidgets('119（会话过期）→ 保留编辑入口 + 只提示重登', (tester) async {
      final backend = _FakeBackend(
        snapshot: _snapshot(fetchDoc),
        gate: const OfficeWriteGateInputs(
          canWrite: true,
          canComment: true,
          schemaMobile: 2003,
          loadError: DsmErrorCode.sidNotFound,
        ),
        openSessionError: const OfficeDocLoadException('x', 'x'),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeDocPage(
              request: const OfficeDocRequest(fileId: '1', name: 'a.odoc'),
              backend: backend,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-doc-edit-entry')), findsOneWidget);
      expect(find.textContaining('重新登录'), findsWidgets);
    });

    testWidgets('读取失败 119 → 会话过期态（独立文案 + 重试）', (tester) async {
      final backend = _FakeBackend(
        snapshot: null,
        loadSnapshotError: _dsmError(DsmErrorCode.sidNotFound),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeDocPage(
              request: const OfficeDocRequest(fileId: '1', name: 'a.odoc'),
              backend: backend,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('office-doc-session-expired')),
        findsOneWidget,
      );
    });

    testWidgets('读取失败（其它） → 失败态 + 重试', (tester) async {
      final backend = _FakeBackend(
        snapshot: null,
        loadSnapshotError: _dsmError(DsmErrorCode.apiNotFound),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeDocPage(
              request: const OfficeDocRequest(fileId: '1', name: 'a.odoc'),
              backend: backend,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-doc-failure')), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('保存失败 → 页面显示错误横幅 + 重试按钮（不静默）', (tester) async {
      final backend = _FakeBackend(
        snapshot: _snapshot(fetchDoc),
        openSessionError: const OfficeDocLoadException('x', 'x'),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeDocPage(
              request: const OfficeDocRequest(fileId: '1', name: 'a.odoc'),
              backend: backend,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('office-doc-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-doc-save-banner')), findsOneWidget);
      expect(find.byKey(const Key('office-doc-save-retry')), findsOneWidget);
    });

    // ★★ DA208（r624 真机）：保存快照成功后，提示条把 40 位 `snapshot_version`
    // 原样显示给用户（真机 `58c00e89e3b444f81e6b7f97260c760c781b4444`）
    // —— 诊断串当文案。判据分两半，缺一不可：
    //   ① 提示条仍然要出现（不能"修成静默"）；
    //   ② 里面**不许**出现那串 id。
    testWidgets('DA208 保存成功 → 只回一句"已保存快照"，不许把 40 位版本 id 显示给用户', (
      tester,
    ) async {
      final backend = _FakeBackend(
        snapshot: _snapshot(fetchDoc),
        transport: _transport(fetchDoc),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: OfficeDocPage(
              request: const OfficeDocRequest(fileId: '1', name: 'a.odoc'),
              backend: backend,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('office-doc-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-doc-save-banner')), findsOneWidget);
      expect(find.text('已保存快照'), findsOneWidget);
      expect(find.textContaining('6346a6c1'), findsNothing);
      expect(find.textContaining('版本'), findsNothing);
      // 卸页 → controller 关闭协作会话（否则看门狗定时器会挂在测试尾巴上）
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      final opened = backend.opened;
      if (opened != null) {
        await tester.runAsync(() => backend.closeSession(opened));
      }
      // 看门狗是 12.5s 周期定时器，关会话后仍需把它那一拍走完
      await tester.pump(const Duration(seconds: 13));
      await tester.pumpAndSettle();
    });
  });

  // -------------------------------------------------------------------------
  // ★★ 第 309 轮：真机缺陷"新建的空白 `.odoc` 打不开"的**修法**锁在用例里。
  //
  // 官方 Web 客户端在读 `.odoc`/`.oslides` 内容前**必调** `Snapshot/create`
  // （v2，只有 `link_id`），失败一律 `catch{}`；`.osheet` **不调**。
  // 真机证据：新建后 21 分钟仍取不到内容 ⇒ 这不是"索引延迟"，是缺这一步。
  // -------------------------------------------------------------------------
  group('P4b. 生产后端：★ r309 读内容前必须先要快照', () {
    const link = '19yfWkVZHIH3a47vkOhJ0YKmOeD9xPl2';
    const apiTable = <String, Map<String, dynamic>>{
      'SYNO.Office.Snapshot': {
        'path': 'entry.cgi',
        'minVersion': 1,
        'maxVersion': 4,
      },
    };

    Map<String, dynamic> docContent() => <String, dynamic>{
      'version': 1,
      'data': <String, dynamic>{
        'type': 'doc',
        'attrs': <String, dynamic>{'schema': 13},
        'content': <Object?>[
          <String, Object?>{
            'type': 'paragraph',
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': 'R309-DOC'},
            ],
          },
        ],
      },
    };

    FakeTransport transportWith({bool createFails = false}) {
      final t = FakeTransport(<String, Map<String, dynamic>>{
        'SYNO.Office.Snapshot.create': <String, dynamic>{},
        'SYNO.Office.Snapshot.get': <String, dynamic>{
          'comment': null,
          'content': docContent(),
          'file': <Object?>[],
          'ntype': 'doc',
          'object_id': '1028_R309DOC.odoc',
        },
      }, apiTable);
      if (createFails) t.failures['SYNO.Office.Snapshot.create'] = 103;
      return t;
    }

    OfficeApiDocBackend backendOf(FakeTransport t) => OfficeApiDocBackend(
      officeApi: OfficeApi(DsmWebApi(t)),
      request: const OfficeDocRequest(
        fileId: '974379797534783818',
        name: 'r309doc.odoc',
        permanentLink: link,
      ),
    );

    test('★ `Snapshot/create` v2 先于 `Snapshot/get` v4（官方逐字）', () async {
      final t = transportWith();
      final snapshot = await backendOf(t).loadSnapshot();
      expect(snapshot.node, isNotNull);
      final order = <String>[
        for (final c in t.calls)
          if (c['api'] == 'SYNO.Office.Snapshot') '${c['method']}',
      ];
      expect(
        order,
        containsAllInOrder(<String>['create', 'get']),
        reason: '必须先要快照再取内容，实际顺序 = $order',
      );
      final create = t.calls.firstWhere(
        (c) => c['api'] == 'SYNO.Office.Snapshot' && c['method'] == 'create',
      );
      // 官方用 v2；`.lib` 里 v3/v4 **没有** create ⇒ 版本不能照 maxVersion 取。
      expect('${create['version']}', '2');
      expect(create['link_id'], link);
    });

    test('★ `Snapshot/create` 失败 ⇒ 按官方 catch{} 吞掉，仍能打开', () async {
      final t = transportWith(createFails: true);
      final snapshot = await backendOf(t).loadSnapshot();
      expect(snapshot.node, isNotNull, reason: '要快照失败不许连累打开');
      expect(
        t.calls.any(
          (c) => c['api'] == 'SYNO.Office.Snapshot' && c['method'] == 'get',
        ),
        isTrue,
        reason: '吞掉失败后必须继续走 get',
      );
    });

    // ★★ 第 309 轮：真机缺陷（新建空白 `.odoc` 打不开）的**主修法**。
    // 官方 `ui.doc.js`：`var a = o.content?.data || this.getDefaultDocJson()`
    // ⇒ 缺内容**回落空白文档**，不报错；但"有 content 却形态怪"仍必须报错。
    FakeTransport blankTransport(Object? content) => FakeTransport(
      <String, Map<String, dynamic>>{
        'SYNO.Office.Snapshot.create': <String, dynamic>{},
        'SYNO.Office.Snapshot.get': <String, dynamic>{
          'comment': null,
          'content': content,
          'file': <Object?>[],
          'ntype': 'doc',
          'object_id': '1028_R309BLANK.odoc',
        },
      },
      apiTable,
    );

    test('★ 缺 content ⇒ 空白文档（不报错、可写块在）', () async {
      for (final missing in <Object?>[null, <String, dynamic>{}]) {
        final snapshot = await backendOf(
          blankTransport(missing),
        ).loadSnapshot();
        expect(snapshot.version, 0, reason: '空白文档版本为 0');
        expect(snapshot.objectId, '1028_R309BLANK.odoc');
        expect(
          snapshot.raw.toString(),
          contains('edit_area'),
          reason: '回落树里必须有可写块，否则用户打开是一片死白',
        );
        expect(snapshot.raw.toString(), contains('paragraph'));
      }
    });

    test('★ content 在但多了个怪 data ⇒ 仍判坏形态（不把怪形态伪装成空白）', () async {
      final t = blankTransport(<String, dynamic>{'data': 42});
      await expectLater(
        backendOf(t).loadSnapshot(),
        throwsA(
          isA<OfficeDocLoadException>().having(
            (e) => e.reason,
            'reason',
            'bad_content_shape',
          ),
        ),
      );
    });
    // ★★ 第 310 轮：真机"编辑态没有可写正文块"的根因 —— **渲染与编辑不是同一份文档**。
    // 渲染用 `state.node`（空白回落树，含 `edit_area`），而"哪个段落可编辑"由
    // `OfficeDocPage.isEditablePath()` 判定，它只看**协作会话的文档**（`session.doc`）。
    // 服务端对空文档不给内容 ⇒ 会话没有 `edit_area` ⇒ 全篇只读。
    // 修法：会话以**渲染用的那份回落树**为基线（官方 `content?.data || preset` 单文档语义）。
    OfficeCollabClient contentlessClient(OfficeCollabTarget target) =>
        OfficeCollabClient(
          target: target,
          transport: FakeCollabTransport(
            ReplayScript(
              <ReplayExchange>[
                ..._boot(),
                ..._announce(),
                // 服务端**没有文档内容**（只有 comment_store）。
                ReplayExchange('423["fetch"]', <String>[
                  '431[null,{"doc":{"comment_store":{}}}]',
                ]),
                ReplayExchange('424["save",{}]', <String>[
                  '434[{"success":true}]',
                ]),
              ],
              handshakeBody:
                  '0{"sid":"<redacted>","upgrades":["websocket"],'
                  '"pingInterval":25000,"pingTimeout":60000}',
            ),
          ),
          sessionCookieId: 'test-sid',
        );

    OfficeApiDocBackend backendWithClient(FakeTransport t) => OfficeApiDocBackend(
      officeApi: OfficeApi(DsmWebApi(t)),
      request: const OfficeDocRequest(
        fileId: '974379797534783818',
        name: 'r310blank.odoc',
        permanentLink: link,
      ),
      clientFactory: contentlessClient,
    );

    test('★ 空白回落 ⇒ 协作会话的基线**就是渲染那棵树**（含 edit_area）', () async {
      final t = blankTransport(null);
      // `openSession()` 需要 socket 用的 `object_id`，它是 `Office.Node:get` 现取的。
      t.responses['SYNO.Office.Node.get'] = <String, dynamic>{
        'object_id': '1028_R310BLANK.odoc',
      };
      final backend = backendWithClient(t);
      final snapshot = await backend.loadSnapshot();
      expect(snapshot.raw.toString(), contains('edit_area'), reason: '渲染树');
      final session = await backend.openSession();
      addTearDown(session.close);
      expect(session.version, 0, reason: '服务端还没有这一版');
      expect(session.doc, isNotNull, reason: '不许让会话没有文档');
      // **判定的依据在这里**：`isEditablePath()` 沿路径找的就是 `edit_area`。
      expect(
        session.doc.toString(),
        contains('edit_area'),
        reason: '会话树里没有 edit_area ⇒ 每个段落都判只读（真机现象）',
      );
      expect(session.doc.toString(), contains('paragraph'));
    });

    test('★ 服务端有内容而 fetch 没内容 ⇒ 不许拿空白顶掉，仍报错', () async {
      final t = transportWith();
      t.responses['SYNO.Office.Node.get'] = <String, dynamic>{
        'object_id': '1028_R310HASCONTENT.odoc',
      };
      final backend = backendWithClient(t);
      await backend.loadSnapshot(); // 有内容 ⇒ 没有 _docSeed
      await expectLater(
        backend.openSession(),
        throwsA(isA<OfficeCollabException>()),
      );
    });
    // ★★ 第 311 轮：真机"编辑态点不到正文块"要在**离线**先复现成机制量。
    // 判据不是"看起来对不对"，而是：编辑态到底渲染了哪些块、可编辑段落字段的
    // 矩形与风格/页边装饰面板的矩形**有没有重叠**。
    Map<String, Map<String, dynamic>> officeTable() =>
        <String, Map<String, dynamic>>{
            ...FakeTransport.table,
        'SYNO.Office.Snapshot': <String, dynamic>{
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 4,
        },
        'SYNO.Office.Permission': <String, dynamic>{
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 1,
        },
        'SYNO.Office.Info': <String, dynamic>{
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 1,
        },
        'SYNO.Office.Node': <String, dynamic>{
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 2,
        },
      };

    FakeTransport editableBlank({Object? content}) {
      final t = FakeTransport(<String, Map<String, dynamic>>{
        'SYNO.Office.Snapshot.create': <String, dynamic>{},
        'SYNO.Office.Snapshot.get': <String, dynamic>{
          'comment': null,
          'content': content,
          'file': <Object?>[],
          'ntype': 'doc',
          'object_id': '1028_R311BLANK.odoc',
        },
        'SYNO.Office.Node.get': <String, dynamic>{
          'object_id': '1028_R311BLANK.odoc',
        },
        'SYNO.Office.Permission.check': <String, dynamic>{
          'readable': true,
          'writable': true,
          'commentable': true,
        },
        'SYNO.Office.Info.get': <String, dynamic>{'schema_mobile': 2003},
      }, officeTable());
      return t;
    }

    testWidgets('★ r311：空白文档进编辑态必须有可输入的正文段落字段', (tester) async {
      // 抓住协作客户端：widget 用例结束时必须显式 `close()`，否则它的心跳
      // `Timer.periodic` 会被 flutter_test 判成 "Timer is still pending"。
      OfficeCollabClient? clientRef;
      final backend = OfficeApiDocBackend(
        officeApi: OfficeApi(DsmWebApi(editableBlank(content: null))),
        request: const OfficeDocRequest(
          fileId: '974379797534783818',
          name: 'r311blank.odoc',
          permanentLink: link,
        ),
        clientFactory: (target) {
          clientRef = contentlessClient(target);
          return clientRef!;
        },
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeDocPage(
              request: const OfficeDocRequest(
                fileId: '974379797534783818',
                name: 'r311blank.odoc',
                permanentLink: link,
              ),
              backend: backend,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('office-doc-edit-entry')),
        findsOneWidget,
        reason: '写权限为 true ⇒ 必须有编辑入口',
      );
      await tester.tap(find.byKey(const Key('office-doc-edit-entry')));
      await tester.pumpAndSettle();

      // 机制量：编辑态渲染出一个**可输入**的段落字段（不是只读 Text）。
      // 空白回落树是 `doc → edit_area → paragraph` ⇒ 路径 `0.0`。
      expect(
        find.byKey(const Key('office-doc-para-field-0.0')),
        findsOneWidget,
        reason: '空白文档进编辑态：正文段落必须是 TextField（第 309 轮真机缺口）',
      );
      // 空白树的正文里**不该**凭空冒出样式/页边装饰面板（真机上那套面板来自
      // 服务端 socket 那份文档，不是我们的回落树 —— 第 311 轮实测）。
      expect(find.byKey(const Key('office-doc-style-editor')), findsNothing);
      expect(find.byKey(const Key('office-doc-page-decorate')), findsNothing);

      // 收尾：让页面 dispose，并显式关掉客户端（`close()` 幂等，同步取消心跳）。
      await tester.pumpWidget(MaterialApp(theme: AppTheme.dark(), home: SizedBox.shrink()));
      await tester.pumpAndSettle();
      // 只触发**同步**部分：`close()` 开头就 `_watchdog?.cancel()`；
      // 不要 await（`close()` 会等传输 dispose，在 fake async 下会卡住）。
      clientRef!.close().ignore();
      await tester.pump();
    });

    testWidgets('★ r313：渲染报告按帧替换 —— 重建不会让 messages/计数无界增长',
        (tester) async {
      // 真机缺口：页面持有的 `OfficeDocRenderReport` 是长生命的，而视图每次
      // build 都往 `messages` 里 `add` ⇒ 一行日志涨到几万字符、计数虚高。
      final report = OfficeDocRenderReport();
      final doc = <String, Object?>{
        'type': 'doc',
        'content': <Object?>[
          <String, Object?>{'type': 'definitely_not_a_schema_node'},
        ],
      };
      Widget app() => MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(body: OfficeDocView(doc: doc, report: report)),
          );
      await tester.pumpWidget(app());
      final firstLen = report.messages.length;
      expect(firstLen, greaterThan(0), reason: '未知节点必须如实登记（不许静默）');
      expect(report.unknownNodeTypes['definitely_not_a_schema_node'], 1);

      for (var i = 0; i < 5; i++) {
        await tester.pumpWidget(app());
        await tester.pump();
      }
      expect(
        report.messages.length,
        firstLen,
        reason: '重建 5 次后报告仍是"最近一帧的量"（追加会让它无界增长）',
      );
      expect(
        report.unknownNodeTypes['definitely_not_a_schema_node'],
        1,
        reason: '计数是"这一帧出现了几个"，不是"累计登记了几次"',
      );
    });

  });
}

/// 造一个真实的 `DsmApiException`（页面/Controller 只读它的 `code`）。
Object _dsmError(int code) => DsmApiException(code, method: 'test');
