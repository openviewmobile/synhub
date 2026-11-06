// 219（M67）「离线文件」页：只读本地登记清单 + 取消登记。
//
// 语义/范围见 `file_offline_pin.dart` 顶部（纯客户端；不假装做离线缓存引擎）。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/drive_entry_dto.dart' show driveHumanSize;
import 'file_offline_pin.dart';
import 'file_providers.dart';
import 'file_row.dart' show formatFileTime;
import 'filestation_g4_text.dart';

class FileOfflinePage extends ConsumerStatefulWidget {
  const FileOfflinePage({super.key});

  @override
  ConsumerState<FileOfflinePage> createState() => _FileOfflinePageState();
}

class _FileOfflinePageState extends ConsumerState<FileOfflinePage> {
  @override
  void initState() {
    super.initState();
    // 落盘清单读回内存（读完自动刷新）
    Future<void>.microtask(
      () => ref.read(offlinePinProvider.notifier).preload(),
    );
  }

  /// ★ 302：把一条登记**真下到本机**，成功后回填 `localPath`
  /// （清单随之显示"已缓存"，SAF 索引也才收录它）。
  Future<void> _cache(OfflinePinEntry entry) async {
    final cached = await ref.read(offlineCacherProvider).cache(
      path: entry.path,
      name: entry.name,
    );
    if (!mounted) return;
    if (!cached.ok) {
      AppSnack.show(
        context,
        fsG4Fill(FsG4TextKeys.offlineCacheFailed, '已登记，但缓存失败：{reason}', {
          'reason': cached.error ?? '未知原因',
        }),
        error: true,
      );
      return;
    }
    await ref.read(offlinePinProvider.notifier).setLocalPath(
      entry.path,
      cached.localPath,
    );
    if (!mounted) return;
    AppSnack.show(
      context,
      fsG4Fill(FsG4TextKeys.offlineCached, '已缓存到本机（{size}）', {
        'size': driveHumanSize(cached.bytes),
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final items = ref.watch(offlinePinProvider);
    final usage = offlinePinUsage(items);
    return Scaffold(
      backgroundColor: hud.bg,
      body: SafeArea(
          child: Column(
            key: const Key('file-offline-page'),
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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            fsG4(FsG4TextKeys.offlineTitle, '离线文件'),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          if (items.isNotEmpty)
                            Text(
                              fsG4Fill(
                                FsG4TextKeys.offlineCount,
                                '共 {count} 项',
                                {'count': '${items.length}'},
                              ),
                              style: Theme.of(
                                context,
                              ).textTheme.labelSmall?.copyWith(color: hud.dim),
                            ),
                          // 219 的「容量提示」：登记文件的原始大小之和。
                          // 语义边界写进 secondary 行：这是登记值，不是本机已占用。
                          if (items.isNotEmpty && usage.knownCount > 0)
                            Text(
                              key: const Key('file-offline-capacity'),
                              usage.hasUnknown
                                  ? fsG4Fill(
                                      FsG4TextKeys.offlineTotalPartial,
                                      '合计 {size}（另有 {count} 项大小未知）',
                                      {
                                        'size': driveHumanSize(
                                          usage.totalBytes,
                                        ),
                                        'count': '${usage.unknownCount}',
                                      },
                                    )
                                  : fsG4Fill(
                                      FsG4TextKeys.offlineTotal,
                                      '合计 {size}',
                                      {
                                        'size': driveHumanSize(
                                          usage.totalBytes,
                                        ),
                                      },
                                    ),
                              style: Theme.of(
                                context,
                              ).textTheme.labelSmall?.copyWith(color: hud.dim),
                            ),
                        ],
                      ),
                    ),
                    if (items.isNotEmpty)
                      IconButton(
                        key: const Key('file-offline-clear'),
                        tooltip: fsG4(FsG4TextKeys.offlineRemove, '移出离线'),
                        icon: const Icon(Icons.delete_sweep_outlined),
                        onPressed: () =>
                            ref.read(offlinePinProvider.notifier).clear(),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: items.isEmpty
                    ? AppEmptyState(
                        key: const Key('file-offline-empty'),
                        icon: Icons.cloud_off_outlined,
                        title: fsG4(FsG4TextKeys.offlineEmpty, '还没有离线文件'),
                        message: fsG4(
                          FsG4TextKeys.offlineEmptyBody,
                          '在文件菜单里选「加入离线文件」，之后就能在这里找到它。',
                        ),
                      )
                    // ListTile 的底色/水波纹画在最近的 Material 上；
                    // `FieldBackdrop` 中间夹了 ColoredBox → 补一层透明 Material
                    // 把链路接回去（仓库既有写法，避免 debug 断言）。
                    : Material(
                        type: MaterialType.transparency,
                        child: ListView.separated(
                          key: const Key('file-offline-list'),
                          itemCount: items.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final e = items[i];
                            return DesignRowTile(
                              key: Key('file-offline-entry-${e.path}'),
                              leading: Icon(
                                e.hasLocalCopy
                                    ? Icons.offline_pin
                                    : Icons.cloud_download_outlined,
                              ),
                              title: Text(e.name),
                              subtitle: Text(
                                [
                                  // ★ 302：登记 ≠ 已缓存。这里如实标出本地有没有字节
                                  // （官方 `Pin.mLocalPath` 空/非空就是这两态）。
                                  e.hasLocalCopy
                                      ? fsG4Fill(
                                          FsG4TextKeys.offlineCached,
                                          '已缓存到本机（{size}）',
                                          {'size': driveHumanSize(e.size)},
                                        )
                                      : fsG4(
                                          FsG4TextKeys.offlineNotCached,
                                          '未缓存',
                                        ),
                                  if (e.size > 0) driveHumanSize(e.size),
                                  if (e.pinnedAt > 0)
                                    formatFileTime(e.pinnedAt, t: context.t),
                                  e.path,
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: hud.dim),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // ★ 302：没缓存上（首次失败/老版本登记）时给重试入口，
                                  // 否则"未缓存"就是个死状态。
                                  if (!e.hasLocalCopy)
                                    IconButton(
                                      key: Key('file-offline-cache-${e.path}'),
                                      tooltip: fsG4(
                                        FsG4TextKeys.offlineCacheNow,
                                        '缓存到本机',
                                      ),
                                      icon: const Icon(
                                        Icons.download_for_offline_outlined,
                                      ),
                                      onPressed: () => _cache(e),
                                    ),
                                  IconButton(
                                    key: Key('file-offline-unpin-${e.path}'),
                                    tooltip: fsG4(
                                      FsG4TextKeys.offlineUnpin,
                                      '移出离线',
                                    ),
                                    icon: const Icon(
                                      Icons.remove_circle_outline,
                                    ),
                                    onPressed: () => ref
                                        .read(offlinePinProvider.notifier)
                                        .unpin(e.path),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
              ),
            ],
          ),
        ),
    );
  }
}
