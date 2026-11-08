#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v uv >/dev/null || ! command -v ffmpeg >/dev/null; then
    printf '%s\n' '请先安装 uv 和 FFmpeg，然后重新打开本脚本。'
    exit 1
fi
if [[ ! -x .venv/bin/python ]]; then
    uv --cache-dir .下载缓存 venv --python 3.11 .venv
fi
uv --cache-dir .下载缓存 pip install --python .venv/bin/python -r requirements-engine.txt
.venv/bin/python install_models.py "$@"
printf '%s\n' '本地模型准备好。后续分离可以断网运行。'
