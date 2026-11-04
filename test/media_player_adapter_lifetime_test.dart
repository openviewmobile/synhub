// r690 · `DA329`：播放器页的适配器**不许**在异步尾巴里懒创建 / 读 `ref`。
//
// 现场（Linux 走查 · 视频页第一屏）：
//   `_loadSubtitleStyle()` 的异步尾巴 `_applySubtitleStyle()` 在页面
//   **已 dispose 之后**才跑；它读 `_adapter`，而 `_adapter` 当时是
//   `late final … = ref.read(mediaPlayerAdapterFactoryProvider)()` —— 惰性求值
//   ⇒ 触发 `ProviderScope.containerOf` 的
//   「Looking up a deactivated widget's ancestor is unsafe」，
//   **并且真的在临死时新建了一个 `MpvPlayerAdapter`**（播放器实例泄漏）。
//
// 修法（`lib/src/features/media/media_player_view.dart`）：
//   ① 适配器在 `initState` 里**立即**建好（`late final` 只赋一次值）；
//   ② `_applySubtitleStyle()` 开头 `if (!mounted) return;`。
//
// 这条用例是**结构守卫**：行为层的"dispose 之后不许读 provider"没法在
// 单测里稳定复现（时序相关），所以钉源码约束 + 用 `flutter analyze` 兜底。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src = File(
    'lib/src/features/media/media_player_view.dart',
  ).readAsStringSync();

  test('DA329 ① 适配器在 initState 里就建好（不是 late 惰性求值）', () {
    // 旧写法（缺陷本体）必须消失
    expect(
      src,
      isNot(contains('widget.adapter ?? ref.read(mediaPlayerAdapterFactoryProvider)()\n')),
      reason: '`late final _adapter = …ref.read…` 的惰性求值已在 r690 去掉',
    );
    // 新写法：initState 里显式赋值
    final initState = src.indexOf('void initState()');
    expect(initState, greaterThan(0));
    final assign = src.indexOf(
      '_adapter = widget.adapter ?? ref.read(mediaPlayerAdapterFactoryProvider)();',
    );
    expect(assign, greaterThan(initState), reason: '赋值必须在 initState 内');
    // `late final` 声明仍在（只赋一次值），但不许再带 `ref.read` 初始化器
    expect(src, contains('late final MediaPlayerAdapter _adapter;'));
  });

  test('DA329 ② 字幕样式的异步尾巴先看 mounted', () {
    final idx = src.indexOf('Future<void> _applySubtitleStyle() async {');
    expect(idx, greaterThan(0));
    final body = src.substring(idx, idx + 260);
    expect(body, contains('if (!mounted) return;'));
  });
}
