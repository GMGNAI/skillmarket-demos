# GMGN AI Trader · Project Specification (SPEC)

English · **[中文](SPEC.md)**

> Single-file context for AI collaborators / new maintainers. Reading this one document is enough to understand: what to build, why it's designed this way, the current progress, and where work still needs to continue.

---

## 1. One-sentence definition

A **local** memecoin screening and trading tool built on **GMGN Skills / MCP** (`gmgn-cli`):
**the machine screens, the human presses to trade.** Deterministic rules cast a wide net → ML scoring cuts hard → the LLM only explains the surviving few → the user buys with one click; meanwhile position escape signals are monitored in real time.

- Form: a local web app (FastAPI backend + single-page HTML frontend, backend serves the frontend same-origin).
- Users: yourself + a few trusted people, each running on their own machine with their own key.
- Risk disclaimer: a pure trading tool; profit and loss are the user's own responsibility; this project does not provide investment advice.

---

## 2. Core positioning decision (important)

After discussion, we explicitly chose **human-in-the-loop** over a fully automated bot:

- The pipeline **only produces candidates**; it does not auto-trade.
- Candidates that pass all gates, with a code-computed position size, are laid out on the dashboard awaiting the user's decision.
- An actual trade happens only when the user clicks "one-click buy" (corresponding to `POST /api/buy`).
- Every candidate must be **tradeable in place with one click**, otherwise it's just a free dashboard funneling flow to competitors.

Abandoned approach: an auto-executing bot (`swap` triggered autonomously by code). The original `ai_trader.py` was a prototype of that approach; its logic has been absorbed into `app.py` and refactored.

---

## 3. Architectural iron rules

1. **The LLM never stands in the event torrent.** The LLM is slow and expensive; it only handles the few that remain "after deterministic rules + score ranking".
2. **All triggering/gating is deterministic.** Whether something advances to the next gate is decided by rules/quantitative judgment; the LLM only gives "suggestion + reasoning + confidence", has no gating authority, and produces no position-size numbers.
3. **The LLM touches neither the risk-control layer nor the escape path.** Risk control (concurrency/exposure/stop-loss/kill-switch) and position escape alerts are pure code — fast and hallucination-free.
4. **On-chain text is never trusted.** Fields like token names must be sanitized before entering the LLM (neutralizing prompt injection), and only the sanitized `symbol_safe` + numeric features are fed in — never the raw name.

---

## 4. Pipeline (strict order)

```
trending (cheap, 1 cli call, the row already contains all due-diligence fields)
  → take the first top_n_prefilter rows → build features directly from row fields (build_from_row, zero extra cli)
  → deterministic hard gates [run first] (rug gate + consensus)        ← cuts most
  → initial ranking (priority_score, trend momentum model)             ← first sort by momentum score
  → dev evaluation dimension (query dev history for the top dev_pool_n only, TTL-cached) → fold dev sub-score into priority_score, re-rank
  → take the first llm_max                                             ← cuts again
  → LLM only explains the survivors (verdict/conviction/crowdedness/thesis)
  → produce candidates + code-computed position size (does not execute)
  → [user clicks one-click buy] → one more hard risk-control pass before trading → SHADOW record / LIVE real order
```

**Ranking = trend momentum model** (the coin-selection objective chosen by the user, see `CFG["rank_weights"]`):
- `priority_score` = weighted(5m momentum·30 + 1h momentum·12 + buy/sell ratio·18 + turnover·12 + consensus·12 + safe float·10 + **dev eval·12**), with each sub-score normalized; if 1h is bleeding down, the whole thing is ×0.4 to sink it.
- **dev evaluation dimension** (`dev_score`, pure-code 0..1 bonus term): a past golden runner (`ath_mc`) adds significant points; serial launching (`creator_open_count`>50) / deleting promo tweets (`twitter_del_post_token_count`) / having exited this token (`creator_token_status`+balance) subtract; community takeover (CTO) provides a floor. Data comes from the `dev` object in `token info` — **an extra cli call is made only for the top `dev_pool_n`(24) survivors after initial ranking**, results cached per-address for `dev_info_ttl_s`(600s) and reused across cycles rather than re-fetched. Not found → neutral 0.5, no false kill, no blocking.
- `LLMJudge` (heuristic placeholder, still momentum logic): **golden runner vs bag-holder** is distinguished by buy ratio —
  1h & 5m both down → reject (bleeding down); buy ratio < `buy_ratio_reject` (0.42) → reject (sell-pressure dominant / bag-holder spot);
  buy ratio ≥ `buy_ratio_pass` (0.50) and 5m not weakening → pass (a moonshot/late one still follows the golden runner); `late` (1h ≥ 300%) is only a high-position risk tag, no longer an automatic veto.
  conviction is driven by momentum (5m) + buy-side (de-saturated, no longer capped by the consensus count).

The parallel second line (running with each screening round):

```
position escape monitor (pure code, no LLM): reuses the safety fields of this round's trending rows (zero extra cli; only coins that fell off the board are queried separately)
  → assess_escape compares against the entry snapshot, accumulating severity on each signal hit
  → signals (only those with stable definitions are used): newly triggered honeypot / re-acquired mint authority (renounced_mint true→false) / sharp top10 concentration (+15%)
    ⚠️ Do NOT use burn_ratio: LP burns are irreversible, and token security uses a different definition than the trending row, so subtracting them inevitably mis-reports "liquidity withdrawal"
  → real price change: positions record entry_price, the monitor compares against the current price to compute pnl
  → severity ≥ escape_severity (70) → escape alert → user one-click sell
```

Gates align with the frontend funnel (gate index): `1=rug gate  2=consensus  3=ML ranking  4=LLM  → awaiting decision`.

---

## 5. Four denoising intervention points (design origin, landing gradually)

From the requirements discussion, distinguishing ML vs LLM responsibilities:

1. **Priority ranking and suppression** (the main denoiser, not LLM): → landed as `priority_score` (**trend momentum weighting**: 5m/1h momentum + buy/sell ratio + turnover + consensus downweight + safety; CFG-tunable weights; to be replaced by a lightweight ML ranker).
2. **Dedup and aggregation** (ML/rules): merge multiple events for the same coin. → not yet implemented (one coin per row).
3. **Explanation and contextualization** (the LLM's job): only translate the survivors into plain language + caveats. → landed as `LLMJudge` (**momentum-based golden-runner/bag-holder heuristic placeholder**, pending a real LLM).
4. **Personalization and threshold learning** (feedback loop): → not implemented; `trade_decisions.jsonl` is already the raw material (write-only for now).

---

## 6. GMGN CLI interfaces used (7 total)

Calls the globally installed `gmgn-cli` via `subprocess`, uniformly adding `--chain <chain> --raw`.

> ⚠️ The tested environment is **gmgn-cli 1.3.9**, whose interface differs from the early 1.0.x; the code is aligned to 1.3.9:
> - `market trending` parameters are `--order-by` (not `--orderby`), `--direction`, and it returns `{"code":0,"data":{"rank":[...]}}` (not `{"tokens":[]}`).
> - **The trending row already contains nearly all due-diligence fields** (`top_10_holder_rate`/`bundler_rate`/`dev_team_hold_rate`/`is_honeypot`/`renounced_mint`/`smart_degen_count`/`renowned_count`/`creation_timestamp`/`price_change_percent1h`…), so features are now **built directly from row fields** (`FeatureExtractor.build_from_row`) — no longer calling info/security/holders per candidate, eliminating the vast majority of requests (including `portfolio stats`).
> - The real API has **no** `security_score` (0-100 safety score), no `change_since_smart_money`, and no smart-money `acc/dist` status field. The rug gate now judges directly off real boolean/numeric fields (honeypot/renounced_mint/buy_tax/sell_tax/rug_ratio/bundler/dev_hold/top10); consensus uses the `smart_degen_count + renowned_count` count; crowdedness is approximated with `price_change_percent1h`.
> - `token security` is **normalized** inside `LiveGMGN` into the safety snapshot the escape monitor needs: `{honeypot, renounced_mint, renounced_freeze, burn_ratio, top10}`; `MockGMGN` outputs the same shape.

Full trending command example:

| Command | Stage | Purpose | Actual call frequency |
|---|---|---|---|
| `market trending` | scan | pull trending candidates (row already contains all due-diligence fields) | **1× per round (the only steady-state cli)** |
| `token info` | due diligence/price/dev eval | `do_buy` entry price; current price for off-board positions (token_price); **dev eval reads the row's `dev` object (dev_info)** | buy / off-board positions + top dev_pool_n survivors per cycle (600s cached) |
| `token security` | escape | normalized safety snapshot; for a position **still on board, reuse the trending row**, only query separately when off board | only off-board positions |
| `token holders` | — | essentially unused (features come from the trending row) | almost never called |
| `portfolio stats` | — | **deprecated** (consensus uses trending's degen/renowned count, no longer per-wallet win-rate lookups) | never called |
| `portfolio info` | execution (LIVE) | get the bound key's wallet address on this chain (swap's `--from`, auto-resolved + cached) | only on first LIVE buy/sell |
| `swap` | execution (LIVE) | market order — **unlocked**: buy `--input-token`=this chain's native token, `--amount`=smallest unit; sell `--input-token`=held coin, `--percent 100` to clear all | on LIVE buy/sell |
| `order get` | execution (LIVE) | poll order status (get status/hash) | after a LIVE buy |

Trending commands **have per-chain defaults** (`DEFAULT_TRENDING_CMDS`): sol defaults to the pump platform; bsc defaults to the fourmeme family of platforms (fourmeme/fourmeme_agent/bn_fourmeme/cubepeg/likwid/goplus_creator/goplus_skills/openfour/flap/flap_stocks); base/eth use the generic template (no `--platform`). `--platform` differs by chain (the pump family is sol-only, the fourmeme family is bsc-only). sol example:
```
gmgn-cli market trending --chain sol --platform Pump.fun --platform pump_mayhem --platform pump_mayhem_agent --platform pump_agent --interval 1h --order-by volume --limit 100 --raw
```
Editable per chain in the frontend gear (stored as `ST.trending_cmds[chain]`). `--interval 1h` is the trending **statistics window**, not the scan frequency; scan frequency is decided by the frontend polling (default 5.6s, editable in the gear; `_run_cmd` auto-appends `--raw`, and the command must start with `gmgn-cli market trending`).

---

## 7. Tech stack and directory structure

- Backend: Python 3.10+, FastAPI + Uvicorn (only these two dependencies, plus pure standard library).
- Frontend: single-file HTML + vanilla JS (no framework), served same-origin by the backend (avoiding CORS). Fonts: Bricolage Grotesque + IBM Plex Mono.
- Data sources: `gmgn-cli` (LIVE) / the built-in `MockGMGN` (default, works without a key for integration testing).

```
aitrader/
├── app.py                 # FastAPI backend + full screening pipeline (self-contained)
├── requirements.txt       # fastapi, uvicorn
├── static/
│   └── index.html         # frontend dashboard (source file — edit this for local dev)
├── docs/
│   └── index.html         # = copy of static/index.html, GitHub Pages publishes /docs
├── outputs/
│   ├── trade_decisions.jsonl   # generated at runtime: SCREEN/FILTER/BUY/SELL/UNMONITOR log (append-only)
│   ├── positions.json          # generated at runtime: position state persisted (overwrite-write, loaded on startup, survives reload/restart)
│   └── trending_cmds.json      # generated at runtime: per-chain trending command overrides (persisted once the user edits, survives restart/refresh, never reverts to default; only reset deletes back to default)
├── scripts/git-hooks/pre-commit  # auto cp static/index.html → docs/index.html (ships with repo; needs `git config core.hooksPath scripts/git-hooks` to enable once)
├── README.md
└── SPEC.md                # this file
```
Credentials are not in the project; they are written to the local machine at runtime at `~/.config/gmgn/.env` (containing `GMGN_API_KEY` / `GMGN_PRIVATE_KEY` / `GMGN_CHAIN`, chmod 600).

**GitHub Pages demo**: `static/index.html` is adaptive — when not on localhost (e.g. github.io) and the backend is unreachable it **automatically enters DEMO mode** showing sample data, displays a demo banner at the top, sends no fetches, and cannot place orders (purely static, zero API, zero key, zero order-funneling suspicion). With a local backend it connects to real data as usual. Deploy: Settings → Pages → `main` branch `/docs`. After editing the frontend, the pre-commit hook auto-syncs docs/ (the hook lives in `scripts/git-hooks/`; after cloning you must `git config core.hooksPath scripts/git-hooks` to enable it once, otherwise it silently won't sync).

> The frontend `API` uses **same-origin** (only falls back to `127.0.0.1:8000` when `location.protocol==='file:'`): local/tunnel access goes back to the backend hosting it; under purely static hosting (GitHub Pages) the same-origin `/api/status` 404s → it enters DEMO as usual. This is the prerequisite for a public demo to show real data (hardcoding `127.0.0.1` would make tunnel visitors hit their own machine's localhost → fail → DEMO fake data).

**Public read-only demo (`PUBLIC_DEMO=1`, real data · can be exposed to the public internet)**: used to show the dashboard to arbitrary visitors with **real** screening (distinct from GitHub Pages' DEMO fake data). When enabled the backend collapses to read-only, safely satisfying "public internet + real data":
- A background daemon thread runs `screen_once` on a timer per `DEFAULT_POLL_S` and caches the result — a visitor's `POST /api/run` **only returns the cache, never triggering gmgn-cli on behalf of the visitor**, so GMGN quota is decoupled from visitor count and can't be hammered (the cost: as long as the instance is up it keeps burning quota regardless of visitors).
- All write endpoints (`/api/config`·`/api/chain`·`/api/settings POST`·`/api/buy`·`/api/sell`·`/api/unmonitor`) all **403**; `/api/status` additionally returns `public_demo:true`; positions are **not exposed** (both public `/api/run` and `/api/positions` strip out positions/portfolio).
- When the frontend sees `public_demo:true` → `body.publicro` read-only state: it hides buy / config gear / source toggle / buy amount / chain switch / the entire position-monitor card, shows a blue "live real data · read-only demo" banner, and the chain follows the backend.
- It **still binds only `127.0.0.1`**: for public exposure use an outer tunnel with rate-limiting / DDoS protection (`cloudflared tunnel --url http://127.0.0.1:8000`). The key never leaves the local machine.

---

## 8. Backend API contract

The backend binds only `127.0.0.1:8000`. All endpoints are already wired to the frontend.

### `GET /api/status` (probed on frontend load, avoids re-entering the key)
```json
returns: { "live_adapter":bool, "chain":"sol", "mode":"SHADOW",
           "has_key":bool, "trading_locked":true, "public_demo":bool, "trending_cmd":"..." }
```
On startup the backend reads the key from `~/.config/gmgn/.env` and automatically switches to `LiveGMGN`; based on `has_key` the frontend auto-connects to real data without manual entry. If unreachable (e.g. GitHub Pages) → the frontend falls back to DEMO.

> **Chain is a per-request dimension (important architecture)**: the backend no longer has a "global current chain". `/api/run`·`/api/buy`·`/api/settings` all carry `chain`, and the backend handles per chain; the adapter is cached per chain (`ST.adapter_for(chain)`, same key, only `--chain` differs) + a short per-chain trending cache (`TRENDING_CACHE_TTL=3s`, multiple tabs on the same chain share one cli call). `mode`/`risk`/`positions` are still global (wallet-level, unified across chains). The frontend **stores each tab's own chain in `sessionStorage`** (mutually non-interfering), with `localStorage` only seeding the "default chain for a new tab". `/api/sell`·`/api/unmonitor` carry no chain: the sell chain is determined by the position's own `chain`. `GMGN_CHAIN` env degenerates to a pure startup default.

### `POST /api/config`
Writes `.env` (api_key may be left empty = keep the existing environment value, no empty-value overwrite) and switches adapter/mode. **Does not write the UI's chain choice**: when writing env it preserves the existing `GMGN_CHAIN` (startup default), not overwritten by the UI chain snapshot.
```json
request: { "api_key":"(may be empty)", "signing_key":"", "chain":"sol", "mode":"SHADOW|LIVE" }
returns: { "ok":true, "mode":"SHADOW", "live_adapter":bool, "trading_locked":bool }
```

### `POST /api/mode` (LIVE/SHADOW toggle · top-right MODE icon)
```json
request: { "mode":"LIVE|SHADOW" }
returns: { "ok":true, "mode":"SHADOW", "trading_locked":bool }
```
Only changes in-memory `ST.mode`, does not write env; LIVE only takes effect when `LIVE_TRADING_DISABLED=False`. The frontend calls it when the MODE icon is clicked; → LIVE gets a frontend second confirmation.

### `POST /api/chain` (kept for compatibility, does not change state)
```json
request: { "chain":"sol|bsc|base|eth" }
returns: { "ok":true, "chain":"bsc", "trending_cmd":"...this chain's command..." }
```
Only returns that chain's trending command; **no longer changes any global state** (chain is now passed with each request). The frontend no longer calls it when switching chains.

### `GET/POST /api/settings` + `POST /api/settings/reset` (trending command / per-chain memory · persistent)
GET `?chain=<chain>` returns that chain's `trending_cmd` + `default_trending_cmd` + `poll_interval_s`.
POST `{trending_cmd, chain}` saves to the specified chain (`ST.trending_cmds[chain]`, **persisted to `trending_cmds.json`**, invalidating that chain's cache); **safety guardrail**: the command must start with `gmgn-cli market trending`, otherwise 400.
POST `/api/settings/reset {chain}` **resets that chain to default** (deletes the persisted override + invalidates the cache), returning the restored `trending_cmd`.
> Persistence semantics: a command the user edited **does not revert to default on backend restart / page refresh**; only clicking the "↺ Reset" button at the top-right of the gear dialog deletes it back to default (top toast "Filters restored to default / 筛选条件已恢复默认").

### `POST /api/run`
Request `{chain}`; runs one screening round for that chain + position monitoring for that chain.
```json
returns: {
  "decisions": [
    { "decision": { "symbol","address","action":"ACTION|SKIP","reason","size_sol",
                    "risk_warn":bool,"priority":int,"gate":int,
                    "verdict": {"verdict","conviction","crowdedness","thesis"},
                    "features": {"honeypot","renounced","renounced_mint","buy_tax","sell_tax",
                                 "bundler","dev_hold","top10","smart_degen","renowned","sm_confluence",
                                 "sniper_count","chg_1h","chg_5m","buy_ratio","turnover","liquidity","mcap","age_min"} },
      "exec": { "hard_sl","tp_ladder":[...],"trailing" } | null }
  ],
  "portfolio": { ...(as before)... },
  "positions": [ { "symbol","address","size_sol","pnl","entry_price","cur_price","severity",
                   "signals":[{"t":"...","hot":bool}] } ],
  "mode": "SHADOW|LIVE"
}
```
`action="ACTION"` = passed all gates, awaiting decision; `risk_warn=true` = buying would trip risk control (frontend button turns amber, warns but does not block).
> **Returns `mode`**: `ST.mode` is global state and **reverts to SHADOW on backend restart (safe default, LIVE not persisted)**. The frontend syncs the LIVE/SHADOW switch from this each round; if the switch is auto-flipped from LIVE back to SHADOW, it shows a warning — preventing a "thought it was LIVE, actually SHADOW just logging" mistaken buy.

### `POST /api/buy`
Before trading it **passes one more hard risk-control check** (hard block 409). LIVE + private key → real order (adapter/native token/precision/wallet by `chain`), **polls the order to a terminal state**: `failed/expired` → 502 and **records no position**; `confirmed/processed/successful` → `filled:true`; still `pending` → `filled:false` (records the position but marks "awaiting confirmation", does not lie about the fill). SHADOW only records + writes positions.json.
```json
request: { "address":"...", "size_sol":0.01, "chain":"sol" }
returns: { "ok":true, "filled":bool, "status":"filled·<hash> | submitted·awaiting·<hash> | SHADOW(…)", "symbol":"..." }
```

### `POST /api/sell` / `POST /api/unmonitor`
`/api/sell` closes a position (counts toward risk control); `/api/unmonitor` **only removes from the escape monitor** (no sell, no risk-control count).
```json
request: { "address":"..." }   returns: { "ok":true, "symbol":"..." }
```

### `GET /api/positions`
Fetches the position monitor separately (the frontend mainly uses the positions inside `/api/run`).

---

## 9. Frontend dashboard

Layout: demo banner (DEMO only) → top status bar → 7 KPIs → main area left (screening result table + live log) right (position escape monitor + gate funnel + risk-control mini bar). The whole thing is already **compacted** for laptop screens (row/heading padding tightened).

Screening result table columns: TOKEN (clickable to copy the ticker + radar icon = already holding this coin) / rule→rank→LLM (gate icons) / safety (honeypot · authority-renounce badge) / BUND / DEV / T10 / smart money/KOL (degen/kol) / timing (early · sideways · overheated · bleeding) / LLM (pass/watch/reject) / priority / decision.
- **TOKEN column**: below the ticker it shows the CA (first 5…last 4, click opens the GMGN token page in a new window) + token age (d/h/m/s, green if <1h); clicking the ticker copies it to the clipboard.
- **Row click**: expands the interpretation details below, click again to collapse; not expanded by default (saves space).
- **"Holdings only" filter**: a siren-icon toggle next to TOKEN that shows only held coins.
- **Instant tooltip**: hovering the gate icon / LLM / decision-elimination label / timing / smart-money column immediately pops a self-drawn overlay (not a native title); delegated on document.
- **Buy amount**: a global input in the title bar, unit follows the chain (SOL/BNB/ETH), value stored in localStorage per chain; changing the value syncs all buy buttons below.
- **CHAIN dropdown** (top-right): SOL/BSC/Base/ETH switch. **The chain is independent per tab**: this tab stores it in `sessionStorage` (multiple tabs each view their own chain without interfering), `localStorage` only seeds a new tab's default chain. Switching chains only changes this tab + re-scans (chain passed with the request), without notifying the backend.
- **MODE icon** (top-right, formerly inside the config gear): click to toggle LIVE/SHADOW, calling `POST /api/mode` to change the backend's `ST.mode`. → LIVE pops a second confirmation (real money), → SHADOW switches directly; when hard-locked it won't let you switch to LIVE. Each `/api/run` returns mode, and the frontend's `syncBackendMode` keeps the icon consistent with the backend (a backend restart reverting to SHADOW auto-flips it back + warns).
- **Background tab pauses polling**: when `document.hidden`, `scanCycle` skips (no quota burn); when the tab becomes visible again it immediately runs a round (`visibilitychange`).

Key interactions:
- **One-click buy / sell / stop monitoring / switch to LIVE**: all use a **custom centered confirmation dialog** (`confirmDialog`, no browser-native confirm/alert anywhere anymore).
- **Position escape monitor**: each position shows current price · entry price + PnL% + a severity progress bar + signals + sell + × stop monitoring; severity ≥ 70 turns red and pulses; **if that coin is not all-green / fell off the board in the left-side screening → the card flashes a faint red once and stays** (escAlertSet, clears when it returns to all-green). The heading shows `N/limit positions`.
- **Data source**: DEMO (sample data self-runs) / local backend (polls `/api/run`); `scanCycle` is re-entrancy-guarded (avoids pileup), and discards the result if the user already switched away before the request returns.
- **Refresh**: the screening area shows a skeleton loading first, doesn't fake-write coins; if the backend is unreachable → auto DEMO.
- Security: keys are sent only to 127.0.0.1, never written to localStorage; only non-sensitive items like chain / buy amount go into localStorage.

---

## 10. Risk-control and security constraints (unbreakable)

- Portfolio-level hard risk control: max concurrent positions, total exposure cap, daily loss cap, consecutive-loss kill-switch. During screening it only warns (`risk_warn`); at trade time it hard-blocks.
- Position size = fixed-fraction method (risk amount / stop-loss distance), computed by code; the LLM never produces a number.
- Exit plan: hard stop-loss + TP ladder + trailing stop, strategy orders placed after the trade.
- The backend binds only `127.0.0.1`, and `0.0.0.0` or public exposure is **forbidden**. External access can only go through an outer tunnel (see §7 `PUBLIC_DEMO`: binding unchanged, forwarded by the tunnel; and in that mode the backend is purely read-only, all write endpoints 403, positions not leaked).
- Keys are written to the local `.env` (chmod 600), not into the project, not into browser storage; each user uses their own key (a GMGN key is bound to the IP whitelist at application time and cannot be shared).

Key parameters are centralized in `app.py`'s `CFG`. Relevant to this session:
- `top_n_prefilter=100`, `llm_max=20` (the heuristic placeholder costs nothing, so it's widened to reduce gate3 over-kills; tighten again once a real LLM is connected).
- Rug gate: `require_renounced_mint`, `max_buy_tax/max_sell_tax=0.10`, `max_rug_ratio=0.60`, `max_bundler_ratio=0.30`, `max_dev_holding_pct=0.10`, `max_top10_concentration=0.40`.
- Consensus: `min_smart_money_confluence=1` (= smart_degen + renowned).
- Ranking: `rank_weights={mom5m:30,mom1h:12,buy_pressure:18,turnover:12,consensus:12,safety:10,dev:12}`; bleeding-down sink `momentum_reject_chg1h=-0.12/chg5m=-0.06`; golden-runner/bag-holder `buy_ratio_pass=0.50/buy_ratio_reject=0.42`.
- Dev eval: `dev_pool_n=24` (after initial ranking, query dev history for the top N; >llm_max so dev can re-rank the gate3 boundary), `dev_info_ttl_s=600` (per-address dev-history cache seconds).
- Risk control: `max_concurrent_positions=20` (**relaxed for the feel-it-out phase**, should be set back to 2~3 before going live), `max_total_exposure_sol=1.0`, `daily_loss_cap_sol=0.5`, `kill_switch_consec_losses=3`.
- Safety guardrail: `LIVE_TRADING_DISABLED` (top of app.py). **Currently `False` (real trading unlocked)**: in LIVE mode + with `GMGN_PRIVATE_KEY` configured, "one-click buy/sell" places a **real order via the signing key, using real funds, irreversibly**. It's still human-in-the-loop (a trade happens only when you click the button), SHADOW is still the default safe state, and you must manually switch to LIVE for it to fire for real. Set it back to `True` to instantly seal off all on-chain writes.
  - **Real-order prerequisite**: `GMGN_PRIVATE_KEY` in `~/.config/gmgn/.env` must be non-empty (the signing key), otherwise `gmgn-cli swap/order` errors; the frontend shows "on-chain buy failed: …" with a clear reason and records no position.
  - **Multi-chain aligned** (gmgn-cli 1.3.9 authoritative Chain Currencies table): native token SOL=`So111…112` (9 decimals), BSC/Base/ETH=`0x0000…0000` (18 decimals); `--from` auto-resolved per chain via `portfolio info`. **EVM chains not yet tested with real money** (after the private key is configured, verify with small amounts chain by chain).

---

## 11. Current status

**Done (runnable)**
- `app.py`: a complete FastAPI backend, including the reordered pipeline, hard gates, scoring, the LLM placeholder, position escape monitoring, risk control, the four APIs, static hosting, and the Mock adapter. Defaults to Mock+SHADOW and runs without a key.
- `static/index.html`: a complete frontend dashboard, wired to all endpoints, demonstrable independently in DEMO mode.
- Scaffolding: requirements / README / directory structure.

**Done this session (real data · read-only market · faked buys · momentum strategy · multi-chain · demonstrable hosting)**
- gmgn-cli 1.3.9 adaptation + `build_from_row` (zero extra cli) + real-field criteria (see §6).
- **Ranking switched to the trend momentum model** + **LLMJudge golden-runner/bag-holder logic** (see §4): moonshots aren't cut wholesale, the buy ratio distinguishes follow vs cut.
- **New dev evaluation dimension** (see §4): the `dev` object from `token info` → `dev_score` (past golden runner adds / serial launching · deleted promo tweets · exited-this-token subtract) as a ranking sub-score folded into `priority_score`; two-pass ranking (initial sort → query dev history only for the top 24 → re-rank), results cached per-address for 600s to save quota; Mock synthesizes an isomorphic profile so it runs with no key.
- **Real position price change** (entry_price/cur_price/pnl) + **disk persistence** (positions.json, survives reload/restart) + **per-chain isolation** + **stop monitoring** (/api/unmonitor).
- **Escape-monitor false-positive fix**: removed the burn_ratio signal (irreversible + cross-source definition), keeping only honeypot/renounced_mint/top10.
- **Multi-chain switching** (SOL/BSC/Base/ETH): **chain made a per-request dimension** (no global current chain) — adapter cached per chain + short per-chain trending cache (3s, multiple tabs on the same chain share one cli call); the frontend keeps each tab's chain in sessionStorage, N tabs each view their own chain without interfering; background tabs pause polling to save quota. Per-chain command memory (ST.trending_cmds), buy unit/amount per chain.
- **Auto-connect to real data on startup** (env key → use_live → /api/status → frontend autoConnect), api_key may be left empty.
- **Per-chain default trending command + gear-configurable** (/api/settings; sol default = pump platform command).
- **Performance**: scanCycle re-entrancy guard + monitor reusing trending rows → `/api/run` 33s → ~1s.
- **Safety guardrail LIVE_TRADING_DISABLED** (see §10).
- **GitHub Pages demo**: static adaptive DEMO + demo banner + docs/ + pre-commit sync (see §7).
- Frontend: see §9 (clickable CA / age / instant tooltip / holdings-only / radar / faint-red linkage / custom confirmation dialog / skeleton loading / compaction, etc.).

**Placeholders / pending integration**
- `LLMJudge.judge`: momentum-heuristic placeholder → swap in a real Claude/GPT (feed `symbol_safe` + numbers, never the raw name; strict JSON parsing). Currently llm_max=20.
- `priority_score`: deterministic momentum weighting → can be swapped for a lightweight ML ranker (intervention point 1), training data = `trade_decisions.jsonl` after PnL backfill.
- Feedback flywheel (intervention point 4): `trade_decisions.jsonl` already appends SCREEN/FILTER/BUY/SELL/UNMONITOR, but is **write-only for now**; needs realized-PnL backfill → tune `CFG` thresholds.
- Adaptive thresholds: `CFG` is hardcoded, not auto-tightened/loosened by market temperature, no aggressive/conservative tiers.
- Dedup/aggregation (intervention point 2): not implemented.
- Escape "liquidity withdrawal" signal: removed the unreliable burn_ratio; **a true pool pull should be detected via `liquidity` dropping** (needs entry to record liquidity + same source, not done).
- Risk control/state: positions are persisted; but `RiskManager` (consecutive loss / daily loss / kill-switch) is still in memory, not persisted, and clears on reload.
- LIVE real orders: **landed** (unlocked + wallet auto-resolution + per-chain precision/native token + sell changed to `--percent 100`, see §10). Remaining: ① EVM chains not tested with real money (verify with small amounts chain by chain once the private key is configured); ② `order get` only polls once, no timeout-retry loop; ③ `max_concurrent_positions` is still the relaxed 20, should be set back to 2~3 before going live.

---

## 12. Key data structures (implementation reference)

- `TokenFeatures` (dataclass): built by `build_from_row` from the trending row. Includes `symbol_safe`; momentum `chg_1h/chg_5m/buys/sells/buy_ratio/turnover/liquidity`; safety `honeypot/renounced_mint/renounced_freeze/burn_ratio/buy_tax/sell_tax/rug_ratio`; float `bundler/dev_hold/top10`; consensus `smart_degen/renowned/sniper_count/sm_confluence(=degen+renowned)`; dev eval `dev` (normalized dev-history dict, `_dev_from_info`) + `dev_eval` (dev sub-score 0..1, None during initial ranking). (The old fields `sec_score/lp_burned/sm_verified/sm_distributing/chg_since_sm` have been removed.)
- `dev` (DevProfile dict): `open_count` (creator_open_count, lifetime tokens launched), `status`/`balance` (creator_token_status/balance), `exited` (already sold out of this token), `ath_mc` (peak market cap of dev's best prior token), `del_post_count` (deleted promo tweets), `create_count`, `cto`. Live reads it from the `dev` object in `token info`; Mock synthesizes an isomorphic one.
- `LLMVerdict`: `verdict(pass/watch/reject)`, `conviction(0..1)`, `crowdedness(early/crowded/late/fading/distributing)`, `red_flags`, `thesis`.
- position: `{symbol,address,chain,size_sol,pnl,cycles,entry_price,cur_price,entry{honeypot,renounced_mint,renounced_freeze,burn_ratio,top10}}`. `entry` is the entry safety snapshot (`assess_escape` diffs against it, but no longer uses the burn_ratio diff); persisted to `outputs/positions.json`.
- adapter-normalized `token_security` / `_sec_from_row`: `{honeypot,renounced_mint,renounced_freeze,burn_ratio,top10}`; Live, Mock, and the trending row must share the same definition (burn_ratio is the known inconsistency point, which is why escape doesn't use it).

---

## 13. Coding conventions

- Comments/copy mix Chinese and English, consistent with the existing code style.
- Pure standard library preferred; new dependencies require caution (currently only fastapi+uvicorn).
- Adapter pattern: all on-chain reads/writes go through the `GMGNAdapter` abstraction; `MockGMGN` and `LiveGMGN` are interchangeable, easing key-free integration testing and backtesting.
- Deterministic logic and LLM logic are strictly separated into file regions; changes must not let the LLM overreach into risk control / escape / position sizing.
