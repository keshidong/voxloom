# voxloom 0.3.1 验证摘要

此目录保存本机已执行检查的摘要，不包含录音、模型权重、令牌或原始测试日志。机器信息和未验收范围见各报告；这些结果不是 CI 最近一次运行状态。

- coverage.md / summary.json：Swift 74 个测试函数、19 个套件，整体 1485/1519 = 97.76%，基础层 100%。
- python-coverage.json：2 个协议测试，44/45 = 97.78%。
- qwen-e2e.json：3 个真实模型 E2E；短录音资源采样，不代表 16GB / 8GB 完整验收。
- 发布包内模型另外通过相同的 3 个 E2E，本地日志为 .build/reports/qwen-bundled-e2e.log。

复现命令和测试范围见 ../../testing.md。原始 LLVM 数据和日志保存在本机 .build/reports/，不纳入源码仓库。
