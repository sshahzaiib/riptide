import Foundation

/// A daily time window in minutes-of-day. Half-open `[start, stop)`; wraps past
/// midnight when `start > stop`. `start == stop` is an empty window (always closed) —
/// represent "no restriction" with `nil` at the call site, not a zero-width window.
public struct TimeWindow: Sendable, Equatable {
    public let startMinute: Int   // 0...1439
    public let stopMinute: Int    // 0...1439

    public init(startMinute: Int, stopMinute: Int) {
        self.startMinute = TimeWindow.normalize(startMinute)
        self.stopMinute = TimeWindow.normalize(stopMinute)
    }

    public init(startHour: Int, startMin: Int, stopHour: Int, stopMin: Int) {
        self.init(startMinute: startHour * 60 + startMin, stopMinute: stopHour * 60 + stopMin)
    }

    public func contains(_ minute: Int) -> Bool {
        let m = TimeWindow.normalize(minute)
        if startMinute == stopMinute { return false }            // empty window
        if startMinute < stopMinute { return m >= startMinute && m < stopMinute }
        return m >= startMinute || m < stopMinute                // wraps midnight
    }

    public static func minuteOfDay(of date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private static func normalize(_ minute: Int) -> Int { ((minute % 1440) + 1440) % 1440 }
}
