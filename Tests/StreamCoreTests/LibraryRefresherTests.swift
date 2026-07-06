import XCTest
@testable import StreamCore

@MainActor
final class LibraryRefresherTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.setHandler(nil)
        super.tearDown()
    }

    private func makeRefresher(store: LibraryStore) -> LibraryRefresher {
        LibraryRefresher(rd: RealDebridClient(token: "T", session: .mocked()),
                         tmdb: TMDBClient(bearerToken: "K", session: .mocked()),
                         store: store)
    }

    nonisolated private static func torrentJSON(id: String, filename: String,
                                                status: String = "downloaded") -> String {
        """
        {"id":"\(id)","filename":"\(filename)","hash":"h","bytes":100,"host":"rd",
         "split":2000,"progress":100,"status":"\(status)",
         "added":"2026-06-01T00:00:00.000Z","links":["https://real-debrid.com/d/\(id)"]}
        """
    }

    /// Routes by host: RD list call vs TMDB search calls.
    private static func handler(torrents: [String],
                                movieResults: String = #"{"results":[]}"#,
                                tvResults: String = #"{"results":[]}"#)
        -> @Sendable (URLRequest) -> MockURLProtocol.Stub {
        { request in
            let url = request.url!
            if url.host!.contains("real-debrid") {
                return .json("[\(torrents.joined(separator: ","))]")
            }
            if url.path.hasSuffix("/search/movie") { return .json(movieResults) }
            if url.path.hasSuffix("/search/tv") { return .json(tvResults) }
            return .json("{}", status: 404)
        }
    }

    func testMatchesMovieAndAppliesMetadata() async throws {
        let store = try LibraryStore.inMemory()
        MockURLProtocol.setHandler(Self.handler(
            torrents: [Self.torrentJSON(id: "T1", filename: "The.Matrix.1999.1080p.mkv")],
            movieResults: """
            {"results":[{"id":603,"title":"The Matrix","overview":"A hacker...",
              "poster_path":"/p.jpg","release_date":"1999-03-30","vote_average":8.2}]}
            """))
        let summary = try await makeRefresher(store: store).refresh()
        XCTAssertEqual(summary.matched, 1)
        XCTAssertEqual(summary.matchFailed, 0)
        let item = try XCTUnwrap(try store.items().first)
        XCTAssertEqual(item.tmdbID, 603)
        XCTAssertEqual(item.posterPath, "/p.jpg")
        XCTAssertEqual(item.mediaKind, "movie")
    }

    func testMatchesEpisodeViaTVSearch() async throws {
        let store = try LibraryStore.inMemory()
        MockURLProtocol.setHandler(Self.handler(
            torrents: [Self.torrentJSON(id: "T2", filename: "Breaking.Bad.S05E14.720p.mkv")],
            tvResults: """
            {"results":[{"id":1396,"name":"Breaking Bad","overview":"...",
              "poster_path":"/bb.jpg","first_air_date":"2008-01-20","vote_average":8.9}]}
            """))
        let summary = try await makeRefresher(store: store).refresh()
        XCTAssertEqual(summary.matched, 1)
        let item = try XCTUnwrap(try store.items().first)
        XCTAssertEqual(item.tmdbID, 1396)
        XCTAssertEqual(item.mediaKind, "episode")
    }

    func testNoResultsLeavesItemUnmatched() async throws {
        let store = try LibraryStore.inMemory()
        MockURLProtocol.setHandler(Self.handler(
            torrents: [Self.torrentJSON(id: "T3", filename: "Obscure.Home.Video.2024.mkv")]))
        let summary = try await makeRefresher(store: store).refresh()
        XCTAssertEqual(summary.matched, 0)
        XCTAssertEqual(summary.matchFailed, 1)
        let item = try XCTUnwrap(try store.items().first)
        XCTAssertNil(item.tmdbID)          // renders as plain file card
    }

    func testTMDBErrorIsBestEffortNotFatal() async throws {
        let store = try LibraryStore.inMemory()
        MockURLProtocol.setHandler { request in
            if request.url!.host!.contains("real-debrid") {
                return .json("[\(Self.torrentJSON(id: "T4", filename: "A.2020.mkv"))]")
            }
            return .json("{}", status: 500)   // TMDB down
        }
        let summary = try await makeRefresher(store: store).refresh()
        XCTAssertEqual(summary.matchFailed, 1)
        XCTAssertEqual(try store.items().count, 1)   // item survives
    }

    func testSkipsNonDownloadedTorrentsAndAlreadyMatched() async throws {
        let store = try LibraryStore.inMemory()
        // Seed a matched item so refresh must not re-match it.
        _ = try store.upsert(torrents: [TorrentListItem(
            id: "T5", filename: "The.Matrix.1999.mkv", bytes: 100, progress: 100,
            status: "downloaded", added: "2026-06-01T00:00:00.000Z",
            links: ["https://real-debrid.com/d/T5"], ended: nil)])
        try store.applyMatch(torrentID: "T5", tmdbID: 603, mediaKind: "movie",
                             posterPath: "/p.jpg", overview: "", rating: 8.2)

        nonisolated(unsafe) var tmdbCalls = 0
        MockURLProtocol.setHandler { request in
            if request.url!.host!.contains("real-debrid") {
                return .json("""
                [\(Self.torrentJSON(id: "T5", filename: "The.Matrix.1999.mkv")),
                 \(Self.torrentJSON(id: "T6", filename: "downloading.mkv", status: "downloading"))]
                """)
            }
            tmdbCalls += 1
            return .json(#"{"results":[]}"#)
        }
        let summary = try await makeRefresher(store: store).refresh()
        XCTAssertEqual(tmdbCalls, 0)                       // matched item not re-searched
        XCTAssertEqual(summary.matched, 0)
        XCTAssertEqual(Set(try store.items().map(\.torrentID)), ["T5"])  // T6 filtered out
    }
}
