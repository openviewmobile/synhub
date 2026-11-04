// ★★★ 第 349 轮：**文件行锁徽标的语义守卫**（结清 **U13** 时顺手补的）。
//
// 背景：r348 的审计里我写下过一句
//   「`docker` 共享文件夹有加密锁徽标 ⇒「**加密共享**文件夹的锁徽标」实现正确 ✅」
// ★★ 本轮复核**代码**发现那句话**用错了词**：
//   `lib/src/features/files/file_row.dart:24-29` 的 `fileLockTooltip()` 只有三种返回值 ——
//     `disableDownload==true`      → `fileDownloadForbidden`（禁止下载）
//     `isMountPoint==true`         → `readOnlyShare`（只读共享）
//     否则                          → `readOnly`（只读）
//   整个 `features/files/` 里**没有任何"加密共享"的锁语义**
//   （`grep -rni encrypt lib/src/features/files/*.dart` 的命中全在 EPUB 的 `book_fb3.dart`）。
//   ⇒ 徽标表达的是「**只读 / 禁止下载**」，不是「加密」。**把话改对，并补一条守卫钉住它。**
//
// ★★ 为什么守卫**不**去切语言：`context.t` 是
//   `AppText.of(this) ?? AppTextZh()`（`lib/src/core/i18n/l10n.dart:22`）——
//   **没有 Localizations 时恒回落中文**（仪器⑯/㉑「装置不诚实 ⇒ 用例不可能红」）。
//   所以这里钉**结构**（三条分支的产出、优先级、语义），不钉语言。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/features/files/file_row.dart';

/// 在一个真 `BuildContext` 上取 tooltip（`fileLockTooltip` 需要 `context.t`）。
Future<String> _tooltip(WidgetTester tester, FileEntryDto e) async {
  late String out;
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Builder(
        builder: (ctx) {
          out = fileLockTooltip(ctx, e);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return out;
}

FileEntryDto _entry({
  bool disableDownload = false,
  String? mountPointType,
  bool canWrite = true,
  bool permKnown = true,
}) =>
    FileEntryDto(
      name: 'x',
      path: '/x',
      disableDownload: disableDownload,
      mountPointType: mountPointType,
      canWrite: canWrite,
      permKnown: permKnown,
    );

void main() {
  group('U13 锁徽标语义（只读/禁止下载 —— 不是加密）', () {
    testWidgets('装置自证：两种显然不同的输入给出真值，不是空串', (tester) async {
      final a = await _tooltip(tester, _entry());
      final b = await _tooltip(tester, _entry(disableDownload: true));
      expect(a.trim(), isNotEmpty, reason: 'tooltip 空串 ⇒ 后面全是假绿');
      expect(b.trim(), isNotEmpty);
    });

    testWidgets('① 三条分支产出三个**互不相同**的串（否则用户区分不出来）', (tester) async {
      final forbidden = await _tooltip(tester, _entry(disableDownload: true));
      final roShare =
          await _tooltip(tester, _entry(mountPointType: 'remote'));
      final roPlain = await _tooltip(tester, _entry(canWrite: false));
      final set = {forbidden, roShare, roPlain};
      expect(set.length, 3,
          reason: '禁止下载 / 只读共享 / 只读 应各说各的，实际：'
              '[$forbidden] [$roShare] [$roPlain]');
    });

    testWidgets('② 优先级：disableDownload 压过 isMountPoint', (tester) async {
      final onlyMount = await _tooltip(tester, _entry(mountPointType: 'remote'));
      final both = await _tooltip(
          tester, _entry(disableDownload: true, mountPointType: 'remote'));
      expect(both, isNot(equals(onlyMount)),
          reason: '`disableDownload` 必须**优先**报"禁止下载"'
              '（`file_row.dart:26` 那条 if 在最前），否则用户以为只是只读');
    });

    testWidgets('③ isMountPoint 的档位与普通只读**不同**（"只读共享" vs "只读"）', (tester) async {
      final roShare =
          await _tooltip(tester, _entry(mountPointType: 'remote'));
      final roPlain = await _tooltip(tester, _entry(canWrite: false));
      expect(roShare, isNot(equals(roPlain)),
          reason: '挂载点（共享根）要区别于普通只读文件 —— `file_row.dart:27`');
    });

    testWidgets('④ ★ 三种说法**都不许**出现"加密"（订正 r348 用错的那个词）', (tester) async {
      for (final e in [
        _entry(disableDownload: true),
        _entry(mountPointType: 'remote'),
        _entry(canWrite: false),
      ]) {
        final s = await _tooltip(tester, e);
        expect(s.contains('加密'), isFalse,
            reason: '锁徽标讲的是**只读/禁止下载**，不是"加密共享"：`$s` '
                '（`fileLockTooltip` 里没有加密语义；见本文件头注释）');
      }
    });
  });
}
