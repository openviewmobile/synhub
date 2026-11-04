// DA190：聊天「添加到会话」弹层的 7 个瓦片标签**必须在 72dp 预算内不被截断**。
//
// 真机来路（r589，亮色，Chat → My Space → `+`）：第 7 块显示成 **"Scheduled ..."** ——
// 标签直接用了页面标题 `chatScheduledTitle`（en "Scheduled messages"，18 字符），
// 而 `_AttachTile` 是 `SizedBox(width: 72)` + `maxLines: 1` + ellipsis。
// AGENTS §2.0.18：**固定预算里的文本截断只能靠改文案，不能靠缩字号**。
//
// 判据：① 瓦片标签必须是专用短标签（不许再拿页面标题凑）；
//      ② 每个标签在两种语言下都要 ≤ 14 字符（同屏 "Photo library" 13 字符实测能放下）；
//      ③ 反向自证：把 18 字符的旧标签塞进来必须被判据②拒绝。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

int _budget = 14;

List<String> _labels(String arb, List<String> keys) {
  final src = File('lib/l10n/$arb').readAsStringSync();
  final out = <String>[];
  for (final k in keys) {
    final m = RegExp('"$k"\\s*:\\s*"([^"]*)"').firstMatch(src);
    if (m != null) out.add(m.group(1)!);
  }
  return out;
}

const _attachKeys = [
  'chatAttachGallery',
  'profileEditTakePhoto',
  'chatAttachVideo',
  'chatAttachRecordVideo',
  'chatFilterFile',
  'chatFilterVote',
  'chatAttachSchedule',
];

void main() {
  test('① 定时瓦片用专用短标签，不再用页面标题', () {
    final src =
        File('lib/src/features/chat/chat_page.dart').readAsStringSync();
    expect(src.contains('label: t.chatAttachSchedule'), isTrue,
        reason: 'DA190：定时瓦片没有改用 chatAttachSchedule');
    // 页面标题本身仍应存在（别把键删了）
    final en = File('lib/l10n/app_en.arb').readAsStringSync();
    expect(en.contains('"chatScheduledTitle"'), isTrue);
  });

  test('② 7 个瓦片标签在 zh/en 下都 ≤ $_budget 字符', () {
    for (final arb in ['app_en.arb', 'app_zh.arb']) {
      final labels = _labels(arb, _attachKeys);
      expect(labels.length, _attachKeys.length,
          reason: '$arb 缺少瓦片标签键');
      final tooLong = <String>[];
      for (var i = 0; i < labels.length; i++) {
        if (labels[i].length > _budget) {
          tooLong.add('${_attachKeys[i]} = "${labels[i]}"（${labels[i].length}）');
        }
      }
      expect(tooLong, isEmpty, reason: '$arb 这些标签会超出 72dp：$tooLong');
    }
  });

  test('③ 反证：旧的 18 字符标签会被判据②拒绝', () {
    final en = File('lib/l10n/app_en.arb').readAsStringSync();
    final m = RegExp('"chatScheduledTitle"\\s*:\\s*"([^"]*)"').firstMatch(en);
    expect(m, isNotNull);
    expect(m!.group(1)!.length, greaterThan(_budget),
        reason: '反证失效：旧标签居然没超预算，说明判据量错了对象');
  });
}
