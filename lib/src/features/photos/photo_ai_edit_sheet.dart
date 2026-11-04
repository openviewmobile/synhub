// 相册 AI 美化（图生图）批次②：**提示词面板 / 隐私前置 / 预览 / 保存**。
//
// 结构（方案 §5 主流程）：
//   入口（大图页 AppBar / 多选栏）
//     → 未同意：阻断式同意页（拒绝 = 关闭且**零请求**，不留痕）
//     → 提示词面板：固定告知横幅（每次、不可折叠）+ 7 预设 + 强度 + 变体数
//     → 进行中：计时 + 可取消（已发出时如实说"服务端可能仍会计费"）
//     → 结果：原图/结果对比（长按看原图）+ **默认主操作 = 保存为新照片**
//              + 保存到本机；**覆盖原图 V1 不做**（Synology 无"替换原图"API，
//                只能"上传新图 + 删原图"，不可原子回滚 → 按钮**隐藏**）
//
// 纪律：
//   * 未配后端 / 总开关关闭 → 入口根本不显示（`photoAiEditEntryVisibleProvider`）；
//   * 缺 key / 未同意 / 无网 / 仅 WiFi / 额度用尽 / 并发中 → 发起前拦下，
//     每条都给**确定文案 + 可重试路径**，绝不静默回到初始态（方案 §8 尾）；
//   * 保存失败 105 → **只隐藏"保存到相册"**，"保存到本机"照常；
//     119/106 → 提示会话过期，**不隐藏任何模块**；
//   * 结果非法时 client 层已抛错，界面**不会走到保存**，更不会落盘。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/media/image_edit_prepare.dart';
import '../../core/settings/app_settings.dart' show settingsServiceProvider;
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart'
    show StationService, kFotoUploadApi;
import '../../core/system_open.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/ai/cloud_pricing.dart';
import '../../data/ai/image_edit_client.dart';
import '../../data/ai/image_edit_pricing.dart';
import '../../data/ai/image_edit_prompts.dart';
import '../../data/dto/foto_dto.dart';
import '../../dsm/webapi.dart';
import '../ai/cloud_settings.dart';
import '../notifications/notification_service.dart'
    show networkTypeProbeProvider;
import 'image_edit_preflight.dart';
import 'image_edit_providers.dart';
import 'photo_ai_edit_text.dart';
import 'photo_providers.dart';
import '../../core/user_facing_error.dart';
import '../../core/theme/app_theme.dart';

/// 打开 AI 美化面板（大图页 / 多选栏共用）。
Future<void> showPhotoAiEditSheet(
  BuildContext context, {
  required FotoItemDto item,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => PhotoAiEditSheet(item: item),
  );
}

/// 面板的稳定 key（测试与可访问性用）
const Key kPhotoAiEditSheetKey = Key('photo-ai-edit-sheet');
const Key kPhotoAiEditBannerKey = Key('photo-ai-edit-banner');
const Key kPhotoAiEditConsentKey = Key('photo-ai-edit-consent');
const Key kPhotoAiEditConsentAgreeKey = Key('photo-ai-edit-consent-agree');
const Key kPhotoAiEditConsentRefuseKey = Key('photo-ai-edit-consent-refuse');
const Key kPhotoAiEditPromptKey = Key('photo-ai-edit-prompt');
const Key kPhotoAiEditStartKey = Key('photo-ai-edit-start');
const Key kPhotoAiEditStopKey = Key('photo-ai-edit-stop');
const Key kPhotoAiEditAllowMobileKey = Key('photo-ai-edit-allow-mobile');
const Key kPhotoAiEditResultKey = Key('photo-ai-edit-result');
const Key kPhotoAiEditResultImageKey = Key('photo-ai-edit-result-image');
const Key kPhotoAiEditSaveTimelineKey = Key('photo-ai-edit-save-timeline');
const Key kPhotoAiEditSaveDeviceKey = Key('photo-ai-edit-save-device');
const Key kPhotoAiEditBlockedKey = Key('photo-ai-edit-blocked');
const Key kPhotoAiEditVariantsKey = Key('photo-ai-edit-variants');

class PhotoAiEditSheet extends ConsumerStatefulWidget {
  const PhotoAiEditSheet({super.key, required this.item});

  final FotoItemDto item;

  @override
  ConsumerState<PhotoAiEditSheet> createState() => _PhotoAiEditSheetState();
}

class _PhotoAiEditSheetState extends ConsumerState<PhotoAiEditSheet> {
  final _prompt = TextEditingController();

  ImageEditStrength _strength = ImageEditStrength.fallback;
  int _variants = 1;
  String _presetId = kImageEditPromptTemplates.first.id;

  /// 用户对"仅 WiFi + 当前移动数据"点了"仍然使用流量"（每次会话有效）
  bool _allowMobile = false;

  bool _running = false;
  bool _saving = false;
  CancelToken? _cancel;
  final Stopwatch _elapsed = Stopwatch();
  Timer? _ticker;
  int _elapsedSeconds = 0;

  /// 发起前/请求中被拦下的原因（**必须有文案**，不许静默）
  ImageEditErrorKind? _blockKind;
  String _blockText = '';

  PreparedImageForEdit? _prepared;
  Uint8List? _originalBytes;
  ImageEditOutcome? _outcome;
  int _variantIndex = 0;
  bool _showOriginal = false;

  /// 保存到相册被服务端拒（105）→ **只隐藏这一个按钮**
  bool _timelineDenied = false;

  @override
  void dispose() {
    _ticker?.cancel();
    _prompt.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ 发起

  PhotoAiEditSettings? get _settings =>
      ref.read(photoAiEditSettingsProvider).value;

  void _block(ImageEditErrorKind kind, [String? text]) {
    if (!mounted) return;
    setState(() {
      _blockKind = kind;
      _blockText = text ?? imageEditErrorText(kind);
    });
  }

  Future<void> _start() async {
    final settings = _settings;
    if (settings == null) return;
    final prompt = _prompt.text.trim();
    if (prompt.isEmpty) {
      _block(ImageEditErrorKind.promptEmpty);
      return;
    }
    if (prompt.length > kImageEditPromptMaxChars) {
      _block(
        ImageEditErrorKind.promptTooLong,
        imageEditErrorText(ImageEditErrorKind.promptTooLong, {
          'chars': '${prompt.length}',
          'limit': '$kImageEditPromptMaxChars',
        }),
      );
      return;
    }
    final net = await ref.read(networkTypeProbeProvider).current();
    final kind = imageEditPreflight(
      enabled: settings.enabled,
      consent: settings.consent,
      backendConfigured: settings.backendConfigured,
      keyPresent: settings.keyPresent,
      network: net,
      wifiOnly: settings.wifiOnly,
      allowMobile: _allowMobile,
      records: ref.read(cloudSettingsProvider).usage,
      nowMs: DateTime.now().millisecondsSinceEpoch,
      dailyCap: settings.dailyCap,
      requestedImages: _variants,
    );
    if (kind != null) {
      // 关掉总开关时在途请求的结果仍可保存；这里只是"不再发起新的"
      _block(kind);
      return;
    }
    final cfg = settings.config;
    if (cfg == null) {
      _block(ImageEditErrorKind.backendNotConfigured);
      return;
    }
    final api = ref.read(fotoSpaceApiProvider);
    if (api == null) {
      if (!mounted) return;
      _block(
        ImageEditErrorKind.backendNotConfigured,
        context.t.photoNotConnected,
      );
      return;
    }
    await _run(cfg, prompt);
  }

  Future<void> _run(ImageEditConfig cfg, String prompt) async {
    final loader = ref.read(photoAiEditBytesLoaderProvider);
    final client = ref.read(imageEditClientProvider);
    final gate = ref.read(imageEditGateProvider);
    final cancel = CancelToken();
    setState(() {
      _running = true;
      _blockKind = null;
      _blockText = '';
      _outcome = null;
      _elapsedSeconds = 0;
    });
    _elapsed
      ..reset()
      ..start();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsedSeconds = _elapsed.elapsed.inSeconds);
    });
    ref.read(imageEditBusyProvider.notifier).set(true);
    _cancel = cancel;
    try {
      await gate.run(() async {
        final raw = await loader(widget.item);
        final prepared = prepareImageForEdit(
          bytes: raw,
          fileName: widget.item.filename,
        );
        final full = cfg.copyWith(
          prompt: prompt,
          strength: _strength,
          variants: _variants,
          width: prepared.width,
          height: prepared.height,
        );
        final outcome = await client.edit(
          cfg: full,
          imageBytes: prepared.bytes,
          fileName: prepared.fileName,
          mimeType: prepared.mimeType,
          cancel: cancel,
        );
        await _recordUsage(full, outcome);
        if (!mounted) return;
        setState(() {
          _prepared = prepared;
          _originalBytes = raw;
          _outcome = outcome;
          _variantIndex = 0;
        });
      });
    } on ImageEditException catch (e) {
      _block(e.kind, e.message);
    } catch (e) {
      _block(
        ImageEditErrorKind.unknownNetwork,
        imageEditErrorText(ImageEditErrorKind.unknownNetwork, {'error': userFacingError(e)}),
      );
    } finally {
      _elapsed.stop();
      _ticker?.cancel();
      _ticker = null;
      _cancel = null;
      ref.read(imageEditBusyProvider.notifier).set(false);
      if (mounted) setState(() => _running = false);
    }
  }

  /// 记一次"按张"用量：`kind=photoAiEdit`，张数 = 本次请求的**变体数**
  /// （方案 §7.2：一次出 n 张就记 n，所以变体数天然计入单日额度）。
  Future<void> _recordUsage(
    ImageEditConfig cfg,
    ImageEditOutcome outcome,
  ) async {
    final quote = estimateImageCost(
      model: cfg.modelId,
      images: cfg.variantCount,
      baseUrl: cfg.baseUrl,
    );
    await ref
        .read(cloudSettingsProvider.notifier)
        .recordUsage(
          CloudUsageRecord(
            atMs: DateTime.now().millisecondsSinceEpoch,
            usage: CloudTokenUsage.zero,
            model: cfg.modelId,
            protocolId: cfg.backend.id,
            kind: kImageEditUsageKind,
            elapsedMs: _elapsed.elapsedMilliseconds,
            costUsd: quote.usd,
            priced: quote.priced,
            ok: outcome.images.isNotEmpty,
            imageCount: cfg.variantCount,
          ),
        );
  }

  void _stop() {
    _cancel?.cancel();
    // 不显示成功；`cancelledBilling` 文案由 catch 分支给出
  }

  // ------------------------------------------------------------ 保存

  String _resultFileName() {
    final base = widget.item.filename;
    final dot = base.lastIndexOf('.');
    final stem = dot > 0 ? base.substring(0, dot) : base;
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    return '${stem}_ai_$stamp.jpg';
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// **默认主操作**：保存为新照片（`Upload.Item/upload`，文件名带 `_ai_`，
  /// **保留原照片 mtime** → 时间轴位置不漂）。
  Future<void> _saveToTimeline() async {
    final outcome = _outcome;
    final api = ref.read(fotoSpaceApiProvider);
    if (outcome == null || api == null || _saving) return;
    final bytes = outcome.images[_variantIndex];
    setState(() => _saving = true);
    Directory? tmp;
    try {
      tmp = Directory.systemTemp.createTempSync('photo_ai_edit');
      final name = _resultFileName();
      final file = File('${tmp.path}/$name');
      // 同步落临时文件：`Upload.Item` 的 multipart 立刻读这个路径，
      // 异步 IO 在 widget 测试的假时钟下容易悬着不完成。
      file.writeAsBytesSync(bytes);
      await api.uploadToTimeline(
        filePath: file.path,
        fileName: name,
        // **保留原 mtime**（`item.time` 是秒）
        mtimeMs: widget.item.time * 1000,
      );
      ref.invalidate(photoTimelineProvider);
      ref.invalidate(photoAlbumsProvider);
      _snack(
        photoAiEditFill(
          PhotoAiEditTextKeys.savedToTimeline,
          '已保存为 {count} 张新照片',
          {'count': '1'},
        ),
      );
    } on DsmApiException catch (e) {
      if (!mounted) return;
      if (e.code == 105) {
        // 105 = 没有权限 → **只隐藏"保存到相册"**，本机保存仍在
        setState(() => _timelineDenied = true);
        _snack(imageEditErrorText(ImageEditErrorKind.saveForbidden105));
      } else if (e.code == 119 || e.code == 106) {
        // 会话过期 → 提示，**不隐藏任何入口**（S2 纪律）
        _snack(imageEditErrorText(ImageEditErrorKind.saveSessionExpired));
      } else {
        _snack(
          photoAiEditFill(PhotoAiEditTextKeys.saveFailed, '保存失败：{error}', {
            'error': userFacingError(e),
          }),
        );
      }
    } catch (e) {
      _snack(
        photoAiEditFill(PhotoAiEditTextKeys.saveFailed, '保存失败：{error}', {
          'error': userFacingError(e),
        }),
      );
    } finally {
      if (tmp != null && tmp.existsSync()) {
        tmp.deleteSync(recursive: true);
      }
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 保存到本机：既有下载目录 + systemOpen（**不引入新依赖**）
  Future<void> _saveToDevice() async {
    final outcome = _outcome;
    if (outcome == null || _saving) return;
    final bytes = outcome.images[_variantIndex];
    setState(() => _saving = true);
    try {
      final dir = await ref.read(photoDownloadDirectoryProvider)();
      final name = _resultFileName();
      final file = File('${dir.path}/$name');
      file.writeAsBytesSync(bytes);
      await ref.read(systemOpenProvider)(file.path);
      _snack(
        photoAiEditFill(
          PhotoAiEditTextKeys.savedToDeviceOpened,
          '已保存到本机并打开：{name}',
          {'name': name},
        ),
      );
    } catch (e) {
      _snack(
        photoAiEditFill(PhotoAiEditTextKeys.saveFailed, '保存失败：{error}', {
          'error': userFacingError(e),
        }),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(photoAiEditSettingsProvider);
    final settings = async.value;
    return Padding(
      key: kPhotoAiEditSheetKey,
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: settings == null
          ? const SizedBox(
              height: 160,
              child: Center(child: CircularProgressIndicator()),
            )
          : settings.consent
          ? _buildBody(settings)
          : _buildConsent(settings),
    );
  }

  Widget _buildBody(PhotoAiEditSettings settings) {
    if (_running) return _buildRunning();
    if (_outcome != null) return _buildResult(settings);
    return _buildPanel(settings);
  }

  // ------------------------------------------------------------ 同意页

  Widget _buildConsent(PhotoAiEditSettings settings) {
    final host = imageEditHostOf(settings.baseUrl);
    final theme = Theme.of(context);
    return Padding(
      key: kPhotoAiEditConsentKey,
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            photoAiEdit(PhotoAiEditTextKeys.consentTitle, '使用前请确认'),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: Gap.sm),
          _banner(host, selfHosted: settings.backend.isSelfHosted),
          const SizedBox(height: Gap.sm),
          Text(
            photoAiEdit(
              PhotoAiEditTextKeys.consentBody,
              '· 照片本体（已移除 EXIF，含 GPS）会发送到你配置的服务；\n'
              '· 不经过本应用的任何服务器；\n'
              '· 可能产生费用；\n'
              '· 可随时在「AI 服务 → AI 美化」里关闭或撤销同意。',
            ),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Gap.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: kPhotoAiEditConsentRefuseKey,
                // 拒绝 = 什么也不写、不留痕、关闭面板、**零请求**
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(
                  photoAiEdit(PhotoAiEditTextKeys.consentRefuse, '不同意'),
                ),
              ),
              const SizedBox(width: Gap.sm),
              FilledButton(
                style: InlineButtonStyle.filled,
                key: kPhotoAiEditConsentAgreeKey,
                onPressed: _grantConsent,
                child: Text(
                  photoAiEdit(PhotoAiEditTextKeys.consentAgree, '我理解并同意'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 只有**显式点"我理解并同意"**才写入（无 checkbox、无"不再提示"）
  Future<void> _grantConsent() async {
    await ref.read(settingsServiceProvider).setImageEditConsentV1('granted');
    ref.invalidate(photoAiEditSettingsProvider);
  }

  // ------------------------------------------------------------ 提示词面板

  Widget _banner(String host, {required bool selfHosted}) {
    final theme = Theme.of(context);
    return Container(
      key: kPhotoAiEditBannerKey,
      width: double.infinity,
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(Radii.cut),
        border: Border.all(color: theme.colorScheme.error),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.privacy_tip_outlined,
                size: 18,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(
                  // 每次发送前**逐字**写明发送对象与主机名（不可折叠）
                  photoAiEditFill(
                    PhotoAiEditTextKeys.sendBanner,
                    '这张照片将被发送到 <你配置的服务>（{host}）',
                    {'host': host},
                  ),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          if (selfHosted)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(
                photoAiEdit(
                  PhotoAiEditTextKeys.sendBannerLocalNote,
                  '若该地址不是本机/局域网，照片仍会离开设备',
                ),
                style: theme.textTheme.bodySmall,
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(_summaryText(), style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  String _summaryText() {
    final prepared = _prepared;
    if (prepared == null) {
      return photoAiEditFill(
        PhotoAiEditTextKeys.sendSummary,
        '{count} 张 · 已移除 EXIF（含 GPS）',
        {'count': '$_variants'},
      );
    }
    return photoAiEditFill(
      PhotoAiEditTextKeys.sendSummaryBytes,
      '{count} 张 · 已移除 EXIF（含 GPS）· 约 {kb} KB',
      {'count': '$_variants', 'kb': '${(prepared.byteLength / 1024).round()}'},
    );
  }

  Widget _buildPanel(PhotoAiEditSettings settings) {
    final theme = Theme.of(context);
    final host = imageEditHostOf(settings.baseUrl);
    final cfg = settings.config;
    final quote = cfg == null
        ? null
        : estimateImageCost(
            model: cfg.modelId,
            images: _variants,
            baseUrl: cfg.baseUrl,
          );
    final quota = imageEditQuota(
      records: ref.watch(cloudSettingsProvider).usage,
      nowMs: DateTime.now().millisecondsSinceEpoch,
      cap: settings.dailyCap,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            photoAiEdit(PhotoAiEditTextKeys.panelTitle, 'AI 美化'),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: Gap.sm),
          _banner(host, selfHosted: settings.backend.isSelfHosted),
          if (_blockText.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            _blockedBox(theme),
          ],
          const SizedBox(height: Gap.md),
          _label(theme, photoAiEdit(PhotoAiEditTextKeys.presetLabel, '预设')),
          Wrap(
            spacing: Gap.xs,
            runSpacing: Gap.xs,
            children: [
              for (final t in kImageEditPromptTemplates)
                ChoiceChip(
                  key: Key('photo-ai-edit-preset-${t.id}'),
                  label: Text(t.labelText),
                  selected: _presetId == t.id,
                  onSelected: (_) => _pickPreset(t),
                ),
            ],
          ),
          if (_currentNotice.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(
                _currentNotice,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: Gap.md),
          _label(theme, photoAiEdit(PhotoAiEditTextKeys.promptLabel, '提示词')),
          TextField(
            key: kPhotoAiEditPromptKey,
            controller: _prompt,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: photoAiEdit(
                PhotoAiEditTextKeys.promptHint,
                '想怎么美化？例如：提升清晰度',
              ),
              helperText: photoAiEditFill(
                PhotoAiEditTextKeys.promptCounter,
                '{chars}/{limit}',
                {
                  'chars': '${_prompt.text.trim().length}',
                  'limit': '$kImageEditPromptMaxChars',
                },
              ),
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: Gap.md),
          _label(theme, photoAiEdit(PhotoAiEditTextKeys.strengthLabel, '强度')),
          Wrap(
            spacing: Gap.xs,
            children: [
              for (final s in ImageEditStrength.values)
                ChoiceChip(
                  key: Key('photo-ai-edit-strength-${s.id}'),
                  label: Text(s.labelText),
                  selected: _strength == s,
                  onSelected: (_) => setState(() => _strength = s),
                ),
            ],
          ),
          const SizedBox(height: Gap.md),
          _label(theme, photoAiEdit(PhotoAiEditTextKeys.variantsLabel, '变体数')),
          Row(
            key: kPhotoAiEditVariantsKey,
            children: [
              IconButton(
                key: const Key('photo-ai-edit-variant-minus'),
                onPressed: _variants > 1
                    ? () => setState(() => _variants--)
                    : null,
                icon: const Icon(Icons.remove_circle_outline),
              ),
              Text('$_variants', style: theme.textTheme.titleMedium),
              IconButton(
                key: const Key('photo-ai-edit-variant-plus'),
                onPressed: _variants < 4
                    ? () => setState(() => _variants++)
                    : null,
                icon: const Icon(Icons.add_circle_outline),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(
                  // >1 张时显示张数与预计费用（单价未知就明说，不猜数字）
                  _variants == 1 ? '' : _costText(quote),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.sm),
          Text(
            photoAiEditFill(
              PhotoAiEditTextKeys.quotaLine,
              '今日剩余 {remaining}/{cap} 张',
              {'remaining': '${quota.remaining}', 'cap': '${quota.cap}'},
            ),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Gap.md),
          Row(
            children: [
              if (_blockKind == ImageEditErrorKind.wifiOnlyBlocked ||
                  _blockKind == ImageEditErrorKind.networkUnknown)
                TextButton(
                  key: kPhotoAiEditAllowMobileKey,
                  onPressed: () {
                    setState(() => _allowMobile = true);
                    _start();
                  },
                  child: Text(
                    photoAiEdit(PhotoAiEditTextKeys.allowMobile, '仍然使用流量'),
                  ),
                ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(context.t.actionCancel),
              ),
              const SizedBox(width: Gap.sm),
              FilledButton.icon( style: InlineButtonStyle.filled,
                key: kPhotoAiEditStartKey,
                onPressed: _canStart(settings, quota) ? _start : null,
                icon: const Icon(Icons.auto_fix_high, size: 18),
                label: Text(photoAiEdit(PhotoAiEditTextKeys.start, '开始美化')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String get _currentNotice {
    for (final t in kImageEditPromptTemplates) {
      if (t.id == _presetId) return t.noticeText;
    }
    return '';
  }

  void _pickPreset(ImageEditPromptTemplate t) {
    setState(() {
      _presetId = t.id;
      _strength = t.strength;
      _prompt.text = t.promptText;
      _blockKind = null;
      _blockText = '';
    });
  }

  String _costText(CloudCostQuote? quote) {
    if (quote == null) return '';
    if (!quote.priced) {
      return photoAiEditFill(
        PhotoAiEditTextKeys.variantsCostUnknown,
        '将生成 {count} 张 · 预计费用：单价未知（将如实记账，无法预估）',
        {'count': '$_variants'},
      );
    }
    if (quote.usd == 0) {
      return photoAiEditFill(
        PhotoAiEditTextKeys.variantsCostLocal,
        '将生成 {count} 张 · 预计费用：0（自建/局域网）',
        {'count': '$_variants'},
      );
    }
    return photoAiEditFill(
      PhotoAiEditTextKeys.variantsCostKnown,
      '将生成 {count} 张 · 预计费用：{usd} USD',
      {'count': '$_variants', 'usd': quote.usd.toStringAsFixed(3)},
    );
  }

  /// 面板按钮的禁用态：额度用尽 / 总开关关闭 / 并发中（**给文案，不静默**）
  bool _canStart(PhotoAiEditSettings settings, ImageEditQuota quota) {
    if (!settings.enabled) return false;
    if (!settings.backendConfigured) return false;
    if (quota.disabled || quota.blocks(_variants)) return false;
    if (ref.watch(imageEditBusyProvider)) return false;
    return true;
  }

  Widget _blockedBox(ThemeData theme) => Container(
    key: kPhotoAiEditBlockedKey,
    width: double.infinity,
    padding: const EdgeInsets.all(Gap.sm),
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(Radii.cut),
    ),
    child: Text(_blockText, style: theme.textTheme.bodySmall),
  );

  Widget _label(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(bottom: Gap.xs),
    child: Text(text, style: theme.textTheme.labelLarge),
  );

  // ------------------------------------------------------------ 进行中

  Widget _buildRunning() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: Gap.md),
          Text(
            photoAiEdit(PhotoAiEditTextKeys.running, '正在美化…'),
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: Gap.xs),
          Text(
            photoAiEditFill(
              PhotoAiEditTextKeys.runningElapsed,
              '已等待 {seconds} 秒',
              {'seconds': '$_elapsedSeconds'},
            ),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Gap.md),
          TextButton(
            key: kPhotoAiEditStopKey,
            onPressed: _stop,
            child: Text(photoAiEdit(PhotoAiEditTextKeys.stop, '停止')),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 结果

  Widget _buildResult(PhotoAiEditSettings settings) {
    final outcome = _outcome!;
    final theme = Theme.of(context);
    final canUploadTimeline = ref
        .watch(serviceAvailabilityProvider)
        .hasApi(StationService.photo, kFotoUploadApi);
    final shown = _showOriginal && _originalBytes != null
        ? _originalBytes!
        : outcome.images[_variantIndex];
    return SingleChildScrollView(
      key: kPhotoAiEditResultKey,
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            photoAiEdit(PhotoAiEditTextKeys.resultTitle, '美化结果'),
            style: theme.textTheme.titleMedium,
          ),
          if (outcome.failed > 0) ...[
            const SizedBox(height: Gap.xs),
            Text(
              outcome.warningText(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: Gap.sm),
          // 原图/结果对比：长按看原图（松手回到结果）
          GestureDetector(
            onLongPressStart: _originalBytes == null
                ? null
                : (_) => setState(() => _showOriginal = true),
            onLongPressEnd: (_) => setState(() => _showOriginal = false),
            child: Container(
              key: kPhotoAiEditResultImageKey,
              height: 260,
              width: double.infinity,
              color: Colors.black12,
              child: Image.memory(shown, fit: BoxFit.contain),
            ),
          ),
          const SizedBox(height: Gap.xs),
          Text(
            photoAiEdit(PhotoAiEditTextKeys.holdToCompare, '按住查看原图'),
            style: theme.textTheme.bodySmall,
          ),
          if (outcome.images.length > 1) ...[
            const SizedBox(height: Gap.sm),
            Wrap(
              spacing: Gap.xs,
              children: [
                for (var i = 0; i < outcome.images.length; i++)
                  ChoiceChip(
                    key: Key('photo-ai-edit-result-$i'),
                    label: Text(
                      photoAiEditFill(
                        PhotoAiEditTextKeys.variantOf,
                        '第 {index}/{total} 张',
                        {
                          'index': '${i + 1}',
                          'total': '${outcome.images.length}',
                        },
                      ),
                    ),
                    selected: _variantIndex == i,
                    onSelected: (_) => setState(() => _variantIndex = i),
                  ),
              ],
            ),
          ],
          const SizedBox(height: Gap.md),
          Row(
            children: [
              // **默认主操作 = 保存为新照片**（106/119 会话过期也不隐藏；
              // 缺 `SYNO.Foto.Upload.Item` 或 105 才隐藏）
              if (canUploadTimeline && !_timelineDenied)
                FilledButton.icon( style: InlineButtonStyle.filled,
                  key: kPhotoAiEditSaveTimelineKey,
                  onPressed: _saving ? null : _saveToTimeline,
                  icon: const Icon(
                    Icons.add_photo_alternate_outlined,
                    size: 18,
                  ),
                  label: Text(
                    photoAiEdit(PhotoAiEditTextKeys.saveAsNewPhoto, '保存为新照片'),
                  ),
                ),
              if (canUploadTimeline && !_timelineDenied)
                const SizedBox(width: Gap.sm),
              OutlinedButton.icon( style: InlineButtonStyle.outlined,
                key: kPhotoAiEditSaveDeviceKey,
                onPressed: _saving ? null : _saveToDevice,
                icon: const Icon(Icons.download_outlined, size: 18),
                label: Text(
                  photoAiEdit(PhotoAiEditTextKeys.saveToDevice, '保存到本机'),
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(context.t.actionCancel),
              ),
            ],
          ),
          // ⚠️ V1 **不做"覆盖原图"**：Synology 侧没有"替换原图"API，
          // 只能"上传新图 + 删原图"，不可原子回滚 → 按钮**隐藏**（不是灰置）。
          if (!canUploadTimeline)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(
                imageEditErrorText(ImageEditErrorKind.uploadApiMissing),
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}
