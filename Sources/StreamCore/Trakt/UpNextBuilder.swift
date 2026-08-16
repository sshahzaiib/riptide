import Foundation

/// One card in the Up Next rail: a paused playback item or a show's next
/// unwatched episode.
public struct UpNextItem: Equatable, Sendable {
    public let isShow: Bool
    public let tmdbID: Int          // movie id, or the SHOW's id for episodes
    public let season: Int?
    public let number: Int?
    public let episodeTitle: String?
    public let progressPercent: Double?   // non-nil only for paused playback
    public let sortDate: Date

    public init(isShow: Bool, tmdbID: Int, season: Int?, number: Int?,
                episodeTitle: String?, progressPercent: Double?, sortDate: Date) {
        self.isShow = isShow
        self.tmdbID = tmdbID
        self.season = season
        self.number = number
        self.episodeTitle = episodeTitle
        self.progressPercent = progressPercent
        self.sortDate = sortDate
    }
}

/// Pure assembly for the Up Next rail; fetching stays in the caller.
public enum UpNextBuilder {
    /// Most-recently-watched first, hidden shows removed, capped.
    public static func shortlist(watched: [TraktWatchedShow],
                                 hiddenTMDBIDs: Set<Int>,
                                 cap: Int = 25) -> [TraktWatchedShow] {
        Array(watched
            .filter { show in
                if let tmdb = show.show.ids.tmdb {
                    return !hiddenTMDBIDs.contains(tmdb)
                }
                return false
            }
            .sorted { $0.lastWatchedAt > $1.lastWatchedAt }
            .prefix(cap))
    }

    /// Paused playback first (newest pausedAt), then next episodes (input
    /// order, which shortlist already sorted newest-first). A show with a
    /// paused episode doesn't also get a next-episode card. Entries without
    /// a tmdb id are skipped.
    public static func build(playback: [TraktPlaybackEntry],
                             progressByShow: [(show: TraktWatchedShow, progress: TraktShowProgress)]) -> [UpNextItem] {
        var items: [UpNextItem] = []
        var coveredShows: Set<Int> = []
        var coveredMovies: Set<Int> = []

        let paused = playback.sorted { ($0.pausedAt ?? .distantPast) > ($1.pausedAt ?? .distantPast) }
        for entry in paused {
            if entry.type == "movie", let id = entry.movie?.ids.tmdb, !coveredMovies.contains(id) {
                coveredMovies.insert(id)
                items.append(UpNextItem(isShow: false, tmdbID: id, season: nil, number: nil,
                                        episodeTitle: nil, progressPercent: entry.progress,
                                        sortDate: entry.pausedAt ?? .distantPast))
            } else if entry.type == "episode", let showID = entry.show?.ids.tmdb,
                      let ep = entry.episode, !coveredShows.contains(showID) {
                // One card per show: a second paused episode of the same show
                // would duplicate the SearchMedia id and break ForEach.
                coveredShows.insert(showID)
                items.append(UpNextItem(isShow: true, tmdbID: showID, season: ep.season,
                                        number: ep.number, episodeTitle: nil,
                                        progressPercent: entry.progress,
                                        sortDate: entry.pausedAt ?? .distantPast))
            }
        }

        for (watchedShow, progress) in progressByShow {
            guard let next = progress.nextEpisode,
                  let showID = watchedShow.show.ids.tmdb,
                  !coveredShows.contains(showID) else { continue }
            coveredShows.insert(showID)
            items.append(UpNextItem(isShow: true, tmdbID: showID, season: next.season,
                                    number: next.number, episodeTitle: next.title,
                                    progressPercent: nil,
                                    sortDate: watchedShow.lastWatchedAt))
        }
        return items
    }
}
