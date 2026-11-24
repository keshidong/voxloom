import Foundation
import SpeechFoundation
import SpeechInput

enum VoiceSampleKind: String, CaseIterable {
    case quiet, normal, loud

    var label: String {
        switch self {
        case .quiet: "轻声"
        case .normal: "正常"
        case .loud: "大声"
        }
    }
}

struct VoiceSampleStore {
    let directory: URL

    func read(_ kind: VoiceSampleKind) throws -> AudioClip? {
        guard contains(kind) else { return nil }
        return try WAVCodec.decode(Data(contentsOf: file(for: kind)))
    }

    func contains(_ kind: VoiceSampleKind) -> Bool {
        FileManager.default.fileExists(atPath: file(for: kind).path)
    }

    func write(_ clip: AudioClip, for kind: VoiceSampleKind) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let destination = file(for: kind)
        try WAVCodec.encode(clip).write(to: destination, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    func remove(_ kind: VoiceSampleKind) throws {
        if contains(kind) { try FileManager.default.removeItem(at: file(for: kind)) }
    }

    private func file(for kind: VoiceSampleKind) -> URL {
        directory.appendingPathComponent(kind.rawValue + ".wav")
    }
}

@MainActor final class VoiceEnrollment {
    static let minimumSamples = 3 * AudioClip.sampleRate
    static let maximumSamples = 8 * AudioClip.sampleRate

    private let makeCapture: () -> any AudioCapturing
    private let player: any VoiceSamplePlaying
    let store: VoiceSampleStore
    private(set) var active: VoiceSampleKind?
    private(set) var isRecording = false
    private(set) var notice: String?
    var playing: VoiceSampleKind? { playback?.kind }
    var onChange: (() -> Void)?
    private var capture: (any AudioCapturing)?
    private var samples: [Int16] = []
    private var takeID: UUID?
    private var authorization: Task<Void, Never>?
    private var playback: (kind: VoiceSampleKind, id: UUID)?

    init(store: VoiceSampleStore, makeCapture: @escaping () -> any AudioCapturing,
         player: any VoiceSamplePlaying = VoiceSamplePlayback()) {
        self.store = store
        self.makeCapture = makeCapture
        self.player = player
    }

    func toggle(_ kind: VoiceSampleKind) {
        if active == kind { finish(); return }
        guard active == nil else { return }
        clearPlayback()
        let take = UUID()
        let capture = makeCapture()
        self.capture = capture
        active = kind
        takeID = take
        notice = "正在准备麦克风"
        onChange?()
        authorization = Task { [weak self] in
            do {
                try await capture.requestAccess()
                guard let self, takeID == take else { return }
                try capture.start(samples: { [weak self] samples in
                    DispatchQueue.main.async { [weak self] in self?.receive(samples, take: take) }
                }, ended: { [weak self] message in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.takeID == take else { return }
                        if let message { self.end(notice: message) } else { self.finish() }
                    }
                })
                isRecording = true
                notice = "正在录制\(kind.label)，说完后点「保存」"
                onChange?()
            } catch {
                if self?.takeID == take { self?.end(notice: error.localizedDescription) }
            }
        }
    }

    func cancel() {
        clearPlayback()
        end(notice: nil)
    }

    func togglePlayback(_ kind: VoiceSampleKind) {
        guard active == nil else { return }
        if playing == kind { stopPlayback(); return }
        do {
            guard let clip = try store.read(kind) else { return }
            clearPlayback()
            let id = UUID()
            playback = (kind, id)
            notice = nil
            try player.play(clip) { [weak self] success in
                guard let self, playback?.id == id else { return }
                playback = nil
                if !success { notice = "无法播放\(kind.label)样本" }
                onChange?()
            }
            onChange?()
        } catch {
            clearPlayback()
            showNotice("无法播放\(kind.label)样本")
        }
    }

    func stopPlayback() {
        guard playback != nil else { return }
        clearPlayback()
        onChange?()
    }

    private func clearPlayback() {
        playback = nil
        player.stop()
    }

    func showNotice(_ notice: String) {
        self.notice = notice
        onChange?()
    }

    func remove(_ kind: VoiceSampleKind) {
        guard active == nil else { return }
        if playing == kind { clearPlayback() }
        do {
            try store.remove(kind)
            notice = "已删除\(kind.label)样本"
        } catch { notice = "无法删除语音样本" }
        onChange?()
    }

    private func receive(_ samples: [Int16], take: UUID) {
        guard takeID == take else { return }
        self.samples.append(contentsOf: samples.prefix(Self.maximumSamples - self.samples.count))
        if self.samples.count == Self.maximumSamples { finish() }
    }

    private func finish() {
        guard let active else { return }
        guard isRecording else { cancel(); return }
        let audible = samples.lazy.filter { abs(Int($0)) >= 24 }.prefix(AudioClip.sampleRate).count
        guard samples.count >= Self.minimumSamples, audible == AudioClip.sampleRate else {
            end(notice: "请录至少 3 秒清晰的本人声音")
            return
        }
        do {
            try store.write(AudioClip(samples: samples), for: active)
            end(notice: "已保存\(active.label)样本")
        } catch { end(notice: "无法保存语音样本") }
    }

    private func end(notice: String?) {
        takeID = nil
        active = nil
        isRecording = false
        authorization?.cancel()
        authorization = nil
        capture?.stop()
        capture = nil
        samples.removeAll()
        self.notice = notice
        onChange?()
    }
}
