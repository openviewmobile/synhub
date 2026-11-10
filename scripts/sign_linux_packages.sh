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
      # ★★★ 为什么要考虑"换一个 rpm 来签"：runner 上已经是 **rpm 6**，它签出来的包
      #   在 rpm 4.18/4.20 上**看不到任何 Signature 行**（只有 digest 行），而
      #   Fedora ≤41、RHEL ≤9、openSUSE 用的就是 4.x ⇒ `dnf gpgcheck=1` 会认为包没签名。
      #   实测（同一把公钥、同一个文件）：rpm 4.18/4.20 读不出，6.x 读得出。
      #   所以发版时用 `SYNHUB_RPM_SIGN_IMAGE`（例如 ubuntu:24.04，内含 rpm 4.18）
      #   在容器里签，签完再回到宿主机的 rpm 上验一遍 —— 两代都能读才算过。
      sign_rpm_here() {
        command -v rpm >/dev/null || die "没有 rpm，无法给 $1 签名"
        # ★ 两个必须显式给的 define，都是踩出来的：
        #   ① `__gpg` —— Debian/Ubuntu 的 rpm 把 `%__gpg` 默认写成 `/usr/bin/gpg2`，
        #      而 Ubuntu 只有 `gpg` ⇒ 报 "Could not exec gpg: No such file or directory"；
        #   ② `_gpg_name` —— 不指定会拿默认 key，多把私钥时签错。
        rpm --addsign \
          --define "__gpg $(command -v gpg)" \
          --define "_gpg_name $KEYID" "$1" >/dev/null
      }

      sign_rpm_in_container() {
        local f="$1" dir base keydir
        dir="$(cd "$(dirname "$f")" && pwd)"; base="$(basename "$f")"
        keydir="$(mktemp -d)"; chmod 700 "$keydir"
        printf '%s' "$SYNHUB_GPG_PRIVATE_KEY" > "$keydir/sk.asc"; chmod 600 "$keydir/sk.asc"
        log "在容器 $SYNHUB_RPM_SIGN_IMAGE 里签名（为了让 rpm 4.x 也验得出）"
        # ★ 镜像拉取与容器内 apt 都是**外部网络**：r740 的 packaging-smoke 就在这两处红过
        #   （一次 exit 100 = apt 失败，一次 exit 1 = 拉不到镜像）。都重试三次再放弃，
        #   失败信息保留在 stderr 里 —— 重试是为了扛抖动，不是为了掩盖真错。
        local try
        for try in 1 2 3; do
          if docker image inspect "$SYNHUB_RPM_SIGN_IMAGE" >/dev/null 2>&1; then break; fi
          log "拉取 $SYNHUB_RPM_SIGN_IMAGE（第 $try 次）"
          docker pull -q "$SYNHUB_RPM_SIGN_IMAGE" >/dev/null 2>&1 && break
          [[ "$try" = 3 ]] && die "拉不到镜像 $SYNHUB_RPM_SIGN_IMAGE（试了 3 次）"
          sleep 5
        done
        docker run --rm -v "$keydir:/key:ro" -v "$dir:/w" -w /w -e KEYID="$KEYID" \
          "$SYNHUB_RPM_SIGN_IMAGE" bash -lc '
            set -e
            if ! command -v rpm >/dev/null || ! command -v gpg >/dev/null; then
              for t in 1 2 3; do
                apt-get update -qq -o Acquire::Retries=5 >/dev/null 2>&1 &&
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                  -o Acquire::Retries=5 rpm gnupg >/dev/null 2>&1 && break
                echo "[sign] 容器内装 rpm/gnupg 失败，重试 $t" >&2; sleep 5
              done
              command -v rpm >/dev/null && command -v gpg >/dev/null
            fi
            export GNUPGHOME="$(mktemp -d)"; chmod 700 "$GNUPGHOME"
            gpg --batch --import /key/sk.asc >/dev/null 2>&1
            rpm --addsign --define "__gpg $(command -v gpg)" \
                --define "_gpg_name $KEYID" "$1" >/dev/null
            echo "[sign] 容器内 rpm：$(rpm --version)"
          ' _ "$base" || die "容器内签名失败（$SYNHUB_RPM_SIGN_IMAGE）"
        rm -rf "$keydir"
      }

      if [[ -n "${SYNHUB_RPM_SIGN_IMAGE:-}" ]] && command -v docker >/dev/null 2>&1; then
        sign_rpm_in_container "$f"
      else
        sign_rpm_here "$f"
      fi

      # ★ 签完必须验：未通过 = 等于没签（这是本仓的通行判据）
      # ★ `rpm --checksig` 需要**公钥在 rpm 自己的库里**，否则一律 NOT OK。
      #   ★★ 而且**必须给独立的 --dbpath**：CI 以非 root 跑，`rpm --import` 写
      #   `/var/lib/rpm` 会失败（第一版把错误 `|| true` 吞了，于是 checksig 报
      #   `NOKEY`，本地以 root 跑却一切正常 —— 这就是它在 PR 上红的原因）。
      PUB="$(mktemp)"; gpg --batch --armor --export "$KEYID" > "$PUB"
      [[ -s "$PUB" ]] || die "导不出公钥（$KEYID）"
      RPMDB="$(mktemp -d)"
      rpm --dbpath "$RPMDB" --initdb
      rpm --dbpath "$RPMDB" --import "$PUB" || die "公钥导入 rpm 库失败（$RPMDB）"
      # ★★ 判据必须是 `-v` 输出里的 **Signature 行**，不能只看 "signatures OK"：
      #   v0.2.2 那次 `.rpm` 里根本没有签名头，而当时的 `rpm --checksig` 却回了
      #   "digests signatures OK" —— 自验通过、产物没签名。现在两条都要，并回显全文。
      OUT="$(rpm --dbpath "$RPMDB" --checksig -v "$f")" || true
      echo "$OUT" | sed 's/^/    /'
      # ★ rpm 的措辞随版本变：4.18 写 `Header V4 EdDSA/SHA512 Signature, key ID <id>: OK`，
      #   4.19+ 写 `Header OpenPGP V4 EdDSA/SHA512 signature, key fingerprint: <fpr>: OK`。
      #   所以判据只认"有 signature 字样 + OK"，不认某一种具体措辞（第一版只认前者，
      #   在 runner 上把**签成功的**包判成了没签）。
      if ! grep -Eiq 'signature.*: *OK' <<<"$OUT"; then
        die "$f 里没有可验证的签名头（rpm 只是重写了包，没有签上）"
      fi
      grep -qi 'signatures OK' <<<"$(rpm --dbpath "$RPMDB" --checksig "$f")" \
        || die "$f 签名校验没通过"
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
