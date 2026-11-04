#!/usr/bin/env bash
# 把样例库里的**官方 Office 模板样本**（Synology Office SPK 3.8.0-22711 的
# `template/`，含 53 份 text.json + 73 个 files/ 图片二进制）放回测试期望的路径。
#
# 为什么需要它：`test/office_*.dart` 默认读 `/tmp/spk/export_Office/template`，
# 而 `/tmp` 会被系统清理 ⇒ 不恢复就会出现大批 `PathNotFoundException`
# （第 251 轮之前长期有 134 条红）。样例库里的那份是**长期保存**的。
#
# 用法： scripts/restore_office_samples.sh
set -euo pipefail
LIB="${SYNOLOGY_SAMPLES:-$HOME/synology_samples}/office-templates"
DST="${OFFICE_NATIVE_SAMPLES:-/tmp/spk/export_Office/template}"
[ -d "$LIB" ] || { echo "缺样例：$LIB（见 samples/MANIFEST.md）" >&2; exit 1; }
mkdir -p "$(dirname "$DST")"
rm -rf "$DST"
cp -R "$LIB" "$DST"
echo "已恢复：${DST}（$(find "${DST}" -name text.json | wc -l | tr -d ' ') 份 text.json，共 $(find "${DST}" -type f | wc -l | tr -d ' ') 个文件）"
