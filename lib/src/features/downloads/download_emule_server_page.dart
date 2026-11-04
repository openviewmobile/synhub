// ⑥下载 F2：**eMule 服务器 / Kad 管理（管理员专属）**。
//
// 接口（`SYNO.DownloadStation2.eMule.Server` v1，`allowUser` 不含普通用户）：
// `list` / `get_status` / `connect` / `connect_kad` / `disconnect` /
// `delete` / `add` —— 参数逐字来自官方 aMule ServerGridPanel（见数据层注释）。
// 新规 R2：非管理员**隐藏入口**（`AdminOnly` / `adminOnlyVisible`），不是提示无权限。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/download_station.dart';
import '../../data/dto/download_task_dto.dart';
import '../admin/admin_gate.dart';
import 'download_providers.dart';
import '../../core/theme/app_theme.dart';

class DownloadEmuleServerPage extends ConsumerStatefulWidget {
  const DownloadEmuleServerPage({super.key});

  @override
  ConsumerState<DownloadEmuleServerPage> createState() =>
      _DownloadEmuleServerPageState();
}

class _DownloadEmuleServerPageState
    extends ConsumerState<DownloadEmuleServerPage> {
  List<DsEmuleServer> _servers = const [];
  DsEmuleServerStatus? _status;
  bool _loading = true;
  String? _error;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final api = ref.read(downloadApiProvider);
    if (api == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await api.emuleServers(limit: 100);
      final st = await api.emuleServerStatus();
      if (!mounted) return;
      setState(() {
        _servers = page.items;
        _status = st;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = describeDownloadError(e);
      });
    }
  }

  Future<void> _act(Future<void> Function() run) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await run();
      await _reload();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(describeDownloadError(e))),
      );
    }
  }

  Future<void> _openAddDialog() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => const _AddServerDialog(),
    );
    if (ok == true) await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final api = ref.watch(downloadApiProvider);
    return AdminPageGate(
      title: dataText('dsEmuleServers', 'eMule 服务器'),
      child: DesignScaffold(
        appBar: AppBar(
          title: Text(dataText('dsEmuleServers', 'eMule 服务器')),
          leading: IconButton(
            key: const Key('ds-emule-srv-back'),
            tooltip: dataText('dsBack', '返回'),
            icon: const Icon(Icons.arrow_back),
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).maybePop(),
          ),
          actions: [
            IconButton(
              key: const Key('ds-emule-srv-refresh'),
              tooltip: t.photoRefresh,
              icon: const Icon(Icons.refresh),
              onPressed: _reload,
            ),
            IconButton(
              key: const Key('ds-emule-srv-add'),
              tooltip: dataText('dsEmuleAddServer', '添加服务器'),
              icon: const Icon(Icons.add),
              onPressed: api == null ? null : _openAddDialog,
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: _reload,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              _StatusBar(
                status: _status,
                onConnectKad: () => _act(
                  () => ref.read(downloadApiProvider)!.emuleConnectKad(),
                ),
                onDisconnect: () => _act(
                  () => ref.read(downloadApiProvider)!.emuleDisconnect(),
                ),
              ),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(Gap.lg),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (!_loading && _error != null)
                Padding(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Text(_error!, key: const Key('ds-emule-srv-error')),
                ),
              if (!_loading && _error == null && _servers.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Text(
                    dataText('dsEmuleNoServer', '还没有 eMule 服务器。'),
                    key: const Key('ds-emule-srv-empty'),
                  ),
                ),
              for (var i = 0; i < _servers.length; i++)
                _ServerTile(
                  index: i,
                  server: _servers[i],
                  selected: _selected.contains(_servers[i].id),
                  onToggle: () => setState(() {
                    final id = _servers[i].id;
                    if (!_selected.remove(id)) _selected.add(id);
                  }),
                  onConnect: () => _act(
                    () => ref
                        .read(downloadApiProvider)!
                        .emuleConnect(_servers[i].id),
                  ),
                  onDelete: () => _act(
                    () => ref
                        .read(downloadApiProvider)!
                        .emuleDeleteServers([_servers[i].id]),
                  ),
                ),
              if (_selected.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: FilledButton(
                    key: const Key('ds-emule-srv-delete-selected'),
                    onPressed: () => _act(
                      () => ref
                          .read(downloadApiProvider)!
                          .emuleDeleteServers(_selected.toList()),
                    ),
                    child: Text(
                      '${dataText('dsEmuleDeleteSelected', '删除选中')} '
                      '(${_selected.length})',
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.status,
    required this.onConnectKad,
    required this.onDisconnect,
  });

  final DsEmuleServerStatus? status;
  final VoidCallback onConnectKad;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final s = status;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ED2K: ${s == null || s.ed2kStatus.isEmpty ? '—' : s.ed2kStatus}  ·  '
            'Kad: ${s == null || s.kadStatus.isEmpty ? '—' : s.kadStatus}',
            key: const Key('ds-emule-srv-status'),
          ),
          const SizedBox(height: Gap.sm),
          Row(
            children: [
              OutlinedButton(
                style: InlineButtonStyle.outlined,
                key: const Key('ds-emule-srv-kad'),
                onPressed: onConnectKad,
                child: Text(dataText('dsEmuleConnectKad', '连接 Kad')),
              ),
              const SizedBox(width: Gap.sm),
              OutlinedButton(
                style: InlineButtonStyle.outlined,
                key: const Key('ds-emule-srv-disconnect'),
                onPressed: onDisconnect,
                child: Text(dataText('dsEmuleDisconnect', '断开全部')),
              ),
            ],
          ),
          const Divider(),
        ],
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.index,
    required this.server,
    required this.selected,
    required this.onToggle,
    required this.onConnect,
    required this.onDelete,
  });

  final int index;
  final DsEmuleServer server;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onConnect;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final title = server.name.isEmpty ? server.ip : server.name;
    return DesignCheckRow(
      key: Key('ds-emule-srv-$index'),
      value: selected,
      onChanged: (_) => onToggle(),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${server.ip}:${server.port} · ${server.userCount}/${server.userMax}',
        maxLines: 1,
      ),
      secondary: PopupMenuButton<String>(
        key: Key('ds-emule-srv-menu-$index'),
        onSelected: (v) {
          if (v == 'connect') onConnect();
          if (v == 'delete') onDelete();
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'connect',
            child: Text(dataText('dsEmuleConnect', '连接')),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Text(dataText('dsDelete', '删除')),
          ),
        ],
      ),
    );
  }
}

/// 添加服务器（官方表单字段：`ip`（vtype ip）、`port`（vtype port）、可选 `name`）。
class _AddServerDialog extends ConsumerStatefulWidget {
  const _AddServerDialog();

  @override
  ConsumerState<_AddServerDialog> createState() => _AddServerDialogState();
}

class _AddServerDialogState extends ConsumerState<_AddServerDialog> {
  final _ip = TextEditingController();
  final _port = TextEditingController(text: '4661');
  final _name = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ip.dispose();
    _port.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final port = int.tryParse(_port.text.trim());
    if (_ip.text.trim().isEmpty || port == null) {
      setState(() => _error = dataText('dsEmuleServerRequired', '请填写 IP 与端口'));
      return;
    }
    setState(() => _error = null);
    try {
      await ref.read(downloadApiProvider)!.emuleAddServer(
        ip: _ip.text,
        port: port,
        name: _name.text,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = describeDownloadError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(dataText('dsEmuleAddServer', '添加服务器')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('ds-emule-srv-ip'),
            controller: _ip,
            decoration: InputDecoration(
              labelText: dataText('dsEmuleServerIp', 'IP / 主机名'),
            ),
          ),
          const SizedBox(height: Gap.sm),
          TextField(
            key: const Key('ds-emule-srv-port'),
            controller: _port,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: dataText('dsEmuleServerPort', '端口'),
            ),
          ),
          const SizedBox(height: Gap.sm),
          TextField(
            key: const Key('ds-emule-srv-name'),
            controller: _name,
            decoration: InputDecoration(
              labelText: dataText('dsEmuleServerName', '名称（可选）'),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: Gap.sm),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const Key('ds-emule-srv-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(dataText('dsCancel', '取消')),
        ),
        FilledButton(
          key: const Key('ds-emule-srv-save'),
          onPressed: _save,
          child: Text(dataText('dsSave', '保存')),
        ),
      ],
    );
  }
}
