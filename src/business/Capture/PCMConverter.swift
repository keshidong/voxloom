import AVFoundation
import SpeechFoundation

/// AVAudioConverter is confined to the single serial audio callback.
final class PCMConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    init(format: AVAudioFormat) throws {
        guard format.sampleRate > 0, format.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: output) else { throw CaptureError.unavailable }
        self.converter = converter
        converter.primeMethod = .none
    }
    func convert(_ buffer: AVAudioPCMBuffer) throws -> [Int16] {
        guard buffer.format == converter.inputFormat else { throw CaptureError.conversion }
        if buffer.frameLength == 0 { return [] }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity)
        else { throw CaptureError.conversion }
        let reader = AudioBufferReader(buffer: buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { requested, state in
            let slice = reader.next(frames: Int(requested))
            state.pointee = slice == nil ? .noDataNow : .haveData
            return slice
        }
        guard status != .error, error == nil, let channel = output.int16ChannelData else { throw CaptureError.conversion }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}

// Input may be requested in several blocks, each smaller than the original buffer.
// Owns the cursor and serializes access for the converter's Sendable callback.
private final class AudioBufferReader: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let lock = NSLock()
    var offset = 0
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func next(frames requested: Int) -> AVAudioPCMBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard offset < Int(buffer.frameLength), requested > 0 else { return nil }
        let frames = min(requested, Int(buffer.frameLength) - offset)
        guard let slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        slice.frameLength = AVAudioFrameCount(frames)
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(slice.mutableAudioBufferList)
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        for index in 0..<source.count {
            memcpy(destination[index].mData!, source[index].mData!.advanced(by: offset * bytesPerFrame), frames * bytesPerFrame)
        }
        offset += frames
        return slice
    }
}

public enum CaptureError: Error, LocalizedError, Sendable {
    case denied, unavailable, conversion
    public var errorDescription: String? {
        switch self {
        case .denied: "请在系统设置 → 隐私与安全性 → 麦克风中允许语音 Demo 访问，然后重新打开。"
        case .unavailable: "麦克风不可用，请检查系统声音输入设备，或重新连接 AirPods。"
        case .conversion: "音频转换失败，请停止后重试。"
        }
    }
}
