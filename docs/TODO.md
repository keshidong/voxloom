# Voxloom 待办

- [ ] **接入 Qwen3-Omni 本地音频纠错。** 先由 Qwen3-ASR 生成初稿，再用 Omni 结合录音和已有前文复核。复核失败或取消时保留初稿。用同一批录音和初稿对照无前文与真实前文，分别记录 MER、耗时中位数和 P95，再验证桌面端的冷启动与内存开销。 [ASCEND 评测](reports/qwen3-omni-correction-2026-11-27.md)
