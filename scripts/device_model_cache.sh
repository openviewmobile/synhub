#!/usr/bin/env bash
# 端侧模型的"离线缓存"——宿主机侧备份/恢复。
#
# 用户 2026-09-25 要求：
#   「手机上的端侧模型非常大，也不要反复下载，非常浪费流量，比如你经常为了测试
#   卸载 App，然后重新安装，安装完了如果需要测试端侧模型又得重新下载模型，
#   这样太浪费流量了」
#
# 两层设计（见 `lib/src/features/ai/model_vault.dart`）：
#   ① **App 内保管库** `/data/data/<包名>/files/models_vault/`
#      —— 工作缓存：App 里删掉模型、覆盖安装新构建都不影响它，`install()` 直接
#      `fromFile` 原地装载，零网络。
#   ② **收件箱** `/storage/emulated/0/Android/media/<包名>/models/`
#      —— 宿主机把模型 push 到这里，App 打开模型页时搬进保管库。
#
# ⚠️ **实测（LGE-AN10 / Android 12）**：卸载 App 后 `Android/media/<包名>/`
#    也会一起消失（第 251 轮实测），所以"重装后模型还在"**只能靠本脚本**
#    （宿主机 `~/synology_samples/device-models/`）。
#
# 用法：
#   scripts/device_model_cache.sh status          看设备三处 + 宿主机备份各有什么
#   scripts/device_model_cache.sh backup          设备 → 宿主机样例库（卸载 App 前跑）
#   scripts/device_model_cache.sh restore         宿主机 → 设备收件箱（重装后跑）
#   scripts/device_model_cache.sh pull-internal   把插件内部目录里的历史模型搬进保管库
#   scripts/device_model_cache.sh verify          核对宿主机备份的大小与 sha256（通过就别重下）
#
# ★ 跑任何会**卸载** App 的测试（`flutter test integration_test/...`）之前：
#     scripts/device_model_cache.sh backup
#   重装完：
#     scripts/device_model_cache.sh restore   # 然后打开 App 模型页，它会自动入库
set -uo pipefail

PKG="${PKG:-com.openviewai.synhub}"
SERIAL_ARG="${SERIAL:+-s $SERIAL}"
ADB="adb $SERIAL_ARG"
VAULT="/data/data/$PKG/files/models_vault"
INBOX="/storage/emulated/0/Android/media/$PKG/models"
PLUGIN="/data/data/$PKG/files/flutter_gemma"
STORE="${SYNOLOGY_SAMPLES:-$HOME/synology_samples}/device-models"
CMD="${1:-status}"
MODEL_GLOB='*.litertlm|*.task|*.bin|*.gguf|*.tflite|*.onnx'

die() {
  echo "错误：$*" >&2
  exit 1
}

have_device() {
  $ADB get-state >/dev/null 2>&1 || die "没有可用的设备（adb devices 看看）"
}

bytes_of() {
  local b="$1"
  if [ "$b" -ge 1073741824 ]; then
    echo "$(echo "scale=1; $b/1073741824" | bc) GB"
  else
    echo "$((b / 1048576)) MB"
  fi
}

# 列出某个设备目录里的普通文件名（一行一个）
names_in() {
  $ADB shell "ls -l $1 2>/dev/null" | tr -d '\r' |
    awk '/^-/ {print $NF}' | grep -vE '^\*$' || true
}

entries_of() { # 带大小的 ls 行
  $ADB shell "ls -l $1 2>/dev/null" | tr -d '\r' | awk '/^-/' || true
}

show_dir() { # 标题 目录
  echo "── $1 $2 ──"
  local e
  e=$(entries_of "$2")
  if [ -z "$e" ]; then echo "  （空）"; else printf '%s\n' "$e"; fi
  echo
}

cmd_status() {
  have_device
  echo "设备：$($ADB get-serialno)"
  echo
  show_dir "① 保管库（App 工作缓存）" "$VAULT"
  show_dir "② 收件箱（宿主机 push 的目标）" "$INBOX"
  show_dir "③ 插件内部目录（历史遗留）" "$PLUGIN"
  echo "── 宿主机备份 $STORE ──"
  if [ -d "$STORE" ] && [ -n "$(ls -A "$STORE" 2>/dev/null)" ]; then
    ls -lh "$STORE" | awk 'NR>1 {printf "  %-9s %s\n", $5, $9}'
    echo "  合计：$(du -sh "$STORE" | cut -f1)"
  else
    echo "  （还没备份过）"
  fi
}

pull_from() { # 标签 设备目录 → 宿主机（已存在且同大小则跳过）
  local label="$1" dir="$2" n=0 name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in *'*'*|.|..) continue ;; esac
    local casehit=0
    case "$name" in $MODEL_GLOB) casehit=1 ;; esac
    [ "$casehit" = 1 ] || continue
    if [ -f "$STORE/$name" ]; then
      local dsz hsz
      dsz=$($ADB shell "stat -c %s '$dir/$name' 2>/dev/null" | tr -d '\r')
      hsz=$(stat -f%z "$STORE/$name")
      if [ -n "$dsz" ] && [ "$dsz" = "$hsz" ]; then
        echo "  = 已有同大小，跳过 $name"
        continue
      fi
    fi
    if $ADB pull "$dir/$name" "$STORE/$name" >/dev/null 2>&1; then
      echo "  ✅ 备份 $name ($(bytes_of "$(stat -f%z "$STORE/$name")"))  ← $label"
      n=$((n + 1))
    fi
  done <<<"$(names_in "$dir")"
  echo "$n"
}

cmd_backup() {
  have_device
  mkdir -p "$STORE"
  local total=0 got
  # ① 保管库最要紧（这才是 App 真正在用的那份）
  got=$(pull_from "保管库" "$VAULT" | tail -1)
  total=$((total + got))
  # ② 收件箱（宿主机上次 push 但 App 还没搬走的）
  got=$(pull_from "收件箱" "$INBOX" | tail -1)
  total=$((total + got))
  # ③ 插件内部目录（本功能上线前下的模型只会在这里）
  got=$(pull_from "插件目录" "$PLUGIN" | tail -1)
  total=$((total + got))

  if [ "$total" = 0 ]; then
    echo "设备上没有新的模型文件可备份。"
  else
    echo "共备份/更新 $total 个文件 → $STORE"
  fi
  : >"$STORE/INDEX.txt"
  local f
  for f in "$STORE"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in INDEX.txt|SHA256SUMS) continue ;; esac
    printf '%s  %-8s %s\n' "$(shasum -a 256 "$f" | cut -c1-16)" \
      "$(bytes_of "$(stat -f%z "$f")")" "$(basename "$f")" >>"$STORE/INDEX.txt"
  done
  echo "清单：$STORE/INDEX.txt"
}

cmd_restore() {
  have_device
  [ -d "$STORE" ] || die "宿主机还没有备份：$STORE（先跑 backup）"
  $ADB shell "mkdir -p $INBOX" >/dev/null 2>&1
  local n=0 f name
  for f in "$STORE"/*; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    # 清单/校验和文件不是模型，不要推到手机上占地方
    case "$name" in INDEX.txt|SHA256SUMS|*.txt|*.json|*.md) continue ;; esac
    if $ADB push "$f" "$INBOX/$name" >/dev/null 2>&1; then
      # 收件箱是共享目录：给 644，App 才读得到（push 进来的属主可能是 shell/root）
      $ADB shell "chmod 644 '$INBOX/$name'" >/dev/null 2>&1
      echo "  ✅ 放进收件箱 $name ($(bytes_of "$(stat -f%z "$f")"))"
      n=$((n + 1))
    else
      echo "  ❌ 放回失败：$name"
    fi
  done
  [ "$n" -gt 0 ] || die "备份目录里没有可恢复的文件"
  echo "共放回 $n 个文件 → $INBOX"
  echo "接着打开 App 的端侧模型页：它会把模型搬进保管库，卡片上显示"
  echo "「已存离线缓存 · 复用免下载」，点安装即可（零下载）。"
}

# 逐个核对宿主机备份里的模型：大小 + sha256。
# 作用：以后"要重下吗"这个问题**不用猜** —— 校验通过就别再下（省流量），
# 校验不过才说明文件坏了/被截断，那时才值得重下。
cmd_verify() {
  [ -d "$STORE" ] || die "没有备份目录：$STORE"
  local n=0 bad=0 f name dsz
  for f in "$STORE"/*; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    case "$name" in INDEX.txt|SHA256SUMS|*.txt|*.json|*.md) continue ;; esac
    n=$((n + 1))
    dsz=$(stat -f%z "$f")
    local expected
    expected=$(grep -E "[[:space:]]${name}\$" "$STORE/SHA256SUMS" 2>/dev/null | awk '{print $1}')
    local actual
    actual=$(shasum -a 256 "$f" | awk '{print $1}')
    if [ -z "$expected" ]; then
      echo "  ⚠️  $name ($(bytes_of "$dsz")) —— SHA256SUMS 里没有它的哈希，无法核对"
      bad=$((bad + 1))
      continue
    fi
    if [ "$expected" = "$actual" ]; then
      echo "  ✅ $name ($(bytes_of "$dsz")) sha256=${actual:0:16}"
    else
      echo "  ❌ $name ($(bytes_of "$dsz")) 哈希不符：期望 ${expected:0:16} / 实际 ${actual:0:16}"
      bad=$((bad + 1))
    fi
  done
  if [ "$n" = 0 ]; then
    die "备份目录里一个模型都没有 —— 没什么可校验的（这个状态**不算**通过）"
  fi
  echo "共核对 $n 个文件，$bad 个有问题"
  [ "$bad" = 0 ] || exit 1
}

cmd_pull_internal() {
  have_device
  $ADB shell "mkdir -p $VAULT" >/dev/null 2>&1
  local n=0 name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in *'*'*|.|..) continue ;; esac
    local casehit=0
    case "$name" in $MODEL_GLOB) casehit=1 ;; esac
    [ "$casehit" = 1 ] || continue
    if $ADB shell "cp '$PLUGIN/$name' '$VAULT/$name'" >/dev/null 2>&1; then
      echo "  ✅ 搬入保管库 $name"
      n=$((n + 1))
    fi
  done <<<"$(names_in "$PLUGIN")"
  if [ "$n" -gt 0 ]; then
    # 保管库在 App 私有目录里：属主要还给 App，否则 App 读不了
    local uid
    uid=$($ADB shell "dumpsys package $PKG | grep -oE 'userId=[0-9]+' | head -1" | tr -d '\r' | cut -d= -f2)
    if [ -n "$uid" ]; then
      $ADB shell "chown -R $uid:$uid '$VAULT'" >/dev/null 2>&1
      $ADB shell "restorecon -R '$VAULT'" >/dev/null 2>&1
    fi
    echo "共搬入 $n 个文件"
  else
    echo "插件目录里没有模型文件"
  fi
}

case "$CMD" in
status) cmd_status ;;
verify) cmd_verify ;;
backup) cmd_backup ;;
restore) cmd_restore ;;
pull-internal) cmd_pull_internal ;;
*)
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
  ;;
esac
