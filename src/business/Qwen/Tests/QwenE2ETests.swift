import Foundation
import SpeechFoundation
import SpeechInput
import Testing

private let root = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { path, _ in path.deletingLastPathComponent() }
private let bundleResources = ProcessInfo.processInfo.environment["VOICE_INPUT_DEMO_RESOURCES"].map { URL(fileURLWithPath: $0) }
private let model = bundleResources?.appendingPathComponent("Qwen3-4B-Instruct-2507-Q4_K_M.gguf") ?? root.appendingPathComponent("models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")
private let engine = bundleResources?.appendingPathComponent("llama-completion") ?? root.appendingPathComponent(".runtime/llama-build/bin/llama-completion")

struct QwenE2ETests {
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: engine.path) && FileManager.default.fileExists(atPath: model.path),
                   "Local Qwen resources and access to Metal required"))
    func actualOfflineModelRepairsDomainWordsAndRetainsAReviewableOriginal() async throws {
        let original = "图舒卡的充直额图以USD即价，每刺最少充直20。"
        let corrector: any TextCorrecting = QwenTextCorrector(configuration: .init(executable: engine, model: model))
        let result = try await corrector.correct(.init(text: original, vocabulary: "图书卡 充值额度 USD 计价"))
        #expect(result.text.contains("充值额度"))
        #expect(result.text.contains("USD"))
        #expect(result.text.contains("计价"))
        #expect(result.containsNumbers)
    }
}
