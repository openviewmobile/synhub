#!/usr/bin/env bash
# r730：把 `flutter build linux --release` 的 bundle 打成 **rpm**（Fedora / RHEL / openSUSE 系）。
#
# 为什么要有它：deb 只覆盖 Debian 系；同一份 bundle 在 Fedora/RHEL 上没有任何可安装形态，
# 用户只能解 tar.gz 手放目录。产物必须做到"能装、能从菜单起、能卸干净"，和 deb 一致：
#   装 → /opt/synhub/（bundle 原样）、/usr/bin/synhub、.desktop、图标
#   卸 → 上述四条全清（%files 显式列全，不留孤儿）
#
# 用法（在 **Linux** 里跑，宿主机没有 rpmbuild）：
#   scripts/build_linux_rpm.sh              # 只出包 → build/linux_rpm/synhub-<ver>-1.<arch>.rpm
#   scripts/build_linux_rpm.sh --verify     # 出包 + rpm -qip/-qlp/-qpR 摘要
#
# 依赖：rpm（提供 rpmbuild）。Fedora: `dnf install rpm-build`；
#       Debian/Ubuntu: `apt-get install rpm`（本仓 CI 用后者）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_ID="com.openviewai.synhub"
PKG="synhub"
VERSION="$(awk '/^version:/{print $2}' pubspec.yaml | cut -d+ -f1)"

die() { echo "[rpm] $*" >&2; exit 1; }

# bundle 路径按**宿主架构**取（deb 脚本同一坑：写死 arm64 在 x64 runner 上必死）
case "$(uname -m)" in
  x86_64|amd64)  LINUX_ARCH=x64;   RPM_ARCH=x86_64 ;;
  aarch64|arm64) LINUX_ARCH=arm64; RPM_ARCH=aarch64 ;;
  *) die "不支持的 Linux 架构：$(uname -m)" ;;
esac

BUNDLE="build/linux/$LINUX_ARCH/release/bundle"
OUT="build/linux_rpm"
[[ -n "$VERSION" ]] || die "pubspec.yaml 里读不到 version"
[[ -x "$BUNDLE/synhub" ]] || die "bundle 里没有可执行文件：$BUNDLE/synhub（先 flutter build linux --release）"
command -v rpmbuild >/dev/null || die "没有 rpmbuild（Fedora: dnf install rpm-build；Ubuntu: apt-get install rpm）"

export PATH="${PATH:-}"

TOPDIR="$(mkdir -p "$OUT/rpmbuild" && cd "$OUT/rpmbuild" && pwd)"
rm -rf "$TOPDIR"
mkdir -p "$TOPDIR"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

# 图标：和 deb 一样优先用仓库里的品牌图；没有就不编一个假的
ICON_LINE=""
for c in assets/branding/icon_512.png assets/branding/icon.png web/icons/Icon-512.png; do
  if [[ -f "$c" ]]; then
    ICON_LINE="install -Dm644 %{_sourcedir}/icon.png %{buildroot}/usr/share/icons/hicolor/256x256/apps/$APP_ID.png"
    cp "$c" "$TOPDIR/SOURCES/icon.png"
    break
  fi
done

# 打包时不生成 debuginfo 包：bundle 里的 .so 是上游预编译的，拆 debuginfo 只会多一个空包
SPEC="$TOPDIR/SPECS/$PKG.spec"
cat > "$SPEC" <<SPECEOF
%global debug_package %{nil}
# ★ 只关掉 strip，**不关** __os_install_post：后者还负责生成 ELF 依赖（libgtk-3.so.0 之类）。
#   第一版把 __os_install_post 整个置空，实测 `rpm -qpR` 里一条库依赖都没有 ——
#   那样装到没装 GTK 的机器上会"装成功、起不来"，比少个包更坏。
#   bundle 里的 .so 是上游预编译产物（含 Dart AOT 快照），不该被本地 strip 动。
%global __brp_strip %{nil}

Name:           $PKG
Version:        $VERSION
Release:        1
Summary:        Synology NAS desktop client (Flutter/Linux)
License:        Apache-2.0
URL:            https://github.com/openviewmobile/synhub
Packager:       SynHub <noreply@openviewai.com>
BuildArch:      $RPM_ARCH
# ★ 依赖按 **soname** 写，不按包名：
#   ① 包名各家不同（Fedora 是 gtk3/libsecret，RHEL 同名，openSUSE 又有差异），
#      而 `mpv-libs` 在 Fedora 还要开 RPM Fusion —— 写包名等于给用户加门槛；
#   ② 更关键：rpm 的 ELF 依赖生成器**不扫 /opt**（实测：同一个 ELF 装到 /usr/bin 会
#      生成 libc/libselinux 依赖，装到 /opt 一条都没有）。bundle 就在 /opt，所以自动
#      推导对我们等于没有，必须显式声明 —— 否则"装成功、起不来"。
Requires:       libgtk-3.so.0()(64bit)
Requires:       libsecret-1.so.0()(64bit)
Requires:       libmpv.so.2()(64bit)
# `pdftoppm`（poppler-utils）在运行时是**起了进程**用的：缺了不是起不来，
# 而是 PDF 预览静默没有图。建议而不强制（suggests），免得为了让 PDF 好看
# 把整个 poppler 拖成硬依赖。
Suggests:       poppler-utils
Provides:       $PKG = %{version}-%{release}

%description
File Station / Drive / Photos / Chat / Audio Station / Notes clients,
QuickConnect login, media playback (media_kit/libmpv), PDF (poppler),
MPRIS media integration.

Build: Flutter 3.47.4. This package bundles the release bundle under /opt/%{name}.

%prep
# 无源码可解（bundle 由调用方先 build），%prep 留空

%build
# 同上

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}/opt/$PKG
cp -a "$ROOT/$BUNDLE/." %{buildroot}/opt/$PKG/
mkdir -p %{buildroot}/usr/bin %{buildroot}/usr/share/applications
ln -sfn /opt/$PKG/$PKG %{buildroot}/usr/bin/$PKG
cat > %{buildroot}/usr/share/applications/$APP_ID.desktop <<DESK
[Desktop Entry]
Type=Application
Name=SynHub
Comment=Synology NAS client
Exec=/usr/bin/$PKG
Icon=$APP_ID
Terminal=false
Categories=Network;FileTransfer;
StartupWMClass=$APP_ID
DESK
chmod 0644 %{buildroot}/usr/share/applications/$APP_ID.desktop
$ICON_LINE

%post
# 只有存在工具时才刷新缓存，缺工具不是安装失败
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || :
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || :
fi

%postun
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || :
fi

%files
%dir /opt/$PKG
/opt/$PKG
/usr/bin/$PKG
/usr/share/applications/$APP_ID.desktop
$( [[ -n "$ICON_LINE" ]] && echo "/usr/share/icons/hicolor/256x256/apps/$APP_ID.png" )

%changelog
* $(LC_ALL=C date '+%a %b %d %Y') SynHub <noreply@openviewai.com> - $VERSION-1
- Release $VERSION
SPECEOF

echo "[rpm] spec: $SPEC"
rpmbuild -bb \
  --define "_topdir $TOPDIR" \
  --define "_sourcedir $TOPDIR/SOURCES" \
  --define "_rpmdir $TOPDIR/RPMS" \
  --define "_build_name_fmt %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm" \
  "$SPEC" 2>&1 | sed 's/^/    /'

RPM="$(find "$TOPDIR/RPMS" -name '*.rpm' | head -1)"
[[ -n "$RPM" ]] || die "rpmbuild 没有产物"
mv "$RPM" "$OUT/"
RPM="$OUT/$(basename "$RPM")"

echo "[rpm] 产物：$RPM（$(du -h "$RPM" | cut -f1)）"
sha256sum "$RPM"

if [[ "${1:-}" == "--verify" ]]; then
  echo "--- rpm -qip ---"
  rpm -qip "$RPM"
  echo "--- rpm -qpR（自动推导的 ELF 依赖） ---"
  rpm -qpR "$RPM" | sort | sed 's/^/    /'
  echo "--- rpm -qlp ---"
  rpm -qlp "$RPM" | head -20
  echo "    …（共 $(rpm -qlp "$RPM" | wc -l | tr -d ' ') 条）"
fi
