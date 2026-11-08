#!/usr/bin/env python3
"""Explicitly restore only pinned score weights; never upgrade the audio environment."""
import hashlib
import json
from pathlib import Path
import tempfile
import urllib.parse
import urllib.request

root = Path(__file__).resolve().parent
manifest = json.loads((root / "models.json").read_text())
weights = root / "weights"
if weights.is_symlink():
    raise SystemExit("请使用项目自身的 weights 目录。")
weights.mkdir(exist_ok=True)
for item in manifest["files"]:
    name = item["name"]
    if Path(name).name != name or not name.endswith(".sdict"):
        raise SystemExit("模型清单中的文件名无效。")
    output = weights / name
    if output.is_file() and hashlib.sha256(output.read_bytes()).hexdigest() == item["sha256"]:
        print("已就绪", name)
        continue
    url = "https://raw.githubusercontent.com/openmirlab/lv-chordia/" + manifest["revision"] + "/weights/" + urllib.parse.quote(name)
    request = urllib.request.Request(url, headers={"User-Agent": "Xianwaiwu-model-restore"})
    with urllib.request.urlopen(request, timeout=90) as response:
        data = response.read(item["bytes"] + 1)
    if len(data) != item["bytes"] or hashlib.sha256(data).hexdigest() != item["sha256"]:
        raise SystemExit("模型校验未通过，原有文件保留：" + name)
    with tempfile.NamedTemporaryFile(dir=weights, prefix=".restore-", delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(data); stream.flush(); temporary.replace(output)
        finally:
            temporary.unlink(missing_ok=True)
    print("已恢复", name)
