# Voxloom 本地声纹过滤评测

评测比较输出音频和目标说话者的原音频。测试设备为 Apple M5 Pro、macOS 26.6.2。参考音频只使用目标说话者的录音。

## 数据与口径

- **ASCEND 测试集**覆盖全部 1,315 条原始录音，其中中文 685 条、英文 257 条、中英混说 373 条。保留完整话语，用另一场会话的 3 秒普通话作声纹参考。每条录音与另一说话者的相近时长音频混合，固定随机种子分配 −6、0、+6 dB 的目标声与背景人声能量比。测试集有两位说话者，混合音频由本项目合成。[ASCEND 数据集](https://huggingface.co/datasets/CAiRE/ASCEND)
- **Cocktail Party Mixtures 的 `test-vctk`**覆盖发布的全部 300 条英文混合音频。包含一至四人，部分音频还带混响、背景音乐或噪声。取第一位说话者的前 3 秒作为参考，评分用后 3 秒。[公开混合数据集](https://huggingface.co/datasets/DJRHails/cocktail-party-mixtures)
- **波形指标**使用目标说话者的 SI-SDR 改善量，正值表示滤过后更接近干净目标。另计整段静音，以及输出对另一位说话者的 SI-SDR 高于目标的次数。静音与选错分别计数。英文耗时使用独立运行的 VCTK 测试，每条输入 3 秒。混合评测模拟音量差，真实轻声和大声的发声变化需要继续用麦克风验证。

## ASCEND 全量波形分离

每格依次列出中位 SI-SDR 改善量、静音条数、输出更像另一人的条数。过滤前的原始混音是 0 dB 改善。

| 方案 | 中文 685 条 | 英文 257 条 | 中英混说 373 条 |
| --- | ---: | ---: | ---: |
| VoxLock INT8 CPU | +9.64 dB / 0 / 46 | +10.98 dB / 0 / 10 | +9.91 dB / 0 / 38 |
| MossFormer2 Core ML + CAM++ | −53.63 dB / 366 / 1 | −53.78 dB / 141 / 0 | −4.88 dB / 186 / 0 |
| SepFormer MPS + CAM++ | −59.80 dB / 583 / 1 | −59.94 dB / 242 / 0 | −54.33 dB / 282 / 2 |

VoxLock 在全部 1,315 条的中位改善为 +10.05 dB。目标比背景人声低 6 dB 时，432 条里有 52 条输出更像另一人。目标高 6 dB 时，409 条里有 7 条出现这种情况。

两阶段方案的拒绝门限让许多样本静音。上表反映这一组模型、声纹匹配器和固定门限的组合效果。

## 英文公开混合测试

| 方案 | 80 条两人混合的中位改善 | 80 条静音 / 输出更像另一人 | 全部 300 条静音 | 221 条多人输出更像另一人 | 3 秒音频 p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| MossFormer2 Core ML + CAM++ | +1.93 dB | 27 / 5 | 115 | 18 | 479 ms |
| SepFormer MPS + CAM++ | −48.78 dB | 48 / 3 | 184 | 9 | 332 ms |
| VoxLock INT8 CPU | −0.46 dB | 0 / 26 | 0 | 97 | 328 ms |

两阶段方案统一使用 0.35 的 CAM++ 余弦相似度门限。静音样本保留在中位数计算中。独立冷加载约为 MossFormer2 9.73 秒、SepFormer 2.99 秒、VoxLock 0.19 秒。

在 221 条多人样本上额外测试了目标缺席。模型仍使用同一目标参考，输入改为其余说话者音轨之和。VoxLock 的中位能量衰减为 17.09 dB。92 条衰减达到 20 dB，58 条低于 6 dB。使用 `10 × log10(输入能量 / 输出能量)` 计算衰减。

### 转写前清理弱残音

预览和定稿都会检查分离后的结果。整段输出的归一化 RMS 不超过 0.002，且每个 1.5 秒对齐窗口的输出均比原始输入低超过 30 dB 时，才将结果视为静音。保留通过判定的完整波形。

本轮在 221 条 VCTK 多人样本中减去目标音轨，保留其他说话者以及原有噪声和音乐。新规则将其中 4 条变为静音，旧版 Qwen 会把其中 2 条转出文字。同一分割的 300 条有目标音轨的混合音频和 373 条 ASCEND 混说音频均未触发清零，其中包括 128 条目标比背景低 6 dB 的混说。另一个开发集的较短测试区间出现过有目标语音但分离后变静音的情况。强串音和多人重叠仍受 VoxLock 的分离能力限制。

## 单独声纹匹配

用同一测试集比较 CAM++ 和 ERes2NetV2。每条做一组同人匹配及一组异人匹配，分别使用混合前的目标和干扰音轨。等错误率（EER）越低越好，各语言分别从测试分数计算门限用于描述结果，部署还需要独立校准。

| 语言 | 正、负样本各 | CAM++ EER | ERes2NetV2 EER |
| --- | ---: | ---: | ---: |
| 中文 | 685 | 15.91% | 12.85% |
| 英文 | 257 | 8.56% | 7.78% |
| 中英混说 | 373 | 26.01% | 21.72% |

ERes2NetV2 可作为目标活动检测的候选，例如每 160 ms 输出目标活动概率的 nomo-pvad。希望从重叠处获得独立波形，还需要音频分离模型。[ERes2NetV2 论文](https://www.isca-archive.org/interspeech_2024/chen24l_interspeech.pdf) · [nomo-pvad](https://github.com/tuya/nomo-pvad)

## 另一个可复验的模型

WeSep 2024 发布了 BSRNN + ECAPA 的目标人声提取权重。论文在 Libri2Mix 和 AISHELL2Mix 分别报告 16.18 和 10.18 dB 的绝对 SI-SDR。本次已在 M5 Pro 上用公开权重跑通一次音频输入和输出，完整的 ASCEND 和 VCTK 对照仍待验证。[WeSep 论文](https://www.isca-archive.org/interspeech_2024/wang24fa_interspeech.pdf) · [官方权重说明](https://github.com/wenet-e2e/wesep/tree/wesep_2024)

## 实验 App

Debug App 使用本机 VoxLock INT8。开关默认关闭。轻声、正常和大声样本可分别录入、试听、重录和删除。启用后，按住 Fn 时复用当前录音的分离状态，按新增音频更新预览。释放 Fn 时完整录音走整段分离和转写，再完成草稿或插入。连续给已打包进程发送中文、英文和混说请求，均得到有效 PCM。额外检查了 60 秒输入的输出长度。实体麦克风、全局 Fn 和目标 App 插入需要在用户授权后验收。

仓库的 Swift 回归脚本通过 186 项测试，Python 评测及打包测试通过 8 项。Debug App 通过 `codesign --verify --strict`。

```bash
python3 scripts/prepare-voice-isolation.py
python3 scripts/make-demo.py --product voxloom -c debug --voice-isolation \
  --bundle-id dev.voxloom.app.isolation.debug \
  --output '.build/voice-isolation-app/Voxloom Voice Isolation Debug.app'
```

## 复跑

在已有评测环境内运行以下命令。`ascend-test.parquet` 使用数据集修订 `737e9800ae31be9932ba8464c80366559bd28424`。环境使用 Python 3.12、DuckDB 1.4.1、NumPy 2.2.6、ONNX Runtime 1.24.4、sherpa-onnx 2.0.1、VoxLock 1.2.0、SpeechBrain 1.0.3、PyTorch 和 TorchAudio 2.7.1、Core ML Tools 9.0。

```bash
python scripts/speech-separation/prepare_ascend.py ascend-test.parquet assets/ascend-all.npz
python scripts/speech-separation/benchmark.py --assets assets --dataset assets/ascend-all.npz --model voxlock --backend cpu --out ascend-voxlock.json
python scripts/speech-separation/benchmark.py --assets assets --dataset assets/ascend-all.npz --model mossformer2 --backend accelerated --out ascend-mossformer2.json
python scripts/speech-separation/benchmark.py --assets assets --dataset assets/ascend-all.npz --model sepformer --backend accelerated --out ascend-sepformer.json
python scripts/speech-separation/verify_speakers.py --assets assets --dataset assets/ascend-all.npz
python -m unittest discover -s scripts/speech-separation
```

英文复跑使用数据集文件 `test-vctk.npz` 作为 `--dataset`。权重文件使用以下公开来源。

- `voxlock/enroll.onnx` 和 `voxlock/chunk_int8.onnx` 使用 [VoxLock v2 固定修订](https://huggingface.co/arbazsiddiqui/voxlock/tree/2413b292bc2c337bfc19a9802aaf3e011e68e9c4/onnx/v2)。
- `MossFormer2_SS_16K.mlpackage` 使用 [MossFormer2 Core ML 转换](https://huggingface.co/Moipee/MossFormer2-SS-16K-CoreML)。`sepformer/` 使用 [SpeechBrain 16 kHz SepFormer 权重](https://huggingface.co/speechbrain/sepformer-whamr16k)。
- `campplus.onnx` 和 `eres2netv2.onnx` 分别使用中英文 CAM++ Advanced 与中文 ERes2NetV2 对应的 sherpa-onnx 导出。[3D-Speaker](https://github.com/modelscope/3D-Speaker) · [ONNX 权重](https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models)
