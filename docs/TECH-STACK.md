# 技术栈速查（wp-cluster 2.2.0）

> 一句话：**CF 优选（可选外层） + OpenLiteSpeed + LSCache 整页缓存 + LSPHP 8.3（OPcache / APCu） + 每站独立 SQLite**，
> 外加一层站群管理（硬链接共享核心、独立 PHP 池、guard 自愈、单站备份/迁移）。**非 Docker**。

## 1. 你原来那三行，哪里需要更新

| 原来的写法 | 现在的准确说法 |
|---|---|
| 最佳组合：OpenLiteSpeed + LiteSpeed Cache 插件 + SQLite + APCu | 方向正确，但少了 **LSPHP 8.3 / OPcache / WP-CLI**，以及最关键的**站群层**（`cp -al` 硬链接共享核心、每站独立库、独立 PHP 池、guard）。 |
| 在 LSCache 插件里把「对象缓存」保持关闭 | **结论对，且是脚本明确的设计取舍**：`wp-cluster add` 里就注明「APCu 对象缓存（LSCache 自带对象缓存保持关闭，避免冲突）」，不写 `litespeed.conf.object`；本机不装 Redis / Memcached，该模块一直是默认关闭。2026-11-16 补做的 A/B/C 实测支持这个取舍（见第 6 节）。 |
| 转而通过安装 APCu Manager 或 SQLite Object Cache | **前半对、后半错**。脚本装并激活 `apcu-manager`，且 `add` 时会写 `apcm_earlyloading=1` —— **新站首次 Web 请求就会由插件自动装上 APCu 的 `object-cache.php` drop-in，接管 WP 对象缓存**；`SQLite Object Cache` 插件根本没装，不属于本方案。实测：早期站 site1–4 未设该 option、没有 drop-in，导入站 ww2 与旧模板 t1 有，**`add` 新建的站一律有**。 |
| CF 优选 + OpenLiteSpeed + LSCache + APCu + SQLite | CF 优选是**可选的外层接入，不在服务器上装任何东西**：脚本只提供 `cf status / probe / plan` 三个命令 + 文档，实际配置全在 Cloudflare 控制台和主域 DNS。 |

## 2. 基础栈：脚本到底装了什么

| 层 | 组件 | 实测版本 / 参数 |
|---|---|---|
| Web 服务器 | OpenLiteSpeed（LiteSpeed 官方 apt 源） | 1.9.4；listener 80/443（域名模式）+ 8100+（端口模式）；每站一个 vhost |
| PHP | LSPHP 8.3 | 8.3.36；扩展 `common curl sqlite3 mysql opcache apcu intl igbinary`；`/usr/local/bin/php` 软链 |
| 数据库 | SQLite（**不用 MySQL**） | `sqlite-database-integration` 插件 + `wp-content/db.php` drop-in；`wp-config.php` 里 `DB_ENGINE=sqlite`、`DB_PATH=/var/www/db/<domain>.sqlite`；每站一库，放在 web 根之外 |
| 字节码缓存 | Zend OPcache | LSPHP 内置 |
| 对象/内存缓存 | APCu 扩展 + drop-in | `apc.shm_size=128M`、`apc.ttl=7200`、`apc.enable_cli=On`；**新建站默认启用** `apcu-manager` 的 `object-cache.php`（`apcm_earlyloading=1`），见第 5、6 节 |
| 整页缓存 | LSCache（OLS 模块 + `litespeed-cache` 插件） | 新站带 `advanced-cache.php`；命中时 OLS 直接返回 HTML，**不进 PHP**（1 核 1.4G 能带多站的关键） |
| 管理工具 | WP-CLI | 官方 phar，直装 `/usr/local/bin/wp` |
| 面板插件 | `apcu-manager` | 统计面板 + **自动安装 APCu 对象缓存 drop-in**（不是纯统计） |

**三层缓存各司其职**：LSCache 管整页 HTML → OPcache 管 PHP 字节码 → APCu 管 WP 对象/选项（新建站默认启用）。SQLite 只做持久化。
注意这是**两层不同的「对象缓存」**：APCu 那层默认开着；LSCache 插件设置页里那个需要 Redis / Memcached 的「对象缓存」模块才是默认关的。

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

`apcu-manager/object-cache.php` drop-in（**新建站默认就有**）会让 **wp-cli 与 LSPHP 的 APCu 分属两个进程空间**：
命令行 `wp option update blog_public 1` 改了数据库，前端仍从自己的 APCu 段读旧值（`ttl=7200`，最多两小时），
表现为 `wp-cluster enable` 之后依旧 `noindex`、sitemap 为空。`wp cache flush` 和 `litespeed-purge all` 都清不到 Web 那份。

`wp-cluster` 已修：`cmd_set_index` 会临时放一个带 key 校验的探针，经站点 URL 让 **Web 进程自己**执行
`wp_cache_flush()` + `apcu_clear_cache()`，用完即删。

> 结论：**保留默认启用**（收益见第 6 节实测），但任何改 option 的操作都要在 Web 侧失效缓存，别只信 `wp option update` 的返回。
> 另外 `apcm_check_earlyloading()` 会在**每次请求**检查并重建 drop-in，所以「直接删 `object-cache.php`」不是可靠的关闭方式；
> 要停用请连 `apcu-manager` 插件一起停用，并用探针确认 `wp_using_ext_object_cache()` 为 false。

## 6. 对象缓存「开 / 关」本机实测（2026-11-16）

**结论先说：要开，但开 APCu 这层就够了；再打开 LSCache 的 Redis / Memcached 对象缓存模块不会更好。**

### 测试设计

- 临时站 `zzbench.vitden.com`（`wp-cluster add --mode port`），1 核 / 1469MB / Debian 13 / OLS 1.9.4 / LSPHP 8.3.36 / SQLite。
- 站根探针 `__bench.php`：测 `wp-load.php` 加载、一次 `WP_Query`、60 次 `get_option()`；响应带 `X-Litespeed-Cache-Control: no-cache`，确认绕开整页缓存。
- 每组切换后清空 APCu / Redis / 整页缓存，预热 18 次，再跑串行 40 次（c=1）与并发 120 次（c=8）。
- 两轮，**第二轮反向顺序**（A→B→C / C→B→A）抵消系统漂移。
- 探针自证分组：报告请求开始时 drop-in 类型、`wp_using_ext_object_cache()`、对象缓存类的实际来源文件、`LITESPEED_OC_FAILURE`、`litespeed.conf.object`。每组所有请求签名唯一，没有混组。

> 第一版测试得出过无效结论：`apcu-manager` 的 `apcm_check_earlyloading()` 会在每次请求重建 `object-cache.php`，
> 导致「无缓存组」8 次请求里只有第 1 次真的关着。修正方式是停用该插件目录 + 探针自证。

### 三组配置

| 组 | 配置 | 探针自证签名 |
|---|---|---|
| A | 无对象缓存（停用 `apcu-manager` + 删 drop-in） | `group=none ext=0 impl_src=wp-core` |
| B | APCu drop-in（**新建站默认**） | `group=apcu ext=1 impl_src=object-class.php` |
| C | LSCache 对象缓存 + Redis（临时装 redis-server 8.0.2 / phpredis 6.3.0） | `group=lscache ext=1 impl_src=lscache-oc oc_fail=0` |

### 数据（两轮均值）

| 指标 | A 无缓存 | B APCu | C Redis | B vs A |
|---|---|---|---|---|
| 串行 RPS（c=1） | 20.8 | 26.3 | 25.5 | **+26%** |
| 串行 e2e p50 | 46.6ms | 37.0ms | 37.3ms | −21% |
| `wp-load.php` p50 | 36.9ms | 32.0ms | 32.2ms | −13% |
| 60 次 `get_option` | 5.6ms | 1.3ms | 1.9ms | −77% |
| 并发 RPS（c=8） | 18.4 | 24.4 | 24.1 | **+33%** |
| 并发 e2e p50 | 422ms | 326ms | 325ms | −23% |
| 并发 e2e p95 | 607ms | 376ms | 372ms | **−38%** |
| 并发 60 次 `get_option` | 59.6ms | 1.5ms | 18.8ms | −97% |

### 怎么读这组数据

1. **匿名访客命中 LSCache 整页缓存时，对象缓存完全不参与**：OLS 直接返回 HTML、不启动 PHP，A/B/C 零差别。站群的主要流量属于这一类，上面的数字只代表「动态路径」。
2. 收益集中在**缓存 miss、登录态、后台、AJAX/REST、wp-cli、WooCommerce 类页面**。探针刻意测的就是这条路径。
3. **B 与 C 基本持平**（串行 RPS 26.3 vs 25.5，并发 p95 376 vs 372ms）。Redis 走 TCP + 序列化，在 `get_option` 密集段反而慢于本机共享内存 APCu；却要多一个常驻服务（实测 RSS 17.5MB）、一个 PHP 扩展、一次 LSPHP 重拉和一套连接配置。
4. **APCu 的边界**：单机共享内存，跨机 / 跨容器不共享。只有站群拆到多机、或 PHP 池隔离到不同用户时，Redis 才有意义；本机单机器不需要。
5. 之前引用的第三方数据（Redis 482 RPS / 98.4% 命中 vs 无缓存 48 RPS）来自 4vCPU / 8GB + WooCommerce 25,000 商品 + 150 并发登录用户，说明「动态密集场景对象缓存收益极大」，但**不是本机 1 核 1.4G 展示站的实测**，不能直接套用。
6. 局限：合成探针、单站、样本 40 / 120，测的是 PHP 侧开销而非真实页面渲染；两轮反向顺序结果吻合，可信度足够支撑「保持现状」的判断，不足以推断大流量电商场景。

### 排查备忘

- `apcu-manager` 每次请求都会检查并重建 drop-in，`rm object-cache.php` ≠ 关闭对象缓存。
- `apt install lsphp83-redis` 后，**已 fork 的 LSPHP 进程不会加载新扩展**（`lswsctrl restart` 的 SIGUSR1 也不重拉子进程），表现为 `oc_fail=1` 静默降级、Redis 里却仍有 wp-cli 写的键。必须 `pkill -x lsphp` 重拉，并确认 Web 侧 `extension_loaded('redis')`。
- C 组测完已完整恢复：`apt purge` 三个包 + autoremove、6379 未监听、临时站与探针全删、6 个生产站 HTTP 200、`doctor` 全项通过。

## 7. 运行时调优「最快 + 最省」本机实测（2026-11-16）

三轮改动、全部在同站（site1，1 核 1469MB）用同一套压测脚本跑改前改后。**只有第 1、3 条真正提速，第 2 条是消除隐患**。

### 7.1 三套缓存打架（最大一笔）

四站当时同时激活 `litespeed-cache` + `flying-press` + `nginx-helper`。FlyingPress 抢不到 `advanced-cache.php`（被 LSCache 占着），却仍在每个请求里跑一遍自己的优化链，且在 `src/Optimizer.php:22-23` 硬编码：

```php
header('Cache-Control: no-store, s-maxage=0');
header('Cloudflare-CDN-Cache-Control: no-store');
```

后果：LSCache 明明缓存了整页，响应却带 `no-store`，Cloudflare 边缘也跟着不缓存。

处理：`wp plugin deactivate flying-press nginx-helper` + `wp litespeed-purge all`。四站 `no-store` 计数归零，LSCache 恢复发 `x-litespeed-cache-control: public,max-age=604800`（7 天）。

### 7.2 OPcache 被写满（隐患，不是当时的瓶颈）

| 项 | 改前 | 最终 |
|---|---|---|
| `memory_consumption` | 128MB | **384MB**（≤12 站统一 384，之后 512 / 768） |
| 已用 / 剩余 | **126.2MB / 1.8MB** | 64–81MB / 303–320MB |
| `cached_scripts` | 3073 | 755–2022（重启后重新灌） |
| 命中率 | 98.8% | **99.7%** |
| `wasted_memory` | 0MB（尚未开始淘汰） | 0MB |

只剩 1.8MB 意味着**下一个新脚本进来就要淘汰旧条目、下次再重编译**。这是一条迟早会踩的线，不是当下的瓶颈——扩到 256MB 时动态路径 RPS 完全没变（22.2 → 22.2）。

**「小站也开大段」为什么几乎零成本**：OPcache 与 APCu 的共享段都是 mmap 匿名页、按需缺页分配。声明 384MB 不等于立刻占 384MB 物理内存，只有真正缓存的脚本才占页——实测 6 站灌满后只用了 64–81MB。所以按「2 站够用」去配 128MB 反而是白亏，直接给 384MB。

### 7.3 一档到底的性能参数（2–6 站 / 1 核）

| 参数 | 默认值 | 最终值 | 依据 |
|---|---|---|---|
| `opcache.memory_consumption` | 128 | **384** | 按需分配，写满才是灾难 |
| `opcache.interned_strings_buffer` | 8 | **32** | 同样在共享段内按需分配 |
| `opcache.max_accelerated_files` | 10000 | **40000** | 实际 2000–3000，留足余量免哈希冲突 |
| `opcache.revalidate_freq` | 2 | **60** | 每文件每 60s 才 stat 一次 |
| `opcache.jit_buffer_size` | 0 | **128M** | 见 7.4，实测 +15% |
| `realpath_cache_size` | 4096K | **16384K** | WP 每请求 resolve 上千路径 |
| `realpath_cache_ttl` | 120 | **600** | 同上，减少回落到 stat |
| `memory_limit` | 128M | **256M** | 后台/导入/插件更新容易打满白屏 |
| `apc.shm_size` | 128M | **256M** | 按需分配 |
| `apc.ttl` | 7200 | **0** | 不按时间过期，写满才 LRU 淘汰 |
| `apc.entries_hint` | 8192 | **16384** | 哈希桶数，减少碰撞 |

`validate_timestamps` **保持开启**：关掉能再省一点 stat，但改主题/插件后必须手动清 OPcache，对「随时改代码」的站群不划算。

### 7.4 JIT：原以为无用，实测有效

上一版这里写的是「1 核上 WP 收益极小，保持关闭」——**这是错的，已用交替对照推翻**。

同一台机器、同一探针，开 → 关 → 开 → 关 → 开 交替五轮，每轮重启 + 预热 20 次后跑 40 个请求：

| 轮次 | JIT | `load_ms` | `work_ms` | 串行 RPS |
|---|---|---|---|---|
| ON-1 | 开 | 31.7 | 0.46 | 26.3 |
| OFF-1 | 关 | 36.3 | 0.69 | 23.5 |
| ON-2 | 开 | 38.2 | 0.52 | 21.7 |
| OFF-2 | 关 | 37.8 | 0.72 | 23.1 |
| ON-3 | 开 | 32.4 | 0.46 | 26.6 |
| **中位** | 开 / 关 | **32.4 / 37.1** | **0.46 / 0.71** | **26.3 / 23.3** |

怎么读：

- **`work_ms` 是最干净的信号**（60 次 `get_option` 的紧循环）：开 0.46–0.52，关 0.69–0.72，**−35%**，五轮零重叠。JIT 编译的就是这类计算密集代码。
- **`load_ms` 有波动**：ON-2 那轮跑到 38.2ms（重启后 JIT 尚未热起来，40 个请求里含着预热成本）。三轮中位 32.4 vs 两轮 37.1，**约 −12%**，方向一致但不宜当精确值。
- JIT 缓冲区在 opcache 段内按需分配：128MB 声明值，实际编译 WP 全部热函数后只占 **0.9MB**。所以「128M 很贵」是误解。
- 128M 比 64M 略好（`load_ms` 33.4 vs 34.3），成本只多约 1MB 页，直接给 128M。

### 7.5 PHP 子进程数：10 → 6 → 又改回 10

`maxConns 10 / PHP_LSAPI_CHILDREN=10` 在 1 核上看着浪费，于是做了对照：

| 指标 | children=10 | children=6 |
|---|---|---|
| 动态串行 RPS（c=1） | 22.2 | 22.1 |
| 动态并发 RPS（c=8） | 20.7 / 21.7 | 17.7 / 19.5 |
| 动态并发 p95 | **440–485ms** | 568–654ms |
| lsphp PSS 合计 | 181MB | 110MB |

省 70MB，换来 20% 的尾延迟恶化。**机器还有 1GB 可用内存，不值得**，最终保持 10。

### 7.6 没改的两项（有实测依据）

- **SQLite `cache_size=-2000`（约 2MB）**：库本身只有 0.6–0.7MB（ww2 12.5MB），2MB 页面缓存已经装得下热数据。而 SQLite 的 page cache 是**每连接**一份，调到 8MB × 10 个子进程 = 多占 80MB，纯亏。
- **`mmap_size=0`**：mmap 能让多进程共享同一份页缓存，但 WAL 模式下收益有限、且和 SQLite 插件的 `busy_timeout` 路径叠加后不易验证。不动。

### 7.7 最终数字（site1，两轮反向顺序）

| 指标 | 优化前 | 最终（性能优先档 + JIT） | 变化 |
|---|---|---|---|
| 动态串行 RPS（c=1） | 16.7 | **24.7–26.6**（中位 25.5） | **+53%** |
| 动态串行 p50 | 55.3ms | 35.6–42.6ms（中位 37.5） | −32% |
| 动态并发 RPS（c=8） | 15.0 | 21.9–25.5 | **+46%** |
| 动态并发 p95 | 669.9ms | 358–540ms | −19% ~ −47% |
| WP 启动 `load_ms` | 37–38ms | 31.7–32.4ms（中位 32.4） | −12% |
| `work_ms`（纯 PHP 逻辑） | 6.73 | **0.46** | −93% |
| 整页缓存 RPS（c=8） | 708.1 | 647–783 | 同量级 |
| 整页缓存 p50 | 10.1ms | 8.9–11.2ms | 同量级 |

拆开看谁贡献了什么：

| 改动 | 动态路径贡献 |
|---|---|
| 拆掉 flying-press / nginx-helper | **+33%**（最大一笔） |
| APCu 对象缓存四站生效 | 含在上面 |
| JIT 128M | **+12~13%**（load_ms 37.1 → 32.4，work_ms −35%） |
| OPcache 扩容 / realpath / memory_limit / APCu 扩容 | 测不出差异（≈0），属于消除隐患 |

**为什么 OPcache 那批「改大」测不出提升**：命中率本来就有 99.7%、`wasted` 是 0，没有可挽回的损失。它们的价值是「不再逼近写满」和「后台重活不白屏」，不是当下的吞吐。这一点必须说清楚，不能拿参数变大冒充变快。

**整页缓存 700+ RPS 与 PHP 参数无关**：OLS 直接吐 HTML，PHP 不启动。所以「让匿名访客更快」只有两条路——拆掉抢缓存/发 `no-store` 的插件、把 TTFB 交给 Cloudflare 边缘。

### 7.8 复现方式

```bash
wp-cluster tune                # 只报告：当前值 vs 建议值、PHP 池 PSS、站点数
wp-cluster tune --apply        # 写 php.ini + 40-apcu.ini（幂等，自动备份）
wp-cluster tune --apply --yes  # 写完后重启 LSPHP 子进程生效
wp-cluster tune --apply --yes --no-jit   # 不想要 JIT 时（回退到 22 RPS 档）
wp-cluster doctor              # OPcache 容量不足会给警告并提示 tune --apply
```

新装机器由 `install-wp-cluster.sh` 的 `tune_php_ini()` 直接写入同一套值，不需要事后补。

## 8. 相关文档

- [ARCHITECTURE.md](ARCHITECTURE.md) — 组件分层、隔离边界、请求路径、状态模型
- [DOCKER-VS-NATIVE.md](DOCKER-VS-NATIVE.md) — 为什么 1 核 1.4G 选原生栈而不是 Docker
- [FAULT-ISOLATION.md](FAULT-ISOLATION.md) — 共享核心 / PHP / OLS 故障的影响半径
- [SITE-MIGRATION.md](SITE-MIGRATION.md) — 单站独立导出与接管
- [CF-OPTIMIZED-IP.md](CF-OPTIMIZED-IP.md) — SaaS 优选 IP 接入 7 步
