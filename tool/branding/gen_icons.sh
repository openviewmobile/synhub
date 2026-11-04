#!/usr/bin/env bash
# 用 assets/branding/*.svg 生成 Android 启动图标（legacy mipmap + 自适应图标三层）。
#
# 关键点：**一定要走 svg_to_png.py**，不要直接 qlmanage。
# qlmanage 会把 SVG 合成到不透明白底，前景层会变成一块白板把背景层盖住
# （真机踩过：图标只剩白底 + 图形）。svg_to_png.py 渲两次（白底/黑底）反解出真 alpha。
#
# 改图标流程：改 SVG → 跑本脚本 → flutter build。**不要手改 png**。
set -euo pipefail
cd "$(dirname "$0")/../.."
RES=android/app/src/main/res
SRC=assets/branding
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

render() { # $1=svg $2=px $3=out
  python3 tool/branding/svg_to_png.py "$1" "$3" "$2" >/dev/null
}

# 1) legacy 图标（48..192）：整图缩放（带真 alpha → 圆角外是透明的）
render "$SRC/icon.svg" 1024 "$TMP/icon1024.png"
for spec in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  d=${spec%%:*}; px=${spec##*:}
  mkdir -p "$RES/mipmap-$d"
  sips -z "$px" "$px" "$TMP/icon1024.png" --out "$RES/mipmap-$d/ic_launcher.png" >/dev/null
done

# 2) 自适应图标三层：画布 108dp → 各密度像素
render "$SRC/icon_background.svg" 1024 "$TMP/bg1024.png"
render "$SRC/icon_foreground.svg" 1024 "$TMP/fg1024.png"
render "$SRC/icon_monochrome.svg" 1024 "$TMP/mono1024.png"
for spec in mdpi:108 hdpi:162 xhdpi:216 xxhdpi:324 xxxhdpi:432; do
  d=${spec%%:*}; px=${spec##*:}
  mkdir -p "$RES/drawable-$d"
  sips -z "$px" "$px" "$TMP/bg1024.png"   --out "$RES/drawable-$d/ic_launcher_background.png" >/dev/null
  sips -z "$px" "$px" "$TMP/fg1024.png"   --out "$RES/drawable-$d/ic_launcher_foreground.png" >/dev/null
  sips -z "$px" "$px" "$TMP/mono1024.png" --out "$RES/drawable-$d/ic_launcher_monochrome.png" >/dev/null
done

# 3) 自适应图标 XML（API 26+；round 与普通同一份，系统自己裁）
mkdir -p "$RES/mipmap-anydpi-v26"
for name in ic_launcher ic_launcher_round; do
  cat > "$RES/mipmap-anydpi-v26/$name.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
XML
done


# 4) macOS / iOS / Web / Windows —— 桌面与移动四端共用同一份 brand SVG
#    ★ 为什么要有这一段：r668 用户第一次手动跑 macOS 版，Dock 里是**脚手架自带的
#    蓝色 Flutter F 标**（`macos/.../app_icon_1024.png` 与
#    `ios/.../Icon-App-1024x1024@1x.png` 都是默认图）。脚本只生成 Android 一端
#    ⇒ 其余四端永远停在脚手架默认图标。**图标必须"一处改、五端齐"。**
IOS=ios/Runner/Assets.xcassets/AppIcon.appiconset
MAC=macos/Runner/Assets.xcassets/AppIcon.appiconset
WEB=web

render "$SRC/icon.svg" 1024 "$TMP/icon1024.png"

# iOS：App Store 拒收带 alpha 的图标 ⇒ 合成到品牌深蓝底（#0B2947，即 SVG 背景渐变首色）
python3 tool/branding/flatten_alpha.py "$TMP/icon1024.png" "$TMP/icon1024_opaque.png" 11 41 71
for spec in 20:1 20:2 20:3 29:1 29:2 29:3 40:1 40:2 40:3 60:2 60:3 76:1 76:2 83.5:2 1024:1; do
  sz=${spec%%:*}; sc=${spec##*:}
  px=$(python3 -c "print(int(round($sz*$sc)))")
  sips -z "$px" "$px" "$TMP/icon1024_opaque.png" --out "$IOS/Icon-App-${sz}x${sz}@${sc}x.png" >/dev/null
done

# macOS：Dock 允许 alpha（圆角外透明才符合 macOS 观感）⇒ 用带 alpha 的渲染
for px in 16 32 64 128 256 512 1024; do
  sips -z "$px" "$px" "$TMP/icon1024.png" --out "$MAC/app_icon_${px}.png" >/dev/null
done

# Web：favicon + 常规两档 + maskable 两档
sips -z 16 16 "$TMP/icon1024.png" --out "$WEB/favicon.png" >/dev/null
for px in 192 512; do
  sips -z "$px" "$px" "$TMP/icon1024.png" --out "$WEB/icons/Icon-${px}.png" >/dev/null
  sips -z "$px" "$px" "$TMP/icon1024.png" --out "$WEB/icons/Icon-maskable-${px}.png" >/dev/null
done

# Windows：一个 .ico 塞 6 个尺寸（PNG 压缩条目，Vista+ 支持）
python3 tool/branding/make_ico.py "$TMP/icon1024.png" windows/runner/resources/app_icon.ico 16 32 48 64 128 256

echo "图标已生成：Android / iOS / macOS / Web / Windows 五端（前景/单色层必须是真 alpha）"
