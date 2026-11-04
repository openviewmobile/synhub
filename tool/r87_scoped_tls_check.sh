#!/usr/bin/env bash
# r87-scoped：**离线**校验 macOS 原生媒体传输层的 scoped TLS 语义。
#
# 零外网、零真 NAS：本机回环起一个只认 `CN=r87.invalid` 自签证书的 HTTPS 服务，
# 再用 `tool/r87_tls_repro.swift`（与 App 内 `macos/Runner/MediaPlayerTransport.swift`
# 同一份源码）对四种组合逐条断言：
#
#   ① 默认 URLSession（平台原验证器）           → 证书不受信任，必须失败
#   ② 政策主机 = 请求主机，但**没有指纹**        → 自签链验不过、无钉扎 ⇒ 必须失败
#   ③ 政策主机 = 请求主机，带**正确指纹**        → 只钉住这一枚 ⇒ 必须成功
#   ④ 政策主机 = **另一台**（192.0.2.9）         → 请求未被放宽（默认处理）⇒ 必须失败
#
# 用法（在仓库根目录）：
#   bash tool/r87_scoped_tls_check.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/r87_scoped.XXXXXX)"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')

cleanup() {
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ① 自签证书（CN/SAN 都不是 127.0.0.1 ⇒ 触发"主机名不匹配"这条真实场景）
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=r87.invalid" -addext "subjectAltName=DNS:r87.invalid" >/dev/null 2>&1
FP=$(openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha256 \
  | sed 's/.*=//; s/://g' | tr 'a-f' 'A-F')
echo "r87-scoped: cert CN=r87.invalid sha256=$FP port=$PORT"

# ② 编 CLI（与 App 内传输层同一份 Swift 源码，不依赖 Flutter）
mkdir -p "$WORK/swift"
cp "$REPO/tool/r87_tls_repro.swift" "$WORK/swift/main.swift"
swiftc -target arm64-apple-macosx14.0 -sdk "$(xcrun --show-sdk-path)" -O \
  -o "$WORK/repro" \
  "$REPO/macos/Runner/MediaPlayerTransport.swift" "$WORK/swift/main.swift" \
  >/dev/null 2>&1

# ③ 起服务
python3 "$REPO/tool/r87_scoped_https_server.py" "$PORT" "$WORK/cert.pem" "$WORK/key.pem" &
SERVER_PID=$!
for _ in $(seq 1 50); do
  if curl -sk --max-time 1 "https://127.0.0.1:$PORT/x" >/dev/null 2>&1; then break; fi
  sleep 0.2
done

URL="https://127.0.0.1:$PORT/x"
pass=0; fail=0
check() { # name expected_substring output
  if grep -q "$2" <<<"$3"; then
    echo "  ✅ $1"; pass=$((pass+1))
  else
    echo "  ❌ $1（预期含 '$2'，实际：$3）"; fail=$((fail+1))
  fi
}

echo "① 默认原验证器："
OUT=$("$WORK/repro" "$URL" --host 127.0.0.1 2>/dev/null || true)
check "A_DEFAULT 必须失败（自签/主机名不匹配）" "A_DEFAULT: ERROR" "$OUT"

echo "② 政策主机精确匹配、但无指纹（自签链验不过）："
check "B_POLICY 必须失败（没有钉扎就不放行）" "B_POLICY: ERROR" "$OUT"

echo "③ 政策主机精确匹配 + 正确指纹："
OUT2=$("$WORK/repro" "$URL" --host 127.0.0.1 --fp "$FP" 2>/dev/null || true)
check "B_POLICY 必须成功（只钉这一枚）" "B_POLICY: HTTP 20" "$OUT2"
check "★ 反向：别的请求仍走原验证器（A_DEFAULT 失败）" "A_DEFAULT: ERROR" "$OUT2"

echo "④ 政策主机是另一台（192.0.2.9）："
OUT3=$("$WORK/repro" "$URL" --host 192.0.2.9 --fp "$FP" 2>&1 || true)
check "needsProxy 必须是 false（请求未被放宽）" "needsProxy=false" "$OUT3"
check "★ 反向：B_POLICY 也必须失败" "B_POLICY: ERROR" "$OUT3"

echo "r87-scoped: pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]]
