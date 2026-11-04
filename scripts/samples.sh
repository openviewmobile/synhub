#!/usr/bin/env bash
# 官方样例库（SPK/APK/PAT + 接口定义）统一入口。
#
# 用户 2026-09-23 要求：「已经下载好的 spk apk 统一放到一个地方保存好，
# 避免反复下载浪费流量」。
#
# 库位置：$HOME/synology_samples/（不在仓库内）
# 清单：  $STORE/MANIFEST.md
#
# 用法：
#   scripts/samples.sh list            列全部原件 + 大小
#   scripts/samples.sh path DSchat     打印匹配文件的路径
#   scripts/samples.sh verify          逐个校验 sha256
#   scripts/samples.sh link            把原件软链回 /tmp（让老命令继续可用）
#   scripts/samples.sh weblib [名字]   看接口定义（.lib/.api/.so 名单）
#   scripts/samples.sh find <关键字>   在库里找
#   scripts/samples.sh add <文件> [短名]  把**刚下载**的原件收进库里 + 追加 MANIFEST
#   scripts/samples.sh audit          扫 /tmp 里"没入库/没软链"的真实副本（防重复下载）
set -uo pipefail

STORE="${SYNOLOGY_SAMPLES:-$HOME/synology_samples}"

die() {
  echo "错误：$*" >&2
  exit 1
}

[ -d "$STORE" ] || die "样例库不存在：$STORE"

cmd="${1:-list}"
shift || true

case "$cmd" in
list)
  echo "样例库：$STORE"
  echo
  for sub in apk spk dsm builds; do
    [ -d "$STORE/$sub" ] || continue
    echo "── $sub/ ──"
    # 用 -- 防文件名以 - 开头；awk 只为了对齐大小
    find "$STORE/$sub" -maxdepth 1 -type f -print0 2>/dev/null |
      xargs -0 -I{} ls -lh {} 2>/dev/null |
      awk '{printf "  %-9s %s\n", $5, $9}'
    echo
  done
  echo "── weblib/（接口定义，小体积高价值）──"
  for d in "$STORE"/weblib/*/; do
    [ -d "$d" ] || continue
    n=$(find "$d" -name '*.lib' 2>/dev/null | wc -l | tr -d ' ')
    a=$(find "$d" -name '*.api' 2>/dev/null | wc -l | tr -d ' ')
    printf '  %-30s .lib %-4s .api %s\n' "$(basename "$d")" "$n" "$a"
  done
  echo
  echo "总计：$(du -sh "$STORE" | cut -f1)"
  ;;

path)
  [ $# -ge 1 ] || die "用法：samples.sh path <关键字>"
  # 别名：库里文件名与日常简称不同（如 DSchat → Android-SynologyChat…）
  alias_for() {
    case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
    dschat | chat) echo 'SynologyChat' ;;
    dsdrive | drive) echo 'SynologyDrive' ;;
    dsphoto | photo | photos) echo 'SynologyPhotos' ;;
    dsfind) echo 'DSfinder' ;;
    *) echo "$1" ;;
    esac
  }
  want=$(alias_for "$1")
  hits=$(find "$STORE" -maxdepth 3 -type f -iname "*$want*" 2>/dev/null | sort)
  if [ -z "$hits" ] && [ "$want" != "$1" ]; then
    hits=$(find "$STORE" -maxdepth 3 -type f -iname "*$1*" 2>/dev/null | sort)
  fi
  n=$(printf '%s\n' "$hits" | grep -c . || true)
  [ "$n" -gt 0 ] || die "库里没有匹配「$1」的文件。用 list 看看有什么。"
  if [ "$n" -gt 1 ]; then
    echo "有多个匹配（取第一个；其余列在下面）：" >&2
    printf '  %s\n' $hits >&2
  fi
  printf '%s\n' "$hits" | head -1
  ;;

verify)
  [ -f "$STORE/MANIFEST.md" ] || die "缺 MANIFEST.md"
  echo "校验 sha256（以 MANIFEST.md 里记录的前 12 位为准）…"
  bad=0
  checked=0
  for sub in apk spk dsm builds; do
    [ -d "$STORE/$sub" ] || continue
    for f in "$STORE/$sub"/*; do
      [ -f "$f" ] || continue
      # ★ 第 97 轮：MANIFEST 改成了 bullet 格式（`* \`名\` — … — sha256 \`…\``），
      #   老脚本只认旧表格格式（`| \`名\` | … |`）⇒ 校验 0 条静默通过。
      #   两种格式都认（按文件名匹配该行，再从行里抓 12 位哈希）。
      want=$(grep -F "\`$(basename "$f")\`" "$STORE/MANIFEST.md" |
        grep -oE '`[0-9a-f]{12}…`' | head -1 | tr -d '`…')
      [ -n "$want" ] || continue
      got=$(shasum -a 256 "$f" | cut -c1-12)
      checked=$((checked + 1))
      if [ "$want" = "$got" ]; then
        echo "  ✅ $(basename "$f")"
      else
        echo "  ❌ $(basename "$f")  期望 $want… 实际 $got…"
        bad=$((bad + 1))
      fi
    done
  done
  echo "已校验 $checked 个，失败 $bad 个"
  [ "$bad" -eq 0 ] || exit 1
  ;;

link)
  # 把原件软链回 /tmp —— 老命令/脚本继续可用，但字节只存一份。
  mkdir -p /tmp
  n=0
  for sub in apk spk dsm builds; do
    [ -d "$STORE/$sub" ] || continue
    for f in "$STORE/$sub"/*; do
      [ -f "$f" ] || continue
      dst="/tmp/$(basename "$f")"
      if [ -L "$dst" ]; then
        rm -f "$dst"
      elif [ -e "$dst" ]; then
        # ★ 第 251 轮：以前这里只"跳过"，于是 /tmp 里长期留着**真实副本**
        #   （我下载完忘了 link，link 又不敢覆盖）⇒ 下次就重复下载。
        #   现在：**字节一致就换成软链**（把真副本删掉，字节只留库里的那一份）；
        #   字节不同则报警并保留，交给人判断（不静默覆盖任何东西）。
        a=$(shasum -a 256 "$f" | cut -c1-16)
        b=$(shasum -a 256 "$dst" | cut -c1-16)
        if [ "$a" = "$b" ]; then
          rm -f "$dst" && ln -s "$f" "$dst" && n=$((n + 1))
          echo "  ♻️  用软链替换了 /tmp 里的同内容真副本：$(basename "$f")"
          continue
        fi
        echo "  ⚠️  跳过（/tmp 已有**不同内容**的同名文件，不覆盖）：$(basename "$f")"
        continue
      fi
      ln -s "$f" "$dst" && n=$((n + 1))
    done
  done
  # 历史脚本里用过的短名，额外补几条软链
  [ -f "$STORE/spk/synophotos.spk" ] && ln -sf "$STORE/spk/synophotos.spk" /tmp/synophotos.spk
  [ -f "$STORE/spk/synodrive.spk" ] && ln -sf "$STORE/spk/synodrive.spk" /tmp/synodrive.spk
  [ -f "$STORE/dsm/dsm722.pat" ] && ln -sf "$STORE/dsm/dsm722.pat" /tmp/dsm722.pat
  echo "已在 /tmp 建立 $n 条软链（字节仍在样例库）"
  ;;

weblib)
  if [ $# -ge 1 ]; then
    d="$STORE/weblib/$1"
    [ -d "$d" ] || {
      echo "可选的套件（$STORE/weblib/）："
      ls -1 "$STORE/weblib/"
      exit 1
    }
    echo "── $1 ──"
    find "$d" -type f | sed "s|$d/||" | sort
  else
    echo "可选的套件："
    ls -1 "$STORE/weblib/"
  fi
  ;;

find)
  [ $# -ge 1 ] || die "用法：samples.sh find <关键字>"
  find "$STORE" -type f -iname "*$1*" 2>/dev/null | sed "s|$STORE/||" | sort
  ;;

add)
  # 把刚下载的原件收进样例库并登记哈希；随后自动 link 回 /tmp。
  # 目的：**一次下载，长期复用**（用户 2026-09-23 要求）。
  [ $# -ge 1 ] || die "用法：samples.sh add <文件路径> [库里用的短名]"
  src="$1"
  [ -f "$src" ] || die "文件不存在：$src"
  name="${2:-$(basename "$src")}"
  case "$(printf '%s' "$name" | tr 'A-Z' 'a-z')" in
  *.spk) sub=spk ;;
  *.apk) sub=apk ;;
  *.pat) sub=dsm ;;
  *) sub=builds ;;
  esac
  dst="$STORE/$sub/$name"
  if [ -e "$dst" ]; then
    a=$(shasum -a 256 "$src" | cut -c1-16); b=$(shasum -a 256 "$dst" | cut -c1-16)
    [ "$a" = "$b" ] || die "库里已有同名但内容不同的文件：$dst（请换个短名）"
    echo "库里已有同内容文件，跳过拷贝：$dst"
  else
    cp "$src" "$dst"
    echo "已入库：$dst"
  fi
  h=$(shasum -a 256 "$dst" | cut -c1-12)
  sz=$(stat -f%z "$dst" 2>/dev/null || stat -c%s "$dst")
  if grep -qF "\`$name\`" "$STORE/MANIFEST.md" 2>/dev/null; then
    echo "MANIFEST 已有该条目，未重复登记"
  else
    {
      echo
      echo "* \`${name}\` — ${name}（${sz} B；sha256 \`${h}…\`）— 来源：手工入库（记载见仓库 AGENTS.md §1.3.0）"
    } >>"$STORE/MANIFEST.md"
    echo "已登记 MANIFEST：${name} sha256 ${h}…"
  fi
  "$0" link >/dev/null 2>&1 || true
  echo "完成。核对：scripts/samples.sh verify"
  ;;

audit)
  # 防"重复下载"：找出 /tmp 里**真实**（非软链）的 spk/apk/pat，
  # 逐个和库里的哈希比对，明确告诉人"这份到底在不在库里"。
  #   samples.sh audit         只报告
  #   samples.sh audit --fix   把"库里已有同内容"的真副本**换成软链**（省磁盘、防再下）
  fix=0
  [ "${1:-}" = "--fix" ] && fix=1
  echo "扫描 /tmp 下的真实包（软链忽略）…"
  miss=0
  dup=0
  linked=0
  while IFS= read -r f; do
    [ -L "$f" ] && { linked=$((linked + 1)); continue; }
    base=$(basename "$f")
    lib="$STORE/$( [ "${base##*.}" = pat ] && echo dsm || ([ "${base##*.}" = apk ] && echo apk || echo spk) )/$base"
    h=$(shasum -a 256 "$f" | cut -c1-12)
    if [ -f "$lib" ]; then
      gl=$(shasum -a 256 "$lib" | cut -c1-12)
      if [ "$h" = "$gl" ]; then
        if [ "$fix" = 1 ]; then
          rm -f "$f" && ln -s "$lib" "$f"
          echo "  ♻️  $base —— 已换成软链 → $lib"
        else
          echo "  ♻️  $base —— 库里已有同内容（跑 samples.sh audit --fix 换成软链即可）"
        fi
        dup=$((dup + 1))
      else
        echo "  ⚠️  $base —— 库里同名但内容不同（人工判断）"
      fi
    else
      inlib=$(grep -F "\`$h" "$STORE/MANIFEST.md" 2>/dev/null | head -1 | sed -E 's/^\* `([^`]*)`.*/\1/')
      if [ -n "$inlib" ]; then
        if [ "$fix" = 1 ]; then
          rm -f "$f" && ln -s "$STORE/$( [ "${base##*.}" = pat ] && echo dsm || ([ "${base##*.}" = apk ] && echo apk || echo spk) )/$inlib" "$f"
          echo "  ♻️  $base —— 已换成软链 → $inlib"
        else
          echo "  ♻️  $base —— 库里有同内容条目：$inlib"
        fi
        dup=$((dup + 1))
      else
        echo "  ❌ $base —— **不在库里**（用 samples.sh add 收进来，别再下第二次）"
        miss=$((miss + 1))
      fi
    fi
  done < <(find /private/tmp -maxdepth 4 \( -name '*.spk' -o -name '*.apk' -o -name '*.pat' \) \
    -not -path "$STORE/*" -not -path '*/Library/*' 2>/dev/null | sort)
  echo "小结：软链 $linked 条；库里已有 $dup 条；**未入库 $miss 条**"
  ;;

*)
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
  ;;
esac
