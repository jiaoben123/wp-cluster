# 故障隔离设计

> 目标：**一个站出事，不要拖垮全部站**。
> 本机是 1 核 / 1.4G 的单实例 OpenLiteSpeed，天然存在共享层；下面把「共享了什么」列清楚，
> 再逐项给出隔离手段、检测手段和恢复手段，全部有对应命令。

---

## 1. 共享边界一览

| 层 | 共享还是独立 | 说明 |
|---|---|---|
| WP 核心（wp-admin / wp-includes） | **共享**（硬链接，101MB 只存一份） | 单站改核心 = 全站改核心，这是最大风险点 |
| 插件 / 主题目录 | **共享**（硬链接，新建站时 `cp -al`） | 单站升级插件会断开该站链接，不影响别人 |
| `wp-content/uploads` | 独立 | 每站自己的目录 |
| SQLite 数据库 | 独立 | `/var/www/db/<slug>.sqlite`，web 根之外 |
| 缓存盐 / LSCache 缓存 | 独立 | `WP_CACHE_KEY_SALT` + 每站 vhost |
| APCu 共享内存 | **共享**（同一 PHP 进程池） | key 冲突已由缓存盐规避 |
| PHP 进程（lsphp 子进程） | **共享**（默认全局池 10 个） | 一个站打满 = 其他站排队 |
| OpenLiteSpeed 主进程 | **共享**（单实例） | 主进程挂 = 全站 502 |
| 磁盘 / 内存 / 单核 CPU | **共享** | 单站把磁盘写满 = 全站写满 |

结论：**磁盘、数据库、缓存已经是天然隔离的；真正需要额外处理的是「核心硬链接」「PHP 进程池」「OLS 主进程」三项。**

---

## 2. 故障矩阵

| # | 故障 | 影响面 | 默认防护 | 加固手段 |
|---|---|---|---|---|
| 1 | 单站 PHP 死循环 / 大内存请求 | 占满共享 PHP 池 → 全站变慢 | `WP_MEMORY_LIMIT=128M`、`max_execution_time` | `wp-cluster isolate <域> --php-pool 3` |
| 2 | 单站被入侵，核心文件被改 | **全站被投毒**（硬链接） | 核心目录 root 所有、`restart` 权限收口 | `verify` 基线告警 + `isolate <域> --core` |
| 3 | 单站插件冲突导致 500 | 只影响本站在请求 | LSCache 不会缓存 500 | `isolate --php-pool` 后仍 500 则 `disable` |
| 4 | 单站 SQLite 损坏 | 只影响本站 | 每站独立库 + 每日备份 | `restore <域> <备份>` |
| 5 | OLS 主进程崩溃 | **全站 502** | systemd `Restart=` | `guard install`（5 分钟一轮，自动重启） |
| 6 | 80/443 端口被占 | 全站不可用 | `doctor` 端口检查 | `guard run` 日志 + `journalctl -u lsws` |
| 7 | 磁盘写满 | 全站写不进、DB 损坏 | 备份保留策略 | `status` 水位 + 手动清理 |
| 8 | 内存耗尽触发 OOM | 随机杀进程 | 1G swap + PHP 池上限 | 下调 `PHP_LSAPI_CHILDREN` |
| 9 | 单站被刷流量 | 单核 CPU 饱和，全站慢 | LSCache 命中即零 PHP | CF 侧限速 + 池隔离 + `purge` |

---

## 3. 三个隔离动作

### 3.1 独立 PHP 进程池（解决 #1 #3 #9）

```bash
wp-cluster isolate shop1.example.com --php-pool 3
```

做的事：

1. 在 `httpd_config.conf` 里新增 `extProcessor lsphp_<slug>`，独立 socket `/tmp/lshttpd/<slug>.sock`，子进程数 3；
2. 在该站 vhost 里加 `scripthandler { add lsapi:lsphp_<slug> php }`；
3. 完整重启 OLS，探测 HTTP 200；任何一步失败自动回滚。

效果（实测，demo 站）：

```
$ ss -xp | grep demo_vitden
u_str ESTAB ... //tmp/lshttpd/demo_vitden_com.sock ... users:(("lsphp",pid=32629))
$ ps -eo pid,rss,cmd | grep lsphp
32033  36432  lsphp        ← 全局池，其他 5 站共用
32629  56684  lsphp        ← demo 专属池
```

撤销：

```bash
wp-cluster isolate shop1.example.com --undo
```

> 注意顺序：必须先摘 vhost 的 `scripthandler` 再删 `extProcessor`，否则 OLS 校验会因悬空引用失败。
> 这个顺序在 2.1.0 里已修（早期版本 `--undo` 会回滚失败）。

### 3.2 拆核心硬链接（解决 #2）

```bash
wp-cluster isolate shop1.example.com --core
```

把该站所有与共享核心同 inode 的文件复制成独立 inode。实测：拆 8006 个文件、磁盘 +200MB、站点仍 200、其他站不受影响。

**用途**：确认某站被入侵 / 需要单独改核心 / 需要单独升级到不同 WP 版本时。
**代价**：该站不再享受「核心只存一份」，磁盘 +100~200MB。

### 3.3 核心完整性基线（解决 #2 的检测）

```bash
wp-cluster verify --baseline     # 当前核心建立基线（首次 / 有意升级后）
wp-cluster verify                # 日常巡检，有漂移返回退出码 7
```

实测输出：

```
共享核心完整性
  核心目录 : /var/www/wp-core
  文件数量 : 3338；其中 3338 个文件被硬链接共享，当前 2 个站点复用
  基线比对 : 通过，无改动

站点隔离状态
域名              核心共享 独立库 收录     状态
demo.vitden.com   是       ✓      noindex  ● ok
site1.vitden.com  否       ✓      index    ● 独立核心
```

建议挂在 cron 里每天一次（`wp-cluster verify --json` 接监控）。

---

## 4. 守护与自愈

```bash
wp-cluster guard install     # systemd timer，每 5 分钟
wp-cluster guard status
wp-cluster guard run         # 手动跑一轮
```

每轮逻辑：

1. `systemctl is-active lsws` → 不是 active 就 `restart`，成功记 `[RECOVER]`，失败记 `[CRITICAL]`；
2. 逐站 `curl`，非 200 累计连续失败次数，≥3 次记 `[CRITICAL]`，恢复后记 `[RECOVER]` 并清零；
3. 全部写 `/var/log/wp-cluster/guard.log`（已纳入 logrotate，周轮转保留 8 份）。

**不自动删站、不自动改配置** —— 自愈只做「重启 + 记录」，避免误判把好站搞坏。

---

## 5. 检测面（现有）

| 命令 | 检测内容 | 异常信号 |
|---|---|---|
| `doctor` | 依赖 / 路径 / 权限 / 端口 / 扩展 | 退出码 3 |
| `health --all` | HTTP、TTFB、缓存命中、证书剩余天数、WP 版本 | 退出码 1 |
| `verify` | 核心是否被改、每站是否有独立库 | 退出码 7 |
| `status` | 内存 / Swap / 负载 / 站点数 | 人工看 |
| `guard` | OLS 存活 + 每站可达 | guard.log |

---

## 6. 这套方案的边界（说实话）

1. **不是容器级隔离**。OLS 是单主进程 + 子进程模型，没有 cgroup / namespace。真正的资源硬隔离（CPU、内存、IO 配额）需要 Docker/K8s 或 systemd slice + 反向代理。
2. **PHP 池隔离只隔离「谁抢到子进程」**，不隔离 CPU 时间；单核机器上一个站跑满 CPU，其他站仍会慢。这是 1 核的物理限制。
3. **内存隔离靠 `WP_MEMORY_LIMIT` 软限制**，不是 cgroup 硬限制；恶意代码仍可绕过。
4. 因此定位是：**用最低成本把「常见故障」的爆炸半径收到单站**，而不是「绝对隔离」。真要绝对隔离，见 `docs/DOCKER-VS-NATIVE.md` 的混合方案（OLS 主站 + 关键站独立容器）。

---

## 7. 建议的默认配置（10 站以内）

```bash
# 每站 3 个子进程，10 站 = 最多 30 个，1.4G 内存够用
ww2.vitden.com       --php-pool 5     # 主站给多一点
其余站               --php-pool 2

# 每天 03:10 核心校验
10 3 * * *  /usr/local/bin/wp-cluster verify --json || 告警

# guard 每 5 分钟
wp-cluster guard install
```

---

## 8. 隔离的回收（重要）

`isolate --php-pool` 会在 OLS 全局配置里新增一个 `extProcessor`。它**必须**随站点一起销毁，否则：

- 残留的 `extProcessor` 继续占着 `/tmp/lshttpd/lsphp_<slug>.sock`；
- 同名站点重建时，`isolate` 会认为「已经隔离过」而不做任何事，排查起来很迷惑。

自 2.1.1 起，`wp-cluster remove <域>` 与 `uninstall --purge` 都会自动清理：

```bash
wp-cluster remove shop9.example.com --yes
# 输出中会顺带移除 extProcessor lsphp_shop9_example_com 与对应 socket
```

顺序是「先摘站点（vhost + listener）→ 再删池」，反了会因悬空 `scripthandler` 导致 OLS 校验失败。
`--core` 拆链是物理复制，不可逆；要回归共享核心只能重建站点。
