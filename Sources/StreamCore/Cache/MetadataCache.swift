import CryptoKit
import Foundation

/// Keyed raw-Data cache: in-memory dictionary backed by files on disk.
/// The file's modification date is the written-at stamp; freshness is
/// checked against `ttl` at read time. All failures degrade to a miss.
public actor MetadataCache {
    public static let shared = MetadataCache()

    private let directory: URL
    private let now: @Sendable () -> Date
    private var memory: [String: (stamp: Date, data: Data)] = [:]

    public init(directory: URL? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.riptide/metadata", isDirectory: true)
        self.now = now
        try? FileManager.default.createDirectory(
            at: self.directory, withIntermediateDirectories: true)
    }

    public func data(for key: String, ttl: TimeInterval) -> Data? {
        if let hit = memory[key], now().timeIntervalSince(hit.stamp) < ttl {
            return hit.data
        }
        let url = fileURL(for: key)
        guard
            let attrs = try? FileManager.default
                .attributesOfItem(atPath: url.path),
            let modified = attrs[.modificationDate] as? Date,
            now().timeIntervalSince(modified) < ttl,
            let data = try? Data(contentsOf: url)
        else { return nil }
        memory[key] = (modified, data)
        return data
    }

    public func store(_ data: Data, for key: String) {
        memory[key] = (now(), data)
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    public func clear() {
        memory.removeAll()
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
    }

    public func diskBytesUsed() -> Int64 {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?
                .fileSize ?? 0
            return total + Int64(size)
        }
    }

    public func sweep(olderThan age: TimeInterval) {
        let fm = FileManager.default
        let cutoff = now().addingTimeInterval(-age)
        let urls = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in urls {
            let modified = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: url) }
        }
    }

    private func fileURL(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }
}
