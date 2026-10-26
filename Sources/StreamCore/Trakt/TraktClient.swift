import CryptoKit
import Foundation

/// Trakt.tv API v2 client. MainActor because tokens mutate and the app is
/// MainActor-driven; all I/O is async URLSession.
// MARK: Payload encoding

struct TraktIDsPayload: Encodable { let tmdb: Int }
struct TraktRefPayload: Encodable { let ids: TraktIDsPayload }
struct TraktEpisodePayload: Encodable { let season: Int; let number: Int }

struct ScrobbleBody: Encodable {
    var movie: TraktRefPayload?
    var show: TraktRefPayload?
    var episode: TraktEpisodePayload?
    let progress: Double
}

struct RatingsBody: Encodable {
    struct Item: Encodable { let rating: Int; let ids: TraktIDsPayload }
    var movies: [Item]?
    var shows: [Item]?
}

struct HistoryBody: Encodable {
    struct Show: Encodable { let ids: TraktIDsPayload; let seasons: [Season]? }
    struct Season: Encodable { let number: Int; let episodes: [Episode] }
    struct Episode: Encodable { let number: Int }
    var movies: [TraktRefPayload]?
    var shows: [Show]?
}

@MainActor
public final class TraktClient {
    public var tokens: TraktTokens?
    /// Fired whenever a 401-triggered refresh succeeds; the app persists them.
    public var onTokensRefreshed: ((TraktTokens) -> Void)?
    public var cache: MetadataCache?

    let clientID: String
    private let clientSecret: String
    private let session: URLSession
    private let base = URL(string: "https://api.trakt.tv")!

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let raw = try d.singleValueContainer().decode(String.self)
            // Trakt mixes fractional ("….000Z") and plain ISO 8601 timestamps.
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true)
                .parse(raw) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath,
                                                    debugDescription: "Bad date: \(raw)"))
        }
        return decoder
    }()

    public init(clientID: String, clientSecret: String, tokens: TraktTokens? = nil,
                session: URLSession = .shared) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.tokens = tokens
        self.session = session
    }

    // MARK: Device auth

    public func requestDeviceCode() async throws -> TraktDeviceCode {
        let data = try await post(path: "/oauth/device/code",
                                  body: ["client_id": clientID],
                                  allowedStatus: [200])
        return try Self.decoder.decode(TraktDeviceCode.self, from: data)
    }

    /// One poll step. nil = still pending (caller sleeps `interval` and retries).
    public func pollDeviceToken(deviceCode: String) async throws -> TraktTokens? {
        let (data, status) = try await postRaw(path: "/oauth/device/token",
                                               body: ["code": deviceCode,
                                                      "client_id": clientID,
                                                      "client_secret": clientSecret])
        switch status {
        case 200:
            let fetched = try Self.decoder.decode(TraktTokens.self, from: data)
            tokens = fetched
            return fetched
        case 400, 429: return nil                       // pending / slow down
        case 404, 409, 410, 418: throw TraktError.denied
        default: throw TraktError.http(status)
        }
    }

    /// Concurrent 401s must share one refresh — Trakt refresh tokens are
    /// single-use, so a second refresh with the same token kills the session.
    private var refreshInFlight: Task<TraktTokens, Error>?

    @discardableResult
    public func refreshTokens() async throws -> TraktTokens {
        if let refreshInFlight { return try await refreshInFlight.value }
        let task = Task { try await performRefresh() }
        refreshInFlight = task
        defer { refreshInFlight = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> TraktTokens {
        guard let tokens else { throw TraktError.unauthorized }
        let (data, status) = try await postRaw(path: "/oauth/token",
                                               body: ["refresh_token": tokens.refreshToken,
                                                      "client_id": clientID,
                                                      "client_secret": clientSecret,
                                                      "redirect_uri": "urn:ietf:wg:oauth:2.0:oob",
                                                      "grant_type": "refresh_token"])
        guard status == 200 else { throw TraktError.unauthorized }
        let fetched = try Self.decoder.decode(TraktTokens.self, from: data)
        self.tokens = fetched
        onTokensRefreshed?(fetched)
        return fetched
    }

    // MARK: User read cache

    public static let userCachePrefix = "trakt:user:"

    private enum UserTTL {
        static let watched: TimeInterval = 15 * 60
        static let watchlist: TimeInterval = 15 * 60
        static let favorites: TimeInterval = 30 * 60
        static let recommendations: TimeInterval = 6 * 3600
        static let hidden: TimeInterval = 6 * 3600
        static let progress: TimeInterval = 24 * 3600
    }

    /// "trakt:user:<8-hex-of-token-sha>:<path>[?<sorted query>]"
    private func userCacheKey(path: String, query: [String: String]?) -> String? {
        guard let token = tokens?.accessToken else { return nil }
        let acct = SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(8)
        let sortedQuery = (query ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return "\(Self.userCachePrefix)\(acct):\(path)" + (sortedQuery.isEmpty ? "" : "?\(sortedQuery)")
    }

    /// Bumped by every authorized write (Task 3). A GET already in flight when
    /// a write lands must not store its stale response into the purged cache.
    private var writeEpoch = 0

    /// Cache-through authorized GET. Miss/expired/corrupt falls to the network
    /// and re-stores. `notBefore` invalidates entries stored before that date.
    private func cachedSend(path: String, query: [String: String]? = nil,
                            ttl: TimeInterval,
                            notBefore: Date? = nil) async throws -> Data {
        guard let cache, let key = userCacheKey(path: path, query: query) else {
            return try await send(path: path, query: query)
        }
        if let hit = await cache.data(for: key, ttl: ttl, notBefore: notBefore) {
            return hit
        }
        let epoch = writeEpoch
        let fresh = try await send(path: path, query: query)
        if epoch == writeEpoch { await cache.store(fresh, for: key) }
        return fresh
    }

    // MARK: Request infra

    private func request(path: String, method: String, body: Data?,
                         authorized: Bool, query: [String: String]? = nil) -> URLRequest {
        var url = base.appending(path: path)
        if let query, !query.isEmpty {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            comps.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            url = comps.url!
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2", forHTTPHeaderField: "trakt-api-version")
        req.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        if authorized, let tokens {
            req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func postRaw(path: String, body: [String: String]) async throws -> (Data, Int) {
        let payload = try JSONEncoder().encode(body)
        let req = request(path: path, method: "POST", body: payload, authorized: false)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw TraktError.badResponse }
        return (data, http.statusCode)
    }

    private func post(path: String, body: [String: String],
                      allowedStatus: Set<Int>) async throws -> Data {
        let (data, status) = try await postRaw(path: path, body: body)
        guard allowedStatus.contains(status) else { throw TraktError.http(status) }
        return data
    }

    // MARK: Scrobbling

    /// Returns Trakt's raw response so callers can log what it resolved
    /// the media to.
    @discardableResult
    public func scrobble(_ action: TraktScrobbleAction, media: TraktMedia,
                         progress: Double) async throws -> Data {
        var body = ScrobbleBody(progress: progress)
        switch media {
        case .movie(let id), .show(let id):
            body.movie = TraktRefPayload(ids: TraktIDsPayload(tmdb: id))
        case .episode(let showID, let season, let episode):
            body.show = TraktRefPayload(ids: TraktIDsPayload(tmdb: showID))
            body.episode = TraktEpisodePayload(season: season, number: episode)
        }
        return try await send(path: "/scrobble/\(action.rawValue)", method: "POST",
                              body: try JSONEncoder().encode(body))
    }

    // MARK: Sync pulls

    public func watchlist() async throws -> [TraktWatchlistEntry] {
        try Self.decoder.decode([TraktWatchlistEntry].self,
                                from: try await cachedSend(path: "/sync/watchlist", ttl: UserTTL.watchlist))
    }

    public func trendingMovies(bypassCache: Bool = false) async throws -> [TraktTrendingEntry] {
        try await trending(path: "/movies/trending", bypassCache: bypassCache)
    }

    public func trendingShows(bypassCache: Bool = false) async throws -> [TraktTrendingEntry] {
        try await trending(path: "/shows/trending", bypassCache: bypassCache)
    }

    /// Public (client-id only) GET with a 30-minute cache.
    private func trending(path: String, bypassCache: Bool) async throws -> [TraktTrendingEntry] {
        let key = "trakt:\(path)"
        if !bypassCache, let cache, let hit = await cache.data(for: key, ttl: 30 * 60),
           let decoded = try? Self.decoder.decode([TraktTrendingEntry].self,
                                                  from: hit) {
            return decoded
        }
        let (data, response) = try await session.data(
            for: request(path: path, method: "GET", body: nil,
                         authorized: false))
        guard let http = response as? HTTPURLResponse else {
            throw TraktError.badResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw TraktError.http(http.statusCode)
        }
        let decoded = try Self.decoder.decode([TraktTrendingEntry].self,
                                              from: data)
        if let cache { await cache.store(data, for: key) }
        return decoded
    }

    public func playback() async throws -> [TraktPlaybackEntry] {
        // extended=full inlines runtimes — the percent→seconds base when the
        // local store has no duration (fresh install / store rebuild).
        try Self.decoder.decode([TraktPlaybackEntry].self,
                                from: try await send(path: "/sync/playback",
                                                     query: ["extended": "full"]))
    }

    public func watchedMovies() async throws -> [TraktWatchedMovie] {
        try Self.decoder.decode([TraktWatchedMovie].self,
                                from: try await cachedSend(path: "/sync/watched/movies",
                                                           ttl: UserTTL.watched))
    }

    public func watchedShows() async throws -> [TraktWatchedShow] {
        try Self.decoder.decode([TraktWatchedShow].self,
                                from: try await cachedSend(path: "/sync/watched/shows",
                                                           ttl: UserTTL.watched))
    }

    /// NOTE: takes the TRAKT id (not TMDB) — /shows/{id} resolves ids in
    /// Trakt's namespace.
    public func showProgress(traktID: Int,
                             lastActivity: Date? = nil) async throws -> TraktShowProgress {
        try Self.decoder.decode(TraktShowProgress.self,
                                from: try await cachedSend(
                                    path: "/shows/\(traktID)/progress/watched",
                                    ttl: UserTTL.progress,
                                    notBefore: lastActivity))
    }

    // MARK: Ratings

    /// Episodes rate their show (spec: episode-level ratings out of v1).
    public func rate(media: TraktMedia, rating: Int) async throws {
        var body = RatingsBody()
        let clamped = min(max(rating, 1), 10)
        switch media {
        case .movie(let id):
            body.movies = [.init(rating: clamped, ids: TraktIDsPayload(tmdb: id))]
        case .show(let id), .episode(let id, _, _):
            body.shows = [.init(rating: clamped, ids: TraktIDsPayload(tmdb: id))]
        }
        _ = try await send(path: "/sync/ratings", method: "POST",
                           body: try JSONEncoder().encode(body))
    }

    // MARK: History

    /// Mark items watched in Trakt history. Episodes of the same show are
    /// batched into one payload — a whole season is a single HTTP call.
    public func addToHistory(_ media: [TraktMedia]) async throws {
        _ = try await send(path: "/sync/history", method: "POST",
                           body: try JSONEncoder().encode(Self.historyBody(media)))
    }

    public func removeFromHistory(_ media: [TraktMedia]) async throws {
        _ = try await send(path: "/sync/history/remove", method: "POST",
                           body: try JSONEncoder().encode(Self.historyBody(media)))
    }

    // MARK: - Watchlist writes

    private struct WatchlistBody: Encodable {
        var movies: [TraktRefPayload]?
        var shows: [TraktRefPayload]?

        init(tmdbID: Int, isShow: Bool) {
            let ref = TraktRefPayload(ids: .init(tmdb: tmdbID))
            if isShow { shows = [ref] } else { movies = [ref] }
        }
    }

    /// Adds one movie/show to the user's watchlist. OAuth required.
    public func addToWatchlist(tmdbID: Int, isShow: Bool) async throws {
        _ = try await send(path: "/sync/watchlist", method: "POST",
                           body: try JSONEncoder().encode(WatchlistBody(tmdbID: tmdbID, isShow: isShow)))
    }

    /// Removes one movie/show from the user's watchlist. OAuth required.
    public func removeFromWatchlist(tmdbID: Int, isShow: Bool) async throws {
        _ = try await send(path: "/sync/watchlist/remove", method: "POST",
                           body: try JSONEncoder().encode(WatchlistBody(tmdbID: tmdbID, isShow: isShow)))
    }

    // MARK: - Recommendations (VIP-personalized)

    /// Personalized recs; requires OAuth. VIP accounts get a deep rec pool,
    /// so the default asks for the API max of 100.
    public func recommendedMovies(limit: Int = 100) async throws -> [TraktListMedia] {
        try await recommendations(kind: "movies", limit: limit)
    }

    public func recommendedShows(limit: Int = 100) async throws -> [TraktListMedia] {
        try await recommendations(kind: "shows", limit: limit)
    }

    private func recommendations(kind: String, limit: Int) async throws -> [TraktListMedia] {
        try Self.decoder.decode([TraktListMedia].self,
                                from: try await cachedSend(path: "/recommendations/\(kind)",
                                                     query: ["limit": String(limit),
                                                             "ignore_collected": "true",
                                                             "ignore_watchlisted": "true"],
                                                     ttl: UserTTL.recommendations))
    }

    /// Hides one item from future recommendations ("not interested").
    /// Takes the TRAKT id — /recommendations/*/{id} resolves in Trakt's namespace.
    public func hideRecommendation(traktID: Int, isShow: Bool) async throws {
        _ = try await send(path: "/recommendations/\(isShow ? "shows" : "movies")/\(traktID)",
                           method: "DELETE")
    }

    // MARK: - Favorites

    /// Favorites feed Trakt's rec engine; the app only toggles membership.
    public func favorites() async throws -> [TraktWatchlistEntry] {
        try Self.decoder.decode([TraktWatchlistEntry].self,
                                from: try await cachedSend(path: "/sync/favorites", ttl: UserTTL.favorites))
    }

    public func addToFavorites(tmdbID: Int, isShow: Bool) async throws {
        _ = try await send(path: "/sync/favorites", method: "POST",
                           body: try JSONEncoder().encode(WatchlistBody(tmdbID: tmdbID, isShow: isShow)))
    }

    public func removeFromFavorites(tmdbID: Int, isShow: Bool) async throws {
        _ = try await send(path: "/sync/favorites/remove", method: "POST",
                           body: try JSONEncoder().encode(WatchlistBody(tmdbID: tmdbID, isShow: isShow)))
    }

    // MARK: - Hidden progress

    /// Shows the user hid from progress/up-next on Trakt (paginated; one page
    /// of 100 covers realistic use).
    public func hiddenProgressShows() async throws -> [TraktHiddenItem] {
        try Self.decoder.decode([TraktHiddenItem].self,
                                from: try await cachedSend(path: "/users/hidden/progress_watched",
                                                     query: ["type": "show", "limit": "100"],
                                                     ttl: UserTTL.hidden))
    }

    static func historyBody(_ media: [TraktMedia]) -> HistoryBody {
        var movieIDs: Set<Int> = []
        var episodesByShow: [Int: [Int: Set<Int>]] = [:]   // show tmdb → season → episodes
        var wholeShowIDs: Set<Int> = []

        for m in media {
            switch m {
            case .movie(let id):
                movieIDs.insert(id)
            case .show(let id):
                wholeShowIDs.insert(id)
            case .episode(let showID, let season, let episode):
                episodesByShow[showID, default: [:]][season, default: []].insert(episode)
            }
        }

        var body = HistoryBody()
        if !movieIDs.isEmpty {
            body.movies = movieIDs.sorted().map { TraktRefPayload(ids: TraktIDsPayload(tmdb: $0)) }
        }

        let allShowIDs = Set(episodesByShow.keys).union(wholeShowIDs)
        if !allShowIDs.isEmpty {
            body.shows = allShowIDs.sorted().map { showID in
                let seasons: [HistoryBody.Season]?
                if wholeShowIDs.contains(showID) {
                    seasons = nil
                } else {
                    let seasonsDict = episodesByShow[showID] ?? [:]
                    seasons = seasonsDict.sorted { $0.key < $1.key }.map { number, eps in
                        HistoryBody.Season(
                            number: number,
                            episodes: eps.sorted().map { HistoryBody.Episode(number: $0) })
                    }
                }
                return HistoryBody.Show(
                    ids: TraktIDsPayload(tmdb: showID),
                    seasons: seasons
                )
            }
        }
        return body
    }

    public func ratedMovies() async throws -> [TraktRatingEntry] {
        try Self.decoder.decode([TraktRatingEntry].self,
                                from: try await send(path: "/sync/ratings/movies"))
    }

    public func ratedShows() async throws -> [TraktRatingEntry] {
        try Self.decoder.decode([TraktRatingEntry].self,
                                from: try await send(path: "/sync/ratings/shows"))
    }

    /// Any successful non-GET write drops cached user reads; bumping the epoch
    /// stops in-flight GETs from re-storing pre-write data.
    private func invalidateUserCache(after method: String) async {
        guard method != "GET" else { return }
        writeEpoch += 1
        if let cache { await cache.remove(prefix: Self.userCachePrefix) }
    }

    /// Authorized call with a single automatic token refresh on 401.
    func send(path: String, method: String = "GET", body: Data? = nil,
              query: [String: String]? = nil) async throws -> Data {
        guard tokens != nil else { throw TraktError.unauthorized }
        let (data, response) = try await session.data(
            for: request(path: path, method: method, body: body, authorized: true, query: query))
        guard let http = response as? HTTPURLResponse else { throw TraktError.badResponse }
        switch http.statusCode {
        case 200, 201, 204:
            await invalidateUserCache(after: method)
            return data
        case 401:
            try await refreshTokens()   // throws .unauthorized on failure
            let (data2, response2) = try await session.data(
                for: request(path: path, method: method, body: body, authorized: true, query: query))
            guard let http2 = response2 as? HTTPURLResponse else { throw TraktError.badResponse }
            switch http2.statusCode {
            case 200...299:
                await invalidateUserCache(after: method)
                return data2
            case 401: throw TraktError.unauthorized
            // Transient server error after a good refresh is not an auth failure.
            default: throw TraktError.http(http2.statusCode)
            }
        default: throw TraktError.http(http.statusCode)
        }
    }
}
