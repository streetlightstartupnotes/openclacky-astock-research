#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${CLACKY_EXT_LOCAL:-$HOME/.clacky/ext/local}/astock-research"

mkdir -p "$(dirname "$TARGET")"
rm -rf "$TARGET"
cp -R "$ROOT" "$TARGET"
# A development checkout may itself be a Git repository. The local extension
# layer only needs runtime files; keeping .git would bloat marketplace packs
# and expose repository metadata in every installation archive.
rm -rf "$TARGET/.git"
"$TARGET/scripts/setup_python.sh"
openclacky ext verify
echo "已安装到：$TARGET"
