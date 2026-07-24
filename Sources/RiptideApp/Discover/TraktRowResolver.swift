import Foundation
import StreamCore

/// Trakt rows carry TMDB ids but no artwork; resolve posters via the
/// cached TMDB details endpoints, ~6 lookups in flight, order-preserving.
/// A failed lookup falls back to a posterless card from the Trakt fields.
@MainActor
func resolveTraktRows(
    _ rows: [(isShow: Bool, media: TraktListMedia?)]
) async -> [SearchMedia] {
    let tmdb = TMDBClient(bearerToken: AppSettings.shared.tmdbToken,
                          cache: .shared)
    let wanted = rows.enumerated()
        .compactMap { index, row -> (index: Int, isShow: Bool, id: Int, title: String, year: Int?)? in
            guard let media = row.media, let id = media.ids.tmdb else { return nil }
            return (index, row.isShow, id, media.title, media.year)
        }
    var resolved: [(Int, SearchMedia)] = []
    await withTaskGroup(of: (Int, SearchMedia).self) { group in
        var iterator = wanted.makeIterator()
        func addNext() {
            guard let item = iterator.next() else { return }
            group.addTask {
                let dateStr = item.year.map { String($0) }
                if item.isShow {
                    do {
                        let d = try await tmdb.showDetails(id: item.id)
                        return (item.index, .show(TMDBShow(
                            id: item.id, name: d.name, overview: d.overview,
                            posterPath: d.posterPath,
                            firstAirDate: d.firstAirDate,
                            voteAverage: d.voteAverage)))
                    } catch {
                        return (item.index, .show(TMDBShow(
                            id: item.id, name: item.title, overview: "",
                            posterPath: nil,
                            firstAirDate: dateStr,
                            voteAverage: 0.0)))
                    }
                } else {
                    do {
                        let d = try await tmdb.movieDetails(id: item.id)
                        return (item.index, .movie(TMDBMovie(
                            id: item.id, title: d.title, overview: d.overview,
                            posterPath: d.posterPath,
                            releaseDate: d.releaseDate,
                            voteAverage: d.voteAverage)))
                    } catch {
                        return (item.index, .movie(TMDBMovie(
                            id: item.id, title: item.title, overview: "",
                            posterPath: nil,
                            releaseDate: dateStr,
                            voteAverage: 0.0)))
                    }
                }
            }
        }
        for _ in 0..<6 { addNext() }
        for await result in group {
            resolved.append(result)
            addNext()
        }
    }
    return resolved.sorted { $0.0 < $1.0 }.map(\.1)
}
