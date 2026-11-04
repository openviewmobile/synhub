// Office C′ 表格（Sheet）批 1 —— 打开生命周期 + 门控 + 加密门复用（离线测试）。
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
import 'package:synhub/src/features/office/office_sheet_page.dart';
import 'package:synhub/src/features/office/office_write_gate.dart';

import 'office_collab_client_test.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

// ---------------------------------------------------------------------------
// 夹具：真机 `spike_min.osheet` 的真实 `@C_text/*` section 字典（与 view 测试同源，
// 来源 `/tmp/office-collab-spike/evid/snapshot_sheet_pre.json` 的 `content`）。
// ---------------------------------------------------------------------------

Map<String, Object?> _spikeSections() => <String, Object?>{
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
  'comment': <Object?>[],
  'define': <String, Object?>{},
  'pivotCaches': <Object?>[],
  'pivotTables': <Object?>[],
  'sh_1': <String, Object?>{
    'cells': <String, Object?>{
      '0': <String, Object?>{
        '0': <String, Object?>{'v': 'C3SPIKE-SHEET-BASE'},
      },
    },
    'colCount': 30,
    'rowCount': 100,
    'rows': <String, Object?>{},
    'cols': <String, Object?>{},
    'global': <String, Object?>{'h': 21, 'w': 101},
    'mergeCells': <Object?>[],
  },
  'locale': 'en_US',
  'locale_info': <String, Object?>{'lcid': 1033},
};

OfficeSheetSnapshot _snapshot({int version = 7}) => OfficeSheetSnapshot(
  sections: _spikeSections(),
  version: version,
  raw: <String, dynamic>{'ntype': 'sheet'},
);

const OfficeWriteGateInputs _allowAll = OfficeWriteGateInputs(
  canWrite: true,
  canComment: true,
  schemaMobile: 2003,
);

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

class _FakeSheetBackend implements OfficeSheetBackend {
  _FakeSheetBackend({
    OfficeSheetSnapshot? snapshot,
    this.gate = _allowAll,
    this.initAck = const <Object?>['7cf2e91ff8cbf8e9', 0, <Object?>[]],
    this.loadGateError,
    this.loadSnapshotError,
    this.openSessionError,
  }) : snapshot = snapshot ?? _snapshot();

  final OfficeSheetSnapshot? snapshot;
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
  Future<OfficeSheetSnapshot> loadSnapshot() async {
    loadCount++;
    if (loadSnapshotError != null) throw loadSnapshotError!;
    return snapshot!;
  }

  @override
  Future<OfficeSheetSession> openSession() async {
    openCount++;
    if (openSessionError != null) throw openSessionError!;
    return OfficeSheetSession(client: _fakeClient(), initAck: initAck);
  }

  @override
  Future<void> closeSession(OfficeSheetSession session) async {
    closeCount++;
    await session.close();
  }
}

Object _dsmError(int code) => DsmApiException(code, method: 'test');

// ---------------------------------------------------------------------------

void main() {
  group('P1. 门控（复用 office_write_gate.dart，纯函数）', () {
    test('canWrite && schema 2003 → 显示编辑入口（下一批才可编辑）', () {
      final d = decideOfficeWriteGate(_allowAll);
      expect(d.state, OfficeWriteGateState.allowed);
      expect(d.showEditorEntry, isTrue);
      expect(d.editable, isTrue);
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
    test('load → ready（从 index 重建 + init 会话），dispose 关闭会话', () async {
      final backend = _FakeSheetBackend();
      final controller = OfficeSheetController(backend);
      await controller.load();

      expect(controller.state.phase, OfficeSheetPhase.ready);
      expect(controller.state.snapshot, isNotNull);
      expect(controller.state.snapshot!.version, 7);
      expect(
        controller.state.snapshot!.sections['sh_1'],
        isA<Map<String, Object?>>(),
      );
      expect(controller.state.sessionReady, isTrue);
      expect(controller.state.sessionNote, isNull);
      expect(controller.state.gate.state, OfficeWriteGateState.allowed);
      expect(backend.openCount, 1);

      await controller.closeSession();
      expect(backend.closeCount, 1);
      // 幂等。
      await controller.closeSession();
      expect(backend.closeCount, 1);
      controller.dispose();
    });

    test('read snapshot 失败 119 → sessionExpired（不静默）', () async {
      final controller = OfficeSheetController(
        _FakeSheetBackend(
          loadSnapshotError: _dsmError(DsmErrorCode.sidNotFound),
        ),
      );
      await controller.load();
      expect(controller.state.phase, OfficeSheetPhase.sessionExpired);
      expect(controller.state.errorCode, DsmErrorCode.sidNotFound);
      expect(controller.state.errorMessage, contains('119'));
      controller.dispose();
    });

    test('read snapshot 失败（其它）→ failure + 明确错误（不静默）', () async {
      final controller = OfficeSheetController(
        _FakeSheetBackend(
          loadSnapshotError: _dsmError(DsmErrorCode.apiNotFound),
        ),
      );
      await controller.load();
      expect(controller.state.phase, OfficeSheetPhase.failure);
      expect(controller.state.errorMessage, contains('102'));
      controller.dispose();
    });

    test('会话建不起来 → 仍 ready（只读），但 sessionNote 点名原因', () async {
      final controller = OfficeSheetController(
        _FakeSheetBackend(
          openSessionError: const OfficeSheetLoadException(
            'no_object_id',
            '拿不到 Office object_id',
          ),
        ),
      );
      await controller.load();
      expect(controller.state.phase, OfficeSheetPhase.ready);
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
        final controller = OfficeSheetController(
          _FakeSheetBackend(
            gate: gate,
            openSessionError: OfficeCollabPermissionDeniedException(
              'Permission denied',
            ),
          ),
        );
        await controller.load();
        expect(controller.state.phase, OfficeSheetPhase.ready, reason: '$gate');
        expect(controller.state.sessionReady, isFalse, reason: '$gate');
        expect(controller.state.gate.reasonText, isNotNull, reason: '$gate');
        expect(controller.state.sessionNote, isNull, reason: '$gate');
        controller.dispose();
      }
    });

    test('★ 反向：闸门判可写 + 协作 PermissionDenied → 必须仍报错', () async {
      final controller = OfficeSheetController(
        _FakeSheetBackend(
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
      final controller = OfficeSheetController(
        _FakeSheetBackend(
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

    test('init ack 的 commands[] 不回放，但认识/不认识都登记', () async {
      final controller = OfficeSheetController(
        _FakeSheetBackend(
          initAck: <Object?>[
            '7cf2e91ff8cbf8e9',
            4,
            <Object?>[
              <String, Object?>{'cmd': 'value'},
              <String, Object?>{'cmd': 'totally_unknown'},
            ],
          ],
        ),
      );
      await controller.load();
      expect(controller.renderReport.commandsNotReplayed, 2);
      expect(controller.renderReport.seenCommands['value'], 1);
      expect(controller.renderReport.unknownCommands['totally_unknown'], 1);
      expect(controller.state.sessionRev, 4);
      controller.dispose();
    });

    test('门控读取抛非 DSM 异常 → fail-open（仍 ready，入口保留）', () async {
      final controller = OfficeSheetController(
        _FakeSheetBackend(loadGateError: StateError('gate boom')),
      );
      await controller.load();
      expect(controller.state.phase, OfficeSheetPhase.ready);
      expect(controller.state.gate.state, OfficeWriteGateState.unknownFailOpen);
      expect(controller.state.gate.showEditorEntry, isTrue);
      expect(controller.state.gate.editable, isFalse);
      controller.dispose();
    });
  });

  group('P3. 页面（widget）', () {
    testWidgets('ready → 显示网格与门控横幅；allowed 时编辑入口可见但不可点', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeSheetPage(
              request: const OfficeSheetRequest(
                fileId: '1',
                name: 'a.osheet',
                permanentLink: '19yf',
              ),
              backend: _FakeSheetBackend(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-sheet-page')), findsOneWidget);
      expect(find.text('C3SPIKE-SHEET-BASE'), findsOneWidget);
      // allowed 无原因 → 不显示门控横幅。
      expect(find.byKey(const Key('office-sheet-gate-banner')), findsNothing);
      final entry = tester.widget<IconButton>(
        find.byKey(const Key('office-sheet-edit-entry')),
      );
      expect(entry.onPressed, isNull, reason: '本批不做编辑交互，只做占位');
    });

    testWidgets('无权限（105）→ 隐藏编辑入口 + 显示原因（页面仍只读可用）', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeSheetPage(
              request: const OfficeSheetRequest(fileId: '1', name: 'a.osheet'),
              backend: _FakeSheetBackend(
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
      expect(find.byKey(const Key('office-sheet-edit-entry')), findsNothing);
      expect(find.byKey(const Key('office-sheet-gate-banner')), findsOneWidget);
      expect(find.text('C3SPIKE-SHEET-BASE'), findsOneWidget);
    });

    testWidgets('119 → 保留编辑入口 + 提示重新登录', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeSheetPage(
              request: const OfficeSheetRequest(fileId: '1', name: 'a.osheet'),
              backend: _FakeSheetBackend(
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
      expect(find.byKey(const Key('office-sheet-edit-entry')), findsOneWidget);
      expect(find.textContaining('重新登录'), findsOneWidget);
    });

    testWidgets('加载失败 → failure 面板 + 重试 + 回退（不静默）', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeSheetPage(
              request: const OfficeSheetRequest(fileId: '1', name: 'a.osheet'),
              backend: _FakeSheetBackend(
                loadSnapshotError: _dsmError(DsmErrorCode.apiNotFound),
              ),
              onFallbackToNativePreview: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('office-sheet-failure')), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('改用只读预览'), findsOneWidget);
    });

    testWidgets('会话失败 → 只读仍可用 + 可见 sessionNote', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeSheetPage(
              request: const OfficeSheetRequest(fileId: '1', name: 'a.osheet'),
              backend: _FakeSheetBackend(
                openSessionError: const OfficeSheetLoadException(
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
        find.byKey(const Key('office-sheet-session-note')),
        findsOneWidget,
      );
      // ★ r308：reason 不认识 ⇒ 全仓唯一兜底（本地化），**不把原文顶上去**。
      expect(find.textContaining('操作未能完成'), findsOneWidget);
      expect(find.textContaining('socket 建不起来'), findsNothing);
      expect(find.text('C3SPIKE-SHEET-BASE'), findsOneWidget);
    });

    testWidgets('★ 只读 + 协作 PermissionDenied → 只有信息横幅，无红色横幅', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeSheetPage(
              request: const OfficeSheetRequest(fileId: '1', name: 'a.osheet'),
              backend: _FakeSheetBackend(
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
      expect(find.byKey(const Key('office-sheet-gate-banner')), findsOneWidget);
      expect(find.byKey(const Key('office-sheet-session-note')), findsNothing);
    });

    testWidgets('★ 反向：可写 + 协作 PermissionDenied → 仍显示红色横幅', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeSheetPage(
              request: const OfficeSheetRequest(fileId: '1', name: 'a.osheet'),
              backend: _FakeSheetBackend(
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
        find.byKey(const Key('office-sheet-session-note')),
        findsOneWidget,
      );
    });

    testWidgets('页面 dispose → 关闭会话', (tester) async {
      final backend = _FakeSheetBackend();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: AppTheme.dark(), 
            home: OfficeSheetPage(
              request: const OfficeSheetRequest(fileId: '1', name: 'a.osheet'),
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
    });
  });

  group('P4. 生产后端（既有 OfficeApi + Snapshot:get v4）', () {
    test('loadSnapshot：data.content → @C_text/index + sh_N', () async {
      const apiTable = <String, Map<String, dynamic>>{
        'SYNO.Office.Snapshot': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 4,
        },
      };
      final transport = FakeTransport(<String, Map<String, dynamic>>{
        'SYNO.Office.Snapshot.get': <String, dynamic>{
          'comment': null,
          'content': _spikeSections(),
          'file': <Object?>[],
          'ntype': 'sheet',
          'object_id': '1028_F2OS4D955D3VP39MCL5GE86HGG.sh',
        },
      }, apiTable);
      final backend = OfficeApiSheetBackend(
        officeApi: OfficeApi(DsmWebApi(transport)),
        request: const OfficeSheetRequest(
          fileId: '974379797534783818',
          name: 'spike_min.osheet',
          permanentLink: '19yfWkVZHIH3a47vkOhJ0YKmOeD9xPl2',
        ),
      );
      final snapshot = await backend.loadSnapshot();
      expect(snapshot.version, 7);
      expect(snapshot.sections.containsKey('index'), isTrue);
      expect(snapshot.sections.containsKey('sh_1'), isTrue);
      expect((snapshot.sections['sh_1'] as Map)['rowCount'], 100);
      final call = transport.calls.firstWhere(
        (c) => c['api'] == 'SYNO.Office.Snapshot' && c['method'] == 'get',
      );
      expect('${call['version']}', '4');
      expect(call['link_id'], '19yfWkVZHIH3a47vkOhJ0YKmOeD9xPl2');
      // ★★ 第 309 轮（**反向**）：官方 Web 客户端**只对 `odoc`/`oslides`** 要快照，
      // `.osheet` **不调** `Snapshot/create` ⇒ 这里必须一条都不发。
      expect(
        transport.calls.any(
          (c) => c['api'] == 'SYNO.Office.Snapshot' && c['method'] == 'create',
        ),
        isFalse,
        reason: '.osheet 不该调 Snapshot/create（官方逐字只判断 odoc/oslides）',
      );
    });

    test('loadSnapshot：缺 permanent_link → 明确失败（不静默）', () async {
      final backend = OfficeApiSheetBackend(
        officeApi: OfficeApi(DsmWebApi(FakeTransport(const {}, const {}))),
        request: const OfficeSheetRequest(fileId: '1', name: 'a.osheet'),
      );
      await expectLater(
        backend.loadSnapshot(),
        throwsA(isA<OfficeSheetLoadException>()),
      );
    });
  });

  group('P5. 加密门复用（加密的 .osheet 不打开）', () {
    testWidgets('加密 → 弹既有提示，不进入表格页', (tester) async {
      final container = ProviderContainer(
        overrides: [
          driveApiProvider.overrideWithValue(_FakeDriveApi(encrypted: true)),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.dark(), home: _SheetOpenProbe(entry: _sheetEntry())),
        ),
      );
      await tester.tap(find.byKey(const Key('sheet-open-probe')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('drive-encrypted-password-dialog')), findsOneWidget);
      expect(find.byType(OfficeSheetPage), findsNothing);
    });
  });
}

/// 未加密时必须正常分流（对照用例：证明上面的红不是"什么都没发生"）。
DriveEntryDto _sheetEntry() => const DriveEntryDto(
  fileId: '974379797534783818',
  name: 'spike_min.osheet',
  type: 'file',
  path: '/spike_min.osheet',
  displayPath: '/mydrive/spike_min.osheet',
  parentId: '1',
  size: 1024,
  modifiedTime: 0,
  createdTime: 0,
  contentType: 'spreadsheet',
  starred: false,
  shared: false,
  owner: 'tester',
  canDownload: true,
  canPreview: true,
  canWrite: true,
  capabilities: <String, dynamic>{},
  permanentLink: '19yfWkVZHIH3a47vkOhJ0YKmOeD9xPl2',
);

class _SheetOpenProbe extends ConsumerWidget {
  const _SheetOpenProbe({required this.entry});

  final DriveEntryDto entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: TextButton(
          key: const Key('sheet-open-probe'),
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

  @override
  Future<bool> officeEncryptCheck({
    required String fileId,
    String password = '',
    String? sharingToken,
  }) async => !encrypted;
}
