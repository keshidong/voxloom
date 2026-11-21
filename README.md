# voxloom

voxloom 是一个本地运行的中英文语音输入项目：语音识别、上下文纠错与设备交互通过独立接口组合。当前提供 macOS Demo，后续接入手势控制与系统输入法。

本机构建产物为 `voxloom 0.3.2.app`，双击即可录音；AirPods 可设为系统默认输入设备。GitHub 仓库提交源码、测试、文档与复现脚本，模型权重、运行环境和 App 构建产物通过下方命令在本机准备。

默认链路：**Qwen3-ASR-1.7B 4-bit → Qwen3-4B-Instruct-2507 Q4_K_M 纠错**。中文与英文均在本机处理，录音中逐段显示原始转写；文字稳定约 0.8 秒或持续更新约 3 秒时请求纠错，停止后补齐末段。原始转写与可编辑候选分别显示、分别复制；数字变化提示核对。可关闭纠错，也可切换 Whisper base / tiny / Turbo。

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
python3 scripts/check.py                 # Swift 单元、模块、界面集成与覆盖率门槛
python3 scripts/check-python.py          # Python 桥接协议测试与覆盖率
python3 scripts/smoke-qwen.py            # 真实双模型 E2E 与短录音资源采样
python3 scripts/smoke-qwen.py --app 'voxloom 0.3.2.app'  # 用打包资源重跑
python3 scripts/smoke-whisper.py         # 保留的 Whisper API / CLI E2E
```

Qwen 安装脚本为 `scripts/prepare-qwen.py`，固定模型 revision、SHA256 和依赖版本；资源安装在 `.runtime/` 与 `models/`，不使用 sudo。运行设置离线模式，不上传音频/正文、不自动下载或回退云端。应用使用本机 ad-hoc 签名，未做其他设备分发公证。原 `voice-input` CLI 保持 Whisper 文件转写能力。

当前验证摘要保存在 [docs/reports/0.3.2](docs/reports/0.3.2/README.md)，完整本地报告在 `.build/reports/`，真实模型 E2E 不计入单元/模块覆盖率。历史首个 Whisper 切片记录保留在 [acceptance-01.md](docs/acceptance-01.md)。资源与模型来源见 [第三方说明](docs/third-party.md)。
