import Foundation
import Testing
@testable import VoxloomDesktop

struct ModelDownloadsTests {
    @Test func installsVerifiedFilesTogetherAndReusesThemOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(string: "https://example.com/weights")!
        let file = ModelDownloads.Asset(path: "subdir/weights", url: source,
            sha256: "2689367b205c16ce32ed4200942b8b8b1e262dfc70d9bc9fbc77c49699a4f1df")
        let models = ModelDownloads(root: root, assets: ["qwen": [file]])
        #expect(!models.isInstalled("qwen"))

        await #expect(throws: ModelDownloads.DownloadError.checksumMismatch) {
            try await models.install("qwen", download: { _, _ in try downloadFile("wrong") })
        }
        #expect(!models.isInstalled("qwen"))

        try await models.install("qwen", download: { request, _ in
            #expect(request == source)
            return try downloadFile("ok")
        })
        #expect(models.isInstalled("qwen"))
        #expect(try Data(contentsOf: models.directory(for: "qwen").appending(path: file.path)) == Data("ok".utf8))
        try await models.install("qwen", download: { _, _ in
            Issue.record("Reopening a verified model must not download it again")
            throw CancellationError()
        })
    }
}

private func downloadFile(_ text: String) throws -> URL {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data(text.utf8).write(to: file)
    return file
}
