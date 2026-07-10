import Foundation
import StreamCore

/// A TMDB search hit that may not be in the library yet.
enum SearchMedia: Identifiable {
    case movie(TMDBMovie)
    case show(TMDBShow)

    var id: String {
        switch self {
        case .movie(let m): "movie-\(m.id)"
        case .show(let s): "show-\(s.id)"
        }
    }
    var tmdbID: Int {
        switch self {
        case .movie(let m): m.id
        case .show(let s): s.id
        }
    }
    var title: String {
        switch self {
        case .movie(let m): m.title
        case .show(let s): s.name
        }
    }
    var year: Int? {
        let date = switch self {
        case .movie(let m): m.releaseDate
        case .show(let s): s.firstAirDate
        }
        return date.flatMap { Int($0.prefix(4)) }
    }
    var posterPath: String? {
        switch self {
        case .movie(let m): m.posterPath
        case .show(let s): s.posterPath
        }
    }
    var overview: String {
        switch self {
        case .movie(let m): m.overview
        case .show(let s): s.overview
        }
    }
    var isShow: Bool {
        if case .show = self { return true }
        return false
    }
}

@Observable
@MainActor
final class GlobalSearchModel {
    private(set) var movies: [TMDBMovie] = []
    private(set) var shows: [TMDBShow] = []
    private(set) var searching = false

    func search(query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, !AppSettings.shared.tmdbToken.isEmpty else {
            movies = []; shows = []; return
        }
        searching = true
        defer { searching = false }
        let tmdb = TMDBClient(bearerToken: AppSettings.shared.tmdbToken)
        async let movieHits = tmdb.searchMovie(title: q, year: nil)
        async let showHits = tmdb.searchTV(title: q, year: nil)
        let m = (try? await movieHits) ?? []
        let s = (try? await showHits) ?? []
        guard !Task.isCancelled else { return }
        movies = m
        shows = s
    }
}
