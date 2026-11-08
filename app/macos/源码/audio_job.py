#!/usr/bin/env python3
"""Private local worker for the experimental desktop app."""
import argparse
import ctypes
from datetime import datetime, timezone
import errno
import hashlib
import json
import math
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(os.environ.get("SHISHENG_ROOT") or Path(__file__).resolve().parents[3])
RUNNER = ROOT / "app/audio" / "引擎" / "run-engine.command"
FFMPEG = os.environ.get("SHISHENG_FFMPEG") or shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
FFPROBE = os.environ.get("SHISHENG_FFPROBE") or str(Path(FFMPEG).with_name("ffprobe"))
CANCELLED = False
CHILD = None
_CANCEL_LOCK = threading.RLock()
TRACKS = {
    "vocals": "人声", "instrumental": "伴奏", "drums": "鼓", "bass": "贝斯",
    "guitar": "吉他", "piano": "钢琴", "other": "其他",
    "lead": "主唱", "harmony": "和声", "backing": "和声伴奏"
}
MODES = {
    "pair": ["vocals", "instrumental"], "vocals": ["vocals"], "instrumental": ["instrumental"],
    "music6": ["vocals", "drums", "bass", "guitar", "piano", "other"],
    "lead": ["lead"], "backing": ["backing"], "leadback": ["lead", "backing"],
    "lead3": ["lead", "harmony", "instrumental"]
}
FORMATS = {
    "wav16": ("wav", ["-c:a", "pcm_s16le"]),
    "wav24": ("wav", ["-c:a", "pcm_s24le"]),
    "flac": ("flac", ["-c:a", "flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "24"]),
    "mp3": ("mp3", ["-c:a", "libmp3lame", "-b:a", "320k"]),
}

def emit(event, **kwargs):
    print(json.dumps(dict(event=event, **kwargs), ensure_ascii=False), flush=True)

class JobError(ValueError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code

def signal_group(pid, sig):
    try:
        os.killpg(pid, sig)
    except ProcessLookupError:
        pass

def cancel_child(proc):
    # Both the signal handler and the post-spawn cancellation check can arrive
    # here. Arm one escalation for this exact child before sending its SIGTERM.
    with _CANCEL_LOCK:
        if getattr(proc, "_group_cancel_timer", None) is not None:
            return
        escalation = threading.Timer(1.0, signal_group, (proc.pid, signal.SIGKILL))
        escalation.daemon = False
        proc._group_cancel_timer = escalation
        escalation.start()
        signal_group(proc.pid, signal.SIGTERM)

def stop(_signum, _frame):
    global CANCELLED
    if CANCELLED:
        return
    CANCELLED = True
    proc = CHILD
    if proc is not None:
        cancel_child(proc)

def watch_parent(parent_pid, finished):
    while not finished.wait(0.25):
        if parent_pid <= 1 or os.getppid() != parent_pid:
            stop(None, None)
            return

def checked():
    if CANCELLED:
        raise InterruptedError("已取消")

def verify_source(path, expected):
    if expected is None:
        return
    if re.fullmatch(r"[0-9a-fA-F]{64}", expected) is None:
        raise JobError("invalid_source_checksum", "原音频的项目记录无效，请重新导入这首歌")
    emit("status", phase="核对原音频")
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            checked()
            digest.update(chunk)
    if digest.hexdigest() != expected.lower():
        raise JobError("source_changed", "原音频内容已变化，请重新定位原音频或作为新项目导入")

def execute(command, live=None):
    global CHILD
    checked()
    lines = []
    proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            encoding="utf-8", errors="replace", start_new_session=True)
    CHILD = proc
    try:
        if CANCELLED:
            cancel_child(proc)
        for line in proc.stdout:
            lines.append(line.strip())
            if live:
                live(line.strip())
        rc = proc.wait()
    finally:
        if proc.poll() is None:
            signal_group(proc.pid, signal.SIGKILL)
            proc.wait()
        CHILD = None
        proc.stdout.close()
    checked()
    if rc:
        tail = " ".join(lines[-4:])[-600:]
        for line in reversed(lines):
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if isinstance(event, dict) and event.get("event") == "error":
                raise JobError(event.get("code", "engine_failed"),
                               event.get("message") or event.get("phase") or "分离失败，请缩短选段后重试")
        if "No space left on device" in tail:
            raise OSError(errno.ENOSPC, "磁盘空间不足")
        if "Permission denied" in tail or "Operation not permitted" in tail:
            raise PermissionError("无法读取或保存文件，请检查文件及文件夹权限")
        if rc == -signal.SIGKILL:
            raise JobError("resource_limit", "音频任务被系统终止，请关闭其他程序或缩短处理范围后重试")
        raise RuntimeError(tail or f"音频程序退出（{rc}）")
    return "\n".join(lines)

def media(args, level="error"):
    return execute([FFMPEG, "-hide_banner", "-nostdin", "-v", level, "-n", *args])

def probe(path):
    try:
        return json.loads(execute([FFPROBE, "-v", "error", "-select_streams", "a:0",
                                  "-show_entries", "stream=sample_rate,channels,duration_ts,time_base:format=duration",
                                  "-of", "json", str(path)]))
    except RuntimeError as exc:
        raise JobError("invalid_audio", "无法读取这份音频，请确认文件完整并重新选择") from exc

def publish(source, destination):
    """Atomically move a completed file or directory without replacing any existing entry."""
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        rename = libc.renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        result = rename(os.fsencode(source), os.fsencode(destination), 4)  # RENAME_EXCL
    else:
        rename = libc.renameat2
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = rename(-100, os.fsencode(source), -100, os.fsencode(destination), 1)  # RENAME_NOREPLACE
    if result:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(destination))

def peak_db(paths):
    args = []
    for path in paths:
        args.extend(["-i", str(path)])
    if len(paths) == 1:
        args.extend(["-af", "astats=metadata=0:reset=0"])
    else:
        args.extend(["-filter_complex", f"amix=inputs={len(paths)}:normalize=0,astats=metadata=0:reset=0"])
    log = media([*args, "-f", "null", "-"], "info")
    peaks = re.findall(r"Peak level dB:\s*(-?inf|[+-]?\d+(?:\.\d+)?)", log)
    if not peaks:
        raise JobError("invalid_audio", "无法检查音频内容，请重新选择音频或重新分离")
    return max(float(value) for value in peaks)

def separate(a):
    if not (math.isfinite(a.start) and math.isfinite(a.end) and 0 <= a.start < a.end
            and a.end - a.start >= .20 - .000001):
        raise JobError("invalid_range", "请选中有效范围，至少 0.2 秒，起点不能晚于终点")
    source = a.source.resolve()
    if not source.is_file():
        raise JobError("source_missing", "原音频已移动或无法读取，请重新定位原音频")
    verify_source(source, a.source_sha256)
    info = probe(source)
    if not info.get("streams"):
        raise JobError("invalid_audio", "文件中没有可读取的音频，请选择其他文件")
    duration = float(info.get("format", {}).get("duration", "nan"))
    if not math.isfinite(duration) or a.end > duration + 1 / 44100:
        raise JobError("invalid_range", "处理范围超出原音频，请重新选择起止位置")
    output = a.dest.resolve()
    if os.path.lexists(output) or not output.parent.is_dir():
        raise JobError("destination_unavailable", "结果位置已存在或无法使用，请重新开始")
    if not RUNNER.is_file():
        raise JobError("missing_component", "项目中的分离引擎未找到，请检查项目引擎位置")
    start = time.monotonic()
    stage = Path(tempfile.mkdtemp(prefix=".分离-", dir=output.parent))
    engine = stage / "engine"
    used_device = None
    fallbacks = []
    engine_gain = 0.0
    backend = None
    engine_info = {}
    def relay(line):
        nonlocal used_device, engine_gain, backend
        try:
            msg = json.loads(line)
        except ValueError:
            return
        if not isinstance(msg, dict):
            return
        if msg.get("device"):
            used_device = str(msg["device"])
        if msg.get("event") == "done":
            engine_info.update(msg)
            backend = msg.get("backend")
            if isinstance(msg.get("gainDB"), (int, float)):
                engine_gain = msg["gainDB"]
        if msg.get("event") == "fallback":
            fallbacks.append(str(msg.get("message") or msg.get("phase") or "加速未能完成，已回退"))
        if msg.get("event") in ("progress", "stage", "status", "device", "fallback"):
            p = msg.get("progress")
            emit("status", phase=msg.get("phase") or msg.get("message") or "正在分离声音",
                 device=used_device, progress=p, scale=msg.get("scale", 100),
                 model=msg.get("model"), backend=msg.get("backend"))
    try:
        engine.mkdir()
        emit("status", phase="读取音频并截取处理范围")
        segment = stage / "片段.wav"
        media(["-i", str(source), "-ss", str(a.start), "-t", str(a.end-a.start),
               "-map", "0:a:0", "-vn", "-ac", "2", "-ar", "44100", "-c:a", "pcm_f32le", str(segment)])
        verify_source(source, a.source_sha256)
        if segment.stat().st_size < 1000:
            raise ValueError("这个范围没有读到足够的音频")
        emit("status", phase="加载模型并分离声音")
        execute([str(RUNNER), "--input", str(segment), "--output-dir", str(engine),
                 "--mode", a.mode, "--device", a.device, "--quality", a.quality], relay)
        checked()
        emit("status", phase="检查轨道和声音峰值")
        ids = MODES[a.mode]
        metadata = []
        for name in ids:
            track = engine / (name + ".wav")
            if not track.is_file() or track.stat().st_size < 1000:
                raise ValueError(f"引擎没有交回「{TRACKS[name]}」音轨")
            track_info = probe(track)["streams"][0]
            if (track_info.get("sample_rate") != "44100" or track_info.get("channels") != 2
                    or track_info.get("duration_ts") != engine_info.get("frames")):
                raise JobError("invalid_result", "分离音轨长度或格式不一致，请重新分离")
            peak = peak_db([track])
            metadata.append({"id": name, "label": TRACKS[name], "filename": track.name,
                             "peakDB": peak if math.isfinite(peak) else None})
        manifest = {
            "schema": 1, "title": source.stem, "mode": a.mode,
            "start": a.start, "end": a.end, "device": used_device,
            "elapsed": round(time.monotonic()-start, 2), "tracks": metadata, "fallbacks": fallbacks,
            "engineGainDB": engine_gain, "quality": a.quality, "backend": backend,
            "model": engine_info.get("model"), "frames": engine_info.get("frames"),
            "sampleRate": 44100, "createdAt": datetime.now(timezone.utc).isoformat(),
            "sourceSHA256": a.source_sha256,
        }
        (engine / "拾声分轨.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
        checked()
        publish(engine, output)
        emit("done", result=str(output))
    finally:
        shutil.rmtree(stage, ignore_errors=True)

def safe_name(text):
    cleaned = re.sub(r"[\x00-\x1f/\\:]", " ", str(text)).strip(" .")[:75]
    return cleaned.encode("utf-8")[:105].decode("utf-8", errors="ignore") or "分轨结果"

def export(a):
    source = a.source.resolve(strict=True)
    directory = a.dest.resolve(strict=True)
    if not directory.is_dir():
        raise ValueError("请选择输出文件夹")
    m = json.loads((source / "拾声分轨.json").read_text(encoding="utf-8"))
    all_tracks = m["tracks"]
    available = {track["id"] for track in all_tracks}
    selected = available if a.tracks is None else set(a.tracks)
    if not selected or not selected.issubset(available):
        raise JobError("invalid_selection", "请至少选择一条当前结果中的音轨")
    if len(available) != len(all_tracks):
        raise JobError("invalid_result", "结果清单中有重复音轨，请重新分离")
    tracks = [dict(track) for track in all_tracks if track["id"] in selected]
    m["tracks"] = tracks
    paths = []
    for track in tracks:
        path = (source / track["filename"]).resolve(strict=True)
        if not path.is_relative_to(source) or not path.is_file():
            raise JobError("invalid_result", "结果音轨位置无效，请重新分离")
        paths.append(path)
    ext, codec = FORMATS[a.format]
    peaks = [peak_db([path]) for path in paths]
    highest = max(peaks + ([peak_db(paths)] if len(paths) > 1 else []))
    # A common gain preserves the relationship among stems. Leave 1 dB of encoder headroom.
    adjustment = min(0, -1 - highest)
    stage = Path(tempfile.mkdtemp(prefix=".拾声导出-", dir=directory))
    created = None
    try:
        title = safe_name(m["title"])
        used_names = set()
        for i, t in enumerate(tracks):
            checked()
            emit("status", phase=f"正在保存 {i+1}/{len(tracks)} · {t['label']}")
            stem = f"{title} · {safe_name(t['label'])}"
            name = f"{stem}.{ext}"
            if name in used_names:
                name = f"{stem} · {safe_name(t['id'])}.{ext}"
            used_names.add(name)
            src = paths[i]
            filters = ["-af", f"volume={adjustment:.5f}dB"] if adjustment else []
            media(["-i", str(src), "-map", "0:a:0", *filters, *codec, str(stage / name)])
            t["filename"] = name
            t["peakDB"] = peaks[i] + adjustment if math.isfinite(peaks[i]) else None
        checked()
        if len(tracks) == 1:
            stem = f"{title} · {safe_name(tracks[0]['label'])}"
            for n in range(1, 10001):
                dest = directory / (stem + (f" ({n})" if n > 1 else "") + "." + ext)
                try:
                    checked()
                    publish(stage / tracks[0]["filename"], dest)
                    created = dest
                    break
                except FileExistsError:
                    continue
        else:
            m["exportGainDB"] = adjustment
            m["exportFormat"] = a.format
            (stage / "拾声分轨.json").write_text(json.dumps(m, ensure_ascii=False, indent=2), encoding="utf-8")
            for n in range(1, 10001):
                dest = directory / (title + " · 分轨" + (f" ({n})" if n > 1 else ""))
                try:
                    checked()
                    publish(stage, dest)
                    created = dest
                    break
                except FileExistsError:
                    continue
        if created is None:
            raise ValueError("同名输出太多，请换一个输出文件夹")
        # Publishing commits an already complete result. A later cancel does not remove it.
        emit("done", result=str(created), gainDB=adjustment,
             tracks=[track["id"] for track in tracks], format=a.format)
    finally:
        shutil.rmtree(stage, ignore_errors=True)

def main():
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    p = argparse.ArgumentParser()
    commands = p.add_subparsers(dest="command", required=True)
    s = commands.add_parser("separate")
    s.add_argument("source", type=Path)
    s.add_argument("dest", type=Path)
    s.add_argument("--start", type=float, required=True)
    s.add_argument("--end", type=float, required=True)
    s.add_argument("--mode", choices=MODES, required=True)
    s.add_argument("--device", choices=["auto", "cpu", "metal"], default="auto")
    s.add_argument("--quality", choices=["standard", "precise"], default="standard")
    s.add_argument("--source-sha256", default=None)
    e = commands.add_parser("export")
    e.add_argument("source", type=Path)
    e.add_argument("dest", type=Path)
    e.add_argument("--format", choices=FORMATS, default="wav24")
    e.add_argument("--tracks", nargs="*", default=None)
    a = p.parse_args()
    finished = threading.Event()
    threading.Thread(target=watch_parent, args=(os.getppid(), finished),
                     name="audio-parent-watch", daemon=True).start()
    try:
        if not Path(FFMPEG).is_file() or not Path(FFPROBE).is_file():
            raise JobError("missing_component", "缺少本机音频工具，请检查项目已有的 FFmpeg 与 FFprobe")
        if a.command == "separate":
            separate(a)
        else:
            export(a)
        return 0
    except InterruptedError:
        emit("cancelled", message="已取消。可调整范围后再试。")
        return 130
    except Exception as exc:
        code = getattr(exc, "code", "engine_failed")
        message = str(exc)
        if isinstance(exc, OSError) and exc.errno == errno.ENOSPC:
            code, message = "disk_full", "磁盘空间不足，请腾出空间或换一个保存位置后重试"
        elif isinstance(exc, PermissionError):
            code, message = "permission", "无法读取或保存文件，请检查权限或换一个保存位置"
        elif isinstance(exc, FileNotFoundError):
            code, message = "file_missing", "需要的文件已移动或不存在，请重新定位音频或重新分离"
        elif isinstance(exc, MemoryError):
            code, message = "memory_full", "本机可用内存不足，请关闭其他程序或缩短处理范围后重试"
        elif isinstance(exc, RuntimeError):
            print(str(exc), file=sys.stderr)
            code, message = "audio_failed", "音频处理未完成，请检查文件是否完整，或更换保存位置后重试"
        elif "缺少本地模型" in message or "模型" in message and "校验失败" in message:
            code = "model_missing" if "缺少" in message else "model_invalid"
        emit("error", code=code, message=message)
        return 1
    finally:
        finished.set()

if __name__ == "__main__":
    sys.exit(main())
