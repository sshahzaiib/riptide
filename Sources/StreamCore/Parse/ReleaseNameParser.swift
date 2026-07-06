import Foundation

/// Structured guess extracted from a scene release name.
public struct ParsedRelease: Sendable, Equatable {
    public var title: String
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    public var quality: String?   // normalized: "2160p" | "1080p" | "720p" | "480p"
    public var source: String?    // normalized: "BluRay" | "WEB-DL" | "WEBRip" | "WEB" | "HDTV" | "DVDRip"

    public var isTV: Bool { season != nil || episode != nil }

    public init(title: String, year: Int? = nil, season: Int? = nil,
                episode: Int? = nil, quality: String? = nil, source: String? = nil) {
        self.title = title; self.year = year; self.season = season
        self.episode = episode; self.quality = quality; self.source = source
    }
}

public enum ReleaseNameParser {
    private static let videoExtensions: Set<String> =
        ["mkv", "mp4", "avi", "m4v", "mov", "wmv", "ts", "webm", "flv", "mpg", "mpeg"]

    public static func parse(_ name: String) -> ParsedRelease {
        var s = name

        // 1. Strip a known video extension.
        if let dot = s.lastIndex(of: "."),
           videoExtensions.contains(String(s[s.index(after: dot)...]).lowercased()) {
            s = String(s[..<dot])
        }

        // 2. Anime-style bracket tags: drop a leading [Group] and remember bracketed
        //    tokens (they may carry quality, e.g. "[1080p]") before removing them.
        var bracketContents: [String] = []
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]"#, with: " ",
                                   options: .regularExpression)
        for m in matches(#"\[([^\]]*)\]"#, in: name) {
            bracketContents.append(m[1])
        }

        // 3. Normalize separators to spaces (dots/underscores; keep dashes for
        //    WEB-DL and anime episode markers until extracted).
        s = s.replacingOccurrences(of: ".", with: " ")
             .replacingOccurrences(of: "_", with: " ")
        let scan = s + " " + bracketContents.joined(separator: " ")

        // 4. Quality (also from bracket tags). "4K" normalizes to 2160p.
        var quality: String?
        if let q = firstMatch(#"(?i)\b(2160p|1080p|720p|480p)\b"#, in: scan) {
            quality = q[1].lowercased()
        } else if firstMatch(#"(?i)\b4K\b"#, in: scan) != nil {
            quality = "2160p"
        }

        // 5. Source.
        var source: String?
        if let m = firstMatch(#"(?i)\b(BluRay|Blu-Ray|BDRip|BRRip|WEB-?DL|WEBRip|WEB|HDTV|DVDRip)\b"#, in: s) {
            switch m[1].lowercased() {
            case "bluray", "blu-ray", "bdrip", "brrip": source = "BluRay"
            case "web-dl", "webdl":                     source = "WEB-DL"
            case "webrip":                              source = "WEBRip"
            case "web":                                 source = "WEB"
            case "hdtv":                                source = "HDTV"
            case "dvdrip":                              source = "DVDRip"
            default: break
            }
        }

        // 6. Season/episode. Order: SxxExx, then NxNN, then anime " - NN".
        var season: Int?, episode: Int?
        var seRange: Range<String.Index>?
        if let m = firstMatchWithRange(#"(?i)\bS(\d{1,2})[ ]?E(\d{1,3})\b"#, in: s) {
            season = Int(m.groups[1]); episode = Int(m.groups[2]); seRange = m.range
        } else if let m = firstMatchWithRange(#"\b(\d{1,2})x(\d{2,3})\b"#, in: s) {
            season = Int(m.groups[1]); episode = Int(m.groups[2]); seRange = m.range
        } else if let m = firstMatchWithRange(#"\s-\s(\d{2,3})\b"#, in: s) {
            episode = Int(m.groups[1]); seRange = m.range
        }

        // 7. Year: candidate 19xx/20xx tokens. If the very first token IS a year
        //    (a title like "2012"), it belongs to the title — use the next one.
        var year: Int?
        var yearRange: Range<String.Index>?
        let yearMatches = matchesWithRange(#"\b(19|20)\d{2}\b"#, in: s)
        let leadingIsYear = yearMatches.first.map {
            s[..<$0.range.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty
        } ?? false
        let candidates = leadingIsYear ? Array(yearMatches.dropFirst()) : yearMatches
        // Ignore year tokens after the S/E marker (episode-title years).
        if let m = candidates.first(where: { seRange == nil || $0.range.lowerBound < seRange!.lowerBound }) {
            year = Int(s[m.range]); yearRange = m.range
        }

        // 8. Title = prefix before the earliest boundary marker (S/E, year, quality,
        //    source), cleaned of stray separators and bracket residue.
        var boundary = s.endIndex
        for r in [seRange, yearRange].compactMap({ $0 }) where r.lowerBound < boundary {
            boundary = r.lowerBound
        }
        for pattern in [#"(?i)\b(2160p|1080p|720p|480p|4K)\b"#,
                        #"(?i)\b(BluRay|Blu-Ray|BDRip|BRRip|WEB-?DL|WEBRip|WEB|HDTV|DVDRip)\b"#] {
            if let m = firstMatchWithRange(pattern, in: s), m.range.lowerBound < boundary {
                boundary = m.range.lowerBound
            }
        }
        var title = String(s[..<boundary])
        title = title.replacingOccurrences(of: #"[()\-]+"#, with: " ", options: .regularExpression)
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if title.isEmpty { title = s.trimmingCharacters(in: .whitespaces) }

        return ParsedRelease(title: title, year: year, season: season,
                             episode: episode, quality: quality, source: source)
    }

    // MARK: Regex helpers (NSRegularExpression kept behind tiny wrappers)

    private struct Match { let groups: [String]; let range: Range<String.Index> }

    private static func firstMatchWithRange(_ pattern: String, in s: String) -> Match? {
        matchesWithRange(pattern, in: s).first
    }

    private static func matchesWithRange(_ pattern: String, in s: String) -> [Match] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let whole = Range(m.range, in: s) else { return nil }
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                groups.append(Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "")
            }
            return Match(groups: groups, range: whole)
        }
    }

    private static func firstMatch(_ pattern: String, in s: String) -> [String]? {
        firstMatchWithRange(pattern, in: s)?.groups
    }

    private static func matches(_ pattern: String, in s: String) -> [[String]] {
        matchesWithRange(pattern, in: s).map(\.groups)
    }
}
