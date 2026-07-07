import Foundation
import Observation
import StreamCore

/// Lazy TMDB enrichment for one show page. Every fetch is best-effort:
/// failures leave the corresponding field nil/empty and the UI falls back
/// to filename-based rendering.
@Observable
@MainActor
final class ShowPageModel {
    let show: ShowGroup
    private let store: LibraryStore

    private(set) var details: TMDBShowDetails?
    private(set) var cast: [TMDBCastMember] = []
    // season -> episodeNumber -> metadata
    private(set) var seasonMeta: [Int: [Int: TMDBSeasonEpisode]] = [:]
    var selected: LibraryItem?

    init(show: ShowGroup, store: LibraryStore) {
        self.show = show
        self.store = store
        self.selected = resumeTarget?.item ?? show.episodes.first
    }

    var showID: Int? { show.episodes.compactMap(\.tmdbID).first }

    var seasons: [(number: Int, episodes: [LibraryItem])] {
        Dictionary(grouping: show.episodes) { $0.season ?? 0 }
            .map { (number: $0.key, episodes: $0.value) }
            .sorted { $0.number < $1.number }
    }

    /// Most recently watched, unfinished episode of this show.
    var resumeTarget: (item: LibraryItem, position: Double)? {
        let keys = Dictionary(uniqueKeysWithValues: show.episodes.map { ($0.itemKey, $0) })
        guard let state = (try? store.continueWatching())?
            .first(where: { keys[$0.itemKey] != nil }),
              let item = keys[state.itemKey] else { return nil }
        return (item, state.positionSeconds)
    }

    func watchState(for item: LibraryItem) -> (progress: Double, finished: Bool)? {
        // continueWatching() excludes finished; fetch all states via progress query.
        guard let states = try? store.allWatchStates() else { return nil }
        guard let state = states.first(where: { $0.itemKey == item.itemKey }),
              state.durationSeconds > 0 else { return nil }
        return (state.positionSeconds / state.durationSeconds, state.finished)
    }

    func episodeMeta(for item: LibraryItem) -> TMDBSeasonEpisode? {
        guard let season = item.season, let episode = item.episode else { return nil }
        return seasonMeta[season]?[episode]
    }

    func load(tmdb: TMDBClient) async {
        guard let showID else { return }
        if let fetched = try? await tmdb.showDetails(id: showID) { details = fetched }
        if let fetched = try? await tmdb.showCredits(id: showID) { cast = fetched }
        for season in seasons where season.number > 0 {
            guard seasonMeta[season.number] == nil,
                  let episodes = try? await tmdb.seasonEpisodes(showID: showID,
                                                                season: season.number)
            else { continue }
            seasonMeta[season.number] = Dictionary(
                uniqueKeysWithValues: episodes.map { ($0.episodeNumber, $0) })
        }
    }
}
