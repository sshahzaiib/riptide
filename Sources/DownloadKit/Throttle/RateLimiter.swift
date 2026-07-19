import Foundation

public actor RateLimiter {
    private var bucket: TokenBucket
    private let unlimited: Bool

    public init(bytesPerSecond: Double) {
        self.unlimited = bytesPerSecond <= 0
        self.bucket = TokenBucket(bytesPerSecond: bytesPerSecond, now: nowSeconds())
    }

    public func throttle(_ bytes: Int) async {
        guard !unlimited else { return }
        let wait = bucket.reserve(Double(bytes), now: nowSeconds())
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }
}
