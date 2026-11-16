#!/usr/bin/env bash
# wp-cluster 安装器：安装主程序 + 目录 + 配置样板，并跑一次环境自检
set -Eeuo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="/usr/local/bin/wp-cluster"
STATE_DIR="/etc/wp-cluster"
LOG_DIR="/var/log/wp-cluster"
BACKUP_DIR="/var/backups/wp-cluster"

info() { printf '\033[0;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[x]\033[0m %s\n' "$*" >&2; }

[ "${EUID:-$(id -u)}" -eq 0 ] || { err "请用 root 运行：sudo ./install.sh"; exit 3; }
[ -f "$SRC_DIR/wp-cluster" ] || { err "找不到 wp-cluster，请在解压目录内运行"; exit 3; }

info "安装主程序 → $BIN"
install -m 755 "$SRC_DIR/wp-cluster" "$BIN"

info "创建目录"
mkdir -p "$STATE_DIR/sites" "$STATE_DIR/mu-plugins" "$LOG_DIR" "$BACKUP_DIR"
chmod 700 "$STATE_DIR"

if [ -f "$SRC_DIR/conf/wp-cluster.conf.example" ] && [ ! -f "$STATE_DIR/wp-cluster.conf" ]; then
  install -m 644 "$SRC_DIR/conf/wp-cluster.conf.example" "$STATE_DIR/wp-cluster.conf"
  info "配置样板已写入 $STATE_DIR/wp-cluster.conf（按需修改）"
fi

if [ -f "$SRC_DIR/VERSION" ]; then
  info "版本：$(cat "$SRC_DIR/VERSION")"
fi

echo
info "运行环境自检……"
echo
if "$BIN" doctor; then
  echo
  info "安装完成。下一步："
  printf '  wp-cluster init\n  wp-cluster import --all\n  wp-cluster add <域名>\n'
else
  echo
  warn "自检未全部通过，请按上面的提示处理后重新运行 wp-cluster doctor"
  exit 3
fi
