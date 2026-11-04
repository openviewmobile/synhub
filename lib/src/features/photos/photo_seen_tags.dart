// 相册**本机见过的标签**（纯本地记忆；服务端没有可用来源时补台）。
//
// 为什么要它（r412 · DA70，现场读到的原始事实见 `tool/probe_r412_photo_tags.dart`
// 与 `docs/evidence-r412/nas/r412_probe_tags_persons.log`）：
//   * `Browse.GeneralTag/list` → `{"list":[]}`（v1 / v2 都空，连**官方 APK
//     2.4.0-644 的逐字调用形态** `version=1 & additional=json(["thumbnail"])`
//     也一样空 —— 参数不是原因）；
//   * `Browse.GeneralTag/count` → `{"count":0}`、`get{id:[1]}` → `{"list":[]}`；
//   * 但 `suggest{keyword:"h"}` → `{"list":[{"id":1,"name":"huihubtag"}]}`，
//     且 `Item/list_with_filter{general_tag_id:[1]}` **能过滤出那张照片**。
// ⇒ 标签**确实存在**，只是 `list/count/get` 这一族在这台 NAS 上恒空。
//
// 后果（**本 App 内的自相矛盾**，不是服务端的错，但用户看得见）：
// 标签弹层早就因为同一个现场事实改用 `suggest`（`photo_tag_sheet.dart` 头注），
// 而**标签浏览页**只认 `list` ⇒ 用户在本 App 里给照片打过的标签，
// 在本 App 的标签页里**永远看不到**（页面上写「还没有标签」）。
//
// 修法口径（**补充，不是替代**）：
//   * 服务端 `list` 给的就以服务端为准；
//   * 只在服务端列表**为空**时，把本机"见过"的标签补进列表，
//     并在页面上**如实写一句来源说明**（`photoTagsLocalNote`）—— 不静默降级。
//   * 记住的时机 = 真正见过它的那两次交互：`suggest` 联想结果、`create` 新建结果。
//
// 编解码是纯函数（便于单测）；落盘走 `photoPrefsStoreProvider`（值不是秘密，
// 与最近搜索/网格密度同一套存储）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dto/foto_dto.dart';
import 'photo_prefs_store.dart';

/// 落盘 key（改字符串会让用户旧记忆读不回来）。
const String kPhotoSeenTagsSlot = 'photo_seen_tags_v1';

/// 最多记多少条（防呆上限；本 NAS 级别的标签数远小于此）。
const int kPhotoSeenTagsLimit = 200;

/// 一条"本机见过"的标签：`space` 用来隔离个人/共享空间（两边的 id 可能撞）。
class PhotoSeenTag {
  const PhotoSeenTag({
    required this.space,
    required this.id,
    required this.name,
    this.count = 0,
  });

  final String space;
  final String id;
  final String name;
  final int count;

  Map<String, dynamic> toJson() => {
    'space': space,
    'id': id,
    'name': name,
    'count': count,
  };

  static PhotoSeenTag? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, dynamic>();
    final space = j['space'];
    final id = j['id'];
    if (space is! String || id is! String || space.isEmpty || id.isEmpty) {
      return null;
    }
    final name = j['name'];
    final count = j['count'];
    return PhotoSeenTag(
      space: space,
      id: id,
      name: name is String ? name : id,
      count: count is int ? count : 0,
    );
  }
}

/// 落盘编码（JSON 数组，裁到上限）。
String encodePhotoSeenTags(List<PhotoSeenTag> tags) =>
    jsonEncode(tags.take(kPhotoSeenTagsLimit).map((e) => e.toJson()).toList());

/// 落盘解码：认不出就回空列表（**绝不**抛 —— 本地记忆坏掉不该让相册崩）。
List<PhotoSeenTag> decodePhotoSeenTags(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final out = <PhotoSeenTag>[];
    final seen = <String>{};
    for (final e in decoded) {
      final tag = PhotoSeenTag.fromJson(e);
      if (tag == null) continue;
      if (!seen.add('${tag.space}:${tag.id}')) continue;
      out.add(tag);
      if (out.length >= kPhotoSeenTagsLimit) break;
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// 把"本机见过"的标签并进服务端列表：**服务端在前、顺序不动**，
/// 服务端没有的（按 id 判重）追加在后面并按名字排序（保证多次渲染稳定）。
List<FotoTagDto> mergePhotoTags({
  required List<FotoTagDto> server,
  required Iterable<PhotoSeenTag> seen,
  required String space,
}) {
  final have = {for (final e in server) e.id};
  final extra = <FotoTagDto>[
    for (final e in seen)
      if (e.space == space && !have.contains(e.id))
        FotoTagDto(id: e.id, name: e.name, count: e.count),
  ]..sort((a, b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.id.compareTo(b.id);
  });
  return [...server, ...extra];
}

/// 标签页上要显示的那一份（服务端 ∪ 本机见过）。
///
/// `serverIsEmptyButLocal` 为真时页面要显示来源说明 —— 这就是"不静默"的判据。
typedef PhotoTagView = ({
  List<FotoTagDto> tags,
  bool serverIsEmptyButLocal,
});

PhotoTagView photoTagView({
  required List<FotoTagDto> server,
  required Iterable<PhotoSeenTag> seen,
  required String space,
}) {
  // **只在服务端列表为空时补台**：服务端给了数据就一律以服务端为准
  // （不是"并集" —— 并集会让我们把服务端已经不再列的旧记忆当成现状展示）。
  if (server.isNotEmpty) {
    return (tags: server, serverIsEmptyButLocal: false);
  }
  final merged = mergePhotoTags(server: server, seen: seen, space: space);
  return (
    tags: merged,
    serverIsEmptyButLocal: merged.isNotEmpty,
  );
}

/// 本机见过的标签（最近记住的在前）。
final photoSeenTagsProvider =
    NotifierProvider<PhotoSeenTagsNotifier, List<PhotoSeenTag>>(
      PhotoSeenTagsNotifier.new,
    );

class PhotoSeenTagsNotifier extends Notifier<List<PhotoSeenTag>> {
  /// 用户是否已经改过（改过之后异步恢复不许把新记忆冲掉）。
  bool _touched = false;

  @override
  List<PhotoSeenTag> build() {
    unawaited(_restore());
    return const [];
  }

  Future<void> _restore() async {
    final raw = await ref.read(photoPrefsStoreProvider).read(kPhotoSeenTagsSlot);
    if (!ref.mounted || _touched) return;
    final restored = decodePhotoSeenTags(raw);
    if (restored.isNotEmpty) state = restored;
  }

  /// 当前空间里本机见过的标签。
  List<PhotoSeenTag> forSpace(String space) => [
    for (final e in state)
      if (e.space == space) e,
  ];

  /// 记住一批刚见过的标签（`suggest` 联想 / `create` 新建 / 服务端列表）。
  Future<void> remember(String space, Iterable<FotoTagDto> tags) async {
    final list = [
      for (final e in tags)
        if (e.id.isNotEmpty) e,
    ];
    if (list.isEmpty || space.isEmpty) return;
    _touched = true;
    // 最近在前：新来的提到最前，同 (space,id) 去重并刷新 name/count。
    final fresh = <String, PhotoSeenTag>{
      for (final e in list)
        '$space:${e.id}': PhotoSeenTag(
          space: space,
          id: e.id,
          name: e.name.isEmpty ? e.id : e.name,
          count: e.count,
        ),
    };
    final next = <PhotoSeenTag>[
      ...fresh.values,
      for (final e in state)
        if (!fresh.containsKey('${e.space}:${e.id}')) e,
    ];
    if (next.length > kPhotoSeenTagsLimit) {
      next.removeRange(kPhotoSeenTagsLimit, next.length);
    }
    state = next;
    await ref
        .read(photoPrefsStoreProvider)
        .write(kPhotoSeenTagsSlot, encodePhotoSeenTags(next));
  }
}
