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

    /// On-disk store in Application Support (Plan 2 app entry point uses this).
    public static func onDisk() throws -> LibraryStore {
        let container = try ModelContainer(for: LibraryItem.self, WatchState.self)
        return LibraryStore(container: container)
    }

    // MARK: Library sync

    /// Mirror the RD torrent list into the cache: insert new, update changed
    /// (by filename/links/size), delete vanished. Parsing happens here so the
    /// UI never sees an unparsed item.
    public func upsert(torrents: [TorrentListItem]) throws -> UpsertSummary {
        let existing = try context.fetch(FetchDescriptor<LibraryItem>())
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.torrentID, $0) })
        var summary = UpsertSummary(inserted: 0, updated: 0, deleted: 0)

        for t in torrents {
            if let item = byID.removeValue(forKey: t.id) {
                if item.filename != t.filename || item.links != t.links
                    || item.sizeBytes != t.bytes {
                    let parsed = ReleaseNameParser.parse(t.filename)
                    item.filename = t.filename
                    item.sizeBytes = t.bytes
                    item.links = t.links
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
                context.insert(LibraryItem(torrentID: t.id, filename: t.filename,
                                           sizeBytes: t.bytes, addedAt: t.added,
                                           links: t.links,
                                           parsed: ReleaseNameParser.parse(t.filename)))
                summary.inserted += 1
            }
        }
        // Anything left in byID no longer exists on RD.
        for (_, orphan) in byID {
            context.delete(orphan)
            summary.deleted += 1
        }
        try context.save()
        return summary
    }

    public func items() throws -> [LibraryItem] {
        try context.fetch(FetchDescriptor<LibraryItem>(
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]))
    }

    public func applyMatch(torrentID: String, tmdbID: Int, mediaKind: String,
                           posterPath: String?, overview: String?, rating: Double?) throws {
        let descriptor = FetchDescriptor<LibraryItem>(
            predicate: #Predicate { $0.torrentID == torrentID })
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

    /// Upsert playback position. >= 95% watched marks the item finished (spec).
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

    /// Unfinished, started items, most recently watched first.
    public func continueWatching() throws -> [WatchState] {
        try context.fetch(FetchDescriptor<WatchState>(
            predicate: #Predicate { !$0.finished && $0.positionSeconds > 0 },
            sortBy: [SortDescriptor(\.lastWatchedAt, order: .reverse)]))
    }
}
