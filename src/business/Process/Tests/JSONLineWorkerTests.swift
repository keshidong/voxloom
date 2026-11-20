import Foundation
import SpeechFoundation
@testable import SpeechInput
import Testing
import Darwin

struct JSONLineWorkerTests {
    @Test func invalidFramesStartupFailuresAndClosedWorkersFailWithoutLeakingProcesses() async throws {
        let script = try #require(Bundle.module.url(forResource: "json-worker", withExtension: "py", subdirectory: "Fixtures"))
        for mode in ["bad-ready", "malformed-ready", "exit", "oversize"] {
            let worker = JSONLineWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, mode])
            await #expect(throws: (any Error).self) { try await worker.request(Data("{}".utf8)) }
            await worker.shutdown()
            await #expect(throws: CancellationError.self) { try await worker.request(Data("{}".utf8)) }
        }
        let missing = JSONLineWorker(executable: URL(fileURLWithPath: "/missing-engine"), arguments: [])
        await #expect(throws: RecognitionError.engineUnavailable) { try await missing.request(Data("{}".utf8)) }
        for invalid in [Data([10]), Data(repeating: 65, count: 65537)] {
            await #expect(throws: RecognitionError.invalidResult) { try await missing.request(invalid) }
        }
    }
    @Test func cancellingAnInFlightRequestReapsTheOwnedProcess() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let script = try #require(Bundle.module.url(forResource: "json-worker", withExtension: "py", subdirectory: "Fixtures"))
        let worker = JSONLineWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path])
        let data = try JSONSerialization.data(withJSONObject: ["hold": marker.path])
        let task = Task { try await worker.request(data) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: marker.path) { try #require(ContinuousClock.now < deadline); await Task.yield() }
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await worker.shutdown()
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
    @Test func requestsReuseOneOwnedProcessAndReturnOrderedJSON() async throws {
        let script = try #require(Bundle.module.url(forResource: "json-worker", withExtension: "py", subdirectory: "Fixtures"))
        let worker = JSONLineWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path])
        defer { worker.close() }
        let first = try JSONSerialization.jsonObject(with: await worker.request(Data(#"{"text":"第一段"}"#.utf8))) as! [String: Any]
        let second = try JSONSerialization.jsonObject(with: await worker.request(Data(#"{"text":"第二段"}"#.utf8))) as! [String: Any]
        #expect(first["pid"] as? Int == second["pid"] as? Int)
        #expect(first["text"] as? String == "第一段")
        #expect(second["text"] as? String == "第二段")
    }
}
