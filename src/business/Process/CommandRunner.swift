import Foundation
import SpeechFoundation
import Darwin

protocol CommandRunning: Sendable {
    func run(executable: URL, arguments: [String]) async throws -> Int32
}

struct SystemCommandRunner: CommandRunning {
    let output: URL?
    init(output: URL? = nil) { self.output = output }
    func run(executable: URL, arguments: [String]) async throws -> Int32 {
        try Task.checkCancellation()
        let handle: FileHandle?
        do { handle = try output.map { try FileHandle(forWritingTo: $0) } }
        catch { throw RecognitionError.fileAccess }
        defer { try? handle?.close() }
        let process = OwnedProcess()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    process.launch(executable: executable, arguments: arguments, output: handle ?? .nullDevice, continuation: continuation)
                }
            }
        } onCancel: { process.cancel() }
    }
}

// Foundation Process is confined to this lock-protected external boundary.
private final class OwnedProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var continuation: CheckedContinuation<Int32, any Error>?
    private var cancelled = false

    func launch(executable: URL, arguments: [String], output: FileHandle, continuation: CheckedContinuation<Int32, any Error>) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [self] child in complete(status: child.terminationStatus) }
        process = child
        self.continuation = continuation
        do {
            try child.run()
            lock.unlock()
        } catch {
            child.terminationHandler = nil
            process = nil
            self.continuation = nil
            lock.unlock()
            continuation.resume(throwing: RecognitionError.engineUnavailable)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if let process, process.isRunning {
            // Only the child owned by this request; never kill a caller's process.
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        lock.unlock()
    }

    private func complete(status: Int32) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let wasCancelled = cancelled
        process?.terminationHandler = nil
        process = nil
        lock.unlock()
        if wasCancelled { continuation?.resume(throwing: CancellationError()) }
        else { continuation?.resume(returning: status) }
    }
}
