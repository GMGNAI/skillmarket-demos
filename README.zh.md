<div align="center">

[English](README.md) | 简体中文

</div>

# skillmarket-demos

基于 GMGN OpenAPI 制作的演示 Demo，由社群成员贡献，仅供学习交流参考，安全性不作保证。如使用其中的交易功能，请自行评估代码安全性并承担相应交易风险。

## 目录结构

每个 demo 一个子目录；GitHub Pages 在线演示放在顶层 `docs/<demo>/`。

```
skillmarket-demos/
├── aitrader/              # GMGN AI Trader：看板筛、人成交（FastAPI + 单页前端）
│   ├── app.py  static/  README.md  SPEC.md ...
├── docs/                  # GitHub Pages 发布根（按 demo 分子目录）
│   └── aitrader/
│       └── index.html     # = aitrader/static/index.html 副本（钩子自动同步）
├── scripts/git-hooks/
│   └── pre-commit         # 提交前自动同步各 demo 的 static → docs/<demo>/
├── README.md              # 英文
└── README.zh.md           # 本文件（简体中文）
```

## Demos

| Demo | 说明 | 在线演示 |
|---|---|---|
| [aitrader](aitrader/) | 基于 GMGN Skills/MCP 的本地 memecoin 筛选 + 一键成交看板：确定性规则抓全 → 评分砍狠 → LLM 只解释幸存者 → 你按下成交。详见 [aitrader/README.md](aitrader/README.md)。 | https://gmgnai.github.io/skillmarket-demos/aitrader/ |

## 新增一个 demo

1. 新建子目录 `<demo>/`，前端源文件放在 `<demo>/static/index.html`。
2. 提交即可——pre-commit 钩子会自动把它同步到 `docs/<demo>/index.html` 并纳入本次提交。
3. 在上面的 Demos 表格里加一行；在线演示 URL 形如 `https://gmgnai.github.io/skillmarket-demos/<demo>/`。

## 启用自动同步钩子（每人 clone 后跑一次）

钩子脚本随仓库分发，但 `git config` 是本地配置、不随 clone 传递，所以 clone 后需启用一次，否则改了 `static/` 而 `docs/` 不更新、Pages 演示会静默停在旧版：

```bash
git config core.hooksPath scripts/git-hooks
```

## GitHub Pages 部署

Settings → Pages → 选 `main` 分支、目录 `/docs`。各 demo 通过子路径访问（见上表）。
非 localhost 访客打开演示页时，前端连不上后端会自动进只读 DEMO 模式（示例数据、不可下单）。
