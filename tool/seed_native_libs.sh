#!/usr/bin/env bash
# 预置 flutter_gemma_litertlm 的原生库，绕开它 build hook 里那个**已经失效**的下载地址。
#
# 背景（第 728 轮实测）：
#   * `flutter test` / `flutter build` 都会触发 `flutter_gemma_litertlm` 的 build hook，
#     它要从 GitHub Releases 现下 `litertlm-<平台>.tar.gz`；
#   * hook 里把地址写死成 `DenisovAV/flutter_gemma` —— 那个仓库**已经改名**成
#     `DenisovAV/flutter_edge_ai`，旧路径现在返回 **HTTP 504**（不是 404，
#     所以看起来像"网络抖动"）。只有 API 资源端点还活着：
#       GET https://api.github.com/repos/DenisovAV/flutter_edge_ai/releases/assets/<id>
#       Accept: application/octet-stream
#   * hook 一旦拿不到就 `exit 255`，整步以 `Unhandled exception` 结束 ——
#     **没有 [E]、没有失败用例名**，这在 CI 日志里看起来像"失败数 +1 但判据一条没有"。
#
# 做法：按 hook 自己的缓存布局（`<cacheBase>/<dirName>/`，扁平层，主库 = libLiteRtLm）
# 先把库放好，并写它认的 JSON marker；marker 版本对得上时 hook 直接命中缓存、不联网。
#
# 用法：bash tool/seed_native_libs.sh [平台目录名]
#   默认按当前宿主推断；CI 上显式传 linux_x86_64 / macos_arm64 之类。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

# 版本与资源 id 来自 flutter_gemma_litertlm 1.8.6 的 hook（releaseTag = native-v0.17.1-a）。
VERSION='0.17.1-a'
OWNER='flutter_gemma_litertlm'
ASSET_REPO='DenisovAV/flutter_edge_ai'
MARKER_NAME='.flutter_gemma_native_version'

# ★ macOS 自带 bash 3.2：**没有关联数组**（`declare -A` 会静默失败，
#   随后 `[k]=v` 被当成算术下标 ⇒ `unbound variable`）。用 case，别用 map。
asset_id_for() {
  case "$1" in
    linux_x86_64) echo 592592466 ;;
    linux_arm64) echo 592592471 ;;
    android_arm64) echo 592592470 ;;
    macos_arm64) echo 592592556 ;;
    windows_x86_64) echo 592592582 ;;
    ios_arm64) echo 592592467 ;;
    ios_sim_arm64) echo 592592462 ;;
    *) echo 0 ;;
  esac
}

dir_name="${1:-}"
if [ -z "$dir_name" ]; then
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) dir_name=linux_x86_64 ;;
    Linux/aarch64|Linux/arm64) dir_name=linux_arm64 ;;
    Darwin/arm64) dir_name=macos_arm64 ;;
    *) echo "未知宿主：$(uname -s)/$(uname -m)，请显式给平台目录名"; exit 2 ;;
  esac
fi

# 缓存根：与 hook 的 `_cacheBaseDir()` 同一条规则（macOS 用 Library/Caches）。
# `SYNHUB_GEMMA_CACHE_BASE` 只给自测用，CI 不要设。
if [ -n "${SYNHUB_GEMMA_CACHE_BASE:-}" ]; then
  base="$SYNHUB_GEMMA_CACHE_BASE"
elif [ -n "${HOME:-}" ] && [ "$(uname -s)" = Darwin ]; then
  base="$HOME/Library/Caches/flutter_gemma/native"
elif [ -n "${LOCALAPPDATA:-}" ] && [ "$(uname -s)" != Darwin ]; then
  base="${LOCALAPPDATA}\\flutter_gemma\\native"
else
  base="${HOME:?HOME 未设置}/.cache/flutter_gemma/native"
fi

# 主库名按**目标平台**判（不是按宿主），否则交叉预置时判据会看错文件。
target="$base/$dir_name"
case "$dir_name" in
  macos_*) main_lib="$target/libLiteRtLm.dylib" ;;
  windows_*) main_lib="$target/LiteRtLm.dll" ;;
  *) main_lib="$target/libLiteRtLm.so" ;;
esac

if [ -f "$main_lib" ] && [ -f "$base/$MARKER_NAME" ]; then
  echo "✅ 已有缓存：$target"
  exit 0
fi

asset_id="$(asset_id_for "$dir_name")"
if [ -z "$asset_id" ] || [ "$asset_id" = 0 ]; then
  echo "⚠️ 没有登记 $dir_name 的资源 id —— 让 hook 自己去下（可能失败）。"
  echo "   补法：curl -sSL https://api.github.com/repos/$ASSET_REPO/releases/tags/native-v$VERSION"
  exit 0
fi

echo "→ 从 API 资源端点下载 ${dir_name}（hook 里那个 releases/download 地址已 504）"
mkdir -p "$target" || exit 2
tmp="${TMPDIR:-/tmp}/litertlm-$dir_name.$$.tar.gz"
if ! curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --max-time 900 \
      -H 'Accept: application/octet-stream' \
      "https://api.github.com/repos/$ASSET_REPO/releases/assets/$asset_id" \
      -o "$tmp"; then
  echo "❌ 下载失败（API 端点也拿不到）—— 这台机器的构建会缺原生库"
  rm -f "$tmp"
  exit 1
fi

if ! tar -xzf "$tmp" -C "$target"; then
  echo "❌ 解包失败：$tmp"
  rm -f "$tmp"
  exit 1
fi
rm -f "$tmp"

# marker 是 hook 的"提交点"：版本对不上它会把已放好的库**删掉**再重下。
printf '{"version":"%s","owner":"%s"}' "$VERSION" "$OWNER" > "$base/$MARKER_NAME" || exit 2

if [ ! -f "$main_lib" ]; then
  echo "❌ 解包后仍然找不到主库：$main_lib"
  ls -la "$target" | head -20
  exit 1
fi
echo "✅ 预置完成：${target}（$(ls -1 "$target" | wc -l | tr -d ' ') 个文件）"

# ─── sqlite3 ────────────────────────────────────────────────────────────────
# 同一个毛病：`sqlite3` 3.6.0 的 build hook 也从 `github.com/<repo>/releases/download`
# 取预编译库，那条路径现在回 504（本轮实测本机与 runner 都一样）；它比 litertlm 更糟：
# hook 会把 504 的响应体当成文件写进缓存，然后**哈希不匹配**报错，看起来像"上游换了包"。
# 实测上游文件没变（sha256 与 asset_hashes.dart 里的一致），只是取不下来。
# hook 会复用缓存里哈希正确的文件，所以按它自己的布局预置即可
# （`.dart_tool/hooks_runner/shared/sqlite3/build/download-<hash 前 8 位>/<库文件名>`）。
seed_sqlite3() {
  local dir_name="$1" asset dest_dir dest_name id proj hash8 target
  proj="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  case "$dir_name" in
    linux_x86_64)  asset='libsqlite3.x64.linux.so';      dest_name='libsqlite3.so';    id=561405050 ;;
    linux_arm64)   asset='libsqlite3.arm64.linux.so';    dest_name='libsqlite3.so';    id=561405029 ;;
    macos_arm64)   asset='libsqlite3.arm64.macos.dylib'; dest_name='libsqlite3.dylib'; id=561405030 ;;
    windows_x86_64) asset='sqlite3.x64.windows.dll';     dest_name='sqlite3.dll';      id=561405126 ;;
    android_arm64) asset='libsqlite3.arm64.android.so';  dest_name='libsqlite3.so';    id=561405024 ;;
    ios_arm64)     asset='libsqlite3.arm64.ios.dylib';   dest_name='libsqlite3.dylib'; id=561405023 ;;
    *) echo "（sqlite3：不处理 $dir_name）"; return 0 ;;
  esac

  # 哈希只在包自己那张表里（版本一变就变），所以从 pub cache 里读，不写死。
  local table
  table=$(ls -1 "$HOME"/.pub-cache/hosted/pub.dev/sqlite3-*/lib/src/hook/asset_hashes.dart 2>/dev/null | tail -1)
  if [ -z "$table" ]; then
    echo "⚠️ sqlite3：pub cache 里找不到 asset_hashes.dart（先跑 flutter pub get）—— 跳过"
    return 0
  fi
  local hash
  hash=$(grep -oE "'$asset': '[0-9a-f]{64}'" "$table" | head -1 | grep -oE '[0-9a-f]{64}')
  if [ -z "$hash" ]; then
    echo "⚠️ sqlite3：表里没有 $asset —— 跳过"
    return 0
  fi
  hash8="${hash:0:8}"
  dest_dir="$proj/.dart_tool/hooks_runner/shared/sqlite3/build/download-$hash8"
  target="$dest_dir/$dest_name"

  if [ -f "$target" ]; then
    local got
    got=$(shasum -a 256 "$target" 2>/dev/null | cut -d' ' -f1)
    [ -z "$got" ] && got=$(sha256sum "$target" 2>/dev/null | cut -d' ' -f1)
    if [ "$got" = "$hash" ]; then echo "✅ sqlite3 已有缓存：$target"; return 0; fi
    echo "（sqlite3 缓存哈希不对，重下）"
  fi

  mkdir -p "$dest_dir" || return 1
  local tmp="${TMPDIR:-/tmp}/sqlite3-$dir_name.$$.bin"
  echo "→ sqlite3：从 API 资源端点下载 $asset"
  if ! curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --max-time 600 \
        -H 'Accept: application/octet-stream' \
        "https://api.github.com/repos/simolus3/sqlite3.dart/releases/assets/$id" \
        -o "$tmp"; then
    echo "❌ sqlite3 下载失败"; rm -f "$tmp"; return 1
  fi
  local got
  got=$(shasum -a 256 "$tmp" 2>/dev/null | cut -d' ' -f1)
  [ -z "$got" ] && got=$(sha256sum "$tmp" 2>/dev/null | cut -d' ' -f1)
  if [ "$got" != "$hash" ]; then
    echo "❌ sqlite3 哈希不匹配：拿到 $got，期望 $hash"
    rm -f "$tmp"; return 1
  fi
  mv "$tmp" "$target" || return 1
  echo "✅ sqlite3 预置完成：$target"
}

seed_sqlite3 "$dir_name" || exit 1
