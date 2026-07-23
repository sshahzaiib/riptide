import Foundation

enum CacheTTL {
    static let details: TimeInterval = 7 * 24 * 3600
    static let season: TimeInterval = 24 * 3600
    static let listing: TimeInterval = 30 * 60
}

/// Minimal TMDB v3 client authenticated with a v4 "API Read Access Token".
public struct TMDBClient: Sendable {
    let bearerToken: String
    let session: URLSession
    let baseURL: URL
    let cache: MetadataCache?

    public init(bearerToken: String,
                session: URLSession = .shared,
                baseURL: URL = URL(string: "https://api.themoviedb.org/3")!,
                cache: MetadataCache? = nil) {
        self.bearerToken = bearerToken
        self.session = session
        self.baseURL = baseURL
        self.cache = cache
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

    /// Cache-through fetch: cached bytes that decode win; anything else
    /// (miss, expired, corrupt) falls through to the network and re-stores.
    func cached<T: Decodable>(_ type: T.Type, path: String,
                               query: [String: String],
                               ttl: TimeInterval) async throws -> T {
        let key = cacheKey(path: path, query: query)
        if let cache, let hit = await cache.data(for: key, ttl: ttl),
           let decoded = try? JSONDecoder().decode(T.self, from: hit) {
            return decoded
        }
        let fresh = try await get(path, query: query)
        let decoded = try decode(T.self, from: fresh)
        if let cache { await cache.store(fresh, for: key) }
        return decoded
    }

    private func cacheKey(path: String, query: [String: String]) -> String {
        "tmdb:" + path + "?" + query.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "&")
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

    public func trendingMovies() async throws -> [TMDBMovie] {
        try await cached(TMDBSearchEnvelope<TMDBMovie>.self,
                         path: "trending/movie/day", query: [:],
                         ttl: CacheTTL.listing).results
    }

    public func trendingTV() async throws -> [TMDBShow] {
        try await cached(TMDBSearchEnvelope<TMDBShow>.self,
                         path: "trending/tv/day", query: [:],
                         ttl: CacheTTL.listing).results
    }

    public func popularMovies() async throws -> [TMDBMovie] {
        try await cached(TMDBSearchEnvelope<TMDBMovie>.self,
                         path: "movie/popular", query: [:],
                         ttl: CacheTTL.listing).results
    }

    public func popularTV() async throws -> [TMDBShow] {
        try await cached(TMDBSearchEnvelope<TMDBShow>.self,
                         path: "tv/popular", query: [:],
                         ttl: CacheTTL.listing).results
    }

    public func episode(showID: Int, season: Int, episode: Int) async throws -> TMDBEpisode {
        try await cached(TMDBEpisode.self, path: "tv/\(showID)/season/\(season)/episode/\(episode)", query: [:], ttl: CacheTTL.season)
    }

    public func showDetails(id: Int) async throws -> TMDBShowDetails {
        try await cached(TMDBShowDetails.self, path: "tv/\(id)", query: [:], ttl: CacheTTL.details)
    }

    public func seasonEpisodes(showID: Int, season: Int) async throws -> [TMDBSeasonEpisode] {
        let envelope = try await cached(TMDBSeasonEnvelope.self, path: "tv/\(showID)/season/\(season)", query: [:], ttl: CacheTTL.season)
        return envelope.episodes
    }

    public func showCredits(id: Int) async throws -> [TMDBCastMember] {
        let envelope = try await cached(TMDBCreditsEnvelope.self, path: "tv/\(id)/credits", query: [:], ttl: CacheTTL.details)
        return Array(envelope.cast.prefix(12))
    }

    public func movieCredits(id: Int) async throws -> [TMDBCastMember] {
        let envelope = try await cached(TMDBCreditsEnvelope.self, path: "movie/\(id)/credits", query: [:], ttl: CacheTTL.details)
        return Array(envelope.cast.prefix(12))
    }

    public func movieDetails(id: Int) async throws -> TMDBMovieDetails {
        try await cached(TMDBMovieDetails.self, path: "movie/\(id)", query: [:], ttl: CacheTTL.details)
    }

    public func externalIDs(movieID: Int) async throws -> TMDBExternalIDs {
        try await cached(TMDBExternalIDs.self, path: "movie/\(movieID)/external_ids", query: [:], ttl: CacheTTL.details)
    }

    public func externalIDs(showID: Int) async throws -> TMDBExternalIDs {
        try await cached(TMDBExternalIDs.self, path: "tv/\(showID)/external_ids", query: [:], ttl: CacheTTL.details)
    }

    /// Clean title-treatment logo (transparent PNG, Stremio-style loading
    /// art). Highest-voted English logo, else any language. nil = none.
    public func logoPath(showID: Int) async throws -> String? {
        try await logoPath(kind: "tv", id: showID)
    }

    public func logoPath(movieID: Int) async throws -> String? {
        try await logoPath(kind: "movie", id: movieID)
    }

    private func logoPath(kind: String, id: Int) async throws -> String? {
        let envelope = try await cached(TMDBImagesEnvelope.self,
                                        path: "\(kind)/\(id)/images",
                                        query: ["include_image_language": "en,null"],
                                        ttl: CacheTTL.details)
        let logos = envelope.logos.sorted { $0.voteAverage > $1.voteAverage }
        return (logos.first { $0.language == "en" } ?? logos.first)?.filePath
    }
}

