#!/usr/bin/env bash
# ★★ 第 42 轮：**真机全功能验收** —— 把 integration_test/ 下的端到端用例逐个跑一遍。
#
# 为什么不用 `flutter test integration_test/...`：
#   那条命令会**卸载 App 并清空它的数据**（AGENTS §2.0.1；UID 会变、会话/模型全丢）。
#   本脚本一律用 `flutter drive --keep-app-running`：跑完**不卸载**，数据保留。
#
# ⚠️ 但 `--target=integration_test/...` 会把设备上的 App 换成**测试入口**，
#    跑完必须装回正常包（脚本最后一步自动做）。否则下次打开 App 会永远停在 splash。
#
# 用法：
#   tool/device_feature_suite.sh [输出日志] [设备序列号]
#   真机耗时参考：每个目标约 60–120 s（含一次 debug 构建 + 安装）。
#
# §5.1：用例自身对 NAS 的写操作只发生在它们自己的临时目录里；本脚本不加
#       `SYNO_LIVE_POST`，即走"只读模式"（需要写操作的断言由用例自己跳过）。
set -u
cd "$(dirname "$0")/.." || exit 1
export PATH="<flutter-sdk>/bin:$PATH"

DEV="${2:-AXGE022428000622}"
OUT="${1:-/tmp/r42_device_suite.log}"
QC="${SYNO_NAS_QC:-demo_admin-qq}"
ACCOUNT="${SYNO_NAS_ACCOUNT:-demo_user}"
PASSWORD="${SYNO_NAS_PASSWORD:-}"

# ★★ 第 47 轮：**默认不清空日志**。原来这里无条件 `: > "$OUT"`，而下面的断点续跑
#   正是靠读这个日志 ⇒ 一清空就只能**全量重跑**（44 目标 ≈ 35 分钟，我因此白跑过一整轮）。
#   要重跑就显式 `DEVICE_SUITE_FRESH=1`。
if [ "${DEVICE_SUITE_FRESH:-0}" = "1" ]; then
  : > "$OUT"
  echo "★ DEVICE_SUITE_FRESH=1 ⇒ 已清空日志，从零开始跑"
elif [ -f "$OUT" ]; then
  echo "★ 续跑模式：复用 $OUT （**已 PASS 的目标会 SKIP**；要全量重跑用 DEVICE_SUITE_FRESH=1）"
else
  : > "$OUT"
fi
pass=0
fail=0
declare -a failed=()

targets=()
for f in integration_test/p0_*.dart integration_test/phase*.dart \
         integration_test/drive_*.dart integration_test/media_*.dart; do
  [ -f "$f" ] || continue
  case "$f" in
    *r41_video_thumb_probe*) continue ;; # 专用探针，不在功能矩阵里
  esac
  targets+=("$f")
done

echo "计划跑 ${#targets[@]} 个真机目标 → $OUT" | tee -a "$OUT"

# ★ 单目标看门狗：`flutter drive` 有可能**永远不返回**（第 42 轮实测：phase6_channel_create
#   卡了 35 分钟不动）。macOS **没有 `timeout`**（GNU coreutils），所以自己实现。
#   超时按 FAIL 记并继续下一个 —— 不许让一个目标拖死整轮验收。
SUITE_TIMEOUT="${DEVICE_SUITE_TIMEOUT:-420}"
drive_guarded() {
  local secs="$1"; shift
  "$@" >>"$OUT" 2>&1 &
  local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
  local wd=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  kill "$wd" 2>/dev/null
  wait "$wd" 2>/dev/null
  return $rc
}

for f in "${targets[@]}"; do
  # 断点续跑：日志里**已 PASS** 的目标跳过（★ 只认 PASS —— 失败目标必须重跑，
  # 否则"续跑"永远收敛不到全绿；第 47 轮修）。
  #   ★★★ 第 54 轮定稿（这一条踩过三次，别再改回去）：
  #   ① 原判据 `^RESULT PASS .* $f$` 的 `.* ` 要求 `$f` 前有空格 ⇒ **永远不匹配**（SKIP 从未生效）；
  #   ② 改成"存在任意 PASS 就跳过"后**制造了假绿**：`phase2`/`phase8` 是 PASS→FAIL 的历史
  #      （先过、后来因状态漂移变红），于是被误判"已通过"、整轮 44 条全 SKIP、
  #      `SUMMARY(本次运行) pass=0 fail=0` —— 看着像全绿，其实一条没跑。
  #   ③ 正解：**只认该目标的最后一条 RESULT** 是不是 PASS。
  #   （`.` 用 `\.` 转义，避免把文件名里的点当通配。）
  local last_line
  last_line="$(grep -E "^RESULT (PASS|FAIL)[[:space:]]+${f//./\\.}$" "$OUT" 2>/dev/null | tail -1)"
  if [ "$last_line" = "RESULT PASS $f" ]; then
    echo "SKIP(该目标最后一条 RESULT=PASS) $f" | tee -a "$OUT"
    continue
  fi
  echo "=== $(date '+%H:%M:%S') $f ===" | tee -a "$OUT"
  # ★★ 每个目标开跑前**先杀掉上一个目标留下的 App**：`--keep-app-running` 会把
  #   App 留在前台，下一个目标装测试入口包时抢 Flutter 引擎/调试端口 ⇒
  #   实测症状 "Error waiting for a debug connection: The log reader stopped
  #   unexpectedly / Application failed to start"（整个目标一条用例都没跑就 FAIL）。
  adb shell am force-stop com.openviewai.synhub 2>/dev/null || true
  # ★★ 预授权：`flutter drive` 装的是**测试入口包**，冷装/清数据后启动会弹
  #   系统 `GrantPermissionsActivity` —— 它挡在 Activity 前面，drive 永远等不到
  #   VM service（实测症状：install 完成后**再无任何输出**、7 分钟后被看门狗杀、
  #   前台是 `com.android.permissioncontroller/...GrantPermissionsActivity`）。
  for _pp in READ_EXTERNAL_STORAGE WRITE_EXTERNAL_STORAGE RECORD_AUDIO CAMERA \
             ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION POST_NOTIFICATIONS; do
    adb shell pm grant com.openviewai.synhub android.permission.$_pp 2>/dev/null || true
  done
  sleep 1
  adb logcat -c 2>/dev/null || true
  if drive_guarded "$SUITE_TIMEOUT" flutter drive --keep-app-running \
      --driver=test_driver/integration_test.dart \
      --target="$f" -d "$DEV" \
      --dart-define=SYNO_NAS_QC="$QC" \
      --dart-define=SYNO_NAS_ACCOUNT="$ACCOUNT" \
      --dart-define=SYNO_NAS_PASSWORD="$PASSWORD"; then
    echo "RESULT PASS $f" | tee -a "$OUT"
    pass=$((pass + 1))
  else
    echo "RESULT FAIL $f" | tee -a "$OUT"
    fail=$((fail + 1))
    failed+=("$f")
    adb shell am force-stop com.openviewai.synhub 2>/dev/null || true
  fi
done

echo "SUMMARY(本次运行) pass=$pass fail=$fail" | tee -a "$OUT"
# ★ 第 47 轮：续跑时"本次 SUMMARY"不等于总账 ⇒ 按日志里每个目标的**最后一条** RESULT 汇总。
#   （不用 `timeout`、不依赖 GNU 工具，awk 在 macOS 上就有。）
awk '/^RESULT (PASS|FAIL) /{ st[$3]=$2 }
     END { n=0; p=0; for (t in st) { n++; if (st[t]=="PASS") p++ }
           printf "TOTAL(跨轮累计) pass=%d fail=%d 共 %d 个目标\n", p, n-p, n }' "$OUT" | tee -a "$OUT"
if [ "${#failed[@]}" -gt 0 ]; then
  printf 'FAILED %s\n' "${failed[@]}" | tee -a "$OUT"
fi

# ★ 收尾：装回正常 debug 包（否则设备上留下的是测试入口）
echo "=== 收尾：装回正常 debug 包 ===" | tee -a "$OUT"
flutter build apk --debug --target-platform android-arm64 >>"$OUT" 2>&1 \
  && adb install -r build/app/outputs/flutter-apk/app-debug.apk >>"$OUT" 2>&1 \
  && echo "OK 已装回正常包" | tee -a "$OUT"
