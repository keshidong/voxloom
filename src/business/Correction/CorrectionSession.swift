import Foundation
import SpeechFoundation
import RxSwift

public enum CorrectionStatus: Sendable, Equatable {
    case idle, working, candidate(CorrectionCandidate), failed(String)
}

@MainActor public final class CorrectionSession {
    private struct Pending: Equatable {
        let epoch: Int
        let request: CorrectionRequest?
    }
    public private(set) var state: CorrectionStatus = .idle
    private let requests = PublishSubject<CorrectionRequest?>()
    private let output = BehaviorSubject<CorrectionStatus>(value: .idle)
    private let bag = DisposeBag()
    private var task: Task<Void, Never>?
    private let corrector: any TextCorrecting
    private let updates = PublishSubject<Pending>()
    private var epoch = 0
    private var lastSubmitted: CorrectionRequest?
    public var states: Observable<CorrectionStatus> { output.asObservable() }
    public init(corrector: any TextCorrecting, scheduler: any SchedulerType = MainScheduler.instance) {
        self.corrector = corrector
        requests.flatMapLatest { [weak self, corrector] request -> Observable<CorrectionStatus> in
            guard let request else { return .just(.idle) }
            return Observable.create { observer in
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
            }.startWith(.working)
        }.observe(on: MainScheduler.asyncInstance).subscribe(onNext: { [weak self] status in
            self?.state = status
            self?.output.onNext(status)
        }).disposed(by: bag)
        let changes = updates.distinctUntilChanged().share()
        Observable.merge(changes.debounce(.milliseconds(800), scheduler: scheduler),
                         changes.sample(Observable<Int>.interval(.seconds(3), scheduler: scheduler)))
            .distinctUntilChanged().subscribe(onNext: { [weak self] pending in
                guard let self, pending.epoch == epoch, let request = pending.request else { return }
                submit(request)
            }).disposed(by: bag)
    }
    public func run(_ request: CorrectionRequest) {
        updates.onNext(Pending(epoch: epoch, request: nil))
        submit(request)
    }
    public func update(_ request: CorrectionRequest) { updates.onNext(Pending(epoch: epoch, request: request)) }
    private func submit(_ request: CorrectionRequest) {
        if request == lastSubmitted, case .failed = state {} else if request == lastSubmitted { return }
        lastSubmitted = request
        requests.onNext(request)
    }
    public func cancel() {
        epoch += 1
        lastSubmitted = nil
        updates.onNext(Pending(epoch: epoch, request: nil))
        requests.onNext(nil)
    }
    public func shutdown() async { cancel(); await task?.value }
}
