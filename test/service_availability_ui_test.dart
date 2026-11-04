// 统一服务可用性 · 模拟数据 UI 测试（设计 §3 的 15 条矩阵）。
//
// 用 `FakeTransport` 的可编程 `SYNO.API.Info` 能力表构造任意服务组合，
// **不连 NAS**；每条都断言"UI 上真实可见/不可见"，不是只断言状态对象。
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
import 'package:synhub/src/features/shell/workspace_recent.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

/// 全部服务都齐全的能力表（DSM `SYNO.API.Info` 的实测形态）。
Map<String, Map<String, dynamic>> _fullTable({Set<String> drop = const {}}) {
  final table = <String, Map<String, dynamic>>{...FakeTransport.table};
  for (final spec in kServiceRegistry.values) {
    for (final api in spec.allApis) {
      table[api] = {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 9};
    }
  }
  for (final d in drop) {
    table.remove(d);
  }
  return table;
}

Set<String> _requiredApis(StationService s) =>
    kServiceRegistry[s]!.requiredApis.toSet();

/// 启一个已登录的容器，并把统一检测的 API 来源指向同一条假传输。
Future<ChatHarness> _boot({
  Set<String> drop = const {},
  bool offlineDescribe = false,
}) async {
  DsmWebApi? apiBox;
  final h = await bootChat(
    apiTable: _fullTable(drop: drop),
    moreOverrides: [availabilityApiProvider.overrideWith((ref) => apiBox)],
  );
  apiBox = h.api;
  h.transport.offlineDescribe = offlineDescribe;
  return h;
}

Key _dock(AppTab t) => Key('dock-${t.name}');

Future<void> _pumpShell(
  WidgetTester tester,
  ChatHarness h, {
  AppTab? initialTab,
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
  await h.container.read(serviceAvailabilityProvider.notifier).refresh();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

int _stackIndex(WidgetTester tester) => tester
    .widget<IndexedStack>(find.byKey(const Key('app-shell-stack')))
    .index!;

void main() {
  group('§3 用例矩阵（模拟能力表）', () {
    testWidgets('#1 全部 API 齐全 → 5 个 tab 全显示', (tester) async {
      final h = await _boot();
      await _pumpShell(tester, h);
      for (final t in AppTab.values) {
        if (t == AppTab.home || kReplacementTabByService.containsValue(t)) {
          continue;
        }
        expect(_dockExists(tester, t), isTrue, reason: '缺少 tab：${t.name}');
      }
      expect(kVisibleDockCount(tester), 5);
      expect(tester.takeException(), isNull);
    });

    testWidgets('#2 无 SYNO.Chat.* → chat tab 消失；工作台聊天入口消失', (tester) async {
      final h = await _boot(drop: _requiredApis(StationService.chat));
      // 先在"最近常用"里放一条 chat，验证它也被收起
      await h.container.read(workspaceRecentProvider.notifier).record('chat');
      await _pumpShell(tester, h);

      expect(_dockExists(tester, AppTab.chat), isFalse);
      expect(_dockExists(tester, AppTab.files), isTrue);
      expect(_dockExists(tester, AppTab.photos), isTrue);

      // 去工作台：聊天入口（最近常用横滑条）应当消失
      await tester.tap(find.byKey(_dock(AppTab.workspace)));
      await tester.pump();
      expect(find.byKey(const Key('ws-recent-chat')), findsNothing);
    });

    testWidgets('#3 无 SYNO.Foto.* → photos tab 消失', (tester) async {
      final h = await _boot(drop: _requiredApis(StationService.photo));
      await _pumpShell(tester, h);
      expect(_dockExists(tester, AppTab.photos), isFalse);
      expect(_dockExists(tester, AppTab.chat), isTrue);
      expect(_dockExists(tester, AppTab.files), isTrue);
    });

    testWidgets('#4 无 FileStation.List → files 消失，note 顶替', (tester) async {
      final h = await _boot(drop: {'SYNO.FileStation.List'});
      await _pumpShell(tester, h);
      expect(_dockExists(tester, AppTab.files), isFalse);
      expect(_dockExists(tester, AppTab.note), isTrue, reason: 'note 应当顶替');
      expect(kVisibleDockCount(tester), 5);
    });

    testWidgets('#5 三个主服务全无 → 受限模式首页', (tester) async {
      final h = await _boot(
        drop: {
          ..._requiredApis(StationService.chat),
          ..._requiredApis(StationService.file),
          ..._requiredApis(StationService.photo),
        },
      );
      await _pumpShell(tester, h);
      expect(_dockExists(tester, AppTab.home), isTrue);
      expect(_dockExists(tester, AppTab.workspace), isTrue);
      expect(_dockExists(tester, AppTab.me), isTrue);
      expect(_dockExists(tester, AppTab.chat), isFalse);
      // 断言本地化 key 的结果（测试只搭 MaterialApp、无 delegate，
      // `context.t` 按约定回落 [AppTextZh]）。
      expect(find.text(AppTextZh().serviceRecheck), findsWidgets);
      // 有可用服务入口（note 在能力表里）
      expect(find.byKey(const Key('restricted-entry-note')), findsOneWidget);
    });

    testWidgets('#6 file 有 List 无 Search → 搜索入口隐藏，浏览不受影响', (tester) async {
      final h = await _boot(drop: {'SYNO.FileStation.Search'});
      await _pumpShell(tester, h);
      expect(_dockExists(tester, AppTab.files), isTrue);
      await tester.tap(find.byKey(_dock(AppTab.workspace)));
      await tester.pump();
      expect(find.text('搜索文件'), findsNothing);
      expect(find.text('文件'), findsWidgets); // 浏览入口还在
    });

    testWidgets('#7 photo 有 Browse 无 Streaming → 相册可用（partial，不隐藏）', (
      tester,
    ) async {
      final h = await _boot(drop: {'SYNO.Foto.Streaming'});
      await _pumpShell(tester, h);
      expect(_dockExists(tester, AppTab.photos), isTrue);
      expect(
        h.container
            .read(serviceAvailabilityProvider)
            .stateOf(StationService.photo),
        AvailabilityState.partial,
      );
    });

    testWidgets('#8 调用回 105（已安装但无权限）→ 隐藏该 tab', (tester) async {
      final h = await _boot();
      await _pumpShell(tester, h);
      expect(_dockExists(tester, AppTab.chat), isTrue);

      h.container
          .read(serviceAvailabilityProvider.notifier)
          .reportErrorCode(StationService.chat, kNoPermissionCode);
      await tester.pump();

      expect(_dockExists(tester, AppTab.chat), isFalse);
      // "设置 → 服务检测"里仍能看到原因
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(theme: AppTheme.dark(), home: ServiceCheckPage()),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('service-row-chat')), findsOneWidget);
      expect(find.text(AppTextZh().serviceStateUnauthorized), findsWidgets);
    });

    testWidgets('#8c 调用回 102（apiNotFound）→ absent 隐藏（未安装）', (tester) async {
      final h = await _boot();
      await _pumpShell(tester, h);
      expect(_dockExists(tester, AppTab.chat), isTrue);

      h.container
          .read(serviceAvailabilityProvider.notifier)
          .reportErrorCode(StationService.chat, kApiNotFoundCode);
      await tester.pump();

      expect(_dockExists(tester, AppTab.chat), isFalse);
    });

    testWidgets('#8b 会话失效回 119/106 → 绝不隐藏 + 提示重新登录', (tester) async {
      final h = await _boot();
      await _pumpShell(tester, h);

      h.container
          .read(serviceAvailabilityProvider.notifier)
          .reportErrorCode(StationService.chat, kSidNotFoundCode);
      await tester.pump();

      // 所有 tab 保持原样
      for (final t in AppTab.values) {
        if (t == AppTab.home || kReplacementTabByService.containsValue(t)) {
          continue;
        }
        expect(_dockExists(tester, t), isTrue, reason: '119 不该隐藏 ${t.name}');
      }
      // 统一提示"会话已过期，请重新登录"
      expect(find.text(AppTextZh().serviceSessionExpiredTitle), findsWidgets);
      // 106 同理
      h.container
          .read(serviceAvailabilityProvider.notifier)
          .reportErrorCode(StationService.file, kSessionTimeoutCode);
      await tester.pump();
      expect(_dockExists(tester, AppTab.files), isTrue);
    });

    testWidgets('#9 网络失败 → 不隐藏，显示可重试', (tester) async {
      final h = await _boot(offlineDescribe: true);
      await _pumpShell(tester, h);
      for (final t in [AppTab.chat, AppTab.files, AppTab.photos]) {
        expect(_dockExists(tester, t), isTrue, reason: '网络失败不该隐藏 ${t.name}');
      }
      expect(find.text(AppTextZh().serviceUnreachableTitle), findsWidgets);
      expect(
        h.container
            .read(serviceAvailabilityProvider)
            .stateOf(StationService.chat),
        AvailabilityState.unreachable,
      );
    });

    testWidgets('#10 先 absent，重新检测后 available → tab 从隐藏变显示', (tester) async {
      final h = await _boot(drop: _requiredApis(StationService.chat));
      await _pumpShell(tester, h);
      expect(_dockExists(tester, AppTab.chat), isFalse);

      // 服务端"装上"了 Chat：能力表补回来 → 重新检测
      for (final api in _requiredApis(StationService.chat)) {
        h.transport.apiTable[api] = {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 9,
        };
      }
      await h.container.read(serviceAvailabilityProvider.notifier).refresh();
      await tester.pump();
      expect(_dockExists(tester, AppTab.chat), isTrue);
    });

    testWidgets('#10b 先 unauthorized（105），授权后重新检测 → tab 恢复', (tester) async {
      final h = await _boot();
      await _pumpShell(tester, h);
      h.container
          .read(serviceAvailabilityProvider.notifier)
          .reportErrorCode(StationService.chat, kNoPermissionCode);
      await tester.pump();
      expect(_dockExists(tester, AppTab.chat), isFalse);

      // 管理员授予权限后重新检测 → 能力表仍全在 → available
      await h.container.read(serviceAvailabilityProvider.notifier).refresh();
      await tester.pump();
      expect(_dockExists(tester, AppTab.chat), isTrue);
    });

    testWidgets('#10c 会话失效（119）后再登录成功 → 可见性全程不变', (tester) async {
      final h = await _boot();
      await _pumpShell(tester, h);
      final before = kVisibleDockCount(tester);

      h.container
          .read(serviceAvailabilityProvider.notifier)
          .reportErrorCode(StationService.chat, kSidNotFoundCode);
      await tester.pump();
      expect(kVisibleDockCount(tester), before);

      // 重新登录成功（能力表不变）→ 重新检测
      await h.container.read(serviceAvailabilityProvider.notifier).refresh();
      await tester.pump();
      expect(kVisibleDockCount(tester), before);
      expect(_dockExists(tester, AppTab.chat), isTrue);
    });

    testWidgets('#11 恢复态落在被隐藏的 tab → 回落到第一个可见 tab', (tester) async {
      final h = await _boot();
      h.container.read(appTabProvider.notifier).select(AppTab.chat);
      await _pumpShell(tester, h);
      expect(h.container.read(appTabProvider), AppTab.chat);

      // chat 变成 absent
      for (final api in _requiredApis(StationService.chat)) {
        h.transport.apiTable.remove(api);
      }
      await h.container.read(serviceAvailabilityProvider.notifier).refresh();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(h.container.read(appTabProvider), AppTab.files);
      expect(_stackIndex(tester), 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('安全阀：临时显示隐藏的模块 → 隐藏 tab 恢复可见，关掉又隐藏', (tester) async {
      final h = await _boot(drop: _requiredApis(StationService.chat));
      await _pumpShell(tester, h);
      expect(_dockExists(tester, AppTab.chat), isFalse);

      await h.container.read(showHiddenServicesProvider.notifier).set(true);
      await tester.pump();
      expect(_dockExists(tester, AppTab.chat), isTrue);

      await h.container.read(showHiddenServicesProvider.notifier).set(false);
      await tester.pump();
      expect(_dockExists(tester, AppTab.chat), isFalse);
    });

    testWidgets('#12 主 tab 隐藏后 index 映射：点第 N 个可见 tab 开第 N 个模块', (tester) async {
      final h = await _boot(drop: _requiredApis(StationService.chat));
      await _pumpShell(tester, h);
      final visible = visibleTabs(
        h.container.read(serviceAvailabilityProvider).resolvedStates,
      );
      expect(visible, [
        AppTab.files,
        AppTab.photos,
        AppTab.note, // 顶替 chat 的第一个可用模块
        AppTab.workspace,
        AppTab.me,
      ]);

      for (var i = 0; i < visible.length; i++) {
        final tab = visible[i];
        await tester.tap(find.byKey(_dock(tab)));
        await tester.pump();
        expect(h.container.read(appTabProvider), tab, reason: '第 $i 个 tab');
        expect(_stackIndex(tester), i, reason: 'index 与可见列表错位');
      }
    });
  });
}

bool _dockExists(WidgetTester tester, AppTab tab) =>
    find.byKey(_dock(tab)).evaluate().isNotEmpty;

int kVisibleDockCount(WidgetTester tester) =>
    tester.widgetList(find.byType(InkWell)).where((w) {
      final key = w.key;
      return key is ValueKey<String> && key.value.startsWith('dock-');
    }).length;
