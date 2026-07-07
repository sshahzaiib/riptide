import Foundation

/// Minimal TMDB v3 client authenticated with a v4 "API Read Access Token".
public struct TMDBClient: Sendable {
    let bearerToken: String
    let session: URLSession
    let baseURL: URL

    public init(bearerToken: String,
                session: URLSession = .shared,
                baseURL: URL = URL(string: "https://api.themoviedb.org/3")!) {
        self.bearerToken = bearerToken
        self.session = session
        self.baseURL = baseURL
    }

    func get(_ path: String, query: [String: String]) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TMDBError.badResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401:       throw TMDBError.unauthorized
        default:        throw TMDBError.http(http.statusCode)
        }
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw TMDBError.badResponse }
    }

    public func searchMovie(title: String, year: Int?) async throws -> [TMDBMovie] {
        var query = ["query": title]
        if let year { query["primary_release_year"] = String(year) }
        let data = try await get("search/movie", query: query)
        return try decode(TMDBSearchEnvelope<TMDBMovie>.self, from: data).results
    }

    public func searchTV(title: String, year: Int?) async throws -> [TMDBShow] {
        var query = ["query": title]
        if let year { query["first_air_date_year"] = String(year) }
        let data = try await get("search/tv", query: query)
        return try decode(TMDBSearchEnvelope<TMDBShow>.self, from: data).results
    }

    public func episode(showID: Int, season: Int, episode: Int) async throws -> TMDBEpisode {
        let data = try await get("tv/\(showID)/season/\(season)/episode/\(episode)", query: [:])
        return try decode(TMDBEpisode.self, from: data)
    }

    public func showDetails(id: Int) async throws -> TMDBShowDetails {
        try decode(TMDBShowDetails.self, from: try await get("tv/\(id)", query: [:]))
    }

    public func seasonEpisodes(showID: Int, season: Int) async throws -> [TMDBSeasonEpisode] {
        let data = try await get("tv/\(showID)/season/\(season)", query: [:])
        return try decode(TMDBSeasonEnvelope.self, from: data).episodes
    }

    public func showCredits(id: Int) async throws -> [TMDBCastMember] {
        let data = try await get("tv/\(id)/credits", query: [:])
        return Array(try decode(TMDBCreditsEnvelope.self, from: data).cast.prefix(12))
    }

    public func movieCredits(id: Int) async throws -> [TMDBCastMember] {
        let data = try await get("movie/\(id)/credits", query: [:])
        return Array(try decode(TMDBCreditsEnvelope.self, from: data).cast.prefix(12))
    }

    public func movieDetails(id: Int) async throws -> TMDBMovieDetails {
        try decode(TMDBMovieDetails.self, from: try await get("movie/\(id)", query: [:]))
    }
}
