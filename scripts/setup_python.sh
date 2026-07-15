#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${ASTOCK_PYTHON:-python3}"
DATA_DIR="${ASTOCK_DATA_DIR:-$HOME/.clacky/ext/data/astock-research}"
VENV="$DATA_DIR/venv"

"$PYTHON" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else "需要 Python 3.9+（推荐 3.10+）")'
mkdir -p "$DATA_DIR"
"$PYTHON" -m venv "$VENV"
"$VENV/bin/python" -m pip install --upgrade pip
"$VENV/bin/python" -m pip install -r "$ROOT/runtime/requirements.txt"
"$VENV/bin/python" "$ROOT/runtime/astock_data.py" check
echo "A股数据环境已就绪：$VENV"
