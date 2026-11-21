# 实际测试覆盖率

84 个测试函数、19 个套件通过；参数化用例在测试日志中单列。

范围：单元与模块测试。真实模型 E2E 未计入覆盖率门槛。包含 CLI 子进程，排除测试及第三方源码。

| 范围 | 已覆盖 / 可执行行 | 行覆盖率 | 门槛 |
|---|---:|---:|---:|
| all | 1598 / 1634 | 97.80% | 90% |
| business | 1264 / 1300 | 97.23% | 90% |
| business/Capture | 131 / 138 | 94.93% | 90% |
| business/CommandLine | 50 / 51 | 98.04% | 90% |
| business/Correction | 123 / 123 | 100.00% | 90% |
| business/Desktop | 314 / 333 | 94.29% | 90% |
| business/Live | 125 / 126 | 99.21% | 90% |
| business/Process | 262 / 266 | 98.50% | 90% |
| business/Qwen | 100 / 103 | 97.09% | 90% |
| business/QwenASR | 67 / 68 | 98.53% | 90% |
| business/Recognition | 4 / 4 | 100.00% | 90% |
| business/Whisper | 88 / 88 | 100.00% | 90% |
| foundation | 334 / 334 | 100.00% | 100% |
| foundation/Audio | 73 / 73 | 100.00% | 100% |
| foundation/CLI | 37 / 37 | 100.00% | 100% |
| foundation/Correction | 124 / 124 | 100.00% | 100% |
| foundation/Live | 92 / 92 | 100.00% | 100% |
| foundation/Recognition | 8 / 8 | 100.00% | 100% |

行数为 LLVM 可执行行，包含 Swift 生成映射；当前工具链未提供分支计数，分支覆盖率为 N/A。

未产生可执行映射的文件（需核对仅含声明）：src/business/Correction/TextCorrector.swift, src/foundation/Audio/AudioError.swift

完整原始数据：coverage.json；逐文件统计：summary.json；测试日志：tests.log。
