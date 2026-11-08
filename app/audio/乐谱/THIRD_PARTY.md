# 乐谱部分的来源与变更

| 组件 | 固定来源 | 许可 |
| --- | --- | --- |
| LV-Chordia 推理代码及随包权重 | https://github.com/openmirlab/lv-chordia/tree/d8ab9ac99bce081bb79065d717f96e2c3b2099c8 | MIT，见 LICENSE-LVChordia；上游 checkpoint manifest 明确列明权重 MIT |
| 原研究 | https://github.com/music-x-lab/ISMIR2019-Large-Vocabulary-Chord-Recognition | 研究作者与版权信息保留于上游代码及许可证 |
| 吉他指法数据 | https://github.com/tombatossals/chords-db/tree/df06fa7b425cf5fd29485ff6591236b3557e3fac | MIT，见 LICENSE-chords-db |
| pydub 0.25.1 | https://github.com/jiaaro/pydub | MIT，见 LICENSE-pydub |

弦外屋保留上述版权与许可。LV-Chordia 相较固定上游只去掉无关 MIDI 导出的初始化注册，避免引入 pretty_midi；权重路径固定为已经校验的本目录，防止意外加载其他环境中的权重。网络结构与权重未修改。随附源码仅额外统一行尾空白与文件末尾空行，Python 语法结构（不含说明文字）前后一致。应用新增的完整上下文苹果加速、省内存分块及新进程重试、进度、取消、来源校验、和弦显示命名、节拍提取和文件生命周期位于 score_job.py。

不随产品引入 ChordMiniApp 的云服务、歌词识别、聊天模型或整个后端；ChordMini 只用于隔离实测。没有复制 EarChords、TabCNN、Chordino、ChordSheetJS 或 Sheet Sage 的实现及权重。训练素材的权利与应用公开分发仍须按实际版本复核，本地测试不能作为公开商业授权审查结论。
