import Foundation

/// Client for the Stremio addon protocol — the wire format Torrentio,
/// AIOStreams, Comet, etc. all implement. Generic on purpose: any addon URL
/// works, there are no per-addon adapters.
public struct StremioAddonClient: Sendable {
    public enum MediaType: String, Sendable {
        case movie, series
    }

    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Normalize a pasted addon URL: trim, strip a trailing `/manifest.json`
    /// and trailing slashes. Returns nil unless it's a valid http(s) URL.
    public static func normalizedBase(from raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("/manifest.json") { s = String(s.dropLast("/manifest.json".count)) }
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        guard let url = URL(string: s),
              url.scheme == "http" || url.scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    public func manifest(baseURL: URL) async throws -> AddonManifest {
        try await get(URL(string: "\(baseURL.absoluteString)/manifest.json")!)
    }

    public func streams(baseURL: URL, type: MediaType, imdbID: String,
                        season: Int? = nil, episode: Int? = nil) async throws -> [AddonStream] {
        var id = imdbID
        if let season, let episode { id += ":\(season):\(episode)" }
        // Built via string interpolation: the ":" separators must stay literal.
        guard let url = URL(string: "\(baseURL.absoluteString)/stream/\(type.rawValue)/\(id).json")
        else { throw StremioAddonError.badResponse }
        let response: StreamsResponse = try await get(url)
        return response.streams
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw StremioAddonError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw StremioAddonError.badStatus(http.statusCode)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw StremioAddonError.badResponse }
    }
}
