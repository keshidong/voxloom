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

独立运行 Whisper.cpp 的 Silero v5.1.2 做对照。阈值 0.5、最短语音 100 毫秒时，62 个真实噪声片段全部判为无人声，原始语音无新增拦截，幅值降至 1/8 的语音有 6 条新增拦截。检测前按 RMS 0.03 计算增益，最多放大 16 倍并限制归一化峰值不超过 0.98。这 6 条恢复放行，噪声片段依然全部判为无人声。结果来自离线对照，App 当前的 Qwen 路径采用上表的平稳底噪规则。突发噪声仍可能出现误转写，现场麦克风和蓝牙链路待实测。[Whisper.cpp 1.8.2 的 VAD 示例](https://github.com/ggml-org/whisper.cpp/tree/v1.8.2/examples/vad-speech-segments)

## 回归命令

普通 Swift 测试包含合成嗡声、风扇和宽带噪声，离线运行即可。旧实现对三类均尝试启动识别引擎，新规则返回空结果。

```bash
bash scripts/swift-command.sh test --no-parallel --filter QwenASRRecognizerTests

python3 scripts/prepare-qwen-noise-fixtures.py
fixtures="$PWD/.build/reports/qwen-noise-fixtures"
say -v Meijia --file-format=WAVE --data-format=LEI16@16000 -o "$fixtures/short-ack.wav" '嗯。'
VOXLOOM_QWEN_NOISE_FIXTURES="$fixtures" \
VOXLOOM_QWEN_SHORT_ACK_WAV="$fixtures/short-ack.wav" \
bash scripts/swift-command.sh test --no-parallel \
  --filter 'realBackgroundNoiseDoesNotRegainFalseTranscripts|realQwenKeepsASpokenShortAcknowledgement|realResidentModelTranscribesChineseEnglishAndSilenceViaPublicInterface'
```

真实推理复用项目现有的本地 Qwen 运行时和权重。已有全量语音目录时，可通过 `VOXLOOM_QWEN_SPEECH_FIXTURES` 指向那 1,965 个 16 kHz PCM16 WAV，运行 `backgroundGateKeepsTheFullPublicSpeechCorpus` 检查每个原本放行的文件。
