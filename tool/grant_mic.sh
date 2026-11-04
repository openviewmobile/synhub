#!/usr/bin/env bash
# 真机跑语音验收前/中授麦克风权限。
#
# 这台 HarmonyOS 机器上每次 `flutter test integration_test` 重装 APK 都会把
# 运行时权限**重置**，于是 App 会弹系统权限框，测试就卡在 hasPermission()。
# 所以：一边跑测试，一边在后台跑这个脚本反复 grant（grant 会把弹框顶掉）。
#
#   ./tool/grant_mic.sh <deviceId> [次数]
set -u
DEV="${1:-AXGE022428000622}"
N="${2:-20}"
for _ in $(seq 1 "$N"); do
  adb -s "$DEV" shell pm grant com.openviewai.synhub \
    android.permission.RECORD_AUDIO >/dev/null 2>&1
  sleep 3
done
