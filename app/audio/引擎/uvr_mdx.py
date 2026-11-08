"""Two pinned UVR MDX models. Network and file management live outside inference."""
import math

UVR_MODELS = {
    "uvr-inst-hq3": {"n_fft": 6144, "bins": 3072, "gain": 1.022},
    "uvr-kara2": {"n_fft": 5120, "bins": 2048, "gain": 1.065},
}
HOP = 1024
FRAMES = 256
BLOCK = HOP * (FRAMES - 1)


def predict_cpu(path, n_fft, bins):
    import numpy as np
    import onnxruntime as ort
    import torch

    options = ort.SessionOptions()
    options.intra_op_num_threads = 4
    session = ort.InferenceSession(str(path), sess_options=options, providers=["CPUExecutionProvider"])
    window = torch.hann_window(n_fft)
    torch.set_num_threads(4)

    def predict(block, denoise):
        spectrum = torch.stft(torch.from_numpy(block), n_fft, HOP, window=window, return_complex=True)
        ri = torch.view_as_real(spectrum[:, :bins]).permute(0, 3, 1, 2).reshape(1, 4, bins, FRAMES)
        packed = ri.numpy().copy()
        packed[:, :, :3] = 0
        estimate = session.run(["output"], {"input": packed})[0]
        if denoise:
            estimate = (estimate - session.run(["output"], {"input": -packed})[0]) * 0.5
        expanded = np.pad(estimate.reshape(2, 2, bins, FRAMES), ((0, 0), (0, 0), (0, n_fft // 2 + 1 - bins), (0, 0)))
        ordered = torch.from_numpy(expanded).permute(0, 2, 3, 1).contiguous()
        return torch.istft(torch.view_as_complex(ordered), n_fft, HOP, window=window, length=BLOCK).numpy()

    return predict


def predict_metal(path, n_fft, bins):
    import mlx.core as mx
    import numpy as np
    from mlx_audio_separator.separator.models.mdx.loader import load_mdx_model
    from mlx_audio_separator.separator.models.mdx.stft import STFT

    if not mx.metal.is_available():
        raise RuntimeError("这次运行未获得 Mac GPU 访问权限。")
    mx.set_default_device(mx.gpu)
    model, _ = load_mdx_model(str(path), {
        "mdx_dim_f_set": bins, "mdx_dim_t_set": 8, "mdx_n_fft_scale_set": n_fft,
    })
    stft = STFT(n_fft, HOP, bins)

    def predict(block, denoise):
        spectrum = stft(mx.array(block[None]))
        spectrum = spectrum.at[:, :, :3, :].add(-spectrum[:, :, :3, :])
        estimate = model(spectrum)
        if denoise:
            estimate = (estimate - model(-spectrum)) * 0.5
        output = stft.inverse(estimate)[0]
        mx.eval(output)
        return np.array(output)

    return predict


def separate(model_name, path, mixture, device, quality, progress):
    import numpy as np

    if not mixture.size or not np.any(mixture):
        progress(1.0)
        return np.zeros_like(mixture)
    model = UVR_MODELS[model_name]
    bins, n_fft = model["bins"], model["n_fft"]
    make_predictor = predict_metal if device == "metal" else predict_cpu
    predict = make_predictor(path, n_fft, bins)
    scale = max(float(np.abs(mixture).max()), 1e-8)
    margin = n_fft // 2
    frames = mixture.shape[-1]
    precise = quality == "precise"
    stride = BLOCK // 2 if precise else BLOCK * 3 // 4
    chunks = 1 + math.ceil(max(0, frames + 2 * margin - BLOCK) / stride)
    padded_length = BLOCK + stride * (chunks - 1)
    padded = np.zeros((2, padded_length), dtype=np.float32)
    padded[:, margin:margin + frames] = mixture / scale
    result = np.zeros_like(padded)
    divider = np.zeros(padded_length, dtype=np.float32)
    window = np.hanning(BLOCK).astype(np.float32)
    for index in range(chunks):
        start = index * stride
        stop = start + BLOCK
        output = predict(padded[:, start:stop].copy(), precise)
        if output.shape != (2, BLOCK):
            raise RuntimeError(f"Unexpected UVR output size {output.shape}")
        result[:, start:stop] += output * window
        divider[start:stop] += window
        progress((index + 1) / chunks)
    live = slice(margin, margin + frames)
    return result[:, live] * (scale * model["gain"]) / np.maximum(divider[live], 1e-8)
