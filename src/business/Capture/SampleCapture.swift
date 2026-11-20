import SpeechFoundation
import RxSwift

/// Clearly labelled public recording; used for a no-microphone demo and E2E.
@MainActor public final class SampleCapture: AudioCapturing {
    public var sourceDescription: String { realtime ? "示例录音 · 16000 Hz" : "复用本次录音 · 16000 Hz" }
    private let audio: AudioClip
    private let scheduler: any SchedulerType
    private var timer: (any Disposable)?
    private let realtime: Bool
    public init(audio: AudioClip, scheduler: any SchedulerType = MainScheduler.instance, realtime: Bool = true) {
        self.audio = audio
        self.scheduler = scheduler
        self.realtime = realtime
    }
    public func requestAccess() async throws {}
    public func start(samples: @escaping @Sendable ([Int16]) -> Void, ended: @escaping @Sendable (String?) -> Void) throws {
        stop()
        if !realtime { samples(audio.samples); ended(nil); return }
        let audio = audio
        var offset = 0
        timer = Observable<Int>.interval(.milliseconds(100), scheduler: scheduler).subscribe(onNext: { _ in
            let end = min(offset + 1600, audio.samples.count)
            samples(Array(audio.samples[offset..<end]))
            offset = end
            if offset == audio.samples.count { self.stop(); ended(nil) }
        })
    }
    public func stop() { timer?.dispose(); timer = nil }
}
