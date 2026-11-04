#!/usr/bin/env bash
# r693 · 容器里的"虚拟麦克风"装置（§C9 录音验证用）
#
# 容器**没有麦克风**，但 `record_linux` 走的是 PulseAudio 的 `parecord`。
# 所以给一个 **null sink + virtual source**：音调打进 null sink（样本直接丢弃、
# **不上声卡、不发声** —— 用户 2026-10-30 明确要求过不许出尖锐声音的测试），
# 虚拟输入源再把 null sink 的 monitor 当成"麦克风"。
#
# 用法：docker exec synhub-linux bash -lc 'bash /src/tool/linux_record_fixture.sh'
#      然后 `pactl list short sources` 里应能看到 `virtmic`。
set -euo pipefail

export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/xdg-runtime}
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# 系统模式跑 pa 时，客户端要在 pulse-access 组里（root 也要）
if ! id -nG | tr ' ' '\n' | grep -qx pulse-access; then
  usermod -aG pulse,pulse-access root || true
  echo '[fixture] root 已加入 pulse/pulse-access（若仍 Access denied，重开一次 exec）'
fi

if ! pactl info >/dev/null 2>&1; then
  echo '[fixture] 启动 pulseaudio（system 模式）'
  pulseaudio --system --disallow-exit --disallow-module-loading=0 -D \
    --log-target=file:/tmp/pulse.log >/dev/null 2>&1 || true
  sleep 2
fi

pactl info >/dev/null || {
  echo '[fixture] pulseaudio 起不来；看 /tmp/pulse.log' >&2
  exit 1
}

pactl list short sinks | grep -q nullsink || {
  pactl load-module module-null-sink sink_name=nullsink >/dev/null
  echo '[fixture] 已建 nullsink（样本丢弃，不发声）'
}
pactl list short sources | grep -q virtmic || {
  pactl load-module module-virtual-source source_name=virtmic master=nullsink.monitor >/dev/null
  echo '[fixture] 已建 virtmic（master=nullsink.monitor）'
}

pactl list short sources
