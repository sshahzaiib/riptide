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
    private(set) var imdbID: String?
    private(set) var allSeasonNumbers: [Int] = []

    struct EpisodeSlot: Identifiable {
        let season: Int
        let number: Int
        let meta: TMDBSeasonEpisode?
        let item: LibraryItem?
        var id: String { item?.itemKey ?? "tmdb-\(season)-\(number)" }
    }

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

    /// Seasons to render: TMDB's full list merged with whatever the library
    /// actually has. Specials (0) only when we own season-0 files — that
    /// bucket also holds items whose filename parse found no season.
    var visibleSeasonNumbers: [Int] {
        var numbers = Set(allSeasonNumbers)
        numbers.formUnion(seasons.map(\.number))
        if !seasons.contains(where: { $0.number == 0 }) { numbers.remove(0) }
        return numbers.sorted()
    }

    /// Row source per season: the TMDB episode list, each slot carrying the
    /// matching library item if we have the file. Falls back to library-only
    /// rows when TMDB metadata is missing (offline, no match).
    var seasonSlots: [(number: Int, slots: [EpisodeSlot])] {
        let libraryBySeason = Dictionary(grouping: show.episodes) { $0.season ?? 0 }
        return visibleSeasonNumbers.map { season in
            let items = (libraryBySeason[season] ?? [])
                .sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
            guard let meta = seasonMeta[season], !meta.isEmpty else {
                return (season, items.map {
                    EpisodeSlot(season: season, number: $0.episode ?? 0,
                                meta: nil, item: $0)
                })
            }
            let byEpisode = Dictionary(grouping: items) { $0.episode ?? 0 }
            var slots = meta.keys.sorted().map { num in
                EpisodeSlot(season: season, number: num, meta: meta[num],
                            item: byEpisode[num]?.first)
            }
            // Library files with episode numbers TMDB doesn't list still render.
            let known = Set(meta.keys)
            slots += items.filter { !known.contains($0.episode ?? 0) }.map {
                EpisodeSlot(season: season, number: $0.episode ?? 0,
                            meta: nil, item: $0)
            }
            return (season, slots)
        }
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
        if let fetched = try? await tmdb.showDetails(id: showID) {
            details = fetched
            allSeasonNumbers = fetched.seasonNumbers
        }
        if let fetched = try? await tmdb.showCredits(id: showID) { cast = fetched }
        // For Find Streams on missing episodes; empty imdb_id decodes as nil.
        if let ids = try? await tmdb.externalIDs(showID: showID) {
            imdbID = ids.imdbID
        }
        for season in visibleSeasonNumbers {
            guard seasonMeta[season] == nil,
                  let episodes = try? await tmdb.seasonEpisodes(showID: showID,
                                                                season: season)
            else { continue }
            seasonMeta[season] = Dictionary(
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
