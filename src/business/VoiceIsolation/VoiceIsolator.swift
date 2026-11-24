import Foundation
import SpeechFoundation

/// Isolates one voice from microphone PCM using saved reference recordings.
public actor VoiceIsolator {
    private let executable: URL
    private let arguments: [String]
    private var worker: JSONLineWorker?
    private var preparation: Task<Void, Never>?
    private var busy = false

    public init(executable: URL, weightsDirectory: URL? = nil) {
        self.executable = executable
        arguments = weightsDirectory.map { ["--weights-directory", $0.path] } ?? []
    }

    deinit { worker?.close() }

    public func prepare() async {
        if let preparation { await preparation.value; return }
        guard !Task.isCancelled, !busy, worker == nil else { return }
        let candidate = JSONLineWorker(executable: executable, arguments: arguments)
        let preparation = Task { [self] in
            do {
                try await candidate.prepare(within: .seconds(5))
                try Task.checkCancellation()
                worker = candidate
            } catch {
                await candidate.shutdown()
            }
            self.preparation = nil
        }
        self.preparation = preparation
        await preparation.value
    }

    public func isolate(_ audio: AudioClip, references: [AudioClip]) async throws -> AudioClip {
        try await filter(audio, references: references, previewSession: nil)
    }

    /// Processes the new suffix of a growing recording, returning the isolated prefix ready for ASR.
    public func preview(_ audio: AudioClip, references: [AudioClip], session: UUID) async throws -> AudioClip {
        try await filter(audio, references: references, previewSession: session)
    }

    private func filter(_ audio: AudioClip, references: [AudioClip], previewSession: UUID?) async throws -> AudioClip {
        try Task.checkCancellation()
        guard !busy else { throw RecognitionError.busy }
        guard (1...3).contains(references.count), references.allSatisfy({ !$0.samples.isEmpty }) else {
            throw RecognitionError.invalidConfiguration
        }
        busy = true
        defer { busy = false }
        await preparation?.value
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxloom-isolation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.wav")
        let output = directory.appendingPathComponent("output.wav")
        try WAVCodec.encode(audio).write(to: input)
        let enrolled = try references.enumerated().map { index, reference in
            let file = directory.appendingPathComponent("reference-\(index).wav")
            try WAVCodec.encode(reference).write(to: file)
            return file.path
        }
        let request = try JSONEncoder().encode(Request(audio: input.path, references: enrolled, output: output.path,
                                                       previewSession: previewSession))
        let worker = self.worker ?? JSONLineWorker(executable: executable, arguments: arguments)
        self.worker = worker
        do {
            let response = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try await worker.request(request) }
                group.addTask {
                    try await Task.sleep(for: .seconds(previewSession == nil ? 90 : 3))
                    throw RecognitionError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            try Task.checkCancellation()
            guard try JSONDecoder().decode(Reply.self, from: response).ok else {
                throw RecognitionError.invalidResult
            }
            let filtered = try WAVCodec.decode(Data(contentsOf: output))
            let validLength = previewSession == nil
                ? filtered.samples.isEmpty || filtered.samples.count == audio.samples.count
                : filtered.samples.count <= audio.samples.count
            guard validLength else {
                throw RecognitionError.invalidResult
            }
            return filtered
        } catch {
            await worker.shutdown()
            self.worker = nil
            throw error
        }
    }

    public func shutdown() async {
        preparation?.cancel()
        await preparation?.value
        await worker?.shutdown()
        worker = nil
    }

    private struct Request: Encodable {
        let audio: String
        let references: [String]
        let output: String
        let previewSession: UUID?
    }

    private struct Reply: Decodable { let ok: Bool }
}
