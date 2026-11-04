// 226（M74）WebDAV 连接模式 —— **界面层**（只读：能力探测 + 列目录）。
//
// 协议/取证见 `webdav_client.dart` 顶部。本文件的边界：
//   * **不提供任何写操作**（上传/新建目录/删除/改名都没有按钮）——
//     协议层压根没实现那些动词；
//   * 官方在 DSM ≥ 7 上把此模式标为废弃（`WebDavConnectionManager`：
//     `DEPRECATED_DSM_VERSION = 7`），页面**显式**把这件事告诉用户，
//     而不是假装它还是受支持路径。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/drive_entry_dto.dart' show driveHumanSize;
import 'file_providers.dart' show fileApiProvider;
import 'file_row.dart' show formatFileTime;
import 'filestation_webdav_text.dart';
import 'webdav_client.dart';

/// 生产传输实现（`dio`）。测试用假实现覆盖 → **不联网**。
final webDavTransportProvider = Provider<WebDavTransport>(
  (ref) => DioWebDavTransport(),
);

/// 从当前会话推导出的默认连接坐标（未连接时 `null`）。
///
/// ⚠️ 会话**不保存口令**（`DsmWebApi.login` 收下 `password` 后不落任何字段），
/// 所以密码永远要用户自己填；这里只预填地址/端口/账号。
final webDavTargetDefaultsProvider = Provider<WebDavTarget?>((ref) {
  final fs = ref.watch(fileApiProvider);
  if (fs == null) return null;
  final uri = Uri.tryParse(fs.api.baseUrl);
  if (uri == null || uri.host.isEmpty) return null;
  return WebDavTarget(
    host: uri.host,
    // 官方 WebDAV 默认端口：https → 5006 / http → 5005
    port: uri.hasPort ? uri.port : (uri.scheme == 'https' ? 5006 : 5005),
    secure: uri.scheme == 'https',
    username: fs.api.session?.account ?? '',
  );
});

class WebDavPage extends ConsumerStatefulWidget {
  const WebDavPage({super.key});

  @override
  ConsumerState<WebDavPage> createState() => _WebDavPageState();
}

class _WebDavPageState extends ConsumerState<WebDavPage> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _account;
  late final TextEditingController _password;
  bool _secure = true;

  bool _busy = false;
  String? _errorKey; // 命中 key 时用本地化文案
  String? _errorRaw; // 其余情况直接显示（含 WebDavException 的码）
  bool _connected = false;
  WebDavCapabilities? _caps;
  WebDavVersion? _version;
  List<WebDavEntry> _entries = const [];
  String _cwd = '/';

  @override
  void initState() {
    super.initState();
    final d = ref.read(webDavTargetDefaultsProvider);
    _host = TextEditingController(text: d?.host ?? '');
    _port = TextEditingController(text: '${d?.port ?? 5006}');
    _account = TextEditingController(text: d?.username ?? '');
    _password = TextEditingController();
    _secure = d?.secure ?? true;
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _account.dispose();
    _password.dispose();
    super.dispose();
  }

  WebDavTarget _target() => WebDavTarget(
    host: _host.text.trim(),
    port: int.tryParse(_port.text.trim()) ?? (_secure ? 5006 : 5005),
    secure: _secure,
    username: _account.text.trim(),
    password: _password.text,
  );

  Future<void> _connect() async {
    if (_host.text.trim().isEmpty) {
      setState(() {
        _errorKey = FsWebDavTextKeys.missingHost;
        _errorRaw = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _errorKey = null;
      _errorRaw = null;
    });
    final client = WebDavClient(
      target: _target(),
      transport: ref.read(webDavTransportProvider),
    );
    try {
      final caps = await client.options();
      final version = await client.version();
      final entries = await client.listChildren('/');
      if (!mounted) return;
      setState(() {
        _caps = caps;
        _version = version;
        _entries = entries;
        _cwd = '/';
        _connected = true;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _connected = false;
        _errorRaw = e is WebDavException
            ? '${e.method} ${e.path} → HTTP ${e.statusCode}'
            : '$e';
      });
    }
  }

  Future<void> _open(String path) async {
    setState(() {
      _busy = true;
      _errorRaw = null;
      _errorKey = null;
    });
    final client = WebDavClient(
      target: _target(),
      transport: ref.read(webDavTransportProvider),
    );
    try {
      final entries = await client.listChildren(path);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _cwd = path;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorRaw = e is WebDavException
            ? '${e.method} ${e.path} → HTTP ${e.statusCode}'
            : '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final deprecated = _version?.isDeprecatedBySynology ?? false;
    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            key: const Key('fs-webdav-page'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, 0),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: t.calBack,
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Text(
                        fsWebDav(FsWebDavTextKeys.title, 'WebDAV 连接'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (_connected)
                      IconButton(
                        key: const Key('fs-webdav-up'),
                        tooltip: fsWebDav(FsWebDavTextKeys.up, '上一级'),
                        icon: const Icon(Icons.arrow_upward),
                        onPressed: _cwd == '/' || _busy
                            ? null
                            : () => _open(_parentOf(_cwd)),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(Gap.md),
                  children: [
                    _form(context),
                    if (deprecated) ...[
                      const SizedBox(height: Gap.sm),
                      _banner(
                        key: const Key('fs-webdav-deprecated'),
                        icon: Icons.warning_amber_outlined,
                        color: hud.danger,
                        text: fsWebDav(
                          FsWebDavTextKeys.deprecated,
                          '官方 DS file 在 DSM 7 起已把 WebDAV 模式标为废弃'
                              '（WebDavConnectionManager: DEPRECATED_DSM_VERSION = 7）。'
                              '它仍然能连，但已不是官方支持的路径。',
                        ),
                      ),
                    ],
                    const SizedBox(height: Gap.sm),
                    _banner(
                      key: const Key('fs-webdav-readonly'),
                      icon: Icons.lock_outline,
                      color: hud.dim,
                      text: fsWebDav(
                        FsWebDavTextKeys.readOnly,
                        '当前只实现读取（OPTIONS / PROPFIND 列目录）；'
                            '上传、新建目录、删除、改名等写操作尚未实现。',
                      ),
                    ),
                    if (_busy) ...[
                      const SizedBox(height: Gap.md),
                      const Center(child: CircularProgressIndicator()),
                    ],
                    if (_errorKey != null || _errorRaw != null) ...[
                      const SizedBox(height: Gap.md),
                      Text(
                        key: const Key('fs-webdav-error'),
                        _errorKey != null
                            ? fsWebDav(
                                _errorKey!,
                                '请填写主机地址（IP 或域名）',
                              )
                            : fsWebDavFill(
                                FsWebDavTextKeys.error,
                                '连接失败：{error}',
                                {'error': _errorRaw ?? ''},
                              ),
                        style: Theme.of(
                          context,
                        ).textTheme.bodyMedium?.copyWith(color: hud.danger),
                      ),
                    ],
                    if (_connected && _caps != null) ...[
                      const SizedBox(height: Gap.md),
                      Text(
                        key: const Key('fs-webdav-capability'),
                        fsWebDavFill(
                          FsWebDavTextKeys.capability,
                          'DAV：{dav} · 支持：{allow}',
                          {
                            'dav': _caps!.dav.isEmpty ? '—' : _caps!.dav,
                            'allow': _caps!.allow.isEmpty
                                ? '—'
                                : _caps!.allow.join(', '),
                          },
                        ),
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: hud.dim),
                      ),
                      const SizedBox(height: Gap.sm),
                      Text(
                        key: const Key('fs-webdav-path'),
                        fsWebDavFill(
                          FsWebDavTextKeys.path,
                          '当前位置：{path}',
                          {'path': _cwd},
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: Gap.sm),
                      if (_entries.isEmpty)
                        AppEmptyState(
                          key: const Key('fs-webdav-empty'),
                          icon: Icons.folder_open_outlined,
                          title: fsWebDav(
                            FsWebDavTextKeys.empty,
                            '这个目录是空的',
                          ),
                          message: fsWebDav(
                            FsWebDavTextKeys.emptyBody,
                            '服务端连上了，但目录里没有任何条目。',
                          ),
                        )
                      else
                        Material(
                          type: MaterialType.transparency,
                          child: Column(
                            key: const Key('fs-webdav-list'),
                            children: [
                              for (final e in _entries)
                                DesignRowTile(
                                  key: Key('fs-webdav-entry-${e.path}'),
                                  leading: Icon(
                                    e.isCollection
                                        ? Icons.folder_outlined
                                        : Icons.insert_drive_file_outlined,
                                  ),
                                  title: Text(e.name),
                                  subtitle: Text(
                                    [
                                      if (!e.isCollection && e.size > 0)
                                        driveHumanSize(e.size),
                                      if (e.lastModified != null)
                                        formatFileTime(
                                          e.lastModified!
                                              .millisecondsSinceEpoch ~/
                                              1000,
                                          t: context.t,
                                        ),
                                    ].join(' · '),
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(color: hud.dim),
                                  ),
                                  trailing: e.isCollection
                                      ? const Icon(Icons.chevron_right)
                                      : null,
                                  onTap: e.isCollection && !_busy
                                      ? () => _open(e.path)
                                      : null,
                                ),
                            ],
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
    );
  }

  Widget _form(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          fsWebDav(
            FsWebDavTextKeys.entryDescription,
            '用 WebDAV 协议连接 NAS（官方 DS file 的另一条传输路径）',
          ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: Gap.sm),
        TextField(
          key: const Key('fs-webdav-host'),
          controller: _host,
          decoration: InputDecoration(
            labelText: fsWebDav(FsWebDavTextKeys.host, '主机'),
            hintText: fsWebDav(
              FsWebDavTextKeys.hostHint,
              'NAS 的 IP 或域名',
            ),
          ),
        ),
        const SizedBox(height: Gap.sm),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('fs-webdav-port'),
                controller: _port,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: fsWebDav(FsWebDavTextKeys.port, '端口'),
                ),
              ),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              // 用 Row+Switch 而不是 SwitchListTile：`SwitchListTile` 也是
              // `ListTile`，会被 `FieldBackdrop` 夹的 `ColoredBox` 触发
              // "ink splashes may be invisible" 的 debug 断言（仓库既有教训）。
              child: Row(
                key: const Key('fs-webdav-secure'),
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fsWebDav(FsWebDavTextKeys.secure, 'HTTPS'),
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        Text(
                          fsWebDav(
                            FsWebDavTextKeys.secureHint,
                            'https 端口通常是 5006',
                          ),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _secure,
                    onChanged: (v) => setState(() => _secure = v),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.sm),
        TextField(
          key: const Key('fs-webdav-account'),
          controller: _account,
          decoration: InputDecoration(
            labelText: fsWebDav(FsWebDavTextKeys.account, '账号'),
          ),
        ),
        const SizedBox(height: Gap.sm),
        TextField(
          key: const Key('fs-webdav-password'),
          controller: _password,
          obscureText: true,
          decoration: InputDecoration(
            labelText: fsWebDav(FsWebDavTextKeys.password, '密码'),
          ),
        ),
        const SizedBox(height: Gap.md),
        FilledButton.icon(
          key: const Key('fs-webdav-connect'),
          icon: const Icon(Icons.cloud_outlined, size: 18),
          label: Text(
            _busy
                ? fsWebDav(FsWebDavTextKeys.connecting, '正在连接…')
                : fsWebDav(FsWebDavTextKeys.connect, '连接'),
          ),
          onPressed: _busy ? null : _connect,
        ),
      ],
    );
  }

  Widget _banner({
    required Key key,
    required IconData icon,
    required Color color,
    required String text,
  }) {
    return Row(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: Gap.xs),
        Expanded(
          child: Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }

  static String _parentOf(String path) {
    final trimmed = path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
    final i = trimmed.lastIndexOf('/');
    if (i <= 0) return '/';
    return trimmed.substring(0, i);
  }
}
