// 「AI 服务 → AI 美化」设置卡片（方案 §6.3 / §7.2）。
//
// 职责（是本功能**唯一**的配置入口）：
//   * 总开关（默认关闭）；
//   * 后端 / 服务地址 / 模型 / API Key（key 只进安全存储槽位）；
//   * 单日上限（0 = 关闭功能）；仅 WiFi（默认开）；
//   * **撤销同意**（清 `image_edit_consent_v1` + 关总开关）。
//
// 纪律：不在这里做任何联网探测；不出现"不再提示"这类隐式勾选
// （同意只能在结果提交前的阻断式页面里显式点击，见 `photo_ai_edit_sheet.dart`）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import '../../core/settings/app_settings.dart'
    show SettingsService, settingsServiceProvider;
import '../../core/settings/cloud_key_store.dart' show cloudKeyStoreProvider;
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/user_facing_error.dart';
import '../../data/ai/image_edit_client.dart';
import '../../data/ai/image_edit_pricing.dart';
import 'image_edit_providers.dart';
import 'photo_ai_edit_text.dart';

class PhotoAiEditSettingsCard extends ConsumerStatefulWidget {
  const PhotoAiEditSettingsCard({super.key});

  @override
  ConsumerState<PhotoAiEditSettingsCard> createState() =>
      _PhotoAiEditSettingsCardState();
}

class _PhotoAiEditSettingsCardState
    extends ConsumerState<PhotoAiEditSettingsCard> {
  final _base = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();

  String _backendId = ImageEditBackend.openAiImagesEdits.id;
  bool _showKey = false;
  bool _seeded = false;

  @override
  void dispose() {
    _base.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  SettingsService get _settings => ref.read(settingsServiceProvider);

  Future<void> _persist() async {
    await _settings.setImageEditBackend(_backendId);
    await _settings.setImageEditBaseUrl(_base.text.trim());
    await _settings.setImageEditModel(_model.text.trim());
    await ref
        .read(cloudKeyStoreProvider)
        .write(SettingsService.kImageEditKeySlot, _key.text.trim());
    ref.invalidate(photoAiEditSettingsProvider);
  }

  Future<void> _setEnabled(bool v) async {
    await _settings.setImageEditEnabled(v);
    ref.invalidate(photoAiEditSettingsProvider);
  }

  Future<void> _setWifiOnly(bool v) async {
    await _settings.setImageEditWifiOnly(v);
    ref.invalidate(photoAiEditSettingsProvider);
  }

  Future<void> _setCap(int? v) async {
    if (v == null) return;
    await _settings.setImageEditDailyCap(v);
    ref.invalidate(photoAiEditSettingsProvider);
  }

  /// 撤销同意：清同意 + 关总开关（方案 §6.3）
  Future<void> _revoke() async {
    await _settings.clearImageEditConsent();
    await _settings.setImageEditEnabled(false);
    ref.invalidate(photoAiEditSettingsProvider);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          photoAiEdit(PhotoAiEditTextKeys.settingsRevoked, '已撤销同意并关闭 AI 美化'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    final async = ref.watch(photoAiEditSettingsProvider);
    final s = async.value;
    if (s == null) {
      // ★ 以前这里只看 `.value`：读设置**失败**时 value 永远是 null ⇒
      //   设置卡永久转圈，用户没有任何重试入口，也看不到失败原因。
      //   现在失败 = 明确错误态 + 可点重试（重试会真的重新读偏好/安全存储）。
      if (async.hasError) {
        return AppErrorView(
          key: const Key('image-edit-settings-error'),
          title: photoAiEdit(
            PhotoAiEditTextKeys.settingsLoadFailed,
            'AI 美化设置读取失败',
          ),
          detail: userFacingError(async.error!),
          onRetry: () => ref.invalidate(photoAiEditSettingsProvider),
        );
      }
      return const Padding(
        padding: EdgeInsets.all(Gap.md),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (!_seeded) {
      _seeded = true;
      _backendId = s.backendId.isEmpty
          ? ImageEditBackend.openAiImagesEdits.id
          : s.backendId;
      _base.text = s.baseUrl;
      _model.text = s.model;
      _key.text = s.apiKey;
    }
    final backend = ImageEditBackend.fromId(_backendId);
    return Column(
      key: const Key('image-edit-settings-card'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 0),
          child: Text(
            photoAiEdit(PhotoAiEditTextKeys.settingsTitle, 'AI 美化（图生图）'),
            style: theme.textTheme.titleSmall,
          ),
        ),
        Material(
          type: MaterialType.transparency,
          child: DesignSwitchRow(
            key: const Key('image-edit-settings-enable'),
            value: s.enabled,
            onChanged: _setEnabled,
            title: Text(
              photoAiEdit(PhotoAiEditTextKeys.settingsEnable, '启用 AI 美化'),
            ),
            subtitle: Text(
              photoAiEdit(
                PhotoAiEditTextKeys.settingsEnableHint,
                '默认关闭；照片会发送到你配置的服务（不经过本应用服务器）',
              ),
            ),
          ),
        ),
        _field(
          theme,
          hud,
          key: const Key('image-edit-settings-backend'),
          child: DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _backendId,
            decoration: InputDecoration(
              labelText: photoAiEdit(PhotoAiEditTextKeys.settingsBackend, '后端'),
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final b in ImageEditBackend.values)
                DropdownMenuItem(value: b.id, child: Text(b.labelText)),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => _backendId = v);
              _persist();
            },
          ),
        ),
        _field(
          theme,
          hud,
          key: const Key('image-edit-settings-base-url'),
          child: TextField(
            controller: _base,
            decoration: InputDecoration(
              labelText: photoAiEdit(
                PhotoAiEditTextKeys.settingsBaseUrl,
                '服务地址',
              ),
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => _persist(),
          ),
        ),
        _field(
          theme,
          hud,
          key: const Key('image-edit-settings-model'),
          child: TextField(
            controller: _model,
            decoration: InputDecoration(
              labelText: photoAiEdit(PhotoAiEditTextKeys.settingsModel, '模型'),
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => _persist(),
          ),
        ),
        _field(
          theme,
          hud,
          key: const Key('image-edit-settings-key'),
          child: TextField(
            controller: _key,
            obscureText: !_showKey,
            decoration: InputDecoration(
              labelText: photoAiEdit(
                PhotoAiEditTextKeys.settingsKey,
                'API Key',
              ),
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                onPressed: () => setState(() => _showKey = !_showKey),
                icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
              ),
            ),
            onChanged: (_) => _persist(),
          ),
        ),
        _field(
          theme,
          hud,
          key: const Key('image-edit-settings-cap'),
          child: DropdownButtonFormField<int>(
            isExpanded: true,
            initialValue: s.dailyCap,
            decoration: InputDecoration(
              labelText: photoAiEdit(
                PhotoAiEditTextKeys.settingsDailyCap,
                '单日上限（张）',
              ),
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final c in kImageEditDailyCapOptions)
                DropdownMenuItem(
                  value: c,
                  child: Text(
                    c == 0
                        ? photoAiEdit(
                            PhotoAiEditTextKeys.settingsCapOff,
                            '关闭（0 张/日）',
                          )
                        : photoAiEditFill(
                            PhotoAiEditTextKeys.settingsCapValue,
                            '{count} 张/日',
                            {'count': '$c'},
                          ),
                  ),
                ),
            ],
            onChanged: _setCap,
          ),
        ),
        Material(
          type: MaterialType.transparency,
          child: DesignSwitchRow(
            key: const Key('image-edit-settings-wifi-only'),
            value: s.wifiOnly,
            onChanged: _setWifiOnly,
            title: Text(
              photoAiEdit(PhotoAiEditTextKeys.settingsWifiOnly, '仅 WiFi 上传'),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  s.consent
                      ? photoAiEdit(
                          PhotoAiEditTextKeys.settingsConsentDone,
                          '已同意（可随时撤销）',
                        )
                      : photoAiEdit(
                          PhotoAiEditTextKeys.settingsConsentMissing,
                          '尚未同意（首次使用时询问）',
                        ),
                  style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                ),
              ),
              TextButton(
                key: const Key('image-edit-settings-revoke'),
                onPressed: _revoke,
                child: Text(
                  photoAiEdit(PhotoAiEditTextKeys.settingsRevoke, '撤销同意'),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, 0),
          child: Text(
            backend.labelText,
            style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
          ),
        ),
      ],
    );
  }

  Widget _field(
    ThemeData theme,
    DesignPalette hud, {
    required Key key,
    required Widget child,
  }) => Padding(
    key: key,
    padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, 0),
    child: child,
  );
}
