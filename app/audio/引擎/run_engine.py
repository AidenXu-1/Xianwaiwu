"""Run a pinned local audio separation job. stdout is reserved for JSON lines."""

import argparse
from fractions import Fraction
import hashlib
from importlib.util import find_spec
import json
import math
import os
from pathlib import Path
import random
import shutil
import signal
import subprocess
import sys
import tempfile
import time

RATE = 44_100
SEED = 214
DEMUCS_QUALITY = {"standard": (1, 0.25), "precise": (2, 0.50)}
ROOT = Path(__file__).resolve().parent
CHECKPOINTS = Path(os.environ.get("XIANWAIWU_SEPARATION_WEIGHTS", ROOT / "模型"))
UVR_INST = "uvr-inst-hq3"
UVR_KARA = "uvr-kara2"
BS_KARA = "bs-karaoke-frazer-becruily"
BS_CONFIG = "bs-karaoke-config"
STEMS = {
    "vocals": ("vocals",),
    "instrumental": ("instrumental",),
    "pair": ("vocals", "instrumental"),
    "music6": ("vocals", "drums", "bass", "guitar", "piano", "other"),
    "lead": ("lead",),
    "backing": ("backing",),
    "leadback": ("lead", "backing"),
    "lead3": ("lead", "harmony", "instrumental"),
}


def emit(event, phase, progress, device=None, **info):
    data = {"event": event, "phase": phase, "progress": progress, **info}
    if device:
        data["device"] = device
    print(json.dumps(data, ensure_ascii=False), flush=True)


def verified_checkpoint(record, model_name):
    path = CHECKPOINTS / record["filename"]
    if not path.is_file():
        raise ValueError(f"缺少本地模型 {model_name}。请先运行引擎安装脚本。")
    with path.open("rb") as model_file:
        digest = hashlib.file_digest(model_file, "sha256").hexdigest()
    if digest != record["sha256"]:
        raise ValueError(f"模型 {model_name} 校验失败。请重新安装模型后重试。")
    return path


def load_model(path):
    import numpy as np
    import torch
    from demucs.htdemucs import HTDemucs
    from demucs.states import load_model as make_model

    allowed = [HTDemucs, Fraction, np.dtype, type(np.dtype(np.float64)), type(np.dtype(np.float32)),
               (np._core.multiarray.scalar, "numpy.core.multiarray.scalar")]
    with torch.serialization.safe_globals(allowed):
        checkpoint = torch.load(path, map_location="cpu", weights_only=True)
    return make_model(checkpoint).eval()


def cpu_stems(model, mixture, label, shifts, overlap):
    import numpy as np
    import torch
    from demucs.apply import apply_model

    thread_count = min(8, os.cpu_count() or 1)
    torch.set_num_threads(thread_count)
    random.seed(SEED)
    rng = random.Random(SEED)
    stride = int((1 - overlap) * int(float(model.segment) * RATE))
    total = sum(
        math.ceil((mixture.shape[-1] + RATE // 2 - rng.randint(0, RATE // 2)) / stride)
        for _ in range(shifts)
    )
    completed = 0

    def report_chunk(*_):
        nonlocal completed
        completed += 1
        emit("progress", "分离声音", min(87, 35 + int(52 * completed / total)), label)

    hook = model.register_forward_hook(report_chunk)
    try:
        with torch.inference_mode():
            result = apply_model(model, torch.from_numpy(mixture)[None], device="cpu",
                                 shifts=shifts, overlap=overlap, progress=False)[0]
    finally:
        hook.remove()
    return dict(zip(model.sources, np.asarray(result)))


def metal_stems(model, mixture, shifts, overlap):
    import mlx.core as mx
    import numpy as np
    from mlx_audio_separator.demucs_mlx.apply_mlx import apply_model
    from mlx_audio_separator.demucs_mlx.mlx_convert import convert_single_model

    if not mx.metal.is_available():
        raise RuntimeError("这次运行未获得 Mac GPU 访问权限。")
    mx.set_default_device(mx.gpu)
    converted = convert_single_model(model, verbose=False)
    converted.eval()
    result = apply_model(converted, mx.array(mixture)[None], shifts=shifts, overlap=overlap,
                         batch_size=1, seed=SEED, progress=False, compile=False)[0]
    mx.eval(result)
    return dict(zip(converted.sources, np.asarray(result)))


def demucs_estimates(model_path, mixture, device, quality):
    import numpy as np

    model = load_model(model_path)
    center = mixture.mean(axis=0)
    mean = float(center.mean())
    scale = max(float(center.std(ddof=1)) if center.size > 1 else 0, 1e-8)
    normalized = (mixture - mean) / scale
    shifts, overlap = DEMUCS_QUALITY[quality]
    emit("progress", "分离声音", 35, device)
    if not np.any(mixture):
        estimates = {name: np.zeros_like(mixture) for name in model.sources}
    elif device == "metal":
        estimates = metal_stems(model, normalized, shifts, overlap)
    else:
        estimates = cpu_stems(model, normalized, device, shifts, overlap)
    estimates = {name: result * scale + mean for name, result in estimates.items()}
    estimates["instrumental"] = mixture - estimates["vocals"]
    return estimates


def uvr_estimates(model_paths, mixture, device, quality):
    from uvr_mdx import separate

    lead_requested = UVR_KARA in model_paths or BS_KARA in model_paths
    end = 59 if lead_requested else 87
    phase = "分离全部人声和乐器"
    emit("progress", phase, 35, device)
    instrumental = separate(UVR_INST, model_paths[UVR_INST], mixture, device, quality,
                            lambda fraction: emit("progress", phase, 35 + round((end - 35) * fraction), device))
    vocals = mixture - instrumental
    if not lead_requested:
        return {"vocals": vocals, "instrumental": instrumental}
    phase = "区分主唱与和声"
    emit("progress", phase, 61, device)
    if BS_KARA in model_paths:
        lead = roformer_lead(model_paths[BS_KARA], model_paths[BS_CONFIG], vocals, device, quality,
                             lambda fraction: emit("progress", phase, 61 + round(26 * fraction), device))
        return {"lead": lead, "harmony": vocals - lead, "instrumental": instrumental}
    harmony = separate(UVR_KARA, model_paths[UVR_KARA], vocals, device, quality,
                       lambda fraction: emit("progress", phase, 61 + round(26 * fraction), device))
    lead = vocals - harmony
    return {"lead": lead, "harmony": harmony, "instrumental": instrumental, "backing": mixture - lead}


def roformer_lead(model_path, config_path, mixture, device, quality, progress):
    import numpy as np
    import torch
    import yaml

    config = yaml.load(config_path.read_text(encoding="utf-8"), Loader=yaml.FullLoader)
    # PyTorch iSTFT omits a partial final hop unless length is provided. Give
    # both backends the same trailing context, then crop without a leading shift.
    trailing_context = int(config["model"]["stft_hop_length"])
    state = torch.load(model_path, map_location="cpu", weights_only=True)
    state = state.get("state_dict", state.get("model", state))
    if device == "metal":
        import mlx.core as mx
        from mlx.utils import tree_flatten
        from mlx_audio_separator.separator.models.roformer.loader import (
            convert_torch_to_mlx_weights, _override_depth_from_weights, create_bs_roformer_mlx)

        if not mx.metal.is_available():
            raise RuntimeError("这次运行未获得 Mac GPU 访问权限。")
        mx.set_default_device(mx.gpu)
        weights = convert_torch_to_mlx_weights(state)
        _override_depth_from_weights(config, set(weights))
        model = create_bs_roformer_mlx(config)
        if set(dict(tree_flatten(model.parameters()))) != set(weights):
            raise ValueError("主唱模型参数与配置不匹配，请重新准备模型。")
        model.load_weights(list(weights.items()), strict=True)
        model.eval()
        mx.eval(model.parameters())

        def predict(block):
            padded = np.pad(block, ((0, 0), (0, trailing_context)), mode="reflect")
            result = model(mx.array(padded[None]))
            mx.eval(result)
            return np.array(result, dtype=np.float32)[..., :block.shape[-1]]
    else:
        try:
            from bs_roformer import BSRoformer
        except ImportError as exc:
            raise ValueError("缺少主唱模型的处理器运行组件，请重新运行引擎安装脚本。") from exc

        options = dict(config["model"])
        if options.pop("linear_transformer_depth", 0) != 0 or options.pop("mlp_expansion_factor", 4) != 4:
            raise ValueError("主唱模型配置不受当前处理器实现支持。")
        torch.set_num_threads(min(8, os.cpu_count() or 1))
        try:
            model = BSRoformer(**options).eval()
            model.load_state_dict(state, strict=True)
        except (TypeError, RuntimeError) as exc:
            raise ValueError(f"主唱模型参数与处理器配置不匹配，请重新准备引擎：{exc}") from exc

        def predict(block):
            padded = np.pad(block, ((0, 0), (0, trailing_context)), mode="reflect")
            with torch.inference_mode():
                return model(torch.from_numpy(padded[None])).numpy()[..., :block.shape[-1]]

    del state
    chunk_length = int(config["audio"]["chunk_size"])
    overlap = int(config["inference"]["num_overlap"]) * (2 if quality == "precise" else 1)
    stride = chunk_length // overlap
    frames = mixture.shape[-1]
    starts = list(range(0, max(1, frames - chunk_length + 1), stride))
    if frames > chunk_length and starts[-1] != frames - chunk_length:
        starts.append(frames - chunk_length)
    result = np.zeros_like(mixture, dtype=np.float32)
    counter = np.zeros(frames, dtype=np.float32)
    window = np.hamming(chunk_length).astype(np.float32)
    for index, start in enumerate(starts):
        block = mixture[:, start:start + chunk_length]
        live = block.shape[-1]
        if live < chunk_length:
            block = np.pad(block, ((0, 0), (0, chunk_length - live)), mode="reflect")
        value = predict(block)
        value = value[0, 0] if value.ndim == 4 else value[0]
        if quality == "precise":
            inverted = predict(-block)
            inverted = inverted[0, 0] if inverted.ndim == 4 else inverted[0]
            value = (value - inverted) * 0.5
        if value.shape != (2, chunk_length):
            raise ValueError("主唱模型返回的音频长度异常，请重新准备引擎或切换处理器。")
        result[:, start:start + live] += value[:, :live] * window[:live]
        counter[start:start + live] += window[:live]
        progress((index + 1) / len(starts))
    return result / np.maximum(counter, 1e-8)


def decode(source, ffmpeg):
    import numpy as np

    result = subprocess.run([ffmpeg, "-hide_banner", "-v", "error", "-nostdin", "-i", str(source),
                             "-map", "0:a:0", "-f", "f32le", "-ac", "2", "-ar", str(RATE), "pipe:1"],
                            check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode or len(result.stdout) < 8:
        if result.stderr:
            sys.stderr.buffer.write(result.stderr)
        raise ValueError("无法读取这份音频。请确认文件完整，并尝试重新导入。")
    samples = np.frombuffer(result.stdout, dtype="<f4").reshape(-1, 2).T.copy()
    if not np.isfinite(samples).all():
        raise ValueError("音频包含无法处理的采样值，请先重新保存为 WAV。")
    return samples


def write_stems(output_dir, results, ffmpeg):
    import numpy as np

    if not all(np.isfinite(track).all() for track in results.values()):
        raise RuntimeError("分离结果包含异常采样值。请换一段音频重试。")
    peak = max(float(np.max(np.abs(track))) for track in results.values())
    # All delivered tracks get the same trim if a track or their full mix could clip.
    if len(results) > 1:
        peak = max(peak, float(np.max(np.abs(sum(results.values())))))
    gain = min(1.0, 10 ** (-0.3 / 20) / peak) if peak >= 1.0 else 1.0
    linked = []
    with tempfile.TemporaryDirectory(prefix=".分离暂存-", dir=output_dir) as tmp:
        try:
            for name, track in results.items():
                draft = Path(tmp) / f"{name}.wav"
                subprocess.run([ffmpeg, "-hide_banner", "-v", "error", "-nostdin", "-f", "f32le",
                                "-ar", str(RATE), "-ac", "2", "-i", "pipe:0", "-c:a", "pcm_s24le",
                                str(draft)], input=(track.T * gain).astype("<f4").tobytes(), check=True)
            for name in results:
                filename = f"{name}.wav"
                target = output_dir / filename
                os.link(Path(tmp) / filename, target)
                linked.append(target)
        except BaseException:
            for target in linked:
                target.unlink(missing_ok=True)
            raise
    return round(20 * math.log10(gain), 3), round(peak, 7)


def run(args, device, initial_progress):
    ffmpeg = os.environ.get("SHISHENG_FFMPEG") or shutil.which("ffmpeg")
    if ffmpeg is None:
        raise ValueError("找不到音频读取工具 FFmpeg，请先安装后重试。")
    source = args.input.resolve()
    destination = args.output_dir.resolve()
    output_names = STEMS[args.mode]
    if not source.is_file():
        raise ValueError("源音频已移动或无法读取，请重新导入。")
    if not destination.is_dir():
        raise ValueError("找不到结果目录，请重新选择。")
    if any((destination / f"{name}.wav").exists() for name in output_names):
        raise ValueError("结果目录里已有同名文件，请换一个空目录。")

    started = time.monotonic()
    manifest = json.loads((ROOT / "模型清单.json").read_text(encoding="utf-8"))
    if os.environ.get("XIANWAIWU_PACKAGED") == "1":
        sys.path.insert(0, str(ROOT.parent))
        from model_store import ensure_files
        names = ((UVR_INST, BS_KARA, BS_CONFIG) if args.mode == "lead3" else
                 (UVR_INST, UVR_KARA) if args.mode in ("lead", "backing", "leadback") else
                 ("htdemucs_6s",) if args.mode == "music6" else (UVR_INST,))
        ensure_files([manifest[name] for name in names], CHECKPOINTS,
                     lambda done, total, name: emit("progress", f"首次准备模型 {done / 1e6:.1f}/{total / 1e6:.1f} MB", min(3, int(3 * done / total)), device))
    uvr_runtime = "onnx" if device == "metal" else "onnxruntime"
    if args.mode == "lead3":
        model_names = (UVR_INST, BS_KARA, BS_CONFIG)
        if find_spec(uvr_runtime) is None:
            raise ValueError("缺少人声分离运行组件，请重新运行引擎安装脚本。")
    elif args.mode in ("lead", "backing", "leadback"):
        model_names = (UVR_INST, UVR_KARA)
        if find_spec(uvr_runtime) is None:
            raise RuntimeError("当前缺少 UVR 推理工具，请先运行安装脚本。")
    elif args.mode == "music6":
        model_names = ("htdemucs_6s",)
    elif (CHECKPOINTS / manifest[UVR_INST]["filename"]).is_file() and find_spec(uvr_runtime) is not None:
        model_names = (UVR_INST,)
    else:
        model_names = ("htdemucs",)
        emit("fallback", "UVR 尚未准备好，使用 Demucs 研究模型", initial_progress, device)

    model_name = "+".join(model_names)
    if BS_KARA in model_names:
        backend = "mlx-uvr-bsroformer" if device == "metal" else "torch-uvr-bsroformer"
    elif UVR_INST in model_names:
        backend = "mlx-uvr" if device == "metal" else "onnxruntime-uvr"
    else:
        backend = "mlx-demucs" if device == "metal" else "torch-demucs"
    emit("progress", "检查本地模型", initial_progress, device, model=model_name, backend=backend)
    weights = {name: verified_checkpoint(manifest[name], name) for name in model_names}
    emit("progress", "读取音频", max(12, initial_progress), device)
    mixture = decode(source, ffmpeg)
    emit("progress", "准备分离", max(24, initial_progress), device)
    infer_start = time.monotonic()
    if UVR_INST in model_names:
        estimates = uvr_estimates(weights, mixture, device, args.quality)
    else:
        estimates = demucs_estimates(weights[model_name], mixture, device, args.quality)
    infer_seconds = time.monotonic() - infer_start
    results = {name: estimates[name] for name in output_names}

    emit("progress", "写入分轨文件", 91, device)
    try:
        gain_db, peak = write_stems(destination, results, ffmpeg)
    except (OSError, subprocess.CalledProcessError) as exc:
        print(str(exc), file=sys.stderr)
        raise ValueError("保存失败。请检查目录权限、同名文件和磁盘剩余空间。") from exc
    emit("done", "分离完成", 100, device, model=model_name,
         backend=backend, quality=args.quality,
         elapsed=round(time.monotonic() - started, 3),
         inference=round(infer_seconds, 3), tracks=[f"{name}.wav" for name in results],
         sampleRate=RATE, frames=int(mixture.shape[-1]), gainDB=gain_db, preScalePeak=peak)


def cancel_job(*_):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--mode", choices=STEMS, required=True)
    parser.add_argument("--device", choices=("auto", "cpu", "metal"), default="auto")
    parser.add_argument("--quality", choices=DEMUCS_QUALITY, default="standard")
    parser.add_argument("--metal-worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, cancel_job)
    try:
        if args.device == "auto" and sys.platform == "darwin" and os.uname().machine == "arm64":
            worker = subprocess.Popen([sys.executable, __file__, *sys.argv[1:], "--device", "metal", "--metal-worker"])
            try:
                code = worker.wait()
            except KeyboardInterrupt:
                worker.terminate()
                try:
                    worker.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    worker.kill()
                    worker.wait()
                raise
            if code == 0:
                return 0
            if code == 130:
                return 130
            if code == 2:
                return 2
            emit("fallback", "Mac GPU 这次未能完成，改用处理器重新分离", 0, "cpu")
        device = "cpu" if args.device == "auto" else args.device
        run(args, device, 4)
        return 0
    except KeyboardInterrupt:
        if not args.metal_worker:
            emit("error", "已取消分离", 0)
        return 130
    except Exception as exc:
        print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
        message = str(exc) if isinstance(exc, ValueError) else "本机分离失败。请尝试更短的选区或切换处理器。"
        if not args.metal_worker or isinstance(exc, ValueError):
            emit("error", message, 0, args.device)
        return 2 if isinstance(exc, ValueError) else 1


if __name__ == "__main__":
    sys.exit(main())
