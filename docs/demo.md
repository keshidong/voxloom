# 桌面语音输入 Demo 0.3.2

日期：2026-11-21。交付：本机构建产物 `voxloom 0.3.2.app`，Apple Silicon / macOS 14+。默认 Qwen3-ASR-1.7B 4-bit + Qwen3-4B-Instruct-2507 Q4_K_M，应用包含 Python/MLX、两个模型、Whisper 替换引擎与中英文公开样本；运行时无需下载或终端。

## 当前源码的草稿输入

窗口在前台且没有待确认草稿时，单按 **Fn** 开始录音。草稿打开时，两次新的 Fn 按下间隔不超过 350 毫秒可确认。窗口也提供「开始录音」「确认草稿」按钮。原始转写供对照，下方草稿可以用键盘编辑。

- 转写或键盘编辑稳定 800 毫秒，或从尚未处理的首次变化起持续变化 3 秒，会提交本地纠错请求。引擎忙时保留正在运行的请求，只排队最新草稿。纠错按原位置合入，用户后续编辑过的位置优先保留。
- 确认会冻结键盘编辑并取消纠错，采集中的录音会补齐最后一次转写后生成确认结果。确认后的文字可用「复制草稿」获取，当前交付目标是 App 内草稿。
- 快捷键依赖系统将 Fn 事件交给前台窗口。如果 Fn 被系统设为切换输入法或启动听写，可使用窗口按钮。
- 合并以识别快照中的字符差异为依据。遇到无法可靠对齐的重叠内容时保留键盘编辑。App 保留原始转写，便于对照确认。

草稿文本合并和 Fn 手势位于 `SpeechFoundation`。录音、草稿与纠错的协调位于 `SpeechInput`，由 `DictationSession` 提供状态和确认文本。同模块的虚拟时间测试覆盖纠错窗口与排队规则，桌面集成测试通过模拟 Fn 与键盘编辑验证确认路径。

### 拼音辅助纠错

纠错模块在本机将含汉字的转写和词汇提示转换为带声调的普通话拼音，随原文作为独立字段提供给本地模型。常见混淆包括 r/l、n/l、t/d、f/h、zh/z、ch/c、sh/s（如 shi/si）和 an/ang、en/eng、in/ing。不同话题共享同一套判断依据。模型结合词汇、局部搭配、读音和指代，只改有证据的片段。具体错词和预期结果记录在测试用例中。

正常的中英文输出仍通过已有的原文匹配校验。拼音是根据文字推算的，实际口音和多音字读法要结合音频或语境评估。普通输入仍使用 4096 或 8192 token 上下文，含大量拼音的请求可使用 16384 token。正文和词汇提示的字节限制以及纠错总时限沿用现有接口。

2026-11-22 在 Apple Silicon、macOS 26.5.1、Swift 6.3.3 上验证。运行 `python3 scripts/check.py`，94 项测试通过，行覆盖率为 1950/1989（98.04%），各模块达标。用 `python3 scripts/smoke-qwen.py --app 'voxloom 拼音辅助.app'` 验证 App 内引擎和权重，7 项真实模型测试通过。合成样例覆盖语境明确的近音纠错、正常词保留、数字和既有的指代回归。真实口音的识别纠错增益待用带参考稿的录音评估。

提示词、相似读音规则和上下文预算的 RED/GREEN 日志位于 `.build/reports/`，文件名前缀为 `pinyin-prompt`、`pinyin-confusions`、`pinyin-budget`。打包日志为 `pinyin-package-final.log`，真实模型日志为 `qwen-bundled-e2e.log`。复跑覆盖率前，修复了进程测试夹具提前发布空 PID 文件的竞态。

### 录音配对回归

离线语料切片最长 45 秒，邻段约重叠 5 秒。有带时间戳的参考字幕时，切点优先选在字幕边界，末段可更短。每个窗口保存同一时段的参考文字。信号相同的重叠部分可以用来观察边界效果，跨窗口汇总时会重复计入。Demo 的 `AudioClip` 仍支持单次最长 60 秒。

把 16 kHz 单声道 PCM16 WAV 和清单放在同一个目录。清单的 `clips` 数组中，每项包含 WAV 文件名和参考文本。可选的 `language` 接受 `auto`、`zh`、`en`，省略时自动识别。可选的 `vocabulary` 提供纠错词汇。

```json
{"clips":[{"audio":"slice-0001.wav","reference":"请打印三份。","language":"zh","vocabulary":"打印"}]}
```

仓库自带 36 段 Google FLEURS 普通话测试集录音和参考文本，共约 384 秒。每段保留自然句长，范围 5.04–18.44 秒。常规测试验证每条参考都有可解码的音频。清单随附数据集版本、原文件和句子 ID。[来源与许可](../src/business/QwenASR/Tests/Fixtures/FLEURS/ATTRIBUTION.md)

```bash
bash scripts/swift-command.sh test --filter CorrectionCorpusTests
VOXLOOM_CORRECTION_CORPUS="$PWD/src/business/QwenASR/Tests/Fixtures/FLEURS/manifest.json" \
  bash scripts/swift-command.sh test --filter QwenCorrectionCorpusE2ETests
```

本机可选语料位于 `.runtime/correction-corpora/bilibili/`，该目录由 Git 忽略。B 站视频 `BV1NS4t6oEXQ` 的原声音轨与 458 条中文字幕配成 23 个窗口，每段 42.56–44.95 秒。相邻窗口约重叠 5 秒。`sample-manifest.json` 可用于快速跑其中 4 段。[视频来源](https://www.bilibili.com/video/BV1NS4t6oEXQ/)

```bash
VOXLOOM_CORRECTION_CORPUS="$PWD/.runtime/correction-corpora/bilibili/manifest.json" \
  bash scripts/swift-command.sh test --filter QwenCorrectionCorpusE2ETests
```

测试用同一份参考比较 ASR 原文和纠错候选，只输出字符编辑距离和计数。统计忽略标点、空格、大小写和全半角差异，另报数字串发生改动的窗口数。视频的 AI 字幕可作为独立参考，字符分数仍会受字幕错误和数字写法影响。合成语料使用预先编写的原稿，口误模拟样例也保留实际朗读稿以便核对。

提示词要求保留切片两端的残句，并在依据不足时照录人名、型号和代码标识。配送是检验通用指代判断的回归场景，覆盖同段同时描述送货和接送人。

本次基线使用本机 Qwen ASR 和 Qwen3 纠错模型。FLEURS 的 1257 个参考字符中，原始转写有 125 处差异，纠错后有 132 处，36 段中有 4 段变差。B 站样本的 4 个窗口共 996 个参考字符，纠错前后均有 106 处差异。逐段统计见 `.build/reports/fleurs-corpus-e2e.log` 和 `.build/reports/bilibili-corpus-sample-e2e.log`。

上一版提示词的历史结果保存在 `.build/paired-correction/`。23 个视频窗口的字符差异为 632 → 698。四段 45 秒合成样例为 17 → 15，更早一版提示词为 16。

历史 FLEURS 对照每三段取首段，组合成固定的 12 段。在这 12 段上，原始转写为 65 处字符差异，旧提示词纠错后为 71 处，通用提示词纠错后为 68 处。两版纠错使用相同的 ASR 输出。两条提示词契约的 RED/GREEN 记录见 `.build/general-correction/prompt-red.log` 和 `prompt-green.log`。当时 99 项项目测试通过，行覆盖率 98.03%。真实 Qwen 冒烟测试通过 5 项，近音连错和配送指代两项仍有误改或漏改。对照结果见 `.build/general-correction/prompt-selected-ab.log` 和 `.build/reports/qwen-bundled-e2e.log`。

### 草稿版验证记录

2026-11-22 在 Apple Silicon、macOS 26.5.1、Swift 6.3.3 上验证。运行 `python3 scripts/check.py`，90 项测试通过，整体行覆盖率 1920/1959（98.01%），基础层 445/445，草稿业务模块 110/110，所有模块达标。关键 RED/GREEN 记录在 `.build/reports/`，文件名前缀为 `draft-timing`、`draft-merge`、`draft-correction`、`draft-queue`、`draft-confirmation`、`fn-shortcut` 和 `draft-ui`。

本机通过 `python3 scripts/make-demo.py --output 'voxloom 草稿版.app' --bundle-id dev.voxloom.draft-preview` 打包并启动。运行 `python3 scripts/smoke-qwen.py --app 'voxloom 草稿版.app'`，使用 App 内引擎和模型的 6 项测试通过。模型结果见 `.build/reports/qwen-bundled-e2e.json`。物理 Fn 键和真机麦克风流程待实测。

## 0.3.2 使用记录

1. 双击打开，默认中文；英文可选 English，也支持自动语言。
2. 点击“开始录音”并允许麦克风访问。使用系统默认输入设备，AirPods 请先在系统声音设置中选中。
3. 上方显示原始转写，下方显示可编辑的纠错候选，各自独立复制。
4. 词汇提示可填产品名、术语，例如“图书卡 充值额度 预付费 USD”；不需要填完整预期句子。
5. 停止后补齐末段；可用新词汇/模型重识别同一录音。最长 60 秒，也可先“试用示例”。

纠错默认开启，文字稳定 800 毫秒或持续更新 3 秒时请求 LLM，录音中即可出现候选。上一轮仍在运行时只排队最新草稿，取消或清空会取消纠错。数字、金额及百分比始终需核对；检测到阿拉伯数字序列变化时明确提示。LLM 失败保留原始文字，不自动上屏。

0.3.2 修复短句纠错偶发提前结束和同段重复指代漏改：模型输出局部修改，程序匹配原文后应用；有实际修改时再复核一次，两轮共用默认 45 秒预算。纠错仍是可编辑候选，模型可能漏改或误改。根因、边界与回归见[修复说明](correction-0.3.2.md)。

当前源码在录到 1 秒并检测到声音后立即提交首段转写。随后约每 500 毫秒检查录音，至少新增 0.5 秒的音频才再次提交。推理串行，忙时只保留最新完整录音，采用有界音频的周期性重新识别。Demo 的 Qwen ASR 模型进程在录音会话内常驻，Voxloom 桌面 App 在连续录音间复用该进程。首次加载和编译需要等待。下一次录音选择其他引擎时回收旧进程，退出时取消采集与推理并等待进程回收。

Qwen 路径使用 MLX/Metal，“Whisper / 纠错 GPU”控制 Whisper 和 LLM 的 GPU 参数。切换 Whisper 时保留 Silero VAD 与 Turbo flash attention；Qwen 目前仅过滤数字全零静音，环境噪声不保证无误识别。轻声、AirPods、混说、数字和领域语义需要实际录音评测。没有接 Watch 或系统输入法。

## 实际验证

- Swift 单元、模块和 AppKit 控件集成：84 个测试函数 / 19 套件，0 失败；整体 1598/1634 = 97.80%，基础层 334/334 = 100%，各业务模块 ≥90%。真实模型 E2E 排除在该覆盖率之外。
- Python 桥接协议：2 个测试通过，44/45 = 97.78% 行覆盖率；MLX 仅在外部边界替换。覆盖加载失败、坏请求、词汇/语言传递、连续请求与错误后恢复。
- 真实 Qwen E2E：6 个测试 / 2 套件，0 失败/跳过。包含中文、英文、全零静音、领域词、同段重复指代、正常人称保留、长文本和多种提示长度，以及 ASR → LLM 完整接口链路。另用 **App 内**两个引擎、权重、Python 和音频样本重跑相同 6 个测试，全部通过。GPU 套件顺序运行，避免无关测试争抢资源；推理时限不变。用户反馈的两种短句版本另做私有回归并通过，正文未收录到源码或报告。
- UI 模块测试明确验证了仍在 recording 状态时显示纠错候选、数字提示、复制、关闭纠错、取消后不重新纠错，以及旧结果隔离。时间组合使用 HistoricalScheduler。
- 历史 0.3 已观察到实际录音生成转写与候选，0.3.1 已观察准备就绪窗口；当时麦克风标签为 MacBook Pro / 48000Hz，不能据此宣称 AirPods 通过。0.3.2 另存为独立应用并完成签名和打包资源回归，未覆盖旧窗口；本轮未通过 UI 自动化验证实际麦克风录音。
- 本次本机为 M5 Pro / 48GiB / macOS 26.6.2，源码及打包资源的双模型 E2E 采样峰值均约 2.40 GiB。口径为每约 100ms 汇总测试进程树 Darwin `ri_phys_footprint`；共享映射可能重复计数，干净的文件映射与内存压力需另外核对。这不是 16GB 设备上 ≤8GB 的最终验收，也不是长时间使用或能耗结论。原始摘要见 [0.3.2 报告](reports/0.3.2/README.md)。

公开中文样本约 4.2 秒，一次初始 Python 运行加载约 14.9 秒、首次转写约 3.16 秒，随后英文约 0.34 秒；其他轮次受缓存影响。这些是单次开发观测，未形成 p50/p95，也不能据此承诺 AirPods 实时体验或准确率。

有效 RED/GREEN 记录包括 `.build/asr-provider-red.log`、`qwen-ui-red.log`、`qwen-recording-ui-red.log`、`correction-cancel-ui-red.log`、`asr-silence-red.log`、`correction-replacement-red.log`；GREEN 与最终原始结果在 `.build/reports/`。部分适配与时序实现早于新增回归测试，未宣称全部改动都经历了有效 RED；编译/下载问题不算 RED。

## 构建与资源

开发者执行 `bash scripts/prepare-demo.sh` 安装并构建；已备资源时 `python3 scripts/make-demo.py`。只在安装步骤联网，应用离线模式不上传音频/正文。打包解析运行时目录链接；模型硬链接有独立目录项，移除工作区模型路径不影响 App 内文件。Python/MLX 全部随 App 复制，进程不依赖工作区或系统 Python。

应用为本机 ad-hoc 签名，未公证分发。固定版本、模型来源、SHA256 与许可证见[第三方说明](third-party.md)。工程覆盖率见[测试标准](testing.md)。整机主动断网冷启动、16GB/8GB 预算、长录音连续多轮与真机 AirPods/Watch 验收保持待完成。
