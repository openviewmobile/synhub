// ignore_for_file: depend_on_referenced_packages
// 第 279 轮：通过 VM service 驱动 `tool/r279_macos_harness.dart` 起的那个 App。
//
// 两种用法：
//
//   ① 单条命令
//      dart run tool/r279_drive.dart <ws-url> ping
//      dart run tool/r279_drive.dart <ws-url> connect http://127.0.0.1:18080
//      dart run tool/r279_drive.dart <ws-url> login mockuser mockpass
//      dart run tool/r279_drive.dart <ws-url> tab files
//      dart run tool/r279_drive.dart <ws-url> route /home
//      dart run tool/r279_drive.dart <ws-url> pushNotes
//      dart run tool/r279_drive.dart <ws-url> state
//      dart run tool/r279_drive.dart <ws-url> shot /tmp/x.png
//
//   ② 脚本（一次连上、顺序跑完整条链路，每步之间可选截图）
//      dart run tool/r279_drive.dart <ws-url> script /tmp/r279_plan.json
//
//      plan 文件是一行一个 JSON：
//        {"op":"connect","url":"http://127.0.0.1:18080"}
//        {"op":"login","account":"mockuser","password":"x"}
//        {"op":"shot","path":"/tmp/r279_a.png"}
//        {"op":"sleep","ms":1200}
//
// 为什么要有"脚本"模式：每跑一次 `dart run` 都要重新编译一遍（几秒），
// 而真跑一条"连接→登录→切 tab→截图"的链路有十几步。
//
// 实现要点（第 279 轮踩过的坑）：命令通过 `evaluate` 打进 App isolate里的顶层
// `r279(json)`；**必须带 nonce**，否则第二次调用会读到上一条命令的陈旧结果
// （第一次实测：`connect` 拿回了 `ping` 的 `pong`）。
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: r279_drive.dart <ws-url> <cmd> [args...]');
    exit(64);
  }
  final wsUrl = args[0];
  final cmd = args[1];
  final driver = _Driver(wsUrl);
  await driver.open();
  try {
    if (cmd == 'script') {
      final file = File(args[2]);
      for (final line in file.readAsLinesSync()) {
        final t = line.trim();
        if (t.isEmpty || t.startsWith('#')) continue;
        final op = jsonDecode(t) as Map<String, dynamic>;
        await driver.run(op);
      }
    } else {
      await driver.run(_encode(cmd, args.skip(2).toList()));
    }
  } finally {
    await driver.close();
  }
}

Map<String, dynamic> _encode(String cmd, List<String> rest) {
  switch (cmd) {
    case 'connect':
      return {'op': 'connect', 'url': rest[0]};
    case 'connectQC':
      return {'op': 'connectQC', 'id': rest[0]};
    case 'login':
      return {
        'op': 'login',
        'account': rest[0],
        'password': rest.length > 1 ? rest[1] : '',
        'remember': rest.length > 2 && rest[2] == 'remember',
      };
    case 'tab':
      return {'op': 'tab', 'name': rest[0]};
    case 'route':
      return {'op': 'route', 'path': rest[0]};
    case 'shot':
      return {'op': 'shot', 'path': rest[0]};
    default:
      return {'op': cmd};
  }
}

class _Driver {
  _Driver(this.wsUrl);

  final String wsUrl;
  VmService? _vm;
  IsolateRef? _iso;
  LibraryRef? _lib;
  int _nonce = 0;

  Future<void> open() async {
    final vm = await vmServiceConnectUri(wsUrl);
    _vm = vm;
    final info = await vm.getVM();
    _iso = info.isolates!.firstWhere((i) => i.name == 'main');
    final isolate = await vm.getIsolate(_iso!.id!);
    _lib = isolate.libraries!.firstWhere(
      (l) => (l.uri ?? '').endsWith('r279_macos_harness.dart'),
      orElse: () => throw StateError(
        'harness library not found — run the app with '
        '-t tool/r279_macos_harness.dart',
      ),
    );
  }

  Future<void> close() async => _vm?.dispose();

  Future<void> run(Map<String, dynamic> op) async {
    final kind = '${op['op']}';
    if (kind == 'shot') {
      await _shot('${op['path']}');
      return;
    }
    if (kind == 'sleep') {
      await Future<void>.delayed(Duration(milliseconds: op['ms'] as int? ?? 500));
      return;
    }
    final nonce = 'n${++_nonce}';
    final payload = <String, dynamic>{'cmd': kind, 'nonce': nonce, ...op}
      ..remove('op');
    final expr = 'r279(${jsonEncode(jsonEncode(payload))})';
    final r = await _vm!.evaluate(_iso!.id!, _lib!.id!, expr);
    if (r is ErrorRef) {
      stderr.writeln('[$kind] evaluate error: ${r.message}');
      return;
    }
    final out = await _poll(nonce);
    stdout.writeln('[$kind] $out');
  }

  Future<String> _poll(String nonce, {int tries = 240}) async {
    for (var i = 0; i < tries; i++) {
      final s = await _readLast();
      if (s != null) {
        try {
          final m = jsonDecode(s) as Map<String, dynamic>;
          if (m['nonce'] == nonce &&
              (m['state'] == 'ok' || m['state'] == 'error')) {
            return s;
          }
        } catch (_) {
          // 还在写/不是 JSON：继续等
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return '{"state":"timeout"}';
  }

  /// 读 `r279Last` 的**完整字符串**。
  ///
  /// ★ 坑（第 279 轮，连踩两次）：`evaluate` 回的 [InstanceRef] 一旦字符串
  /// **比较长**（`state` 那条 JSON 就是），`valueAsString` 会**被截断**（并置
  /// `valueAsStringIsTruncated`）—— 于是 `jsonDecode` 永远抛、看起来像
  /// "命令永远跑不完"。`ping`/`tab` 这类短结果是好的，所以只有 `state` 出问题。
  ///
  /// 稳妥做法：**分片读**。先 `r279Last.length`，再按 200 字符一段
  /// `r279Last.substring(a, b)` —— 每片都很短，永远不会被截断。
  Future<String?> _readLast() async {
    final len = await _evaluate('r279Last.length');
    if (len is! InstanceRef || len.valueAsString == null) return null;
    final n = int.tryParse(len.valueAsString!);
    if (n == null || n == 0) return null;
    final buf = StringBuffer();
    for (var i = 0; i < n; i += 200) {
      final end = (i + 200) > n ? n : i + 200;
      final piece = await _evaluate('r279Last.substring($i, $end)');
      if (piece is! InstanceRef || piece.valueAsString == null) return null;
      buf.write(piece.valueAsString);
    }
    return buf.toString();
  }

  Future<Object?> _evaluate(String expr) =>
      _vm!.evaluate(_iso!.id!, _lib!.id!, expr);

  Future<void> _shot(String out) async {
    final r = await _vm!.callServiceExtension(
      '_flutter.screenshot',
      isolateId: _iso!.id,
    );
    final json = r.json ?? const <String, Object?>{};
    final payload = json['result'] ?? json;
    final b64 = payload is Map ? payload['screenshot'] as String? : null;
    if (b64 == null || b64.isEmpty) {
      stderr.writeln('[shot] no screenshot: ${jsonEncode(json)}');
      return;
    }
    File(out).writeAsBytesSync(base64Decode(b64));
    stdout.writeln('[shot] $out ${File(out).lengthSync()} bytes');
  }
}
