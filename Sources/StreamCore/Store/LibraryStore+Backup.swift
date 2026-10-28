import Foundation
import SwiftData

public struct HistoryEntryDTO: Codable, Sendable {
    public var key: String
    public var title: String
    public var year: Int?
    public var mediaKind: String
    public var tmdbID: Int?
    public var season: Int?
    public var episode: Int?
    public var posterPath: String?
    public var lastWatchedAt: Date
    public var progress: Double
    public var finished: Bool
}

public struct WatchStateDTO: Codable, Sendable {
    public var itemKey: String
    public var positionSeconds: Double
    public var durationSeconds: Double
    public var lastWatchedAt: Date
    public var finished: Bool
}

extension LibraryStore {
    public func exportHistory() throws -> [HistoryEntryDTO] {
        try history().map {
            HistoryEntryDTO(key: $0.key, title: $0.title, year: $0.year, mediaKind: $0.mediaKind,
                            tmdbID: $0.tmdbID, season: $0.season, episode: $0.episode,
                            posterPath: $0.posterPath, lastWatchedAt: $0.lastWatchedAt,
                            progress: $0.progress, finished: $0.finished)
        }
    }

    public func exportWatchStates() throws -> [WatchStateDTO] {
        try context.fetch(FetchDescriptor<WatchState>()).map {
            WatchStateDTO(itemKey: $0.itemKey, positionSeconds: $0.positionSeconds,
                          durationSeconds: $0.durationSeconds, lastWatchedAt: $0.lastWatchedAt,
                          finished: $0.finished)
        }
    }

    /// Upsert by key; a row is applied only if new or strictly newer. Returns rows applied.
    public func importHistory(_ rows: [HistoryEntryDTO]) throws -> Int {
        var applied = 0
        for r in rows {
            let existing = try context.fetch(FetchDescriptor<HistoryEntry>(
                predicate: #Predicate { $0.key == r.key })).first
            if let e = existing {
                guard r.lastWatchedAt > e.lastWatchedAt else { continue }
                e.title = r.title; e.year = r.year; e.mediaKind = r.mediaKind; e.tmdbID = r.tmdbID
                e.season = r.season; e.episode = r.episode; e.posterPath = r.posterPath
                e.lastWatchedAt = r.lastWatchedAt; e.progress = r.progress; e.finished = r.finished
            } else {
                context.insert(HistoryEntry(
                    key: r.key, title: r.title, year: r.year, mediaKind: r.mediaKind, tmdbID: r.tmdbID,
                    season: r.season, episode: r.episode, posterPath: r.posterPath,
                    lastWatchedAt: r.lastWatchedAt, progress: r.progress, finished: r.finished))
            }
            applied += 1
        }
        try context.save()
        return applied
    }

    public func importWatchStates(_ rows: [WatchStateDTO]) throws -> Int {
        var applied = 0
        for r in rows {
            let existing = try context.fetch(FetchDescriptor<WatchState>(
                predicate: #Predicate { $0.itemKey == r.itemKey })).first
            if let e = existing {
                guard r.lastWatchedAt > e.lastWatchedAt else { continue }
                e.positionSeconds = r.positionSeconds; e.durationSeconds = r.durationSeconds
                e.lastWatchedAt = r.lastWatchedAt; e.finished = r.finished
            } else {
                context.insert(WatchState(itemKey: r.itemKey, positionSeconds: r.positionSeconds,
                                          durationSeconds: r.durationSeconds,
                                          lastWatchedAt: r.lastWatchedAt, finished: r.finished))
            }
            applied += 1
        }
        try context.save()
        return applied
    }
}
