#!/usr/bin/env bash
# ★ r458：仓库工程卫生 —— 清"可再生构建缓存"，**默认 dry-run**（只有 --yes 才真删）。
#
# 为什么需要它：`.dart_tool/flutter_build/<hash>/` 的 hash 由**构建配置**决定
# （target · `--dart-define` 集合 · flavor · build mode）；配置一变就是新目录，
# **Flutter 从不回收旧的**，只有 `flutter clean` 才整体清掉。
# 本仓 450+ 轮、每轮换 dart-define，一轮一个新 hash ⇒ 实测攒到 **429 个目录 / 38 G**
# （250 个 `app.dill`，单个 147–165 MB；复用率 ≈ 0）。2026-10-18 一轮清出 **~46 G**。
#
# 永远**不动**的两类：
#   ① `docs/evidence-*/`（真机证据；`android_a_closure_table_test` / `defect_closure_test`
#      等守卫会校验里面的路径**真实存在**，删了当场变红，像素也没法复核）；
#   ② 当前产物 `build/app/outputs/flutter-apk/app-release.apk`（要保住"设备上装的就是它"这条链）。
#
# 用法：
#   scripts/prune_flutter_caches.sh                 # 只看会删什么、能省多少
#   scripts/prune_flutter_caches.sh --days 14       # 只清 14 天前的 flutter_build 目录
#   scripts/prune_flutter_caches.sh --keep 3        # flutter_build 保留最近 3 个（默认 1）
#   scripts/prune_flutter_caches.sh --sites          # 连 macos/ios/web 站产物一起清
#   scripts/prune_flutter_caches.sh --yes            # 真删
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DAYS=0
KEEP=1
SITES=0
DO_IT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="${2:?--days 需要数字}"; shift 2 ;;
    --keep) KEEP="${2:?--keep 需要数字}"; shift 2 ;;
    --sites) SITES=1; shift ;;
    --yes|-y) DO_IT=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "❌ 未知参数：$1（用 --help）" >&2; exit 2 ;;
  esac
done

FB="$ROOT/.dart_tool/flutter_build"
human() { du -sh "$1" 2>/dev/null | cut -f1; }
mb_of() { du -sm "$1" 2>/dev/null | cut -f1; }

echo "==> 仓库：$ROOT"
echo "==> 现在：$(human "$ROOT")"

# ---------- ① flutter_build：按"最近使用"排序，保留 --keep 个 ----------
targets=()
if [ -d "$FB" ]; then
  # 目录 mtime 在"内容没变"时不会更新 ⇒ 用 app.dill 的 mtime 兜底，两者取较新
  sorted=()
  while IFS= read -r _d; do sorted+=("$_d"); done < <(
    for d in "$FB"/*/; do
      d="${d%/}"
      stamp=0
      for f in "$d/app.dill" "$d/build_hooks_result.json" "$d"; do
        [ -e "$f" ] || continue
        m=$(stat -f %m "$f" 2>/dev/null || echo 0)
        [ "$m" -gt "$stamp" ] && stamp="$m"
      done
      printf '%s\t%s\n' "$stamp" "$d"
    done | sort -rn | cut -f2-
  )
  i=0
  for d in "${sorted[@]}"; do
    i=$((i+1))
    [ "$i" -le "$KEEP" ] && { echo "    保留  $(human "$d")  $(basename "$d")"; continue; }
    if [ "$DAYS" -gt 0 ]; then
      if find "$d" -maxdepth 0 -mtime "-$DAYS" | grep -q .; then
        echo "    保留（$DAYS 天内）$(basename "$d")"; continue
      fi
    fi
    targets+=("$d")
  done
  echo "==> flutter_build：共 $i 个目录，将删 ${#targets[@]} 个"
fi

# ---------- ② 与"站"无关的其它可再生缓存 ----------
others=(
  "$ROOT/build/test_cache"
  "$ROOT/build/app/intermediates"
  "$ROOT/android/.gradle"
  "$ROOT/.dart_tool/hooks_runner"
)
if [ "$SITES" = "1" ]; then
  others+=("$ROOT/build/macos" "$ROOT/build/ios" "$ROOT/build/web" "$ROOT/build/linux" "$ROOT/build/windows")
fi
# 顶层散落的 kernel 缓存（`build/<hash>.cache.dill.track.dill`）
for f in "$ROOT"/build/*.cache.dill.track.dill; do
  [ -e "$f" ] && others+=("$f")
done

echo "==> 其它可再生缓存："
for p in "${others[@]}"; do
  [ -e "$p" ] || continue
  printf '    %-6s %s\n' "$(human "$p")" "${p#"$ROOT"/}"
done

# ---------- ③ 合并成一张清单（bash 3.2 + `set -u` 下空数组展开会报 unbound，绕开） ----------
all=()
if [ "${#targets[@]}" -gt 0 ]; then all=("${targets[@]}"); fi
for _p in "${others[@]}"; do all+=("$_p"); done

# ---------- ③ 红线断言（删之前先证明目标合法） ----------
for p in "${all[@]}"; do
  case "$p" in
    "$ROOT"/*) ;;
    *) echo "❌ 越界（不在仓库内）：$p" >&2; exit 1 ;;
  esac
  case "$p" in
    */docs|*/docs/*|*/docs/evidence-*) echo "❌ 拒绝删证据：$p" >&2; exit 1 ;;
  esac
  case "$p" in
    "$ROOT/build/app/outputs"|"$ROOT/build/app/outputs/"*) echo "❌ 拒绝删产物：$p" >&2; exit 1 ;;
  esac
done
echo "==> 红线检查通过（不碰 docs/evidence-*、不碰 build/app/outputs/）"

# ---------- ④ 估算 + 执行 ----------
before=$(mb_of "$ROOT")
if [ "$DO_IT" != "1" ]; then
  echo
  saved=0
  for p in "${all[@]}"; do
    [ -e "$p" ] || continue
    saved=$(( saved + $(mb_of "$p") ))
  done
  echo "==> DRY-RUN：未删除任何东西。当前 ${before} MB；勾到的目标合计 ${saved} MB"
  echo "    真删：scripts/prune_flutter_caches.sh --yes $*"
  exit 0
fi

for p in "${all[@]}"; do
  [ -e "$p" ] || continue
  rm -rf "$p"
done
after=$(mb_of "$ROOT")
echo
echo "==> 已删。${before} MB → ${after} MB（省 $(( before - after )) MB）"
echo "==> 证据目录仍在：$(ls -d "$ROOT"/docs/evidence-* 2>/dev/null | wc -l | tr -d ' ') 个"
echo "==> 产物仍在：$(human "$ROOT/build/app/outputs/flutter-apk/app-release.apk") $(shasum -a 256 "$ROOT/build/app/outputs/flutter-apk/app-release.apk" 2>/dev/null | cut -c1-16)…"
echo "★ 下次构建/测试会全量重编（实测 release 构建 ≈ 1m20s）。"
