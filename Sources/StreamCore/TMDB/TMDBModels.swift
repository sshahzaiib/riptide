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
