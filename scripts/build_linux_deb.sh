#!/usr/bin/env bash
# r701 · B7：把 `flutter build linux --release` 的 bundle 打成 **deb** 并（可选）安装验证。
#
# 为什么要有这个脚本：B7 原来写"打包与签名不在本轮范围"——本轮把它当**能力**来做：
# 产物必须是"系统能装、能从菜单路径起、卸载干净"的东西，而不是一个 build 目录。
#
# 用法（在**Linux 容器/机器**里跑，宿主机没有 dpkg）：
#   scripts/build_linux_deb.sh            # 只出包 → build/linux_deb/synhub_<ver>_arm64.deb
#   scripts/build_linux_deb.sh --install  # 出包 + dpkg -i + 用 /usr/bin/synhub 起一次
#   scripts/build_linux_deb.sh --purge    # 卸载并清理
#
# 依赖：dpkg-deb、rsync、flutter（bundle 由调用方先 build，或本脚本代跑）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_ID="com.openviewai.synhub"
PKG="synhub"
VERSION="$(awk '/^version:/{print $2}' pubspec.yaml | cut -d+ -f1)"
BUNDLE="build/linux/arm64/release/bundle"
OUT="build/linux_deb"
STAGE="$OUT/stage"

die() { echo "[deb] $*" >&2; exit 1; }

if [[ "${1:-}" == "--purge" ]]; then
  dpkg -r "$PKG" >/dev/null 2>&1 || true
  rm -rf "/opt/$PKG"
  echo "[deb] 已卸载（/opt/$PKG 已清）"
  exit 0
fi

need_build=0
[[ -d "$BUNDLE" ]] || need_build=1
if [[ $need_build == 1 ]]; then
  echo "[deb] 没有 release bundle，先 build…"
  export PATH="/opt/flutter/bin:$PATH"
  flutter build linux --release
fi
[[ -x "$BUNDLE/synhub" ]] || die "bundle 里没有可执行文件：$BUNDLE/synhub"

ARCH="$(dpkg --print-architecture)"
[[ -n "$VERSION" ]] || die "pubspec.yaml 里读不到 version"

rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/opt/$PKG" "$STAGE/usr/bin" \
         "$STAGE/usr/share/applications" "$STAGE/usr/share/icons/hicolor/256x256/apps"

# bundle 整体进 /opt/<pkg>
rsync -a "$BUNDLE/" "$STAGE/opt/$PKG/"

# 启动器：绝对路径软链（不写 shell 包装，避免 PATH 里再找 flutter）
ln -s "/opt/$PKG/synhub" "$STAGE/usr/bin/$PKG"

# 图标：优先用仓库里的品牌图，没有就跳过（不编一个假图标）
ICON_SRC=""
for c in assets/branding/icon_512.png assets/branding/icon.png web/icons/Icon-512.png; do
  [[ -f "$c" ]] && { ICON_SRC="$c"; break; }
done
if [[ -n "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$STAGE/usr/share/icons/hicolor/256x256/apps/$APP_ID.png"
fi

cat > "$STAGE/usr/share/applications/$APP_ID.desktop" <<DESK
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

SIZE_KB="$(du -sk "$STAGE" | awk '{print $1}')"
cat > "$STAGE/DEBIAN/control" <<CTRL
Package: $PKG
Version: $VERSION
Section: net
Priority: optional
Architecture: $ARCH
Installed-Size: $SIZE_KB
Maintainer: SynHub <noreply@openviewai.com>
Description: Synology NAS desktop client (Flutter/Linux)
 File Station / Drive / Photos / Chat / Audio Station / Notes clients,
 QuickConnect login, media playback (media_kit/libmpv), PDF (poppler),
 MPRIS media integration.
Depends: libgtk-3-0, libmpv2 | libmpv1, libsecret-1-0
CTRL

DEB="$OUT/synhub_${VERSION}_${ARCH}.deb"
mkdir -p "$OUT"
dpkg-deb --root-owner-group --build "$STAGE" "$DEB" >/dev/null
echo "[deb] 产物：$DEB"
dpkg-deb --info "$DEB" | sed -n '1,12p'

if [[ "${1:-}" == "--install" ]]; then
  dpkg -i "$DEB" >/dev/null
  echo "[deb] 已安装：$(dpkg-query -W -f='${Package} ${Version} ${Status}' "$PKG")"
  echo "[deb] /usr/bin/$PKG → $(readlink -f "/usr/bin/$PKG")"
fi
