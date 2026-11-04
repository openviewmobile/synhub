// 静态守卫：**删除确认文案不许承诺"连带删除文件"**（第 383 轮 · DA29）。
//
// ★ 为什么会有这条（r382 真机 + 官方对照）：
//   删任务的二次确认正文原来写
//     `The task and its downloaded files will be deleted. This cannot be undone.`
//   /「任务和已下载的文件都会被删除，且无法恢复。」
//   而 **r382 真机把它证伪了**：用宿主只读 HTTP 探针做对照实验，**3 个任务
//   （1 个带文件清单 + 2 个普通 URL 任务）删完后，`home/Download` 下的
//   `probe_r381/382/383.zip` 全都还在**（点空态里的显式 `Refresh` 才读到真值）。
//   官方前端（`DownloadStation-x86_64-4.1.2-5012.spk` → `ui/texts/enu/strings:228`）
//   的同一句 `download_cfrm_remove` = **"Are you sure you want to remove the
//   download task?"** —— **根本不提删文件**。
//   ⇒ 这是**我们自己发明的承诺**（"会撒谎的文案"族，与 r378 的 R8 同族），
//     而且它**方向相反**：用户以为文件会被清掉，实际文件留下了。
//
// ★ 为什么守卫是"**不许提文件**"而不是"必须说文件会留下"：
//   服务端在什么状态下才 unlink **仍是留白**（未完成任务/部分文件的删除行为
//   我们没验过）⇒ 写"文件会留下"同样是一种**未被验证的承诺**。
//   唯一在**所有状态下都真**的写法是：只说"任务从列表移除 + 不可恢复"。
//   ★ 这条纪律比"照抄官方"更强：**写多了就是新的撒谎**。
//
// ★ 反向断言：把**修前的原文**喂给同一条判据必须判红（否则"0 命中"可能只是
//   正则写错了 —— §1.3.0.1 的老教训）；同时"任务会被移除"这类**合法**文案
//   必须**不**被误杀。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 四个**确认删除**的文案 key（r383 一起改的四处）。
const List<String> _confirmKeys = <String>[
  'dsDeleteBody',
  'dsDeleteBodyN',
  'dsClearFinishedConfirm',
  'dsRemoveErrorsConfirm',
];

/// 「承诺连带删文件」的形状（中英各一组）。
final RegExp _fileClaimZh = RegExp(r'(已下载|下载)的文件');
final RegExp _fileClaimEn = RegExp(
  r'(its|their|the)\s+downloaded\s+files?|downloaded\s+files?\s+will\s+be\s+deleted',
  caseSensitive: false,
);

/// 判据：这段文案有没有承诺"连带删文件"？命中返回命中的子串（便于失败信息）。
String? fileClaimIn(String value) {
  final zh = _fileClaimZh.firstMatch(value);
  if (zh != null) return zh.group(0);
  final en = _fileClaimEn.firstMatch(value);
  if (en != null) return en.group(0);
  return null;
}

Map<String, dynamic> _arb(String path) =>
    json.decode(File(path).readAsStringSync()) as Map<String, dynamic>;

void main() {
  test('★★ DA29：四个删除确认文案都不许承诺"连带删除已下载文件"', () {
    for (final path in <String>['lib/l10n/app_zh.arb', 'lib/l10n/app_en.arb']) {
      final arb = _arb(path);
      for (final k in _confirmKeys) {
        final v = arb[k];
        expect(v, isA<String>(), reason: '$path 里 $k 必须是字符串');
        expect(
          fileClaimIn(v as String),
          isNull,
          reason: '$path 的 $k 又在承诺"连带删文件"了（r382 真机已证伪）：$v',
        );
        // 正向控制：改完也不能变成"什么都没说"（必须还讲清"任务会被移除"）。
        expect(
          v.toLowerCase().contains('task') || v.contains('任务'),
          isTrue,
          reason: '$path 的 $k 必须还讲清楚删的是"任务"：$v',
        );
      }
    }
  });

  test('★ DA29：Dart 侧**回退字面量**（`dataText` 的第二实参）同样不许承诺', () {
    // `dataText('dsClearFinishedConfirm', '<回退文案>')` —— ARB 缺键时用的就是它，
    // 所以它必须与 ARB 同一条纪律（§2.0.47「某一路径有守卫 ≠ 所有路径都干净」）。
    //
    // ★★ 只认**真正的调用实参**，不许整行扫：r383 第一版整行扫把**注释**和
    //    `dsForceCompleteConfirm`（"已下载的文件会保留在目标文件夹"，那是官方
    //    `str_force_complete_confirm` 的语义，**不是**本次要拦的承诺）全抓了进来
    //    —— 正是 §2.0.48 记的"纯文本守卫会把注释数进去"。这里改成按
    //    `dataText('key', 'fallback')` 的**括号实参**取，且只看 `_confirmKeys`。
    final call = RegExp(
      r"dataText\(\s*'([A-Za-z0-9_]+)'\s*,\s*'((?:\\.|[^'\\])*)'",
      multiLine: true,
      dotAll: true,
    );
    final hits = <String>[];
    var seen = 0;
    for (final e in Directory('lib/src/features/downloads').listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      for (final m in call.allMatches(e.readAsStringSync())) {
        final key = m.group(1)!;
        if (!_confirmKeys.contains(key)) continue;
        seen++;
        final claim = fileClaimIn(m.group(2)!);
        if (claim != null) hits.add('${e.path}  $key  $claim');
      }
    }
    expect(hits, isEmpty, reason: '回退字面量里还有"连带删文件"承诺：\n${hits.join('\n')}');
    // ★ 反向控制（防"0 命中只是没扫到"）：这四个 key 里，`dsClearFinishedConfirm`
    //   与 `dsRemoveErrorsConfirm` **确实**走 `dataText(key, fallback)`（下载页批量菜单），
    //   所以必须扫到 **≥2** 条；另两个（`dsDeleteBody`/`dsDeleteBodyN`）是直接
    //   `t.dsDeleteBody` 渲染的，**由上面那条 ARB 用例管**（不是漏扫）。
    expect(seen, greaterThanOrEqualTo(2),
        reason: '没扫到 dataText 回退字面量，说明正则失效了（不是文案干净）');
  });

  test('判据本身有效（反向：修前原文必须被判红，合法文案不许被误杀）', () {
    // 修前的四条原文（真机/ARB 逐字）—— 一条都不许放过。
    for (final leaked in <String>[
      'The task and its downloaded files will be deleted. This cannot be undone.',
      'The 3 selected tasks and their downloaded files will be deleted. This cannot be undone.',
      'Completed tasks and their downloaded files will be deleted and cannot be recovered.',
      'Delete all failed tasks? Tasks and downloaded files will be deleted and cannot be recovered.',
      '任务和已下载的文件都会被删除，且无法恢复。',
      '3 个任务和已下载的文件都会被删除，且无法恢复。',
      '已完成的任务和已下载的文件都会被删除，且无法恢复。',
      '要删除所有错误任务吗？任务和已下载的文件都会被删除，且无法恢复。',
    ]) {
      expect(fileClaimIn(leaked), isNotNull, reason: '修前原文必须判红：$leaked');
    }
    // 反向：合法文案不许误杀（否则守卫会满屏假阳性）。
    for (final ok in <String>[
      '任务会从下载列表中移除，此操作无法恢复。',
      '选中的 3 个任务会从下载列表中移除，此操作无法恢复。',
      'The task will be removed from the download list. This cannot be undone.',
      'The 3 selected tasks will be removed from the download list. This cannot be undone.',
      '要删除所有错误任务吗？此操作无法恢复。',
      // ★ 合法：**单独**删文件（「文件」里的动作）本来就该这么写。
      'Delete "probe_r381.zip"? This cannot be undone.',
      '要删除这些文件吗？此操作无法恢复。',
    ]) {
      expect(fileClaimIn(ok), isNull, reason: '合法文案不许误杀：$ok');
    }
  });
}
