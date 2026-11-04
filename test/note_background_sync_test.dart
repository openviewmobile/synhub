// ★★★ 第 114 轮 / 台账 M3：笔记后台同步的**离线可验部分**。
//
// 官方是常驻 `dataSync` 服务（`AndroidManifest.xml:113`）+ 界面驱动
// `resumeSyncService/pauseSyncService`；我方在平台约束下用 WorkManager
// 周期任务做等价机制。这里钉住：
//   ① 后台入口的**参数/报告序列化**；
//   ② 无会话 ⇒ `no-saved-session`（**不清数据、不弹框**）；
//   ③ 状态映射：offline/error ⇒ ok=false，conflicts 计数带出去；
//   ④ 异常 ⇒ 走 userFacingError，绝不让后台任务崩；
//   ⑤ 测试环境不碰通道（排程三件套全 false，不抛）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/notes/note_background_sync.dart';
import 'package:synhub/src/features/notes/note_background_sync_page.dart';
import 'package:synhub/src/features/notes/note_reminder.dart' show noteB;
import 'package:synhub/src/features/notes/note_background_sync_scheduler.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/notes/note_sync.dart';
import 'package:synhub/src/design/kit/design_kit.dart';

NoteSyncStatus _status({
  NoteSyncState state = NoteSyncState.idle,
  int pending = 0,
  int conflicts = 0,
}) => NoteSyncStatus(
  state: state,
  pending: pending,
  conflicts: List.generate(conflicts, (i) => _fakeConflict('c$i')),
);

NoteConflict _fakeConflict(String id) => NoteConflict(
  objectId: id,
  title: id,
  baseVer: '1',
  serverVer: '2',
  localContent: '<p>l</p>',
  serverContent: '<p>s</p>',
);

void main() {
  group('114. 笔记后台同步（M3）', () {
    test('★ 报告序列化：reason/ok/pending/conflicts/error 全带出去', () async {
      final map = await runNoteSyncInBackground(
        const {'reason': 'periodic'},
        open: () async => NoteSyncBackgroundContext(
          runSync: () async => _status(pending: 3, conflicts: 1),
          close: () async {},
        ),
      );
      expect(map['reason'], 'periodic');
      expect(map['ok'], isTrue);
      expect(map['pending'], 3);
      expect(map['conflicts'], 1);
      expect(map['error'], isNull);
    });

    test('★ 无会话 ⇒ no-saved-session（不是崩溃，也不清数据）', () async {
      final map = await runNoteSyncInBackground(
        const {},
        open: () async => null,
      );
      expect(map['ok'], isFalse);
      expect(map['error'], 'no-saved-session');
      expect(map['reason'], 'periodic', reason: '缺省 reason 固定为 periodic');
    });

    test('★ 离线/出错 ⇒ ok=false（离线单独标 offline）', () async {
      final offline = await runNoteSyncInBackground(
        const {},
        open: () async => NoteSyncBackgroundContext(
          runSync: () async => _status(state: NoteSyncState.offline),
          close: () async {},
        ),
      );
      expect(offline['ok'], isFalse);
      expect(offline['error'], 'offline');

      final errored = await runNoteSyncInBackground(
        const {},
        open: () async => NoteSyncBackgroundContext(
          runSync: () async => _status(state: NoteSyncState.error),
          close: () async {},
        ),
      );
      expect(errored['ok'], isFalse);
    });

    test('★ 装配/同步抛异常 ⇒ 报告里带人话错误，任务不崩', () async {
      final map = await runNoteSyncInBackground(
        const {},
        open: () async => throw StateError('boom'),
      );
      expect(map['ok'], isFalse);
      expect('${map['error']}'.isNotEmpty, isTrue);
    });

    test('★ close 一定被调（含抛异常路径）', () async {
      var closed = 0;
      await runNoteSyncInBackground(
        const {},
        open: () async => NoteSyncBackgroundContext(
          runSync: () async => throw StateError('boom'),
          close: () async => closed++,
        ),
      );
      expect(closed, 1);
    });

    test('★ 测试环境：登记/开关/立即同步三件套都返回 false 且不抛', () async {
      expect(await registerNoteBackgroundSync(), isFalse);
      expect(await setNoteBackgroundSyncEnabled(enabled: true), isFalse);
      expect(await setNoteBackgroundSyncEnabled(enabled: false), isFalse);
      expect(await triggerNoteBackgroundSyncNow(), isFalse);
      // 测试环境里 handle 仍可求（entrypoint 是真实函数）
      expect(noteBackgroundSyncCallbackHandle(), isA<int?>());
    });
  });
  _backgroundSyncPageTests();
}

// ★ 第 115 轮：后台同步**设置页**（开关 + 立即同步）。
void _backgroundSyncPageTests() {
  late _RecordingSyncBridge bridge;

  Widget wrap() => ProviderScope(
    overrides: [noteBackgroundSyncBridgeProvider.overrideWithValue(bridge)],
    child: MaterialApp(theme: AppTheme.dark(), home: NoteBackgroundSyncPage()),
  );

  group('115. 后台同步设置页', () {
    testWidgets('★ 初始化读 enabled，开关反映原生状态', (tester) async {
      bridge = _RecordingSyncBridge(initial: true);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      expect(bridge.enabledCalls, 1);
      final sw = tester.widget<DesignSwitchRow>(
        find.byKey(const Key('note-bg-sync-enable')),
      );
      expect(sw.value, isTrue);
    });

    testWidgets('★ 关掉开关 → 调 setEnabled(false)', (tester) async {
      bridge = _RecordingSyncBridge(initial: true);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('note-bg-sync-enable')));
      await tester.pumpAndSettle();
      expect(bridge.setCalls, [false]);
    });

    testWidgets('★ 原生确认 enable 后开关才落在开的位置', (tester) async {
      bridge = _RecordingSyncBridge(initial: false);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('note-bg-sync-enable')));
      await tester.pumpAndSettle();
      expect(bridge.setCalls, [true]);
      final sw = tester.widget<DesignSwitchRow>(
        find.byKey(const Key('note-bg-sync-enable')),
      );
      expect(sw.value, isTrue);
    });

    testWidgets('★ 原生拒绝 ⇒ 开关**不**翻（不假装成功）+ 提示', (tester) async {
      bridge = _RecordingSyncBridge(initial: false, accept: false);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('note-bg-sync-enable')));
      await tester.pumpAndSettle();
      final sw = tester.widget<DesignSwitchRow>(
        find.byKey(const Key('note-bg-sync-enable')),
      );
      expect(sw.value, isFalse, reason: '原生没确认就不能显示成功');
      expect(
        find.text(noteB(kNoteBackgroundSyncFailed, '设置失败')),
        findsOneWidget,
      );
    });

    testWidgets('★ 立即同步 → syncNow(reason=manual) + 排队提示', (tester) async {
      bridge = _RecordingSyncBridge(initial: true);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('note-bg-sync-now')));
      await tester.pumpAndSettle();
      expect(bridge.syncNowCalls, ['manual']);
      expect(
        find.text(noteB(kNoteBackgroundSyncQueued, '已排队，稍后自动同步')),
        findsOneWidget,
      );
    });
  });
}

/// 记录调用的假排程桥。
class _RecordingSyncBridge extends NoteBackgroundSyncBridge {
  _RecordingSyncBridge({required this.initial, this.accept = true});

  final bool? initial;
  final bool accept;
  int enabledCalls = 0;
  final List<bool> setCalls = [];
  final List<String> syncNowCalls = [];

  @override
  Future<bool?> enabled() async {
    enabledCalls++;
    return initial;
  }

  @override
  Future<bool> setEnabled({required bool enabled}) async {
    setCalls.add(enabled);
    return accept;
  }

  @override
  Future<bool> syncNow({String reason = 'manual'}) async {
    syncNowCalls.add(reason);
    return accept;
  }
}
