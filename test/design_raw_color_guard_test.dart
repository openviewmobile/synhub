// DA154：`Colors.grey` 这类**裸颜色**不许出现在界面代码里（Office 画布除外）。
//
// 为什么：`Colors.grey` 不随主题变 —— 亮色下浅灰压白底几乎看不见，
// 暗色下又比 `dim` 亮，文字层级会跟设计稿对不上。界面次要文字一律
// `textTheme.bodySmall + DesignPalette.dim`。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DA154：features 里不许有裸 Colors.grey（office 画布除外）', () {
    final bad = <String>[];
    for (final f in Directory('lib/src/features')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final name = f.uri.pathSegments.last;
      // office 画布画的是"白纸"，纸上的灰是文档墨色，与 App 主题无关。
      if (name.startsWith('office_')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        if (l.trimLeft().startsWith('//')) continue; // 注释不算
        if (l.contains('Colors.grey')) {
          bad.add('${f.path}:${i + 1}');
        }
      }
    }
    expect(bad, isEmpty, reason: 'DA154：这些行还在用裸 Colors.grey → $bad');
  });
}
