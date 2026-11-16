# wp-cluster

在一台低配 VPS 上批量部署**互相独立**的 WordPress 站点，并为每站提供完整的运维生命周期（建站 → 健康检查 → 备份 → 恢复 → 升级 → 删除）。

技术栈：**OpenLiteSpeed + LSPHP 8.3 + SQLite + APCu + LSCache**，可选 Cloudflare。
不是 WordPress Multisite —— 每站独立的目录、数据库、缓存盐、vhost，互不影响。

```
wp-cluster 2.2.0
```

[![Platform](https://img.shields.io/badge/platform-Debian%2011%2F12%2F13%20%7C%20Ubuntu%2020.04%2B-2b7489)](#环境要求)
[![Shell](https://img.shields.io/badge/shell-bash%205%2B-4EAA25)](#环境要求)
[![Tests](https://img.shields.io/badge/tests-119%20passed-brightgreen)](tests/regression.sh)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

---

## 一行安装

在干净的 Debian / Ubuntu 上（root）：

```bash
cd /home && URL='https://raw.githubusercontent.com/jiaoben123/wp-cluster/main/install-wp-cluster.sh' && curl -fsSL "$URL" -o install-wp-cluster.sh && chmod 700 install-wp-cluster.sh && printf '%s\n' "$URL" > /home/.wp-cluster-update-url && chmod 600 /home/.wp-cluster-update-url && ./install-wp-cluster.sh
```

它会做四件事，全部幂等（可重复执行）：

1. 装 OpenLiteSpeed + LSPHP 8.3（含 apcu / opcache / sqlite3 / intl）+ WP-CLI；
2. 从本仓库拉取 `wp-cluster` 装到 `/usr/local/bin/`，配置样板写到 `/etc/wp-cluster/`；
3. 播种一个模板站（`/var/www/wp-template`），作为所有新站的硬链接样板；
4. 初始化共享核心、日志轮转，并跑一次环境自检。

装完直接：

```bash
wp-cluster doctor                             # 环境自检
wp-cluster add blog.example.com               # 建站（域名模式，默认 noindex）
wp-cluster add test.example.com --mode port    # 无域名也能先跑起来
wp-cluster list --check                        # 清单 + HTTP 探测
```

常用可选参数（先下载脚本再执行）：

```bash
bash install-wp-cluster.sh --check                 # 只体检，不动系统
bash install-wp-cluster.sh --upgrade               # 只更新工具本体
bash install-wp-cluster.sh --domain a.com --email you@a.com   # 装完顺便建首站
```

已有环境（Apache/Nginx 或别的面板）请勿直接覆盖：`--check` 看完输出再决定，混装会抢 80/443。

---

## 环境要求

| 项目 | 最低 | 建议 |
|---|---|---|
| 系统 | Debian 11 / Ubuntu 20.04 | Debian 12/13、Ubuntu 22.04/24.04 |
| 内存 | 512MB（必须带 swap） | 1GB+ |
| 磁盘 | 4GB | 20GB+ |
| 架构 | x86_64 / arm64 | 同左 |

单核 1.4G 实测可稳跑 6–7 个站；扩容按「新增一站约 0.5MB 磁盘」估算。

---

## 为什么不用 Docker

这套栈跑在 **1 核 / 1.4G** 的机器上，Docker 的固定开销占比过高（实测与估算见 [docs/DOCKER-VS-NATIVE.md](docs/DOCKER-VS-NATIVE.md)）：

| 项目 | 本方案（原生） | Docker + MariaDB + Redis |
|---|---|---|
| 常驻内存 | OLS 3 进程 21MB + PHP 按需 | dockerd 80–150MB + MariaDB 120–200MB + Redis 10–30MB |
| 新增 1 个站的磁盘 | **约 0.5MB**（核心硬链接共享） | 50–60MB 起（核心无法跨容器共享） |
| 单站 WP 核心 | 101MB 全站只存一份 | 每容器一份镜像层或卷 |

结论：**单机、站点数量 5–50、内存 ≤ 4G → 原生更划算**；需要跨机编排、镜像回滚、多人协作 → 再用 Docker/K8s。

> 兼容性用工程手段兜底：`doctor` 校验 OS/扩展/路径，配置改动全部"先备份 → 再校验 → 失败回滚"，`--dry-run` 可预演。已在 Debian 12/13、Ubuntu 22.04/24.04 验证。

---

## 快速开始

```bash
# 0. 一行安装（已装过则跳过）；也可在解压目录里 sudo ./install.sh
cd /home && URL='https://raw.githubusercontent.com/jiaoben123/wp-cluster/main/install-wp-cluster.sh' && curl -fsSL "$URL" -o install-wp-cluster.sh && chmod 700 install-wp-cluster.sh && ./install-wp-cluster.sh

# 1. 自检
wp-cluster doctor

# 2. 初始化（建立共享核心、状态目录、日志轮转）——安装器已自动执行
wp-cluster init

# 3. 接管机器上已有的 WordPress 站点
wp-cluster import --all

# 4. 新建站点
wp-cluster add shop1.example.com              # 端口模式，默认 noindex
wp-cluster add blog.example.com --mode domain --ssl --index --email 你的邮箱

# 5. 日常
wp-cluster list --check
wp-cluster health --all
wp-cluster backup --all
```

---

## 命令

### 部署

| 命令 | 说明 |
|---|---|
| `init` | 初始化目录、共享核心、mu-plugin、日志轮转 |
| `import --all \| import <域>` | 接管已存在的站点（生成注册表） |
| `add <域> [选项]` | 新建站点 |
| `doctor [--fix]` | 环境自检，`--fix` 修复目录权限 |

`add` 选项：

| 选项 | 说明 |
|---|---|
| `--mode port\|domain` | 端口模式（默认，测试用）或域名模式（共享 80/443） |
| `--port N` | 指定端口，默认自动分配 `8100-8199` |
| `--index` | 允许收录；默认 noindex |
| `--ssl` | 域名模式下签发 Let's Encrypt（需 80 端口可达） |
| `--minimal` | 只激活核心三件插件（`mu-plugins` 仍复制，主题/页面构建器依赖它们；换成不含 mu-plugins 的模板站才真正省内存） |
| `--with-demo` | 生成演示文章/页面 |
| `--title / --admin-user / --admin-email / --php-memory` | 站点元信息 |

### 查看

| 命令 | 说明 |
|---|---|
| `list [--check] [--json]` | 站点清单，`--check` 附带 HTTP 探测 |
| `info <域> [--json]` | 详情（含后台密码，仅 root 可读） |
| `status [--json]` | 整机资源与站群规模 |
| `health [域\|--all] [--json]` | 健康检查，有异常返回非 0 |

### 运维

| 命令 | 说明 |
|---|---|
| `enable / disable <域>` | 切换收录（不重启 OLS） |
| `purge <域>\|--all` | 清 LSCache |
| `ssl <域> --email <邮箱> [--force]` | 签发/续签证书 |
| `backup <域>\|--all [--type daily\|weekly\|monthly\|manual]` | 备份 |
| `restore <域> <文件> [--yes]` | 恢复（校验和 + 路径穿越检查 + 原子替换） |
| `export <域> [-o 文件]` | 导出可迁移整站包（库 + 文件 + 清单 + 校验和） |
| `adopt <包> --domain <新域>` | 在任意机器/新域名下接管整站（自动换域名、换盐、换库路径） |
| `upgrade <域>\|--all` | 升级核心/插件 |
| `logs [域] [-n N]` | 日志 |
| `remove <域> [--purge]` | 删除站点 |
| `cron install\|remove\|status` | 自动备份计划 |
| `self-update` | 更新工具本身 |
| `uninstall [--purge]` | 卸载 |

### 隔离与守护

| 命令 | 说明 |
|---|---|
| `verify [--baseline]` | 共享核心完整性校验（防单站污染全站），有漂移返回 7 |
| `isolate <域> [--core] [--php-pool N] [--undo]` | 单站隔离：拆核心硬链接 / 独立 PHP 进程池 |
| `guard install\|remove\|status\|run` | systemd timer 巡检，OLS 挂了自动重启，异常写日志 |

### Cloudflare

| 命令 | 说明 |
|---|---|
| `cf status [域\|--all]` | 解析 IP / 落地节点 / TLS / TTFB / 是否橙云 / CF 缓存 |
| `cf probe [--targets a,b] [--rounds N]` | 优选域名延迟实测并按 TTFB 排序 |
| `cf plan <域> [--all]` | 生成 SaaS 自定义主机名（优选 IP）接入步骤与 DNS 清单 |

### 全局选项

`--dry-run` `--json` `--yes` `--quiet` `--verbose` `--no-color` `--config <文件>` `--trace`

### 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 一般失败 |
| 2 | 参数错误 |
| 3 | 前置条件不满足 |
| 4 | 已存在 |
| 5 | 不存在 |
| 6 | 锁冲突 |
| 7 | 配置校验失败 |
| 8 | 外部命令失败 |

---

## 文件布局

仓库：

```
wp-cluster/
├── install-wp-cluster.sh       # 一行安装入口：装环境 + 装本体 + 播种模板站 + init
├── install.sh                  # 本机安装器：装二进制 / 建目录 / 写配置样板 / 自检
├── wp-cluster                  # 主程序（单文件 bash，无第三方依赖）
├── conf/wp-cluster.conf.example
├── docs/                       # 架构、容器对比、故障隔离、站点迁移、CF 优选
├── tests/regression.sh         # 回归套件（13 组 119 项断言）
└── tests/walkthrough.sh        # 用户旅程（11 步真实操作）
```

运行期：

```
/var/www/
├── wp-core/                    # 共享核心（硬链接源，101MB 一份）
├── <domain>/                   # 站点根目录（核心与 wp-core 共享 inode）
│   ├── wp-config.php           # 独立 SQLite 路径 + 独立缓存盐
│   ├── wp-content/
│   │   ├── plugins/ themes/    # 硬链接自模板站
│   │   ├── mu-plugins/         # 模板 mu-plugins + noindex 守卫
│   │   ├── uploads/            # 独享
│   │   └── db.php              # SQLite drop-in
│   └── logs/
└── db/
    └── <slug>.sqlite           # 每站独立数据库（web 根之外）

/etc/wp-cluster/
├── wp-cluster.conf             # 配置（可选）
├── sites/<domain>.env          # 状态注册表（600）
├── core.sha256                 # 核心完整性基线（verify --baseline 生成）
└── mu-plugins/wp-cluster-noindex.php

/var/backups/wp-cluster/<domain>/<domain>-<type>-<时间戳>.tar.gz     # 本机回滚用
/var/backups/wp-cluster/<domain>/<domain>-export-<时间戳>.tar.gz     # 跨机迁移用
/var/log/wp-cluster/{wp-cluster,wp-cli,guard,acme,cron}.log
/var/lib/wp-cluster/guard/<domain>.fail                              # guard 连续失败计数
```

---

## 配置

复制 `conf/wp-cluster.conf.example` 到 `/etc/wp-cluster/wp-cluster.conf` 后按需修改，未设置项使用内置默认值。

```bash
WWW_ROOT=/var/www
TEMPLATE_SITE=                 # 留空自动探测（按 mu-plugins/插件/主题/媒体打分）
TEMPLATE_STRIP_MU=force-noindex.php   # 建站时跳过的模板 mu-plugin（它会压过收录开关）
PORT_START=8100
BACKUP_DAILY_KEEP=7

POOL_CHILDREN_DEFAULT=3        # isolate --php-pool 默认子进程数
GUARD_INTERVAL=5min            # guard 巡检间隔
GUARD_FAIL_THRESHOLD=3         # 连续失败几次记 CRITICAL
CF_PROBE_TARGETS=cf.090227.xyz,cf-cname.xingpingcn.top,...
```

> `TEMPLATE_STRIP_MU` 只写文件名、可逗号分隔多个。模板站如果自带「无条件 noindex」的 mu-plugin，
> 不跳过它的话，`wp-cluster enable` 会把注册表改成「允许收录」但页面依旧 noindex。

---

## 测试

```bash
bash tests/regression.sh --full   # 全量：13 组 119 项，含建站/备份/迁移/隔离/锁，约 3–4 分钟
bash tests/regression.sh --fast   # 跳过 export/adopt 迁移演练
bash tests/walkthrough.sh         # 用户旅程：按下面「明天怎么体验」的 11 条命令逐条真跑，33 项断言
```

套件只创建并删除 `zzreg1/zzreg2` 两个临时站，不触碰生产站；断言失败会列出「期望/实际」，
并在 `KEEP=1 bash tests/regression.sh` 时保留现场。覆盖：静态检查、只读命令、JSON 契约、
退出码（2/4/5/6/7）、dry-run 零落盘、收录开关、LSCache、备份恢复、跨域名接管、核心漂移检测、
PHP 池隔离与撤销、guard 巡检、锁冲突、删除后残留检查。

`walkthrough.sh` 更贴近真实使用：它跑的就是运维手册那 11 条命令，并额外验证「输出不泄露后台密码」、
「dry-run 前后配置 md5 一致」、「删除时独立 PHP 池随之清理」。

---

## 专项文档

| 文档 | 内容 |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 设计取舍、状态机、失败回滚 |
| [docs/DOCKER-VS-NATIVE.md](docs/DOCKER-VS-NATIVE.md) | 为什么不用 Docker（含实测数据） |
| [docs/FAULT-ISOLATION.md](docs/FAULT-ISOLATION.md) | **故障隔离**：共享边界、故障矩阵、三种隔离动作、边界说明 |
| [docs/SITE-MIGRATION.md](docs/SITE-MIGRATION.md) | **备份/恢复/单站迁移**：export/adopt 全流程与踩坑 |
| [docs/CF-OPTIMIZED-IP.md](docs/CF-OPTIMIZED-IP.md) | **CF 优选 IP**：SaaS 自定义主机名 7 步、额度、站群批量、监控回滚 |

---

## 运维手册

**每日**：`wp-cluster health --all`（可接监控，非 0 即异常）、`wp-cluster verify`

**每周**：`wp-cluster list --check`、看一眼 `status` 的 Swap 与负载

**每月**：`wp-cluster upgrade --all`，升级前先 `backup --all`；升级后 `verify --baseline` 重建基线

**扩容**：直接 `add`，新站只占 ~0.5MB 磁盘；关注 `status` 里 LSPHP 进程数与 Swap

**迁移单站**：`export <域>` → scp 导出包 → 目标机 `adopt <包> --domain <域>`

**隔离重点站**：`isolate <域> --php-pool 3`；疑被入侵时 `isolate <域> --core`

**自愈**：`guard install` 一次即可，之后每 5 分钟自动巡检

**证书续期**：acme.sh 自带 cron，`health` 能看到剩余天数，<14 天会标 warn

---

## 安全说明

- 状态文件含后台密码，权限 `600`，`/etc/wp-cluster` 目录 `700`。
- 站点数据库放在 web 根之外（`/var/www/db`），无法被直接下载。
- 默认 `noindex`，避免测试站被搜索引擎收录。
- 默认 `DISALLOW_FILE_EDIT`、`AUTOMATIC_UPDATER_DISABLED`。
- vhost 默认带 HSTS / CSP / X-Frame-Options / Permissions-Policy / Referrer-Policy。
- 删除站点、恢复覆盖、卸载清空都需要输入域名或确认词。

---

## 已知限制

- 仅验证 Debian 12/13、Ubuntu 22.04/24.04 + OpenLiteSpeed 官方源。
- `ssl` 要求域名已解析到本机且 80 端口可访问；Cloudflare 橙云下需 `--force` 并确认回源正常。
- 模板克隆只复制代码骨架，不含数据库内容与 uploads。
- 硬链接共享核心：**不要**在单个站点里升级 WP 核心（`wp core update` 会替换 inode），`upgrade` 命令已按站隔离处理，跨站升级请统一执行 `upgrade --all`。
- SQLite 方案下 `wp db query` / `wp db export` 不可用（它们依赖 `mysql` 客户端）。查库请用 `sqlite3` 或 PDO；备份请用 `wp-cluster backup`（内部用 `VACUUM INTO` 快照，不依赖 mysql 客户端）。
- 模板站自带的「本地主机守卫」类 mu-plugin 会对 `127.0.0.1` 强制 noindex（防止误收录测试站）。验证收录状态请用站点自己的 `home_url` 访问，不要用 `127.0.0.1`。
- 自己写验活 / 绕缓存的 URL 时，**避开 `w`、`p`、`s` 等 WordPress 保留查询变量**：`?w=28471` 会被当成按周归档渲染 404，`?p=1` 会 301 到文章固定链接。工具内部用 `?wpcluster-verify=`，不受影响。

---

## 许可证

MIT，见 [LICENSE](LICENSE)。商用、二次分发、改造成自己的面板都可以，保留版权声明即可。

## 交流

- 发现 bug / 想要新功能：[开 issue](https://github.com/jiaoben123/wp-cluster/issues)
- 安全问题请勿公开开 issue，邮件联系仓库所有者
