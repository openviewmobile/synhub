// 相册 wave3 页面层：相册设置（缓存状态/大小 + 列表显示偏好，只读）+ 照片 EXIF 小节。
//
// 全部**只读**：`Download/clear_cache` 与 `Browse.Album/set_album_list_display`
// 都是写操作且本批未取证 → 不做、不进 UI（登记在 `docs/photo-gaps-wave3.md` §7）。
//
// 门控：每个小节自己看 `hasApi`（缺失 → `SizedBox.shrink()`，连请求都不发），
// 再按 `photoWave3Gate` 的三态处理 `105`/`160`（隐藏）与 `119`/`106`（会话提示）。
library;

import '../../design/kit/design_kit.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/foto_wave3_dto.dart';
import 'photo_c2_sections.dart';
import 'photo_c2_text.dart';
import 'photo_format_support.dart';
import 'photo_playback_settings.dart';
import 'photo_wave2_text.dart';
import 'photo_wave3_providers.dart';
import 'photo_local_cache.dart';
import 'photo_wave3_text.dart';
import 'photo_widgets.dart';

/// 相册设置子页：相册缓存（`Download/*` v2）+ 相册列表显示偏好（`Browse.Album` v3）
/// + **播放设置**（P48，本地：HTTP / 端口 / 忽略证书错误）。
///
/// 前三节只读；播放设置是**本地偏好**（不走任何服务端写接口）。
class PhotoAlbumSettingsPage extends ConsumerWidget {
  const PhotoAlbumSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PhotoC2Scaffold(
      pageKey: const Key('photo-wave3-album-settings'),
      title: photoWave3(PhotoWave3TextKeys.albumSettings, '相册设置'),
      body: ListView(
        padding: const EdgeInsets.all(Gap.md),
        children: const [
          _AlbumCacheSection(),
          SizedBox(height: Gap.lg),
          _AlbumListDisplaySection(),
          SizedBox(height: Gap.lg),
          _PlaybackSettingsSection(),
        ],
      ),
    );
  }
}

// ================================================================ 公共小块

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(text, style: theme.textTheme.titleMedium);
  }
}

/// 一行"标签 —— 值"（值不可交互，纯只读）。
class _ReadOnlyRow extends StatelessWidget {
  const _ReadOnlyRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: DesignPalette.of(context).dim,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// 会话失效提示（`119`/`106`；**不隐藏**小节）。
class _SessionHint extends StatelessWidget {
  const _SessionHint();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(
      photoC2(PhotoC2TextKeys.sessionHint, '登录状态已失效，请重新登录后重试。'),
      key: const Key('photo-wave3-session-hint'),
      style: Theme.of(context).textTheme.bodySmall,
    ),
  );
}

/// "这部分内容暂时取不到，可稍后重试。"（复用 wave2 的 key，不新造）
class _PartialUnavailable extends StatelessWidget {
  const _PartialUnavailable(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
    ),
  );
}

String _partialUnavailableText() =>
    photoWave2(PhotoWave2TextKeys.partialUnavailable, '这部分内容暂时取不到，可稍后重试。');

// ================================================================ 相册缓存

/// 相册缓存（`get_cache_status` + `calculate_cache_size` **v2**）。
///
/// ⚠️ **只展示，不清理**：`clear_cache` 是写操作、本批未取证其语义
/// （官方 Web `function BL()` 会真的下发），所以本页**没有任何清理按钮**。
class _AlbumCacheSection extends ConsumerWidget {
  const _AlbumCacheSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasApi = ref
        .watch(serviceAvailabilityProvider)
        .hasApi(StationService.photo, kFotoDownloadApi);
    if (!hasApi) return const SizedBox.shrink();

    final status = ref.watch(photoAlbumCacheStatusProvider);
    final size = ref.watch(photoAlbumCacheSizeProvider);
    final statusGate = photoWave3Gate(status, hasApi: true);
    final sizeGate = photoWave3Gate(size, hasApi: true);
    // `105`/`160` 出在任一调用上 → 整个缓存小节隐藏（只降级这一节）。
    if (statusGate == PhotoWave3Gate.hidden ||
        sizeGate == PhotoWave3Gate.hidden) {
      return const SizedBox.shrink();
    }
    final sessionHint =
        statusGate == PhotoWave3Gate.sessionHint ||
        sizeGate == PhotoWave3Gate.sessionHint;

    return Column(
      key: const Key('photo-wave3-cache-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(photoWave3(PhotoWave3TextKeys.cache, '相册缓存')),
        if (sessionHint) const _SessionHint(),
        _CacheStatusRow(status),
        _CacheSizeRow(size),
        const SizedBox(height: Gap.sm),
        Text(
          photoWave3(
            PhotoWave3TextKeys.cacheReadOnly,
            '本版本只展示缓存状态与占用，不提供清理操作。',
          ),
          key: const Key('photo-wave3-cache-readonly'),
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
        ),
        // ---- P53 客户端本地缓存（上限 + 清理）：官方 `PreferenceManager.CACHE_LIMIT`
        // / `pref_clear_cache` / `bg_clear_cache_button` 同款；**只动 App 自己的
        // 缓存目录**，不发任何 NAS 请求。
        _LocalCacheRows(),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const Key('photo-wave3-cache-refresh'),
            onPressed: () {
              ref.invalidate(photoAlbumCacheStatusProvider);
              ref.invalidate(photoAlbumCacheSizeProvider);
            },
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(photoWave3(PhotoWave3TextKeys.refresh, '重新读取')),
          ),
        ),
      ],
    );
  }
}

/// 客户端本地缓存：容量上限下拉 + 清理按钮（带二次确认）。
class _LocalCacheRows extends ConsumerWidget {
  const _LocalCacheRows();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final limit = ref.watch(photoLocalCacheLimitProvider);
    final stats = ref.watch(photoLocalCacheStatsProvider);
    final current = limit.value;
    return Column(
      key: const Key('photo-local-cache'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DesignRowTile(
          key: const Key('photo-cache-limit-row'),
          contentPadding: EdgeInsets.zero,
          title: Text(photoWave3(PhotoWave3TextKeys.cacheLimit, '本机缓存上限')),
          subtitle: Text(
            stats.value == null
                ? photoWave3(PhotoWave3TextKeys.cacheLocalReading, '正在统计本机缓存…')
                : context.t.photoCacheLocalSize(
                    (stats.value!.bytes / (1024 * 1024)).toStringAsFixed(1),
                    stats.value!.fileCount,
                  ),
            key: const Key('photo-cache-local-size'),
          ),
          trailing: DropdownButton<int>(
            key: const Key('photo-cache-limit-select'),
            value: current == null || current == 0 ? 0 : current,
            onChanged: current == null
                ? null
                : (v) {
                    if (v != null) {
                      ref.read(photoLocalCacheLimitProvider.notifier).set(v);
                    }
                  },
            items: [
              for (final bytes in kPhotoLocalCacheLimitOptions)
                DropdownMenuItem(
                  key: Key('photo-cache-limit-${bytes ~/ (1024 * 1024)}'),
                  value: bytes,
                  child: Text(photoCacheLimitLabel(bytes)),
                ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const Key('photo-cache-clear'),
            onPressed: () => _confirmClear(context, ref),
            icon: const Icon(Icons.delete_sweep_outlined, size: 16),
            label: Text(photoWave3(PhotoWave3TextKeys.cacheClear, '清理本机缓存')),
          ),
        ),
      ],
    );
  }

  /// 清理前**必须二次确认**（官方是 `str_clear_cache_alert_desc` 弹窗）。
  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(photoWave3(PhotoWave3TextKeys.cacheClear, '清理本机缓存')),
        content: Text(
          photoWave3(
            PhotoWave3TextKeys.cacheClearDesc,
            '只清这台手机上的图片缓存，NAS 上的照片不会被删除；下次浏览会重新下载。',
          ),
        ),
        actions: [
          TextButton(
            key: const Key('photo-cache-clear-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t.actionCancel),
          ),
          FilledButton(
            key: const Key('photo-cache-clear-ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t.dtoActionDelete),
          ),
        ],
      ),
    );
    if (ok != true) return; // 取消 → 一个文件都不删
    final freed = await ref.read(photoLocalCacheActionsProvider).clear();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '${photoWave3(PhotoWave3TextKeys.cacheCleared, '已清理')} '
          '${(freed / (1024 * 1024)).toStringAsFixed(1)} MB',
        ),
      ),
    );
  }
}

class _CacheStatusRow extends ConsumerWidget {
  const _CacheStatusRow(this.value);

  final AsyncValue<FotoCacheStatusDto> value;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gate = photoWave3Gate(value, hasApi: true);
    if (gate == PhotoWave3Gate.hidden) return const SizedBox.shrink();
    final label = photoWave3(PhotoWave3TextKeys.cacheStatus, '缓存状态');
    // 会话失效：小节级已经给了提示，这里只占位（**不隐藏**）。
    if (gate == PhotoWave3Gate.sessionHint) return _ReadOnlyRow(label, '—');
    if (value.hasError) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ReadOnlyRow(label, '—'),
          _PartialUnavailable(_partialUnavailableText()),
          TextButton(
            key: const Key('photo-wave3-cache-status-retry'),
            onPressed: () => ref.invalidate(photoAlbumCacheStatusProvider),
            child: Text(context.t.photoRetry),
          ),
        ],
      );
    }
    final dto = value.value;
    if (dto == null) {
      return _ReadOnlyRow(label, '…');
    }
    final text = switch (dto) {
      _ when dto.isDone => photoWave3(
        PhotoWave3TextKeys.cacheStatusDone,
        '已完成',
      ),
      _ when dto.isProcessing => photoWave3(
        PhotoWave3TextKeys.cacheStatusProcessing,
        '正在处理',
      ),
      // 空 / 其它任何值（含未来新增状态）**一律不显示成"已完成"**。
      _ => photoWave3(PhotoWave3TextKeys.cacheStatusUnknown, '状态未知'),
    };
    return _ReadOnlyRow(label, text);
  }
}

class _CacheSizeRow extends ConsumerWidget {
  const _CacheSizeRow(this.value);

  final AsyncValue<FotoCacheSizeDto> value;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gate = photoWave3Gate(value, hasApi: true);
    if (gate == PhotoWave3Gate.hidden) return const SizedBox.shrink();
    final label = photoWave3(PhotoWave3TextKeys.cacheSize, '缓存占用');
    if (gate == PhotoWave3Gate.sessionHint) return _ReadOnlyRow(label, '—');
    if (value.hasError) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ReadOnlyRow(label, '—'),
          _PartialUnavailable(_partialUnavailableText()),
          TextButton(
            key: const Key('photo-wave3-cache-size-retry'),
            onPressed: () => ref.invalidate(photoAlbumCacheSizeProvider),
            child: Text(context.t.photoRetry),
          ),
        ],
      );
    }
    final dto = value.value;
    if (dto == null) return _ReadOnlyRow(label, '…');
    if (!dto.hasValue) {
      return _ReadOnlyRow(
        label,
        photoWave3(PhotoWave3TextKeys.cacheSizeUnavailable, '暂时取不到缓存大小'),
      );
    }
    return _ReadOnlyRow(
      label,
      photoWave3Fill(
        PhotoWave3TextKeys.cacheSizeValue,
        'NAS 上的图片缓存占用了 {size}',
        {'size': photoBytes(dto.bytes!)},
      ),
    );
  }
}

// ================================================================ 列表显示偏好

/// 相册列表显示偏好（`get_album_list_display` **v3**，**只读**）。
///
/// 同族的 `set_album_list_display` 是写操作且未取证 → 没有任何修改入口。
class _AlbumListDisplaySection extends ConsumerWidget {
  const _AlbumListDisplaySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasApi = ref
        .watch(serviceAvailabilityProvider)
        .hasApi(StationService.photo, kFotoBrowseAlbumApi);
    if (!hasApi) return const SizedBox.shrink();

    final value = ref.watch(photoAlbumListDisplayProvider);
    final gate = photoWave3Gate(value, hasApi: true);
    if (gate == PhotoWave3Gate.hidden) return const SizedBox.shrink();

    final label = photoWave3(PhotoWave3TextKeys.albumListDisplay, '相册列表显示偏好');
    Widget body;
    if (gate == PhotoWave3Gate.sessionHint) {
      body = _ReadOnlyRow(label, '—');
    } else if (value.hasError) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ReadOnlyRow(label, '—'),
          _PartialUnavailable(_partialUnavailableText()),
          TextButton(
            key: const Key('photo-wave3-album-display-retry'),
            onPressed: () => ref.invalidate(photoAlbumListDisplayProvider),
            child: Text(context.t.photoRetry),
          ),
        ],
      );
    } else if (value.value == null) {
      body = _ReadOnlyRow(label, '…');
    } else {
      final dto = value.value!;
      final text = switch (dto) {
        _ when dto.isAllAlbums => photoWave3(
          PhotoWave3TextKeys.albumDisplayAll,
          '所有相册',
        ),
        _ when dto.isMyAlbums => photoWave3(
          PhotoWave3TextKeys.albumDisplayMine,
          '我的相册',
        ),
        _ => photoWave3(
          PhotoWave3TextKeys.albumDisplayUnknown,
          '服务端返回了未识别的显示偏好',
        ),
      };
      body = _ReadOnlyRow(label, text);
    }

    return Column(
      key: const Key('photo-wave3-album-display-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(label),
        if (gate == PhotoWave3Gate.sessionHint) const _SessionHint(),
        body,
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const Key('photo-wave3-album-display-refresh'),
            onPressed: () => ref.invalidate(photoAlbumListDisplayProvider),
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(photoWave3(PhotoWave3TextKeys.refresh, '重新读取')),
          ),
        ),
      ],
    );
  }
}

// ================================================================ 照片 EXIF

/// 照片详情 / 信息面板里的 EXIF 小节（`Browse.Item/get_exif` **v1** + `id`）。
///
/// * 能力位缺失 / `105`/`160` → 整段不渲染（**不显示空白标题**）；
/// * `119`/`106` → 会话提示，**不隐藏**；
/// * 回包认不出任何字段 → **明确空态**（不是"0 项表格"）；
/// * 只显示**有值**的字段，拿不到的字段不占行。
class PhotoExifSection extends ConsumerWidget {
  const PhotoExifSection({super.key, required this.itemId});

  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasApi = ref
        .watch(serviceAvailabilityProvider)
        .hasApi(StationService.photo, kFotoBrowseItemApi);
    if (!hasApi) return const SizedBox.shrink();

    final value = ref.watch(photoExifProvider(itemId));
    final gate = photoWave3Gate(value, hasApi: true);
    if (gate == PhotoWave3Gate.hidden) return const SizedBox.shrink();

    final t = context.t;
    final children = <Widget>[
      const Divider(height: Gap.lg),
      _SectionTitle(photoWave3(PhotoWave3TextKeys.exifTitle, '拍摄信息')),
    ];
    if (gate == PhotoWave3Gate.sessionHint) {
      children.add(const _SessionHint());
    } else if (value.hasError) {
      children.add(
        _PartialUnavailable(
          photoWave3(PhotoWave3TextKeys.exifFailed, '拍摄信息暂时取不到'),
        ),
      );
      children.add(
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            key: const Key('photo-wave3-exif-retry'),
            onPressed: () => ref.invalidate(photoExifProvider(itemId)),
            child: Text(t.photoRetry),
          ),
        ),
      );
    } else if (value.value == null) {
      children.add(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: Gap.sm),
          child: SizedBox(
            height: 16,
            width: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    } else if (value.value!.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            photoWave3(PhotoWave3TextKeys.exifEmpty, '这张照片没有可显示的拍摄信息'),
            key: const Key('photo-wave3-exif-empty'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    } else {
      for (final f in value.value!.fields) {
        children.add(_ReadOnlyRow(_exifLabel(f.key), f.value));
      }
    }

    return Column(
      key: const Key('photo-wave3-exif'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

/// EXIF 字段名 → 中文标题（只覆盖 [kFotoExifKeys] 六个；认不出不会走到这里）。
String _exifLabel(String key) => switch (key) {
  'camera' => photoWave3(PhotoWave3TextKeys.exifCamera, '相机'),
  'aperture' => photoWave3(PhotoWave3TextKeys.exifAperture, '光圈'),
  'exposure_time' => photoWave3(PhotoWave3TextKeys.exifExposureTime, '曝光时间'),
  'focal_length' => photoWave3(PhotoWave3TextKeys.exifFocalLength, '焦距'),
  'iso' => photoWave3(PhotoWave3TextKeys.exifIso, 'ISO'),
  'lens' => photoWave3(PhotoWave3TextKeys.exifLens, '镜头'),
  _ => key,
};

/// 相册**播放设置**（P48）：HTTP / HTTP 端口 / 忽略证书错误。
///
/// 官方证据：`str_stream_http`、`str_stream_http_port`、`str_player_setting_desc`、
/// `str_video_play_cert_invalid_desc`、`error_http_port_incorrect`。全部是
/// **客户端**设置（服务端 API 不适用）：
///   * `useHttp` + 端口 → `foto_api.dart` 的 `FotoMediaUrlOverride` 把
///     `Download/download` · `Streaming/streaming` 直链改写成 `http://host:port/…`；
///   * `ignoreCert` → 相册视频改走**应用内 HTTP 客户端**取字节（证书由应用判断，
///     `DioFactory` 本来就放行自签），不再把 https 直链交给系统信任链。
class _PlaybackSettingsSection extends ConsumerStatefulWidget {
  const _PlaybackSettingsSection();

  @override
  ConsumerState<_PlaybackSettingsSection> createState() =>
      _PlaybackSettingsSectionState();
}

class _PlaybackSettingsSectionState
    extends ConsumerState<_PlaybackSettingsSection> {
  late final TextEditingController _port;
  String? _portError;

  @override
  void initState() {
    super.initState();
    final s = ref.read(photoPlaybackSettingsProvider);
    _port = TextEditingController(text: s.httpPort?.toString() ?? '');
  }

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  Future<void> _commitPort(String raw) async {
    final ok = await ref
        .read(photoPlaybackSettingsProvider.notifier)
        .setHttpPort(raw);
    if (!mounted) return;
    setState(() {
      _portError = ok
          ? null
          : photoG1(PhotoG1TextKeys.playbackPortInvalid, '端口不正确（应为 1–65535）');
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(photoPlaybackSettingsProvider);
    final notifier = ref.read(photoPlaybackSettingsProvider.notifier);
    return Column(
      key: const Key('photo-playback-settings'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(photoG1(PhotoG1TextKeys.playbackSettings, '播放设置')),
        DesignSwitchRow(
          key: const Key('photo-playback-http'),
          contentPadding: EdgeInsets.zero,
          title: Text(photoG1(PhotoG1TextKeys.playbackHttp, '用 HTTP 播放')),
          subtitle: Text(
            photoG1(
              PhotoG1TextKeys.playbackHttpDesc,
              '自签证书导致视频播不出来时，改用 HTTP 直链取流。',
            ),
          ),
          value: settings.useHttp,
          onChanged: (on) {
            notifier.setUseHttp(on);
            // 打开开关时把端口输入框的当前值也提交一次（空 = 只用 HTTP 不改端口）
            if (on) unawaited(_commitPort(_port.text));
          },
        ),
        if (settings.useHttp)
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm),
            child: TextField(
              key: const Key('photo-playback-http-port'),
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: photoG1(PhotoG1TextKeys.playbackHttpPort, 'HTTP 端口'),
                hintText: '$kPhotoHttpPortDefault',
                errorText: _portError,
              ),
              onSubmitted: _commitPort,
              onEditingComplete: () => _commitPort(_port.text),
            ),
          ),
        DesignSwitchRow(
          key: const Key('photo-playback-cert'),
          contentPadding: EdgeInsets.zero,
          title: Text(photoG1(PhotoG1TextKeys.playbackCert, '忽略证书错误')),
          subtitle: Text(
            photoG1(
              PhotoG1TextKeys.playbackCertDesc,
              '自签证书时忽略证书校验错误（视频由本应用取流后再播放）。',
            ),
          ),
          value: settings.ignoreCert,
          onChanged: notifier.setIgnoreCert,
        ),
      ],
    );
  }
}
