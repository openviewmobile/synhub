// 第 236 轮 · `DA180`（用户裁定 ③）：**标签不许被选项挤成竖排**。
//
// 真机（亮色，阅读设置弹层）：
//   `Line spacing` 被压成「Line / spacin / g」、`Background` 被压成「B / ac / kg / ro / un / d」，
//   每个字单独一行 —— 因为 `DesignRowTile(trailing: Wrap(ChoiceChip...))` 里
//   trailing 不限宽，标题列被挤到 ~40dp。
//
// 判据：这两个"多选项"设置行必须走**上下两段**的 `_PrefsChoiceRow`，
// 且 `DesignRowTile` 不许再把 ChoiceChip 塞进 `trailing`。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final f = File('lib/src/features/files/file_book_view.dart');
  late String code;
  setUpAll(() => code = f.readAsStringSync());

  test('装置自证：源码读到了', () {
    expect(f.existsSync(), isTrue);
    expect(code.length, greaterThan(50000));
  });

  test('多选项设置行使用上下两段布局（DA180）', () {
    expect(code.contains('class _PrefsChoiceRow'), isTrue, reason: '缺 _PrefsChoiceRow');
    final used = RegExp(r'_PrefsChoiceRow\(').allMatches(code).length;
    expect(used, greaterThanOrEqualTo(3), reason: '只见到 $used 处使用（定义 1 + 调用 ≥2）');
    // 两个"选项 ≥3"的行必须在调用点里
    expect(RegExp(r'_PrefsChoiceRow\([\s\S]{0,160}?readerLineHeight').hasMatch(code), isTrue);
    expect(RegExp(r'_PrefsChoiceRow\([\s\S]{0,160}?readerBackground').hasMatch(code), isTrue);
  });

  test('DesignRowTile 不许再把 ChoiceChip 塞进 trailing（会挤竖排）', () {
    final bad = RegExp(
      r'DesignRowTile\([\s\S]{0,400}?trailing:\s*(Wrap|Row)\(',
    );
    // 该文件里现在是 0 处；若有人回退成旧写法会在这里红
    final hits = <String>[];
    for (final m in bad.allMatches(code)) {
      final chunk = m.group(0)!;
      if (chunk.contains('ChoiceChip')) hits.add(chunk.split('\n').first);
    }
    expect(hits, isEmpty, reason: '这些行会挤成竖排：${hits.join(' | ')}');
  });

  test('反证：检测器对旧写法确实能命中', () {
    const old =
        'DesignRowTile(\n  title: Text(t.readerLineHeight),\n  trailing: Wrap(children: [ChoiceChip(label: Text("1.5"))]),\n)';
    expect(RegExp(r'DesignRowTile\([\s\S]{0,400}?trailing:\s*(Wrap|Row)\(').hasMatch(old), isTrue);
    expect(old.contains('ChoiceChip'), isTrue);
  });
}
