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
    private var stateByKey: [String: WatchState] = [:]
    private var userSelected = false

    init(show: ShowGroup, store: LibraryStore) {
        self.show = show
        self.store = store
        refreshWatchStates()
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
        show.episodes
            .compactMap { item -> (LibraryItem, WatchState)? in
                guard let state = stateByKey[item.itemKey],
                      !state.finished, state.positionSeconds > 0 else { return nil }
                return (item, state)
            }
            .max { $0.1.lastWatchedAt < $1.1.lastWatchedAt }
            .map { ($0.0, $0.1.positionSeconds) }
    }

    func watchState(for item: LibraryItem) -> (progress: Double, finished: Bool)? {
        guard let state = stateByKey[item.itemKey] else { return nil }
        let progress = state.durationSeconds > 0
            ? state.positionSeconds / state.durationSeconds : 0
        return (progress, state.finished)
    }

    func isFinished(_ item: LibraryItem) -> Bool {
        stateByKey[item.itemKey]?.finished == true
    }

    /// Context-menu mark: local write first (survives Trakt pulls), then a
    /// best-effort batched push to Trakt history.
    func setWatched(_ watched: Bool, items: [LibraryItem]) {
        for item in items {
            try? store.setWatched(itemKey: item.itemKey, watched: watched)
        }
        refreshWatchStates()
        guard let showID else { return }
        let media: [TraktMedia] = items.compactMap { item in
            guard let season = item.season, let episode = item.episode else { return nil }
            return .episode(showTMDBID: showID, season: season, episode: episode)
        }
        TraktService.shared.setWatched(watched, media: media)
    }


    func episodeMeta(for item: LibraryItem) -> TMDBSeasonEpisode? {
        guard let season = item.season, let episode = item.episode else { return nil }
        return seasonMeta[season]?[episode]
    }

    func load(tmdb: TMDBClient) async {
        guard let showID else { return }
        if let fetched = try? await tmdb.showDetails(id: showID) { details = fetched }
        if let fetched = try? await tmdb.showCredits(id: showID) { cast = fetched }
        for season in seasons {
            guard seasonMeta[season.number] == nil,
                  let episodes = try? await tmdb.seasonEpisodes(showID: showID,
                                                                season: season.number)
            else { continue }
            seasonMeta[season.number] = Dictionary(
                uniqueKeysWithValues: episodes.map { ($0.episodeNumber, $0) })
        }
    }

    /// One store query; every card reads the dictionary.
    func refreshWatchStates() {
        let states = (try? store.allWatchStates()) ?? []
        stateByKey = Dictionary(uniqueKeysWithValues: states.map { ($0.itemKey, $0) })
        // Follow playback progress unless the user picked an episode manually.
        if !userSelected {
            selected = resumeTarget?.item ?? selected ?? show.episodes.first
        }
    }

    func userDidSelect(_ item: LibraryItem) {
        userSelected = true
        selected = item
    }
}
