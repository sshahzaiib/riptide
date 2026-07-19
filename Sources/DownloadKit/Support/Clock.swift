import Foundation

/// Monotonic time in seconds; unaffected by wall-clock changes.
public func nowSeconds() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
