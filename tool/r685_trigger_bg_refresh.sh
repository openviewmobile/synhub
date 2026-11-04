#!/usr/bin/env bash
# r685：在 iOS 模拟器上强制唤起一次后台刷新 handler
#
# 为什么需要它：模拟器上 `BGTaskScheduler.submit` 会被系统拒
# （`BGTaskSchedulerErrorDomain:1`），`_simulateLaunchForTaskWithIdentifier:`
# 又因为没有排队请求而被拒（"No task request … has been scheduled"，原始日志在
# `docs/platform-ios.md` §22.3）。唯一能让 **我们的** handler 真跑一遍的办法，
# 是用 LLDB 调 `[[BackgroundBridge shared] handleRefreshLaunch:<taskId>]`。
#
# 用法：
#   tool/r685_trigger_bg_refresh.sh                       # 打当前 booted 设备
#   tool/r685_trigger_bg_refresh.sh <device-udid> [taskId]
#
# 注意：`BackgroundBridge` 是 Swift 类，必须带 `@objc`（本仓 r685 加过）
# 才能用 ObjC 表达式调到 —— 否则 LLDB 只会静默返回 nil。
set -euo pipefail

DEVICE="${1:-booted}"
TASK_ID="${2:-com.openviewai.synhub.refresh}"

PID="$(ps -Ao pid,command | grep "Runner.app/Runner" | grep -v grep | awk '{print $1}' | head -1)"
if [[ -z "${PID}" ]]; then
  echo "✗ 没找到 Runner 进程（先装并启动 App）" >&2
  exit 1
fi
echo "→ device=${DEVICE} pid=${PID} task=${TASK_ID}"

xcrun lldb -p "${PID}" \
  -o "expr -l objc++ -- (void)[(id)[NSClassFromString(@\"BackgroundBridge\") shared] handleRefreshLaunch:@\"${TASK_ID}\"]" \
  -o 'process detach' -o quit 2>&1 | tail -4

echo "→ 期望：设备日志出现 '[bg] 后台刷新被唤起 #N task=…'，"
echo "  并且 App 内 BackgroundService.refreshStats() 的 fired 加 1、收到 onBackgroundRefresh 事件"
