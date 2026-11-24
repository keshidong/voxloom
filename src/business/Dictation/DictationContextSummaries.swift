import SpeechFoundation

@MainActor public final class DictationContextSummaries {
    private var summarizer: (any RecognitionContextSummarizing)?
    private var source: RecognitionContextSource?
    private var result: RecognitionContextSummary?
    private var pending: Task<Void, Never>?
    private var latestRecording = 0

    public init(summarizer: (any RecognitionContextSummarizing)? = nil) { self.summarizer = summarizer }

    public func installSummarizer(_ summarizer: any RecognitionContextSummarizing) {
        guard self.summarizer == nil else { return }
        self.summarizer = summarizer
        if let source { schedule(source, with: summarizer) }
    }

    func beginRecording() -> Int {
        latestRecording += 1
        return latestRecording
    }

    /// Reuses a completed summary for the same text, while a new summary runs independently of recognition.
    func prepare(_ current: RecognitionContextSource?, for recording: Int) {
        guard recording == latestRecording, !Task.isCancelled else { return }
        if source == current && (result != nil || pending != nil || current == nil) { return }

        source = current
        result = nil
        if let summarizer { schedule(current, with: summarizer) }
    }

    private func schedule(_ current: RecognitionContextSource?, with summarizer: any RecognitionContextSummarizing) {
        let previous = pending
        previous?.cancel()
        pending = Task(priority: .utility) { [weak self, summarizer] in
            await previous?.value
            guard !Task.isCancelled else { return }
            let summary: RecognitionContextSummary?
            if let current { summary = try? await summarizer.summarize(current) }
            else { summary = nil }
            guard !Task.isCancelled else { return }
            self?.result = summary
            self?.pending = nil
        }
    }

    func summary(for source: RecognitionContextSource) -> RecognitionContextSummary? {
        self.source == source ? result : nil
    }

    public func cancel() {
        latestRecording += 1
        source = nil
        result = nil
        pending?.cancel()
    }

    public func shutdown() async {
        cancel()
        await pending?.value
        pending = nil
    }
}
