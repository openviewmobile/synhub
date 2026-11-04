// ★★★ **DS finder 管理接口（第一批）** —— 全部按官方 APK 的实证契约实现。
//
// 用户 2026-09-23 新规：
// * 管理员功能必须实现，且按身份门控（非管理员隐藏、管理员展示）；
// * 涉及管理员的接口**一律走 Mock Server 验证，必须通过**。
//
// ## 为什么先做 BeepControl
// 它是 DS finder 的**招牌功能**（"让 NAS 响一声，好找到它在哪"），
// 而且官方**只用两个只读/无害方法**（`get` / `stop_beep`），
// 不碰 §5.1 的变更动词黑名单里的 `set` —— 实现风险最低、价值最高。
//
// ## 契约来源（全是本机可复核的硬证据）
// `Android-DSfinder.2.5.7-484.ww.apk` 反编译后的
// `smali_classes3/com/synology/assistant/data/remote/api/ApiBeepControl.smali`：
//
// ```
// API              = "SYNO.Core.Hardware.BeepControl"
// METHOD_GET       = "get"
// METHOD_STOP_BEEP = "stop_beep"
// VERSION          = 1
// BEEP_REASON      = "beep_reason"
// ```
//
// ⚠️ **一处诚实的空白**：官方 `get` 的**响应字段名**没有在 smali 里直接暴露
// （那个 VO 用的是通用 map，没有具名字段）。所以下面的 `BeepStatus`
// 解析**只采信我们能在 `.lib`/官方 JS 里对上的字段**，其余留空，
// 并且在字段缺失时回 `null`（**不知道**），而不是猜一个 false。
import '../core/net/traffic_meter.dart';
import 'package:synhub/src/dsm/webapi.dart';

/// `SYNO.Core.Hardware.BeepControl`
const String kBeepControlApi = 'SYNO.Core.Hardware.BeepControl';

/// 官方只声明了 v1（`ApiBeepControl.smali` 的 `VERSION = 0x1`）。
const int kBeepControlVersion = 1;

/// `stop_beep` 的 `beep_reason` 取值 —— 逐个抄自
/// `ApiBeepControl.smali` 的 `BEEP_REASON_*` 常量。
///
/// ★ 用枚举而不是裸字符串：官方这 12 个值是**闭集**，
/// 拼错一个字符串在 Mock 上不会报错（Mock 只校验 api/method/version），
/// 到了真机才会静默无效。
enum BeepReason {
  powerOn('reason_power_on'),
  powerOff('reason_power_off'),
  fanFail('reason_fan_fail'),
  enclosureFanFail('reason_enclosure_fan_fail'),
  eunitFanFail('reason_eunit_fan_fail'),
  redundantPowerFail('reason_redundant_power_fail'),
  resetButton('reason_reset_button'),
  volumeCrash('reason_volume_crash'),
  volumeOrCacheCrash('reason_volume_or_cache_crash'),
  ssdCacheCrash('reason_ssd_cache_crash'),
  sasLinkFail('reason_sas_link_fail');

  const BeepReason(this.wire);

  /// 发给服务端的原始值
  final String wire;
}

/// `BeepControl:get` 的解析结果。
class BeepStatus {
  const BeepStatus({this.beeping});

  /// 当前是否正在蜂鸣。
  /// `null` = **不知道**（服务端没给这个字段）——
  /// 不要用 `false` 冒充"没在响"，那会让界面显示错误的结论。
  final bool? beeping;

  /// 从响应里解析。**只认布尔**，类型不对不算。
  factory BeepStatus.fromJson(Map<String, dynamic> json) {
    final raw = json['beep_status'] ?? json['is_beeping'] ?? json['beeping'];
    return BeepStatus(beeping: raw is bool ? raw : null);
  }
}

/// DS finder 的管理接口客户端。
///
/// ⚠️ 所有这些接口在 `.lib` 里都是 `adminOnly: true`
/// ⇒ 普通用户调用会拿到 `105`。界面**必须**先过 `AdminOnly` 门控，
/// 但服务端仍可能回 `105`（权限刚被改），所以调用方要能处理它。
class SystemAdminApi {
  SystemAdminApi(DsmWebApi api, {this.discover})
    : api = api.withModule(TrafficModules.admin);

  final DsmWebApi api;

  /// 版本协商器（`SYNO.API.Info` 的能力表）。
  /// 传 null 时直接用官方声明的版本 —— **只在测试里这么用**。
  final int Function(String apiName, List<int> candidates)? discover;

  int _v(String name, int fallback) =>
      discover?.call(name, [fallback]) ?? fallback;

  /// `get` —— 查询蜂鸣状态。**只读**。
  Future<BeepStatus> beepStatus() async {
    final data = await api.call(
      kBeepControlApi,
      'get',
      preferredVersion: _v(kBeepControlApi, kBeepControlVersion),
      params: const {},
    );
    return BeepStatus.fromJson(data);
  }

  /// `SYNO.Core.System:info` —— 系统信息（只读）。
  ///
  /// ★ **版本用官方的 v1**（`ApiCoreSystem.VERSION = 0x1`），
  /// 不沿用身份探测里的 v3。理由：探测用 v3 是**我们自己**为了
  /// "结构上不可能误发 shutdown"而做的选择；而这里是**对齐官方的功能**，
  /// 版本不同返回字段可能不同 ⇒ 以官方为准。
  ///
  /// ⚠️ v1 的方法表里**混有** `shutdown`/`reboot`/`reset`（§5.1 黑名单）
  /// ⇒ 调用方只能发 `info`。用例断言了调用集合 == `{info}`。
  Future<SystemInfo> systemInfo({String? type}) async {
    final data = await api.call(
      'SYNO.Core.System',
      'info',
      preferredVersion: _v('SYNO.Core.System', 1),
      params: {if (type != null) 'type': type},
    );
    return SystemInfo.fromJson(data);
  }

  /// `SYNO.Core.Service:get` —— 服务/守护进程状态（只读）。
  ///
  /// ★★★ **一处必须点明的版本陷阱**：
  /// 官方 `ApiCoreService.smali` 写着 `VERSION = 0x1`，但那个常量是给
  /// **`control`**（启停服务）用的。而 `.lib` 里
  /// **`SYNO.Core.Service` 的 v1 只有 `control`，`get` 从 v2 才有**
  /// ⇒ 如果照抄官方的 `VERSION=1` 去调 `get`，会直接拿到 **`103`（方法不存在）**。
  ///
  /// 所以这里用 **v2**：先满足"方法存在"，再谈版本。
  /// 这条正是本项目反复强调的「`103` = 方法不存在，不许靠猜」。
  ///
  /// ⚠️ 官方 `control`（启停服务）**本仓不实现** —— 它语义上就是变更操作。
  Future<Map<String, dynamic>> serviceStatus() async {
    return api.call(
      'SYNO.Core.Service',
      'get',
      // v2：v1 没有 `get`（见上面的说明）
      preferredVersion: _v('SYNO.Core.Service', 2),
      params: const {},
    );
  }

  /// `SYNO.Core.Package:list` —— 已安装套件列表（只读）。
  ///
  /// 官方 `ApiCorePackage.smali`：`API = "SYNO.Core.Package"`、
  /// `GET = "get"`、`STATUS = "status"`（`status` 是**取值**不是方法名）、
  /// `VERSION_1 = 0x1`。
  /// `.lib` 里 v1 同时有 `list` 和 `get` ⇒ 两个都可用。
  Future<List<Map<String, dynamic>>> packageList() async {
    final data = await api.call(
      'SYNO.Core.Package',
      'list',
      preferredVersion: _v('SYNO.Core.Package', 1),
      params: const {},
    );
    final raw = data['packages'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  /// `SYNO.Core.Package:get` —— 单个套件详情（只读）。
  Future<Map<String, dynamic>> packageGet(String packageId) async {
    return api.call(
      'SYNO.Core.Package',
      'get',
      preferredVersion: _v('SYNO.Core.Package', 1),
      params: {'id': packageId},
    );
  }

  // ────────────────────────────────────────────────────────────────
  // 第四批（第 81 轮）：一批**只读**的 adminOnly 接口
  //
  // ★ 选它们的纪律（本轮才明确下来）：
  //   ① 必须在 `tool/mock_dsm/catalog.json` 里**有可信的方法表**
  //      —— 没有方法表就没法验证方法存在，Mock 也会判 103，
  //      那样的"实现"只是猜；
  //   ② 只取**只读**方法（`get`/`status` 一类）；
  //   ③ 官方 smali 里有对应常量（对得上官方行为）。
  //
  // ⚠️ 因此**存储类接口本轮没做**：`SYNO.Storage.CGI.Storage` /
  //    `SYNO.Core.Storage.Volume` / `CGI.HddMan` / `CGI.Smart` 在目录里
  //    都是 `methods: {}`（**SPK 里没抽到方法表**）⇒ 无法验证方法是否存在。
  //    详见 `docs/admin-parity-requirement.md` §20。
  // ────────────────────────────────────────────────────────────────

  /// 通用只读调用：`{api}:{method}`，返回 `data`。
  Future<Map<String, dynamic>> _read(
    String apiName,
    String method, {
    int version = 1,
    Map<String, dynamic> params = const {},
  }) {
    return api.call(
      apiName,
      method,
      preferredVersion: _v(apiName, version),
      params: params,
    );
  }

  // ── 第八批（第 93 轮）：通知偏好（官方 chat APK 的 @Field 实证）──
  //
  // ★ 事实来源：`SynologyChat 2.11.1-607` smali
  //   `com/synology/sylib/syapi/webapi/request/ApiPersonalNotificationSetting.smali`
  //   的 `.field` 常量（**最硬的一级来源**）。

  /// `SYNO.Personal.Notification.Settings:get` —— 通知偏好。
  ///
  /// ★ **[package] 必须由调用方显式给出**：官方 smali 里有
  /// `PARAM_KEY__PACKAGE = "package"`，且真机上不带参数调 `get` 回
  /// **`114`（缺必需参数）** ⇒ 强烈指向 `package` 是必需项。
  /// **但我没有"该传什么值"的证据**，所以**不设默认值、不猜** ——
  /// 传什么由调用方决定。
  Future<Map<String, dynamic>> notificationSettingsGet({
    required String package,
  }) => _read(
    'SYNO.Personal.Notification.Settings',
    'get',
    params: {'package': package},
  );

  /// `SYNO.Personal.Notification.Token:get` —— 本账号的通知令牌（只读）。
  ///
  /// ⚠️ 用户明确**不做 FCM** ⇒ 项目**不注册**推送令牌；
  /// 但**读取**是只读且官方有此方法，故提供能力，不在启动时自动调用。
  Future<Map<String, dynamic>> notificationTokenGet({
    required String package,
  }) => _read(
    'SYNO.Personal.Notification.Token',
    'get',
    params: {'package': package},
  );

  // ── 第七批（第 89 轮）：用**新解开的 DSM 核心方法表**实现 ──
  //
  // ★ 方法名与权限来自 `DSM_DS1019+_72806.pat` 里解出的
  //   `QuickConnect` / `SecureSignIn` / `StorageManager` SPK 的 `webapi/*.lib`
  //   （见 `docs/admin-parity-requirement.md` §26）。
  //   在此之前这些 API 归在「无法验证」——**不是不能做，是缺第二来源**。

  /// `SYNO.Core.QuickConnect:get` —— QuickConnect 配置（**普通用户可读**）。
  ///
  /// ★ 本项目的硬要求之一就是"必须支持 QuickConnect"。
  /// `.lib` 的 `allowUser` 含 `normal.*` ⇒ **普通用户也能读**。
  Future<Map<String, dynamic>> quickConnectGet() =>
      _read('SYNO.Core.QuickConnect', 'get');

  /// `SYNO.Core.QuickConnect:status` —— QC 连接状态（v1 有，**只读**）。
  Future<Map<String, dynamic>> quickConnectStatus() =>
      _read('SYNO.Core.QuickConnect', 'status');

  /// `SYNO.Core.QuickConnect:get_server_alias` —— QC 别名（v3）。
  ///
  /// ★ 陷阱提醒：`get_server_alias` **只在 v3**（v1/v2 没有）⇒ 必须发 3，
  /// 否则 103。这正是第 85 轮那条**通用版本守卫**要防的。
  Future<Map<String, dynamic>> quickConnectGetServerAlias() =>
      _read('SYNO.Core.QuickConnect', 'get_server_alias', version: 3);

  /// `SYNO.SecureSignIn.Authenticator:list` —— 两步验证器列表（**只读**）。
  ///
  /// ⚠️ 同 API 的 `revoke`/`revokeAll`/`update` 是**变更操作** ⇒ 不实现。
  Future<List<Map<String, dynamic>>> authenticatorList() async => _listOf(
    await _read('SYNO.SecureSignIn.Authenticator', 'list'),
    'authenticators',
  );

  /// `SYNO.Storage.CGI.HddMan:get` —— 硬盘管理信息（adminOnly，只读）。
  Future<Map<String, dynamic>> hddManGet() =>
      _read('SYNO.Storage.CGI.HddMan', 'get');

  /// `SYNO.Core.Storage.Volume:get` —— 单个存储空间详情（adminOnly，只读）。
  Future<Map<String, dynamic>> volumeGet(String id) =>
      _read('SYNO.Core.Storage.Volume', 'get', params: {'id': id});

  /// `SYNO.Storage.CGI.Smart:get_smart_info` —— S.M.A.R.T. 详情（只读）。
  ///
  /// ⚠️ 同 API 的 `secure_erase` / `update_smartctl_db` / `smart_warning_set`
  /// 是**变更操作** ⇒ 不实现。
  Future<Map<String, dynamic>> smartInfo({String? disk}) => _read(
    'SYNO.Storage.CGI.Smart',
    'get_smart_info',
    params: {if (disk != null) 'disk': disk},
  );

  /// `SYNO.Storage.CGI.Storage:load_bad_disks` —— 异常磁盘（只读）。
  Future<Map<String, dynamic>> storageLoadBadDisks() =>
      _read('SYNO.Storage.CGI.Storage', 'load_bad_disks');

  /// `SYNO.Storage.CGI.Storage:get_resync_speed` —— 重建速度（只读）。
  Future<Map<String, dynamic>> storageResyncSpeed() =>
      _read('SYNO.Storage.CGI.Storage', 'get_resync_speed');

  // ── 第六批（第 86 轮）：收尾剩余只读方法 ──

  /// `SYNO.Core.QuickStart.Info:load_ds_info` —— 向导里的 NAS 信息（只读）。
  Future<Map<String, dynamic>> quickStartLoadDsInfo() =>
      _read('SYNO.Core.QuickStart.Info', 'load_ds_info');

  /// `SYNO.Core.QuickStart.Info:check_permission` —— 是否有权看向导（只读）。
  Future<Map<String, dynamic>> quickStartCheckPermission() =>
      _read('SYNO.Core.QuickStart.Info', 'check_permission');

  /// `SYNO.Core.QuickStart.Install:check_progress` —— 安装进度（只读）。
  ///
  /// ⚠️ `QuickStart.Install` 的 `install_pkgs` / `install_sur`
  /// 是**变更操作** ⇒ 本仓不实现，只读 `check_progress`。
  Future<Map<String, dynamic>> quickStartInstallProgress() =>
      _read('SYNO.Core.QuickStart.Install', 'check_progress');

  /// `SYNO.Core.Upgrade.Server:check` —— 检查升级服务器（只读）。
  Future<Map<String, dynamic>> upgradeServerCheck() =>
      _read('SYNO.Core.Upgrade.Server', 'check');

  /// `SYNO.API.Auth.RedirectURI:check` —— 校验重定向 URI（只读）。
  Future<Map<String, dynamic>> authRedirectUriCheck() =>
      _read('SYNO.API.Auth.RedirectURI', 'check');

  // ── 第五批（第 85 轮）：账号 / 群组 / 权限 / 策略，全部**只读** ──

  /// `SYNO.Core.User:list` —— 用户列表（adminOnly）。
  Future<List<Map<String, dynamic>>> userList() async =>
      _listOf(await _read('SYNO.Core.User', 'list'), 'users');

  /// `SYNO.Core.User:get` —— 单个用户详情（adminOnly）。
  Future<Map<String, dynamic>> userGet(String name) =>
      _read('SYNO.Core.User', 'get', params: {'name': name});

  /// `SYNO.Core.Group:list` —— 群组列表（adminOnly）。
  Future<List<Map<String, dynamic>>> groupList() async =>
      _listOf(await _read('SYNO.Core.Group', 'list'), 'groups');

  /// `SYNO.Core.Group.Member:list` —— 群组成员（adminOnly）。
  Future<List<Map<String, dynamic>>> groupMemberList() async =>
      _listOf(await _read('SYNO.Core.Group.Member', 'list'), 'users');

  /// `SYNO.Core.AppPriv.Rule:list` —— 应用权限规则（adminOnly）。
  Future<List<Map<String, dynamic>>> appPrivRuleList() async =>
      _listOf(await _read('SYNO.Core.AppPriv.Rule', 'list'), 'rules');

  /// `SYNO.Core.User.PasswordPolicy:get` —— 密码策略（adminOnly）。
  Future<Map<String, dynamic>> passwordPolicyGet() =>
      _read('SYNO.Core.User.PasswordPolicy', 'get');

  /// `SYNO.Core.Package.Server:list` —— 套件来源（adminOnly）。
  Future<List<Map<String, dynamic>>> packageServerList() async =>
      _listOf(await _read('SYNO.Core.Package.Server', 'list'), 'servers');

  /// `SYNO.Core.Desktop.Timeout:get` —— 会话超时（**普通用户可读**）。
  Future<Map<String, dynamic>> desktopTimeoutGet() =>
      _read('SYNO.Core.Desktop.Timeout', 'get');

  /// `SYNO.Auth.RescueEmail:get` —— 救援邮箱（**普通用户可读**）。
  Future<Map<String, dynamic>> rescueEmailGet() =>
      _read('SYNO.Auth.RescueEmail', 'get');

  /// `SYNO.Core.DataCollect:get` —— 数据收集设置（adminOnly）。
  Future<Map<String, dynamic>> dataCollectGet() =>
      _read('SYNO.Core.DataCollect', 'get');

  /// `SYNO.Core.MyDSCenter:query` —— MyDS Center 绑定信息（adminOnly）。
  ///
  /// ★★★ **版本陷阱（第 2 次出现，与 §19.1 的 `Service:get` 同类）**：
  /// `.lib` 里 `SYNO.Core.MyDSCenter` 的 **v1 只有 `register`**，
  /// `query` 在 **v2**。用默认 v1 调会拿 **`103`**。
  ///
  /// 这是被测试**抓出来**的（BC11 首跑就报
  /// `DsmApiException(方法不存在 @ SYNO.Core.MyDSCenter.query, code=103)`），
  /// 不是靠读表预防的 —— 所以把检查项固化下来，见 §24.2。
  Future<Map<String, dynamic>> myDsCenterQuery() =>
      _read('SYNO.Core.MyDSCenter', 'query', version: 2);

  /// 从响应里取列表字段：**类型不对就返回空列表**，不崩、不猜。
  List<Map<String, dynamic>> _listOf(Map<String, dynamic> data, String key) {
    final raw = data[key];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  /// `SYNO.Storage.CGI.Storage:load_info` —— 存储总览（**只读**）。
  ///
  /// ★★★ 方法名的来源（第 82 轮解锁 §20 记的那条覆盖边界）：
  /// `.lib` 里这个 API 的 `methods` 是**空的**（`methodsVerified: false`），
  /// 本地也没有 DSM 核心的 `.lib`。但官方 **DS finder 的服务端 UI**
  /// 留下了第二来源：
  /// `ex_AI_pat/usr/syno/synoman/mobile/ui/mobile.js` 里明确写着
  /// `api:"SYNO.Storage.CGI.Storage"` + `method:"load_info"`。
  /// ⇒ 方法存在**可验证**了，本仓据此实现并把方法表**带回** Mock 目录
  /// （`methodsVerified: true`，`source: "mobile.js"`）。
  Future<Map<String, dynamic>> storageLoadInfo() =>
      _read('SYNO.Storage.CGI.Storage', 'load_info');

  /// `SYNO.Storage.CGI.Smart:get_health_info` —— 磁盘健康（**只读**）。
  /// 来源同 [storageLoadInfo]（`mobile.js` 的 `get_health_info`）。
  Future<Map<String, dynamic>> storageSmartHealth() =>
      _read('SYNO.Storage.CGI.Smart', 'get_health_info');

  /// `SYNO.Core.Storage.Volume:list` —— 存储空间列表（**只读**）。
  /// 官方契约：`ApiCoreStorageVolume.LIST = "list"`；`mobile.js` 亦印证。
  Future<List<Map<String, dynamic>>> storageVolumeList() async {
    final data = await _read('SYNO.Core.Storage.Volume', 'list');
    final raw = data['volumes'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  /// `SYNO.Core.Network:get`（官方 `ApiCoreNetwork`，v1）
  Future<Map<String, dynamic>> networkGet() =>
      _read('SYNO.Core.Network', 'get');

  /// `SYNO.Core.Upgrade:status`（官方 `ApiCoreUpgrade.METHOD_STATUS`，v1）
  Future<Map<String, dynamic>> upgradeStatus() =>
      _read('SYNO.Core.Upgrade', 'status');

  /// `SYNO.Core.Upgrade:basic_status`（`.lib` v1 有）
  Future<Map<String, dynamic>> upgradeBasicStatus() =>
      _read('SYNO.Core.Upgrade', 'basic_status');

  /// `SYNO.Core.Upgrade.Setting:get`（官方键名见 `ApiCoreUpgradeSetting`）
  Future<Map<String, dynamic>> upgradeSettingGet() =>
      _read('SYNO.Core.Upgrade.Setting', 'get');

  /// `SYNO.Core.Security.AutoBlock:get`（官方 `ApiCoreSecurityAutoBlock.GET`）
  Future<Map<String, dynamic>> autoBlockGet() =>
      _read('SYNO.Core.Security.AutoBlock', 'get');

  /// `SYNO.Core.Theme.Desktop:get`
  Future<Map<String, dynamic>> themeDesktopGet() =>
      _read('SYNO.Core.Theme.Desktop', 'get');

  /// `SYNO.Core.User.Home:get`（官方 `ApiCoreUserHome.GET`）
  Future<Map<String, dynamic>> userHomeGet() =>
      _read('SYNO.Core.User.Home', 'get');

  /// `SYNO.Core.Region.NTP:get`
  Future<Map<String, dynamic>> ntpGet() => _read('SYNO.Core.Region.NTP', 'get');

  /// `SYNO.Core.Region.NTP:status`（`.lib` v1 有）
  Future<Map<String, dynamic>> ntpStatus() =>
      _read('SYNO.Core.Region.NTP', 'status');

  /// `SYNO.Core.Region.Language:get`
  Future<Map<String, dynamic>> languageGet() =>
      _read('SYNO.Core.Region.Language', 'get');

  /// `SYNO.DSM.FindMe:supported` —— 这台 NAS 支不支持 FindMe。**只读**。
  ///
  /// ⚠️ 官方还有 `start`/`stop`（§5.1 变更动词），本仓**不实现**。
  Future<bool?> findMeSupported() async {
    final data = await api.call(
      kFindMeApi,
      'supported',
      preferredVersion: _v(kFindMeApi, kFindMeVersion),
      params: const {},
    );
    final raw = data['supported'] ?? data['is_supported'];
    return raw is bool ? raw : null;
  }

  /// `stop_beep` —— 让 NAS 停止蜂鸣。**官方就这两个方法，没有 `set`**。
  ///
  /// ⚠️ `stop_beep` 不是 §5.1 黑名单词（黑名单里有 `stop`，但没有
  /// `stop_beep`）—— 它停的是**蜂鸣**，不是服务/任务。
  /// 即便如此，本仓对它仍然按"会影响设备"对待：
  /// 报告里单独声明，且**不在探针里调用**。
  Future<void> stopBeep({BeepReason? reason}) async {
    await api.call(
      kBeepControlApi,
      'stop_beep',
      preferredVersion: _v(kBeepControlApi, kBeepControlVersion),
      params: {if (reason != null) 'beep_reason': reason.wire},
    );
  }
}

/// `SYNO.DSM.FindMe` —— DS finder **独有**的"寻找我的 NAS"接口。
///
/// 官方契约（`ApiFindMe.smali`）：
/// ```
/// API     = "SYNO.DSM.FindMe"
/// METHOD_SUPPORTED = "supported"
/// METHOD_START     = "start"
/// METHOD_STOP      = "stop"
/// VERSION = 2
/// ```
///
/// ⚠️ `start` / `stop` 是 §5.1 **变更动词黑名单**成员
/// ⇒ 本仓**只实现 `supported`**（只读），不实现启停。
/// 这不是偷懒：启停要等有真机授权、且能单独声明影响面时再做。
const String kFindMeApi = 'SYNO.DSM.FindMe';

/// 官方 `ApiFindMe.VERSION = 0x2`
const int kFindMeVersion = 2;

/// `SYNO.Core.System:info` 的解析结果。
///
/// 字段名逐个来自官方 `StatusVo$DiskSysInfoVo.smali` 的 `.field`：
/// `model` / `version` / `build_num` / `admin_port`。
///
/// ★ 全部可空：**拿不到就是"不知道"**，不用占位值冒充。
class SystemInfo {
  const SystemInfo({this.model, this.version, this.buildNum, this.adminPort});

  final String? model;
  final String? version;
  final int? buildNum;
  final int? adminPort;

  factory SystemInfo.fromJson(Map<String, dynamic> json) => SystemInfo(
    model: json['model'] is String ? json['model'] as String : null,
    version: json['version'] is String ? json['version'] as String : null,
    buildNum: json['build_num'] is int ? json['build_num'] as int : null,
    adminPort: json['admin_port'] is int ? json['admin_port'] as int : null,
  );
}
