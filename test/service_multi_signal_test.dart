// 统一多信号检测的**纯判定**用例（用户 2026-09-21 要求：多信号合并 + 模拟数据）。
//
// 这里钉死三件最容易做错的事：
//   1. 各模块的 AppPrivilege 键**逐条取证**不许漂移（形状也不许照抄）；
//   2. 合并规则：信号 2 缺席 + 信号 1 缺席 → absent；两者矛盾 → **绝不 absent**；
//   3. 105 / 119 / 106 / unknown 的既有语义一字不改。
//
// 不连 NAS、不 pump UI（UI 层在 `service_multi_signal_ui_test.dart`）。
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/features/shell/app_tab.dart';

import 'support/nas_capability_fixtures.dart';

AppPrivilegeSignal _priv(Map<String, bool> entries, {bool allowAll = false}) =>
    AppPrivilegeSignal(entries: entries, allowAll: allowAll);

ServiceSpec _spec(StationService s) => kServiceRegistry[s]!;

Set<String> _apis(StationService s) => _spec(s).allApis.toSet();

void main() {
  group('信号 1 的键：逐条取证（防漂移）', () {
    test('除 ai 外每个模块都登记了 AppPrivilege 键；ai 刻意不登记', () {
      for (final s in StationService.values) {
        final keys = _spec(s).appPrivilegeKeys;
        if (s == StationService.ai) {
          expect(keys, isEmpty, reason: 'AI 在本机能力层不依赖 AppPrivilege');
        } else {
          expect(keys, isNotEmpty, reason: '$s 缺 AppPrivilege 键');
        }
        for (final k in keys) {
          expect(k.startsWith('SYNO.'), isTrue, reason: '非法键：$k');
        }
      }
    });

    test('每个键的取值 = 解包包 INFO 的 dsmappname / 真机 AppPrivilege 原文', () {
      // 等级 A：包内 `INFO` 的 `dsmappname=` 逐字命中。
      expect(_spec(StationService.file).appPrivilegeKeys, [
        'SYNO.SDS.App.FileStation3.Instance', // export_FileStation/INFO
      ]);
      expect(_spec(StationService.photo).appPrivilegeKeys, [
        'SYNO.Foto.AppInstance', // export_SynologyPhotos/INFO + 官方 JS 查表点
      ]);
      expect(_spec(StationService.note).appPrivilegeKeys, [
        'SYNO.SDS.NoteStation.Application', // export_NoteStation/INFO
      ]);
      expect(_spec(StationService.calendar).appPrivilegeKeys, [
        'SYNO.Cal.Application', // export_Calendar/INFO（**不是** SYNO.SDS.*）
      ]);
      expect(_spec(StationService.contacts).appPrivilegeKeys, [
        'SYNO.Contacts.AppInstance', // export_Contacts/INFO
      ]);
      expect(_spec(StationService.drive).appPrivilegeKeys, [
        'SYNO.SDS.Drive.Application', // export_SynologyDrive/INFO
      ]);
      expect(_spec(StationService.office).appPrivilegeKeys, [
        'SYNO.SDS.Office.AppInstance', // export_Office/INFO（真机 AppPrivilege 无此键）
      ]);
      expect(_spec(StationService.audio).appPrivilegeKeys, [
        'SYNO.SDS.AudioStation.Application', // export_AudioStation/INFO
      ]);
      expect(_spec(StationService.download).appPrivilegeKeys, [
        'SYNO.SDS.DownloadStation.Application', // export_DownloadStation/INFO
      ]);
      // 等级 A（无后缀！别照抄 .Application / .Instance 的形状）
      expect(_spec(StationService.surveillance).appPrivilegeKeys, [
        'SYNO.SDS.SurveillanceStation', // ex_SS/INFO
      ]);
      expect(_spec(StationService.mailplus).appPrivilegeKeys, [
        'SYNO.SDS.MailClient.Application', // ex_MailPlus/INFO
        'SYNO.SDS.MailPlusServer.Instance', // ex_MPS/INFO
        'SYNO.SDS.MailServer.Instance', // 真机 AppPrivilege 第 15 项
      ]);
      // 等级 B：无 Chat 解包件，键取自真机 AppPrivilege 全量 20 项。
      expect(_spec(StationService.chat).appPrivilegeKeys, [
        'SYNO.SDS.Chat.Application',
      ]);
    });
  });

  group('AppPrivilegeSignal：照抄官方前端语义', () {
    test('键存在且为 true → 命中', () {
      final s = _priv(const {'SYNO.Foto.AppInstance': true});
      expect(s.isPresent(const ['SYNO.Foto.AppInstance']), isTrue);
      expect(s.isDenied(const ['SYNO.Foto.AppInstance']), isFalse);
    });

    test('键存在且为 false → 明确拒绝（不是"未知"）', () {
      final s = _priv(const {'SYNO.Foto.AppInstance': false});
      expect(s.isPresent(const ['SYNO.Foto.AppInstance']), isFalse);
      expect(s.isDenied(const ['SYNO.Foto.AppInstance']), isTrue);
    });

    test('键不存在 → 既非命中亦非拒绝（官方前端判"不允许"，但不是矛盾）', () {
      final s = _priv(const {'SYNO.Desktop': true});
      expect(s.isPresent(const ['SYNO.Foto.AppInstance']), isFalse);
      expect(s.isDenied(const ['SYNO.Foto.AppInstance']), isFalse);
    });

    test('通配键 SYNO.ALLOW.ALL.APPLICATIONS 只抵消 false，不凭空造"命中"', () {
      final wildcard = _priv(const {
        kAppPrivilegeAllowAllKey: true,
        'SYNO.Foto.AppInstance': false,
      }, allowAll: true);
      // 抵消 false → 不算拒绝
      expect(wildcard.isDenied(const ['SYNO.Foto.AppInstance']), isFalse);
      expect(wildcard.isPresent(const ['SYNO.Foto.AppInstance']), isTrue);
      // 但"键根本不存在"≠ 已安装（否则管理员账号下没装的套件永远藏不掉）
      final noKey = _priv(const {
        kAppPrivilegeAllowAllKey: true,
      }, allowAll: true);
      expect(noKey.isPresent(const ['SYNO.Foto.AppInstance']), isFalse);
      expect(noKey.isDenied(const ['SYNO.Foto.AppInstance']), isFalse);
    });

    test('多键：任一命中即命中；全部 false 才算拒绝', () {
      final mixed = _priv(const {
        'SYNO.SDS.MailClient.Application': false,
        'SYNO.SDS.MailPlusServer.Instance': true,
      });
      const keys = [
        'SYNO.SDS.MailClient.Application',
        'SYNO.SDS.MailPlusServer.Instance',
      ];
      expect(mixed.isPresent(keys), isTrue);
      expect(mixed.isDenied(keys), isFalse);
    });

    test('fromInitdata：没有 AppPrivilege → unavailable（known=false）', () {
      expect(AppPrivilegeSignal.fromInitdata(const {}).known, isFalse);
      expect(
        AppPrivilegeSignal.fromInitdata(const {'AppPrivilege': 'oops'}).known,
        isFalse,
      );
    });

    test('fromInitdata：忽略非布尔值，只留真 bool', () {
      final s = AppPrivilegeSignal.fromInitdata(const {
        'AppPrivilege': {
          'SYNO.Foto.AppInstance': true,
          'SYNO.Desktop': 'yes', // 非 bool → 丢弃
        },
      });
      expect(s.known, isTrue);
      expect(s.entries, {'SYNO.Foto.AppInstance': true});
    });
  });

  group('classifyMultiSignal：合并规则（真机快照）', () {
    test('真机：MailPlus 两信号矛盾 → uncertain，**绝不 absent**', () {
      final states = realNasSnapshot.states();
      expect(
        states[StationService.mailplus],
        AvailabilityState.uncertain,
        reason: '信号 2 缺席（SYNO.MailClient.* = 0）但信号 1 三键全 true',
      );
      expect(hidesModule(states[StationService.mailplus]!), isFalse);
      expect(states[StationService.mailplus], isNot(AvailabilityState.absent));
    });

    test('真机：audio / download 已安装 → available；surveillance 一致缺席 → absent', () {
      final states = realNasSnapshot.states();
      // 2026-09-21 真值刷新：真机已装 AS（27 个命名空间）/ DS（43 个命名空间），
      // 信号 2 命中 → available（证据见夹具头注释与 docs/*parity-audit.md）。
      for (final s in [StationService.audio, StationService.download]) {
        expect(
          states[s],
          AvailabilityState.available,
          reason: '$s 应当 available',
        );
        expect(hidesModule(states[s]!), isFalse, reason: '$s 不该被隐藏');
      }
      // 未装的 surveillance 仍是"两信号一致缺席"。
      expect(states[StationService.surveillance], AvailabilityState.absent);
      expect(hidesModule(states[StationService.surveillance]!), isTrue);
      expect(realNasSnapshot.hiddenServices(), [StationService.surveillance]);
    });

    test('合成降级快照：未装 audio/download → 两信号一致缺席 → absent 且隐藏', () {
      // [nasWithoutStations] 是**为降级路径构造**的合成快照，不是当前真机；
      // 用它钉死"服务端没有该服务时客户端要降级"这条能力。
      final states = nasWithoutStations.states();
      for (final s in [
        StationService.audio,
        StationService.download,
        StationService.surveillance,
      ]) {
        expect(states[s], AvailabilityState.absent, reason: '$s 应当 absent');
        expect(hidesModule(states[s]!), isTrue);
      }
      expect(nasWithoutStations.hiddenServices(), [
        StationService.audio,
        StationService.download,
        StationService.surveillance,
      ]);
    });

    test('真机：已装模块 available（含 Office——它的 AppPrivilege 键在真机缺席）', () {
      final states = realNasSnapshot.states();
      for (final s in [
        StationService.chat,
        StationService.file,
        StationService.photo,
        StationService.note,
        StationService.calendar,
        StationService.contacts,
        StationService.drive,
        StationService.office,
        StationService.ai,
        // 2026-09-21 真值刷新：真机已装 AS/DS，两者都是 available。
        StationService.audio,
        StationService.download,
      ]) {
        expect(
          states[s],
          AvailabilityState.available,
          reason: '$s 应当 available',
        );
      }
      // Office 的键确实不在真机 AppPrivilege 里 → 它靠信号 2 立住。
      expect(
        realNasSnapshot.privilege.isPresent(
          _spec(StationService.office).appPrivilegeKeys,
        ),
        isFalse,
      );
    });

    test('真机底栏：5 个 tab（三个主槽都还在）', () {
      expect(realNasSnapshot.tabs(), [
        AppTab.chat,
        AppTab.files,
        AppTab.photos,
        AppTab.workspace,
        AppTab.me,
      ]);
    });

    test('真机普查锚定：API 数 / AS·DS 命名空间数 / 装机版本（防夹具漂移）', () {
      // 数字真值来源（真机只读采集 2026-09-21，本批未重新探测）：
      //   1047   → docs/audio-parity-audit.md:93、docs/download-parity-audit.md:44
      //   27 / 43→ docs/audio-parity-audit.md:95、docs/download-parity-audit.md:45
      //   装机版本→ docs/audio-parity-audit.md:83、docs/download-parity-audit.md:24
      expect(
        realNasSnapshot.apiCensus,
        1047,
        reason: '装 AS/DS 后的真机 `SYNO.API.Info` 普查数（未装时 977）',
      );
      expect(kLiveNasAudioStationNamespaces, 27);
      expect(kLiveNasDownloadStationNamespaces, 43);
      expect(kLiveNasAudioStationVersion, '7.2.1-6006');
      expect(kLiveNasDownloadStationVersion, '4.1.2-5012');
      // 合成快照**不**声明普查数（编的数据不许冒充采到的）。
      expect(nasWithoutStations.apiCensus, isNull);
    });
  });

  group('classifyMultiSignal：最小 NAS / 全功能 NAS', () {
    test('最小 NAS：只有 FileStation → file partial，其余 absent', () {
      final states = minimalNasSnapshot.states();
      expect(states[StationService.file], AvailabilityState.partial);
      expect(states[StationService.chat], AvailabilityState.absent);
      expect(states[StationService.photo], AvailabilityState.absent);
      expect(states[StationService.mailplus], AvailabilityState.absent);
      // ai 是本机能力：没有服务端位也永不 absent。
      expect(states[StationService.ai], AvailabilityState.partial);
      expect(minimalNasSnapshot.hiddenServices(), [
        StationService.chat,
        StationService.photo,
        StationService.note,
        StationService.calendar,
        StationService.contacts,
        StationService.drive,
        StationService.office,
        StationService.audio,
        StationService.download,
        StationService.surveillance,
        StationService.mailplus,
      ]);
    });

    test('最小 NAS：核心模块 chat/photo 缺失 → 降级为 [files, workspace, me]', () {
      expect(minimalNasSnapshot.tabs(), [
        AppTab.files,
        AppTab.workspace,
        AppTab.me,
      ]);
    });

    test('无核心模块（只有 NoteStation）→ 受限模式首页', () {
      expect(noCoreNasSnapshot.tabs(), [
        AppTab.home,
        AppTab.workspace,
        AppTab.me,
      ]);
      final tabs = noCoreNasSnapshot.tabs();
      expect(tabs.contains(AppTab.chat), isFalse);
      expect(tabs.contains(AppTab.files), isFalse);
      expect(tabs.contains(AppTab.photos), isFalse);
    });

    test('全功能 NAS：13 个服务全 available', () {
      final states = fullNasSnapshot.states();
      for (final e in states.entries) {
        expect(
          e.value,
          AvailabilityState.available,
          reason: '${e.key} 应 available',
        );
      }
      expect(fullNasSnapshot.hiddenServices(), isEmpty);
      expect(fullNasSnapshot.tabs(), [
        AppTab.chat,
        AppTab.files,
        AppTab.photos,
        AppTab.workspace,
        AppTab.me,
      ]);
    });
  });

  group('classifyMultiSignal：回退与边界', () {
    test('信号 1 不可用（服务器没有 Initdata）→ 与 classifyApiTable 完全一致', () {
      final apis = legacyNasSnapshot.apiNames;
      for (final e in kServiceRegistry.entries) {
        expect(
          classifyMultiSignal(e.value, apis, legacyNasSnapshot.privilege),
          classifyApiTable(e.value, apis),
          reason: '${e.key} 的回退路径漂了',
        );
      }
      // 回退后照样能隐藏"没装"的套件（不是"缺一个信号就永远不隐藏"）。
      final states = legacyNasSnapshot.states();
      expect(states[StationService.audio], AvailabilityState.absent);
      expect(states[StationService.download], AvailabilityState.absent);
      expect(states[StationService.surveillance], AvailabilityState.absent);
      expect(states[StationService.chat], AvailabilityState.available);
      expect(states[StationService.mailplus], AvailabilityState.absent);
    });

    test('privilege == null → 与 classifyApiTable 一致', () {
      final apis = realNasSnapshot.apiNames;
      for (final e in kServiceRegistry.entries) {
        expect(
          classifyMultiSignal(e.value, apis, null),
          classifyApiTable(e.value, apis),
        );
      }
    });

    test('信号 1 明确拒绝（键 false）→ unauthorized，权限优先于信号 2', () {
      final apis = fullNasSnapshot.apiNames;
      final priv = _priv(const {'SYNO.Foto.AppInstance': false});
      expect(
        classifyMultiSignal(_spec(StationService.photo), apis, priv),
        AvailabilityState.unauthorized,
      );
      expect(
        hidesModule(
          classifyMultiSignal(_spec(StationService.photo), apis, priv),
        ),
        isTrue,
      );
      // 其它模块不受影响。
      expect(
        classifyMultiSignal(_spec(StationService.chat), apis, priv),
        AvailabilityState.available,
      );
    });

    test('通配键为 true 时 false 不再算拒绝 → 回到信号 2 判定', () {
      final apis = fullNasSnapshot.apiNames;
      final priv = _priv(const {
        kAppPrivilegeAllowAllKey: true,
        'SYNO.Foto.AppInstance': false,
      }, allowAll: true);
      expect(
        classifyMultiSignal(_spec(StationService.photo), apis, priv),
        AvailabilityState.available,
      );
    });

    test('chat 两信号矛盾（API 全无 + 权限 true）→ uncertain 且主 tab 保留', () {
      final apis = fullNasSnapshot.apiNames.difference(
        _apis(StationService.chat),
      );
      final priv = _priv(const {'SYNO.SDS.Chat.Application': true});
      final state = classifyMultiSignal(_spec(StationService.chat), apis, priv);
      expect(state, AvailabilityState.uncertain);
      expect(hidesModule(state), isFalse);

      // 可见性：uncertain 既不被隐藏，也不会被当成"顶替者"（顶替要求 available）。
      final tabs = visibleTabs({
        ...fullNasSnapshot.states(),
        StationService.chat: state,
      });
      expect(tabs, [
        AppTab.chat,
        AppTab.files,
        AppTab.photos,
        AppTab.workspace,
        AppTab.me,
      ]);
    });

    test('ai：requiredApis 为空 → 永不 absent / unauthorized（含权限 false）', () {
      final ai = _spec(StationService.ai);
      expect(
        classifyMultiSignal(ai, const {}, null),
        AvailabilityState.partial,
      );
      expect(
        classifyMultiSignal(ai, const {}, _priv(const {})),
        AvailabilityState.partial,
      );
      expect(
        classifyMultiSignal(
          ai,
          const {},
          _priv(const {kAppPrivilegeAllowAllKey: false}),
        ),
        AvailabilityState.partial,
      );
    });
  });

  group('信号 3（错误码）语义一字不改', () {
    test('102 → absent（仅必需位；可选位由 reportApiError 归 partial）', () {
      expect(classifyErrorCode(kApiNotFoundCode), AvailabilityState.absent);
      expect(hidesModule(AvailabilityState.absent), isTrue);
    });

    test('105 / 160 → unauthorized（隐藏该入口）', () {
      expect(
        classifyErrorCode(kNoPermissionCode),
        AvailabilityState.unauthorized,
      );
      expect(
        classifyErrorCode(kNoAppPrivilegeCode),
        AvailabilityState.unauthorized,
      );
      expect(hidesModule(AvailabilityState.unauthorized), isTrue);
    });

    test('119 / 106 → sessionExpired，**绝不隐藏**', () {
      expect(
        classifyErrorCode(kSidNotFoundCode),
        AvailabilityState.sessionExpired,
      );
      expect(
        classifyErrorCode(kSessionTimeoutCode),
        AvailabilityState.sessionExpired,
      );
      expect(hidesModule(AvailabilityState.sessionExpired), isFalse);
      expect(
        visibleTabs({
          ...fullNasSnapshot.states(),
          StationService.chat: AvailabilityState.sessionExpired,
        }),
        [AppTab.chat, AppTab.files, AppTab.photos, AppTab.workspace, AppTab.me],
      );
    });

    test('未知码 → unknown，不隐藏（fail-open）', () {
      expect(classifyErrorCode(100), AvailabilityState.unknown);
      expect(classifyErrorCode(0), AvailabilityState.unknown);
      expect(hidesModule(AvailabilityState.unknown), isFalse);
      expect(hidesModule(AvailabilityState.uncertain), isFalse);
      expect(hidesModule(AvailabilityState.unreachable), isFalse);
    });
  });
}
