#!/usr/bin/env bash
# ★★★ 从 **Synology 官方镜像** 抓官方安卓 App 的 APK。
#
# 为什么有这个脚本：第 74 轮我因为"试了一个被墙域名"就宣布拿不到
# DS finder 的 APK，被用户纠正。把这些事实固定成脚本，
# 以后**不用靠记忆**，直接调。
#
# 用法：
#   scripts/fetch_official_apk.sh DSfinder              # 列版本
#   scripts/fetch_official_apk.sh DSfinder 2.5.7-484    # 下载 .ww 到 /tmp
#   scripts/fetch_official_apk.sh --list-all            # 列出所有官方安卓 App
#
# 命名：Android-<App>.<版本>-<build>.<cn|ww>.apk
# 本脚本**只取 .ww**（与仓库已有样本一致）。
#
# 网络：镜像站在墙外，**必须走代理**。代理从系统 PAC 里动态读，
# 不写死端口（PAC 由本机客户端动态改）。
set -euo pipefail

MIRROR="https://archive.synology.com/download/Mobile"
DEST="${DEST:-/tmp}"

# ── 从 PAC 里读出真实代理（不写死 7897）────────────────────────────
resolve_proxy() {
  local pac
  pac=$(scutil --proxy 2>/dev/null | awk -F' : ' '/ProxyAutoConfigURLString/{print $2}' | tr -d ' ')
  [ -z "$pac" ] && return 1
  curl -sS --max-time 15 "$pac" 2>/dev/null \
    | grep -oE '(PROXY|SOCKS5) [0-9.]+:[0-9]+' \
    | awk '{print $2}' | sort -u | head -1
}

PROXY=$(resolve_proxy || true)
if [ -n "${PROXY:-}" ]; then
  export https_proxy="http://${PROXY}" http_proxy="http://${PROXY}"
  echo "[proxy] ${PROXY} (read from system PAC)"
else
  echo "[proxy] ⚠️ 没从 PAC 读到代理，直连试试（镜像站多半会失败）" >&2
fi

# ── 参数 ──────────────────────────────────────────────────────────
if [ $# -eq 0 ]; then
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [ "$1" = "--list-all" ]; then
  curl -sS --max-time 60 -L "$MIRROR" \
    | grep -oE 'Android-[A-Za-z0-9]+' | sort -u
  exit 0
fi

APP="$1"
VERSION="${2:-}"

if [ -z "$VERSION" ]; then
  echo "=== $APP 的官方版本（末尾 10 个）==="
  curl -sS --max-time 60 -L "$MIRROR/Android-$APP" \
    | grep -oE "Android-$APP/[0-9][0-9.]*-[0-9]+" \
    | sed "s|Android-$APP/||" | sort -uV | tail -10
  echo
  echo "下载：$0 $APP <版本>"
  exit 0
fi

PAGE="$MIRROR/Android-$APP/$VERSION"
echo "[page] $PAGE"
URL=$(curl -sS --max-time 60 -L "$PAGE" \
  | grep -oE 'https://global\.synologydownload\.com/[^"]*\.ww\.apk' | head -1)

if [ -z "$URL" ]; then
  echo "❌ 版本页里没找到 .ww 的 apk 直链。页面内容：$PAGE" >&2
  exit 1
fi

OUT="$DEST/$(basename "$URL")"
echo "[apk ] $URL"
echo "[out ] $OUT"
curl -sS --max-time 900 -L "$URL" -o "$OUT"

SIZE=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT")
echo "[done] $SIZE 字节"
file "$OUT"

# ── 顺手提示：直接搜身份字段 / API 清单 ────────────────────────────
cat <<'TIP'

── 拿到之后可以马上做这两件事（不用反编译）──
  # ① 有没有 is_admin / isAdmin
  unzip -p "$OUT" 'classes*.dex' | strings | grep -E '^is_admin$|^isAdmin$'

  # ② 该 App 用到的全部 SYNO API
  unzip -p "$OUT" 'classes*.dex' | strings | grep -E '^SYNO\.[A-Za-z0-9._]+$' | sort -u

  需要 smali（定位字段来自哪个 API）：
  java -jar $HOME/tools/apktool.jar d -r -f -o /tmp/${APP}-apktool "$OUT"
TIP
