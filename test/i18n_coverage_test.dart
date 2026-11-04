// ★ 第 259 轮：**"界面上中英文串到一起"的全局守卫**。
//
// 用户 2026-09-26 报障：「界面上还是有很多中英文串到一起的，也需要全局解决下」。
//
// 根因不是"漏翻了某几句"，而是**机制**：
// 数据层/服务层不能 import Flutter（要被 `dart run tool/*.dart` 纯 Dart 加载），
// 所以它们的文案写成 `dataText('key', '中文原文')`，运行时由
// `setCurrentText()` 注入的 `dataTextMap` 查表翻译，**查不到就回落中文原文**。
// 于是"加了新文案、忘了登记进 `dataTextMap`"时：
//
//   * 中文模式下**看不出来**（回落的就是中文，正好对）；
//   * 英文模式下那一句**突然变中文** ⇒ 界面中英混排。
//
// 第 259 轮普查结果：**226 个 key** 处于这个状态（34 个文件），
// 其中 211 个连 ARB 里都没有。已全部补齐。
//
// 这个用例把那套普查**固化下来**，并把口径对准"用户看到的现象"：
// ① 英文表解析出来的每一句都不许含中日韩字符（含全角标点）；
// ② 代码里用到的 key 必须都登记进 `dataTextMap`（就是上面那个 226 的来源）；
// ③ 两套 ARB 的键集合必须一致（en 缺 → gen-l10n 回落模板中文 ⇒ 又是混排）；
// ④ 中文表解析结果非空（避免"登记了但值是空串"这种假修复）。
// ⑤ 反向验证（证明这套守卫真能抓到现象）；
// ⑥ ★ 第 43 轮补：**整份 `app_en.arb` 的值**都不许含中日韩 ——
//    ① 的口径只是 `dataTextMap` 那批**数据层** key，而 widget 里直接 `t.xxx` 用的
//    ARB 键（如 Files 工具栏的「文件工具」）在 ① 和 `i18n_hardcoded_cjk_test`
//    （扫 Dart 字面量，ARB 不在其中）**两道守卫里都是盲区**，见
//    `docs/multi-platform-roadmap.md` §7.1。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/core/i18n/data_text.dart';
import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';

/// 中日韩字符 + 全角标点（`。`、`（`、`「`、`·` 之类都算"中文串进来了"）
final _cjk = RegExp(r'[\u3000-\u303F\u4E00-\u9FFF\uFF00-\uFFEF]');

/// 允许在英文界面里出现的例外（**必须写清理由**；现在没有例外）。
const _enAllowCjk = <String>{};

/// 允许在 **en ARB 的值**里出现中日韩的例外（**必须写清理由**）。
/// 现在没有例外 —— 有的话请写明"为什么这一句英文界面里就该是中文"。
const _enArbAllowCjk = <String>{
  // 语言名一律用**母语写法**（与系统语言设置一致，用户才能认出自己选的是哪种语言）。
  // 这两条是本项目里仅有的、**英文界面上就该显示中文**的文案。
  'langZh', // = '简体中文'
  'setLanguageHint', // = 'Interface language (system / 简体中文 / English)'
};

/// 用 `jsonDecode` 完整读一份 ARB（比正则版 `_arb` 更全：多行的 plural/select 也能读到），
/// 并滤掉 `@key` 元数据。
Map<String, String> _arbJson(String lang) {
  final f = File('lib/l10n/app_$lang.arb');
  expect(f.existsSync(), isTrue, reason: '找不到 ${f.path}');
  final raw = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  final out = <String, String>{};
  raw.forEach((k, v) {
    if (k.startsWith('@')) return; // 元数据：placeholders / description
    if (v is String) out[k] = v;
  });
  return out;
}

/// 从源码里抽出所有 `dataText('key', '…')` / `xxxText('key', '…')` 的 key。
Map<String, Set<String>> _usedKeys() {
  final re = RegExp(r"""(\w*Text)\(\s*'([A-Za-z0-9_]+)'\s*,\s*'""");
  final out = <String, Set<String>>{};
  for (final f in Directory('lib/src').listSync(recursive: true)) {
    if (f is! File || !f.path.endsWith('.dart')) continue;
    if (f.path.contains('/core/i18n/')) continue; // 表本身不算"使用点"
    final src = f.readAsStringSync();
    for (final m in re.allMatches(src)) {
      out.putIfAbsent(m.group(2)!, () => <String>{}).add(f.path);
    }
  }
  return out;
}

/// ★★ DA11（r356）：允许用**拼出来的 key**（`'prefix$var'`）调翻译助手的调用点。
///
/// **必须写清理由**，而且理由必须落到"该家族的每个具体 key 都已登记 + 有枚举
/// 守卫盯着"上 —— 否则就是 DA11 那种静默回落中文（真机英文界面显示
/// `照片 (1)`）。`_usedKeys()` 的正则只认字面 key，插值串**结构上扫不到**，
/// 所以单独立这一条。
const _interpolatedKeySites = <String, String>{
  'lib/src/data/region/region_context.dart':
      'regionCountry<CC>：53 个具体 key 全部登记进 dataTextMap + zh/en ARB，'
          '并由 test/i18n_dynamic_key_family_test.dart 逐条枚举（英文下不回落中文）。',
  'lib/src/features/office/office_doc_paper.dart':
      'officeDocTocLevel<N>（N=1..6，官方 string/heading_1..6）：6 个具体 key '
          '全部登记进 dataTextMap + zh/en ARB，并由 '
          'test/i18n_dynamic_key_family_test.dart 逐条枚举（英文下不回落中文）。',
};

/// 翻译助手家族（与 `_usedKeys()` 同口径：`*Text(` 家族 + 各批次自己的助手）。
const _helperFamilies =
    r'dataText|driveC1|driveC1Fill|driveG4|driveG4Fill|driveG6|driveP0|'
    r'driveGap|driveGapFill|fsT|fsTFill|fsG4|photoC2|noteB|officeDocText|'
    r'officeDocFill|officeSheetText|officeSheetFill|officeSlidesText|'
    r'officeSlidesFill|officeLibraryText|officeTemplatePreviewText|serviceText';

/// 抽出"翻译助手 + **插值** key"的调用点（`'driveCategory$name'` 这类）。
///
/// 返回 `(file, line, call, key)`，按文件排序，便于报错时直接定位。
List<({String file, int line, String call, String key})> _interpolatedKeyCalls() {
  final re = RegExp(r'\b(' + _helperFamilies + r")\s*\(\s*'([^']*\$[^']*)'");
  final out = <({String file, int line, String call, String key})>[];
  for (final f in Directory('lib/src').listSync(recursive: true)) {
    if (f is! File || !f.path.endsWith('.dart')) continue;
    if (f.path.contains('/core/i18n/')) continue; // 表本身不算"使用点"
    final src = f.readAsStringSync();
    for (final m in re.allMatches(src)) {
      final line = '\n'.allMatches(src.substring(0, m.start)).length + 1;
      out.add((file: f.path, line: line, call: m.group(1)!, key: m.group(2)!));
    }
  }
  out.sort((a, b) => a.file == b.file ? a.line - b.line : a.file.compareTo(b.file));
  return out;
}

Map<String, dynamic> _arb(String lang) {
  final f = File('lib/l10n/app_$lang.arb');
  expect(f.existsSync(), isTrue, reason: '找不到 ${f.path}');
  final src = f.readAsStringSync();
  // 极简 JSON 取值：只取 "key": "value" 这种一行一条的形态（ARB 就是我们自己生成的）
  final out = <String, dynamic>{};
  // 只认**顶层**消息键（恰好两个空格缩进）：`placeholders` 里的名字
  // （`ok`/`description` 这类）缩进更深，早先按 `\s*` 匹配会误判成"en 缺键"。
  final re = RegExp(r'^  "([A-Za-z0-9_]+)"\s*:\s*"((?:[^"\\]|\\.)*)"\s*,?\s*$',
      multiLine: true);
  for (final m in re.allMatches(src)) {
    out[m.group(1)!] = m.group(2)!;
  }
  return out;
}

void main() {
  final enMap = dataTextMap(AppTextEn());
  final zhMap = dataTextMap(AppTextZh());

  test('① 英文界面解析出来的每一句都不含中日韩字符（这就是"中英串在一起"）', () {
    final offenders = <String, String>{};
    enMap.forEach((k, v) {
      if (_enAllowCjk.contains(k)) return;
      if (_cjk.hasMatch(v)) offenders[k] = v;
    });
    expect(
      offenders,
      isEmpty,
      reason: '以下 key 在英文模式下会显示中文（登记进 dataTextMap 但译文是中文，'
          '或者干脆回落了中文原文）：\n'
          '${offenders.entries.map((e) => '  ${e.key} = ${e.value}').join('\n')}',
    );
  });

  test('② 代码里用到的 key 必须都登记进 dataTextMap（漏登记 = 英文模式回落中文）', () {
    final used = _usedKeys();
    final missing = <String, Set<String>>{};
    used.forEach((k, files) {
      if (!enMap.containsKey(k)) missing[k] = files;
    });
    expect(
      missing,
      isEmpty,
      reason: '以下 ${missing.length} 个 key 只有中文回落、没登记进 dataTextMap：\n'
          '${missing.entries.map((e) => '  ${e.key}  (${e.value.first})').join('\n')}\n'
          '（完整名单见本用例输出；修法：补 ARB 双语 + 在 dataTextMap 里登记）',
    );
  });

  test('③ 两套 ARB 键集合一致（en 缺键时 gen-l10n 会回落中文模板）', () {
    final en = _arb('en');
    final zh = _arb('zh');
    final onlyZh = zh.keys.toSet().difference(en.keys.toSet()).toList()..sort();
    final onlyEn = en.keys.toSet().difference(zh.keys.toSet()).toList()..sort();
    expect(en.length, greaterThan(5000), reason: '条数太少，可能 ARB 没被正确解析');
    expect(onlyZh, isEmpty, reason: 'en 缺这些 key（会回落中文）：$onlyZh');
    expect(onlyEn, isEmpty, reason: 'zh 缺这些 key：$onlyEn');
  });

  test('④ 中文表同样完整（登记了但值空 = 假修复）', () {
    // 允许为空的例外（必须写清理由）：
    // `imageEditPresetCustomPrompt` 是"自定义提示词"输入框的**默认值**，
    // 空 = 让用户自己写（不是漏翻）。
    const allowEmpty = <String>{'imageEditPresetCustomPrompt'};
    final empty = <String>[];
    zhMap.forEach((k, v) {
      if (v.trim().isEmpty && !allowEmpty.contains(k)) empty.add(k);
    });
    expect(empty, isEmpty, reason: '这些 key 的中文译文是空的：$empty');
    expect(zhMap.length, enMap.length, reason: '中英表条数必须一一对应');
  });

  test('⑥ 整份 en ARB 的值都不许含中日韩（ARB 漏翻 = 英文界面里的中文）', () {
    // ★ 为什么必须有这一条：`i18n_coverage_test` 守卫①的口径是 **dataTextMap**
    // （数据层文案），`i18n_hardcoded_cjk_test` 扫的是 **Dart 字符串字面量**。
    // **ARB 里的中文在这两条里都不存在** ⇒ widget 里直接 `t.xxx` 的 ARB 键
    // 若 en 译文还是中文，两道守卫全绿也照样漏（第 279 轮 macOS 截图实测：
    // Files 工具栏出现「文件工具」）。见 `docs/multi-platform-roadmap.md` §7.1。
    final en = _arbJson('en');
    // 防空转（AGENTS §1.3.0.1）：解析出 0 条不是"通过"，是"没解析到"。
    expect(en.length, greaterThan(5000), reason: '条数太少，en ARB 可能没被正确解析');
    final offenders = <String, String>{};
    en.forEach((k, v) {
      if (_enArbAllowCjk.contains(k)) return;
      if (_cjk.hasMatch(v)) offenders[k] = v;
    });
    expect(
      offenders,
      isEmpty,
      reason: '以下 ${offenders.length} 个 key 的**英文** ARB 值仍是中文 '
          '（widget 直接 t.xxx 用它们 ⇒ 英文界面里出现中文）：\n'
          '${offenders.entries.map((e) => '  ${e.key} = ${e.value}').join('\n')}',
    );
  });

  test('⑦ 用"拼出来的 key"调翻译助手，必须进 allowlist（DA11 的盲区）', () {
    final calls = _interpolatedKeyCalls();
    // ★ 防呆（AGENTS §1.3.0.1）：扫到 0 处不是"没问题"，是正则坏了。
    expect(
      calls,
      isNotEmpty,
      reason: '一处插值 key 都没扫到 —— 先怀疑正则/口径，不要当成"全干净"',
    );
    final offenders = [
      for (final c in calls)
        if (!_interpolatedKeySites.containsKey(c.file)) c,
    ];
    expect(
      offenders,
      isEmpty,
      reason: '以下调用点用**插值拼出来的 key** 调翻译助手，而它不在 '
          '_interpolatedKeySites 里（DA11：运行时查不到就静默回落中文，'
          '英文界面当场露馅）：\n'
          '${offenders.map((c) => '  ${c.file}:${c.line}  '
              '${c.call}(\'${c.key}\')').join('\n')}\n'
          '修法二选一：① 把 key 改成**字面常量**（推荐，见 DriveMediaKind）'
          '并四处齐全登记；② 进 allowlist 并写明"每个具体 key 都已登记 + '
          '有枚举守卫"的理由。',
    );
    // allowlist 不许留陈旧条目（文件里已经不拼 key 了就得删）
    final files = calls.map((c) => c.file).toSet();
    final stale = _interpolatedKeySites.keys
        .where((f) => !files.contains(f))
        .toList();
    expect(stale, isEmpty, reason: '这些 allowlist 条目已经不再拼 key，请删掉：$stale');
    // 理由不许留空
    _interpolatedKeySites.forEach((f, why) {
      expect(why.trim().length, greaterThan(10), reason: '$f 的理由必须写清');
    });
  });

  test('⑤ 反向验证：这条守卫真的能抓到"漏登记"（否则等于没守）', () {
    // 造一个"代码里在用、但表里没有"的 key，按同样的口径判一次：
    const fake = 'zzzThisKeyIsNotRegistered';
    expect(enMap.containsKey(fake), isFalse);
    expect(_cjk.hasMatch(dataText(fake, '中文回落')), isTrue,
        reason: '未登记的 key 应当原样回落中文 —— 这正是用户报障的现象');
  });
}
