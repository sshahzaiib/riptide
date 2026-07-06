import Foundation

/// Real-Debrid account info (`GET /user`). `premium` is seconds of premium remaining.
public struct RealDebridAccount: Sendable, Equatable, Decodable {
    public let username: String
    public let type: String            // "premium" | "free"
    public let premium: Int            // seconds remaining; 0 when free/expired
    public let expiration: String?     // raw ISO-8601, optional

    public var isPremium: Bool { type == "premium" && premium > 0 }
    public var premiumDaysRemaining: Int { premium / 86_400 }
}

/// A resolved hoster link (`POST /unrestrict/link`). `download` is the direct premium URL.
public struct UnrestrictedLink: Sendable, Equatable, Decodable {
    public let id: String
    public let filename: String
    public let filesize: Int64
    public let host: String
    public let download: String        // direct download URL (RD's `download` field)
    public let streamable: Int

    public var directURL: URL? { URL(string: download) }
}

/// Result of `POST /torrents/addMagnet`.
public struct AddMagnetResult: Sendable, Equatable, Decodable {
    public let id: String
    public let uri: String
}

/// A file inside a torrent (`GET /torrents/info/{id}` → `files[]`). `id` is 1-indexed.
public struct TorrentFile: Sendable, Equatable, Decodable {
    public let id: Int
    public let path: String
    public let bytes: Int64
    public let selected: Int
}

/// Torrent status (`GET /torrents/info/{id}`). Early statuses omit `files`/`links`,
/// so those (and other late-populated fields) default to empty/zero.
public struct TorrentInfo: Sendable, Equatable, Decodable {
    public let id: String
    public let filename: String
    public let bytes: Int64
    public let progress: Double
    public let status: String
    public let files: [TorrentFile]
    public let links: [String]

    enum CodingKeys: String, CodingKey {
        case id, filename, bytes, progress, status, files, links
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        status = try c.decode(String.self, forKey: .status)
        filename = try c.decodeIfPresent(String.self, forKey: .filename) ?? ""
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        files = try c.decodeIfPresent([TorrentFile].self, forKey: .files) ?? []
        links = try c.decodeIfPresent([String].self, forKey: .links) ?? []
    }

    /// Direct memberwise init for tests/fixtures.
    init(id: String, filename: String = "", bytes: Int64 = 0, progress: Double = 0,
         status: String, files: [TorrentFile] = [], links: [String] = []) {
        self.id = id; self.filename = filename; self.bytes = bytes
        self.progress = progress; self.status = status; self.files = files; self.links = links
    }
}

/// Real-Debrid error envelope: `{ "error": ..., "error_code": ..., "error_details": ... }`.
struct RealDebridAPIError: Decodable, Equatable {
    let error: String
    let errorCode: Int?
    let errorDetails: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorCode = "error_code"
        case errorDetails = "error_details"
    }
}

/// One entry from `GET /torrents`. `ended` is present only for finished torrents.
public struct TorrentListItem: Sendable, Equatable, Decodable {
    public let id: String
    public let filename: String
    public let bytes: Int64
    public let progress: Double
    public let status: String
    public let added: String           // raw ISO-8601
    public let links: [String]
    public let ended: String?
}

/// One entry from `GET /downloads` (previously unrestricted links).
public struct DownloadListItem: Sendable, Equatable, Decodable {
    public let id: String
    public let filename: String
    public let filesize: Int64
    public let link: String            // original hoster link
    public let download: String        // direct streamable URL
    public let streamable: Int
    public let generated: String       // raw ISO-8601
    public let mimeType: String?
}

