// 多 NAS / 多账号的管理页（P64 / N5 / D3 的公共入口）。
//
// 用户语言为主：这里只说「NAS / 服务器 / 账号 / 当前」，不出现 sid、baseUrl
// 这类内部词；QuickConnect ID 是官方自己就叫的名字，照旧。
//
// 能做的事：看本机保存了哪些 NAS/账号、哪个是当前、切过去、加一个、改名、移除。
// 「移除」必须二次确认，而且**只删这一条**（别的 NAS 配置原样保留，安全不变量）。
//
// 放置位置：`ServerSetupPage`（服务器页）里一个「管理 NAS」入口打开它；
// 不依赖全局路由表，因此别的页面想加入口时只需调 [NasManagerPage.open]。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import '../../core/router/app_routes.dart';
import 'nas_registry.dart';
import 'saved_session.dart';
import 'server_profile.dart';
import 'session_controller.dart';

class NasManagerPage extends ConsumerStatefulWidget {
  const NasManagerPage({super.key});

  /// 从任意页面打开管理页（用 rootNavigator，避免被底部导航挡住）。
  static Future<void> open(BuildContext context) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => const NasManagerPage()),
    );
  }

  @override
  ConsumerState<NasManagerPage> createState() => _NasManagerPageState();
}

class _NasManagerPageState extends ConsumerState<NasManagerPage> {
  @override
  void initState() {
    super.initState();
    // 列表是异步读的；这里踢一脚，界面用 loading 态兜底
    ref.read(nasRegistryProvider.notifier).ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    final nas = ref.watch(nasRegistryProvider);
    final session = ref.watch(sessionControllerProvider);

    return DesignScaffold(
      appBar: AppBar(
        title: Text(context.t.nasTitle),
        actions: [
          IconButton(
            tooltip: context.t.nasAdd,
            icon: const Icon(Icons.add),
            onPressed: () => _addNas(context),
          ),
        ],
      ),
      body: !nas.loaded
          ? const Center(child: CircularProgressIndicator())
          : nas.configs.isEmpty
          ? _empty(context)
          : ListView(
              children: [
                if (nas.partial)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Text(
                      context.t.nasPartialLoad,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                for (final c in nas.configs)
                  _NasTile(
                    config: c,
                    active: c.id != null && c.id == session.activeNasId,
                    switching: session.switching,
                    onSwitch: () => _switch(context, c),
                    onRename: () => _rename(context, c),
                    onRemove: () => _remove(context, c),
                  ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    context.t.nasFootnote,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
    );
  }

  Widget _empty(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.dns_outlined, size: 40),
          const SizedBox(height: 12),
          Text(context.t.nasEmpty),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => _addNas(context),
            icon: const Icon(Icons.add),
            label: Text(context.t.nasAdd),
          ),
        ],
      ),
    ),
  );

  /// 切到某一条。需要登录时把用户带到登录页（地址/账号已预填）。
  Future<void> _switch(BuildContext context, SavedSession c) async {
    final id = c.id;
    if (id == null) return;
    final result = await ref
        .read(sessionControllerProvider.notifier)
        .switchTo(id);
    if (!context.mounted) return;
    _afterResult(context, result, c.profile.label);
  }

  Future<void> _addNas(BuildContext context) async {
    final draft = await showDialog<_NasDraft>(
      context: context,
      builder: (_) => const _NasFormDialog(),
    );
    if (draft == null || !context.mounted) return;

    final result = await ref
        .read(sessionControllerProvider.notifier)
        .addNas(draft.profile, displayName: draft.displayName);
    if (!context.mounted) return;
    _afterResult(context, result, draft.profile.label);
  }

  Future<void> _rename(BuildContext context, SavedSession c) async {
    final controller = TextEditingController(text: c.profile.displayName ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.t.rename),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: context.t.nasNameLabel,
            hintText: context.t.nasNameHint,
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: Text(context.t.actionSave),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || c.id == null) return;
    await ref
        .read(sessionControllerProvider.notifier)
        .renameNas(c.id!, name.trim().isEmpty ? null : name.trim());
  }

  /// 移除：**必须明确确认**，且只删这一条。
  Future<void> _remove(BuildContext context, SavedSession c) async {
    final id = c.id;
    if (id == null) return;
    final isActive = id == ref.read(sessionControllerProvider).activeNasId;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.t.nasRemoveTitle),
        content: Text(
          isActive
              ? context.t.nasRemoveActiveBody(c.profile.label)
              : context.t.nasRemoveBody(c.profile.label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.t.dtoActionDelete),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final result = await ref
        .read(sessionControllerProvider.notifier)
        .removeNas(id);
    if (!context.mounted) return;
    if (!isActive) return; // 删的不是当前：什么都不用做
    if (result == NasSwitchResult.success) {
      final now = ref.read(nasRegistryProvider).active;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            now == null
                ? context.t.nasRemovedNone
                : context.t.nasRemovedSwitched(now.profile.label),
          ),
        ),
      );
      return;
    }
    // 落在剩余项上但需要补登录 / 连不上：走统一的收尾
    _afterResult(
      context,
      result,
      ref.read(nasRegistryProvider).active?.profile.label ?? c.profile.label,
    );
  }

  void _afterResult(BuildContext context, NasSwitchResult r, String label) {
    switch (r) {
      case NasSwitchResult.success:
      case NasSwitchResult.alreadyActive:
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.t.nasSwitched(label))));
      case NasSwitchResult.needLogin:
      case NasSwitchResult.loginFailed:
        // 去登录页：它会从会话状态里预填地址与账号
        context.go(AppRoutes.login);
      case NasSwitchResult.connectFailed:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ref.read(sessionControllerProvider).error ?? context.t.nasConnectFailed,
            ),
          ),
        );
      case NasSwitchResult.notFound:
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.t.nasRecordGone)));
    }
  }
}

class _NasTile extends StatelessWidget {
  const _NasTile({
    required this.config,
    required this.active,
    required this.switching,
    required this.onSwitch,
    required this.onRename,
    required this.onRemove,
  });

  final SavedSession config;
  final bool active;
  final bool switching;
  final VoidCallback onSwitch;
  final VoidCallback onRename;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = config.account.trim();
    return DesignRowTile(
      leading: Icon(
        active ? Icons.dns : Icons.dns_outlined,
        color: active ? theme.colorScheme.primary : null,
      ),
      title: Text(config.profile.label),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (config.profile.displayName != null)
            Text(config.profile.value, style: theme.textTheme.bodySmall),
          Text(
            account.isEmpty
                ? context.t.nasNotSignedIn
                : context.t.nasAccount(account),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (active)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Chip(
                label: Text(context.t.nasCurrent),
                visualDensity: VisualDensity.compact,
              ),
            ),
          PopupMenuButton<String>(
            enabled: !switching,
            tooltip: context.t.fileMoreActions,
            onSelected: (v) => switch (v) {
              'switch' => onSwitch(),
              'rename' => onRename(),
              _ => onRemove(),
            },
            itemBuilder: (_) => [
              if (!active)
                PopupMenuItem(value: 'switch', child: Text(context.t.nasSwitchTo)),
              PopupMenuItem(value: 'rename', child: Text(context.t.rename)),
              PopupMenuItem(value: 'remove', child: Text(context.t.nasRemove)),
            ],
          ),
        ],
      ),
      onTap: switching || active ? null : onSwitch,
    );
  }
}

/// 「添加 NAS」对话框收集到的东西。
class _NasDraft {
  const _NasDraft({required this.profile, this.displayName});
  final ServerProfile profile;
  final String? displayName;
}

class _NasFormDialog extends StatefulWidget {
  const _NasFormDialog();

  @override
  State<_NasFormDialog> createState() => _NasFormDialogState();
}

class _NasFormDialogState extends State<_NasFormDialog> {
  final _name = TextEditingController();
  final _address = TextEditingController();
  ServerAddressKind _kind = ServerAddressKind.quickConnect;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _address.text.trim();
    if (value.isEmpty) return;
    final name = _name.text.trim();
    Navigator.of(context).pop(
      _NasDraft(
        profile: ServerProfile(
          kind: _kind,
          value: value,
          displayName: name.isEmpty ? null : name,
        ),
        displayName: name.isEmpty ? null : name,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.t.nasAdd),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            decoration: InputDecoration(
              labelText: context.t.nasNameOptional,
              hintText: context.t.nasNameHint,
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<ServerAddressKind>(
            segments: [
              const ButtonSegment(
                value: ServerAddressKind.quickConnect,
                label: Text('QuickConnect ID'),
                icon: Icon(Icons.cloud_outlined),
              ),
              ButtonSegment(
                value: ServerAddressKind.direct,
                label: Text(context.t.nasDirectAddress),
                icon: const Icon(Icons.lan_outlined),
              ),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _address,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: _kind == ServerAddressKind.quickConnect
                  ? 'QuickConnect ID'
                  : context.t.nasHostOrAddress,
              hintText: _kind == ServerAddressKind.quickConnect
                  ? context.t.srvQuickConnectExample
                  : context.t.srvHostExample,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t.actionCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(context.t.nasAddAndConnect)),
      ],
    );
  }
}

/// 服务器页上的「NAS 切换器」：多个时给一排列，只有一个时给一行状态。
///
/// 单独抽出来是为了让"切换器出现/只剩一个时的表现"能被页面层用例直接断言。
class NasSwitcherBar extends ConsumerWidget {
  const NasSwitcherBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nas = ref.watch(nasRegistryProvider);
    final session = ref.watch(sessionControllerProvider);
    final theme = Theme.of(context);
    if (!nas.loaded || nas.configs.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                nas.hasMultiple
                    ? context.t.nasSelectN(nas.configs.length)
                    : context.t.nasSaved,
                style: theme.textTheme.labelLarge,
              ),
            ),
            TextButton(
              onPressed: () => NasManagerPage.open(context),
              child: Text(context.t.nasManage),
            ),
          ],
        ),
        if (nas.hasMultiple)
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final c in nas.configs)
                ChoiceChip(
                  label: Text(c.profile.label),
                  selected: c.id != null && c.id == session.activeNasId,
                  onSelected: session.switching
                      ? null
                      : (_) async {
                          if (c.id == null) return;
                          final r = await ref
                              .read(sessionControllerProvider.notifier)
                              .switchTo(c.id!);
                          if (!context.mounted) return;
                          if (r == NasSwitchResult.needLogin ||
                              r == NasSwitchResult.loginFailed) {
                            context.go(AppRoutes.login);
                          }
                        },
                ),
            ],
          )
        else
          Text(
            nas.active == null
                ? context.t.nasLabelNotSignedIn(nas.configs.first.profile.label)
                : context.t.nasCurrentLabel(nas.active!.profile.label),
            style: theme.textTheme.bodySmall,
          ),
      ],
    );
  }
}
