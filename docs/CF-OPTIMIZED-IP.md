# Cloudflare 优选 IP 接入（站群方案）

> 要解决的问题：**站群套了 CF，国内访问仍然慢**。
> 实测证据（2026-11-15）：桌面端 Lighthouse 47 分，TTFB 960–1400ms，`cf-ray` 落地 **AMS（阿姆斯特丹）**；
> 同一页面源站 TTFB 只有 82–139ms。也就是说，**慢的不是 WordPress，是「国内 → CF 边缘 → 源站」这段绕路**。
> 免费版没有 Argo 智能路由，anycast 会把国内流量甩到欧洲/美西，这就是「优选 IP」要修的东西。

---

## 1. 为什么需要 SaaS（而不是直接改 A 记录）

直接把域名 A 到某个「优选 IP」行不行？不行，原因有三个：

1. CF 边缘靠 **SNI/Host 判断属于哪个 zone**。你的域名不在 CF 的证书体系里，握手会被拒；
2. 优选 IP 是共享的 anycast 地址，谁都能连，但只有「CF 认得的 hostname」才会回源；
3. 你要 HTTPS，而证书必须由 CF 针对你的域名签发。

**Cloudflare for SaaS（自定义主机名）** 就是官方给的解法：把你的域名注册成某个 CF zone 的「自定义主机名」，CF 负责证书 + 回源；你的 DNS 只需 CNAME 到优选域名，从而控制「走哪个 CF 入口 IP」。

```
用户 → DNS 解析到「优选域名」的 CF IP → CF 边缘（就近/优选节点）
                                   ↓ 按 SNI 命中自定义主机名
                                   ↓ 回退源 origin.辅助域名
                              源站 192.129.193.53:443
```

---

## 2. 三条路线对比

| 方案 | 做法 | 国内改善 | 成本 | 风险 | 适合 |
|---|---|---|---|---|---|
| **A. SaaS 自定义主机名 + 优选 CNAME**（推荐） | 辅助域名做 SaaS zone，主域 CNAME 到优选域名 | ★★★★ 可指定入口 IP，能落到 HKG/NRT/SIN | 免费 100 个 hostname，超出 \$0.10/个/月 | 优选域名是第三方服务，会失效；主域不能橙云 | 站群 ≤100 站 |
| B. 主域留在 CF，用 Worker/第三方反代做优选入口 | Worker 反代 + 自定义域 | ★★ 受 Worker 路由限制，等于多一跳 | Worker 免费额度 | 复杂、易被滥用策略限制、证书链更长 | 不建议 |
| C. 不优选，买 Argo / APO | 开 Argo Smart Routing（\$5/月起）或 APO（WordPress 专用） | ★★ 免费版开不了 Argo；APO 只优化缓存不优化回源路径 | \$5/月起/zone | 站群 = 每 zone 都要买 | 只做 1–2 个主力站 |

**结论：站群场景选 A。** 一个辅助域名可以承载 100 个自定义主机名，正好覆盖「10–100 站」的规模；超过 100 站再拆第二个辅助域名。

---

## 3. 详细配置步骤（7 步，实测流程）

前置：

- **辅助域名**（本例 `aux-domain.com`）：必须托管在 Cloudflare；
- **主域名**（本例 `ww2.vitden.com`）：DNS 必须能加 CNAME，**且不能是 CF 橙云**；
  如果主域也在 CF 托管，先关橙云；或干脆把主域 DNS 换到 DNSPod/华为云等第三方解析。

### 第 1 步：辅助域名建回退源

```
DNS → A   origin.aux-domain.com   →   192.129.193.53（你的源站）   代理：橙云 ✅
SSL/TLS → 概述 → 加密模式：完全（严格）
```

### 第 2 步：辅助域名添加回退源

```
SSL/TLS → 自定义主机名（Custom Hostnames）→ 回退源 → 填 origin.aux-domain.com
刷新后状态应为「有效 / Active」
```

### 第 3 步：为主域名添加自定义主机名

```
SSL/TLS → 自定义主机名 → 添加自定义主机名
  主机名：      ww2.vitden.com
  源服务器：    默认（= origin.aux-domain.com）
  证书验证：    TXT（推荐）或 HTTP
```

> 若主域在 CF 且橙云开着，会报错：
> `The hostname is using Cloudflare and cannot be activated with a TXT or HTTP validation token.`
> —— 这就是「必须先关橙云 / 换第三方 DNS」的原因。

按提示在**主域名 DNS** 加一条 TXT（`_acme-challenge` 或 CF 指定名），回 CF 刷新为「有效」。

### 第 4 步：主域名 CNAME 到优选域名

```
主域名 DNS → CNAME   ww2.vitden.com   →   <优选域名>
```

**这条记录不要开代理**（在第三方 DNS 上本来也没有代理选项）。可用的优选域名（2026-11 实测可解析、返回 CF IP）：

| 优选域名 | 解析结果 |
|---|---|
| `cf.090227.xyz` | 104.21.71.249 / 172.67.172.155 |
| `cf-cname.xingpingcn.top` | 104.26.4.60 / 104.26.5.60 / 172.67.70.92 |
| `cf.877774.xyz` | 104.18.41.190 / 172.64.146.66 |
| `cloudflare.182682.xyz` | 6 个 CF IP（104.18/172.64/172.66 段） |
| `icook.hk` / `time.is` | 104.21.90.210 / 104.26.12.54 |

> 这些是社区维护的「优选域名」，本质是别人已经接好 CF 的域名 + 持续更新的 IP 集合。
> **不能长期依赖**，见第 6 节监控方案。

### 第 5 步：验证

```bash
curl -s https://ww2.vitden.com/cdn-cgi/trace | grep -E 'colo|ip|tls'
# colo=HKG / NRT / SIN  ← 成功；仍是 AMS/LAX 说明该优选域名对你这条线路没帮助
wp-cluster cf status ww2.vitden.com
```

### 第 6 步：回滚（30 秒）

把主域名的 CNAME 改回原记录（或直接 A 到源站 IP）。SaaS 侧不用动，证书不受影响，源站无感。

---

## 4. 站群批量落地

```bash
wp-cluster cf plan --all --fallback origin.aux-domain.com --cname cf.090227.xyz
```

输出每站的 DNS 清单。逐站重复第 3–5 步即可；`Custom Hostnames` 面板可以批量添加。

**额度（官方定价页核对）**

| 项目 | Free / Pro / Business |
|---|---|
| 包含的自定义主机名 | **100 个** |
| 超出单价 | **\$0.10 / 个 / 月** |
| 单 zone 上限 | 50,000 |
| 通配符主机名 | 仅 Enterprise |

所以：**≤100 站 = 0 成本**；100–300 站 ≈ \$10–20/月。这对站群来说仍比自己买多 IP/多机便宜得多。

---

## 5. 与本方案的集成点

| 命令 | 作用 | 是否需要 CF API Token |
|---|---|---|
| `wp-cluster cf status [域\|--all]` | 解析 IP、落地节点、TLS 版本、TTFB、是否橙云、CF 缓存状态 | 否 |
| `wp-cluster cf probe [--targets a,b] [--rounds N]` | 对候选优选域名做 N 轮实测，按 TTFB 排序，标出不可达 | 否 |
| `wp-cluster cf plan <域> [--all]` | 生成该站/全部站的 SaaS 接入步骤与 DNS 清单 | 否 |

三个命令都是**只读**的：不改 DNS、不改 CF 设置、不需要 token，可以随时跑、随时停。
写入操作（建 custom hostname、改 DNS）仍在 CF 面板/你的 DNS 服务商完成，避免脚本拿高权限 token 误操作。

### 实测输出（源站视角，VPS 在美国）

```
目标                             解析IP数 TLS握手 TTFB      节点 状态
www.cloudflare.com                 2         0.034s    0.039s    LAX    可用
cf.090227.xyz                      2         0.037s    0.052s    LAX    可用
cf-cname.xingpingcn.top            3         0.190s    0.203s    LAX    可用
```

> **重要**：测点决定结论。VPS 在美国，测出来都是 LAX，对「国内访问」没有参考价值。
> 真正要跑 `cf probe` 的位置是**你的国内办公网络**（本机 Windows 上跑同一段 curl 即可）。
> 建议：国内网络每 30 分钟测一轮，取「TTFB 最小 + colo ∈ {HKG,NRT,SIN,TPE}」的那个优选域名。

---

## 6. 监控与自动切换（建议做法）

优选域名会挂（被墙、被滥用拉黑、维护停更）。生产上必须有兜底：

```
每 30 分钟：
  1. cf probe 6 个候选 → 取 TTFB 最小且 colo 在国内/亚太的
  2. 与当前 CNAME 比对，差异 > 30% 才切换（防抖）
  3. 通过 DNS 服务商 API 改 CNAME（DNSPod/华为云都有 API）
  4. 连续 3 轮全部候选不可用 → 回滚到「直连源站 A 记录」并告警
```

这一步需要在你的 DNS 服务商侧配置 API 密钥，属于**下一步可选工作**（见待办清单 B3）。

---

## 7. 风险与合规提示

1. **第三方优选域名不可控**：可能明天就失效、可能解析到被污染的 IP。必须多候选 + 监控 + 可回滚，不能当唯一入口。
2. **主域不能橙云**：这意味着这些站失去 CF 的 WAF/规则/缓存（这些能力挂在 zone 上）。
   实际影响：LSCache 源站整页缓存仍然生效，静态资源仍走 CF 缓存（自定义主机名会继承 zone 的缓存规则），
   但「按域名的 WAF 自定义规则、页面规则」不再可用。站群静态站可接受。
3. **Cloudflare for SaaS 的定位是给 SaaS 厂商服务客户域名**。自用属于非常规用法，
   CF 有权调整策略或限速；不要把它当成长期稳定的商业依赖。
4. **证书验证方式**：TXT 最省事；HTTP 验证要求主域 80 端口能被 CF 访问到你的源站。
5. **国内合规**：站群面向国内用户时，域名备案与内容合规是独立问题，优选 IP 不改变这一点。

---

## 8. 参考来源

- 旁逸斜出《Cloudflare+SaaS 回源优选 IP 加速大陆用户访问》(2025-05-26)：完整的 7 步配置流程，本文第 3 节与之对齐。
- 星の住処《使用 Cloudflare SaaS 实现优选域名 IP 加速网站》：被 CF 机器人防护拦截，正文未能抓取（仅拿到标题）。
- NodeSeek《post-482620》：站点拒绝抓取（fetch failed），未能提取正文。
- Cloudflare 官方定价页：`Cloudflare for SaaS` 免费 100 个自定义主机名、超出 \$0.10/个/月的额度以此为准。
- Cloudflare Docs《Cloudflare for SaaS · Plans》：Free/Pro/Business 均 100 个包含额度，单 zone 上限 50,000。
