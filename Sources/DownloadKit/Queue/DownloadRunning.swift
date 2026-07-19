import Foundation

/// The single capability the queue needs from a downloader. `DownloadEngine.start`
/// already matches this exactly, so the conformance is free — and tests can inject a
/// controllable double to make concurrency/scheduling deterministic.
public protocol DownloadRunning: Sendable {
    func start(url: URL, destination: URL, connections: Int, bytesPerSecond: Double) -> AsyncStream<DownloadProgress>
}

extension DownloadEngine: DownloadRunning {}
