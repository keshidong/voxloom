import Foundation
import Testing
@testable import VoxloomDesktop

struct ModelDownloadsTests {
    @Test func aConnectionResetTriesTheNextSourceForTheSameAsset() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = """
        {"qwen":[{"path":"weights","url":"https://primary.example/weights",
        "fallbackURLs":["https://mirror.example/weights"],
        "sha256":"2689367b205c16ce32ed4200942b8b8b1e262dfc70d9bc9fbc77c49699a4f1df","bytes":2}]}
        """
        let assets = try JSONDecoder().decode([String: [ModelDownloads.Asset]].self, from: Data(manifest.utf8))
        let models = ModelDownloads(root: root, assets: assets)
        let requests = SourceRequests()
        try await models.install("qwen", download: { address, _ in
            await requests.record(address)
            if address.host == "primary.example" { throw URLError(.networkConnectionLost) }
            return try downloadFile("ok")
        })

        #expect(await requests.hosts == ["primary.example", "mirror.example"])
        #expect(models.isInstalled("qwen"))
        #expect(try Data(contentsOf: models.directory(for: "qwen").appending(path: "weights")) == Data("ok".utf8))
    }

    @Test func usesTheVerifiedSourceForTheRemainingFilesOfTheSameModel() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["weights", "config"].map(mirroredAsset)
        let models = ModelDownloads(root: root, assets: ["qwen": files])
        let requests = SourceRequests()
        try await models.install("qwen", download: { address, _ in
            await requests.record(address)
            if address.host == "primary.example" { throw URLError(.networkConnectionLost) }
            return try downloadFile("ok")
        })

        #expect(await requests.hosts == ["primary.example", "mirror.example", "mirror.example"])
        #expect(models.isInstalled("qwen"))
    }

    @Test func checksumFailureRejectsEvenSameSizeBytesAndCleansTheCandidate() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let models = ModelDownloads(root: root, assets: ["qwen": [mirroredAsset("weights")]])
        let corrupt = root.appendingPathComponent("unverified-weights")
        let requests = SourceRequests()
        try await models.install("qwen", download: { address, _ in
            await requests.record(address)
            if address.host == "primary.example" {
                try Data("no".utf8).write(to: corrupt)
                return corrupt
            }
            #expect(!FileManager.default.fileExists(atPath: corrupt.path))
            return try downloadFile("ok")
        })

        #expect(await requests.hosts == ["primary.example", "mirror.example"])
        #expect(try Data(contentsOf: models.directory(for: "qwen").appending(path: "weights")) == Data("ok".utf8))
    }

    @Test func exhaustingSourcesDoesNotInstallAPartialModel() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let models = ModelDownloads(root: root, assets: ["qwen": ["config", "weights"].map(mirroredAsset)])
        let requests = SourceRequests()
        await #expect(throws: ModelDownloads.DownloadError.checksumMismatch) {
            try await models.install("qwen", download: { address, _ in
                await requests.record(address)
                if address.lastPathComponent == "config" { return try downloadFile("ok") }
                if address.host == "primary.example" { throw ModelDownloads.DownloadError.httpStatus(503) }
                return try downloadFile("no")
            })
        }
        #expect(await requests.hosts == ["primary.example", "primary.example", "mirror.example"])
        #expect(!models.isInstalled("qwen"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func cancellationStopsWithoutRequestingTheFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let models = ModelDownloads(root: root, assets: ["qwen": [mirroredAsset("weights")]])
        let requests = SourceRequests()
        let job = Task {
            try await models.install("qwen", download: { address, _ in
                await requests.record(address)
                withUnsafeCurrentTask { $0?.cancel() }
                throw URLError(.networkConnectionLost)
            })
        }
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(await requests.hosts == ["primary.example"])
        #expect(!models.isInstalled("qwen"))
    }

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
        let withMirror = ModelDownloads(root: root, assets: ["qwen": [
            .init(path: file.path, url: file.url, sha256: file.sha256,
                  fallbackURLs: [URL(string: "https://mirror.example/weights")!])
        ]])
        #expect(withMirror.directory(for: "qwen") == models.directory(for: "qwen"))
        try await withMirror.install("qwen", download: { _, _ in
            Issue.record("Adding an alternate source must not download verified files again")
            throw CancellationError()
        })
    }
}

private func mirroredAsset(_ name: String) -> ModelDownloads.Asset {
    ModelDownloads.Asset(path: name, url: URL(string: "https://primary.example/\(name)")!,
        sha256: "2689367b205c16ce32ed4200942b8b8b1e262dfc70d9bc9fbc77c49699a4f1df",
        bytes: 2, fallbackURLs: [URL(string: "https://mirror.example/\(name)")!])
}

private actor SourceRequests {
    private(set) var hosts: [String] = []

    func record(_ url: URL) {
        if let host = url.host { hosts.append(host) }
    }
}

private func downloadFile(_ text: String) throws -> URL {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data(text.utf8).write(to: file)
    return file
}
