import Foundation
import SpeechFoundation
import RxSwift

public enum CorrectionStatus: Sendable, Equatable {
    case idle, working, candidate(CorrectionCandidate), failed(String)
}

@MainActor public final class CorrectionSession {
    private enum Trigger { case quiet, deadline }

    struct Job {
        let request: CorrectionRequest
        var inputRevision: Int?
        var accept: ((CorrectionCandidate) -> Void)?

        fileprivate var key: JobKey {
            if let inputRevision { return .draft(inputRevision, request.vocabulary) }
            return .request(request)
        }
    }

    fileprivate enum JobKey: Equatable {
        case request(CorrectionRequest)
        case draft(Int, String)
    }

    private enum PendingWork {
        case request(CorrectionRequest)
        case draft(() -> Job?)

        func makeJob() -> Job? {
            switch self {
            case .request(let request): Job(request: request)
            case .draft(let capture): capture()
            }
        }
    }

    private struct Submission {
        let revision: Int
        let request: CorrectionRequest?
    }

    public private(set) var state: CorrectionStatus = .idle
    private let requests = PublishSubject<Submission>()
    private let output = BehaviorSubject<CorrectionStatus>(value: .idle)
    private let bag = DisposeBag()
    private var task: Task<Void, Never>?
    private let scheduler: any SchedulerType
    private let quietTimer = SerialDisposable()
    private let deadlineTimer = SerialDisposable()
    private var pending: PendingWork?
    private var ready: Trigger?
    private var lastSubmitted: JobKey?
    private var acceptCandidate: ((CorrectionCandidate) -> Void)?
    private var revision = 0
    private var inFlight = false
    public var states: Observable<CorrectionStatus> { output.asObservable() }
    public init(corrector: any TextCorrecting, scheduler: any SchedulerType = MainScheduler.instance) {
        self.scheduler = scheduler
        quietTimer.disposed(by: bag)
        deadlineTimer.disposed(by: bag)
        requests.flatMapLatest { [weak self, corrector] submission -> Observable<(Int, CorrectionStatus)> in
            guard let request = submission.request else { return .just((submission.revision, .idle)) }
            return Observable<CorrectionStatus>.create { observer in
                let previous = self?.task
                let task = Task { @MainActor in
                    // Disposal cancels the predecessor. Await its cleanup so a
                    // resident/owned engine is available before the next call.
                    await previous?.value
                    do {
                        try Task.checkCancellation()
                        let candidate = try await corrector.correct(request)
                        try Task.checkCancellation()
                        observer.onNext(.candidate(candidate))
                    } catch is CancellationError {} catch {
                        observer.onNext(.failed("本地纠错失败：\(error.localizedDescription)"))
                    }
                    observer.onCompleted()
                }
                self?.task = task
                return Disposables.create { task.cancel() }
            }.startWith(.working).map { (submission.revision, $0) }
        }.observe(on: MainScheduler.asyncInstance)
            .subscribe(onNext: { [weak self] revision, status in self?.receive(status, revision: revision) })
            .disposed(by: bag)
    }
    public func run(_ request: CorrectionRequest) {
        discardScheduledWork()
        submit(Job(request: request))
    }
    /// Flushes the final text immediately and reports whether its result is pending.
    public func prepareFinal(_ request: CorrectionRequest) -> Bool {
        discardScheduledWork()
        let job = Job(request: request)
        if lastSubmitted == job.key { return inFlight }
        submit(job)
        return true
    }

    var hasImmediateWork: Bool { inFlight || ready == .deadline }

    func prepareFinalDraft(_ capture: @escaping () -> Job?) -> Bool {
        discardScheduledWork()
        guard let job = capture() else { return false }
        if lastSubmitted == job.key { return inFlight }
        if inFlight {
            // Finish the active edit first, then capture the latest draft including its valid changes.
            pending = .draft(capture)
            ready = .deadline
        } else {
            submit(job)
        }
        return true
    }

    public func update(_ request: CorrectionRequest) {
        if case .request(let current)? = pending, current == request { return }
        update(.request(request))
    }

    func updateDraft(_ capture: @escaping () -> Job?) {
        update(.draft(capture))
    }

    private func update(_ work: PendingWork) {
        let startsWindow = pending == nil
        pending = work
        if ready == .quiet { ready = nil }
        quietTimer.disposable = scheduleFlush(after: .milliseconds(800), trigger: .quiet)
        if startsWindow { deadlineTimer.disposable = scheduleFlush(after: .seconds(3), trigger: .deadline) }
    }
    private func scheduleFlush(after delay: RxTimeInterval, trigger: Trigger) -> any Disposable {
        scheduler.scheduleRelative((), dueTime: delay) { [weak self] _ in
            if let self, pending != nil {
                if ready != .deadline { ready = trigger }
                submitIfReady()
            }
            return Disposables.create()
        }
    }
    func discardScheduledWork() {
        pending = nil
        ready = nil
        quietTimer.disposable = Disposables.create()
        deadlineTimer.disposable = Disposables.create()
    }
    private func submitIfReady() {
        guard !inFlight, ready != nil, let work = pending else { return }
        discardScheduledWork()
        if let job = work.makeJob() { submit(job) }
    }
    private func submit(_ job: Job) {
        if job.key == lastSubmitted {
            guard !inFlight, case .failed = state else { return }
        }
        lastSubmitted = job.key
        acceptCandidate = job.accept
        revision += 1
        inFlight = true
        requests.onNext(Submission(revision: revision, request: job.request))
    }
    private func receive(_ status: CorrectionStatus, revision: Int) {
        guard revision == self.revision else { return }
        inFlight = status == .working
        if case .candidate(let candidate) = status { acceptCandidate?(candidate) }
        if !inFlight { acceptCandidate = nil }
        state = status
        output.onNext(status)
        // Updating the transcript should not repeatedly restart an in-flight model.
        submitIfReady()
    }
    public func cancel() {
        lastSubmitted = nil
        acceptCandidate = nil
        discardScheduledWork()
        revision += 1
        inFlight = false
        requests.onNext(Submission(revision: revision, request: nil))
    }
    public func shutdown() async { cancel(); await task?.value }
}
