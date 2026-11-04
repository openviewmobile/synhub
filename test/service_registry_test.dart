// 能力层 + 可见性纯函数的单测（不 pump UI，设计 §2.1 / §2.3 / §4）。
//
// 这里同时守住两条"防漂移"线：
//   * `service_registry.dart` 里的错误码镜像必须与 `DsmErrorCode` 一致；
//   * `visibleTabs` 的隐藏语义（absent / unauthorized 隐藏；
//     sessionExpired / unreachable / unknown 不隐藏）必须成立。
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/shell/app_tab.dart';

Map<StationService, AvailabilityState> _states(
  Map<StationService, AvailabilityState> overrides,
) => {
  for (final s in StationService.values) s: AvailabilityState.available,
  ...overrides,
};

/// 只让三个主服务参与判定（其余服务 unknown，隔离顶替逻辑）。
Map<StationService, AvailabilityState> _primaryStates(
  Map<StationService, AvailabilityState> overrides,
) => {
  for (final s in StationService.values) s: AvailabilityState.unknown,
  StationService.chat: AvailabilityState.available,
  StationService.file: AvailabilityState.available,
  StationService.photo: AvailabilityState.available,
  ...overrides,
};

/// 全部服务都齐全的 API 名集合。
Set<String> _allApis() => {
  for (final spec in kServiceRegistry.values) ...spec.allApis,
};

void main() {
  group('注册表完整性', () {
    test('13 个服务都有 ServiceSpec；主槽只有 chat/file/photo', () {
      for (final s in StationService.values) {
        expect(
          kServiceRegistry.containsKey(s),
          isTrue,
          reason: '缺少 $s 的 ServiceSpec',
        );
      }
      final primary = kServiceRegistry.values
          .where((s) => s.primarySlot != null)
          .map((s) => s.id)
          .toSet();
      expect(primary, {
        StationService.chat,
        StationService.file,
        StationService.photo,
      });
    });

    test('API 名都像 SYNO.*，且没有重复进错服务的名字', () {
      for (final spec in kServiceRegistry.values) {
        for (final api in spec.allApis) {
          expect(api.startsWith('SYNO.'), isTrue, reason: '非法 API 名：$api');
        }
      }
    });

    test('ai：本机能力恒可用 + NAS AI Console 是可选增强（2026-09-21 更正）', () {
      final ai = kServiceRegistry[StationService.ai]!;
      // 端侧模型 + 自带 key 的云端 LLM 是**本机能力** → 没有必需服务端 API，
      // 永不 `absent` / 隐藏（旧断言"没有 SYNO.AI.*"已被活体探针推翻）。
      expect(ai.requiredApis, isEmpty);
      expect(ai.primarySlot, isNull);
      // NAS 侧 AI Console 登记为**可选能力位**。
      expect(ai.optionalApis, [
        kAiCompletionApi,
        kAiThreadApi,
        kAiConfigApi,
        kAiMetricsApi,
      ]);
      // 一台没有任何 SYNO.AI.* 的 NAS → 仍不隐藏模块，只如实报 partial。
      final none = classifyApiTable(ai, const {});
      expect(none, AvailabilityState.partial);
      expect(hidesModule(none), isFalse, reason: '端侧 / 云端 AI 仍可用');
      // 服务端 AI 齐全 → available。
      expect(
        classifyApiTable(ai, {
          kAiCompletionApi,
          kAiThreadApi,
          kAiConfigApi,
          kAiMetricsApi,
        }),
        AvailabilityState.available,
      );
      // 只缺一个服务端位 → partial，仍不隐藏。
      expect(
        classifyApiTable(ai, {kAiCompletionApi, kAiThreadApi, kAiConfigApi}),
        AvailabilityState.partial,
      );
    });

    test('错误码镜像与 DsmErrorCode 一致（防两处漂移）', () {
      expect(kApiNotFoundCode, DsmErrorCode.apiNotFound);
      expect(kNoPermissionCode, DsmErrorCode.noPermission);
      expect(kNoAppPrivilegeCode, DsmErrorCode.noAppPrivilege);
      expect(kSidNotFoundCode, DsmErrorCode.sidNotFound);
      expect(kSessionTimeoutCode, DsmErrorCode.sessionTimeout);
    });

    test('顶替顺序每一项都能映射成非主槽 tab', () {
      for (final s in kReplacementOrder) {
        final tab = kReplacementTabByService[s];
        expect(tab, isNotNull, reason: '$s 缺顶替 tab');
        expect(kPrimaryTabByService.containsKey(s), isFalse);
      }
    });
  });

  group('classifyApiTable', () {
    final file = kServiceRegistry[StationService.file]!;

    test('必需全在且可选全在 → available', () {
      expect(classifyApiTable(file, _allApis()), AvailabilityState.available);
    });

    test('必需缺失 → absent（未安装）', () {
      final apis = _allApis()..remove('SYNO.FileStation.List');
      expect(classifyApiTable(file, apis), AvailabilityState.absent);
    });

    test('只缺可选 → partial（模块仍可用）', () {
      final apis = _allApis()..remove('SYNO.FileStation.Search');
      expect(classifyApiTable(file, apis), AvailabilityState.partial);
    });
  });

  group('classifyErrorCode（105 / 119 绝不能混）', () {
    test('102 → absent（未安装，隐藏）', () {
      expect(classifyErrorCode(102), AvailabilityState.absent);
    });

    test('105 / 160 → unauthorized（无权限，也隐藏）', () {
      expect(classifyErrorCode(105), AvailabilityState.unauthorized);
      expect(classifyErrorCode(160), AvailabilityState.unauthorized);
    });

    test('119 / 106 → sessionExpired（会话失效，绝不隐藏）', () {
      expect(classifyErrorCode(119), AvailabilityState.sessionExpired);
      expect(classifyErrorCode(106), AvailabilityState.sessionExpired);
    });

    test('其它码 → unknown（宁可不动）', () {
      expect(classifyErrorCode(100), AvailabilityState.unknown);
    });

    test('hidesModule：只有 absent / unauthorized 隐藏', () {
      expect(hidesModule(AvailabilityState.absent), isTrue);
      expect(hidesModule(AvailabilityState.unauthorized), isTrue);
      for (final s in [
        AvailabilityState.available,
        AvailabilityState.partial,
        AvailabilityState.unknown,
        AvailabilityState.sessionExpired,
        AvailabilityState.unreachable,
      ]) {
        expect(hidesModule(s), isFalse, reason: '$s 不该隐藏');
      }
    });
  });

  group('visibleTabs', () {
    test('全部可用 → 固定 5 个（回归基线）', () {
      expect(visibleTabs(_states({})), [
        AppTab.chat,
        AppTab.files,
        AppTab.photos,
        AppTab.workspace,
        AppTab.me,
      ]);
    });

    test('chat absent → 隐藏，其它保持', () {
      // 顶替者（note 等）故意留 unknown，隔离"隐藏"本身的行为
      expect(
        visibleTabs(
          _primaryStates({StationService.chat: AvailabilityState.absent}),
        ),
        [AppTab.files, AppTab.photos, AppTab.workspace, AppTab.me],
      );
    });

    test('chat unauthorized（无权限）→ 也隐藏', () {
      expect(
        visibleTabs(
          _primaryStates({StationService.chat: AvailabilityState.unauthorized}),
        ),
        [AppTab.files, AppTab.photos, AppTab.workspace, AppTab.me],
      );
    });

    test('chat sessionExpired（119）→ 绝不隐藏', () {
      expect(
        visibleTabs(
          _states({StationService.chat: AvailabilityState.sessionExpired}),
        ),
        [AppTab.chat, AppTab.files, AppTab.photos, AppTab.workspace, AppTab.me],
      );
    });

    test('chat unreachable（网络）→ 不隐藏', () {
      expect(
        visibleTabs(
          _states({StationService.chat: AvailabilityState.unreachable}),
        ),
        [AppTab.chat, AppTab.files, AppTab.photos, AppTab.workspace, AppTab.me],
      );
    });

    test('file absent + note available → note 顶替', () {
      expect(
        visibleTabs(
          _states({
            StationService.file: AvailabilityState.absent,
            StationService.note: AvailabilityState.available,
          }),
        ),
        [AppTab.chat, AppTab.photos, AppTab.note, AppTab.workspace, AppTab.me],
      );
    });

    test('顶替者自己也 partial → 不顶替', () {
      final tabs = visibleTabs(
        _states({
          StationService.file: AvailabilityState.absent,
          StationService.note: AvailabilityState.partial,
          StationService.calendar: AvailabilityState.available,
        }),
      );
      expect(tabs.contains(AppTab.note), isFalse);
      expect(tabs.contains(AppTab.calendar), isTrue);
    });

    test('三个主服务全隐藏 → 受限模式首页 + workspace / me', () {
      expect(
        visibleTabs(
          _states({
            StationService.chat: AvailabilityState.absent,
            StationService.file: AvailabilityState.unauthorized,
            StationService.photo: AvailabilityState.absent,
          }),
        ),
        [AppTab.home, AppTab.workspace, AppTab.me],
      );
    });

    test('unknown 不隐藏（未检测时先按可见渲染）', () {
      expect(visibleTabs(unknownAvailability()), [
        AppTab.chat,
        AppTab.files,
        AppTab.photos,
        AppTab.workspace,
        AppTab.me,
      ]);
    });

    test('安全阀 showHidden → 隐藏的模块恢复可见', () {
      expect(
        visibleTabs(
          _states({
            StationService.chat: AvailabilityState.absent,
            StationService.file: AvailabilityState.unauthorized,
          }),
          showHidden: true,
        ),
        [AppTab.chat, AppTab.files, AppTab.photos, AppTab.workspace, AppTab.me],
      );
    });

    test('hiddenPrimaryServices 只包含被隐藏的主槽', () {
      expect(
        hiddenPrimaryServices(
          _states({
            StationService.chat: AvailabilityState.absent,
            StationService.file: AvailabilityState.sessionExpired,
          }),
        ),
        [StationService.chat],
      );
    });
  });
}
