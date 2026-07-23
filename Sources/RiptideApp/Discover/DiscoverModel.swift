import Foundation
import Observation
import StreamCore

@Observable @MainActor
final class DiscoverModel {
    enum ShelfID: String, CaseIterable, Identifiable {
        case watchlist = "Watchlist"
        case trendingMovies = "Trending Movies"
        case trendingShows = "Trending Shows"
        case popularMovies = "Popular Movies"
        case popularShows = "Popular Shows"
        case traktTrendingMovies = "Trending on Trakt — Movies"
        case traktTrendingShows = "Trending on Trakt — Shows"
        var id: String { rawValue }
    }

    enum ShelfState { case idle, loading, loaded, failed }
    struct Shelf {
        var items: [SearchMedia] = []
        var state: ShelfState = .idle
    }

    private(set) var shelves: [ShelfID: Shelf] = Dictionary(
        uniqueKeysWithValues: ShelfID.allCases.map { ($0, Shelf()) })
    private var hasLoaded = false

    /// Watchlist shelf only exists when Trakt is connected.
    var orderedShelves: [ShelfID] {
        ShelfID.allCases.filter {
            $0 != .watchlist || TraktService.shared.client != nil
        }
    }

    func load(force: Bool = false) {
        guard force || !hasLoaded else { return }
        hasLoaded = true
        for shelf in orderedShelves { fetch(shelf, bypassCache: force) }
    }

    func retry(_ shelf: ShelfID) { fetch(shelf, bypassCache: false) }

    private func fetch(_ shelf: ShelfID, bypassCache: Bool) {
        shelves[shelf]?.state = .loading
        Task {
            do {
                let items = try await items(for: shelf, bypassCache: bypassCache)
                shelves[shelf] = Shelf(items: items, state: .loaded)
            } catch {
                shelves[shelf]?.state = .failed
            }
        }
    }

    private func items(for shelf: ShelfID,
                        bypassCache: Bool) async throws -> [SearchMedia] {
        // Spec: manual refresh (⌘R) must bypass the 30-min listing cache.
        // Shelf listings use a cache-less client when forced; poster
        // resolution below always stays cached (details are stable).
        let tmdb = TMDBClient(bearerToken: AppSettings.shared.tmdbToken,
                              cache: bypassCache ? nil : .shared)
        switch shelf {
        case .trendingMovies:
            return try await tmdb.trendingMovies().prefix(20).map { .movie($0) }
        case .trendingShows:
            return try await tmdb.trendingTV().prefix(20).map { .show($0) }
        case .popularMovies:
            return try await tmdb.popularMovies().prefix(20).map { .movie($0) }
        case .popularShows:
            return try await tmdb.popularTV().prefix(20).map { .show($0) }
        case .watchlist:
            guard let trakt = TraktService.shared.client else { return [] }
            let entries = try await trakt.watchlist()
            return await resolve(entries.map { entry in
                (isShow: entry.type == "show",
                 media: entry.show ?? entry.movie)
            })
        case .traktTrendingMovies:
            guard let trakt = TraktService.shared.client else { return [] }
            let saved = trakt.cache
            if bypassCache { trakt.cache = nil }
            defer { trakt.cache = saved }
            let entries = try await trakt.trendingMovies()
            return await resolve(entries.map { (isShow: false, media: $0.movie) })
        case .traktTrendingShows:
            guard let trakt = TraktService.shared.client else { return [] }
            let saved = trakt.cache
            if bypassCache { trakt.cache = nil }
            defer { trakt.cache = saved }
            let entries = try await trakt.trendingShows()
            return await resolve(entries.map { (isShow: true, media: $0.show) })
        }
    }

    /// Trakt rows carry TMDB ids but no artwork; resolve posters via the
    /// TMDB details endpoints, ~6 lookups in flight. Always uses a cached
    /// client — details are stable, so refresh never needs to bypass here.
    private func resolve(
        _ rows: [(isShow: Bool, media: TraktListMedia?)]
    ) async -> [SearchMedia] {
        let tmdb = TMDBClient(bearerToken: AppSettings.shared.tmdbToken,
                              cache: .shared)
        let wanted: [(Int, Bool, Int)] = rows.prefix(20).enumerated()
            .compactMap { index, row in
                guard let id = row.media?.ids.tmdb else { return nil }
                return (index, row.isShow, id)
            }
        var resolved: [(Int, SearchMedia)] = []
        await withTaskGroup(of: (Int, SearchMedia)?.self) { group in
            var iterator = wanted.makeIterator()
            var inFlight = 0
            func addNext() {
                guard let (index, isShow, id) = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    if isShow {
                        guard let d = try? await tmdb.showDetails(id: id)
                        else { return nil }
                        return (index, .show(TMDBShow(
                            id: id, name: d.name, overview: d.overview,
                            posterPath: d.posterPath,
                            firstAirDate: d.firstAirDate,
                            voteAverage: d.voteAverage)))
                    } else {
                        guard let d = try? await tmdb.movieDetails(id: id)
                        else { return nil }
                        return (index, .movie(TMDBMovie(
                            id: id, title: d.title, overview: d.overview,
                            posterPath: d.posterPath,
                            releaseDate: d.releaseDate,
                            voteAverage: d.voteAverage)))
                    }
                }
            }
            for _ in 0..<6 { addNext() }
            for await result in group {
                inFlight -= 1
                if let result { resolved.append(result) }
                addNext()
            }
        }
        return resolved.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
