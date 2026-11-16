#!/usr/bin/env bash
# =============================================================================
#  wp-cluster 用户旅程实测（对应 README「明天怎么体验」的 11 步）
#  用法: bash tests/walkthrough.sh
#  只创建 demo2 / demo3 两个站，跑完自动删除；后台密码输出已脱敏。
#  退出码 0 = 全部通过
# =============================================================================
set -uo pipefail

D2=demo2.vitden.com
D3=demo3.vitden.com
CONF=/usr/local/lsws/conf/httpd_config.conf
TMP=$(mktemp -d /tmp/wpc-walk.XXXXXX)
OUT="$TMP/out"
LOG=/var/log/wp-cluster/walkthrough.log
PASS=0; FAIL=0
SECRET=""                 # 建站后从注册表读出真实密码，用于精确脱敏
declare -a FAILED=()

C_G=$'\033[32m'; C_R=$'\033[31m'; C_D=$'\033[2m'; C_0=$'\033[0m'

ok()  { PASS=$((PASS+1)); printf '    %s✓%s %s\n' "$C_G" "$C_0" "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '    %s✗%s %s\n' "$C_R" "$C_0" "$1"; }

# 执行一步：打印标题 -> 运行 -> 打印退出码与耗时 -> 输出脱敏后回显
run() {
  local no="$1" desc="$2"; shift 2
  printf '\n===== [%s] %s =====\n' "$no" "$desc"
  # 防呆：命令必须作为独立参数传入，否则会「空跑」并假报通过
  if [ "$#" -eq 0 ]; then
    bad "[$no] 测试脚本错误：没有传入要执行的命令"
    LAST_RC=99
    return 0
  fi
  printf '    $ %s\n' "$*"
  local t0=$(date +%s) rc
  "$@" >"$OUT" 2>&1
  rc=$?
  local dur=$(( $(date +%s) - t0 ))
  # 三道脱敏：按「后台/账号」行格式打码 → 通用长随机串打码 → 用注册表里的真实密码做字面替换
  # add / adopt 会直接打印新密码（此时注册表还没写或密码已变），所以不能只依赖 SECRET
  awk '/(后台|账号)/ && / \/ / {sub(/\/ [^ （\t]+/, "/ ***REDACTED***")} {print}' "$OUT" >"$OUT.mask"
  sed -E 's/[A-Za-z0-9]{14,}/***REDACTED***/g' "$OUT.mask" >"$OUT.mask2"
  if [ -n "${SECRET:-}" ]; then
    sed "s/$SECRET/***REDACTED***/g" "$OUT.mask2" >"$OUT.clean"
  else
    cp "$OUT.mask2" "$OUT.clean"
  fi
  sed 's/^/    /' "$OUT.clean" | tee -a "$LOG"
  printf '    %s退出码 %s · 耗时 %ss%s\n' "$C_D" "$rc" "$dur" "$C_0"
  LAST_RC=$rc
  return 0
}

printf '\nwp-cluster 用户旅程实测 · %s · %s\n' "$(date '+%F %T')" "$(wp-cluster version | head -1)"
: >"$LOG"

# -----------------------------------------------------------------------------
run 01 "环境自检" wp-cluster doctor
[ "$LAST_RC" -eq 0 ] && ok "doctor 通过" || bad "doctor 返回 $LAST_RC"

run 02 "站点清单 + HTTP 探测" wp-cluster list --check
[ "$LAST_RC" -eq 0 ] && ok "清单与探测通过" || bad "list --check 返回 $LAST_RC"

MD5_BEFORE=$(md5sum "$CONF" | awk '{print $1}')
run 03 "先看计划，不落盘" wp-cluster add "$D2" --mode port --dry-run
MD5_AFTER=$(md5sum "$CONF" | awk '{print $1}')
[ "$LAST_RC" -eq 0 ] && ok "dry-run 返回 0" || bad "dry-run 返回 $LAST_RC"
[ "$MD5_BEFORE" = "$MD5_AFTER" ] && ok "OLS 配置未被改动（md5 一致）" || bad "dry-run 污染了配置"
[ ! -e "/etc/wp-cluster/sites/$D2.env" ] && ok "未写注册表" || bad "注册表被写入"
[ ! -d "/var/www/$D2" ] && ok "未建站点目录" || bad "站点目录被创建"

run 04 "真建站" wp-cluster add "$D2" --mode port
[ "$LAST_RC" -eq 0 ] && ok "建站返回 0" || bad "建站返回 $LAST_RC"
[ -f "/etc/wp-cluster/sites/$D2.env" ] && ok "注册表已生成" || bad "注册表缺失"
[ -f "/var/www/db/demo2_vitden_com.sqlite" ] && ok "独立数据库已生成" || bad "数据库缺失"
P2=$(wp-cluster info "$D2" --json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["port"])' 2>/dev/null)
U2=$(wp-cluster info "$D2" --json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["url"])' 2>/dev/null)
# 验活参数避开 WP 保留查询变量：w=按周归档、p=文章ID，非法值会渲染 404 / 301
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$U2/?wpcluster-check=$RANDOM$RANDOM" 2>/dev/null)
BYTES=$(curl -s -o /dev/null -w '%{size_download}' --max-time 15 "$U2/?wpcluster-check=$RANDOM$RANDOM" 2>/dev/null)
[ "$CODE" = "200" ] && ok "首页 HTTP 200（端口 $P2）" || bad "首页 HTTP $CODE"
[ "${BYTES:-0}" -gt 500 ] && ok "首页非空（${BYTES}B）" || bad "首页空白（${BYTES}B）"
SECRET=$(grep -m1 '^ADMIN_PASS=' "/etc/wp-cluster/sites/$D2.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
if [ -n "$SECRET" ] && grep -q "$SECRET" "$OUT.clean"; then bad "add 输出泄露了明文密码"; else ok "add 输出已脱敏（不打印真实密码）"; fi

run 05 "站点详情（含后台账号，已脱敏）" wp-cluster info "$D2"
[ "$LAST_RC" -eq 0 ] && ok "info 返回 0" || bad "info 返回 $LAST_RC"
grep -q '标题' "$OUT.clean" && ok "输出含站点标题" || bad "输出缺标题"
if grep -q 'REDACTED' "$OUT.clean"; then ok "后台密码已脱敏"; elif grep -q '后台' "$OUT.clean"; then bad "密码疑似明文出现在输出"; else bad "未找到后台信息"; fi
if [ -n "$SECRET" ] && grep -q "$SECRET" "$OUT.clean"; then bad "真实密码出现在回显中"; else ok "回显不含真实密码"; fi

run 06 "手动备份" wp-cluster backup "$D2" --type manual
[ "$LAST_RC" -eq 0 ] && ok "备份返回 0" || bad "备份返回 $LAST_RC"
BK=$(ls -t /var/backups/wp-cluster/"$D2"/*manual*.tar.gz 2>/dev/null | head -1)
[ -n "$BK" ] && ok "备份包已生成（$(du -h "$BK" | cut -f1)）" || bad "未找到备份包"

run 07 "导出打包" wp-cluster export "$D2"
[ "$LAST_RC" -eq 0 ] && ok "导出返回 0" || bad "导出返回 $LAST_RC"
PKG=$(ls -t /var/backups/wp-cluster/"$D2"/*export*.tar.gz 2>/dev/null | head -1)
[ -n "$PKG" ] && ok "导出包已生成（$(du -h "$PKG" | cut -f1)）" || bad "未找到导出包"

if [ -n "${PKG:-}" ]; then
  run 08 "换域名接管" wp-cluster adopt "$PKG" --domain "$D3" --mode port
  [ "$LAST_RC" -eq 0 ] && ok "接管返回 0" || bad "接管返回 $LAST_RC"
  [ -f "/etc/wp-cluster/sites/$D3.env" ] && ok "新站注册表已生成" || bad "新站注册表缺失"
  U3=$(wp-cluster info "$D3" --json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["url"])' 2>/dev/null)
  C3=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$U3/?wpcluster-check=$RANDOM$RANDOM" 2>/dev/null)
  [ "$C3" = "200" ] && ok "接管后 HTTP 200（$U3）" || bad "接管后 HTTP $C3"
  HOME3=$(/usr/local/lsws/lsphp83/bin/php /usr/local/bin/wp --path="/var/www/$D3" --allow-root option get home 2>/dev/null | tr -d '\r')
  [ "$HOME3" = "$U3" ] && ok "home 已指向新域名" || bad "home=$HOME3 期望 $U3"
else
  bad "跳过 adopt（无导出包）"
fi

EXT_BEFORE=$(grep -c '^extProcessor' "$CONF" 2>/dev/null || true)
run 09 "独立 PHP 池（3 子进程）" wp-cluster isolate "$D2" --php-pool 3
EXT_AFTER=$(grep -c '^extProcessor' "$CONF" 2>/dev/null || true)
[ "$LAST_RC" -eq 0 ] && ok "隔离返回 0" || bad "隔离返回 $LAST_RC"
[ "$EXT_AFTER" -gt "$EXT_BEFORE" ] && ok "独立池已创建（$EXT_BEFORE → $EXT_AFTER）" || bad "池数量未增加"
C2B=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$U2/?wpcluster-check=$RANDOM$RANDOM" 2>/dev/null)
[ "$C2B" = "200" ] && ok "隔离后站点仍 200" || bad "隔离后 HTTP $C2B"

run 10 "CF 优选测速（只读）" wp-cluster cf probe
[ "$LAST_RC" -eq 0 ] && ok "probe 返回 0" || bad "probe 返回 $LAST_RC"
grep -qiE 'TTFB|优选|目标|域名' "$OUT.clean" && ok "输出含测速表" || bad "输出不含测速表"

run 11 "删除 demo2" wp-cluster remove "$D2" --yes
[ "$LAST_RC" -eq 0 ] && ok "删除返回 0" || bad "删除返回 $LAST_RC"
[ ! -d "/var/www/$D2" ] && ok "目录已删" || bad "目录残留"
[ ! -e "/etc/wp-cluster/sites/$D2.env" ] && ok "注册表已删" || bad "注册表残留"
grep -q 'lsphp_demo2' "$CONF" && bad "独立 PHP 池残留" || ok "独立 PHP 池已随站清理"

# -----------------------------------------------------------------------------
printf '\n===== 收尾：清理 %s =====\n' "$D3"
wp-cluster remove "$D3" --yes >"$OUT" 2>&1; echo "    rc=$?"
printf '\n===== 收尾：全站健康 =====\n'
wp-cluster health --all | tail -10
printf '\n===== 收尾：完整性 / 资源 / 残留 =====\n'
wp-cluster verify | grep -E '文件数量|核验' | head -3
wp-cluster status | tail -3
ls /tmp/lshttpd/*.sock 2>/dev/null

printf '\n'
printf '%.0s─' {1..70}; echo
printf '  通过 %s · 失败 %s\n' "$PASS" "$FAIL"
if [ "${#FAILED[@]}" -gt 0 ]; then printf '  %s失败项%s\n' "$C_R" "$C_0"; printf '   - %s\n' "${FAILED[@]}"; fi
printf '%.0s─' {1..70}; echo
rm -rf "$TMP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
