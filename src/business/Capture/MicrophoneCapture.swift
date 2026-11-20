import AVFoundation
import Foundation

@MainActor public final class MicrophoneCapture: AudioCapturing {
    public private(set) var sourceDescription = "系统默认麦克风"
    private var engine: AVAudioEngine?
    private var configurationObserver: (any NSObjectProtocol)?
    private var tappedInput: AVAudioNode?
    private let requestPermission: @MainActor () async -> Bool
    private let isAuthorized: @MainActor () -> Bool
    private let makeInput: @MainActor () -> (AVAudioEngine, AVAudioNode)
    private let installTap: @MainActor (AVAudioNode, AVAudioFormat, @escaping AVAudioNodeTapBlock) -> Void
    public init() {
        requestPermission = { await AVCaptureDevice.requestAccess(for: .audio) }
        isAuthorized = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
        makeInput = { let engine = AVAudioEngine(); return (engine, engine.inputNode) }
        installTap = { node, format, callback in node.installTap(onBus: 0, bufferSize: 2048, format: format, block: callback) }
    }

    init(requestPermission: @escaping @MainActor () async -> Bool,
         isAuthorized: @escaping @MainActor () -> Bool,
         makeInput: @escaping @MainActor () -> (AVAudioEngine, AVAudioNode),
         installTap: @escaping @MainActor (AVAudioNode, AVAudioFormat, @escaping AVAudioNodeTapBlock) -> Void = {
             node, format, callback in node.installTap(onBus: 0, bufferSize: 2048, format: format, block: callback)
         }) {
        self.requestPermission = requestPermission
        self.isAuthorized = isAuthorized
        self.makeInput = makeInput
        self.installTap = installTap
    }

    public func requestAccess() async throws {
        guard await requestPermission() else { throw CaptureError.denied }
    }

    public func start(samples: @escaping @Sendable ([Int16]) -> Void, ended: @escaping @Sendable (String?) -> Void) throws {
        stop()
        guard isAuthorized() else { throw CaptureError.denied }
        let (engine, input) = makeInput()
        let format = input.outputFormat(forBus: 0)
        let name = AVCaptureDevice.default(for: .audio)?.localizedName ?? "系统默认麦克风"
        sourceDescription = "\(name) · \(Int(format.sampleRate)) Hz"
        let converter = try PCMConverter(format: format)
        installTap(input, format) { @Sendable buffer, _ in
            do { samples(try converter.convert(buffer)) }
            catch { ended(CaptureError.conversion.localizedDescription) }
        }
        self.engine = engine
        tappedInput = input
        do { try engine.start() } catch { stop(); throw CaptureError.unavailable }
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main) { @Sendable _ in
                ended("音频设备发生变化，请重新开始录音。")
            }
    }

    public func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        tappedInput?.removeTap(onBus: 0)
        tappedInput = nil
        engine?.stop()
        engine = nil
    }
}
