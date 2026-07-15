# GMGN AI Trader (local)

**[English](README.en.md)** · 中文

看板筛、人成交：确定性规则抓全 → 评分砍狠 → LLM 只解释幸存者 → 你按下一键买入。
另起一条持仓逃生监控，命中 rug 信号即提示一键平仓。LLM 永远碰不到风控与逃生路径。

> 完整设计 / API 契约 / 当前进度见 [SPEC.md](SPEC.md)。本文件只讲怎么跑起来。

## 支持的功能

- **选币流水线**：`market trending` 拉趋势榜候选（行内已含尽调字段，零额外 cli）→ **确定性硬门槛**避雷（蜜罐/买卖税/rug/bundler/dev 持仓/前 10 集中度）+ 共识（聪明钱/KOL 计数）→ **趋势动能评分排序**（5m/1h 动能·买卖比·换手·共识·安全·dev）→ **LLM 只对幸存者解释**（verdict/conviction/crowdedness/thesis）→ 产出候选、代码算仓位。
- **钱包评估 Tab**：与「代币筛选」并列的独立 Tab，输入任意钱包地址即可拆解交易风格。核心洞察：**高战绩 ≠ 你能抄到**，把「他是不是真有本事」和「你跟单能拿到多少」拆成两个分：**真实战绩分**（止损纪律主导 + 盈利面/ROI/胜率/样本量，低胜率也能高分）与**可跟单分**（进场市值/单笔利润/持仓时长 vs 你的延迟/执行可行性/优势类型）；14 种**交易风格标签**（发币方/机器人/闪电手/狙击手/钻石手/巨鲸/真高手/亏损韭菜/赌狗打法/慢工出细活/高胜率/快枪手/冷门捡漏/普通交易者，规则详见 [WALLET_TAB_NOTES.md](WALLET_TAB_NOTES.md)）；判定为发币方（自己发的币 > 交易币数一半）时复用选币侧 **Dev 信誉**评分，且真实战绩分/可跟单分自动打折（自己发的币对进场时机/胜率无参考意义）；带延迟/滑点/gas 三滑块的**跟单回测模拟器**，客户端实时镜像后端公式重算。全页面中英双语，右上角切换即时生效；确定性规则打分，**LLM 不参与**。
- **Dev 评估维度**：对初排靠前的候选查 dev 钱包发币历史（`portfolio created-tokens`）+ 最近 N 个发币逐币安全扫描（`token security`），算出 dev 信誉分——**逐币存活率主导** + 内盘沉底/发不安全币（可增发/未弃权/未开源/貔貅）/换皮重发/已清仓减分。既是**排序子分**、又是**过滤门**：连环 rug 的工厂号、换皮重发的 dev 直接拦掉（不只是降分）。前端有 `DEV评分` 列 + 点行弹「Dev 信誉卡」（历史发币/rug 率/存活/换皮/安全风险）。
- **持仓逃生监控**：建仓落安全快照，每轮 diff 复检（蜜罐/弃权/前 10 集中度），劣化到阈值弹「立即平仓」。与选币/风控严格分离，LLM 永远碰不到逃生路径。
- **一键买入 / 平仓（人在环）**：通过全部闸门的候选摆成「待你决策」，只有你点按钮才成交；买入轮询确认真实成交，失败不记仓、不谎报，成交带 tx hash。
- **实盘 / 模拟盘**：SHADOW（模拟盘，默认安全态，只落日志）↔ LIVE（实盘，真实资金、不可逆）一键切换 + 二次确认；`app.py` 顶部 `LIVE_TRADING_DISABLED` 总开关可一键封死所有链上写。
- **多链**：SOL / BSC / Base / ETH 请求维度切换，按链缓存 adapter + 短缓存热榜、按链记忆命令与买入单位；多 tab 各持各链互不干扰。
- **持久化 / 隔离**：持仓落盘（`positions.json`，重启不丢）+ 按链隔离；决策全程写 `trade_decisions.jsonl`（SCREEN/FILTER/BUY/SELL/UNMONITOR）。
- **免 key 可跑**：内置 `MockGMGN` 适配器合成同构数据，不装 gmgn-cli、不填 key 也能完整联调演示；配了 key 启动即自动切真实行情。
- **GitHub Pages 演示模式**：非 localhost 且连不上后端时前端自动进 DEMO 模式（示例数据 + 演示横幅，零接口、零 key、不能下单）。

## 目录结构
```
aitrader/
├── app.py                 FastAPI 后端 + 筛选流水线（自包含）
├── requirements.txt       fastapi, uvicorn
├── static/
│   └── index.html         前端 dashboard（源文件，本地开发改这个，后端同源托管；含代币筛选 + 钱包评估两个 Tab）
├── docs/aitrader/
│   └── index.html         static/index.html 副本，供 GitHub Pages 发布
├── outputs/
│   ├── trade_decisions.jsonl   运行时生成（SCREEN/FILTER/BUY/SELL/UNMONITOR 日志）
│   ├── positions.json          运行时生成（持仓落盘，重启不丢）
│   └── trending_cmds.json      运行时生成（按链热榜命令覆盖，重启不丢；齿轮内「↺ 重置」删回默认）
├── README.md
└── SPEC.md
```
凭据不在项目里，运行时写到本机：`~/.config/gmgn/.env`（chmod 600）。

## 准备（一次性）
1. Python 3.10+
2. 仅 LIVE / 真实行情需要：装 `gmgn-cli`（实测对齐 **1.3.9**，1.0.x 接口已不兼容）
   ```bash
   npm install -g gmgn-cli@1.3.9
   ```
3. 仅 LIVE / 真实行情需要：去 gmgn.ai/ai 用自己的 Ed25519 公钥 + 出口 IP 申请 API Key
   （key 绑定申请时的 IP 白名单，每个使用者用自己的，不能共用）

不装 gmgn-cli、不填 key 也能跑——默认走内置 `MockGMGN` 适配器。

4. 仅改前端者需要：启用 git 钩子（改 `static/index.html` 提交时自动同步到 `docs/`）
   ```bash
   git config core.hooksPath scripts/git-hooks
   ```
   钩子脚本随仓库分发，但这行 `git config` 是本地配置、不随 clone 传递，**每人 clone 后需各跑一次**；没跑则改了 `static/` 而 `docs/` 不更新，GitHub Pages 演示会静默停在旧版。

## 启动
```bash
# 在 skillmarket-demos 仓库根下
cd aitrader
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn app:app --host 127.0.0.1 --port 8000
```
浏览器打开 http://127.0.0.1:8000

> 启动时后端会读 `~/.config/gmgn/.env` 的 key，有 key 即自动切真实数据，前端无需手填。

## 使用
- 默认 Mock 适配器 + SHADOW 模式，**不填 key 也能跑**（联调用）。
- 配了 key 则自动连真实行情；右上齿轮可改每条链的热榜命令 / 轮询间隔。
- 右上 CHAIN 下拉切换 **SOL / BSC / Base / ETH**（每个 tab 用 sessionStorage 各自持链，多 tab 互不干扰）；右上 **MODE 图标点击切实盘/模拟盘**。
- 通过全部闸门的候选会摆成「待你决策」，点「一键买入」才成交。
- 持仓出现在右侧逃生监控，劣化到阈值（severity≥70）会弹「立即平仓」。

## 实盘 / 模拟盘（重要）
- **SHADOW（模拟盘）= 默认安全态**：买入/平仓只落日志 + 写 positions.json，**不发任何链上交易**。
- **LIVE（实盘）= 真实成交、动用资金、不可逆**：需 ① 右上角 **MODE 图标点切到实盘**（会二次确认）+ ② `~/.config/gmgn/.env` 配好 `GMGN_PRIVATE_KEY`（Ed25519 PEM 签名密钥，非钱包私钥）。
- `app.py` 顶部 `LIVE_TRADING_DISABLED`：**当前为 `False`（已解锁）**。置回 `True` 即可一键封死所有链上写（即便切 LIVE 也强制 SHADOW、绝不调 `swap()`）。
- 仍是**人在环**：只有你点「一键买入/平仓」才成交；后端重启后 mode 回 SHADOW（不持久 LIVE），需重新切。
- 买入会**轮询确认真实成交**：失败不记仓、不谎报；成交提示带 tx hash，自己点链上浏览器核对最稳。
- ⚠️ 真实交易**目前仅 Solana 完整验证**；EVM 见下方「已知限制」。

## GitHub Pages 演示
非 localhost（如 github.io）连不上后端时，前端**自动进 DEMO 模式**：显示示例数据、挂演示横幅、不发任何 fetch、不能下单（纯静态、零接口、零 key）；钱包评估 Tab 切到 DEMO 时同样会自动填一个假地址 + 假查询结果，仅演示页面布局，不代表任何真实数据。
部署：Settings → Pages → `main` 分支 `/docs`。改前端后 pre-commit 自动把各 demo 的 `<demo>/static/index.html` 同步到 `docs/<demo>/index.html`（本 demo 即 `docs/aitrader/index.html`）。

## 安全
- 后端只绑 127.0.0.1，切勿改成 0.0.0.0 或暴露公网。
- key 只发往本机后端、写本机 .env、不入浏览器存储。

## 已知限制 / 待办

**⚠ 买入时的自动卖出策略 —— 尚未实现**
前端买入弹窗显示的「退出预案（硬止损 / TP 阶梯 / 移动止损）」目前**只是展示文案**（`exit_plan()`）。`do_buy` 真实下单调的 `swap()` **没有传 `--condition-orders`，实际并没有挂任何止盈止损单**，买入后只能靠人盯盘 + 逃生监控 + 手动平仓。待办：按 TP/SL 阶梯拼 `--condition-orders` 随 swap 一并提交（参数语义/各链支持度需对照真实接口验证）。

**⚠ 钱包评估 —— base 链 Dev 判定有已知数据坑**
判定「是否发币方」用的 `created_token_count` 字段在 base 链上对已确认发过币的钱包仍可能回填成 0（GMGN 后端数据问题，非本项目代码 bug），可能导致该链上的发币方被漏判为纯交易者、不展示 Dev 信誉卡；sol/bsc/eth 未见此问题。各评分阈值/权重同样是启发式占位，未用真实盈亏回填校准。详见 [WALLET_TAB_NOTES.md](WALLET_TAB_NOTES.md)。

**⚠ EVM 链筛选疑似有问题 —— 目前只有 Solana 完整跑通**
- **Solana**：筛选 / 买 / 卖 / 持仓监控全链路已验证（含 `order quote` 实测签名）。
- **EVM（BSC / Base / ETH）**：链路已接（adapter / 原生币 `0x0` / 18 位精度 / 钱包解析 / bsc 默认 fourmeme 平台命令均按权威表对齐），但**筛选结果疑似不对/不全、未完整验证，买卖也未实盘逐链验证**。疑点：EVM `market trending` 行字段是否与 `FeatureExtractor.build_from_row` / `hard_gates` 的 Solana 假设一致（`is_honeypot`/`renounced_mint`/`bundler_rate`/`buys/sells` 等可能命名不同或缺失 → 避雷门/动能打分跑偏）；base/eth 是否需按链配 launchpad 平台。**EVM 当前建议只作只读浏览，实盘前先查清 + 小额逐链验证。**

**待接入（代码里已标注，详见 SPEC §11）**
- `LLMJudge.judge`：现为动能启发式占位，生产换真实 LLM（喂消毒后的 symbol_safe + 数值，绝不喂原始币名）。
- `priority_score`：现为确定性动能加权（对应文档的 ML 排序），可换轻量模型。
- 反馈飞轮：trade_decisions.jsonl 已是原料，回填实际盈亏后用来调 CFG 阈值（当前只写不读）。
