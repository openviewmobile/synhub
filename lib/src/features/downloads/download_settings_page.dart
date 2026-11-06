// Download Station 设置页。
//
// 只有普通用户**可读可写/可读**的东西在这里：
//   * F9 自动解压：`Settings.AutoExtraction`（v1，normal，可读可写）；
//   * F14 套件信息/模块/能力位：`Package.Info|Module|Service`（v2，normal，只读）
//     —— 用于**能力探测**（`enable_bt_preview` / `enable_unzip` 等），比硬编码可靠；
//   * F12 完成提醒开关（纯本地）。
//
// 全局限速 / Scheduler / BTSearch / FileHosting 等 `Settings.*` 是 admin-only
// （`docs/download-api-live.md:37/50`），**不做**、也不给假入口。
//
// 权威事实：
//   * `docs/download-api-live.md:31`：`Settings.AutoExtraction:get` v1 实调 OK
//     （回 `create_subfolder`/`delete_archive`/`enable_unzip`…），普通用户；
//   * F14 真机只读实调（2026-09-22）：
//     `Package.Info.get` → `{major:4,minor:1,build_number:5012,is_manager:false}`；
//     `Package.Module.list` → `listItems`（BT + eMule 两项）；
//     `Package.Service.get` → `{enable_bt_preview:true,enable_emule:true,
//                              enable_unzip:false,is_unzip_service_enable:false}`。
import 'package:flutter/material.dart';
import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../core/i18n/l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/hud_widgets.dart';
import '../../data/download_station.dart';
import '../../data/dto/download_task_dto.dart';
import 'download_completion.dart';
import 'download_labels.dart';
import 'download_providers.dart';

class DownloadSettingsPage extends ConsumerWidget {
  const DownloadSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(downloadApiProvider);
    final unsupported =
        api != null && !api.hasApi(DownloadStationApi.apiAutoExtraction);
    return DesignScaffold(
      appBar: AppBar(title: Text(dataText('dsSettings', '下载设置'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Gap.xxl),
        children: [
          if (unsupported)
            AppEmptyState(
              key: const Key('ds-settings-unsupported'),
              icon: Icons.extension_off_outlined,
              title: dataText(
                'dsAutoExtractionUnsupported',
                '这台 NAS 的 Download Station 不支持自动解压设置',
              ),
            )
          else
            const _AutoExtraction(),
          const SizedBox(height: Gap.md),
          // F14：套件版本 / 模块 / 能力位（只读）。
          const _PackageSection(),
          const SizedBox(height: Gap.md),
          // F12：完成提醒开关（纯本地）。
          const _NotifyToggle(),
        ],
      ),
    );
  }
}

/// 自动解压开关（`Settings.AutoExtraction.get|set` v1）。
class _AutoExtraction extends ConsumerWidget {
  const _AutoExtraction();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(downloadAutoExtractionProvider);
    return settings.when(
      // 注意：本页外层已经是 ListView —— 这里**不能**再放一个 ListView
      // （嵌套滚动 → "Vertical viewport was given unbounded height"）。
      loading: () => const Padding(
        padding: EdgeInsets.all(Gap.lg),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => AppErrorView(
        title: dataText('dsSettingsLoadFailed', '设置加载失败'),
        detail: describeDownloadError(e),
        onRetry: () => ref.invalidate(downloadAutoExtractionProvider),
      ),
      data: (s) => _AutoExtractionTile(settings: s),
    );
  }
}

class _AutoExtractionTile extends ConsumerStatefulWidget {
  const _AutoExtractionTile({required this.settings});

  final DownloadAutoExtractionSettings settings;

  @override
  ConsumerState<_AutoExtractionTile> createState() =>
      _AutoExtractionTileState();
}

/// 自动解压的**全部 6 个可写字段**（G-r408-01 收口，r410）。
///
/// 契约逐字取自官方 4.1.2 `ui/download.js`（`Settings.GlobalUnzip`，
/// **普通用户**那份 `personal_fieldset`；admin 那份是 `enable_unzip_service`，
/// 本客户端不下发）：
///
/// | 字段 | 官方控件 | 值域 |
/// |---|---|---|
/// | `enable_unzip` | checkbox（总开关） | bool |
/// | `unzip_location` | radio ×2 | `current_folder` / `select_folder` |
/// | `unzip_to_path` | 只读 textfield + 文件夹选择按钮 | 路径串（`allowBlank:false`） |
/// | `create_subfolder` | checkbox | bool |
/// | `unzip_overwrite` | checkbox | bool |
/// | `delete_archive` | checkbox | bool |
///
/// 官方 `enableUnzipFields()` 的**依赖关系**也照抄：`enable_unzip` 关掉时，
/// 位置/路径/三个勾选**全部 disabled**。
/// 官方 `unzip_to_path` 是"只读 + 选择器"；本客户端没有服务端目录选择器
/// （与 `download_create_page.dart` 的 `destination` 同款做法）⇒ 用**可编辑**
/// 文本框 + 保存按钮：能力上**不比官方少**，不编一个假的选择器。
///
/// ★ 写动词纪律：每个控件**只发自己那个脏字段**（官方 `getDirtyFieldValues`）。
/// ★ DA34（r387）教训保留：保存后 `AutoExtraction` 与 `Package.Service` 两个
/// provider **一起失效**，否则页面上"开关=关"与"Auto extract ✓"自相矛盾。
class _AutoExtractionTileState extends ConsumerState<_AutoExtractionTile> {
  bool _saving = false;
  bool? _pendingEnable;
  String? _pendingLocation;

  /// 路径框（官方 `unzip_to_path`）。用户改过之后**不再**被服务端回读覆盖，
  /// 免得刚输入一半就被刷新冲掉。
  final TextEditingController _path = TextEditingController();
  bool _pathDirty = false;

  static const String _kCurrent = 'current_folder';
  static const String _kSelect = 'select_folder';

  @override
  void initState() {
    super.initState();
    _path.text = widget.settings.unzipToPath;
  }

  @override
  void didUpdateWidget(_AutoExtractionTile old) {
    super.didUpdateWidget(old);
    if (!_pathDirty && widget.settings.unzipToPath != _path.text) {
      // 服务端真值变了（保存后 invalidate 回读）⇒ 没脏就同步。
      _path.text = widget.settings.unzipToPath;
    }
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final meta = DesignPalette.of(context).dim;
    final enable = _pendingEnable ?? widget.settings.enableUnzip;
    final location = _pendingLocation ?? widget.settings.unzipLocation;
    // 官方依赖关系：总开关关 ⇒ 其余控件全 disabled。
    final subEnabled = enable && !_saving;
    final isSelect = location == _kSelect;
    // 官方两个 radio 值之外的**未知值**：原样单列一档，绝不静默改写
    // （§2.0.47：不编名字，也不许把真值丢掉）。
    final unknown = location.isNotEmpty &&
        location != _kCurrent &&
        location != _kSelect;
    return _SettingsPanel(
      title: dataText('dsAutoExtraction', '自动解压'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // `SwitchListTile` 必须在 Material 上画水波：外层是带背景色的
          // DecoratedBox 时 Flutter 会报 "ink splashes may be invisible"。
          Material(
            color: Colors.transparent,
            child: DesignSwitchRow(
              key: const Key('ds-auto-extract'),
              contentPadding: EdgeInsets.zero,
              title: Text(dataText('dsAutoExtraction', '自动解压')),
              subtitle: Text(
                dataText(
                  'dsAutoExtractionHint',
                  '下载完成后自动解压压缩文件（服务端设置）',
                ),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: meta,
                ),
              ),
              value: enable,
              onChanged: _saving ? null : _setEnable,
            ),
          ),
          // ---- unzip_location（官方 radio ×2 + 未知值原样一档）----
          Text(
            dataText('dsUnzipLocation', '解压位置'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: meta,
            ),
          ),
          _locationRadio(
            key: 'ds-unzip-loc-current',
            value: _kCurrent,
            label: dsUnzipLocationLabel(context.t, _kCurrent),
            group: location,
            enabled: subEnabled,
          ),
          _locationRadio(
            key: 'ds-unzip-loc-select',
            value: _kSelect,
            label: dsUnzipLocationLabel(context.t, _kSelect),
            group: location,
            enabled: subEnabled,
          ),
          if (unknown)
            _locationRadio(
              key: 'ds-unzip-loc-unknown',
              value: location,
              label: dsUnzipLocationLabel(context.t, location),
              group: location,
              enabled: subEnabled,
            ),
          // ---- unzip_to_path（仅"指定文件夹"时有意义）----
          Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('ds-unzip-path'),
                      controller: _path,
                      // 官方：两个 radio 与路径行**一直画着**，只有选到
                      // `select_folder` 且总开关开着时才可用。
                      enabled: subEnabled && isSelect,
                      decoration: InputDecoration(
                        labelText: dataText('dsUnzipToPath', '指定文件夹路径'),
                        hintText: dataText(
                          'dsUnzipToPathHint',
                          '例如 /volume1/downloads',
                        ),
                      ),
                      onChanged: (_) => _pathDirty = true,
                      onSubmitted: (_) => _savePath(),
                    ),
                  ),
                  IconButton(
                    key: const Key('ds-unzip-path-save'),
                    tooltip: dataText('dsUnzipToPathSave', '保存路径'),
                    onPressed: subEnabled && isSelect ? _savePath : null,
                    icon: const Icon(Icons.check),
                  ),
                ],
              ),
            ),
          // ---- 三个勾选（create_subfolder / unzip_overwrite / delete_archive）
          _boolRow(
            key: 'ds-unzip-subfolder',
            label: dataText('dsUnzipCreateSubfolder', '解压后创建子文件夹'),
            value: widget.settings.createSubfolder,
            enabled: subEnabled,
            onChanged: (v) => _save(createSubfolder: v),
          ),
          _boolRow(
            key: 'ds-unzip-overwrite',
            label: dataText('dsUnzipOverwrite', '覆盖同名文件'),
            value: widget.settings.unzipOverwrite,
            enabled: subEnabled,
            onChanged: (v) => _save(unzipOverwrite: v),
          ),
          _boolRow(
            key: 'ds-unzip-delete-archive',
            label: dataText('dsUnzipDeleteArchive', '解压完成后删除压缩包'),
            value: widget.settings.deleteArchive,
            enabled: subEnabled,
            onChanged: (v) => _save(deleteArchive: v),
          ),
        ],
      ),
    );
  }

  Widget _locationRadio({
    required String key,
    required String value,
    required String label,
    required String group,
    required bool enabled,
  }) {
    return Material(
      color: Colors.transparent,
      child: RadioListTile<String>(
        key: Key(key),
        contentPadding: EdgeInsets.zero,
        dense: true,
        value: value,
        // ignore: deprecated_member_use
        groupValue: group,
        // ignore: deprecated_member_use
        onChanged: enabled ? (v) => _setLocation(v) : null,
        title: Text(label),
      ),
    );
  }

  Widget _boolRow({
    required String key,
    required String label,
    required bool value,
    required bool enabled,
    required ValueChanged<bool> onChanged,
  }) {
    return Material(
      color: Colors.transparent,
      child: DesignSwitchRow(
        key: Key(key),
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(label),
        value: value,
        onChanged: enabled ? onChanged : null,
      ),
    );
  }

  Future<void> _setEnable(bool next) async {
    setState(() {
      _saving = true;
      _pendingEnable = next;
    });
    await _save(enableUnzip: next);
    if (mounted) setState(() => _pendingEnable = null);
  }

  Future<void> _setLocation(String? next) async {
    if (next == null || next == widget.settings.unzipLocation) return;
    // 官方表单 `unzip_to_path` 是 `allowBlank:false`：切到"指定文件夹"但
    // 路径还空着时**不发**这次写（否则服务端必拒），只提示用户先填。
    if (next == _kSelect && _path.text.trim().isEmpty) {
      // 官方 `unzip_to_path` 是 `allowBlank:false` ⇒ 现在发过去必被拒。
      // 官方本身的 radio **是可以先勾上的**（表单提交时才校验）⇒ 这里也
      // 本地先切过去 + 提示，等路径填好点保存时**两个字段一起发**。
      setState(() => _pendingLocation = next);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            dataText('dsUnzipNeedPath', '请先填写目标文件夹路径'),
          ),
        ),
      );
      return;
    }
    setState(() {
      _saving = true;
      _pendingLocation = next;
    });
    // ★ DA65：服务端收的是**布尔**（`true` = 用下载文件夹）。
    await _save(unzipLocationToCurrentFolder: next == _kCurrent);
    if (mounted) setState(() => _pendingLocation = null);
  }

  Future<void> _savePath() async {
    final path = _path.text.trim();
    if (path.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            dataText('dsUnzipNeedPath', '请先填写目标文件夹路径'),
          ),
        ),
      );
      return;
    }
    setState(() => _saving = true);
    // 官方一次表单提交会同时带 `unzip_location` 与 `unzip_to_path`
    // ⇒ 本地已切到"指定文件夹"但还没发出去时，这里一并发。
    // `true` = 用下载文件夹 ⇒ 本地切到"指定文件夹"时是 **false**。
    final pendingLoc = _pendingLocation == _kSelect ? false : null;
    await _save(unzipToPath: path, unzipLocationToCurrentFolder: pendingLoc);
    if (mounted) setState(() => _pathDirty = false);
  }

  /// 只发**脏字段**（官方 `getDirtyFieldValues`）：本次没改的一律不下发。
  Future<void> _save({
    bool? enableUnzip,
    bool? unzipLocationToCurrentFolder,
    String? unzipToPath,
    bool? createSubfolder,
    bool? deleteArchive,
    bool? unzipOverwrite,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await ref.read(downloadActionsProvider).setAutoExtraction(
            enableUnzip: enableUnzip,
            unzipLocationToCurrentFolder: unzipLocationToCurrentFolder,
            unzipToPath: unzipToPath,
            createSubfolder: createSubfolder,
            deleteArchive: deleteArchive,
            unzipOverwrite: unzipOverwrite,
          );
      ref.invalidate(downloadAutoExtractionProvider);
      // ★ DA34（r387 **真机撞到**）：同一页上「Auto extract ✓/✗」能力位来自
      //   **另一个** provider（`Package.Service.get` 的 `enable_unzip`），
      //   而它读的是**同一个服务端事实**。只失效上面那个 → 保存后页面上
      //   同时显示"开关=关"与"Auto extract ✓"（自相矛盾，真机读数见
      //   `docs/evidence-r387/w3_14.xml`）。⇒ 一起失效，让两个读数同源同帧。
      ref.invalidate(downloadPackageServiceProvider);
      messenger.showSnackBar(
        SnackBar(
          content: Text(dataText('dsAutoExtractionSaved', '自动解压设置已保存')),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            dataText(
              'dsSettingsSaveFailed',
              '保存失败：{msg}',
            ).replaceAll('{msg}', describeDownloadError(e)),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// 套件版本 / 模块 / 能力位（F14，`Package.*` v2，只读）。
///
/// 三个 API 都从能力表探测：都没有 → 整块不显示（老 DS 不报错）。
class _PackageSection extends ConsumerWidget {
  const _PackageSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(downloadApiProvider);
    final hasAny =
        api != null &&
        (api.hasApi(DownloadStationApi.apiPkgInfo) ||
            api.hasApi(DownloadStationApi.apiPkgModule) ||
            api.hasApi(DownloadStationApi.apiPkgService));
    if (!hasAny) return const SizedBox.shrink();
    final info = ref.watch(downloadPackageInfoProvider);
    final modules = ref.watch(downloadPackageModulesProvider);
    final service = ref.watch(downloadPackageServiceProvider);
    final meta = DesignPalette.of(context).dim;
    return _SettingsPanel(
      title: dataText('dsPackageInfo', 'Download Station 套件信息'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            info.when(
              loading: () => dataText('dsLoading', '加载中…'),
              error: (e, _) => describeDownloadError(e),
              data: (v) => v == null || v.versionString.isEmpty
                  ? dataText('dsVersionUnknown', '版本未知')
                  : '${dataText('dsVersion', '版本')} ${v.versionString}',
            ),
            key: const Key('ds-package-version'),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: Gap.sm),
          Text(
            modules.when(
              loading: () => '',
              error: (e, _) => '',
              data: (list) => list.isEmpty
                  ? ''
                  : context.t.dsModulesLine(list.map(_moduleLabel).join(' · ')),
            ),
            key: const Key('ds-package-modules'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: meta,
            ),
          ),
          const SizedBox(height: Gap.sm),
          service.when(
            loading: () => const SizedBox.shrink(),
            error: (e, _) => const SizedBox.shrink(),
            data: (s) => s == null
                ? const SizedBox.shrink()
                : Wrap(
                    key: const Key('ds-package-capabilities'),
                    spacing: Gap.sm,
                    runSpacing: Gap.xs,
                    children: [
                      _capability(
                        'bt_preview',
                        dataText('dsCapBtPreview', 'BT 预览'),
                        s.enableBtPreview,
                      ),
                      _capability(
                        'emule',
                        dataText('dsCapEmule', 'eMule'),
                        s.enableEmule,
                      ),
                      _capability(
                        'unzip',
                        dataText('dsCapUnzip', '自动解压'),
                        s.enableUnzip,
                      ),
                      _capability(
                        'unzip_service',
                        dataText('dsCapUnzipService', '解压服务'),
                        s.isUnzipServiceEnable,
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _capability(String id, String label, bool on) {
    return TelemetryLabel(
      '$label ${on ? '✓' : '✗'}',
      key: Key('ds-cap-$id'),
    );
  }

  /// 官方模块 `folder` → 可读名（`dlm`=BT、`aMule`=eMule；其余原样）。
  static String _moduleLabel(DsPackageModule m) => switch (m.folder) {
    'dlm' => 'BT',
    'aMule' => 'eMule',
    _ => m.folder.isEmpty ? m.fn : m.folder,
  };
}

/// 完成提醒开关（F12，纯本地）。
class _NotifyToggle extends ConsumerStatefulWidget {
  const _NotifyToggle();

  @override
  ConsumerState<_NotifyToggle> createState() => _NotifyToggleState();
}

class _NotifyToggleState extends ConsumerState<_NotifyToggle> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(downloadNotifyProvider.notifier).preload();
    });
  }

  @override
  Widget build(BuildContext context) {
    final on = ref.watch(downloadNotifyProvider);
    return _SettingsPanel(
      title: dataText('dsNotify', '任务完成提醒'),
      child: Material(
        color: Colors.transparent,
        child: DesignSwitchRow(
          key: const Key('ds-notify-complete'),
          contentPadding: EdgeInsets.zero,
          title: Text(dataText('dsNotifyComplete', '任务完成时提醒')),
          subtitle: Text(
            dataText(
              'dsNotifyCompleteHint',
              '任务下载完成或失败时在应用内提示（服务端没有完成事件推送，由客户端轮询检测）',
            ),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: DesignPalette.of(context).dim,
            ),
          ),
          value: on,
          onChanged: (v) => ref.read(downloadNotifyProvider.notifier).set(v),
        ),
      ),
    );
  }
}

/// 统一的设置面板外壳（与自动解压那张卡同款视觉）。
class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
      child: Container(
        padding: const EdgeInsets.all(Gap.lg),
        decoration: BoxDecoration(
          color: DesignPalette.of(context).surface,
          borderRadius: BorderRadius.circular(Radii.pane),
          border: Border.all(color: DesignPalette.of(context).line.withValues(alpha: 0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TelemetryLabel(title, uppercase: false),
            const SizedBox(height: Gap.sm),
            child,
          ],
        ),
      ),
    );
  }
}
