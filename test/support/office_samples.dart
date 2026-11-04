// 官方 Office 模板样本（Synology Office SPK 内置 `template/`）的**统一定位**。
//
// ## 为什么单独抽出来（第 251 轮）
//
// 6 个 office 测试文件此前都把样本目录硬编码成 `/tmp/spk/export_Office/template`。
// `/tmp` 会被系统清理 ⇒ 一旦丢失就是 134 条 `PathNotFoundException`（长期基线里的
// "外部环境失败"）。第 251 轮把官方 SPK（`Office-DSM_Enterprise-x86_64-PAS-3.8.0-22711.spk`）
// 的 `template/` 全量（53 份 `text.json` + 73 个 `files/` 图片二进制，共 311 文件）
// 存进了**官方样例库**（`~/synology_samples/office-templates`），并给了恢复脚本
// `scripts/restore_office_samples.sh`。
//
// 查找顺序（**只读，不造数据**）：
//   1. 环境变量 `OFFICE_NATIVE_SAMPLES`（显式指定优先）；
//   2. `/tmp/spk/export_Office/template`（老路径；由恢复脚本或历史解包提供）；
//   3. `~/synology_samples/office-templates`（样例库，长期保存）。
// 都找不到时返回老路径 —— 调用方照旧走 `skip` 并说明原因，**不假装通过**。
import 'dart:io';

/// 官方 Office 模板样本根目录（不含 `doc/`、`slides/` 等子目录）。
Directory officeTemplateRoot() {
  final env = Platform.environment['OFFICE_NATIVE_SAMPLES'];
  final home = Platform.environment['HOME'] ?? '';
  final candidates = <String>[
    if (env != null && env.isNotEmpty) env,
    '/tmp/spk/export_Office/template',
    if (home.isNotEmpty) '$home/synology_samples/office-templates',
  ];
  for (final c in candidates) {
    if (Directory(c).existsSync()) return Directory(c);
  }
  return Directory(candidates.first);
}

/// 样本是否可用；不可用时给出**明确原因**（调用方据此 skip，而不是静默跳过）。
String? officeTemplateSkipReason(Directory root) => root.existsSync()
    ? null
    : '官方 Office 模板样本缺失：${root.path}（请跑 scripts/restore_office_samples.sh，'
          '或设置 OFFICE_NATIVE_SAMPLES）';
