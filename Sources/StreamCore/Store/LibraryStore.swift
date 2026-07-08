import Foundation
import SwiftData

public struct UpsertSummary: Equatable, Sendable {
    public var inserted: Int
    public var updated: Int
    public var deleted: Int

    public init(inserted: Int, updated: Int, deleted: Int) {
        self.inserted = inserted; self.updated = updated; self.deleted = deleted
    }
}

/// SwiftData-backed library cache + watch positions. MainActor because the app
/// reads it from SwiftUI; all operations are synchronous on the main context.
@MainActor
public final class LibraryStore {
    public let container: ModelContainer
    let context: ModelContext

    public init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    public static func inMemory() throws -> LibraryStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: LibraryItem.self, WatchState.self,
                                           configurations: config)
        return LibraryStore(container: container)
    }

    /// On-disk store in Application Support. Pre-1.0 schema policy: if the
    /// container fails to open (schema changed), wipe and recreate rather
    /// than migrate.
    public static func onDisk() throws -> LibraryStore {
        do {
            let container = try ModelContainer(for: LibraryItem.self, WatchState.self)
            return LibraryStore(container: container)
        } catch {
            let support = URL.applicationSupportDirectory
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(
                    at: support.appendingPathComponent("default.store\(suffix)"))
            }
            let container = try ModelContainer(for: LibraryItem.self, WatchState.self)
            return LibraryStore(container: container)
        }
    }

    // MARK: Library sync

    /// Mirror the flattened RD file list into the cache: insert new, update
    /// changed (filename/link/size), delete vanished. Parsing happens here so
    /// the UI never sees an unparsed item.
    public func upsert(entries: [LibraryFileEntry]) throws -> UpsertSummary {
        let existing = try context.fetch(FetchDescriptor<LibraryItem>())
        var byKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.itemKey, $0) })
        var summary = UpsertSummary(inserted: 0, updated: 0, deleted: 0)
        var processed = Set<String>()

        for entry in entries {
            guard processed.insert(entry.itemKey).inserted else { continue }
            if let item = byKey.removeValue(forKey: entry.itemKey) {
                if item.filename != entry.filename || item.link != entry.link
                    || item.sizeBytes != entry.bytes {
                    let parsed = ReleaseNameParser.parse(entry.filename)
                    item.filename = entry.filename
                    item.sizeBytes = entry.bytes
                    item.link = entry.link
                    item.title = parsed.title
                    item.year = parsed.year
                    item.season = parsed.season
                    item.episode = parsed.episode
                    item.quality = parsed.quality
                    item.mediaKind = parsed.isTV ? "episode" : "movie"
                    // Filename changed -> stale match; rematch on next refresh.
                    item.tmdbID = nil
                    item.posterPath = nil
                    item.overview = nil
                    item.rating = nil
                    item.lastRefreshed = .now
                    summary.updated += 1
                }
            } else {
                context.insert(LibraryItem(entry: entry,
                                           parsed: ReleaseNameParser.parse(entry.filename)))
                summary.inserted += 1
            }
        }
        // Anything left in byKey no longer exists on RD. Drop its watch state
        // too, or Continue Watching would keep offering dead entries.
        if !byKey.isEmpty {
            let allStates = try context.fetch(FetchDescriptor<WatchState>())
            for (_, orphan) in byKey {
                for state in allStates where state.itemKey == orphan.itemKey {
                    context.delete(state)
                }
                context.delete(orphan)
                summary.deleted += 1
            }
        }
        try context.save()
        return summary
    }

    public func items() throws -> [LibraryItem] {
        try context.fetch(FetchDescriptor<LibraryItem>(
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]))
    }

    /// Item count per torrent — lets the refresher skip torrentInfo calls for
    /// packs it has already expanded.
    public func entryCounts() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in try context.fetch(FetchDescriptor<LibraryItem>()) {
            counts[item.torrentID, default: 0] += 1
        }
        return counts
    }

    /// Reconstruct the sync entries for one torrent from cached items (so a
    /// skipped torrentInfo call still contributes to the upsert input).
    public func cachedEntries(torrentID: String) throws -> [LibraryFileEntry] {
        let descriptor = FetchDescriptor<LibraryItem>(
            predicate: #Predicate { $0.torrentID == torrentID })
        return try context.fetch(descriptor).map {
            LibraryFileEntry(torrentID: $0.torrentID, fileIndex: $0.fileIndex,
                             filename: $0.filename, bytes: $0.sizeBytes,
                             added: $0.addedAt, link: $0.link)
        }
    }

    public func applyMatch(itemKey: String, tmdbID: Int, mediaKind: String,
                           posterPath: String?, overview: String?, rating: Double?) throws {
        let descriptor = FetchDescriptor<LibraryItem>(
            predicate: #Predicate { $0.itemKey == itemKey })
        guard let item = try context.fetch(descriptor).first else { return }
        item.tmdbID = tmdbID
        item.mediaKind = mediaKind
        item.posterPath = posterPath
        item.overview = overview
        item.rating = rating
        item.lastRefreshed = .now
        try context.save()
    }

    // MARK: Watch state

    /// Playback position. >= 95% watched marks the item finished (spec).
    public func saveProgress(itemKey: String, position: Double, duration: Double) throws {
        let descriptor = FetchDescriptor<WatchState>(
            predicate: #Predicate { $0.itemKey == itemKey })
        let finished = duration > 0 && position / duration >= 0.95
        if let state = try context.fetch(descriptor).first {
            state.positionSeconds = position
            state.durationSeconds = duration
            state.lastWatchedAt = .now
            state.finished = finished
        } else {
            context.insert(WatchState(itemKey: itemKey, positionSeconds: position,
                                      durationSeconds: duration, finished: finished))
        }
        try context.save()
    }

    /// Remote (Trakt) playback position. Unlike saveProgress this keeps the
    /// caller's timestamp so newer-wins comparisons stay correct.
    public func applyRemoteProgress(itemKey: String, position: Double,
                                    duration: Double, watchedAt: Date) throws {
        let descriptor = FetchDescriptor<WatchState>(
            predicate: #Predicate { $0.itemKey == itemKey })
        if let state = try context.fetch(descriptor).first {
            state.positionSeconds = position
            state.durationSeconds = duration
            state.lastWatchedAt = watchedAt
            state.finished = false
        } else {
            let state = WatchState(itemKey: itemKey, positionSeconds: position,
                                   durationSeconds: duration, finished: false)
            state.lastWatchedAt = watchedAt
            context.insert(state)
        }
        try context.save()
    }

    /// Remote (Trakt) watched marker: finished, position/duration preserved.
    public func applyRemoteWatched(itemKey: String, watchedAt: Date) throws {
        let descriptor = FetchDescriptor<WatchState>(
            predicate: #Predicate { $0.itemKey == itemKey })
        if let state = try context.fetch(descriptor).first {
            state.finished = true
            state.lastWatchedAt = watchedAt
        } else {
            let state = WatchState(itemKey: itemKey, positionSeconds: 0,
                                   durationSeconds: 0, finished: true)
            state.lastWatchedAt = watchedAt
            context.insert(state)
        }
        try context.save()
    }

    /// Unfinished, started items, most recently watched first.
    public func continueWatching() throws -> [WatchState] {
        try context.fetch(FetchDescriptor<WatchState>(
            predicate: #Predicate { !$0.finished && $0.positionSeconds > 0 },
            sortBy: [SortDescriptor(\.lastWatchedAt, order: .reverse)]))
    }

    /// Every stored watch state (finished included) — show pages badge
    /// finished episodes with it.
    public func allWatchStates() throws -> [WatchState] {
        try context.fetch(FetchDescriptor<WatchState>())
    }
}
