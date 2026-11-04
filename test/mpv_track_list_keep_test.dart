// r679 · `DA312` 的守门用例：**轨道表不许被中间态的空表覆盖**。
//
// 现场（iOS 模拟器 · mkv 双音轨 · libmpv 兜底）：
//   s256 before n=2 ids=[1, 2] selected=1
//   s256 after  n=0 ids=[]     selected=2      ← 切到第 2 条之后表空了
//   界面读数：`audio` 行值 = 「没有可选项」（`mediaNoTracks`），用户再也切不回去。
//
// 根因不是"选择失败"（`selected` 确实变成了 2），而是 mpv 在重开解码器过程中
// **先发一次空 `tracks` 事件**，`_applyTracks` 把它当真表落进去了。
// 修法是一条纯函数（`MpvPlayerAdapter.keepLastNonEmptyTracks`）：空表不覆盖非空表；
// 「这个文件本来就没有音轨」由 `load()` 清表表达（换文件 ≠ 同一文件的中间态）。
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/media/mpv_player_adapter.dart';

void main() {
  group('DA312 · 换音轨时轨道表不许被清空', () {
    test('非空 → 空：保留非空（中间态）', () {
      final prev = ['1', '2'];
      final out = MpvPlayerAdapter.keepLastNonEmptyTracks<String>(prev, const []);
      expect(out, prev);
      expect(identical(out, prev), isTrue, reason: '同一实例 ⇒ 调用方不必再判断');
    });

    test('非空 → 非空：用新表（换了文件/增删轨道）', () {
      final out = MpvPlayerAdapter.keepLastNonEmptyTracks<String>(
        const ['1', '2'],
        const ['3'],
      );
      expect(out, ['3']);
    });

    test('空 → 空：还是空（这个文件本来就没有音轨）', () {
      final out = MpvPlayerAdapter.keepLastNonEmptyTracks<String>(const [], const []);
      expect(out, isEmpty);
    });

    test('空 → 非空：装上新表（第一次拿到真表）', () {
      final out = MpvPlayerAdapter.keepLastNonEmptyTracks<String>(
        const [],
        const ['1', '2'],
      );
      expect(out, ['1', '2']);
    });

    test('反向验证：没有这条规矩，切轨后行值就会变「没有可选项」', () {
      // 模拟"直接赋值"的老行为：空表一来就落盘 ⇒ 表变空。
      var naive = <String>['1', '2'];
      naive = const []; // 老实现 `_audioTracks = [...]`
      expect(naive, isEmpty, reason: '老行为确实会空（这是缺陷复现）');
      // 新实现：
      var fixed = <String>['1', '2'];
      fixed = MpvPlayerAdapter.keepLastNonEmptyTracks<String>(fixed, const []);
      expect(fixed, ['1', '2']);
    });
  });
}
