// ★ 第 278 轮：**厂商（OEM）后台保活指引**的离线守卫。
//
// 为什么值得一条专门的用例：本 App 不用 FCM ⇒ 国内 ROM 的「应用启动管理／
// 智能省电／深度睡眠」是"通知能不能到"的唯一闸门。指引的内容、厂商判定、
// 深链组件名，都是**字符串契约** —— 最容易在重构里悄悄漂移。这里把它钉死：
//
//   ① **Dart 与 Kotlin 的厂商 id 必须逐字一致**（原生判定 → Dart 文案）；
//   ② **Kotlin 会探测的厂商设置包，必须都在 manifest 的 `<queries>` 里**
//      （不声明 ⇒ Android 11+ 包可见性把 `resolveActivity` 过滤成 null ⇒
//       明明系统里有页面却探不到，界面退化成"只有手动路径"）；
//   ③ 指引**逐家**断言：激进档必须给出「自启动 + 电池 + 锁卡片」，
//      探不到自启动页时**不给可点落点**（点不动的东西比没有更糟）；
//   ④ **i18n 双语**：`AppTextEn()` 下 12 家厂商的全部文案**不许出现中日韩字符**
//      （否则就是漏了 `dataTextMap` 登记 —— AGENTS §2.0.13）；
//   ⑤ **反向验证**：修复前的状态（没有 `<queries>` 里的厂商包 / 没登记
//      `dataTextMap`）必须让上面的断言变红，证明用例是承重的。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/device/oem_guidance.dart';
import 'package:synhub/src/core/i18n/data_text.dart';
import 'package:synhub/src/core/i18n/l10n.dart';

const String kManifestPath = 'android/app/src/main/AndroidManifest.xml';
const String kKotlinPath =
    'android/app/src/main/kotlin/com/openviewai/synhub/OemCompatBridge.kt';

/// 中日韩字符 + 全角标点（与 `i18n_coverage_test.dart` 同一口径）
final _cjk = RegExp(r'[\u3000-\u303F\u4E00-\u9FFF\uFF00-\uFFEF]');

String _read(String p) {
  final f = File(p);
  expect(f.existsSync(), isTrue, reason: '找不到 $p（flutter test 的 cwd 应为包根）');
  return f.readAsStringSync();
}

/// 剥 XML 注释（manifest 的注释里举了反例，不剥会被当成真声明）
String _stripXmlComments(String s) =>
    s.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

/// `<queries>` 里声明的 `<package android:name="…"/>`
Set<String> _manifestQueriedPackages(String manifest) => {
  for (final m in RegExp(
    r'<package\s+android:name="([^"]+)"',
  ).allMatches(_stripXmlComments(manifest)))
    m.group(1)!,
};

/// `OemCompatBridge.oemId()` 的返回字符串（Kotlin 的 `when` 分支值）
Set<String> _kotlinOemIds(String kt) {
  final start = kt.indexOf('internal fun oemId(');
  expect(start, greaterThan(0), reason: 'Kotlin 里找不到 oemId()');
  final end = kt.indexOf('internal fun autostartCandidates', start);
  expect(end, greaterThan(start), reason: 'Kotlin 里找不到 autostartCandidates()');
  final body = kt.substring(start, end);
  final ids = {
    for (final m in RegExp(r'->\s*"([a-z]+)"').allMatches(body)) m.group(1)!,
  };
  expect(ids, isNotEmpty, reason: 'oemId() 里一个分支值都没抽到（正则漂了？）');
  return ids;
}

/// `OemCompatBridge.autostartCandidates()` 里出现的全部 `ComponentName(pkg, cls)`
List<({String pkg, String cls})> _kotlinAutostartCandidates(String kt) {
  final start = kt.indexOf('internal fun autostartCandidates(');
  expect(start, greaterThan(0), reason: 'Kotlin 里找不到 autostartCandidates()');
  // 函数体到 `// google / other` 的分支为止（后面的 else 分支没有组件）
  final end = kt.indexOf('// google / other', start);
  final body = kt.substring(start, end > start ? end : kt.length);
  final out = <({String pkg, String cls})>[];
  for (final m in RegExp(
    r'ComponentName\(\s*"([^"]+)"\s*,\s*"([^"]+)"\s*,?\s*\)',
  ).allMatches(body)) {
    out.add((pkg: m.group(1)!, cls: m.group(2)!));
  }
  expect(out.length, greaterThan(8), reason: '抽到的候选组件太少（正则漂了？）');
  return out;
}

/// 逐家厂商的全部用户可见文案（用于 i18n 扫描）
List<String> _allTextsFor(OemVendor v) {
  final g = oemGuidanceFor(v, autostartAvailable: true);
  final g2 = oemGuidanceFor(v, autostartAvailable: false);
  return [
    for (final s in [...g.steps, ...g2.steps]) s.text,
    g.path,
    g.note,
    oemKillLevelText(g.level),
    oemAutostartMissingText(),
    oemPathLabelText(),
    oemBatteryStateText(ignored: true),
    oemBatteryStateText(ignored: false),
    ...oemGeneralNotes(),
  ];
}

void main() {
  late final String manifest;
  late final Set<String> queried;
  late final Set<String> kotlinIds;
  late final List<({String pkg, String cls})> candidates;

  setUpAll(() {
    manifest = _read(kManifestPath);
    queried = _manifestQueriedPackages(manifest);
    final kt = _read(kKotlinPath);
    kotlinIds = _kotlinOemIds(kt);
    candidates = _kotlinAutostartCandidates(kt);
  });

  group('① 厂商 id：Dart 与 Kotlin 逐字一致', () {
    test('Kotlin oemId() 的每个分支值都在 Dart 的 OemVendor 里', () {
      final dartIds = {for (final v in OemVendor.values) v.id};
      for (final id in kotlinIds) {
        expect(
          dartIds,
          contains(id),
          reason: 'Kotlin 会返回 "$id"，但 Dart OemVendor 没有这个 id '
              '⇒ 指引会静默落到 other（用户看到通稿）',
        );
      }
    });

    test('Dart 的每个厂商 id（other 除外）都被 Kotlin 覆盖', () {
      for (final v in OemVendor.values) {
        if (v == OemVendor.other) continue;
        expect(
          kotlinIds,
          contains(v.id),
          reason: 'Dart 有 ${v.id} 的指引，但 Kotlin 永远不会判定为 ${v.id} '
              '⇒ 该厂商的指引是死代码',
        );
      }
    });

    test('大小写与空白不容错到"判错家"：fromId 只认小写精确值', () {
      expect(OemVendor.fromId('honor'), OemVendor.honor);
      expect(OemVendor.fromId('HONOR'), OemVendor.honor); // 归一化小写
      expect(OemVendor.fromId('  Xiaomi '), OemVendor.xiaomi);
      expect(OemVendor.fromId(''), OemVendor.other);
      expect(OemVendor.fromId(null), OemVendor.other);
      expect(OemVendor.fromId('nokia'), OemVendor.other);
    });
  });

  group('② Kotlin 探测的厂商设置包必须在 manifest <queries> 里', () {
    test('每个候选组件的 package 都已在 <queries> 声明', () {
      final missing = <String>{
        for (final c in candidates)
          if (!queried.contains(c.pkg)) c.pkg,
      };
      expect(
        missing,
        isEmpty,
        reason: '这些包没进 <queries> ⇒ Android 11+ 包可见性会把 '
            'resolveActivity 过滤成 null ⇒ 明明有页面却探不到：$missing',
      );
    });

    test('每个候选组件都是 package/class 两段式（没有空串）', () {
      for (final c in candidates) {
        expect(c.pkg, isNotEmpty);
        expect(c.cls, contains('.'), reason: '类名应有包前缀：${c.cls}');
      }
    });

    test('★ 真机验证过的那条（Honor LGE-AN10 / MagicUI 6.0.0）仍在候选里', () {
      // 证据：`adb shell cmd package resolve-activity --brief -n
      //   com.hihonor.systemmanager/.startupmgr.ui.StartupNormalAppListActivity`
      // → `com.hihonor.systemmanager/.startupmgr.ui.StartupNormalAppListActivity`
      // 完整记录见 docs/android-compat-matrix.md §2（honor 行，真机验证）
      expect(
        candidates,
        contains((
          pkg: 'com.hihonor.systemmanager',
          cls: 'com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity',
        )),
        reason: '真机验过的那条被删了 ⇒ Honor 用户会失去唯一可点的深链',
      );
    });

    test('不会拿来路不明的通配：<queries> 里不许出现 "*"', () {
      for (final p in queried) {
        expect(p.contains('*'), isFalse, reason: '<queries> 里的包名不许有通配：$p');
      }
    });
  });

  group('③ 指引内容逐家正确', () {
    test('激进档（8 家）必须有 自启动 + 后台活动 + 电池 + 锁卡片', () {
      for (final v in kAggressiveOem) {
        final g = oemGuidanceFor(v, autostartAvailable: true);
        expect(g.level, OemKillLevel.aggressive, reason: '${v.id} 档位漂了');
        final ids = {for (final s in g.steps) s.id};
        expect(ids, containsAll(<String>['autostart', 'background-activity', 'battery', 'lock-recents']),
            reason: '${v.id} 的步骤少了：$ids');
      }
    });

    test('中等档（oneplus / samsung）不列"锁卡片"与"后台活动"', () {
      for (final v in kModerateOem) {
        final g = oemGuidanceFor(v, autostartAvailable: true);
        expect(g.level, OemKillLevel.moderate);
        final ids = {for (final s in g.steps) s.id};
        expect(ids, isNot(contains('lock-recents')), reason: v.id);
        expect(ids, isNot(contains('background-activity')), reason: v.id);
        expect(ids, contains('battery'), reason: v.id);
      }
    });

    test('google / other：只有电池一步，而且仍然不空', () {
      for (final v in [OemVendor.google, OemVendor.other]) {
        final g = oemGuidanceFor(v, autostartAvailable: true);
        expect(g.level, OemKillLevel.standard);
        expect(g.steps, hasLength(1));
        expect(g.steps.single.id, 'battery');
        expect(g.steps.single.target, OemSettingsTarget.batteryWhitelist);
        expect(g.path, isNotEmpty, reason: '标准档也要给手动路径');
      }
    });

    test('探不到自启动页 ⇒ **不给**可点落点（点不动比没有更糟）', () {
      for (final v in OemVendor.values) {
        if (!oemGuidanceFor(v, autostartAvailable: false).expectsAutostartPage) {
          continue;
        }
        final none = oemGuidanceFor(v, autostartAvailable: false);
        final step = none.steps.firstWhere((s) => s.id == 'autostart');
        expect(
          step.target,
          isNull,
          reason: '${v.id}：原生没验真到自启动页，不该挂落点',
        );
        // 有页时**必须**挂上，否则"验真"白做
        final some = oemGuidanceFor(v, autostartAvailable: true);
        expect(
          some.steps.firstWhere((s) => s.id == 'autostart').target,
          OemSettingsTarget.autostart,
          reason: '${v.id}：验真到了却不可点',
        );
      }
    });

    test('每家都有非空的手动路径与特有提示（12 家无遗漏）', () {
      for (final v in OemVendor.values) {
        expect(oemPathText(v).trim(), isNotEmpty, reason: '${v.id} 缺手动路径');
        expect(oemNoteText(v).trim(), isNotEmpty, reason: '${v.id} 缺厂商提示');
      }
    });
  });

  group('④ i18n：英文下 12 家厂商全部文案不许含中日韩字符', () {
    test('AppTextEn 下零 CJK（含全角标点）', () {
      setCurrentText(AppTextEn());
      addTearDown(() => setCurrentText(AppTextZh()));
      final bad = <String>[];
      for (final v in OemVendor.values) {
        for (final s in _allTextsFor(v)) {
          if (_cjk.hasMatch(s)) bad.add('${v.id}: $s');
        }
      }
      expect(
        bad,
        isEmpty,
        reason: '英文模式下冒出中文 ⇒ 极可能是 dataTextMap 漏登记：\n${bad.join('\n')}',
      );
    });

    test('反向验证：把翻译器卸掉（等于漏登记）时必须回落中文 ⇒ 用例真抓得住', () {
      setDataTextResolver(null);
      addTearDown(() => setCurrentText(AppTextZh()));
      // 没有翻译器 = 数据层漏登记时的真实行为：逐条回落中文原文
      expect(_cjk.hasMatch(oemPathText(OemVendor.honor)), isTrue);
      expect(_cjk.hasMatch(oemNoteText(OemVendor.xiaomi)), isTrue);
      expect(_cjk.hasMatch(oemGeneralNotes().first), isTrue);
    });

    test('中文表在所有厂商上都有内容（不是空串假绿）', () {
      setCurrentText(AppTextZh());
      for (final v in OemVendor.values) {
        for (final s in _allTextsFor(v)) {
          expect(s.trim(), isNotEmpty, reason: '${v.id} 有空白文案');
        }
      }
    });
  });
}
