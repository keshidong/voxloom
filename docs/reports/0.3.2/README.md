# voxloom 0.3.2 验证摘要

2026-11-21，本机 M5 Pro / 48GiB / macOS 26.6.2 / Swift 6.3.2。变更标识：本地纠错预填充修复、局部修改校验和有界复核。本目录与该修复同一次提交保存，不包含录音、私有反馈正文、模型权重、令牌或原始日志；不是 CI 最近一次运行状态。

| 检查 | 结果 | 摘要 |
|---|---|---|
| `python3 scripts/check.py` | 退出 0，84 测试 / 19 套件，0 失败 | Swift 1598/1634 = 97.80%；基础层 334/334 = 100%，各业务模块 ≥90% |
| `python3 scripts/check-python.py` | 退出 0，2 测试，0 失败 | Python 桥接协议 44/45 = 97.78% |
| `python3 scripts/smoke-qwen.py` | 退出 0，6 测试 / 2 套件，0 失败/跳过 | 真实 Qwen ASR 与 LLM；49.02 秒，采样峰值 2.40 GiB |
| `python3 scripts/smoke-qwen.py --app 'voxloom 0.3.2.app'` | 退出 0，6 测试 / 2 套件，0 失败/跳过 | App 内引擎、Python、模型与样本；49.64 秒，采样峰值 2.40 GiB |

Swift、Python 覆盖率独立计算，真实模型 E2E 不计入门槛；完整逐模块数据在 [coverage.md](coverage.md) 和 [summary.json](summary.json)。分支覆盖率 N/A。排除 Tests/ 与第三方依赖；仅声明文件无可执行映射，详情见 [testing.md](../../testing.md)。

GPU 套件顺序运行，避免不同套件同时争抢 GPU；每次推理仍采用生产超时。真实回归包含中文、英文、全零静音、领域词纠正、重复指代、正常人称保留、长文本末句完整性、多种提示长度和 ASR → LLM 链路。用户反馈的两个短句版本另外通过本地私有诊断，正文未提交；公开回归使用合成书籍/纸箱场景。

资源数值为约 100ms 采样的测试进程树 Darwin `ri_phys_footprint` 总和，共享映射可能重复计数。该结果不是目标 16GB 设备上 ≤8GB 验收，也不是长期内存、p50/p95 延迟、能耗或准确率基准。未完成 AirPods/Watch 真机、整机主动断网冷启动、系统输入法和跨 App 上屏验收；0.3.2 未通过 UI 自动化重测实际麦克风录音。

原始本地日志：`.build/llm-fix-final-coverage.log`、`.build/llm-fix-final-python.log`、`.build/llm-private-verification.log`、`.build/reports/tests.log`、`python-tests.log`、`qwen-e2e.log`、`qwen-bundled-e2e.log`。应用打包与签名记录为 `.build/llm-fix-final-package.log`。有效 RED/GREEN 范围见[修复说明](../../correction-0.3.2.md)。
