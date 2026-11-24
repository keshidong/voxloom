import Foundation
import Testing
@testable import SpeechInput

struct QwenContextSummarizerTests {
    @Test func extractsOnlyVerbatimTermsFromTheLatestTwoMessages() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = QwenContextSummarizer(executable: URL(fileURLWithPath: "/usr/bin/true"),
            model: root.appending(path: "fixture.gguf"), useGPU: false, temporaryDirectory: root,
            runner: SummaryCommand(expectedJSON: #"["讨论 MLX Audio","比较 Qwen3-ASR"]"#, response: """
            {"summary":"正在比较两种转写设置。","terms":["MLX Audio","Qwen3-ASR","EarlierTopic","Qwen3-ASR"]}
            """))

        let result = try await provider.summarize(.messages(["EarlierTopic", "讨论 MLX Audio", "比较 Qwen3-ASR"]))

        #expect(result.summary == "正在比较两种转写设置。")
        #expect(result.terms == ["MLX Audio", "Qwen3-ASR"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func takesTheExactSourceLinesSelectedByTheModel() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = QwenContextSummarizer(executable: URL(fileURLWithPath: "/usr/bin/true"),
            model: root.appending(path: "fixture.gguf"), useGPU: false, temporaryDirectory: root,
            runner: SummaryCommand(expectedJSON: #"[{"id":4,"text":"要测 Qwen3-ASR\n明天继续"},{"id":3,"text":"SendButton"},{"id":2,"text":"我在试  MLX Audio"},{"id":1,"text":"SearchPanel"}]"#,
                response: """
                {"latestMessageID":4,"previousMessageID":2,"summary":"正在讨论语音转写。","terms":["SearchPanel","MLX Audio","Qwen3-ASR"]}
                """))

        let result = try await provider.summarize(.nearbyText(["SearchPanel", "我在试  MLX Audio", "SendButton",
                                                             "要测 Qwen3-ASR\n明天继续"]))

        #expect(result.originalMessages == ["我在试  MLX Audio", "要测 Qwen3-ASR\n明天继续"])
        #expect(result.terms == ["MLX Audio", "Qwen3-ASR"])
        #expect(result.summary == "正在讨论语音转写。")
    }
}

private struct SummaryCommand: CommandRunning {
    let expectedJSON: String
    let response: String

    func run(executable: URL, arguments: [String]) async throws -> Int32 {
        let index = try #require(arguments.firstIndex(of: "--file"))
        let input = URL(fileURLWithPath: arguments[index + 1])
        let prompt = try String(contentsOf: input, encoding: .utf8)
        #expect(prompt.contains(expectedJSON))
        #expect(prompt.contains("当前在做什么"))
        #expect(!prompt.contains("EarlierTopic"))
        #expect(arguments.contains("--json-schema"))
        let output = input.deletingLastPathComponent().appending(path: "result.json")
        try Data((response + "\n[end of text]\n").utf8).write(to: output)
        return 0
    }
}
