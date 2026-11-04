// S2 任务 1：**统一错误出口**接线（模块调用失败 → 回填服务状态）。
//
// 这里验的是"真链路"：`ServiceReportingApi.call` 失败 → 注册表反查服务 →
// `ServiceAvailabilityNotifier.reportApiError` → `hidesModule` → 底栏 tab。
// 不是只断言状态对象，而是断言 `AppShellPage` 上 tab 真实可见/不可见。
//
// 三条承重用例（设计 §3 矩阵 8 / 8c / 8b / 9 的 S2 接线版）：
//   * 105（无权限）→ **隐藏**；
//   * 102（未安装）→ **隐藏**；
//   * 119（会话失效）→ **绝不隐藏**（反例，防止误伤）；
//   * 网络异常 → **不隐藏**。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/shell/app_shell_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

/// 全服务齐全的能力表。
Map<String, Map<String, dynamic>> _fullTable() {
  final table = <String, Map<String, dynamic>>{...FakeTransport.table};
  for (final spec in kServiceRegistry.values) {
    for (final api in spec.allApis) {
      table[api] = {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 9};
    }
  }
  return table;
}

Future<ChatHarness> _boot() async {
  DsmWebApi? apiBox;
  final h = await bootChat(
    apiTable: _fullTable(),
    moreOverrides: [availabilityApiProvider.overrideWith((ref) => apiBox)],
  );
  apiBox = h.api;
  // 关掉"自动重登"：本组用例要确定性观察**回填**，不让重登把 sid 换掉后
  // 触发一次重新探测把状态覆盖回 available。
  h.api.onSessionExpired = null;
  // 首次探测：挂上统一错误出口回调。
  await h.container.read(serviceAvailabilityProvider.notifier).refresh();
  return h;
}

Future<void> _pumpShell(WidgetTester tester, ChatHarness h) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(theme: AppTheme.dark(), home: AppShellPage()),
    ),
  );
  await tester.pump();
}

bool _dock(WidgetTester tester, AppTab tab) =>
    find.byKey(Key('dock-${tab.name}')).evaluate().isNotEmpty;

/// 让下一次某 API 调用回一个错误码（永久失败）。
Future<void> _failCall(
  ChatHarness h,
  String api,
  String method,
  int code,
) async {
  h.transport.failures['$api.$method'] = code;
  await expectLater(
    h.api.call(api, method),
    throwsA(isA<DsmApiException>()),
    reason: '$api.$method 应当抛 DsmApiException($code)',
  );
}

void main() {
  group('S2 统一错误出口回填', () {
    testWidgets('① 105 无权限回填 → 模块隐藏（R6-6 前置）', (tester) async {
      final h = await _boot();
      await _pumpShell(tester, h);
      expect(_dock(tester, AppTab.files), isTrue);

      await _failCall(h, 'SYNO.FileStation.List', 'list', kNoPermissionCode);
      await tester.pump();

      expect(
        h.container
            .read(serviceAvailabilityProvider)
            .stateOf(StationService.file),
        AvailabilityState.unauthorized,
      );
      expect(_dock(tester, AppTab.files), isFalse, reason: '105 必须隐藏');
    });

    testWidgets('② 102 未安装回填 → 模块隐藏', (tester) async {
      final h = await _boot();
      await _pumpShell(tester, h);
      expect(_dock(tester, AppTab.files), isTrue);

      await _failCall(h, 'SYNO.FileStation.List', 'list', kApiNotFoundCode);
      await tester.pump();

      expect(
        h.container
            .read(serviceAvailabilityProvider)
            .stateOf(StationService.file),
        AvailabilityState.absent,
      );
      expect(_dock(tester, AppTab.files), isFalse, reason: '102 必须隐藏');
    });

    testWidgets('③ 119 会话失效回填 → 可见性**完全不变**（反例）', (tester) async {
      final h = await _boot();
      await _pumpShell(tester, h);
      final before = [
        for (final t in [AppTab.chat, AppTab.files, AppTab.photos])
          _dock(tester, t),
      ];

      await _failCall(h, 'SYNO.FileStation.List', 'list', kSidNotFoundCode);
      await tester.pump();

      expect(
        h.container
            .read(serviceAvailabilityProvider)
            .stateOf(StationService.file),
        AvailabilityState.sessionExpired,
      );
      // 119 绝不隐藏：三个主 tab 与之前**逐个相同**
      for (var i = 0; i < 3; i++) {
        expect(
          _dock(tester, [AppTab.chat, AppTab.files, AppTab.photos][i]),
          before[i],
          reason: '119 不允许改变可见性',
        );
      }
      expect(_dock(tester, AppTab.files), isTrue);
      // 106（会话超时）同理
      await _failCall(h, 'SYNO.Chat.Channel', 'list', kSessionTimeoutCode);
      await tester.pump();
      expect(_dock(tester, AppTab.chat), isTrue);
    });

    testWidgets('④ 网络失败回填 → 可见性不变', (tester) async {
      final h = await _boot();
      await _pumpShell(tester, h);

      h.transport.offlineKeys.add('SYNO.FileStation.List.list');
      await expectLater(
        h.api.call('SYNO.FileStation.List', 'list'),
        throwsA(isA<Object>()),
      );
      await tester.pump();

      expect(
        h.container
            .read(serviceAvailabilityProvider)
            .stateOf(StationService.file),
        AvailabilityState.unreachable,
      );
      expect(_dock(tester, AppTab.files), isTrue, reason: '网络失败不该隐藏');
    });

    testWidgets('⑤ 可选能力位回 102 → partial（不隐藏整个模块）', (tester) async {
      final h = await _boot();
      await _pumpShell(tester, h);

      // `Thumb` 是 file 的可选能力位：它 102 不代表 File Station 没装。
      await _failCall(h, 'SYNO.FileStation.Thumb', 'get', kApiNotFoundCode);
      await tester.pump();

      expect(
        h.container
            .read(serviceAvailabilityProvider)
            .stateOf(StationService.file),
        AvailabilityState.partial,
      );
      expect(_dock(tester, AppTab.files), isTrue, reason: '可选能力位缺失不隐藏');
    });
  });
}
