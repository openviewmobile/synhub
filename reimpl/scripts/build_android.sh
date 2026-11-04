#!/usr/bin/env bash
# 构建 Android 版 libsynochatpunch.so 并安装到 Flutter 的 jniLibs。
#
#   ./reimpl/scripts/build_android.sh                  # 默认只编 arm64-v8a
#   ABIS="arm64-v8a armeabi-v7a" ./reimpl/scripts/build_android.sh   # 需要时显式指定
#
# 目前只支持 arm64-v8a —— 32 位与 x86_64 都不做。
#
# 依赖：Android NDK（ANDROID_NDK_HOME 或默认 SDK 路径）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
NDK="${ANDROID_NDK_HOME:-}"
if [[ -z "$NDK" ]]; then
  NDK="$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1)"
fi
[[ -d "$NDK" ]] || { echo "找不到 NDK（设 ANDROID_NDK_HOME）" >&2; exit 1; }

ABIS="${ABIS:-arm64-v8a}"
PLATFORM="${ANDROID_PLATFORM:-android-29}"
JNI="$ROOT/android/app/src/main/jniLibs"

# 宿主机对应的 llvm-strip
case "$(uname -s)" in
  Darwin) HOST=darwin-x86_64 ;;
  Linux)  HOST=linux-x86_64 ;;
  *) echo "不支持的宿主: $(uname -s)" >&2; exit 1 ;;
esac
STRIP="$NDK/toolchains/llvm/prebuilt/$HOST/bin/llvm-strip"

echo "NDK     : $NDK"
echo "ABI     : $ABIS"
echo "Platform: $PLATFORM"
echo

for ABI in $ABIS; do
  BUILD="$ROOT/reimpl/build-android-$ABI"
  cmake -S "$ROOT/reimpl" -B "$BUILD" > /dev/null \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="$PLATFORM" \
    -DCMAKE_BUILD_TYPE=Release
  cmake --build "$BUILD" --target synochatpunch > /dev/null

  SO="$BUILD/libsynochatpunch.so"
  [[ -f "$SO" ]] || { echo "[$ABI] 未产出 .so" >&2; exit 1; }

  BEFORE="$(du -h "$SO" | cut -f1)"
  [[ -x "$STRIP" ]] && "$STRIP" --strip-unneeded "$SO"
  AFTER="$(du -h "$SO" | cut -f1)"

  SYMS="$(nm -D --defined-only "$SO" | grep -c synopunch)"
  mkdir -p "$JNI/$ABI"
  cp "$SO" "$JNI/$ABI/"
  printf '  %-12s %6s → %-6s  导出符号 %s  → jniLibs/%s/\n' "$ABI" "$BEFORE" "$AFTER" "$SYMS" "$ABI"
done

echo
echo "完成。jniLibs 内容："
ls -la "$JNI"/*/libsynochatpunch.so
