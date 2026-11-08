#!/usr/bin/env bash
# r732：把已签名的 deb/rpm 组织成**可被包管理器信任的仓库**（apt + dnf 两套索引）。
#
# 为什么：单个签名的 .deb 只证明"这一个包是谁签的"，用户仍要手动下载、手动升级。
# 有了签名索引，用户侧变成 `apt install synhub` / `dnf install synhub`，之后
# `apt upgrade` 能收到新版本，而且 apt/dnf 会**用公钥校验索引和包**，链路闭合。
#
# 目录结构（发布到 gh-pages，站点根 = 仓库根）：
#   keys/synhub-archive-keyring.asc
#   repo/apt/dists/stable/{Release,InRelease,Release.gpg,main/binary-<arch>/{Packages,Packages.gz}}
#   repo/apt/pool/main/s/synhub/*.deb
#   repo/rpm/<arch>/{repodata/*,repomd.xml.asc,*.rpm}
#   repo/rpm/synhub.repo            # dnf 的 .repo 文件（用户直接下这个）
#
# 用法（在 Linux 里，**先跑 sign_linux_packages.sh**）：
#   export SYNHUB_GPG_PRIVATE_KEY=...   SYNHUB_GPG_KEY_ID=...
#   scripts/build_linux_repo.sh --out dist/pages \
#       build/linux_deb/*.deb build/linux_rpm/*.rpm
set -euo pipefail

die() { echo "[repo] $*" >&2; exit 1; }
log() { echo "[repo] $*"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT=""
FILES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    -*) die "未知参数：$1" ;;
    *) FILES+=("$1"); shift ;;
  esac
done
[[ -n "$OUT" ]] || die "缺 --out <目录>"
[[ ${#FILES[@]} -gt 0 ]] || die "没有输入包"

[[ -n "${SYNHUB_GPG_PRIVATE_KEY:-}" ]] || die "没有 SYNHUB_GPG_PRIVATE_KEY —— 索引必须签名，拒绝产出未签名仓库"

command -v gpg >/dev/null || die "没有 gpg"

GNUPGHOME="$(mktemp -d)"; chmod 700 "$GNUPGHOME"; export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT
printf '%s' "$SYNHUB_GPG_PRIVATE_KEY" | gpg --batch --import >/dev/null 2>&1 || die "私钥导入失败"
KEYID="${SYNHUB_GPG_KEY_ID:-}"
[[ -n "$KEYID" ]] || KEYID="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^sec:/{print $5; exit}')"
[[ -n "$KEYID" ]] || die "没有可用私钥"

# ★ 指纹必须和仓库里 `keys/README.md` 写的一致：否则我们会发布一个"用户手上的公钥
#   验不过"的仓库 —— 签名全对、用户全不认。这条是**会变红**的守卫，不是注释。
WANT_FPR="$(awk -F': *' '/^key-fingerprint:/{print $2; exit}' "$ROOT/keys/README.md" 2>/dev/null | tr -d ' ')"
GOT_FPR="$(gpg --batch --with-colons --fingerprint "$KEYID" | awk -F: '/^fpr:/{print $10; exit}')"
if [[ -n "$WANT_FPR" && "$WANT_FPR" != "$GOT_FPR" ]]; then
  die "签名密钥指纹不一致：仓库声明 $WANT_FPR，实际 $GOT_FPR —— 先更新 keys/README.md 再发版"
fi
log "指纹核对通过：$GOT_FPR"

rm -rf "$OUT"
mkdir -p "$OUT/keys" "$OUT/repo/apt/dists/stable" "$OUT/repo/apt/pool/main/s/synhub" \
         "$OUT/repo/rpm"

# ── 公钥：用户侧 `gpg --dearmor` 用的就是它
gpg --batch --armor --export "$KEYID" > "$OUT/keys/synhub-archive-keyring.asc"
[[ -s "$OUT/keys/synhub-archive-keyring.asc" ]] || die "导出公钥为空"

# ── deb
DEBS=(); RPMS=()
for f in "${FILES[@]}"; do
  case "$f" in
    *.deb) DEBS+=("$f") ;;
    *.rpm) RPMS+=("$f") ;;
    *) log "跳过（既不是 deb 也不是 rpm）：$f" ;;
  esac
done

if [[ ${#DEBS[@]} -gt 0 ]]; then
  command -v dpkg-deb >/dev/null || die "没有 dpkg-deb"
  ARCHS=()
  for d in "${DEBS[@]}"; do
    cp "$d" "$OUT/repo/apt/pool/main/s/synhub/"
    a="$(dpkg-deb -f "$d" Architecture)"
    case " ${ARCHS[*]:-} " in *" $a "*) ;; *) ARCHS+=("$a") ;; esac
  done
  for a in "${ARCHS[@]}"; do
    mkdir -p "$OUT/repo/apt/dists/stable/main/binary-$a"
    ( cd "$OUT/repo/apt" && dpkg-scanpackages --arch "$a" pool/main > \
        "dists/stable/main/binary-$a/Packages" 2>/dev/null )
    gzip -9kf "$OUT/repo/apt/dists/stable/main/binary-$a/Packages"
    log "apt: binary-$a 索引 $(grep -c '^Package:' "$OUT/repo/apt/dists/stable/main/binary-$a/Packages") 个包"
  done
  ( cd "$OUT/repo/apt" && cat > /tmp/apt-release.conf <<CONF
APT::FTPArchive::Release::Origin "SynHub";
APT::FTPArchive::Release::Label "SynHub";
APT::FTPArchive::Release::Suite "stable";
APT::FTPArchive::Release::Codename "stable";
APT::FTPArchive::Release::Architectures "${ARCHS[*]}";
APT::FTPArchive::Release::Components "main";
APT::FTPArchive::Release::Description "SynHub — Synology NAS client (unsigned build by project key)";
CONF
    apt-ftparchive -c /tmp/apt-release.conf release dists/stable > dists/stable/Release )
  ( cd "$OUT/repo/apt/dists/stable" \
      && gpg --batch --yes --local-user "$KEYID" --armor --detach-sign -o Release.gpg Release \
      && gpg --batch --yes --local-user "$KEYID" --clearsign -o InRelease Release )
  gpg --batch --verify "$OUT/repo/apt/dists/stable/Release.gpg" \
      "$OUT/repo/apt/dists/stable/Release" >/dev/null 2>&1 || die "apt Release 签名校验失败"
  log "apt: Release/InRelease 已签名并验证"
fi

if [[ ${#RPMS[@]} -gt 0 ]]; then
  command -v createrepo_c >/dev/null || die "没有 createrepo_c（apt: createrepo-c / dnf: createrepo_c）"
  # ★ 目录按**包自己的架构**命名（第一版写死 x86_64，aarch64 的包就被放进 x86_64/
  #   里 —— 那样 `baseurl` 会指错，用户侧直接 404）。一个目录一个 arch，各自签名索引。
  declare -a RPM_ARCHS=()
  for r in "${RPMS[@]}"; do
    ra="$(rpm -qp --queryformat '%{ARCH}' "$r")"
    [[ -n "$ra" ]] || die "读不出架构：$r"
    case " ${RPM_ARCHS[*]:-} " in *" $ra "*) ;; *) RPM_ARCHS+=("$ra") ;; esac
  done
  for ra in "${RPM_ARCHS[@]}"; do
    DEST="$OUT/repo/rpm/$ra"
    mkdir -p "$DEST"
    for r in "${RPMS[@]}"; do
      [[ "$(rpm -qp --queryformat '%{ARCH}' "$r")" == "$ra" ]] && cp "$r" "$DEST/"
    done
    createrepo_c --quiet "$DEST"
    gpg --batch --yes --local-user "$KEYID" --armor --detach-sign \
        --output "$DEST/repodata/repomd.xml.asc" "$DEST/repodata/repomd.xml"
    gpg --batch --verify "$DEST/repodata/repomd.xml.asc" "$DEST/repodata/repomd.xml" >/dev/null 2>&1 \
      || die "rpm/$ra repomd 签名校验失败"
    log "rpm/$ra: repodata 已签名并验证（$(ls "$DEST"/*.rpm | wc -l | tr -d ' ') 个包）"
  done

  cat > "$OUT/repo/rpm/synhub.repo" <<'REPO'
[synhub]
name=SynHub (Synology NAS client)
# ★ %ARCH% 由 dnf 按当前机器展开，x86_64 / aarch64 目录都能对上
baseurl=https://openviewmobile.github.io/synhub/repo/rpm/$basearch
enabled=1
# ★ gpgcheck 校验**包**签名，repo_gpgcheck 校验**索引**签名 —— 两个都要开：
#   只开前者，攻击者可以伪造索引指向一个"合法签名但内容不同"的包。
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://openviewmobile.github.io/synhub/keys/synhub-archive-keyring.asc
REPO
fi

# ── 一份给人看的首页：站点根被直接打开时不至于 404
cat > "$OUT/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>SynHub repository</title>
<h1>SynHub — package repository</h1>
<p>Install instructions: <a href="https://github.com/openviewmobile/synhub#install">GitHub</a></p>
<ul>
  <li><a href="keys/synhub-archive-keyring.asc">Signing key</a></li>
  <li><a href="repo/rpm/synhub.repo">dnf repo file</a></li>
</ul>
HTML

log "仓库树：$OUT"
find "$OUT" -maxdepth 4 -type f | sort | sed 's/^/    /' | head -30
