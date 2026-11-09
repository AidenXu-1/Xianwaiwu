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

## 商店外 App 安装包

自有代码采用 [MIT](LICENSE)，第三方组件分别适用各自许可。1.3.8 的 Apple 芯片安装包内置 CPython 3.11.15、固定版本音频依赖，以及从源码构建的 FFmpeg 9.0.2 / LAME 3.100。FFmpeg 仅启用音频功能，没有启用 GPL 或非自由构建选项，保留 FFmpeg 与 LAME 各自 LGPL 许可。上方关于自行安装工具的说明针对源码构建；安装包用户无需安装 Python、Homebrew 或填写 API。

Python 包保留原 dist-info 元信息、包内许可与版权声明；额外的 Python 发行与音频工具许可位于 App 的 Contents/Resources/Runtime/ThirdPartyLicenses/。App 菜单“开源许可与模型来源”可打开本说明。自有代码的 MIT 不替代第三方许可。

同一版本页将提供 Xianwaiwu-runtime-sources.zip，包含音频工具和相关运行组件源码、构建脚本与固定来源记录。Python 构建来自 python-build-standalone 20260414，其源码及许可出处也随附。可按原许可修改与替换第三方组件，并为调试这些修改进行必要检查；App 没有阻止替换的访问控制。构建入口为 tools/build-audio-tools.py 和 tools/package-macos.py。

安装包不含模型权重，首次使用时从固定来源下载并核验 SHA-256，保存到用户资料目录 Models/，后续复用。失败或取消保留已有内容，不在 App 内写模型，原音频不上传。

当前安装包按内置组件实际要求标注 macOS 26.2+。这是商店外发布的未公证版本，使用本机签名核对包内文件完整性，没有 Apple 分发证书。首次打开可能需要按 [Apple 官方说明](https://support.apple.com/102445) 在系统设置中允许。
