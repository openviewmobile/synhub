#!/usr/bin/env bash
# arm64 release 构建（**唯一受支持的构建方式**）。
#
# ## 为什么需要脚本
#
# `integration_test` 是 dev_dependency，但 Flutter 会把它写进
# `android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java`，
# 而 release 构建里没有它的 Android 源码 ⇒
# `compileReleaseJavaWithJavac` 报 `package dev.flutter.plugins.integration_test does not exist`。
#
# ⚠️ **只删注册器文件没用**：构建期会被重新生成（实测时间戳从 15:17 变 15:18）。
# 唯一有效做法是构建前把 `integration_test` 从 pubspec 临时注释掉，构建后恢复。
#
# 详见 `docs/release-build-integration-test.md`。
#
# ## 用法
#   ./scripts/build_arm64_release.sh
#
# 产物：build/app/outputs/flutter-apk/app-release.apk（并打印 sha256）

set -euo pipefail

cd "$(dirname "$0")/.."
export PATH="<flutter-sdk>/bin:$PATH"

PUBSPEC="pubspec.yaml"
BACKUP="$(mktemp -t pubspec_before_build.XXXXXX.yaml)"
cp "$PUBSPEC" "$BACKUP"

# 无论成功失败都要恢复 pubspec（否则真机验收用例会找不到 integration_test）
restore() {
  cp "$BACKUP" "$PUBSPEC"
  echo "==> 已恢复 $PUBSPEC"
}
trap restore EXIT

if ! grep -qE '^\s*integration_test:' "$PUBSPEC"; then
  echo "!! 找不到未注释的 integration_test，pubspec 可能已被改过；仍继续。"
fi

# 临时注释掉 integration_test 那两行（key + sdk: flutter）
python3 - "$PUBSPEC" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s2 = re.sub(
    r'^(\s*)integration_test:\n(\s*)sdk: flutter\n',
    lambda m: (f'{m.group(1)}# integration_test:   # 构建期临时注释，见 '
               f'docs/release-build-integration-test.md\n'
               f'{m.group(2)}#   sdk: flutter\n'),
    s, count=1, flags=re.M)
if s2 == s:
    print('!! 未匹配到 integration_test 段落（可能已注释）')
open(p, 'w', encoding='utf-8').write(s2)
PY

echo "==> flutter pub get"
flutter pub get >/dev/null

echo "==> 删除可能残留的 GeneratedPluginRegistrant.java"
rm -f android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java

# ── 签名预检（W0-4 / r352）────────────────────────────────────────────
# 发布密钥在**仓库外**：$HOME/keystores/synhub-release.jks
# 口令同样在仓库外（0600）：$HOME/keystores/synhub-release.properties
# 若环境里已给 SYNHUB_KEYSTORE_PASSWORD 就用环境的（CI 口径）。
#
# ★ 默认**不**自动启用发布密钥：真机验收包一直是 debug 签名，
#   换签名会让 `adb install -r` 直接 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`
#   （只能卸载重装 ⇒ 清数据、丢登录，见 AGENTS §2.0.1）。
# ★ 默认**不**用发布密钥（保持验收包与设备上已装包同密钥，可 `-r` 覆盖安装）；
#   要出**可发布**产物必须显式 opt-in：`SYNHUB_SIGN=release`（或 `--release-signed`）。
SIGN_MODE="debug"
for a in "$@"; do [ "$a" = "--release-signed" ] && SIGN_MODE="release"; done
[ "${SYNHUB_SIGN:-}" = "release" ] && SIGN_MODE="release"

KS_ENV_FILE="$HOME/keystores/synhub-release.properties"
if [ "$SIGN_MODE" = "release" ] && [ -z "${SYNHUB_KEYSTORE_PASSWORD:-}" ] && [ -f "$KS_ENV_FILE" ]; then
  # 文件是 shell 可 source 的 KEY=VALUE（0600，仓库外）
  # shellcheck disable=SC1090
  . "$KS_ENV_FILE"
  export SYNHUB_KEYSTORE_FILE "${SYNHUB_KEYSTORE_PASSWORD}" "${SYNHUB_KEY_ALIAS}"
fi
if [ "$SIGN_MODE" = "release" ]; then
  : "${SYNHUB_KEYSTORE_PASSWORD:?SYNHUB_SIGN=release 但没给口令（见 $HOME/keystores/synhub-release.properties）}"
  : "${SYNHUB_KEYSTORE_FILE:?给了口令但没给 SYNHUB_KEYSTORE_FILE}"
  : "${SYNHUB_KEY_ALIAS:?没给 SYNHUB_KEY_ALIAS}"
  [ -f "$SYNHUB_KEYSTORE_FILE" ] || { echo "!! keystore 不存在：$SYNHUB_KEYSTORE_FILE"; exit 1; }
  export SYNHUB_KEYSTORE_FILE SYNHUB_KEYSTORE_PASSWORD SYNHUB_KEY_ALIAS
  export SYNHUB_KEY_PASSWORD="${SYNHUB_KEY_PASSWORD:-$SYNHUB_KEYSTORE_PASSWORD}"
  echo "==> 签名：**发布密钥** ${SYNHUB_KEYSTORE_FILE}（alias=${SYNHUB_KEY_ALIAS}）"
  # ★ DA105（r458）：这句原来是**无条件**打印的"签名不同 ⇒ 不能 -r"，r452 起验收机
  #   装的就是发布签名包 ⇒ 它是**假警告**，照做会去卸载重装（清数据、丢登录）。
  #   现在：这里只说规则，**真核对**放到收尾（读设备上 base.apk 的证书摘要逐字比对）。
  echo "    （只有证书真不同才需要卸载重装；收尾会跟设备上已装包**逐字核对证书摘要**）"
else
  unset SYNHUB_KEYSTORE_PASSWORD SYNHUB_KEYSTORE_FILE SYNHUB_KEY_ALIAS SYNHUB_KEY_PASSWORD
  echo "==> 签名：**debug**（默认档，与验收设备已装包同密钥）"
  echo "    要出可发布产物：SYNHUB_SIGN=release ./scripts/build_arm64_release.sh"
fi

# 额外 dart-define（评审用：例如 SYNHUB_EXTRA_DEFINES="--dart-define=SYNHUB_DEV_TOOLS=true"
# 让临时页面在 release 包里也注册；**发布产物不许带**，默认空）。
: "${SYNHUB_EXTRA_DEFINES:=}"
if [ -n "$SYNHUB_EXTRA_DEFINES" ]; then
  echo "==> 额外 dart-define：$SYNHUB_EXTRA_DEFINES"
fi
echo "==> flutter build apk --release --target-platform android-arm64"
# shellcheck disable=SC2086
flutter build apk --release --target-platform android-arm64 $SYNHUB_EXTRA_DEFINES

APK="build/app/outputs/flutter-apk/app-release.apk"
echo
echo "==> 产物：$APK"
ls -la "$APK"
shasum -a 256 "$APK"

# 签名验真：不能只看 Gradle 有没有打印，要读产物里的签名者（AGENTS §2.0.31）
# ★ 原来这里写死 `$HOME/Library/Android/sdk`（只对 macOS 成立）。在 Linux runner 上
#   `ls` 找不到会返回 2，而 `VAR="$(ls ...)"` 在 `set -e` 下**直接终止脚本** ——
#   release #2 的 android job 就是这样以 exit 2 挂在收尾（APK 本身已经编好了）。
find_apksigner() {
  if command -v apksigner >/dev/null 2>&1; then command -v apksigner; return 0; fi
  local sdk p
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    [ -n "$sdk" ] || continue
    p="$(ls -d "$sdk"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1 || true)"
    if [ -n "$p" ]; then printf '%s\n' "$p"; return 0; fi
  done
  return 0
}
APKSIGNER="$(find_apksigner)"
if [ -n "$APKSIGNER" ]; then
  echo "==> apksigner verify --print-certs"
  "$APKSIGNER" verify --print-certs "$APK" 2>/dev/null | sed -n '1,6p'
else
  echo "!! 找不到 apksigner，跳过签名者核对"
fi

# ★ DA105（r458）：与设备上已装包**真核对**证书摘要（有且只有 1 台在线设备时）。
#   判据取产物（apksigner 读证书），不看 Gradle 打印；同摘要 ⇒ `adb install -r` 覆盖装不掉登录。
if [ -n "$APKSIGNER" ] && command -v adb >/dev/null 2>&1; then
  DEV_COUNT="$(adb devices 2>/dev/null | sed '1d' | awk '$2=="device"' | wc -l | tr -d ' ')"
  if [ "$DEV_COUNT" = "1" ]; then
    SERIAL="$(adb devices 2>/dev/null | sed '1d' | awk '$2=="device"{print $1}')"
    RPATH="$(adb -s "$SERIAL" shell pm path com.openviewai.synhub 2>/dev/null | tr -d '\r' | sed -n 's/^package://p' | head -1)"
    if [ -n "$RPATH" ]; then
      TMPD="$(mktemp -d)"
      if adb -s "$SERIAL" pull "$RPATH" "$TMPD/base.apk" >/dev/null 2>&1; then
        NEW_SHA="$("$APKSIGNER" verify --print-certs "$APK" 2>/dev/null | sed -n 's/.*certificate SHA-256 digest: //p' | head -1)"
        OLD_SHA="$("$APKSIGNER" verify --print-certs "$TMPD/base.apk" 2>/dev/null | sed -n 's/.*certificate SHA-256 digest: //p' | head -1)"
        if [ -n "$NEW_SHA" ] && [ "$NEW_SHA" = "$OLD_SHA" ]; then
          echo "==> 设备同签名核对：✅ 设备上已装包与本次产物**同一证书**（${NEW_SHA}）⇒ 可 adb install -r（不掉登录）"
        else
          echo "==> 设备同签名核对：⚠️ 证书**不同**（新 ${NEW_SHA:-取不到} / 设备 ${OLD_SHA:-取不到}）⇒ -r 会 INSTALL_FAILED_UPDATE_INCOMPATIBLE，需卸载重装"
        fi
        rm -rf "$TMPD"
      else
        echo "==> 设备同签名核对：跳过（拉不到设备上的 base.apk）"
      fi
    else
      echo "==> 设备同签名核对：跳过（设备上没装 com.openviewai.synhub）"
    fi
  else
    echo "==> 设备同签名核对：跳过（在线设备数=${DEV_COUNT}，需恰好 1 台）"
  fi
fi
