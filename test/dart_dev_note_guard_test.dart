// 静态守卫：`lib/src/**/*.dart` 里**用户可见的字符串**不许出现"开发侧用语"（r378）。
//
// ★ 为什么单开一个文件：ARB 侧已有 R8（`test/i18n_user_facing_copy_test.dart`），
//   但**Dart 兜底字面量**（`_zh('key','中文')` / `fsG4(key,'中文')` /
//   `dataText('key','中文')` 的第二个参数）是那条守卫的**已知豁免区** ——
//   本轮实测：ARB 全清之后，Dart 侧还藏着 **5 处**同族泄漏
//   （`原生侧仍报告未配置`、`本仓库尚未自研完成`、`这台设备上未取证`、
//   `服务端成功回包未取证`、`电台播放尚未取证`）。
//   ⇒ 不扫这里，同一类缺陷会**从豁免区一次次漏回来**（§2.0.51 同族）。
//
// ★ 清点的字面形状（§2.0.63⑤）：**按行**扫描 `.dart` 源码里的开发用语词，
//   已剥掉 `//` 行注释、`/* */` 块注释；**豁免**（每条都写了理由）：
//   ① `debugPrint(` 那一行 —— 它本来就是开发者日志通道；
//   ② 下面 `_diagnosticOnly` 列出的文件 —— 它们整文件都是**给诊断/导出看的**
//      渲染保真度笔记（`report.note(...)` / `notes.add(...)`），不是用户文案。
//   任何**新增**豁免都必须在这里写清理由 —— 别用"看着像"绕过。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 诊断/导出专用文件（整文件豁免；**用户可见文案不在这些文件里**）。
const Map<String, String> _diagnosticOnly = {
  'lib/src/features/office/office_doc_view.dart':
      'Office 渲染保真度报告（report.note）：只说"这份文档哪块没渲染"，给诊断页/导出看',
  'lib/src/features/office/office_slides_schema.dart': '幻灯片 schema 观察笔记（observed.*）',
  'lib/src/features/office/office_slides_canvas.dart': '幻灯片画布渲染降级原因登记（report/notes 通道）',
  'lib/src/features/office/office_sheet_schema.dart': '工作表 schema 观察笔记（observed.* 通道，给诊断/导出看）',
  'lib/src/features/office/office_doc_table.dart': '表格渲染降级原因登记（report/notes 通道，给诊断看）',
  'lib/src/features/office/office_doc_page_frame.dart': '页面装饰渲染降级原因登记（report/notes 通道）',
  'lib/src/features/office/office_doc_ooxml.dart': 'OOXML 结构观察笔记登记（notes 通道，给诊断/导出看）',
  'lib/src/features/office/office_sheet_view.dart': '自动筛选未渲染的原因登记（report.note 通道）',
  'lib/src/data/auth_extra_api.dart':
      '未实现 API 的依据表（逐条写"➖ 不做"并引用 docs），只给诊断/对账看',
};

/// 与 ARB 侧 R8 同源的判据（这里再写一份是因为 Dart 文件不走 ARB 守卫）。
/// ★ 拉丁词要求**词边界**：`officeDocGateUnverified`、`chatUnverifiedErrorCodes`
///   这类**标识符/key 名**里也含 `Unverified`，但它们是代码符号、不是给用户看的词
///   ⇒ 不加边界会满屏假阳性（第一版就被这 4 条咬到）。中文没有词边界概念，
///   所以中英文分支分开写。
final RegExp _devNoteRe = RegExp(
  r'(?<![A-Za-z])(?:real device|this repo|this round|unverified|native side'
  r'|Kotlin)(?![A-Za-z])'
  r'|真机|本仓库|本轮|未验证|未经验证|未取证|原生侧',
  caseSensitive: false,
);

/// 剥注释：行注释（`//`，但不吃掉 `://`）＋整块 `/* */`。
String stripComments(String src) {
  final noBlock = src.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return noBlock
      .split('\n')
      .map((l) {
        // 逐个数 `//`：**前面是 `:` 的**（`https://`）不是注释起点，跳过继续找。
        var from = 0;
        while (true) {
          final i = l.indexOf('//', from);
          if (i < 0) return l;
          if (i > 0 && l[i - 1] == ':') {
            from = i + 2;
            continue;
          }
          return l.substring(0, i);
        }
      })
      .join('\n');
}

/// 找违规行：返回 `文件:行号 片段`。
List<String> devNoteViolationsIn(String path, String src) {
  if (_diagnosticOnly.containsKey(path)) return const [];
  final out = <String>[];
  final lines = stripComments(src).split('\n');
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (l.contains('debugPrint(')) continue; // 开发者日志通道
    final m = _devNoteRe.firstMatch(l);
    if (m != null) {
      out.add('$path:${i + 1}  「${m.group(0)}」  ${l.trim()}');
    }
  }
  return out;
}

void main() {
  test('lib/src 的 Dart 字符串里不许有开发侧用语（ARB 守卫的豁免区补位）', () {
    final violations = <String>[];
    var scanned = 0;
    for (final e in Directory('lib/src').listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      // 设计稿原型（lib/src/design/）：串是设计说明（"标注""评审"等），
      // 不是开发侧用语；只经 dev 档画廊可达。
      if (e.path.startsWith('lib/src/design/')) continue;
      scanned++;
      violations.addAll(devNoteViolationsIn(e.path, e.readAsStringSync()));
    }
    // 防空转：必须真的扫到了文件（§1.3.0.1：校验 0 条不是成功）。
    expect(scanned, greaterThan(300), reason: '没扫到文件 ⇒ 这条守卫是假绿');
    expect(
      violations,
      isEmpty,
      reason:
          '下面这些是**用户会看到**的兜底字面量里的开发用语，'
          '要么改成用户话，要么进 `_diagnosticOnly` 并写清理由：\n'
          '${violations.join('\n')}',
    );
  });

  test('判据有效 + 豁免是有理由的（反向验证）', () {
    // ① 真阳性：本轮真机抓到过的兜底字面量必须被判红。
    for (final s in <String>[
      "dataText('k', '这台设备上未取证，暂不支持。');",
      "fsG4('k', '原生侧仍报告未配置');",
      "officeLibraryText('k', '已请求应用主题（服务端成功回包未取证）');",
      "Text('this repo does not verify it on a device');",
    ]) {
      expect(
        devNoteViolationsIn('lib/src/features/x/f.dart', s),
        isNotEmpty,
        reason: '必须判红：$s',
      );
    }
    // ② 注释与 debugPrint 不算（否则守卫会把开发者笔记全判红 ⇒ 没人愿意用它）。
    expect(
      devNoteViolationsIn(
        'lib/src/features/x/f.dart',
        '// 真机夹具 13 份 .odoc\n'
        'debugPrint("真机存在，但目录里没有方法表");\n'
        'final u = "https://nas.example.com:5001"; // 真机地址\n',
      ),
      isEmpty,
    );
    // ③ 豁免文件即使命中也不报（但必须**在表里**，且表里每条都有理由）。
    expect(
      devNoteViolationsIn(
        'lib/src/features/office/office_doc_view.dart',
        "report.note('真机夹具 13 份 .odoc 全部有 page_decorate');",
      ),
      isEmpty,
    );
    for (final e in _diagnosticOnly.entries) {
      expect(
        e.value.length,
        greaterThan(8),
        reason: '${e.key} 的豁免理由太短 ⇒ 等于没写',
      );
      expect(File(e.key).existsSync(), isTrue, reason: '${e.key} 已不存在 ⇒ 删掉豁免');
    }
  });
}
