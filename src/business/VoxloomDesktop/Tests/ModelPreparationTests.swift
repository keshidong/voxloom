import Foundation
import Testing
@testable import VoxloomDesktop

@MainActor struct ModelPreparationTests {
    @Test func failedDownloadsReportTheErrorAndCanBeRetried() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = ModelDownloads.Asset(path: "weights", url: URL(string: "https://example.com/model")!,
            sha256: "2689367b205c16ce32ed4200942b8b8b1e262dfc70d9bc9fbc77c49699a4f1df", bytes: 2)
        let attempt = Attempt()
        let setup = ModelPreparation(downloads: ModelDownloads(root: root, assets: ["qwen": [asset]]),
            download: { _, progress in
                try await attempt.download(progress)
            })
        #expect(setup.status(for: "qwen") == .missing)
        let failed = try #require(setup.prepare("qwen"))
        #expect(setup.status(for: "qwen") == .downloading(nil))
        await failed.value
        #expect(setup.status(for: "qwen") == .failed("下载服务器返回 HTTP 503"))
        #expect(setup.prepare("qwen") == nil)
        let retry = try #require(setup.prepare("qwen", retry: true))
        await retry.value
        #expect(setup.status(for: "qwen") == .ready)
    }
}

private actor Attempt {
    private var count = 0

    func download(_ progress: ModelDownloads.TransferProgress) throws -> URL {
        count += 1
        if count == 1 { throw ModelDownloads.DownloadError.httpStatus(503) }
        progress(1, -1)
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("ok".utf8).write(to: file)
        return file
    }
}
