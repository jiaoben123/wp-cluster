#!/usr/bin/env bash
# =============================================================================
#  wp-cluster 回归测试套件
#  用法: bash tests/regression.sh [--fast|--full]
#        --fast  跳过耗时的 export/adopt 跨站接管（默认跑）
#        --full  全量（含迁移演练）
#
#  设计原则
#   1) 只创建/删除 zzreg* 临时站，绝不触碰生产站
#   2) 每个断言独立判定，失败不中断
#   3) 结束时自动清理临时站与临时配置（失败时保留现场并打印路径）
#   4) 不依赖外部网络（cf status/probe 若超时计 SKIP）
#  退出码: 0 全通过 · 1 有失败
# =============================================================================
set -uo pipefail

PASS=0; FAIL=0; SKIP=0
declare -a FAILED=()
declare -a SKIPPED=()

C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_D=$'\033[2m'; C_0=$'\033[0m'
GROUP=""

MODE="${1:---fast}"
[ "$MODE" = "--full" ] && MODE=full || MODE=fast

TMPD=$(mktemp -d /tmp/wpc-regress.XXXXXX)
OUT="$TMPD/out.txt"
KEEP=0
PHP_BIN=${PHP_BIN:-/usr/local/lsws/lsphp83/bin/php}
WP_CLI=${WP_CLI:-/usr/local/bin/wp}

D1="zzreg1.vitden.com"
D2="zzreg2.vitden.com"
P1=8190
P2=8191

hr() { printf '%.0s─' {1..78}; echo; }
group() { printf '\n%s%s%s\n' "$C_D" "$*" "$C_0"; }

ok()   { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$C_G" "$C_0" "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED+=("[$GROUP] $1"); printf '  %sFAIL%s %s\n' "$C_R" "$C_0" "$1"; [ -n "${2:-}" ] && printf '       %s%s%s\n' "$C_D" "$2" "$C_0"; }
skip() { SKIP=$((SKIP+1)); SKIPPED+=("[$GROUP] $1"); printf '  %sSKIP%s %s（%s）\n' "$C_Y" "$C_0" "$1" "${2:-}"; }

# 断言：命令成功
t_ok() { local d="$1"; shift; if "$@" >"$OUT" 2>&1; then ok "$d"; else bad "$d" "rc=$? · $(tail -2 "$OUT" | tr '\n' ' ' | cut -c1-160)"; fi; }

# 断言：退出码等于 N
t_rc() { local d="$1" want="$2"; shift 2; "$@" >"$OUT" 2>&1; local rc=$?; if [ "$rc" = "$want" ]; then ok "$d (rc=$rc)"; else bad "$d" "期望 rc=$want 实际 rc=$rc · $(tail -2 "$OUT" | tr '\n' ' ' | cut -c1-160)"; fi; }

# 断言：退出码非 0
t_nonzero() { local d="$1"; shift; "$@" >"$OUT" 2>&1; local rc=$?; if [ "$rc" -ne 0 ]; then ok "$d (rc=$rc)"; else bad "$d" "期望失败但返回 0"; fi; }

# 断言：输出含某字符串
t_has() { local d="$1" pat="$2"; shift 2; if "$@" >"$OUT" 2>&1 && grep -qF -- "$pat" "$OUT"; then ok "$d"; else bad "$d" "输出缺少: $pat"; fi; }

# 断言：输出不含某字符串
t_hasnt() { local d="$1" pat="$2"; shift 2; if "$@" >"$OUT" 2>&1 && ! grep -qF -- "$pat" "$OUT"; then ok "$d"; else bad "$d" "输出不应包含: $pat"; fi; }

# 断言：JSON 合法且满足 python 表达式（变量 d = 解析结果）
t_json() { local d="$1" expr="${2:-True}"; shift 2; "$@" >"$OUT" 2>&1; local rc=$?; if [ "$rc" -ne 0 ]; then bad "$d" "命令 rc=$rc"; return; fi
  if python3 -c "
import json,sys
try:
    d=json.load(open('$OUT'))
except Exception as e:
    print('BADJSON:',e); sys.exit(1)
assert ($expr), 'ASSERT FAILED'
" 2>"$TMPD/py.err"; then ok "$d"; else bad "$d" "$(tail -1 "$TMPD/py.err") · $(head -c 120 "$OUT")"; fi; }

# 断言：文件存在 / 不存在 / 目录存在
t_file()   { local d="$1" f="$2"; if [ -f "$f" ]; then ok "$d"; else bad "$d" "缺少文件 $f"; fi; }
t_nofile() { local d="$1" f="$2"; if [ ! -e "$f" ]; then ok "$d"; else bad "$d" "不该存在 $f"; fi; }
t_dir()    { local d="$1" f="$2"; if [ -d "$f" ]; then ok "$d"; else bad "$d" "缺少目录 $f"; fi; }

# HTTP 状态码
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$1" 2>/dev/null || echo 000; }
http_bytes() { curl -s -o /dev/null -w '%{size_download}' --max-time 15 "$1" 2>/dev/null || echo 0; }
t_http() { local d="$1" url="$2" want="${3:-200}"; local c; c=$(http_code "$url"); if [ "$c" = "$want" ]; then ok "$d (HTTP $c)"; else bad "$d" "期望 $want 实际 $c · $url"; fi; }

cleanup() {
  local rc=$?
  echo
  if [ "$KEEP" = "0" ]; then
    group "清理"
    wp-cluster remove "$D1" --yes >/dev/null 2>&1 && printf '  已删除 %s\n' "$D1"
    wp-cluster remove "$D2" --yes >/dev/null 2>&1 && printf '  已删除 %s\n' "$D2"
    rm -f /var/backups/wp-cluster/$D1/*export-regress*.tar.gz 2>/dev/null
    rm -rf "$TMPD"
  else
    printf '  现场保留: %s\n' "$TMPD"
  fi
  echo
  hr
  printf '  通过 %s · 失败 %s · 跳过 %s\n' "$PASS" "$FAIL" "$SKIP"
  if [ "${#FAILED[@]}" -gt 0 ]; then
    printf '\n  %s失败明细%s\n' "$C_R" "$C_0"
    printf '   - %s\n' "${FAILED[@]}"
  fi
  if [ "${#SKIPPED[@]}" -gt 0 ]; then
    printf '\n  %s跳过%s\n' "$C_Y" "$C_0"
    printf '   - %s\n' "${SKIPPED[@]}"
  fi
  hr
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}
trap cleanup EXIT

# =============================================================================
printf '\n%s\n' "wp-cluster 回归测试 · $(date '+%F %T') · mode=$MODE"
printf '  主机: %s · 工具: %s\n' "$(hostname)" "$(wp-cluster version 2>/dev/null | head -1)"

# =============================================================================
GROUP="A 静态与元数据"
group "$GROUP"
t_ok "脚本语法检查" bash -n "$(readlink -f "$(command -v wp-cluster)")"
t_has "版本号可输出" "wp-cluster" wp-cluster version
V_SCRIPT=$(grep -m1 '^WP_CLUSTER_VERSION=' "$(readlink -f "$(command -v wp-cluster)")" | cut -d'"' -f2)
V_FILE=$(cat /root/wp-cluster/VERSION 2>/dev/null | tr -d '[:space:]')
if [ "$V_SCRIPT" = "$V_FILE" ]; then ok "版本号一致（$V_SCRIPT）"; else bad "版本号不一致" "脚本=$V_SCRIPT 文件=$V_FILE"; fi
t_has "帮助含新增命令" "isolate" wp-cluster help
t_has "帮助含 cf 子命令" "cf probe" wp-cluster help
t_has "帮助含退出码表" "退出码" wp-cluster help
SELF=$(readlink -f "$(command -v wp-cluster)")
if grep -q $'\r' "$SELF"; then bad "无 CRLF 换行"; else ok "无 CRLF 换行"; fi
if head -c3 "$SELF" | grep -q $'\xef\xbb\xbf'; then bad "无 BOM"; else ok "无 BOM"; fi

# =============================================================================
GROUP="B 只读命令"
group "$GROUP"
t_ok "doctor 全绿" wp-cluster doctor
t_has "list 列出站点" "ww2.vitden.com" wp-cluster list
t_ok "list --check" wp-cluster list --check
t_ok "status" wp-cluster status
t_ok "health --all" wp-cluster health --all
t_ok "verify 通过" wp-cluster verify
t_ok "cf status（单域）" wp-cluster cf status ww2.vitden.com
t_ok "cf plan 生成步骤" wp-cluster cf plan ww2.vitden.com --aux vitden.com --fallback origin.vitden.com
t_has "cf plan 含 custom hostname" "自定义主机名" wp-cluster cf plan ww2.vitden.com --aux vitden.com
t_ok "guard status" wp-cluster guard status
t_ok "cron status" wp-cluster cron status
t_ok "logs -n 5" wp-cluster logs -n 5

# =============================================================================
GROUP="C JSON 契约"
group "$GROUP"
t_json "list --json 是数组" "isinstance(d,list) and len(d)>=1 and 'domain' in d[0]" wp-cluster list --json
t_json "status --json 字段完整" "all(k in d for k in ('sites','mem','load')) or isinstance(d,dict)" wp-cluster status --json
t_json "health --json 含 bytes" "isinstance(d,list) and 'bytes' in d[0] and 'status' in d[0]" wp-cluster health --all --json
t_json "verify --json 合并对象" "'core' in d and 'sites' in d and isinstance(d['sites'],list)" wp-cluster verify --json
t_json "cf status --json 数组" "isinstance(d,list) and ('dns' in d[0]) and ('ttfb' in d[0])" wp-cluster cf status ww2.vitden.com --json
t_json "info --json 对象" "'domain' in d and 'http_code' in d and 'theme' in d" wp-cluster info ww2.vitden.com --json

# =============================================================================
GROUP="D 参数校验与退出码"
group "$GROUP"
t_rc "未知命令 → 2" 2 wp-cluster nosuchcmd
t_rc "info 缺参数 → 2" 2 wp-cluster info
t_rc "add 缺参数 → 2" 2 wp-cluster add
t_rc "info 不存在 → 5" 5 wp-cluster info no-such-site.example.com
t_rc "remove 不存在 → 5" 5 wp-cluster remove no-such-site.example.com --yes
t_rc "restore 缺参数 → 2" 2 wp-cluster restore "$D1"
t_rc "url 非法 → 2" 2 wp-cluster add "bad_domain!" --mode port
t_rc "端口越界 → 2" 2 wp-cluster add "$D1" --mode port --port 99999
t_rc "mode 非法 → 2" 2 wp-cluster add "$D1" --mode bogus
t_rc "isolate 不存在 → 5" 5 wp-cluster isolate no-such-site.example.com
t_nonzero "adopt 包不存在" wp-cluster adopt /tmp/no-such-export.tar.gz --domain "$D1" --yes
t_nonzero "adopt 非法包" bash -c "echo notatar > $TMPD/bad.tar.gz; wp-cluster adopt $TMPD/bad.tar.gz --domain $D1 --yes"

# =============================================================================
GROUP="E dry-run 不落盘"
group "$GROUP"
t_ok "add --dry-run" wp-cluster add "$D1" --mode port --port "$P1" --dry-run
t_nofile "dry-run 未写注册表" "/etc/wp-cluster/sites/$D1.env"
t_nofile "dry-run 未建目录" "/var/www/$D1"
t_ok "init --dry-run" wp-cluster init --dry-run
t_nonzero "backup 不存在站 → 非 0" wp-cluster backup no-such-site.example.com

# =============================================================================
GROUP="F 建站"
group "$GROUP"
t_ok "add $D1（端口模式）" wp-cluster add "$D1" --mode port --port "$P1" --title "Regress One" --admin-user zzadmin --minimal
t_file "注册表已生成" "/etc/wp-cluster/sites/$D1.env"
t_dir  "站点目录已生成" "/var/www/$D1"
t_file "数据库已生成" "/var/www/db/zzreg1_vitden_com.sqlite"
t_http "站点可访问" "http://127.0.0.1:$P1/?r=$RANDOM"
BODY=$(http_bytes "http://127.0.0.1:$P1/?b=$RANDOM")
if [ "${BODY:-0}" -gt 500 ]; then ok "首页非空白（${BODY}B）"; else bad "首页非空白" "仅 ${BODY}B"; fi
t_ok "health 单站通过" wp-cluster health "$D1"
t_rc "重复建站 → 4" 4 wp-cluster add "$D1" --mode port --port "$P1"
t_has "info 显示标题" "Regress One" wp-cluster info "$D1"
if [ "$(stat -c '%a' "/etc/wp-cluster/sites/$D1.env")" = "600" ]; then ok "注册表权限 600"; else bad "注册表权限 600" "$(stat -c '%a' "/etc/wp-cluster/sites/$D1.env")"; fi
# 收录检查必须用「站点自己的 home_url」访问：
# 用 127.0.0.1 会被模板里的本地主机守卫判为本地 → 一律 noindex；用 Host 头会被 canonical 301 到不可解析的名字
URL1=$(wp-cluster info "$D1" --json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["url"])' 2>/dev/null)
if [ -n "$URL1" ]; then ok "取得站点 URL（$URL1）"; else bad "取得站点 URL"; fi

# =============================================================================
GROUP="G 收录开关与缓存"
group "$GROUP"
t_ok "disable → noindex" wp-cluster disable "$D1"
t_has "HTML 含 noindex" "noindex" bash -c "curl -s --max-time 15 '$URL1/?n=$RANDOM'"
t_ok "enable → 允许收录" wp-cluster enable "$D1"
# 用 home_url 直连判断真实收录状态（模板的本地主机守卫对 127.0.0.1 会强制 noindex，属预期）
idx_check() {
  local i out
  for i in 1 2 3; do
    out=$(curl -s --max-time 15 "$URL1/?i=$RANDOM$i")
    if [ "${#out}" -gt 500 ] && ! printf '%s' "$out" | grep -qi 'noindex'; then return 0; fi
    sleep 2
  done
  return 1
}
if idx_check; then ok "enable 后页面可收录"; else bad "enable 后页面可收录" "仍输出 noindex"; fi
t_ok "disable 幂等" wp-cluster disable "$D1"
t_ok "purge 清缓存" wp-cluster purge "$D1"
t_ok "purge 幂等" wp-cluster purge "$D1"
curl -s -o /dev/null "http://127.0.0.1:$P1/" >/dev/null 2>&1
curl -s -o /dev/null "http://127.0.0.1:$P1/" >/dev/null 2>&1
CACHE=$(curl -sI --max-time 15 "http://127.0.0.1:$P1/" | grep -i '^x-litespeed-cache:' | tr -d '\r' | awk '{print $2}')
if [ "$CACHE" = "hit" ]; then ok "LSCache 命中"; else bad "LSCache 命中" "x-litespeed-cache=${CACHE:-无}"; fi

# =============================================================================
GROUP="H 备份 / 恢复"
group "$GROUP"
t_ok "backup manual" wp-cluster backup "$D1" --type manual
BK=$(ls -t /var/backups/wp-cluster/"$D1"/*manual*.tar.gz 2>/dev/null | head -1)
if [ -n "$BK" ]; then ok "备份包已生成（$(du -h "$BK" | cut -f1)）"; else bad "备份包已生成" "未找到 manual 包"; fi
# 先落盘再 grep：管道里用 grep -q 会 SIGPIPE 掉 tar，配合 pipefail 会误判失败
if [ -n "$BK" ]; then tar tzf "$BK" >"$TMPD/bk.list" 2>/dev/null; fi
if [ -n "$BK" ] && grep -qx 'database.sqlite' "$TMPD/bk.list"; then ok "备份包含数据库"; else bad "备份包含数据库"; fi
if [ -n "$BK" ] && grep -qx 'site-files.tar.gz' "$TMPD/bk.list"; then ok "备份包含文件包"; else bad "备份包含文件包"; fi
if [ -n "$BK" ]; then
  t_ok "restore 覆盖恢复" wp-cluster restore "$D1" "$BK" --yes
  t_http "恢复后可访问" "http://127.0.0.1:$P1/?rr=$RANDOM"
  if "$PHP_BIN" -r '$d=new PDO("sqlite:/var/www/db/zzreg1_vitden_com.sqlite");echo $d->query("PRAGMA quick_check")->fetchColumn();' 2>/dev/null | grep -qx ok; then ok "恢复后数据库完整"; else bad "恢复后数据库完整" "quick_check 未返回 ok"; fi
  t_ok "restore --dry-run" wp-cluster restore "$D1" "$BK" --yes --dry-run
else
  skip "restore 流程" "无备份包"
fi

# =============================================================================
GROUP="I 导出 / 接管（单站迁移）"
group "$GROUP"
t_ok "export" wp-cluster export "$D1" -o "$TMPD/export.tar.gz"
t_file "导出包生成" "$TMPD/export.tar.gz"
if [ -f "$TMPD/export.tar.gz" ]; then
  tar tzf "$TMPD/export.tar.gz" >"$TMPD/exp.list" 2>/dev/null
  if grep -qx 'manifest.json' "$TMPD/exp.list"; then ok "包含 manifest.json"; else bad "包含 manifest.json"; fi
  if grep -qx 'SHA256SUMS' "$TMPD/exp.list"; then ok "包含 SHA256SUMS"; else bad "包含 SHA256SUMS"; fi
  t_json "manifest 可解析" "'format' in d and 'domain' in d and d['domain']=='$D1'" bash -c "tar xzOf '$TMPD/export.tar.gz' manifest.json > $TMPD/m.json; cat $TMPD/m.json"
  if [ "$MODE" = "full" ]; then
    t_ok "adopt 到 $D2" wp-cluster adopt "$TMPD/export.tar.gz" --domain "$D2" --mode port
    t_dir "新站目录" "/var/www/$D2"
    t_file "新站注册表" "/etc/wp-cluster/sites/$D2.env"
    NEWURL=$(wp-cluster info "$D2" --json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["url"])' 2>/dev/null)
    if [ -n "$NEWURL" ]; then t_http "接管后可访问" "$NEWURL/?ad=$RANDOM"; else bad "接管后可访问" "无法取 URL"; fi
    # 迁移正确性看数据库，不看首页文本：home/siteurl 必须已指向新地址，正文里不应再有旧域名
    NEWHOME=$("$PHP_BIN" "$WP_CLI" --path="/var/www/$D2" --allow-root option get home 2>/dev/null | tr -d '\r')
    # wp db query 需要 mysql 客户端，SQLite 方案下不可用 → 直接用 PDO 查库文件
    DB2=$(grep -m1 '^DB_PATH=' "/etc/wp-cluster/sites/$D2.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
    OLDLEFT=$("$PHP_BIN" -r '$d=new PDO("sqlite:".$argv[1]); $q=$d->prepare("select count(*) from wp_posts where post_content like ?"); $q->execute(["%".$argv[2]."%"]); echo (int)$q->fetchColumn();' "$DB2" "$D1" 2>/dev/null)
    POSTCNT=$("$PHP_BIN" "$WP_CLI" --path="/var/www/$D2" --allow-root post list --post_type=post --format=count 2>/dev/null | tr -d '[:space:]')
    if [ "$NEWHOME" = "$NEWURL" ]; then ok "home 已指向新域名（$NEWHOME）"; else bad "home 已指向新域名" "home=$NEWHOME 期望 $NEWURL"; fi
    if [ "${OLDLEFT:-1}" = "0" ]; then ok "正文无旧域名残留"; else bad "正文无旧域名残留" "仍有 $OLDLEFT 条"; fi
    if [ "${POSTCNT:-0}" -gt 0 ] 2>/dev/null; then ok "文章已迁移（$POSTCNT 篇）"; else bad "文章已迁移" "post count=$POSTCNT"; fi
  else
    skip "adopt 接管" "--fast 模式跳过，--full 启用"
  fi
else
  skip "adopt 接管" "无导出包"
fi

# =============================================================================
GROUP="J 隔离"
group "$GROUP"
t_ok "verify --baseline 写基线" wp-cluster verify --baseline
t_ok "verify 基线后仍通过" wp-cluster verify
# 漂移检测：往共享核心塞一个无害文件，verify 必须报 7
echo "drift-$(date +%s)" > /var/www/wp-core/zz-drift-test.txt
t_rc "核心漂移被检出 → 7" 7 wp-cluster verify
rm -f /var/www/wp-core/zz-drift-test.txt
t_ok "清除漂移后恢复通过" wp-cluster verify

EXT_BEFORE=$(grep -c '^extProcessor' /usr/local/lsws/conf/httpd_config.conf || true)
t_ok "isolate --php-pool 2" wp-cluster isolate "$D1" --php-pool 2
EXT_AFTER=$(grep -c '^extProcessor' /usr/local/lsws/conf/httpd_config.conf || true)
if [ "$EXT_AFTER" -gt "$EXT_BEFORE" ]; then ok "已新增独立 PHP 池（$EXT_BEFORE → $EXT_AFTER）"; else bad "已新增独立 PHP 池" "extProcessor 数未增加"; fi
t_http "隔离后站点正常" "http://127.0.0.1:$P1/?iso=$RANDOM"
t_has "vhost 已绑定独立 handler" "zzreg1" bash -c "cat /usr/local/lsws/conf/vhosts/$D1/vhconf.conf"
t_ok "isolate --undo" wp-cluster isolate "$D1" --undo
EXT_UNDO=$(grep -c '^extProcessor' /usr/local/lsws/conf/httpd_config.conf || true)
if [ "$EXT_UNDO" = "$EXT_BEFORE" ]; then ok "撤销后处理器数还原（$EXT_UNDO）"; else bad "撤销后处理器数还原" "$EXT_BEFORE → $EXT_UNDO"; fi
t_http "撤销后站点正常" "http://127.0.0.1:$P1/?undo=$RANDOM"

LINKS_BEFORE=$(find "/var/www/$D1" -type f -links +1 2>/dev/null | wc -l)
t_ok "isolate --core 拆硬链接" wp-cluster isolate "$D1" --core
LINKS_AFTER=$(find "/var/www/$D1" -type f -links +1 2>/dev/null | wc -l)
if [ "$LINKS_AFTER" -lt "$LINKS_BEFORE" ] || [ "$LINKS_AFTER" -eq 0 ]; then ok "硬链接已拆分（$LINKS_BEFORE → $LINKS_AFTER）"; else bad "硬链接已拆分" "$LINKS_BEFORE → $LINKS_AFTER"; fi
t_http "拆链后站点正常" "http://127.0.0.1:$P1/?core=$RANDOM"
# 「其他站」不能写死端口：生产环境里 8081 上未必有站点，写死会误报失败。
# 从注册表里挑第一个「非本次测试站」的端口模式站点；一个都没有就如实跳过。
OTHER_URL=""
for f in /etc/wp-cluster/sites/*.env; do
  [ -f "$f" ] || continue
  _d=$(basename "$f" .env); [ "$_d" = "$D1" ] && continue
  _m=$(grep -m1 '^MODE=' "$f" 2>/dev/null | cut -d= -f2- | tr -d '"')
  _p=$(grep -m1 '^PORT=' "$f" 2>/dev/null | cut -d= -f2- | tr -d '"')
  if [ "$_m" = "port" ] && [ -n "$_p" ]; then OTHER_URL="http://127.0.0.1:$_p/"; break; fi
done
if [ -n "$OTHER_URL" ]; then
  t_http "其他站未受影响" "$OTHER_URL"
else
  skip "其他站未受影响" "本机无第二个端口模式站点"
fi
t_ok "拆链后 verify 仍通过" wp-cluster verify
t_ok "isolate 参数重复无害" bash -c "wp-cluster isolate $D1 --core >/dev/null 2>&1; wp-cluster isolate $D1 --php-pool 2 >/dev/null 2>&1"

# =============================================================================
GROUP="K 守护 / 计划任务"
group "$GROUP"
t_ok "guard install（幂等）" wp-cluster guard install
t_ok "guard status" wp-cluster guard status
t_has "guard timer 已注册" "wp-cluster-guard.timer" systemctl list-timers --all --no-pager
t_ok "guard run（单轮巡检）" wp-cluster guard run
t_file "巡检日志已写入" "/var/log/wp-cluster/guard.log"
t_ok "cron status" wp-cluster cron status

# =============================================================================
GROUP="L 锁与并发"
group "$GROUP"
printf 'LOCK_FILE="/var/lock/wpc-regress.lock"\nLOCK_TIMEOUT=2\n' > "$TMPD/lock.conf"
( flock -x 9; sleep 6 ) 9>/var/lock/wpc-regress.lock &
LOCKPID=$!
sleep 1
t_rc "锁被占用 → 6" 6 wp-cluster backup "$D1" --config "$TMPD/lock.conf"
wait "$LOCKPID" 2>/dev/null || true
t_ok "锁释放后恢复" wp-cluster backup "$D1" --config "$TMPD/lock.conf" --type manual

# =============================================================================
GROUP="M 删除与清理"
group "$GROUP"
t_ok "remove $D1" wp-cluster remove "$D1" --yes
t_nofile "目录已删除" "/var/www/$D1"
t_nofile "注册表已删除" "/etc/wp-cluster/sites/$D1.env"
t_nofile "数据库已删除" "/var/www/db/zzreg1_vitden_com.sqlite"
t_nofile "vhost 已删除" "/usr/local/lsws/conf/vhosts/$D1"
if curl -s -o /dev/null --max-time 5 "http://127.0.0.1:$P1/" 2>/dev/null; then bad "端口已释放" "仍可连接 $P1"; else ok "端口已释放"; fi
# 该站在 J 组做过 isolate --php-pool，删除时必须一并清掉独立 extProcessor，不能残留
if grep -q "lsphp_zzreg1" /usr/local/lsws/conf/httpd_config.conf 2>/dev/null; then bad "独立 PHP 池已清理" "extProcessor lsphp_zzreg1 仍残留"; else ok "独立 PHP 池已清理"; fi
t_nofile "池 socket 已清理" "/tmp/lshttpd/lsphp_zzreg1_vitden_com.sock"
t_rc "删除后 info → 5" 5 wp-cluster info "$D1"
if [ "$MODE" = "full" ]; then
  t_ok "remove $D2" wp-cluster remove "$D2" --yes
fi
t_ok "最终 health --all" wp-cluster health --all
t_ok "最终 verify" wp-cluster verify
