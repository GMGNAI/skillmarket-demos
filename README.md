<div align="center">

English | [简体中文](README.zh.md)

</div>

# skillmarket-demos

Community-contributed demos built with the GMGN OpenAPI, provided for reference and learning only. Security is not guaranteed. Use any trading functions at your own risk.

## Layout

Each demo lives in its own subdirectory; the GitHub Pages live demo for each is under the top-level `docs/<demo>/`.

```
skillmarket-demos/
├── aitrader/              # GMGN AI Trader: machine screens, you trade (FastAPI + single-page frontend)
│   ├── app.py  static/  README.md  SPEC.md ...
├── docs/                  # GitHub Pages publish root (one subfolder per demo)
│   └── aitrader/
│       └── index.html     # = aitrader/static/index.html copy (auto-synced by the hook)
├── scripts/git-hooks/
│   └── pre-commit         # on commit, auto-syncs each demo's static → docs/<demo>/
├── README.md              # this file (English)
└── README.zh.md           # 简体中文
```

## Demos

| Demo | Description | Live |
|---|---|---|
| [aitrader](aitrader/) | Local memecoin screening + one-click trading dashboard built on GMGN Skills/MCP: deterministic rules cast wide → scoring cuts hard → LLM only explains survivors → you press to trade. See [aitrader/README.md](aitrader/README.md). | https://gmgnai.github.io/skillmarket-demos/aitrader/ |

## Adding a demo

1. Create a `<demo>/` subdirectory; put the frontend source at `<demo>/static/index.html`.
2. Just commit — the pre-commit hook auto-syncs it to `docs/<demo>/index.html` and stages it in the same commit.
3. Add a row to the Demos table above; the live URL looks like `https://gmgnai.github.io/skillmarket-demos/<demo>/`.

## Enable the auto-sync hook (one-time per clone)

The hook script ships with the repo, but `git config` is local and does not travel with a clone, so enable it once after cloning — otherwise editing `static/` without updating `docs/` will silently leave the Pages demo on an old version:

```bash
git config core.hooksPath scripts/git-hooks
```

## GitHub Pages

Settings → Pages → select branch `main`, folder `/docs`. Each demo is reachable via its subpath (see the table above).
When a non-localhost visitor opens a demo page, the frontend can't reach a backend and automatically enters read-only DEMO mode (sample data, no trading).
