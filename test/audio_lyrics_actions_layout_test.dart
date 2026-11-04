// **DA107**（r471）：歌词区两个动作按钮在窄屏被右缘切掉。
//
// 真机现象（可复算）：单曲页歌词区同时有「换一个歌词版本」与「Search lyrics online」
// 时，`Row(children: [Spacer(), …, searchButton])` 总宽超过可用宽度 ⇒
// 右边那个按钮**被屏幕右缘裁掉**（逐字读作 `Search lyrics o…`），既读不全也点不到。
// 修法：`Align + Wrap`（放得下靠右一行，放不下换行）。
//
// 本用例是**静态守卫**（该按钮行的几何由真机像素证明，见
// `docs/evidence-r471/device/r471_02_lyrics_actions_wrap.png`）；它防的是
// "以后有人把 Wrap 改回 Row + Spacer"这一种回归。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DA107：歌词动作行必须是 Wrap（不许回到 Row + Spacer 的溢出写法）', () {
    final src = File('lib/src/features/audio/audio_song_page.dart').readAsStringSync();

    expect(
      src.contains('Align(\n              alignment: Alignment.centerRight,\n              child: Wrap('),
      isTrue,
      reason: 'DA107：歌词区两个动作按钮要用 Align + Wrap（放不下换行），不是 Row + Spacer',
    );
    expect(
      src.contains('if (pickButton != null) pickButton,'),
      isTrue,
      reason: 'DA107：换版本按钮必须仍在同一组里（不要为了"不溢出"把它删掉）',
    );
    // 反向：歌词区不许再出现 `const Spacer(),` 跟着两个按钮这种旧写法
    final lyricsBlock = src.substring(src.indexOf('final pickButton'));
    expect(
      lyricsBlock.contains('Row(\n              children: [\n                const Spacer(),'),
      isFalse,
      reason: 'DA107：旧写法（Row + Spacer）会溢出，不许回归',
    );
  });
}
