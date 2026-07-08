import Foundation

public struct TraktDeviceCode: Decodable, Equatable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationUrl: String
    public let expiresIn: Int
    public let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUrl = "verification_url"
        case expiresIn = "expires_in"
        case interval
    }
}

public struct TraktTokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let createdAt: Int
    public let expiresIn: Int

    public init(accessToken: String, refreshToken: String, createdAt: Int, expiresIn: Int) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.createdAt = createdAt
        self.expiresIn = expiresIn
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case createdAt = "created_at"
        case expiresIn = "expires_in"
    }
}

/// What a Trakt call is about. Built from LibraryItem/PlayItem app-side.
public enum TraktMedia: Equatable, Sendable {
    case movie(tmdbID: Int)
    case show(tmdbID: Int)                                   // ratings only
    case episode(showTMDBID: Int, season: Int, episode: Int) // scrobbling
}

public struct TraktIDs: Decodable, Equatable, Sendable {
    public let tmdb: Int?
    public let trakt: Int?
}

public struct TraktMovieRef: Decodable, Equatable, Sendable {
    public let ids: TraktIDs
}

public struct TraktShowRef: Decodable, Equatable, Sendable {
    public let ids: TraktIDs
}

public struct TraktEpisodeRef: Decodable, Equatable, Sendable {
    public let season: Int
    public let number: Int
}

public struct TraktPlaybackEntry: Decodable, Equatable, Sendable {
    public let progress: Double        // percent 0-100
    public let pausedAt: Date?
    public let type: String            // "movie" | "episode"
    public let movie: TraktMovieRef?
    public let show: TraktShowRef?
    public let episode: TraktEpisodeRef?

    enum CodingKeys: String, CodingKey {
        case progress
        case pausedAt = "paused_at"
        case type, movie, show, episode
    }
}

public struct TraktWatchedMovie: Decodable, Equatable, Sendable {
    public let lastWatchedAt: Date
    public let movie: TraktMovieRef

    enum CodingKeys: String, CodingKey {
        case lastWatchedAt = "last_watched_at"
        case movie
    }
}

/// Shallow entry from /sync/watched/shows. The live API no longer inlines
/// `seasons` (despite the docs) — per-episode data comes from a follow-up
/// /shows/{trakt-id}/progress/watched call.
public struct TraktWatchedShow: Decodable, Equatable, Sendable {
    public let show: TraktShowRef
    public let lastWatchedAt: Date

    enum CodingKeys: String, CodingKey {
        case show
        case lastWatchedAt = "last_watched_at"
    }
}

/// Per-episode watched state from /shows/{trakt-id}/progress/watched.
public struct TraktShowProgress: Decodable, Equatable, Sendable {
    public let seasons: [Season]

    public struct Season: Decodable, Equatable, Sendable {
        public let number: Int
        public let episodes: [Episode]
    }
    public struct Episode: Decodable, Equatable, Sendable {
        public let number: Int
        public let completed: Bool
        public let lastWatchedAt: Date?

        enum CodingKeys: String, CodingKey {
            case number, completed
            case lastWatchedAt = "last_watched_at"
        }
    }
}

public struct TraktRatingEntry: Decodable, Equatable, Sendable {
    public let rating: Int
    public let movie: TraktMovieRef?
    public let show: TraktShowRef?
}

public enum TraktScrobbleAction: String, Sendable {
    case start, pause, stop
}

public enum TraktError: Error, Equatable {
    case unauthorized     // 401 that survived a refresh attempt
    case denied           // device flow terminally rejected (404/409/410/418)
    case badResponse
    case http(Int)
}
