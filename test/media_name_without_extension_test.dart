// ★ r645（DA244）：顶栏拿**容器格式**占位 —— 标题里带 `.AVI` 挤掉真正的名字，
// 副标题整整一行只写 `AVI`。判据分两层：
//   ① 纯函数层：`mediaNameWithoutExtension()` 只摘"像扩展名"的那一段，
//      隐藏文件 / 纯数字尾段 / 无点名字一律原样返回；
//   ② 接线层：文件预览页的顶栏在"正在播"分支里**必须真的调用它**，
//      并且副标题在"没有别的话要说"时整行不出现（静态读源码，反向验证过）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/media/media_source.dart';

void main() {
  group('DA244：给人看的名字只摘容器格式', () {
    test('常见容器扩展名都摘掉（大小写都认）', () {
      expect(
        mediaNameWithoutExtension('60招基础街球S01E01.AVI'),
        '60招基础街球S01E01',
      );
      expect(mediaNameWithoutExtension('clip.mkv'), 'clip');
      expect(mediaNameWithoutExtension('movie.MP4'), 'movie');
      expect(mediaNameWithoutExtension('a.b.c.webm'), 'a.b.c');
      expect(mediaNameWithoutExtension('sub.srt'), 'sub');
    });

    test('反向：不是扩展名的段一位都不许动', () {
      // 隐藏文件（`.nomedia`）——去掉点就变成另一个名字了
      expect(mediaNameWithoutExtension('.nomedia'), '.nomedia');
      // 尾段是纯数字（`第1.5集`）——数字不是扩展名
      expect(mediaNameWithoutExtension('第1.5集'), '第1.5集');
      // 没有点 / 以点结尾 / 尾段过长
      expect(mediaNameWithoutExtension('README'), 'README');
      expect(mediaNameWithoutExtension('trailing.'), 'trailing.');
      expect(mediaNameWithoutExtension('x.verylongext'), 'x.verylongext');
      // 尾段含连字符/空格（不是扩展名）
      expect(mediaNameWithoutExtension('name.part-2'), 'name.part-2');
    });

    test('接线层：预览页顶栏在播时用它，且空副标题不占行', () {
      final src = File(
        'lib/src/features/files/file_preview_page.dart',
      ).readAsStringSync();
      expect(
        src.contains('mediaNameWithoutExtension(name)'),
        isTrue,
        reason: '在播分支必须真的用这个函数，而不是又写一遍 split(".")',
      );
      expect(
        src.contains('if (subtitleParts.isNotEmpty)'),
        isTrue,
        reason: '副标题没有内容时不许留一行空白（旧实现恒写一行扩展名）',
      );
      // 反向判据：旧实现的那一行 `playing != null ? playingExt : …` 必须消失
      expect(src.contains('playingExt'), isFalse);

      // ★ DA245：**第二条标题路径**也必须走同一个函数。只修预览页 ⇒
      //   同一条素材竖屏不带扩展名、横过来又带回来。
      //   ★ r650（`DA250`）：那条路径已从「常驻 AppBar」搬到**播放器内的浮层顶栏**
      //   （`media-top-bar`），标题取 `_currentSource`（跟随换集/续播）—— 判据不变：
      //   **必须调用同一个函数**，不许又抄一遍 `split('.')`。
      final full = File(
        'lib/src/features/media/media_player_view.dart',
      ).readAsStringSync();
      expect(
        full.contains('mediaNameWithoutExtension(_currentSource.displayName)'),
        isTrue,
        reason: 'DA245 + DA250：浮层顶栏标题必须与预览页同源',
      );
    });
  });
}
