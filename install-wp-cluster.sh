#!/usr/bin/env bash
# =============================================================================
#  wp-cluster 一键安装器
#
#  作用：在干净的 Debian / Ubuntu 上，从零装出「OpenLiteSpeed + LSPHP + SQLite
#        + APCu + LSCache」的原生 WordPress 站群环境，并装好 wp-cluster 工具。
#
#  一行命令：
#    curl -fsSL https://raw.githubusercontent.com/jiaoben123/wp-cluster/main/install-wp-cluster.sh | bash
#
#  带参数（需先把脚本落到本地）：
#    ./install-wp-cluster.sh --check                只检查环境，不装任何东西
#    ./install-wp-cluster.sh --upgrade              只更新 wp-cluster 本体（不动环境/站点）
#    ./install-wp-cluster.sh --domain a.com         装完后顺便建首个站点（需 DNS 已指向本机）
#    ./install-wp-cluster.sh --branch dev           从指定分支安装
#
#  支持系统：Debian 11/12/13、Ubuntu 20.04/22.04/24.04（x86_64 / arm64）
# =============================================================================
set -Eeuo pipefail

REPO_OWNER="${WP_CLUSTER_REPO_OWNER:-jiaoben123}"
REPO_NAME="${WP_CLUSTER_REPO_NAME:-wp-cluster}"
REPO_BRANCH="${WP_CLUSTER_BRANCH:-main}"
INSTALL_DIR="${WP_CLUSTER_DIR:-/root/wp-cluster}"
UPDATE_URL_FILE="/home/.wp-cluster-update-url"

LSWS_HOME="/usr/local/lsws"
LSWS_CONF="$LSWS_HOME/conf/httpd_config.conf"
PHP_VERSION="lsphp83"
PHP_BIN="$LSWS_HOME/$PHP_VERSION/bin/php"
WP_CLI="/usr/local/bin/wp"
TEMPLATE_DIR="/var/www/wp-template"
DB_DIR="/var/www/db"
LOG_FILE="/var/log/wp-cluster-install.log"

MODE="install"        # install | upgrade | check
WANT_DOMAIN=""
ASSUME_YES=0
SITE_TITLE=""
ADMIN_EMAIL=""

# ---------- 输出 ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[1;33m'
  C_B=$'\033[0;36m'; C_BD=$'\033[1m'; C_0=$'\033[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_BD=''; C_0=''
fi

mkdir -p "$(dirname "$LOG_FILE")"
: >>"$LOG_FILE" 2>/dev/null || true

_log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true; }
step() { printf '\n%s▸ %s%s\n' "$C_BD" "$*" "$C_0"; _log "STEP $*"; }
ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*"; _log "OK   $*"; }
skip() { printf '  %s·%s %s\n' "$C_Y" "$C_0" "$*"; _log "SKIP $*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; _log "WARN $*"; }
err()  { printf '  %s✗%s %s\n' "$C_R" "$C_0" "$*" >&2; _log "ERR  $*"; }
die()  { err "$*"; printf '\n  完整日志：%s\n' "$LOG_FILE" >&2; exit 3; }
have() { command -v "$1" >/dev/null 2>&1; }

on_error() {
  local rc=$1 line=$2
  err "安装中断（退出码 $rc，第 $line 行）"
  if [ -s "$LOG_FILE" ]; then
    printf '\n  最近日志：\n' >&2
    tail -n 12 "$LOG_FILE" | sed 's/^/    /' >&2
  fi
  exit "$rc"
}

# 探测 wp-cli 版本：root 下必须带 --allow-root，且失败时不得触发 ERR trap
wp_cli_version() {
  ( set +e; set +o pipefail
    "$PHP_BIN" "$WP_CLI" --version --allow-root 2>/dev/null | head -1 )
}
trap 'on_error $? $LINENO' ERR

usage() {
  sed -n '4,17p' "$0" 2>/dev/null | sed 's/^#  \{0,1\}//' | sed '/^$/d'
  cat <<'EOF'

选项：
  --check              只做环境检查，不安装、不修改
  --upgrade            只更新 wp-cluster 本体与文档，不动系统环境与站点
  --domain <域名>      安装完成后创建首个站点（域名模式，80/443）
  --title <标题>       首个站点的标题（默认用域名）
  --email <邮箱>       首个站点管理员邮箱 / ACME 注册邮箱
  --dir <路径>         安装目录（默认 /root/wp-cluster）
  --branch <分支>      从指定分支拉取（默认 main）
  -y, --yes            不再交互确认
  -h, --help           显示本帮助
EOF
}

# ---------- 参数 ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check" ;;
    --upgrade|--update) MODE="upgrade" ;;
    --domain) shift; WANT_DOMAIN="${1:-}" ;;
    --domain=*) WANT_DOMAIN="${1#*=}" ;;
    --title) shift; SITE_TITLE="${1:-}" ;;
    --title=*) SITE_TITLE="${1#*=}" ;;
    --email) shift; ADMIN_EMAIL="${1:-}" ;;
    --email=*) ADMIN_EMAIL="${1#*=}" ;;
    --dir) shift; INSTALL_DIR="${1:-}" ;;
    --dir=*) INSTALL_DIR="${1#*=}" ;;
    --branch) shift; REPO_BRANCH="${1:-}" ;;
    --branch=*) REPO_BRANCH="${1#*=}" ;;
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（用 --help 查看用法）" ;;
  esac
  shift
done

ARCHIVE_URL="https://codeload.github.com/$REPO_OWNER/$REPO_NAME/tar.gz/$REPO_BRANCH"
RAW_SCRIPT_URL="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$REPO_BRANCH/install-wp-cluster.sh"

# =============================================================================
#  1. 前置检查
# =============================================================================
require_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "请用 root 运行（sudo -i 后再执行）"
}

check_os() {
  [ -r /etc/os-release ] || die "无法识别系统（缺少 /etc/os-release）"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) : ;;
    *) die "当前只支持 Debian / Ubuntu，检测到：${ID:-unknown}" ;;
  esac
  local arch; arch=$(uname -m)
  case "$arch" in
    x86_64|aarch64|arm64) : ;;
    *) warn "未验证的 CPU 架构：$arch，可能装不上 lsphp 包" ;;
  esac
  ok "系统：$PRETTY_NAME（$arch）"
}

check_ram() {
  local kb; kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  local mb=$((kb / 1024))
  if [ "$mb" -lt 700 ]; then
    warn "内存 ${mb}MB —— 建议 ≥1GB，并启用 swap（wp-cluster doctor 会检查）"
  else
    ok "内存：${mb}MB"
  fi
}

# =============================================================================
#  2. 基础依赖
# =============================================================================
apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" >>"$LOG_FILE" 2>&1
}

install_base_deps() {
  step "基础依赖"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >>"$LOG_FILE" 2>&1 || die "apt-get update 失败"

  local need=() p
  for p in curl ca-certificates tar unzip python3 openssl cron logrotate rsync; do
    dpkg -s "$p" >/dev/null 2>&1 || need+=("$p")
  done
  if [ ${#need[@]} -gt 0 ]; then
    apt_install "${need[@]}" || die "安装基础依赖失败：${need[*]}"
    ok "已安装：${need[*]}"
  else
    skip "基础依赖已齐全"
  fi
}

# =============================================================================
#  3. OpenLiteSpeed + LSPHP
# =============================================================================
install_ols() {
  step "OpenLiteSpeed"
  if [ -x "$LSWS_HOME/bin/lshttpd" ]; then
    skip "已安装：$("$LSWS_HOME/bin/lshttpd" -v 2>/dev/null | head -1)"
    return 0
  fi
  curl -fsSL --max-time 60 https://rpms.litespeedtech.com/debian/enable_lst_debian_repo.sh \
    -o /tmp/enable_lst_repo.sh || die "下载 LiteSpeed 软件源脚本失败"
  bash /tmp/enable_lst_repo.sh >>"$LOG_FILE" 2>&1 || die "启用 LiteSpeed 软件源失败"
  apt-get update -qq >>"$LOG_FILE" 2>&1 || die "apt-get update 失败"
  apt_install openlitespeed || die "安装 openlitespeed 失败"
  ok "openlitespeed $("$LSWS_HOME/bin/lshttpd" -v 2>/dev/null | head -1)"
}

install_lsphp() {
  step "LSPHP 8.3 与扩展"
  local pkgs=(lsphp83 lsphp83-common lsphp83-curl lsphp83-sqlite3 lsphp83-mysql
              lsphp83-opcache lsphp83-apcu lsphp83-intl lsphp83-igbinary)
  local need=() p
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || need+=("$p")
  done
  if [ ${#need[@]} -gt 0 ]; then
    apt_install "${need[@]}" || die "安装 lsphp83 扩展失败：${need[*]}"
    ok "已安装：${need[*]}"
  else
    skip "LSPHP 扩展已齐全"
  fi
  # wp-cli 的 phar 头是 #!/usr/bin/env php，需要一个 PATH 里的 php
  if [ ! -x /usr/local/bin/php ]; then
    ln -sf "$PHP_BIN" /usr/local/bin/php
    ok "已建立 /usr/local/bin/php → $PHP_BIN"
  fi
  ok "PHP $("$PHP_BIN" -r 'echo PHP_VERSION;' 2>/dev/null)"
}

ensure_lsphp_handler() {
  # OLS 的 vhost 用 scripthandler 指向全局 extProcessor lsphp；缺了它所有站都会 503
  if grep -q '^extProcessor  *lsphp *{' "$LSWS_CONF" 2>/dev/null; then
    return 0
  fi
  step "补全 OLS 的 lsphp 处理器"
  python3 - "$LSWS_CONF" <<'PY' >>"$LOG_FILE" 2>&1
import sys, re
path = sys.argv[1]
src = open(path, encoding='utf-8', errors='surrogateescape').read()
if re.search(r'^extProcessor\s+lsphp\s*\{', src, re.M):
    sys.exit(0)
block = """extProcessor lsphp{
  type                    lsapi
  address                 uds://tmp/lshttpd/lsphp.sock
  maxConns                10
  env                     PHP_LSAPI_CHILDREN=10
  env                     LSAPI_AVOID_FORK=200M
  initTimeout             60
  retryTimeout            0
  persistConn             1
  respBuffer              0
  autoStart               1
  path                    lsphp83/bin/lsphp
  backlog                 100
  instances               1
  priority                0
  memSoftLimit            0
  memHardLimit            0
  procSoftLimit           1400
  procHardLimit           1500
}

"""
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(block + src)
PY
  ok "已写入 extProcessor lsphp"
}

enable_lsws() {
  step "启动 OpenLiteSpeed"
  systemctl enable lsws >>"$LOG_FILE" 2>&1 || true
  if systemctl is-active --quiet lsws; then
    skip "lsws 已在运行"
  else
    systemctl start lsws >>"$LOG_FILE" 2>&1 || die "lsws 启动失败（见 journalctl -u lsws）"
    ok "lsws 已启动"
  fi
}

install_wpcli() {
  step "WP-CLI"
  if [ -x "$WP_CLI" ]; then
    local v; v=$(wp_cli_version)
    if [ -n "$v" ]; then skip "已安装：$v"; else skip "已安装：$WP_CLI（版本探测失败，可直接使用）"; fi
    return 0
  fi
  curl -fsSL --max-time 60 https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    -o "$WP_CLI" || die "下载 wp-cli 失败"
  chmod 755 "$WP_CLI"
  ok "已安装：$(wp_cli_version)"
}

# =============================================================================
#  4. 拉取 wp-cluster 本体
# =============================================================================
fetch_repo() {
  step "获取 wp-cluster（$REPO_OWNER/$REPO_NAME@$REPO_BRANCH）"
  local tmp; tmp=$(mktemp -d /tmp/wpc-fetch.XXXXXX)
  curl -fsSL --max-time 120 "$ARCHIVE_URL" -o "$tmp/repo.tar.gz" \
    || { rm -rf "$tmp"; die "下载仓库失败（$ARCHIVE_URL）"; }
  tar xzf "$tmp/repo.tar.gz" -C "$tmp" || { rm -rf "$tmp"; die "解包失败"; }
  local src; src=$(find "$tmp" -maxdepth 1 -mindepth 1 -type d | head -1)
  [ -f "$src/wp-cluster" ] || { rm -rf "$tmp"; die "仓库结构异常：找不到 wp-cluster"; }
  [ -f "$src/install.sh" ] || { rm -rf "$tmp"; die "仓库结构异常：找不到 install.sh"; }

  mkdir -p "$INSTALL_DIR"
  if [ -f "$INSTALL_DIR/wp-cluster" ]; then
    cp -a "$INSTALL_DIR/wp-cluster" "$INSTALL_DIR/wp-cluster.bak.$(date +%Y%m%d%H%M%S)"
    skip "已存在旧版本，已备份为 wp-cluster.bak.*"
  fi
  # 只覆盖仓库跟踪的文件，保留 logs/ 等运行期产物
  cp -a "$src/wp-cluster" "$src/install.sh" "$src/install-wp-cluster.sh" \
        "$src/README.md" "$src/CHANGELOG.md" "$src/VERSION" "$src/LICENSE" "$INSTALL_DIR"/ 2>/dev/null || true
  cp -a "$src/conf" "$src/docs" "$src/tests" "$INSTALL_DIR"/ 2>/dev/null || true
  rm -rf "$tmp"
  chmod 755 "$INSTALL_DIR/wp-cluster" "$INSTALL_DIR/install.sh"
  ok "代码已就位：$INSTALL_DIR（版本 $(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo unknown)）"
}

write_update_marker() {
  step "记录自更新地址"
  local url="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$REPO_BRANCH/wp-cluster"
  mkdir -p "$(dirname "$UPDATE_URL_FILE")"
  printf '%s\n' "$url" >"$UPDATE_URL_FILE"
  chmod 600 "$UPDATE_URL_FILE"
  mkdir -p /etc/wp-cluster
  cp -f "$UPDATE_URL_FILE" /etc/wp-cluster/update-url
  chmod 600 /etc/wp-cluster/update-url
  ok "已写入 $UPDATE_URL_FILE（wp-cluster self-update 会读它）"

  # 配置文件里的 SELF_UPDATE_URL 优先级高于上面的标记文件：若是旧地址残留，会静默盖掉新地址
  local conf="/etc/wp-cluster/wp-cluster.conf" pinned=''
  if [ -f "$conf" ]; then
    pinned=$(sed -n 's/^SELF_UPDATE_URL="\(.*\)"/\1/p' "$conf" | head -1)
    if [ -n "$pinned" ] && [ "$pinned" != "$url" ]; then
      printf '  ! %s 里的 SELF_UPDATE_URL 指向 %s\n' "$conf" "$pinned" >&2
      printf '    它优先级更高，会让 self-update 从旧地址拉取；如需改用本次地址，请把该项改为空字符串。\n' >&2
    fi
  fi
}

# =============================================================================
#  5. 播种模板站（第一次建站需要有一个「干净样板」供硬链接）
# =============================================================================
ensure_template() {
  step "检查模板站"
  local d found=0
  for d in /var/www/*/; do
    d=${d%/}
    if [ -d "$d/wp-content/plugins/sqlite-database-integration" ] && [ -f "$d/wp-content/db.php" ]; then
      found=1; ok "已有可用模板：$d"; break
    fi
  done
  [ "$found" -eq 1 ] && return 0

  if [ -n "${TEMPLATE_SITE:-}" ] && [ -d "$TEMPLATE_SITE/wp-content/plugins/sqlite-database-integration" ]; then
    ok "配置指定的模板可用：$TEMPLATE_SITE"; return 0
  fi

  step "播种模板站（$TEMPLATE_DIR）"
  mkdir -p "$TEMPLATE_DIR" "$DB_DIR"
  chown nobody:nogroup "$DB_DIR" 2>/dev/null || true
  chmod 775 "$DB_DIR"

  if [ ! -f "$TEMPLATE_DIR/wp-load.php" ]; then
    "$PHP_BIN" "$WP_CLI" core download --path="$TEMPLATE_DIR" --locale=zh_CN \
      --allow-root >>"$LOG_FILE" 2>&1 || die "下载 WordPress 核心失败"
    ok "WordPress $( ( set +e; set +o pipefail; "$PHP_BIN" "$WP_CLI" --path="$TEMPLATE_DIR" --allow-root core version 2>/dev/null ) )"
  else
    skip "核心文件已存在"
  fi

  # SQLite 插件：直接取官方 zip，避免 drop-in 就位前 bootstrap WordPress 连 MySQL
  if [ ! -d "$TEMPLATE_DIR/wp-content/plugins/sqlite-database-integration" ]; then
    local z; z=$(mktemp /tmp/sq.XXXXXX.zip)
    curl -fsSL --max-time 90 "https://downloads.wordpress.org/plugin/sqlite-database-integration.zip" \
      -o "$z" || die "下载 sqlite-database-integration 失败"
    unzip -q -o "$z" -d "$TEMPLATE_DIR/wp-content/plugins/" || die "解压 SQLite 插件失败"
    rm -f "$z"
    ok "已下载 sqlite-database-integration"
  else
    skip "SQLite 插件已存在"
  fi

  local sqdir="$TEMPLATE_DIR/wp-content/plugins/sqlite-database-integration"
  if [ ! -f "$TEMPLATE_DIR/wp-content/db.php" ]; then
    cp -f "$sqdir/db.copy" "$TEMPLATE_DIR/wp-content/db.php" 2>/dev/null \
      || cp -f "$sqdir/db.copy" "$TEMPLATE_DIR/wp-content/db.php"
    sed -i "s|{SQLITE_IMPLEMENTATION_FOLDER_PATH}|$sqdir|g" "$TEMPLATE_DIR/wp-content/db.php"
    ok "已生成 SQLite drop-in（db.php）"
  fi

  if [ ! -f "$TEMPLATE_DIR/wp-config.php" ]; then
    local salts
    salts=$(cat <<EOF
define('AUTH_KEY',         '$(openssl rand -hex 32)');
define('SECURE_AUTH_KEY',  '$(openssl rand -hex 32)');
define('LOGGED_IN_KEY',    '$(openssl rand -hex 32)');
define('NONCE_KEY',        '$(openssl rand -hex 32)');
define('AUTH_SALT',        '$(openssl rand -hex 32)');
define('SECURE_AUTH_SALT', '$(openssl rand -hex 32)');
define('LOGGED_IN_SALT',   '$(openssl rand -hex 32)');
define('NONCE_SALT',       '$(openssl rand -hex 32)');
EOF
)
    cat >"$TEMPLATE_DIR/wp-config.php" <<PHPEOF
<?php
/** wp-cluster 模板站配置（自动生成，勿手工修改） */
define('DB_NAME', 'wordpress');
define('DB_USER', 'wordpress');
define('DB_PASSWORD', '');
define('DB_HOST', 'localhost');
define('DB_CHARSET', 'utf8mb4');
define('DB_COLLATE', '');
define('DB_ENGINE', 'sqlite');
define('DB_PATH', '$DB_DIR/template.sqlite');

define('WP_DEBUG', false);
define('DISALLOW_FILE_EDIT', true);

$salts
\$table_prefix = 'wp_';
if ( ! defined('ABSPATH') ) { define('ABSPATH', __DIR__ . '/'); }
require_once ABSPATH . 'wp-settings.php';
PHPEOF
    ok "已生成 wp-config.php"
  fi

  if ! "$PHP_BIN" "$WP_CLI" --path="$TEMPLATE_DIR" --allow-root core is-installed >/dev/null 2>&1; then
    local pass; pass=$(openssl rand -hex 8)
    "$PHP_BIN" "$WP_CLI" core install --path="$TEMPLATE_DIR" --allow-root \
      --url="http://template.invalid" --title="wp-cluster template" \
      --admin_user="admin" --admin_password="$pass" --admin_email="admin@localhost" \
      --skip-email >>"$LOG_FILE" 2>&1 || die "模板站安装失败（见 $LOG_FILE）"
    ok "模板站已安装（管理员密码不保留，模板站不对外服务）"
  else
    skip "模板站已安装"
  fi

  # 新站默认继承的插件：整页缓存 + APCu 管理
  local p
  for p in litespeed-cache apcu-manager; do
    if ! "$PHP_BIN" "$WP_CLI" --path="$TEMPLATE_DIR" --allow-root plugin is-installed "$p" >/dev/null 2>&1; then
      "$PHP_BIN" "$WP_CLI" --path="$TEMPLATE_DIR" --allow-root plugin install "$p" --activate \
        >>"$LOG_FILE" 2>&1 || warn "安装插件 $p 失败（不影响建站）"
    fi
  done
  "$PHP_BIN" "$WP_CLI" --path="$TEMPLATE_DIR" --allow-root option update blog_public 0 >/dev/null 2>&1 || true

  chown -R nobody:nogroup "$TEMPLATE_DIR" 2>/dev/null || true
  chown nobody:nogroup "$DB_DIR/template.sqlite" 2>/dev/null || true
  ok "模板站就绪：$TEMPLATE_DIR"
}

# =============================================================================
#  6. 安装主程序并初始化
# =============================================================================
run_local_installer() {
  step "安装 wp-cluster 主程序"
  bash "$INSTALL_DIR/install.sh" >>"$LOG_FILE" 2>&1 \
    || die "install.sh 执行失败（见 $LOG_FILE）"
  ok "已安装到 /usr/local/bin/wp-cluster"
}

init_cluster() {
  step "初始化站群环境"
  if wp-cluster init >>"$LOG_FILE" 2>&1; then
    ok "共享核心就绪：$(du -sh /var/www/wp-core 2>/dev/null | awk '{print $1}')"
  else
    tail -n 15 "$LOG_FILE" | sed 's/^/    /' >&2
    die "wp-cluster init 失败"
  fi
}

maybe_first_site() {
  [ -n "$WANT_DOMAIN" ] || return 0
  step "创建首个站点：$WANT_DOMAIN"
  local args=("$WANT_DOMAIN")
  [ -n "$SITE_TITLE" ] && args+=(--title "$SITE_TITLE")
  if [ -n "$ADMIN_EMAIL" ]; then
    wp-cluster add "${args[@]}" --email "$ADMIN_EMAIL" >>"$LOG_FILE" 2>&1 \
      || die "建站失败（见 $LOG_FILE；可先 wp-cluster doctor 检查环境）"
  else
    wp-cluster add "${args[@]}" >>"$LOG_FILE" 2>&1 \
      || die "建站失败（见 $LOG_FILE；可先 wp-cluster doctor 检查环境）"
  fi
  ok "站点已上线"
  wp-cluster info "$WANT_DOMAIN" 2>/dev/null | sed 's/^/  /' || true
}

summary() {
  local ip; ip=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "<本机IP>")
  printf '\n%s安装完成%s\n' "$C_BD$C_G" "$C_0"
  printf '  版本      : %s\n' "$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo -)"
  printf '  程序      : /usr/local/bin/wp-cluster\n'
  printf '  安装目录  : %s\n' "$INSTALL_DIR"
  printf '  站点目录  : /var/www/<域名>    共享核心 /var/www/wp-core\n'
  printf '  数据库    : /var/www/db/<域名>.sqlite（每站独立）\n'
  printf '  备份      : /var/backups/wp-cluster/<域名>/\n'
  printf '  日志      : /var/log/wp-cluster/\n'
  cat <<EOF

  下一步：
    wp-cluster doctor                       # 环境自检
    wp-cluster add blog.example.com         # 建站（域名需已解析到 $ip）
    wp-cluster add test.example.com --mode port   # 无域名时用端口试跑
    wp-cluster list                         # 站点清单
    wp-cluster health --all                 # 全部站点体检
    wp-cluster help                         # 全部命令

  记得放行防火墙 80/443：ufw allow 80,443/tcp
EOF
}

# =============================================================================
#  主流程
# =============================================================================
require_root
printf '%s\n' "${C_BD}wp-cluster 安装器${C_0}"
_log "=== 启动 install-wp-cluster.sh（mode=$MODE branch=$REPO_BRANCH）==="

check_os
check_ram

if [ "$MODE" = "check" ]; then
  step "环境检查（不做任何修改）"
  [ -x "$LSWS_HOME/bin/lshttpd" ] && ok "OLS: $("$LSWS_HOME/bin/lshttpd" -v 2>/dev/null | head -1)" || warn "OLS 未安装"
  dpkg -s lsphp83 >/dev/null 2>&1 && ok "lsphp83 已安装" || warn "lsphp83 未安装"
  [ -x "$PHP_BIN" ] && ok "PHP: $("$PHP_BIN" -r 'echo PHP_VERSION;')" || warn "PHP 可执行缺失"
  if [ -x "$WP_CLI" ]; then
    wpc_v=$(wp_cli_version)
    [ -n "$wpc_v" ] && ok "wp-cli: $wpc_v" || ok "wp-cli: $WP_CLI（版本探测失败）"
  else
    warn "wp-cli 未安装"
  fi
  [ -f "$INSTALL_DIR/wp-cluster" ] && ok "wp-cluster: $(cat "$INSTALL_DIR/VERSION" 2>/dev/null)" || warn "wp-cluster 未安装"
  systemctl is-active --quiet lsws && ok "lsws: 运行中" || warn "lsws: 未运行"
  echo
  printf '  安装方式：bash install-wp-cluster.sh\n'
  exit 0
fi

if [ "$MODE" = "upgrade" ]; then
  fetch_repo
  run_local_installer
  write_update_marker
  ok "已更新到 $(wp-cluster version 2>/dev/null | head -1)"
  exit 0
fi

install_base_deps
install_ols
install_lsphp
ensure_lsphp_handler
enable_lsws
install_wpcli
fetch_repo
run_local_installer
write_update_marker
ensure_template
init_cluster
maybe_first_site
summary
_log "=== 安装完成 ==="
