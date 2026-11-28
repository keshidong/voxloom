# 第三方运行资源

资源安装后可离线运行。App 中保存依赖自带的许可证与 metadata；模型使用 Apache-2.0，Whisper、llama.cpp、RxSwift 与 MLX Audio 的许可证随包保留。

| 资源 | 固定版本 / revision | 来源 |
|---|---|---|
| Qwen3-ASR-1.7B 4-bit | 78a389c776a5483b2d0d4ea5494e11012e0d6159 | [MLX 权重](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-4bit)，[原始 Qwen ASR](https://github.com/QwenLM/Qwen3-ASR) |
| Qwen3-4B-Instruct-2507 Q4_K_M | a06e946bb6b655725eafa393f4a9745d460374c9 | [GGUF](https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF) |
| Qwen3-Omni-30B-A3B-Instruct Q4_K_M 与 Q8_0 音频投影 | 6e35a28f4a19b18730f8949b0c579c6429649ab8 | [GGUF](https://huggingface.co/ggml-org/Qwen3-Omni-30B-A3B-Instruct-GGUF/tree/6e35a28f4a19b18730f8949b0c579c6429649ab8) |
| MLX Audio | 0.6.7，完整依赖固定在 qwen-asr-requirements.txt | [源码](https://github.com/Blaizzy/mlx-audio) |
| Python / uv | 3.12.16 / 0.13.9 | [uv 官方](https://github.com/astral-sh/uv) |
| llama.cpp | v1.0.0 | [源码](https://github.com/ggml-org/llama.cpp) |
| Whisper / RxSwift | v1.8.2 / 6.10.2 | [Whisper](https://github.com/ggml-org/whisper.cpp)，[RxSwift](https://github.com/ReactiveX/RxSwift) |

ASR 权重为 1,603,081,617 字节，LLM 权重为 2,497,281,120 字节。模型、配置文件的下载地址、磁盘大小和 SHA-256 记录在清单里。每个文件的 `url` 是主地址，`fallbackURLs` 是可选的有序备用地址。旧清单省略该字段时只使用主地址。所有来源共用同一个 `sha256`，安装目录也按内容校验值确定，增加来源后仍可使用现有缓存。[模型下载清单](../scripts/model-downloads.json)

当前没有训练新的联合模型。未来可收集经用户同意保存的音频/人工文本对，先对 ASR 做领域评测与微调。Whisper 编码器接适配层与 Qwen 解码器在架构上可行，[Qwen2-Audio 报告](https://arxiv.org/html/2407.10759v1)有相近先例；这与当前串联两个离线模型是不同开发范围。
