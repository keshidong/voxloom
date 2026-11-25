import CryptoKit
import Foundation
import os

struct ModelDownloads: Sendable {
    struct Asset: Decodable, Sendable {
        let path: String
        let url: URL
        let sha256: String
        let bytes: Int64?
        let fallbackURLs: [URL]?

        init(path: String, url: URL, sha256: String, bytes: Int64? = nil, fallbackURLs: [URL]? = nil) {
            self.path = path
            self.url = url
            self.sha256 = sha256
            self.bytes = bytes
            self.fallbackURLs = fallbackURLs
        }

        var sources: [URL] {
            var seen = Set<URL>()
            return ([url] + (fallbackURLs ?? [])).filter { seen.insert($0).inserted }
        }
    }

    enum DownloadError: LocalizedError, Equatable {
        case unknownModel, badResponse, httpStatus(Int), checksumMismatch

        var errorDescription: String? {
            switch self {
            case .unknownModel: "安装包缺少模型下载信息"
            case .badResponse: "下载服务器没有返回有效响应"
            case let .httpStatus(code): "下载服务器返回 HTTP \(code)"
            case .checksumMismatch: "模型文件校验失败"
            }
        }
    }

    typealias Progress = @Sendable (Double?) -> Void
    typealias TransferProgress = @Sendable (Int64, Int64) -> Void
    typealias Download = @Sendable (URL, @escaping TransferProgress) async throws -> URL

    let root: URL
    let assets: [String: [Asset]]

    func directory(for model: String) -> URL {
        let checksums = assets[model, default: []].map(\.sha256).joined()
        let version = SHA256.hash(data: Data(checksums.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: "\(model)-\(version)", directoryHint: .isDirectory)
    }

    func isInstalled(_ model: String) -> Bool {
        guard let files = assets[model], !files.isEmpty else { return false }
        let directory = directory(for: model)
        return files.allSatisfy { asset in
            let file = directory.appending(path: asset.path)
            guard let metadata = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  metadata.isRegularFile == true else { return false }
            return asset.bytes.map { $0 == metadata.fileSize.map(Int64.init) } ?? true
        }
    }

    func install(_ model: String, progress: @escaping Progress = { _ in },
                 download: Download = Self.fetch) async throws {
        if isInstalled(model) { return }
        guard let files = assets[model], !files.isEmpty else { throw DownloadError.unknownModel }
        let manager = FileManager.default
        let stage = root.appending(path: ".\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: stage) }
        let expectedBytes = files.reduce(0) { $0 + ($1.bytes ?? 1) }
        var installedBytes: Int64 = 0
        var preferredHost: String?
        for asset in files {
            try Task.checkCancellation()
            let completed = installedBytes
            let expected = asset.bytes ?? 1
            let verified = try await downloadVerified(asset, preferredHost: preferredHost, using: download) { written, responseSize in
                let fileSize = asset.bytes ?? responseSize
                guard fileSize > 0 else { progress(nil); return }
                let fraction = min(1, Double(written) / Double(fileSize))
                progress((Double(completed) + fraction * Double(expected)) / Double(expectedBytes))
            }
            let file = verified.file
            defer { try? manager.removeItem(at: file) }
            let destination = stage.appending(path: asset.path)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: file, to: destination)
            installedBytes += expected
            preferredHost = verified.source.host
        }
        try Task.checkCancellation()
        let destination = directory(for: model)
        do {
            if isInstalled(model) { return }
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: stage)
            } else {
                try manager.moveItem(at: stage, to: destination)
            }
        } catch {
            if !isInstalled(model) { throw error }
        }
    }

    private func downloadVerified(_ asset: Asset, preferredHost: String?, using download: Download,
                                  progress: @escaping TransferProgress) async throws -> (file: URL, source: URL) {
        var sources = asset.sources
        if let preferredHost, let index = sources.firstIndex(where: { $0.host == preferredHost }), index != 0 {
            let source = sources.remove(at: index)
            sources.insert(source, at: 0)
        }
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            var received: URL?
            do {
                let file = try await receive(source, using: download, progress: progress)
                received = file
                try Task.checkCancellation()
                try Self.verify(file, checksum: asset.sha256)
                return (file, source)
            } catch {
                if let received { try? FileManager.default.removeItem(at: received) }
                try Task.checkCancellation()
                guard index + 1 < sources.count, Self.canTryAnotherSource(after: error) else { throw error }
                progress(0, -1)
            }
        }
        throw DownloadError.badResponse
    }

    private func receive(_ source: URL, using download: Download, progress: @escaping TransferProgress) async throws -> URL {
        let reporting = OSAllocatedUnfairLock(initialState: true)
        defer { reporting.withLock { $0 = false } }
        return try await download(source) { written, total in
            reporting.withLock { if $0 { progress(written, total) } }
        }
    }

    private static func canTryAnotherSource(after error: any Error) -> Bool {
        if let error = error as? DownloadError {
            switch error {
            case .badResponse, .checksumMismatch: return true
            case let .httpStatus(code): return [401, 403, 404, 408, 410, 429].contains(code) || (500..<600).contains(code)
            case .unknownModel: return false
            }
        }
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .badServerResponse, .cannotParseResponse, .resourceUnavailable, .zeroByteResource, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private static func verify(_ file: URL, checksum: String) throws {
        let stream = try FileHandle(forReadingFrom: file)
        defer { try? stream.close() }
        var hash = SHA256()
        while let block = try stream.read(upToCount: 1024 * 1024), !block.isEmpty {
            try Task.checkCancellation()
            hash.update(data: block)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == checksum else {
            throw DownloadError.checksumMismatch
        }
    }

    static func fetch(_ url: URL, progress: @escaping TransferProgress) async throws -> URL {
        try await ModelDownloadTransfer(report: progress).download(url)
    }
}

private final class ModelDownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct State {
        var task: URLSessionDownloadTask?
        var continuation: CheckedContinuation<URL, Error>?
        var cancelled = false
    }

    private let report: ModelDownloads.TransferProgress
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(report: @escaping ModelDownloads.TransferProgress) { self.report = report }

    func download(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: url)
                let started = state.withLock { state in
                    guard !state.cancelled else { return false }
                    state.continuation = continuation
                    state.task = task
                    task.resume()
                    return true
                }
                if started {
                    session.finishTasksAndInvalidate()
                } else {
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let task = self.state.withLock { state in
                state.cancelled = true
                return state.task
            }
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else {
                throw ModelDownloads.DownloadError.badResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                throw ModelDownloads.DownloadError.httpStatus(response.statusCode)
            }
            let destination = FileManager.default.temporaryDirectory.appending(path: "voxloom-" + UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: destination)
            if !finish(.success(destination)) { try? FileManager.default.removeItem(at: destination) }
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finish(.failure(error ?? ModelDownloads.DownloadError.badResponse))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        report(totalBytesWritten, totalBytesExpectedToWrite)
    }

    @discardableResult
    private func finish(_ result: Result<URL, Error>) -> Bool {
        let continuation = state.withLock { state in
            let continuation = state.continuation
            state.continuation = nil
            state.task = nil
            return continuation
        }
        continuation?.resume(with: result)
        return continuation != nil
    }
}
