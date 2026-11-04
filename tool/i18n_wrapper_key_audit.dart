// 数据层"包装器文案"登记审计（**纯 Dart**，`dart run tool/i18n_wrapper_key_audit.dart`）。
//
// 把模块里 `wrapper(SomeTextKeys.name, '中文回落')` 形态的调用点全部抽出来，
// 逐个比对：
//   * `lib/l10n/app_zh.arb`（gen-l10n 模板，中文）
//   * `lib/l10n/app_en.arb`（英文）
//   * `lib/src/core/i18n/l10n.dart` 的 `dataTextMap`
// 三个地方只要缺一个，英文模式就会回落中文（用户报障的“中英串在一起”）。
//
// 退出码：有缺口（或 `XTextKeys.name` 解析不到）时非 0，可挂 CI。
//
// 扫描逻辑在 `lib/src/core/i18n/wrapper_key_scan.dart`（纯函数，单测同源）。
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/i18n/wrapper_key_scan.dart';

void main(List<String> args) {
  final identifierKeysOnly = args.contains('--identifier-only');
  final root = _findRepoRoot();
  final libDir = Directory('${root.path}/lib');
  if (!libDir.existsSync()) {
    stderr.writeln('找不到 ${libDir.path}');
    exit(2);
  }

  // ---- 1. 收集 lib/**/*.dart ----
  final sources = <String, String>{};
  for (final e in libDir.listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final rel = _rel(root, e);
    sources[rel] = e.readAsStringSync();
  }

  // ---- 2. 读两套 ARB + dataTextMap ----
  final zhKeys = _arbKeys(File('${root.path}/lib/l10n/app_zh.arb'));
  final enKeys = _arbKeys(File('${root.path}/lib/l10n/app_en.arb'));
  final mapKeys = _dataTextMapKeys(File('${root.path}/lib/src/core/i18n/l10n.dart'));

  // ---- 3. 扫描 ----
  final audit = auditWrapperKeys(
    sources: sources,
    zhKeys: zhKeys,
    enKeys: enKeys,
    mapKeys: mapKeys,
    identifierKeysOnly: identifierKeysOnly,
  );

  // ---- 4. 输出 ----
  final buf = StringBuffer();
  buf.writeln('== i18n wrapper-key audit ==');
  buf.writeln('repo root              : ${root.path}');
  buf.writeln('dart files scanned     : ${sources.length}');
  buf.writeln('wrappers discovered    : ${audit.wrapperNames.length}');
  buf.writeln('total call sites       : ${audit.callSites.length}');
  buf.writeln('unique keys            : ${audit.uniqueKeys}');
  buf.writeln('missing from zh        : ${audit.missingZh.length}');
  buf.writeln('missing from en        : ${audit.missingEn.length}');
  buf.writeln('missing from dataTextMap: ${audit.missingMap.length}');
  buf.writeln('unresolved key refs    : ${audit.unresolvedRefs.length}');
  buf.writeln('key conflicts          : ${audit.conflicts.length}');

  if (audit.unresolvedRefs.isNotEmpty) {
    buf.writeln();
    buf.writeln('-- unresolved XTextKeys refs --');
    for (final r in audit.unresolvedRefs) {
      buf.writeln('  $r');
    }
  }
  if (audit.conflicts.isNotEmpty) {
    buf.writeln();
    buf.writeln('-- conflicting Chinese literals --');
    for (final c in audit.conflicts) {
      buf.writeln('  $c');
    }
  }
  if (audit.keyToZh.isNotEmpty && audit.hasFindings) {
    buf.writeln();
    buf.writeln('-- missing keys (key | zh | first call site) --');
    final byKey = <String, WrapperCallSite>{};
    for (final s in audit.callSites) {
      byKey.putIfAbsent(s.key, () => s);
    }
    final keys = <String>{
      ...audit.missingZh,
      ...audit.missingEn,
      ...audit.missingMap,
    }.toList()
      ..sort();
    for (final k in keys) {
      final first = byKey[k];
      final where = first == null ? '' : '  ${first.file}:${first.line}';
      final flags = <String>[
        if (audit.missingZh.contains(k)) 'zh',
        if (audit.missingEn.contains(k)) 'en',
        if (audit.missingMap.contains(k)) 'map',
      ].join(',');
      buf.writeln('  $k | ${audit.keyToZh[k] ?? ''} | $flags$where');
    }
  }

  buf.writeln();
  buf.writeln(audit.hasFindings ? 'RESULT: FAIL' : 'RESULT: OK');
  stdout.write(buf);

  if (audit.hasFindings) exit(1);
}

Directory _findRepoRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/pubspec.yaml').existsSync() &&
        Directory('${dir.path}/lib/l10n').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return Directory.current;
    dir = parent;
  }
}

String _rel(Directory root, File f) {
  final r = root.absolute.path.endsWith('/')
      ? root.absolute.path
      : '${root.absolute.path}/';
  final a = f.absolute.path;
  return a.startsWith(r) ? a.substring(r.length) : a;
}

Set<String> _arbKeys(File f) {
  if (!f.existsSync()) {
    stderr.writeln('找不到 ${f.path}');
    exit(2);
  }
  final raw = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  return raw.keys.where((k) => !k.startsWith('@')).toSet();
}

/// 抓 `Map<String, String> dataTextMap(AppText t) => { … };` 里的 key。
Set<String> _dataTextMapKeys(File f) {
  if (!f.existsSync()) {
    stderr.writeln('找不到 ${f.path}');
    exit(2);
  }
  final src = f.readAsStringSync();
  final anchor = src.indexOf('dataTextMap(AppText t)');
  if (anchor < 0) {
    stderr.writeln('${f.path} 里找不到 dataTextMap(AppText t)');
    exit(2);
  }
  final open = src.indexOf('{', anchor);
  if (open < 0) {
    stderr.writeln('dataTextMap 找不到 `{`');
    exit(2);
  }
  final end = _blockEnd(src, open);
  if (end < 0) {
    stderr.writeln('dataTextMap 大括号不配对');
    exit(2);
  }
  final body = src.substring(open + 1, end);
  final re = RegExp(r"'([A-Za-z_]\w*)'\s*:");
  return re.allMatches(body).map((m) => m.group(1)!).toSet();
}

int _blockEnd(String s, int openBrace) {
  var depth = 0;
  var i = openBrace;
  while (i < s.length) {
    final c = s[i];
    if (c == "'" || c == '"') {
      final q = c;
      i++;
      while (i < s.length) {
        if (s[i] == '\\') {
          i += 2;
          continue;
        }
        if (s[i] == q) {
          i++;
          break;
        }
        i++;
      }
      continue;
    }
    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return i;
    }
    i++;
  }
  return -1;
}
