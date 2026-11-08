#!/usr/bin/env bash
# r732：生成/轮换 Linux 包仓库的 GPG 签名密钥（**在维护者自己的机器上跑**，不要在 CI 里跑）。
#
# 为什么单独一个脚本：签名密钥是长期资产，轮换必须可复现；而且私钥**绝不能**
# 进仓库 —— 所以这里把它写到仓库外、`0600`、并且只打印指纹与后续两步。
#
# 用法：
#   scripts/new_gpg_key.sh                 # 生成新的 ed25519 签名密钥
#   scripts/new_gpg_key.sh --out ~/x.asc   # 指定私钥落盘位置
#
# 生成后有两件事必须做（脚本会打印现成的命令）：
#   ① 把私钥灌进 Actions secret：SYNHUB_GPG_PRIVATE_KEY
#   ② 把公钥提交进仓库：keys/synhub-archive-keyring.asc
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${HOME}/.config/synhub/synhub-linux-signing-key.asc"
NAME="SynHub release signing <noreply@openviewai.com>"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    -*) echo "未知参数：$1" >&2; exit 2 ;;
    *) shift ;;
  esac
done

command -v gpg >/dev/null || { echo "没有 gpg" >&2; exit 1; }

TMPHOME="$(mktemp -d)"; chmod 700 "$TMPHOME"
export GNUPGHOME="$TMPHOME"
trap 'rm -rf "$TMPHOME"' EXIT

echo "[key] 生成 ed25519 签名密钥（无口令 —— 它只以 secret 形式存在，口令不会带来额外保护）"
gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "$NAME" ed25519 sign 0 >/dev/null 2>&1

KEYID="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')"
[[ -n "$KEYID" ]] || { echo "生成失败" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
( umask 077; gpg --batch --armor --export-secret-keys "$KEYID" > "$OUT" )
chmod 600 "$OUT"
mkdir -p "$ROOT/keys"
gpg --batch --armor --export "$KEYID" > "$ROOT/keys/synhub-archive-keyring.asc"

cat <<INFO

指纹（写进 keys/README.md，README 的验证命令用它）：
  $KEYID

私钥（**仓库外**，0600，别提交、别贴聊天）：
  $OUT

公钥（已写进仓库，可提交）：
  $ROOT/keys/synhub-archive-keyring.asc

接下来两步：
  ① 把私钥灌进 Actions secret（值不会显示在日志里）：
       gh secret set SYNHUB_GPG_PRIVATE_KEY < "$OUT"
       gh secret set SYNHUB_GPG_KEY_ID --body "$KEYID"
     （没有 gh：Settings → Secrets and variables → Actions → New repository secret）
  ② 提交公钥：
       git add keys/synhub-archive-keyring.asc keys/README.md
  ③ 备份私钥到离线处（U 盘/密码管理器）。**丢了就要换钥匙，用户得重新导入公钥。**
INFO
