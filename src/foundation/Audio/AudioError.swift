public enum AudioError: Error, Sendable, Equatable {
    case tooLong
    case malformedWAV
    case unsupportedFormat
}
