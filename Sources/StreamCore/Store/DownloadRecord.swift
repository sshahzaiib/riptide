import Foundation
import SwiftData

public enum DownloadState: String, Sendable {
    case downloading, completed, failed, paused
}

/// One local download / on-disk copy of a LibraryItem's file. A record with
/// `state == .completed` and an existing file at `localPath` IS the local
/// library entry — there is no separate catalog table.
@Model
public final class DownloadRecord {
    @Attribute(.unique) public var itemKey: String
    public var localPath: String
    public var stateRaw: String
    public var totalBytes: Int64
    public var downloadedBytes: Int64
    public var title: String
    public var filename: String
    public var errorMessage: String?
    public var createdAt: Date

    public var state: DownloadState {
        get { DownloadState(rawValue: stateRaw) ?? .failed }
        set { stateRaw = newValue.rawValue }
    }

    public init(itemKey: String, localPath: String, state: DownloadState,
                totalBytes: Int64 = 0, downloadedBytes: Int64 = 0,
                title: String, filename: String, errorMessage: String? = nil,
                createdAt: Date = .now) {
        self.itemKey = itemKey
        self.localPath = localPath
        self.stateRaw = state.rawValue
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.title = title
        self.filename = filename
        self.errorMessage = errorMessage
        self.createdAt = createdAt
    }
}
