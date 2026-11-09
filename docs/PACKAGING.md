# 独立 Mac 安装包

安装包为 Apple 芯片、商店外自用版本，使用本机签名，不要求 Apple Developer 账号。模型不装入 App，首次调用对应功能时下载到用户资料目录，保持与开发路径分离。

## 构建顺序

先按 INSTALL.md 准备源码环境并构建原生 App，然后在项目根目录执行：

```sh
app/audio/引擎/.venv/bin/python -B tools/collect-runtime-sources.py --workspace scratch/distribution
app/audio/引擎/.venv/bin/python -B tools/build-audio-tools.py --workspace scratch/distribution
app/audio/引擎/.venv/bin/python -B tools/package-macos.py --app releases/弦外屋.app --workspace scratch/distribution --output scratch/github-ready/release-assets
```

打包只读取已有环境，将自包含 Python、固定依赖、精简音频工具、产品组件、原创合成示例及许可装入 App。不会把个人歌曲、歌词、分轨、资料库或模型权重装进安装包。源码仓库也不提交这些构建产物。

构建目录为本轮专用 scratch/distribution；重复制作前保留需要的旧产物，再清理该目录的 package/。脚本拒绝覆盖已存在的包暂存目录或同名 DMG，防止误覆盖可用候选。

## 校验与来源

音频工具从固定官方源码构建，按实际分离通道校验浮点 PCM 解码和编码的无损往返。打包扫描全部原生库，只允许包内相对引用及系统库；修正绝对库身份、Python 配置前缀，移除编译调试路径。最低系统要求按内置原生组件计算。

每个原生文件及 App 都使用本机签名，随后验证完整性，再生成可拖入应用程序的 DMG。此验证不等同于 Apple 分发证书或公证。

收集脚本保存原始源码、固定来源与校验值。版本页的运行组件源码 ZIP 应包含这些文件、构建脚本及说明，与同版本 DMG 放在一起。用户可按原许可替换组件、重建 App；依赖各自许可保留。

实际验收应从只读安装盘或搬移后的 App 出发，使用新资料库，禁止读取开发目录与外部工具，并分别检查联网首次模型准备和离线复用。实际其他 Mac 验收另记，不能用本机隔离结果替代。

当前发行底包固定为 CPython 3.11.15 / python-build-standalone 20260414。打包时会核对真实版本与 BUILD 记录；若开发环境使用其他发行版，可将对应固定底包解压后通过 --python-base 指定。更换发行底包时须一起更新来源、许可材料与版本记录，不能沿用旧的元信息。
