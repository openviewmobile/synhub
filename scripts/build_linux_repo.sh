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

# ── 站点首页：给人看的安装/下载页（不只是"别 404"）
#   ★ 之前这里只有三行链接 —— 用户打开站点唯一能看到的信息是"有个公钥"。
#     现在把三条安装路径、校验步骤和"哪些平台有产物"都摆在这一页上，
#     并且**版本号从实际产物里读**，不再手写（手写必过期）。
LATEST_DEB="$(cd "$OUT" 2>/dev/null && ls repo/apt/pool/main/s/synhub/*.deb 2>/dev/null | sort -V | tail -1 | sed 's#.*/##' || true)"
LATEST_RPM="$(cd "$OUT" 2>/dev/null && ls repo/rpm/x86_64/*.rpm 2>/dev/null | sort -V | tail -1 | sed 's#.*/##' || true)"
VER_SHOWN="$(printf '%s' "$LATEST_DEB" | sed -n 's/^synhub_\([0-9.]*\)_.*/\1/p')"
[[ -n "$VER_SHOWN" ]] || VER_SHOWN="（本次未发布 Linux 包）"
cat > "$OUT/index.html" <<HTML
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>SynHub — downloads</title>
<style>
 :root{color-scheme:light dark}
 body{font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Noto Sans SC",sans-serif;
      margin:0 auto;max-width:52rem;padding:2.5rem 1.25rem 4rem}
 h1{font-size:1.9rem;margin:0 0 .25rem} h2{font-size:1.15rem;margin:2.2rem 0 .6rem}
 .sub{opacity:.72;margin:0 0 1.6rem}
 pre{background:rgba(127,127,127,.12);padding:.85rem 1rem;border-radius:8px;overflow-x:auto;font-size:.86rem}
 code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
 table{border-collapse:collapse;width:100%;font-size:.92rem}
 th,td{text-align:left;padding:.4rem .5rem;border-bottom:1px solid rgba(127,127,127,.25)}
 .ok{color:#0a7d33} .warn{color:#a86400}
 footer{margin-top:3rem;font-size:.85rem;opacity:.7}
</style></head><body>
<h1>SynHub</h1>
<p class="sub">Unofficial, from-scratch client for Synology NAS — not affiliated with or endorsed by Synology Inc.<br>
Current Linux package version: <strong>${VER_SHOWN}</strong> · <a href="https://github.com/openviewmobile/synhub/releases/latest">all downloads on GitHub Releases</a></p>

<h2>Debian / Ubuntu</h2>
<pre><code>curl -fsSL https://openviewmobile.github.io/synhub/keys/synhub-archive-keyring.asc \\
  | sudo gpg --dearmor -o /usr/share/keyrings/synhub.gpg
echo "deb [signed-by=/usr/share/keyrings/synhub.gpg] https://openviewmobile.github.io/synhub/repo/apt stable main" \\
  | sudo tee /etc/apt/sources.list.d/synhub.list
sudo apt update &amp;&amp; sudo apt install synhub</code></pre>

<h2>Fedora / RHEL / openSUSE</h2>
<pre><code>sudo curl -fsSL https://openviewmobile.github.io/synhub/repo/rpm/synhub.repo \\
  -o /etc/yum.repos.d/synhub.repo
sudo dnf install synhub</code></pre>
<p class="sub">Both repositories are GPG-signed — package <em>and</em> index (<code>repo_gpgcheck=1</code>).</p>

<h2>Direct packages</h2>
<table>
 <tr><th>File</th><th>Arch</th><th>Signature</th></tr>
 <tr><td><a href="repo/apt/pool/main/s/synhub/${LATEST_DEB}">${LATEST_DEB}</a></td><td>amd64</td><td class="ok">detached .asc</td></tr>
 <tr><td><a href="repo/rpm/x86_64/${LATEST_RPM}">${LATEST_RPM}</a></td><td>x86_64</td><td class="ok">embedded (rpm 4.x &amp; 6.x)</td></tr>
</table>
<p class="warn">The repository is <strong>x86_64 only</strong>: Flutter does not publish a Linux arm64 SDK, so no arm64 package can be built. On arm64 use the Android build or build from source on an x64 machine.</p>

<h2>Verify before you install</h2>
<pre><code>curl -fsSLO https://github.com/openviewmobile/synhub/releases/latest/download/SHA256SUMS.txt
curl -fsSLO https://github.com/openviewmobile/synhub/releases/latest/download/SHA256SUMS.txt.asc
gpg --keyserver hkps://keys.openpgp.org --recv-keys 9E85497E64A128A1427CD5F8AEF0C14A16617FE8
gpg --verify SHA256SUMS.txt.asc SHA256SUMS.txt &amp;&amp; sha256sum -c SHA256SUMS.txt</code></pre>

<h2>Other platforms</h2>
<p>Android (arm64-v8a), iOS (unsigned), macOS (ad-hoc), Windows (x64) and Web builds ship on the
<a href="https://github.com/openviewmobile/synhub/releases/latest">Releases page</a>; every release is
re-verified by the <code>verify-release</code> workflow with the published key.</p>
<p>macOS and Windows builds are <strong>not</strong> signed with a commercial certificate (none is
purchased, deliberately): on macOS right-click the app &rarr; Open, or run
<code>xattr -dr com.apple.quarantine /Applications/SynHub.app</code>; on Windows choose
<em>More info</em> &rarr; <em>Run anyway</em> at the SmartScreen prompt.</p>

<h2>Links</h2>
<ul>
 <li><a href="keys/synhub-archive-keyring.asc">Signing key</a> (fingerprint 9E85 497E 64A1 28A1 427C D5F8 AEF0 C14A 1661 7FE8)</li>
 <li><a href="repo/rpm/synhub.repo">dnf repo file</a></li>
 <li><a href="https://github.com/openviewmobile/synhub">Source</a> · <a href="https://github.com/openviewmobile/synhub/blob/main/RELEASING.md">Release process</a></li>
</ul>
<footer>Packages are signed with the SynHub project key. Signatures assert build provenance only —
they say nothing about fitness for purpose, and nothing here is supported by Synology.</footer>
</body></html>
HTML

log "仓库树：$OUT"
find "$OUT" -maxdepth 4 -type f | sort | sed 's/^/    /' | head -30
