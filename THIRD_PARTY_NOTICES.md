# 第三方组件与模型

应用自己的代码、第三方代码、指法数据、模型权重和用户歌曲分别适用各自的授权。仓库不附带模型权重、Python 环境、歌曲和分离结果。

## 随源码保留的组件

| 组件 | 固定来源 | 随附许可 |
| --- | --- | --- |
| LV-Chordia 推理代码 | [openmirlab/lv-chordia，d8ab9ac](https://github.com/openmirlab/lv-chordia/tree/d8ab9ac99bce081bb79065d717f96e2c3b2099c8) | [MIT 原文](app/audio/乐谱/LICENSE-LVChordia) |
| 吉他指法数据 | [tombatossals/chords-db，df06fa7](https://github.com/tombatossals/chords-db/tree/df06fa7b425cf5fd29485ff6591236b3557e3fac) | [MIT 原文](app/audio/乐谱/LICENSE-chords-db) |
| pydub 0.25.1 | [jiaaro/pydub](https://github.com/jiaaro/pydub) | [MIT 原文](app/audio/乐谱/LICENSE-pydub) |

本项目对推理入口、设备选择、分块处理、进度、取消和临时文件管理的改动见 [乐谱组件说明](app/audio/乐谱/THIRD_PARTY.md)。

## 安装时获取的模型

| 用途 | 模型 | 来源与校验 |
| --- | --- | --- |
| 双轨与兼容路径 | UVR Inst HQ 3、可选 KARA 2 | [分离模型清单](app/audio/引擎/模型清单.json) |
| 三轨中的主唱与和声 | Frazer/Becruily BS-Roformer Karaoke | [作者模型页](https://huggingface.co/becruily/bs-roformer-karaoke)，固定版本见模型清单 |
| 六轨及既有分离路径 | Demucs htdemucs / htdemucs_6s | [Demucs](https://github.com/facebookresearch/demucs)，固定文件见模型清单 |
| 和弦时间谱 | LV-Chordia 五模型集成 | [和弦模型清单](app/audio/乐谱/models.json) |

下载来源、文件大小与 SHA-256 用于核对是否为固定版本，不等同于模型授权证明。2026-11-09 核对的 UVR 转载仓库与 BS-Roformer 作者固定版本元信息未给出明确许可标记，因此这里不把这些权重归为应用代码的许可，也不随源码包再分发它们。模型使用和再分发范围需按相应权利方的授权核实。

## 安装时获取的软件依赖

音频环境依赖 Torch、torchaudio、Demucs、MLX 音频组件、ONNX Runtime、librosa、NumPy 等，固定版本见 [requirements-engine.txt](app/audio/引擎/requirements-engine.txt)。这些依赖通过安装工具获取，适用各自许可。本仓库没有把整个 Python 环境复制进来。

FFmpeg/FFprobe 由用户另行安装。FFmpeg 的许可取决于实际构建选项；本仓库不附带其可执行文件。详见 [FFmpeg 许可说明](https://ffmpeg.org/legal.html)。

用户应自行确认所导入音频、歌词和后续导出内容的使用范围。本项目的代码授权不替代歌曲、录音、歌词或训练素材的权利。
