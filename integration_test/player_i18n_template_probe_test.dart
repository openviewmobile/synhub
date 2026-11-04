// 第 64 轮（r64）探针：**`dataTextMap` 里的值必须是"模板"，不是"占位符名字"**。
//
// 为什么放在 `integration_test/` 而不是 `test/`：本轮（r64）的文件范围被限定为
// "自己的新文件只在 `integration_test/` 与 `docs/` 下"，而这是一个**纯 widget/单测**
// 探针（**不碰设备、不碰平台通道**）—— 用普通跑法即可：
//
//   flutter test integration_test/player_i18n_template_probe_test.dart
//
// ★★ **实测坑（r64 亲历，别重踩）**：`flutter test integration_test/<file>` 会被
//   Flutter 当成**集成测试目标**去部署 —— 它真的会 `assembleDebug` + `adb install`，
//   而且**会把设备上的 App 卸载掉（连数据一起没了，要重新登录）**。
//   r64 就是这么丢掉一次登录态的（详见 `docs/device-verification.md §⑫.8` 的教训 3、
//   `AGENTS §2.0.1`）。所以：
//   * **不要**在有登录态的设备上跑它；要跑就先备份/接受重登；
//   * 更稳的跑法：把它的断言当"纯 Dart 探针"用宿主 `dart run` 复刻，
//     或直接跑既有守卫 `test/i18n_coverage_test.dart`（同一族口径，纯 `test/`，不碰设备）。
//   * **不要**用 `flutter drive` / `tool/device_feature_suite.sh` 跑它。
//
// 它钉死的真机现象（`/tmp/r64_p33_enter.png`、`/tmp/r64_p10_fwd.png`）：
//   菜单第四项显示 `Speed speedx`、HUD 显示 `Forward n seconds` / `Volume n%` /
//   `Brightness n%` / `Back n seconds`。
// 根因：`'mediaSpeedValue': t.mediaSpeedValue('speed')` —— 生成 getter 把 `{speed}`
//   代成了字符串 `"speed"`，调用方随后的 `.replaceAll('{speed}', …)` 再也匹配不到。
//
// 断言口径（与 `docs/launch-readiness.md §4.1-3` 一致）：
//   ① 这 5 条媒体文案的英文值必须仍是**带占位符的模板**，替换后是**人话**（反向验证）；
//   ② **全表普查**：凡是 ARB 里有占位符的键，`dataTextMap` 的值里**必须**出现 `{name}`；
//      一个都不许是"裸名"（这就是那 76 条的通行判据）。
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/l10n/gen/app_localizations_en.dart';

void main() {
  final map = dataTextMap(AppTextEn());

  test('① 媒体 HUD/菜单的 5 条文案：替换后是人话，不是 "speedx"/"n%"', () {
    // 真机 before（像素）："Speed speedx" / "Forward n seconds" / "Back n seconds"
    // / "Volume n%" / "Brightness n%"。
    expect(
      map['mediaSpeedValue']!.replaceAll('{speed}', '1.5'),
      'Speed 1.5x',
    );
    expect(
      map['mediaForwardN']!.replaceAll('{n}', '10'),
      'Forward 10 seconds',
    );
    expect(
      map['mediaBackwardN']!.replaceAll('{n}', '10'),
      'Back 10 seconds',
    );
    expect(map['mediaVolumePercent']!.replaceAll('{n}', '40'), 'Volume 40%');
    expect(
      map['mediaBrightnessPercent']!.replaceAll('{n}', '40'),
      'Brightness 40%',
    );
  });

  test('② 反向验证：裸占位符名（修复前的写法）确实会产出 "Speed speedx"', () {
    // 把模板换成"裸名"，复现真机那一行 —— 证明这条判据真的抓得到这个缺陷。
    final buggy = AppTextEn().mediaSpeedValue('speed');
    expect(buggy, 'Speed speedx');
    expect(buggy.replaceAll('{speed}', '1.5'), 'Speed speedx'); // 替换不再生效
  });

  test('③ 全表普查：带占位符的键，值里必须留着 {name}', () {
    final bare = <String, String>{};
    for (final entry in map.entries) {
      final value = entry.value;
      // 值里出现"e.g. {n}" 这种模板才算对；下面找的是"有花括号"的键。
      final hasBrace = RegExp(r'\{[A-Za-z0-9_]+\}').hasMatch(value);
      if (!hasBrace) {
        // 没有花括号的键分两种：ARB 里本来就没有占位符（合法），
        // 或者**本该有**占位符却被写成了裸名（缺陷）。用 ARB 侧的模板判：
        // 模板里没有 `{` ⇒ 合法；有 `{` 而值是裸名 ⇒ 漏。
        // 这里只对"值恰好等于某个占位符名"的形状报警（精确、零误报）。
        if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(value) &&
            value.length <= 12 &&
            const {
              'n',
              'x',
              'code',
              'count',
              'msg',
              'err',
              'error',
              'name',
              'text',
              'mark',
              'level',
              'attrs',
              'label',
              'm',
              'left',
              'e',
              'inner',
              'kind',
              'type',
              'block',
              'minutes',
              'op',
              'speed',
              'source',
              'hash',
              'id',
              'when',
              'size',
              'percent',
              'owner',
              'summary',
              'version',
              'what',
              'got',
              'date',
              'host',
              'duration',
              'path',
            }.contains(value)) {
          bare[entry.key] = value;
        }
      }
    }
    expect(bare, isEmpty, reason: '这些键的值是"裸占位符名"而不是模板：$bare');
  });
}
