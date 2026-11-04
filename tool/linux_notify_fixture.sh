#!/usr/bin/env bash
# r693 · 容器里的"桌面通知消费方"装置（Linux 通知能力验证用）
#
# 要证的**不是**"`notify-send` 退出码 0"（那只能说明消息丢进了 D-Bus），
# 而是"真有一个通知守护进程收到了它"。所以这里起三件：
#   ① `dbus-daemon --session`（地址写到 /tmp/synhub_dbus_addr）
#   ② `dunst` 作为 `org.freedesktop.Notifications` 的持有者
#   ③ `dbus-monitor` 把 Notify 调用记到 /tmp/synhub_notif_monitor.log
#
# 用法：docker exec synhub-linux bash -lc 'bash /src/tool/linux_notify_fixture.sh'
# 之后跑集成用例时带上：
#   export DBUS_SESSION_BUS_ADDRESS=$(cat /tmp/synhub_dbus_addr)
#   export DISPLAY=:97
set -euo pipefail

export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/xdg-runtime}
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

ADDR_FILE=/tmp/synhub_dbus_addr
MON_FILE=/tmp/synhub_notif_monitor.log

if [ -S "$XDG_RUNTIME_DIR/bus" ]; then
  echo "[notify-fixture] 复用已存在的会话总线"
  ADDR="unix:path=$XDG_RUNTIME_DIR/bus"
else
  rm -f "$ADDR_FILE"
  ADDR=$(dbus-daemon --session --fork --print-address=1)
  echo "$ADDR" >"$ADDR_FILE"
  echo "[notify-fixture] 新会话总线：$ADDR"
fi
export DBUS_SESSION_BUS_ADDRESS="$ADDR"

# 通知守护进程（dunst）。已是持有者就不再起第二个。
if ! gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
      --method org.freedesktop.DBus.NameHasOwner org.freedesktop.Notifications 2>/dev/null | grep -q true; then
  command -v dunst >/dev/null || {
    echo '[notify-fixture] 缺 dunst（sudo apt-get install -y dunst libnotify-bin）' >&2
    exit 1
  }
  DISPLAY=${DISPLAY:-:97} dunst >/tmp/synhub_dunst.log 2>&1 &
  sleep 2
  echo "[notify-fixture] dunst 已起（日志 /tmp/synhub_dunst.log）"
fi

# 消费方读数：把 Notify 调用记下来，用例去 grep
if ! pgrep -f "dbus-monitor --session" >/dev/null; then
  : >"$MON_FILE"
  dbus-monitor --session "interface='org.freedesktop.Notifications'" >>"$MON_FILE" 2>&1 &
  sleep 1
  echo "[notify-fixture] dbus-monitor 记录到 $MON_FILE"
fi

gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
  --method org.freedesktop.DBus.NameHasOwner org.freedesktop.Notifications
