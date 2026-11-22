# Google FLEURS 普通话测试语料

录音及参考文本来自 Google FLEURS 数据集。研究作者为 Alexis Conneau、Min Ma、Simran Khanuja、Yu Zhang、Vera Axelrod、Siddharth Dalmia、Jason Riesa、Clara Rivera 和 Ankur Bapna。[数据集](https://huggingface.co/datasets/google/fleurs) · [研究论文](https://research.google/pubs/fleurs-few-shot-learning-evaluation-of-universal-representations-of-speech/)

本目录使用 `cmn_hans_cn` 配置的 `test` 分集，数据集版本 `3c5cd38623376cb92bc769d5193891b564853276`。Voxloom 选取其中 36 条，重命名并转为 16 kHz 单声道 PCM16 WAV。每条录音保留原句边界，`manifest.json` 记录源文件、句子 ID、源文件 SHA-256 和参考文本。录音和参考文本适用 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)。
