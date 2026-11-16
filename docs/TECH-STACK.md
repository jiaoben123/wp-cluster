# 技术栈速查（wp-cluster 2.2.0）

> 一句话：**CF 优选（可选外层） + OpenLiteSpeed + LSCache 整页缓存 + LSPHP 8.3（OPcache / APCu） + 每站独立 SQLite**，
> 外加一层站群管理（硬链接共享核心、独立 PHP 池、guard 自愈、单站备份/迁移）。**非 Docker**。

## 1. 你原来那三行，哪里需要更新

| 原来的写法 | 现在的准确说法 |
|---|---|
| 最佳组合：OpenLiteSpeed + LiteSpeed Cache 插件 + SQLite + APCu | 方向正确，但少了 **LSPHP 8.3 / OPcache / WP-CLI**，以及最关键的**站群层**（`cp -al` 硬链接共享核心、每站独立库、独立 PHP 池、guard）。 |
| 在 LSCache 插件里把「对象缓存」保持关闭 | **结论对，但不是脚本主动关的**：LSCache 的对象缓存模块依赖外部 Redis / Memcached，本机没装、脚本也没改 `litespeed.conf`，所以它一直是默认的关闭状态。实测 6 站的 `litespeed.conf` 都是空。 |
| 转而通过安装 APCu Manager 或 SQLite Object Cache | **这行需要改**。脚本确实装并激活了 `apcu-manager`，但**只当统计/管理面板用，没有启用它的 `object-cache.php` drop-in**；`SQLite Object Cache` 插件**根本没装**，不属于本方案。实测新建的 site1–4 都没有 `object-cache.php`，只有导入站 ww2 和旧模板 t1 有（导入时带过来的）。 |
| CF 优选 + OpenLiteSpeed + LSCache + APCu + SQLite | CF 优选是**可选的外层接入，不在服务器上装任何东西**：脚本只提供 `cf status / probe / plan` 三个命令 + 文档，实际配置全在 Cloudflare 控制台和主域 DNS。 |

## 2. 基础栈：脚本到底装了什么

| 层 | 组件 | 实测版本 / 参数 |
|---|---|---|
| Web 服务器 | OpenLiteSpeed（LiteSpeed 官方 apt 源） | 1.9.4；listener 80/443（域名模式）+ 8100+（端口模式）；每站一个 vhost |
| PHP | LSPHP 8.3 | 8.3.36；扩展 `common curl sqlite3 mysql opcache apcu intl igbinary`；`/usr/local/bin/php` 软链 |
| 数据库 | SQLite（**不用 MySQL**） | `sqlite-database-integration` 插件 + `wp-content/db.php` drop-in；`wp-config.php` 里 `DB_ENGINE=sqlite`、`DB_PATH=/var/www/db/<domain>.sqlite`；每站一库，放在 web 根之外 |
| 字节码缓存 | Zend OPcache | LSPHP 内置 |
| 对象/内存缓存 | APCu 扩展 | `apc.shm_size=128M`、`apc.ttl=7200`、`apc.enable_cli=On`；**扩展装了，但默认没有 WP 对象缓存 drop-in** |
| 整页缓存 | LSCache（OLS 模块 + `litespeed-cache` 插件） | 新站带 `advanced-cache.php`；命中时 OLS 直接返回 HTML，**不进 PHP**（1 核 1.4G 能带多站的关键） |
| 管理工具 | WP-CLI | 官方 phar，直装 `/usr/local/bin/wp` |
| 面板插件 | `apcu-manager` | 仅统计/管理，不启用 drop-in |

**三层缓存各司其职**：LSCache 管整页 HTML → OPcache 管 PHP 字节码 → APCu 管进程内对象（有 drop-in 时）。SQLite 只做持久化。

## 3. 站群层：这才是这个脚本的核心

| 机制 | 实现 |
|---|---|
| 共享核心 | `cp -al` 硬链接 `/var/www/wp-core`（101MB 一份），新站只多 **0.5MB / 44K** 独占磁盘 |
| 每站独立 | SQLite 库、`uploads`、vhost、OLS 日志、`WP_CACHE_KEY_SALT`、状态文件 |
| 唯一事实来源 | `/etc/wp-cluster/sites/<domain>.env`（行解析，不 source） |
| 故障隔离 | ① `verify` sha256 核心基线（漂移退出码 7）② `isolate --php-pool N` 独立 LSPHP 池 + 独立 UDS socket ③ `guard` systemd timer 5 分钟自愈 |
| 备份 / 迁移 | `backup` / `export` / `adopt`；SQLite 用 `VACUUM INTO` 快照 + 原子 `mv`，**不用 `wp db export`**（它依赖 mysql 客户端） |

## 4. CF 优选（可选，纯外部配置）

- 原理：**主域名 CNAME 到「优选域名」**（不能用 A 记录直接指优选 IP）；Cloudflare 侧用 **for SaaS 自定义主机名**承接证书与回源，辅助域名上建回退源指向源站 `192.129.193.53`。
- 额度：免费 **100 个**自定义主机名，超出约 $0.10/个/月；一个辅助域名可覆盖 10–100 站。
- 脚本侧命令：`wp-cluster cf status [域|--all]`（边缘节点/TTFB/TLS）、`cf probe`（优选域名延迟排序）、`cf plan <域>`（生成 7 步接入计划）。
- 实测（VPS 美西视角）全部落 LAX，`cf-cname.xingpingcn.top` 0.041s 最快；**国内线路快慢必须从你本机测**，VPS 的结论不能代表你。
- 详见 [CF-OPTIMIZED-IP.md](CF-OPTIMIZED-IP.md)。

## 5. 一个必须记住的坑（2026-11-16 实测）

导入站自带的 `apcu-manager/object-cache.php` drop-in 会让 **wp-cli 与 LSPHP 的 APCu 分属两个进程空间**：
命令行 `wp option update blog_public 1` 改了数据库，前端仍从自己的 APCu 段读旧值（`ttl=7200`，最多两小时），
表现为 `wp-cluster enable` 之后依旧 `noindex`、sitemap 为空。`wp cache flush` 和 `litespeed-purge all` 都清不到 Web 那份。

`wp-cluster` 已修：`cmd_set_index` 会临时放一个带 key 校验的探针，经站点 URL 让 **Web 进程自己**执行
`wp_cache_flush()` + `apcu_clear_cache()`，用完即删。

> 结论：**默认新站不要启用对象缓存 drop-in**。如果导入了带 drop-in 的站，任何改 option 的操作都要在 Web 侧失效缓存，
> 别只信 `wp option update` 的返回。

## 6. 相关文档

- [ARCHITECTURE.md](ARCHITECTURE.md) — 组件分层、隔离边界、请求路径、状态模型
- [DOCKER-VS-NATIVE.md](DOCKER-VS-NATIVE.md) — 为什么 1 核 1.4G 选原生栈而不是 Docker
- [FAULT-ISOLATION.md](FAULT-ISOLATION.md) — 共享核心 / PHP / OLS 故障的影响半径
- [SITE-MIGRATION.md](SITE-MIGRATION.md) — 单站独立导出与接管
- [CF-OPTIMIZED-IP.md](CF-OPTIMIZED-IP.md) — SaaS 优选 IP 接入 7 步
