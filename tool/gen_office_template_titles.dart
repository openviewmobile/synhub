// 生成 `lib/src/features/office/office_template_titles.dart`。
//
// 事实来源：**Office SPK 3.8.0-22711**（`~/synology_samples/spk/Office-3.8.0-22711.spk`）
// 里 `package.tgz` 的 `ui/texts/{chs,enu}/strings`（Synology 官方 INI 式本地化表）。
//
// 为什么需要它：服务端 `SYNO.Office.Template:list` 对**系统模板**回的 `title`
// 不是给人看的字符串，而是 **`<section>:<key>`**（真机实测：
// `"theme_presentation:country_road"`、`"template_doc:trip_planner"`）——
// 官方前端 `SYNO.SDS.Office.Utils.parseTemplateTitle` 就是拆开去查这张表
// （`SYNO.SDS.Office.Template.ViewStore.Tpl.titleConverter`：
// `t.system ? parseTemplateTitle(t.title) : t.title`）。
//
// 跑法（先按 AGENTS §1.3.0.2 查库，**不要**重新下载 SPK）：
//   /tmp/spkvenv/bin/python ~/.dsh/skills/synology-spk/scripts/spk_unpack.py \
//     ~/synology_samples/spk/Office-3.8.0-22711.spk --only package.tgz -o /tmp/office_pkg.tar
//   tar xf /tmp/office_pkg.tar -C /tmp/office_pkg package.tgz
//   tar xzf /tmp/office_pkg/package.tgz -C /tmp/office_pkg ui/texts        # 只取本地化
//   # 把 chs/enu 的 strings 收进样例库（各 ~100KB，别每次解 182MB）
//   cp /tmp/office_pkg/ui/texts/chs/strings ~/synology_samples/office-templates-texts/chs.strings
//   cp /tmp/office_pkg/ui/texts/enu/strings ~/synology_samples/office-templates-texts/enu.strings
//   dart run tool/gen_office_template_titles.dart
//
// ignore_for_file: avoid_print
import 'dart:io';

/// 模板用到的三类 section（`title_section`，来自 56 份 `template/*/config.json`：
/// `theme_presentation`×24 / `template_doc`×16 / `template_sheet`×13）。
const _sections = ['theme_presentation', 'template_doc', 'template_sheet'];

const _srcDir = '<home>/synology_samples/office-templates-texts';
const _out = 'lib/src/features/office/office_template_titles.dart';

/// 解析官方 INI 式 `strings`：`[section]` 分段，`key = "值"`。
Map<String, Map<String, String>> _parse(String path) {
  final out = <String, Map<String, String>>{};
  String? section;
  for (final raw in File(path).readAsLinesSync()) {
    final line = raw.trimRight();
    final sec = RegExp(r'^\s*\[([^\]]+)\]\s*$').firstMatch(line);
    if (sec != null) {
      section = sec.group(1);
      continue;
    }
    if (section == null || line.trimLeft().startsWith('#')) continue;
    final i = line.indexOf('=');
    if (i < 0) continue;
    var v = line.substring(i + 1).trim();
    // 官方值形如 `"文字"`，可能有尾随空白；也有 `{0}` 这类占位符（如 `calendar`）。
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      v = v.substring(1, v.length - 1);
    }
    out.putIfAbsent(section, () => {})[line.substring(0, i).trim()] = v;
  }
  return out;
}

String _escape(String s) =>
    s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$');

void main() {
  final zh = _parse('$_srcDir/chs.strings');
  final en = _parse('$_srcDir/enu.strings');
  final buf = StringBuffer()
    ..writeln('// GENERATED — 不要手改；跑 `dart run tool/gen_office_template_titles.dart` 重建。')
    ..writeln('//')
    ..writeln('// 来源：Office SPK 3.8.0-22711 `ui/texts/{chs,enu}/strings`（官方本地化表）。')
    ..writeln('// 用途：`SYNO.Office.Template:list` 对**系统模板**回的 `title` 是')
    ..writeln('// `<section>:<key>`（如 `theme_presentation:country_road`），')
    ..writeln('// 官方前端 `parseTemplateTitle` 拆开后查的正是这张表。')
    ..writeln('//')
    ..writeln('// ignore_for_file: lines_longer_than_80_chars')
    ..writeln();
  var n = 0;
  for (final lang in ['Zh', 'En']) {
    final table = lang == 'Zh' ? zh : en;
    buf.writeln(
      '/// 官方模板标题表（${lang == 'Zh' ? '简体中文' : 'English'}），'
      '键是 `section:key` 里的 `section`。',
    );
    buf.writeln('const Map<String, Map<String, String>> '
        'kOfficeTemplateTitles$lang = <String, Map<String, String>>{');
    for (final s in _sections) {
      final entries = table[s] ?? const <String, String>{};
      buf.writeln("  '$s': <String, String>{");
      for (final e in entries.entries) {
        buf.writeln("    '${_escape(e.key)}': '${_escape(e.value)}',");
      }
      buf.writeln('  },');
    }
    buf.writeln('};');
    buf.writeln();
  }
  for (final s in _sections) {
    n += (zh[s]?.length ?? 0);
  }
  buf
    ..writeln('/// 模板类型在官方分组里的先后（`SYNO.SDS.Office.Template.Define.TYPE_ORDER`）。')
    ..writeln('const Map<String, int> kOfficeTemplateTypeOrder = <String, int>{')
    ..writeln("  'doc': 1,")
    ..writeln("  'sheet': 2,")
    ..writeln("  'presentation': 3,")
    ..writeln('};')
    ..writeln()
    ..writeln('/// 官方判定为**已过时**的系统演示文稿主题')
    ..writeln('/// （`SYNO.SDS.Office.Template.Utils.isDeprecatedTemplate`），排序时沉底。')
    ..writeln('const Set<String> kOfficeDeprecatedTemplateKeys = <String>{')
    ..writeln("  'focus_square',")
    ..writeln("  'humble_blue',")
    ..writeln("  'note_paper',")
    ..writeln("  'simple_life',")
    ..writeln("  'tangram_collage',")
    ..writeln("  'triangle_festival',")
    ..writeln("  'water_party',")
    ..writeln('};');
  final out = buf.toString();
  if (out.length < 2000) {
    throw StateError('生成内容太短，拒绝写入（$n 条）');
  }
  File(_out).writeAsStringSync(out);
  print('写入 $_out：${out.length} 字符，${n * 2} 条标题（zh+en）');
}
