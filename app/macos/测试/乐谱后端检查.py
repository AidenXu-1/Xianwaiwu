#!/usr/bin/env python3
"""Small executable contract checks; use the project's existing audio Python."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
JOB = ROOT / "app/audio/乐谱/score_job.py"
spec = importlib.util.spec_from_file_location("score_job", JOB)
job = importlib.util.module_from_spec(spec); spec.loader.exec_module(job)
checks = []
def check(value, label):
    assert value, label
    checks.append(label); print("PASS", len(checks), label, flush=True)

check(job.normalize("C:min/b7") == "Cm/Bb", "小和弦与降七级低音")
check(job.normalize("Eb:maj/3") == "Eb/G", "大和弦转位低音")
check(job.normalize("F:sus4(b7)") == "F7sus4", "挂留属七和弦")
check(job.normalize("Ab:min9") == "Abm9", "九和弦不简化丢失")
check(job.normalize("N") == "N.C.", "无和弦时间明确保留")
try: job.normalize("C:fake")
except ValueError: check(True, "未知类型明确拒绝")
else: raise AssertionError("unknown chord")

with tempfile.TemporaryDirectory(prefix="xw-score-contract-") as directory:
    folder = Path(directory)
    import numpy as np
    import soundfile as sf
    sample = folder / "silence.wav"
    sf.write(sample, np.zeros(44100, dtype="float32"), 22050)
    sha = hashlib.sha256(sample.read_bytes()).hexdigest()
    base = [sys.executable, str(JOB), "--input", str(sample), "--source-sha256", sha]
    def run(extra):
        result = subprocess.run(base + extra, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=60)
        events = []
        for line in result.stdout.splitlines():
            try: events.append(json.loads(line))
            except json.JSONDecodeError: pass
        return result, events
    result, events = run(["--start", "10", "--end", "2"])
    check(result.returncode != 0 and events[-1]["type"] == "error", "倒序选段在推理前拒绝")
    result, events = run(["--start", "nan", "--end", "2"])
    check(result.returncode != 0 and events[-1]["type"] == "error", "非有限时间拒绝")
    result, events = run(["--start", "0", "--end", "1801"])
    check(result.returncode != 0 and events[-1]["type"] == "error", "超出单次范围明确拒绝")
    result, events = run(["--start", "0", "--end", "2"])
    check(result.returncode == 0 and events[-1]["type"] == "done", "真实静音输入能够完整返回")
    regions = events[-1]["result"]["segments"]
    check(regions[0]["start"] == 0 and regions[-1]["end"] == 2 and all(r["label"] == "N.C." for r in regions),
          "静音没有伪造和弦且范围完整")
    result, events = run(["--start", "0", "--end", "0.2"])
    check(result.returncode == 0 and events[-1]["type"] == "done", "最短可选范围有明确结果")
print("Completed", len(checks), "backend checks")
