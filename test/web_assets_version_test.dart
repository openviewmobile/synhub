// ★★ 第 338 轮（D37）守卫：**web 的 wasm 资产必须与 `pubspec.lock` 里的版本一一对应**。
//
// 症状（真浏览器实测）：`sqlite3` 包升到 3.6.0，而 `web/sqlite3.wasm` 还是
// sqlite3-2.4.6 的产物 ⇒
//   `TypeError: WebAssembly.instantiate(): Import #25 "env": module is not an object or function`
// 这是**静默**的：编译、打包、单元测试全都不报，只有真浏览器跑到 wasm 实例化时才炸
// （而且只在真的用库那一步，见 `docs/evidence-r338/README.md` §4 的独立判据）。
//
// 这个守卫把"版本 ↔ 资产"的对应关系**钉成断言**：
//   ① `pubspec.lock` 里 `sqlite3` / `drift` 的解析版本 == 本文件钉的版本；
//   ② 两个资产的**字节数 + sha256** == 本文件钉的值。
// 谁升了依赖却没重新取资产 ⇒ 立刻红，并在这里写明该去哪取。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/digests/sha256.dart';

/// 取自 `https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-<版本>/sqlite3.wasm`
const String kPinnedSqlite3Version = '3.6.0';
const int kPinnedWasmBytes = 748686;
const String kPinnedWasmSha256 =
    '13d3f11d05b39ba0618a7115fb41640a5d48b6300f5d3f325f554b42bd6688a4';

/// 取自 drift 仓库对应版本的 `web/drift_worker.dart.js`
/// （`https://github.com/simolus3/drift/releases/download/drift-<版本>/drift_worker.dart.js`）
const String kPinnedDriftVersion = '2.35.3';
const int kPinnedWorkerBytes = 361829;
const String kPinnedWorkerSha256 =
    'a54b81412d4c4ab56653bb9e4c02912b0820bb37e2bba00722ddef4d78083d4a';

/// 从 lock 文件里取某包的解析版本（`pubspec.lock` 是 YAML，但结构固定，不引入依赖）
String _lockedVersion(String lock, String pkg) {
  final lines = lock.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (lines[i] == '  $pkg:') {
      for (var j = i + 1; j < lines.length && j < i + 8; j++) {
        final m = RegExp(r'^    version: "([^"]+)"$').firstMatch(lines[j]);
        if (m != null) return m.group(1)!;
      }
    }
  }
  return '';
}

void main() {
  test('① pubspec.lock 的 sqlite3/drift 版本 == 钉住的版本（升依赖必须来这里改）', () {
    final lock = File('pubspec.lock').readAsStringSync();
    // 反向：确认真的读到了内容（读空文件时下面两条会"看起来通过"）
    expect(lock.length, greaterThan(1000));
    expect(_lockedVersion(lock, 'sqlite3'), kPinnedSqlite3Version);
    expect(_lockedVersion(lock, 'drift'), kPinnedDriftVersion);
    // 自证解析器没坏：随便取一个必然存在的包
    expect(_lockedVersion(lock, 'flutter_test'), isNotEmpty);
  });

  test('② web/sqlite3.wasm 的字节数与 sha256 == 钉住的值', () {
    final f = File('web/sqlite3.wasm');
    expect(f.existsSync(), isTrue, reason: 'web 的 wasm 资产必须在仓库里');
    expect(f.lengthSync(), kPinnedWasmBytes);
    expect(
      _sha256Of(f),
      kPinnedWasmSha256,
      reason: 'sha 变了 ⇒ 资产被换过；换资产必须同时更新本文件与 '
          'docs/platform-web.md §14.5（sqlite3 $kPinnedSqlite3Version）',
    );
  });

  test('③ web/drift_worker.dart.js 的字节数与 sha256 == 钉住的值', () {
    final f = File('web/drift_worker.dart.js');
    expect(f.existsSync(), isTrue);
    expect(f.lengthSync(), kPinnedWorkerBytes);
    expect(_sha256Of(f), kPinnedWorkerSha256);
  });

  test('④ 反向：钉住的版本确实出现在 lock 里（防"常量写错也能绿"）', () {
    final lock = File('pubspec.lock').readAsStringSync();
    expect(lock.contains('version: "$kPinnedSqlite3Version"'), isTrue);
    expect(lock.contains('version: "$kPinnedDriftVersion"'), isTrue);
  });
}

/// sha256：**纯 Dart**（`pointycastle` 已是直接依赖，仓库既有写法见
/// `lib/src/features/analytics/usage_event.dart` 的 `pseudonymize`）——
/// 不调宿主命令，免得在没装 `shasum`/`sha256sum` 的机器上出现"另一套行为"。
String _sha256Of(File f) {
  final digest = SHA256Digest().process(f.readAsBytesSync());
  if (digest.length != 32) {
    throw StateError('sha256 长度不对：${digest.length}');
  }
  final hex = digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  if (hex.length != 64) {
    throw StateError('sha256 形状不对：$hex');
  }
  return hex;
}
