import Foundation
import SpeechFoundation
import Testing
@testable import SpeechInput

struct QwenOmniAudioReviewerTests {
    @Test(arguments: [true, false], [Int32(0), 7])
    func givesLocalEngineTheAudioDraftAndLogsOnlyReviewMetadata(hasApplication: Bool, exitCode: Int32) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "engine")
        let model = root.appending(path: "model.gguf")
        let projector = root.appending(path: "audio.gguf")
        let contextLog = root.appending(path: "logs/omni-app-context.json")
        let name = "Terminal" + String(repeating: "x", count: 140)
        let bundleIdentifier = "org.example." + String(repeating: "editor.", count: 40) + "preview"
        let snapshot = "AXWindow\n部署\n" + String(repeating: "  AXGroup\n", count: 180)
            + "    AXStaticText 部署文档里写的是滚动更新"
        let appCheck = hasApplication ? """
        grep -Fq '"applicationName":"\(name)"' "$prompt"
        grep -Fq '"applicationBundleIdentifier":"\(bundleIdentifier)"' "$prompt"
        grep -Fq '"applicationContext":"AXWindow\\n部署\\n  AXGroup' "$prompt"
        grep -Fq 'AXStaticText 部署文档里写的是滚动更新"' "$prompt"
        grep -Fq '"pronunciationMatches":{"部属":["部署"]}' "$prompt"
        grep -Fq '"transcript":"运行猫令。〔部署／部属〕已经通过。"' "$prompt"
        """ : """
        grep -Fq '"transcript":"运行猫令。部属已经通过。"' "$prompt"
        if grep -Eq '"(applicationName|applicationBundleIdentifier|applicationContext|pronunciationMatches)"' "$prompt"; then
          exit 1
        fi
        """
        try Data().write(to: model)
        try Data().write(to: projector)
        try Data("""
        #!/bin/bash
        set -eu
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --audio) audio="$2"; shift ;;
            --file) prompt="$2"; shift ;;
            --mmproj) [[ -f "$2" ]]; shift ;;
          esac
          shift
        done
        [[ $(head -c 4 "$audio") == RIFF ]]
        \(appCheck)
        grep -Fq '运行猫令' "$prompt"
        grep -Fq '先打开仓库' "$prompt"
        grep -Fq '输入框所在的目标 App' "$prompt"
        grep -Fq '语病是排查转录错误的线索' "$prompt"
        grep -Fq '只修正录音能够支持的转录错误' "$prompt"
        grep -Fq '保留录音中实际说出的语病' "$prompt"
        printf '%s\\n' '{"transcript":"运行命令"}'
        exit \(exitCode)
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let preview = AppContextProbe()
        let reviewer = QwenOmniAudioReviewer(configuration: .init(executable: executable, model: model,
            projector: projector), temporaryDirectory: root, appContextLog: contextLog,
            onApplicationContextSubmitted: { await preview.record($0) })
        let audio = try AudioClip(samples: [2000, -2000])
        let application = hasApplication ? DictationApplication(name: name, bundleIdentifier: bundleIdentifier) : nil

        let request = AudioReviewRequest(audio: audio, transcript: "运行猫令。部属已经通过。", precedingText: "先打开仓库",
            vocabulary: "私有词表", application: application,
            applicationContext: hasApplication ? snapshot : "")

        if exitCode == 0 {
            #expect(try await reviewer.review(request) == "运行命令")
        } else {
            await #expect(throws: CorrectionError.engineFailed(exitCode)) { try await reviewer.review(request) }
        }
        #expect(await preview.entries == [hasApplication ? snapshot : ""])
        let data = try Data(contentsOf: contextLog)
        let log = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let permissions = try FileManager.default.attributesOfItem(atPath: contextLog.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(log["hasApplicationInfo"] as? Bool == hasApplication)
        #expect(log["applicationName"] as? String == application?.name)
        #expect(log["applicationBundleIdentifier"] as? String == application?.bundleIdentifier)
        #expect(log["outcome"] as? String == (exitCode == 0 ? "completed" : "engineFailed"))
        #expect(log["contextBytes"] as? Int == request.applicationContext.utf8.count)
        #expect((log["elapsedMilliseconds"] as? Int ?? -1) >= 0)
        var keys: Set<String> = ["submittedAt", "hasApplicationInfo", "outcome", "contextBytes", "elapsedMilliseconds"]
        if exitCode != 0 {
            #expect(log["engineExitCode"] as? Int32 == exitCode)
            keys.insert("engineExitCode")
        }
        if hasApplication { keys.formUnion(["applicationName", "applicationBundleIdentifier"]) }
        #expect(Set(log.keys) == keys)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["engine", "model.gguf", "audio.gguf", "logs"])
    }
}

private actor AppContextProbe {
    var entries: [String] = []

    func record(_ text: String) { entries.append(text) }
}
