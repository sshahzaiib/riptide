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
                                           DownloadRecord.self, HistoryEntry.self,
                                           configurations: config)
        return LibraryStore(container: container)
    }

    /// On-disk store in Application Support/Riptide — an explicit path, NOT
    /// SwiftData's shared `default.store` (a bare SwiftPM executable has no
    /// app container, so the default path collides with any other SwiftData
    /// process on the machine). Pre-1.0 schema policy: if the store fails to
    /// open — or fails the probe fetches below, since table creation is lazy
    /// and a stale/foreign file only errors at first query ("no such table:
    /// ZWATCHSTATE") — wipe and recreate rather than migrate.
    public static func onDisk() throws -> LibraryStore {
        let dir = URL.applicationSupportDirectory
            .appendingPathComponent("Riptide", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("library.store")
        func open() throws -> LibraryStore {
            let config = ModelConfiguration(url: storeURL)
            let container = try ModelContainer(for: LibraryItem.self, WatchState.self,
                                               DownloadRecord.self, HistoryEntry.self,
                                           configurations: config)
            let store = LibraryStore(container: container)
            _ = try store.context.fetchCount(FetchDescriptor<LibraryItem>())
            _ = try store.context.fetchCount(FetchDescriptor<WatchState>())
            _ = try store.context.fetchCount(FetchDescriptor<DownloadRecord>())
            _ = try store.context.fetchCount(FetchDescriptor<HistoryEntry>())
            return store
        }
        do { return try open() } catch {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: storeURL.path + suffix))
            }
            return try open()
        }
    }

    /// Mirror the flattened RD file list into the cache: insert new, update
    /// changed (filename/link/size), delete vanished. Parsing happens here so
    /// the UI never sees an unparsed item.
    /// `protecting` = service ids whose refresh FAILED this cycle: their
    /// orphans survive (a service outage must not wipe its items).
    public func upsert(entries: [LibraryFileEntry],
                       protecting failedServices: Set<String> = []) throws -> UpsertSummary {
        let existing = try context.fetch(FetchDescriptor<LibraryItem>())
        var byKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.itemKey, $0) })
        var summary = UpsertSummary(inserted: 0, updated: 0, deleted: 0)
        var processed = Set<String>()

        for entry in entries {
            guard processed.insert(entry.itemKey).inserted else { continue }
            if let item = byKey.removeValue(forKey: entry.itemKey) {
                if item.filename != entry.filename || item.link != entry.link
                    || item.sizeBytes != entry.bytes || (item.mediaKind == "extra") != entry.isExtra {
                    let parsed = ReleaseNameParser.parse(entry.filename)
                    item.filename = entry.filename
                    item.sizeBytes = entry.bytes
                    item.link = entry.link
                    item.title = parsed.title
                    item.year = parsed.year
                    item.season = parsed.season
                    item.episode = parsed.episode
                    item.quality = parsed.quality
                    item.mediaKind = entry.isExtra ? "extra"
                        : (parsed.isTV ? "episode" : "movie")
                    // Filename changed -> stale match; rematch on next refresh.
                    item.tmdbID = nil
                    item.posterPath = nil
                    item.overview = nil
                    item.rating = nil
                    item.lastRefreshed = .now
                    summary.updated += 1
                }
            } else {
                let item = LibraryItem(entry: entry,
                                       parsed: ReleaseNameParser.parse(entry.filename))
                if entry.isExtra { item.mediaKind = "extra" }
                context.insert(item)
                summary.inserted += 1
            }
        }
        // Anything left in byKey no longer exists on RD. Drop its watch state
        // too, or Continue Watching would keep offering dead entries.
        if !byKey.isEmpty {
            let allStates = try context.fetch(FetchDescriptor<WatchState>())
            for (_, orphan) in byKey where !failedServices.contains(orphan.service) {
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

    /// Remove every file of a torrent (and their watch state) after a debrid delete.
    public func delete(torrentID: String) throws {
        let gone = try context.fetch(FetchDescriptor<LibraryItem>()).filter { $0.torrentID == torrentID }
        let keys = Set(gone.map(\.itemKey))
        for state in try context.fetch(FetchDescriptor<WatchState>()) where keys.contains(state.itemKey) {
            context.delete(state)
        }
        gone.forEach(context.delete)
        try context.save()
    }

    public func items() throws -> [LibraryItem] {
        try context.fetch(FetchDescriptor<LibraryItem>(
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]))
    }

    /// Library-priority lookup for addon search: is this TMDB title (or this
    /// specific episode) already in the account? Movies pass nil/nil.
    public func item(tmdbID: Int, season: Int?, episode: Int?) throws -> LibraryItem? {
        let id: Int? = tmdbID
        let descriptor = FetchDescriptor<LibraryItem>(
            predicate: #Predicate {
                $0.tmdbID == id && $0.season == season && $0.episode == episode
            })
        return try context.fetch(descriptor).first
    }

    /// The library item that is EXACTLY the next episode after `itemKey`:
    /// (S, E+1), or (S+1, 1) when E+1 isn't owned AND `itemKey` is the
    /// highest-numbered owned episode of its season (season rollover). A gap
    /// returns nil — autoplay must never skip story content. In particular,
    /// if a later episode of the SAME season is already owned (e.g. own
    /// S1E1, S1E3, S2E1 — advancing from S1E1), rolling over to S2E1 would
    /// silently skip S1E3, so that case returns nil too. When duplicate
    /// files exist for the target, prefer one from the same torrent pack.
    public func nextEpisode(after itemKey: String) throws -> LibraryItem? {
        let keyDescriptor = FetchDescriptor<LibraryItem>(
            predicate: #Predicate { $0.itemKey == itemKey })
        guard let current = try context.fetch(keyDescriptor).first,
              let showID = current.tmdbID,
              let season = current.season,
              let episode = current.episode else { return nil }
        let id: Int? = showID
        let siblings = try context.fetch(FetchDescriptor<LibraryItem>(
            predicate: #Predicate { $0.tmdbID == id }))
            .filter { $0.mediaKind == "episode" && $0.season != nil && $0.episode != nil }
        func owned(_ s: Int, _ e: Int) -> [LibraryItem] {
            siblings.filter { $0.season == s && $0.episode == e }
        }
        var candidates = owned(season, episode + 1)
        if candidates.isEmpty {
            let isHighestInSeason = !siblings.contains {
                $0.season == season && ($0.episode ?? episode) > episode
            }
            guard isHighestInSeason else { return nil }
            candidates = owned(season + 1, 1)
        }
        // Pack affinity stays on top; across packs, last played then quality.
        if let packMate = candidates.first(where: { $0.torrentID == current.torrentID }) {
            return packMate
        }
        guard !candidates.isEmpty else { return nil }
        // ponytail: full watch-state fetch — the table is small and this runs
        // once per episode end; switch to a keyed predicate if it ever shows.
        let states = Dictionary(try allWatchStates().map { ($0.itemKey, $0) },
                                uniquingKeysWith: { first, _ in first })
        return VersionPreference.preferred(items: candidates, states: states)
    }

    /// Mirror of nextEpisode: EXACTLY (S, E-1), or — from E1 only — the
    /// highest-numbered owned episode of season S-1. A same-season gap
    /// (E-1 missing while earlier episodes exist) returns nil: skipping
    /// backwards over unowned story content is as wrong as forwards.
    public func previousEpisode(before itemKey: String) throws -> LibraryItem? {
        let keyDescriptor = FetchDescriptor<LibraryItem>(
            predicate: #Predicate { $0.itemKey == itemKey })
        guard let current = try context.fetch(keyDescriptor).first,
              let showID = current.tmdbID,
              let season = current.season,
              let episode = current.episode else { return nil }
        let id: Int? = showID
        let siblings = try context.fetch(FetchDescriptor<LibraryItem>(
            predicate: #Predicate { $0.tmdbID == id }))
            .filter { $0.mediaKind == "episode" && $0.season != nil && $0.episode != nil }
        func owned(_ s: Int, _ e: Int) -> [LibraryItem] {
            siblings.filter { $0.season == s && $0.episode == e }
        }
        let candidates: [LibraryItem]
        if episode > 1 {
            candidates = owned(season, episode - 1)
        } else {
            let highest = siblings.filter { $0.season == season - 1 }
                .compactMap(\.episode).max()
            candidates = highest.map { owned(season - 1, $0) } ?? []
        }
        return candidates.first { $0.torrentID == current.torrentID } ?? candidates.first
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
            LibraryFileEntry(service: $0.service, torrentID: $0.torrentID,
                             fileIndex: $0.fileIndex, filename: $0.filename,
                             bytes: $0.sizeBytes, added: $0.addedAt, link: $0.link,
                             isExtra: $0.mediaKind == "extra")
        }
    }

    /// All stored entries grouped by torrentID — the cache adapters consult
    /// to skip per-torrent detail RPCs.
    public func cachedEntriesByTorrent() throws -> [String: [LibraryFileEntry]] {
        Dictionary(grouping: try items().map {
            LibraryFileEntry(service: $0.service, torrentID: $0.torrentID,
                             fileIndex: $0.fileIndex, filename: $0.filename,
                             bytes: $0.sizeBytes, added: $0.addedAt, link: $0.link,
                             isExtra: $0.mediaKind == "extra")
        }, by: \.torrentID)
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

    /// Cleanup for libraries synced before extras detection existed — the
    /// cached-entries fast path never re-parses, so stale rows linger.
    /// Filename-only (paths aren't stored). Idempotent; runs every refresh.
    @discardableResult
    public func reclassifyExtras() throws -> Int {
        var flipped = 0
        for item in try context.fetch(FetchDescriptor<LibraryItem>())
        where item.mediaKind != "extra"
            && ReleaseNameParser.isExtra(filename: item.filename) {
            item.mediaKind = "extra"
            item.tmdbID = nil          // any match was a mis-match
            item.posterPath = nil
            item.overview = nil
            item.rating = nil
            flipped += 1
        }
        if flipped > 0 { try context.save() }
        return flipped
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
        try recordHistory(itemKey: itemKey, progress: duration > 0 ? position / duration : 0,
                          finished: finished, at: .now)
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
        try recordHistory(itemKey: itemKey, progress: duration > 0 ? position / duration : 0,
                          finished: nil, at: watchedAt)
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
        try recordHistory(itemKey: itemKey, progress: 1, finished: true, at: watchedAt)
    }

    /// Manual watched toggle (context menus). Writes a fresh lastWatchedAt so
    /// the next Trakt pull — strictly-newer-wins — cannot resurrect old state.
    public func setWatched(itemKey: String, watched: Bool) throws {
        let descriptor = FetchDescriptor<WatchState>(
            predicate: #Predicate { $0.itemKey == itemKey })
        let state: WatchState
        if let existing = try context.fetch(descriptor).first {
            state = existing
        } else {
            state = WatchState(itemKey: itemKey, positionSeconds: 0,
                               durationSeconds: 0, finished: false)
            context.insert(state)
        }
        state.finished = watched
        state.positionSeconds = watched ? state.durationSeconds : 0
        state.lastWatchedAt = .now
        try context.save()
        try recordHistory(itemKey: itemKey, progress: watched ? 1 : 0, finished: watched, at: .now)
    }

    // MARK: History

    private func recordHistory(itemKey: String, progress: Double, finished: Bool?, at: Date) throws {
        let d = FetchDescriptor<LibraryItem>(predicate: #Predicate { $0.itemKey == itemKey })
        guard let item = try context.fetch(d).first else { return }
        try recordHistory(item: item, progress: progress, finished: finished, at: at)
    }

    /// Upserts the history row for `item`. Newest timestamp wins for progress/finished;
    /// lastWatchedAt only moves forward. `finished: nil` leaves the flag alone.
    public func recordHistory(item: LibraryItem, progress: Double, finished: Bool?, at: Date) throws {
        guard item.mediaKind != "extra" else { return }
        let key = HistoryEntry.key(for: item)
        let d = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.key == key })
        if let row = try context.fetch(d).first {
            if at >= row.lastWatchedAt {
                row.progress = progress
                if let finished {
                    // ponytail: progress 0 + false is how setWatched(false) resets; other false never regresses
                    row.finished = finished || (row.finished && progress > 0)
                }
            }
            row.lastWatchedAt = max(row.lastWatchedAt, at)
        } else {
            context.insert(HistoryEntry(
                key: key, title: item.title, year: item.year, mediaKind: item.mediaKind,
                tmdbID: item.tmdbID, season: item.season, episode: item.episode,
                posterPath: item.posterPath, lastWatchedAt: at, progress: progress,
                finished: finished ?? false))
        }
        try context.save()
    }

    public func history() throws -> [HistoryEntry] {
        try context.fetch(FetchDescriptor<HistoryEntry>(
            sortBy: [SortDescriptor(\.lastWatchedAt, order: .reverse)]))
    }

    public func removeHistory(key: String) throws {
        try context.delete(model: HistoryEntry.self, where: #Predicate { $0.key == key })
        try context.save()
    }

    /// One-time seed from existing watch states; orphans (no item) are skipped.
    public func backfillHistory() throws -> Int {
        var n = 0
        for s in try allWatchStates() where s.positionSeconds > 0 || s.finished {
            let key = s.itemKey
            let d = FetchDescriptor<LibraryItem>(predicate: #Predicate { $0.itemKey == key })
            guard let item = try context.fetch(d).first, item.mediaKind != "extra" else { continue }
            try recordHistory(item: item,
                              progress: s.durationSeconds > 0 ? s.positionSeconds / s.durationSeconds : (s.finished ? 1 : 0),
                              finished: s.finished, at: s.lastWatchedAt)
            n += 1
        }
        return n
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
