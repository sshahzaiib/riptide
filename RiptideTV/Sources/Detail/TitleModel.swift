import Foundation
import Observation
import StreamCore
import class StreamCore.LibraryItem

struct PickerContext: Identifiable {
    let id = UUID()
    let items: [LibraryItem]
    let request: StreamRequest?
}

enum PlayOutcome { case play(PlayItem), picker(PickerContext) }

/// Loads TMDB metadata, episode rows and resolves Play for one TitlePage.
@Observable
@MainActor
final class TitleModel {
    enum Failure: LocalizedError {
        case noIMDB
        var errorDescription: String? { "This title can't be searched on addons yet." }
    }

    let ref: TitleRef
    private(set) var title: String
    private(set) var overview: String
    private(set) var backdropPath: String?
    private(set) var seasonNumbers: [Int] = []
    private var remoteRows: [EpisodeRow] = []
    private(set) var showModel: ShowPageModel?
    var season = 1
    private var imdbID: String?

    init(ref: TitleRef) {
        self.ref = ref.resolved
        title = self.ref.title
        overview = self.ref.overview
        if case .libraryShow(let g) = self.ref { showModel = ShowPageModel(show: g, store: AppModels.store) }
    }

    private var tmdb: TMDBClient { TMDBClient(bearerToken: AppSettings.shared.tmdbToken, cache: .shared) }

    /// All owned files of a library movie (every version), else empty.
    var movieItems: [LibraryItem] {
        guard case .libraryMovie(let item) = ref else { return [] }
        guard let id = item.tmdbID else { return [item] }
        return AppModels.library.items.filter { $0.tmdbID == id && $0.mediaKind == "movie" }
    }

    var rows: [EpisodeRow] {
        guard let showModel else { return remoteRows }
        return (showModel.seasonSlots.first { $0.number == season }?.slots ?? []).map { slot in
            let state = slot.item.flatMap { showModel.watchState(for: $0) }
                ?? showModel.remoteState(season: slot.season, episode: slot.number)
            return EpisodeRow(id: slot.id, season: slot.season, number: slot.number,
                              name: slot.meta?.name ?? slot.item?.filename ?? "Episode \(slot.number)",
                              items: slot.items, progress: state?.progress,
                              finished: state?.finished ?? false)
        }
    }

    /// The row the show-level Play button starts: resume/next-up for owned shows.
    var playTarget: EpisodeRow? {
        if let key = showModel?.selected?.itemKey,
           let hit = rows.first(where: { $0.items.contains { $0.itemKey == key } }) { return hit }
        return rows.first
    }

    func load() async {
        guard let id = ref.tmdbID else { return }
        if ref.isShow {
            if let d = try? await tmdb.showDetails(id: id) {
                backdropPath = d.backdropPath
                if !d.overview.isEmpty { overview = d.overview }
                seasonNumbers = d.seasonNumbers
            }
            if let showModel {
                await showModel.load(tmdb: tmdb)
                seasonNumbers = showModel.visibleSeasonNumbers
                if let s = showModel.selected?.season { season = s }
            }
            if !seasonNumbers.contains(season) {
                season = seasonNumbers.first { $0 > 0 } ?? seasonNumbers.first ?? 1
            }
            await loadSeason()
        } else if let d = try? await tmdb.movieDetails(id: id) {
            backdropPath = d.backdropPath
            if !d.overview.isEmpty { overview = d.overview }
        }
    }

    /// Non-library shows only; owned shows read ShowPageModel.
    func loadSeason() async {
        guard showModel == nil, let id = ref.tmdbID else { return }
        remoteRows = []
        let s = season
        let eps = (try? await tmdb.seasonEpisodes(showID: id, season: s)) ?? []
        guard s == season else { return }
        remoteRows = eps.map { EpisodeRow(id: "\(s)-\($0.episodeNumber)", season: s,
                                          number: $0.episodeNumber, name: $0.name, items: []) }
    }

    func request(season: Int?, episode: Int?) async throws -> StreamRequest {
        guard let id = ref.tmdbID else { throw Failure.noIMDB }
        if imdbID == nil {
            let ids = ref.isShow ? try? await tmdb.externalIDs(showID: id)
                                 : try? await tmdb.externalIDs(movieID: id)
            imdbID = ids?.imdbID
        }
        guard let imdb = imdbID, !imdb.isEmpty else { throw Failure.noIMDB }
        return StreamRequest(type: ref.isShow ? .series : .movie, imdbID: imdb, title: ref.title,
                             season: season, episode: episode, tmdbID: id)
    }

    /// Play decision table: see task-10 report.
    func resolve(items: [LibraryItem], season: Int? = nil, episode: Int? = nil,
                 forcePicker: Bool, alwaysShow: Bool) async throws -> PlayOutcome {
        if !items.isEmpty {
            if forcePicker {
                return .picker(PickerContext(items: items,
                                             request: try? await request(season: season, episode: episode)))
            }
            if alwaysShow && items.count > 1 { return .picker(PickerContext(items: items, request: nil)) }
            return .play(try await PlayResolver.best(libraryItems: items, request: nil, store: AppModels.store))
        }
        let req = try await request(season: season, episode: episode)
        if forcePicker || alwaysShow { return .picker(PickerContext(items: [], request: req)) }
        return .play(try await PlayResolver.best(libraryItems: [], request: req, store: AppModels.store))
    }
}
