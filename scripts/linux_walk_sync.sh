#!/usr/bin/env bash
# 把宿主仓源码同步进 Linux 走查容器（amd64 + Rosetta）。
#
# ★ 为什么必须有这个脚本（第 133 轮的血的教训）：
#   容器里的 `/work/src` 是宿主机目录的**拷贝**（bind 到 $DEST）。
#   直接在宿主机改了 `lib/` 却没同步就跑 `flutter test -d linux`，
#   跑的是**旧代码** —— 我因此把"已经修好的 `_DriveRow` 透明 Material"
#   当成"现网仍在抛 `ListTile background color ...`"，白查了三轮。
#   ⇒ **每次跑走查前先执行本脚本**，它还会打印源码指纹（证明跑的是哪一份）。
#
# ★ 另一个坑：**不能把宿主机的 `linux/flutter/ephemeral` 同步进容器**。
#   宿主上的 `.plugin_symlinks/*` 是**绝对软链**，指向 `$HOME/.pub-cache/...`，
#   在容器里是不存在的路径 ⇒ CMake 直接
#   `add_subdirectory given source "flutter/ephemeral/.plugin_symlinks/xxx/linux" which is not an existing directory`。
#   所以下面显式排除 ephemeral 与 generated_*（这些由容器内的 flutter 自己生成）。
#
# 用法：
#   scripts/linux_walk_sync.sh                 # 默认同步到 $DEST
#   DEST=/somewhere/src scripts/linux_walk_sync.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${DEST:-$HOME/r108_linux_build/src}"

if [ ! -d "$DEST" ]; then
  echo "目标目录不存在：$DEST" >&2
  exit 1
fi

rsync -a --delete "$ROOT/lib/" "$DEST/lib/"
rsync -a "$ROOT/assets/" "$DEST/assets/"
rsync -a "$ROOT/integration_test/" "$DEST/integration_test/"
# linux/ 里只同步我们自己写的（CMakeLists / MyApplication 等），
# 排除 flutter 生成物 —— 见上面第二段注释。
rsync -a "$ROOT/linux/" "$DEST/linux/" \
  --exclude 'flutter/ephemeral' \
  --exclude 'flutter/generated_plugins.cmake' \
  --exclude 'flutter/generated_plugin_registrant.cc' \
  --exclude 'flutter/generated_plugin_registrant.h'

for f in pubspec.yaml pubspec.lock l10n.yaml analysis_options.yaml; do
  [ -f "$ROOT/$f" ] && cp "$ROOT/$f" "$DEST/$f"
done

# 源码指纹：**只哈希内容、且固定 LC_ALL=C**（r349 仪器⑲）。
#   ★ 旧口径有两处"构造性不可比"：
#     ① `xargs shasum` 的输出**带绝对路径** ⇒ 宿主 `/Users/...` 与容器 `/work/src/...`
#        必然算出不同哈希，**永远证明不了"两端同一份代码"**；
#     ② `sort` 的**整理顺序随 locale 变**（宿主 UTF-8 vs 容器 C）⇒ 行序不同 ⇒ 哈希不同。
#   ⇒ 现在剥掉路径、固定 C 排序；**同一份代码在宿主与容器里算出同一个值**（已实测）。
FINGERPRINT="$(
  find "$DEST/lib" "$DEST/integration_test" -type f \( -name '*.dart' -o -name '*.arb' \) \
    | LC_ALL=C sort \
    | xargs shasum | awk '{print $1}' | LC_ALL=C sort | shasum | awk '{print $1}'
)"
echo "同步完成 → $DEST"
echo "源码内容指纹（lib+integration_test 的 dart/arb，路径无关/LC_ALL=C）：$FINGERPRINT"
