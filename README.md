# 小声哔哔（Voxloom）

简体中文 · [English](README.en.md)

小声哔哔是一款在 macOS 本机运行的中英文语音输入 App。中文系统显示「小声哔哔」，其他语言显示 Voxloom。

## 使用

资源准备完成后，运行 `python3 scripts/package-app.py --external-models` 可生成 `Voxloom.app`。菜单栏使用透明底的波形，颜色随系统调整，深色菜单栏里显示白色。[App 图标源稿](src/business/VoxloomDesktop/App/Resources/AppIcon.svg)

打包参数 `--configuration`（`-c`）接受 `debug` 和 `release`，默认是 `release`。Debug 版使用独立应用名与 Bundle ID。

下载模型时，Voxloom 先访问 Hugging Face。遇到连接重置、服务器错误或文件校验失败，会尝试清单中可用的 ModelScope 和 HF-Mirror 备用地址。同一次模型下载会优先沿用已下载并校验成功的来源。所有新下载的文件都须通过清单中的 SHA-256 校验才会安装。[模型下载清单](scripts/model-downloads.json)

- 先把光标放到目标输入框，再单独按住 Fn（地球键）约 0.18 秒开始录音。松开后补齐尚未转写的音频。启用纠错时，最多再等 3 秒，超时时使用已有草稿。Voxloom 确认焦点仍在原输入框时，会自动发送粘贴请求。目标无法确认或已变化、录音中断或授权不足时，结果保留在草稿中。每轮录音最长 60 秒。
- 也可以用鼠标按住语音条最左侧的声波按钮约 0.18 秒开始录音，松开结束。指针移出按钮后松开也会结束录音。首次使用时可以在辅助功能引导点「稍后」，授权麦克风并等转写模型就绪后即可录音。未开启辅助功能时，转写保留在草稿里，可点「展开」后复制。
- 录音中保持 Fn 按住，再按 E，松开 Fn 后打开草稿编辑器。转写完成后按 Enter 插入到录音开始时的输入框，Shift+Enter 换行。原输入框无法确认时，文字保留在草稿里。保持 Fn 按住再按 Esc 会取消本轮并恢复之前的草稿，松开 Fn 后可重新录音。
- 累计录到约 1 秒且检测到声音时，立即提交首段转写。启动 Voxloom 时，若选用 Qwen3-ASR，App 会在后台加载模型。启用声纹过滤时也会提前加载分离模型。预热无需录音，听写复用已经准备的进程。使用其他识别引擎开始下一轮或退出 Voxloom 时会释放 Qwen 进程。
- 录音中尚未显示文字时，每新增约 0.5 秒音频会立即尝试预览。声纹预览遇到一次错误时，会用后续音频再试一次。松开后仍会处理最终录音。
- 底部语音条显示录音时长、音量、进度和最新一行转写，完整内容可在草稿里查看。齿轮打开设置，点击菜单栏的 App 图标可重新显示语音条。有未插入的草稿时，再按住 Fn 会另起一行追加，随后可以一起手动插入。取消续录会恢复本轮开始前的草稿。发出插入请求后，下一轮从空白草稿开始。
- 点语音条的「展开」可在原语音条上方编辑、复制或清空草稿。在草稿编辑区按 Enter 插入，按 Shift+Enter 换行，按 Esc 清空草稿。目标 App 聚焦时也可以双击 Fn。目标文本有选区时会使用该 App 的标准粘贴行为替换选区。前台 App 在插入前切换时，草稿可再次插入或复制。
- 在展开的草稿编辑区，`⌘C` 复制所选文字，`⌘V` 将剪贴板中的文字粘贴到光标处或替换选区。
- 转录语言默认是中文，可在设置中改为自动或英文。设置也支持选择 Qwen3-ASR 或 Whisper、填写词汇，以及开启默认关闭的 Qwen 纠错。已保存的选项会继续生效。[全量准确率评测](docs/reports/transcription-evaluation-2026-11-23.md)
- 包含声纹分离模型的构建可在设置里开启「只保留我的声音（实验）」，默认关闭。轻声、正常、大声各可录一段 3–8 秒的本人声音，可跟读设置里的中英短句。每段样本可以单独试听、重录或删除。至少录一段即可使用。按住 Fn 时，本地分离新增音频并更新转写预览。松开后用完整录音重新分离并转写，生成可提交的定稿。
- 设置里的「词汇提示」用于手动填写术语、人名和产品名。传给 Qwen3-ASR 的词汇提示上限为 512 UTF-8 字节，Whisper 为 192 字节。
- 启用纠错后，App 在 ASR 模型就绪时下载 Qwen3-4B。设置页显示进度、校验、失败和重试。下载期间可以照常听写。
- 启用纠错后，语音转写或键盘编辑停顿 800 毫秒时触发纠错，持续输入满 3 秒就提交最新一稿。引擎忙时只保留最新一稿，当前任务完成后再运行。模型结果按提交时的字符位置合入当前稿，跳过用户重输或新转写覆盖的位置。下一轮使用合并后的现稿。Voxloom 桌面听写使用单轮局部修改，通用 `QwenTextCorrector` 默认保留复核，可通过 `QwenConfiguration.mode` 选择 `.interactive`。
- 启动时如果还未开启辅助功能，语音条会先引导授权，用于全局快捷键和自动插入。启用或点「稍后」后，点「授权麦克风」或按住说话键都能请求首次麦克风授权。「稍后」仅对本次启动生效。ASR 模型从启动时就在后台下载，麦克风授权成功后，语音条显示下载进度。模型就绪后，再按住说话键即可听写。
- 默认按住 Fn 说话。打开「设置 → 按住说话键 → 更改」可选单键，或用 Control、Option、Command、Shift 组成快捷键，例如 Control + Option 或 Command + Shift + 空格。按住选定的快捷键听写，松开其中任一键结束。
- 在悬浮窗或设置中点「启用辅助功能」，在 macOS「隐私与安全性 → 辅助功能」中允许 Voxloom 使用全局快捷键和自动插入。目标 App 无需逐个授权。

本地检查包含语音条展开和收起、录音与转写反馈、Fn 按住和松开、辅助功能授权状态刷新，以及原生文本控件中的光标插入、选区替换和剪贴板恢复。真机全局快捷键和跨 App 插入需在授权后验收。

本地开发包使用临时签名。重新打包后，如果「辅助功能」里 Voxloom 已开启，语音条却仍显示「启用辅助功能」，请在该列表中重新添加当前的 `Voxloom.app`。若 macOS 提示重新打开 App，按提示操作。

如果 Voxloom 0.1.4 在低于 macOS 26.2 的系统上显示 `engineUnavailable`，可先在「设置 → 转写模型」选择 Whisper Turbo，等模型下载完成后再录音。新构建会为 macOS 14 选择 Qwen 的 MLX 运行库，并在打包时核对其最低系统版本。

## 运行时资源占用

2026-11-23 在 Apple M2 Pro、32 GiB 统一内存、macOS 26.5.1 上采样，间隔约 0.29 秒。待机数据取自运行中的桌面 App，当时 Qwen ASR 模型已加载。推理数据使用 App 随附的 Qwen3-ASR-1.7B 4-bit、Qwen3-4B-Instruct-2507 Q4_K_M 和 4.2 秒普通话样本。其中一个用例加入手动词汇和纠错参考文本，另一个用例省略两项。[双模型测试](src/business/QwenASR/Tests/QwenASRE2ETests.swift)

| 场景 | 内存（中位 / 峰值） | CPU（中位 / 峰值） | 整机 GPU（中位 / 峰值） |
|---|---:|---:|---:|
| 待机 · App 主进程 | 35.6 / 35.6 MiB | 0.0% / 0.1% | — |
| 待机 · App 与已驻留的 ASR 子进程 | 1.92 / 1.92 GiB | 0.0% / 0.1% | 0% / 97% |
| 短样本推理 · ASR 和纠错的模型工作进程 | 1.72 / 2.32 GiB | 93.0% / 185.8% | 80% / 99% |

内存使用 macOS 的 `ri_phys_footprint`。进程树汇总可能重复计入共享页，计入测试进程后，推理整棵进程树的峰值约为 2.35 GiB。CPU 的 100% 对应一个逻辑核。GPU 列是驱动报告的整机 `Device Utilization %`，同时运行的程序都会影响数值。本次采样无法给出 Voxloom 独占的 GPU 使用率。

本次结果对应短样本，长时间听写和 16 GiB 设备的资源表现待测。本机采样记录位于 `.build/reports/desktop-resources.json`。

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
bash scripts/prepare-app.sh --prepare-only  # 下载本地开发和评测所需资源
python3 scripts/prepare-voice-isolation.py --runtime-only
python3 scripts/package-app.py --external-models --voice-isolation
python3 scripts/package-app.py -c debug --external-models --voice-isolation
python3 scripts/check.py                 # Swift 单元、模块、界面集成与覆盖率门槛
python3 scripts/check-python.py          # Python 桥接协议测试与覆盖率
python3 scripts/smoke-qwen.py            # 真实双模型 E2E 与短录音资源采样
python3 scripts/smoke-whisper.py         # 保留的 Whisper API / CLI E2E
```

Qwen 开发资源由 `scripts/prepare-qwen.py` 安装，固定模型 revision、SHA256 和依赖版本。资源存放在 `.runtime/` 与 `models/`。安装模型后，转写、纠错和声纹分离都在本机运行，音频和正文不会上传。原 `voice-input` CLI 仍支持 Whisper 文件转写。

当前验证摘要保存在 [docs/reports/0.3.2](docs/reports/0.3.2/README.md)，完整本地报告在 `.build/reports/`，真实模型 E2E 不计入单元/模块覆盖率。历史首个 Whisper 切片记录保留在 [acceptance-01.md](docs/acceptance-01.md)。资源与模型来源见 [第三方说明](docs/third-party.md)。

[测试与实际覆盖率](docs/testing.md) · [开发规范](AGENTS.md)

### 打包 macOS DMG

PR 合并到 `main` 后，GitHub Actions 自动递增补丁版本号，例如 `v0.1.0` → `v0.1.1`，为合并后的提交创建标签，再构建 Apple Silicon 的 Release DMG 并发布到 **Releases → Assets**。同一提交重跑时沿用已有标签。

也可以在 **Actions → Package Voxloom DMG → Run workflow** 手动打 Release 或 Debug 包。手动打包的产物在 **Artifacts** 最多保留 90 天。

打开 DMG 后，在「Voxloom Installer」窗口里按箭头把 App 拖入「应用程序」。ASR 模型通过 SHA-256 校验后即可听写。开启纠错或人声分离时下载对应的可选模型。设置可查看各模型的下载状态并重试。模型存储在 `~/Library/Application Support/dev.voxloom.app/Models`，后续升级可复用相同版本的模型。

Release 的 Bundle ID 固定为 `dev.voxloom.app`，Debug 固定为 `dev.voxloom.app.debug`。App 使用 ad-hoc 签名，未经 Apple 公证。

在本机打包 Release DMG：

```bash
bash scripts/prepare-app.sh --runtime-only
python3 scripts/prepare-voice-isolation.py --runtime-only
.runtime/qwen-asr-runtime/asr-python/bin/python3.12 -m venv .build/dmg-tools
.build/dmg-tools/bin/python -m pip install -r scripts/dmg/requirements.txt
.build/dmg-tools/bin/python scripts/make-dmg.py --voice-isolation --output .build/distribution/Voxloom-release-arm64.dmg
```
