#!/usr/bin/env bash
# 一条命令核验下载到的发布物：公钥、校验和、deb/rpm 签名。
#
# 用法：
#   scripts/verify_download.sh <下载目录> [tag]
#   （tag 省略时从目录里的文件名推断，例如 synhub_0.2.8_amd64.deb → 0.2.8）
#
# 为什么要有它：README 里那段 gpg/sha256sum/rpm 命令是对的，但用户要自己拼
# **指纹**、**文件名**、**是否装了 rpm**。真实的门槛是"照着做要试几次"，
# 不是"不知道原理"。这条脚本把几次试错变成一次运行，凡是缺工具都明确说缺什么。
set -euo pipefail

SITE="${SYNHUB_SITE:-https://openviewmobile.github.io/synhub}"
KEY_URL="$SITE/keys/synhub-archive-keyring.asc"

die() { echo "✗ $*" >&2; exit 1; }
ok()  { echo "✓ $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

[[ $# -ge 1 ]] || die "用法: $0 <下载目录> [tag]"
DIR="$1"
[[ -d "$DIR" ]] || die "不是目录：$DIR"
cd "$DIR"

# ---- 版本号：优先参数，其次文件名 ----
VER="${2:-}"
if [[ -z "$VER" ]]; then
  VER="$(ls 2>/dev/null | sed -n 's/^synhub[-_]\([0-9][0-9.]*\)[_-].*/\1/p' | head -1)"
fi
[[ -n "$VER" ]] || die "推断不出向量版本，请显式给 tag（例如 v0.2.8）"
VER="${VER#v}"

[[ -f SHA256SUMS.txt ]] || die "缺少 SHA256SUMS.txt（从 release 页面下载它）"
[[ -f SHA256SUMS.txt.asc ]] || die "缺少 SHA256SUMS.txt.asc（没有它就证明不了校验和本身）"

have gpg || die "需要 gpg（macOS: brew install gnupg；Debian/Ubuntu: apt install gnupg）"

# ---- ① 只用**站点发布的那把公钥**，不偷偷用签名私钥 ----
KEYRING="$(mktemp -d)"
trap 'rm -rf "$KEYRING"' EXIT
export GNUPGHOME="$KEYRING"; chmod 700 "$GNUPGHOME"
if have curl; then
  curl -fsSL --retry 3 "$KEY_URL" -o "$KEYRING/pub.asc" || die "下载公钥失败：$KEY_URL"
elif have wget; then
  wget -qO "$KEYRING/pub.asc" "$KEY_URL" || die "下载公钥失败：$KEY_URL"
else
  die "需要 curl 或 wget"
fi
gpg --batch --quiet --import "$KEYRING/pub.asc" || die "导入公钥失败"
ok "已用站点发布的公钥建了临时钥匙环（不影响你自己的 ~/.gnupg）"

# ---- ② 校验和文件本身的签名 ----
# gpg 会把 "not certified with a trusted signature" 这类**预期内**的提示也打到 stderr，
# 混在成功输出里会让人以为出了问题 ⇒ 正常路径只留一行结论，细节只在失败时抛出。
if ! gpg --batch --verify SHA256SUMS.txt.asc SHA256SUMS.txt 2>"$KEYRING/verify.log"; then
  cat "$KEYRING/verify.log" >&2
  die "SHA256SUMS.txt 的签名验不过 —— 校验和不可信，后面都不用做了"
fi
signer="$(gpg --batch --list-keys --with-colons 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
ok "SHA256SUMS.txt 的签名有效（签名者 ${signer}）"

# ---- ③ 逐文件比对 ----
# ★ 只核目录里真实存在的文件：用户可能只下了某一个平台的包。
missing=0; checked=0
while read -r sum path; do
  f="${path#./}"
  if [[ ! -f "$f" ]]; then missing=$((missing+1)); continue; fi
  got="$(sha256sum "$f" 2>/dev/null | awk '{print $1}')" \
    || got="$(shasum -a 256 "$f" | awk '{print $1}')"
  [[ "$got" = "$sum" ]] || die "$f 的 sha256 与 SHA256SUMS.txt 不一致（文件被换过或下载残缺）"
  checked=$((checked+1))
done < SHA256SUMS.txt
[[ "$checked" -gt 0 ]] || die "目录里没有一个文件能对上 SHA256SUMS.txt（路径或版本不对？）"
ok "$checked 个文件的 sha256 与签名过的清单一致（$missing 个清单条目本目录没有，跳过）"

# ---- ④ 平台签名 ----
if [[ -f "synhub_${VER}_amd64.deb" && -f "synhub_${VER}_amd64.deb.asc" ]]; then
  if ! gpg --batch --verify "synhub_${VER}_amd64.deb.asc" "synhub_${VER}_amd64.deb" \
       2>"$KEYRING/deb.log"; then
    cat "$KEYRING/deb.log" >&2
    die "deb 的分离签名验不过"
  fi
  ok "deb 的分离签名有效"
fi
if compgen -G "synhub-${VER}-*.rpm" >/dev/null; then
  if have rpm; then
    DB="$(mktemp -d)"; rpm --dbpath "$DB" --initdb
    rpm --dbpath "$DB" --import "$KEYRING/pub.asc" || die "公钥导入 rpm 库失败"
    rpm --dbpath "$DB" --checksig -v synhub-"${VER}"-*.rpm > "$KEYRING/sig.txt" || true
    # ★ 判据是 Signature 行里的 OK —— 只看 "signatures OK" 会把 rpm 6 的措辞差异
    #   和"根本没有签名头"混在一起（v0.2.2 就是这么放过一次）。
    grep -Eiq 'signature.*: *OK' "$KEYRING/sig.txt" \
      || { cat "$KEYRING/sig.txt" >&2; die "rpm 里读不出有效签名"; }
    ok "rpm 的嵌入签名有效（$(rpm --version)）"
    rm -rf "$DB"
  else
    echo "· 没装 rpm，跳过 rpm 嵌入签名（deb 侧与校验和已验证）"
  fi
fi

echo
ok "全部核验通过：这些字节来自 SynHub 的发布流程，且未被改动。"
