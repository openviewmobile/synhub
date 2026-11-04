// File Station C5：远程挂载 / 虚拟卷管理页。
//
// 入口在文件浏览页顶栏（`file_browse_page.dart` 的 `_Deck`），**只在服务器
// 注册表里有 `SYNO.FileStation.Mount` / `Mount.List` 时才出现**；服务器回
// 105（noPermission）/ 160（noAppPrivilege）时页面把新增/卸载按钮整个换掉，
// 只留一句明确原因 —— 不留会失败的入口。
//
// 官方基线：DS file 4.17.2-609 **没有**挂载 UI（审计 §7.5 C3：dex 里
// `mount_remote`/`mount_iso`/`FileStation.Mount` 0 命中），它只能通过
// `[__VIRTUAL__CIFS__]` / `[__VIRTUAL__ISO__]` 两个哨兵**浏览**已挂载的卷。
// 本页把这些**服务端普通用户能力**补齐（注册表 allowUser 含 normal.*），
// 参数逐字取自服务端自带官方前端 `ui/file_browser/FileBrowser.js`。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/file_entry_dto.dart';
import '../../data/dto/file_mount_dto.dart';
import '../../data/local/file_store.dart' show describeFileError;
import '../admin/admin_gate.dart' show adminOnlyVisible;
import 'file_mount.dart';
import 'file_providers.dart';
import 'file_sheets.dart' show confirmDanger;
import 'filestation_c5_text.dart';

class FileMountPage extends ConsumerWidget {
  const FileMountPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final cap = ref.watch(fileMountCapabilityProvider);
    final snapshot = ref.watch(fileMountsProvider);
    final denied = snapshot.value?.permissionDenied ?? false;
    // ★ 官方两道门（逐字依据见 [FileMountGate]）：
    //   ① 服务端 `mountConfig.enable_remote_mount / enable_iso_mount`；
    //   ② 远程卷还要求 `is_admin || 用户有 home 文件夹`。
    // 列表未到货（loading）时 config 为默认 false ⇒ 按钮先不出现，
    // 与官方 `onGetUserGrpDone` 里"先建后 show"的顺序一致。
    final gate = FileMountGate.of(
      config: snapshot.value?.list.config ?? const FileMountConfig(),
      isAdmin: adminOnlyVisible(ref),
      // `home` 这一格与官方 `dirTree.getNodeById("remote/home")` 同源：
      // 都取"根共享列表里到底有没有 home"，不是猜"应该有"。
      hasHome: ref.watch(fileHomeEntryProvider) != null,
    );

    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(fsC5(FsC5TextKeys.mountTitle, '远程挂载')),
        actions: [
          IconButton(
            tooltip: context.t.photoRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(fileMountsProvider),
          ),
          // 「新增挂载」= 官方 `btnMountRemote` / `btnMountISO`：
          // 服务器开了哪一类才给哪一类，两类都没开就整个不出现
          if (cap.canMount && !denied && gate.anyAllowed)
            IconButton(
              tooltip: fsC5(FsC5TextKeys.mountAdd, '新增挂载'),
              icon: const Icon(Icons.add),
              onPressed: () => _showAddSheet(context, ref, gate),
            ),
        ],
      ),
      body: snapshot.when(
          data: (value) => _body(context, ref, value, gate),
          error: (error, _) => AppErrorView(
            title: fsC5(FsC5TextKeys.mountTitle, '远程挂载'),
            detail: describeFileError(error),
            onRetry: () => ref.invalidate(fileMountsProvider),
          ),
          loading: () => const AppListSkeleton(),
        ),
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    FileMountSnapshot snap,
    FileMountGate gate,
  ) {
    if (snap.permissionDenied) {
      // 明确提示，且**没有**任何会失败的动作按钮
      return AppEmptyState(
        icon: Icons.lock_outline,
        title: fsC5(FsC5TextKeys.mountUnavailable, '无法管理远程挂载'),
        message: fsC5(
          FsC5TextKeys.mountPermissionDenied,
          '这个账号没有挂载/卸载远程卷的权限（DSM → 控制面板 → 应用程序权限 → File Station）',
        ),
      );
    }
    final list = snap.list;
    final iso = ref.watch(fileVirtualFoldersProvider(FileMountType.iso));
    final cifs = ref.watch(fileVirtualFoldersProvider(FileMountType.cifs));
    final virtual = <FileEntryDto>[
      ...?iso.value,
      ...?cifs.value,
    ];
    if (list.all.isEmpty && virtual.isEmpty) {
      // ★ 官方口径：`enable_remote_mount` / `enable_iso_mount` 都为 false 时
      // 官方把**新增那一格整个藏掉**（`error_privilege_not_enough`）。我们没有
      // 藏掉"管理页"这个壳（入口按服务端注册表判定，省掉每次进根目录的额外探测），
      // 但**不能再摆一句"还没有挂载任何远程卷或 ISO 镜像"** —— 那会让人以为
      // 自己可以加。这里改成如实说明"服务器没给药"，且不出现任何会失败的动作。
      if (!gate.anyAllowed) {
        return AppEmptyState(
          icon: Icons.lock_outline,
          title: fsC5(FsC5TextKeys.mountUnavailable, '无法管理远程挂载'),
          // ★ i18n 守卫（`test/i18n_hardcoded_cjk_test.dart`）：`fsC5(key, '中文')`
          // 必须是**字面量对**才被认作译文回落，所以这里写成两个分支各一次调用。
          message: gate.remoteNeedsHome
              ? fsC5(
                  FsC5TextKeys.mountNeedsHome,
                  '非管理员只能在用户主目录（home）里挂载远程文件夹；这个账号没有启用用户主目录。',
                )
              : fsC5(
                  FsC5TextKeys.mountServerDisabled,
                  '这台服务器没有为这个账号开启挂载能力，所以没有可新增的类型。请联系管理员在 File Station 里开启远程挂载或 ISO 挂载。',
                ),
        );
      }
      return AppEmptyState(
        icon: Icons.cloud_queue,
        title: fsC5(FsC5TextKeys.mountTitle, '远程挂载'),
        message: fsC5(
          FsC5TextKeys.mountEmpty,
          '还没有挂载任何远程卷或 ISO 镜像。',
        ),
      );
    }
    // ListTile 的"背景/水波纹可能看不见"断言：`FieldBackdrop` 用
    // `ColoredBox` 垫底，必须在它**下面**再给一层透明 `Material`，
    // 否则带 onTap 的 ListTile 一帧就会抛断言（真机不报错，但 ink 也真的没了）。
    return Material(
      type: MaterialType.transparency,
      child: ListView(
        padding: const EdgeInsets.only(bottom: Gap.xl),
        children: [
          if (list.isoList.isNotEmpty)
            _section(
              context,
              ref,
              title: fsC5(FsC5TextKeys.mountIsoSection, 'ISO 镜像卷'),
              mounts: list.isoList,
              type: FileMountType.iso,
            ),
          if (list.remoteList.isNotEmpty)
            _section(
              context,
              ref,
              title: fsC5(FsC5TextKeys.mountRemoteSection, '远程卷（CIFS）'),
              mounts: list.remoteList,
              type: FileMountType.cifs,
            ),
          if (virtual.isNotEmpty)
            _virtualSection(context, ref, virtual),
        ],
      ),
    );
  }

  Widget _section(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required List<FileMountDto> mounts,
    required FileMountType type,
  }) {
    final cap = ref.watch(fileMountCapabilityProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              if (type == FileMountType.cifs)
                TextButton(
                  onPressed: () => _reconnect(context, ref, mounts),
                  child: Text(fsC5(FsC5TextKeys.mountReconnect, '重新连接')),
                )
              else
                TextButton(
                  onPressed: () => _remount(context, ref, type),
                  child: Text(fsC5(FsC5TextKeys.mountRemount, '重新挂载')),
                ),
            ],
          ),
        ),
        for (final m in mounts) _row(context, ref, m, type, cap),
      ],
    );
  }

  Widget _row(
    BuildContext context,
    WidgetRef ref,
    FileMountDto m,
    FileMountType type,
    FileMountCapability cap,
  ) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final subtitle = <String>[
      if (m.source.isNotEmpty) m.source,
      if (m.actor.isNotEmpty)
        '${fsC5(FsC5TextKeys.mountActor, '挂载者')}: ${m.actor}',
      if (type == FileMountType.iso)
        fsC5(FsC5TextKeys.mountIsoReadOnly, 'ISO 卷是只读的'),
    ].join(' · ');
    return DesignRowTile(
      leading: Icon(
        type == FileMountType.iso
            ? Icons.album_outlined
            : Icons.cloud_outlined,
        color: hud.dim,
      ),
      title: Text(m.mountPoint),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (subtitle.isNotEmpty) Text(subtitle),
          if (m.autoMountFailed)
            Text(
              fsC5(FsC5TextKeys.mountAutoMountFailed, '开机自动挂载失败'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: () => _browse(context, ref, m.mountPoint),
            child: Text(fsC5(FsC5TextKeys.mountBrowse, '浏览')),
          ),
          if (cap.canUnmount)
            IconButton(
              tooltip: fsC5(FsC5TextKeys.mountUnmount, '卸载'),
              icon: const Icon(Icons.eject_outlined),
              onPressed: () => _unmount(context, ref, m, t),
            ),
        ],
      ),
    );
  }

  Widget _virtualSection(
    BuildContext context,
    WidgetRef ref,
    List<FileEntryDto> entries,
  ) {
    final hud = DesignPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
          child: Text(
            fsC5(FsC5TextKeys.mountVirtualSection, '虚拟文件夹'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        for (final e in entries)
          DesignRowTile(
            leading: Icon(Icons.folder_outlined, color: hud.dim),
            title: Text(e.name),
            subtitle: Text(e.path),
            onTap: () => _browse(context, ref, e.path),
          ),
      ],
    );
  }

  // ------------------------------------------------------------ 动作

  void _browse(BuildContext context, WidgetRef ref, String path) {
    if (path.isEmpty) return;
    ref.read(fileBrowseStackProvider.notifier).openPath(path);
    Navigator.of(context).pop();
  }

  Future<void> _unmount(
    BuildContext context,
    WidgetRef ref,
    FileMountDto m,
    AppText t,
  ) async {
    final ok = await confirmDanger(
      context,
      title: fsC5(FsC5TextKeys.mountUnmount, '卸载'),
      message: fsC5Fill(
        FsC5TextKeys.mountUnmountConfirm,
        '确定要卸载 {name} 吗？',
        {'name': m.mountPoint},
      ),
      actionLabel: fsC5(FsC5TextKeys.mountUnmount, '卸载'),
    );
    if (!ok || !context.mounted) return;
    try {
      // 挂载管理页统一走 `Mount.List/unmount`（`mount_point` 数组，官方
      // `MountGrid` 的 tbar 动作就是这条），比单点 `Mount/unmount` 少两个参数。
      await ref.read(fileMountActionsProvider).unmount([m.mountPoint]);
      if (!context.mounted) return;
      AppSnack.show(
        context,
        fsC5(FsC5TextKeys.mountUnmounted, '已卸载'),
      );
    } catch (e) {
      if (!context.mounted) return;
      AppSnack.show(context, describeFileError(e), error: true);
    }
  }

  Future<void> _reconnect(
    BuildContext context,
    WidgetRef ref,
    List<FileMountDto> mounts,
  ) async {
    try {
      await ref
          .read(fileMountActionsProvider)
          .reconnect(mounts.map((m) => m.mountPoint).toList());
    } catch (e) {
      if (!context.mounted) return;
      AppSnack.show(context, describeFileError(e), error: true);
    }
  }

  Future<void> _remount(
    BuildContext context,
    WidgetRef ref,
    FileMountType type,
  ) async {
    try {
      await ref.read(fileMountActionsProvider).remount(type);
    } catch (e) {
      if (!context.mounted) return;
      AppSnack.show(context, describeFileError(e), error: true);
    }
  }

  void _showAddSheet(
    BuildContext context,
    WidgetRef ref,
    FileMountGate gate,
  ) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 官方把 CIFS/NFS 与 ISO 分成两个入口、各自按 `mountConfig` 显隐
            // （`btnMountRemote` vs `btnMountISO`）⇒ 这里同样只列出服务器开了的
            if (gate.remoteAllowed)
              DesignRowTile(
                leading: const Icon(Icons.cloud_outlined),
                title: Text(
                  fsC5(FsC5TextKeys.mountAddCifs, '挂载远程文件夹（CIFS）'),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showCifsDialog(context, ref);
                },
              ),
            if (gate.isoAllowed)
              DesignRowTile(
                leading: const Icon(Icons.album_outlined),
                title: Text(fsC5(FsC5TextKeys.mountAddIso, '挂载 ISO 镜像')),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showIsoDialog(context, ref);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCifsDialog(BuildContext context, WidgetRef ref) async {
    final t = context.t;
    final server = TextEditingController(text: r'\\');
    final account = TextEditingController();
    final password = TextEditingController();
    final point = TextEditingController();
    var autoMount = false;
    String? error;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: Text(fsC5(FsC5TextKeys.mountAddCifs, '挂载远程文件夹（CIFS）')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: server,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: fsC5(FsC5TextKeys.mountServer, '服务器地址'),
                    helperText: fsC5Fill(
                      FsC5TextKeys.mountServerHint,
                      r'形如 {example}',
                      {'example': r'\\192.168.1.1\Share'},
                    ),
                  ),
                ),
                TextField(
                  controller: account,
                  decoration: InputDecoration(
                    labelText: fsC5(FsC5TextKeys.mountAccount, '账号'),
                  ),
                ),
                TextField(
                  controller: password,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: fsC5(FsC5TextKeys.mountPassword, '密码'),
                  ),
                ),
                TextField(
                  controller: point,
                  decoration: InputDecoration(
                    labelText: fsC5(FsC5TextKeys.mountMountPoint, '挂载点'),
                    helperText: fsC5Fill(
                      FsC5TextKeys.mountPointHint,
                      '如 {example}',
                      {'example': '/volume1/Share'},
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        fsC5(FsC5TextKeys.mountAutoMount, '开机自动挂载'),
                      ),
                    ),
                    Switch(
                      value: autoMount,
                      onChanged: (v) => setState(() => autoMount = v),
                    ),
                  ],
                ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(dialogContext).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(t.actionCancel),
            ),
            FilledButton(
              onPressed: () async {
                if (server.text.trim().isEmpty || point.text.trim().isEmpty) {
                  setState(
                    () => error = fsC5(
                      FsC5TextKeys.mountRequired,
                      '服务器地址与挂载点不能为空',
                    ),
                  );
                  return;
                }
                try {
                  await ref
                      .read(fileMountActionsProvider)
                      .mountCifs(
                        serverIp: server.text.trim(),
                        account: account.text,
                        password: password.text,
                        mountPoint: point.text.trim(),
                        autoMount: autoMount,
                      );
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                  if (context.mounted) {
                    AppSnack.show(
                      context,
                      fsC5(FsC5TextKeys.mountSubmitted, '已提交挂载'),
                    );
                  }
                } catch (e) {
                  setState(() => error = describeFileError(e));
                }
              },
              child: Text(fsC5(FsC5TextKeys.mountAdd, '新增挂载')),
            ),
          ],
        ),
      ),
    );
    server.dispose();
    account.dispose();
    password.dispose();
    point.dispose();
  }

  Future<void> _showIsoDialog(BuildContext context, WidgetRef ref) async {
    final t = context.t;
    final source = TextEditingController();
    final point = TextEditingController();
    var autoMount = false;
    String? error;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: Text(fsC5(FsC5TextKeys.mountAddIso, '挂载 ISO 镜像')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: source,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: fsC5(FsC5TextKeys.mountSource, 'ISO 源文件'),
                    helperText: '/volume1/iso/win.iso',
                  ),
                ),
                TextField(
                  controller: point,
                  decoration: InputDecoration(
                    labelText: fsC5(FsC5TextKeys.mountMountPoint, '挂载点'),
                    helperText: fsC5Fill(
                      FsC5TextKeys.mountPointHint,
                      '如 {example}',
                      {'example': '/volume1/win'},
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        fsC5(FsC5TextKeys.mountAutoMount, '开机自动挂载'),
                      ),
                    ),
                    Switch(
                      value: autoMount,
                      onChanged: (v) => setState(() => autoMount = v),
                    ),
                  ],
                ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(dialogContext).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(t.actionCancel),
            ),
            FilledButton(
              onPressed: () async {
                if (source.text.trim().isEmpty || point.text.trim().isEmpty) {
                  setState(
                    () => error = fsC5(
                      FsC5TextKeys.mountRequired,
                      '服务器地址与挂载点不能为空',
                    ),
                  );
                  return;
                }
                try {
                  await ref
                      .read(fileMountActionsProvider)
                      .mountIso(
                        source: source.text.trim(),
                        mountPoint: point.text.trim(),
                        autoMount: autoMount,
                      );
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                  if (context.mounted) {
                    AppSnack.show(
                      context,
                      fsC5(FsC5TextKeys.mountSubmitted, '已提交挂载'),
                    );
                  }
                } catch (e) {
                  setState(() => error = describeFileError(e));
                }
              },
              child: Text(fsC5(FsC5TextKeys.mountAdd, '新增挂载')),
            ),
          ],
        ),
      ),
    );
    source.dispose();
    point.dispose();
  }
}
