# GMGN AI Trader · 项目需求文档 (SPEC)

> 给 AI 协作者 / 新接手者的单文件上下文。读完这一份即可理解：要做什么、为什么这么设计、当前进度、以及哪里需要继续写。

---

## 1. 一句话定义

基于 **GMGN Skills / MCP**（`gmgn-cli`）搭建的**本地** memecoin 筛选与成交工具：
**机器负责筛，人负责按下成交。** 确定性规则抓全 → ML 评分砍狠 → LLM 只解释幸存的少数 → 用户一键买入；同时实时监控持仓的逃生信号。

- 形态：本地 Web 应用（FastAPI 后端 + 单页 HTML 前端，后端同源托管前端）。
- 用户：自己 + 少数信任的人，各自在本机运行、配自己的 key。
- 风险声明：纯交易工具，盈亏由使用者自负；本项目不提供投资建议。

---

## 2. 核心定位决策（重要）

经过讨论，明确选择**人在环（human-in-the-loop）**而非全自动 bot：

- 流水线**只产出候选**，不自动下单。
- 通过全部闸门的候选，带着代码算好的仓位，摆在看板上等用户决策。
- 真正成交只发生在用户点「一键买入」时（对应 `POST /api/buy`）。
- 每条候选必须能**就地一键成交**，否则等于给对手导流的免费看板。

被放弃的方案：自动执行的 bot（`swap` 由代码自主触发）。原 `ai_trader.py` 是该方案的原型，逻辑已被吸收进 `app.py` 并重构。

---

## 3. 架构铁律

1. **LLM 绝不站在事件洪流上。** LLM 慢且贵，只处理"已通过确定性规则 + 评分排序"后剩下的少数。
2. **触发/放行全部确定性。** 是否进入下一关由规则/定量判断，LLM 只有"建议+理由+置信度"，没有放行权、不出仓位数字。
3. **LLM 碰不到风控层，也碰不到逃生路径。** 风控（并发/敞口/止损/kill-switch）和持仓逃生预警都是纯代码，求快、不幻觉。
4. **链上文本一律不可信。** 币名等字段进 LLM 前必须消毒（中和提示注入），且只喂消毒后的 `symbol_safe` + 数值特征，绝不喂原始名。

---

## 4. 流水线（严格顺序）

```
trending(便宜, 1 次 cli, 行内已含全部尽调字段)
  → 取前 top_n_prefilter 行 → 直接用行字段建特征(build_from_row, 零额外 cli)
  → 确定性硬门槛【先跑】(避雷 + 共识)            ← 砍掉大半
  → 评分排序(priority_score, 趋势动能模型)       ← 再砍, 只留 llm_max 个
  → LLM 只对幸存者解释(verdict/conviction/crowdedness/thesis)
  → 产出候选 + 代码算仓位(不执行)
  → [用户点一键买入] → 成交前再过一次硬风控 → SHADOW记录 / LIVE真实下单
```

**排序 = 趋势动能模型**（用户选定的选币目标，见 `CFG["rank_weights"]`）：
- `priority_score` = 加权(5m 动能·30 + 1h 动能·12 + 买卖比·18 + 换手·12 + 共识·12 + 安全筹码·10)，各子分归一化；1h 阴跌则整体 ×0.4 沉底。
- `LLMJudge`（启发式占位，仍是动能逻辑）：**金狗 vs 接盘**靠买占比区分——
  1h&5m 双跌 → reject(阴跌)；买占比 < `buy_ratio_reject`(0.42) → reject(卖压主导/接盘位)；
  买占比 ≥ `buy_ratio_pass`(0.50) 且 5m 未走弱 → pass(暴涨/late 也跟金狗)；`late`(1h≥300%)仅高位风险标签，不再一票否决。
  conviction 由动能(5m)+买盘驱动（已解饱和，不再被共识计数顶满）。

并行的另一条线（与每轮筛选同跑）：

```
持仓逃生监控(纯代码, 无 LLM): 复用本轮 trending 行的安全字段(零额外 cli; 掉榜的币才单独查)
  → assess_escape 比对建仓快照, 命中信号累加 severity
  → 信号(口径稳定的才用): honeypot 新触发 / 增发权找回(renounced_mint true→false) / top10 大幅集中(+15%)
    ⚠️ 不要用 burn_ratio: LP 销毁不可逆且 token security 与 trending 行口径不同, 相减必误报"流动性撤离"
  → 真实价格涨跌: 持仓记 entry_price, 监控比对当前价算 pnl
  → severity≥escape_severity(70) 即逃生预警 → 用户一键平仓
```

闸门与前端漏斗对齐（gate index）：`1=避雷  2=共识  3=ML排序  4=LLM  → 待决策`。

---

## 5. 去噪四介入点（设计来源，逐步落地）

来自需求讨论，区分 ML 与 LLM 职责：

1. **优先级排序与抑制**（主力去噪，非 LLM）：→ 已落地为 `priority_score`（**趋势动能加权**：5m/1h动能+买卖比+换手+共识降权+安全；CFG 可调权重；待换轻量 ML 排序）。
2. **去重与聚合**（ML/规则）：同一币多事件合并。→ 暂未实现（一币一行）。
3. **解释与情境化**（LLM 的活）：只对幸存者翻译成人话 + caveat。→ 已落地为 `LLMJudge`（**动能版金狗/接盘启发式占位**，待接真实 LLM）。
4. **个性化与阈值学习**（反馈闭环）：→ 未实现；`trade_decisions.jsonl` 已是原料（只写未读）。

---

## 6. 用到的 GMGN CLI 接口（共 7 个）

通过 `subprocess` 调全局安装的 `gmgn-cli`，统一加 `--chain <chain> --raw`。

> ⚠️ 实测环境为 **gmgn-cli 1.3.9**，与早期 1.0.x 接口已不同，代码已按 1.3.9 对齐：
> - `market trending` 参数是 `--order-by`（非 `--orderby`）、`--direction`，返回 `{"code":0,"data":{"rank":[...]}}`（非 `{"tokens":[]}`）。
> - **trending 行内已含几乎全部尽调字段**（`top_10_holder_rate`/`bundler_rate`/`dev_team_hold_rate`/`is_honeypot`/`renounced_mint`/`smart_degen_count`/`renowned_count`/`creation_timestamp`/`price_change_percent1h`…），故现已**直接用行字段建特征**（`FeatureExtractor.build_from_row`），不再对每个候选逐个调 info/security/holders，省掉绝大部分请求（含 `portfolio stats`）。
> - 真实 API **没有** `security_score`（0-100 安全分）、`change_since_smart_money`、聪明钱 `acc/dist` 状态字段。避雷改用真实布尔/数值字段直接判（honeypot/renounced_mint/buy_tax/sell_tax/rug_ratio/bundler/dev_hold/top10）；共识改用 `smart_degen_count + renowned_count` 计数；拥挤度用 `price_change_percent1h` 近似。
> - `token security` 在 `LiveGMGN` 内被**归一化**成逃生监控所需的安全快照 `{honeypot, renounced_mint, renounced_freeze, burn_ratio, top10}`，`MockGMGN` 输出同构。

完整 trending 命令示例：

| 命令 | 阶段 | 作用 | 实际调用频率 |
|---|---|---|---|
| `market trending` | 扫描 | 拉趋势榜候选（行内已含全部尽调字段） | **每轮 1 次（唯一常态 cli）** |
| `token info` | 尽调/价格 | `do_buy` 建仓价；持仓掉榜时查现价(token_price) | 仅买入/掉榜持仓时 |
| `token security` | 逃生 | 归一化安全快照；持仓**在榜则复用 trending 行**，掉榜才单独查 | 仅掉榜持仓 |
| `token holders` | — | 已基本不用（特征取自 trending 行） | 几乎不调 |
| `portfolio stats` | — | **已废弃**（共识改用 trending 的 degen/renowned 计数，不再逐钱包查胜率） | 不调 |
| `portfolio info` | 执行(LIVE) | 取绑定 Key 的本链钱包地址（swap 的 `--from`，自动解析+缓存） | 仅 LIVE 买/卖首次 |
| `swap` | 执行(LIVE) | 市价下单——**已解锁**：买入 `--input-token`=本链原生币、`--amount`=最小单位；卖出 `--input-token`=持仓币、`--percent 100` 全清 | LIVE 模式买/卖时 |
| `order get` | 执行(LIVE) | 轮询订单状态（取 status/hash） | LIVE 买入后 |

热榜命令**按链有默认**（`DEFAULT_TRENDING_CMDS`）：sol 默认带 pump 平台；bsc 默认带 fourmeme 系平台（fourmeme/fourmeme_agent/bn_fourmeme/cubepeg/likwid/goplus_creator/goplus_skills/openfour/flap/flap_stocks）；base/eth 走通用模板（无 `--platform`）。`--platform` 按链不同（pump 系仅 sol、fourmeme 系仅 bsc）。sol 示例：
```
gmgn-cli market trending --chain sol --platform Pump.fun --platform pump_mayhem --platform pump_mayhem_agent --platform pump_agent --interval 1h --order-by volume --limit 100 --raw
```
可在前端齿轮按链改（存 `ST.trending_cmds[chain]`）。`--interval 1h` 是热榜**统计窗口**，非扫描频率；扫描频率由前端轮询决定（默认 5.6s，齿轮可改；`_run_cmd` 自动补 `--raw`，命令须以 `gmgn-cli market trending` 开头）。

---

## 7. 技术栈与目录结构

- 后端：Python 3.10+，FastAPI + Uvicorn（仅这两个依赖，纯标准库 + 它们）。
- 前端：单文件 HTML + 原生 JS（无框架），后端同源托管（避免 CORS）。字体 Bricolage Grotesque + IBM Plex Mono。
- 数据源：`gmgn-cli`（LIVE）/ 内置 `MockGMGN`（默认，无 key 可联调）。

```
aitrader/
├── app.py                 # FastAPI 后端 + 完整筛选流水线(自包含)
├── requirements.txt       # fastapi, uvicorn
├── static/
│   └── index.html         # 前端 dashboard（源文件，本地开发改这个）
├── docs/
│   └── index.html         # = static/index.html 副本，GitHub Pages 发布 /docs
├── outputs/
│   ├── trade_decisions.jsonl   # 运行时生成: SCREEN/FILTER/BUY/SELL/UNMONITOR 日志(append-only)
│   └── positions.json          # 运行时生成: 持仓状态落盘(覆盖写, 启动加载, reload/重启不丢)
├── scripts/git-hooks/pre-commit  # 自动 cp static/index.html → docs/index.html(随仓库分发; 需 git config core.hooksPath scripts/git-hooks 启用一次)
├── README.md
└── SPEC.md                # 本文件
```
凭据不入项目，运行时写到本机 `~/.config/gmgn/.env`（含 `GMGN_API_KEY` / `GMGN_PRIVATE_KEY` / `GMGN_CHAIN`，chmod 600）。

**GitHub Pages 演示**：`static/index.html` 自适应——非 localhost（如 github.io）连不上后端时**自动进 DEMO 模式**显示示例数据、顶部挂演示横幅、不发任何 fetch、不能下单（纯静态、零接口、零 key、零带单嫌疑）。本地有后端则照常连真实。部署：Settings→Pages→`main` 分支 `/docs`。改前端后 pre-commit 自动同步 docs/（钩子在 `scripts/git-hooks/`，clone 后需 `git config core.hooksPath scripts/git-hooks` 启用一次，否则静默不同步）。

> 前端 `API` 走**同源**（`location.protocol==='file:'` 才回退到 `127.0.0.1:8000`）：本机/隧道访问都回到托管它的后端，纯静态托管（GitHub Pages）同源 `/api/status` 404 → 照常进 DEMO。这是公开演示能看到真实数据的前提（写死 `127.0.0.1` 时隧道访客只会打到自己机器的 localhost → 失败 → DEMO 假数据）。

**公开只读演示（`PUBLIC_DEMO=1`，真实数据 · 可挂公网）**：用于把看板给不特定访客看**真实**筛选（区别于 GitHub Pages 的 DEMO 假数据）。开启后后端收敛成纯只读，安全地满足「公网 + 真实数据」：
- 后台守护线程按 `DEFAULT_POLL_S` 定时跑 `screen_once` 并缓存——访客的 `POST /api/run` **只吐缓存，不由访客触发 gmgn-cli**，故 GMGN 配额与访客人数解耦、刷不爆（代价：只要实例开着就持续烧配额，与有无访客无关）。
- 所有写接口（`/api/config`·`/api/chain`·`/api/settings POST`·`/api/buy`·`/api/sell`·`/api/unmonitor`）一律 **403**；`/api/status` 多回 `public_demo:true`；持仓**不对外**（公开 `/api/run` 与 `/api/positions` 都剥掉持仓/组合）。
- 前端见 `public_demo:true` → `body.publicro` 只读态：隐藏买入/配置齿轮/源切换/买入数量/链切换/整块持仓监控卡，挂蓝色「实时真实数据 · 只读演示」横幅，链跟随后端。
- **仍只绑 `127.0.0.1`**：公网暴露请在外层用带限频/防 DDoS 的隧道完成（`cloudflared tunnel --url http://127.0.0.1:8000`）。key 不出本机。

---

## 8. 后端 API 契约

后端只绑 `127.0.0.1:8000`。所有接口前端已对接。

### `GET /api/status`（前端加载即探测，免重填 key）
```json
返回: { "live_adapter":bool, "chain":"sol", "mode":"SHADOW",
        "has_key":bool, "trading_locked":true, "public_demo":bool, "trending_cmd":"..." }
```
启动时后端读 `~/.config/gmgn/.env` 的 key 即自动切 `LiveGMGN`；前端据 `has_key` 自动连真实数据、无需手填。连不上（如 GitHub Pages）→ 前端 fallback DEMO。

> **链是请求维度（重要架构）**：后端不再有「全局当前链」。`/api/run`·`/api/buy`·`/api/settings` 都带 `chain`，后端按链处理；按链缓存 adapter（`ST.adapter_for(chain)`，同 key 仅 `--chain` 不同）+ 按链短缓存 trending（`TRENDING_CACHE_TTL=3s`，同链多 tab 共享一次 cli）。`mode`/`risk`/`positions` 仍全局（钱包级、跨链合一）。前端**每个 tab 用 `sessionStorage` 存自己的链**（互不干扰），`localStorage` 仅作「新 tab 默认链」种子。`/api/sell`·`/api/unmonitor` 不带 chain：卖出链由持仓自带的 `chain` 决定。`GMGN_CHAIN` env 退化为纯启动默认。

### `POST /api/config`
写 `.env`（api_key 可留空=沿用环境已有，不空值覆盖）并切适配器/模式。**不写 UI 选链**：写 env 时保留环境里已有的 `GMGN_CHAIN`（启动默认），不被 UI 选链快照覆盖。
```json
请求: { "api_key":"(可空)", "signing_key":"", "chain":"sol", "mode":"SHADOW|LIVE" }
返回: { "ok":true, "mode":"SHADOW", "live_adapter":bool, "trading_locked":bool }
```

### `POST /api/chain`（兼容保留，不改状态）
```json
请求: { "chain":"sol|bsc|base|eth" }
返回: { "ok":true, "chain":"bsc", "trending_cmd":"...该链命令..." }
```
只回该链热榜命令；**不再改任何全局状态**（链已随各请求传递）。前端切链不再调它。

### `GET/POST /api/settings`（热榜命令 / 按链记忆）
GET `?chain=<链>` 返回该链 `trending_cmd` + `default_trending_cmd` + `poll_interval_s`。
POST `{trending_cmd, chain}` 保存到指定链（`ST.trending_cmds[chain]`，并作废该链 trending 缓存）；**安全护栏**：命令必须以 `gmgn-cli market trending` 开头，否则 400。

### `POST /api/run`
请求 `{chain}`；跑该链一轮筛选 + 该链持仓监控。
```json
返回: {
  "decisions": [
    { "decision": { "symbol","address","action":"ACTION|SKIP","reason","size_sol",
                    "risk_warn":bool,"priority":int,"gate":int,
                    "verdict": {"verdict","conviction","crowdedness","thesis"},
                    "features": {"honeypot","renounced","renounced_mint","buy_tax","sell_tax",
                                 "bundler","dev_hold","top10","smart_degen","renowned","sm_confluence",
                                 "sniper_count","chg_1h","chg_5m","buy_ratio","turnover","liquidity","mcap","age_min"} },
      "exec": { "hard_sl","tp_ladder":[...],"trailing" } | null }
  ],
  "portfolio": { ...(同前)... },
  "positions": [ { "symbol","address","size_sol","pnl","entry_price","cur_price","severity",
                   "signals":[{"t":"...","hot":bool}] } ]
}
```
`action="ACTION"` = 通过全部闸门、待决策；`risk_warn=true` = 买入会触风控（前端按钮转琥珀色、提示不阻断）。

### `POST /api/buy`
成交前**再过一次硬风控**（硬拦 409）。LIVE+私钥→真实发单（按 `chain` 取 adapter/原生币/精度/钱包）；否则 SHADOW 只记录 + 落 positions.json，记 `chain`/`entry_price`。
```json
请求: { "address":"...", "size_sol":0.01, "chain":"sol" }
返回: { "ok":true, "status":"confirmed · <txhash> | SHADOW（…）", "symbol":"..." }
```

### `POST /api/sell` / `POST /api/unmonitor`
`/api/sell` 平仓（计风控）；`/api/unmonitor` **仅从逃生监控移除**（不卖出、不计风控）。
```json
请求: { "address":"..." }   返回: { "ok":true, "symbol":"..." }
```

### `GET /api/positions`
单独取持仓监控（前端主要走 `/api/run` 内的 positions）。

---

## 9. 前端看板

布局：演示横幅(仅DEMO) → 顶部状态条 → 7 KPI → 主区左(筛选结果表 + 实时日志) 右(持仓逃生监控 + 闸门漏斗 + 风控迷你条)。整体已为笔记本屏幕**紧凑化**(行/标题 padding 收紧)。

筛选结果表列：TOKEN(可点复制 Ticker + 雷达图标=该币已持仓) / 规则→排序→LLM(闸门图标) / 安全(蜜罐·放权徽章) / BUND / DEV / T10 / 聪明钱/KOL(degen/kol) / 时机(早期·横盘·过热·阴跌) / LLM(pass/watch/reject) / 优先级 / 决策。
- **TOKEN 列**：Ticker 下方显示 CA(前5…后4，点击新窗口开 GMGN 代币页) + 代币年龄(d/h/m/s，<1h 标绿)；点 Ticker 复制到剪贴板。
- **行点击**：展开下方解读详情，再点收起；默认不展开(省空间)。
- **「只看持仓」过滤**：TOKEN 旁 siren 图标开关，只显示已持仓的币。
- **即时 tooltip**：闸门图标 / LLM / 决策阵亡标签 / 时机 / 聪明钱列 hover 立即弹自画浮层(非原生 title)；委托挂在 document。
- **买入数量**：标题栏全局输入框，单位随链(SOL/BNB/ETH)，数值按链存 localStorage；改值下面所有买入按钮同步。
- **CHAIN 下拉**(右上)：SOL/BSC/Base/ETH 切换。**链是每个 tab 独立的**：本 tab 存 `sessionStorage`(多 tab 各看各链互不干扰)，`localStorage` 仅作新 tab 默认链种子。切链只改本 tab + 重扫(链随请求传)，不通知后端。
- **后台 tab 暂停轮询**：`document.hidden` 时 `scanCycle` 跳过(不烧配额)，tab 重新可见立即补一轮(`visibilitychange`)。

关键交互：
- **一键买入 / 平仓 / 取消监控 / 切 LIVE**：全部用**自定义居中确认弹窗**(`confirmDialog`，已无任何浏览器原生 confirm/alert)。
- **持仓逃生监控**：每个持仓显示 现价·建仓价 + PnL% + severity 进度条 + 信号 + 平仓 + ×取消监控；severity≥70 变红脉动；**该币在左侧筛选非全绿/掉榜 → 卡片闪一下弱红并保持**(escAlertSet，恢复全绿则消失)。标题显示 `N/上限 持仓`。
- **数据源**：DEMO(示例数据自跑) / 本地后端(轮询 `/api/run`)；`scanCycle` 有防重入(避免堆积)，请求返回前若已切走则丢弃结果。
- **刷新**：筛选区先骨架 loading，不假写代币；连不上后端→自动 DEMO。
- 安全：key 只发 127.0.0.1、不写 localStorage；链/买入数量等无敏感项才入 localStorage。

---

## 10. 风控与安全约束（不可破）

- 组合级硬风控：最大并发持仓、总敞口上限、当日亏损上限、连亏 kill-switch。筛选时只提示（`risk_warn`），成交时硬拦。
- 仓位 = 固定分数法（冒险额 / 止损距离），由代码算，LLM 永不出数字。
- 退出预案：硬止损 + TP 阶梯 + 移动止损，成交后挂策略单。
- 后端只绑 `127.0.0.1`，**禁止** `0.0.0.0` 或暴露公网。需对外只能走外层隧道（见 §7 `PUBLIC_DEMO`：绑定不变，靠隧道转发；且该模式下后端纯只读、写接口全 403、持仓不外泄）。
- key 写本机 `.env`（chmod 600），不入项目、不入浏览器存储；每个使用者用自己的 key（GMGN key 绑申请时 IP 白名单，不可共用）。

关键参数集中在 `app.py` 的 `CFG`。本会话相关：
- `top_n_prefilter=100`、`llm_max=20`（启发式占位不花钱，放大减少 gate3 误杀；接真实 LLM 再收紧）。
- 避雷：`require_renounced_mint`、`max_buy_tax/max_sell_tax=0.10`、`max_rug_ratio=0.60`、`max_bundler_ratio=0.30`、`max_dev_holding_pct=0.10`、`max_top10_concentration=0.40`。
- 共识：`min_smart_money_confluence=1`（=smart_degen+renowned）。
- 排序：`rank_weights={mom5m:30,mom1h:12,buy_pressure:18,turnover:12,consensus:12,safety:10}`；阴跌沉底 `momentum_reject_chg1h=-0.12/chg5m=-0.06`；金狗/接盘 `buy_ratio_pass=0.50/buy_ratio_reject=0.42`。
- 风控：`max_concurrent_positions=20`（**感受阶段放宽**，真实上线前应调回 2~3）、`max_total_exposure_sol=1.0`、`daily_loss_cap_sol=0.5`、`kill_switch_consec_losses=3`。
- 安全护栏：`LIVE_TRADING_DISABLED`（app.py 顶部）。**当前为 `False`（已解锁真实交易）**：LIVE 模式 + 已配 `GMGN_PRIVATE_KEY` 时，「一键买入/平仓」会经签名密钥**真实发单、动用资金、不可逆**。仍是人在环（只有点按钮才成交），SHADOW 仍是默认安全态、需手动切 LIVE 才真发。置回 `True` 即可一键封死所有链上写。
  - **真实下单前置**：`~/.config/gmgn/.env` 的 `GMGN_PRIVATE_KEY` 必须非空（签名密钥），否则 `gmgn-cli swap/order` 报错；前端会显示「链上买入失败：…」清晰原因，不建仓。
  - **多链已对齐**（gmgn-cli 1.3.9 权威 Chain Currencies 表）：原生币 SOL=`So111…112`(9 位)、BSC/Base/ETH=`0x0000…0000`(18 位)；`--from` 按链用 `portfolio info` 自动解析。**EVM 各链尚未用真金白银实测**（私钥配好后建议先小额逐链验证）。

---

## 11. 当前状态

**已完成（可运行）**
- `app.py`：完整 FastAPI 后端，含重排后的流水线、硬门槛、评分、LLM 占位、持仓逃生监控、风控、四个 API、静态托管、Mock 适配器。默认 Mock+SHADOW 不填 key 即可跑。
- `static/index.html`：完整前端看板，已对接全部接口，DEMO 模式可独立演示。
- 脚手架：requirements / README / 目录结构。

**本会话已完成（真实数据 · 只读行情 · 买入做假 · 动能策略 · 多链 · 可演示托管）**
- gmgn-cli 1.3.9 适配 + `build_from_row`（零额外 cli）+ 真实字段判据（见 §6）。
- **排序改趋势动能模型** + **LLMJudge 金狗/接盘逻辑**（见 §4）：暴涨不一刀切，买占比区分跟/砍。
- **持仓真实价格涨跌**（entry_price/cur_price/pnl）+ **落盘持久化**（positions.json，reload/重启不丢）+ **按链隔离** + **取消监控**(/api/unmonitor)。
- **逃生监控修误报**：删 burn_ratio 信号（不可逆+跨源口径），只留 honeypot/renounced_mint/top10。
- **多链切换**（SOL/BSC/Base/ETH）：**链改为请求维度**（无全局当前链）——按链缓存 adapter + 按链 trending 短缓存(3s，同链多 tab 共享一次 cli)；前端每 tab 用 sessionStorage 各自持链，N tab 各看各链互不干扰；后台 tab 暂停轮询省配额。按链记忆命令(ST.trending_cmds)、买入单位/数量按链。
- **启动自动连真实数据**（env key → use_live → /api/status → 前端 autoConnect），api_key 可留空。
- **热榜命令按链默认 + 齿轮可配**（/api/settings；sol 默认=pump platform 命令）。
- **性能**：scanCycle 防重入 + 监控复用 trending 行 → `/api/run` 33s→~1s。
- **安全护栏 LIVE_TRADING_DISABLED**（见 §10）。
- **GitHub Pages 演示**：static 自适应 DEMO + 演示横幅 + docs/ + pre-commit 同步（见 §7）。
- 前端：见 §9（CA可点/年龄/即时tooltip/只看持仓/雷达/弱红联动/自定义确认弹窗/骨架loading/紧凑化等）。

**占位 / 待接入**
- `LLMJudge.judge`：动能启发式占位 → 换真实 Claude/GPT（喂 `symbol_safe`+数值，绝不喂原始名；JSON 严格解析）。当前 llm_max=20。
- `priority_score`：确定性动能加权 → 可换轻量 ML 排序（介入点 1），训练数据=回填盈亏后的 `trade_decisions.jsonl`。
- 反馈飞轮（介入点 4）：`trade_decisions.jsonl` 已 append SCREEN/FILTER/BUY/SELL/UNMONITOR，**当前只写不读**；需回填实际盈亏 → 调 `CFG` 阈值。
- 自适应阈值：`CFG` 写死，未按市场温度自动收紧/放宽、未做激进/保守档。
- 去重聚合（介入点 2）：未实现。
- 逃生"流动性撤离"信号：删了不可靠的 burn_ratio，**真正的撤池应看 `liquidity` 下降**（需 entry 记 liquidity + 同源，未做）。
- 风控/状态：持仓已落盘；但 `RiskManager`（连亏/日亏/kill-switch）仍内存、不落盘，reload 即清。
- LIVE 真实下单：**已落地**（解锁 + 钱包自动解析 + 按链精度/原生币 + 卖出改 `--percent 100`，见 §10）。遗留：① EVM 各链未用真金白银实测（待私钥配好后小额逐链验证）；② `order get` 仅轮询一次，未做超时重试循环；③ `max_concurrent_positions` 仍为放宽的 20，真实上线前应调回 2~3。

---

## 12. 关键数据结构（实现参考）

- `TokenFeatures`（dataclass）：由 `build_from_row` 从 trending 行建。含 `symbol_safe`；动能 `chg_1h/chg_5m/buys/sells/buy_ratio/turnover/liquidity`；安全 `honeypot/renounced_mint/renounced_freeze/burn_ratio/buy_tax/sell_tax/rug_ratio`；筹码 `bundler/dev_hold/top10`；共识 `smart_degen/renowned/sniper_count/sm_confluence(=degen+renowned)`。（已删旧字段 `sec_score/lp_burned/sm_verified/sm_distributing/chg_since_sm`。）
- `LLMVerdict`：`verdict(pass/watch/reject)`、`conviction(0..1)`、`crowdedness(early/crowded/late/fading/distributing)`、`red_flags`、`thesis`。
- 持仓 position：`{symbol,address,chain,size_sol,pnl,cycles,entry_price,cur_price,entry{honeypot,renounced_mint,renounced_freeze,burn_ratio,top10}}`。`entry` 是建仓安全快照(`assess_escape` 做 diff，但已不再用 burn_ratio diff)；落盘到 `outputs/positions.json`。
- 适配器归一化 `token_security` / `_sec_from_row`：`{honeypot,renounced_mint,renounced_freeze,burn_ratio,top10}`，Live 与 Mock 与 trending 行三者口径需一致（burn_ratio 是已知不一致点，故逃生不用它）。

---

## 13. 编码约定

- 注释/文案中英混排，与现有代码风格一致。
- 纯标准库优先，新依赖需谨慎（目前仅 fastapi+uvicorn）。
- 适配器模式：所有链上读写走 `GMGNAdapter` 抽象，`MockGMGN` 与 `LiveGMGN` 可互换，便于无 key 联调与回测。
- 确定性逻辑与 LLM 逻辑严格分文件区块，改动时不得让 LLM 越权到风控/逃生/仓位。