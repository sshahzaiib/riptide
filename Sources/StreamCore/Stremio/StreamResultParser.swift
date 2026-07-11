import Foundation

public struct ParsedStreamMeta: Sendable, Equatable {
    public var resolution: String?
    public var sizeBytes: Int64?
    public var cached: Bool?          // nil = unknown, sorts between true and false
    public let service: DebridServiceID?

    public init(resolution: String? = nil, sizeBytes: Int64? = nil, cached: Bool? = nil, service: DebridServiceID? = nil) {
        self.resolution = resolution
        self.sizeBytes = sizeBytes
        self.cached = cached
        self.service = service
    }
}

/// Best-effort extraction from human-formatted addon text. The protocol is
/// the stable contract; this text is not — unknown formats just yield nils
/// and the UI falls back to the raw text.
public enum StreamResultParser {
    public static func parse(_ stream: AddonStream) -> ParsedStreamMeta {
        let text = [stream.name, stream.title, stream.description]
            .compactMap { $0 }.joined(separator: "\n")
        var resolution: String?
        var sizeBytes: Int64?
        var cached: Bool?

        if let match = firstMatch(#"(?i)\b(2160p|1080p|720p|480p|4k)\b"#, in: text) {
            let lower = match.lowercased()
            resolution = lower == "4k" ? "2160p" : lower
        }

        if let size = stream.behaviorHints?.videoSize {
            sizeBytes = size
        } else if let match = firstMatch(#"(?i)[\d.]+\s*(GB|MB)\b"#, in: text) {
            let multiplier: Double = match.uppercased().hasSuffix("GB") ? 1_073_741_824 : 1_048_576
            let digits = match.prefix { "0123456789.".contains($0) }
            if let value = Double(digits) { sizeBytes = Int64(value * multiplier) }
        }

        // ponytail: heuristic markers — "download"/⏳ = uncached (Torrentio
        // "[RD download]"), ⚡ or "[XX+]" (RD+/PM+/TB+/AD+) = cached.
        if firstMatch(#"(?i)\bdownload\b"#, in: text) != nil || text.contains("⏳") {
            cached = false
        } else if text.contains("⚡") || firstMatch(#"\[[A-Za-z]{2,4}\+\]"#, in: text) != nil {
            cached = true
        }

        // ponytail: heuristic markers — per-stream debrid service detection (best-effort text sniffing).
        let hasRD = firstMatch(#"(?<![a-zA-Z0-9])RD\+?(?![a-zA-Z0-9])"#, in: text) != nil
            || firstMatch(#"(?i)\b(real-debrid|realdebrid)\b"#, in: text) != nil
        let hasAD = firstMatch(#"(?<![a-zA-Z0-9])AD\+?(?![a-zA-Z0-9])"#, in: text) != nil
            || firstMatch(#"(?i)\b(alldebrid|all-debrid)\b"#, in: text) != nil

        let service: DebridServiceID?
        if hasRD && !hasAD {
            service = .realDebrid
        } else if hasAD && !hasRD {
            service = .allDebrid
        } else {
            service = nil
        }

        return ParsedStreamMeta(resolution: resolution, sizeBytes: sizeBytes, cached: cached, service: service)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range])
    }
}
