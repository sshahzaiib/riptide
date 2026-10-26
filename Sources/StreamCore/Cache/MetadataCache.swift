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

    public func data(for key: String, ttl: TimeInterval,
                     notBefore: Date? = nil) -> Data? {
        func valid(_ stamp: Date) -> Bool {
            now().timeIntervalSince(stamp) < ttl
                && (notBefore.map { stamp >= $0 } ?? true)
        }
        if let hit = memory[key] {
            if valid(hit.stamp) { return hit.data }
            memory.removeValue(forKey: key)
            // Same stamp is on disk; don't fall through and resurrect it.
            return nil
        }
        let url = fileURL(for: key)
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let modified = attrs[.modificationDate] as? Date,
            valid(modified),
            let data = try? Data(contentsOf: url)
        else { return nil }
        memory[key] = (modified, data)
        return data
    }

    /// Purge every entry whose key starts with `prefix`, from memory and disk.
    /// Precondition: `prefix` must not contain "/" (memory filters by
    /// `hasPrefix`, disk by the sanitized namespace before the first "/").
    public func remove(prefix: String) {
        memory = memory.filter { !$0.key.hasPrefix(prefix) }
        let filePrefix = Self.sanitize(prefix.prefix(while: { $0 != "/" }))
        guard !filePrefix.isEmpty else { return }
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix(filePrefix) {
            try? fm.removeItem(at: url)
        }
    }

    public func store(_ data: Data, for key: String) {
        let currentDate = now()
        memory[key] = (currentDate, data)
        let url = fileURL(for: key)
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.modificationDate: currentDate], ofItemAtPath: url.path)
        } catch {}
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
        memory = memory.filter { $0.value.stamp >= cutoff }
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

    /// Filename namespace: the key up to (excluding) its first "/", with every
    /// non-alphanumeric mapped to "_". 1:1 char mapping keeps string-prefix
    /// relations intact, so remove(prefix:) can match on filenames alone.
    nonisolated private static func sanitize(_ s: Substring) -> String {
        String(s.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    nonisolated static func fileName(for key: String) -> String {
        let namespace = sanitize(key.prefix(while: { $0 != "/" }))
        let hash = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return namespace + "-" + hash + ".json"
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(Self.fileName(for: key))
    }
}
