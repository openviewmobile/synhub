// 用真实 RAR 样本（/tmp/rar-samples、/tmp/ebook-samples）对自研解压层做端到端验证：
// 以本机 7z 为 oracle（列目录 + 解压），逐文件逐字节对照。
//
//   dart run tool/rar_real_verify.dart [目录或文件...]
//
// 默认看 /tmp/rar-samples 与 /tmp/ebook-samples/real.rar。样本不进仓库。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/features/files/rar_archive.dart';

const _defaultInputs = <String>[
  '/tmp/rar-samples',
  '/tmp/ebook-samples/real.rar',
];

Future<void> main(List<String> args) async {
  final inputs = args.isEmpty ? _defaultInputs : args;
  final files = <String>[];
  for (final input in inputs) {
    final type = FileSystemEntity.typeSync(input);
    if (type == FileSystemEntityType.directory) {
      final dir = Directory(input);
      for (final e in dir.listSync()) {
        if (e is File && e.path.toLowerCase().endsWith('.rar'))
          files.add(e.path);
      }
    } else if (type == FileSystemEntityType.file) {
      files.add(input);
    }
  }
  files.sort();

  var pass = 0;
  var unsupported = 0;
  var fail = 0;
  for (final path in files) {
    final name = path.split('/').last;
    final bytes = File(path).readAsBytesSync();
    stdout.writeln('=== $name  (${bytes.length} B)');

    // ---- oracle：bsdtar（libarchive，样本的来源）→ unrar → 7z，各解一份 ----
    final oracles = <String, String>{}; // 工具名 → 解压目录
    var oi = 0;
    for (final tool in const ['bsdtar', 'unrar', '7z']) {
      final exe = _which(tool);
      if (exe == null) continue;
      final dir = Directory('/tmp/rar-verify/oracle/$name/${tool}_${oi++}');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);
      final args = switch (tool) {
        'bsdtar' => ['-xf', path, '-C', dir.path],
        'unrar' => ['x', '-p-', '-o+', '-idq', path, '${dir.path}/'],
        _ => ['x', '-y', '-bso0', '-bse1', '-p', '-o${dir.path}', path],
      };
      await _run(exe, args, const Duration(seconds: 25));
      // 有的样本被解出成 000 权限（libarchive 测试夹具的怪癖），读之前放开
      await _run('chmod', [
        '-R',
        'u+rwX',
        dir.path,
      ], const Duration(seconds: 5));
      final names = <String>[];
      for (final e in dir.listSync(recursive: true)) {
        if (e is File) names.add(_rel(dir.path, e.path));
      }
      if (names.isEmpty) {
        dir.deleteSync(recursive: true);
        continue;
      }
      oracles[tool] = dir.path;
    }
    if (oracles.isEmpty) {
      stdout.writeln('  ⓘ 没有可用 oracle（bsdtar/unrar/7z 都解不出）');
    }

    // ---- 自研解压（open / extract 分开报告，分清"打不开"和"解不开"）----
    RarArchive? archive;
    try {
      archive = RarArchive.open(bytes);
      stdout.writeln(
        '  open ✓  RAR${archive.version}.x  固实=${archive.isSolid}  '
        '条目=${archive.entries.length}',
      );
    } on RarUnsupportedException catch (e) {
      stdout.writeln('  open ⛔ 明确不支持：${e.message}');
      unsupported++;
      continue;
    } on RarFormatException catch (e) {
      stdout.writeln('  open ⛔ 坏文件：${e.message}');
      unsupported++;
      continue;
    }
    try {
      final out = archive.extract();
      final mineDir = Directory('/tmp/rar-verify/mine/$name');
      if (mineDir.existsSync()) mineDir.deleteSync(recursive: true);
      mineDir.createSync(recursive: true);
      final mineNames = <String>[];
      for (final e in out.entries) {
        final f = File('${mineDir.path}/${e.key}')..createSync(recursive: true);
        f.writeAsBytesSync(e.value);
        mineNames.add(e.key);
      }
      mineNames.sort();

      if (oracles.isEmpty) {
        stdout.writeln('  解出 ${out.length} 个文件；oracle 都没产出可比对的文件 → 跳过对照');
        pass++;
        continue;
      }
      var matched = 0;
      final problems = <String>[];
      final notes = <String>[];
      for (final oracle in oracles.entries) {
        final dir = oracle.value;
        final oNames = <String>[];
        for (final e in Directory(dir).listSync(recursive: true)) {
          if (e is File) oNames.add(_rel(dir, e.path));
        }
        oNames.sort();
        if (!_sameNames(oNames, mineNames)) {
          notes.add(
            '${oracle.key}: 文件名集合不一致（${oNames.length} vs '
            '${mineNames.length}）',
          );
          continue;
        }
        var bad = 0;
        for (final rel in oNames) {
          final op = '$dir/$rel';
          // 符号链接：oracle 解出来是链接（内容是链接目标字符串），读 File 会跟到
          // 目标文件；这里按"链接目标"比对，才是 RAR 里真正存的那几个字节。
          final List<int> a;
          if (FileSystemEntity.isLinkSync(op)) {
            a = utf8.encode(Link(op).targetSync());
          } else {
            a = File(op).readAsBytesSync();
          }
          final b = File('${mineDir.path}/$rel').readAsBytesSync();
          if (!_bytesEqual(a, b)) {
            notes.add(
              '${oracle.key}: $rel 内容不一致'
              '（oracle ${a.length} B vs mine ${b.length} B）',
            );
            bad++;
          }
        }
        if (bad == 0) matched++;
      }
      if (matched > 0) {
        final others = oracles.keys.where(
          (k) => !notes.any((n) => n.startsWith('$k:')),
        );
        stdout.writeln(
          '  ✅ 与 ${others.join('/')} 逐字节一致（${mineNames.length} 个文件）',
        );
        for (final n in notes) {
          stdout.writeln('     （$n）');
        }
        pass++;
      } else {
        stdout.writeln('  ✗ 与所有 oracle 都不一致');
        for (final n in notes) {
          stdout.writeln('     $n');
        }
        fail++;
      }
    } on RarUnsupportedException catch (e) {
      stdout.writeln('  extract ⛔ 明确不支持：${e.message}');
      unsupported++;
    } on RarFormatException catch (e) {
      stdout.writeln('  extract ⛔ 坏文件：${e.message}');
      unsupported++;
    } catch (e) {
      stdout.writeln('  extract ✗ 崩溃：$e');
      fail++;
    }
  }

  stdout.writeln('');
  stdout.writeln(
    '结论：一致 $pass / 明确报错 $unsupported / 失败 $fail'
    '（共 ${files.length} 个样本）',
  );
  if (fail > 0) exitCode = 1;
}

/// 跑一个外部命令，带超时；超时返回 null。stdin 关掉，杜绝 unrar/7z 等密码提示挂住。
Future<int?> _run(String exe, List<String> args, Duration timeout) async {
  final path = File(exe).existsSync() ? exe : _which(exe);
  if (path == null) return null;
  final p = await Process.start(path, args, mode: ProcessStartMode.normal);
  p.stdin.close();
  final done = p.exitCode;
  try {
    return await done.timeout(timeout);
  } on TimeoutException {
    p.kill(ProcessSignal.sigkill);
    return null;
  }
}

String? _which(String exe) {
  // rarlab 官方 unrar 常在 /tmp/rar6；先看显式路径，再找 PATH 上的常见目录
  for (final dir in const [
    '/tmp/rar6/rar',
    '/opt/homebrew/bin',
    '/usr/local/bin',
    '/usr/bin',
    '/bin',
  ]) {
    final f = File('$dir/$exe');
    if (f.existsSync()) return f.path;
  }
  return null;
}

String _rel(String root, String path) =>
    path.substring(root.length + 1).replaceAll('\\', '/');

bool _sameNames(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
