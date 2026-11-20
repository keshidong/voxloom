# 第三方运行资源

资源安装后可离线运行。App 中保存依赖自带的许可证与 metadata；模型使用 Apache-2.0，Whisper、llama.cpp、RxSwift 与 MLX Audio 的许可证随包保留。

| 资源 | 固定版本 / revision | 来源 |
|---|---|---|
| Qwen3-ASR-1.7B 4-bit | 78a389c776a5483b2d0d4ea5494e11012e0d6159 | [MLX 权重](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-4bit)，[原始 Qwen ASR](https://github.com/QwenLM/Qwen3-ASR) |
| Qwen3-4B-Instruct-2507 Q4_K_M | a06e946bb6b655725eafa393f4a9745d460374c9 | [GGUF](https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF) |
| MLX Audio | 0.6.7，完整依赖固定在 qwen-asr-requirements.txt | [源码](https://github.com/Blaizzy/mlx-audio) |
| Python / uv | 3.12.16 / 0.13.9 | [uv 官方](https://github.com/astral-sh/uv) |
| llama.cpp | v1.0.0 | [源码](https://github.com/ggml-org/llama.cpp) |
| Whisper / RxSwift | v1.8.2 / 6.10.2 | [Whisper](https://github.com/ggml-org/whisper.cpp)，[RxSwift](https://github.com/ReactiveX/RxSwift) |

ASR 权重 1,603,081,617 字节，SHA256 `9848eaf7a5c1589c671b35035ac27b72e248dd0c604eacae547e7e403d29db45`；LLM 权重 2,497,281,120 字节，SHA256 `3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597`。这些是磁盘大小，不是运行内存。全部 ASR 配置/tokenizer 文件的哈希在 scripts/qwen-asr-assets.json。

当前没有训练新的联合模型。未来可收集经用户同意保存的音频/人工文本对，先对 ASR 做领域评测与微调。Whisper 编码器接适配层与 Qwen 解码器在架构上可行，[Qwen2-Audio 报告](https://arxiv.org/html/2407.10759v1)有相近先例；这与当前串联两个离线模型是不同开发范围。
