#!/usr/bin/env bash
# 一条命令起 Mock NAS 并**等它就绪**（供人工/CI/后续批次复用）。
#
#   bash tool/mock_nas/run_mock_nas.sh                       # 默认 :8788，声明 file
#   bash tool/mock_nas/run_mock_nas.sh --port=8788 --apis=all
#   bash tool/mock_nas/run_mock_nas.sh --apis=file,note,download,photo
#
# 行为：
#   ① 选 dart（PATH → 本机 Flutter SDK）；
#   ② 后台起 `mock_nas_server.dart`（参数原样透传）；
#   ③ 轮询 `SYNO.API.Info` 直到就绪（默认最多 30s），**就绪前不会误判**；
#   ④ 打印 READY 行与 PID，然后阻塞等待 —— Ctrl-C 即收工。
#
# 退出码：0 = 曾就绪并被 Ctrl-C 结束；1 = 超时未就绪；2 = 找不到 dart。
#
# 本机、离线：只监听 127.0.0.1/0.0.0.0 的 mock，**不连任何真实 NAS**。
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SERVER="$ROOT/tool/mock_nas/mock_nas_server.dart"

DART="${DART:-}"
if [ -z "$DART" ]; then
  if command -v dart >/dev/null 2>&1; then
    DART="$(command -v dart)"
  elif [ -x "$HOME/Documents/flutter/bin/dart" ]; then
    DART="$HOME/Documents/flutter/bin/dart"
  else
    echo "找不到 dart。请设 DART=/path/to/dart 或把 dart 加进 PATH。" >&2
    exit 2
  fi
fi

PORT=8788
HOST=0.0.0.0
for arg in "$@"; do
  case "$arg" in
    --port=*) PORT="${arg#--port=}" ;;
    --host=*) HOST="${arg#--host=}" ;;
  esac
done

READY_TIMEOUT="${MOCK_READY_TIMEOUT:-30}"
LOG="$(mktemp -t mock_nas.XXXXXX.log)"

"$DART" "$SERVER" "$@" >"$LOG" 2>&1 &
PID=$!

cleanup() {
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
}
trap 'cleanup; echo "[run] 已停止 mock（PID=${PID}）"; echo "[run] 启动日志：$LOG"; exit 0' INT TERM

echo "[run] 启动：${DART} ${SERVER} $*"
echo "[run] 等待就绪：http://127.0.0.1:$PORT/webapi/query.cgi"

ready=0
for _ in $(seq 1 $((READY_TIMEOUT * 4))); do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "[run] mock 进程提前退出；日志：" >&2
    cat "$LOG" >&2
    exit 1
  fi
  if curl -s -o /dev/null --max-time 1 \
      "http://127.0.0.1:$PORT/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=all"; then
    ready=1
    break
  fi
  sleep 0.25
done

if [ "$ready" -ne 1 ]; then
  echo "[run] ${READY_TIMEOUT}s 内未就绪；日志：" >&2
  cat "$LOG" >&2
  cleanup
  exit 1
fi

API_COUNT="$(curl -s "http://127.0.0.1:$PORT/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=all" \
  | python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("data",{})))' 2>/dev/null || echo '?')"
echo "[run] READY  http://127.0.0.1:${PORT}（声明 ${API_COUNT} 个 API）"
echo "[run] PID=$PID  启动日志=$LOG"
echo "[run] 停止：Ctrl-C 或 kill $PID"

wait "$PID"
