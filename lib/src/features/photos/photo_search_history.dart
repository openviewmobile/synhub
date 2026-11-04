// 相册**最近搜索**：状态层 + 落盘（P24）。
//
// 官方证据（`photo-parity-audit.md:141`）：
//   * `id/search_history_keyword`、`search_history_folder_path`、
//     `search_history_space`、`menu/popup_menu_search_history`、
//     `string/delete_all_history`；
//   * 服务端 API **不适用** —— 官方也是**本地**保存历史（`Foto.Search.Search`
//     没有 history 方法）。
//
// 行为对齐官方到"关键词 + 最近在前 + 一键清除历史"这一层：
//   * 每次**提交**搜索（点放大镜 / 回车 / 点建议）记一条；
//   * 同样的词再搜一次 → 提到最前（大小写不敏感去重）；
//   * 上限 [kPhotoSearchHistoryLimit] 条，超出丢最旧；
//   * 搜索页**空态**列出历史，点一条直接重搜；`全部清除` 清空。
//
// 编解码是纯函数，便于单测；落盘走 [photoPrefsStoreProvider]。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'photo_prefs_store.dart';

/// 保留多少条最近搜索（官方历史列表也是有限条数）。
const int kPhotoSearchHistoryLimit = 10;

/// 记一条搜索词：去空白、去重（大小写不敏感）、提到最前、裁剪上限。
///
/// 空词**不入历史**（点空搜索框不该产生一条空记录）。
List<String> addPhotoSearchKeyword(List<String> current, String keyword) {
  final k = keyword.trim();
  if (k.isEmpty) return List<String>.of(current);
  final lower = k.toLowerCase();
  final out = <String>[
    k,
    for (final e in current)
      if (e.trim().toLowerCase() != lower) e,
  ];
  if (out.length > kPhotoSearchHistoryLimit) {
    out.removeRange(kPhotoSearchHistoryLimit, out.length);
  }
  return out;
}

/// 删掉一条（界面上的单条删除；认不出就原样返回）。
List<String> removePhotoSearchKeyword(List<String> current, String keyword) {
  final lower = keyword.trim().toLowerCase();
  return [
    for (final e in current)
      if (e.trim().toLowerCase() != lower) e,
  ];
}

/// 落盘编码（JSON 数组）。
String encodePhotoSearchHistory(List<String> history) =>
    jsonEncode(history.take(kPhotoSearchHistoryLimit).toList());

/// 落盘解码：认不出就回空列表（**绝不**抛，历史坏掉不该让搜索页崩）。
List<String> decodePhotoSearchHistory(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final out = <String>[];
    for (final e in decoded) {
      if (e is String && e.trim().isNotEmpty) out.add(e);
      if (out.length >= kPhotoSearchHistoryLimit) break;
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// 最近搜索历史（最近在前）。
final photoSearchHistoryProvider =
    NotifierProvider<PhotoSearchHistoryNotifier, List<String>>(
      PhotoSearchHistoryNotifier.new,
    );

class PhotoSearchHistoryNotifier extends Notifier<List<String>> {
  /// 用户是否已经改过（改过之后异步恢复不许把新历史冲掉）。
  bool _touched = false;

  @override
  List<String> build() {
    unawaited(_restore());
    return const [];
  }

  Future<void> _restore() async {
    final raw = await ref
        .read(photoPrefsStoreProvider)
        .read(kPhotoSearchHistorySlot);
    if (!ref.mounted || _touched) return;
    final restored = decodePhotoSearchHistory(raw);
    if (restored.isNotEmpty) state = restored;
  }

  /// 记一次提交的搜索词。
  Future<void> record(String keyword) async {
    _touched = true;
    final next = addPhotoSearchKeyword(state, keyword);
    if (next.length == state.length &&
        (next.isEmpty || next.first == state.first)) {
      return; // 没变化就不落盘
    }
    state = next;
    await _persist(next);
  }

  /// 删一条。
  Future<void> remove(String keyword) async {
    _touched = true;
    final next = removePhotoSearchKeyword(state, keyword);
    state = next;
    await _persist(next);
  }

  /// `delete_all_history`：清空历史。
  Future<void> clear() async {
    _touched = true;
    state = const [];
    await ref.read(photoPrefsStoreProvider).delete(kPhotoSearchHistorySlot);
  }

  Future<void> _persist(List<String> history) async {
    await ref
        .read(photoPrefsStoreProvider)
        .write(kPhotoSearchHistorySlot, encodePhotoSearchHistory(history));
  }
}
