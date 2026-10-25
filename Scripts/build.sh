#!/bin/zsh
# ScreenToGif macOS — 编译（Release）
set -euo pipefail
cd "$(dirname "$0")/.."
exec arch -arm64 swift build -c release --product ScreenToGif "$@"
