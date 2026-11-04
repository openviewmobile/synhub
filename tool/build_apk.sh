#!/usr/bin/env bash
# 打 Android 包（**只出 arm64-v8a**）。
#
#   ./tool/build_apk.sh            # release（默认）
#   ./tool/build_apk.sh debug      # debug
#   ./tool/build_apk.sh release --split-debug-info=build/symbols
#
# 为什么需要这个脚本：
#   `flutter build apk` 不带设备时，默认 target-platform =
#   `android-arm,android-arm64,android-x64` —— 会白编两份用不上的
#   `libapp.so`（AOT 很慢）。APK 里当然不会带（`android/app/build.gradle.kts`
#   的 `packaging.jniLibs.excludes` 兜着），但构建时间和中间产物是实打实的。
#   带上 `--target-platform=android-arm64` 就只编一份。
#
# ─────────────────────────────────────────────────────────────────────────
# 为什么 release 分支还要「临时屏蔽 integration_test」：
#
#   `integration_test` 是 dev_dependencies（真机验收用）。它带一个 Android
#   plugin（`dev.flutter.plugins.integration_test.IntegrationTestPlugin`），
#   flutter tool 会把它写进
#       android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java
#   （该文件是**生成物**，见 `android/.gitignore`，不在版本控制里）。
#
#   debug/profile 构建会**故意**把 dev 依赖的 plugin 也写进 registrant；而
#   release 构建的 Gradle 侧（`flutter_tools/gradle/.../PluginHandler.kt`）又会
#   **故意不把 dev 依赖加进 releaseApi**。两者本身是配套的：release 时 flutter
#   tool 会用 `injectPlugins(releaseMode: true)` 把 dev 依赖从 registrant 里去掉。
#
#   问题出在**生成物被别的东西覆盖/残留**的时候：
#     * 任何一次 debug/profile 构建（`flutter run`、`flutter test integration_test/
#       -d <设备>`、`flutter pub get`）都会把 dev 依赖写进这个 registrant；
#     * release 构建里 Gradle 只会编译 flutter tool 事先生成的 registrant，
#       自己**不会**重新生成它（实测 `./gradlew :app:assembleRelease` 在文件缺失时
#       直接不生成、照样“成功”，说明生成完全靠 flutter tool）；
#     * 一旦 Gradle 真正执行 `compileReleaseJavaWithJavac`（清过 build/、或 javac
#       中间产物失效时），它读到的就是那份含 integration_test 的 registrant，
#       于是报：
#           error: package dev.flutter.plugins.integration_test does not exist
#       构建失败。多个并行批次同时跑 debug 测试/release 构建时尤其容易踩到。
#
#   以前子代理的绕法是「手工把 integration_test 从 dev_dependencies 删掉 →
#   flutter pub get → 构建 → 再手工恢复」，极易忘记恢复、每个批次都要重踩。
#
#   本脚本把这件事自动化：release 构建前把 dev_dependencies 里的 integration_test
#   临时移出并 `flutter pub get`，这样 flutter tool 无论何时生成 registrant 都
#   不可能带上 integration_test（对「生成物被并发覆盖」也成立）；构建结束（无论
#   成功、失败还是 Ctrl-C）由 EXIT/INT/TERM trap **保证**恢复 pubspec.yaml，
#   并用「内容比对 + md5」断言恢复成功。
#
#   影响面：
#     * 只动脚本 + 临时改 `pubspec.yaml`；**不碰** lib/**、test/**、ARB、android/**。
#     * 只在 MODE=release 时启用；debug/profile 不加屏蔽（它们本来就需要 dev 依赖）。
#     * 构建期间 pubspec 暂时没有 integration_test —— 这段时间里**不要**在同一
#       个工作区并发跑 `flutter test integration_test/`（会解析不到该依赖）。
#       为降低并发自伤，脚本用 `.dart_tool/build_apk.lock` 串行化自身。
#     * 异常中断（kill -9 等 trap 来不及跑）下次运行会先自动恢复（见 SHIELD_DIR）。
# ─────────────────────────────────────────────────────────────────────────
#
# 不需要这个脚本的场景：
#   * `flutter run -d <设备>` / `flutter test integration_test/ -d <设备>`：
#     flutter tool 自己按设备 ABI 构建（`android_device.dart:576`
#     `targetArchs: [androidArch]`），本来就只编 arm64。
set -euo pipefail

MODE="release"
case "${1:-}" in
  release | debug | profile)
    MODE="$1"
    shift
    ;;
  "") ;;
  *)
    echo "用法: $0 [release|debug|profile] [其它 flutter build apk 参数…]" >&2
    exit 2
    ;;
esac

cd "$(dirname "$0")/.."

PUBSPEC="pubspec.yaml"
LOCKFILE="pubspec.lock"
SHIELD_DIR=".dart_tool/build_apk_shield"
SHIELD_BACKUP="$SHIELD_DIR/pubspec.yaml.backup"
LOCK_DIR=".dart_tool/build_apk.lock"

die() {
  echo "build_apk.sh: $*" >&2
  exit 1
}

# 兼容 macOS（md5 -q）与 Linux（md5sum）。
file_hash() {
  if command -v md5 >/dev/null 2>&1; then
    md5 -q "$1"
  else
    md5sum "$1" | awk '{print $1}'
  fi
}

# 让脚本在没把 flutter 加进 PATH 的 shell 里也能跑：回退用 android/local.properties
# 里的 flutter.sdk。找不到就明确报错，而不是神秘地 command not found。
if ! command -v flutter >/dev/null 2>&1; then
  FLUTTER_SDK=""
  if [ -f android/local.properties ]; then
    FLUTTER_SDK=$(sed -n 's/^flutter\.sdk=//p' android/local.properties | tail -1)
  fi
  if [ -n "$FLUTTER_SDK" ] && [ -x "$FLUTTER_SDK/bin/flutter" ]; then
    export PATH="$FLUTTER_SDK/bin:$PATH"
    echo "== 未在 PATH 找到 flutter，回退到 android/local.properties: $FLUTTER_SDK/bin/flutter =="
  fi
fi
command -v flutter >/dev/null 2>&1 || die "找不到 flutter，请先把 flutter 加进 PATH"

SHIELD_ACTIVE=0
ORIG_PUBSPEC_HASH=""
ORIG_LOCK_HASH=""

restore_pubspec() {
  [ "$SHIELD_ACTIVE" -eq 1 ] || return 0
  SHIELD_ACTIVE=0
  cp -f "$SHIELD_BACKUP" "$PUBSPEC"
  echo "== 恢复 pubspec.yaml（屏蔽 integration_test 结束）=="
  # 恢复 lock / .dart_tool / .flutter-plugins-dependencies 等派生状态。
  flutter pub get >/dev/null 2>&1 || echo "build_apk.sh: 警告：恢复后的 flutter pub get 失败，请手动跑一次" >&2

  local ph lh
  ph=$(file_hash "$PUBSPEC")
  lh=$(file_hash "$LOCKFILE")
  if [ "$ph" != "$ORIG_PUBSPEC_HASH" ]; then
    echo "build_apk.sh: 严重错误：pubspec.yaml 恢复后与原始内容不一致！" >&2
    echo "  期望 md5=${ORIG_PUBSPEC_HASH}  实际 md5=${ph}" >&2
    echo "  备份仍在：${SHIELD_BACKUP}" >&2
    return 1
  fi
  if [ "$lh" != "$ORIG_LOCK_HASH" ]; then
    echo "build_apk.sh: 警告：pubspec.lock 与构建前不一致（期望 ${ORIG_LOCK_HASH}，实际 ${lh}）" >&2
  else
    echo "== 恢复校验通过：pubspec.yaml md5=${ph}，pubspec.lock md5=${lh}（均与构建前逐字一致）=="
  fi
  rm -f "$SHIELD_BACKUP"
  rmdir "$SHIELD_DIR" 2>/dev/null || true
}

release_lock() {
  rm -rf "$LOCK_DIR"
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  # restore_pubspec 里可能还有 set -u 相关写法；清理阶段绝不能再因它中断，
  # 否则锁和备份会残留。
  set +eu
  restore_pubspec || true
  release_lock
  exit "$rc"
}

# 串行化多个 build_apk.sh（它们会临时改同一份 pubspec.yaml）。
acquire_lock() {
  local waited=0 p
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    p=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then
      echo "== 清理残留的构建锁（pid=$p 已不存在）=="
      rm -rf "$LOCK_DIR"
      continue
    fi
    [ "$waited" -ge 1800 ] && die "等待构建锁超时（另一个 build_apk.sh 已运行超过 30 分钟）"
    echo "== 另一个 build_apk.sh 正在运行，等待构建锁…（$waited s）=="
    sleep 2
    waited=$((waited + 2))
  done
  echo $$ >"$LOCK_DIR/pid"
}

trap cleanup EXIT INT TERM
acquire_lock

# 上次异常中断（trap 没来得及跑）会留下备份：先把它恢复掉再继续。
if [ -f "$SHIELD_BACKUP" ]; then
  echo "== 检测到上次异常中断遗留的屏蔽备份，先恢复 pubspec.yaml =="
  cp -f "$SHIELD_BACKUP" "$PUBSPEC"
  rm -f "$SHIELD_BACKUP"
  flutter pub get >/dev/null 2>&1 || true
fi

if [ "$MODE" = "release" ]; then
  mkdir -p "$SHIELD_DIR"
  ORIG_PUBSPEC_HASH=$(file_hash "$PUBSPEC")
  ORIG_LOCK_HASH=$(file_hash "$LOCKFILE")
  cp -f "$PUBSPEC" "$SHIELD_BACKUP"
  # 先置位再改文件：只要备份已生成，任何失败都会走 trap 恢复。
  SHIELD_ACTIVE=1

  python3 - "$PUBSPEC" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    lines = fh.read().split("\n")

out = []
removed = 0
i = 0
while i < len(lines):
    if re.match(r"^  integration_test:\s*$", lines[i]):
        # 连带删掉紧贴着它、且提到 integration_test 的注释行
        while out and out[-1].lstrip().startswith("#") and "integration_test" in out[-1]:
            out.pop()
        i += 1
        # 删掉该 key 的缩进子块（integration_test 只有一行 `sdk: flutter`）
        while i < len(lines) and lines[i].strip() and lines[i].startswith("    "):
            i += 1
        removed += 1
        continue
    out.append(lines[i])
    i += 1

if removed == 0:
    sys.stderr.write(
        "build_apk.sh: 警告：dev_dependencies 里没找到 integration_test，屏蔽为空操作\n"
    )
else:
    sys.stderr.write(f"build_apk.sh: 已临时移除 dev_dependencies.integration_test（{removed} 处）\n")

with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(out))
PY

  echo "== release 构建：已临时移除 integration_test，重新解析依赖 =="
  flutter pub get
fi

flutter build apk "--$MODE" --target-platform=android-arm64 "$@"
