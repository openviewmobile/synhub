#!/usr/bin/env bash
# 构建 iOS 版打洞库 **静态库**（r683）。
#
#   ./reimpl/scripts/build_ios.sh --sim        # 模拟器（arm64，Apple Silicon 宿主）
#   ./reimpl/scripts/build_ios.sh --device     # 真机（arm64）
#
# 产物固定落在 `ios/lib/libsynochatpunch.a`（**单一稳定路径**，因为 Runner 的
# `OTHER_LDFLAGS` 里写的是 `-force_load "$(SRCROOT)/lib/libsynochatpunch.a"`）。
# ⇒ 出真机包之前要**先** `--device` 重跑一次；两个架构不能同时存在一个 .a 里
# （要同时支持就得上 xcframework，本仓暂不需要）。
#
# 为什么是静态库：iOS 不允许 App 随便带 dylib（要签名 + 嵌入 + 代码签名一致性），
# 而 Dart FFI 在 iOS 上可以走 `DynamicLibrary.process()` 查**静态链接**进来的符号
# —— 前提是这些符号没被裁掉，所以 Runner 侧必须 `-force_load` 整包链入。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:---sim}"
case "$MODE" in
  --sim)    SDK=iphonesimulator ;;
  --device) SDK=iphoneos ;;
  *) echo "用法: $0 [--sim|--device]" >&2; exit 2 ;;
esac

BUILD="$ROOT/reimpl/build-ios-$SDK"
OUT="$ROOT/ios/lib"
mkdir -p "$OUT"

echo "SDK   : $SDK"
echo "BUILD : $BUILD"
echo "OUT   : $OUT/libsynochatpunch.a"

cmake -S "$ROOT/reimpl" -B "$BUILD" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$SDK" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DCMAKE_BUILD_TYPE=Release > /dev/null

# 把所有依赖的静态库都编出来（`synochatpunch` 只是薄薄一层 C ABI 壳，
# 真正干活的是 relay/exchange/protocol/socket/udt4/discovery）。
cmake --build "$BUILD" --target synochatpunch punch_relay punch_exchange \
  punch_protocol punch_socket punch_discovery udt4 -j 8 > /dev/null

# ★ 合并成**一个** archive：Runner 侧只 `-force_load` 一个 .a，
#   否则 `_synopunch_new` 里引用的 relay/exchange 符号会在链接期缺失
#   （静态库不会自动带上它依赖的静态库）。
libtool -static -o "$OUT/libsynochatpunch.a" \
  "$BUILD/libsynochatpunch.a" \
  "$BUILD/libpunch_relay.a" \
  "$BUILD/libpunch_exchange.a" \
  "$BUILD/libpunch_protocol.a" \
  "$BUILD/libpunch_socket.a" \
  "$BUILD/libpunch_discovery.a" \
  "$BUILD/libudt4.a" > /dev/null

# 自检：至少要有 C ABI 的入口符号（否则 `-force_load` 也救不了 Dart）。
# ★ 先把符号表取一次到变量里：`set -o pipefail` 下 `nm | grep -q` 会因为
#   `grep -q` 提前退出把 `nm` 打成 SIGPIPE(141)，于是"符号明明在"也判成缺
#   （r683 踩过：`✗ 产物缺少符号: _synopunch_start` 而 nm 里就有一条）。
SYMS="$(nm -gU "$OUT/libsynochatpunch.a" || true)"
SYM=$(printf '%s\n' "$SYMS" | grep -c "_synopunch_new" || true)
if [[ "$SYM" -eq 0 ]]; then
  echo "✗ 产物里没有 _synopunch_new（C ABI 没编进去）" >&2
  exit 1
fi
# 依赖侧的符号也必须在（`_synopunch_start` 要对 relay/exchange 的符号求值；
# 只带 punch_c.o 的 archive 在链接期会报 undefined，本仓 r683 踩过一次）。
# ★ `printf | grep -q` 在 pipefail 下会因 grep 提前退出把 printf 打成 SIGPIPE(141)
#   ⇒ 整条判成"缺符号"（r683 踩过一次，r684 又踩：`_synopunch_poll` 明明在表里）。
#   改 here-string：写端是 bash 自己，不会 SIGPIPE。
for s in _synopunch_start _synopunch_tcp_port _synopunch_poll \
         _synopunch_prepare _synopunch_udt_port _synopunch_await_peer \
         _synopunch_start_engine; do
  if ! grep -q -- "$s" <<<"$SYMS"; then
    echo "✗ 产物缺少符号: $s" >&2
    exit 1
  fi
done
echo "✓ $(basename "$OUT/libsynochatpunch.a") $(stat -f%z "$OUT/libsynochatpunch.a") bytes, "\
"目标文件数=$(ar t "$OUT/libsynochatpunch.a" | grep -c '\.o$'), relay 符号数=$(printf '%s\n' "$SYMS" | grep -c relay)"
