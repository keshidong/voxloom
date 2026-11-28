import Foundation
import SpeechFoundation

/// Owns one local model process for an app and releases it after idle dictation.
public actor QwenOmniServer {
    struct Model: Equatable, Sendable {
        let weights: URL
        let projector: URL
        let useGPU: Bool
    }

    private struct Running {
        let model: Model
        let directory: URL
        let process: Process
        let lifetime: FileHandle
        var socket: String { directory.appending(path: "review.sock").path }
    }

    private let executable: URL
    private let idleTimeout: Duration
    private var running: Running?
    private var preparation: Task<Void, Never>?
    private var idle: Task<Void, Never>?
    private var unloading: Task<Void, Never>?
    private var busy = false

    public init(executable: URL, idleTimeout: Duration = .seconds(30)) {
        self.executable = executable
        self.idleTimeout = idleTimeout
    }

    deinit {
        preparation?.cancel()
        idle?.cancel()
        try? running?.lifetime.close()
    }

    func prepare(_ request: Data, model: Model) async {
        guard !Task.isCancelled, !busy, preparation == nil else { return }
        let task = Task { [weak self] in
            _ = try? await self?.exchange(request, model: model, timeout: .seconds(15))
        }
        preparation = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        preparation = nil
    }

    func respond(to request: Data, model: Model, timeout: Duration) async throws -> Data {
        await preparation?.value
        return try await exchange(request, model: model, timeout: timeout)
    }

    public func shutdown() async {
        idle?.cancel()
        idle = nil
        preparation?.cancel()
        await preparation?.value
        idle?.cancel()
        idle = nil
        await unload()
    }

    private func exchange(_ request: Data, model: Model, timeout: Duration) async throws -> Data {
        try Task.checkCancellation()
        guard !busy else { throw CorrectionError.busy }
        busy = true
        idle?.cancel()
        idle = nil
        defer {
            busy = false
            if running != nil { scheduleIdleRelease() }
        }
        do {
            let server = try await readyServer(for: model)
            return try await send(request, to: server, timeout: timeout)
        } catch {
            await unload()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func readyServer(for model: Model) async throws -> Running {
        if let running, running.model == model, running.process.isRunning { return running }
        await unload()
        let server = try launch(model)
        running = server
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while server.process.isRunning, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: server.socket),
               try await curl(server, path: "/health", timeout: .seconds(1)) == 0 {
                return server
            }
            try await Task.sleep(for: .milliseconds(80))
        }
        throw server.process.isRunning ? CorrectionError.timedOut : CorrectionError.engineUnavailable
    }

    private func launch(_ model: Model) throws -> Running {
        let files = FileManager.default
        guard files.isExecutableFile(atPath: executable.path) else { throw CorrectionError.engineUnavailable }
        // The path must fit Darwin's short sockaddr_un, even with a long user temp path.
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appending(path: "voxloom-omni-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let socket = directory.appending(path: "review.sock").path
        var arguments = [executable.path, "--model", model.weights.path, "--mmproj", model.projector.path,
                         "--host", socket, "--ctx-size", "16384", "--parallel", "1", "--threads", "4",
                         "--gpu-layers", model.useGPU ? "99" : "0", "--jinja", "--no-warmup",
                         "--no-webui", "--no-slots", "--cache-ram", "0", "--log-disable",
                         "--sleep-idle-seconds", "35"]
        if model.useGPU {
            arguments += ["--flash-attn", "on", "--cache-type-k", "q8_0", "--cache-type-v", "q8_0"]
        } else {
            arguments.append("--no-mmproj-offload")
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.supervise, "voxloom-omni"] + arguments
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? files.removeItem(at: directory)
            throw CorrectionError.engineUnavailable
        }
        try? pipe.fileHandleForReading.close()
        return Running(model: model, directory: directory, process: process, lifetime: pipe.fileHandleForWriting)
    }

    private func send(_ data: Data, to server: Running, timeout: Duration) async throws -> Data {
        let directory = server.directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let input = directory.appending(path: "request.json")
        let output = directory.appending(path: "response.json")
        try data.write(to: input)
        try Data().write(to: output)
        let status = try await curl(server, path: "/v1/chat/completions", timeout: timeout,
                                    input: input, output: output)
        guard status == 0 else { throw CorrectionError.engineFailed(status) }
        let handle = try FileHandle(forReadingFrom: output)
        defer { try? handle.close() }
        let response = try handle.read(upToCount: 65_537) ?? Data()
        guard response.count <= 65_536 else { throw CorrectionError.invalidResult }
        return response
    }

    private func curl(_ server: Running, path: String, timeout: Duration,
                      input: URL? = nil, output: URL? = nil) async throws -> Int32 {
        var arguments = ["-qfsS", "--noproxy", "*", "--unix-socket", server.socket,
                         "--max-filesize", "65536", "http://localhost" + path]
        if let input { arguments += ["-H", "Content-Type: application/json", "--data-binary", "@" + input.path] }
        return try await DeadlineCommandRunner(base: SystemCommandRunner(output: output), timeout: timeout)
            .run(executable: URL(fileURLWithPath: "/usr/bin/curl"), arguments: arguments)
    }

    private func scheduleIdleRelease() {
        let timeout = idleTimeout
        idle = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.releaseIfIdle()
        }
    }

    private func releaseIfIdle() async {
        guard !Task.isCancelled, !busy else { return }
        idle = nil
        await unload()
    }

    private func unload() async {
        if let unloading {
            await unloading.value
            return
        }
        guard let server = running else { return }
        running = nil
        let task = Task {
            try? server.lifetime.close()
            // Closing the pipe tells the supervisor to terminate and reap llama-server.
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while server.process.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(40))
            }
            if server.process.isRunning { server.process.terminate() }
            try? FileManager.default.removeItem(at: server.directory)
        }
        unloading = task
        await task.value
        unloading = nil
    }

    // The parent owns the only writer. If the app exits, EOF stops its server.
    private static let supervise = """
    "$@" </dev/null &
    child=$!
    exec 3<&0
    (
      IFS= read -r ignored <&3 || true
      kill "$child" 2>/dev/null || true
    ) &
    watcher=$!
    trap 'kill "$child" 2>/dev/null || true' HUP INT TERM
    wait "$child" 2>/dev/null
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null
    """
}
