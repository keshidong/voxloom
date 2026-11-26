# Qwen3-ASR 无人声误转写回归

用本机 Qwen3-ASR 1.7B 4-bit、中文模式、空词汇提示复现。两个常见输入是持续空调底噪和低频嗡声。旧规则允许连续 60 毫秒超过低电平门槛的音频进入解码。全零输入会被 App 拦下，直接交给模型时仍可能生成「嗯。」。

新增的底噪判断只检查音频。对至少 1 秒的录音比较 200 毫秒窗口去除直流成分后的平均功率。各窗口均处在低电平、最高和最低 RMS 相差不超过 1.5 倍时，判为平稳底噪并返回空结果。正常解码继续使用原录音。

## 回放结果

| 测试集 | 旧规则留下的误转写 | 平稳底噪规则留下的误转写 |
| --- | ---: | ---: |
| 通过旧门槛的合成低频嗡声、风扇底噪和宽带噪声 | 13 / 13 | 0 / 13 |
| MS-SNSD 的 31 个真实噪声文件，每个文件取中间 2 秒并测试两档音量 | 62 / 62 | 44 / 62 |
| 上一组中的空调噪声 | 20 / 20 | 2 / 20 |
| 上述真实噪声中只转写为「嗯」的片段 | 46 / 62 | 35 / 62 |

公开噪声取自 `noise_test` 的空调、复印机、咀嚼、关门、键盘和吸尘器六类，保留这些类别全部 31 个文件。两档电平为 RMS 0.004 和 0.012。公开样本由脚本按固定版本下载。[MS-SNSD 固定版本](https://github.com/microsoft/MS-SNSD/tree/fe61c4ba0d9ac8dd7e23d719cc79f8947e1dc742/noise_test)

| 公开语音门槛检查 | 旧规则通过 | 新规则额外拦截 |
| --- | ---: | ---: |
| 1,965 条原始录音 | 1,950 | 0 |
| 同一批录音的幅值降至 1/8 | 1,531 | 0 |

共 945 条普通话、647 条英语和 373 条中英文混说。表中比较解码前的放行决定。真实模型另外复跑了中英文、幅值降至 1/8 的普通话及约 0.29 秒的合成发声「嗯。」，这些正例仍可转写。[FLEURS](https://huggingface.co/datasets/google/fleurs) · [ASCEND](https://huggingface.co/datasets/CAiRE/ASCEND)

## 接入 Silero 后的同批 A/B

| MS-SNSD 回放 | 平稳底噪规则 | 平稳底噪规则加 Silero |
| --- | ---: | ---: |
| RMS 0.004，31 个噪声片段 | 22 / 31 误转写 | 0 / 31 误转写 |
| RMS 0.012，同一批 31 个片段 | 22 / 31 误转写 | 0 / 31 误转写 |
| 合计 | 44 / 62 误转写 | 0 / 62 误转写 |

用同一个 Qwen 模型跑完整识别接口。检测判为无人声的录音直接返回空文本。正常普通话、幅值降至 1/8 的普通话、英语和约 0.29 秒的短「嗯。」均通过真实 Qwen 回归。

Silero v5.1.2 使用 0.5 判定阈值和 100 毫秒最短语音。检测用的 PCM16 副本以 RMS 0.03 为目标增益，最多放大 16 倍，同时限制放大后的峰值不超过 0.98。Qwen 解码使用原录音。全量 1,965 条公开录音再次跑相同参数的检测。原始音量下通过旧门槛的 1,950 条和幅值降至 1/8 后通过旧门槛的 1,531 条均无新增拦截。未经增益调整的 Silero 对照组会额外拦掉 6 条低音量语音。[Whisper.cpp 1.8.2 的 VAD 示例](https://github.com/ggml-org/whisper.cpp/tree/v1.8.2/examples/vad-speech-segments)

桌面 App 将 Silero 权重作为独立的下载项处理。Qwen 权重就绪后自动下载约 885 KB 的检测权重，原有的 Qwen 权重缓存继续使用。下载中或检测工具出错时，识别沿用平稳底噪规则。录音者现场的麦克风和蓝牙链路仍待复测。

本机 Release 构建每种时长交替测量 20 次。固定识别工作进程的开销后，1 秒和 4.2 秒语音的检测增量中位数分别为 47.9 和 53.7 毫秒，p95 分别为 56.5 和 62.2 毫秒。一个 2 秒键盘噪声样本返回空文本的中位数为 50.3 毫秒，p95 为 55.4 毫秒。

## 常驻语音检测进程

Voxloom 在 Qwen 模型预热时并行加载本地 Silero。后续录音在同一辅助进程中逐段检测，使用同一份权重和检测参数。分离前的音量检查用于跳过明显静音，分离后的 Silero 用于判断输出中是否还有语音。

本机用同一个 1.5 秒公开语音前缀分别测 40 次。每段启动辅助进程时，检测耗时中位数为 40.45 毫秒，最长为 4,950 毫秒。常驻进程就绪后，中位数为 1.83 毫秒，最长为 4.59 毫秒。这些数字只计检测请求，音频采集、声纹分离、Qwen 解码和进程预热另计。

## 回归命令

普通 Swift 测试包含合成嗡声、风扇和宽带噪声，离线运行即可。旧实现对三类均尝试启动识别引擎，新规则返回空结果。

```bash
bash scripts/swift-command.sh test --no-parallel --filter QwenASRRecognizerTests

bash scripts/prepare-whisper.sh silero-v5.1.2
python3 -B scripts/vad-worker/test_worker.py
python3 scripts/prepare-qwen-noise-fixtures.py
fixtures="$PWD/.build/reports/qwen-noise-fixtures"
say -v Meijia --file-format=WAVE --data-format=LEI16@16000 -o "$fixtures/short-ack.wav" '嗯。'
VOXLOOM_QWEN_NOISE_FIXTURES="$fixtures" \
VOXLOOM_QWEN_SHORT_ACK_WAV="$fixtures/short-ack.wav" \
bash scripts/swift-command.sh test --no-parallel \
  --filter 'realBackgroundNoiseDoesNotRegainFalseTranscripts|realQwenKeepsASpokenShortAcknowledgement|realResidentModelTranscribesChineseEnglishAndSilenceViaPublicInterface'
```

真实推理复用项目现有的本地 Qwen 运行时和权重。已有全量语音目录时，可通过 `VOXLOOM_QWEN_SPEECH_FIXTURES` 指向那 1,965 个 16 kHz PCM16 WAV，运行 `backgroundGateKeepsTheFullPublicSpeechCorpus` 检查每个原本放行的文件。

## 录屏里的环境底噪和点击声

将同一录屏的音轨转换为 16 kHz、单声道 PCM16。25.80–27.05 秒避开明显点击声，5.90–7.90 秒保留点击声。两个片段通过原有的能量门槛和增益后的 Silero，Qwen 在自动语言且词汇提示为空时均输出「嗯。」。

检测输入以 20 毫秒为一帧。按帧功率的第 20 百分位估计底噪，只有 100 毫秒内至少 3 帧的 RMS 超过底噪的 2.5 倍，才应用原来的增益。Silero 对其余片段使用原量级，Qwen 仍使用原录音。这个条件可保留长静音里短促的发声，并防止一个瞬时峰值把整段底噪抬高。

| A/B 数据 | 原增益通过语音检测 | 修改后通过语音检测 |
| --- | ---: | ---: |
| 录屏 27.2 秒前、通过原能量门槛的 1,328 个重叠窗口 | 576 | 0 |
| 1,965 段公开语音，原音量 | 1,950 | 1,950 |
| 同一批公开语音，幅值降至 1/8 | 1,531 | 1,531 |

录屏窗口长 0.65–5 秒，每 100 毫秒移动一次。公开语音逐条比较放行决定，普通话、英语和中英文混说三组均无变化。通过真实 Qwen 接口回放，两个原始误转写片段及 62 个 MS-SNSD 噪声片段均返回空文本，约 0.29 秒的发声「嗯」仍可识别。

回放音频留在本地。将两个切片命名为 `room-tone.wav`、`near-click.wav`，放在同一目录运行下列测试。普通模块测试另有合成底噪加点击声的用例。

```bash
VOXLOOM_QWEN_ROOM_TONE_FIXTURES=/path/to/local/replay \
bash scripts/swift-command.sh test -c release --no-parallel --filter realRoomToneDoesNotProduceATranscript
```
