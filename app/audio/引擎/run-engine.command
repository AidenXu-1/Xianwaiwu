#!/bin/bash
set -eu
engine_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
python_exec="${SHISHENG_PYTHON:-$engine_dir/.venv/bin/python}"
if [[ -n "${SHISHENG_TOOLS:-}" ]]; then
    export PATH="$SHISHENG_TOOLS:/usr/bin:/bin"
else
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
fi
if [[ ! -x "$python_exec" ]]; then
    printf '%s\n' '{"event":"error","phase":"本地分离引擎尚未安装。请先运行引擎目录中的安装脚本。","progress":0}'
    exit 1
fi
exec "$python_exec" "$engine_dir/run_engine.py" "$@"
