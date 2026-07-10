import Foundation

/// Manifest served at `{base}/manifest.json` by every Stremio addon.
public struct AddonManifest: Sendable, Decodable {
    public let id: String
    public let name: String
    public let version: String?
    public let resources: [Resource]
    public let types: [String]

    /// Protocol quirk: a resources entry is either a bare string ("stream")
    /// or an object ({"name": "stream", "types": [...]}).
    public struct Resource: Sendable, Decodable {
        public let name: String
        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self) { name = s; return }
            struct Object: Decodable { let name: String }
            name = try container.decode(Object.self).name
        }
    }

    public var supportsStreams: Bool { resources.contains { $0.name == "stream" } }
}

/// One entry from `{base}/stream/{type}/{id}.json`. Fields are all optional
/// in the protocol; debrid-configured addons set `url`, P2P results set
/// `infoHash` only.
public struct AddonStream: Sendable, Decodable, Hashable {
    public let name: String?
    public let title: String?
    public let description: String?
    public let url: String?
    public let infoHash: String?
    public let behaviorHints: BehaviorHints?

    public struct BehaviorHints: Sendable, Decodable, Hashable {
        public let filename: String?
        public let videoSize: Int64?
    }

    /// Playable debrid-resolved URL, nil for P2P-only results.
    public var httpURL: URL? {
        guard let url, let parsed = URL(string: url),
              parsed.scheme == "http" || parsed.scheme == "https" else { return nil }
        return parsed
    }

    /// Raw addon text for UI display (addons put metadata in name + title,
    /// or name + description — AIOStreams uses description).
    public var displayText: String {
        [name, title ?? description].compactMap { $0 }.joined(separator: "\n")
    }
}

struct StreamsResponse: Decodable {
    let streams: [AddonStream]
}

public enum StremioAddonError: Error, Equatable, Sendable {
    case badStatus(Int)
    case badResponse
}
