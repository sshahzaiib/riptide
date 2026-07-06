import Foundation
import SwiftData

/// One RD torrent surfaced in the library. `torrentID` mirrors RD; parsed and
/// TMDB fields are denormalized here so shelves render offline from cache.
@Model
public final class LibraryItem {
    @Attribute(.unique) public var torrentID: String
    public var filename: String
    public var sizeBytes: Int64
    public var addedAt: String            // raw ISO-8601 from RD, sortable as string
    public var links: [String]
    // Parsed from filename
    public var title: String
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    public var quality: String?
    // TMDB match (nil until matched; item renders as plain file card)
    public var tmdbID: Int?
    public var mediaKind: String          // "movie" | "episode" | "unknown"
    public var posterPath: String?
    public var overview: String?
    public var rating: Double?
    public var lastRefreshed: Date

    public init(torrentID: String, filename: String, sizeBytes: Int64, addedAt: String,
                links: [String], parsed: ParsedRelease, lastRefreshed: Date = .now) {
        self.torrentID = torrentID
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.addedAt = addedAt
        self.links = links
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

/// Playback position for one file. `itemKey` = "<torrentID>#<fileIndex>" so
/// multi-file packs track per-file progress.
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
