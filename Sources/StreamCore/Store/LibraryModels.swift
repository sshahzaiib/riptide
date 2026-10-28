import Foundation
import SwiftData

/// Input for library sync: one playable file, already flattened from RD's
/// torrent + file layout by the refresher.
public struct LibraryFileEntry: Sendable, Equatable {
    public let service: String         // "rd" | "ad"
    public let torrentID: String       // RD torrent id or AD magnet id
    public let fileIndex: Int
    public let filename: String        // per-file basename (or torrent name)
    public let bytes: Int64
    public let added: String           // raw ISO-8601 from the torrent
    public let link: String            // debrid hoster link for THIS file
    public let isExtra: Bool           // bonus material (deleted scene, featurette…)

    /// RD keys keep their pre-multi-debrid format so nothing re-syncs.
    public var itemKey: String {
        service == "rd" ? "\(torrentID)#\(fileIndex)" : "\(service)#\(torrentID)#\(fileIndex)"
    }

    public init(service: String = "rd", torrentID: String, fileIndex: Int,
                filename: String, bytes: Int64, added: String, link: String, isExtra: Bool = false) {
        self.service = service
        self.torrentID = torrentID
        self.fileIndex = fileIndex
        self.filename = filename
        self.bytes = bytes
        self.added = added
        self.link = link
        self.isExtra = isExtra
    }
}

/// One playable file surfaced in the library. Parsed and TMDB fields are
/// denormalized so shelves render offline from cache.
@Model
public final class LibraryItem {
    @Attribute(.unique) public var itemKey: String   // "<torrentID>#<fileIndex>"
    public var service: String = "rd"
    public var torrentID: String
    public var fileIndex: Int
    public var filename: String
    public var sizeBytes: Int64
    public var addedAt: String
    public var link: String
    // Parsed from filename
    public var title: String
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    public var quality: String?
    // TMDB match (nil until matched; item renders as plain file card)
    public var tmdbID: Int?
    public var mediaKind: String          // "movie" | "episode"
    public var posterPath: String?
    public var overview: String?
    public var rating: Double?
    public var lastRefreshed: Date

    public init(entry: LibraryFileEntry, parsed: ParsedRelease, lastRefreshed: Date = .now) {
        self.service = entry.service
        self.itemKey = entry.itemKey
        self.torrentID = entry.torrentID
        self.fileIndex = entry.fileIndex
        self.filename = entry.filename
        self.sizeBytes = entry.bytes
        self.addedAt = entry.added
        self.link = entry.link
        self.title = parsed.title
        self.year = parsed.year
        self.season = parsed.season
        self.episode = parsed.episode
        self.quality = parsed.quality
        self.tmdbID = nil
        self.mediaKind = parsed.isTV ? "episode" : "movie"
        self.posterPath = nil
        self.overview = nil
        self.rating = nil
        self.lastRefreshed = lastRefreshed
    }
}

/// Playback position for one file. `itemKey` matches `LibraryItem.itemKey`.
@Model
public final class WatchState {
    @Attribute(.unique) public var itemKey: String
    public var positionSeconds: Double
    public var durationSeconds: Double
    public var lastWatchedAt: Date
    public var finished: Bool

    public init(itemKey: String, positionSeconds: Double, durationSeconds: Double,
                lastWatchedAt: Date = .now, finished: Bool = false) {
        self.itemKey = itemKey
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.lastWatchedAt = lastWatchedAt
        self.finished = finished
    }
}

/// One row per watched title (movie / episode), independent of the library:
/// survives torrent deletion and orphan cleanup.
@Model
public final class HistoryEntry {
    @Attribute(.unique) public var key: String   // tmdb:<id> | tmdb:<id>/S<s>E<e> | file:<filename>
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

    public init(key: String, title: String, year: Int?, mediaKind: String, tmdbID: Int?,
                season: Int?, episode: Int?, posterPath: String?, lastWatchedAt: Date,
                progress: Double, finished: Bool) {
        self.key = key; self.title = title; self.year = year; self.mediaKind = mediaKind
        self.tmdbID = tmdbID; self.season = season; self.episode = episode
        self.posterPath = posterPath; self.lastWatchedAt = lastWatchedAt
        self.progress = progress; self.finished = finished
    }

    public static func key(for item: LibraryItem) -> String {
        guard let id = item.tmdbID else { return "file:\(item.filename)" }
        if let s = item.season, let e = item.episode { return "tmdb:\(id)/S\(s)E\(e)" }
        return "tmdb:\(id)"
    }
}
