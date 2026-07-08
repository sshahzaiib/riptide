import Foundation

/// Pulls Trakt playback progress + watched history into the local store.
/// Newest-timestamp-wins in both directions; local state is never touched
/// when it is newer than Trakt's.
@MainActor
public struct TraktSyncer {
    public struct Summary: Equatable, Sendable {
        public var playbackApplied = 0
        public var watchedApplied = 0
        public init() {}
    }

    let client: TraktClient
    let store: LibraryStore

    public init(client: TraktClient, store: LibraryStore) {
        self.client = client
        self.store = store
    }

    public func pull() async throws -> Summary {
        let items = try store.items()
        var movieKeys: [Int: String] = [:]          // movie tmdb -> itemKey
        var episodeKeys: [String: String] = [:]     // "showTmdb#s#e" -> itemKey
        for item in items {
            guard let id = item.tmdbID else { continue }
            if item.mediaKind == "movie" {
                movieKeys[id] = item.itemKey
            } else if let s = item.season, let e = item.episode {
                episodeKeys["\(id)#\(s)#\(e)"] = item.itemKey
            }
        }
        // Snapshot: itemKey -> (lastWatchedAt, duration, finished).
        var states = Dictionary(uniqueKeysWithValues: (try store.allWatchStates())
            .map { ($0.itemKey, ($0.lastWatchedAt, $0.durationSeconds, $0.finished)) })
        var summary = Summary()

        for entry in try await client.playback() {
            let key: String? = switch entry.type {
            case "movie": entry.movie?.ids.tmdb.flatMap { movieKeys[$0] }
            case "episode": entry.show?.ids.tmdb.flatMap { showID in
                entry.episode.flatMap { episodeKeys["\(showID)#\($0.season)#\($0.number)"] }
            }
            default: nil
            }
            guard let key, let pausedAt = entry.pausedAt else { continue }
            let local = states[key]
            // Percent -> seconds needs a locally known duration.
            guard let duration = local?.1, duration > 0,
                  pausedAt > (local?.0 ?? .distantPast) else { continue }
            try store.applyRemoteProgress(itemKey: key,
                                          position: entry.progress / 100 * duration,
                                          duration: duration, watchedAt: pausedAt)
            states[key] = (pausedAt, duration, false)
            summary.playbackApplied += 1
        }

        func markWatched(key: String, at watchedAt: Date) throws {
            let local = states[key]
            guard local?.2 != true, watchedAt > (local?.0 ?? .distantPast) else { return }
            try store.applyRemoteWatched(itemKey: key, watchedAt: watchedAt)
            states[key] = (watchedAt, local?.1 ?? 0, true)
            summary.watchedApplied += 1
        }

        for watched in try await client.watchedMovies() {
            guard let id = watched.movie.ids.tmdb, let key = movieKeys[id] else { continue }
            try markWatched(key: key, at: watched.lastWatchedAt)
        }
        for show in try await client.watchedShows() {
            guard let showID = show.show.ids.tmdb else { continue }
            for season in show.seasons {
                for episode in season.episodes {
                    guard let key = episodeKeys["\(showID)#\(season.number)#\(episode.number)"]
                    else { continue }
                    try markWatched(key: key, at: episode.lastWatchedAt)
                }
            }
        }
        return summary
    }
}
