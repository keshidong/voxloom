import Foundation

enum ModelDownloadStatus: Equatable {
    case missing
    case downloading(Double?)
    case ready
    case failed(String)
}

@MainActor final class ModelPreparation {
    private struct Transfer {
        let id: UUID
        let task: Task<Void, Never>
        var progress: Double?
    }

    private let downloads: ModelDownloads
    private let download: ModelDownloads.Download
    private var transfers: [String: Transfer] = [:]
    private var errors: [String: String] = [:]
    var onChange: ((String) -> Void)?

    init(downloads: ModelDownloads, download: @escaping ModelDownloads.Download = ModelDownloads.fetch) {
        self.downloads = downloads
        self.download = download
    }

    func status(for model: String) -> ModelDownloadStatus {
        if let transfer = transfers[model] { return .downloading(transfer.progress) }
        if downloads.isInstalled(model) { return .ready }
        if let message = errors[model] { return .failed(message) }
        return .missing
    }

    @discardableResult
    func prepare(_ model: String, retry: Bool = false) -> Task<Void, Never>? {
        guard transfers[model] == nil, !downloads.isInstalled(model), retry || errors[model] == nil else { return nil }
        let id = UUID()
        errors[model] = nil
        let task = Task(priority: .utility) { [weak self, downloads, download] in
            do {
                try await downloads.install(model, progress: { [weak self] fraction in
                    Task { @MainActor in self?.updateProgress(fraction, for: model, id: id) }
                }, download: download)
                self?.finish(model, id: id, error: nil)
            } catch {
                self?.finish(model, id: id, error: Task.isCancelled ? nil : error.localizedDescription)
            }
        }
        transfers[model] = Transfer(id: id, task: task)
        onChange?(model)
        return task
    }

    func cancel(_ model: String) {
        let task = transfers.removeValue(forKey: model)?.task
        let error = errors.removeValue(forKey: model)
        task?.cancel()
        if task != nil || error != nil { onChange?(model) }
    }

    func stop() async {
        let tasks = transfers.values.map(\.task)
        transfers.removeAll()
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    private func updateProgress(_ fraction: Double?, for model: String, id: UUID) {
        guard transfers[model]?.id == id else { return }
        let progress = fraction.map { (min(1, max(0, $0)) * 100).rounded(.down) / 100 }
        guard transfers[model]?.progress != progress else { return }
        transfers[model]?.progress = progress
        onChange?(model)
    }

    private func finish(_ model: String, id: UUID, error: String?) {
        guard transfers[model]?.id == id else { return }
        transfers[model] = nil
        errors[model] = error
        onChange?(model)
    }
}
