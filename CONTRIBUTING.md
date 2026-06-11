<div align="center">

English | [简体中文](CONTRIBUTING.zh.md)

</div>

# Contributing

For maintainers and contributors of this repo.

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
├── README.md / README.zh.md
└── CONTRIBUTING.md / CONTRIBUTING.zh.md
```

## Adding a demo

1. Create a `<demo>/` subdirectory; put the frontend source at `<demo>/static/index.html`.
2. Just commit — the pre-commit hook auto-syncs it to `docs/<demo>/index.html` and stages it in the same commit.
3. Add a row to the Demos table in the README; the live URL looks like `https://gmgnai.github.io/skillmarket-demos/<demo>/`.

## Enable the auto-sync hook (one-time per clone)

The hook script ships with the repo, but `git config` is local and does not travel with a clone, so enable it once after cloning — otherwise editing `static/` without updating `docs/` will silently leave the Pages demo on an old version:

```bash
git config core.hooksPath scripts/git-hooks
```

## GitHub Pages

Settings → Pages → select branch `main`, folder `/docs`. Each demo is reachable via its subpath (e.g. `https://gmgnai.github.io/skillmarket-demos/aitrader/`).
When a non-localhost visitor opens a demo page, the frontend can't reach a backend and automatically enters read-only DEMO mode (sample data, no trading).
