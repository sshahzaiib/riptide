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

@MainActor
public final class TraktClient {
    public var tokens: TraktTokens?
    /// Fired whenever a 401-triggered refresh succeeds; the app persists them.
    public var onTokensRefreshed: ((TraktTokens) -> Void)?

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

    // MARK: Request infra

    private func request(path: String, method: String, body: Data?,
                         authorized: Bool) -> URLRequest {
        var req = URLRequest(url: base.appending(path: path))
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

    public func playback() async throws -> [TraktPlaybackEntry] {
        try Self.decoder.decode([TraktPlaybackEntry].self,
                                from: try await send(path: "/sync/playback"))
    }

    public func watchedMovies() async throws -> [TraktWatchedMovie] {
        try Self.decoder.decode([TraktWatchedMovie].self,
                                from: try await send(path: "/sync/watched/movies"))
    }

    public func watchedShows() async throws -> [TraktWatchedShow] {
        try Self.decoder.decode([TraktWatchedShow].self,
                                from: try await send(path: "/sync/watched/shows"))
    }

    /// NOTE: takes the TRAKT id (not TMDB) — /shows/{id} resolves ids in
    /// Trakt's namespace.
    public func showProgress(traktID: Int) async throws -> TraktShowProgress {
        try Self.decoder.decode(TraktShowProgress.self,
                                from: try await send(path: "/shows/\(traktID)/progress/watched"))
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

    public func ratedMovies() async throws -> [TraktRatingEntry] {
        try Self.decoder.decode([TraktRatingEntry].self,
                                from: try await send(path: "/sync/ratings/movies"))
    }

    public func ratedShows() async throws -> [TraktRatingEntry] {
        try Self.decoder.decode([TraktRatingEntry].self,
                                from: try await send(path: "/sync/ratings/shows"))
    }

    /// Authorized call with a single automatic token refresh on 401.
    func send(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        guard tokens != nil else { throw TraktError.unauthorized }
        let (data, response) = try await session.data(
            for: request(path: path, method: method, body: body, authorized: true))
        guard let http = response as? HTTPURLResponse else { throw TraktError.badResponse }
        switch http.statusCode {
        case 200, 201, 204: return data
        case 401:
            try await refreshTokens()   // throws .unauthorized on failure
            let (data2, response2) = try await session.data(
                for: request(path: path, method: method, body: body, authorized: true))
            guard let http2 = response2 as? HTTPURLResponse else { throw TraktError.badResponse }
            switch http2.statusCode {
            case 200...299: return data2
            case 401: throw TraktError.unauthorized
            // Transient server error after a good refresh is not an auth failure.
            default: throw TraktError.http(http2.statusCode)
            }
        default: throw TraktError.http(http.statusCode)
        }
    }
}
