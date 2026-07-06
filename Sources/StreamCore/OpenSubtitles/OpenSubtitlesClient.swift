import Foundation

public struct SubtitleResult: Sendable, Equatable {
    public let id: String
    public let language: String
    public let release: String
    public let fileID: Int
    public let fileName: String

    public init(id: String, language: String, release: String, fileID: Int, fileName: String) {
        self.id = id; self.language = language; self.release = release
        self.fileID = fileID; self.fileName = fileName
    }
}

public enum OpenSubtitlesError: Error, Equatable, Sendable {
    case unauthorized      // 401/403 — bad API key
    case quotaExceeded     // 406 — daily download quota hit
    case http(Int)
    case badResponse
}

/// Minimal OpenSubtitles REST client (api.opensubtitles.com/api/v1).
/// v1 searches by title/season/episode; file-hash matching is a later refinement (spec).
public struct OpenSubtitlesClient: Sendable {
    let apiKey: String
    let session: URLSession
    let baseURL: URL

    public init(apiKey: String,
                session: URLSession = .shared,
                baseURL: URL = URL(string: "https://api.opensubtitles.com/api/v1")!) {
        self.apiKey = apiKey
        self.session = session
        self.baseURL = baseURL
    }

    // MARK: Wire formats

    private struct SearchResponse: Decodable {
        struct Entry: Decodable {
            struct Attributes: Decodable {
                struct File: Decodable {
                    let fileID: Int
                    let fileName: String
                    enum CodingKeys: String, CodingKey {
                        case fileID = "file_id"
                        case fileName = "file_name"
                    }
                }
                let language: String
                let release: String
                let files: [File]
            }
            let id: String
            let attributes: Attributes
        }
        let data: [Entry]
    }

    private struct DownloadResponse: Decodable {
        let link: String
        let fileName: String
        enum CodingKeys: String, CodingKey {
            case link
            case fileName = "file_name"
        }
    }

    // MARK: Request layer

    private func request(_ method: String, _ path: String,
                         query: [String: String] = [:],
                         jsonBody: Data? = nil) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: comps.url!)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("Riptide v0.1", forHTTPHeaderField: "User-Agent")
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonBody
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenSubtitlesError.badResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403:  throw OpenSubtitlesError.unauthorized
        case 406:       throw OpenSubtitlesError.quotaExceeded
        default:        throw OpenSubtitlesError.http(http.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw OpenSubtitlesError.badResponse }
    }

    // MARK: API

    /// Search subtitles by title (+ optional season/episode). Entries with no
    /// downloadable files are dropped.
    public func search(query: String, season: Int?, episode: Int?,
                       languages: String = "en") async throws -> [SubtitleResult] {
        var q = ["query": query, "languages": languages]
        if let season { q["season_number"] = String(season) }
        if let episode { q["episode_number"] = String(episode) }
        let data = try await request("GET", "subtitles", query: q)
        let response = try decode(SearchResponse.self, from: data)
        return response.data.compactMap { entry in
            guard let file = entry.attributes.files.first else { return nil }
            return SubtitleResult(id: entry.id,
                                  language: entry.attributes.language,
                                  release: entry.attributes.release,
                                  fileID: file.fileID,
                                  fileName: file.fileName)
        }
    }

    /// Resolve the download link for `fileID`, fetch it, and write the subtitle
    /// file into `directory`. Returns the written file's URL.
    public func downloadSubtitle(fileID: Int, into directory: URL) async throws -> URL {
        let body = try JSONEncoder().encode(["file_id": fileID])
        let data = try await request("POST", "download", jsonBody: body)
        let resolved = try decode(DownloadResponse.self, from: data)
        guard let link = URL(string: resolved.link) else { throw OpenSubtitlesError.badResponse }

        let (fileData, response) = try await session.data(from: link)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { throw OpenSubtitlesError.badResponse }
        // fileName is attacker-influencable: keep only the last path component and
        // refuse traversal tokens so we can never write outside `directory`.
        var safeName = (resolved.fileName as NSString).lastPathComponent
        if safeName.isEmpty || safeName == "." || safeName == ".." {
            safeName = "subtitle-\(fileID).srt"
        }
        let target = directory.appendingPathComponent(safeName)
        try fileData.write(to: target, options: .atomic)
        return target
    }
}
