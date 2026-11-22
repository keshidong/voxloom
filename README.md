# voxloom

简体中文 · [English](README.en.md)

voxloom 是一个本地运行的中英文语音输入项目。语音识别、上下文纠错与设备交互通过独立接口组合。

## Voxloom 桌面 App

运行 `python3 scripts/make-demo.py --product voxloom` 可生成 `Voxloom.app`。App 有独立的程序入口和设置，直接使用项目的录音、转写和草稿模块。深绿波形的可编辑源稿随源码保留。[App 图标源稿](src/business/VoxloomDesktop/App/Resources/AppIcon.svg)

- 先把光标放到目标输入框，再单独按住 Fn（地球键）约 0.18 秒开始录音。松开后补齐尚未转写的音频，再等纠错最多 3 秒。已经开始的纠错可以先合入，超时时使用已有草稿。目标仍符合录音开始时的焦点时，Voxloom 自动发送粘贴请求。目标变化、录音中断或授权不足时，结果保留在草稿中。每轮录音最长 60 秒。
- 底部语音条显示录音时长、音量、进度和最新一行转写，完整内容可在草稿里查看。齿轮打开设置，菜单栏波形图标可重新显示语音条。有未插入的草稿时，再按住 Fn 会另起一行追加，随后可以一起手动插入。取消续录会恢复本轮开始前的草稿。发出插入请求后，下一轮从空白草稿开始。
- 点语音条的「草稿」展开完整编辑区，可编辑、复制、清空或试用内置示例。在草稿编辑区按 Enter 插入，按 Shift+Enter 换行。目标 App 聚焦时也可以双击 Fn。目标文本有选区时会使用该 App 的标准粘贴行为替换选区。前台 App 在插入前切换时，草稿可再次插入或复制。
- 设置可选择 Qwen3-ASR 或 Whisper、开启 Qwen 纠错、选择语言和填写词汇。默认在按住 Fn 时读取前台可编辑输入框光标附近的片段，最多 240 个 UTF-16 单位。ASR 用其中的词语做识别提示，纠错将片段作为独立参考。上下文在本机处理，不另存到历史或设置。密码框、只读输入框和读取失败的输入框会直接使用普通听写。此功能可在设置中关闭，新设置从下一次录音生效。
- 语音转写或键盘编辑停顿 800 毫秒时触发纠错，持续输入满 3 秒就提交最新一稿。引擎忙时只保留最新一稿，当前任务完成后再运行。模型结果按提交时的字符位置合入当前稿，跳过用户重输或新转写覆盖的位置。下一轮使用合并后的现稿。Voxloom 桌面听写使用单轮局部修改，通用 `QwenTextCorrector` 默认保留复核，可通过 `QwenConfiguration.mode` 选择 `.interactive`。
- 在悬浮窗或设置中点「启用辅助功能」，在 macOS「隐私与安全性 → 辅助功能」中允许 Voxloom 使用全局 Fn 和自动插入。目标 App 无需逐个授权。麦克风权限在首次录音时申请。「试用示例」使用随附的录音。

本地检查包含语音条展开和收起、录音与转写反馈、Fn 按住和松开、辅助功能授权状态刷新，以及原生文本控件中的光标插入、选区替换和剪贴板恢复。真机全局快捷键和跨 App 插入需在授权后验收。

本地开发包使用临时签名。重新打包后，如果「辅助功能」里 Voxloom 已开启，语音条却仍显示「启用辅助功能」，请在该列表中重新添加当前的 `Voxloom.app`。若 macOS 提示重新打开 App，按提示操作。

## 运行时资源占用

2026-11-23 在 Apple M2 Pro、32 GiB 统一内存、macOS 26.5.1 上采样，间隔约 0.29 秒。待机数据取自运行中的桌面 App，当时 Qwen ASR 模型已加载。推理数据使用 App 随附的 Qwen3-ASR-1.7B 4-bit、Qwen3-4B-Instruct-2507 Q4_K_M 和 4.2 秒普通话样本，运行带输入上下文和不带上下文两个用例。[双模型测试](src/business/QwenASR/Tests/QwenASRE2ETests.swift)

| 场景 | 内存（中位 / 峰值） | CPU（中位 / 峰值） | 整机 GPU（中位 / 峰值） |
|---|---:|---:|---:|
| 待机 · App 主进程 | 35.6 / 35.6 MiB | 0.0% / 0.1% | — |
| 待机 · App 与已驻留的 ASR 子进程 | 1.92 / 1.92 GiB | 0.0% / 0.1% | 0% / 97% |
| 短样本推理 · ASR 和纠错的模型工作进程 | 1.72 / 2.32 GiB | 93.0% / 185.8% | 80% / 99% |

内存使用 macOS 的 `ri_phys_footprint`。进程树汇总可能重复计入共享页，计入测试进程后，推理整棵进程树的峰值约为 2.35 GiB。CPU 的 100% 对应一个逻辑核。GPU 列是驱动报告的整机 `Device Utilization %`，同时运行的程序都会影响数值。本次采样无法给出 Voxloom 独占的 GPU 使用率。

本次结果对应短样本，长时间听写和 16 GiB 设备的资源表现待测。本机采样记录位于 `.build/reports/desktop-resources.json`。

## macOS Demo

保留的 Demo 构建产物为 `voxloom 0.3.2.app`。GitHub 仓库提交源码、测试、文档与复现脚本，模型权重、运行环境和两个 App 构建产物在本机准备。

默认链路为 **Qwen3-ASR-1.7B 4-bit → Qwen3-4B-Instruct-2507 Q4_K_M 纠错**。中文与英文均在本机处理，原始转写和可编辑草稿分别显示、分别复制。窗口前台时单按 Fn 开始录音，草稿未确认时双按 Fn 停止录音并确认。键盘修改可以与转写和纠错同时进行。

语音转写或键盘编辑停顿 0.8 秒或持续变化 3 秒时请求纠错，数字变化提示核对。确认时补齐末段转写并冻结草稿。可关闭纠错，也可切换 Whisper base / tiny / Turbo。交互边界与快捷键见 [桌面草稿说明](docs/demo.md#当前源码的草稿输入)。

本地纠错同时参考原文和带声调的普通话拼音。提示词包含 r/l、t/d、平翘舌和前后鼻音等常见混淆，结合句意和词汇决定是否修改。拼音来自转写和词汇提示，实际发音仍需结合音频评估。

0.3.2 修复纠错引擎提前结束导致的 `invalidResult`，以经过原文匹配校验的局部修改生成候选，有修改时最多再复核一次，补查同一段里的重复指代错误。接口保持不变；详见[纠错修复说明](docs/correction-0.3.2.md)。

这是最长 60 秒录音的周期性重新识别，尚未接入 Qwen 原生流式解码、Watch 或系统输入法上屏。首次加载模型需要等待；模型准确率、AirPods 轻声及中英混说仍需录音集评估。双模型已运行，但 16GB 设备上整个进程树峰值 ≤8GB 的完整验收尚未完成。

[Demo 用法与验证](docs/demo.md) · [测试与实际覆盖率](docs/testing.md) · [开发规范](AGENTS.md)

## 可替换接口

基础层提供 PCM/WAV、识别值模型和纠错提示/结果纯函数；业务层封装设备、模型与进程。单次推理使用 Swift async/await，交错的录音、点击、定时器和返回事件采用 RxSwift。测试就近放在模块内的 `Tests/`。

```swift
let recognizer: any SpeechRecognizer = QwenASRRecognizer(configuration: .init(
    executable: asrRuntime.appendingPathComponent("qwen-asr"),
    model: asrModelDirectory
))
let corrector: any TextCorrecting = QwenTextCorrector(configuration: .init(
    executable: llamaCompletionURL,
    model: correctionModelURL
))
let original = try await recognizer.transcribe(audio, options: .init(
    language: .chinese, context: "图书卡 充值额度 预付费 USD"
))
let candidate = try await corrector.correct(.init(text: original.text, vocabulary: "充值额度 USD"))
// original.text 与 candidate.text 分别保留；candidate.numbersChanged 提示数字变化。
await recognizer.shutdown()
```

`AudioClip` 是 16kHz 单声道 Int16 PCM，最长 60 秒。一个实例同时接受一个请求，重复调用返回 busy；取消 Task 停止对应推理并清理临时文件。Qwen ASR 在会话期间保留一个模型进程，`shutdown()` 等待回收；Whisper 的 shutdown 默认无额外工作。更换实现不改变调用方的音频/文本接口；更换兼容权重只改配置。LLM 超时默认 45 秒，Qwen ASR 默认 90 秒。

词汇提示仅用于术语，不是预设整句答案。候选不能恢复音频中已丢失的信息，也不能据上下文推定百分比。当前数字比较支持阿拉伯数字、十进制和百分号，不是完整事实核验。

## 开发与复现

源码构建要求 Apple Silicon、macOS 14+、Swift 6 工具链与 Python 3。已在 M5 Pro / 48GiB / macOS 26.6.2 / Swift 6.3.2 验证；Intel 和 16GB 设备未验收。Python 3.12.16、MLX Audio 0.6.7 及依赖随 App 打包，用户运行不依赖系统 Python。

```bash
bash scripts/prepare-demo.sh             # 开发者安装固定资源并构建；此步骤联网
python3 scripts/make-demo.py             # 资源齐全时重打包 0.3.2
python3 scripts/make-demo.py --product voxloom  # 打包独立桌面 App
python3 scripts/check.py                 # Swift 单元、模块、界面集成与覆盖率门槛
python3 scripts/check-python.py          # Python 桥接协议测试与覆盖率
python3 scripts/smoke-qwen.py            # 真实双模型 E2E 与短录音资源采样
python3 scripts/smoke-qwen.py --app 'voxloom 0.3.2.app'  # 用打包资源重跑
python3 scripts/smoke-whisper.py         # 保留的 Whisper API / CLI E2E
```

Qwen 安装脚本为 `scripts/prepare-qwen.py`，固定模型 revision、SHA256 和依赖版本；资源安装在 `.runtime/` 与 `models/`，不使用 sudo。运行设置离线模式，不上传音频/正文、不自动下载或回退云端。应用使用本机 ad-hoc 签名，未做其他设备分发公证。原 `voice-input` CLI 保持 Whisper 文件转写能力。

当前验证摘要保存在 [docs/reports/0.3.2](docs/reports/0.3.2/README.md)，完整本地报告在 `.build/reports/`，真实模型 E2E 不计入单元/模块覆盖率。历史首个 Whisper 切片记录保留在 [acceptance-01.md](docs/acceptance-01.md)。资源与模型来源见 [第三方说明](docs/third-party.md)。
