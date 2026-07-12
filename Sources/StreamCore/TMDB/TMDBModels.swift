import Foundation

public struct TMDBMovie: Sendable, Equatable, Decodable {
    public let id: Int
    public let title: String
    public let overview: String
    public let posterPath: String?
    public let releaseDate: String?
    public let voteAverage: Double

    enum CodingKeys: String, CodingKey {
        case id, title, overview
        case posterPath = "poster_path"
        case releaseDate = "release_date"
        case voteAverage = "vote_average"
    }

    public init(id: Int, title: String, overview: String, posterPath: String?,
                releaseDate: String?, voteAverage: Double) {
        self.id = id; self.title = title; self.overview = overview
        self.posterPath = posterPath; self.releaseDate = releaseDate
        self.voteAverage = voteAverage
    }
}

public struct TMDBShow: Sendable, Equatable, Decodable {
    public let id: Int
    public let name: String
    public let overview: String
    public let posterPath: String?
    public let firstAirDate: String?
    public let voteAverage: Double

    enum CodingKeys: String, CodingKey {
        case id, name, overview
        case posterPath = "poster_path"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
    }
}

public struct TMDBEpisode: Sendable, Equatable, Decodable {
    public let id: Int
    public let name: String
    public let overview: String
    public let stillPath: String?
    public let airDate: String?

    enum CodingKeys: String, CodingKey {
        case id, name, overview
        case stillPath = "still_path"
        case airDate = "air_date"
    }
}

struct TMDBSearchEnvelope<T: Decodable>: Decodable {
    let results: [T]
}

public enum TMDBError: Error, Equatable, Sendable {
    case unauthorized
    case http(Int)
    case badResponse
}

public enum TMDB {
    /// `https://image.tmdb.org/t/p/w{width}{path}` — path includes its leading slash.
    public static func imageURL(path: String, width: Int = 500) -> URL {
        URL(string: "https://image.tmdb.org/t/p/w\(width)\(path)")!
    }
}

public struct TMDBShowDetails: Sendable, Equatable, Decodable {
    public let id: Int
    public let name: String
    public let backdropPath: String?
    public let overview: String
    public let voteAverage: Double
    public let firstAirDate: String?
    public let numberOfSeasons: Int?
    public let seasons: [SeasonRef]?

    public struct SeasonRef: Sendable, Equatable, Decodable {
        public let seasonNumber: Int
        enum CodingKeys: String, CodingKey { case seasonNumber = "season_number" }
    }

    /// Selectable season numbers, including Season 0 ("Specials") when TMDB
    /// lists it. Falls back to 1...numberOfSeasons for payloads without the
    /// seasons array.
    public var seasonNumbers: [Int] {
        if let seasons, !seasons.isEmpty { return seasons.map(\.seasonNumber).sorted() }
        return Array(1...max(numberOfSeasons ?? 1, 1))
    }

    enum CodingKeys: String, CodingKey {
        case id, name, overview, seasons
        case backdropPath = "backdrop_path"
        case voteAverage = "vote_average"
        case firstAirDate = "first_air_date"
        case numberOfSeasons = "number_of_seasons"
    }
}

public struct TMDBSeasonEpisode: Sendable, Equatable, Decodable {
    public let episodeNumber: Int
    public let name: String
    public let overview: String
    public let stillPath: String?
    public let airDate: String?
    public let runtime: Int?

    enum CodingKeys: String, CodingKey {
        case name, overview, runtime
        case episodeNumber = "episode_number"
        case stillPath = "still_path"
        case airDate = "air_date"
    }
}

public struct TMDBCastMember: Sendable, Equatable, Decodable {
    public let id: Int
    public let name: String
    public let character: String?
    public let profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, character
        case profilePath = "profile_path"
    }
}

public struct TMDBMovieDetails: Sendable, Equatable, Decodable {
    public let id: Int
    public let title: String
    public let backdropPath: String?
    public let overview: String
    public let voteAverage: Double
    public let releaseDate: String?
    public let runtime: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, overview, runtime
        case backdropPath = "backdrop_path"
        case voteAverage = "vote_average"
        case releaseDate = "release_date"
    }
}

struct TMDBSeasonEnvelope: Decodable {
    let episodes: [TMDBSeasonEpisode]
}

struct TMDBCreditsEnvelope: Decodable {
    let cast: [TMDBCastMember]
}

struct TMDBImagesEnvelope: Decodable {
    let logos: [TMDBImage]
}

struct TMDBImage: Decodable {
    let filePath: String
    let language: String?
    let voteAverage: Double

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case language = "iso_639_1"
        case voteAverage = "vote_average"
    }
}

public struct TMDBExternalIDs: Sendable, Equatable, Decodable {
    public let imdbID: String?

    enum CodingKeys: String, CodingKey {
        case imdbID = "imdb_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // TMDB sometimes returns "" instead of null for a missing imdb_id.
        let raw = try container.decodeIfPresent(String.self, forKey: .imdbID)
        imdbID = raw?.isEmpty == false ? raw : nil
    }
}
