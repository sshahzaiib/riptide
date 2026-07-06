import Foundation

public struct RefreshSummary: Equatable, Sendable {
    public var upsert: UpsertSummary
    public var matched: Int
    public var matchFailed: Int

    public init(upsert: UpsertSummary, matched: Int, matchFailed: Int) {
        self.upsert = upsert; self.matched = matched; self.matchFailed = matchFailed
    }
}

/// Full library sync: RD torrent list → store diff → TMDB match for unmatched
/// items. Matching is best-effort — any TMDB failure just leaves that item as
/// a plain (still playable) file card; refresh never throws for TMDB reasons.
@MainActor
public struct LibraryRefresher {
    let rd: RealDebridClient
    let tmdb: TMDBClient
    let store: LibraryStore

    public init(rd: RealDebridClient, tmdb: TMDBClient, store: LibraryStore) {
        self.rd = rd; self.tmdb = tmdb; self.store = store
    }

    public func refresh() async throws -> RefreshSummary {
        // Only finished torrents are streamable.
        let torrents = try await rd.allTorrents().filter { $0.status == "downloaded" }
        let upsert = try store.upsert(torrents: torrents)

        var matched = 0, failed = 0
        for item in try store.items() where item.tmdbID == nil {
            do {
                if item.mediaKind == "episode" {
                    guard let show = try await tmdb.searchTV(title: item.title,
                                                             year: item.year).first else {
                        failed += 1; continue
                    }
                    try store.applyMatch(torrentID: item.torrentID, tmdbID: show.id,
                                         mediaKind: "episode",
                                         posterPath: show.posterPath,
                                         overview: show.overview,
                                         rating: show.voteAverage)
                } else {
                    guard let movie = try await tmdb.searchMovie(title: item.title,
                                                                 year: item.year).first else {
                        failed += 1; continue
                    }
                    try store.applyMatch(torrentID: item.torrentID, tmdbID: movie.id,
                                         mediaKind: "movie",
                                         posterPath: movie.posterPath,
                                         overview: movie.overview,
                                         rating: movie.voteAverage)
                }
                matched += 1
            } catch {
                // ponytail: per-item error detail dropped; summary count is enough
                // for v1's "N items unmatched" toast. Item stays as a file card.
                failed += 1
            }
        }
        return RefreshSummary(upsert: upsert, matched: matched, matchFailed: failed)
    }
}
