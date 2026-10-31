import Foundation

/// What the phone form sends to the TV. nil or empty string means "keep the
/// existing value"; names listed in `clear` are erased.
public struct PairingPayload: Codable, Equatable, Sendable {
    public var rdToken: String?
    public var adToken: String?
    public var tmdbToken: String?
    public var traktClientID: String?
    public var traktClientSecret: String?
    public var openSubsKey: String?
    public var addonURLs: [String] = []
    public var clear: Set<String> = []

    public init() {}

    /// Parses `application/x-www-form-urlencoded`. Field names equal the
    /// property names; unknown fields are ignored and empty values stay nil.
    public static func fromForm(_ body: String) -> PairingPayload {
        var p = PairingPayload()
        for pair in body.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = decode(kv[0]) else { continue }
            let value = kv.count > 1 ? (decode(kv[1]) ?? "") : ""
            switch key {
            case "rdToken": p.rdToken = value.isEmpty ? nil : value
            case "adToken": p.adToken = value.isEmpty ? nil : value
            case "tmdbToken": p.tmdbToken = value.isEmpty ? nil : value
            case "traktClientID": p.traktClientID = value.isEmpty ? nil : value
            case "traktClientSecret": p.traktClientSecret = value.isEmpty ? nil : value
            case "openSubsKey": p.openSubsKey = value.isEmpty ? nil : value
            case "addonURLs":
                p.addonURLs = value.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            case _ where key.hasPrefix("clear_"):
                p.clear.insert(String(key.dropFirst("clear_".count)))
            default: break
            }
        }
        return p
    }

    private static func decode(_ s: Substring) -> String? {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}
