// Drive「分类浏览」（D23，官方 Home 页的四个媒体分类图标）。
//
// ★ 第 205 轮取证结论（**没有新 API，也不猜参数**）：
//   * 权威 `webapi/SYNO.SynologyDrive.lib` 的 `Files` **v1–v11 都没有
//     category 类方法**；官方 Drive **3.9.0-1113** 反编译出来的
//     `api/ApiSynoDriveFiles$Method` 枚举与权威表逐项一致（含
//     `list/recent/search/list_starred/list_labelled/list_backup_tasks` 等），
//     同样**没有** category 方法；
//   * `file_type` 在 3.9.0 的全部 smali 里**零命中**（只在 2018 版 Web UI
//     `drive/synodrive_common.js` 的 `fillSearchType` 里，取值
//     `image/audio/video/document/custom`）；
//   * 官方 App 里确有这个功能：资源字符串 #5061「Access photos, documents,
//     audio, and videos via category icons on the Home page」、#6050
//     「Show category icons」，埋点 `UdcEvent$ViewTypeValue` 里有
//     `category_photo` / `category_video` / `category_audio` / `category_doc`；
//   * `model/data/DriveCategory` 枚举是**左侧导航**（MyDrive/TeamFolder/
//     Computers/SharedWithMe/…/RecentBrowseImage/…），不是 Home 的媒体图标。
//
// ⇒ 所以官方就是**客户端分组**：把已列出的条目按扩展名归类，不额外发
//   带 `file_type` 的请求（官方 3.9.0 根本不发这个参数）。
//   本页照此实现：数据源用已实现的 `Files/recent`（v3，真机验过），
//   四个分类在本地按扩展名归类 + 过滤。
//
// 扩展名白名单**复用仓库里已有的、都有反编译出处的三张表**：
//   * 图片 `kImageExtensions`（`data/dto/file_prop_dto.dart`，来自聊天 APK
//     `FileProp.java`）；
//   * 视频 `kVideoExtensions` / 音频 `kAudioExtensions`
//     （`features/media/media_playlist.dart`，跟 ExoPlayer 解码能力对齐）。
// **「文档」不另立白名单**（那会是编造）：口径 = 不是目录、不是图片、不是
//   视频、不是音频 —— 一个完整划分，写进下方注释与用例。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';

import '../../core/provider_retry.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/drive_entry_dto.dart';
import '../../data/dto/file_prop_dto.dart' show kImageExtensions;
import '../files/drive_providers.dart' show driveApiProvider;
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../media/media_playlist.dart' show kAudioExtensions, kVideoExtensions;
import 'drive_g4_text.dart';

/// 官方 Home 页的四个媒体分类（埋点值见文件头注释）。
//
// ★★ DA11（r356 真机取证）：`i18nKey` **必须是字面常量**，不许再用
// `'driveCategory$name'` 这种**拼出来的 key**。
// 真机英文模式下四个 chip 曾显示中文（`照片 (1)` / `文档 (16)`），根因就是
// 拼出来的 key 没有任何一处登记：
//   * `test/i18n_coverage_test.dart` 的 `_usedKeys()` 正则只认
//     `字面 key`（`'([A-Za-z0-9_]+)'`，插值串不匹配）；
//   * `test/i18n_source_scan_test.dart` 只扫 `*Text(` 家族、且豁免翻译助手的第 2 实参；
//   ⇒ **两道守卫都看不见**，运行时 `dataText` 查不到就静默回落中文兜底。
// 现在 key 落到枚举字段上（字面量），并已四处齐全登记
// （zh ARB / en ARB / `gen-l10n` 产物 / `dataTextMap`）。
enum DriveMediaKind {
  photo('category_photo', '照片', 'driveCategoryPhoto'),
  video('category_video', '视频', 'driveCategoryVideo'),
  audio('category_audio', '音频', 'driveCategoryAudio'),
  document('category_doc', '文档', 'driveCategoryDocument');

  const DriveMediaKind(this.analyticsValue, this.zh, this.i18nKey);

  /// 官方 `UdcEvent$ViewTypeValue` 里的埋点值（一字不改）。
  final String analyticsValue;

  /// 中文兜底原文（没装翻译器时回落用）。
  final String zh;

  /// `dataTextMap` 登记键 —— **字面量**，免得守卫与运行时都看不见（DA11）。
  final String i18nKey;

  String label() => driveG4(i18nKey, zh);
}

/// 条目 → 分类。**目录返回 `null`**（目录不进任何媒体分类）。
///
/// 判据（全部来自官方/仓库既有反编译白名单，见文件头）：
///   图片 = `kImageExtensions`；视频 = `kVideoExtensions`；
///   音频 = `kAudioExtensions`；其余**非目录**一律算「文档」。
DriveMediaKind? driveMediaKindOf(DriveEntryDto entry) {
  if (entry.isDir) return null;
  final ext = entry.extension;
  if (kImageExtensions.contains(ext)) return DriveMediaKind.photo;
  if (kVideoExtensions.contains(ext)) return DriveMediaKind.video;
  if (kAudioExtensions.contains(ext)) return DriveMediaKind.audio;
  return DriveMediaKind.document;
}

/// 归类计数（只数非目录条目）。四个 key **始终存在**（哪怕是 0），
/// 这样 UI 上四个分类永远都在，与官方 Home 的固定四个图标一致。
Map<DriveMediaKind, int> driveMediaCounts(Iterable<DriveEntryDto> entries) {
  final out = <DriveMediaKind, int>{
    for (final k in DriveMediaKind.values) k: 0,
  };
  for (final e in entries) {
    final k = driveMediaKindOf(e);
    if (k != null) out[k] = out[k]! + 1;
  }
  return out;
}

/// 按分类过滤（顺序保持服务端返回的顺序）。
List<DriveEntryDto> driveMediaFilter(
  Iterable<DriveEntryDto> entries,
  DriveMediaKind kind,
) => [
  for (final e in entries)
    if (driveMediaKindOf(e) == kind) e,
];

/// 分类浏览的数据源：`Files/recent`（v3）。
///
/// 只**读**（§5.1 安全）；`limit` 取 500（官方 Home 的分类入口也是"最近
/// 用过的文件"聚合，不在服务端做全盘扫描）。
final driveCategoryItemsProvider =
    FutureProvider.autoDispose<List<DriveEntryDto>>((ref) async {
      final api = ref.watch(driveApiProvider);
      if (api == null) {
        throw StateError('not connected');
      }
      final r = await api.recent(limit: 500);
      return r.items;
    }, retry: noRetry);

/// 打开分类浏览页。
Future<void> openDriveCategoryPage(BuildContext context) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const DriveCategoryPage()),
    );

/// Drive 分类浏览页：顶部四个分类 chip（带计数），下方是该分类的文件列表。
class DriveCategoryPage extends ConsumerStatefulWidget {
  const DriveCategoryPage({super.key});

  @override
  ConsumerState<DriveCategoryPage> createState() => _DriveCategoryPageState();
}

class _DriveCategoryPageState extends ConsumerState<DriveCategoryPage> {
  DriveMediaKind _kind = DriveMediaKind.photo;

  @override
  void initState() {
    super.initState();
    // 进入「分类浏览」页（曝光）——只用稳定页面 id，不记条目内容
    trackView(UsageModule.drive, screen: 'category');
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final async = ref.watch(driveCategoryItemsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(driveG4('driveCategoryTitle', '分类浏览')),
      ),
      body: async.when(
        loading: () => const AppSkeleton(key: Key('drive-category-loading')),
        error: (e, _) => AppErrorView(
          key: const Key('drive-category-error'),
          detail: driveG4('driveCategoryError', '读取最近文件失败'),
          onRetry: () => ref.invalidate(driveCategoryItemsProvider),
        ),
        data: (items) {
          final counts = driveMediaCounts(items);
          final shown = driveMediaFilter(items, _kind);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: Gap.md,
                  vertical: Gap.sm,
                ),
                child: Row(
                  children: [
                    for (final k in DriveMediaKind.values) ...[
                      ChoiceChip(
                        key: Key('drive-category-chip-${k.name}'),
                        selected: _kind == k,
                        label: Text(context.t.driveCategoryChip(k.label(), counts[k] ?? 0)),
                        onSelected: (_) {
                          // 分类筛选偏好（photo/video/audio/document），只记稳定枚举值
                          trackFilter(
                            UsageModule.drive,
                            key: UsageDetailKeys.section,
                            value: k.name,
                          );
                          setState(() => _kind = k);
                        },
                      ),
                      const SizedBox(width: Gap.sm),
                    ],
                  ],
                ),
              ),
              Divider(height: 1, color: hud.line),
              Expanded(
                child: shown.isEmpty
                    ? AppEmptyState(
                        key: const Key('drive-category-empty'),
                        icon: Icons.filter_alt_off_outlined,
                        title: driveG4('driveCategoryEmpty', '这个分类里还没有文件'),
                        message: driveG4(
                          'driveCategoryEmptyHint',
                          '分类按文件扩展名在本地归类（官方 Home 的分类图标同款做法），只统计"最近"里的文件',
                        ),
                      )
                    : ListView.builder(
                        key: const Key('drive-category-list'),
                        itemCount: shown.length,
                        itemBuilder: (context, i) {
                          final e = shown[i];
                          return DesignRowTile(
                            key: Key('drive-category-item-${e.fileId}'),
                            leading: Icon(
                              _iconFor(_kind),
                              color: hud.dim,
                            ),
                            title: Text(
                              e.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              e.displayPath.isEmpty
                                  ? (e.humanSize.isEmpty
                                        ? e.extension
                                        : e.humanSize)
                                  : e.displayPath,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  IconData _iconFor(DriveMediaKind k) => switch (k) {
    DriveMediaKind.photo => Icons.image_outlined,
    DriveMediaKind.video => Icons.movie_outlined,
    DriveMediaKind.audio => Icons.music_note_outlined,
    DriveMediaKind.document => Icons.description_outlined,
  };
}
