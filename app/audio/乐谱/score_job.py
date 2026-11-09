#!/usr/bin/env python3
"""Local, bounded chord inference using pinned LV-Chordia weights and existing audio tools."""
import argparse
import contextlib
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent
WEIGHTS = Path(os.environ.get("XIANWAIWU_SCORE_WEIGHTS", ROOT / "weights"))
sys.path.insert(0, str(ROOT / "vendor"))
os.environ.setdefault("NUMBA_CACHE_DIR", str(Path(tempfile.gettempdir()) / "xianwaiwu-score-numba"))
STARTED = time.monotonic()
child = None

class AccelerationFailure(Exception):
    pass

def event(kind, **values):
    print(json.dumps({"type": kind, **values}, ensure_ascii=False, allow_nan=False), flush=True)

def cancelled(_signal, _frame):
    raise KeyboardInterrupt

def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for part in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(part)
    return h.hexdigest()

NAMES = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
def normalize(label):
    if label in ("N", "X"):
        return "N.C."
    match = re.fullmatch(r"([A-G](?:#|b)?)(?::([^/]+))?(?:/(.+))?", label)
    if not match:
        raise ValueError("识别返回了无法读取的和弦。")
    root, quality, bass = match.groups()
    quality = quality or "maj"
    suffixes = {"maj": "", "min": "m", "min7": "m7", "min6": "m6", "maj6": "6",
                "hdim7": "m7b5", "sus4(b7)": "7sus4", "min9": "m9"}
    quality = suffixes.get(quality, quality)
    if quality not in ("", "m", "7", "maj7", "m7", "dim", "dim7", "m7b5", "aug",
                       "sus2", "sus4", "7sus4", "6", "m6", "add9", "madd9", "9", "m9",
                       "maj9", "11", "m11", "maj11", "13", "maj13", "mmaj7"):
        raise ValueError("识别返回了暂不支持的和弦类型。")
    value = {"C":0,"D":2,"E":4,"F":5,"G":7,"A":9,"B":11}[root[0]]
    value = (value + (1 if root.endswith("#") else -1 if root.endswith("b") else 0)) % 12
    symbol = NAMES[value] + quality
    if bass:
        degrees = {"1":0,"2":2,"b3":3,"3":4,"4":5,"b5":6,"5":7,"#5":8,"6":9,"b7":10,"7":11}
        if bass not in degrees:
            raise ValueError("识别返回了暂不支持的低音标记。")
        symbol += "/" + NAMES[(value + degrees[bass]) % 12]
    return symbol

def validate_args(args):
    if not (args.input.is_file() and re.fullmatch(r"[a-f0-9]{64}", args.source_sha256)):
        raise ValueError("原音频或歌曲指纹无效，请重新打开项目。")
    if not (math.isfinite(args.start) and math.isfinite(args.end) and args.start >= 0 and
            0.199999 <= args.end - args.start <= 1800):
        raise ValueError("请选择 0.2 秒至 30 分钟的练习范围。")

def recognize(args):
    global child
    if os.environ.get("XIANWAIWU_PACKAGED") == "1":
        sys.path.insert(0, str(ROOT.parent))
        from model_store import ensure_files
        import urllib.parse
        manifest = json.loads((ROOT / "models.json").read_text())
        records = [{**item, "filename": item["name"],
                    "url": "https://raw.githubusercontent.com/openmirlab/lv-chordia/" + manifest["revision"] + "/weights/" + urllib.parse.quote(item["name"])} for item in manifest["files"]]
        ensure_files(records, WEIGHTS, lambda done, total, name:
                     event("progress", message=f"首次准备乐谱模型 {done / 1e6:.1f}/{total / 1e6:.1f} MB", fraction=0.01 * done / total))
    import numpy as np
    import soundfile as sf
    import librosa
    import torch
    torch.set_num_threads(2)
    from lv_chordia.chord_recognition import load_ensemble
    from lv_chordia.mir import DataEntry, io
    from lv_chordia.extractors.cqt import CQTV2
    from lv_chordia.extractors.xhmm_ismir import XHMMDecoder

    manifest = json.loads((ROOT / "models.json").read_text())
    for item in manifest["files"]:
        weight = WEIGHTS / item["name"]
        if not weight.is_file() or weight.stat().st_size != item["bytes"] or digest(weight) != item["sha256"]:
            raise ValueError("乐谱模型缺失或校验未通过，请恢复本项目的乐谱模型后再试。")
    event("progress", message="核对原音频", fraction=0.02)
    if digest(args.input) != args.source_sha256:
        raise ValueError("原音频内容已经改变，已有乐谱已保留。请重新定位原音频或创建新项目。")
    with tempfile.TemporaryDirectory(prefix="audio-", dir=args.work_directory) as directory:
        audio = Path(directory) / "input.wav"
        command = [os.environ.get("SHISHENG_FFMPEG", "/opt/homebrew/bin/ffmpeg"),
                   "-v", "error", "-nostdin", "-y", "-ss", str(args.start), "-i", str(args.input),
                   "-t", str(args.end - args.start), "-ac", "1", "-ar", "22050", "-c:a", "pcm_f32le", str(audio)]
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            _, stderr = child.communicate(timeout=180)
            if child.returncode:
                raise ValueError("这段音频未能读取，请确认文件完整后重试。")
        finally:
            if child.poll() is None:
                child.terminate()
                try: child.wait(timeout=1)
                except subprocess.TimeoutExpired: child.kill(); child.wait()
            child = None
        y, sr = sf.read(audio, dtype="float32")
        requested = args.end - args.start
        if abs(len(y) / sr - requested) > 0.05:
            raise ValueError("没有读到完整选段，请确认原音频与项目记录一致。")
        if len(y) < 2048:
            raise ValueError("这段音乐太短，请至少选择 0.2 秒。")
        event("progress", message="整理音高信息", fraction=0.08)
        entry = DataEntry()
        entry.prop.set("sr", 22050); entry.prop.set("hop_length", 512)
        entry.append_file(str(audio), io.MusicIO, "music")
        entry.append_extractor(CQTV2, "cqt", cache_enabled=False)
        features = entry.cqt
        accelerated = args.device != "cpu" and torch.backends.mps.is_available() and requested <= 600
        collected = []
        if accelerated:
            event("progress", message="正在识别整段音乐", fraction=0.15)
            try:
                ensemble = load_ensemble(False, device=torch.device("mps"))
                for i, net in enumerate(ensemble):
                    collected.append(net.inference(features))
                    event("progress", message="识别和弦与切换位置", fraction=0.15 + 0.7 * (i + 1) / len(ensemble))
                torch.mps.synchronize()
            except RuntimeError as error:
                # The parent restarts a fresh CPU process once, reclaiming Metal allocations first.
                raise AccelerationFailure() from error
        else:
            event("progress", message="正在使用省内存方式识别", fraction=0.12)
            ensemble = load_ensemble(False)
            step = int(10 * 22050 / 512)
            context = int(4 * 22050 / 512)
            count = len(ensemble) * math.ceil(len(features) / step)
            completed = 0
            for net in ensemble:
                buffers = [[] for _ in range(6)]
                for a in range(0, len(features), step):
                    b = min(len(features), a + step)
                    lo = max(0, a - context); hi = min(len(features), b + context)
                    output = net.inference(features[lo:hi])
                    for i, values in enumerate(output):
                        buffers[i].append(values[a-lo:b-lo])
                    completed += 1
                    event("progress", message="识别和弦与切换位置", fraction=0.12 + 0.73 * completed / count)
                collected.append([np.concatenate(values) for values in buffers])
        probabilities = [np.mean([values[i] for values in collected], axis=0) for i in range(6)]
        decoder = XHMMDecoder(template_file=str(ROOT / "lv_chordia/data/submission_chord_list.txt"))
        regions = decoder.decode_to_chordlab(entry, probabilities, False)
        segments = []
        for a, b, label in regions:
            start = max(args.start, min(args.end, args.start + float(a)))
            end = max(start, min(args.end, args.start + float(b)))
            if end - start <= 0.000001: continue
            symbol = normalize(label)
            if segments and segments[-1]["label"] == symbol:
                segments[-1]["end"] = end
            else:
                segments.append({"start": start, "end": end, "label": symbol})
        if not segments:
            raise ValueError("这段音频没有得到可读取的和弦结果，可以换一段音乐再试。")
        segments[0]["start"] = args.start
        segments[-1]["end"] = args.end
        event("progress", message="整理节拍与谱面", fraction=0.9)
        # Estimate pulses for the timeline; do not invent bar lines or word timings.
        if len(y) >= 22050 and float(np.max(np.abs(y))) > 1e-5:
            _, frames = librosa.beat.beat_track(y=y, sr=sr, hop_length=512)
            beats = [args.start + float(t) for t in librosa.frames_to_time(frames, sr=sr, hop_length=512)
                     if args.start <= args.start + float(t) <= args.end]
        else: beats = []
    if digest(args.input) != args.source_sha256:
        raise ValueError("识别期间原音频内容发生了变化，已有乐谱已保留，请重试。")
    return {"sourceSHA256": args.source_sha256, "start": args.start, "end": args.end,
            "model": "LV-Chordia / " + ("MPS full 1" if accelerated else "CPU compact 1"), "elapsed": time.monotonic() - STARTED,
            "segments": segments, "beats": beats}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--work-directory", type=Path)
    parser.add_argument("--device", choices=["auto", "cpu"], default="auto")
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--start", type=float, required=True)
    parser.add_argument("--end", type=float, required=True)
    parser.add_argument("--source-sha256", required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, cancelled)
    try:
        validate_args(args)
        event("progress", message="准备本机识别", fraction=0)
        event("done", result=recognize(args))
    except AccelerationFailure:
        event("retry_cpu", message="本机加速暂不可用，改用省内存方式。"); return 75
    except KeyboardInterrupt:
        event("cancelled"); return 130
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        event("error", message=str(error)); return 1
    except Exception:
        import traceback
        traceback.print_exc(file=sys.stderr)
        event("error", message="本机乐谱识别未完成，已有乐谱已保留。请先选一小段重试。")
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
