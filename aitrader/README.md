# GMGN AI Trader (local)

看板筛、人成交：确定性规则抓全 → 评分砍狠 → LLM 只解释幸存者 → 你按下一键买入。
另起一条持仓逃生监控，命中 rug 信号即提示一键平仓。LLM 永远碰不到风控与逃生路径。

> 完整设计 / API 契约 / 当前进度见 [SPEC.md](SPEC.md)。本文件只讲怎么跑起来。

## 目录结构
```
aitrader/
├── app.py                 FastAPI 后端 + 筛选流水线（自包含）
├── requirements.txt       fastapi, uvicorn
├── static/
│   └── index.html         前端 dashboard（源文件，本地开发改这个，后端同源托管）
├── docs/
│   └── index.html         static/index.html 副本，供 GitHub Pages 发布
├── outputs/
│   ├── trade_decisions.jsonl   运行时生成（SCREEN/FILTER/BUY/SELL/UNMONITOR 日志）
│   └── positions.json          运行时生成（持仓落盘，重启不丢）
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
- 右上 CHAIN 下拉切换 **SOL / BSC / Base / ETH**（存浏览器 localStorage，不写 env）。
- 通过全部闸门的候选会摆成「待你决策」，点「一键买入」才成交。
- 持仓出现在右侧逃生监控，劣化到阈值（severity≥70）会弹「立即平仓」。

## 成交是做假的（重要）
`app.py` 顶部 `LIVE_TRADING_DISABLED=True` 硬锁死链上成交：
**即使配了 key、即使切到 LIVE，也强制 SHADOW、绝不调用 `swap()`。**
SHADOW 下买入/平仓只落日志 + 写 positions.json，不发任何链上交易。
要真实下单需手动把该常量置 False，并核对代码里标注的 LIVE 占位项（钱包地址、卖出语义、`max_concurrent_positions` 调回保守值等，见 SPEC §10/§11）。

## GitHub Pages 演示
非 localhost（如 github.io）连不上后端时，前端**自动进 DEMO 模式**：显示示例数据、挂演示横幅、不发任何 fetch、不能下单（纯静态、零接口、零 key）。
部署：Settings → Pages → `main` 分支 `/docs`。改前端后 pre-commit 自动把 `static/index.html` 同步到 `docs/`。

## 安全
- 后端只绑 127.0.0.1，切勿改成 0.0.0.0 或暴露公网。
- key 只发往本机后端、写本机 .env、不入浏览器存储。

## 待接入（代码里已标注，详见 SPEC §11）
- `LLMJudge.judge`：现为动能启发式占位，生产换真实 LLM（喂消毒后的 symbol_safe + 数值，绝不喂原始币名）。
- `priority_score`：现为确定性动能加权（对应文档的 ML 排序），可换轻量模型。
- 反馈飞轮：trade_decisions.jsonl 已是原料，回填实际盈亏后用来调 CFG 阈值（当前只写不读）。
