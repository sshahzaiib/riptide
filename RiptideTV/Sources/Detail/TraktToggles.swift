import SwiftUI
import StreamCore

/// Watchlist + favorite toggles for a title. Renders nothing when Trakt is
/// signed out or the title has no TMDB match. Used as title-page buttons and
/// as the poster long-press menu.
struct TraktToggles: View {
    let ref: TitleRef

    var body: some View {
        if TraktService.shared.isConnected, let media = ref.searchMedia {
            let listed = WatchlistModel.shared.isOnWatchlist(media)
            Button { Task { await WatchlistModel.shared.toggle(media) } } label: {
                Label(listed ? "On Watchlist" : "Add to Watchlist", systemImage: listed ? "bookmark.fill" : "bookmark")
            }
            .disabled(WatchlistModel.shared.isToggling(media))
            let fav = FavoritesModel.shared.isFavorite(media)
            Button { Task { await FavoritesModel.shared.toggle(media) } } label: {
                Label(fav ? "Favorited" : "Add to Favorites", systemImage: fav ? "heart.fill" : "heart")
            }
            .disabled(FavoritesModel.shared.isToggling(media))
        }
    }

    /// Message from the last failed toggle on this title, if any.
    @MainActor static func error(for ref: TitleRef) -> String? {
        guard let id = ref.searchMedia?.id else { return nil }
        return [WatchlistModel.shared.lastError, FavoritesModel.shared.lastError]
            .compactMap { $0 }.first { $0.id == id }?.message
    }

    /// Fetches membership once per sign-in so the toggles show the right state.
    @MainActor static func loadMembership() async {
        guard TraktService.shared.isConnected else { return }
        if WatchlistModel.shared.state == .idle { await WatchlistModel.shared.load() }
        if FavoritesModel.shared.state == .idle { await FavoritesModel.shared.load() }
    }
}

extension TitleRef {
    /// The Trakt-addressable form of this title; nil for unmatched library files.
    var searchMedia: SearchMedia? {
        if case .media(let m) = self { return m }
        guard let id = tmdbID else { return nil }
        let date = year.map { "\($0)-01-01" }
        return isShow
            ? .show(TMDBShow(id: id, name: title, overview: overview, posterPath: posterPath, firstAirDate: date, voteAverage: 0))
            : .movie(TMDBMovie(id: id, title: title, overview: overview, posterPath: posterPath, releaseDate: date, voteAverage: 0))
    }
}
