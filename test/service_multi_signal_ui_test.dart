// 统一多信号检测 · **模拟数据 UI 用例**（用户要求："模拟数据测试下效果"）。
//
// 用真值复刻的三份能力快照（`support/nas_capability_fixtures.dart`）驱动真实的
// `AppShellPage` / `WorkspaceTab` / `ServiceCheckPage`，断言的都是"UI 上到底
// 渲染了什么"，不是只断言状态对象：
//   * absent 的模块：底栏 tab 与工作台磁贴**都不渲染**；
//   * 真机 MailPlus（两信号矛盾 = `uncertain`）：磁贴**仍然渲染**；
//   * 工作台磁贴的**数量与顺序**正确；
//   * 窄屏 / 宽屏都不抛布局异常（`takeException()` 为 null）。
//
// **零网络**：全部走 `FakeTransport`，没有登录 NAS、没有真实请求。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart'
    show AppTextZh;
import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/settings/service_check_page.dart';
import 'package:synhub/src/features/shell/app_shell_page.dart';

import 'support/chat_harness.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/nas_capability_fixtures.dart';

/// 把能力快照翻译成 `FakeTransport` 的 `SYNO.API.Info` 表。
///
/// 从 harness 的默认表出发：**非模块 API**（Auth / Encryption / Profile …）
/// 一律保留（登录链路要用），**模块 API** 只保留本快照声明存在的那些。
Map<String, Map<String, dynamic>> _tableFor(NasSnapshot snap) {
  final t = <String, Map<String, dynamic>>{...FakeTransport.table};
  t.removeWhere(
    (api, _) => serviceForApiName(api) != null && !snap.apiNames.contains(api),
  );
  for (final api in snap.apiNames) {
    t.putIfAbsent(
      api,
      () => const {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 9},
    );
  }
  if (snap.initdataInApiTable) {
    t[kDesktopInitdataApi] = const {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    };
  }
  return t;
}

Future<ChatHarness> _bootFor(NasSnapshot snap) async {
  DsmWebApi? apiBox;
  final h = await bootChat(
    extra: snap.responses(),
    apiTable: _tableFor(snap),
    moreOverrides: [availabilityApiProvider.overrideWith((ref) => apiBox)],
  );
  apiBox = h.api;
  return h;
}

/// 真机快照要求"一屏放下全部磁贴"，好让顺序可读；用完还原。
void _useTallSurface(WidgetTester tester, {double height = 3400}) {
  tester.view.physicalSize = Size(1400, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pumpShell(
  WidgetTester tester,
  ChatHarness h, {
  AppTab? initialTab,
  bool refresh = true,
}) async {
  if (initialTab != null) {
    h.container.read(appTabProvider.notifier).select(initialTab);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(theme: AppTheme.dark(), home: AppShellPage()),
    ),
  );
  await tester.pump();
  if (refresh) {
    await h.container.read(serviceAvailabilityProvider.notifier).refresh();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Key _dock(AppTab t) => Key('dock-${t.name}');

bool _dockExists(WidgetTester tester, AppTab t) =>
    find.byKey(_dock(t)).evaluate().isNotEmpty;

/// 工作台上已渲染的磁贴 id，**按渲染顺序**。
List<String> _tileIds(WidgetTester tester) {
  const prefix = 'ws-tile-';
  return tester
      .widgetList(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(prefix),
        ),
      )
      .map((w) => (w.key! as ValueKey<String>).value.substring(prefix.length))
      .toList();
}

Future<void> _openWorkspace(WidgetTester tester) async {
  await tester.tap(find.byKey(_dock(AppTab.workspace)));
  await tester.pumpAndSettle();
}

void main() {
  group('夹具 A：真机 NAS（2026-09-21 真值）', () {
    testWidgets('底栏：5 个 tab；audio/download 已装但不占槽位，surveillance absent 不渲染', (
      tester,
    ) async {
      final h = await _bootFor(realNasSnapshot);
      await _pumpShell(tester, h);

      expect(_dockExists(tester, AppTab.chat), isTrue);
      expect(_dockExists(tester, AppTab.files), isTrue);
      expect(_dockExists(tester, AppTab.photos), isTrue);
      expect(_dockExists(tester, AppTab.workspace), isTrue);
      expect(_dockExists(tester, AppTab.me), isTrue);
      // 底栏隐藏 ≠ absent：三个主槽都在 → 顶替者根本不进候选（与可用性无关）。
      expect(_dockExists(tester, AppTab.home), isFalse);
      // 2026-09-21 真值刷新：audio/download 现在**已安装 = available**，
      // 但它们不是主槽、且主槽已满 → 依然不占底栏（不是被 absent 藏掉）。
      final snap = h.container.read(serviceAvailabilityProvider);
      expect(snap.stateOf(StationService.audio), AvailabilityState.available);
      expect(
        snap.stateOf(StationService.download),
        AvailabilityState.available,
      );
      expect(_dockExists(tester, AppTab.audio), isFalse);
      expect(_dockExists(tester, AppTab.download), isFalse);
      // surveillance 仍是 absent → 隐藏。
      expect(
        snap.stateOf(StationService.surveillance),
        AvailabilityState.absent,
      );
      expect(_dockExists(tester, AppTab.surveillance), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('工作台：10 个磁贴、顺序正确；audio/download 现在有磁贴；MailPlus 仍在', (
      tester,
    ) async {
      _useTallSurface(tester);
      final h = await _bootFor(realNasSnapshot);
      await _pumpShell(tester, h);
      await _openWorkspace(tester);

      expect(_tileIds(tester), [
        'files',
        'notes',
        'photos',
        'contacts',
        'calendar',
        'tasks',
        'search',
        'downloads',
        'audio',
        'mailplus',
      ], reason: '真机快照的入口顺序 + surveillance 隐藏 + MailPlus(uncertain) 保留');
      // surveillance 仍 absent → 无磁贴。
      expect(
        find.byKey(const Key('ws-tile-surveillance')),
        findsNothing,
        reason: 'surveillance 是 absent，磁贴不该渲染',
      );
      // 真值刷新的正向断言：已装就必须看得见（不是"没断言"）。
      expect(find.byKey(const Key('ws-tile-downloads')), findsOneWidget);
      expect(find.byKey(const Key('ws-tile-audio')), findsOneWidget);
      expect(find.byKey(const Key('ws-tile-mailplus')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('MailPlus = uncertain（两信号矛盾），设置页如实标注"信号矛盾"', (tester) async {
      _useTallSurface(tester); // 服务检测页 13 行要一屏放下才找得到最后几行
      final h = await _bootFor(realNasSnapshot);
      await _pumpShell(tester, h);

      final snap = h.container.read(serviceAvailabilityProvider);
      expect(
        snap.stateOf(StationService.mailplus),
        AvailabilityState.uncertain,
      );
      expect(
        hidesModule(snap.stateOf(StationService.mailplus)),
        isFalse,
        reason: '矛盾时绝不隐藏',
      );
      // 信号 1 真的读到了（三个 MailPlus 键）
      expect(snap.privilege, isNotNull);
      expect(
        snap.privilege!.isPresent(
          kServiceRegistry[StationService.mailplus]!.appPrivilegeKeys,
        ),
        isTrue,
      );
      // 2026-09-21 真值刷新：audio/download 已装 → available；surveillance 仍 absent。
      for (final s in [StationService.audio, StationService.download]) {
        expect(
          snap.stateOf(s),
          AvailabilityState.available,
          reason: '$s 真机已安装（由信号 2 命中）',
        );
      }
      expect(
        snap.stateOf(StationService.surveillance),
        AvailabilityState.absent,
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: ServiceCheckPage()),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('service-row-mailplus')), findsOneWidget);
      expect(find.textContaining('信号矛盾'), findsWidgets);
      expect(find.text(AppTextZh().serviceStateAbsent), findsWidgets);
    });

    testWidgets('窄屏 800x600：工作台多屏渲染不抛布局异常', (tester) async {
      final h = await _bootFor(realNasSnapshot);
      await _pumpShell(tester, h);
      await _openWorkspace(tester);
      // 第一屏只放得下 4 个磁贴 → 会有第二屏（PageView），仍然不能溢出。
      expect(find.byKey(const Key('ws-pager')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('夹具 A′：合成降级快照（真机形态但未装 audio/download，**不是当前真机**）', () {
    testWidgets('未装 audio/download → 状态 absent 且工作台无磁贴（UI 真降级）', (
      tester,
    ) async {
      _useTallSurface(tester);
      final h = await _bootFor(nasWithoutStations);
      await _pumpShell(tester, h);
      await _openWorkspace(tester);

      final snap = h.container.read(serviceAvailabilityProvider);
      expect(snap.stateOf(StationService.audio), AvailabilityState.absent);
      expect(snap.stateOf(StationService.download), AvailabilityState.absent);
      // 正向断言降级：磁贴真的不渲染，而不是"没查"。
      expect(find.byKey(const Key('ws-tile-audio')), findsNothing);
      expect(find.byKey(const Key('ws-tile-downloads')), findsNothing);
      expect(_tileIds(tester), [
        'files',
        'notes',
        'photos',
        'contacts',
        'calendar',
        'tasks',
        'search',
        'mailplus',
      ]);
      // 三个主槽仍在 → 不进受限首页；顶替者不出现（主槽已满）。
      expect(_dockExists(tester, AppTab.home), isFalse);
      expect(_dockExists(tester, AppTab.audio), isFalse);
      expect(_dockExists(tester, AppTab.download), isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  group('夹具 B：最小 NAS（只有 FileStation）', () {
    testWidgets('底栏降级为 [files, workspace, me]；chat/photo 不渲染', (tester) async {
      final h = await _bootFor(minimalNasSnapshot);
      await _pumpShell(tester, h);

      expect(_dockExists(tester, AppTab.files), isTrue);
      expect(_dockExists(tester, AppTab.workspace), isTrue);
      expect(_dockExists(tester, AppTab.me), isTrue);
      expect(
        _dockExists(tester, AppTab.chat),
        isFalse,
        reason: '核心模块 chat 缺失 → 隐藏',
      );
      expect(_dockExists(tester, AppTab.photos), isFalse);
      // 三个主槽没有全缺（files 在）→ 不进受限首页
      expect(_dockExists(tester, AppTab.home), isFalse);
      expect(
        h.container
            .read(serviceAvailabilityProvider)
            .stateOf(StationService.chat),
        AvailabilityState.absent,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('工作台只剩 files（FileStation 是 partial：tasks/search 也降级掉）', (
      tester,
    ) async {
      _useTallSurface(tester);
      final h = await _bootFor(minimalNasSnapshot);
      await _pumpShell(tester, h);
      await _openWorkspace(tester);

      expect(_tileIds(tester), ['files']);
      expect(
        h.container
            .read(serviceAvailabilityProvider)
            .stateOf(StationService.file),
        AvailabilityState.partial,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('核心模块全缺（只有 NoteStation）→ 受限模式首页', (tester) async {
      _useTallSurface(tester);
      final h = await _bootFor(noCoreNasSnapshot);
      await _pumpShell(tester, h);

      expect(_dockExists(tester, AppTab.home), isTrue);
      expect(_dockExists(tester, AppTab.workspace), isTrue);
      expect(_dockExists(tester, AppTab.me), isTrue);
      expect(_dockExists(tester, AppTab.chat), isFalse);
      expect(_dockExists(tester, AppTab.files), isFalse);
      expect(_dockExists(tester, AppTab.photos), isFalse);
      // 有可用模块时给出可点入口（note 在能力表 + AppPrivilege 里）
      expect(find.byKey(const Key('restricted-entry-note')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('夹具 C：全功能 NAS（全存在）', () {
    testWidgets('5 个 tab + 11 个磁贴（含 audio/download/surveillance/MailPlus）', (
      tester,
    ) async {
      _useTallSurface(tester);
      final h = await _bootFor(fullNasSnapshot);
      await _pumpShell(tester, h);

      expect(_dockExists(tester, AppTab.chat), isTrue);
      expect(_dockExists(tester, AppTab.files), isTrue);
      expect(_dockExists(tester, AppTab.photos), isTrue);

      await _openWorkspace(tester);
      expect(_tileIds(tester), [
        'files',
        'notes',
        'photos',
        'contacts',
        'calendar',
        'tasks',
        'search',
        'downloads',
        'audio',
        'surveillance',
        'mailplus',
      ]);
      expect(tester.takeException(), isNull);
    });
  });

  group('夹具 D：老 NAS（服务器不提供 Initdata → 信号 1 不可用）', () {
    testWidgets('退回信号 2：未装套件仍被隐藏（缺一个信号 ≠ 永不隐藏）', (tester) async {
      _useTallSurface(tester);
      final h = await _bootFor(legacyNasSnapshot);
      await _pumpShell(tester, h);
      await _openWorkspace(tester);

      final snap = h.container.read(serviceAvailabilityProvider);
      expect(snap.privilege, isNull);
      expect(snap.stateOf(StationService.audio), AvailabilityState.absent);
      expect(snap.stateOf(StationService.download), AvailabilityState.absent);
      expect(
        snap.stateOf(StationService.surveillance),
        AvailabilityState.absent,
      );
      expect(_tileIds(tester), [
        'files',
        'notes',
        'photos',
        'contacts',
        'calendar',
        'tasks',
        'search',
      ]);
      expect(tester.takeException(), isNull);
    });
  });

  group('信号 3：105 / 119 / 未知 三情形（UI 真实可见性）', () {
    testWidgets('105（已安装但无权限）→ 隐藏该 tab', (tester) async {
      final h = await _bootFor(fullNasSnapshot);
      await _pumpShell(tester, h);
      expect(_dockExists(tester, AppTab.chat), isTrue);

      h.container
          .read(serviceAvailabilityProvider.notifier)
          .reportErrorCode(StationService.chat, kNoPermissionCode);
      await tester.pump();

      expect(_dockExists(tester, AppTab.chat), isFalse);
      expect(
        h.container
            .read(serviceAvailabilityProvider)
            .stateOf(StationService.chat),
        AvailabilityState.unauthorized,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('119（会话失效）→ 绝不隐藏 + 一句"重新登录"', (tester) async {
      final h = await _bootFor(fullNasSnapshot);
      await _pumpShell(tester, h);
      final before = _dockExists(tester, AppTab.chat);

      h.container
          .read(serviceAvailabilityProvider.notifier)
          .reportErrorCode(StationService.chat, kSidNotFoundCode);
      await tester.pump();

      expect(before, isTrue);
      expect(_dockExists(tester, AppTab.chat), isTrue);
      expect(
        h.container
            .read(serviceAvailabilityProvider)
            .stateOf(StationService.chat),
        AvailabilityState.sessionExpired,
      );
      expect(find.text(AppTextZh().serviceSessionExpiredTitle), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('未知错误码 → 状态不动、tab 不隐藏（fail-open）', (tester) async {
      // 刻意把"检测用的 API"置空：这台机器**还没检测过**（unknown）。
      final h = await bootChat(
        extra: fullNasSnapshot.responses(),
        apiTable: _tableFor(fullNasSnapshot),
        moreOverrides: [availabilityApiProvider.overrideWith((ref) => null)],
      );
      await _pumpShell(tester, h, refresh: false);

      expect(
        h.container
            .read(serviceAvailabilityProvider)
            .stateOf(StationService.chat),
        AvailabilityState.unknown,
      );
      expect(_dockExists(tester, AppTab.chat), isTrue);

      // 认不出来的码（100）不许改状态
      h.container
          .read(serviceAvailabilityProvider.notifier)
          .reportErrorCode(StationService.chat, 100);
      await tester.pump();
      expect(
        h.container
            .read(serviceAvailabilityProvider)
            .stateOf(StationService.chat),
        AvailabilityState.unknown,
      );
      expect(_dockExists(tester, AppTab.chat), isTrue);
      expect(tester.takeException(), isNull);
    });
  });
}
