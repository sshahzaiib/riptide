import Foundation

public struct RefreshSummary: Equatable, Sendable {
    public var upsert: UpsertSummary
    public var matched: Int
    public var matchFailed: Int
    public var serviceErrors: [String: String]
    public var authFailures: Set<String>

    public init(
        upsert: UpsertSummary,
        matched: Int,
        matchFailed: Int,
        serviceErrors: [String: String] = [:],
        authFailures: Set<String> = []
    ) {
        self.upsert = upsert
        self.matched = matched
        self.matchFailed = matchFailed
        self.serviceErrors = serviceErrors
        self.authFailures = authFailures
    }
}

/// Full library sync: RD torrent list → flatten to per-file entries (calling
/// torrentInfo only for packs not already expanded) → store diff → grouped
/// TMDB matching. Matching is best-effort — any TMDB failure just leaves those
/// items as plain (still playable) file cards.
@MainActor
public struct LibraryRefresher {
    let services: [any DebridService]
    let tmdb: TMDBClient
    let store: LibraryStore

    public init(services: [any DebridService], tmdb: TMDBClient, store: LibraryStore) {
        self.services = services; self.tmdb = tmdb; self.store = store
    }

    public func refresh() async throws -> RefreshSummary {
        let knownCounts = try store.entryCounts()
        let cached = try store.cachedEntriesByTorrent()
        var entries: [LibraryFileEntry] = []
        var serviceErrors: [String: String] = [:]
        var authFailures: Set<String> = []
        var failed: Set<String> = []
        for service in services {
            do {
                entries.append(contentsOf: try await service.libraryEntries(
                    knownCounts: knownCounts, cached: cached))
            } catch {
                if error.isCancellation { throw error }
                failed.insert(service.serviceID.rawValue)
                serviceErrors[service.serviceID.rawValue] = "\(error)"
                if case RealDebridError.unauthorized = error { authFailures.insert("rd") }
                if case AllDebridError.authFailed = error { authFailures.insert("ad") }
            }
        }
        // AD copy of an RD file (same name + size, RD preferred) is dropped —
        // AD's list API has no infohash, so name+size is the only join key.
        let rdFiles = Set(entries.filter { $0.service == "rd" }
            .map { "\($0.filename.lowercased())|\($0.bytes)" })
        entries.removeAll {
            $0.service == "ad" && rdFiles.contains("\($0.filename.lowercased())|\($0.bytes)")
        }
        let upsert = try store.upsert(entries: entries, protecting: failed)

        // Grouped matching: one TMDB search per distinct (kind, title, year) —
        // a 23-episode pack costs one API call.
        var matched = 0, failed2 = 0
        let unmatched = try store.items().filter { $0.tmdbID == nil }
        let groups = Dictionary(grouping: unmatched) {
            "\($0.mediaKind)|\($0.title.lowercased())|\($0.year.map(String.init) ?? "")"
        }
        for (_, members) in groups {
            let rep = members[0]
            do {
                if rep.mediaKind == "episode" {
                    guard let show = try await tmdb.searchTV(title: rep.title,
                                                             year: rep.year).first else {
                        failed2 += members.count; continue
                    }
                    for member in members {
                        try store.applyMatch(itemKey: member.itemKey, tmdbID: show.id,
                                             mediaKind: "episode",
                                             posterPath: show.posterPath,
                                             overview: show.overview,
                                             rating: show.voteAverage)
                    }
                } else {
                    guard let movie = try await tmdb.searchMovie(title: rep.title,
                                                                 year: rep.year).first else {
                        failed2 += members.count; continue
                    }
                    for member in members {
                        try store.applyMatch(itemKey: member.itemKey, tmdbID: movie.id,
                                             mediaKind: "movie",
                                             posterPath: movie.posterPath,
                                             overview: movie.overview,
                                             rating: movie.voteAverage)
                    }
                }
                matched += members.count
            } catch {
                failed2 += members.count
            }
        }
        return RefreshSummary(upsert: upsert, matched: matched, matchFailed: failed2, serviceErrors: serviceErrors, authFailures: authFailures)
    }
}
