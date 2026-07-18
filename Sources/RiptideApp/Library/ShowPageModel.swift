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
    private(set) var remoteStates: [String: (progress: Double, finished: Bool)] = [:]
    private(set) var allSeasonNumbers: [Int] = []

    struct EpisodeSlot: Identifiable {
        let season: Int
        let number: Int
        let meta: TMDBSeasonEpisode?
        /// Every owned file of this episode, VersionPreference-ranked;
        /// `.first` is the preferred version. Empty = we don't own it.
        let items: [LibraryItem]
        var item: LibraryItem? { items.first }
        var id: String { item?.itemKey ?? "tmdb-\(season)-\(number)" }
    }

    var selected: LibraryItem?
    private var stateByKey: [String: WatchState] = [:]
    private var userSelected = false

    init(show: ShowGroup, store: LibraryStore) {
        self.show = show
        self.store = store
        refreshWatchStates()
        self.selected = resumeTarget?.item ?? firstUnwatched ?? show.episodes.first
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

    /// Row source per season: one slot per episode number, duplicate files
    /// collapsed into that slot's ranked `items`. Falls back to library-only
    /// rows when TMDB metadata is missing (offline, no match).
    var seasonSlots: [(number: Int, slots: [EpisodeSlot])] {
        let libraryBySeason = Dictionary(grouping: show.episodes) { $0.season ?? 0 }
        return visibleSeasonNumbers.map { season in
            (season, slots(season: season, items: libraryBySeason[season] ?? []))
        }
    }

    private func slots(season: Int, items: [LibraryItem]) -> [EpisodeSlot] {
        let meta = seasonMeta[season] ?? [:]
        let byEpisode = Dictionary(grouping: items.filter { $0.episode != nil },
                                   by: { $0.episode! })
        var slots: [EpisodeSlot] = []
        for num in meta.keys.sorted() {
            slots.append(EpisodeSlot(season: season, number: num, meta: meta[num],
                                     items: ranked(byEpisode[num] ?? [])))
        }
        // Library files with episode numbers TMDB doesn't list still render.
        for num in byEpisode.keys.filter({ meta[$0] == nil }).sorted() {
            slots.append(EpisodeSlot(season: season, number: num, meta: nil,
                                     items: ranked(byEpisode[num]!)))
        }
        // Files with no parsed episode number: one card each, never merged.
        slots += items.filter { $0.episode == nil }.map {
            EpisodeSlot(season: season, number: 0, meta: nil, items: [$0])
        }
        return slots
    }

    private func ranked(_ items: [LibraryItem]) -> [LibraryItem] {
        VersionPreference.ranked(items: items, states: stateByKey)
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

    /// First not-finished episode in (season, episode) order. An episode
    /// counts as watched when ANY duplicate file of it is finished.
    /// Season 0 (specials + unparsed) is excluded from next-up.
    var firstUnwatched: LibraryItem? {
        let numbered = show.episodes
            .filter { ($0.season ?? 0) > 0 && $0.episode != nil }
            .sorted { ($0.season!, $0.episode!) < ($1.season!, $1.episode!) }
        let finishedEpisodes = Set(
            numbered.filter { stateByKey[$0.itemKey]?.finished == true }
                .map { "\($0.season!)#\($0.episode!)" })
        guard let hit = numbered.first(where: {
            !finishedEpisodes.contains("\($0.season!)#\($0.episode!)")
        }) else { return nil }
        // Prefer the ranked version of that episode so the hero Play button
        // and the card's ✓ agree on which file plays.
        let sameEpisode = numbered.filter { $0.season == hit.season && $0.episode == hit.episode }
        return VersionPreference.preferred(items: sameEpisode, states: stateByKey)
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

    /// All owned files of this item's episode, preference-ranked (`.first`
    /// preferred). Items with no parsed episode number stay single-version.
    func versions(of item: LibraryItem) -> [LibraryItem] {
        guard let s = item.season, let e = item.episode else { return [item] }
        return ranked(show.episodes.filter { $0.season == s && $0.episode == e })
    }

    /// Context-menu mark: local write first (survives Trakt pulls), then a
    /// best-effort batched push to Trakt history.
    func setWatched(_ watched: Bool, items: [LibraryItem]) {
        // A mark is episode-level (Trakt has no notion of files): expand each
        // numbered item to every duplicate file of the same episode so 1080p
        // and 4K copies never diverge. Unnumbered items pass through as-is.
        let byEpisode = Dictionary(grouping: show.episodes.filter {
            $0.season != nil && $0.episode != nil
        }) { "\($0.season!)#\($0.episode!)" }
        var expanded: [LibraryItem] = []
        var seenKeys = Set<String>()
        for item in items {
            let siblings: [LibraryItem]
            if let season = item.season, let episode = item.episode {
                siblings = byEpisode["\(season)#\(episode)"] ?? [item]
            } else {
                siblings = [item]
            }
            for sibling in siblings where seenKeys.insert(sibling.itemKey).inserted {
                expanded.append(sibling)
            }
        }

        for item in expanded {
            try? store.setWatched(itemKey: item.itemKey, watched: watched)
        }
        refreshWatchStates()
        guard let showID else { return }
        var seenEpisodes = Set<String>()
        let media: [TraktMedia] = expanded.compactMap { item in
            guard let season = item.season, let episode = item.episode,
                  seenEpisodes.insert("\(season)#\(episode)").inserted else { return nil }
            return .episode(showTMDBID: showID, season: season, episode: episode)
        }
        TraktService.shared.setWatched(watched, media: media)
    }


    func episodeMeta(for item: LibraryItem) -> TMDBSeasonEpisode? {
        guard let season = item.season, let episode = item.episode else { return nil }
        return seasonMeta[season]?[episode]
    }

    func remoteState(season: Int, episode: Int) -> (progress: Double, finished: Bool)? {
        remoteStates["\(season)#\(episode)"]
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
                episodes.map { ($0.episodeNumber, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        if let fetched = await TraktService.shared.showEpisodeStates(tmdbID: showID) {
            remoteStates = fetched
        }
    }

    /// One store query; every card reads the dictionary.
    func refreshWatchStates() {
        let states = (try? store.allWatchStates()) ?? []
        stateByKey = Dictionary(states.map { ($0.itemKey, $0) },
                                uniquingKeysWith: { first, _ in first })
        // Follow playback progress unless the user picked an episode manually.
        if !userSelected {
            selected = resumeTarget?.item ?? firstUnwatched ?? selected ?? show.episodes.first
        }
    }

    func userDidSelect(_ item: LibraryItem) {
        userSelected = true
        selected = item
    }
}
