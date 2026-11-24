# 测试标准与覆盖率

日期：2026-11-21。状态：Qwen ASR + Qwen3-4B 录音中纠错已接入 Demo；Swift 与 Python 就近测试、覆盖率门槛和真实模型 E2E 已通过。完整输入法及真实设备验收仍待实施。

本文件是覆盖率数值门槛与报告口径的唯一维护位置。架构与 TDD 规则见 [开发规范](../AGENTS.md)，具体能力见 [输入法方案](input-method-plan.md)。

## 测试体系

| 类型 | 范围 | 实现要求 | 不能代替的验证 |
|---|---|---|---|
| 基础层单元测试 | 每个纯函数模块 | 相同输入产生相同结果；覆盖边界、错误和全部有效/无效状态规则 | 真实传感器识别及外部服务行为 |
| 业务层单元测试 | 单个业务用例的公开行为 | 使用实际基础层，仅替换外部边界；普通流程直接测试，Rx* 流程用虚拟时间验证状态和事件序列 | 模块装配和真实设备行为 |
| 模块测试 | 模块公开契约、业务模块之间及业务层 → 基础层协作 | 内部真实实现组合；外部适配契约测试覆盖数据转换、取消和清理 | 真实跨设备链路及最终输入体验 |
| 自动化 E2E | 应用入口 → 输入编排 → 识别/候选 → 目标输入框 | 使用实际应用构建，通过 UI 自动化检查完整流程；明确哪些外部边界仍为模拟 | 真实 AirPods 收音和真实腕部动作 |
| 真实设备 E2E | AirPods、Watch、必要的手机中转及目标输入设备 | 从实际说话/动作到目标输入框验收；可自动化部分自动执行，实体动作的人工步骤单独记录 | 不能由模拟器或注入事件宣布通过 |

模块测试包含单模块公开契约与多个真实模块的集成，不能只是将单元测试改名。基础层和业务层都必须有对应的模块契约验证。

## 必测行为

下表是用例清单，不表示测试已经存在。每个切片只先实现当前行为的 RED，再实现 GREEN。

| 模块/场景 | 必须覆盖的行为 |
|---|---|
| 纯函数基本契约 | 无输入修改、确定性；空输入、非法值、临界值与有效范围；时间等环境信息显式传入 |
| 手势判定 | 上翻、下翻、中立、阈值两侧、连续样本、动作回程、重复触发、左右手坐标、时间窗口；静止与日常动作不能误当候选切换 |
| 候选选择 | 空列表、单项、多项、首尾不循环、非法索引、候选列表更换、未选择时确认 |
| 输入状态 | 开始、停止、识别完成、空结果、选择、确认、取消、关闭；每个允许和拒绝的状态转换 |
| 多事件协调与 Rx* 时序 | 取消前/后到达、超时同刻事件、乱序、重复；采用 Rx* 时补充重订阅和多个观察者；旧轮次结果不能覆盖新轮次 |
| 错误与恢复 | 权限拒绝、设备不可用、模型加载/推理失败、断连、恢复与再次开始；单次失败不意外终止状态流 |
| 资源生命周期 | 取消/关闭停止对应采集和监听；多次释放安全；订阅释放、共享副作用和重订阅不会泄漏或重复启动 |
| 跨设备协议 | 版本、身份、去重、过期、断连、超时、回执丢失、恢复；送达与执行结果分开 |
| 文字写入 | 只写入当前有效目标、空结果不写入、重复确认不重复上屏、目标焦点改变、写入失败及结果未知 |
| 真实音频 | 实际输入为 AirPods、麦克风权限、开始/停止、耳机断连、路由变化与系统音频中断 |
| 离线模型与识别 | 模型未安装、损坏、加载失败、断网冷启动、重复使用、取消与释放；已安装资源时不依赖外部网络，不上传音频或识别正文，不静默回退云端 |
| 中文、英文与混说 | 中文输入、英文输入、同句中英术语、专名、数字与标点；保持原语言转写；中文 CER、英文 WER 和混说结果分开统计 |
| 真实 Watch | 可见主要控件互点、上下翻、回程误触、左右手、抬腕/放腕、离开 App、设备不支持 |
| 完整 E2E | 开始 → 说话 → 停止 → 识别 → 上下选择 → 确认 → 目标文字正确；取消无上屏、断连无重复、失败后可重新输入 |
| 离线 E2E | 模型安装后断开互联网并重启应用，保留必要的蓝牙/本地设备链路；分别完成中文和英文输入，并执行中英混说场景，核对最终输入框与无音频/正文外传 |
| 双模型资源与性能 | 在 16GB 总内存设备上测量整个输入法及模型/辅助进程，峰值内存不超过 8GB；覆盖冷/热启动、模型切换、长输入、连续多轮、取消、缓存增长、内存压力和退出释放；记录延迟、吞吐与能耗 |

测试方式随实现选择，不要求全部业务测试采用 Rx*。纯函数直接验证输入输出，普通异步流程通过可控依赖验证结果；只有采用 Rx* 编排的流程使用对应语言的虚拟调度器与事件时间线，例如 RxSwift 的 RxTest/TestScheduler。超时测试使用可控时钟或调度器，不使用真实 sleep。真实设备识别准确率与延迟另行测量，不能从虚拟时间测试推导。

本地 STT 模型对比使用同一批人工校对的测试录音和明确的文本归一化规则。分别报告中文 CER、英文 WER、混说与术语正确率，以及首结果/最终结果延迟、冷/热启动、内存和能耗；记录模型、量化和推理引擎版本。模型识别效果与工程代码覆盖率分别验收，不把高代码覆盖率当成识别准确率。公开短录音和小规模双语对照用于建立初步基线。

桌面听写测试验证 ASR 接收用户选择的语言和手动词汇，并按引擎的 UTF-8 字节预算截断词汇。移除自动上下文的依据见[两轮全量评测](reports/asr-context-removal-2026-11-24.md)。

内存验收覆盖整个输入法进程树及模型，不只统计权重或单个主进程，也不以磁盘大小当作运行内存。统一物理内存计量口径，核对共享 CPU/GPU 缓冲，防止漏计或重复计算；同时记录系统内存压力和 swap，不能只凭未崩溃判断可运行。分别报告 STT/LLM 加载、推理、卸载及整体峰值，连续轮次检查是否持续增长；8GB 是验收上限，方案中的 5–7GB 是待实测估算。时延报告区分冷/热状态，并包含 p50/p95；具体芯片和性能阈值仍待确定。

## 普通话、英语和中英混说准确率

FLEURS 普通话和英语测试集以及 ASCEND 混说测试组共 1,965 段录音。全量结果及关闭 Voxloom 默认纠错的依据见[评测报告](reports/transcription-evaluation-2026-11-23.md)。

ASR 阶段用同一份录音清单对比包内 Qwen3-ASR 1.7B 4-bit 和 Whisper large-v3-turbo Q5_0。纠错阶段读取已经保存的 Qwen 原始转写，用包内 Qwen3-4B-Instruct-2507 单轮纠错，以原始转写作为对照。两个评分函数的输入都是参考稿和文本。命令行入口负责调用模型与读写文件。

```bash
bash scripts/transcription-eval/run.sh build
python3 -B scripts/transcription-eval/test_runner.py
evaluation=.build/reports/bilingual-eval
resources=Voxloom.app/Contents/Resources
"$evaluation/transcription-eval" asr /path/to/audio-manifest.json "$resources" "$evaluation/asr.json"
"$evaluation/transcription-eval" correction "$evaluation/asr.json" "$resources" "$evaluation/correction.json"
```

清单的 `clips` 数组逐条提供 `id`、16 kHz 单声道 PCM16 WAV 的 `audio` 路径、`reference` 和 `group`（`zh`、`en`、`mixed`）。两个 ASR 都使用自动语言识别。普通话用 CER，按字符计。英语用 WER，按单词计。中英混说用 MER，把汉字和英文单词作为同一序列里的单位。每组错误率用总编辑次数除以总参考单位数。评分统一大小写、全半角和汉字繁简，通常忽略标点，保留词内撇号和数字内的小数点。数字按原写法计分。纠错报告同时记录每段的改善、持平或变差。ASR 报告保存原始转写，供后续纠错对照。

初步 ASR 对照使用 FLEURS（CC BY 4.0）测试集的 36 段普通话（`cmn_hans_cn`）和 16 段英语（`en_us`），以及 ASCEND（CC BY-SA 4.0）测试集的 16 段自然中英混说。混说组覆盖两位说话者。每次推理的耗时包含模型调用和处理，实际听写的录音、界面和粘贴另行计时。[FLEURS](https://huggingface.co/datasets/google/fleurs) · [ASCEND](https://huggingface.co/datasets/CAiRE/ASCEND)

纠错阶段也支持直接读取开放纠错基准发布的原始转写和参考稿。清单的 `clips` 数组逐条提供 `id`、`group`、`reference` 和 `transcript`。本机使用 ChineseHP（Apache 2.0）的 AISHELL-1 test 和 HyPoradise-v0（MIT）的 LibriSpeech test-other，按样本 ID 的 SHA-256 排序后分别取前 64 条。中文 ID 用 `chinesehp-` 加原始句 ID，英文 ID 用 `hyporadise-ls-other-` 加从零开始的五位行号。每条使用发布方的第一条候选，保留原本正确的样本以观察误改。清单记录数据版本与原文件哈希。[ChineseHP](https://github.com/tzyll/ChineseHP/tree/main/data/aishell-1/test) · [HyPoradise-v0](https://huggingface.co/datasets/PeacefulData/HyPoradise-v0/tree/main/test)

```bash
"$evaluation/transcription-eval" correction-dataset \
  /path/to/transcript-manifest.json "$resources" \
  "$evaluation/open-correction/correction.json"
```

## 覆盖率门槛

以下是开发质量门槛，不是已经达到的实际结果。

| 统计范围 | 行覆盖率门槛 | 额外要求 |
|---|---:|---|
| 基础层整体及每个基础模块 | 100% | 纯函数边界、判定分支、允许/拒绝的状态转换都有有效断言 |
| 业务层整体及每个业务模块 | ≥90% | 成功、失败、取消、超时、重复与释放路径必须覆盖 |
| 全部自有生产代码 | ≥90% | UI 绑定、装配与外部适配也计入，不得默认排除 |
| 当前切片关键状态/决策场景 | 100% | 按已登记场景数统计，独立于代码覆盖率 |
| 当前切片及发布必选 E2E | 100% 通过 | 必须区分自动化、模拟外部边界和真实设备结果；未运行/跳过不计通过 |

- 行覆盖率 = 已执行的生产代码行数 ÷ 可执行的生产代码行数。整体用行数汇总后计算，不能对模块百分比直接求平均。
- 基础层与业务层的行覆盖率门槛由单元和模块测试满足；E2E 产生的覆盖数据单独保存，不用于掩盖下层测试缺口。
- 统计范围包括当前版本全部自有生产代码，未命中的文件按零命中计入，不得只统计测试进程碰到的文件。
- 每个模块分别判定门槛，整体达标不能抵消单模块不达标。报告精确计数，不能通过显示值四舍五入跨过门槛。
- 可排除测试代码、第三方依赖和未改动的工具生成代码；排除项必须登记文件范围和原因。手写错误分支、平台适配和界面编排不能为提高数字随意排除。
- 有可执行生产代码但未执行测试的模块不达标；纯模型无可执行行时标 N/A，不作 100% 统计。当前未建立源码工程也标 N/A。
- 工具支持函数、分支或区域覆盖率时，附原始指标；工具未输出分支覆盖率时标 N/A 并说明原因，禁止用行覆盖率冒充。关键决策场景表仍须全部验证，但其场景通过率不是工具分支覆盖率。
- 高覆盖率不能替代有意义的断言，也不能证明真实设备能力已验证。

## 采集与执行要求

当前是 macOS Swift Package，无 Xcode scheme 或 UI target。测试采用 Swift Testing，位于各源码模块的 `Tests/`，SwiftPM 通过自定义测试 target 引用，生产 target 显式排除。后续应用 UI 建立后使用 XCTest/XCUIAutomation，并记录真实 scheme 与 destination。

```bash
python3 scripts/check.py                 # Swift 单元 + 模块 + 行覆盖率门禁
python3 scripts/check-python.py          # Python 协议测试 + 覆盖率
python3 scripts/smoke-qwen.py            # 真实 Qwen 双模型 E2E
python3 scripts/smoke-qwen.py --app 'voxloom 0.3.2.app'  # 打包资源 E2E
python3 scripts/smoke-whisper.py         # 已安装资源的真实模型 API/CLI E2E
```

`check.py` 先构建带覆盖率插桩的 CLI、Demo 和桌面 App，再运行 Swift 测试。`llvm-profdata` 合并测试和 CLI 子进程数据，`llvm-cov` 导出行覆盖率。原始数据与日志保存在 `.build/reports/`。合并告警、未映射源码和覆盖率不达标都会使检查失败。测试工具脚本不计入应用 Swift 覆盖率。

GitHub Actions 在推送 `main`、创建或更新指向 `main` 的 PR 或手动运行时执行。macOS 15 Runner 构建 Swift 产品，串行运行模块和桌面测试，包括 FLEURS 配对夹具检查，并执行 Python 协议和覆盖率检查。Demo 窗口、桌面 App 生命周期、内置示例和悬浮面板各自使用独立的测试进程。本机可用 `bash scripts/prepare-rx.sh` 安装测试依赖，再运行 `bash scripts/test-swift.sh` 复跑这些 Swift 测试。Swift 覆盖率门槛、真实模型和设备测试仍通过本机命令单独检查。[流水线配置](../.github/workflows/ci.yml)

真实模型 E2E 缺资源时直接失败；独立执行 Swift 测试时，真实资源相关用例有条件启用，出现跳过时不能据此宣称真实模型验收。安装与中文样本获取命令见 [README](../README.md)。

- 开发中运行当前行为及受影响测试；切片完成时运行相关模块与跨层集成。
- 代码集成前运行单元、模块、可自动化 E2E 与覆盖率检查；报告不达标时不得称为切片完成。
- 发布前运行全部必选 E2E 与真实设备回归，记录设备/系统、构建版本和实际外部服务。
- 外部环境缺失时记录受影响场景、原因和已有证据；相应验收保持待验证。
- 仅文档变更执行文档和本地引用检查，不制造代码覆盖率结果。

## 报告要求

每次实现或行为变更的报告至少包含：

1. 代码版本/变更标识、工具链、设备或模拟器、测试配置与执行时间。
2. 实际执行的命令、退出结果及原始报告路径。
3. 单元/模块/E2E 各自的通过、失败、跳过和未执行数量。
4. 每层、每模块、整体的已覆盖行/可执行行、百分比、门槛与结论；工具提供的其他指标另列。
5. 关键状态/决策与 E2E 场景清单、断言结果及证据。
6. 排除范围、原因、尚未验证的硬件或外部依赖，以及已知限制。

实际报告不得只写“测试全部通过”或“覆盖率达标”。不得混合不同源码版本的覆盖数据；不同设备/配置如需合并，应说明合并范围并保留各自报告。

## 当前实际结果

2026-11-21，Demo 0.3.2：Swift 84 个测试函数、19 个套件通过，Python 2 个协议测试通过。逐模块门槛全部通过。真实模型 6 个 Qwen E2E 另跑且未计入覆盖率；App 内打包资源同样通过这 6 个测试，含中文、英文、静音、领域纠错、重复指代、正常人称保留、长文本、提示长度边界与完整 ASR → LLM 链路。两套 GPU 测试顺序运行，推理超时和断言不变。

| 范围 | 已覆盖 / 可执行行 | 行覆盖率 |
|---|---:|---:|
| all (Swift) | 1598 / 1634 | 97.80% |
| business (Swift) | 1264 / 1300 | 97.23% |
| business/Capture (Swift) | 131 / 138 | 94.93% |
| business/CommandLine (Swift) | 50 / 51 | 98.04% |
| business/Correction (Swift) | 123 / 123 | 100.00% |
| business/Desktop (Swift) | 314 / 333 | 94.29% |
| business/Live (Swift) | 125 / 126 | 99.21% |
| business/Process (Swift) | 262 / 266 | 98.50% |
| business/Qwen (Swift) | 100 / 103 | 97.09% |
| business/QwenASR (Swift) | 67 / 68 | 98.53% |
| business/Recognition (Swift) | 4 / 4 | 100.00% |
| business/Whisper (Swift) | 88 / 88 | 100.00% |
| foundation (Swift) | 334 / 334 | 100.00% |
| foundation/Audio (Swift) | 73 / 73 | 100.00% |
| foundation/CLI (Swift) | 37 / 37 | 100.00% |
| foundation/Correction (Swift) | 124 / 124 | 100.00% |
| foundation/Live (Swift) | 92 / 92 | 100.00% |
| foundation/Recognition (Swift) | 8 / 8 | 100.00% |
| QwenASR/Runtime (Python) | 44 / 45 | 97.78% |

Swift 采用 LLVM 可执行行；Python 采用 stdlib trace，分开报告，未混合不同工具计数。分支覆盖率均 N/A。排除 Tests/ 和第三方依赖；AudioError.swift 与 TextCorrector.swift 仅声明，无可执行映射。Python 的 1 行未覆盖为脚本直接入口，真实进程 E2E 另有验证。

Swift 数据：`.build/reports/coverage.md`、`summary.json`、`coverage.json`、`tests.profdata`、`tests.log`；Python：`python-coverage.json`、`python-tests.log`；模型：`qwen-e2e.json`、`qwen-e2e.log`、`qwen-bundled-e2e.json`、`qwen-bundled-e2e.log`。可提交摘要见 [0.3.2 报告](reports/0.3.2/README.md)。短录音通过不代表准确率、真机或 16GB/8GB 内存已验收。UI 与已知限制见 [Demo 验证](demo.md)。

## 工具依据

- [RxSwift 官方仓库](https://github.com/ReactiveX/RxSwift)：Swift 中采用 Rx* 时的实现与测试工具参考，不表示全部业务都使用 RxSwift；具体语言、库和版本随实际工程确定。
- [Apple 测试说明](https://developer.apple.com/documentation/xcode/testing)：单元、集成和 UI 测试的组合及平台测试工具。
- [Apple 代码覆盖率说明](https://developer.apple.com/documentation/xcode/determining-how-much-code-your-tests-cover)：采集、查看覆盖率，以及覆盖率不能替代有效测试的边界。
- [Apple 测试结果说明](https://developer.apple.com/documentation/xcode/running-tests-and-interpreting-results)：结果包、覆盖率和日志的留存与复核。
