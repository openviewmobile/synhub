// 相册「地点 → 在地图中打开」的**弹层**（第一期 · 方案 A）。
//
// 只做四件事：
//   1. 如实说明手里有什么（**只有地名**时明确写"按地名搜索，不是精确定位"）；
//   2. 让用户选"用哪个地图服务"（可覆盖区域判定，选择落盘）；
//   3. "在地图中打开" —— 拼 URL 交给系统，**不发网络请求、不持有 key**；
//   4. "复制地名"。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'photo_map_links.dart';
import 'photo_map_prefs.dart';
import 'photo_map_text.dart';
import 'photo_map_tiles.dart';

/// 服务名（中文回落；多语言走 ARB key）
String photoMapServiceName(PhotoMapService s) => switch (s) {
  PhotoMapService.google => photoMap(
    PhotoMapTextKeys.serviceGoogle,
    'Google 地图',
  ),
  PhotoMapService.amap => photoMap(PhotoMapTextKeys.serviceAmap, '高德地图'),
  PhotoMapService.tencent => photoMap(PhotoMapTextKeys.serviceTencent, '腾讯地图'),
  PhotoMapService.baidu => photoMap(PhotoMapTextKeys.serviceBaidu, '百度地图'),
};

/// 打开弹层。
Future<void> showPhotoMapSheet(
  BuildContext context, {
  required String name,
  double? latitude,
  double? longitude,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (_) =>
      PhotoMapSheet(name: name, latitude: latitude, longitude: longitude),
);

/// 弹层本体（公开出来是为了能直接 pump 它做离线用例）。
class PhotoMapSheet extends ConsumerStatefulWidget {
  const PhotoMapSheet({
    super.key,
    required this.name,
    this.latitude,
    this.longitude,
  });

  final String name;
  final double? latitude;
  final double? longitude;

  @override
  ConsumerState<PhotoMapSheet> createState() => _PhotoMapSheetState();
}

class _PhotoMapSheetState extends ConsumerState<PhotoMapSheet> {
  @override
  void initState() {
    super.initState();
    // 读回用户上次手选的服务（和 `CalendarEnvNotifier.preload()` 同一约定）
    Future<void>.microtask(
      () => ref.read(photoMapServiceProvider.notifier).preload(),
    );
    // 读回「境外服务 + 精确坐标」的一次性告知是否已经确认过
    Future<void>.microtask(
      () => ref.read(photoMapOverseasConsentProvider.notifier).preload(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final target = PhotoMapTarget(
      name: widget.name,
      latitude: widget.latitude,
      longitude: widget.longitude,
    );
    final service = ref.watch(resolvedPhotoMapServiceProvider);
    final link = buildPhotoMapLink(service: service, target: target);
    final theme = Theme.of(context);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          key: const Key('photo-map-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              photoMapFill(PhotoMapTextKeys.sheetTitle, '在地图中打开「{name}」', {
                'name': target.name,
              }),
              style: theme.textTheme.titleMedium,
            ),
            // ---- 应用内地图（P21）：有坐标才画，自己拼瓦片、不依赖 GMS ----
            if (target.hasCoordinates) ...[
              const SizedBox(height: 10),
              PhotoTileMap(
                key: const Key('photo-map-inapp'),
                latitude: target.latitude!,
                longitude: target.longitude!,
                markers: [
                  PhotoMapMarker(
                    id: 'target',
                    latitude: target.latitude!,
                    longitude: target.longitude!,
                    label: target.name,
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            // ---- 徽标：**精确坐标** vs **按地名搜索**（两条路径必须一眼可分）----
            if (target.isUsable)
              Container(
                key: const Key('photo-map-badge'),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  target.hasCoordinates
                      ? photoMap(PhotoMapTextKeys.preciseBadge, '精确坐标')
                      : photoMap(PhotoMapTextKeys.nameSearchBadge, '按地名搜索'),
                  style: theme.textTheme.labelSmall,
                ),
              ),
            const SizedBox(height: 8),
            // ---- 诚实提示 ----
            //   * 有坐标：坐标是**敏感个人信息** → **默认不展示数字**，
            //     用户主动点「复制坐标」才拿得到（合规要求，见实施记录 §合规）；
            //   * 没有坐标：只能是"按地名搜索"，如实说不保证精确。
            Text(
              target.hasCoordinates
                  ? photoMap(
                      PhotoMapTextKeys.preciseNoNumbersHint,
                      '这条照片带精确坐标（WGS-84），会直接定位到拍摄点；'
                      '为保护隐私，默认不显示坐标数字（可点「复制坐标」）。',
                    )
                  : photoMap(
                      PhotoMapTextKeys.nameOnlyHint,
                      '这条地点只有地名、没有经纬度：地图应用会按「地名搜索」，'
                      '不保证落在精确位置。',
                    ),
              key: const Key('photo-map-hint'),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Text(
              photoMap(PhotoMapTextKeys.serviceLabel, '地图服务'),
              style: theme.textTheme.labelLarge,
            ),
            _ServiceTile(
              id: 'auto',
              title: photoMap(PhotoMapTextKeys.serviceAuto, '自动（跟随地区）'),
              subtitle: photoMapFill(
                PhotoMapTextKeys.autoResolved,
                '当前判定为：{service}',
                {
                  'service': photoMapServiceName(
                    defaultPhotoMapService(
                      countryCode: ref.watch(photoMapRegionCountryCodeProvider),
                    ),
                  ),
                },
              ),
              selected: ref.watch(photoMapServiceProvider) == null,
              onTap: () =>
                  ref.read(photoMapServiceProvider.notifier).setOverride(null),
            ),
            for (final s in PhotoMapService.values)
              _ServiceTile(
                id: s.id,
                title: photoMapServiceName(s),
                selected: ref.watch(photoMapServiceProvider) == s,
                onTap: () =>
                    ref.read(photoMapServiceProvider.notifier).setOverride(s),
              ),
            const SizedBox(height: 4),
            Text(
              photoMap(
                PhotoMapTextKeys.regionHint,
                '区域判定只看设备地区/时区，可能不准——上面可以手动改，改完会记住。',
              ),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (link.hasFallback && link.fallbackService != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  photoMapFill(
                    PhotoMapTextKeys.fallbackNote,
                    '{service} 没有免 key 的网页版；打不开时会回落到 {fallback} 网页。',
                    {
                      'service': photoMapServiceName(link.service),
                      'fallback': photoMapServiceName(link.fallbackService!),
                    },
                  ),
                  key: const Key('photo-map-fallback-note'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('photo-map-open'),
                    icon: const Icon(Icons.map_outlined),
                    label: Text(photoMap(PhotoMapTextKeys.openAction, '打开')),
                    onPressed: target.isUsable
                        ? () => _open(context, ref, link)
                        : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('photo-map-copy'),
                    icon: const Icon(Icons.copy_outlined),
                    label: Text(photoMap(PhotoMapTextKeys.copyName, '复制地名')),
                    onPressed: target.hasName
                        ? () async {
                            await Clipboard.setData(
                              ClipboardData(text: target.name),
                            );
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  photoMap(PhotoMapTextKeys.copied, '已复制'),
                                ),
                              ),
                            );
                          }
                        : null,
                  ),
                ),
              ],
            ),
            // 坐标是敏感个人信息 → 界面上**不渲染数字**；用户主动点这里才把
            // `lat,lon` 放进剪贴板（复制 = 用户自己的动作，不是我们展示）。
            if (target.hasCoordinates)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('photo-map-copy-coord'),
                  icon: const Icon(Icons.pin_drop_outlined),
                  label: Text(photoMap(PhotoMapTextKeys.copyCoord, '复制坐标')),
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(
                        text:
                            '${photoMapCoord(target.latitude!)},'
                            '${photoMapCoord(target.longitude!)}',
                      ),
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(photoMap(PhotoMapTextKeys.copied, '已复制')),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 打开：**先首选（App scheme）后回落（网页）**；两条都不行才提示失败。
  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    PhotoMapLink link,
  ) async {
    // 合规（见 docs/photo-precise-gps.md §合规）：坐标 = 行踪轨迹 = 敏感个人信息；
    // 把它交给**境外**服务（Google）属于**数据出境** → 首次必须一次性告知并取得
    // 同意，同意后记住、不再打扰。**境内**服务（高德 / 腾讯 / 百度）不弹。
    if (link.precise &&
        link.service == PhotoMapService.google &&
        !ref.read(photoMapOverseasConsentProvider)) {
      final agreed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const Key('photo-map-consent-dialog'),
          title: Text(
            photoMap(PhotoMapTextKeys.overseasConsentTitle, '把坐标发送给境外地图服务？'),
          ),
          content: Text(
            photoMapFill(
              PhotoMapTextKeys.overseasConsentBody,
              '坐标将发送给 {service}（境外服务，属数据出境）。同意后才会打开，'
              '且只告知这一次。',
              {'service': photoMapServiceName(link.service)},
            ),
          ),
          actions: [
            TextButton(
              key: const Key('photo-map-consent-refuse'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(
                photoMap(PhotoMapTextKeys.overseasConsentRefuse, '取消'),
              ),
            ),
            FilledButton(
              key: const Key('photo-map-consent-agree'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(
                photoMap(PhotoMapTextKeys.overseasConsentAgree, '同意并继续'),
              ),
            ),
          ],
        ),
      );
      // 拒了 → **一个 URL 都不打开**（保守：没同意就不出境）
      if (agreed != true) return;
      await ref.read(photoMapOverseasConsentProvider.notifier).grant();
      if (!context.mounted) return;
    }
    final result = await openPhotoMapLink(
      link,
      launcher: ref.read(photoMapLauncherProvider),
    );
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (!result.ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            photoMap(PhotoMapTextKeys.failed, '没能打开地图：请确认设备装了对应地图应用或浏览器。'),
          ),
        ),
      );
      return;
    }
    if (result.usedFallback && link.fallbackService != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            photoMapFill(
              PhotoMapTextKeys.fallbackNote,
              '{service} 没有免 key 的网页版；打不开时会回落到 {fallback} 网页。',
              {
                'service': photoMapServiceName(link.service),
                'fallback': photoMapServiceName(link.fallbackService!),
              },
            ),
          ),
        ),
      );
    }
  }
}

class _ServiceTile extends StatelessWidget {
  const _ServiceTile({
    required this.id,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
  });

  final String id;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => DesignRowTile(
    key: Key('photo-map-service-$id'),
    dense: true,
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle!),
    trailing: selected ? const Icon(Icons.check) : null,
    onTap: onTap,
  );
}
