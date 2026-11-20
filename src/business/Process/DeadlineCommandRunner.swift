import Foundation
import SpeechFoundation

struct DeadlineCommandRunner: CommandRunning {
    let base: any CommandRunning
    let timeout: Duration
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    func run(executable: URL, arguments: [String]) async throws -> Int32 {
        let base = base
        let timeout = timeout
        let sleep = sleep
        return try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask { try await base.run(executable: executable, arguments: arguments) }
            group.addTask {
                try await sleep(timeout)
                throw RecognitionError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? -1
        }
    }
}
