import Foundation

public enum BackupError: Error, LocalizedError {
    case unsupportedVersion(Int)
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "This backup was made by a newer Riptide (format \(v)). Update Riptide to restore it."
        }
    }
}

public struct BackupFile: Codable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var createdAt: Date
    public var keychain: [String: String]
    /// JSONSerialization of the defaults domain dictionary.
    // ponytail: JSON can't carry Date/Data plist values; the app stores none in defaults today.
    public var defaults: Data
    public var history: [HistoryEntryDTO]
    public var watchStates: [WatchStateDTO]

    public init(version: Int = currentVersion, createdAt: Date, keychain: [String: String], defaults: Data,
                history: [HistoryEntryDTO], watchStates: [WatchStateDTO]) {
        self.version = version; self.createdAt = createdAt; self.keychain = keychain
        self.defaults = defaults; self.history = history; self.watchStates = watchStates
    }

    public static func decode(_ data: Data) throws -> BackupFile {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let file = try d.decode(BackupFile.self, from: data)
        if file.version > currentVersion { throw BackupError.unsupportedVersion(file.version) }
        return file
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .prettyPrinted
        return try e.encode(self)
    }
}
