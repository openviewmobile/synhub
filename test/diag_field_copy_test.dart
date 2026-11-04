// ★★★ 第 349 轮：**D76 的守卫** —— 「输入框 label 里塞了放不下的限定语」。
//
// 背景（真机像素 `04_diag.png`，`空洞穿透诊断` 页）：
//   `PUNCH CONTROL` 里那个 QuickConnect ID 输入框，屏上画出来是
//   `QuickConnect ID（可留空…`  —— Flutter 单行把它省略了，
//   **恰好切掉"仅跑前两步"这半句**（用户唯一能知道"留空会发生什么"的信息）。
//   原文案把控件名和限定语塞进**同一个 `labelText`**：
//     zh `QuickConnect ID（可留空，仅跑前两步）`
//     en `QuickConnect ID (optional; runs only the first two steps)`（54 字符，更长）
//   375dp 宽的输入框里还要让出 prefixIcon ⇒ 放不下。
//
// 修法（按 AGENTS §2.0.18：截断只能靠**改文案/给预算**，不许缩字号）：
//   `labelText` 只留**控件名**，限定语移进 `GlassTextField.helperText`
//   （该组件本来就支持，见 `glass_text_field.dart:23` / `:124`）。
//
// 这条用例**钉的是文案结构**，不是渲染 —— 渲染那条腿靠真机像素，
// 因为 §2.0.63 说得很清楚：**测试字体不是真机字体**，用量到的宽度判真机截断不可靠。
//
// ★ 反向验证（§2.0.29）：把两处 ARB 改回合并形态，
//   第 ① 条与第 ③ 条会立刻红 —— 见本文件末尾注释里的实测读数。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 读 ARB 并取出某个 key 的字符串值（ARB 是纯 JSON）。
Map<String, String> _arb(String path) {
  final raw = File(path).readAsStringSync();
  final json = jsonDecode(raw) as Map<String, dynamic>;
  final out = <String, String>{};
  for (final e in json.entries) {
    final v = e.value;
    if (v is String) out[e.key] = v;
  }
  return out;
}

void main() {
  group('D76 QuickConnect 诊断输入框的文案结构', () {
    // ★ 装置自证（仪器㉑ 的同型纪律）：先证明"文件真读到了"，
    //   否则下面所有断言都会在空 Map 上"通过"。
    test('装置自证：两份 ARB 都真读到了', () {
      final zh = _arb('lib/l10n/app_zh.arb');
      final en = _arb('lib/l10n/app_en.arb');
      expect(zh.length, greaterThan(1000),
          reason: 'ARB 读成空/极少 ⇒ 后面全是构造性假绿');
      expect(en.length, greaterThan(1000));
      expect(zh.containsKey('diagQcIdLabel'), isTrue);
      expect(en.containsKey('diagQcIdLabel'), isTrue);
    });

    test('★ DA5：① label 里不许再有全角/半角括号限定语（放不下就会被省略）', () {
      for (final locale in const ['zh', 'en']) {
        final arbs = _arb('lib/l10n/app_$locale.arb');
        final label = arbs['diagQcIdLabel']!;
        expect(label.contains('（') || label.contains('('), isFalse,
            reason: '$locale 的 diagQcIdLabel 又带上了限定语：`$label` '
                '—— 375dp 输入框放不下，会被省略成 `…`（D76 回归）');
      }
    });

    test('② helper 存在、非空，且**不是** label 的复制品', () {
      for (final locale in const ['zh', 'en']) {
        final arbs = _arb('lib/l10n/app_$locale.arb');
        final label = arbs['diagQcIdLabel']!;
        final helper = arbs['diagQcIdHelper'];
        expect(helper, isNotNull,
            reason: '$locale 缺 diagQcIdHelper —— 限定语被删了而不是搬走，'
                '用户再也看不到"留空会怎样"');
        expect(helper!.trim(), isNotEmpty, reason: '$locale 的 helper 是空的');
        expect(helper, isNot(equals(label)),
            reason: '$locale 的 helper 与 label 一模一样 ⇒ 搬了个寂寞');
      }
    });

    test('③ 限定语真的在 helper 里（"仅跑前两步"不许丢）', () {
      final zh = _arb('lib/l10n/app_zh.arb');
      final en = _arb('lib/l10n/app_en.arb');
      expect(zh['diagQcIdHelper'], contains('可留空'),
          reason: '中文 helper 应说明可留空');
      expect(zh['diagQcIdHelper'], contains('前两步'),
          reason: '中文 helper 应说明"仅跑前两步" —— 这是被截掉的那半句');
      // 英文：限定语语义要在，措辞不钉死到某个词上
      final enHelper = en['diagQcIdHelper']!;
      expect(enHelper.toLowerCase(), contains('optional'),
          reason: '英文 helper 应说明 optional');
      expect(enHelper.toLowerCase(), contains('two'),
          reason: '英文 helper 应说明只跑前两步');
    });

    test('④ gen-l10n 产物里两条 getter 都在（别只改 ARB 不生成）', () {
      final zhGen =
          File('lib/l10n/gen/app_localizations_zh.dart').readAsStringSync();
      final enGen =
          File('lib/l10n/gen/app_localizations_en.dart').readAsStringSync();
      for (final src in [zhGen, enGen]) {
        expect(src.contains('get diagQcIdLabel'), isTrue);
        expect(src.contains('get diagQcIdHelper'), isTrue,
            reason: 'ARB 改了但没跑 `flutter gen-l10n` ⇒ 运行时读不到 helper');
      }
    });
  });
}
