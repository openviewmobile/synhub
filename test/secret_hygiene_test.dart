// 「真实 NAS 口令不许落库」的钉子（r295）。
//
// 背景：真机/真 NAS 的端到端脚本图省事，把口令**字面量**写进了 15 个文件
// （6 个 `integration_test/` 走查、`test/dsm_live_test.dart`、`test/cgi_encryption_test.dart`、
// `test/note_crypto_test.dart`、2 个 `tool/r*_macos*.sh`、`tool/flt_apis.dart`，
// 以及 3 份 docs 里作为"实测记录"被引用的形态）。
// 2026-09 的实测口令**只有 10 字符、且第 2 位是 `*`、第 5 位是 `:`**
// —— 这是一个**结构性指纹**：不打印口令本身也能扫出"是不是同形"。
//
// 本文件钉三件事：
//   ① **自证**：指纹正则与"口令赋值"正则都能命中已知样本
//      （AGENTS §1.3.0.1：校验 0 条不是成功，是没校验）；
//   ② 与真实 NAS 相关的脚本里**不许**出现同形裸口令；
//   ③ 这些脚本里的口令必须**来自环境/占位符**（不许是字面量）。
//
// ★ 口径说明（不许放宽成本文的例外）：
//   * 允许的形态：`<占位符>`、空串、`${SYNO_NAS_PASSWORD…}`、`String.fromEnvironment(…)`；
//   * **合成**口令 `q*7B:vT3D1`（与真实口令同形，用于单测夹具）是**允许**的 ——
//     它在 `test/cgi_encryption_test.dart` / `test/note_crypto_test.dart` 里当输入，
//     不含任何真实凭据；形状相同才使 `javaUrlEncode` 的 `*`/`:` 断言仍有意义。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 真实口令的**同形指纹**：10 个可打印字符、`[1]=='*'`、`[4]==':'`。
final RegExp _sameShape = RegExp(r"[!-~]\*[!-~]{2}:[!-~]{5}");

/// 口令赋值形态（Dart 与 shell 都覆盖）。
final RegExp _passwordAssign = RegExp(
  r"""(?:passwd|password|PASSWORD|PWD)\s*[:=]\s*['"]([^'"]{6,})['"]""",
);

/// 允许出现的合成口令（单测夹具输入，不是凭据）。
const _syntheticPasswords = {'q*7B:vT3D1'};

/// 允许出现的**公开假口令**：Mock Server 的口令就写在 server 里，不是秘密。
const _publicFakePasswords = {'mockpass'};

/// 与真实 NAS 打交道的脚本 —— **只收"确实会连真机"的这些**，不含全仓。
const _nasTouchingFiles = [
  'integration_test/linux_walkthrough_test.dart',
  'integration_test/macos_ui_audit_test.dart',
  'integration_test/macos_walkthrough_test.dart',
  'integration_test/r132_ios_ui_audit_test.dart',
  'integration_test/r283_ipad_adaptive_test.dart',
  'integration_test/r284_macos_files_panes_test.dart',
  'test/dsm_live_test.dart',
  'tool/r131_macos_audit.sh',
  'tool/r284_macos_files.sh',
  'tool/flt_apis.dart',
];

bool _isAllowedValue(String v) {
  if (v.isEmpty) return true;
  if (v.startsWith('<')) return true; // <在此填写你的口令>
  if (v.contains(r'$')) return true; // ${SYNO_NAS_PASSWORD…} / $SYNO_NAS_PASSWORD
  if (v.contains('String.fromEnvironment')) return true;
  if (v.contains('mock')) return true; // mock 服务的假口令（公开值）
  return _syntheticPasswords.contains(v) || _publicFakePasswords.contains(v);
}

void main() {
  test('① 自证：两条正则都能命中已知样本（否则"0 命中"不算校验）', () {
    expect(
      _sameShape.hasMatch('q*7B:vT3D1'),
      isTrue,
      reason: '同形指纹必须能命中一个已知的 10 字符同形口令',
    );
    expect(_sameShape.hasMatch('no-star-here'), isFalse);

    final m = _passwordAssign.firstMatch("password: 'abcdefgh'");
    expect(m?.group(1), 'abcdefgh', reason: '口令赋值模式必须能抓出值');
    expect(_passwordAssign.firstMatch('password: getFromEnv()'), isNull);
  });

  test('② 与真实 NAS 相关的脚本里没有"同形裸口令"', () {
    for (final f in _nasTouchingFiles) {
      final file = File(f);
      expect(file.existsSync(), isTrue, reason: '$f 不见了？守卫清单要更新');
      final text = file.readAsStringSync();
      for (final m in _sameShape.allMatches(text)) {
        expect(
          _syntheticPasswords,
          contains(m.group(0)),
          reason:
              '★ $f 里出现同形裸口令（10 字符、[1]=*、[4]=:）—— '
              '真实口令一律只从环境变量/dart-define 来',
        );
      }
    }
  });

  test('③ 这些脚本里的口令必须是环境变量或占位符', () {
    for (final f in _nasTouchingFiles) {
      final text = File(f).readAsStringSync();
      for (final m in _passwordAssign.allMatches(text)) {
        final v = m.group(1)!;
        expect(
          _isAllowedValue(v),
          isTrue,
          reason: '★ $f 里的口令是字面量（len=${v.length}）—— 改成环境变量/占位符',
        );
      }
    }
  });
}
