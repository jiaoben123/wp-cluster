# 单站备份 / 恢复 / 迁移

> 一句话：**每站能单独打包、单独搬到另一台机器、单独回滚，不依赖整机。**
> 三个命令分工：`backup`（本机回滚）、`export`（跨机搬家）、`adopt`（落地接管）。

---

## 1. 三者区别

| 命令 | 产出 | 用途 | 依赖目标机已有站点？ |
|---|---|---|---|
| `backup <域>` | `<域>-<类型>-<时间>.tar.gz`（库快照 + wp-content + 清单 + 校验和） | 本机回滚、定期归档 | 是（`restore` 需要同名站点已存在） |
| `export <域>` | `<域>-export-<时间>.tar.gz` | 搬到另一台机器 / 换域名 | 否（`adopt` 新建） |
| `restore <域> <包>` | —— | 用备份覆盖现有站点 | 是 |
| `adopt <包> --domain 新域` | 新站点 | 在任意机器落地一个完整站点 | 否 |

备份包里**不含 WP 核心**（101MB），因为核心靠 `wp-cluster init` 在目标机已有；这样备份小、迁移快。

---

## 2. 日常备份（本机回滚）

```bash
wp-cluster backup shop1.example.com --type manual
wp-cluster backup --all                 # 全部站，daily 槽位
wp-cluster cron install                 # 装每日/每周/每月自动备份
```

保留策略：日 7 份、周 4 份、月 6 份（`conf` 可改）。备份包内含：

```
database.sqlite       # VACUUM INTO 的一致性快照
site-files.tar.gz     # wp-config.php + wp-content（排除 cache/litespeed/upgrade/日志）
manifest.txt          # 域名、URL、WP/PHP 版本、时间、主机名
SHA256SUMS
```

恢复：

```bash
wp-cluster restore shop1.example.com /var/backups/wp-cluster/shop1/xxx.tar.gz --yes
```

恢复流程做了三件保险：
1. 校验和验证 + 路径穿越检查（`../`、绝对路径一律拒绝）；
2. 恢复前自动拍一份 `manual` 快照；
3. 数据库用**原子替换**（见第 5 节），替换后跑 `PRAGMA quick_check`。

---

## 3. 单站搬家（跨机器 / 换域名）

### 3.1 源站导出

```bash
wp-cluster export ww2.vitden.com
# 文件: /var/backups/wp-cluster/ww2.vitden.com/ww2.vitden.com-export-20261115-152417.tar.gz (33M)
scp <包> 目标机:/root/
```

包结构：

```
database.sqlite     # 12.4MB（实测 ww2：125 张表 / 1868 行 posts）
files.tar.gz        # wp-content + .htaccess + robots.txt
manifest.json       # 域名/URL/模式/标题/管理员/收录/WP版本/活动插件/主题/站点路径
SHA256SUMS
```

`manifest.json` 示例：

```json
{
  "format": "wp-cluster-export/1",
  "domain": "ww2.vitden.com",
  "url": "https://ww2.vitden.com",
  "site_dir": "/var/www/ww2.vitden.com",
  "wp_version": "7.1.4",
  "theme": "shindar-theme",
  "plugins_active": ["advanced-custom-fields-pro", "litespeed-cache", "..."],
  "index": 0
}
```

### 3.2 目标机接管

```bash
wp-cluster adopt /root/ww2.vitden.com-export-*.tar.gz --domain m1.vitden.com --mode port
# 或域名模式 + 证书
wp-cluster adopt <包> --domain shop9.example.com --mode domain --ssl --index
```

`adopt` 做的 8 步：

1. 解包 + 校验和 + 路径穿越检查；
2. **复用 `add` 全流程**建骨架（vhost、listener、权限、注册表、WP 安装），保证与新建站完全一致；
3. 原子替换数据库 + `quick_check`；
4. 覆盖 `wp-content`（插件/主题/上传/mu-plugins/.htaccess），并按 `TEMPLATE_STRIP_MU` 剔除「无条件 noindex」的遗留 mu-plugin；
5. 修正 `wp-content/db.php` 里写死的**绝对路径**（SQLite drop-in 会记录原站目录）；
6. 重新生成 `wp-config.php`（新域名、新库路径、新盐）；
7. `wp search-replace` 全表替换旧 URL → 新 URL，并 `option update home/siteurl`；
8. 重新激活插件与主题、flush rewrite、清 LSCache、探测 200、打印文章数。

实测（ww2 → m1，换域名 + 换协议 + 换端口）：

```
[+] 从导出包接管：https://ww2.vitden.com → m1.vitden.com
  原 WP 版本: 7.1.4    原插件数: 7
→ 恢复数据库 → 恢复站点文件 → 替换域名引用
    Success: Made 2087 replacements.
[+] 接管完成（HTTP 200）
  域名: m1.vitden.com   地址: http://192.129.193.53:8100   文章数: 180
```

验收项：`option get home` 正确、标题「深信达」保留、180 篇文章、431 个媒体文件、7 个插件激活、正文无旧域名残留。

---

## 4. 整机迁移顺序（换 VPS 时照这个来）

```bash
# 旧机
wp-cluster backup --all                       # 兜底
wp-cluster export --all 2>/dev/null || for d in $(wp-cluster list --json | ...); do wp-cluster export $d; done
scp /var/backups/wp-cluster/*/*-export-*.tar.gz 新机:/root/exports/

# 新机
./install.sh && wp-cluster doctor && wp-cluster init
for f in /root/exports/*.tar.gz; do
  wp-cluster adopt "$f" --domain <对应域名> --mode domain --ssl
done
wp-cluster verify --baseline
wp-cluster guard install
```

DNS 切换前把新机用端口模式跑一遍（`--mode port`）验证，确认无误再改 A 记录。

---

## 5. 踩过的坑（都在 2.1.0 修了）

### 5.1 SQLite 数据库被覆盖后损坏（最隐蔽）

现象：`adopt` 后站点 500，日志报
`Cannot escape data without an active database connection`，
库文件大小退回安装时的 880KB，`PRAGMA quick_check` 报 `malformed database schema`。

两个原因叠加：

1. `cp -f` 覆盖是**原地截断同一个 inode**，正在使用的库被写一半；
2. `add` 结束时 `systemctl restart lsws` **强杀**了正在写库的 PHP 子进程，留下 hot `-journal`；下次打开该库时 SQLite 按 journal 回滚，把新库滚成了旧内容 → 结构错乱。

修复（`replace_db()`）：

```bash
rm -f <db>-journal <db>-wal <db>-shm      # 先清 hot journal
cp 快照 → <db>.incoming.$$                # 写临时文件（新 inode）
chmod 664 / chown nobody
mv -f <db>.incoming.$$ <db>               # 原子 rename
rm -f <db>-journal <db>-wal <db>-shm      # 再清一次
PRAGMA quick_check                        # 失败即报错退出
```

### 5.2 `db.php` 写死原站绝对路径

SQLite drop-in 里有 `SQLITE_IMPLEMENTATION_FOLDER_PATH`，克隆到新域名后指向已不存在的目录。
`adopt` 会用 `sed` 把旧 `site_dir` 替换成新目录（若原文件是模板占位符，插件会自动 `realpath` 兜底）。

### 5.3 ACF PRO 授权域名

`wp search-replace` 会把 ACF 的 `activated_url` 一起改掉，可能导致授权失效。
如遇授权问题：备份里保留旧值，或在新站后台重新激活。**这是唯一预期内的「残留旧域名」**。

### 5.4 备份包不含核心

`restore` 到一台没有执行过 `wp-cluster init` 的机器会缺 `wp-admin`。
跨机请用 `adopt`；或用 `install.sh && wp-cluster init` 先准备核心。

---

## 6. 验收清单（搬完照这个对一遍）

```bash
wp-cluster health <域>                 # HTTP 200 / 缓存 hit / 证书天数
wp-cluster info <域>                   # URL、模式、库路径
curl -s <URL> | grep -o '<title>[^<]*' # 标题对不对
wp-cluster logs <域> -n 30             # 有没有 PHP 报错
du -sh <SITE_DIR>/wp-content/uploads   # 媒体文件数对不对
```
