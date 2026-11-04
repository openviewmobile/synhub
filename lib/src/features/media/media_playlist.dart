// 「上一个 / 下一个」用的**播放列表**构造（纯逻辑层）。
//
// 这一层**不许** import flutter / package:flutter / l10n（同 `media_source.dart`）。
// 只做三件事，全是纯函数：
//   1. 文件名 → 媒体类型（视频 / 音频 / 不是媒体）；
//   2. 一个目录的条目 → **按自然序排好的同类型播放列表**；
//   3. 当前文件在列表里的位置 + 首尾边界（第一个禁用"上一个"、最后一个禁用"下一个"）。
//
// 为什么播放列表在 **Dart 侧**算而不是原生侧：
//   * 目录内容只有 FileStation 的 `List.list` 知道，原生播放器拿到的是裸 URL；
//   * 排序规则（自然序、同目录、同类型）是产品行为，应该能被离线单测钉死；
//   * 原生侧只负责"按我给好的顺序播"，`seekToNext/PreviousMediaItem` 的语义就够。
library;

import '../../data/dto/file_entry_dto.dart';
import 'media_source.dart';

/// 视频扩展名（**播放器能解码的比"预览页愿意内嵌的"更宽**：这里跟着
/// ExoPlayer 走，硬解不支持的容器它自己会报 `decodeFailed` → 回退面板）。
const Set<String> kVideoExtensions = {
  'mp4',
  'm4v',
  'mov',
  'mkv',
  'webm',
  'avi',
  'flv',
  'f4v',
  'ts',
  'm2ts',
  'mts',
  'mpg',
  'mpeg',
  'vob',
  'wmv',
  'asf',
  '3gp',
  '3g2',
  'ogv',
  'rmvb',
  'divx',
};

/// 音频扩展名
const Set<String> kAudioExtensions = {
  'mp3',
  'wav',
  'aac',
  'm4a',
  'ogg',
  'oga',
  'opus',
  'flac',
  'wma',
  'aiff',
  'aif',
  'ape',
  'mka',
  'amr',
  'ac3',
  'dts',
  'mid',
  'm4b',
};

/// 文件名的扩展名（小写；没有扩展名 → 空串）
String fileNameExtension(String name) {
  final i = name.lastIndexOf('.');
  if (i <= 0 || i == name.length - 1) return '';
  return name.substring(i + 1).toLowerCase();
}

/// 文件名去掉最后一个扩展名（`a.b.mp4` → `a.b`；没有扩展名 → 原样）
String fileNameStem(String name) {
  final i = name.lastIndexOf('.');
  if (i <= 0) return name;
  return name.substring(0, i);
}

/// 文件名 → 媒体类型（不是媒体 → null）
MediaKind? mediaKindOfName(String name) {
  final ext = fileNameExtension(name);
  if (kVideoExtensions.contains(ext)) return MediaKind.video;
  if (kAudioExtensions.contains(ext)) return MediaKind.audio;
  return null;
}

/// FileStation 路径的父目录（`/a/b.mp4` → `/a`；根下的文件 → `/`）
String parentPathOf(String path) {
  final i = path.lastIndexOf('/');
  if (i <= 0) return '/';
  return path.substring(0, i);
}

/// 自然序比较：数字段按**数值**比，其余按小写字典序。
///
/// 这样 `ep2 < ep10`（纯字典序会反过来），`E01` 和 `e01` 视为等价（再退回原串
/// 保证稳定）。返回负数 / 0 / 正数，语义同 `Comparable.compareTo`。
int compareNatural(String a, String b) {
  final la = a.toLowerCase();
  final lb = b.toLowerCase();
  var i = 0;
  var j = 0;
  while (i < la.length && j < lb.length) {
    final ca = la.codeUnitAt(i);
    final cb = lb.codeUnitAt(j);
    final da = _isDigit(ca);
    final db = _isDigit(cb);
    if (da && db) {
      // 吃掉前导 0 之外的整段数字
      var i2 = i;
      while (i2 < la.length && _isDigit(la.codeUnitAt(i2))) {
        i2++;
      }
      var j2 = j;
      while (j2 < lb.length && _isDigit(lb.codeUnitAt(j2))) {
        j2++;
      }
      final na = la.substring(i, i2);
      final nb = lb.substring(j, j2);
      final sa = na.replaceFirst(RegExp(r'^0+(?=\d)'), '');
      final sb = nb.replaceFirst(RegExp(r'^0+(?=\d)'), '');
      if (sa.length != sb.length) return sa.length - sb.length;
      final cmp = sa.compareTo(sb);
      if (cmp != 0) return cmp;
      i = i2;
      j = j2;
      continue;
    }
    if (ca != cb) return ca - cb;
    i++;
    j++;
  }
  final rest = (la.length - i) - (lb.length - j);
  if (rest != 0) return rest;
  // 大小写不同但小写相同 → 用原串稳定排序，避免同目录里两条不同文件比较结果
  // 为 0 导致顺序随机。
  return a.compareTo(b);
}

bool _isDigit(int code) => code >= 0x30 && code <= 0x39;

/// 一个目录的条目 → 同类型、自然序的播放列表（目录项与异类文件被丢掉）
///
/// [entries] 通常是 `FileStation.List.list` 对**当前文件所在目录**的结果；
/// 如果是别处的条目（路径前缀不同）也会被保留 —— 这里不做路径过滤，因为
/// Drive 的 path 是 `drive:<file_id>` 这种非路径形状，过滤反而会误杀。
/// 调用方只需要把对的目录传进来。
List<FileEntryDto> buildMediaPlaylist({
  required List<FileEntryDto> entries,
  required MediaKind kind,
}) {
  final seen = <String>{};
  final out = <FileEntryDto>[];
  for (final e in entries) {
    if (e.isDir || e.name.isEmpty) continue;
    if (mediaKindOfName(e.name) != kind) continue;
    if (!seen.add(e.path)) continue;
    out.add(e);
  }
  out.sort((a, b) => compareNatural(a.name, b.name));
  return out;
}

/// 当前文件在列表里的下标（不在列表里 → -1）
int playlistIndexFor(List<FileEntryDto> items, String path) {
  for (var i = 0; i < items.length; i++) {
    if (items[i].path == path) return i;
  }
  return -1;
}

/// 把"当前文件"保证放进列表：不在就按自然序插进去
///
/// 场景：`List.list` 偶发漏项 / 分页没取全 / 当前文件是刚上传的（列表缓存旧）。
/// 少了这一步，用户会看到"当前播的这首不在列表里"，上一个/下一个直接失效。
List<FileEntryDto> ensureInPlaylist(
  List<FileEntryDto> items,
  FileEntryDto entry,
) {
  if (entry.isDir || entry.path.isEmpty) return items;
  if (playlistIndexFor(items, entry.path) >= 0) return items;
  final out = [...items, entry];
  out.sort((a, b) => compareNatural(a.name, b.name));
  return out;
}

/// 上一个可用？（第一个 / 不在列表里 → false）
bool hasPreviousIn(List<FileEntryDto> items, int index) =>
    items.isNotEmpty && index > 0 && index < items.length;

/// 下一个可用？（最后一个 / 不在列表里 → false）
bool hasNextIn(List<FileEntryDto> items, int index) =>
    items.isNotEmpty && index >= 0 && index < items.length - 1;

/// `index` 前后移动 `delta` 后的下标（**夹在 [0, length-1]**，空列表 → -1）
///
/// 与界面按钮的禁用态用同一套夹取规则：禁用只是"按钮点不动"，即使被程序化调用
/// 也不会越界。
int clampPlaylistIndex(int index, int delta, int length) {
  if (length <= 0) return -1;
  final next = index + delta;
  if (next < 0) return 0;
  if (next > length - 1) return length - 1;
  return next;
}
