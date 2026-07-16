import Foundation

/// Per-item on-disk store for downloaded OpenSubtitles files. The folder
/// listing IS the record of downloads — no manifest, no database.
/// Layout: ~/Library/Application Support/Riptide/subs/<itemKey>/<fileID>-<name>
enum SubtitleCache {
    /// The item's cache folder, created on demand. nil for empty itemKey
    /// (debug-URL playback) or on creation failure — callers degrade to
    /// the old un-cached behavior.
    static func directory(for itemKey: String) -> URL? {
        guard !itemKey.isEmpty,
              let base = FileManager.default.urls(
                  for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("Riptide/subs/\(itemKey)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch { return nil }
        return dir
    }

    static func cachedFiles(for itemKey: String) -> [URL] {
        guard let dir = directory(for: itemKey),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        else { return [] }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// fileIDs parsed from the "<fileID>-" filename prefix.
    static func cachedFileIDs(for itemKey: String) -> Set<Int> {
        Set(cachedFiles(for: itemKey).compactMap {
            $0.lastPathComponent.split(separator: "-", maxSplits: 1).first.flatMap { Int($0) }
        })
    }

    static func cachedFile(for itemKey: String, fileID: Int) -> URL? {
        cachedFiles(for: itemKey).first { $0.lastPathComponent.hasPrefix("\(fileID)-") }
    }

    /// Rename a freshly downloaded file to the "<fileID>-<name>" scheme.
    /// Replaces any existing destination (same fileID = same content).
    static func prefixed(_ file: URL, fileID: Int) throws -> URL {
        let dest = file.deletingLastPathComponent()
            .appendingPathComponent("\(fileID)-\(file.lastPathComponent)")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: file, to: dest)
        return dest
    }
}
