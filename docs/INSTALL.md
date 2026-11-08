# 安装与源码构建

当前版本 1.3.7，面向 Apple 芯片 Mac。本仓库提供源码，App 需要与本项目的音频环境一起使用；当前没有经过新电脑验收的独立安装包。

App 声明的运行下限为 macOS 14，但本轮只验证开发者当前的 Apple 芯片 Mac，不表示所有旧系统与依赖组合都已经验证。

## 准备工具

- 完整 Xcode 与其命令行工具。构建会处理 `.icon` 图标文档，需要支持该格式的 Xcode；其他 Xcode 版本尚未逐一验证。
- Python 3，用于生成 Xcode 工程。
- uv，用于准备固定版本的音频环境。
- FFmpeg 与 FFprobe。Apple 芯片 Mac 默认从 `/opt/homebrew/bin` 查找。

已有 Homebrew 的机器可以安装音频工具：

```sh
brew install uv ffmpeg
```

工具的官方说明：[Xcode](https://developer.apple.com/xcode/)、[uv](https://docs.astral.sh/uv/getting-started/installation/)、[FFmpeg](https://ffmpeg.org/download.html)。

## 获取源码

下载仓库 ZIP 并解压，或执行：

```sh
git clone https://github.com/AidenXu-1/Xianwaiwu.git
cd Xianwaiwu
```

下面的命令均在项目根目录执行。

## 准备音频环境与模型

```sh
bash 'app/audio/引擎/setup-engine.command'
python3 'app/audio/乐谱/install_models.py'
```

第一个命令创建项目自己的 Python 3.11 环境，安装固定依赖并下载分离模型；第二个命令下载和弦识别模型。安装过程需要访问依赖平台、GitHub 和模型来源站点。

默认模型合计约 440 MB；可选的旧版兼容模型另计。依赖环境需要额外磁盘空间。下载时会校验文件大小及 SHA-256，已有且通过校验的文件会复用。

模型权重的来源许可独立适用，见[第三方声明](../THIRD_PARTY_NOTICES.md)。源码仓库不捆绑这些权重。

## 构建与打开

```sh
python3 'app/audio/样本/create_demo.py'
bash 'app/macos/构建原生版.command'
open 'releases/弦外屋.app'
```

共享构建方案为 `Xianwaiwu`。示例生成脚本只在示例缺失时创建一段 12 秒合成练习音频，保留已有文件。构建脚本会生成原生工程并把 App 放进 `releases/`。保留项目目录结构，App 会从上层目录寻找本地引擎与指法数据；当前不支持只把 App 拖到其他位置后脱离项目运行。

构建不包含正式开发者签名和公证。当前说明针对源码本机构建，不作为已签名安装包的安装说明。

## 第一次操作

打开后拖入一首本地歌曲，先选择几秒至几十秒进行分离。试听完成后，再决定处理整首。点击歌名旁「歌词」导入自带有效时间的文件；点击「乐谱」生成可校正的和弦参考谱。

## 数据放在哪里

- 日常资料库：`~/Library/Application Support/Xianwaiwu`。
- 模型与运行环境：项目内 `app/audio/引擎/` 和 `app/audio/乐谱/weights/`。
- 用户导出：保存时自行选择的位置。

原始歌曲不会改写。请保留原文件，移动后可在 App 中重新定位。需要开发验证时使用独立 `XIANWAIWU_DATA`，不要将日常资料库作为测试目录。
