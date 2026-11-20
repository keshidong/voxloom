import Foundation

public enum WAVCodec {
    public static let maximumFileSize = 2_000_000

    public static func decode(_ data: Data) throws -> AudioClip {
        guard data.count <= maximumFileSize else { throw AudioError.tooLong }
        let bytes = Array(data)
        guard bytes.count >= 12,
              Array(bytes[0..<4]) == Array("RIFF".utf8),
              Array(bytes[8..<12]) == Array("WAVE".utf8),
              number(bytes, at: 4, length: 4) + 8 == bytes.count
        else { throw AudioError.malformedWAV }

        var offset = 12
        var formatFound = false
        var samples: [Int16]?
        while offset < bytes.count {
            guard offset + 8 <= bytes.count else { throw AudioError.malformedWAV }
            let kind = Array(bytes[offset..<(offset + 4)])
            let length = number(bytes, at: offset + 4, length: 4)
            let start = offset + 8
            guard length <= bytes.count - start else { throw AudioError.malformedWAV }
            if kind == Array("fmt ".utf8) {
                guard !formatFound, length >= 16 else { throw AudioError.malformedWAV }
                guard number(bytes, at: start, length: 2) == 1,
                      number(bytes, at: start + 2, length: 2) == 1,
                      number(bytes, at: start + 4, length: 4) == AudioClip.sampleRate,
                      number(bytes, at: start + 8, length: 4) == AudioClip.sampleRate * 2,
                      number(bytes, at: start + 12, length: 2) == 2,
                      number(bytes, at: start + 14, length: 2) == 16
                else { throw AudioError.unsupportedFormat }
                formatFound = true
            } else if kind == Array("data".utf8) {
                guard samples == nil, length.isMultiple(of: 2) else { throw AudioError.malformedWAV }
                samples = stride(from: start, to: start + length, by: 2).map {
                    Int16(bitPattern: UInt16(number(bytes, at: $0, length: 2)))
                }
            }
            offset = start + length + length % 2
            guard offset <= bytes.count else { throw AudioError.malformedWAV }
        }
        guard formatFound, let samples else { throw AudioError.malformedWAV }
        return try AudioClip(samples: samples)
    }

    private static func number(_ bytes: [UInt8], at start: Int, length: Int) -> Int {
        (0..<length).reduce(0) { $0 | Int(bytes[start + $1]) << ($1 * 8) }
    }

    public static func encode(_ audio: AudioClip) -> Data {
        var data = Data("RIFF".utf8)
        append(UInt32(36 + audio.samples.count * 2), bytes: 4, to: &data)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(16, bytes: 4, to: &data)
        append(1, bytes: 2, to: &data)
        append(1, bytes: 2, to: &data)
        append(UInt32(AudioClip.sampleRate), bytes: 4, to: &data)
        append(UInt32(AudioClip.sampleRate * 2), bytes: 4, to: &data)
        append(2, bytes: 2, to: &data)
        append(16, bytes: 2, to: &data)
        data.append(contentsOf: "data".utf8)
        append(UInt32(audio.samples.count * 2), bytes: 4, to: &data)
        for sample in audio.samples {
            append(UInt32(UInt16(bitPattern: sample)), bytes: 2, to: &data)
        }
        return data
    }

    private static func append(_ value: UInt32, bytes: Int, to data: inout Data) {
        for offset in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (offset * 8))) }
    }
}
