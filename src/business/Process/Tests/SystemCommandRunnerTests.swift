import Foundation
@testable import SpeechInput
import SpeechFoundation
import Testing
import Darwin

struct SystemCommandRunnerTests {
    @Test func capturesOwnedProcessesStandardOutputInAnExplicitLocalFile() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: output)
        defer { try? FileManager.default.removeItem(at: output) }
        let status = try await SystemCommandRunner(output: output).run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["test output"])
        #expect(status == 0)
        #expect(try String(contentsOf: output, encoding: .utf8) == "test output")
    }
    @Test func returnsOwnedProcessesExitStatus() async throws {
        let status = try await SystemCommandRunner().run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [])
        #expect(status == 1)
    }

    @Test func mapsUnavailableExecutableWithoutLeakingUnderlyingDetails() async {
        await #expect(throws: RecognitionError.engineUnavailable) {
            try await SystemCommandRunner().run(executable: URL(fileURLWithPath: "/missing/whisper-cli"), arguments: [])
        }
    }

    @Test func preCancelledCommandDoesNotLaunch() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SystemCommandRunner().run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancellingRunningCommandReapsItsOwnChild() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try await SystemCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo $$ > \"$1\"; exec /bin/sleep 60", "fixture", marker.path])
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var pid: Int32?
        // External-process readiness, bounded by a watchdog; no sleep-based ordering assertion.
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: marker, encoding: .utf8),
               let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { pid = value; break }
            await Task.yield()
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let child = try #require(pid)
        #expect(Darwin.kill(child, 0) == -1)
    }
}

private struct HangingRunner: CommandRunning {
    func run(executable: URL, arguments: [String]) async throws -> Int32 {
        try await Task.sleep(for: .seconds(60))
        return 0
    }
}

struct DeadlineCommandRunnerTests {
    @Test func expiredDeadlineCancelsHangingWorkWithoutRealWaiting() async {
        let runner = DeadlineCommandRunner(base: HangingRunner(), timeout: .seconds(10), sleep: { _ in })
        await #expect(throws: RecognitionError.timedOut) {
            try await runner.run(executable: URL(fileURLWithPath: "/unused"), arguments: [])
        }
    }
}
