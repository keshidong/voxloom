#!/usr/bin/env python3
"""Build, run deterministic tests, and enforce coverage on all owned Swift code."""
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
REPORTS = ROOT / ".build/reports"


def run(arguments, log):
    result = subprocess.run(arguments, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (REPORTS / log).write_bytes(result.stdout)
    if result.returncode:
        sys.stderr.write(result.stdout.decode(errors="replace"))
        raise SystemExit(result.returncode)
    return result.stdout


def main():
    REPORTS.mkdir(parents=True, exist_ok=True)
    run(["bash", "scripts/swift-command.sh", "build", "--product", "voice-input", "--enable-code-coverage"], "build.log")
    run(["bash", "scripts/swift-command.sh", "build", "--product", "voice-demo", "--enable-code-coverage"], "build-demo.log")
    run(["bash", "scripts/swift-command.sh", "build", "--product", "voxloom", "--enable-code-coverage"], "build-voxloom.log")
    # Never merge profiles left over from another build or real-model E2E run.
    cli_profiles = ROOT / ".build/cli-profiles"
    cli_profiles.mkdir(parents=True, exist_ok=True)
    for directory in [cli_profiles, ROOT / ".build/debug/codecov"]:
        for profile in directory.glob("*.profraw"):
            profile.unlink()
    output = run(["bash", "scripts/swift-command.sh", "test", "--enable-code-coverage",
                  "--skip", "WhisperE2ETests|QwenE2ETests|QwenASRE2ETests|QwenCorrectionCorpusE2ETests|realWhisperCommandLine"], "tests.log")
    passed = re.search(r"Test run with (\d+) tests in (\d+) suites passed", output.decode(errors="replace"))
    if not passed:
        raise SystemExit("No successful Swift Testing result found; see .build/reports/tests.log")

    binaries = ROOT / ".build/debug"
    profiles = list((binaries / "codecov").glob("*.profraw")) + list(cli_profiles.glob("*.profraw"))
    if not profiles:
        raise SystemExit("No coverage profiles produced")
    merged = REPORTS / "tests.profdata"
    run(["xcrun", "llvm-profdata", "merge", "-sparse", *map(str, profiles), "-o", str(merged)], "merge.log")
    if (REPORTS / "merge.log").read_text().strip():
        raise SystemExit("Coverage merge reported a warning; see .build/reports/merge.log")
    exported = run(["xcrun", "llvm-cov", "export",
                    str(binaries / "VoiceInputPackageTests.xctest/Contents/MacOS/VoiceInputPackageTests"),
                    "-object", str(binaries / "voice-input"), "-object", str(binaries / "voice-demo"),
                    "-object", str(binaries / "voxloom"), f"-instr-profile={merged}"], "coverage.json")
    files = {}
    for dataset in json.loads(exported)["data"]:
        for entry in dataset["files"]:
            path = Path(entry["filename"])
            if path.is_relative_to(ROOT / "src") and "Tests" not in path.parts:
                files[str(path.relative_to(ROOT))] = entry["summary"]["lines"]
    if not files:
        raise SystemExit("No production code found in coverage export")

    groups = {}
    for path, lines in files.items():
        _, layer, module, *_ = Path(path).parts
        for key in ["all", layer, f"{layer}/{module}"]:
            group = groups.setdefault(key, {"count": 0, "covered": 0})
            for field in ["count", "covered"]:
                group[field] += lines[field]
    failures = []
    table = ["| 范围 | 已覆盖 / 可执行行 | 行覆盖率 | 门槛 |", "|---|---:|---:|---:|"]
    for key, group in sorted(groups.items()):
        percent = 100 * group["covered"] / group["count"]
        threshold = 100 if key.startswith("foundation") else 90
        group.update(percent=percent, threshold=threshold)
        table.append(f"| {key} | {group['covered']} / {group['count']} | {percent:.2f}% | {threshold}% |")
        if percent < threshold:
            failures.append(key)
    unmapped = sorted(str(p.relative_to(ROOT)) for p in (ROOT / "src").rglob("*.swift")
                      if "Tests" not in p.parts and str(p.relative_to(ROOT)) not in files)
    # This file contains only enum case declarations. New unmapped source needs review.
    declarations = {"src/foundation/Audio/AudioError.swift", "src/business/Correction/TextCorrector.swift"}
    failures.extend(path for path in unmapped if path not in declarations)
    report = {
        "tests": int(passed[1]), "suites": int(passed[2]), "groups": groups, "files": files,
        "unmappedFiles": unmapped, "gatePassed": not failures,
        "scope": "Unit and module tests; real-model E2E excluded. Counts use LLVM executable lines.",
        "branchCoverage": None,
    }
    (REPORTS / "summary.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    content = ["# 实际测试覆盖率", "", f"{passed[1]} 个测试函数、{passed[2]} 个套件通过；参数化用例在测试日志中单列。", "",
               "范围：单元与模块测试。真实模型 E2E 未计入覆盖率门槛。包含 CLI 子进程，排除测试及第三方源码。", "",
               *table, "", "行数为 LLVM 可执行行，包含 Swift 生成映射；当前工具链未提供分支计数，分支覆盖率为 N/A。", "",
               "未产生可执行映射的文件（需核对仅含声明）：" + (", ".join(unmapped) or "无"), "",
               "完整原始数据：coverage.json；逐文件统计：summary.json；测试日志：tests.log。", ""]
    (REPORTS / "coverage.md").write_text("\n".join(content))
    print("\n".join(content))
    if failures:
        raise SystemExit("Coverage gates failed: " + ", ".join(failures))


if __name__ == "__main__":
    main()
