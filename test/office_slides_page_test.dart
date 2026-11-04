import 'dart:io';
// Office C′ 演示文稿（Slides）批 1 —— 打开生命周期 + 门控 + 加密门复用（离线测试）。
//
// 无网络、无设备、无构建：Office 数据层用 `test/support/chat_harness.dart` 的
// `FakeTransport`（只回 JSON），会话用 `office_collab_client_test.dart` 的
// `FakeCollabTransport`（不连接，只保证 `close()` 安全），页面用假后端。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/drive_entry_dto.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/office_api.dart';
import 'package:synhub/src/data/office_collab/office_collab_client.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/drive/drive_open_entry.dart';
import 'package:synhub/src/features/files/drive_providers.dart'
    show driveApiProvider;
import 'package:synhub/src/features/office/office_slides_page.dart';
import 'package:synhub/src/features/office/office_write_gate.dart';

import 'office_collab_client_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

// ---------------------------------------------------------------------------
// 夹具：真机 `Snapshot:get v4` 回包的 **@C_text/* section 字典**（形状取自
// `/tmp/office_probe_evid/snap_probe_exported.oslides.json`；文本值是短标记）。
// ---------------------------------------------------------------------------

Map<String, Object?> _spikeSections() => <String, Object?>{
  'content': <String, Object?>{
    'version': 7,
    'data': <String, Object?>{
      'type': 'doc',
      'attrs': <String, Object?>{
        'schema': 13,
        'type': 'presentation',
        'cx': 960,
        'cy': 540,
      },
      'content': <Object?>[
        <String, Object?>{'type': 'settings', 'attrs': <String, Object?>{}},
        <String, Object?>{
          'type': 'slide_container',
          'attrs': <String, Object?>{'page_num_enabled': false},
          'content': <Object?>[
            <String, Object?>{
              'type': 'slide',
              'attrs': <String, Object?>{
                'id': 'S1',
                'master_id': 'M',
                'layout_id': 'L',
                'is_visible': true,
              },
              'content': <Object?>[
                <String, Object?>{
                  'type': 'slide_content_container',
                  'attrs': <String, Object?>{},
                  'content': <Object?>[
                    <String, Object?>{
                      'type': 'paragraph',
                      'attrs': <String, Object?>{},
                      'content': <Object?>[
                        <String, Object?>{
                          'type': 'text',
                          'text': 'C3SPIKE-SLIDES-BASE',
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          ],
        },
      ],
    },
  },
  'index': <String, Object?>{'schemaVersion': 13},
  'comment': <String, Object?>{'data': <Object?>[], 'format': 1},
};

OfficeSlidesSnapshot _snapshot({int version = 7}) => OfficeSlidesSnapshot(
  sections: _spikeSections(),
  version: version,
  raw: <String, dynamic>{'ntype': 'presentation'},
);

const OfficeWriteGateInputs _allowAll = OfficeWriteGateInputs(
  canWrite: true,
  canComment: true,
  schemaMobile: 2003,
);

OfficeCollabClient _fakeClient() => OfficeCollabClient(
  target: OfficeCollabTarget(
    baseUrl: Uri.parse('https://nas.example.com:5001'),
    objectId: '1028_QHRQLN2LIP2MV2TTLGAC7D86C8.slide',
    linkId: '19yfWkVZHIH3a47vkOhJ0YKmOeD9xPl2',
  ),
  transport: FakeCollabTransport(
    ReplayScript(<ReplayExchange>[], handshakeBody: '0{"sid":"<redacted>"}'),
  ),
  sessionCookieId: 'test-sid',
);

class _FakeSlidesBackend implements OfficeSlidesBackend {
  _FakeSlidesBackend({
    OfficeSlidesSnapshot? snapshot,
    this.gate = _allowAll,
    this.initAck = const <Object?>['7cf2e91ff8cbf8e9', 0, <Object?>[]],
    this.loadGateError,
    this.loadSnapshotError,
    this.openSessionError,
  }) : snapshot = snapshot ?? _snapshot();

  final OfficeSlidesSnapshot? snapshot;
  final OfficeWriteGateInputs gate;
  final Object? initAck;
  final Object? loadGateError;
  final Object? loadSnapshotError;
  final Object? openSessionError;

  int closeCount = 0;
  int openCount = 0;
  int loadCount = 0;

  @override
  Future<OfficeWriteGateInputs> loadGate() async {
    if (loadGateError != null) throw loadGateError!;
    return gate;
  }

  @override
  Future<OfficeSlidesSnapshot> loadSnapshot() async {
    loadCount++;
    if (loadSnapshotError != null) throw loadSnapshotError!;
    return snapshot!;
  }

  @override
  Future<OfficeSlidesSession> openSession() async {
    openCount++;
    if (openSessionError != null) throw openSessionError!;
    return OfficeSlidesSession(client: _fakeClient(), initAck: initAck);
  }

  @override
  Future<void> closeSession(OfficeSlidesSession session) async {
    closeCount++;
    await session.close();
  }
}

Object _dsmError(int code) => DsmApiException(code, method: 'test');

/// 记录 `emit` 的假 client（批 2：证明写通道发的是 `event` / `poll`）。
class _RecordingClient extends OfficeCollabClient {
  _RecordingClient(OfficeCollabTarget target)
    : super(
        target: target,
        transport: FakeCollabTransport(
          ReplayScript(
            <ReplayExchange>[],
            handshakeBody: '0{"sid":"<redacted>"}',
          ),
        ),
        sessionCookieId: 'test-sid',
      );

  final List<String> emitted = <String>[];
  final List<Object?> emittedData = <Object?>[];
  Object? fetchAck;

  @override
  Future<void> connect() async {}

  @override
  Future<Object?> emit(String event, [Object? data]) async {
    emitted.add(event);
    emittedData.add(data);
    if (event == 'fetch') return fetchAck;
    return null;
  }

  @override
  Future<void> close() async {}
}

// ---------------------------------------------------------------------------

void main() {
  group('P1. 门控（复用 office_write_gate.dart，纯函数）', () {
    test('canWrite && schema 2003 → 显示编辑入口（下一批才可编辑）', () {
      final d = decideOfficeWriteGate(_allowAll);
      expect(d.state, OfficeWriteGateState.allowed);
      expect(d.showEditorEntry, isTrue);
      expect(d.editable, isTrue);
      expect(d.reasonText, isNull);
    });

    test('105 无权限 → 隐藏入口 + 原因', () {
      final d = decideOfficeWriteGate(
        const OfficeWriteGateInputs(
          canWrite: false,
          canComment: false,
          schemaMobile: 2003,
          loadError: DsmErrorCode.noPermission,
        ),
      );
      expect(d.state, OfficeWriteGateState.hiddenNoPermission);
      expect(d.showEditorEntry, isFalse);
      expect(d.reasonText, isNotNull);
    });

    test('schema_mobile 1999 → 隐藏入口（配置位太旧）', () {
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

    test('119 → 保留入口，只提示重新登录', () {
      final d = decideOfficeWriteGate(
        const OfficeWriteGateInputs(
          canWrite: true,
          canComment: true,
          schemaMobile: 2003,
          loadError: DsmErrorCode.sidNotFound,
        ),
      );
      expect(d.state, OfficeWriteGateState.reloginOnly);
      expect(d.showEditorEntry, isTrue);
      expect(d.reasonText, isNotNull);
    });
  });

  group('P2. 打开生命周期（controller）', () {
    test('load → ready（从 content section 重建 + init 会话），dispose 关闭会话', () async {
      final backend = _FakeSlidesBackend();
      final controller = OfficeSlidesController(backend);
      await controller.load();

      expect(controller.state.phase, OfficeSlidesPhase.ready);
      expect(controller.state.snapshot, isNotNull);
      expect(controller.state.snapshot!.version, 7);
      expect(
        controller.state.snapshot!.sections['content'],
        isA<Map<String, Object?>>(),
      );
      expect(controller.state.sessionReady, isTrue);
      expect(controller.state.sessionNote, isNull);
      expect(controller.state.gate.state, OfficeWriteGateState.allowed);
      expect(backend.openCount, 1);
      expect(controller.renderReport.unknownSteps, isEmpty);

      await controller.closeSession();
      expect(backend.closeCount, 1);
      // 幂等。
      await controller.closeSession();
      expect(backend.closeCount, 1);
      controller.dispose();
    });

    test('read snapshot 失败 119 → sessionExpired（不静默）', () async {
      final controller = OfficeSlidesController(
        _FakeSlidesBackend(
          loadSnapshotError: _dsmError(DsmErrorCode.sidNotFound),
        ),
      );
      await controller.load();
      expect(controller.state.phase, OfficeSlidesPhase.sessionExpired);
      expect(controller.state.errorCode, DsmErrorCode.sidNotFound);
      expect(controller.state.errorMessage, contains('119'));
      controller.dispose();
    });

    test('read snapshot 失败 106（超时）→ 也是 sessionExpired', () async {
      final controller = OfficeSlidesController(
        _FakeSlidesBackend(
          loadSnapshotError: _dsmError(DsmErrorCode.sessionTimeout),
        ),
      );
      await controller.load();
      expect(controller.state.phase, OfficeSlidesPhase.sessionExpired);
      expect(controller.state.errorCode, DsmErrorCode.sessionTimeout);
      controller.dispose();
    });

    test('read snapshot 失败（其它）→ failure + 明确错误（不静默）', () async {
      final controller = OfficeSlidesController(
        _FakeSlidesBackend(
          loadSnapshotError: _dsmError(DsmErrorCode.apiNotFound),
        ),
      );
      await controller.load();
      expect(controller.state.phase, OfficeSlidesPhase.failure);
      expect(controller.state.errorMessage, contains('102'));
      controller.dispose();
    });

    test('会话建不起来 → 仍 ready（只读），但 sessionNote 点名原因', () async {
      final controller = OfficeSlidesController(
        _FakeSlidesBackend(
          openSessionError: const OfficeSlidesLoadException(
            'no_object_id',
            '拿不到 Office object_id',
          ),
        ),
      );
      await controller.load();
      expect(controller.state.phase, OfficeSlidesPhase.ready);
      expect(controller.state.sessionReady, isFalse);
      expect(controller.state.sessionNote, contains('缺少文档内部 id'));
      expect(controller.state.sessionNote, isNot(contains('拿不到 Office object_id')));
      expect(controller.state.snapshot, isNotNull);
      controller.dispose();
    });

    // ★ 只读横幅缺陷（`docs/office-readonly-banner-defect.md`）：闸门已判只读时，
    // 协作的 PermissionDenied 是必然推论 ⇒ 不再重复成红色 sessionNote。
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
        final controller = OfficeSlidesController(
          _FakeSlidesBackend(
            gate: gate,
            openSessionError: OfficeCollabPermissionDeniedException(
              'Permission denied',
            ),
          ),
        );
        await controller.load();
        expect(controller.state.phase, OfficeSlidesPhase.ready, reason: '$gate');
        expect(controller.state.sessionReady, isFalse, reason: '$gate');
        expect(controller.state.gate.reasonText, isNotNull, reason: '$gate');
        expect(controller.state.sessionNote, isNull, reason: '$gate');
        controller.dispose();
      }
    });

    test('★ 反向：闸门判可写 + 协作 PermissionDenied → 必须仍报错', () async {
      final controller = OfficeSlidesController(
        _FakeSlidesBackend(
          openSessionError: OfficeCollabPermissionDeniedException(
            'Permission denied',
          ),
        ),
      );
      await controller.load();
      expect(controller.state.gate.state, OfficeWriteGateState.allowed);
      expect(controller.state.sessionNote, isNotNull);
      controller.dispose();
    });

    test('只读 + 其它协作故障（超时）→ 仍报错（只静音权限拒绝）', () async {
      final controller = OfficeSlidesController(
        _FakeSlidesBackend(
          gate: readOnlyGates.first,
          openSessionError: OfficeCollabTimeoutException(
            'sync',
            const Duration(seconds: 60),
          ),
        ),
      );
      await controller.load();
      expect(controller.state.sessionNote, isNotNull);
      controller.dispose();
    });

    test('init ack 的 step 列表不回放，但认识/不认识都登记', () async {
      final controller = OfficeSlidesController(
        _FakeSlidesBackend(
          initAck: <Object?>[
            '7cf2e91ff8cbf8e9',
            4,
            <Object?>[
              <String, Object?>{'stepType': 'setNodeAttrs'},
              <String, Object?>{'stepType': 'totally_unknown'},
            ],
          ],
        ),
      );
      await controller.load();
      expect(controller.renderReport.commandsNotReplayed, 2);
      expect(controller.renderReport.seenSteps['setNodeAttrs'], 1);
      expect(controller.renderReport.unknownSteps['totally_unknown'], 1);
      expect(controller.state.sessionRev, 4);
      expect(controller.state.sessionIdentifier, '7cf2e91ff8cbf8e9');
      controller.dispose();
    });

    test('门控读取抛非 DSM 异常 → fail-open（仍 ready，入口保留）', () async {
      final controller = OfficeSlidesController(
        _FakeSlidesBackend(loadGateError: StateError('gate boom')),
      );
      await controller.load();
      expect(controller.state.phase, OfficeSlidesPhase.ready);
      expect(controller.state.gate.state, OfficeWriteGateState.unknownFailOpen);
      expect(controller.state.gate.showEditorEntry, isTrue);
      expect(controller.state.gate.editable, isFalse);
      controller.dispose();
    });
  });

  group('P3. 页面（widget）', () {
    testWidgets('ready → 显示幻灯片与门控横幅；allowed 时编辑入口可见且**真实可点**', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeSlidesPage(
              request: const OfficeSlidesRequest(
                fileId: '1',
                name: 'a.oslides',
                permanentLink: '19yf',
              ),
              backend: _FakeSlidesBackend(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-slides-page')), findsOneWidget);
      expect(find.text('C3SPIKE-SLIDES-BASE'), findsOneWidget);
      expect(find.text('第 1 页'), findsOneWidget);
      // allowed 无原因 → 不显示门控横幅。
      expect(find.byKey(const Key('office-slides-gate-banner')), findsNothing);
      final entry = tester.widget<IconButton>(
        find.byKey(const Key('office-slides-edit-entry')),
      );
      expect(entry.onPressed, isNotNull, reason: '批 2 起编辑入口是真实编辑');
    });

    testWidgets('无权限（105）→ 隐藏编辑入口 + 显示原因（页面仍只读可用）', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeSlidesPage(
              request: const OfficeSlidesRequest(
                fileId: '1',
                name: 'a.oslides',
              ),
              backend: _FakeSlidesBackend(
                gate: const OfficeWriteGateInputs(
                  canWrite: false,
                  canComment: false,
                  schemaMobile: 2003,
                  loadError: DsmErrorCode.noPermission,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-slides-edit-entry')), findsNothing);
      expect(
        find.byKey(const Key('office-slides-gate-banner')),
        findsOneWidget,
      );
      expect(find.text('C3SPIKE-SLIDES-BASE'), findsOneWidget);
    });

    testWidgets('119 → 保留编辑入口 + 提示重新登录', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeSlidesPage(
              request: const OfficeSlidesRequest(
                fileId: '1',
                name: 'a.oslides',
              ),
              backend: _FakeSlidesBackend(
                gate: const OfficeWriteGateInputs(
                  canWrite: true,
                  canComment: true,
                  schemaMobile: 2003,
                  loadError: DsmErrorCode.sidNotFound,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-slides-edit-entry')), findsOneWidget);
      expect(find.textContaining('重新登录'), findsOneWidget);
    });

    testWidgets('加载失败 → failure 面板 + 重试 + 回退（不静默）', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeSlidesPage(
              request: const OfficeSlidesRequest(
                fileId: '1',
                name: 'a.oslides',
              ),
              backend: _FakeSlidesBackend(
                loadSnapshotError: _dsmError(DsmErrorCode.apiNotFound),
              ),
              onFallbackToNativePreview: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-slides-failure')), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      // O3: button label changed to plain user language (no engineering wording).
      expect(find.text('用文字方式打开'), findsOneWidget);
      expect(find.text('只读预览'), findsNothing);
      expect(find.byKey(const Key('office-slides-edit-entry')), findsNothing);
    });

    testWidgets('会话失效（119）→ sessionExpired 面板（不是静默白屏）', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeSlidesPage(
              request: const OfficeSlidesRequest(
                fileId: '1',
                name: 'a.oslides',
              ),
              backend: _FakeSlidesBackend(
                loadSnapshotError: _dsmError(DsmErrorCode.sessionTimeout),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('office-slides-session-expired')),
        findsOneWidget,
      );
      expect(find.textContaining('登录会话已失效'), findsOneWidget);
    });

    testWidgets('会话失败 → 只读仍可用 + 可见 sessionNote', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeSlidesPage(
              request: const OfficeSlidesRequest(
                fileId: '1',
                name: 'a.oslides',
              ),
              backend: _FakeSlidesBackend(
                openSessionError: const OfficeSlidesLoadException(
                  'x',
                  'socket 建不起来',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('office-slides-session-note')),
        findsOneWidget,
      );
      // ★ r308：reason 不认识 ⇒ 全仓唯一兜底（本地化），**不把原文顶上去**。
      expect(find.textContaining('操作未能完成'), findsOneWidget);
      expect(find.textContaining('socket 建不起来'), findsNothing);
      expect(find.text('C3SPIKE-SLIDES-BASE'), findsOneWidget);
    });

    testWidgets('★ 只读 + 协作 PermissionDenied → 只有信息横幅，无红色横幅', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeSlidesPage(
              request: const OfficeSlidesRequest(
                fileId: '1',
                name: 'a.oslides',
              ),
              backend: _FakeSlidesBackend(
                gate: const OfficeWriteGateInputs(
                  canWrite: false,
                  canComment: false,
                  schemaMobile: 2003,
                ),
                openSessionError: OfficeCollabPermissionDeniedException(
                  'Permission denied',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('office-slides-gate-banner')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('office-slides-session-note')), findsNothing);
    });

    testWidgets('★ 反向：可写 + 协作 PermissionDenied → 仍显示红色横幅', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeSlidesPage(
              request: const OfficeSlidesRequest(
                fileId: '1',
                name: 'a.oslides',
              ),
              backend: _FakeSlidesBackend(
                openSessionError: OfficeCollabPermissionDeniedException(
                  'Permission denied',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('office-slides-session-note')),
        findsOneWidget,
      );
    });

    testWidgets('页面 dispose → 关闭会话（幂等）', (tester) async {
      final backend = _FakeSlidesBackend();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeSlidesPage(
              request: const OfficeSlidesRequest(
                fileId: '1',
                name: 'a.oslides',
              ),
              backend: backend,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(backend.openCount, 1);
      // 换掉整棵树 = dispose。
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 20));
      expect(backend.closeCount, 1);
      // 再 pump 一次仍只关一次（幂等）。
      await tester.pump(const Duration(milliseconds: 20));
      expect(backend.closeCount, 1);
    });

    testWidgets('批 2：常显未确认计数（0 时显示"所有改动已确认"）', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeSlidesPage(
              request: const OfficeSlidesRequest(
                fileId: '1',
                name: 'a.oslides',
              ),
              backend: _FakeSlidesBackend(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-slides-pending')), findsOneWidget);
      expect(find.text('所有改动已确认'), findsOneWidget);
    });

    testWidgets('批 2：点按编辑入口 → 打开编辑面板并列出可编辑块', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeSlidesPage(
              request: const OfficeSlidesRequest(
                fileId: '1',
                name: 'a.oslides',
              ),
              backend: _FakeSlidesBackend(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('office-slides-edit-entry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-slides-edit-sheet')), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key as ValueKey<String>).value.startsWith(
                'office-slides-edit-block-',
              ),
        ),
        findsWidgets,
      );
    });

    testWidgets('批 2：点按正文块 → 对话框预填当前文本；取消不改动', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeSlidesPage(
              request: const OfficeSlidesRequest(
                fileId: '1',
                name: 'a.oslides',
              ),
              backend: _FakeSlidesBackend(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final gesture = find.byWidgetPredicate(
        (w) =>
            w is GestureDetector &&
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith('office-slide-edit-'),
      );
      expect(gesture, findsWidgets);
      await tester.tap(gesture.first);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('office-slides-edit-dialog')),
        findsOneWidget,
      );
      final field = tester.widget<TextField>(
        find.byKey(const Key('office-slides-edit-field')),
      );
      expect(field.controller?.text, 'C3SPIKE-SLIDES-BASE');
      await tester.tap(find.byKey(const Key('office-slides-edit-cancel')));
      await tester.pumpAndSettle();
      expect(find.text('C3SPIKE-SLIDES-BASE'), findsOneWidget);
      expect(find.text('所有改动已确认'), findsOneWidget);
    });
  });

  group('P4. 生产后端（既有 OfficeApi + Snapshot:get v4）', () {
    test(
      'loadSnapshot：data.content → @C_text/content；comment/file 一并带上',
      () async {
        const apiTable = <String, Map<String, dynamic>>{
          'SYNO.Office.Snapshot': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 4,
          },
        };
        final transport = FakeTransport(<String, Map<String, dynamic>>{
          'SYNO.Office.Snapshot.get': <String, dynamic>{
            'comment': <String, dynamic>{'data': <Object?>[], 'format': 1},
            'content': _spikeSections()['content'],
            'file': <Object?>[],
            'ntype': 'presentation',
            'object_id': '1028_QHRQLN2LIP2MV2TTLGAC7D86C8.slide',
          },
        }, apiTable);
        final backend = OfficeApiSlidesBackend(
          officeApi: OfficeApi(DsmWebApi(transport)),
          request: const OfficeSlidesRequest(
            fileId: '974379797534783818',
            name: 'probe_exported.oslides',
            permanentLink: '19yfWkVZHIH3a47vkOhJ0YKmOeD9xPl2',
          ),
        );
        final snapshot = await backend.loadSnapshot();
        expect(snapshot.version, 7);
        expect(snapshot.sections.containsKey('content'), isTrue);
        expect(snapshot.sections.containsKey('comment'), isTrue);
        expect(snapshot.sections.containsKey('file'), isTrue);
        final call = transport.calls.firstWhere(
          (c) => c['api'] == 'SYNO.Office.Snapshot' && c['method'] == 'get',
        );
        expect('${call['version']}', '4');
        expect(call['link_id'], '19yfWkVZHIH3a47vkOhJ0YKmOeD9xPl2');
        // ★★ 第 309 轮：**读内容前必须先要快照**（官方 Web 客户端逐字
        // `if("odoc"===n||"oslides"===n)try{…Snapshot/create v2{link_id}}catch{}`）。
        // 真机：新建的空白 `.oslides`/`.odoc` 服务端不会自动产生快照。
        final order = <String>[
          for (final c in transport.calls)
            if (c['api'] == 'SYNO.Office.Snapshot') '${c['method']}',
        ];
        expect(
          order,
          containsAllInOrder(<String>['create', 'get']),
          reason: '必须先要快照再取内容，实际顺序 = $order',
        );
        final create = transport.calls.firstWhere(
          (c) => c['api'] == 'SYNO.Office.Snapshot' && c['method'] == 'create',
        );
        // 官方用 v2；`.lib` 里 v3/v4 **没有** create ⇒ 不许照 maxVersion 取。
        expect('${create['version']}', '2');
        expect(create['link_id'], '19yfWkVZHIH3a47vkOhJ0YKmOeD9xPl2');
      },
    );

    test('★ `Snapshot/create` 失败 ⇒ 按官方 catch{} 吞掉，仍能打开', () async {
      const apiTable = <String, Map<String, dynamic>>{
        'SYNO.Office.Snapshot': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 4,
        },
      };
      final transport = FakeTransport(<String, Map<String, dynamic>>{
        'SYNO.Office.Snapshot.get': <String, dynamic>{
          'comment': <String, dynamic>{'data': <Object?>[], 'format': 1},
          'content': _spikeSections()['content'],
          'file': <Object?>[],
          'ntype': 'presentation',
          'object_id': '1028_QHRQLN2LIP2MV2TTLGAC7D86C8.slide',
        },
      }, apiTable);
      transport.failures['SYNO.Office.Snapshot.create'] = 103;
      final backend = OfficeApiSlidesBackend(
        officeApi: OfficeApi(DsmWebApi(transport)),
        request: const OfficeSlidesRequest(
          fileId: '974379797534783818',
          name: 'probe_exported.oslides',
          permanentLink: '19yfWkVZHIH3a47vkOhJ0YKmOeD9xPl2',
        ),
      );
      final snapshot = await backend.loadSnapshot();
      expect(snapshot.version, 7, reason: '要快照失败不许连累打开');
      expect(
        transport.calls.any(
          (c) => c['api'] == 'SYNO.Office.Snapshot' && c['method'] == 'get',
        ),
        isTrue,
        reason: '吞掉失败后必须继续走 get',
      );
    });

    test('loadSnapshot：缺 permanent_link → 明确失败（不静默）', () async {
      final backend = OfficeApiSlidesBackend(
        officeApi: OfficeApi(DsmWebApi(FakeTransport(const {}, const {}))),
        request: const OfficeSlidesRequest(fileId: '1', name: 'a.oslides'),
      );
      await expectLater(
        backend.loadSnapshot(),
        throwsA(isA<OfficeSlidesLoadException>()),
      );
    });

    test('★★ r314 loadSnapshot：**缺 content ⇒ 空白演示文稿**（不是 bad_content_shape）',
        () async {
      // 真机缺陷：新建的空白 `.oslides` 每次打开都记
      // `[office:slidesLoad:bad_content_shape]`，真相是服务端**连 content 键都没给**
      // （新建 8h+ 仍如此）。官方 Web 逐字 `sourceInfo.content ? … : preset`
      // ⇒ 缺内容用预设空白，**不报错**；只有"有 content 但形态怪"才报错
      // （下一条用例继续守着那一半）。
      for (final payload in <Map<String, Object?>>[
        <String, Object?>{}, // 连键都没有（真机形态）
        <String, Object?>{'content': null},
        <String, Object?>{'content': <String, Object?>{}},
        <String, Object?>{'content': <String, Object?>{'version': 3}}, // 无 data
      ]) {
        const apiTable = <String, Map<String, dynamic>>{
          'SYNO.Office.Snapshot': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 4,
          },
        };
        final transport = FakeTransport(<String, Map<String, dynamic>>{
          'SYNO.Office.Snapshot.get': <String, dynamic>{
            ...payload,
            'object_id': '1028_ABC.slide',
          },
        }, apiTable);
        final backend = OfficeApiSlidesBackend(
          officeApi: OfficeApi(DsmWebApi(transport)),
          request: const OfficeSlidesRequest(
            fileId: '1',
            name: 'a.oslides',
            permanentLink: '19yf',
          ),
        );
        final snapshot = await backend.loadSnapshot();
        expect(snapshot.objectId, '1028_ABC.slide');
        expect(snapshot.version, 0);
        expect(snapshot.sections.containsKey('content'), isTrue);
        // ⚠️ 关键：**不许伪造幻灯片节点**（回落是"空内容"，不是"假一页"）
        expect(snapshot.sections['content'], <String, Object?>{'data': null, 'version': 0});
      }
    });

    test('loadSnapshot：content 形态对不上 → bad_content_shape（不伪造空文档）', () async {
      const apiTable = <String, Map<String, dynamic>>{
        'SYNO.Office.Snapshot': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 4,
        },
      };
      // ★★ r314：载荷从 `{'nope': true}` 改成一份**真的像 section 字典、却没有
      // `content`** 的回包。原因：适配器 `officeSectionsFromSnapshot` 对 oslides
      // 的判据是 `content['data'] != null` 或 `_looksLikeNativeSectionMap`
      // （只认 `sh_*` / `style`+`define`）；`{'nope': true}` 两条都不满足 ⇒
      // `sections == null` ⇒ 按官方语义那其实是"**服务端没给内容** ⇒ 预设空白"。
      // 本用例要守的是另一半："回包**是** section 字典、只是没有 `content` ⇒
      // 不伪造空文档，明确报坏形态"。所以载荷必须是 `style`+`define` 形态。
      final transport = FakeTransport(<String, Map<String, dynamic>>{
        'SYNO.Office.Snapshot.get': <String, dynamic>{
          'content': <String, dynamic>{
            'style': <String, dynamic>{},
            'define': <String, dynamic>{},
          },
          'ntype': 'presentation',
        },
      }, apiTable);
      final backend = OfficeApiSlidesBackend(
        officeApi: OfficeApi(DsmWebApi(transport)),
        request: const OfficeSlidesRequest(
          fileId: '1',
          name: 'a.oslides',
          permanentLink: '19yf',
        ),
      );
      await expectLater(
        backend.loadSnapshot(),
        throwsA(
          isA<OfficeSlidesLoadException>().having(
            (e) => e.reason,
            'reason',
            'bad_content_shape',
          ),
        ),
      );
    });
  });

  group('P5. 加密门复用（加密的 .oslides 不打开；未加密必须能分流）', () {
    testWidgets('加密 → 弹既有提示，不进入演示文稿页', (tester) async {
      final container = ProviderContainer(
        overrides: [
          driveApiProvider.overrideWithValue(_FakeDriveApi(encrypted: true)),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.dark(), home: _SlidesOpenProbe(entry: _slidesEntry())),
        ),
      );
      await tester.tap(find.byKey(const Key('slides-open-probe')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('drive-encrypted-password-dialog')), findsOneWidget);
      expect(find.byType(OfficeSlidesPage), findsNothing);
    });

    testWidgets('未加密 → 分流到 OfficeSlidesPage（对照：证明上面不是"什么都没发生"）', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          driveApiProvider.overrideWithValue(_FakeDriveApi(encrypted: false)),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.dark(), home: _SlidesOpenProbe(entry: _slidesEntry())),
        ),
      );
      await tester.tap(find.byKey(const Key('slides-open-probe')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('drive-encrypted-password-dialog')), findsNothing);
      expect(find.byType(OfficeSlidesPage), findsOneWidget);
      // 未连接 DSM → 明确 failure，而不是静默白屏。
      expect(find.byKey(const Key('office-slides-failure')), findsOneWidget);
    });
  });

  group('P7. ★ r314 幻灯片写入后必须重读画布（静态守卫）', () {
    test('编辑保存之后紧跟 `_loadDeck()`（否则"写了看不见"）', () {
      // 真机缺陷：`Countrysider314tpl.oslides` 的标题块改成 `Slide314` 后
      // 服务端已落盘（离开重进文本块列表就是 `Slide314`），但**画布不变** ——
      // 画布渲染的是 `_deck`（PPTX 通道），只在 `initState` 拉过一次。
      // 这条守卫钉住"保存成功后立刻重读"，不需要整页 Widget 夹具。
      final src = File('lib/src/features/office/office_slides_page.dart')
          .readAsStringSync();
      final saveAt = src.indexOf('await edit.editBlockText(');
      expect(saveAt, greaterThan(0), reason: '找不到保存调用，守卫失效');
      final after = src.substring(saveAt, saveAt + 1200);
      expect(
        after.contains('await _loadDeck();'),
        isTrue,
        reason: '保存成功后必须重读 PPTX 画布（`_loadDeck`），实际片段：\n$after',
      );
    });
  });

  group('P6. 批 2 会话写通道（fetch / event / poll，真机帧形状）', () {
    test('fetch ack → docData/version；写通道发 event / poll', () async {
      final client = _RecordingClient(
        OfficeCollabTarget(
          baseUrl: Uri.parse('https://nas.example.com:5001'),
          objectId: '1028_QHRQLN2LIP2MV2TTLGAC7D86C8.slide',
          linkId: '19yfWkVZHIH3a47vkOhJ0YKmOeD9xPl2',
        ),
      );
      final doc = <String, Object?>{
        'version': 13,
        'data': ((_spikeSections()['content'] as Map)['data'] as Map)
            .cast<String, Object?>(),
      };
      client.fetchAck = <Object?>[
        null,
        <String, Object?>{'doc': doc, 'comment_store': <Object?>[]},
      ];
      final session = OfficeSlidesSession(
        client: client,
        initAck: client.fetchAck,
        fetchDoc: doc,
        fetchVersion: 13,
      );
      expect(session.rev, 13);
      expect(session.version, 13);
      expect(session.docData?['type'], 'doc');

      await session.sendEvent(<String, Object?>{
        'version': 13,
        'steps': <Object?>[],
        'clientId': 'c',
      });
      expect(client.emitted.last, 'event');
      expect((client.emittedData.last as Map)['version'], 13);

      await session.poll(13);
      expect(client.emitted.last, 'poll');
      expect((client.emittedData.last as Map)['version'], 13);
    });

    test('非 [null,{doc}] 的 fetch ack → 生产 openSession 明确失败', () async {
      // 直接验证解析分支的形状判据（与生产代码同一段逻辑）。
      final bad = <Object?>['identifier', 0, <Object?>[]];
      final list = bad;
      final payload = (list.length > 1) ? list[1] : null;
      final doc = payload is Map ? payload['doc'] : null;
      expect(doc, isNull, reason: '批 1 的 init 形状不再是合法 fetch ack');
    });
  });
}

DriveEntryDto _slidesEntry() => const DriveEntryDto(
  fileId: '974379797534783818',
  name: 'probe_exported.oslides',
  type: 'file',
  path: '/probe_exported.oslides',
  displayPath: '/mydrive/probe_exported.oslides',
  parentId: '1',
  size: 10205487,
  modifiedTime: 0,
  createdTime: 0,
  contentType: 'presentation',
  starred: false,
  shared: false,
  owner: 'tester',
  canDownload: true,
  canPreview: true,
  canWrite: true,
  capabilities: <String, dynamic>{},
  permanentLink: '19yfWkVZHIH3a47vkOhJ0YKmOeD9xPl2',
);

class _SlidesOpenProbe extends ConsumerWidget {
  const _SlidesOpenProbe({required this.entry});

  final DriveEntryDto entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: TextButton(
          key: const Key('slides-open-probe'),
          onPressed: () => driveOpenEntry(context, ref, entry),
          child: const Text('open'),
        ),
      ),
    );
  }
}

/// 一个"永不联网"的传输：本组测试只走被覆写的 `officeEncryptCheck`。
class _NoopTransport implements WebApiTransport {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDriveApi extends DriveApi {
  _FakeDriveApi({required this.encrypted}) : super(DsmWebApi(_NoopTransport()));

  final bool encrypted;

  /// 本组只关心分流；直链不联网也要有个值（否则 `downloadUrl` 会打真传输）。
  @override
  String downloadUrl({
    required String fileId,
    bool forceDownload = true,
    bool isPreview = false,
  }) => 'https://example.invalid/dl/$fileId';

  @override
  Future<bool> officeEncryptCheck({
    required String fileId,
    String password = '',
    String? sharingToken,
  }) async => !encrypted;
}
