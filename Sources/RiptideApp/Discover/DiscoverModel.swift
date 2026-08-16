import Foundation
import Observation
import StreamCore

@Observable @MainActor
final class DiscoverModel {
    static let shared = DiscoverModel()

    enum ShelfID: String, CaseIterable, Identifiable {
        case watchlist = "Watchlist"
        case recommendedMovies = "Recommended for You — Movies"
        case recommendedShows = "Recommended for You — Shows"
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

    /// SearchMedia.id ("movie-603") → trakt id, for recommendation dismiss.
    private var recTraktIDs: [String: Int] = [:]
    /// Transient error from the last failed dismiss; cleared on next dismiss.
    private(set) var dismissError: (shelf: ShelfID, message: String)?

    /// Watchlist shelf only exists when Trakt is connected.
    var orderedShelves: [ShelfID] {
        ShelfID.allCases.filter { shelf in
            switch shelf {
            case .watchlist, .recommendedMovies, .recommendedShows:
                return TraktService.shared.client != nil && TraktService.shared.isConnected
            case .traktTrendingMovies, .traktTrendingShows:
                return TraktService.shared.client != nil
            default:
                return true
            }
        }
    }

    func load(force: Bool = false) {
        for shelf in orderedShelves {
            guard shelves[shelf]?.state != .loading else { continue }
            fetch(shelf, bypassCache: force)
        }
    }

    func retry(_ shelf: ShelfID) {
        guard shelves[shelf]?.state != .loading else { return }
        fetch(shelf, bypassCache: false)
    }

    private func fetch(_ shelf: ShelfID, bypassCache: Bool) {
        let wasLoaded = shelves[shelf]?.state == .loaded
        if !wasLoaded {
            shelves[shelf]?.state = .loading
        }
        Task {
            do {
                let items = try await items(for: shelf, bypassCache: bypassCache)
                shelves[shelf] = Shelf(items: items, state: .loaded)
            } catch {
                if !wasLoaded {
                    shelves[shelf]?.state = .failed
                }
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
            await WatchlistModel.shared.load()
            if WatchlistModel.shared.state == .failed {
                throw URLError(.cannotLoadFromNetwork)
            }
            return Array(WatchlistModel.shared.items.prefix(20))
        case .recommendedMovies:
            guard let trakt = TraktService.shared.client else { return [] }
            let recs = try await trakt.recommendedMovies()
            mergeRecTraktIDs(recs, isShow: false)
            return await resolveTraktRows(recs.prefix(20).map { (isShow: false, media: $0) })
        case .recommendedShows:
            guard let trakt = TraktService.shared.client else { return [] }
            let recs = try await trakt.recommendedShows()
            mergeRecTraktIDs(recs, isShow: true)
            return await resolveTraktRows(recs.prefix(20).map { (isShow: true, media: $0) })
        case .traktTrendingMovies:
            guard let trakt = TraktService.shared.client else { return [] }
            let entries = try await trakt.trendingMovies(bypassCache: bypassCache)
            return await resolveTraktRows(entries.prefix(20).map { (isShow: false, media: $0.movie) })
        case .traktTrendingShows:
            guard let trakt = TraktService.shared.client else { return [] }
            let entries = try await trakt.trendingShows(bypassCache: bypassCache)
            return await resolveTraktRows(entries.prefix(20).map { (isShow: true, media: $0.show) })
        }
    }

    func isRecommendationShelf(_ id: ShelfID) -> Bool {
        id == .recommendedMovies || id == .recommendedShows
    }

    private func mergeRecTraktIDs(_ recs: [TraktListMedia], isShow: Bool) {
        for rec in recs {
            guard let tmdb = rec.ids.tmdb, let trakt = rec.ids.trakt else { continue }
            recTraktIDs[(isShow ? "show-" : "movie-") + String(tmdb)] = trakt
        }
    }

    /// Optimistically removes the card, hides it server-side, re-inserts on failure.
    func dismissRecommendation(_ media: SearchMedia, in shelf: ShelfID) async {
        guard isRecommendationShelf(shelf),
              let trakt = TraktService.shared.client,
              let traktID = recTraktIDs[media.id],
              let index = shelves[shelf]?.items.firstIndex(where: { $0.id == media.id })
        else { return }
        dismissError = nil
        shelves[shelf]?.items.remove(at: index)
        do {
            try await trakt.hideRecommendation(traktID: traktID, isShow: media.isShow)
        } catch {
            let insertAt = min(index, shelves[shelf]?.items.count ?? 0)
            shelves[shelf]?.items.insert(media, at: insertAt)
            dismissError = (shelf, "Couldn't hide \"\(media.title)\"")
        }
    }
}
