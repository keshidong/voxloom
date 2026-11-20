import Foundation
import SpeechFoundation
import Darwin

protocol JSONWorkerRunning: Sendable {
    func request(_ data: Data) async throws -> Data
    func close()
    func shutdown() async
}

extension JSONWorkerRunning {
    func shutdown() async { close() }
}

/// Private stdin/stdout RPC. One owned process, serialized requests, bounded frames.
final class JSONLineWorker: JSONWorkerRunning, @unchecked Sendable {
    let executable: URL
    let arguments: [String]
    private let queue = DispatchQueue(label: "voice-input.json-worker", qos: .userInitiated)
    private let lock = NSLock()
    private var closed = false
    private var io: IO?
    private var ready = false
    init(executable: URL, arguments: [String]) { self.executable = executable; self.arguments = arguments }
    deinit { close() }
    func request(_ data: Data) async throws -> Data {
        try Task.checkCancellation()
        guard data.count <= 65_536, !data.contains(10) else { throw RecognitionError.invalidResult }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        let io = try launch()
                        if !ready {
                            let message = try JSONDecoder().decode(Ready.self, from: readLine(io.output))
                            guard message.ready else { throw RecognitionError.modelUnavailable }
                            ready = true
                        }
                        try io.input.write(contentsOf: data + Data([10]))
                        let response = try readLine(io.output)
                        if isClosed { throw CancellationError() }
                        continuation.resume(returning: response)
                    } catch {
                        let interrupted = isClosed
                        close()
                        io?.process.waitUntilExit()
                        continuation.resume(throwing: interrupted ? CancellationError() : error)
                    }
                }
            }
        } onCancel: { close() }
    }
    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    private func launch() throws -> IO {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw CancellationError() }
        if let io { return io }
        let input = Pipe(), output = Pipe(), process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw RecognitionError.engineUnavailable }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        let result = IO(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading)
        io = result
        return result
    }
    private func readLine(_ file: FileHandle) throws -> Data {
        var line = Data()
        while line.count <= 65_536 {
            guard let byte = try file.read(upToCount: 1), !byte.isEmpty else { throw RecognitionError.engineUnavailable }
            if byte[0] == 10 { return line }
            line.append(byte)
        }
        throw RecognitionError.invalidResult
    }
    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let io = io
        if let io, io.process.isRunning { _ = Darwin.kill(io.process.processIdentifier, SIGKILL) }
        lock.unlock()
        queue.async {
            io?.process.waitUntilExit()
            try? io?.input.close()
            try? io?.output.close()
        }
    }
    func shutdown() async {
        close()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    private struct Ready: Decodable { let ready: Bool }
    private final class IO: @unchecked Sendable {
        let process: Process
        let input: FileHandle
        let output: FileHandle
        init(process: Process, input: FileHandle, output: FileHandle) { self.process = process; self.input = input; self.output = output }
    }
}
