import Foundation

public struct RefreshSummary: Equatable, Sendable {
    public var upsert: UpsertSummary
    public var matched: Int
    public var matchFailed: Int

    public init(upsert: UpsertSummary, matched: Int, matchFailed: Int) {
        self.upsert = upsert; self.matched = matched; self.matchFailed = matchFailed
    }
}

/// Full library sync: RD torrent list → flatten to per-file entries (calling
/// torrentInfo only for packs not already expanded) → store diff → grouped
/// TMDB matching. Matching is best-effort — any TMDB failure just leaves those
/// items as plain (still playable) file cards.
@MainActor
public struct LibraryRefresher {
    let rd: RealDebridClient
    let tmdb: TMDBClient
    let store: LibraryStore

    public init(rd: RealDebridClient, tmdb: TMDBClient, store: LibraryStore) {
        self.rd = rd; self.tmdb = tmdb; self.store = store
    }

    public func refresh() async throws -> RefreshSummary {
        // Only finished torrents with at least one link are streamable.
        let torrents = try await rd.allTorrents()
            .filter { $0.status == "downloaded" && !$0.links.isEmpty }
        let knownCounts = try store.entryCounts()

        var entries: [LibraryFileEntry] = []
        for t in torrents {
            if t.links.count <= 1 {
                entries.append(LibraryFileEntry(torrentID: t.id, fileIndex: 0,
                                                filename: t.filename, bytes: t.bytes,
                                                added: t.added, link: t.links[0]))
            } else if knownCounts[t.id] == t.links.count {
                // Already expanded on a previous refresh — no torrentInfo call.
                entries.append(contentsOf: try store.cachedEntries(torrentID: t.id))
            } else {
                // Season pack / multi-file: real names live in files[].path.
                let info = try await rd.torrentInfo(t.id)
                let selected = info.files.filter { $0.selected == 1 }
                for (i, file) in selected.enumerated() where i < t.links.count {
                    let base = (file.path as NSString).lastPathComponent
                    entries.append(LibraryFileEntry(torrentID: t.id, fileIndex: i,
                                                    filename: base, bytes: file.bytes,
                                                    added: t.added, link: t.links[i]))
                }
            }
        }
        let upsert = try store.upsert(entries: entries)

        // Grouped matching: one TMDB search per distinct (kind, title, year) —
        // a 23-episode pack costs one API call.
        var matched = 0, failed = 0
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
                        failed += members.count; continue
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
                        failed += members.count; continue
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
                failed += members.count
            }
        }
        return RefreshSummary(upsert: upsert, matched: matched, matchFailed: failed)
    }
}
