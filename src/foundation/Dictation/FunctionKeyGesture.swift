public struct FunctionKeyGesture: Sendable {
    public enum Action: Equatable, Sendable { case start, stop, interrupted, confirm }

    private enum Phase { case released, pressed, holding }
    private var phase = Phase.released
    private var firstTap: Double?

    public init() {}

    public var isHolding: Bool { phase == .holding }

    public mutating func press() -> Bool {
        guard phase == .released else { return false }
        phase = .pressed
        return true
    }

    public mutating func reachHoldThreshold() -> Action? {
        guard phase == .pressed else { return nil }
        phase = .holding
        firstTap = nil
        return .start
    }

    /// The timestamp is monotonic seconds. A pair of taps can confirm an available draft.
    public mutating func release(at timestamp: Double, canConfirm: Bool) -> Action? {
        let previous = phase
        phase = .released
        if previous == .holding { return .stop }
        guard previous == .pressed else { return nil }
        guard canConfirm else { firstTap = nil; return nil }
        if let firstTap, timestamp >= firstTap, timestamp - firstTap <= 0.35 {
            self.firstTap = nil
            return .confirm
        }
        firstTap = timestamp
        return nil
    }

    public mutating func interrupt() -> Action? {
        let wasHolding = phase == .holding
        phase = .released
        firstTap = nil
        return wasHolding ? .interrupted : nil
    }
}
