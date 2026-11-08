#!/bin/bash
set -eu
engine_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
python_exec="$engine_dir/.venv/bin/python"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if [[ ! -x "$python_exec" ]]; then
    printf '%s\n' '{"event":"error","phase":"本地分离引擎尚未安装。请先运行引擎目录中的安装脚本。","progress":0}'
    exit 1
fi
exec "$python_exec" "$engine_dir/run_engine.py" "$@"
