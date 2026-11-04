// r433：**`AppPrivilege` 画像**的守卫 —— "某模块权限键 `false` ⇒ 模块隐藏"。
//
// ## 为什么加这一条
// `docs/launch-readiness.md` §4 与 `docs/android-remaining-todo-r418.md` §一-4
// 一直挂着一条"需要用户在 DSM 里改权限"的项：
//
//   > 「无权限 ⇒ 模块隐藏」（`AppPrivilege` 某模块 `false` ⇒ 该模块隐藏）
//   >   卡在哪：本机账号 `demo_user` 的 22 个 app 全 `true`，无此场景。
//
// r433 换了**授权内**的一条腿：本机 **Mock Server** 也是我们自己的探针
// （`network_security_config.xml` 早为 `adb reverse` 留了 `127.0.0.1` 明文例外），
// 让它按**真机形状的键表**回画像 ⇒ 在真机上就能造出"`false`"与"键不存在"两态。
//
// 本文件钉死两件事：
//   ① Mock 的画像**编码正确**（`true` / `false` / 键缺席 / 通配键四种形状）；
//   ② 这条画像喂进**生产判定**（`classifyMultiSignal` + `hidesModule` +
//      `visibleTabs`）后，确实只有"显式 `false`"会把模块藏掉。
//
// ★ 反向验证：把 `MockDsmBackend.appPrivilegePayload()` 里的
// `k: !appPrivilegeDenied.contains(k)` 改成 `k: true`（即漏掉拒绝态）⇒
// MP2 的"隐身"判据必须变红。**改不动就说明这条用例是假绿**。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/entitlement/session_entitlement.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/features/shell/app_tab.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';

/// 真机形状键表（与 `tool/mock_dsm/mock_dsm_server.dart` 的常量同源；
/// 工具层不能 import `test/`，这里再抄一份用于断言）。
const List<String> _kRealKeys = <String>[
  'SYNO.AFP',
  'SYNO.Cal.Application',
  'SYNO.Contacts.AppInstance',
  'SYNO.Desktop',
  'SYNO.FTP',
  'SYNO.Foto.AppInstance',
  'SYNO.Rsync',
  'SYNO.SDS.App.FileStation3.Instance',
  'SYNO.SDS.BackupService.Instance',
  'SYNO.SDS.Chat.Application',
  'SYNO.SDS.DocumentViewer.Application',
  'SYNO.SDS.Drive.Application',
  'SYNO.SDS.MailClient.Application',
  'SYNO.SDS.MailPlusServer.Instance',
  'SYNO.SDS.MailServer.Instance',
  'SYNO.SDS.NoteStation.Application',
  'SYNO.SDS.SMBService.AppPrivilege.Instance',
  'SYNO.SDS.SynologyFileManager.Privilege.Extension',
  'SYNO.SDS.WebDAVServer.Instance',
  'SYNO.SFTP',
];

const String _kFilesPrivilegeKey = 'SYNO.SDS.App.FileStation3.Instance';

/// 一份"服务端装了 File Station / Chat / Photos"的 API 名表（信号 2）。
///
/// 真机与 Mock 都装了这个模块，所以**隐藏只可能由信号 1（权限）引起**
/// —— 这正是本轮要控制住的变量。
const Set<String> _kApiNames = <String>{
  'SYNO.FileStation.List', // required
  'SYNO.FileStation.Search', // 以下 9 条 = File Station 的 optionalApis 全给
  'SYNO.FileStation.Sharing',
  'SYNO.FileStation.Compress',
  'SYNO.FileStation.Extract',
  'SYNO.FileStation.Favorite',
  'SYNO.FileStation.BackgroundTask',
  'SYNO.FileStation.VirtualFolder',
  'SYNO.FileStation.Thumb',
  'SYNO.FileStation.Download',
  'SYNO.SDS.Chat.Channel',
  'SYNO.Foto.Browse.Item',
};

MockDsmBackend _backend({
  List<String>? keys,
  Set<String> denied = const <String>{},
  Set<String> omitted = const <String>{},
  bool allowAll = false,
}) => MockDsmBackend(
  catalog: DsmCatalog.load(),
  synthesizeSessionIdentity: true,
  appPrivilegeProfileKeys: keys,
  appPrivilegeDenied: denied,
  appPrivilegeOmitted: omitted,
  appPrivilegeAllowAll: allowAll,
);

/// 走 Mock 的**同一条** `handle()` 路径取 `Initdata:get` 的回包（不是直接调工具方法）。
MockDsmResponse _initdata(MockDsmBackend b) {
  final sid = b.login(username: 'mockuser', admin: false);
  return b.handle('/webapi/entry.cgi', {
    'api': 'SYNO.Core.Desktop.Initdata',
    'method': 'get',
    'version': '1',
    '_sid': sid,
  });
}

Map<String, dynamic> _privilegeOf(MockDsmBackend b) {
  final data = _initdata(b).json['data'] as Map;
  return Map<String, dynamic>.from(data['AppPrivilege'] as Map);
}

void main() {
  group('MP1. Mock 的 `AppPrivilege` 画像编码（r433 仪器）', () {
    test('默认（不传键表）⇒ 只回通配键，r295 起的旧行为**一字不改**', () {
      final payload = _privilegeOf(_backend());
      expect(payload, {'SYNO.ALLOW.ALL.APPLICATIONS': true});
    });

    test('键表模式 ⇒ 逐键 `true`，被拒的键**存在且为 `false`**，且默认不带通配键', () {
      final payload = _privilegeOf(
        _backend(keys: _kRealKeys, denied: {_kFilesPrivilegeKey}),
      );
      // 规模先行（防"键表悄悄变空还照样过"）
      expect(_kRealKeys.length, 20);
      expect(payload.length, 20);
      expect(payload[_kFilesPrivilegeKey], isFalse);
      expect(payload['SYNO.SDS.Chat.Application'], isTrue);
      expect(payload.containsKey(kAppPrivilegeAllowAllKey), isFalse);
    });

    test('`--priv-omit` ⇒ 该键**完全不出现**（"键不存在"是第三态，不是 `false`）', () {
      final payload = _privilegeOf(
        _backend(keys: _kRealKeys, omitted: {_kFilesPrivilegeKey}),
      );
      expect(payload.containsKey(_kFilesPrivilegeKey), isFalse);
      expect(payload.length, 19);
    });

    test('`--priv-allow-all` ⇒ 通配键在场（用来证明"通配键能抵消 `false`"）', () {
      final payload = _privilegeOf(
        _backend(
          keys: _kRealKeys,
          denied: {_kFilesPrivilegeKey},
          allowAll: true,
        ),
      );
      expect(payload[kAppPrivilegeAllowAllKey], isTrue);
    });

    test('三态进 `SessionEntitlement`：`deniedApp` / `allowsApp` 分得开', () {
      final denied = SessionEntitlement.fromInitdata(
        _initdata(
          _backend(keys: _kRealKeys, denied: {_kFilesPrivilegeKey}),
        ).json['data'] as Map<String, dynamic>,
      );
      expect(denied.deniedApp([_kFilesPrivilegeKey]), isTrue);
      expect(denied.allowsApp([_kFilesPrivilegeKey]), isFalse);

      final omitted = SessionEntitlement.fromInitdata(
        _initdata(
          _backend(keys: _kRealKeys, omitted: {_kFilesPrivilegeKey}),
        ).json['data'] as Map<String, dynamic>,
      );
      // 键不存在 ⇒ 官方判"不放行"，但**不是**明确拒绝（三态的第二态）。
      expect(omitted.deniedApp([_kFilesPrivilegeKey]), isFalse);
      expect(omitted.allowsApp([_kFilesPrivilegeKey]), isFalse);

      final granted = SessionEntitlement.fromInitdata(
        _initdata(_backend(keys: _kRealKeys)).json['data']
            as Map<String, dynamic>,
      );
      expect(granted.deniedApp([_kFilesPrivilegeKey]), isFalse);
      expect(granted.allowsApp([_kFilesPrivilegeKey]), isTrue);
    });
  });

  group('MP2. 真机语义：只有**显式 `false`** 才把模块藏掉（走生产判定）', () {
    AvailabilityState stateOf(MockDsmBackend b) {
      final data =
          _initdata(b).json['data'] as Map<String, dynamic>;
      final ent = SessionEntitlement.fromInitdata(data);
      return classifyMultiSignal(
        kServiceRegistry[StationService.file]!,
        _kApiNames,
        ent.appPrivilege,
      );
    }

    test('键 `false` ⇒ `unauthorized` ⇒ `hidesModule` ⇒ 底栏**没有 `files`**', () {
      final state = stateOf(
        _backend(keys: _kRealKeys, denied: {_kFilesPrivilegeKey}),
      );
      expect(state, AvailabilityState.unauthorized);
      expect(hidesModule(state), isTrue);
      final tabs = visibleTabs({StationService.file: state}, showHidden: false);
      expect(tabs.contains(AppTab.files), isFalse);
      // 同时证明"隐藏后底栏仍可用"（不是空壳）：受限模式不在场。
      expect(tabs.contains(AppTab.home), isFalse);
    });

    test('键 `true`（同一份 API 表）⇒ `available` ⇒ 底栏有 `files`', () {
      final state = stateOf(_backend(keys: _kRealKeys));
      // 全给 required + optional ⇒ 信号 2 的结论是 available（不是 partial）
      expect(state, AvailabilityState.available);
      expect(hidesModule(state), isFalse);
      expect(
        visibleTabs({StationService.file: state}).contains(AppTab.files),
        isTrue,
      );
    });

    test('键**缺席**而 API 表在 ⇒ 仍 `available`（规则 2 说了算）'
        ' ⇒ 证明隐藏是"显式拒绝"引起的，不是"键缺失"', () {
      final state = stateOf(
        _backend(keys: _kRealKeys, omitted: {_kFilesPrivilegeKey}),
      );
      expect(state, AvailabilityState.available,
          reason: '规则 1 只在"明确拒绝"时短路；键缺席时由信号 2 说了算');
      expect(hidesModule(state), isFalse);
    });

    test('通配键 `true` ⇒ `false` 被抵消 ⇒ 不隐藏（官方语义，防过度隐藏）', () {
      final state = stateOf(
        _backend(
          keys: _kRealKeys,
          denied: {_kFilesPrivilegeKey},
          allowAll: true,
        ),
      );
      expect(state, isNot(AvailabilityState.unauthorized));
      expect(hidesModule(state), isFalse);
    });
  });
}
