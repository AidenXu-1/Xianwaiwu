# 安装与源码构建

当前版本 1.3.8，Apple 芯片 Mac，安装包最低 macOS 26.2。内置加速组件的实际最低系统为 26.2，客户端源码的 14.0 编译目标不代表整套依赖兼容 14.0。Intel Mac 与其他电脑的实际运行尚未逐一验收。

## 安装 Mac 自用版

1. 从[版本页](https://github.com/AidenXu-1/Xianwaiwu/releases/latest)下载 Xianwaiwu-1.3.8-arm64.dmg。
2. 打开 DMG，将“弦外屋”拖到 Applications（应用程序）。
3. 从应用程序打开弦外屋。安装版自带运行工具，无需安装 Python、Homebrew、Word 或配置 API。

这是商店外自用版本，未使用 Apple 分发证书，也未作公证。若首次打开被系统拦住，可按 [Apple 官方说明](https://support.apple.com/102445)在“系统设置 → 隐私与安全性”中选择“仍要打开”。App Store 不参与本版本安装。

## 首次模型准备

首次点击分离或生成乐谱时，界面显示下载和校验进度；准备完成后继续处理。只下载对应功能所需文件，校验固定大小和 SHA-256。网络中断、校验失败或取消保留原有项目与已完成模型，联网后重试即可。

| 功能 | 首次模型下载量 | 复用关系 |
| --- | --- | --- |
| 人声与伴奏 | 约 67 MB | 三轨也使用这一份 |
| 主唱、和声、伴奏 | 约 271 MB | 已有双轨模型时只新增约 204 MB |
| 音乐六轨 | 约 55 MB | 按需单独准备 |
| 和弦弹唱谱 | 约 29 MB | 不安装歌词识别模型 |

以上常用模型全部准备后合计约 355 MB，不随歌曲数量重复下载。安装包与运行工具另占空间；歌曲与分轨大小取决于时长和结果数量。模型来自固定公开来源，原音频不上传。来源与许可分别见[第三方声明](../THIRD_PARTY_NOTICES.md)。

## 数据与更新

日常项目、歌词、乐谱和试听状态位于 ~/Library/Application Support/Xianwaiwu，安装版模型位于其中的 Models/。导出位置自行选择。更新时退出 App，再用新版替换应用程序中的 App，保留资料目录。App 搬移或更新不需要重新复制开发项目。

原始歌曲不会改写，移动后可重新定位。移除 App 不会自动清理资料库与模型。

## 从源码构建

开发者需要完整 Xcode、Python 3、uv、FFmpeg 与 FFprobe。图标构建需支持 .icon 文档的 Xcode，其他 Xcode 和系统组合尚未逐一验证。

已有 Homebrew 的机器可运行：

```sh
brew install uv ffmpeg
git clone https://github.com/AidenXu-1/Xianwaiwu.git
cd Xianwaiwu
bash 'app/audio/引擎/setup-engine.command'
python3 'app/audio/乐谱/install_models.py'
python3 'app/audio/样本/create_demo.py'
bash 'app/macos/构建原生版.command'
open 'releases/弦外屋.app'
```

源码开发模式使用项目目录内的 Python 环境和模型、外部 FFmpeg。它与独立安装版的路径分别处理。安装脚本默认下载模型约 440 MB，包含兼容路径模型；已有且校验通过的文件复用。示例生成器只在缺失时生成 12 秒原创合成音频，不覆盖已有文件。

独立安装包的可重建步骤见[打包说明](PACKAGING.md)。检查入口见[本机检查](../app/macos/测试/README.md)。

## 验证边界

已执行的搬移、只读安装盘与开发目录隔离结果见版本准备记录。本机模拟隔离不能替代另一台 Mac 的实际验收；未声称 Apple 公证或 App Store 审核通过。
