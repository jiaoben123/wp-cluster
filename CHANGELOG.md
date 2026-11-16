# Changelog

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [2.3.0] - 2026-11-16

运行时调优，一档「性能优先」。全部结论来自 1 核 / 1469MB / 6 站本机实测
（详见 `docs/TECH-STACK.md` 第 7 节）。

### 新增
- **`wp-cluster tune [--apply] [--yes] [--no-jit] [--json]`**：PHP 运行时体检与调优。
  - 只读模式打印 php.ini / APCu ini 路径、站点数、LSPHP 进程池 PSS，以及 11 项参数的
    「当前值 → 建议值」；
  - `--apply` 幂等写入 php.ini 与 `mods-available/40-apcu.ini`（各自自动备份，
    重复执行不会产生重复块）；
  - `--yes` 追加 `pkill -x lsphp` 让新配置生效（OLS 自动重拉，站点瞬断 1–2 秒）；
  - `--no-jit` 关闭 JIT（默认开）；`--json` 供脚本消费。
- **`install-wp-cluster.sh` 装完即调优**：`tune_php_ini()` 写入同一套性能优先档，
  php.ini 与 APCu ini 分开处理，已存在则跳过。

### 性能优先档（2–6 站 / 1 核）
| 参数 | 默认 | 本项目 |
|---|---|---|
| `opcache.memory_consumption` | 128 | **384**（≤12 站统一 384，之后 512 / 768） |
| `opcache.interned_strings_buffer` | 8 | **32** |
| `opcache.max_accelerated_files` | 10000 | **40000** |
| `opcache.revalidate_freq` | 2 | **60** |
| `opcache.jit_buffer_size` | 0 | **128M** |
| `realpath_cache_size` / `_ttl` | 4096K / 120 | **16384K / 600** |
| `memory_limit` | 128M | **256M** |
| `apc.shm_size` / `apc.ttl` / `entries_hint` | 128M / 7200 / 8192 | **256M / 0 / 16384** |

共享段（OPcache / APCu）都是 mmap 匿名页、按需缺页分配，声明大段不等于立刻占物理内存：
6 站灌满后 OPcache 实际只用了 64–81MB。所以按「2 站够用」配 128MB 是白亏。

### 变更
- **`doctor` 增加「OPcache 容量」检查**：低于站点数推算值时给警告并提示 `wp-cluster tune --apply`。

### 实测依据
- **拆掉第二套缓存是最大一笔**：四站同时激活 `litespeed-cache` + `flying-press` +
  `nginx-helper`，FlyingPress 抢不到 `advanced-cache.php` 却每请求白跑一遍，还在
  `src/Optimizer.php:22-23` 硬编码 `Cache-Control: no-store`，把 LSCache 和 Cloudflare
  边缘缓存一起废掉。停用后动态路径 **+33%**。
- **JIT 推翻上一版结论**：上一版写「1 核上 JIT 收益极小、保持关闭」，实测是错的。
  开→关→开→关→开 交替五轮（每轮重启 + 预热 20 次 + 40 请求）：`work_ms` 0.46–0.52 vs
  0.69–0.72（**−35%**，零重叠）、`load_ms` 中位 32.4 vs 37.1（**−12%**）、
  串行 RPS 中位 26.3 vs 23.3（**+13%**）。128M 比 64M 略好，缓冲区按需分配
  （实际只占 0.9MB），故默认 128M。
- **OPcache 扩容 / realpath / memory_limit / APCu 扩容测不出吞吐差异**（命中率本已 99.7%、
  wasted 0），价值在「不再逼近写满」和「后台重活不白屏」，不冒充提速。
- 最终（同站多轮）：动态串行 16.7 → 24.7–26.6 RPS（中位 25.5，**+53%**）、
  p50 55.3 → 37.5ms；并发 c=8 15.0 → 21.9–25.5 RPS、p95 669.9 → 358–540ms；
  整页缓存 708 → 647–783（同量级，PHP 不参与）。
- **PHP 子进程数保持 10**：`PHP_LSAPI_CHILDREN=6` 省 70MB PSS，但并发 p95 从 440–485ms
  恶化到 568–654ms，1 核机器上不划算。
- **SQLite `cache_size` 不动**：库仅 0.6–0.7MB（ww2 12.5MB），2MB 页缓存够用；page cache
  是每连接一份，调大会按子进程数成倍放大。

## [2.2.0] - 2026-11-16

首次公开发布。新增一键安装器与自更新地址标记文件，仓库化（README / LICENSE / .gitignore）。

### 新增
- **`install-wp-cluster.sh` 一键安装器**：在干净的 Debian / Ubuntu 上从零装出整套原生栈，
  幂等可重复执行。
  - 依赖安装：`curl ca-certificates tar unzip python3 openssl cron logrotate rsync`；
  - OpenLiteSpeed：官方源 + `openlitespeed` 包，缺 `extProcessor lsphp` 时自动补全；
  - LSPHP 8.3：`lsphp83` + common/curl/sqlite3/mysql/opcache/apcu/intl/igbinary，
    并建 `/usr/local/bin/php` 软链（wp-cli 的 phar 头依赖 `env php`）；
  - WP-CLI：官方 phar 直装；
  - **模板站播种**：核心下载 → 直接解压 sqlite-database-integration 的官方 zip（避免 drop-in
    就位前 bootstrap WordPress 去连 MySQL）→ 生成 `db.php` 与 `wp-config.php`（`DB_PATH`
    指向 `/var/www/db/template.sqlite`）→ `wp core install` → 装 litespeed-cache / apcu-manager；
  - 其他：`--check` 只体检、`--upgrade` 只更新本体、`--domain/--email/--title` 装完顺便建首站、
    失败自动打印日志尾部（`/var/log/wp-cluster-install.log`）。
- **自更新地址标记文件**：`/home/.wp-cluster-update-url`（一行命令写入，600）与
  `/etc/wp-cluster/update-url`。`resolve_update_url()` 解析顺序：环境变量 → 配置 →
  标记文件 → 内置默认，换仓库/换分支无需改代码。
- 仓库文件：`LICENSE`（MIT）、`.gitignore`、README 增加「一行安装 / 环境要求 / 许可证」。

### 修复（首次公开前的自查）
- **安装器 root 下误报「安装中断」**：`wp --version` 以 root 运行会拒绝执行（需要 `--allow-root`），
  命令替换失败触发 ERR trap，打印「已安装：」后跟空版本号。抽出 `wp_cli_version()` 助手，
  带 `--allow-root` 且在子 shell 内关掉 `errexit/pipefail`，失败不再打断流程；`--check` 段同步改用。
- **`fetch_repo` 漏拷安装器**：`/root/wp-cluster` 里缺 `install-wp-cluster.sh`，目录不完整。
- **`self-update` 增加地址来源提示**：输出「来源：环境变量 / 配置文件 / 标记文件路径 / 内置默认」。
  配置文件里残留的旧 `SELF_UPDATE_URL` 优先级高于标记文件，会静默盖掉新地址；安装器在写入标记后
  会检测并告警。
- **`enable` / `disable` 收录开关被 APCu 对象缓存挡住**（ww2 实测发现）：站点装了
  `apcu-manager` 的 `object-cache.php` drop-in 时，wp-cli 与 LSPHP 的 APCu 是两个进程空间，
  `wp cache flush` 只清得到 CLI 那份，`litespeed-purge all` 只清页面缓存。于是 `wp-cluster enable`
  改完 `blog_public=1` 后，前端仍读到缓存里的 0 —— 继续 `noindex,nofollow`、sitemap 为空，
  命令还把原因误判为「有其它插件在写 robots」。新增 `web_flush_object_cache()`：临时放一个带
  key 校验的探针，经站点 URL 由 **Web 进程**执行 `wp_cache_flush()` + `apcu_clear_cache()`
  （多次请求覆盖 fork 出的多个 LSPHP 子进程），用完即删。告警文案改为按「对象缓存 → mu-plugin
  → wp-config 常量」顺序排查。实测 `enable` → `index, follow, max-snippet:-1` + 6 张子 sitemap，
  `disable` → `noindex, nofollow` + 空 sitemap，可完整还原。

### 文档修正与实测（2026-11-16 补）
- **纠正「默认新站没有对象缓存」的错误描述**：`wp-cluster add` 实际会写 `apcm_earlyloading=1`，
  `apcu-manager` 在新站首次 Web 请求时自动安装 `object-cache.php` drop-in，APCu 默认接管 WP 对象缓存。
  README / `docs/TECH-STACK.md` / `docs/ARCHITECTURE.md` 里「apcu-manager 只作统计面板」「默认新站没有这层」
  等表述已改正；`SQLite Object Cache` 仍未安装、不属于本方案。
- **补做对象缓存开 / 关 A/B/C 实测**：无对象缓存 / APCu drop-in / LSCache+Redis 三组，两轮反向顺序、
  探针自证分组，完整数据见 `docs/TECH-STACK.md` 第 6 节。结论：动态路径下 APCu 相对无缓存串行 RPS +26%、
  并发 p95 −38%；Redis 与 APCu 基本持平却要多一个常驻服务，因此维持「LSCache 对象缓存模块关闭」。
  测试用的临时站、Redis 包、探针已全部清理，6 站 HTTP 200、`doctor` 全项通过。

### 变更
- `SELF_UPDATE_URL` 默认值改为空，交由 `resolve_update_url()` 解析；默认指向
  `jiaoben123/wp-cluster@main`。
- README 快速开始改为「一行安装优先」，并补仓库文件布局。

### 未变
- 主程序功能与 2.1.2 一致（119 项回归断言全通过）。

## [2.1.2] - 2026-11-16

按用户实际操作的 11 步命令清单做「用户旅程实测」，并修掉实测中看到的一个显示问题。

### 修复

- **`cf probe` 把不可达目标显示成 `999.000s`**：`999` 是程序内部的「不可达」哨兵值，原样进表格会让人误以为真测出了 999 秒延迟。现在不可达目标的 TLS 握手 / TTFB 显示 `n/a`，状态列仍是「不可达」。

### 新增：用户旅程实测脚本

- `tests/walkthrough.sh`：按 README「明天怎么体验」的 11 条命令逐条真跑（doctor → list --check → add --dry-run → add → info → backup → export → adopt → isolate → cf probe → remove），每步记录退出码、耗时、关键输出，并做 33 项断言。
- 只创建 `demo2` / `demo3` 两个临时站，跑完自动删除；**所有输出三重脱敏**（格式打码 + 长随机串打码 + 注册表真实密码字面替换），并断言「真实密码不得出现在回显」。
- 脚本内置防呆：命令必须作为独立参数传入 `run()`，否则报错而不是空跑假通过。
- 实测结果：**33 项断言全部通过，0 失败**（建站 17s、备份 5s、导出 7s、跨域名接管 29s、隔离 5s、CF 测速 4s）。

### 实测中记下的两个知识点（非缺陷）

- 验活/绕缓存的 query 参数**不要用 `w`、`p` 等 WP 保留查询变量**：`?w=28471` 会被 WordPress 当「按周归档」渲染成 404 页面，`?p=1` 会 301 到文章 permalink。工具内部用的是 `?wpcluster-verify=`，已避开。
- `add` / `adopt` 的输出会直接打印新生成的后台密码，做日志/截图时必须脱敏。

## [2.1.1] - 2026-11-16

主题：**全量回归测试 + 修掉 2.1.0 的 5 个真实缺陷**。新增 `tests/regression.sh`（9 组 119 项断言），
在 1 核 / 1.4G / 7 站环境连续跑通。以下缺陷均由该套件发现，先复现再修。

### 修复

- **`add --dry-run` 会真的改 OLS 配置**：`ols_txn()` 把 `ols_conf` 的写操作直接放行，dry-run 下仍会写入
  `listener` / `virtualHost` 块。后果是「试跑一次」就把端口永久占住，之后真正建站报「端口已被占用」。
  现在 dry-run 在 `ols_txn()` 处早退（实测 dry-run 前后 `httpd_config.conf` 的 md5 完全一致）。
- **dry-run 在验收阶段假失败**：`check_url` 只在非 dry-run 分支赋值，dry-run 拿到空串算出 0 字节，
  误判「空白页 / 主题未激活」→ 触发回滚并退出码 8。现在 dry-run 打印建站计划后直接返回 0。
- **`remove` 残留独立 PHP 池**：`isolate --php-pool` 建的 `extProcessor lsphp_<slug>` 不会被删除，
  留在 OLS 配置里占 socket，且同名站点重建时会被误判「已隔离」。`remove` 与 `uninstall --purge`
  现在一并清理（先摘 vhost 再删池，避免悬空 handler 校验失败）。
- **`enable` 对模板站无效**：模板自带的无条件 noindex mu-plugin（`force-noindex.php`）优先级高于收录开关，
  导致 `enable` 之后页面依然 `noindex`。新增配置 `TEMPLATE_STRIP_MU`（默认 `force-noindex.php`），
  建站与接管时自动跳过；`enable` 若仍检测到 noindex，会列出可疑的 mu-plugin/插件并给出处理办法。
- **`info` 不显示站点标题**：补「标题」行（读 `blogname`，失败回退注册表），`--json` 新增 `title` 字段。
- **`guard run` 正常时不留日志**：无法区分「没跑」和「全好」。现在无异常也写一行心跳
  `[OK] 巡检通过 sites=N`，`guard status` 能直接看到最近一次巡检时间。

### 改进

- `enable` 的 robots 检测同时兼容单引号与双引号两种 meta 写法（WP 核心 `<meta name='robots'>` 与
  Rank Math `<meta name="robots">` 格式不同，原先只认后者）。
- 模板站 ww2 的收录状态改由 wp-cluster 开关接管（`wp-config.php` 常量），并移除遗留的 `force-noindex.php`，
  避免「模板自带硬编码 noindex → 所有新站永远无法收录」。

### 测试

- 新增 `tests/regression.sh`：静态检查 / 只读命令 / JSON 契约 / 参数与退出码 / dry-run 不落盘 /
  建站 / 收录与缓存 / 备份恢复 / 导出接管 / 隔离 / 守护 / 锁 / 删除清理。
  只创建并删除 `zzreg*` 临时站，失败自动保留现场（`KEEP=1`）。
  用法：`bash tests/regression.sh --full`（`--fast` 跳过迁移演练）。

## [2.1.0] - 2026-11-16

主题：**故障隔离 + 单站可迁移 + CF 优选集成**。全部命令在 1 核 / 1.4G / 6 站环境实测通过。

### 新增：故障隔离

- **`verify`**：共享核心完整性基线。`--baseline` 生成 `/etc/wp-cluster/core.sha256`（实测 3338 个文件），日常 `verify` 比对漂移（有差异退出码 7），并列出每站「核心是否共享 / 独立库是否存在 / 收录状态」。解决「硬链接共享导致单站改核心=全站被污染」的检测问题。
- **`isolate <域> --php-pool N`**：为该站创建独立 `extProcessor`（独立 socket + 独立子进程数）并在 vhost 里挂 `scripthandler`，一个站打满不再抢其他站的 PHP 子进程。实测 demo 站独立 lsphp 进程 56MB、站点 200、撤销后回到全局池。
- **`isolate <域> --core`**：拆分该站与共享核心的硬链接（实测 8006 个文件、磁盘 +200MB、本站 200、其他站不受影响）。用于单站被入侵或需独立核心版本。
- **`isolate <域> --undo`**：撤销 PHP 池隔离（顺序：先摘 vhost `scripthandler` → 校验 → 删 extProcessor → 重启 → 清 socket）。
- **`guard install|remove|status|run`**：systemd timer 每 5 分钟巡检，OLS 不 active 就重启，逐站 HTTP 探测，连续 3 次失败记 CRITICAL，恢复记 RECOVER，写 `guard.log`（已纳入 logrotate）。不做自动删站/改配置。

### 新增：单站导出与接管

- **`export <域> [-o 文件]`**：导出可迁移整站包（`database.sqlite` + `files.tar.gz` + `manifest.json` + `SHA256SUMS`）。实测 ww2（12.4MB 库 / 431 媒体）→ 33MB。
- **`adopt <包> --domain <新域> [--mode] [--port] [--index] [--ssl]`**：在任意机器/新域名下接管整站。复用 `add` 全流程建骨架，再替换库与文件、修正 `db.php` 绝对路径、重生成 wp-config（新盐）、`search-replace` 换域名、重激活插件主题、探测 200。实测 ww2 → m1.vitden.com：2087 处替换、180 篇文章、431 媒体、HTTP 200。

### 新增：Cloudflare

- **`cf status [域|--all]`**：解析 IP、落地节点（colo）、TLS 版本、TLS 握手、TTFB、是否橙云、CF 缓存状态。不用 token，只读。
- **`cf probe`**：对候选优选域名做多轮实测并按 TTFB 排序，标注不可达；候选列表可配置（默认 6 个社区优选域名）。
- **`cf plan <域> [--all]`**：生成 SaaS 自定义主机名（优选 IP）的完整接入步骤与站群 DNS 清单。

### 修复

- **`restore` / `adopt` 覆盖数据库会损坏**：`cp` 原地截断在线库 + OLS restart 强杀 PHP 子进程留下 hot journal，下次打开回滚成结构错乱的库（报 `malformed database schema` / `Cannot escape data without an active database connection`）。改为 `replace_db()`：清 journal → 写临时文件（新 inode）→ 原子 `mv` → 再清 journal，并用 `PRAGMA quick_check` 验收。
- **`isolate --undo` 必然失败**：先删 `extProcessor` 再摘 vhost 引用，OLS 校验报悬空 handler 并回滚。改为先摘引用。
- **`add` 会建出「200 但空白」的站**：主题激活失败或模板无活动主题时，WordPress 返回 200 + 0 字节，旧验收只看状态码判为成功。现在：① 无活动主题直接回滚报错；② 验收增加 `size_download ≥ 500` 判断；③ `health` 新增「响应」列，200 但 body < 500 字节判 fail。
- **`--minimal` 导致主题 500**：只激活核心插件但主题（shindar）依赖模板站的 85 个 mu-plugins。改为 mu-plugins 始终复制，`--minimal` 仅控制普通插件；实测 `--minimal` 新建站 185KB 正常渲染、缓存 hit。
- `export` 的 `manifest.json` 中 `php_version` 误取 Python 版本，改为实际 LSPHP 版本。

### 文档

- 新增 `docs/FAULT-ISOLATION.md`（共享边界、9 类故障矩阵、三种隔离动作、能力边界）。
- 新增 `docs/SITE-MIGRATION.md`（backup/export/adopt 区别、整机迁移顺序、4 个踩坑）。
- 新增 `docs/CF-OPTIMIZED-IP.md`（SaaS 优选原理、三条路线对比、7 步配置、额度、站群批量、监控回滚、风险）。

## [2.0.0] - 2026-11-15

从"一次性建站脚本"重写为可长期运维的工具。

### 新增

- **状态注册表** `/etc/wp-cluster/sites/<domain>.env`：工具只信注册表，不再反向解析 OLS 配置；每站字段含模式、端口、URL、索引状态、SSL、库路径、创建时间。
- **`import`**：接管历史站点（本机已存在的 6 个站可一次性纳入管理），支持 unquoted 的历史文件。
- **`doctor`**：15 项环境自检（OS/OLS/LSPHP 扩展/lsws 服务/wp-cli/模板站/配置语法/磁盘/Swap/权限/依赖），支持 `--fix` 修复目录权限；退出码可直接接监控。
- **`health`**：HTTP 状态、TTFB、LSCache 命中、证书剩余天数、WP 版本，任一站点异常时整体返回非 0。
- **`backup` / `restore`**：SQLite 用 `VACUUM INTO` 做一致性快照（非直接拷贝），打包含 `manifest.txt` + `SHA256SUMS`，恢复前校验校验和与路径穿越；自动保留日/周/月三档槽位。
- **`cron install`**：每日 03:30 / 每周日 04:15 / 每月 1 日 04:45 自动备份，日志轮转文件一并安装。
- **`ssl`**：acme.sh 签发，**申请前先做 HTTP-01 真实探测**，探测失败直接退出，避免触发 Let's Encrypt 频率限制。
- **`enable` / `disable`**：通过 `WP_CLUSTER_NOINDEX` 常量 + mu-plugin 切换收录，无需重启 OLS（重启会影响全部站点）。
- **`upgrade`**：核心 + 插件 + `update-db` 批量升级并回写版本号。
- **`self-update`**：下载后 `bash -n` 语法校验 + 特征串校验，通过才替换，失败不动原文件。
- **`uninstall`**：分"卸载工具"与"连站点一起删"两档，后者需手输确认词。
- **全局能力**：`--dry-run`、`--json`、`--yes`、`--quiet`、`--verbose`、`--config`；全局 `flock` 串行化；ERR trap 统一报错；退出码规范（0–8）。
- **原子化建站**：建站失败自动回滚目录/数据库/vhost，并恢复 OLS 配置快照，不留半成品。
- **模板自动探测**：按 mu-plugins/插件/主题/媒体数量打分选模板，避免选到空壳站。

### 修复 / 改进（相对 1.x）

- `wp core install` 以 root 创建 SQLite 文件（600 权限），Web 用户无法写入 → 安装后与每次 wp-cli 写操作后自动 `chown`，含 `-journal/-wal/-shm` 旁文件。
- 模板带入的 80→443 重定向让端口模式站点 301 死循环 → 端口模式不再生成该规则。
- 硬链接主题后 WP 不再安装默认主题，新站无活动主题 → 建站时显式激活模板站的主题。
- 自定义主题依赖模板站 mu-plugins（如 `s9ui_attr()`），缺失导致 500 → 默认一并复制 mu-plugins，可用 `--minimal` 关闭。
- `list` 的 awk 把 `virtualHost` 与 `listener` 顺序错配 → 改为从注册表读取。
- `remove` 只删文件不删 listener → 现在同时清理 listener 块与共享 listener 里的 `map` 行。
- 配置写入未落盘、`remove` 结果被尾部写回覆盖 → 配置编辑器统一走"改内存 → 落盘 → 校验 → 失败回滚"。
- 建站验收使用带随机参数的 URL，避免命中历史缓存（包括被缓存的 500 响应）。

### 已知限制

- `ssl` 仅支持域名模式（端口模式没有公网 80/443）。
- 端口模式不适合生产对外访问，仅用于内部测试与压测。
- 模板克隆是"整站骨架克隆"，不复制数据库内容与 uploads。
