// 相册网格**密度（列数）**：状态层 + 落盘（P4）。
//
// 官方证据（`photo-parity-audit.md:121` / `parity-recount-drive-photos.md:257`）：
//   * `layout/segment_view_mode`、`id/zoom`、`id/grid` —— 官方是**本地分段控件**
//     切换缩略图密度，APK 里**没有** pinch-to-zoom 字符串；
//   * 服务端 API **不适用**（纯客户端渲染）。
//
// 所以这里做的是官方那一套：用户选密度 → 所有网格按新列数渲染，选择**落盘**
// 以便下次进来还是原样。纯函数编解码单独提出，便于单测/纯 Dart 探针。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'photo_prefs_store.dart';

/// 可选的网格列数（官方 `segment_view_mode` 的多档密度）。
///
/// 2 = 大图（最少列）/ 5 = 密排（最多列）。默认 3 与原 `PhotoGrid.columns`
/// 默认值一致 —— 不改用户既有观感。
const List<int> kPhotoGridColumnChoices = <int>[2, 3, 4, 5];

/// 默认列数（等于 `PhotoGrid.columns` 的默认值 3）。
const int kPhotoGridColumnsDefault = 3;

/// 把任意输入收敛成合法列数（认不出 → 默认 3，不抛）。
int normalizePhotoGridColumns(Object? raw) {
  final n = raw is int ? raw : int.tryParse('${raw ?? ''}');
  if (n == null) return kPhotoGridColumnsDefault;
  if (kPhotoGridColumnChoices.contains(n)) return n;
  // 落盘值被改坏 / 版本迁移 → 就近夹到最近的合法档
  var best = kPhotoGridColumnChoices.first;
  for (final c in kPhotoGridColumnChoices) {
    if ((c - n).abs() < (best - n).abs()) best = c;
  }
  return best;
}

/// 落盘编码（就是十进制字符串；非合法值按 [normalizePhotoGridColumns] 收敛）。
String encodePhotoGridColumns(int columns) =>
    '${normalizePhotoGridColumns(columns)}';

/// 落盘解码（`null` / 空 / 垃圾 → 默认值）。
int decodePhotoGridColumns(String? raw) => raw == null || raw.trim().isEmpty
    ? kPhotoGridColumnsDefault
    : normalizePhotoGridColumns(raw);

/// 当前网格列数。跨页面共享（时间轴 / 相册 / 收藏 / 人物…全部同一份）。
final photoGridColumnsProvider =
    NotifierProvider<PhotoGridColumnsNotifier, int>(
      PhotoGridColumnsNotifier.new,
    );

class PhotoGridColumnsNotifier extends Notifier<int> {
  /// 用户是否已经改过（改过之后**绝不允许**异步恢复把选择冲掉）。
  bool _touched = false;

  @override
  int build() {
    // 先给默认值（同步、界面立刻可用），落盘值读回来后再刷新。
    unawaited(_restore());
    return kPhotoGridColumnsDefault;
  }

  Future<void> _restore() async {
    final raw = await ref
        .read(photoPrefsStoreProvider)
        .read(kPhotoGridColumnsSlot);
    if (!ref.mounted || _touched) return;
    final restored = decodePhotoGridColumns(raw);
    if (restored != state) state = restored;
  }

  /// 选一个密度档（界面调用）。非法值收敛到最近档。
  Future<void> setColumns(int columns) async {
    _touched = true;
    final next = normalizePhotoGridColumns(columns);
    if (next != state) state = next;
    await ref
        .read(photoPrefsStoreProvider)
        .write(kPhotoGridColumnsSlot, encodePhotoGridColumns(next));
  }
}
