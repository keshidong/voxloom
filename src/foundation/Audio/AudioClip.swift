/// Mono, 16 kHz, signed 16-bit PCM. No device or file ownership.
public struct AudioClip: Sendable, Equatable {
    public static let sampleRate = 16_000
    public static let maximumSamples = sampleRate * 60
    public let samples: [Int16]

    public init(samples: [Int16]) throws {
        guard samples.count <= Self.maximumSamples else { throw AudioError.tooLong }
        self.samples = samples
    }

    public var duration: Double { Double(samples.count) / Double(Self.sampleRate) }
}
