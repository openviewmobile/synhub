// ★★★ **管理工具页**（用户 2026-09-23 新规 · 第 74 轮）
//
// 这是**第一个真实消费 `AdminOnly` 门控**的页面 —— 门控机制在第 73 轮
// 就已就位，但当时"还没有页面挂上去"，那等于没验证过端到端。
//
// ## 这一页放什么
// 只放**本仓已经实现对的服务端能力**，不放占位。
// 目前能真跑通的是 Active Insight（`SYNO.ActiveInsight.Package/get_status`，
// 在 `.lib` 里是 **adminOnly**）。
//
// ⚠️ 这也是 §9.4 那笔账的落点：旧计划把 Active Insight 排除，
// 理由是"6 个 API 的 `allowUser` 全是 `admin.*`，与**只做普通用户功能**冲突"
// —— 用户新规已作废该前提（管理员功能必须实现且按身份门控）。
// 本页就是"撤回排除、按门控实现"的第一步。
//
// ## 纪律
// * 非管理员**根本进不到这里**（入口被 `AdminOnly` 藏了；
//   即便走深链，`AdminPageGate` 也会拦住）；
// * 但**服务端仍可能回 `105`**（例如账号权限刚被改），
//   所以页内对 `105` 必须**如实说"需要管理员权限"**，不能白屏；
// * 只读：本页只调 `get_status`，**零变更动词**。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../data/system_admin_api.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'admin_gaps_text.dart';
import 'admin_gate.dart';

class AdminToolsPage extends ConsumerStatefulWidget {
  const AdminToolsPage({super.key});

  @override
  ConsumerState<AdminToolsPage> createState() => _AdminToolsPageState();
}

class _AdminToolsPageState extends ConsumerState<AdminToolsPage> {
  @override
  void initState() {
    super.initState();
    trackView(UsageModule.admin, screen: 'tools');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final api = ref.watch(authExtraApiProvider);
    return AdminPageGate(
      title: adminGap(AdminGapTextKeys.adminToolsTitle, '管理工具'),
      child: Scaffold(
        key: const Key('admin-tools-page'),
        appBar: AppBar(
          title: Text(adminGap(AdminGapTextKeys.adminToolsTitle, '管理工具')),
        ),
        body: ListView(
          children: [
            DesignRowTile(
              key: const Key('admin-tools-active-insight'),
              leading: const Icon(Icons.insights_outlined),
              title: Text(
                adminGap(AdminGapTextKeys.activeInsightTitle, 'Active Insight'),
              ),
              subtitle: api == null
                  ? Text(t.setNotConnected)
                  : const _ActiveInsightStatus(),
            ),
            // ★★★ DS finder 招牌功能：蜂鸣状态 + 停止蜂鸣（第 77 轮）。
            //
            // ⚠️ 官方 `ApiBeepControl` **只有 `get` 和 `stop_beep`** ——
            // 没有 `set`。所以 DS finder 的"蜂鸣"功能其实是
            // **读取报警状态 + 停止蜂鸣**，不是"让 NAS 响一声"。
            // 界面照此实现，不发明官方没有的入口。
            const Divider(height: 1),
            // 第三/四/五批（第 83 轮）：复用同一个通用磁贴
            _AdminAsyncTile(
              tileKey: 'admin-storage-tile',
              icon: Icons.storage_outlined,
              title: adminGap(AdminGapTextKeys.storageTitle, '存储'),
              load: (api) async {
                // ★ 第 84 轮：把 `load_info`（存储池）也接上，
                // 不再让这个 API 只停在 API 层（上轮登记的缺口二）。
                final info = await api.storageLoadInfo();
                final vols = await api.storageVolumeList();
                final pools = info['storagePools'];
                final poolN = pools is List ? pools.length : null;
                final volPart = vols.isEmpty
                    ? adminGap(AdminGapTextKeys.emptyList, '（空）')
                    : vols
                          .map((v) => '${v['id'] ?? '?'}:${v['status'] ?? '?'}')
                          .join(' · ');
                // 存储池数拿不到就**不显示**这一段，不写 "0 个池" 冒充
                return poolN == null
                    ? volPart
                    : adminGapFill(
                        AdminGapTextKeys.storagePoolsLine,
                        '$volPart（$poolN 个存储池）',
                        {'vol': volPart, 'n': '$poolN'},
                      );
              },
            ),
            const Divider(height: 1),
            // ★ 第七批：QuickConnect 是本项目硬要求支持的能力
            _AdminAsyncTile(
              tileKey: 'admin-qc-tile',
              icon: Icons.cloud_outlined,
              title: adminGap(AdminGapTextKeys.qcTitle, 'QuickConnect'),
              load: (api) async {
                final d = await api.quickConnectGet();
                final en = d['enabled'] ?? d['enable'];
                if (en is! bool) {
                  return adminGap(AdminGapTextKeys.sysInfoUnknown, '系统信息未知');
                }
                return en
                    ? adminGap(AdminGapTextKeys.adminEnabled, '已启用')
                    : adminGap(AdminGapTextKeys.adminDisabled, '未启用');
              },
            ),
            const Divider(height: 1),
            _AdminAsyncTile(
              tileKey: 'admin-2fa-tile',
              icon: Icons.security_outlined,
              title: adminGap(AdminGapTextKeys.auth2faTitle, '两步验证器'),
              load: (api) async {
                final l = await api.authenticatorList();
                return l.isEmpty
                    ? adminGap(AdminGapTextKeys.emptyList, '（空）')
                    : adminGapFill(
                        AdminGapTextKeys.authCount,
                        '共 ${l.length} 个验证器',
                        {'n': '${l.length}'},
                      );
              },
            ),
            const Divider(height: 1),
            _AdminAsyncTile(
              tileKey: 'admin-hdd-tile',
              icon: Icons.hardware_outlined,
              title: adminGap(AdminGapTextKeys.hddTitle, '硬盘管理'),
              load: (api) async {
                final d = await api.hddManGet();
                final disks = d['disks'];
                if (disks is! List || disks.isEmpty) {
                  return adminGap(AdminGapTextKeys.emptyList, '（空）');
                }
                return adminGapFill(
                  AdminGapTextKeys.hddCount,
                  '共 ${disks.length} 块',
                  {'n': '${disks.length}'},
                );
              },
            ),
            const Divider(height: 1),
            _AdminAsyncTile(
              tileKey: 'admin-user-tile',
              icon: Icons.people_alt_outlined,
              title: adminGap(AdminGapTextKeys.userTitle, '用户'),
              load: (api) async {
                final us = await api.userList();
                return us.isEmpty
                    ? adminGap(AdminGapTextKeys.emptyList, '（空）')
                    : adminGapFill(
                        AdminGapTextKeys.userCount,
                        '共 ${us.length} 个用户',
                        {'n': '${us.length}'},
                      );
              },
            ),
            const Divider(height: 1),
            _AdminAsyncTile(
              tileKey: 'admin-group-tile',
              icon: Icons.groups_outlined,
              title: adminGap(AdminGapTextKeys.groupTitle, '群组'),
              load: (api) async {
                final gs = await api.groupList();
                return gs.isEmpty
                    ? adminGap(AdminGapTextKeys.emptyList, '（空）')
                    : adminGapFill(
                        AdminGapTextKeys.groupCount,
                        '共 ${gs.length} 个群组',
                        {'n': '${gs.length}'},
                      );
              },
            ),
            const Divider(height: 1),
            _AdminAsyncTile(
              tileKey: 'admin-apppriv-tile',
              icon: Icons.rule_outlined,
              title: adminGap(AdminGapTextKeys.appPrivTitle, '应用权限'),
              load: (api) async {
                final rs = await api.appPrivRuleList();
                return rs.isEmpty
                    ? adminGap(AdminGapTextKeys.emptyList, '（空）')
                    : adminGapFill(
                        AdminGapTextKeys.appPrivCount,
                        '共 ${rs.length} 条规则',
                        {'n': '${rs.length}'},
                      );
              },
            ),
            const Divider(height: 1),
            _AdminAsyncTile(
              tileKey: 'admin-pwdpolicy-tile',
              icon: Icons.password_outlined,
              title: adminGap(AdminGapTextKeys.pwdPolicyTitle, '密码策略'),
              load: (api) async {
                final d = await api.passwordPolicyGet();
                final en = d['enable'] ?? d['enabled'];
                if (en is! bool) {
                  return adminGap(AdminGapTextKeys.sysInfoUnknown, '系统信息未知');
                }
                return en
                    ? adminGap(AdminGapTextKeys.adminEnabled, '已启用')
                    : adminGap(AdminGapTextKeys.adminDisabled, '未启用');
              },
            ),
            const Divider(height: 1),
            _AdminAsyncTile(
              tileKey: 'admin-diskhealth-tile',
              icon: Icons.health_and_safety_outlined,
              title: adminGap(AdminGapTextKeys.diskHealthTitle, '磁盘健康'),
              load: (api) async {
                final d = await api.storageSmartHealth();
                final disks = d['disks'];
                if (disks is! List || disks.isEmpty) {
                  return adminGap(AdminGapTextKeys.emptyList, '（空）');
                }
                return adminGapFill(
                  AdminGapTextKeys.diskCount,
                  '共 ${disks.length} 块磁盘',
                  {'n': '${disks.length}'},
                );
              },
            ),
            const Divider(height: 1),
            _AdminAsyncTile(
              tileKey: 'admin-package-tile',
              icon: Icons.extension_outlined,
              title: adminGap(AdminGapTextKeys.packageTitle, '套件'),
              load: (api) async {
                final pkgs = await api.packageList();
                if (pkgs.isEmpty) {
                  return adminGap(AdminGapTextKeys.emptyList, '（空）');
                }
                final head = adminGapFill(
                  AdminGapTextKeys.packageCount,
                  '共 ${pkgs.length} 个：',
                  {'n': '${pkgs.length}'},
                );
                return '$head'
                    '${pkgs.take(3).map((e) => e['id'] ?? '?').join(', ')}'
                    '${pkgs.length > 3 ? ' …' : ''}';
              },
            ),
            const Divider(height: 1),
            _AdminAsyncTile(
              tileKey: 'admin-network-tile',
              icon: Icons.lan_outlined,
              title: adminGap(AdminGapTextKeys.networkTitle, '网络'),
              load: (api) async {
                final d = await api.networkGet();
                final name = d['server_name'];
                return name is String && name.isNotEmpty
                    ? name
                    : adminGap(AdminGapTextKeys.sysInfoUnknown, '系统信息未知');
              },
            ),
            const Divider(height: 1),
            _AdminAsyncTile(
              tileKey: 'admin-upgrade-tile',
              icon: Icons.system_update_alt_outlined,
              title: adminGap(AdminGapTextKeys.upgradeTitle, 'DSM 升级'),
              load: (api) async {
                final d = await api.upgradeBasicStatus();
                final avail = d['available'] ?? d['has_upgrade'];
                if (avail is! bool) {
                  return adminGap(AdminGapTextKeys.sysInfoUnknown, '系统信息未知');
                }
                return avail
                    ? adminGap(AdminGapTextKeys.upgradeAvailable, '有可用更新')
                    : adminGap(AdminGapTextKeys.upgradeLatest, '已是最新');
              },
            ),
            const Divider(height: 1),
            _AdminAsyncTile(
              tileKey: 'admin-service-tile',
              icon: Icons.settings_suggest_outlined,
              title: adminGap(AdminGapTextKeys.serviceTitle, '服务状态'),
              load: (api) async {
                final d = await api.serviceStatus();
                final list = d['services'];
                if (list is! List || list.isEmpty) {
                  return adminGap(AdminGapTextKeys.emptyList, '（空）');
                }
                return adminGapFill(
                  AdminGapTextKeys.serviceCount,
                  '共 ${list.length} 项服务',
                  {'n': '${list.length}'},
                );
              },
            ),
            const Divider(height: 1),
            const _SysInfoTile(),
            const Divider(height: 1),
            const _FindMeTile(),
            const Divider(height: 1),
            const _BeepTile(),
          ],
        ),
      ),
    );
  }
}

/// 蜂鸣：状态（`get`）+ 停止（`stop_beep`）。
class _BeepTile extends ConsumerStatefulWidget {
  const _BeepTile();

  @override
  ConsumerState<_BeepTile> createState() => _BeepTileState();
}

class _BeepTileState extends ConsumerState<_BeepTile> {
  bool? _beeping;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = ref.read(systemAdminApiProvider);
    if (api == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final s = await api.beepStatus();
      if (!mounted) return;
      setState(() {
        _beeping = s.beeping;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _stop() async {
    final api = ref.read(systemAdminApiProvider);
    if (api == null) return;
    setState(() => _busy = true);
    try {
      await api.stopBeep();
      if (!mounted) return;
      trackOnce(UsageModule.admin, UsageAction.edit, objectType: 'beep');
      setState(() {
        _busy = false;
        _beeping = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            key: const Key('admin-beep-stopped'),
            content: Text(adminGap(AdminGapTextKeys.beepStopped, '已停止蜂鸣')),
          ),
        );
      }
    } catch (e) {
      trackOnceFailure(
        UsageModule.admin,
        UsageAction.edit,
        objectType: 'beep',
        reason: 'stop_failed',
        error: e,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final denied =
        _error != null &&
        (_error!.contains('105') || _error!.contains('noPermission'));
    final String subtitle;
    if (_loading) {
      subtitle = adminGap(AdminGapTextKeys.adminLoading, '读取中…');
    } else if (denied) {
      subtitle = adminGap(
        AdminGapTextKeys.adminOnlyNeedsAdmin,
        '需要管理员权限才能查看此页面。',
      );
    } else if (_error != null) {
      subtitle = adminGap(AdminGapTextKeys.adminReadFailed, '读取失败。');
    } else if (_beeping == null) {
      subtitle = adminGap(AdminGapTextKeys.beepUnknown, '状态未知');
    } else if (_beeping == true) {
      subtitle = adminGap(AdminGapTextKeys.beepBeeping, '正在蜂鸣');
    } else {
      subtitle = adminGap(AdminGapTextKeys.beepNotBeeping, '未在蜂鸣');
    }

    return DesignRowTile(
      key: const Key('admin-beep-tile'),
      leading: const Icon(Icons.notifications_active_outlined),
      title: Text(adminGap(AdminGapTextKeys.beepTitle, '蜂鸣')),
      subtitle: Text(subtitle, key: const Key('admin-beep-state')),
      trailing: (_beeping == true && !_busy)
          ? TextButton(
              key: const Key('admin-beep-stop'),
              onPressed: _stop,
              child: Text(adminGap(AdminGapTextKeys.beepStop, '停止')),
            )
          : null,
    );
  }
}

/// Active Insight 的**只读**状态（`get_status`，adminOnly）。
class _ActiveInsightStatus extends ConsumerWidget {
  const _ActiveInsightStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(authExtraApiProvider);
    if (api == null) return const SizedBox.shrink();
    return FutureBuilder<bool>(
      // ⚠️ 不缓存：这一行是"状态"，进页面时读一次即可。
      future: api.activeInsightEnabled(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return Text(adminGap(AdminGapTextKeys.adminLoading, '读取中…'));
        }
        if (snap.hasError) {
          // ★ 服务端回 105 时**如实说"需要管理员权限"**，不白屏、不假装"未启用"。
          final e = snap.error;
          final denied = '$e'.contains('105') || '$e'.contains('noPermission');
          return Text(
            denied
                ? adminGap(
                    AdminGapTextKeys.adminOnlyNeedsAdmin,
                    '需要管理员权限才能查看此页面。',
                  )
                : adminGap(AdminGapTextKeys.adminReadFailed, '读取失败。'),
            key: const Key('admin-tools-active-insight-error'),
          );
        }
        return Text(
          snap.data == true
              ? adminGap(AdminGapTextKeys.adminEnabled, '已启用')
              : adminGap(AdminGapTextKeys.adminDisabled, '未启用'),
          key: const Key('admin-tools-active-insight-state'),
        );
      },
    );
  }
}

/// 系统信息（`SYNO.Core.System:info`，官方 v1）。
class _SysInfoTile extends ConsumerStatefulWidget {
  const _SysInfoTile();

  @override
  ConsumerState<_SysInfoTile> createState() => _SysInfoTileState();
}

class _SysInfoTileState extends ConsumerState<_SysInfoTile> {
  SystemInfo? _info;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = ref.read(systemAdminApiProvider);
    if (api == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final i = await api.systemInfo();
      if (!mounted) return;
      trackOnce(UsageModule.admin, UsageAction.edit, objectType: 'system');
      setState(() {
        _info = i;
        _loading = false;
      });
    } catch (e) {
      trackOnceFailure(
        UsageModule.admin,
        UsageAction.edit,
        objectType: 'system',
        reason: 'load_failed',
        error: e,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final denied =
        _error != null &&
        (_error!.contains('105') || _error!.contains('noPermission'));
    final i = _info;
    final String subtitle;
    if (_loading) {
      subtitle = adminGap(AdminGapTextKeys.adminLoading, '读取中…');
    } else if (denied) {
      subtitle = adminGap(
        AdminGapTextKeys.adminOnlyNeedsAdmin,
        '需要管理员权限才能查看此页面。',
      );
    } else if (_error != null) {
      subtitle = adminGap(AdminGapTextKeys.adminReadFailed, '读取失败。');
    } else if (i == null || (i.model == null && i.version == null)) {
      // 字段全缺 ⇒ 如实说"未知"，不拼一个假字符串
      subtitle = adminGap(AdminGapTextKeys.sysInfoUnknown, '系统信息未知');
    } else {
      subtitle = [
        if (i.model != null) i.model!,
        if (i.version != null) i.version!,
        if (i.buildNum != null) 'build ${i.buildNum}',
      ].join(' · ');
    }
    return DesignRowTile(
      key: const Key('admin-sysinfo-tile'),
      leading: const Icon(Icons.memory_outlined),
      title: Text(adminGap(AdminGapTextKeys.sysInfoTitle, '系统信息')),
      subtitle: Text(subtitle, key: const Key('admin-sysinfo-state')),
    );
  }
}

/// FindMe 支持状态（`SYNO.DSM.FindMe:supported`，官方 v2）。
///
/// ⚠️ 官方还有 `start`/`stop`（§5.1 变更动词），**本仓不实现**
/// ⇒ 这里**只有状态显示，没有启停按钮**。刻意如此。
class _FindMeTile extends ConsumerStatefulWidget {
  const _FindMeTile();

  @override
  ConsumerState<_FindMeTile> createState() => _FindMeTileState();
}

class _FindMeTileState extends ConsumerState<_FindMeTile> {
  bool? _supported;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = ref.read(systemAdminApiProvider);
    if (api == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final v = await api.findMeSupported();
      if (!mounted) return;
      trackOnce(UsageModule.admin, UsageAction.edit, objectType: 'findme');
      setState(() {
        _supported = v;
        _loading = false;
      });
    } catch (e) {
      trackOnceFailure(
        UsageModule.admin,
        UsageAction.edit,
        objectType: 'findme',
        reason: 'load_failed',
        error: e,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final denied =
        _error != null &&
        (_error!.contains('105') || _error!.contains('noPermission'));
    final String subtitle;
    if (_loading) {
      subtitle = adminGap(AdminGapTextKeys.adminLoading, '读取中…');
    } else if (denied) {
      subtitle = adminGap(
        AdminGapTextKeys.adminOnlyNeedsAdmin,
        '需要管理员权限才能查看此页面。',
      );
    } else if (_error != null) {
      subtitle = adminGap(AdminGapTextKeys.adminReadFailed, '读取失败。');
    } else if (_supported == null) {
      subtitle = adminGap(AdminGapTextKeys.findMeUnknown, '状态未知');
    } else if (_supported == true) {
      subtitle = adminGap(AdminGapTextKeys.findMeSupported, '本机支持');
    } else {
      subtitle = adminGap(AdminGapTextKeys.findMeUnsupported, '本机不支持');
    }
    return DesignRowTile(
      key: const Key('admin-findme-tile'),
      leading: const Icon(Icons.travel_explore_outlined),
      title: Text(adminGap(AdminGapTextKeys.findMeTitle, 'FindMe（定位我的 NAS）')),
      subtitle: Text(subtitle, key: const Key('admin-findme-state')),
      // 刻意不给启停按钮：官方 start/stop 是 §5.1 变更动词，本仓未实现
    );
  }
}

/// ★ 通用**只读**管理磁贴：一行标题 + 一行状态。
///
/// 抽出来是为了让"接一个新管理接口"只写 [load] 一处 ——
/// 三档显示（加载中 / 需要管理员权限 / 读取失败 / 未知）在这里统一处理，
/// 避免每个接口各写一遍、各漏一档。
class _AdminAsyncTile extends ConsumerStatefulWidget {
  const _AdminAsyncTile({
    required this.tileKey,
    required this.icon,
    required this.title,
    required this.load,
  });

  final String tileKey;
  final IconData icon;
  final String title;

  /// 成功时返回要显示的文案；返回 null 表示"未知"。
  final Future<String?> Function(SystemAdminApi api) load;

  @override
  ConsumerState<_AdminAsyncTile> createState() => _AdminAsyncTileState();
}

class _AdminAsyncTileState extends ConsumerState<_AdminAsyncTile> {
  String? _text;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final api = ref.read(systemAdminApiProvider);
    if (api == null) {
      setState(() => _loading = false);
      return;
    }
    final panel = _adminPanelId(widget.tileKey);
    try {
      final t = await widget.load(api);
      if (!mounted) return;
      trackOnce(UsageModule.admin, UsageAction.edit, objectType: panel);
      setState(() {
        _text = t;
        _loading = false;
      });
    } catch (e) {
      trackOnceFailure(
        UsageModule.admin,
        UsageAction.edit,
        objectType: panel,
        reason: 'load_failed',
        error: e,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final denied =
        _error != null &&
        (_error!.contains('105') || _error!.contains('noPermission'));
    final String subtitle;
    if (_loading) {
      subtitle = adminGap(AdminGapTextKeys.adminLoading, '读取中…');
    } else if (denied) {
      subtitle = adminGap(
        AdminGapTextKeys.adminOnlyNeedsAdmin,
        '需要管理员权限才能查看此页面。',
      );
    } else if (_error != null) {
      subtitle = adminGap(AdminGapTextKeys.adminReadFailed, '读取失败。');
    } else if (_text == null) {
      subtitle = adminGap(AdminGapTextKeys.sysInfoUnknown, '系统信息未知');
    } else {
      subtitle = _text!;
    }
    return DesignRowTile(
      key: Key(widget.tileKey),
      leading: Icon(widget.icon),
      title: Text(widget.title),
      subtitle: Text(subtitle, key: Key('${widget.tileKey}-state')),
    );
  }
}

/// Stable ASCII panel id derived from the tile key
/// (`admin-package-tile` -> `package`).
String _adminPanelId(String tileKey) =>
    tileKey.replaceFirst('admin-', '').replaceFirst('-tile', '');
