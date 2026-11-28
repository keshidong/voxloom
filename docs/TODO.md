# Voxloom 待办

- [x] **接入 Qwen3-Omni 本地音频复核。** 先由 ASR 生成初稿，再用 Omni 结合录音、Voxloom 已有草稿和开始听写时的目标 App 信息复核。失败或取消时保留初稿。
- [ ] **验证 Omni 前文收益和桌面资源开销。** 用同一批录音和初稿对照无前文与真实前文，记录 MER、耗时中位数和 P95。测量桌面端多次冷启动与峰值内存。 [ASCEND 评测](reports/qwen3-omni-correction-2026-11-27.md)
