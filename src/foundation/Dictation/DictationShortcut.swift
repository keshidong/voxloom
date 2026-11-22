public struct DictationShortcut: Sendable {
    public enum Action: Equatable { case start, confirm }

    private var firstPress: Double?

    public init() {}

    public mutating func press(at timestamp: Double, isEditing: Bool) -> Action? {
        guard isEditing else {
            firstPress = nil
            return .start
        }
        if let first = firstPress, timestamp >= first, timestamp - first <= 0.35 {
            firstPress = nil
            return .confirm
        }
        firstPress = timestamp
        return nil
    }
}
