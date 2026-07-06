# Riptide Plan 1: StreamCore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `StreamCore`, the pure-logic SPM package behind Riptide: Real-Debrid client (copied from Cascade + list endpoints), release-name parser, TMDB client, OpenSubtitles client, and SwiftData library/watch-state store.

**Architecture:** Single SPM library target with zero UI imports, mirroring Cascade's `DownloadCore`. All HTTP clients take an injectable `URLSession` and are tested with a `MockURLProtocol` (copied from Cascade). SwiftData store tested with an in-memory `ModelContainer`. The SwiftUI app + MPVKit player is Plan 2 and is out of scope here.

**Tech Stack:** Swift 6 (swift-tools 6.0), macOS 14+, XCTest, SwiftData, URLSession. No third-party dependencies in this plan.

## Global Constraints

- swift-tools-version: 6.0; platform floor `.macOS(.v14)` (SwiftData requirement; spec allows ≥14).
- `Sources/StreamCore/` must contain **zero** `import SwiftUI` / `import AppKit` (spec: pure logic, unit-testable).
- No third-party dependencies in Plan 1 (spec: MPVKit is the only dependency, and it belongs to the Plan 2 app target).
- All public types `Sendable` where possible, matching Cascade's style.
- Tests run with `swift test` (serial, never `--parallel` — MockURLProtocol's shared handler requires it).
- Commit after every green test cycle. No Claude co-author trailer on commits.
- Repo root: `/Users/shahzaib/Documents/dev/riptide`. Cascade source (read-only donor): `/Users/shahzaib/Documents/dev/cascade`.

---

### Task 1: SPM Package Scaffold

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `Sources/StreamCore/StreamCore.swift`
- Test: `Tests/StreamCoreTests/SmokeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: a building `StreamCore` library target and `StreamCoreTests` test target that later tasks add files into.

- [ ] **Step 1: Write Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Riptide",
    platforms: [.macOS(.v14)],
    products: [.library(name: "StreamCore", targets: ["StreamCore"])],
    targets: [
        .target(name: "StreamCore"),
        .testTarget(name: "StreamCoreTests", dependencies: ["StreamCore"]),
    ]
)
```

- [ ] **Step 2: Write .gitignore**

```
.build/
.DS_Store
*.xcodeproj
.swiftpm/
```

- [ ] **Step 3: Write the library marker and smoke test**

`Sources/StreamCore/StreamCore.swift`:

```swift
/// StreamCore: pure-logic core for Riptide (Real-Debrid streaming app).
/// No UI imports allowed in this module.
public enum StreamCore {
    public static let version = "0.1.0"
}
```

`Tests/StreamCoreTests/SmokeTests.swift`:

```swift
import XCTest
@testable import StreamCore

final class SmokeTests: XCTestCase {
    func testPackageBuildsAndLinks() {
        XCTAssertEqual(StreamCore.version, "0.1.0")
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: `Executed 1 test, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Package.swift .gitignore Sources Tests
git commit -m "feat: scaffold StreamCore SPM package"
```

---

### Task 2: Real-Debrid Client (copy from Cascade + list endpoints)

**Files:**
- Create: `Sources/StreamCore/RealDebrid/RealDebridClient.swift` (copied, then modified)
- Create: `Sources/StreamCore/RealDebrid/RealDebridModels.swift` (copied, then extended)
- Create: `Sources/StreamCore/RealDebrid/RealDebridError.swift` (copied verbatim)
- Create: `Tests/StreamCoreTests/MockURLProtocol.swift` (copied verbatim)
- Test: `Tests/StreamCoreTests/RealDebridListTests.swift`

**Interfaces:**
- Consumes: Task 1 scaffold.
- Produces (used by Plan 2 app and Task 6 store):
  - `RealDebridClient.init(token: String, session: URLSession = .shared, config: Config = Config(), sleep: ...)`
  - `func listTorrents(page: Int = 1, limit: Int = 100) async throws -> [TorrentListItem]`
  - `func allTorrents(limit: Int = 100) async throws -> [TorrentListItem]`
  - `func listDownloads(page: Int = 1, limit: Int = 100) async throws -> [DownloadListItem]`
  - `func unrestrictLink(_ link: String) async throws -> UnrestrictedLink` (from Cascade, unchanged)
  - `struct TorrentListItem: Sendable, Equatable, Decodable { id, filename: String; bytes: Int64; progress: Double; status, added: String; links: [String]; ended: String? }`
  - `struct DownloadListItem: Sendable, Equatable, Decodable { id, filename: String; filesize: Int64; link, download: String; streamable: Int; generated: String; mimeType: String? }`

- [ ] **Step 1: Copy the donor files from Cascade**

```bash
mkdir -p Sources/StreamCore/RealDebrid
cp /Users/shahzaib/Documents/dev/cascade/Sources/DownloadCore/RealDebrid/RealDebridClient.swift Sources/StreamCore/RealDebrid/
cp /Users/shahzaib/Documents/dev/cascade/Sources/DownloadCore/RealDebrid/RealDebridModels.swift Sources/StreamCore/RealDebrid/
cp /Users/shahzaib/Documents/dev/cascade/Sources/DownloadCore/RealDebrid/RealDebridError.swift Sources/StreamCore/RealDebrid/
cp /Users/shahzaib/Documents/dev/cascade/Tests/DownloadCoreTests/MockURLProtocol.swift Tests/StreamCoreTests/
rm Tests/StreamCoreTests/SmokeTests.swift
```

Then run `swift build` — expected: **succeeds** (the copied files have no DownloadCore-specific imports; they only import Foundation).

- [ ] **Step 2: Write failing tests for the list endpoints**

`Tests/StreamCoreTests/RealDebridListTests.swift`:

```swift
import XCTest
@testable import StreamCore

final class RealDebridListTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func client() -> RealDebridClient {
        RealDebridClient(token: "T", session: .mocked())
    }

    private static let torrentJSON = """
    [{"id":"ABCDEF","filename":"The.Matrix.1999.1080p.BluRay.x264.mkv","hash":"h1",
      "bytes":8589934592,"host":"real-debrid.com","split":2000,"progress":100,
      "status":"downloaded","added":"2026-06-01T10:00:00.000Z",
      "links":["https://real-debrid.com/d/AAA"],"ended":"2026-06-01T10:05:00.000Z"},
     {"id":"GHIJKL","filename":"pack","hash":"h2","bytes":0,"host":"real-debrid.com",
      "split":2000,"progress":40,"status":"downloading","added":"2026-06-02T10:00:00.000Z",
      "links":[]}]
    """

    func testListTorrentsDecodesAndSendsPagination() async throws {
        nonisolated(unsafe) var seenURL: URL?
        MockURLProtocol.setHandler { request in
            seenURL = request.url
            return .json(Self.torrentJSON)
        }
        let items = try await client().listTorrents(page: 3, limit: 50)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, "ABCDEF")
        XCTAssertEqual(items[0].filename, "The.Matrix.1999.1080p.BluRay.x264.mkv")
        XCTAssertEqual(items[0].bytes, 8_589_934_592)
        XCTAssertEqual(items[0].links, ["https://real-debrid.com/d/AAA"])
        XCTAssertEqual(items[0].ended, "2026-06-01T10:05:00.000Z")
        XCTAssertNil(items[1].ended)          // omitted for in-progress torrents
        let comps = URLComponents(url: try XCTUnwrap(seenURL), resolvingAgainstBaseURL: false)!
        XCTAssertTrue(comps.path.hasSuffix("/torrents"))
        XCTAssertEqual(Set(comps.queryItems ?? []),
                       [URLQueryItem(name: "limit", value: "50"),
                        URLQueryItem(name: "page", value: "3")])
    }

    func testListDownloadsDecodes() async throws {
        MockURLProtocol.setHandler { _ in
            .json("""
            [{"id":"DL1","filename":"movie.mkv","mimeType":"video/x-matroska",
              "filesize":1000,"link":"https://real-debrid.com/d/AAA",
              "host":"real-debrid.com","chunks":32,
              "download":"https://cdn.real-debrid.com/dl/movie.mkv","streamable":1,
              "generated":"2026-06-03T00:00:00.000Z"}]
            """)
        }
        let items = try await client().listDownloads()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].download, "https://cdn.real-debrid.com/dl/movie.mkv")
        XCTAssertEqual(items[0].streamable, 1)
        XCTAssertEqual(items[0].mimeType, "video/x-matroska")
    }

    func testAllTorrentsPagesUntilShortPage() async throws {
        // page 1 returns `limit` items (full page), page 2 returns 1 (short page) -> stop.
        nonisolated(unsafe) var pagesRequested: [String] = []
        MockURLProtocol.setHandler { request in
            let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let page = comps.queryItems!.first { $0.name == "page" }!.value!
            pagesRequested.append(page)
            func item(_ id: String) -> String {
                """
                {"id":"\(id)","filename":"f","hash":"h","bytes":1,"host":"rd",
                 "split":2000,"progress":100,"status":"downloaded",
                 "added":"2026-06-01T00:00:00.000Z","links":[]}
                """
            }
            if page == "1" { return .json("[\(item("A")),\(item("B"))]") }
            return .json("[\(item("C"))]")
        }
        let all = try await client().allTorrents(limit: 2)
        XCTAssertEqual(all.map(\.id), ["A", "B", "C"])
        XCTAssertEqual(pagesRequested, ["1", "2"])
    }

    func testEmptyLibraryReturnsEmptyArray() async throws {
        // RD returns 204 No Content with empty body for an empty list.
        MockURLProtocol.setHandler { _ in .json("", status: 204) }
        let items = try await client().listTorrents()
        XCTAssertEqual(items, [])
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter RealDebridListTests`
Expected: **compile error** — `listTorrents`, `TorrentListItem` etc. don't exist yet. That is the failing state for a compiled language; proceed.

- [ ] **Step 4: Implement — models**

Append to `Sources/StreamCore/RealDebrid/RealDebridModels.swift`:

```swift
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
```

- [ ] **Step 5: Implement — query support in `send` and the endpoints**

In `Sources/StreamCore/RealDebrid/RealDebridClient.swift`, replace the `send` function's request-building lines with a version that accepts query items. The full new `send`:

```swift
    /// Performs one authenticated request, retrying on rate-limit up to `maxRetries`.
    /// Returns the raw 2xx body. Throws a mapped `RealDebridError` on any non-2xx.
    func send(_ method: String, _ path: String,
              query: [String: String]? = nil,
              form: [String: String]? = nil) async throws -> Data {
        var attempt = 0
        while true {
            var url = config.baseURL.appendingPathComponent(path)
            if let query, !query.isEmpty {
                var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                comps.queryItems = query.sorted { $0.key < $1.key }
                    .map { URLQueryItem(name: $0.key, value: $0.value) }
                url = comps.url!
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let form {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Self.formEncode(form)
            }

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw RealDebridError.badResponse }
            if (200..<300).contains(http.statusCode) { return data }

            let apiError = try? JSONDecoder().decode(RealDebridAPIError.self, from: data)
            let mapped = RealDebridError.map(status: http.statusCode,
                                             apiError: apiError,
                                             retryAfter: Self.retryAfter(http))
            if case .rateLimited(let ra) = mapped, attempt < config.maxRetries {
                attempt += 1
                try await sleep(ra ?? config.retryBaseDelay * Double(attempt))
                continue
            }
            throw mapped
        }
    }
```

Then add the endpoints after `torrentInfo` in the `// MARK: Endpoints` section:

```swift
    /// One page of the user's torrent list (`GET /torrents`).
    /// RD answers 204 with an empty body when the list is empty — treat as [].
    public func listTorrents(page: Int = 1, limit: Int = 100) async throws -> [TorrentListItem] {
        let data = try await send("GET", "torrents",
                                  query: ["page": String(page), "limit": String(limit)])
        if data.isEmpty { return [] }
        return try decode([TorrentListItem].self, from: data)
    }

    /// Every torrent in the account: pages until a short page.
    public func allTorrents(limit: Int = 100) async throws -> [TorrentListItem] {
        var all: [TorrentListItem] = []
        var page = 1
        while true {
            let batch = try await listTorrents(page: page, limit: limit)
            all.append(contentsOf: batch)
            if batch.count < limit { return all }
            page += 1
        }
    }

    /// One page of previously unrestricted links (`GET /downloads`).
    public func listDownloads(page: Int = 1, limit: Int = 100) async throws -> [DownloadListItem] {
        let data = try await send("GET", "downloads",
                                  query: ["page": String(page), "limit": String(limit)])
        if data.isEmpty { return [] }
        return try decode([DownloadListItem].self, from: data)
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test`
Expected: all tests pass (4 in RealDebridListTests), 0 failures.

- [ ] **Step 7: Commit**

```bash
git add Sources/StreamCore/RealDebrid Tests/StreamCoreTests
git commit -m "feat: Real-Debrid client with torrent/download list endpoints (from Cascade)"
```

---

### Task 3: ReleaseNameParser

**Files:**
- Create: `Sources/StreamCore/Parse/ReleaseNameParser.swift`
- Test: `Tests/StreamCoreTests/ReleaseNameParserTests.swift`

**Interfaces:**
- Consumes: nothing (pure function, Foundation only).
- Produces (used by Task 6 store and Plan 2):
  - `struct ParsedRelease: Sendable, Equatable { var title: String; var year: Int?; var season: Int?; var episode: Int?; var quality: String?; var source: String?; var isTV: Bool }`
  - `enum ReleaseNameParser { static func parse(_ name: String) -> ParsedRelease }`

- [ ] **Step 1: Write the failing fixture-table test**

`Tests/StreamCoreTests/ReleaseNameParserTests.swift`:

```swift
import XCTest
@testable import StreamCore

final class ReleaseNameParserTests: XCTestCase {
    private struct Case {
        let input: String
        let expected: ParsedRelease
        let line: UInt
        init(_ input: String, _ expected: ParsedRelease, line: UInt = #line) {
            self.input = input; self.expected = expected; self.line = line
        }
    }

    private func p(_ title: String, year: Int? = nil, season: Int? = nil,
                   episode: Int? = nil, quality: String? = nil,
                   source: String? = nil) -> ParsedRelease {
        ParsedRelease(title: title, year: year, season: season,
                      episode: episode, quality: quality, source: source)
    }

    func testFixtureTable() {
        let cases: [Case] = [
            Case("The.Matrix.1999.1080p.BluRay.x264-GROUP.mkv",
                 p("The Matrix", year: 1999, quality: "1080p", source: "BluRay")),
            Case("Dune.Part.Two.2024.2160p.WEB-DL.DDP5.1.Atmos.mkv",
                 p("Dune Part Two", year: 2024, quality: "2160p", source: "WEB-DL")),
            Case("Breaking.Bad.S05E14.720p.HDTV.x264-ASAP.mkv",
                 p("Breaking Bad", season: 5, episode: 14, quality: "720p", source: "HDTV")),
            Case("The.Bear.2022.S03E01.1080p.WEB.h264-SUCCESSFULCRAB.mkv",
                 p("The Bear", year: 2022, season: 3, episode: 1, quality: "1080p", source: "WEB")),
            Case("show name 1x02 whatever.mp4",
                 p("show name", season: 1, episode: 2)),
            Case("2012.2009.1080p.BluRay.mkv",                       // leading-year title
                 p("2012", year: 2009, quality: "1080p", source: "BluRay")),
            Case("Movie.Without.Year.1080p.mkv",
                 p("Movie Without Year", quality: "1080p")),
            Case("Oppenheimer (2023) 2160p WEBRip.mp4",              // parenthesised year
                 p("Oppenheimer", year: 2023, quality: "2160p", source: "WEBRip")),
            Case("[SubsPlease] Frieren - 05 [1080p].mkv",            // anime style
                 p("Frieren", episode: 5, quality: "1080p")),
            Case("The.Office.US.S09E23.S09E24.720p.WEB-DL.mkv",      // double episode: first wins
                 p("The Office US", season: 9, episode: 23, quality: "720p", source: "WEB-DL")),
            Case("Interstellar.2014.IMAX.2160p.4K.BluRay.mkv",
                 p("Interstellar", year: 2014, quality: "2160p", source: "BluRay")),
            Case("Some.Movie.4K.HDR.mkv",                            // 4K token maps to 2160p
                 p("Some Movie", quality: "2160p")),
            Case("plain_filename.mkv", p("plain filename")),
            Case("no extension at all", p("no extension at all")),
            Case("Snowpiercer.1x09.HDTV.mp4",
                 p("Snowpiercer", season: 1, episode: 9, source: "HDTV")),
        ]
        for c in cases {
            let got = ReleaseNameParser.parse(c.input)
            XCTAssertEqual(got, c.expected, "input: \(c.input)", line: c.line)
        }
    }

    func testIsTV() {
        XCTAssertTrue(ReleaseNameParser.parse("A.S01E01.mkv").isTV)
        XCTAssertTrue(ReleaseNameParser.parse("[G] B - 03 [720p].mkv").isTV)
        XCTAssertFalse(ReleaseNameParser.parse("A.2020.1080p.mkv").isTV)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ReleaseNameParserTests`
Expected: compile error — `ReleaseNameParser` doesn't exist.

- [ ] **Step 3: Implement the parser**

`Sources/StreamCore/Parse/ReleaseNameParser.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ReleaseNameParserTests`
Expected: PASS (2 tests). If a fixture fails, fix the parser — not the fixture — unless the fixture contradicts the spec's grammar (dots/underscores as spaces, year terminates title, S01E02 / 1x02 patterns, quality and source tokens, group suffix after final dash).

- [ ] **Step 5: Run the full suite and commit**

Run: `swift test`
Expected: all green.

```bash
git add Sources/StreamCore/Parse Tests/StreamCoreTests/ReleaseNameParserTests.swift
git commit -m "feat: release-name parser with fixture-table tests"
```

---

### Task 4: TMDB Client

**Files:**
- Create: `Sources/StreamCore/TMDB/TMDBClient.swift`
- Create: `Sources/StreamCore/TMDB/TMDBModels.swift`
- Test: `Tests/StreamCoreTests/TMDBClientTests.swift`

**Interfaces:**
- Consumes: `MockURLProtocol` from Task 2 (tests only).
- Produces (used by Task 6 matching and Plan 2 UI):
  - `TMDBClient.init(bearerToken: String, session: URLSession = .shared)` — bearerToken is TMDB's v4 "API Read Access Token".
  - `func searchMovie(title: String, year: Int?) async throws -> [TMDBMovie]`
  - `func searchTV(title: String, year: Int?) async throws -> [TMDBShow]`
  - `func episode(showID: Int, season: Int, episode: Int) async throws -> TMDBEpisode`
  - `struct TMDBMovie: { id: Int; title: String; overview: String; posterPath: String?; releaseDate: String?; voteAverage: Double }`
  - `struct TMDBShow: { id: Int; name: String; overview: String; posterPath: String?; firstAirDate: String?; voteAverage: Double }`
  - `struct TMDBEpisode: { id: Int; name: String; overview: String; stillPath: String?; airDate: String? }`
  - `enum TMDB { static func imageURL(path: String, width: Int = 500) -> URL }`
  - `enum TMDBError: Error, Equatable { case unauthorized, http(Int), badResponse }`

- [ ] **Step 1: Write failing tests**

`Tests/StreamCoreTests/TMDBClientTests.swift`:

```swift
import XCTest
@testable import StreamCore

final class TMDBClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func client() -> TMDBClient {
        TMDBClient(bearerToken: "TOK", session: .mocked())
    }

    func testSearchMovieRequestAndDecode() async throws {
        nonisolated(unsafe) var seen: URLRequest?
        MockURLProtocol.setHandler { request in
            seen = request
            return .json("""
            {"page":1,"results":[{"id":603,"title":"The Matrix",
              "overview":"A hacker...","poster_path":"/p.jpg",
              "release_date":"1999-03-30","vote_average":8.2}]}
            """)
        }
        let results = try await client().searchMovie(title: "The Matrix", year: 1999)
        XCTAssertEqual(results, [TMDBMovie(id: 603, title: "The Matrix",
                                           overview: "A hacker...", posterPath: "/p.jpg",
                                           releaseDate: "1999-03-30", voteAverage: 8.2)])
        let req = try XCTUnwrap(seen)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer TOK")
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        XCTAssertTrue(comps.path.hasSuffix("/search/movie"))
        XCTAssertEqual(Set(comps.queryItems ?? []),
                       [URLQueryItem(name: "primary_release_year", value: "1999"),
                        URLQueryItem(name: "query", value: "The Matrix")])
    }

    func testSearchTVOmitsYearWhenNil() async throws {
        nonisolated(unsafe) var seen: URL?
        MockURLProtocol.setHandler { request in
            seen = request.url
            return .json("""
            {"page":1,"results":[{"id":1396,"name":"Breaking Bad","overview":"...",
              "poster_path":null,"first_air_date":"2008-01-20","vote_average":8.9}]}
            """)
        }
        let results = try await client().searchTV(title: "Breaking Bad", year: nil)
        XCTAssertEqual(results.first?.id, 1396)
        XCTAssertNil(results.first?.posterPath)
        let comps = URLComponents(url: try XCTUnwrap(seen), resolvingAgainstBaseURL: false)!
        XCTAssertTrue(comps.path.hasSuffix("/search/tv"))
        XCTAssertEqual(comps.queryItems, [URLQueryItem(name: "query", value: "Breaking Bad")])
    }

    func testEpisodeFetch() async throws {
        nonisolated(unsafe) var seen: URL?
        MockURLProtocol.setHandler { request in
            seen = request.url
            return .json("""
            {"id":62161,"name":"Ozymandias","overview":"...",
             "still_path":"/s.jpg","air_date":"2013-09-15"}
            """)
        }
        let ep = try await client().episode(showID: 1396, season: 5, episode: 14)
        XCTAssertEqual(ep.name, "Ozymandias")
        XCTAssertTrue(try XCTUnwrap(seen).path.hasSuffix("/tv/1396/season/5/episode/14"))
    }

    func testUnauthorizedMapsToError() async {
        MockURLProtocol.setHandler { _ in .json(#"{"status_code":7}"#, status: 401) }
        do {
            _ = try await client().searchMovie(title: "x", year: nil)
            XCTFail("expected throw")
        } catch let e as TMDBError {
            XCTAssertEqual(e, .unauthorized)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testImageURL() {
        XCTAssertEqual(TMDB.imageURL(path: "/p.jpg").absoluteString,
                       "https://image.tmdb.org/t/p/w500/p.jpg")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TMDBClientTests`
Expected: compile error — `TMDBClient` doesn't exist.

- [ ] **Step 3: Implement models**

`Sources/StreamCore/TMDB/TMDBModels.swift`:

```swift
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
```

- [ ] **Step 4: Implement client**

`Sources/StreamCore/TMDB/TMDBClient.swift`:

```swift
import Foundation

/// Minimal TMDB v3 client authenticated with a v4 "API Read Access Token".
public struct TMDBClient: Sendable {
    let bearerToken: String
    let session: URLSession
    let baseURL: URL

    public init(bearerToken: String,
                session: URLSession = .shared,
                baseURL: URL = URL(string: "https://api.themoviedb.org/3")!) {
        self.bearerToken = bearerToken
        self.session = session
        self.baseURL = baseURL
    }

    func get(_ path: String, query: [String: String]) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TMDBError.badResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401:       throw TMDBError.unauthorized
        default:        throw TMDBError.http(http.statusCode)
        }
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw TMDBError.badResponse }
    }

    public func searchMovie(title: String, year: Int?) async throws -> [TMDBMovie] {
        var query = ["query": title]
        if let year { query["primary_release_year"] = String(year) }
        let data = try await get("search/movie", query: query)
        return try decode(TMDBSearchEnvelope<TMDBMovie>.self, from: data).results
    }

    public func searchTV(title: String, year: Int?) async throws -> [TMDBShow] {
        var query = ["query": title]
        if let year { query["first_air_date_year"] = String(year) }
        let data = try await get("search/tv", query: query)
        return try decode(TMDBSearchEnvelope<TMDBShow>.self, from: data).results
    }

    public func episode(showID: Int, season: Int, episode: Int) async throws -> TMDBEpisode {
        let data = try await get("tv/\(showID)/season/\(season)/episode/\(episode)", query: [:])
        return try decode(TMDBEpisode.self, from: data)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter TMDBClientTests`
Expected: PASS (5 tests). Then `swift test` — full suite green.

- [ ] **Step 6: Commit**

```bash
git add Sources/StreamCore/TMDB Tests/StreamCoreTests/TMDBClientTests.swift
git commit -m "feat: TMDB search/episode client"
```

---

### Task 5: OpenSubtitles Client

**Files:**
- Create: `Sources/StreamCore/OpenSubtitles/OpenSubtitlesClient.swift`
- Test: `Tests/StreamCoreTests/OpenSubtitlesClientTests.swift`

**Interfaces:**
- Consumes: `MockURLProtocol` from Task 2 (tests only).
- Produces (used by Plan 2 player):
  - `OpenSubtitlesClient.init(apiKey: String, session: URLSession = .shared)`
  - `func search(query: String, season: Int?, episode: Int?, languages: String = "en") async throws -> [SubtitleResult]`
  - `func downloadSubtitle(fileID: Int, into directory: URL) async throws -> URL` — resolves the download link, fetches it, writes the file, returns its path.
  - `struct SubtitleResult: Sendable, Equatable { id: String; language: String; release: String; fileID: Int; fileName: String }`
  - `enum OpenSubtitlesError: Error, Equatable { case unauthorized, quotaExceeded, http(Int), badResponse }`

- [ ] **Step 1: Write failing tests**

`Tests/StreamCoreTests/OpenSubtitlesClientTests.swift`:

```swift
import XCTest
@testable import StreamCore

final class OpenSubtitlesClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func client() -> OpenSubtitlesClient {
        OpenSubtitlesClient(apiKey: "KEY", session: .mocked())
    }

    private static let searchJSON = """
    {"total_count":1,"data":[
      {"id":"7061","type":"subtitle","attributes":{
        "language":"en","release":"Breaking.Bad.S05E14.720p",
        "files":[{"file_id":911,"file_name":"ozymandias.srt"}]}},
      {"id":"7062","type":"subtitle","attributes":{
        "language":"en","release":"no-files-entry","files":[]}}]}
    """

    func testSearchRequestAndDecode() async throws {
        nonisolated(unsafe) var seen: URLRequest?
        MockURLProtocol.setHandler { request in
            seen = request
            return .json(Self.searchJSON)
        }
        let results = try await client().search(query: "Breaking Bad", season: 5, episode: 14)
        // Entries without files are dropped — nothing downloadable.
        XCTAssertEqual(results, [SubtitleResult(id: "7061", language: "en",
                                                release: "Breaking.Bad.S05E14.720p",
                                                fileID: 911, fileName: "ozymandias.srt")])
        let req = try XCTUnwrap(seen)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Api-Key"), "KEY")
        XCTAssertNotNil(req.value(forHTTPHeaderField: "User-Agent"))
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        XCTAssertTrue(comps.path.hasSuffix("/subtitles"))
        XCTAssertEqual(Set(comps.queryItems ?? []),
                       [URLQueryItem(name: "episode_number", value: "14"),
                        URLQueryItem(name: "languages", value: "en"),
                        URLQueryItem(name: "query", value: "Breaking Bad"),
                        URLQueryItem(name: "season_number", value: "5")])
    }

    func testDownloadWritesFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("riptide-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        MockURLProtocol.setHandler { request in
            if request.url!.path.hasSuffix("/download") {
                return .json(#"{"link":"https://dl.opensubtitles.com/f/911.srt","file_name":"ozymandias.srt"}"#)
            }
            return .json("1\n00:00:01,000 --> 00:00:02,000\nhello\n")
        }
        let fileURL = try await client().downloadSubtitle(fileID: 911, into: dir)
        XCTAssertEqual(fileURL.lastPathComponent, "ozymandias.srt")
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("hello"))
    }

    func testQuotaExceededMapsToError() async {
        MockURLProtocol.setHandler { _ in .json(#"{"message":"quota"}"#, status: 406) }
        do {
            _ = try await client().search(query: "x", season: nil, episode: nil)
            XCTFail("expected throw")
        } catch let e as OpenSubtitlesError {
            XCTAssertEqual(e, .quotaExceeded)
        } catch { XCTFail("wrong error: \(error)") }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter OpenSubtitlesClientTests`
Expected: compile error — `OpenSubtitlesClient` doesn't exist.

- [ ] **Step 3: Implement**

`Sources/StreamCore/OpenSubtitles/OpenSubtitlesClient.swift`:

```swift
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
        let target = directory.appendingPathComponent(resolved.fileName)
        try fileData.write(to: target, options: .atomic)
        return target
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter OpenSubtitlesClientTests`
Expected: PASS (3 tests). Then `swift test` — full suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/StreamCore/OpenSubtitles Tests/StreamCoreTests/OpenSubtitlesClientTests.swift
git commit -m "feat: OpenSubtitles search/download client"
```

---

### Task 6: LibraryStore (SwiftData)

**Files:**
- Create: `Sources/StreamCore/Store/LibraryModels.swift`
- Create: `Sources/StreamCore/Store/LibraryStore.swift`
- Test: `Tests/StreamCoreTests/LibraryStoreTests.swift`

**Interfaces:**
- Consumes: `TorrentListItem` (Task 2), `ParsedRelease` / `ReleaseNameParser` (Task 3).
- Produces (used by Plan 2 UI):
  - `@Model final class LibraryItem` — fields listed in Step 3.
  - `@Model final class WatchState` — fields listed in Step 3.
  - `@MainActor final class LibraryStore { init(container: ModelContainer) }`
  - `func upsert(torrents: [TorrentListItem]) throws -> UpsertSummary` — parses filenames, inserts new items, updates changed ones, deletes items whose torrent vanished from RD. `struct UpsertSummary: Equatable { var inserted: Int; var updated: Int; var deleted: Int }`
  - `func items() throws -> [LibraryItem]` (sorted by `addedAt` descending)
  - `func applyMatch(torrentID: String, tmdbID: Int, mediaKind: String, posterPath: String?, overview: String?, rating: Double?) throws`
  - `func saveProgress(itemKey: String, position: Double, duration: Double) throws` — upserts WatchState; `position/duration >= 0.95` sets `finished = true`.
  - `func continueWatching() throws -> [WatchState]` — unfinished, position > 0, most recent first.
  - `static func inMemory() throws -> LibraryStore` (tests + previews)

- [ ] **Step 1: Write failing tests**

`Tests/StreamCoreTests/LibraryStoreTests.swift`:

```swift
import XCTest
import SwiftData
@testable import StreamCore

@MainActor
final class LibraryStoreTests: XCTestCase {
    private func torrent(id: String, filename: String,
                         added: String = "2026-06-01T00:00:00.000Z",
                         links: [String] = ["https://real-debrid.com/d/X"]) -> TorrentListItem {
        TorrentListItem(id: id, filename: filename, bytes: 100, progress: 100,
                        status: "downloaded", added: added, links: links, ended: nil)
    }

    func testUpsertInsertsAndParses() throws {
        let store = try LibraryStore.inMemory()
        let summary = try store.upsert(torrents: [
            torrent(id: "T1", filename: "The.Matrix.1999.1080p.BluRay.mkv"),
            torrent(id: "T2", filename: "Breaking.Bad.S05E14.720p.HDTV.mkv"),
        ])
        XCTAssertEqual(summary, UpsertSummary(inserted: 2, updated: 0, deleted: 0))
        let items = try store.items()
        XCTAssertEqual(items.count, 2)
        let matrix = try XCTUnwrap(items.first { $0.torrentID == "T1" })
        XCTAssertEqual(matrix.title, "The Matrix")
        XCTAssertEqual(matrix.year, 1999)
        XCTAssertEqual(matrix.mediaKind, "movie")
        let bb = try XCTUnwrap(items.first { $0.torrentID == "T2" })
        XCTAssertEqual(bb.season, 5)
        XCTAssertEqual(bb.episode, 14)
        XCTAssertEqual(bb.mediaKind, "episode")
    }

    func testUpsertIsIdempotentAndDiffs() throws {
        let store = try LibraryStore.inMemory()
        _ = try store.upsert(torrents: [torrent(id: "T1", filename: "A.2020.mkv"),
                                        torrent(id: "T2", filename: "B.2021.mkv")])
        // Second sync: T1 unchanged, T2 vanished, T3 new.
        let summary = try store.upsert(torrents: [torrent(id: "T1", filename: "A.2020.mkv"),
                                                  torrent(id: "T3", filename: "C.2022.mkv")])
        XCTAssertEqual(summary, UpsertSummary(inserted: 1, updated: 0, deleted: 1))
        XCTAssertEqual(Set(try store.items().map(\.torrentID)), ["T1", "T3"])
    }

    func testUpsertUpdatesChangedFilename() throws {
        let store = try LibraryStore.inMemory()
        _ = try store.upsert(torrents: [torrent(id: "T1", filename: "old.mkv")])
        let summary = try store.upsert(torrents: [torrent(id: "T1", filename: "A.2020.1080p.mkv")])
        XCTAssertEqual(summary, UpsertSummary(inserted: 0, updated: 1, deleted: 0))
        let item = try XCTUnwrap(try store.items().first)
        XCTAssertEqual(item.title, "A")
        XCTAssertEqual(item.year, 2020)
    }

    func testApplyMatch() throws {
        let store = try LibraryStore.inMemory()
        _ = try store.upsert(torrents: [torrent(id: "T1", filename: "The.Matrix.1999.mkv")])
        try store.applyMatch(torrentID: "T1", tmdbID: 603, mediaKind: "movie",
                             posterPath: "/p.jpg", overview: "A hacker...", rating: 8.2)
        let item = try XCTUnwrap(try store.items().first)
        XCTAssertEqual(item.tmdbID, 603)
        XCTAssertEqual(item.posterPath, "/p.jpg")
    }

    func testWatchProgressLifecycle() throws {
        let store = try LibraryStore.inMemory()
        try store.saveProgress(itemKey: "T1#0", position: 300, duration: 7200)
        var cw = try store.continueWatching()
        XCTAssertEqual(cw.map(\.itemKey), ["T1#0"])
        XCTAssertEqual(cw[0].positionSeconds, 300)
        XCTAssertFalse(cw[0].finished)

        // Update overwrites, doesn't duplicate.
        try store.saveProgress(itemKey: "T1#0", position: 600, duration: 7200)
        cw = try store.continueWatching()
        XCTAssertEqual(cw.count, 1)
        XCTAssertEqual(cw[0].positionSeconds, 600)

        // >= 95% marks finished and leaves Continue Watching.
        try store.saveProgress(itemKey: "T1#0", position: 6900, duration: 7200)
        XCTAssertTrue(try store.continueWatching().isEmpty)
    }

    func testContinueWatchingOrdersByRecency() throws {
        let store = try LibraryStore.inMemory()
        try store.saveProgress(itemKey: "old", position: 10, duration: 100)
        try store.saveProgress(itemKey: "new", position: 10, duration: 100)
        // "new" was written later -> more recent lastWatchedAt -> first.
        XCTAssertEqual(try store.continueWatching().map(\.itemKey), ["new", "old"])
    }
}
```

Note: this test file needs a memberwise `TorrentListItem` initializer. Add one to `RealDebridModels.swift` in Step 3 (Decodable-only structs don't synthesize public inits).

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LibraryStoreTests`
Expected: compile error — `LibraryStore` doesn't exist.

- [ ] **Step 3: Implement models**

Add to `Sources/StreamCore/RealDebrid/RealDebridModels.swift`, inside `TorrentListItem`:

```swift
    public init(id: String, filename: String, bytes: Int64, progress: Double,
                status: String, added: String, links: [String], ended: String?) {
        self.id = id; self.filename = filename; self.bytes = bytes
        self.progress = progress; self.status = status; self.added = added
        self.links = links; self.ended = ended
    }
```

`Sources/StreamCore/Store/LibraryModels.swift`:

```swift
import Foundation
import SwiftData

/// One RD torrent surfaced in the library. `torrentID` mirrors RD; parsed and
/// TMDB fields are denormalized here so shelves render offline from cache.
@Model
public final class LibraryItem {
    @Attribute(.unique) public var torrentID: String
    public var filename: String
    public var sizeBytes: Int64
    public var addedAt: String            // raw ISO-8601 from RD, sortable as string
    public var links: [String]
    // Parsed from filename
    public var title: String
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    public var quality: String?
    // TMDB match (nil until matched; item renders as plain file card)
    public var tmdbID: Int?
    public var mediaKind: String          // "movie" | "episode" | "unknown"
    public var posterPath: String?
    public var overview: String?
    public var rating: Double?
    public var lastRefreshed: Date

    public init(torrentID: String, filename: String, sizeBytes: Int64, addedAt: String,
                links: [String], parsed: ParsedRelease, lastRefreshed: Date = .now) {
        self.torrentID = torrentID
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.addedAt = addedAt
        self.links = links
        self.title = parsed.title
        self.year = parsed.year
        self.season = parsed.season
        self.episode = parsed.episode
        self.quality = parsed.quality
        self.tmdbID = nil
        self.mediaKind = parsed.isTV ? "episode" : "movie"
        self.posterPath = nil
        self.overview = nil
        self.rating = nil
        self.lastRefreshed = lastRefreshed
    }
}

/// Playback position for one file. `itemKey` = "<torrentID>#<fileIndex>" so
/// multi-file packs track per-file progress.
@Model
public final class WatchState {
    @Attribute(.unique) public var itemKey: String
    public var positionSeconds: Double
    public var durationSeconds: Double
    public var lastWatchedAt: Date
    public var finished: Bool

    public init(itemKey: String, positionSeconds: Double, durationSeconds: Double,
                lastWatchedAt: Date = .now, finished: Bool = false) {
        self.itemKey = itemKey
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.lastWatchedAt = lastWatchedAt
        self.finished = finished
    }
}
```

- [ ] **Step 4: Implement store**

`Sources/StreamCore/Store/LibraryStore.swift`:

```swift
import Foundation
import SwiftData

public struct UpsertSummary: Equatable, Sendable {
    public var inserted: Int
    public var updated: Int
    public var deleted: Int

    public init(inserted: Int, updated: Int, deleted: Int) {
        self.inserted = inserted; self.updated = updated; self.deleted = deleted
    }
}

/// SwiftData-backed library cache + watch positions. MainActor because the app
/// reads it from SwiftUI; all operations are synchronous on the main context.
@MainActor
public final class LibraryStore {
    public let container: ModelContainer
    let context: ModelContext

    public init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
    }

    public static func inMemory() throws -> LibraryStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: LibraryItem.self, WatchState.self,
                                           configurations: config)
        return LibraryStore(container: container)
    }

    /// On-disk store in Application Support (Plan 2 app entry point uses this).
    public static func onDisk() throws -> LibraryStore {
        let container = try ModelContainer(for: LibraryItem.self, WatchState.self)
        return LibraryStore(container: container)
    }

    // MARK: Library sync

    /// Mirror the RD torrent list into the cache: insert new, update changed
    /// (by filename/links/size), delete vanished. Parsing happens here so the
    /// UI never sees an unparsed item.
    public func upsert(torrents: [TorrentListItem]) throws -> UpsertSummary {
        let existing = try context.fetch(FetchDescriptor<LibraryItem>())
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.torrentID, $0) })
        var summary = UpsertSummary(inserted: 0, updated: 0, deleted: 0)

        for t in torrents {
            if let item = byID.removeValue(forKey: t.id) {
                if item.filename != t.filename || item.links != t.links
                    || item.sizeBytes != t.bytes {
                    let parsed = ReleaseNameParser.parse(t.filename)
                    item.filename = t.filename
                    item.sizeBytes = t.bytes
                    item.links = t.links
                    item.title = parsed.title
                    item.year = parsed.year
                    item.season = parsed.season
                    item.episode = parsed.episode
                    item.quality = parsed.quality
                    item.mediaKind = parsed.isTV ? "episode" : "movie"
                    // Filename changed -> stale match; rematch on next refresh.
                    item.tmdbID = nil
                    item.posterPath = nil
                    item.overview = nil
                    item.rating = nil
                    item.lastRefreshed = .now
                    summary.updated += 1
                }
            } else {
                context.insert(LibraryItem(torrentID: t.id, filename: t.filename,
                                           sizeBytes: t.bytes, addedAt: t.added,
                                           links: t.links,
                                           parsed: ReleaseNameParser.parse(t.filename)))
                summary.inserted += 1
            }
        }
        // Anything left in byID no longer exists on RD.
        for (_, orphan) in byID {
            context.delete(orphan)
            summary.deleted += 1
        }
        try context.save()
        return summary
    }

    public func items() throws -> [LibraryItem] {
        try context.fetch(FetchDescriptor<LibraryItem>(
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]))
    }

    public func applyMatch(torrentID: String, tmdbID: Int, mediaKind: String,
                           posterPath: String?, overview: String?, rating: Double?) throws {
        let descriptor = FetchDescriptor<LibraryItem>(
            predicate: #Predicate { $0.torrentID == torrentID })
        guard let item = try context.fetch(descriptor).first else { return }
        item.tmdbID = tmdbID
        item.mediaKind = mediaKind
        item.posterPath = posterPath
        item.overview = overview
        item.rating = rating
        item.lastRefreshed = .now
        try context.save()
    }

    // MARK: Watch state

    /// Upsert playback position. >= 95% watched marks the item finished (spec).
    public func saveProgress(itemKey: String, position: Double, duration: Double) throws {
        let descriptor = FetchDescriptor<WatchState>(
            predicate: #Predicate { $0.itemKey == itemKey })
        let finished = duration > 0 && position / duration >= 0.95
        if let state = try context.fetch(descriptor).first {
            state.positionSeconds = position
            state.durationSeconds = duration
            state.lastWatchedAt = .now
            state.finished = finished
        } else {
            context.insert(WatchState(itemKey: itemKey, positionSeconds: position,
                                      durationSeconds: duration, finished: finished))
        }
        try context.save()
    }

    /// Unfinished, started items, most recently watched first.
    public func continueWatching() throws -> [WatchState] {
        try context.fetch(FetchDescriptor<WatchState>(
            predicate: #Predicate { !$0.finished && $0.positionSeconds > 0 },
            sortBy: [SortDescriptor(\.lastWatchedAt, order: .reverse)]))
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter LibraryStoreTests`
Expected: PASS (6 tests).

Note: `testContinueWatchingOrdersByRecency` compares two `.now` timestamps taken microseconds apart; if it ever flakes on equal timestamps, insert `usleep(1000)` between the two `saveProgress` calls in the test — do not change the store.

- [ ] **Step 6: Run the full suite and commit**

Run: `swift test`
Expected: all tests green (≈21 across 5 files).

```bash
git add Sources/StreamCore/Store Sources/StreamCore/RealDebrid/RealDebridModels.swift Tests/StreamCoreTests/LibraryStoreTests.swift
git commit -m "feat: SwiftData library store with sync diffing and watch state"
```

---

## Plan 1 Exit Criteria

- `swift test` fully green; `swift build` clean under Swift 6 strict concurrency.
- `grep -r "import SwiftUI\|import AppKit" Sources/StreamCore/` returns nothing.
- All six tasks committed individually on a feature branch (`feat/plan-1-streamcore`).

## Deferred to Plan 2 (app + player)

MPVKit dependency and player view, library shelves UI, TMDB matching orchestration (parser → search → `applyMatch` pipeline with rate limiting), Keychain storage for the three API keys, settings sheet, resume prompt, OpenSubtitles picker UI.
