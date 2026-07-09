#!/usr/bin/env bash
set -e

REPO="https://github.com/GMGNAI/skillmarket-demos.git"
DEST="$HOME/gmgn-demos/aitrader"

echo ""
echo "==> GMGN AI Trader 一键部署"
echo ""

# 检查 Python 版本
if ! command -v python3 &>/dev/null; then
  echo "错误：未找到 python3，请先安装 Python 3.10+"
  echo "  macOS: brew install python"
  echo "  Linux: sudo apt install python3 python3-pip"
  exit 1
fi

PY_VER=$(python3 -c 'import sys; print(sys.version_info.minor)')
PY_MAJOR=$(python3 -c 'import sys; print(sys.version_info.major)')
if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_VER" -lt 10 ]; }; then
  echo "错误：需要 Python 3.10+，当前版本 $(python3 --version)"
  exit 1
fi

# 检查 git
if ! command -v git &>/dev/null; then
  echo "错误：未找到 git，请先安装 git"
  exit 1
fi

# clone 或更新
if [ -d "$DEST/.git" ]; then
  echo "==> 已存在，更新代码..."
  git -C "$DEST/../.." pull --rebase 2>/dev/null || true
else
  echo "==> 克隆仓库到 $DEST ..."
  mkdir -p "$HOME/gmgn-demos"
  git clone --depth=1 "$REPO" "$HOME/gmgn-demos/skillmarket-demos"
  # 如果目标路径不是 aitrader 子目录就软链
  if [ ! -d "$DEST" ]; then
    ln -s "$HOME/gmgn-demos/skillmarket-demos/aitrader" "$DEST"
  fi
fi

cd "$DEST"

# 安装依赖
echo "==> 安装依赖..."
python3 -m pip install -q -r requirements.txt

# 启动
echo ""
echo "==> 启动 AI Trader..."
echo "    访问地址：http://127.0.0.1:8000"
echo "    Ctrl+C 停止"
echo ""

# 延迟打开浏览器（等后端起来）
(sleep 2 && python3 -c "
import webbrowser, urllib.request, time
for _ in range(10):
    try:
        urllib.request.urlopen('http://127.0.0.1:8000/api/status', timeout=1)
        webbrowser.open('http://127.0.0.1:8000')
        break
    except:
        time.sleep(0.5)
" &)

python3 app.py
