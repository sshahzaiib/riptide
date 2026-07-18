import Foundation

/// Token bucket in bytes. Tokens may go NEGATIVE to represent owed debt, so that
/// many reservers at the same instant accumulate (rather than share) wait time.
/// `bytesPerSecond == 0` means unlimited.
public struct TokenBucket: Sendable {
    public let capacity: Double
    public let refillPerSecond: Double
    private var tokens: Double
    private var lastRefill: TimeInterval

    public init(bytesPerSecond: Double, now: TimeInterval) {
        self.refillPerSecond = max(bytesPerSecond, 0)
        self.capacity = max(bytesPerSecond, 1)   // ~1s burst
        self.tokens = capacity
        self.lastRefill = now
    }

    public mutating func reserve(_ amount: Double, now: TimeInterval) -> TimeInterval {
        guard refillPerSecond > 0 else { return 0 }     // unlimited
        if now > lastRefill {                            // refill only forward in time
            tokens = min(capacity, tokens + (now - lastRefill) * refillPerSecond)
            lastRefill = now
        }
        tokens -= amount                                 // may go negative (debt)
        if tokens >= 0 { return 0 }
        let recover = -tokens / refillPerSecond          // time to repay the debt
        return max(0, lastRefill - now) + recover
    }
}
