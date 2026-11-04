// 云端大模型的配置面板（AI 服务页里"云端大模型"这一档）。
//
// 交互抄的是业界通行做法（Cherry Studio / Open WebUI / LobeChat 那一类）：
//   1. 先选**厂商预设**（自动带出 base URL 与协议），或者选"自定义/中转"；
//   2. 填 **API Key** —— 立刻写进系统安全存储，界面上只显示打码值；
//   3. **点一下就拉模型列表**（`GET /models`），拉不到就手填 + 常见模型点选；
//   4. **测试连接**（一条极短的非流式请求），把 401/404/超时这些说成人话；
//   5. 高级参数（温度、最大输出）折叠起来，不挡主流程。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/ai/cloud_llm_client.dart';
import '../../data/ai/cloud_profile.dart';
import '../../data/ai/cloud_provider.dart';
import 'cloud_settings.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';

class AiCloudPanel extends ConsumerStatefulWidget {
  const AiCloudPanel({super.key});

  @override
  ConsumerState<AiCloudPanel> createState() => _AiCloudPanelState();
}

class _AiCloudPanelState extends ConsumerState<AiCloudPanel> {
  late final TextEditingController _base;
  late final TextEditingController _model;
  late final TextEditingController _key;
  bool _showKey = false;
  bool _advanced = false;
  String _lastProviderId = '';

  @override
  void initState() {
    super.initState();
    trackView(UsageModule.ai, screen: 'cloud_settings');
    final s = ref.read(cloudSettingsProvider);
    _lastProviderId = s.providerId;
    _base = TextEditingController(text: s.baseUrl);
    _model = TextEditingController(text: s.model);
    _key = TextEditingController(text: s.apiKey);
  }

  @override
  void dispose() {
    _base.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final s = ref.watch(cloudSettingsProvider);
    final notifier = ref.read(cloudSettingsProvider.notifier);

    // 换了厂商：把输入框同步过来（预设地址/协议/该家的 key）
    if (s.providerId != _lastProviderId) {
      _lastProviderId = s.providerId;
      _base.text = s.baseUrl;
      _key.text = s.apiKey;
      _model.text = s.model;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 多套配置：一眼看出"现在用的是哪一套"，点一下就能切
        _profileTile(theme, hud, s, notifier),
        _gap(),
        _tile(
          theme,
          hud,
          icon: Icons.hub_outlined,
          title: s.providerId.isEmpty
              ? context.t.aiPickProvider
              : s.provider.nameText,
          body: s.providerId.isEmpty
              ? context.t.aiPickProviderHint
              : (s.provider.noteText.isEmpty
                    ? s.protocol.labelText
                    : '${s.protocol.labelText} · ${s.provider.noteText}'),
          onTap: _pickProvider,
          trailing: const Icon(Icons.chevron_right, size: 20),
        ),
        _gap(),
        _field(
          theme,
          hud,
          controller: _base,
          label: 'Base URL',
          hint: s.provider.baseUrl.isEmpty
              ? context.t.aiBaseUrlExample
              : s.provider.baseUrl,
          onChanged: notifier.setBaseUrl,
          suffix:
              s.provider.baseUrl.isNotEmpty && s.baseUrl != s.provider.baseUrl
              ? TextButton(
                  onPressed: () {
                    _base.text = s.provider.baseUrl;
                    notifier.setBaseUrl(s.provider.baseUrl);
                  },
                  child: Text(context.t.aiDefault),
                )
              : null,
        ),
        if (s.providerId.isNotEmpty && s.provider.isCustom) ...[
          _gap(),
          _protocolPicker(theme, hud, s, notifier),
        ],
        _gap(),
        _field(
          theme,
          hud,
          controller: _key,
          label: 'API Key',
          hint: s.provider.keyHintText.isEmpty
              ? context.t.aiKeyHintFallback
              : s.provider.keyHintText,
          obscure: !_showKey,
          onChanged: notifier.setKey,
          suffix: IconButton(
            tooltip: _showKey ? context.t.contactHide : context.t.aiShow,
            onPressed: () => setState(() => _showKey = !_showKey),
            icon: Icon(
              _showKey
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 18,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, 0),
          child: Row(
            children: [
              Icon(Icons.lock_outline, size: 13, color: hud.dim),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  s.provider.needsKey
                      ? context.t.aiKeyStored
                      : context.t.aiNoKeyCheck,
                  style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
                ),
              ),
              if (s.provider.docsUrl.isNotEmpty)
                Text(
                  context.t.aiWhereToGetKey,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
            ],
          ),
        ),
        if (s.provider.docsUrl.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, 2, Gap.md, 0),
            child: SelectableText(
              s.provider.docsUrl,
              style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
            ),
          ),
        _gap(),
        _field(
          theme,
          hud,
          controller: _model,
          label: context.t.aiModelLabel,
          hint: context.t.aiModelExample,
          onChanged: notifier.setModel,
          suffix: s.provider.supportsModelList
              ? IconButton(
                  tooltip: context.t.aiFetchModels,
                  onPressed: s.loading ? null : () => _fetchModels(),
                  icon: s.loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 18),
                )
              // 这家没有列表接口：不给一个点了就报错的按钮
              : Tooltip(
                  message: context.t.aiNoModelListInterface,
                  child: Padding(
                    padding: const EdgeInsets.only(right: Gap.sm),
                    child: Icon(Icons.edit_note, size: 18, color: hud.dim),
                  ),
                ),
        ),
        if (s.cachedModels.isNotEmpty) ...[
          const SizedBox(height: Gap.xs),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            child: Wrap(
              spacing: Gap.xs,
              runSpacing: 4,
              children: [
                for (final m in s.cachedModels.take(8))
                  ActionChip(
                    label: Text(m.id, style: theme.textTheme.labelSmall),
                    onPressed: () {
                      _model.text = m.id;
                      notifier.setModel(m.id);
                    },
                  ),
                if (s.cachedModels.length > 8)
                  ActionChip(
                    label: Text(
                      context.t.aiAllModels(s.cachedModels.length),
                      style: theme.textTheme.labelSmall,
                    ),
                    onPressed: _pickModel,
                  ),
              ],
            ),
          ),
        ] else if (s.provider.presetModels.isNotEmpty) ...[
          const SizedBox(height: Gap.xs),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            child: Wrap(
              spacing: Gap.xs,
              runSpacing: 4,
              children: [
                for (final id in s.provider.presetModels)
                  ActionChip(
                    label: Text(id, style: theme.textTheme.labelSmall),
                    onPressed: () {
                      _model.text = id;
                      notifier.setModel(id);
                    },
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, 2, Gap.md, 0),
            child: Text(
              context.t.aiCommonModels,
              style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
            ),
          ),
        ],
        if (s.error.isNotEmpty)
          _note(theme, hud, s.error, warn: true)
        else if (s.testResult.isNotEmpty)
          _note(theme, hud, s.testResult, warn: false),
        _gap(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.md),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: s.testing || !s.configured
                      ? null
                      : () => notifier.test(),
                  icon: s.testing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering, size: 18),
                  // `Expanded` 把宽度收紧了，英文（"Test connection"）在 1.0
                  // 缩放下就会把按钮内部的 Row 挤溢（实测 19px）→ 标签省略。
                  label: Text(
                    context.t.aiTestConnection,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: Gap.sm),
              // 「高级参数」是行内非 flex 子项，宽度**无界** → 大字号下溢出。
              Flexible(
                child: TextButton(
                  onPressed: () => setState(() => _advanced = !_advanced),
                  child: Text(
                    _advanced
                        ? context.t.aiCollapseAdvanced
                        : context.t.aiAdvancedParams,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_advanced) ...[
          _gap(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            child: Text(
              context.t.aiTemperature(s.temperature.toStringAsFixed(2)),
              style: theme.textTheme.bodySmall,
            ),
          ),
          Slider(
            value: s.temperature.clamp(0, 1.5),
            min: 0,
            max: 1.5,
            divisions: 30,
            onChanged: notifier.setTemperature,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    context.t.aiMaxOutputTokens,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                // 推理模型（真机实测 deepseek-v4.1-flash）会把 1024 个 token
                // 全花在思考上，所以档位必须给到 4096/8192；不够时引擎还会
                // 自动加大预算重试一次（见 cloud_engine.dart）
                for (final n in const [256, 512, 1024, 2048, 4096, 8192])
                  Padding(
                    padding: const EdgeInsets.only(left: Gap.xs),
                    child: ChoiceChip(
                      label: Text('$n', style: theme.textTheme.labelSmall),
                      selected: s.maxTokens == n,
                      onSelected: (_) => notifier.setMaxTokens(n),
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: Gap.md),
      ],
    );
  }

  // ---------------------------------------------------------------- 弹层

  Future<void> _pickProvider() async {
    final picked = await showModalBottomSheet<CloudProviderInfo>(
      context: context,
      backgroundColor: DesignPalette.of(context).bg,
      isScrollControlled: true,
      builder: (_) => const _ProviderSheet(),
    );
    if (picked == null || !mounted) return;
    await ref
        .read(cloudSettingsProvider.notifier)
        .selectProvider(picked.id, customProtocol: picked.protocol.id);
    if (!mounted) return;
    final s = ref.read(cloudSettingsProvider);
    setState(() {
      _lastProviderId = s.providerId;
      _base.text = s.baseUrl;
      _key.text = s.apiKey;
      _model.text = s.model;
    });
  }

  /// 打开"配置方案"弹层：多套并存 + 一键切换 / 另存 / 重命名 / 删除
  Future<void> _pickProfile() async {
    final s = ref.read(cloudSettingsProvider);
    final action = await showModalBottomSheet<_ProfileAction>(
      context: context,
      backgroundColor: DesignPalette.of(context).bg,
      isScrollControlled: true,
      builder: (_) => _ProfileSheet(settings: s),
    );
    if (action == null || !mounted) return;
    final notifier = ref.read(cloudSettingsProvider.notifier);
    switch (action.kind) {
      case _ProfileActionKind.switchTo:
        await notifier.switchProfile(action.id);
      case _ProfileActionKind.saveAs:
        final name = await _askProfileName(
          title: context.t.aiProfileSaveAs,
          initial: '',
        );
        if (name == null || !mounted) return;
        await notifier.saveProfileAsNew(name);
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        messenger.showSnackBar(
          SnackBar(content: Text(context.t.aiProfileSaved(name))),
        );
      case _ProfileActionKind.rename:
        final name = await _askProfileName(
          title: context.t.aiProfileRename,
          initial: action.name,
        );
        if (name == null || !mounted) return;
        await notifier.renameProfile(action.id, name);
      case _ProfileActionKind.delete:
        final ok = await _confirmDelete(action.name);
        if (!ok || !mounted) return;
        await notifier.deleteProfile(action.id);
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        messenger.showSnackBar(
          SnackBar(content: Text(context.t.aiProfileDeleted(action.name))),
        );
    }
    if (!mounted) return;
    final cur = ref.read(cloudSettingsProvider);
    setState(() {
      _lastProviderId = cur.providerId;
      _base.text = cur.baseUrl;
      _key.text = cur.apiKey;
      _model.text = cur.model;
    });
  }

  Future<String?> _askProfileName({
    required String title,
    required String initial,
  }) async {
    // ⚠️ 输入框控制器交给对话框**自己**持有：`showDialog` 的 Future 在退场
    // 动画开始前就返回了，在这里 `dispose()` 会被还在渲染的 TextField 用到
    // （"A TextEditingController was used after being disposed"）。
    final out = await showDialog<String>(
      context: context,
      builder: (_) => _ProfileNameDialog(title: title, initial: initial),
    );
    if (out == null) return null;
    return out.trim().isEmpty ? title : out.trim();
  }

  Future<bool> _confirmDelete(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.t.aiProfileDelete),
        content: Text(ctx.t.aiProfileDeleteConfirm(name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(ctx.t.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(ctx.t.dtoActionDelete),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _fetchModels() async {
    await ref.read(cloudSettingsProvider.notifier).refreshModels();
    if (!mounted) return;
    final s = ref.read(cloudSettingsProvider);
    if (s.cachedModels.isNotEmpty) await _pickModel();
  }

  Future<void> _pickModel() async {
    final s = ref.read(cloudSettingsProvider);
    final picked = await showModalBottomSheet<CloudModelInfo>(
      context: context,
      backgroundColor: DesignPalette.of(context).bg,
      isScrollControlled: true,
      builder: (_) => _ModelSheet(models: s.cachedModels),
    );
    if (picked == null || !mounted) return;
    _model.text = picked.id;
    await ref.read(cloudSettingsProvider.notifier).setModel(picked.id);
  }

  // ---------------------------------------------------------------- 小组件

  Widget _gap() => const SizedBox(height: Gap.sm);

  /// 当前配置一览 + 一键切换入口（多套配置并存）
  Widget _profileTile(
    ThemeData theme,
    DesignPalette hud,
    CloudSettings s,
    CloudSettingsNotifier notifier,
  ) {
    final active = s.activeProfile;
    final label = active == null
        ? context.t.aiProfileNone
        : notifier.profileLabel(active, context.t);
    final sub = <String>[
      if (s.providerId.isNotEmpty) s.provider.nameText,
      if (s.model.trim().isNotEmpty) s.model.trim(),
      if (s.profiles.length > 1) context.t.aiProfileCount(s.profiles.length),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
      child: Material(
        color: hud.surface2,
        borderRadius: BorderRadius.circular(12),
        child: DesignRowTile(
          onTap: _pickProfile,
          leading: Icon(
            Icons.layers_outlined,
            size: 20,
            color: theme.colorScheme.primary,
          ),
          title: Row(
            children: [
              Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
              Text(
                context.t.aiProfileSwitch,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
          subtitle: Text(
            sub.isEmpty ? context.t.aiProfileSaveAsHint : sub,
            style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
          ),
        ),
      ),
    );
  }

  Widget _field(
    ThemeData theme,
    DesignPalette hud, {
    required TextEditingController controller,
    required String label,
    required String hint,
    required ValueChanged<String> onChanged,
    bool obscure = false,
    Widget? suffix,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: false,
        onChanged: onChanged,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          filled: true,
          fillColor: hud.surface2,
          suffixIcon: suffix,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: hud.line),
          ),
        ),
      ),
    );
  }

  Widget _protocolPicker(
    ThemeData theme,
    DesignPalette hud,
    CloudSettings s,
    CloudSettingsNotifier notifier,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
      child: Row(
        children: [
          Text(context.t.aiProtocol, style: theme.textTheme.bodySmall),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: SegmentedButton<String>(
              segments: [
                for (final p in CloudProtocol.values)
                  ButtonSegment(value: p.id, label: Text(p.labelText)),
              ],
              selected: {s.protocolId},
              onSelectionChanged: (v) => notifier.setProtocol(v.first),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(
    ThemeData theme,
    DesignPalette hud, {
    required IconData icon,
    required String title,
    required String body,
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
      child: Material(
        color: hud.surface,
        borderRadius: BorderRadius.circular(12),
        child: DesignRowTile(
          onTap: onTap,
          leading: Icon(icon, size: 20, color: theme.colorScheme.primary),
          title: Text(title, style: theme.textTheme.bodyMedium),
          subtitle: Text(
            body,
            style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
          ),
          trailing: trailing,
        ),
      ),
    );
  }

  Widget _note(
    ThemeData theme,
    DesignPalette hud,
    String text, {
    required bool warn,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            warn ? Icons.error_outline : Icons.check_circle_outline,
            size: 15,
            color: warn ? theme.colorScheme.error : theme.colorScheme.primary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: warn ? theme.colorScheme.error : hud.dim,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 厂商选择弹层：分三段（国外 / 国内 / 自建与自定义）
class _ProviderSheet extends StatelessWidget {
  const _ProviderSheet();

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    const remote = {'openai', 'anthropic', 'gemini'};
    const local = {'ollama', 'lmstudio', 'vllm'};
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: Gap.sm),
          children: [
            for (final (title, items) in [
              (
                context.t.aiIntlService,
                kCloudProviders.where((p) => remote.contains(p.id)),
              ),
              (
                context.t.aiChinaService,
                kCloudProviders.where(
                  (p) => !remote.contains(p.id) && !local.contains(p.id),
                ),
              ),
              (
                context.t.aiSelfHosted,
                kCloudProviders.where((p) => local.contains(p.id)),
              ),
            ])
              if (items.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 4),
                  child: Text(
                    title,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: hud.dim,
                    ),
                  ),
                ),
                for (final p in items)
                  DesignRowTile(
                    dense: true,
                    leading: Icon(
                      p.isCustom
                          ? Icons.tune
                          : (local.contains(p.id)
                                ? Icons.dns_outlined
                                : Icons.cloud_outlined),
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    title: Text(p.nameText, style: theme.textTheme.bodyMedium),
                    subtitle: Text(
                      p.isCustom
                          ? p.noteText
                          : '${p.baseUrl}${p.noteText.isEmpty ? '' : ' · ${p.noteText}'}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: hud.dim,
                      ),
                    ),
                    onTap: () => Navigator.of(context).pop(p),
                  ),
              ],
          ],
        ),
      ),
    );
  }
}

/// 模型选择弹层：搜索 + 点选
class _ModelSheet extends StatefulWidget {
  const _ModelSheet({required this.models});

  final List<CloudModelInfo> models;

  @override
  State<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<_ModelSheet> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final list = widget.models
        .where(
          (m) =>
              _q.isEmpty ||
              m.id.toLowerCase().contains(_q.toLowerCase()) ||
              m.label.toLowerCase().contains(_q.toLowerCase()),
        )
        .toList();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Gap.md,
                Gap.sm,
                Gap.md,
                Gap.xs,
              ),
              child: TextField(
                autofocus: true,
                onChanged: (v) => setState(() => _q = v),
                decoration: InputDecoration(
                  hintText: context.t.aiSearchModels(widget.models.length),
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  filled: true,
                  fillColor: hud.surface2,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: hud.line),
                  ),
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final m = list[i];
                  return DesignRowTile(
                    dense: true,
                    title: Text(m.id, style: theme.textTheme.bodyMedium),
                    subtitle: m.ownedBy.isEmpty
                        ? null
                        : Text(
                            m.ownedBy,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: hud.dim,
                            ),
                          ),
                    onTap: () => Navigator.of(context).pop(m),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「配置方案」弹层的动作
enum _ProfileActionKind { switchTo, saveAs, rename, delete }

class _ProfileAction {
  const _ProfileAction(this.kind, {this.id = '', this.name = ''});

  final _ProfileActionKind kind;
  final String id;
  final String name;
}

/// 配置方案弹层：列出所有已保存的配置，点一下就切；每套可重命名/删除
class _ProfileSheet extends ConsumerWidget {
  const _ProfileSheet({required this.settings});

  final CloudSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final notifier = ref.read(cloudSettingsProvider.notifier);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
              child: Row(
                children: [
                  Icon(
                    Icons.layers_outlined,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(
                      context.t.aiProfilesTitle,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  Text(
                    context.t.aiProfileCount(settings.profiles.length),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: hud.dim,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.md, 2, Gap.md, Gap.sm),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  context.t.aiProfileKeyNote,
                  style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
                ),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (settings.profiles.isEmpty)
                    DesignRowTile(
                      dense: true,
                      title: Text(
                        context.t.aiProfileEmpty,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  for (final p in settings.profiles)
                    _row(context, theme, hud, notifier, p),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(Gap.sm),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: () => Navigator.of(
                    context,
                  ).pop(const _ProfileAction(_ProfileActionKind.saveAs)),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(context.t.aiProfileSaveAs),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.sm),
              child: Text(
                context.t.aiProfileSaveAsHint,
                style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    ThemeData theme,
    DesignPalette hud,
    CloudSettingsNotifier notifier,
    CloudProfile p,
  ) {
    final active = p.id == settings.activeProfileId;
    final label = notifier.profileLabel(p, context.t);
    final preset = cloudProviderById(p.providerId);
    final bits = <String>[
      preset?.nameText ?? p.providerId,
      if (p.model.trim().isNotEmpty) p.model.trim(),
      if (p.baseUrl.trim().isNotEmpty) p.baseUrl.trim(),
    ].join(' · ');
    return DesignRowTile(
      dense: true,
      leading: Icon(
        active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        size: 18,
        color: active ? theme.colorScheme.primary : hud.dim,
      ),
      title: Text(label, style: theme.textTheme.bodyMedium),
      subtitle: Text(
        bits,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
      ),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 18),
        onSelected: (v) {
          switch (v) {
            case 'rename':
              Navigator.of(context).pop(
                _ProfileAction(
                  _ProfileActionKind.rename,
                  id: p.id,
                  name: label,
                ),
              );
            case 'delete':
              Navigator.of(context).pop(
                _ProfileAction(
                  _ProfileActionKind.delete,
                  id: p.id,
                  name: label,
                ),
              );
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'rename',
            child: Text(context.t.aiProfileRename),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Text(context.t.aiProfileDelete),
          ),
        ],
      ),
      onTap: active
          ? null
          : () => Navigator.of(
              context,
            ).pop(_ProfileAction(_ProfileActionKind.switchTo, id: p.id)),
    );
  }
}

/// 给配置起名的小对话框（控制器随对话框一起销毁）
class _ProfileNameDialog extends StatefulWidget {
  const _ProfileNameDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_ProfileNameDialog> createState() => _ProfileNameDialogState();
}

class _ProfileNameDialogState extends State<_ProfileNameDialog> {
  late final TextEditingController _c = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _c,
        autofocus: true,
        decoration: InputDecoration(
          hintText: context.t.aiProfileNameHint,
          isDense: true,
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.t.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_c.text.trim()),
          child: Text(context.t.actionSave),
        ),
      ],
    );
  }
}
