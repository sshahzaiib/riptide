// Sources/StreamCore/Debrid/TransferDiff.swift
import Foundation

/// Pure ready-transition detector for the Downloads poller.
public enum TransferDiff {
    /// Keys whose status changed from a previously observed non-ready state
    /// to ready. Keys absent from `previous` (first poll, or already ready
    /// at first sight) never fire — launch must not replay notifications.
    public static func newlyReady(previous: [String: DebridTransfer.Status],
                                  current: [String: DebridTransfer.Status]) -> [String] {
        current.compactMap { key, status in
            guard status == .ready,
                  let old = previous[key], old != .ready else { return nil }
            return key
        }
        .sorted()
    }
}
