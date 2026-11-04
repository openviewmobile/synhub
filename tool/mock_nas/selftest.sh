#!/usr/bin/env bash
# 本地 Mock NAS 自测脚本 —— 在宿主上把"能力表切换 / 119 注入 / 206 vs 200"
# 全部跑一遍，打印**原始** curl 输出，并给出 PASS/FAIL 汇总。
#
# 用法：
#   bash tool/mock_nas/selftest.sh
#   DART=/path/to/dart bash tool/mock_nas/selftest.sh
#
# 不碰设备、不联网、不需要 NAS 凭据。
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SERVER="$ROOT/tool/mock_nas/mock_nas_server.dart"

# 优先用 PATH 里的 dart；找不到就回落到本机 Flutter SDK 里的 dart。
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

BASE_PORT="${BASE_PORT:-18088}"
PIDS=()
TMP="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

start() { # start <port> [args...]
  local port="$1"; shift
  # 用 `dart <file>` 而不是 `dart run`：脚本会起多个实例，`dart run` 的
  # native-assets 打包步骤并发时会互相踩（codesign dylib 报错）。
  "$DART" "$SERVER" --port="$port" "$@" >"$TMP/$port.log" 2>&1 &
  PIDS+=("$!")
}

wait_up() { # wait_up <port>
  for _ in $(seq 1 60); do
    if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$1/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=all"; then
      return 0
    fi
    sleep 0.25
  done
  echo "!! 端口 $1 上的 mock 没起来；日志：" >&2
  cat "$TMP/$1.log" >&2
  return 1
}

check() { # check <desc> <needle> <haystack>
  if printf '%s' "$3" | grep -q -- "$2"; then
    echo "PASS: $1"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $1（期望包含：$2）"
    FAIL=$((FAIL + 1))
  fi
}

echo "==================================================================="
echo "Mock NAS 自测 —— dart=$DART"
echo "==================================================================="

# ---------------------------------------------------------------- 1) 能力表可切换
start "$BASE_PORT" --apis=file
wait_up "$BASE_PORT" || exit 1
echo
echo "### 1a. --apis=file 的能力表（只应声明 FileStation）"
TABLE_FILE="$(curl -s "http://127.0.0.1:$BASE_PORT/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=all")"
printf '%s\n' "$TABLE_FILE" | python3 -m json.tool
check "能力表含 SYNO.FileStation.List"     "SYNO.FileStation.List" "$TABLE_FILE"
check "能力表含 SYNO.FileStation.Download" "SYNO.FileStation.Download" "$TABLE_FILE"
if printf '%s' "$TABLE_FILE" | grep -q "SYNO.Foto.Browse.Item"; then
  echo "FAIL: --apis=file 不应声明 SYNO.Foto.Browse.Item"; FAIL=$((FAIL + 1))
else
  echo "PASS: --apis=file 不含 SYNO.Foto.Browse.Item"; PASS=$((PASS + 1))
fi

echo
echo "### 1b. 未声明的 API → 102（与真实 DSM 一致）"
UNKNOWN="$(curl -s "http://127.0.0.1:$BASE_PORT/webapi/entry.cgi?api=SYNO.Foto.Browse.Item&version=1&method=list&_sid=MOCK-SID-1")"
printf '%s\n' "$UNKNOWN"
check "未声明 API 回 102" '"code":102' "$UNKNOWN"

echo
echo "### 1c. 登录（假 sid）"
LOGIN="$(curl -s "http://127.0.0.1:$BASE_PORT/webapi/auth.cgi?api=SYNO.API.Auth&version=7&method=login&session=Chat")"
printf '%s\n' "$LOGIN"
SID="$(printf '%s' "$LOGIN" | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["sid"])')"
check "登录回 MOCK-SID-*（明显假值）" 'MOCK-SID-' "$LOGIN"

# ---------------------------------------------------------------- 2) Range 206 vs 200
echo
echo "### 2a. Range 默认：Range: bytes=0-63 → 应 206 + Content-Range"
H206="$(curl -s -D - -o "$TMP/r206.bin" -H 'Range: bytes=0-63' \
  "http://127.0.0.1:$BASE_PORT/webapi/entry.cgi?api=SYNO.FileStation.Download&method=download&path=%5B%22%2Fhome%2FBooks%2Fmock-clip.mp4%22%5D&_sid=$SID")"
printf '%s\n' "$H206"
echo "收到字节：$(wc -c < "$TMP/r206.bin" | tr -d ' ')"
check "206 Partial Content"        '206 Partial Content' "$H206"
check "Content-Range: bytes 0-63"  'content-range: bytes 0-63/' "$H206"

# 直接改端口重起一个 --range=off 的实例
start "$((BASE_PORT + 1))" --apis=file --range=off
wait_up "$((BASE_PORT + 1))" || exit 1
echo
echo "### 2b. --range=off 对照：同一个 Range 头 → 应 200（无 Content-Range）"
H200="$(curl -s -D - -o /dev/null -H 'Range: bytes=0-63' \
  "http://127.0.0.1:$((BASE_PORT + 1))/webapi/entry.cgi?api=SYNO.FileStation.Download&method=download&_sid=$SID")"
printf '%s\n' "$H200"
check "range=off 回 200"                 '200 OK' "$H200"
if printf '%s' "$H200" | grep -qi 'content-range'; then
  echo "FAIL: range=off 不应有 Content-Range"; FAIL=$((FAIL + 1))
else
  echo "PASS: range=off 无 Content-Range"; PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------- 3) 故障注入
start "$((BASE_PORT + 2))" --apis=file --download-error=119
wait_up "$((BASE_PORT + 2))" || exit 1
echo
echo "### 3a. --download-error=119：Download 一律 119"
E119="$(curl -s -D - "http://127.0.0.1:$((BASE_PORT + 2))/webapi/entry.cgi?api=SYNO.FileStation.Download&method=download&_sid=$SID")"
printf '%s\n' "$E119"
check "Download 回 119" '"code":119' "$E119"

start "$((BASE_PORT + 3))" --apis=file --list-error=105
wait_up "$((BASE_PORT + 3))" || exit 1
echo
echo "### 3b. --list-error=105：List 一律 105（无权限）"
E105="$(curl -s -D - "http://127.0.0.1:$((BASE_PORT + 3))/webapi/entry.cgi?api=SYNO.FileStation.List&method=list&_sid=$SID")"
printf '%s\n' "$E105"
check "List 回 105" '"code":105' "$E105"

start "$((BASE_PORT + 4))" --api-info-empty
wait_up "$((BASE_PORT + 4))" || exit 1
echo
echo "### 3c. --api-info-empty：无**任何套件服务**（核心 API 仍在，否则登不进去）"
EMPTY="$(curl -s "http://127.0.0.1:$((BASE_PORT + 4))/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=all")"
printf '%s\n' "$EMPTY"
check "核心 SYNO.API.Info 仍在"      'SYNO.API.Info' "$EMPTY"
check "核心 SYNO.API.Encryption 仍在" 'SYNO.API.Encryption' "$EMPTY"
check "核心 SYNO.API.Auth 仍在"      'SYNO.API.Auth' "$EMPTY"
if printf '%s' "$EMPTY" | grep -q 'FileStation'; then
  echo "FAIL: api-info-empty 不应有 FileStation"; FAIL=$((FAIL + 1))
else
  echo "PASS: api-info-empty 无 FileStation"; PASS=$((PASS + 1))
fi

start "$((BASE_PORT + 6))" --literal-api-info-empty
wait_up "$((BASE_PORT + 6))" || exit 1
echo
echo "### 3d. --literal-api-info-empty：字面只剩 SYNO.API.Info（观测用，App 登不进）"
LIT="$(curl -s "http://127.0.0.1:$((BASE_PORT + 6))/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=all")"
printf '%s\n' "$LIT"
check "字面模式只剩 SYNO.API.Info" '"SYNO.API.Info"' "$LIT"
if printf '%s' "$LIT" | grep -q 'Encryption'; then
  echo "FAIL: literal 模式不应有 Encryption"; FAIL=$((FAIL + 1))
else
  echo "PASS: literal 模式无 Encryption"; PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------- 4) 播到一半会话失效
start "$((BASE_PORT + 5))" --apis=file --download-truncate-after=4096 --download-bytes=1048576
wait_up "$((BASE_PORT + 5))" || exit 1
P5="$((BASE_PORT + 5))"
echo
echo "### 4a. --download-truncate-after=4096：首次只发 4096 字节（声明整长，curl exit 18）"
TR1="$(curl -s --max-time 10 -D - -o "$TMP/tr1.bin" -H 'Range: bytes=0-' \
  "http://127.0.0.1:$P5/webapi/entry.cgi?api=SYNO.FileStation.Download&method=download&_sid=$SID&SynoToken=MOCK-TOKEN-1")"
TR1_EXIT=$?
printf '%s\n' "$TR1"
echo "curl_exit=$TR1_EXIT  收到字节=$(wc -c < "$TMP/tr1.bin" | tr -d ' ')"
check "首次声明完整长度（content-length: 1048576）" 'content-length: 1048576' "$TR1"
check "首次只发 4096 字节" '4096' "$(wc -c < "$TMP/tr1.bin" | tr -d ' ')"
check "提前 EOF（curl exit 18）" '18' "$TR1_EXIT"

echo
echo "### 4b. 同一 sid 的下一次请求 → 119（= 播到一半会话失效）"
TR2="$(curl -s -D - "http://127.0.0.1:$P5/webapi/entry.cgi?api=SYNO.FileStation.Download&method=download&_sid=$SID")"
printf '%s\n' "$TR2"
check "重试命中 119" '"code":119' "$TR2"

echo
echo "### 4c. 该 sid 的**其它**请求也 119"
TR3="$(curl -s "http://127.0.0.1:$P5/webapi/entry.cgi?api=SYNO.FileStation.List&method=list&_sid=$SID")"
printf '%s\n' "$TR3"
check "List 也 119" '"code":119' "$TR3"

echo
echo "### 4d. 重新登录拿到**新的** sid，会话可恢复"
RELOGIN="$(curl -s "http://127.0.0.1:$P5/webapi/auth.cgi?api=SYNO.API.Auth&version=7&method=login&session=Chat")"
printf '%s\n' "$RELOGIN"
NEWSID="$(printf '%s' "$RELOGIN" | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["sid"])')"
echo "新 sid=${NEWSID}（旧 sid=${SID}）"
if [ "$NEWSID" != "$SID" ]; then
  echo "PASS: 重登发的 sid 与已失效 sid 不同"; PASS=$((PASS + 1))
else
  echo "FAIL: 重登又发了已失效的 sid"; FAIL=$((FAIL + 1))
fi
RECOVER="$(curl -s -D - -o /dev/null -H 'Range: bytes=0-31' \
  "http://127.0.0.1:$P5/webapi/entry.cgi?api=SYNO.FileStation.Download&method=download&_sid=$NEWSID")"
printf '%s\n' "$RECOVER"
check "新 sid 可正常取流（206）" '206 Partial Content' "$RECOVER"

# ---------------------------------------------------------------- 5) 真实客户端协议兼容
echo
echo "### 5a. 用本项目真实 DSM 客户端代码打 mock（登录 RSA / 能力表 / 119 解析）"
PROBE_A="$("$DART" "$ROOT/tool/mock_nas/probe_client.dart" --url="http://127.0.0.1:$BASE_PORT" 2>&1)"
printf '%s\n' "$PROBE_A"
check "真实客户端 login OK"                  'login OK' "$PROBE_A"
check "真实客户端 List 读到 mock-clip.mp4"   'mock-clip.mp4' "$PROBE_A"
check "下载直链含 _sid 与 SynoToken"         'has _sid=true has SynoToken=true' "$PROBE_A"

echo
echo "### 5b. 截断实例：真实客户端同 sid 的后续调用拿到 119"
PROBE_B="$("$DART" "$ROOT/tool/mock_nas/probe_client.dart" --url="http://127.0.0.1:$P5" 2>&1)"
printf '%s\n' "$PROBE_B"
check "真实客户端落到 sessionExpired（code=119）" 'code=119' "$PROBE_B"

# ---------------------------------------------------------------- 汇总
echo
echo "==================================================================="
echo "汇总：PASS=$PASS FAIL=$FAIL"
echo "（mock 日志在 ${TMP}，退出时已清理；需要保留请跑 --verbose 手动起）"
echo "==================================================================="
[ "$FAIL" -eq 0 ]
