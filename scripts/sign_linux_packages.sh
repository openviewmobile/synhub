#!/usr/bin/env bash
# r732：给 Linux 产物和校验和做 **GPG 签名**（项目自有密钥，不依赖任何 CA）。
#
# 为什么：deb/rpm 现在是从 Releases 下下来 `dpkg -i`，包管理器完全不校验来源；
# `SHA256SUMS.txt` 也是裸的 —— 谁改了文件都能顺手改校验和。签名把"来源"变成可验证的事实。
#
# 用法（在 Linux 里；私钥只从**环境变量**来，绝不落盘到仓库）：
#   export SYNHUB_GPG_PRIVATE_KEY="$(cat key.asc)"     # Actions secret
#   export SYNHUB_GPG_KEY_ID="ABCD1234..."             # 可选，缺省用导入的第一把
#   scripts/sign_linux_packages.sh build/linux_deb/*.deb build/linux_rpm/*.rpm SHA256SUMS.txt
#
# 没有 `SYNHUB_GPG_PRIVATE_KEY` 时**降级并大声警告**（和 Android 的 debug 签名同一套约定）：
# 发版不会因此失败，但摘要里会写清"这次是未签名的"，不假装。
set -euo pipefail

die() { echo "[sign] $*" >&2; exit 1; }
log() { echo "[sign] $*"; }

[[ $# -gt 0 ]] || die "没有要签的文件：$*"

if [[ -z "${SYNHUB_GPG_PRIVATE_KEY:-}" ]]; then
  echo "::warning::SYNHUB_GPG_PRIVATE_KEY 未配置 —— 本次 Linux 产物与 SHA256SUMS **未签名**"
  echo "[sign] 跳过签名（未配置密钥）"
  exit 0
fi

command -v gpg >/dev/null || die "没有 gpg"

# 独立的 GNUPGHOME：不碰 runner 上可能存在的其他钥匙串，也保证退出后不留私钥
GNUPGHOME="$(mktemp -d)"
chmod 700 "$GNUPGHOME"
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT

printf '%s' "$SYNHUB_GPG_PRIVATE_KEY" | gpg --batch --import >/dev/null 2>&1 || die "私钥导入失败"

KEYID="${SYNHUB_GPG_KEY_ID:-}"
if [[ -z "$KEYID" ]]; then
  KEYID="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^sec:/{print $5; exit}')"
fi
[[ -n "$KEYID" ]] || die "导入后没有可用私钥"
log "签名密钥：$KEYID"

signed=0
for f in "$@"; do
  [[ -f "$f" ]] || die "文件不存在：$f"
  case "$f" in
    *.rpm)
      command -v rpm >/dev/null || die "没有 rpm，无法给 $f 签名"
      # ★ 两个必须显式给的 define，都是踩出来的：
      #   ① `__gpg` —— Debian/Ubuntu 的 rpm 把 `%__gpg` 默认写成 `/usr/bin/gpg2`，
      #      而 Ubuntu 只有 `gpg` ⇒ 报 "Could not exec gpg: No such file or directory"；
      #   ② `_gpg_name` —— 不指定会拿默认 key，多把私钥时签错。
      rpm --addsign \
        --define "__gpg $(command -v gpg)" \
        --define "_gpg_name $KEYID" "$f" >/dev/null
      # ★ 签完必须验：`rpm -K` 未通过 = 等于没签（这是本仓的通行判据）
      # ★ `rpm --checksig` 需要**公钥在 rpm 自己的库里**，否则一律 NOT OK；
      #   所以先把公钥 import 进来（runner 是一次性的，改它的 rpm 库没有副作用）。
      PUB="$(mktemp)"; gpg --batch --armor --export "$KEYID" > "$PUB"
      rpm --import "$PUB" 2>/dev/null || true
      rpm --checksig "$f" | grep -qi 'signatures OK' || {
        echo "[sign] rpm --checksig 输出：" >&2; rpm --checksig -v "$f" | sed 's/^/    /' >&2
        die "$f 签名校验失败"
      }
      log "已签并验证：$f"
      ;;
    *.deb)
      # ★ 这里**不做**包内嵌签名，理由是实测出来的两条：
      #   ① Ubuntu 24.04 已经删掉了 `dpkg-sig` 包；`debsigs` 还在，但 `--sign=archive`
      #      在本机容器里直接失败（perl 报 `Use of uninitialized value $args[4] in exec`，
      #      随后 `--verify` 报 `no entry  in archive`）—— 工具本身在这个发行版上是坏的。
      #   ② 更根本：**apt 校验的是 Release/InRelease 的签名，不是包内嵌签名**。
      #      所以对 .deb 来说，内嵌签名没有任何消费者。
      #   因此 .deb 走**分离签名**（`<pkg>.deb.asc`），对它自己有意义的是"单文件可自证来源"，
      #   而仓库链路靠 `build_linux_repo.sh` 签索引。
      gpg --batch --yes --local-user "$KEYID" --armor --detach-sign --output "$f.asc" "$f"
      gpg --batch --verify "$f.asc" "$f" >/dev/null 2>&1 || die "$f 分离签名校验失败"
      log "已签并验证：$f.asc"
      ;;
    *)
      # 其余（SHA256SUMS.txt 之类）一律做**分离签名**
      gpg --batch --yes --local-user "$KEYID" --armor --detach-sign \
          --output "$f.asc" "$f"
      gpg --batch --verify "$f.asc" "$f" >/dev/null 2>&1 || die "$f 分离签名校验失败"
      log "已签并验证：$f.asc"
      ;;
  esac
  signed=$((signed + 1))
done

log "共签名 $signed 个文件"
