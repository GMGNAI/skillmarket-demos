# 钱包评估 Tab — 改动说明 / Handoff

> 本文件记录在原 aitrader demo（代币筛选）基础上新增的「钱包评估」Tab 及相关改动，
> 方便在别的编辑器（如 VS Code 的 Claude Code）无缝接手继续开发。
> 最后更新：2026-07-14。

## 一句话概括
在原来的「代币筛选」之外，新增并列的「**钱包评估**」Tab：输入一个钱包地址，输出交易风格标签、
**真实战绩分** / **可跟单分** 双评分、**Dev 信誉**、以及一个带滑块的**跟单回测模拟器**。
核心洞察（沿用参考设计）：**高战绩 ≠ 你能抄到** —— 把「他是不是真有本事」和「你跟单能拿到多少」拆成两个分。

## 怎么跑起来
```bash
cd /Users/chumeijuan/Documents/skillmarket-demos/aitrader
# 虚拟环境已建好（Python 3.11，见 .venv/）
.venv/bin/uvicorn app:app --host 127.0.0.1 --port 8000 --reload
# 浏览器打开 http://127.0.0.1:8000
```
- 这是 Python / FastAPI 应用，不需要"编译"，uvicorn 启动即可。
- 改前端 `static/index.html` 普通刷新即生效（后端已加 no-cache 头，见下）。
- 免 key 也能跑（走内置 MockGMGN，合成 7 种钱包画像）；配了 `~/.config/gmgn/.env` 的 `GMGN_API_KEY` 则自动连真实行情。

## 涉及文件
- `app.py` — 后端：适配器、评分逻辑、`/api/wallet` 端点、no-cache 中间件。
- `static/index.html` — 前端：Tab 切换 + 钱包视图（源文件，改这个）。
- `docs/index.html` — GitHub Pages 副本，**目前是旧版、未同步**（钱包 Tab 未部署到 Pages）。
  提交时 `scripts/git-hooks` 的 pre-commit 会把 static → docs 同步（需先 `git config core.hooksPath scripts/git-hooks`）。

---

## 后端改动（app.py）

### 1. 适配器新增能力
- `GMGNAdapter.wallet_activity(wallet, limit, cursor)` —— 逐笔交易（买入行含 `price_usd`×`total_supply`=进场市值；买卖时间戳配对=持仓时长）。
  - `LiveGMGN`：调 `gmgn-cli portfolio activity`。
  - `MockGMGN`：按地址稳定哈希合成，见下。
- `LiveGMGN.portfolio_stats` 改为带 `--period 7d`。

### 2. Mock 钱包画像（免 key 演示）
- `_stable_seed(str)`：不依赖 PYTHONHASHSEED 的稳定哈希，同一地址每次落到同一原型。
- `_MOCK_ARCHETYPES`：7 种原型 —— sniper / diamond / whale / bot / dev(工厂号) / devgood(正经dev) / degen。
- `MockGMGN.portfolio_stats / wallet_activity / created_tokens` 按原型合成同构数据。
- 演示示例地址（前端示例 chips 用）：`DemoSniper1` / `DemoDiamond7` / `DemoWhale1` / `DemoBot4` / `DemoFactory3` / `DemoGoodDev2` / `DemoDegen6`。

### 3. 钱包评估核心逻辑（都是确定性纯代码，LLM 不参与）
- `_norm_wallet_stats(raw)` —— 归一化 `portfolio stats`（PnL/胜率/盈亏分布分桶/均持仓/推特/created_token_count 等）。
- `_activity_summary(raw)` —— 从抽样逐笔算：进场市值 <$100k 占比、中位进场市值、5秒闪买闪卖占比、均 gas。
- `wallet_tags(w, summ, dev)` —— **交易风格标签**（规则见下）。
- `track_record_score(w)` —— **真实战绩分**：因子权重 `WALLET_CFG["track_w"]`（止损纪律 tail 主导 + 盈利面/ROI/胜率/样本量）。低胜率也能高分。
- `copytrade_score(w, summ)` —— **可跟单分**：5 因子（进场市值/单笔利润/持仓vs延迟/执行可行性/优势类型），加权平均。
- `copytrade_backtest(w, summ, latency, slippage, gas)` —— 跟单回测：`跟单% = 钱包% − 延迟漂移 − 双边滑点 − gas`。
  - `wallet_pct` 钳制到 `[-0.9, 3.0]`（dev 钱包 bought_cost 极小会导致比值爆表，故钳制）。
  - 抄单陷阱敞口 = 钱包 7D − 跟单者 7D。
- `wallet_dev_profile(g, chain, wallet)` —— 复用选币侧 `dev_score`（存活率/rug率/内盘沉底/换皮/安全扫描）。
- `wallet_verdict(...)` —— 一句话结论（规则生成）。

### 4. 端点 `POST /api/wallet`（WalletIn）
- 入参：`chain, address, latency_s=3, slippage_pct=0.05, gas_usd=0.2, sample=200`。
- `_sample_activity` 翻页抽样最近 N 笔（最多 4 页）。
- **Dev 判定门槛**：`created_token_count > 0 且 created_token_count > 0.5 × token_num`（自己发的币 > 交易币数一半）才算发币方 → 查 dev 信誉 + 打 Dev 标签。否则视为纯交易者。

### 5. no-cache 中间件
- `@app.middleware("http") _no_cache`：给所有响应加 `Cache-Control: no-cache, no-store, must-revalidate` + `Pragma` + `Expires`。开发时改前端普通刷新即生效。仅本机，无 CDN 副作用。

---

## 交易风格标签规则（wallet_tags）
中间量：`trades`=买+卖总笔数；`tn`=交易币种数；`big_win`=(>500%+200–500%)/tn；`big_loss`=(<−50%)/tn；
`early`=进场<$100k 占比；`flip`=5秒闪买闪卖占比。

| 标签 | 触发条件 |
|---|---|
| 🏭 发币方 / Dev | `dev != None`（= 发币数 > 交易币数一半，见端点门槛）|
| 🤖 机器人 / 科学家 | `trades ≥ 2000` |
| ⚡ 闪电手 | `flip ≥ 0.3` |
| 🎯 狙击手 | `early ≥ 0.8` |
| 💎 钻石手 | `avg_hold_s ≥ 5天` 且 `trades < 200` |
| 🐋 巨鲸 | `avg_buy_usd ≥ $5000` |
| 📈 真高手 | `realized_profit > $20k` 且 `big_loss ≤ 0.05` |
| 🩸 亏损韭菜 | `big_loss ≥ 0.3` 且 `realized_profit < 0` |
| 🎰 赌狗打法 | `big_win ≥ 0.02` 且 `胜率 < 0.35` 且 `realized_profit > 0` |
| 🐌 慢工出细活 | `trades < 60` 且 `realized_profit > 0` 且 `flip < 0.1` |
| 🏆 高胜率 | `胜率 ≥ 0.65` 且 `trades ≥ 15` |
| 🐇 快枪手 | `0 < avg_hold_s < 1小时` 且 `flip < 0.3` 且 `trades ≥ 30` |
| 🔦 冷门捡漏 | `中位进场市值 < $30k`（绝对值，区别于「狙击手」按早期占比判定）|
| 🧭 普通交易者 | 以上都没命中的兜底 |

- 高手/韭菜/赌狗三者 `if/elif` 互斥；其余可叠加。
- 阈值都是演示级启发式，未经数据校准，可按实际标准调。

---

## 前端改动（static/index.html）
- 顶部加 Tab 切换：`#tabToken`（代币筛选，原有）/ `#tabWallet`（钱包评估，新）；`switchView(v)` 切换，状态存 sessionStorage。
- 原 kpis+grid 包进 `#viewToken`；新增 `#viewWallet`。
- 钱包视图渲染 `renderWallet()`，卡片顺序：**头部卡 → 真实战绩分·可跟单分 → Dev 信誉 → 因子拆解 → 跟单回测 → AI 结论**。
  - **Dev 信誉块始终显示**：是发币方→评分+6项指标；不是→显示"该地址未发过 token"。
- 跟单回测 3 个滑块（延迟/滑点/gas）由 `btCompute()` **客户端镜像后端公式**即时重算（与后端 `copytrade_backtest` 保持一致，含 `[-0.9, 3.0]` 钳制）。
- 中英双语：静态属性走 I18N（`tab_token` 等）；钱包动态内容走 `WLK[lang]` 字典，`applyI18n()` 里已挂钩语言切换时重渲染。
- CSS 命名注意：钱包相关辅助函数/类避开了已有的 `fmtMc` 等全局名（曾因重名导致整段脚本语法错误）。

## 已知限制 / TODO
- 钱包 Tab **依赖本地后端**（`/api/wallet`）。GitHub Pages 纯静态托管 / DEMO 模式下连不上真后端时，点评估会
  提示"需本地后端"，不发真实请求；`showWalletDemo()` 会自动填一个假地址 + 写死的示例结果，仅演示页面布局。
- **[2026-07-17] 新增 robinhood 链**：`gmgn-cli` 1.5.1 新增支持，已升级本地 `gmgn-cli` 到 1.5.2 并实测验证：
  `market trending`/`portfolio stats`/`portfolio activity`/`portfolio created-tokens`/`token security`/`token info`
  六个命令在 robinhood 上返回的字段结构与 bsc/base/eth 完全一致；`token info --address 0x000...000` 实测确认
  原生币是 ETH（18 位精度），故 `NATIVE_TOKEN`/`NATIVE_DECIMALS` 沿用与 bsc/base/eth 相同的 `0x0`+18 位约定。
  **注意**：`cooking create`（发币）与 `track kol`/`track smartmoney`/`market signal` 官方文档标注暂不支持
  robinhood（本应用未调用这几个命令，不受影响）；`swap`/`order`/`gas-price` 虽然 `--chain robinhood` 可用，
  但官方 README 的 Chain Currencies 表没列出该链币种，真实下单前务必自己先跑一次小额验证。
- **[2026-07-17] 修复：无真实交易记录的钱包被打出虚高分数**：GMGN `portfolio stats` 偶尔在 `trades=0`
  （buy=sell=0，从没真实买卖过）时仍返回非零 `token_num`/`dist`（疑似把转入/空投持有的代币也计进去了），
  照旧公式硬算会把"完全没数据"误判成"从不亏钱"，凑出一个看似正常实则毫无依据的高分。现在 `api_wallet`
  （[app.py:1917](app.py#L1917)）检测到 `trades==0` 就直接跳过打分/回测，标签只给"❔无交易记录"，
  真实战绩分/可跟单分前端显示"—"而不是数字，跟单回测栏也换成对应提示文案。
- EVM 链字段已实盘验证（2026-07-14，`gmgn-cli` 当前开放 sol/bsc/base/eth/robinhood 五条链）：
  `portfolio stats`/`portfolio activity`/`portfolio created-tokens` 三个接口在 bsc/base/eth 上返回的字段名和结构
  与 sol 一致（`wallet_address`/`pnl_stat.*`/`common.*`/`activities[].token.total_supply`/`price_usd`/`gas_usd` 等），
  `/api/wallet` 端到端跑真实地址（vitalik.eth、Binance Hot Wallet 20 等）均 200，未见解析报错。
  **发现一个数据质量坑**：dev 判定门槛用的 `common.created_token_count`（见端点里 `ctc > 0.5×token_num`）在
  base 链上对已确认发过币的钱包（用 `market trending` 的 `creator` 字段反查）仍返回 `0`，而同一钱包查
  `portfolio created-tokens` 明明能查到已发币；eth 链上同类测试该字段正常（非 0）。像是 GMGN 后端在 base 上
  这个字段回填不全，不是我们代码的 bug，但意味着 **base 链的「发币方」可能被漏判**（该钱包会被当成纯交易者，
  不展示 Dev 信誉卡）。如果这个漏判影响实际使用，可以改成对 EVM 链直接查一次 `created-tokens` 的 `tokens` 数组
  长度做门槛判断，而不是只信 `portfolio stats` 里的 `created_token_count`。
- 各评分阈值/权重为启发式占位，未用真实盈亏回填校准。
- **[已修复 2026-07-14] Dev 信誉卡「历史发币」数量显示错误**：`static/index.html` 渲染时优先取
  `dv.analyzed`（=`created-tokens` 原始 `tokens` 数组长度，被 gmgn-cli/API 截断在 ~100 条，只是取样数，
  不是真实总数），只在其为空时才 fallback 到真正代表「毕业发币数」的 `dv.launches`（= created-tokens 的
  `open_count`）。实测一个真实工厂号钱包（sol `timeworn2X1EwMLSzeVhdVTbVSzSCKuibKd2kQ2Lsyn`）：
  `open_count=4`（真·毕业发币数）、`inner_count=496`（内盘沉底），但 `tokens` 数组只截断到 100 条，
  导致原代码显示「历史发币 100」而不是真实的 4，被严重高估。已改成优先用 `dv.launches`（[static/index.html:1780](static/index.html#L1780)），
  与选币侧 devcard 的既有惯例（`devLaunches`=毕业数为主，`inner_count` 单独展示）保持一致。
  **附带限制**：`dv.analyzed`/`alive`/`rugged`/`rug_rate` 仍然只基于这最多 100 条的截断样本算，
  发币数超过 100 的钱包，rug 率只是「取样估计」不是精确值——`created-tokens` 这个 gmgn-cli 命令目前
  没有分页参数（`--help` 里只有 `--order-by`/`--direction`/`--migrate-state`），没法翻页拉全量。
- `docs/index.html` 未同步最新 static（部署 Pages 前需同步）。
