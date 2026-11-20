import Foundation
import SpeechFoundation
import Testing
import Darwin

private let projectRoot = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { path, _ in path.deletingLastPathComponent() }
private let executable = projectRoot.appendingPathComponent(".build/debug/voice-input")

struct CLIOutput: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

func runCLI(_ arguments: [String]) async throws -> CLIOutput {
    let child = Process()
    child.executableURL = executable
    child.arguments = arguments
    let stdout = Pipe(), stderr = Pipe()
    child.standardOutput = stdout
    child.standardError = stderr
    var environment = ProcessInfo.processInfo.environment
    let profiles = projectRoot.appendingPathComponent(".build/cli-profiles")
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    environment["LLVM_PROFILE_FILE"] = profiles.appendingPathComponent("cli-%p.profraw").path
    child.environment = environment
    return try await withCheckedThrowingContinuation { continuation in
        child.terminationHandler = { process in
            continuation.resume(returning: CLIOutput(status: process.terminationStatus,
                stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
                stderr: stderr.fileHandleForReading.readDataToEndOfFile()))
        }
        do { try child.run() } catch { continuation.resume(throwing: error) }
    }
}

struct CLIWorkspace {
    let root: URL
    let audio: URL
    let model: URL
    let engine: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        audio = root.appendingPathComponent("input with spaces.wav")
        model = root.appendingPathComponent("model with spaces.bin")
        engine = root.appendingPathComponent("engine with spaces")
        try WAVCodec.encode(AudioClip(samples: [1, -1])).write(to: audio)
        try Data(#"{"text":"中文 English"}"#.utf8).write(to: model)
        try FileManager.default.copyItem(at: Bundle.module.url(forResource: "whisper-fixture", withExtension: "py", subdirectory: "Fixtures")!, to: engine)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.path)
    }
    var arguments: [String] { ["transcribe", audio.path, "--engine", engine.path, "--model", model.path, "--cpu"] }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

struct CommandLineTests {
    @Test func transcribesThroughARealProcessAndFileBoundaryWithSyntheticEngine() async throws {
        let workspace = try CLIWorkspace()
        defer { workspace.remove() }
        let output = try await runCLI(workspace.arguments + ["--json", "--context", "RxSwift $(literal)"])
        #expect(output.status == 0)
        #expect(try JSONDecoder().decode(Transcript.self, from: output.stdout) == Transcript(text: "中文 English", language: "zh"))
        #expect(output.stderr.isEmpty)
    }

    @Test func helpAndInvalidArgumentsHaveStableExitBehavior() async throws {
        let help = try await runCLI(["--help"])
        #expect(help.status == 0)
        #expect(String(decoding: help.stdout, as: UTF8.self).contains("voice-input transcribe"))
        let invalid = try await runCLI(["unknown"])
        #expect(invalid.status == 2)
        #expect(invalid.stdout.isEmpty)
        #expect(String(decoding: invalid.stderr, as: UTF8.self).contains("invalidArguments"))
    }

    @Test func printsPlainTextAndRejectsMissingMalformedAndOversizedFiles() async throws {
        let workspace = try CLIWorkspace()
        defer { workspace.remove() }
        let plain = try await runCLI(workspace.arguments)
        #expect(plain.status == 0)
        #expect(String(decoding: plain.stdout, as: UTF8.self) == "中文 English\n")
        for content in [Data("bad WAV".utf8), Data(repeating: 0, count: WAVCodec.maximumFileSize + 1)] {
            try content.write(to: workspace.audio)
            let result = try await runCLI(workspace.arguments)
            #expect(result.status == 2)
            #expect(result.stdout.isEmpty)
        }
        try FileManager.default.removeItem(at: workspace.audio)
        let missing = try await runCLI(workspace.arguments)
        #expect(missing.status == 2)
        #expect(String(decoding: missing.stderr, as: UTF8.self).contains("fileAccess"))
    }

    @Test(arguments: [SIGINT, SIGTERM])
    func interruptCancelsEngineAndRemovesTemporaryAudio(signal: Int32) async throws {
        let workspace = try CLIWorkspace()
        defer { workspace.remove() }
        let marker = workspace.root.appendingPathComponent("ready.json")
        let settings: [String: Any] = ["hold": true, "marker": marker.path]
        try JSONSerialization.data(withJSONObject: settings).write(to: workspace.model)
        let child = Process()
        child.executableURL = executable
        child.arguments = workspace.arguments
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["LLVM_PROFILE_FILE"] = projectRoot.appendingPathComponent(".build/cli-profiles/interrupt-%p.profraw").path
        child.environment = environment
        try child.run()
        var enginePID: Int32?
        var job: String?
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < readyDeadline {
            if let data = try? Data(contentsOf: marker),
               let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pid = values["pid"] as? Int32, let directory = values["job"] as? String {
                enginePID = pid; job = directory; break
            }
            await Task.yield()
        }
        if enginePID != nil { _ = Darwin.kill(child.processIdentifier, signal) }
        let exitDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while child.isRunning && ContinuousClock.now < exitDeadline { await Task.yield() }
        let exited = !child.isRunning
        if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
        if !exited, let enginePID { _ = Darwin.kill(enginePID, SIGKILL) }
        child.waitUntilExit()
        #expect(enginePID != nil)
        #expect(exited)
        #expect(child.terminationStatus == 130)
        if let enginePID { #expect(Darwin.kill(enginePID, 0) == -1) }
        if let job { #expect(!FileManager.default.fileExists(atPath: job)) }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("models/ggml-tiny.bin").path),
                   "Real Whisper resources are installed by prepare-whisper.sh"))
    func realWhisperCommandLineUsesInstalledLocalModel() async throws {
        let output = try await runCLI(["transcribe", projectRoot.appendingPathComponent(".runtime/whisper.cpp-1.8.2/samples/jfk.wav").path,
            "--engine", projectRoot.appendingPathComponent(".runtime/whisper-build/bin/whisper-cli").path,
            "--model", projectRoot.appendingPathComponent("models/ggml-tiny.bin").path, "--language", "en", "--cpu", "--json"])
        #expect(output.status == 0)
        let result = try JSONDecoder().decode(Transcript.self, from: output.stdout)
        #expect(result.language == "en")
        #expect(result.text.lowercased().contains("country"))
    }
}
