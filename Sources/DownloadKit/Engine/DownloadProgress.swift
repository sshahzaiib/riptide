import Foundation

public enum DownloadPhase: Sendable, Equatable { case queued, probing, downloading, completed, failed(String) }

public struct DownloadProgress: Sendable, Equatable {
    public let bytesDownloaded: Int64
    public let totalBytes: Int64?
    public let bytesPerSecond: Double
    public let phase: DownloadPhase
    public init(bytesDownloaded: Int64, totalBytes: Int64?, bytesPerSecond: Double, phase: DownloadPhase) {
        self.bytesDownloaded = bytesDownloaded; self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond; self.phase = phase
    }
}
