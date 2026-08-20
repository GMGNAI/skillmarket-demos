<div align="center">

English | [简体中文](README.md)

</div>

# MemeX Agent · BSC due diligence

Drop a contract address into the box, six deterministic rule-based skills run, and you get
a 0-100 composite score where **every point deducted comes with its reason**. No LLM does
the scoring.

Live demo: https://gmgnai.github.io/skillmarket-demos/memex/

---

## What this demo is

A **single-file, front-end-only** on-chain due-diligence panel. No backend, no build step,
no third-party libraries — `static/index.html` is the whole thing, calling the official
GMGN OpenAPI directly with your own API key.

All six skills are deterministic rules in `skills.js`:

| Skill | Weight | What it looks at |
|---|---|---|
| Contract audit | 34% | honeypot / taxes / open source / renounced / LP / pool depth / top-10 concentration / dev profile — 19 checks |
| Smart money | 22% | smart money · renowned · blue chip vs bots · bundlers · snipers · fresh wallets; top-100 P&L and net flow |
| Early buyers | 19% | the **current** state of the first 70 buyers: exited / added / transferred out / still holding |
| Price action | 15% | EMA crosses · regression slope · ATR volatility · volume divergence · range drawdown |
| X narrative | 10% | project timeline + source tweet + a KOL list scanned for CA mentions |
| Binance Alpha catalyst | capped adjustment | whether it listed on Alpha, how long ago, whether it is still listed |

The Alpha catalyst is **not part of the weighted average** — most tokens never list on
Alpha, so averaging it in would only dilute the skills that actually discriminate. It is
applied as a capped bonus/penalty after the weighting.

---

## Using it

1. Open the live demo, or download `static/index.html` and **just open it** — one file, no dependencies
2. Get an API key from the [GMGN API management page](https://gmgn.ai/ai?chain=bsc&tab=api_management)
3. In the panel: Settings → Data sources → paste it in
4. Drop in a contract address, a wallet address, a `$SYMBOL`, or an X handle

The key stays in your own browser's `localStorage`. This page has **no backend**, so
there is nowhere for it to send the key except `openapi.gmgn.ai`.

### API key only — never the private key

Upstream splits endpoints in two: `authExist` needs only `X-APIKEY` (queries), while
`authSigned` also needs `X-Signature` (an Ed25519 private-key signature, for trading).
**This demo implements only the former** — there is not a single line of signing logic in
the code and no private-key input in the UI.

A private key is a trade-signing credential: whoever holds it can place and cancel orders
on your behalf. An analysis tool needs no write operations, so the *ability* to sign
should not exist at all. **Even if your API key leaks, the worst anyone can do is burn
your read quota — they cannot touch your funds.**

---

## What browser-direct mode can and cannot do

This needs stating plainly, or you will think something is broken.

`openapi.gmgn.ai` returns `Access-Control-Allow-Origin: *` and permits the `X-APIKEY`
header, so a browser can call the official OpenAPI directly. The public `gmgn.ai`
endpoint, however, sends **no CORS headers** — a browser simply cannot reach it, not even
from localhost.

So some data is unavailable in front-end-only mode:

| Data | Status | Why |
|---|---|---|
| Token info / security / holders / candles / trending | ✅ official API | |
| Wallet profile (win rate, holding period, P&L distribution) | ✅ official API | the main reason to supply a key — the public endpoint returns 0 for all of these |
| Risk stats (rat traders / bundlers / snipers / fresh-wallet ratio) | ❌ unavailable | no official equivalent |
| Early buyers | ❌ unavailable | upstream has `token_top_traders`, but that means "top traders" — we need the state machine of the *earliest* buyers. Different semantics, not a drop-in replacement |
| Trade feed | ❌ unavailable | no official equivalent |
| X narrative / Web2 sources | ❌ unavailable | those sites send no CORS headers either |

**Missing data is never counted as good news.** This is deliberate: `f(undefined)` yields
0, and left alone, "dev holdings 0%" and "sniper share 0%" would read as "dev has fully
exited" and "snipers cleared out", making a token nobody checked look clean — far more
dangerous than reporting it as missing. So absent fields go into `unknown` and are stated
on the card; when the honeypot check is missing the score is capped at 59 and the verdict
reads "key checks unavailable — not enough to judge safety".

For all six skills use the
[Chrome extension or the local server](https://github.com/Edwardchennnn/MemeX-Agent) —
those fetch with privileges or server-side and are not bound by the browser's same-origin
policy.

---

## No AI is called by default

The six skills contain no LLM request at all, which is what makes them free to run and
reproducible — the same data always yields the same score. Hooks for an AI layer exist
(intent parsing / narrative writing / follow-ups) under one hard rule: **AI never scores.**
Turning AI on or off never changes the score for a given contract.

Note that "calls no AI" is not the same as "works offline" — scoring needs no network, but
on-chain data is fetched live.

---

## How the single file is produced

The upstream repo is multi-file (ES modules + classic scripts + external stylesheet and
fonts). This repo's pre-commit hook syncs only `<demo>/static/index.html` to the Pages
directory; sibling files under `static/` are not synced, so any external reference would
404 in production — it has to be a genuinely single file.

Two scripts handle that (in the upstream `tools/`):

- `bundle_demo.py` bundles the 15 ES modules into one classic script. It **covers only the
  import/export forms this project actually uses** and exits with an error on anything
  unrecognised rather than quietly emitting a broken bundle
- `build_demo_page.py` inlines the stylesheet / dictionary / chart code / modules / primary
  font, and self-checks that no absolute-path reference remains

The bundle was compared against the real ES modules: **export names 15/15 identical,
function bodies byte-identical 153/153**.

---

## Not investment advice

The output is due-diligence facts and risk signals, not buy or sell instructions.
**A high score does not mean safe; a low score does not mean it will fall.** Upstream data
comes from GMGN, and if that data is manipulated the conclusions follow it — the tool
labels which route each field came from, but cannot verify upstream honesty.

Full source, Chrome extension and local-server versions:
https://github.com/Edwardchennnn/MemeX-Agent
